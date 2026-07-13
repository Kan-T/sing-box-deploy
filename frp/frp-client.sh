#!/usr/bin/env bash
# frp-client.sh - FRP 客户端一键部署/重装脚本
# 适配：华为云 VDI / 任意 Linux 客户端 (Ubuntu 20.04+/Debian 11+/CentOS 7+)
# 用法：
#   交互式：sudo bash frp-client.sh
#   参数化：sudo bash frp-client.sh --server <IP> --token <TOKEN> --proxies 'name=ssh,type=tcp,local_port=22,remote_port=6000;name=web,type=tcp,local_port=80,remote_port=8080'
#   环境变量：SERVER_ADDR, TOKEN, PROXIES (同上格式)
# 重复运行会自动清理旧部署并重新安装

set -euo pipefail
trap 'echo "❌ 执行失败，行号: ${LINENO}, 命令: ${BASH_COMMAND}" >&2' ERR

# ============== 默认配置（可被参数/环境变量覆盖） ==============
FRP_VERSION="0.63.0"
BIN_DIR="/opt/frp"
CONF_DIR="/etc/frp"
SERVER_ADDR="${SERVER_ADDR:-}"
SERVER_PORT="${SERVER_PORT:-7000}"
TOKEN="${TOKEN:-}"
# PROXIES 格式: name=ssh,type=tcp,local_ip=127.0.0.1,local_port=22,remote_port=6000;name=web,type=tcp,local_port=80,remote_port=8080
PROXIES="${PROXIES:-}"
# ===============================================================

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR]\033[0m $*"; }

# ---- 参数解析 ----
while [[ $# -gt 0 ]]; do
    case $1 in
        --server) SERVER_ADDR="$2"; shift 2 ;;
        --port) SERVER_PORT="$2"; shift 2 ;;
        --token) TOKEN="$2"; shift 2 ;;
        --proxies) PROXIES="$2"; shift 2 ;;
        *) err "未知参数: $1"; exit 1 ;;
    esac
done

# ---- Root 检查 ----
if [[ $(id -u) -ne 0 ]]; then
    err "请使用 sudo 运行: sudo bash $0 ..."
    exit 1
fi

# ---- 交互式输入（若未提供参数/环境变量） ----
if [[ -z "$SERVER_ADDR" ]]; then
    read -rp "请输入 frps 服务端公网 IP: " SERVER_ADDR
    [[ -z "$SERVER_ADDR" ]] && { err "服务端 IP 不能为空"; exit 1; }
fi

if [[ -z "$TOKEN" ]]; then
    read -rp "请输入 frps Token (留空将尝试从服务端获取/跳过): " TOKEN
fi

if [[ -z "$PROXIES" ]]; then
    echo "配置代理规则 (格式: name=xxx,type=tcp,local_ip=127.0.0.1,local_port=xxx,remote_port=xxx)"
    echo "多条规则用分号 ; 分隔，留空则进入交互式逐条录入"
    read -rp "代理规则: " PROXIES
fi

