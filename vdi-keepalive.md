# VDI Keepalive — 华为 FusionAccess VDI 防断连方案

## 背景

华为 FusionAccess VDI（虚拟桌面）在用户离开一段时间后会自动断开/锁屏。
根本原因是 **HDC 服务端**（连接代理服务器）在检测到 HDP 协议通道无活跃后，主动切断会话。

本方案提供一套**本地 keepalive 脚本**，尽量阻止锁屏/断开，并监控 sing-box 隧道健康。

## 环境

| 项目 | 值 |
|------|-----|
| VDI 系统 | Ubuntu 20.04（华为 FusionAccess） |
| 登录方式 | 仅 VNC（HDC 断开后） |
| HDC 服务器 | 10.10.0.10 / 10.10.0.11 |
| 代理隧道 | FRP + sing-box (VLESS-Reality) |
| keepalive 脚本 | `~/keep_alive/keepalive.py` |
| 健康检查 | `~/keep_alive/heal.py` |

## 目录结构

```
~/keep_alive/
├── keepalive.py     # 主程序（evdev + xclip + xset 多通道）
├── heal.py          # 诊断修复脚本
├── policy_fake.xml  # 覆盖 HDAgent 本地策略（禁 10 分钟锁屏）
├── watch.sh         # 终端刷新脚本（已弃用，改用 subprocess 方案）
├── keepalive.log    # 运行日志
└── heal.log         # 诊断日志
```

## 服务管理

```bash
# 手动启动/停止
systemctl --user start vdi-keepalive
systemctl --user stop vdi-keepalive
systemctl --user status vdi-keepalive

# 健康检查
python3 ~/keep_alive/heal.py          # 诊断 + 自动修复
python3 ~/keep_alive/heal.py --check  # 仅诊断
```

## keepalive.py 架构（v13 最小化稳定版）

### 为什么 v13 不卡死

之前版本的 CPU 100% 问题根因：`evdev.write()` 和 `XOpenDisplay()` 在 X 服务器不响应时
会**永久阻塞 Python 进程**，且 `signal.alarm` 无法中断阻塞在 C 扩展的调用。

**v13 解决：** 所有可能阻塞的操作都放到**子进程**里执行并加超时：

```python
def safe_run(script, timeout=4):
    p = subprocess.Popen([sys.executable, "-c", script], ...)
    p.wait(timeout=timeout)   # 超时后 kill
```

### 防护通道

| 通道 | 实现 | 说明 |
|------|------|------|
| evdev 键盘 | 子进程写 `/dev/input/event1` | 模拟 Shift/Ctrl 键 |
| evdev 鼠标 | 子进程写 `/dev/input/event3` | 模拟鼠标移动 |
| 剪贴板 | `xclip` 后台线程 | 产生 HDP 协议流量 |
| 屏保抑制 | `xset s off` + `xset -dpms` | 阻止 X11 屏保 |
| systemd-inhibit | 阻止系统休眠 | |
| gnome-inhibit | 阻止 GNOME 锁屏 | |

### 为什么 XWarpPointer / XTEST / uinput 都不行

| 方案 | 结果 |
|------|------|
| XWarpPointer | 复位 XScreenSaver，但 HDC 不认 |
| XTEST / xdotool | 不复位 XScreenSaver |
| uinput 虚拟设备 | X 不识别为用户活动 |
| 画像素改帧缓冲 | X264 编码器 0%（远程不请求帧） |

**结论：本地模拟输入到不了 HDP 协议层。HDC 只认远程客户端发来的输入。**

## heal.py 功能

- 检查 keepalive 进程/服务/日志
- 检查 bind mount（policy_fake.xml → /etc/hdpserver/policy.xml）
- 检查 sing-box 进程/端口/配置/DNS
- 自动修复 keepalive（无 sudo 操作）
- 需要 sudo 的操作打印醒目提示让用户执行

## sing-box DNS 修复记录

