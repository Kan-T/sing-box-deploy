# FRP 内网穿透部署方案

## 方案概述

利用 **FRP (Fast Reverse Proxy)** 建立永久性反向代理隧道，通过拥有公网 IP 的服务器中转，实现对公司华为云桌面系统 (VDI) 网络的访问。

## 架构原理

```
本地 Hiddify / NeoBox 客户端
       │  (国内骨干网，纯内网，GFW 碰不到)
       ▼
国内 ECS (frps, 8.134.207.151) ◄──── 隧道 ────► 华为云 VDI (frpc + sing-box)
       │  7000=frps通信  9443=VLESS出口转发  6022=VDI SSH
       │                          │
       │                          ▼
       │                  VDI sing-box:443 → 出境访问境外
       ▼
  本地指定端口访问
```

**为什么入口在国内**：本地到国内 ECS 走纯内网骨干，不受"本地出口到境外线路被运营商 DROP"影响（旧方案直接跨境连境外 frps，线路波动即断）。出口（境外流量）由华为云 VDI 的 sing-box 承担，国内 ECS 只做"入口跳板"。

## 组件说明

| 组件 | 运行位置 | 角色 |
|------|----------|------|
| **frps** | 国内 ECS (阿里云广州 8.134.207.151) | 服务端入口，监听 frpc + 转发 9443 |
| **frpc** | 华为云 VDI (94.74.88.130) | 客户端，主动连国内 frps 建立隧道 |
| **sing-box** | 华为云 VDI | VLESS-Reality 出口，真正出境 |

## 部署流程

1. **国内 ECS 部署 frps** - 入口跳板，监听 7000/9443/6022
2. **VDI 部署 frpc** - 主动连国内 frps，映射本地 443(→9443) + 22(→6022)
3. **本地连接** - Hiddify/NeoBox 节点 IP 指向国内 ECS:9443（UUID/公钥/ShortID/SNI 全沿用 VDI sing-box 的）

## 优势

- ✅ 入口在国内，纯内网骨干，**不受本地出口到境外的线路波动影响**（这是新方案的核心收益）
- ✅ 无需 VDI 拥有公网 IP
- ✅ 隧道加密传输，安全可靠
- ✅ 支持 TCP/UDP 多协议转发
- ✅ 成本极低（仅需一台国内轻量服务器）
- ✅ 入口可替换：将来国内 ECS IP 被标记，换一台境外 VPS 做 frps 即可（架构不变，只改 frpc 的 serverAddr + 本地节点 IP）

> **取舍说明**：新方案把"本地接入点"挪到国内，牺牲了"境外 IP 抗 GFW SNI 审查"的能力（Reality 伪装对国内 IP 意义不大），换来"纯内网入口不受跨境线路波动影响"。出口仍在境外（华为云），翻墙功能不受影响。

---

## 环境信息（当前部署）

| 项目 | 值 | 说明 |
|------|------|------|
| **国内 frps (入口)** | `8.134.207.151` (阿里云广州, 实例 `i-7xv2n6228pgnp9eppo1q`) | 入口跳板，监听 7000/9443/6022/7500 |
| **VDI (frpc+出口)** | `94.74.88.130` (华为云, 内网) | frpc 主动连国内 frps，sing-box 监听 127.0.0.1:443 |
| **frp 版本** | `v0.63.0` | |
| **安装目录** | `/opt/frp` (软链接 → `/opt/frp_0.63.0_linux_amd64`) | 两台机器同 |
| **配置文件** | frps: `/etc/frp/frps.toml` / frpc: `/etc/frp/frpc.toml` | |
| **Token** | `wzlkzjioM9TBgDv2MfDGL12FZgjDdguN` | 国内 frps 与 VDI frpc 共用 |
| **Dashboard** | `http://8.134.207.151:7500` (admin / gzfrps2026) | 仅国内 frps 有 |

