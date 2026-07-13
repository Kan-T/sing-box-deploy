#!/usr/bin/env bash
# uninstall-frps.sh - 彻底卸载 frps 服务端
# 用法：sudo bash uninstall-frps.sh

set -euo pipefail

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }

if [[ $(id -u) -ne 0 ]]; then
    echo "❌ 请使用 sudo 运行: sudo bash $0"
    exit 1
fi

log "开始卸载 frps..."

# 1. 停止并禁用服务
if systemctl is-active --quiet frps 2>/dev/null; then
    log "停止 frps 服务..."
    systemctl stop frps
fi
if systemctl is-enabled --quiet frps 2>/dev/null; then
    log "禁用 frps 开机自启..."
    systemctl disable frps
fi

# 2. 删除 systemd 单元文件
UNIT_FILE="/etc/systemd/system/frps.service"
if [[ -f "$UNIT_FILE" ]]; then
    log "删除 systemd 单元文件: $UNIT_FILE"
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
fi

# 3. 删除二进制目录（软链接指向的版本目录）
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

# 5. 清理防火墙规则（UFW）
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    if ufw status numbered | grep -qE "7000|6000|7500"; then
        log "清理 UFW 端口规则 (7000/tcp, 6000/tcp, 7500/tcp)..."
        ufw delete allow 7000/tcp 2>/dev/null || true
        ufw delete allow 6000/tcp 2>/dev/null || true
        ufw delete allow 7500/tcp 2>/dev/null || true
    fi
fi

# 6. 清理 iptables 规则
for port in 7000 6000 7500; do
    if iptables -L INPUT -n 2>/dev/null | grep -q "dpt:$port"; then
        log "清理 iptables INPUT 链端口 $port 规则..."
        while iptables -L INPUT -n --line-numbers 2>/dev/null | grep -q "dpt:$port"; do
            LINE=$(iptables -L INPUT -n --line-numbers 2>/dev/null | grep "dpt:$port" | head -1 | awk '{print $1}')
            iptables -D INPUT "$LINE" 2>/dev/null || break
        done
    fi
done

# 7. 清理持久化 iptables 规则文件
for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    if [[ -f "$f" ]] && grep -qE "dpt:(7000|6000|7500)" "$f"; then
        log "从 $f 移除端口规则..."
        sed -i -E '/dpt:(7000|6000|7500)/d' "$f"
    fi
done

echo ""
log "✅ frps 卸载完成"
echo "=========================================="
echo "  已清理："
echo "  - systemd 服务 (frps)"
echo "  - 二进制目录 (/opt/frp, /opt/frp_*)"
echo "  - 配置目录 (/etc/frp)"
echo "  - 防火墙规则 (UFW/iptables 端口 7000, 6000, 7500)"
echo "=========================================="
warn "⚠️  请手动前往云厂商控制台删除安全组入站规则："
warn "    TCP 7000 (frp 通信端口)"
warn "    TCP 6000 (frp HTTP 代理端口，如已配置)"
warn "    TCP 7500 (Dashboard 端口，如已启用)"