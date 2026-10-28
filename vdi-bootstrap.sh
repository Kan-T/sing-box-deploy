#!/bin/bash
# =============================================================================
# vdi-bootstrap.sh — 华为云 VDI (Ubuntu 20.04) 一键自举，从零/换任意机器搭建
#
# 一次跑完，把 VDI 配成"正规 HDC 桌面 + 翻墙出口 + 24h 保活 + 国内 ECS 反向通道"。
# 每一步幂等：已装就跳过，可重复运行。
#
# 做 6 件事：
#   1. 装 sing-box（翻墙出口，VLESS-Reality）      → deploy.sh
#   2. 装 frpc 反向隧道到国内 ECS                   → frp/frp-client.sh
#   3. 部署 keepalive + policy_fake.xml + bind mount（24h 不睡/不断）
#   4. 配 root SSH 公钥到 VDI（经 6022 隧道远程运维）
#   5. 确认 HDP 会话 agent 的 autostart 完好（hdpdaemon.desktop）
#   6. 打印本地客户端要用的 VLESS 链接（IP 换成国内 ECS 入口）
#
# 用法（在 VDI 里以 root 跑）：
#   sudo bash vdi-bootstrap.sh \
#     --ecs-ip 8.134.207.151 \
#     --frp-token wzlkzjioM9TBgDv2MfDGL12FZgjDdguN \
#     --ssh-pubkey "ssh-ed25519 AAAA... me@host" \
#     [--frp-bin-url "https://gh-proxy.com/..."]   # 国内下载 frp 用
#     [--sni www.apple.com]
#
# 依赖同目录下的 deploy.sh 和 frp/frp-client.sh。脚本自己定位所在目录。
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ $(id -u) -ne 0 ]] && { echo "需要 root: sudo bash $0"; exit 1; }

# ---------- 参数 ----------
ECS_IP=""
FRP_TOKEN=""
SSH_PUBKEY=""
FRP_BIN_URL=""
SNI="www.apple.com"
FRP_BIND_PORT=7000          # VDI frpc → 国内 ECS frps 的通信端口
REMOTE_SINGBOX_PORT=9443    # 国内 ECS 上转 VDI sing-box 443 的端口
REMOTE_SSH_PORT=6022        # 国内 ECS 上转 VDI SSH 22 的端口（运维通道）

while [[ $# -gt 0 ]]; do
  case $1 in
    --ecs-ip) ECS_IP="$2"; shift 2 ;;
    --frp-token) FRP_TOKEN="$2"; shift 2 ;;
    --ssh-pubkey) SSH_PUBKEY="$2"; shift 2 ;;
    --frp-bin-url) FRP_BIN_URL="$2"; shift 2 ;;
    --sni) SNI="$2"; shift 2 ;;
    --remote-singbox-port) REMOTE_SINGBOX_PORT="$2"; shift 2 ;;
    --remote-ssh-port) REMOTE_SSH_PORT="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^#//' ; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

[[ -z "$ECS_IP" ]] && { echo "缺 --ecs-ip（国内 ECS 公网 IP，frps 所在）"; exit 1; }
[[ -z "$FRP_TOKEN" ]] && { echo "缺 --frp-token（与 frps 端一致）"; exit 1; }

log() { echo -e "\033[1;36m[BOOTSTRAP]\033[0m $*"; }
ok()  { echo -e "\033[1;32m  ✅\033[0m $*"; }
warn(){ echo -e "\033[1;33m  ⚠️ \033[0m $*"; }

DEPLOY="$SCRIPT_DIR/deploy.sh"
FRP_CLIENT="$SCRIPT_DIR/frp/frp-client.sh"
[[ -f "$DEPLOY" ]] || { echo "找不到 $DEPLOY（放同一目录）"; exit 1; }
[[ -f "$FRP_CLIENT" ]] || { echo "找不到 $FRP_CLIENT（frp/ 子目录）"; exit 1; }

# =============================================================================
log "STEP 1/6: 部署 sing-box（翻墙出口，VLESS-Reality）"
# deploy.sh 幂等（备份旧配置 + 重装 sing-box）。用默认 LISTEN_PORT=443。
if [[ -f "$DEPLOY" ]]; then
  bash "$DEPLOY"
  ok "sing-box 部署完成（443 监听，VLESS-Reality）"
  SB_UUID=$(python3 -c "import json;print(json.load(open('/etc/sing-box/config.json'))['inbounds'][0]['users'][0]['uuid'])" 2>/dev/null || echo "")
  SB_PUB=$(python3 -c "import json;print(json.load(open('/etc/sing-box/config.json'))['inbounds'][0]['tls']['reality']['public_key'] if False else '')" 2>/dev/null)
  SB_PUB=$(grep -oP '"public_key"\s*:\s*"\K[^"]+' /etc/sing-box/config.json 2>/dev/null || echo "")
  SB_SID=$(grep -oP '"short_id"\s*:\s*\[\s*"\K[^"]+' /etc/sing-box/config.json 2>/dev/null || echo "")
  [[ -z "$SB_PUB" ]] && SB_PUB=$(grep -oP 'pbk=\K[^&]+' /etc/sing-box/client-info.txt 2>/dev/null)
  [[ -z "$SB_UUID" ]] && SB_UUID=$(grep -oP 'uuid:\s*\K[a-f0-9-]+' /etc/sing-box/client-info.txt 2>/dev/null || grep -oP '@\K[a-f0-9-]+' /etc/sing-box/client-info.txt 2>/dev/null)
  [[ -z "$SB_SID" ]] && SB_SID=$(grep -oP 'sid=\K[^&]+' /etc/sing-box/client-info.txt 2>/dev/null)