> **历史**：最初 frps 部署在阿里云东京 `8.216.46.75`，因本地出口到该 IP 段被运营商 DROP（线路级，非协议级）已弃用。现迁移到国内广州 ECS 做入口。

---

## 端口规划（国内 ECS 入口）

| 端口 | 协议 | 用途 | 安全组/防火墙 |
|------|------|------|--------------|
| **7000** | TCP | frps 通信端口 (frpc 连接) | 已放行 0.0.0.0/0 |
| **7500** | TCP | frps Dashboard 管理界面 | 已放行 0.0.0.0/0 |
| **9443** | TCP | VDI sing-box VLESS 出口转发 | 已放行 0.0.0.0/0 |
| **6022** | TCP | VDI SSH 反向映射 (运维通道) | 已放行 0.0.0.0/0 |
| **80/443/8081** | TCP | 国内 ECS 已有 web 服务 (docker/node) | 原有，勿动 |

> **注意**：国内 ECS 还跑着 nginx + 多个 node web 服务（quiz-api / digital-employee-saas），frps 部署只加 7000/7500/9443/6022，**不碰现有 web 服务端口**。

---

## 服务端部署（国内 ECS）

### 一键部署

```bash
# 国内 ECS 直连 GitHub 慢，加 --download-url 走国内镜像；apt 源问题加 --skip-apt 1
# 用阿里云 OpenAPI RunCommand 直接执行（不需要 SSH，22 端口可能被拦）：
#   见 D:/SelfProjects/aliyun-sts/install_gz_frps.py 同款逻辑

sudo bash frp-server.sh \
  --token wzlkzjioM9TBgDv2MfDGL12FZgjDdguN \
  --bind-port 7000 \
  --dashboard-port 7500 \
  --download-url "https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/v0.63.0/frp_0.63.0_linux_amd64.tar.gz" \
  --skip-apt 1
```

### 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--token` | 自动生成 32 字符 | frpc 连接认证密钥，**必须与客户端一致** |
| `--bind-port` | 7000 | frps 监听端口 (frpc 连接用) |
| `--dashboard-port` | 7500 | Web 管理界面端口，设为空可禁用 |
| `--dashboard-user` | admin | Dashboard 登录用户名 |
| `--dashboard-pwd` | 自动生成 16 字符 | Dashboard 登录密码 |
| `--download-url` | GitHub 直连 | 自定义 frp 二进制下载源（国内用 gh-proxy 镜像） |
| `--skip-apt` | 0 | 1=跳过 apt 依赖安装（apt 源过期会挂的机器用） |

### 部署后输出示例

```
==========================================
  frps 部署完成！
==========================================
  版本:           v0.63.0
  安装目录:       /opt/frp -> /opt/frp_0.63.0_linux_amd64
  配置文件:       /etc/frp/frps.toml
  绑定端口:       7000/TCP
  Token:          wzlkzjioM9TBgDv2MfDGL12FZgjDdguN
  Dashboard:      http://8.134.207.151:7500 (admin / gzfrps2026)
==========================================
```

> **⚠️ 重要**：请妥善保存 **Token**，客户端部署时必须使用相同 Token。

### 管理命令

```bash
# 查看状态
systemctl status frps

# 查看实时日志
journalctl -u frps -f

# 重启服务
systemctl restart frps

# 查看 Dashboard
# 浏览器访问: http://8.134.207.151:7500
```

### 重新部署/升级

直接重新运行脚本即可（自动清理旧版本）：
```bash
sudo bash frp-server.sh --token <token> --bind-port 7000 --download-url <url> --skip-apt 1
```

---

## 客户端部署（华为云 VDI）

### 参数化部署（推荐）

```bash
# 华为云 VDI 用国内可达源下载 frp（华为云出境没问题，但走国内源更稳）
sudo bash frp-client.sh \
  --server 8.134.207.151 \
  --port 7000 \
  --token wzlkzjioM9TBgDv2MfDGL12FZgjDdguN \
  --proxies 'name=vdi-singbox,type=tcp,local_ip=127.0.0.1,local_port=443,remote_port=9443;name=ssh,type=tcp,local_ip=127.0.0.1,local_port=22,remote_port=6022' \
  --download-url "https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/v0.63.0/frp_0.63.0_linux_amd64.tar.gz" \
  --skip-apt 1
```

