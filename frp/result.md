# FRP 部署输出记录

> 历史文件，记录历次部署的实际输出。当前生效的入口是**国内广州 ECS 8.134.207.151**。

---

## 当前生效：国内 ECS frps（2026-10-27 部署）

```
==========================================
  frps 部署完成！
==========================================
  版本:           v0.63.0
  实例:           i-7xv2n6228pgnp9eppo1q (阿里云广州)
  公网 IP:        8.134.207.151
  二进制目录:     /opt/frp -> /opt/frp_0.63.0_linux_amd64
  配置目录:       /etc/frp
  配置文件:       /etc/frp/frps.toml
  绑定端口:       7000/TCP
  Token:          wzlkzjioM9TBgDv2MfDGL12FZgjDdguN
  Dashboard:      http://8.134.207.151:7500 (admin / gzfrps2026)
  监听端口:       7000 / 7500 / 9443 / 6022
  安全组:         sg-7xv2n6228pgnr4hywu4w 已放行 7000/9443/6022/7500 (0.0.0.0/0)

  ⚠ 国内 ECS 还跑着 nginx + 多个 node web 服务 (80/443/3001/3010/8081)，
     frps 部署只加 7000/7500/9443/6022，不碰现有 web 服务。
==========================================
```

---

## 当前生效：华为云 VDI frpc（2026-10-27 改指向）

```
==========================================
  VDI frpc 部署完成！
==========================================
  版本:           v0.63.0
  二进制目录:     /opt/frp -> /opt/frp_0.63.0_linux_amd64
  配置目录:       /etc/frp
  配置文件:       /etc/frp/frpc.toml
  服务端:         8.134.207.151:7000   ← 国内 ECS 入口
  Token:          wzlkzjioM9TBgDv2MfDGL12FZgjDdguN

  代理规则:
    - vdi-singbox tcp://127.0.0.1:443 -> 8.134.207.151:9443
    - ssh         tcp://127.0.0.1:22  -> 8.134.207.151:6022

  frps 侧确认:
    new proxy [vdi-singbox] type [tcp] success
    new proxy [ssh] type [tcp] success

  常用命令:
    查看状态:  systemctl status frpc
    查看日志:  journalctl -u frpc -f
    重启:      systemctl restart frpc
==========================================
```

---

## 本地 Hiddify / NeoBox 节点（当前生效）

家里 / 手机 Hiddify、NeoBox 添加节点用下面的 VLESS 链接一键导入
（IP 是**国内 ECS 8.134.207.151**，端口 9443，出口走华为云 VDI）：

```
vless://855c3ac0-cd8e-465e-a743-a48d9f8012e1@8.134.207.151:9443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=iu5wVNmSuIeGk67J_Ygx5fK4f982sBBP4bkjVjEjQ18&sid=2bd464d7&type=tcp#VDI-出口(国内ECS)
```

> ⚠️ UUID/公钥/ShortID/SNI 全沿用 VDI sing-box 的，只有 IP 从 8.216.46.75 换成 8.134.207.151。

---

## （历史·已弃用）阿里云东京 frps 8.216.46.75

> 2026-07-13 初始部署，2026-10-27 因本地出口线路到 8.216 段被运营商 DROP 弃用。
> 留档仅作历史参考，**不要再用 8.216.46.75 做节点**。

```
frps: 8.216.46.75:7000 / 8443 / 9443 / 6000  (东京，已不用)
VDI sing-box: vless://855c3ac0-...@94.74.88.130:443 (华为云直连，无公网入口，不可达)
```
