# FRP 内网穿透部署方案

## 方案概述

利用 **FRP (Fast Reverse Proxy)** 建立永久性反向代理隧道，通过拥有公网 IP 的服务器中转，实现对公司华为云桌面系统 (VDI) 网络的访问。

## 架构原理

```
本地 Hiddify 客户端
       │
       ▼
公网服务器 (frps) ◄────── 隧道 ──────► 公司 VDI (frpc)
       │                                      │
       ▼                                      ▼
  指定端口访问                          目标服务端口
```

## 组件说明

| 组件 | 运行位置 | 角色 |
|------|----------|------|
| **frps** | 公网服务器 (阿里云/腾讯云/AWS 等) | 服务端，监听客户端连接 |
| **frpc** | 公司华为云 VDI | 客户端，主动连接 frps 建立隧道 |

## 部署流程

1. **准备公网服务器** - 拥有固定公网 IP，建议轻量应用服务器（成本低）
2. **部署 frps** - 在公网服务器运行服务端，配置监听端口
3. **部署 frpc** - 在 VDI 运行客户端，配置连接 frps 并映射目标端口
4. **本地连接** - Hiddify 客户端连接公网服务器 IP + 映射端口

## 优势

- ✅ 绕过单位防火墙限制（出站连接通常不拦截）
- ✅ 无需 VDI 拥有公网 IP
- ✅ 隧道加密传输，安全可靠
- ✅ 支持 TCP/UDP 多协议转发
- ✅ 成本极低（仅需一台轻量云服务器）

---

## 环境信息（已知）

| 项目 | 值 | 说明 |
|------|------|
| **Server 公网 IP** | `8.216.46.75` (阿里云 ECS) |
| **Client 内网 IP** | `94.74.88.54` (华为云 VDI) |
| **frp 版本** | `v0.63.0` |
| **安装目录** | `/opt/frp` (软链接 → `/opt/frp_0.63.0_linux_amd64`) |
| **配置文件** | Server: `/opt/frp/frps.toml` / Client: `/opt/frp/frpc.toml` |

---

## 端口规划

| 端口 | 协议 | 用途 | 安全组/防火墙 |
|------|------|------|--------------|
| **7000** | TCP | frps 通信端口 (frpc 连接) | Server 入站放行 |
| **7500** | TCP | frps Dashboard 管理界面 | Server 入站放行 (可选) |
| **8443** | TCP | Hiddify 代理映射端口 | Server 入站放行 |
| **6022** | TCP | SSH 远程管理映射端口 | Server 入站放行 |
| **6000** | TCP | 预留/其他 TCP 服务 | 按需放行 |
| **5000** | UDP | 预留/游戏语音等 | 按需放行 |

> **注意**：Server 端安全组必须放行 **7000、7500、8443、6022** 等 TCP 入站规则。

---

## 服务端部署

### 一键部署

```bash
# 上传脚本到服务器
scp frp-server.sh root@8.216.46.75:~/

# 登录服务器执行
ssh root@8.216.46.75
sudo bash frp-server.sh
```

### 自定义参数部署

```bash
sudo bash frp-server.sh \
  --token your-custom-token \
  --bind-port 7000 \
  --dashboard-port 7500 \
  --dashboard-user admin \
  --dashboard-pwd your-dashboard-password
```

### 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--token` | 自动生成 32 字符 | frpc 连接认证密钥，**必须与客户端一致** |
| `--bind-port` | 7000 | frps 监听端口 (frpc 连接用) |
| `--dashboard-port` | 7500 | Web 管理界面端口，设为空可禁用 |
| `--dashboard-user` | admin | Dashboard 登录用户名 |
| `--dashboard-pwd` | 自动生成 16 字符 | Dashboard 登录密码 |

### 部署后输出示例

```
==========================================
  frps 部署完成！
==========================================
  版本:           v0.63.0
  安装目录:       /opt/frp -> /opt/frp_0.63.0_linux_amd64
  配置文件:       /opt/frp/frps.toml
  绑定端口:       7000/TCP
  Token:          k8x9m2n4p5q7r8s9t0u1v2w3x4y5z6a7
  Dashboard:      http://8.216.46.75:7500 (admin / x9y8z7w6v5)
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
# 浏览器访问: http://8.216.46.75:7500
```

### 重新部署/升级

直接重新运行脚本即可（自动清理旧版本）：
```bash
sudo bash frp-server.sh  # 保持原配置重装
# 或带新参数
sudo bash frp-server.sh --token new-token --bind-port 7000
```

---

## 客户端部署

### 交互式部署（推荐首次使用）

```bash
# 上传脚本到 VDI
scp frp-client.sh user@94.74.88.54:~/

# 登录 VDI 执行
ssh user@94.74.88.54
sudo bash frp-client.sh
```

按提示输入：
1. **Server IP**: `8.216.46.75`
2. **Token**: 服务端输出的 Token (如 `k8x9m2n4p5q7r8s9t0u1v2w3x4y5z6a7`)
3. **代理规则**: 逐条录入或粘贴完整字符串

### 参数化部署（适合自动化/重装）

