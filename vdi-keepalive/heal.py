#!/usr/bin/env python3
"""
VDI Healthcheck — 诊断并自动修复 keepalive + sing-box + bind mount。
用法：
    python3 ~/keep_alive/heal.py          # 诊断 + 自动修复
    python3 ~/keep_alive/heal.py --check  # 仅诊断，不修复
"""
import os, sys, time, subprocess, ctypes, re, json
from datetime import datetime

LOG = "/home/kantaoc/keep_alive/heal.log"
POLICY_FAKE = "/home/kantaoc/keep_alive/policy_fake.xml"
POLICY_REAL = "/etc/hdpserver/policy.xml"
SB_CONFIG = "/etc/sing-box/config.json"
KB = "/dev/input/event1"
MS = "/dev/input/event3"

# ============================================================
# Report system
# ============================================================
issues = []
fixes = []

def log(msg):
    with open(LOG, "a") as f:
        f.write(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}\n")
    print(msg)

def issue(item, status, detail):
    issues.append((item, status, detail))
    icon = "✅" if status == "OK" else "⚠️" if status == "WARN" else "❌"
    print(f"  {icon} {item}: {detail}")

def fix_needed(desc, cmd_list, requires_sudo=False):
    fixes.append((desc, cmd_list, requires_sudo))

# ============================================================
# Helpers
# ============================================================
def disp():
    try:
        r = subprocess.run(["ps", "aux"], capture_output=True, text=True, timeout=5)
        for l in r.stdout.split("\n"):
            if "Xvfb" in l and "fa" in l:
                m = re.search(r'Xvfb\s+:(\d+)', l)
                if m: return m.group(1)
    except: pass
    return None

# ============================================================
# 1. System basics
# ============================================================
def check_system():
    print("\n--- 系统基础 ---")
    d = disp()
    issue("Xvfb display", "OK" if d else "FAIL",
          f":{d}" if d else "Xvfb 未运行")
    issue("系统 uptime", "OK",
          subprocess.run(["uptime", "-p"], capture_output=True, text=True).stdout.strip())

# ============================================================
# 2. Keepalive check
# ============================================================
def check_keepalive():
    print("\n--- keepalive ---")

    # Process
    proc = subprocess.run(["pgrep", "-f", "keep_alive/keepalive.py"],
                         capture_output=True, text=True)
    pids = proc.stdout.strip().split()
    n = len(pids)
    if n >= 1:
        issue("进程", "OK" if n == 1 else "WARN",
              f"{n} 个进程 (PID: {', '.join(pids)})")
        if n > 1:
            fix_needed("杀掉多余 keepalive 进程",
                       [["kill"] + pids[1:]])
    else:
        issue("进程", "FAIL", "keepalive 未运行")
        fix_needed("启动 keepalive", [["systemctl", "--user", "start", "vdi-keepalive"]])

    # Service
    r = subprocess.run(["systemctl", "--user", "is-active", "vdi-keepalive"],
                       capture_output=True, text=True)
    active = r.stdout.strip() == "active"
    issue("systemd service", "OK" if active else "FAIL",
          "active" if active else r.stdout.strip())

    # Log
    try:
        with open("/home/kantaoc/keep_alive/keepalive.log") as f:
            content = f.read()
        pulses = re.findall(r'#(\d+).*?idle=(\d+)ms', content)
        # 检查当前进程是新启动的（时长 < 120 秒），新日志可能还没脉冲
        since = subprocess.run(["ps", "-o", "etime=", "-p", pids[0] if pids else "1"],
                              capture_output=True, text=True).stdout.strip()
        is_new = False
        if since:
            parts = since.strip().split(":")
            if len(parts) == 2:
                is_new = int(parts[0]) < 2 and int(parts[1]) < 120
            elif len(parts) == 1:
                is_new = int(since.strip()) < 120

        if pulses:
            last_n, last_idle = pulses[-1]
            issue("最后一次脉冲", "OK" if int(last_idle) < 3000 else "WARN",
                  f"#{last_n} idle={last_idle}ms")
        elif is_new:
            issue("脉冲", "OK", "刚启动，等待首个脉冲中")
        else:
            issue("脉冲", "FAIL", "日志中没有脉冲记录")
    except: issue("日志", "FAIL", "无法读取")

    # Pulldate
    since = subprocess.run(["ps", "-o", "etime=", "-p", pids[0] if pids else "1"],
                          capture_output=True, text=True).stdout.strip()
    if since:
        issue("运行时间", "OK", since)

