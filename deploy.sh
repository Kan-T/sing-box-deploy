#!/bin/bash
# =============================================================================
# sing-box VLESS-Reality 一键部署脚本（增强版）
# 适用系统：Ubuntu 20.04/22.04/24.04 (Debian系均可)
# 官方文档：https://sing-box.sagernet.org
# GitHub：https://github.com/SagerNet/sing-box
#
# 说明：
#   - 与现有 Shadowsocks 共存，不冲突
#   - 端口冲突自动检测
#   - 连接信息保存到 /etc/sing-box/client-info.txt
#   - systemd 开机自启
#   - 支持重复运行安全（配置备份、BBR 幂等）
# =============================================================================

# ==================== 【用户可配置参数区】====================
# 请根据需要修改以下参数的值

# 监听端口
LISTEN_PORT=443

# 伪装的目标网站（SNI），流量会伪装成访问该网站
# 推荐值：www.apple.com（推荐）/ www.microsoft.com / www.speedtest.net / dl.google.com
REALITY_SNI="www.apple.com"

# 用户自定义名称（用于客户端识别，随便填）
USER_NAME="sing-box"

# UUID（用户唯一标识）：留空则脚本自动生成
CUSTOM_UUID=""

# 是否开启 BBR 拥塞控制加速（推荐开启）
ENABLE_BBR=true

# 日志级别：debug / info / warn / error / fatal / panic
LOG_LEVEL="warn"

# ==================== 【参数区结束，下方无需修改】====================

# ---------- 辅助函数 ----------
red()   { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }

info()  { echo -e "$(green 'ℹ') $1"; }
ok()    { echo -e "$(green '✅') $1"; }
warn()  { echo -e "$(yellow '⚠') $1"; }
err()   { echo -e "$(red '❌') $1"; }

# 检查上一条命令是否成功
check_cmd() {
    if [ $? -ne 0 ]; then
        err "$1"
        exit 1
    fi
}

# ---------- 前置检查 ----------
# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 用户运行此脚本（或 sudo su 切换）"
    exit 1
fi

# 检查端口是否被占用
check_port() {
    if ss -tlnp | grep -q ":$1 "; then
        local proc=$(ss -tlnp | grep ":$1 " | head -1 | grep -oP 'users:\(\(\K[^)]+')
        err "端口 $1 已被占用（$proc）"
        warn "请修改 LISTEN_PORT 参数为其他端口"
        return 1
    fi
    return 0
}

# 检查系统
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "aarch64" ]; then
    warn "架构 $ARCH 未充分测试，可能不兼容"
fi

echo "============================================================"
echo "  sing-box VLESS-Reality 一键部署脚本"
echo "  官方源：https://sing-box.sagernet.org"
echo "============================================================"
echo ""

# ---------- 0. 清理上一次运行的遗留进程 ----------
echo -e "\n[0/9] 正在清理上一次运行的遗留进程..."
cleanup_previous() {
    # 停止 systemd 服务（若存在且正在运行）
    if systemctl list-unit-files sing-box.service &>/dev/null && systemctl is-active --quiet sing-box 2>/dev/null; then
        systemctl stop sing-box
        info "已停止 systemd 管理的 sing-box 服务"
    fi

    # 兜底：杀死仍在运行的 sing-box 进程，释放监听端口
    if pgrep -x sing-box >/dev/null 2>&1; then
        pkill -x sing-box
        # 等待进程退出并释放端口
        for i in $(seq 1 10); do
            pgrep -x sing-box >/dev/null 2>&1 || break
            sleep 0.5
        done
        if pgrep -x sing-box >/dev/null 2>&1; then
            pkill -9 -x sing-box
        fi
        info "已终止遗留的 sing-box 进程"
    fi

    # 等待端口彻底释放
    for i in $(seq 1 10); do
        ss -tlnp | grep -q ":$LISTEN_PORT " || break
        sleep 0.5
    done
}
cleanup_previous
ok "遗留进程清理完成"

# ---------- 1. 端口冲突检测 ----------
echo -e "\n[2/10] 正在检测端口冲突..."
if ! check_port $LISTEN_PORT; then
    exit 1
fi
ok "端口 $LISTEN_PORT 可用"

# ---------- 2. 低内存环境适配 ----------
echo -e "\n[3/10] 正在检查系统环境..."

