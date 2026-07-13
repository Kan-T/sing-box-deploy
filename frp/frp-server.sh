#!/usr/bin/env bash
# frp-server.sh - FRP 服务端一键部署/重装脚本
# 适配：1 vCPU / 512MB RAM 小型 ECS (Ubuntu 20.04+/Debian 11+)
# 用法：sudo bash frp-server.sh [--token <token>] [--bind-port <port>] [--dashboard-port <port>] [--dashboard-user <user>] [--dashboard-pwd <pwd>]
# 重复运行会自动清理旧部署并重新安装

set -euo pipefail
trap 'echo "❌ 执行失败，行号: ${LINENO}, 命令: ${BASH_COMMAND}" >&2' ERR

# ============== 配置区（可通过参数覆盖） ==============
FRP_VERSION="0.63.0"
BIN_DIR="/opt/frp"
CONF_DIR="/etc/frp"
BIND_PORT=7000
DASHBOARD_PORT=7500
DASHBOARD_USER="admin"
DASHBOARD_PWD=""
TOKEN=""
# ======================================================

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m $*"; }

# ---- 参数解析 ----
while [[ $# -gt 0 ]]; do
    case $1 in
        --token) TOKEN="$2"; shift 2 ;;
        --bind-port) BIND_PORT="$2"; shift 2 ;;
        --dashboard-port) DASHBOARD_PORT="$2"; shift 2 ;;
        --dashboard-user) DASHBOARD_USER="$2"; shift 2 ;;
        --dashboard-pwd) DASHBOARD_PWD="$2"; shift 2 ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done

# ---- Root 检查 ----
if [[ $(id -u) -ne 0 ]]; then
    err "请使用 sudo 运行: sudo bash $0"
    exit 1
fi

# ---- 生成随机 token（若未提供） ----
if [[ -z "$TOKEN" ]]; then
    TOKEN=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    warn "未指定 token，已自动生成: $TOKEN"
fi

# ---- 生成随机 dashboard 密码（若启用 dashboard 但未提供密码） ----
if [[ -n "$DASHBOARD_PORT" && -z "$DASHBOARD_PWD" ]]; then
    DASHBOARD_PWD=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)
    warn "Dashboard 已启用但未设密码，已自动生成: $DASHBOARD_PWD"
fi

# ========== 清理旧部署 ==========
log "清理旧部署..."
systemctl stop frps 2>/dev/null || true
systemctl disable frps 2>/dev/null || true
rm -f /etc/systemd/system/frps.service
systemctl daemon-reload

# 删除旧二进制目录（软链接指向的版本目录）
if [[ -L "$BIN_DIR" ]]; then
    OLD_TARGET=$(readlink -f "$BIN_DIR" 2>/dev/null || true)
    rm -f "$BIN_DIR"
    if [[ -n "$OLD_TARGET" && -d "$OLD_TARGET" ]]; then
        log "删除旧版本目录: $OLD_TARGET"
        rm -rf "$OLD_TARGET"
    fi
elif [[ -d "$BIN_DIR" ]]; then
    log "删除旧二进制目录: $BIN_DIR"
    rm -rf "$BIN_DIR"
fi

# 清理旧配置目录
if [[ -d "$CONF_DIR" ]]; then
    log "删除旧配置目录: $CONF_DIR"
    rm -rf "$CONF_DIR"
fi

# 清理防火墙旧规则
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw delete allow "$BIND_PORT"/tcp 2>/dev/null || true
    [[ -n "$DASHBOARD_PORT" ]] && ufw delete allow "$DASHBOARD_PORT"/tcp 2>/dev/null || true
fi

# ========== 创建 Swap（512MB 内存必备） ==========
if ! swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/swapfile$'; then
    log "创建 1GB swap 文件..."
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swap 已启用: $(free -h | awk '/Swap:/ {print $2}')"
else
    log "Swap 已存在，跳过创建"
fi

# ========== 安装依赖 ==========
log "安装依赖 (wget, tar, systemd)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y -qq wget tar ca-certificates systemd >/dev/null

# ========== 下载并安装 frp ==========
VERSION_DIR="/opt/frp_${FRP_VERSION}_linux_amd64"
ARCHIVE="frp_${FRP_VERSION}_linux_amd64.tar.gz"
DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${ARCHIVE}"

log "下载 frp v${FRP_VERSION}..."
cd /tmp
wget -q --show-progress "$DOWNLOAD_URL"
tar -zxf "$ARCHIVE"
rm -f "$ARCHIVE"

log "安装二进制到 $VERSION_DIR ..."
mv "frp_${FRP_VERSION}_linux_amd64" "$VERSION_DIR"
ln -sfn "$VERSION_DIR" "$BIN_DIR"