else
  warn "跳过 sing-box 部署（无 deploy.sh）"
fi

# =============================================================================
log "STEP 2/6: 部署 frpc（反向隧道到国内 ECS，映射 443→$REMOTE_SINGBOX_PORT, 22→$REMOTE_SSH_PORT）"
FRPC_ARGS=(--server "$ECS_IP" --port "$FRP_BIND_PORT" --token "$FRP_TOKEN"
  --proxies "name=vdi-singbox,type=tcp,local_ip=127.0.0.1,local_port=443,remote_port=${REMOTE_SINGBOX_PORT};name=ssh,type=tcp,local_ip=127.0.0.1,local_port=22,remote_port=${REMOTE_SSH_PORT}")
[[ -n "$FRP_BIN_URL" ]] && FRPC_ARGS+=(--download-url "$FRP_BIN_URL")
# VDI 上 apt 源常过期，frp 是预编译二进制，默认 skip-apt 更稳
FRPC_ARGS+=(--skip-apt 1)
bash "$FRP_CLIENT" "${FRPC_ARGS[@]}"
ok "frpc 部署完成（443→$REMOTE_SINGBOX_PORT, 22→$REMOTE_SSH_PORT，指向 $ECS_IP）"

# =============================================================================
log "STEP 3/6: 部署 keepalive + policy_fake.xml + bind mount（24h 不睡/不断）"
KEEP_DIR="/home/$(ls /home | head -1)/keep_alive"   # 桌面用户 home；kantaoc 默认
KEEP_USER="$(ls /home | head -1)"
mkdir -p "$KEEP_DIR"
if [[ -f "$SCRIPT_DIR/vdi-keepalive/keepalive.py" ]]; then
  cp -f "$SCRIPT_DIR/vdi-keepalive/keepalive.py" "$KEEP_DIR/keepalive.py"
  cp -f "$SCRIPT_DIR/vdi-keepalive/heal.py" "$KEEP_DIR/heal.py" 2>/dev/null || true
  ok "keepalive.py / heal.py 已复制 → $KEEP_DIR"
else
  warn "未找到 vdi-keepalive/keepalive.py，跳过复制"
fi

# policy_fake.xml：若本机没有且 HDAgent 存在，从现有 policy.xml 生成"关锁屏"版
POLICY_FAKE="$KEEP_DIR/policy_fake.xml"
POLICY_REAL="/etc/hdpserver/policy.xml"
if [ ! -f "$POLICY_FAKE" ] && [ -f "$POLICY_REAL" ]; then
  log "  生成 policy_fake.xml（AutoDisconnect=0/AutoLock=0）"
  cp "$POLICY_REAL" "$POLICY_FAKE"
  sed -i -E 's/<AutoDisconnect>[^<]*<\/AutoDisconnect>/<AutoDisconnect>0<\/AutoDisconnect>/g;
             s/<AutoLock>[^<]*<\/AutoLock>/<AutoLock>0<\/AutoLock>/g' "$POLICY_FAKE"
  chown "$KEEP_USER" "$POLICY_FAKE" 2>/dev/null || true
fi
# 立即挂上
if [ -f "$POLICY_FAKE" ]; then
  mount | grep -q "$POLICY_REAL" || mount --bind "$POLICY_FAKE" "$POLICY_REAL"
  ok "policy bind mount 已生效（重启后由 heal.py 自动重挂，或用 vdi-hdc-repair.sh）"
fi

# keepalive systemd user 服务（vdi-keepalive）
if [ -f "$KEEP_DIR/keepalive.py" ]; then
  UCONF="/home/$KEEP_USER/.config/systemd/user/vdi-keepalive.service"
  mkdir -p "/home/$KEEP_USER/.config/systemd/user"
  cat > "$UCONF" <<EOF
[Unit]
Description=VDI Keepalive (evdev + clipboard + screensaver inhibit)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $KEEP_DIR/keepalive.py
Restart=always
RestartSec=5
Environment=DISPLAY=:0
Environment=XAUTHORITY=/run/user/$(id -u $KEEP_USER)/gdm/Xauthority
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u $KEEP_USER)
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u $KEEP_USER)/bus