# ============================================================
# 3. Bind mount check
# ============================================================
def check_bind_mount():
    print("\n--- HDAgent policy ---")
    r = subprocess.run(["mount"], capture_output=True, text=True, timeout=5)
    mounted = POLICY_REAL in r.stdout
    issue("bind mount", "OK" if mounted else "FAIL",
          "生效" if mounted else "未挂载，HDAgent 10分钟锁屏策略生效")

    if not mounted and os.path.exists(POLICY_FAKE):
        # 自动恢复（非 --check 模式下）
        if "--check" not in sys.argv:
            sudo_test = subprocess.run(["sudo", "-n", "true"], capture_output=True, text=True, timeout=5)
            if sudo_test.returncode == 0:
                r = subprocess.run(["sudo", "mount", "--bind", POLICY_FAKE, POLICY_REAL],
                                   capture_output=True, text=True, timeout=10)
                if r.returncode == 0:
                    issue("bind mount", "FIXED", "已自动挂载")
                else:
                    issue("bind mount", "FAIL", f"sudo mount 失败: {r.stderr.strip()}")
            else:
                issue("bind mount", "WARN", "未挂载且 sudo 不可用，需手动运行：")
                print(f"  sudo mount --bind {POLICY_FAKE} {POLICY_REAL}")
        else:
            issue("bind mount", "WARN", "未挂载（--check 模式不自动修复）")
    elif not mounted:
        issue("bind mount", "FAIL", "policy_fake.xml 不存在")
        print("\n  ❌ 策略文件缺失！请重新创建 policy_fake.xml")

    if os.path.exists(POLICY_REAL):
        r2 = subprocess.run(["grep", "-E", "AutoDisconnect|AutoLock", POLICY_REAL],
                           capture_output=True, text=True)
        for line in r2.stdout.strip().split("\n"):
            if "AutoDisconnect>1" in line or "AutoLock>1" in line:
                issue("本地策略", "WARN",
                      f"仍有 {line.strip()} — 需要 bind mount 覆盖")
                break

    # HDAgent
    r3 = subprocess.run(["pgrep", "HDAgent"], capture_output=True, text=True)
    issue("HDAgent", "OK" if r3.stdout.strip() else "FAIL",
          f"PID {r3.stdout.strip()}" if r3.stdout.strip() else "未运行")

# ============================================================
# 4. Terminal window check
# ============================================================
def check_terminal():
    print("\n--- 终端窗口 ---")
    r = subprocess.run(["ps", "aux"], capture_output=True, text=True, timeout=5)
    has_term = "watch.sh" in r.stdout and "bash" in r.stdout
    issue("watch.sh 窗口", "OK" if has_term else "WARN",
          "运行中" if has_term else "未运行（不影响核心功能，但建议重启 keepalive）")

# ============================================================
# 5. Sing-box check
# ============================================================
def check_singbox():
    print("\n--- sing-box ---")

    # Process
    r = subprocess.run(["pgrep", "sing-box"], capture_output=True, text=True)
    pids = r.stdout.strip().split()
    issue("进程", "OK" if pids else "FAIL",
          f"PID {','.join(pids)}" if pids else "未运行")

    if not pids:
        fix_needed("启动 sing-box",
                   [["systemctl", "start", "sing-box"]],
                   requires_sudo=True)
        return

    # Service
    r2 = subprocess.run(["systemctl", "is-active", "sing-box"], capture_output=True, text=True)
    active = r2.stdout.strip() == "active"
    issue("systemd service", "OK" if active else "FAIL", r2.stdout.strip())
    if not active:
        fix_needed("重启 sing-box",
                   [["systemctl", "restart", "sing-box"]],
                   requires_sudo=True)

    # Port 443
    r3 = subprocess.run(["ss", "-tlnp"], capture_output=True, text=True)
    port_lines = [l for l in r3.stdout.split("\n") if "*:443" in l]
    on_port = len(port_lines) > 0
    issue("端口 443", "OK" if on_port else "FAIL",
          "sing-box 在监听" if on_port else "sing-box 未监听 443")

    # Config syntax
    r4 = subprocess.run(["sing-box", "check", "-c", SB_CONFIG],
                       capture_output=True, text=True)
    config_ok = r4.returncode == 0
    issue("配置语法", "OK" if config_ok else "FAIL",
          "通过" if config_ok else r4.stderr.strip()[:100])

    if not config_ok and "legacy DNS" in r4.stderr:
        # Config has the dns section, need to remove it
        fix_needed("修复 sing-box DNS（移除 dns 段）",
                   [["sed", "-i", '/"dns": {/,/^  }/d', SB_CONFIG]],
                   requires_sudo=True)
        fix_needed("重启 sing-box",
                   [["systemctl", "restart", "sing-box"]],
                   requires_sudo=True)

    # hosts entry for www.apple.com
    r5 = subprocess.run(["grep", "-q", "www.apple.com", "/etc/hosts"])
    issue("/etc/hosts apple.com", "OK" if r5.returncode == 0 else "FAIL",
          "已添加" if r5.returncode == 0 else "缺少，REALITY 握手会失败")
    if r5.returncode != 0:
        fix_needed("添加 www.apple.com 到 /etc/hosts",
                   [["bash", "-c",
                     "echo '23.200.180.246\twww.apple.com' >> /etc/hosts"]],
                   requires_sudo=True)

    # Journal errors
    r6 = subprocess.run(["journalctl", "-u", "sing-box", "-n", "20", "--no-pager"],
                       capture_output=True, text=True)
    errors = re.findall(r'(?i)(error|invalid|fail)', r6.stdout)
    issue("日志错误", "OK" if len(errors) < 3 else "WARN",
          f"最近 20 行无异常" if len(errors) < 3 else f"发现 {len(errors)} 条错误")

    # Startup tracking
    r7 = subprocess.run(["ps", "-o", "lstart=", "-p", pids[0]],
                       capture_output=True, text=True)
    issue("运行时间", "OK", r7.stdout.strip())

