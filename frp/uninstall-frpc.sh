#!/usr/bin/env bash
# uninstall-frpc.sh - 彻底卸载 frpc 客户端
# 用法：sudo bash uninstall-frpc.sh

set -euo pipefail

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }

if [[ $(id -u) -ne 0 ]]; then
    echo "❌ 请使用 sudo 运行: sudo bash $0"
    exit 1
fi

log "开始卸载 frpc..."

# 1. 停止并禁用服务
if systemctl is-active --quiet frpc 2>/dev/null; then
    log "停止 frpc 服务..."
    systemctl stop frpc
fi
if systemctl is-enabled --quiet frpc 2>/dev/null; then
    log "禁用 frpc 开机自启..."
    systemctl disable frpc
fi

# 2. 删除 systemd 单元文件
UNIT_FILE="/etc/systemd/system/frpc.service"
if [[ -f "$UNIT_FILE" ]]; then
    log "删除 systemd 单元文件: $UNIT_FILE"
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
fi

# 3. 删除二进制目录
LINK_DIR="/opt/frp"
if [[ -L "$LINK_DIR" ]]; then
    TARGET=$(readlink -f "$LINK_DIR" 2>/dev/null || true)
    log "删除软链接: $LINK_DIR"
    rm -f "$LINK_DIR"
    if [[ -n "$TARGET" && -d "$TARGET" ]]; then
        log "删除版本目录: $TARGET"
        rm -rf "$TARGET"
    fi
elif [[ -d "$LINK_DIR" ]]; then
    log "删除目录: $LINK_DIR"
    rm -rf "$LINK_DIR"
fi

# 清理所有 frp_* 版本目录
for dir in /opt/frp_*; do
    [[ -d "$dir" ]] && { log "清理残留目录: $dir"; rm -rf "$dir"; }
done

# 4. 删除配置目录
CONF_DIR="/etc/frp"
if [[ -d "$CONF_DIR" ]]; then
    log "删除配置目录: $CONF_DIR"
    rm -rf "$CONF_DIR"
fi

echo ""
log "✅ frpc 卸载完成"
echo "=========================================="
echo "  已清理："
echo "  - systemd 服务 (frpc)"
echo "  - 二进制目录 (/opt/frp, /opt/frp_*)"
echo "  - 配置目录 (/etc/frp)"
echo "=========================================="