[Install]
WantedBy=default.target
EOF
  chown -R "$KEEP_USER" "/home/$KEEP_USER/.config/systemd/user" 2>/dev/null || true
  # 启动（需要图形会话在跑才有 DISPLAY；若没有则记录待登录后自动拉起）
  runuser -u "$KEEP_USER" -- env XDG_RUNTIME_DIR=/run/user/$(id -u $KEEP_USER) \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u $KEEP_USER)/bus \
    systemctl --user enable vdi-keepalive 2>/dev/null || warn "  vdi-keepalive 未能在当前环境 enable（需图形会话在跑，登录后自动生效）"
  runuser -u "$KEEP_USER" -- env XDG_RUNTIME_DIR=/run/user/$(id -u $KEEP_USER) \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u $KEEP_USER)/bus \
    systemctl --user start vdi-keepalive 2>/dev/null || true
  ok "vdi-keepalive user service 已配置（图形会话内运行）"
fi

# VPN 自愈巡检 timer（frpc/sing-box/bind mount 掉了自动拉起，24h 兜底）
if [[ -f "$SCRIPT_DIR/vdi-keepalive/vpn-watchdog.sh" ]]; then
  cp -f "$SCRIPT_DIR/vdi-keepalive/vpn-watchdog.sh" "$KEEP_DIR/vpn-watchdog.sh"
  install -m 755 "$KEEP_DIR/vpn-watchdog.sh" /usr/local/bin/vpn-watchdog.sh 2>/dev/null || true
  install -m 644 "$SCRIPT_DIR/vdi-keepalive/vdi-vpn-watchdog.service" /etc/systemd/system/vdi-vpn-watchdog.service 2>/dev/null || true
  install -m 644 "$SCRIPT_DIR/vdi-keepalive/vdi-vpn-watchdog.timer" /etc/systemd/system/vdi-vpn-watchdog.timer 2>/dev/null || true
  # service 里 ExecStart 指向桌面用户 home，适配实际路径
  sed -i "s|/home/kantaoc/keep_alive|$KEEP_DIR|g" /etc/systemd/system/vdi-vpn-watchdog.service 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null
  systemctl enable --now vdi-vpn-watchdog.timer 2>/dev/null || warn "  vdi-vpn-watchdog timer 未能 enable（稍后手动: systemctl enable --now vdi-vpn-watchdog.timer）"
  ok "vpn-watchdog 巡检 timer 已部署（每 3min 自愈 frpc/sing-box/bind mount）"
fi

# =============================================================================
log "STEP 4/6: 配 root SSH 公钥到 VDI（经 6022 隧道远程运维）"
if [[ -n "$SSH_PUBKEY" ]]; then
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  grep -qF "$SSH_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  ok "root SSH 公钥已写入 /root/.ssh/authorized_keys"
  warn "本地连接: ssh -i <key> -p $REMOTE_SSH_PORT root@$ECS_IP"
else
  warn "未提供 --ssh-pubkey，跳过（之后可手动 append 到 /root/.ssh/authorized_keys）"
fi

# =============================================================================
log "STEP 5/6: 确认 HDP 会话 agent autostart 完好（正规登录时自动起 hdpdaemon20）"
if [ -f /etc/xdg/autostart/hdpdaemon.desktop ]; then
  ok "hdpdaemon.desktop 存在（正规 HDC 登录会自动拉起 hdpdaemon20）"
else
  warn "未找到 /etc/xdg/autostart/hdpdaemon.desktop（这台 VDI 可能不是华为 FusionAccess 桌面，跳过）"
fi

# =============================================================================
log "STEP 6/6: 本地客户端要用的 VLESS 链接（IP = 国内 ECS $ECS_IP:$REMOTE_SINGBOX_PORT）"
echo ""
echo "============================================================"
echo "  🎉 VDI 自举完成。本地 Hiddify/NeoBox 节点用这个链接（IP 是国内 ECS 入口）："
echo ""
if [[ -n "$SB_UUID" && -n "$SB_PUB" && -n "$SB_SID" ]]; then
  echo "  vless://$SB_UUID@$ECS_IP:$REMOTE_SINGBOX_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$SB_PUB&sid=$SB_SID&type=tcp#VDI-出口"
else
  echo "  （sing-box 未部署成功，先跑 deploy.sh，或从 /etc/sing-box/client-info.txt 取 UUID/公钥/ShortID，IP 换成 $ECS_IP:$REMOTE_SINGBOX_PORT）"
fi
echo ""
echo "  验证 VDI 出口:  curl -sv --max-time 8 telnet://$ECS_IP:$REMOTE_SINGBOX_PORT  （通=frps在转发）"
echo "  验证 SSH 通道:  ssh -i <key> -p $REMOTE_SSH_PORT root@$ECS_IP"
echo "  HDP 故障恢复:    sudo bash $SCRIPT_DIR/vdi-hdc-repair.sh --all"
echo "============================================================"