### 仅改指向（frpc 已装过，只换 frps IP）

```bash
# frp 二进制已存在时，只重建配置和服务，跳过下载/安装
sudo bash frp-client.sh \
  --server <新IP> --token <token> \
  --proxies 'name=vdi-singbox,type=tcp,local_ip=127.0.0.1,local_port=443,remote_port=9443;name=ssh,type=tcp,local_ip=127.0.0.1,local_port=22,remote_port=6022' \
  --skip-download 1
```

### 代理规则格式

```
name=代理名称,type=协议,local_ip=本地IP,local_port=本地端口,remote_port=远程端口
```

多条规则用 `;` 分隔。

| 字段 | 必填 | 说明 | 示例 |
|------|------|------|------|
| `name` | 是 | 代理唯一标识 | `vdi-singbox`, `ssh` |
| `type` | 否 | tcp/udp (默认 tcp) | `tcp` |
| `local_ip` | 否 | 本地服务监听 IP (默认 127.0.0.1) | `127.0.0.1` |
| `local_port` | 是 | 本地服务实际端口 | `443`, `22` |
| `remote_port` | 是 | 国内 ECS 映射端口 | `9443`, `6022` |

### 常用代理配置示例

#### 1. VDI sing-box 出口 (TCP 443 → 9443)
```bash
--proxies 'name=vdi-singbox,type=tcp,local_port=443,remote_port=9443'
```

#### 2. SSH 远程管理 (TCP 22 → 6022)
```bash
--proxies 'name=ssh,type=tcp,local_port=22,remote_port=6022'
```

#### 3. 组合：sing-box + SSH
```bash
--proxies 'name=vdi-singbox,type=tcp,local_port=443,remote_port=9443;name=ssh,type=tcp,local_port=22,remote_port=6022'
```

### 部署后访问验证

| 服务 | VDI 本地访问 | 远程访问 (你的电脑/手机) |
|------|-------------|---------------------|
| **sing-box VLESS 出口** | `127.0.0.1:443` | `8.134.207.151:9443` |
| **SSH (VDI)** | `ssh 127.0.0.1 -p 22` | `ssh -p 6022 root@8.134.207.151` |

> **本地 Hiddify/NeoBox 节点**：VLESS 链接 IP 用 `8.134.207.151`、端口 `9443`，UUID/公钥/ShortID/SNI 全沿用 VDI sing-box 的（见 result.md 的 vless 链接，IP 换成 8.134.207.151）。

### 管理命令

```bash
# 查看状态
systemctl status frpc

# 查看实时日志
journalctl -u frpc -f

# 重启服务
systemctl restart frpc

# 重新部署 (修改配置后)
sudo bash frp-client.sh --server <IP> --token xxx --proxies '...'
```

---

## 卸载清理

### 服务端卸载
```bash
sudo bash uninstall-frps.sh
```

### 客户端卸载
```bash
sudo bash uninstall-frpc.sh
```

卸载会清理：
- systemd 服务 (`frps`/`frpc`)
- 安装目录 (`/opt/frp`, `/opt/frp_*`)
- 配置文件
- 防火墙规则 (UFW/iptables)
- 提醒手动删除云厂商安全组规则

---

## 故障排查

### 1. 连接不上
- 检查国内 ECS 安全组：7000、9443、6022、7500 等 TCP 入站是否放行（本部署已用 OpenAPI `AuthorizeSecurityGroup` 放行）
- 检查国内 ECS 本地防火墙：`ufw status` 或 `iptables -L INPUT`
- 检查国内 frps 日志：`journalctl -u frps -n 100 --no-pager`，看到 `new proxy [vdi-singbox] type [tcp] success` 表示 frpc 已注册
- 检查 VDI frpc 日志：`journalctl -u frpc -n 100 --no-pager`，看到 `start proxy success` 表示代理已建立
- 本机测试 9443 可达：`curl -sv --max-time 8 telnet://8.134.207.151:9443`

