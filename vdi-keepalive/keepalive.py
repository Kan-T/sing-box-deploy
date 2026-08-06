#!/usr/bin/env python3
"""
VDI Keepalive v13 — 最小化稳定版
所有可能卡死的操作都放在子进程+超时保护下。
"""
import os, sys, time, signal, subprocess, threading
from datetime import datetime

LOG = "/home/kantaoc/keep_alive/keepalive.log"
INTERVAL = 45
KBD_PY = """import evdev,time
k=evdev.InputDevice('/dev/input/event1')
for kc in [42,29]:
 k.write(evdev.ecodes.EV_KEY,kc,1);k.write(evdev.ecodes.EV_SYN,0,0);time.sleep(0.02)
 k.write(evdev.ecodes.EV_KEY,kc,0);k.write(evdev.ecodes.EV_SYN,0,0)
"""
MS_PY = """import evdev
m=evdev.InputDevice('/dev/input/event3')
m.write(evdev.ecodes.EV_REL,evdev.ecodes.REL_X,5);m.write(evdev.ecodes.EV_SYN,0,0)
"""

def log(msg):
    with open(LOG,"a") as f:
        f.write(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}\n")

def safe_run(script, timeout=4):
    try:
        p = subprocess.Popen([sys.executable,"-c",script],
                            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        p.wait(timeout=timeout)
        return p.returncode
    except subprocess.TimeoutExpired:
        p.kill(); p.wait(); return -1
    except: return -2

def evdev_pulse():
    safe_run(KBD_PY)
    safe_run(MS_PY)

def xclip_pulse():
    try:
        subprocess.run(["xclip","-selection","clipboard","-i"],
                      input=f"vk{int(time.time())}\n".encode(),
                      capture_output=True,timeout=3)
    except: pass

def xset_pulse():
    try:
        subprocess.run(["xset","s","off"],capture_output=True,timeout=2)
        subprocess.run(["xset","-dpms"],capture_output=True,timeout=2)
        subprocess.run(["xdg-screensaver","reset"],capture_output=True,timeout=2)
    except: pass

def clip_worker():
    while True:
        xclip_pulse()
        for _ in range(30):
            time.sleep(1)

if __name__ == "__main__":
    open(LOG,"w").close()
    log("="*50)
    log("VDI Keepalive v13 (最小化)")

    try: subprocess.Popen(["systemd-inhibit","--what=idle:sleep",
          "--who=vdi-keepalive","--why=keep VDI active",
          "--mode=block","sleep","infinity"])
    except: pass
    try: subprocess.Popen(["gnome-session-inhibit","--inhibit","idle",
          "--inhibit","suspend","--app-id","vdi-keepalive",
          "--reason","keep VDI alive","sleep","infinity"])
    except: pass
    try: subprocess.run(["xdg-screensaver","suspend",str(os.getpid())],timeout=3)
    except: pass

    threading.Thread(target=clip_worker,daemon=True).start()
    log("clipboard worker started")

    counter = 0
    while True:
        try:
            counter += 1
            signal.alarm(10)
            evdev_pulse()
            xset_pulse()
            signal.alarm(0)
            log(f"#{counter}")
        except TimeoutError:
            log(f"#{counter} ⚠️ 超时")
        except Exception as e:
            log(f"#{counter} 错误: {e}")

        for _ in range(INTERVAL):
            time.sleep(1)
