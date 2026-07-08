#!/bin/bash
# =============================================================================
# sing-box VLESS-Reality 一键部署脚本（修正版）
# 适用系统：Ubuntu 20.04/22.04/24.04 (Debian系均可)
# 官方文档：https://sing-box.sagernet.org
# GitHub：https://github.com/SagerNet/sing-box
# =============================================================================

# ==================== 【用户可配置参数区】====================
# 请根据需要修改以下参数的值

# 监听端口（建议443，伪装成HTTPS流量；如果被占用可改为其他如8443）
LISTEN_PORT=443

# 伪装的目标网站（SNI），流量会伪装成访问该网站
# 推荐值：www.microsoft.com / www.apple.com / www.speedtest.net / dl.google.com
# 注意：不要使用国内网站，也不要使用你自己的域名
REALITY_SNI="www.microsoft.com"

# 用户自定义名称（用于客户端识别，随便填）
USER_NAME="my-vless-user"

# UUID（用户唯一标识）：留空则脚本自动生成，也可以手动指定一个
# 格式如：11391936-7544-4af5-ad02-e9f3970b1f64
CUSTOM_UUID=""

# 是否开启 BBR 拥塞控制加速（推荐开启，对VPS网络提速明显）
ENABLE_BBR=true

# 日志级别：debug / info / warn / error / fatal / panic
LOG_LEVEL="warn"

# ==================== 【参数区结束，下方无需修改】====================

set -e  # 遇到错误立即退出

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 错误：请使用 root 用户运行此脚本（或 sudo su 切换）"
    exit 1
fi

echo "============================================================"
echo "  sing-box VLESS-Reality 一键部署脚本"
echo "  官方源：https://sing-box.sagernet.org"
echo "============================================================"

# ---------- 1. 系统更新 ----------
echo -e "\n[1/6] 正在更新系统软件包..."
apt update -y
apt upgrade -y
apt install -y curl wget sudo gnupg lsb-release

# ---------- 2. 从 sing-box 官方 APT 源安装 ----------
echo -e "\n[2/6] 正在从官方源安装 sing-box..."
KEYRINGS_DIR="/etc/apt/keyrings"
mkdir -p "$KEYRINGS_DIR"

# 下载官方 GPG 密钥
curl -fsSL https://sing-box.app/gpg.key -o "$KEYRINGS_DIR/sagernet.asc"
chmod a+r "$KEYRINGS_DIR/sagernet.asc"

# 添加官方 APT 源（使用新的 .sources 格式，官方推荐）
echo "Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: $KEYRINGS_DIR/sagernet.asc" | tee /etc/apt/sources.list.d/sagernet.sources > /dev/null

# 安装 sing-box
apt-get update
apt-get install -y sing-box

# 验证安装
if ! command -v sing-box &> /dev/null; then
    echo "❌ 错误：sing-box 安装失败"
    exit 1
fi
echo "✅ sing-box 安装成功：$(sing-box version | head -n1)"

# ---------- 3. 生成加密材料 ----------
echo -e "\n[3/6] 正在生成加密密钥..."

# 生成 UUID
if [ -z "$CUSTOM_UUID" ]; then
    UUID=$(sing-box generate uuid)
else
    UUID="$CUSTOM_UUID"
fi

# 生成 x25519 密钥对（REALITY 专用）
KEYPAIR=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey:" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey:" | awk '{print $2}')

# 生成 short_id（8位十六进制）
SHORT_ID=$(sing-box generate rand8 --hex)

echo "✅ 加密材料生成完成"

# ---------- 4. 写入配置文件 ----------
echo -e "\n[4/6] 正在写入配置文件..."

CONFIG_FILE="/etc/sing-box/config.json"

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
if ! sing-box check -c "$CONFIG_FILE"; then
    echo "❌ 错误：配置文件语法检查失败"
    exit 1
fi
echo "✅ 配置文件写入完成：$CONFIG_FILE"

# ---------- 5. 开启 BBR（可选）----------
if [ "$ENABLE_BBR" = true ]; then
    echo -e "\n[5/6] 正在开启 BBR 拥塞控制..."
    # 检查是否已开启
    BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [ "$BBR_STATUS" != "bbr" ]; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo "✅ BBR 已开启"
    else
        echo "✅ BBR 已处于开启状态"
    fi
fi

# ---------- 6. 启动并设置开机自启 ----------
echo -e "\n[6/6] 正在启动 sing-box 服务..."

# 重载 systemd
systemctl daemon-reload

# 启用并启动服务
systemctl enable sing-box
systemctl start sing-box

# 检查服务状态
if systemctl is-active --quiet sing-box; then
    echo "✅ sing-box 服务已启动并设置开机自启"
else
    echo "❌ 错误：sing-box 服务启动失败"
    exit 1
fi

# ---------- 输出连接信息 ----------
echo -e "\n============================================================"
echo " 🎉 部署完成！"
echo "============================================================"
echo ""
echo "📋 你的 VLESS-Reality 连接信息如下："
echo ""
echo "  服务器IP: $(curl -s ifconfig.me)"
echo "  端口:     $LISTEN_PORT"
echo "  UUID:     $UUID"
echo "  公钥:     $PUBLIC_KEY"
echo "  ShortID:  $SHORT_ID"
echo "  SNI:      $REALITY_SNI"
echo "  Flow:     xtls-rprx-vision"
echo "  指纹(fp): chrome"
echo ""

# 生成 vless:// 分享链接（已修正：加入 fp=chrome 参数）
SERVER_IP=$(curl -s ifconfig.me)
VLESS_LINK="vless://$UUID@$SERVER_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#$USER_NAME"

echo "🔗 VLESS 分享链接（可复制到客户端导入）："
echo ""
echo "  $VLESS_LINK"
echo ""
echo "============================================================"
echo "💡 客户端推荐："
echo "   Windows: v2rayN (GitHub: 2dust/v2rayN)"
echo "   macOS:   Hiddify / FoXray"
echo "   Android: v2rayNG / Hiddify"
echo "   iOS:     Shadowrocket / FoXray"
echo ""
echo "⚠️ 注意事项："
echo "   1. 阿里云 ECS 需在控制台【安全组】放行 $LISTEN_PORT 端口（TCP）"
echo "   2. 如访问不流畅，尝试更换 SNI 为 www.apple.com 或 dl.google.com"
echo "   3. 查看日志：journalctl -u sing-box -f"
echo "   4. 重启服务：systemctl restart sing-box"
echo "============================================================"