### 问题
Hiddify 通过 FRP 隧道到 sing-box 的 REALITY 握手失败：
```
TLS handshake: REALITY: processed invalid connection
```

### 根因
- 系统 DNS 是华为内网（10.81.192.53/54），不能解析外网域名
- REALITY 需要连 `www.apple.com:443` 做 TLS 握手验证，DNS 解析失败

### 修复
1. **移除 config.json 中的 dns 段**（避免 legacy DNS 格式报错）
2. **`/etc/hosts` 添加**：
   ```
   23.200.180.246  www.apple.com
   ```

### 关键配置
```json
{
  "inbounds": [{
    "type": "vless",
    "listen_port": 443,
    "tls": {
      "enabled": true,
      "server_name": "www.apple.com",
      "reality": {
        "enabled": true,
        "handshake": {"server": "www.apple.com", "server_port": 443},
        "private_key": "<PRIVATE_KEY>",
        "short_id": ["2bd464d7"]
      }
    }
  }]
}
```

## 已知限制

1. **HDC 服务端策略无法绕过** — 本地所有模拟都不被 HDC 认可，需要管理员在
   FusionAccess 管理平台调整"会话超时断开"策略
2. **重启后 bind mount 丢失** — 需要重新挂载（heal.py 非 `--check` 模式会自动 `mount --bind` 恢复；`vdi-hdc-repair.sh` 也会重挂）
3. **VNC 不帮助活跃检测** — VNC 走 X11 协议，不走 HDP

## VDI 只能 VNC、进不了正规桌面协议（HDC/HDP）的排查

**症状**：本地 HDC 客户端连不上（"虚拟机尚未就绪" 6039 / 连接失败），只能退回 VNC 才能进桌面。HDAgent 日志反复：

```
Make session ready fail, create socket fail, error:-1013
StartPreconnectFunc: Preconnect failed, code:28104003
The user(kantaoc) logined in to the VNC, needs to log out of the session or restart the desktop
IsVaildSession: login module is null, only HDAgent restart, no need to rebuild session
```

**根因**（2026-10 排查确认）：HDAgent 的 HDP pre-connect 需要一个由**用户图形会话**创建的 unix socket。那个 socket 由 GNOME 登录会话的 autostart 拉起：

```
/etc/xdg/autostart/hdpdaemon.desktop → hdpdaemon.sh → hdpdaemon20
```

一旦当前会话是 **VNC 建的**（不是正规 HDC 登录），或会话里 `hdpdaemon20` 没起来 / 会话状态脏了，HDAgent 就拒绝 HDP 接管 → 客户端回退 VNC。

**修复**（按风险从低到高，全程不碰 frpc/sing-box/keepalive，VPN 不断）：

| 级别 | 操作 | 何时用 |
|---|---|---|
| 1 | `sudo bash vdi-hdc-repair.sh --light` | 注销当前 VNC 会话，清"会话被 VNC 占住"状态，然后重新正规登录 |
| 2 | `sudo bash vdi-hdc-repair.sh --agent` | kill HDAgent（华为 monitor 自动重拉重注册），清 `IsVaildSession null` 空转 |
| 3 | `sudo bash vdi-hdc-repair.sh --all` | 1+2 都做（推荐先跑） |
| 4 | `sudo bash vdi-hdc-repair.sh --reboot` | 重启 VDI（最后手段，最彻底；frpc/sing-box/keepalive 都开机自启，起来后自动回来） |

跑完 1-3 后：**用正规 HDC 客户端（华为 Workspace，走 HDP/流媒体协议，不要选 VNC/备用）重新登录**。正规登录会经 gdm 建会话 + autostart 拉起 `hdpdaemon20`，HDP 通道即通，不再退回 VNC。

> ⚠️ 关键：登录时务必走正规 HDC 协议。若你客户端默认连的还是 VNC，等于没换，必须手动切到 HDP/流媒体。