# ========== 生成配置文件（放在 /etc/frp，避免 systemd ProtectSystem 权限问题） ==========
log "生成配置文件到 $CONF_DIR ..."
install -d -m 755 "$CONF_DIR"

cat > "${CONF_DIR}/frps.toml" <<EOF
bindPort = ${BIND_PORT}
auth.token = "${TOKEN}"

# 内存优化：限制连接池和缓冲区
transport.maxPoolCount = 50
transport.heartbeatInterval = 30
transport.heartbeatTimeout = 90

# 日志级别
log.level = "info"
log.maxDays = 3
log.disablePrintColor = true
EOF

# 可选：Dashboard 配置
if [[ -n "$DASHBOARD_PORT" ]]; then
    cat >> "${CONF_DIR}/frps.toml" <<EOF

webServer.addr = "0.0.0.0"
webServer.port = ${DASHBOARD_PORT}
webServer.user = "${DASHBOARD_USER}"
webServer.password = "${DASHBOARD_PWD}"
EOF
    log "Dashboard 已启用: http://<公网IP>:${DASHBOARD_PORT} (用户: ${DASHBOARD_USER})"
fi

chmod 600 "${CONF_DIR}/frps.toml"

# ========== 生成 systemd 服务（内存/CPU 限制） ==========
log "配置 systemd 服务 (内存限制 200M, CPU 80%)..."
cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=FRP Server (frps)
After=network-online.target
Wants=network-online.target
Documentation=https://gofrp.org/

[Service]
Type=simple
# 环境变量优化 Go 运行时内存
Environment=GOGC=20
Environment=GOMEMLIMIT=150MiB
ExecStart=${BIN_DIR}/frps -c ${CONF_DIR}/frps.toml
Restart=always
RestartSec=5
LimitNOFILE=65535
# 资源限制（针对 512MB 内存）
MemoryLimit=200M
MemorySwapMax=300M
CPUQuota=80%
# 安全加固
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${CONF_DIR}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

# ========== 配置防火墙 ==========
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    log "配置 UFW 防火墙..."
    ufw allow "${BIND_PORT}"/tcp comment "frps bind port"
    [[ -n "$DASHBOARD_PORT" ]] && ufw allow "${DASHBOARD_PORT}"/tcp comment "frps dashboard"
fi

# ========== 启动服务 ==========
log "启动 frps 服务..."
systemctl daemon-reload
systemctl enable frps
systemctl start frps

# ========== 健康检查 ==========
sleep 2
if systemctl is-active --quiet frps; then
    log "✅ frps 运行正常"
else
    err "frps 启动失败，查看日志: journalctl -u frps -n 50 --no-pager"
    exit 1
fi

# ========== 输出连接信息 ==========
PUBLIC_IP=$(curl -s --max-time 3 http://checkip.amazonaws.com 2>/dev/null || curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "无法获取")

echo ""
echo "=========================================="
echo "  frps 部署完成！"
echo "=========================================="
echo "  版本:           v${FRP_VERSION}"
echo "  二进制目录:     ${BIN_DIR} -> ${VERSION_DIR}"
echo "  配置目录:       ${CONF_DIR}"
echo "  配置文件:       ${CONF_DIR}/frps.toml"
echo "  绑定端口:       ${BIND_PORT}/TCP"
echo "  Token:          ${TOKEN}"
[[ -n "$DASHBOARD_PORT" ]] && echo "  Dashboard:      http://${PUBLIC_IP}:${DASHBOARD_PORT} (${DASHBOARD_USER} / ${DASHBOARD_PWD})"
echo ""
echo "  客户端配置示例 (frpc.toml):"
echo "  ------------------------------------------"
echo "  serverAddr = \"${PUBLIC_IP}\""
echo "  serverPort = ${BIND_PORT}"
echo "  auth.token = \"${TOKEN}\""
echo ""
echo "  [[proxies]]"
echo "  name = \"ssh\""
echo "  type = \"tcp\""
echo "  localIP = \"127.0.0.1\""
echo "  localPort = 22"
echo "  remotePort = 6000"
echo "  ------------------------------------------"
echo ""
warn "⚠️  重要提醒："
echo "  1. 请在云厂商安全组放行入站: ${BIND_PORT}/TCP ${DASHBOARD_PORT:+${DASHBOARD_PORT}/TCP }"
echo "  2. 请妥善保存 Token: ${TOKEN}"
echo "  3. 查看日志: journalctl -u frps -f"
echo "  4. 重新部署: 直接重新运行本脚本即可"
echo "=========================================="