### 2. Token 不匹配
- 确保国内 frps 和 VDI frpc 使用完全相同的 Token
- 国内 ECS 查看：`grep token /etc/frp/frps.toml`
- frps 日志报 `token in login doesn't match` → 两边 token 不一致，重配 frpc

### 3. 端口冲突
- `remote_port` 在国内 ECS 上不能重复（7000/7500/9443/6022 别和已有 web 服务撞）
- 国内 ECS 已有 80/443/3001/3010/8081 在跑，frps 只占 7000/7500/9443/6022
- 查看 Dashboard 确认端口占用：`http://8.134.207.151:7500`

### 4. VDI frpc 频繁重连
- 检查 VDI 到国内 ECS 的线路：在 VDI 上 `ping 8.134.207.151` / `curl -sv telnet://8.134.207.151:7000`
- 心跳配置：`heartbeatInterval=30` `heartbeatTimeout=90`
- frps 日志看 frpc 是否反复 `login` → VDI 侧网络不稳

### 5. 本地连 9443 通但代理不通
- 9443 TCP 通只代表 frps 在转发，不代表 VDI sing-box 正常
- 验证 VDI sing-box：`ssh -p 6022 root@8.134.207.151 'systemctl status sing-box; ss -tlnp | grep 443'`
- 或 VDI 本机：`journalctl -u sing-box -n 20 --no-pager`

### 6. 通过 6022 反向 SSH 进 VDI（运维通道）
frpc 把 VDI 的 22 反向映射到国内 ECS 的 6022，运维方可远程进 VDI：
```bash
# 前提：VDI 的 root 配了 SSH 公钥认证（authorized_keys），否则需密码
ssh -p 6022 root@8.134.207.151
# 进 VDI 后可直接管理 frpc / sing-box / keepalive，无需再登华为云控制台
```
> 6022 是 frp 反向隧道，本地连国内 ECS 的 6022 即可进 VDI。国内 ECS 安全组已放行 6022。

### 6. 国内 ECS 直连 GitHub 下载 frp 慢/失败
- 加 `--download-url "https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/v0.63.0/frp_0.63.0_linux_amd64.tar.gz"`
- 脚本会校验下载完整性（文件过小会报"截断"）

---

## 文件清单

```
frp/
├── README.md              # 本文档
├── frp-server.sh          # 服务端部署/重装脚本（含 --download-url / --skip-apt）
├── frp-client.sh          # 客户端部署/重装脚本（含 --download-url / --skip-apt / --skip-download）
├── result.md              # 部署输出记录（含 VLESS 链接）
├── repoint-frpc-cmd.txt   # VDI 仅改 frpc 指向的轻量命令
├── uninstall-frps.sh      # 服务端彻底卸载
└── uninstall-frpc.sh      # 客户端彻底卸载
```

---

## 快速开始清单（当前已部署状态）

- [x] 国内 ECS: frps 运行中（7000/9443/6022/7500 监听）
- [x] 国内 ECS: 阿里云安全组放行 7000/9443/6022/7500
- [x] VDI: frpc 运行中（连 8.134.207.151:7000，映射 443→9443、22→6022）
- [x] 本地 Hiddify/NeoBox: 节点 IP 改为 8.134.207.151:9443，VLESS 连通过

---

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.63.0 | 2026-07-13 | 初始版本（阿里云东京 8.216.46.75 做 frps） |
| 迁移 | 2026-10-27 | frps 迁到国内广州 ECS 8.134.207.151 做入口，frpc 改指向；脚本加 --download-url / --skip-apt / --skip-download；新增 6022 SSH 反向映射 |