**如果本地线路把 HDP 媒体面（UDP）丢了、又退回 VNC**：那是本地出口到华为云控制面的线路问题（和翻墙根因同源），不是 VDI 的问题。此时可走 frpc 隧道把 HDP 媒体面也转过去（跟翻墙同一入口），或继续用 VNC + keepalive 维持 24h。

## bind mount 持久化（重启后自动恢复）

`/etc/hdpserver/policy.xml` 的 bind mount（覆盖 HDAgent 10 分钟锁屏/断连策略）**重启后不会自动恢复**。三种做法，按推荐顺序：

1. **fstab 持久化**（最稳，开机自动挂）：
   ```
   /home/kantaoc/keep_alive/policy_fake.xml /etc/hdpserver/policy.xml none bind 0 0
   ```
   加到 `/etc/fstab`，重启自动生效。
2. **heal.py 自动重挂**（已内置）：非 `--check` 模式下检测到未挂载就 `sudo mount --bind` 恢复。
3. **vdi-hdc-repair.sh 兜底**：每次跑修复时会重挂 bind mount。

推荐 **1 + 2 双保险**：fstab 负责开机，heal.py 负责"挂载被意外弄掉"。

## VPN 自愈巡检（vpn-watchdog timer）

让 frpc/sing-box（翻墙出口隧道）**24h 有兜底**：每 3 分钟 systemd timer 自动跑一次
`vpn-watchdog.sh`，发现某段掉了就自动拉起并记日志。纯系统级，不依赖桌面会话。

**巡检项**：
| 项 | 判定 | 自愈动作 |
|---|---|---|
| frpc | `is-active` 非 active，或 frpc 日志末行是 disconnected/EOF/dial fail | `systemctl restart frpc` |
| sing-box | `is-active` 非 active，或 443 未监听 | `systemctl restart sing-box` |
| bind mount | `/etc/hdpserver/policy.xml` 未挂载 | `mount --bind policy_fake.xml` |

**部署**（`vdi-bootstrap.sh` 会一并装；或手动）：
```bash
sudo install -m 755 vpn-watchdog.sh /home/kantaoc/keep_alive/
sudo install -m 644 vdi-vpn-watchdog.service /etc/systemd/system/
sudo install -m 644 vdi-vpn-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vdi-vpn-watchdog.timer
```

**日志**：`/home/kantaoc/keep_alive/vpn-watchdog.log`（每轮一行，heal.py 会审计最近状态）

**为什么 3 分钟而不是 15 分钟**：frpc/sing-box 是 VPN 命脉，挂太久影响翻墙；
3 分钟是"自愈快"和"巡检开销"的平衡点。

### ⚠️ 关键坑（2026-10-28 踩到，务必避免再犯）

**在 6022 SSH 通道里跑 `vpn-watchdog.sh`（或任何会重启 frpc 的操作），会掐断自己。**
6022 隧道就是 frpc 建的——巡检 `restart frpc` 的瞬间，我所在的这条 SSH 会断，
脚本后半段（sing-box / bind mount 检查）跑不到一半就中断。

正确姿势：
1. **timer 自动触发时**没问题（没有外部 SSH 依赖），让它自己跑。
2. **手动验证时**：先确认 frpc 健康，再 `systemctl stop frpc` 测试自愈，
   但要**准备好 6022 会断**——断后等 timer（≤3min）自愈 frpc，再重连验证。
   不要一边 `stop frpc` 一边指望同一条 SSH 跑完整个脚本。

**frpc `systemctl stop` 后没有别的恢复路径**：6022 断了就只能等 timer 下一轮
（≤3min）或 VDI 重启。这就是为什么 timer 不能设太长。

## 端口对照

| 服务 | 端口 | 说明 |
|------|------|------|
| sing-box VLESS-Reality | 443 | FRP 转发到远程 9443 |
| HDAgent | 6781 | 华为管理端口 |
| FRP | 7000 | frpc 连 frps |
| VNC | 5900+ | VNC 登录 |
