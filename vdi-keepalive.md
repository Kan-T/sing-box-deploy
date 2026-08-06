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
2. **重启后 bind mount 丢失** — 需要重新挂载（heal.py 会提示）
3. **VNC 不帮助活跃检测** — VNC 走 X11 协议，不走 HDP

## 端口对照

| 服务 | 端口 | 说明 |
|------|------|------|
| sing-box VLESS-Reality | 443 | FRP 转发到远程 9443 |
| HDAgent | 6781 | 华为管理端口 |
| FRP | 7000 | frpc 连 frps |
| VNC | 5900+ | VNC 登录 |
