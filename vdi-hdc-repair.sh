#!/bin/bash
# =============================================================================
# vdi-hdc-repair.sh — 恢复华为 VDI 的正规 HDC/HDP 桌面协议连接
#
# 症状：本地 HDC 客户端连不上（"虚拟机尚未就绪" 6039 / "失去连接"），
#       只能退回 VNC 才能进桌面。HDAgent 日志反复 Preconnect failed,
#       code:28104003 / "logined in to the VNC" / "IsVaildSession null"。
#
# 根因（2026-10 排查确认）：
#   HDAgent 的 HDP pre-connect 需要一个由"用户图形会话"创建的 unix socket。
#   那个 socket 由 GNOME 登录会话的 autostart（/etc/xdg/autostart/hdpdaemon.desktop
#   → hdpdaemon.sh → hdpdaemon20）拉起。一旦当前会话是 **VNC 建的**（不是正规
#   HDC 登录），HDAgent 就拒绝 HDP 接管；或会话里 hdpdaemon20 没起来 / 会话状态
#   脏了，同样 pre-connect 失败。
#
# 本脚本按风险从低到高逐级恢复，每一级都可单独跑：
#   1. --light   只注销当前 kantaoc 图形会话（loginctl terminate），
#                清掉"会话被 VNC 占住"的状态，然后等你重新用正规 HDC 登录。
#                frpc/sing-box/keepalive 全是 root 系统服务，不受影响，VPN 不断。
#   2. --agent   kill HDAgent，让华为 hdpsrvmanager_monitor 自动重拉并重新向
#                HDC 控制面注册（清 "IsVaildSession null" 空转态）。
#   3. --all     light + agent 都做（推荐先跑 --all，还不行再重启 VDI）。
#   4. --reboot  重启 VDI（最后手段，最彻底；frpc/sing-box/keepalive 都开机自启,
#                起来后自动回来）。
#
# 跑完 --all 后：**用正规 HDC 客户端（华为 Workspace，走 HDP/流媒体协议，
#   不要选 VNC/备用）重新登录 VDI**。正规登录会经 gdm 建会话 + autostart 拉起
#   hdpdaemon20，HDP 通道即通。
#
# 用法：
#   sudo bash vdi-hdc-repair.sh --light
#   sudo bash vdi-hdc-repair.sh --agent
#   sudo bash vdi-hdc-repair.sh --all
#   sudo bash vdi-hdc-repair.sh --reboot
#
# 换任意 VDI：把下面的 USER 改成那台机器的桌面用户（默认 kantaoc）。
# =============================================================================
set -uo pipefail

USER="${VDI_USER:-kantaoc}"
ACTION=""
for a in "$@"; do
  case $a in
    --light|--agent|--all|--reboot) ACTION=$a ;;
    --user) : ;; # 让 --user 值进下一条
    *) if [[ "${PREV:-}" == "--user" ]]; then USER=$a; fi ;;
  esac
  PREV=$a
done
# 简易 --user 值解析
ARGS=("$@"); for i in "${!ARGS[@]}"; do [[ "${ARGS[$i]}" == "--user" && $((i+1)) -lt ${#ARGS[@]} ]] && USER="${ARGS[$((i+1))]}"; done

[ -z "$ACTION" ] && { echo "用法: sudo bash vdi-hdc-repair.sh [--light|--agent|--all|--reboot] [--user <桌面用户>]"; exit 1; }
[[ $(id -u) -ne 0 ]] && { echo "需要 root: sudo bash $0 $ACTION"; exit 1; }

log() { echo -e "\033[1;32m[VDI-REPAIR]\033[0m $*"; }

# ---------- 前置快照（证明 VPN 没被碰） ----------
vpn_state() { echo "frpc=$(systemctl is-active frpc 2>/dev/null || echo n/a) sing-box=$(systemctl is-active sing-box 2>/dev/null || echo n/a)"; }

echo "================================================"
echo "  VDI 正规 HDC 协议恢复 — 动作: $ACTION, 桌面用户: $USER"
echo "================================================"
echo "  VPN 基线: $(vpn_state)"

# ---------- 1. 注销当前图形会话（清 VNC 占用） ----------
do_light() {
  log "注销 $USER 的当前图形会话（不影响 frpc/sing-box/keepalive）..."
  # 找该用户 seat0 的会话并 terminate
  for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$USER" '$3==u {print $1}'); do
    log "  terminate session $sid"
    loginctl terminate-session "$sid" 2>/dev/null || true
  done
  sleep 3
  log "  剩余会话: $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1,$3}' | tr '\n' ' ')"
}

# ---------- 2. 重启 HDAgent（清 IsVaildSession null 空转，重注册 HDC） ----------
do_agent() {
  log "重启 HDAgent（华为 hdpsrvmanager_monitor 会自动拉起并重新注册 HDC）..."
  pkill -f '/usr/local/hdpserver/bin/HDAgent' 2>/dev/null || log "  HDAgent 未在运行（可能本就需重启）"
  sleep 8
  if pgrep -f '/usr/local/hdpserver/bin/HDAgent' >/dev/null; then
    log "  HDAgent 已重拉: PID $(pgrep -f '/usr/local/hdpserver/bin/HDAgent' | head -1)"
  else
    log "  ⚠️ HDAgent 未被自动拉起。确认 hdpsrvmanager_monitor 在跑: $(systemctl is-active hdpsrvmanager_monitor 2>/dev/null)"
  fi
}

# ---------- 3. 恢复 bind mount（防止重启后丢，HDAgent 10分钟锁屏策略） ----------
do_bindmount() {
  FAKE="/home/$USER/keep_alive/policy_fake.xml"
  REAL="/etc/hdpserver/policy.xml"
  if [ -f "$FAKE" ] && mount | grep -q "$REAL"; then
    log "  bind mount 已挂载，跳过"
  elif [ -f "$FAKE" ]; then
    log "  恢复 bind mount: $FAKE -> $REAL"
    mount --bind "$FAKE" "$REAL" && log "  bind mount 已恢复" || log "  ⚠️ bind mount 失败（手动: sudo mount --bind $FAKE $REAL）"
  else
    log "  无 $FAKE（这台机器可能没部署 keepalive），跳过"
  fi
}

case "$ACTION" in
  light)  do_light; do_bindmount ;;
  agent)  do_agent; do_bindmount ;;
  all)    do_light; do_agent; do_bindmount ;;
  reboot)
    log "即将重启 VDI（--reboot）。frpc/sing-box/keepalive 都开机自启，起来后自动回来。"
    log "重启前快照: $(vpn_state)"
    # 尽量走华为云管理重启（会完整重建 HDP 会话栈），兜底干净 reboot
    if [ -x /usr/local/hdpserver/hwsysagent/scripts/reboot.sh ]; then
      log "调用华为 reboot.sh 重启..."
      /usr/local/hdpserver/hwsysagent/scripts/reboot.sh &
    else
      log "无华为 reboot.sh，执行干净 reboot..."
      reboot &
    fi
    wait
    exit 0
    ;;
esac

echo "================================================"
echo "  完成。"
echo "  VPN: $(vpn_state)"
echo "================================================"
echo "下一步: 用【正规 HDC 客户端（华为 Workspace，走 HDP/流媒体协议，"
echo "        不要选 VNC/备用）】重新登录 VDI 用户 $USER。"
echo "        正规登录会拉起 hdpdaemon20，HDP 通道即通。"
echo "        若仍失败 → 跑: sudo bash $0 --reboot"
