# sing-box VLESS-Reality 部署指南

在阿里云 ECS（东京）上部署 sing-box VLESS-Reality 代理，与现有 Shadowsocks 共存的完整方案。

## 目录

- [项目说明](#项目说明)
- [架构总览](#架构总览)
- [服务器端部署](#服务器端部署)
- [本地客户端配置](#本地客户端配置)
  - [方案 A：Hiddify（推荐）](#方案-ahiddify推荐)
  - [方案 B：sing-box 命令行模式](#方案-bsing-box-命令行模式)
- [端口对照表](#端口对照表)
- [维护管理](#维护管理)
- [排错指南](#排错指南)

---

## 项目说明

| 项目 | 值 |
|------|-----|
| 服务器 | 阿里云 ECS 东京 (8.216.46.75) |
| 系统 | Ubuntu 22.04 (512MB RAM) |
| 代理协议 | VLESS-Reality |
| 底层软件 | [sing-box](https://sing-box.sagernet.org) v1.13+ |
| 共存服务 | Shadowsocks (端口 443) |
| 本地客户端 | Hiddify / sing-box 命令行 |

**关键端口：**

| 服务 | 端口 | 说明 |
|------|------|------|
| Shadowsocks | **443** | 现有服务，不受影响 |
| sing-box 服务端 | **8443** | VLESS-Reality 入站 |
| HTTP 代理（本地） | **7890** | 第三方软件接入端 |
| SOCKS5 代理（本地） | **7890** | 与 HTTP 同居 mixed 端口 |

---

## 架构总览

```
┌──────────────────┐     VLESS-Reality      ┌─────────────────┐
│  本地客户端       │ ──────────────────▶    │ 东京 ECS        │
│  (Hiddify /      │    8.216.46.75:8443    │ sing-box 服务端  │
│   sing-box)      │ ◀──────────────────    │ Shadowsocks:443 │
│                  │     Reality 加密       │ (共存)           │
│  本:7890 HTTP    │                        └─────────────────┘
│  本:7890 SOCKS5  │
└──────┬───────────┘
       │
       │ 127.0.0.1:7890
       ▼
┌──────────────────┐
│ 第三方软件        │
│ 浏览器 / curl    │
│ 其他应用         │
└──────────────────┘
```

---

## 服务器端部署

### 一键部署（推荐）

在 ECS 服务器上以 root 运行：

```bash
bash <(curl -sL https://raw.githubusercontent.com/你的仓库/sing-box-deploy/main/deploy.sh)
```

或上传 `deploy.sh` 到服务器后运行：

```bash
chmod +x deploy.sh
./deploy.sh
```

### 手动部署

也可依次执行以下步骤：

#### 1. 安装 sing-box

```bash
# 添加官方源
curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
chmod a+r /etc/apt/keyrings/sagernet.asc
echo "Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc" > /etc/apt/sources.list.d/sagernet.sources

apt update && apt install -y sing-box
```

#### 2. 生成密钥材料

```bash
# UUID
UUID=$(sing-box generate uuid)

# x25519 密钥对
KEYPAIR=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey:" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey:" | awk '{print $2}')

# Short ID
SHORT_ID=$(sing-box generate rand 4 --hex)
```

#### 3. 编写配置文件

创建 `/etc/sing-box/config.json`：

```json
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 8443,
      "users": [
        {
          "name": "my-vless-user",
          "uuid": "<你的 UUID>",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.apple.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.apple.com",
            "server_port": 443
          },
          "private_key": "<你的 PRIVATE_KEY>",
          "short_id": ["<你的 ShortID>"]
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
```

#### 4. 验证配置文件

```bash
sing-box check -c /etc/sing-box/config.json
```

#### 5. 启用并启动服务

```bash
systemctl enable sing-box
systemctl restart sing-box
```

#### 6. 验证运行状态

```bash
systemctl status sing-box
journalctl -u sing-box -n 20 --no-pager
```

如看到 `REALITY: processed invalid connection` 但后续有正常流量，属于正常现象（Reality 协议探测机制）。

#### 7. 关闭 IPv6（必需）

```bash
echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/99-net-ipv6.conf
sysctl -p /etc/sysctl.d/99-net-ipv6.conf
```

> **为什么必须关闭：** 512MB 低配 ECS 的 IPv6 出站路由不稳，不关闭会导致 `dial tcp i/o timeout`。

#### 8. 开启 BBR（可选但推荐）

```bash
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
```

#### 9. 安全组放行

在阿里云 ECS 控制台 → **安全组** → 添加入方向规则：

| 规则 | 值 |
|------|-----|
| 协议 | TCP |
| 端口 | 8443 |
| 源 | 0.0.0.0/0 |
| 描述 | sing-box VLESS-Reality |

#### 10. 查看连接信息

```bash
cat /etc/sing-box/client-info.txt
```

记录输出的 VLESS 链接，后续配置客户端要用。

---

## 本地客户端配置

### 方案 A：Hiddify（推荐）

[Hiddify](https://github.com/hiddify/hiddify-next) 是基于 sing-box 的多平台代理客户端，有 GUI 开关，支持协议全面。

#### 安装

从 [GitHub Releases](https://github.com/hiddify/hiddify-next/releases) 下载 Windows 版安装包或便携版。

#### 导入节点

1. 运行 Hiddify
2. 点击 **+ 添加** → 选择 **从剪贴板导入**
3. 粘贴从服务器获取的 VLESS 链接：

```
vless://61c70a84-facf-43f8-85c6-82096a7f5d60@8.216.46.75:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=d0uUSr8zfuIZbANQGQc8UQikMN784lVglPyHeemuuwY&sid=c13a907a&type=tcp#Tokyo-singbox
```

#### 配置端口

Hiddify 默认使用端口 **12334**，建议改为 **7890** 以适配已有软件配置。

**修改方法**（需退出 Hiddify 后再改）：

1. 完全退出 Hiddify（系统托盘右键 → 退出）
2. 打开 `D:\Programs\Hiddify\hiddify_portable_data\data\current-config.json`
3. 将所有 `"listen_port": 12334` 改为 `"listen_port": 7890`
4. 重新启动 Hiddify

> ⚠️ Hiddify 可能启动时会覆盖配置文件，如不生效需在 UI 设置中确认是否有端口配置项。

#### 模式选择

Hiddify 有三种运行模式（在下拉菜单切换）：

| 模式 | 作用 | 配置端口 | 用途 |
|------|------|----------|------|
| **服务模式**（代理） | 仅开端口，不修改系统设置 | 第三方软件手动连接 | 推荐，可控性高 |
| **系统代理** | 开端口 + 自动修改系统代理 | Chrome 等自动走代理 | 方便但不够灵活 |
| **VPN**（TUN） | 虚拟网卡接管所有流量 | 全部流量走代理 | 最彻底，可能影响国内访问 |

**建议使用「服务模式」**，第三方软件连接 `127.0.0.1:7890` 即可。

#### 开机自启

Hiddify 设置中将 **动作在关闭时** 设为 `隐藏到系统托盘`，再创建快捷方式到 Windows 启动目录：

```
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup
```

#### 验证代理工作

```bash
curl -x http://127.0.0.1:7890 -sS --max-time 10 https://google.com -o /dev/null -w "%{http_code}"
# 返回 200 表示正常
```

---

### 方案 B：sing-box 命令行模式

如果你不想用 Hiddify，可以手动运行 sing-box 客户端。优点是配置完全自主。

#### 1. 下载 sing-box

从 [sing-box Releases](https://github.com/SagerNet/sing-box/releases) 下载 Windows 版。

使用 sing-box 1.13+ 版本（与服务器版本匹配最佳）。

#### 2. 创建客户端配置

创建 `config.json`（放到 sing-box 目录下的 `myconf/` 子目录）：

```json
{
  "log": {
    "level": "info",
    "output": "logs/box.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 7890
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "8.216.46.75",
      "server_port": 8443,
      "uuid": "61c70a84-facf-43f8-85c6-82096a7f5d60",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "www.apple.com",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "d0uUSr8zfuIZbANQGQc8UQikMN784lVglPyHeemuuwY",
          "short_id": "c13a907a"
        }
      },
      "packet_encoding": "xudp"
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "domain_suffix": [".cn"],
        "outbound": "direct"
      }
    ],
    "final": "proxy"
  }
}
```

#### 3. 启动 sing-box

```bash
cd D:\Programs\sing-box-windows-64
sing-box run -c myconf\config.json
```

#### 4. 快捷开关脚本

**启动代理**（`开启代理.bat`）：

```batch
@echo off
cd /d "D:\Programs\sing-box-windows-64"
start /B sing-box.exe run -c myconf\config.json > logs\box.log 2>&1
echo 代理已启动
```

**关闭代理**（`关闭代理.bat`）：

```batch
@echo off
taskkill /IM sing-box.exe /F /T 2>nul
echo 代理已关闭
```

---

## 端口对照表

### 服务端端口

| 端口 | 服务 | 说明 |
|------|------|------|
| 443 | Shadowsocks | 现有服务，sing-box 不占此端口 |
| **8443** | sing-box VLESS-Reality | 主入站端口，安全组需放行 |
| 22 | SSH | 远程管理 |

### 本地端口

| 端口 | 协议 | 说明 |
|------|------|------|
| **7890** | HTTP/SOCKS5（mixed） | 第三方软件连接此端口 |
| 12334 | HTTP/SOCKS5（Hiddify 默认） | Hiddify 未改端口时使用 |
| 12337 | DNS（Hiddify） | 内部 DNS 代理 |
| 16756 | Clash API（Hiddify） | 内部管理接口 |
| 17078 | TUN（Hiddify） | VPN 模式使用 |
| 10808 | SOCKS5（v2rayN 默认） | v2rayN 用户的备用方案 |

### 验证端口是否正在监听

```bash
# 查看所有本地代理端口
netstat -ano | findstr "LISTEN" | findstr "7890 12334 10808"

# 查看具体端口属于哪个进程
netstat -ano | findstr ":7890 "
```

---

## 维护管理

### 服务器端维护

```bash
# 状态检查
systemctl status sing-box
ss -tlnp | grep 8443

# 查看实时日志
journalctl -u sing-box -f

# 重启服务
systemctl restart sing-box

# 停止服务
systemctl stop sing-box

# 完全卸载
systemctl disable --now sing-box
apt remove -y sing-box
```

### 重新部署

脚本支持重复运行，会自动清理上一次运行遗留的 sing-box 进程（停止 systemd 服务并终止残留进程，释放监听端口），无需手动停止服务即可重跑：

```bash
# 修改 deploy.sh 中的参数后重新运行
./deploy.sh
```

旧配置会自动备份到 `/etc/sing-box/config.json.backup.时间戳`。

### 更新 sing-box

```bash
apt update && apt upgrade -y sing-box
systemctl restart sing-box
```

---

## 排错指南

### 1. 服务端连接超时

```
dial tcp 8.216.46.75:8443: i/o timeout
```

**排查：**
- 阿里云安全组是否放行了 8443 端口？
- 服务器 sing-box 是否在运行？`systemctl status sing-box`
- 防火墙是否拦截？`ufw status`

### 2. Reality 握手失败

```
REALITY: received real certificate
```

**原因：** 客户端和服务端的 Reality 密钥对不匹配（通常是 v2rayN 使用 Xray-core 连接 sing-box 服务端）。

**解决：** 
- 服务端用 `sing-box generate reality-keypair` 生成的密钥对
- 客户端必须配置服务端生成的 **公钥**（`public_key`）
- 不可用独立生成的密钥对
- 使用 Hiddify 或 sing-box 原生客户端（不要用 v2rayN + Xray-core）

### 3. 出站超时

```
connect: dial tcp <IP>:443: i/o timeout
```

**原因：** 服务器 IPv6 出站路由问题。

**解决：** 已在部署脚本中自动禁用 IPv6：
```bash
sysctl net.ipv6.conf.all.disable_ipv6=1
```

### 4. OOM（内存溢出）

512MB 内存的 ECS 在 `apt upgrade` 大包操作时可能 OOM（sshd 被 kill，连接断开）。

**解决：** 脚本已自动创建 1GB swap 文件。手动操作：
```bash
dd if=/dev/zero of=/swapfile bs=1M count=1024
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
```

### 5. Hiddify 退出后配置丢失

Hiddify 在退出时可能重置端口为默认值。

**解决方法：** 手动修改 `current-config.json` 后，在退出前不要清理——先关闭开关（不退出程序）再修改配置，然后重新打开。

### 6. 本地端口验证

```bash
# 测试代理端口是否工作
curl -x http://127.0.0.1:7890 -I https://www.google.com

# 查看公网 IP 是否已切换
curl -x http://127.0.0.1:7890 https://ifconfig.me
# 应返回服务器 IP: 8.216.46.75

# 对比直连 IP
curl https://ifconfig.me
# 应返回本地公网 IP（不同）
```

---

## VLESS 链接（当前部署）

供 Hiddify 等客户端一键导入：

```
vless://61c70a84-facf-43f8-85c6-82096a7f5d60@8.216.46.75:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=d0uUSr8zfuIZbANQGQc8UQikMN784lVglPyHeemuuwY&sid=c13a907a&type=tcp#Tokyo-singbox
```

> ⚠️ 此链接含服务器信息，请勿公开分享。

---

## 文件说明

| 文件 | 说明 |
|------|------|
| `deploy.sh` | 服务器端一键部署脚本 |
| `README.md` | 本操作指南 |
| `/etc/sing-box/config.json` | 服务端配置文件 |
| `/etc/sing-box/client-info.txt` | 客户端连接信息 |
| `D:\Programs\Hiddify\hiddify_portable_data\data\current-config.json` | Hiddify 本地配置 |
