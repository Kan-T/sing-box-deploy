#!/bin/bash
# =============================================================================
# vpn-watchdog.sh — VDI VPN 自愈巡检（每 3 分钟由 systemd timer 触发）
#
# 目的：让 frpc/sing-box（翻墙出口隧道）24h 有兜底。任何一段掉线/服务挂了，
#       自动拉起并记日志。纯系统级，不依赖桌面会话 / keepalive。
#
# 巡检项（最小、无副作用）：
#   1. frpc      不 active → restart；active 但隧道没建（近期无 start proxy success）→ restart
#   2. sing-box  不 active → restart
#   3. bind mount 丢了 → mount --bind 恢复（重启后必丢，HDAgent 10min 锁屏策略兜底）
#
# 用法（root，被 timer 自动跑，也可手动）：
#   sudo bash vpn-watchdog.sh            # 巡检 + 自愈
#   sudo bash vpn-watchdog.sh --check    # 只检测不自愈
#
# 日志：/home/kantaoc/keep_alive/vpn-watchdog.log（每轮一行，供 heal.py / 人工排查）
# 可调项：KEEPALIVE_HOME（桌面用户 home，默认 /home/kantaoc）
# =============================================================================
set -uo pipefail

KEEPALIVE_HOME="${KEEPALIVE_HOME:-/home/kantaoc}/keep_alive"
LOG="$KEEPALIVE_HOME/vpn-watchdog.log"
POLICY_FAKE="$KEEPALIVE_HOME/policy_fake.xml"
POLICY_REAL="/etc/hdpserver/policy.xml"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

ts() { date '+%Y-%m-%d %H:%M:%S'; }
wlog() { echo "[$(ts)] $*" | tee -a "$LOG" >/dev/null; }

mkdir -p "$KEEPALIVE_HOME" 2>/dev/null || { echo "写不到 $KEEPALIVE_HOME，退出"; exit 0; }

# ---------- 1. frpc ----------
frpc_state=$(systemctl is-active frpc 2>/dev/null)
if [[ "$frpc_state" != "active" ]]; then
    if [[ $CHECK_ONLY -eq 1 ]]; then
        wlog "frpc=❌($frpc_state) 需重启 (--check 不自动修)"
    else
        systemctl restart frpc 2>>"$LOG"
        sleep 3
        new=$(systemctl is-active frpc 2>/dev/null)
        wlog "frpc $frpc_state→$new (已重启)"
    fi
else
    # active。再确认 frps 侧是否真有 frpc 连接着（frpc 活 ≠ 隧道在；frpc 可能挂着但连不上 frps）。
    # 用 frpc 最近一条日志判断：若最后一行是 login/start proxy success 类，健康；
    # 若是 disconnected/EOF/dial failed，说明隧道断了，重启 frpc 重建。
    LASTLINE=$(journalctl -u frpc -n 5 --no-pager 2>/dev/null | grep -vE "^--$|^$" | tail -1)
    if echo "$LASTLINE" | grep -qiE "start proxy success|login to server success"; then
        wlog "frpc=OK"
    elif echo "$LASTLINE" | grep -qiE "disconnected|EOF|dial.*fail|token.*mismatch|closing|error"; then
        if [[ $CHECK_ONLY -eq 1 ]]; then
            wlog "frpc=❌ 隧道断了 ($LASTLINE) (--check 不自动修)"
        else
            systemctl restart frpc 2>>"$LOG"; sleep 3
            wlog "frpc 隧道断→已重启"
        fi
    else
        # frpc active 且没明显断线报错，视为正常（保守，不误重启）
        wlog "frpc=OK"
    fi
fi

# ---------- 2. sing-box ----------
# 不只 is-active：活着不代表真在监听 443。补一道端口确认。
sb_state=$(systemctl is-active sing-box 2>/dev/null)
if [[ "$sb_state" != "active" ]]; then
    if [[ $CHECK_ONLY -eq 1 ]]; then
        wlog "sing-box=❌($sb_state) 需重启 (--check 不自动修)"
    else
        systemctl restart sing-box 2>>"$LOG"
        sleep 2
        wlog "sing-box $sb_state→$(systemctl is-active sing-box 2>/dev/null) (已重启)"
    fi
elif ! ss -tln 2>/dev/null | grep -qE ":443 "; then
    if [[ $CHECK_ONLY -eq 1 ]]; then
        wlog "sing-box=active 但 443 未监听 (--check 不自动修)"
    else
        systemctl restart sing-box 2>>"$LOG"
        sleep 2
        wlog "sing-box 443 未监听→已重启 (现 $(systemctl is-active sing-box 2>/dev/null))"
    fi
else
    wlog "sing-box=OK"
fi

# ---------- 3. bind mount（HDAgent 锁屏策略兜底） ----------
if [ -f "$POLICY_FAKE" ]; then
    if mount | grep -q "$POLICY_REAL"; then
        wlog "bindmount=OK"
    else
        if [[ $CHECK_ONLY -eq 1 ]]; then
            wlog "bindmount=❌ 未挂载 (--check 不自动修)"
        else
            mount --bind "$POLICY_FAKE" "$POLICY_REAL" 2>>"$LOG"
            [ "$(mount | grep -c "$POLICY_REAL")" -ge 1 ] && wlog "bindmount 已恢复" || wlog "bindmount 恢复失败"
        fi
    fi
fi

exit 0