# ============================================================
# 5b. frpc 隧道（反向 SSH 6022 / VLESS 出口）
# ============================================================
def check_frps_tunnel():
    print("\n--- frpc 隧道 (国内 ECS 反向通道) ---")
    # frpc 是 VDI 上把 22→6022、443→9443 反向映射到国内 ECS frps 的服务，
    # 本地运维进 VDI / 翻墙出口都依赖它。挂了就全断。
    r = subprocess.run(["systemctl", "is-active", "frpc"],
                       capture_output=True, text=True, timeout=5)
    active = r.stdout.strip() == "active"
    issue("frpc service", "OK" if active else "FAIL",
          "active（隧道存活）" if active else r.stdout.strip())
    if not active:
        fix_needed("重启 frpc（恢复 6022 反向 SSH + 9443 出口隧道）",
                   [["systemctl", "restart", "frpc"]],
                   requires_sudo=True)
        return

    # frpc 是否真的连上 frps（看 journal 最近有没有 login success / 断线）
    rj = subprocess.run(["journalctl", "-u", "frpc", "-n", "60", "--no-pager"],
                        capture_output=True, text=True, timeout=5)
    last = "\n".join(rj.stdout.split("\n")[-60:])
    has_login = "login to server success" in last
    has_proxy = "start proxy success" in last
    # 最近的失败/断开
    broken = any(k in last.split("\n")[-10:] for k in
                 ("disconnected", "EOF", "token in login doesn't match", "dial"))
    if has_login and has_proxy:
        issue("frpc 隧道状态", "OK" if not broken else "WARN",
              "已注册 vdi-singbox + ssh 代理" + ("（近期有断线）" if broken else ""))
    else:
        issue("frpc 隧道状态", "WARN", "未见 login/proxy success，可能未连上 frps")
        fix_needed("重启 frpc 重建隧道",
                   [["systemctl", "restart", "frpc"]],
                   requires_sudo=True)

# ============================================================
# 5c. HDP 会话 agent（hdpdaemon20）+ 正规协议连接
# ============================================================
def check_hdp_session():
    print("\n--- HDP 会话 (正规协议, 非 VNC) ---")
    # hdpdaemon20 由 GNOME 登录会话的 autostart 拉起，是 HDAgent 建 HDP
    # 会话 socket 的前提。缺它 = pre-connect 永远 code:28104003，只能 VNC。
    r = subprocess.run(["pgrep", "-f", "hdpdaemon20"], capture_output=True, text=True)
    pids = [p for p in r.stdout.split() if p.strip()]
    issue("hdpdaemon20", "OK" if pids else "WARN",
          f"运行中 (PID {pids[0]})" if pids else "未运行——正规 HDP 协议连接会失败(只能VNC)。确认你是用正规 HDC 客户端登录, 不是 VNC。")

    # HDP 会话 agent 的 unix socket（建在 /run/user/<uid>/）
    r2 = subprocess.run(["ls", "/run/user"], capture_output=True, text=True)
    uid_dirs = [d for d in r2.stdout.split() if d.isdigit()]
    hdp_sock = False
    for d in uid_dirs:
        rr = subprocess.run(["sh", "-c", f"ls /run/user/{d}/ 2>/dev/null | grep -ciE 'hdp|gina'"],
                            capture_output=True, text=True)
        try:
            if int(rr.stdout.strip() or 0) > 0:
                hdp_sock = True
        except ValueError:
            pass
    issue("HDP 会话 socket", "OK" if hdp_sock else "WARN",
          "已建立" if hdp_sock else "未见（会话侧 HDP 未就绪）")

    # HDAgent 最近日志是否还在刷 28104003 / IsVaildSession null（坏态）
    r3 = subprocess.run(["sh", "-c",
        "F=$(ls -t /var/log/hdplog/serverlog/HDAgent/HDAgent-*.log 2>/dev/null | head -1); "
        "[ -n \"$F\" ] && strings -a \"$F\" 2>/dev/null | grep -cE '28104003|IsVaildSession.*null' || echo 0"],
        capture_output=True, text=True)
    bad = 0
    try:
        bad = int(r3.stdout.strip() or 0)
    except ValueError:
        pass
    if bad == 0:
        issue("HDAgent 日志", "OK", "无 28104003/坏态记录")
    else:
        issue("HDAgent 日志", "FAIL", f"有 {bad} 条 pre-connect 失败/坏态。若持续, 参考 vdi-hdc-repair.sh（注销会话+重启HDAgent+重新正规登录, 或重启VDI）")