# 检查内存并设置 swap（防止 OOM）
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_MEM" -le 1024 ]; then
    warn "内存仅 ${TOTAL_MEM}MB，自动创建 1GB swap 防止 OOM..."
    # 如果已有 swap 且足够大，跳过
    SWAP_TOTAL=$(free -m | awk '/^Swap:/{print $2}')
    if [ "$SWAP_TOTAL" -lt 1024 ]; then
        # 关闭已有 swap
        swapoff -a 2>/dev/null || true
        # 创建 swap 文件（如果不存在）
        if [ ! -f /swapfile ] || [ "$(stat -c%s /swapfile 2>/dev/null)" -lt 1073741824 ]; then
            rm -f /swapfile
            dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
            chmod 600 /swapfile
        fi
        mkswap /swapfile
        swapon /swapfile
        # 写入 fstab 确保开机自启
        grep -q "^/swapfile" /etc/fstab 2>/dev/null || \
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    # 降低 swappiness 减少 swap 滥用
    sysctl vm.swappiness=10
    grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null || \
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    ok "Swap 空间已设置（$(free -m | awk '/^Swap:/{print $2}')MB）"
fi

# 更新软件包索引（不升级，只安装必要工具降低 OOM 风险）
apt update -y
apt install -y curl wget sudo gnupg lsb-release
check_cmd "系统准备失败"
ok "系统环境就绪"

# ---------- 3. 从 sing-box 官方 APT 源安装 ----------
echo -e "\n[4/10] 正在从官方源安装 sing-box..."

# 检查是否已安装
if command -v sing-box &> /dev/null; then
    ok "sing-box 已安装：$(sing-box version | head -n1)"
else
    KEYRINGS_DIR="/etc/apt/keyrings"
    mkdir -p "$KEYRINGS_DIR"

    # 下载官方 GPG 密钥
    curl -fsSL https://sing-box.app/gpg.key -o "$KEYRINGS_DIR/sagernet.asc"
    check_cmd "下载 GPG 密钥失败"
    chmod a+r "$KEYRINGS_DIR/sagernet.asc"

    # 添加官方 APT 源
    echo "Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: $KEYRINGS_DIR/sagernet.asc" | tee /etc/apt/sources.list.d/sagernet.sources > /dev/null

    # 安装 sing-box
    apt-get update
    apt-get install -y sing-box
    check_cmd "sing-box 安装失败"

    ok "sing-box 安装成功：$(sing-box version | head -n1)"
fi

# ---------- 4. 生成加密材料 ----------
echo -e "\n[5/10] 正在生成加密密钥..."

# 生成 UUID
if [ -z "$CUSTOM_UUID" ]; then
    UUID=$(sing-box generate uuid)
else
    UUID="$CUSTOM_UUID"
fi

# 生成 x25519 密钥对
KEYPAIR=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey:" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey:" | awk '{print $2}')

# 生成 short_id
SHORT_ID=$(sing-box generate rand 4 --hex)

# 获取公网 IP
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null || echo "获取失败")
ok "加密材料生成完成"

# ---------- 5. 备份旧配置并写入新配置 ----------
echo -e "\n[6/10] 正在写入配置文件..."

CONFIG_FILE="/etc/sing-box/config.json"

# 如果存在旧配置，备份
if [ -f "$CONFIG_FILE" ]; then
    BACKUP_FILE="/etc/sing-box/config.json.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    ok "旧配置已备份到 $BACKUP_FILE"
fi

cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "level": "$LOG_LEVEL",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "users": [
        {
          "name": "$USER_NAME",
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REALITY_SNI",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

# 检查配置文件语法
sing-box check -c "$CONFIG_FILE"
check_cmd "配置文件语法检查失败"
ok "配置文件写入完成：$CONFIG_FILE"

# ---------- 6. 保存客户端连接信息 ----------
echo -e "\n[7/10] 正在保存连接信息..."

CLIENT_INFO_FILE="/etc/sing-box/client-info.txt"
cat > "$CLIENT_INFO_FILE" << EOF
============================================================
 sing-box VLESS-Reality 连接信息
 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
============================================================

  服务器IP: $SERVER_IP
  端口:     $LISTEN_PORT
  协议:     VLESS-Reality
  UUID:     $UUID
  公钥:     $PUBLIC_KEY
  ShortID:  $SHORT_ID
  SNI:      $REALITY_SNI
  Flow:     xtls-rprx-vision
  指纹(fp): chrome
  加密:     none

  分享链接:
  vless://$UUID@$SERVER_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#$USER_NAME

============================================================
⚠️ 此文件包含敏感信息，请妥善保管！
============================================================
EOF

ok "连接信息已保存到 $CLIENT_INFO_FILE"
chmod 600 "$CLIENT_INFO_FILE"

# ---------- 7. 开启 BBR（可选、幂等）----------
if [ "$ENABLE_BBR" = true ]; then
    echo -e "\n[8/10] 正在开启 BBR 拥塞控制..."

    # 检查当前状态
    CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    CURRENT_QDISC=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')

    if [ "$CURRENT_CC" = "bbr" ] && [ "$CURRENT_QDISC" = "fq" ]; then
        ok "BBR 已处于开启状态（$CURRENT_CC + $CURRENT_QDISC）"
    else
        # 幂等追加：只追加还不在 sysctl.conf 中的行
        grep -q "^net.core.default_qdisc=fq$" /etc/sysctl.conf 2>/dev/null || \
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        grep -q "^net.ipv4.tcp_congestion_control=bbr$" /etc/sysctl.conf 2>/dev/null || \
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        ok "BBR 已开启"
    fi
fi

# ---------- 8. 禁用 IPv6 避免出站超时 ----------
echo -e "\n[9/10] 正在优化网络参数（禁用 IPv6 避免出站超时）..."
if [ -f /etc/sysctl.d/99-singbox.conf ]; then
    ok "IPv6 已禁用"
else
    echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/99-singbox.conf
    sysctl -p /etc/sysctl.d/99-singbox.conf 2>/dev/null || true
    ok "IPv6 已禁用"
fi

# ---------- 9. 启动并设置开机自启 ----------
echo -e "\n[10/10] 正在启动 sing-box 服务..."

# 重载 systemd
systemctl daemon-reload

# 启用开机自启
systemctl enable sing-box
check_cmd "设置开机自启失败"

# 启动服务
systemctl restart sing-box 2>/dev/null || systemctl start sing-box

# 等待一下让服务完全启动
sleep 2

# 检查服务状态
if systemctl is-active --quiet sing-box; then
    ok "sing-box 服务已启动并设置开机自启"
    info "当前运行状态："
    systemctl status sing-box --no-pager -l | head -5
else
    err "sing-box 服务启动失败"
    warn "查看详细日志：journalctl -u sing-box -n 50 --no-pager"
    exit 1
fi

# ---------- 显示结果 ----------
echo ""
echo "============================================================"
green " 🎉 部署完成！"
echo "============================================================"
echo ""
echo "📋 你的 VLESS-Reality 连接信息："
echo ""
echo "  服务器IP: $SERVER_IP"
echo "  端口:     $LISTEN_PORT"
echo "  UUID:     $UUID"
echo "  公钥:     $PUBLIC_KEY"
echo "  ShortID:  $SHORT_ID"
echo "  SNI:      $REALITY_SNI"
echo "  Flow:     xtls-rprx-vision"
echo "  指纹(fp): chrome"
echo ""

VLESS_LINK="vless://$UUID@$SERVER_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#$USER_NAME"

green "🔗 VLESS 分享链接："
echo ""
echo "  $VLESS_LINK"
echo ""

# 复制到剪贴板友好
if command -v clip.exe &>/dev/null; then
    echo -n "$VLESS_LINK" | clip.exe
    info "链接已复制到 Windows 剪贴板"
fi

echo "============================================================"
echo "📂 连接信息已保存到：/etc/sing-box/client-info.txt"
echo "📋 查看方式：cat /etc/sing-box/client-info.txt"
echo ""
info "⚠️ 阿里云 ECS 需在控制台【安全组】放行 $LISTEN_PORT 端口（TCP）"
info "📝 查看日志：journalctl -u sing-box -f"
info "🔄 重启服务：systemctl restart sing-box"
info "🛑 停止服务：systemctl stop sing-box"
info "❌ 完全卸载：systemctl disable --now sing-box && apt remove -y sing-box"
echo ""
info "现有 Shadowsocks 服务不受影响（端口 443）"
echo "============================================================"
