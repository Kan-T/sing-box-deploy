# sing-box VLESS-Reality + FRP 部署指南

通过 **国内 ECS 做 frps 入口** + **华为云 VDI 做 sing-box 出口** 的方案，让本地 Hiddify/NeoBox 走纯内网骨干连到国内，再经 frp 隧道出境到华为云 VDI 访问境外网络。

> **核心收益**：本地到国内 ECS 是纯内网骨干，不受"本地出口到境外线路被运营商 DROP"影响（旧方案直接跨境连东京/境外 frps，线路波动即断）。出口仍在境外（华为云），翻墙功能不变。
>
> **详细 FRP 部署见 [frp/README.md](frp/README.md)**，本文件聚焦整体架构 + sing-box 节点配置。

## 目录

- [项目说明](#项目说明)
- [架构总览](#架构总览)
- [FRP 通道](#frp-通道国内-ecs-入口--vdi-出口)
- [sing-box 节点配置](#sing-box-节点配置)
- [本地客户端](#本地客户端)
- [端口对照表](#端口对照表)
- [维护管理](#维护管理)
- [排错指南](#排错指南)
- [VDI 只能 VNC / 进不了正规 HDC 桌面](#vdi-只能-vnc--进不了正规-hdc-桌面协议)
- [VDI Keepalive](#vdi-keepalive-华为-fusionaccess-vdi-防断连方案)

---

## 项目说明

| 项目 | 值 |
|------|-----|
| 入口跳板 | 阿里云 ECS 广州 (8.134.207.151, `i-7xv2n6228pgnp9eppo1q`) |
| 出口 | 华为云 VDI (94.74.88.130, 内网) |
| 代理协议 | VLESS-Reality (出口在华为云 VDI 的 sing-box) |
| 底层软件 | [sing-box](https://sing-box.sagernet.org) + [frp](https://github.com/fatedier/frp) v0.63.0 |
| 本地客户端 | Hiddify / NeoBox / sing-box 命令行 |

**关键端口（国内 ECS 入口侧）：**

| 服务 | 端口 | 说明 |
|------|------|------|
| frps 通信 | **7000** | VDI frpc 主动连此口建隧道 |
| VLESS 出口转发 | **9443** | 本地节点连这里，实际流量被转给华为云 VDI |
| VDI SSH 映射 | **6022** | 反向映射到 VDI:22，运维通道 |
| frps Dashboard | **7500** | 管理界面（admin / gzfrps2026） |

> ⚠️ 国内 ECS 还跑着 nginx + 多个 node web 服务（80/443/3001/3010/8081），frps 只占 7000/7500/9443/6022，不碰现有 web 服务。

---

## 架构总览

```
┌──────────────────┐  纯内网骨干    ┌───────────────────┐  frp隧道  ┌──────────────────┐
│  本地客户端       │ ─────────────▶ │  国内 ECS 广州     │ ◀──────── │  华为云 VDI      │
│  (Hiddify /      │  8.134.207.151 │  frps             │  7000     │  frpc + sing-box │
│   NeoBox)        │  :9443         │  (入口跳板)        │  9443     │  127.0.0.1:443   │
│                  │ ◀───────────── │                   │ ────────▶ │                  │
│  本:7890/12334   │   VLESS-Reality│                   │           │  sing-box 出口    │
└──────────────────┘               └───────────────────┘           └────────┬─────────┘
                                                                             │
                                                                             ▼ 出境访问境外
```

**数据流**：本地 → 国内 ECS:9443（frps 转发）→ frp 隧道 → VDI sing-box:443（VLESS-Reality）→ 境外。本地只连国内 IP，出境动作发生在 GFW 管不到的华为云侧。

---

## FRP 通道（国内 ECS 入口 + VDI 出口）

完整部署/排错见 [frp/README.md](frp/README.md)。要点：

| 组件 | 位置 | 作用 |
|------|------|------|
| frps | 国内 ECS 8.134.207.151 | 入口，监听 7000(通信) + 9443(VLESS转发) + 6022(VDI SSH) + 7500(dashboard) |
| frpc | 华为云 VDI 94.74.88.130 | 主动连国内 frps，映射本地 443(→9443) + 22(→6022) |
| sing-box | 华为云 VDI | VLESS-Reality 出口，真正出境 |

**部署命令（国内 ECS 装 frps）：**
```bash
sudo bash frp/frp-server.sh --token wzlkzjioM9TBgDv2MfDGL12FZgjDdguN \
  --bind-port 7000 --dashboard-port 7500 \
  --download-url "https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/v0.63.0/frp_0.63.0_linux_amd64.tar.gz" \
  --skip-apt 1
```

**部署命令（华为云 VDI 装/改 frpc）：**
```bash
sudo bash frp/frp-client.sh --server 8.134.207.151 --port 7000 \
  --token wzlkzjioM9TBgDv2MfDGL12FZgjDdguN \
  --proxies 'name=vdi-singbox,type=tcp,local_ip=127.0.0.1,local_port=443,remote_port=9443;name=ssh,type=tcp,local_ip=127.0.0.1,local_port=22,remote_port=6022' \
  --download-url "https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/v0.63.0/frp_0.63.0_linux_amd64.tar.gz" \
  --skip-apt 1
```

> VDI 上 frpc 已装过时用 `--skip-download 1` 只改指向（见 [frp/repoint-frpc-cmd.txt](frp/repoint-frpc-cmd.txt)）。

---

## sing-box 节点配置

**当前生效的本地节点 VLESS 链接**（IP 用国内 ECS 8.134.207.151:9443，UUID/公钥/ShortID/SNI 全沿用华为云 VDI 的 sing-box）：

```
vless://855c3ac0-cd8e-465e-a743-a48d9f8012e1@8.134.207.151:9443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=iu5wVNmSuIeGk67J_Ygx5fK4f982sBBP4bkjVjEjQ18&sid=2bd464d7&type=tcp#VDI-出口(国内ECS)
```

### 本地 sing-box 命令行客户端配置（可选）

创建 `myconf/config.json`：

```json
{
  "log": { "level": "info", "output": "logs/box.log", "timestamp": true },
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
      "server": "8.134.207.151",
      "server_port": 9443,
      "uuid": "855c3ac0-cd8e-465e-a743-a48d9f8012e1",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "www.apple.com",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "iu5wVNmSuIeGk67J_Ygx5fK4f982sBBP4bkjVjEjQ18",
          "short_id": "2bd464d7"
        }
      },
      "packet_encoding": "xudp"
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [ { "domain_suffix": [".cn"], "outbound": "direct" } ],
    "final": "proxy"
  }
}
```

> 华为云 VDI 上的 sing-box 服务端配置（inbound 监听 127.0.0.1:443，outbound direct 出境）见 [frp/result.md](frp/result.md) 记录的 VDI sing-box 信息。

---

## 本地客户端

### 方案 A：Hiddify（推荐）

[Hiddify](https://github.com/hiddify/hiddify-next) 是基于 sing-box 的多平台代理客户端。

1. 从 [GitHub Releases](https://github.com/hiddify/hiddify-next/releases) 下载
2. **+ 添加 → 从剪贴板导入**，粘贴上面「当前生效的本地节点 VLESS 链接」
3. 模式选**「服务模式」**，第三方软件连 `127.0.0.1:7890`（或 Hiddify 默认 12334）

验证：
```bash
curl -x http://127.0.0.1:7890 -sS --max-time 10 https://google.com -o /dev/null -w "%{http_code}"
# 返回 200 表示正常
```

### 方案 B：NeoBox（手机）

同上 VLESS 链接，IP 用 `8.134.207.151:9443`，协议参数（UUID/公钥/ShortID/SNI/fp）全沿用。

> ⚠️ 手机 NeoBox 之前连的是 `8.216.46.75:443`（旧东京 Shadowsocks 共存口，错的），已废弃，改连 8.134.207.151:9443。

---

## 端口对照表

### 国内 ECS 入口侧

| 端口 | 服务 | 说明 |
|------|------|------|
| 80/443/8081 | 已有 web 服务 | nginx + docker + node，勿动 |
| 3001/3010 | 已有 node web | quiz-api / digital-employee-saas，勿动 |
| **7000** | frps 通信 | VDI frpc 连接入口 |
| **9443** | VLESS 出口转发 | 本地节点连这里 |
| **6022** | VDI SSH 映射 | 运维通道 |
| **7500** | frps Dashboard | 管理界面 |

### 华为云 VDI 侧（frpc 映射的本地服务）

| 端口 | 服务 | 说明 |
|------|------|------|
| 443 | sing-box VLESS-Reality | 真正出境的出口 |
| 22 | SSH | 反向映射到国内 6022 |

### 本地端口

| 端口 | 协议 | 说明 |
|------|------|------|
| **7890** | HTTP/SOCKS5（mixed） | 第三方软件连接此端口 |
| 12334 | HTTP/SOCKS5（Hiddify 默认） | Hiddify 未改端口时使用 |

---

## 维护管理

### 国内 ECS frps
```bash
systemctl status frps
journalctl -u frps -n 30 --no-pager      # 看 frpc 是否注册（new proxy [vdi-singbox] success）
systemctl restart frps
```

### 华为云 VDI frpc + sing-box
通过国内 ECS 的 6022 进 VDI 操作（不再需要华为云控制台/Workbench）：
```bash
ssh -p 6022 root@8.134.207.151
# 进 VDI 后：
systemctl status frpc sing-box
journalctl -u frpc -n 20 --no-pager
systemctl restart frpc
```

> 也可用 `vdi-keepalive/heal.py` 一键诊断（见下）。

### 重新部署
frp 脚本幂等，重复运行自动清理旧部署。国内 ECS 国内源下载 frp 加 `--download-url`，apt 源过期加 `--skip-apt 1`。

---

## 排错指南

### 1. 本地连 9443 超时
- 本机直连国内 ECS 测试：`curl -sv --max-time 8 telnet://8.134.207.151:9443`
- 通 = 链路正常，查 Hiddify/NeoBox 节点 IP 是否还是旧的 8.216.46.75（应改 8.134.207.151）
- 不通 = 国内 ECS frps 挂了或安全组没放行 9443，查 `systemctl status frps` + 安全组

### 2. 9443 通但代理不通（VLESS 握手失败）
- 9443 TCP 通只代表 frps 在转发，不代表 VDI sing-box 正常
- 验证 VDI：`ssh -p 6022 root@8.134.207.151 'systemctl status sing-box; ss -tlnp | grep 443'`
- VDI frpc 是否掉线：国内 ECS `journalctl -u frps | grep -i "new proxy"`，无 `vdi-singbox success` 说明 frpc 没注册，重启 VDI frpc

### 3. Reality 握手失败（received real certificate）
- 客户端公钥必须用 VDI sing-box 服务端生成的 `public_key`（`iu5wVNmSuIeGk67J_Ygx5fK4f982sBBP4bkjVjEjQ18`），不可独立生成
- 用 Hiddify / NeoBox / sing-box 原生客户端，不要 v2rayN + Xray-core

### 4. 本地出口线路到境外被运营商 DROP（本方案的背景痛点）
- 症状：本地直连任何境外 IP（阿里云/腾讯云/AWS）全超时，但国内 IP 通
- 这就是为什么入口要放国内——本地到国内 ECS 走内网骨干，绕开被 DROP 的跨境线路
- 若国内 ECS 8.134 段将来被标记，换一台境外 VPS 做 frps 入口（架构不变，frpc 改 serverAddr + 本地节点改 IP）

### 5. Hiddify 退出后配置丢失
手动改 `current-config.json` 后先关开关（不退出）再改，然后重新打开。

---

## VDI 只能 VNC / 进不了正规 HDC 桌面协议

**症状**：本地华为 Workspace / HDC 客户端连不上（"虚拟机尚未就绪" 6039 / "失去连接"自动重连失败），只能退回 **VNC** 才能进桌面。

**根因**（2026-10 排查确认）：HDAgent 的 HDP pre-connect 需要一个由**用户图形会话**创建的 unix socket，由 GNOME 登录会话的 autostart 拉起（`hdpdaemon.desktop → hdpdaemon.sh → hdpdaemon20`）。一旦当前会话是 **VNC 建的**、或 `hdpdaemon20` 没起来 / 会话状态脏了，HDAgent 就拒绝 HDP 接管（`code:28104003`），客户端回退 VNC。

**修复**（按风险从低到高，全程不碰 frpc/sing-box/keepalive，VPN 不断）：

```bash
sudo bash vdi-hdc-repair.sh --all      # 注销 VNC 会话 + 重启 HDAgent + 重挂 bind mount
# 然后用正规 HDC 客户端（华为 Workspace，走 HDP/流媒体协议，不要选 VNC/备用）重新登录
# 仍失败 →
sudo bash vdi-hdc-repair.sh --reboot   # 重启 VDI（最彻底；frpc/sing-box/keepalive 都开机自启）
```

跑完 1-3 级后**务必用正规 HDC 协议重新登录**（若客户端默认连 VNC，手动切到 HDP/流媒体）。正规登录会拉起 `hdpdaemon20`，HDP 通道即通，不再退回 VNC。

详细日志特征、本地线路丢 HDP 媒体面（UDP）的情况，见 [vdi-keepalive.md](vdi-keepalive.md) 的"VDI 只能 VNC"一节。

---

## 一键脚本（放本目录，在 VDI 里以 root 跑）

| 脚本 | 用途 |
|------|------|
| `vdi-bootstrap.sh` | 任意 VDI 从零/换机器**一键自举**：装 sing-box + frpc + keepalive + bind mount + SSH 公钥，打印 VLESS 链接 |
| `vdi-hdc-repair.sh` | 修复"只能 VNC / 6039 / 28104003"：注销会话 / 重启 HDAgent / 重启 VDI 分级恢复 |

用法示例：
```bash
# 从零搭一台新 VDI（--ecs-ip 是 frps 所在国内 ECS）
sudo bash vdi-bootstrap.sh --ecs-ip 8.134.207.151 --frp-token <TOKEN> \
  --ssh-pubkey "ssh-ed25519 AAAA... me@host" \
  --frp-bin-url "https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/v0.63.0/frp_0.63.0_linux_amd64.tar.gz"

# 修"只能 VNC"
sudo bash vdi-hdc-repair.sh --all
```

---

## VLESS 链接（当前生效）

供 Hiddify / NeoBox 一键导入：

```
vless://855c3ac0-cd8e-465e-a743-a48d9f8012e1@8.134.207.151:9443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=iu5wVNmSuIeGk67J_Ygx5fK4f982sBBP4bkjVjEjQ18&sid=2bd464d7&type=tcp#VDI-出口(国内ECS)
```

> ⚠️ 此链接含服务器信息，请勿公开分享。

---

## 文件说明

| 文件 | 说明 |
|------|------|
| `frp/` | FRP 部署（国内 ECS frps + VDI frpc + 排错） |
| `frp/README.md` | FRP 完整部署/排错文档 |
| `frp/result.md` | FRP 部署输出记录 + 当前生效 VLESS 链接 |
| `frp/frp-server.sh` | 国内 ECS frps 部署脚本（含国内源/skip-apt） |
| `frp/frp-client.sh` | VDI frpc 部署脚本（含国内源/skip-apt/skip-download） |
| `frp/repoint-frpc-cmd.txt` | VDI 仅改 frpc 指向的轻量命令 |
| `deploy.sh` | sing-box 服务端部署脚本（华为云 VDI 上的 sing-box） |
| `vdi-keepalive.md` | 华为 VDI 防断连方案 |
| `vdi-keepalive/heal.py` | VDI 一键诊断 + 自动修复 |
| `vdi-keepalive/keepalive.py` | VDI 防 HDC 空闲断开 |

---

## VDI Keepalive（华为 FusionAccess VDI 防断连方案）

> 详见 [vdi-keepalive.md](vdi-keepalive.md)

在华为 FusionAccess VDI 上部署本地 keepalive 脚本，防止 HDC 服务端空闲断开，并监控 sing-box 隧道健康。包含：

- **keepalive.py**（v13）：evdev + 剪贴板 + 屏保抑制多通道防护，子进程超时保护防卡死
- **heal.py**：一键诊断 + 自动修复 keepalive / bind mount / sing-box
- **sing-box DNS 修复**：REALITY 握手失败的 `/etc/hosts` 解决方案

---

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| 初始 | 2026-07-13 | 阿里云东京 ECS 直连 sing-box（8.216.46.75:8443） |
| 迁移 | 2026-10-27 | frps 迁到国内广州 ECS 8.134.207.151 做入口，VDI 做出口；本地节点改 8.134.207.151:9443；脚本加国内源/skip-apt/skip-download；新增 6022 SSH 运维通道 |