# ============================================================
# 5d. VPN 自愈巡检 (vpn-watchdog timer)
# ============================================================
def check_vpn_watchdog():
    print("\n--- VPN 自愈巡检 (vpn-watchdog) ---")
    r = subprocess.run(["systemctl", "is-active", "vdi-vpn-watchdog.timer"],
                       capture_output=True, text=True, timeout=5)
    active = r.stdout.strip() == "active"
    issue("watchdog timer", "OK" if active else "WARN",
          "每 3min 巡检 frpc/sing-box/bind mount" if active
          else "未启用（VPN 掉线不会自愈；sudo systemctl enable --now vdi-vpn-watchdog.timer）")

    r2 = subprocess.run(["tail", "-n", "6", "/home/kantaoc/keep_alive/vpn-watchdog.log"],
                        capture_output=True, text=True, timeout=5)
    tail = r2.stdout.strip()
    bad = ("❌" in tail) or ("恢复失败" in tail)
    if tail:
        issue("最近巡检", "WARN" if bad else "OK",
              "发现异常自愈项（看 vpn-watchdog.log）" if bad else "上次巡检正常")
    else:
        issue("最近巡检", "WARN", "无日志（timer 可能未跑过）")


    if not fixes:
        print("\n✅ 无修复需要")
        return

    print(f"\n--- 修复 ({len(fixes)} 项) ---")
    for desc, cmds, needs_sudo in fixes:
        if needs_sudo:
            full = " && ".join(" ".join(c) for c in cmds)
            print(f"\n  {'='*50}")
            print(f"  ⚠️  {desc}")
            print(f"  {'='*50}")
            print(f"  复制运行: sudo {full}")
            print(f"  {'='*50}\n")
        else:
            for c in cmds:
                r = subprocess.run(c, capture_output=True, text=True, timeout=10)
                status = "OK" if r.returncode == 0 else f"失败 ({r.stderr.strip()[:60]})"
                print(f"  ✅ {' '.join(c)} → {status}")
                log(f"FIX: {' '.join(c)} → {status}")

    if any(s for _, _, s in fixes if s):
        print("\n⚠️  以上 sudo 命令执行后请重新运行 heal.py 确认。\n")

# ============================================================
# 7. Summary
# ============================================================
def summary():
    print("\n" + "=" * 55)
    print("  诊断摘要")
    print("=" * 55)
    o = sum(1 for _, s, _ in issues if s == "OK")
    w = sum(1 for _, s, _ in issues if s == "WARN")
    f = sum(1 for _, s, _ in issues if s == "FAIL")
    print(f"  检查项: {len(issues)} | ✅ {o} | ⚠️ {w} | ❌ {f}")
    print(f"  修复项: {len(fixes)}")
    print(f"  日志: {LOG}")
    print()

    if o == len(issues) and not fixes:
        print("  一切正常 ✅")
    elif f > 0:
        print("  需要修复 ❌")
    else:
        print("  基本正常 ⚠️")

# ============================================================
# Main
# ============================================================
if __name__ == "__main__":
    only_check = "--check" in sys.argv
    open(LOG, "w").close()

    print("=" * 55)
    print(f"  VDI Healthcheck {'(仅诊断)' if only_check else '(诊断+修复)'}")
    print(f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 55)

    check_system()
    check_keepalive()
    check_bind_mount()
    check_terminal()
    check_singbox()
    check_frps_tunnel()
    check_hdp_session()
    check_vpn_watchdog()

    summary()

    if not only_check:
        apply_fixes()

    sys.exit(0 if issues.count(("", "FAIL", "")) == 0 else 1)