```bash
sudo bash frp-client.sh \
  --server 8.216.46.75 \
  --token k8x9m2n4p5q7r8s9t0u1v2w3x4y5z6a7 \
  --proxies 'name=hiddify,type=tcp,local_port=443,remote_port=8443;name=ssh,type=tcp,local_port=22,remote_port=6022'
```

### 代理规则格式

```
name=代理名称,type=协议,local_ip=本地IP,local_port=本地端口,remote_port=远程端口
```

多条规则用 `;` 分隔。

| 字段 | 必填 | 说明 | 示例 |
|------|------|------|------|
| `name` | 是 | 代理唯一标识 | `hiddify`, `ssh` |
| `type` | 否 | tcp/udp (默认 tcp) | `tcp` |
| `local_ip` | 否 | 本地服务监听 IP (默认 127.0.0.1) | `127.0.0.1` |
| `local_port` | 是 | 本地服务实际端口 | `443`, `22` |
| `remote_port` | 是 | 公网服务器映射端口 | `8443`, `6022` |

### 常用代理配置示例

#### 1. Hiddify 面板/代理 (TCP 443 → 8443)
```bash
--proxies 'name=hiddify,type=tcp,local_port=443,remote_port=8443'
```

#### 2. SSH 远程管理 (TCP 22 → 6022)
```bash
--proxies 'name=ssh,type=tcp,local_port=22,remote_port=6022'
```

#### 3. 组合：Hiddify + SSH + 本地 Web (8080 → 8080)
```bash
--proxies 'name=hiddify,type=tcp,local_port=443,remote_port=8443;name=ssh,type=tcp,local_port=22,remote_port=6022;name=web,type=tcp,local_port=8080,remote_port=8080'
```

#### 4. UDP 示例 (游戏/语音)
```bash
--proxies 'name=game,type=udp,local_port=5000,remote_port=5000'
```

### 环境变量方式（适合 CI/CD）

```bash
export SERVER_ADDR="8.216.46.75"
export TOKEN="k8x9m2n4p5q7r8s9t0u1v2w3x4y5z6a7"
export PROXIES="name=hiddify,type=tcp,local_port=443,remote_port=8443;name=ssh,type=tcp,local_port=22,remote_port=6022"
sudo -E bash frp-client.sh
```

### 部署后访问验证

| 服务 | VDI 本地访问 | 远程访问 (你的电脑) |
|------|-------------|---------------------|
| **Hiddify 面板** | `https://127.0.0.1:443` | `https://8.216.46.75:8443` |
| **Hiddify 代理** | `127.0.0.1:443` | `8.216.46.75:8443` |
| **SSH** | `ssh user@127.0.0.1 -p 22` | `ssh user@8.216.46.75 -p 6022` |

### 管理命令

```bash
# 查看状态
systemctl status frpc

# 查看实时日志
journalctl -u frpc -f

# 重启服务
systemctl restart frpc

# 重新部署 (修改配置后)
sudo bash frp-client.sh --server 8.216.46.75 --token xxx --proxies '...'
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
- 检查 Server 安全组：7000、8443、6022 等 TCP 入站是否放行
- 检查 Server 本地防火墙：`ufw status` 或 `iptables -L`
- 检查 Client 日志：`journalctl -u frpc -n 100 --no-pager`

### 2. Token 不匹配
- 确保 Server 和 Client 使用完全相同的 Token
- 可在 Server 查看：`cat /opt/frp/frps.toml | grep token`

### 3. 端口冲突
- `remote_port` 在 Server 上不能重复
- 查看 Dashboard 确认端口占用：`http://8.216.46.75:7500`

### 4. 内存不足 (512MB ECS)
- 脚本已配置 Swap (1GB)、GOGC=20、MemoryLimit=200M
- 查看内存：`free -h` / `systemctl status frps`

### 5. 客户端频繁重连
- 检查网络稳定性：`ping 8.216.46.75`
- 调整心跳：配置中已设置 `heartbeatInterval=30` `heartbeatTimeout=90`

---

## 文件清单

```
frp/
├── README.md              # 本文档
├── frp-server.sh          # 服务端部署/重装脚本
├── frp-client.sh          # 客户端部署/重装脚本
├── uninstall-frps.sh      # 服务端彻底卸载
└── uninstall-frpc.sh      # 客户端彻底卸载
```

---

## 快速开始清单

- [ ] Server: 运行 `sudo bash frp-server.sh`，记录输出的 **Token**
- [ ] Server: 阿里云控制台安全组放行 **7000, 7500, 8443, 6022** TCP 入站
- [ ] Client: 运行 `sudo bash frp-client.sh`，输入 Server IP、Token、代理规则
- [ ] Client: 确认 VDI 上 Hiddify 监听 443、SSH 监听 22
- [ ] 测试：本地浏览器访问 `https://8.216.46.75:8443` 打开 Hiddify 面板
- [ ] 测试：本地 SSH `ssh user@8.216.46.75 -p 6022` 连接 VDI
- [ ] 可选：配置 Hiddify 客户端连接 `8.216.46.75:8443`

---

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.63.0 | 2026-07-13 | 初始版本，适配 512MB ECS，支持幂等重装、Token 认证、Dashboard |