# ========== 解析 PROXIES 字符串为数组 ==========
declare -a PROXY_CONFIGS
if [[ -n "$PROXIES" ]]; then
    IFS=';' read -ra RAW_PROXIES <<< "$PROXIES"
    for raw in "${RAW_PROXIES[@]}"; do
        [[ -z "$raw" ]] && continue
        # 解析 key=value 对
        declare -A cfg
        cfg[name]=""
        cfg[type]="tcp"
        cfg[local_ip]="127.0.0.1"
        cfg[local_port]=""
        cfg[remote_port]=""
        IFS=',' read -ra KV_PAIRS <<< "$raw"
        for kv in "${KV_PAIRS[@]}"; do
            key=${kv%%=*}
            val=${kv#*=}
            cfg["$key"]="$val"
        done
        # 验证必填字段
        [[ -z "${cfg[name]}" ]] && { err "代理规则缺少 name: $raw"; exit 1; }
        [[ -z "${cfg[local_port]}" ]] && { err "代理规则缺少 local_port: $raw"; exit 1; }
        [[ -z "${cfg[remote_port]}" ]] && { err "代理规则缺少 remote_port: $raw"; exit 1; }
        PROXY_CONFIGS+=("${cfg[name]}|${cfg[type]}|${cfg[local_ip]}|${cfg[local_port]}|${cfg[remote_port]}")
    done
fi

# 若仍为空，进入交互式逐条录入
if [[ ${#PROXY_CONFIGS[@]} -eq 0 ]]; then
    log "进入交互式代理配置模式 (输入空 name 结束)"
    while true; do
        read -rp "  代理名称 (如 ssh/web): " p_name
        [[ -z "$p_name" ]] && break
        read -rp "  协议类型 [tcp/udp] (默认 tcp): " p_type; p_type=${p_type:-tcp}
        read -rp "  本地 IP (默认 127.0.0.1): " p_local_ip; p_local_ip=${p_local_ip:-127.0.0.1}
        read -rp "  本地端口: " p_local_port
        read -rp "  远程端口 (frps 端口): " p_remote_port
        [[ -z "$p_local_port" || -z "$p_remote_port" ]] && { warn "端口不能为空，跳过"; continue; }
        PROXY_CONFIGS+=("$p_name|$p_type|$p_local_ip|$p_local_port|$p_remote_port")
    done
fi

[[ ${#PROXY_CONFIGS[@]} -eq 0 ]] && { err "至少需要一条代理规则"; exit 1; }

# ========== 清理旧部署 ==========
log "清理旧部署..."
systemctl stop frpc 2>/dev/null || true
systemctl disable frpc 2>/dev/null || true
rm -f /etc/systemd/system/frpc.service
systemctl daemon-reload

# 删除旧二进制目录（软链接指向的版本目录）
if [[ -L "$BIN_DIR" ]]; then
    OLD_TARGET=$(readlink -f "$BIN_DIR" 2>/dev/null || true)
    rm -f "$BIN_DIR"
    [[ -n "$OLD_TARGET" && -d "$OLD_TARGET" ]] && rm -rf "$OLD_TARGET"
elif [[ -d "$BIN_DIR" ]]; then
    rm -rf "$BIN_DIR"
fi

# 删除旧配置目录
if [[ -d "$CONF_DIR" ]]; then
    log "删除旧配置目录: $CONF_DIR"
    rm -rf "$CONF_DIR"
fi

# ========== 安装依赖 ==========
log "安装依赖..."
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -qq
    apt-get install -y -qq wget tar ca-certificates systemd >/dev/null
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q wget tar ca-certificates systemd >/dev/null
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q wget tar ca-certificates systemd >/dev/null
else
    err "不支持的包管理器，请手动安装 wget tar systemd"
    exit 1
fi

# ========== 下载并安装 frp ==========
VERSION_DIR="/opt/frp_${FRP_VERSION}_linux_amd64"
ARCHIVE="frp_${FRP_VERSION}_linux_amd64.tar.gz"
DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${ARCHIVE}"

log "下载 frp v${FRP_VERSION}..."
cd /tmp
wget -q --show-progress "$DOWNLOAD_URL"
tar -zxf "$ARCHIVE"
rm -f "$ARCHIVE"

log "安装到 $VERSION_DIR ..."
mv "frp_${FRP_VERSION}_linux_amd64" "$VERSION_DIR"
ln -sfn "$VERSION_DIR" "$BIN_DIR"

# ========== 创建配置目录 ==========
log "创建配置目录: $CONF_DIR"
install -d -m 755 "$CONF_DIR"

# ========== 生成 frpc.toml 配置 ==========
log "生成 frpc.toml 配置..."
cat > "${CONF_DIR}/frpc.toml" <<EOF
serverAddr = "${SERVER_ADDR}"
serverPort = ${SERVER_PORT}
auth.token = "${TOKEN}"

# 连接池与心跳优化（适配弱网/长连接）
transport.poolCount = 5
transport.heartbeatInterval = 30
transport.heartbeatTimeout = 90
transport.dialServerTimeout = 10

# 日志
log.level = "info"
log.maxDays = 3
log.disablePrintColor = true

EOF

# 追加代理配置
for cfg in "${PROXY_CONFIGS[@]}"; do
    IFS='|' read -r p_name p_type p_local_ip p_local_port p_remote_port <<< "$cfg"
    cat >> "${CONF_DIR}/frpc.toml" <<EOF
[[proxies]]
name = "${p_name}"
type = "${p_type}"
localIP = "${p_local_ip}"
localPort = ${p_local_port}
remotePort = ${p_remote_port}
EOF
    [[ "$p_type" == "udp" ]] && echo 'transport.maxPoolCount = 1' >> "${CONF_DIR}/frpc.toml"
done

chmod 600 "${CONF_DIR}/frpc.toml"

# ========== 生成 systemd 服务（资源限制） ==========
log "配置 systemd 服务 (内存限制 100M, CPU 50%)..."
cat > /etc/systemd/system/frpc.service <<EOF
[Unit]
Description=FRP Client (frpc)
After=network-online.target
Wants=network-online.target
Documentation=https://gofrp.org/

[Service]
Type=simple
Environment=GOGC=30
Environment=GOMEMLIMIT=80MiB
ExecStart=${BIN_DIR}/frpc -c ${CONF_DIR}/frpc.toml
Restart=always
RestartSec=5
LimitNOFILE=65535
# 资源限制（客户端通常更轻量）
MemoryLimit=100M
MemorySwapMax=150M
CPUQuota=50%
# 安全加固
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${CONF_DIR}

[Install]
WantedBy=multi-user.target
EOF

# ========== 启动服务 ==========
log "启动 frpc 服务..."
systemctl daemon-reload
systemctl enable frpc
systemctl start frpc

# ========== 健康检查 ==========
sleep 2
if systemctl is-active --quiet frpc; then
    log "✅ frpc 运行正常"
else
    err "frpc 启动失败，查看日志: journalctl -u frpc -n 50 --no-pager"
    exit 1
fi

# ========== 输出摘要 ==========
echo ""
echo "=========================================="
echo "  frpc 部署完成！"
echo "=========================================="
echo "  版本:           v${FRP_VERSION}"
echo "  二进制目录:     ${BIN_DIR} -> ${VERSION_DIR}"
echo "  配置目录:       ${CONF_DIR}"
echo "  配置文件:       ${CONF_DIR}/frpc.toml"
echo "  服务端:         ${SERVER_ADDR}:${SERVER_PORT}"
echo "  Token:          ${TOKEN:-<未设置>}"
echo ""
echo "  代理规则:"
for cfg in "${PROXY_CONFIGS[@]}"; do
    IFS='|' read -r p_name p_type p_local_ip p_local_port p_remote_port <<< "$cfg"
    printf "    - %-10s %s://%s:%d -> %s:%d\n" "$p_name" "$p_type" "$p_local_ip" "$p_local_port" "$SERVER_ADDR" "$p_remote_port"
done
echo ""
echo "  常用命令:"
echo "    查看状态:  systemctl status frpc"
echo "    查看日志:  journalctl -u frpc -f"
echo "    重启:      systemctl restart frpc"
echo "    重新部署:  直接重新运行本脚本"
echo "=========================================="