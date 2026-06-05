# WireGuard Home VPN

让公司电脑的所有流量经由家里的 macOS 出网。

## 架构

```
公司电脑（客户端）
    │
    │  WireGuard 加密隧道（UDP 51820）
    │
家用路由器（端口映射 51820 → Mac）
    │
家里 Mac（服务端）
    ├─ WireGuard 解密
    ├─ IP 转发（net.inet.ip.forwarding）
    ├─ pfctl NAT（替换源地址）
    └─── 家用宽带 ─── 互联网
```

## 前置条件

- 家里的 Mac：macOS 12+，已安装 [Homebrew](https://brew.sh)
- 家用路由器：支持端口映射（port forwarding）
- 家里有固定公网 IP（或已配置好 DDNS）

---

## 使用方法

### 第一步：在家里 Mac 上初始化服务端

```bash
sudo bash setup-server.sh
```

脚本自动完成：

1. 安装 `wireguard-tools`（通过 Homebrew）
2. 生成服务端 Curve25519 密钥对，存储在 `$(brew --prefix)/etc/wireguard/`
3. 自动检测物理出口网卡（排除 Surge 等软件产生的虚拟 utun 接口）
4. 生成 `wg0.conf`，PostUp/PostDown 为单行命令（wg-quick 不支持 `\` 换行）
5. 向 `/etc/pf.conf` 注册 `wireguard` anchor（首次运行自动备份原文件）
6. 在 `/Library/LaunchDaemons/` 注册服务，开机自动启动

### 第二步：在家用路由器上配置端口映射

将 **UDP 51820** 端口转发到家里 Mac 的内网 IP。

> 具体操作因路由器品牌而异，通常在「虚拟服务器」或「端口映射」菜单下设置。  
> Mac 内网 IP 在系统设置 → 网络 里查看，或运行 `ipconfig getifaddr en0`。

端口映射字段说明：

| 字段 | 值 |
|------|----|
| 协议 | UDP |
| 外部端口 | 51820 |
| 内部 IP | Mac 的内网 IP |
| 内部端口 | 51820 |

### 第三步：生成公司电脑的客户端配置

```bash
sudo bash add-client.sh work-macbook <家里的公网IP或域名>
```

脚本自动完成：

1. 生成客户端密钥对
2. 分配 VPN 子网 IP（`10.13.13.x`，自动递增）
3. 生成 `clients/work-macbook/work-macbook.conf`（含 `MTU = 1280`，避免大包被丢弃）
4. 热更新运行中的 WireGuard（无需重启）
5. 若已安装 `qrencode`，打印二维码供手机扫码导入

### 第四步：在公司电脑上导入配置

| 系统 | 方式 |
|------|------|
| macOS / Windows | 安装 [WireGuard App](https://www.wireguard.com/install/)，导入 `.conf` 文件 |
| Linux | `sudo wg-quick up /path/to/work-macbook.conf` |
| iOS / Android | 安装 WireGuard App，扫描二维码 |

启用后，`AllowedIPs = 0.0.0.0/0, ::/0` 表示**全部流量**（IPv4 + IPv6）都经 VPN 隧道回家出网。

---

## 验证

连上 VPN 后，在公司电脑上：

```bash
# 出口 IP 应该显示家里的公网 IP
curl https://ifconfig.me

# ping VPN 网关
ping 10.13.13.1

# ping 外网（验证转发和 NAT）
ping 8.8.8.8
```

在服务端查看连接状态：

```bash
sudo wg show
# 能看到 peer、握手时间、流量统计
```

---

## 原理说明

### WireGuard 协议

- 基于 **UDP**，延迟低，NAT 穿透友好
- 加密套件固定：Curve25519（密钥交换）+ ChaCha20-Poly1305（加密）+ BLAKE2s（哈希）
- 无协商过程，没有"配置错误"的空间，攻击面极小
- 代码量约 4000 行，经过独立安全审计（2019 年 Trail of Bits）
- 2020 年合并进 Linux 内核 5.6，macOS 上使用用户态的 `wireguard-go`

### TUN 虚拟网卡

`wg-quick up wg0` 在系统里创建一张虚拟网卡（macOS 上名为 `utun*`）。  
应用发出的包经路由表送往 `utun*`，WireGuard 加密后从真实网卡发出；  
收到的 UDP 包解密后写回 `utun*`，对上层应用透明。

### IP 转发

```bash
sysctl -w net.inet.ip.forwarding=1
```

默认 macOS 只转发目标是本机的包，开启后内核会转发"路过的包"，  
让公司电脑的流量能经由 Mac 送往互联网。

### pfctl NAT

公司电脑的 VPN IP（`10.13.13.x`）是私有地址，互联网不认识。  
NAT 规则将出包的源地址替换为 Mac 自己的 IP：

```
原始包：src=10.13.13.2  dst=8.8.8.8
经 NAT：src=192.168.1.4  dst=8.8.8.8   ← 互联网看到的
回包：  src=8.8.8.8     dst=192.168.1.4
还原：  src=8.8.8.8     dst=10.13.13.2 ← 送回给公司电脑
```

pfctl 通过连接状态表自动完成回包还原，无需手动干预。

### MTU

WireGuard 封装会增加约 60 字节的头部开销。  
客户端配置默认设置 `MTU = 1280`（保守值），避免大包超出物理网卡 MTU（1500）被丢弃。  
ICMP ping 包小，不受影响；TCP/HTTPS 的大包如不设置 MTU 容易出现"能 ping 通但无法浏览网页"的现象。

### LaunchDaemon（开机自启）

注册在 `/Library/LaunchDaemons/`，系统启动时以 root 身份运行，  
用户未登录时也会自动拉起 WireGuard。

---

## 与 Surge 的兼容性

如果家里 Mac 同时运行了 Surge，需要额外配置，否则 WireGuard 响应包会被 Surge 劫持。

### 问题原因

Surge Enhanced Mode（增强模式）会接管系统路由表，所有出站流量都经过 Surge 的虚拟接口。  
WireGuard 向公司电脑发回包时，包被 Surge 拦截，**源地址被替换为 Surge 的虚拟 IP（`198.18.0.1`）**，  
公司电脑收到后认不出这个地址，握手失败。

> `PROCESS-NAME,wireguard-go,DIRECT` 规则对 UDP 无效——Surge 处理 UDP 时无论规则是否 DIRECT，仍使用虚拟 IP 转发。

### 解决方案

在 Surge 配置文件的 `[General]` 中，将公司电脑所在的 IP 段加入 `tun-excluded-routes`：

```ini
[General]
tun-excluded-routes = 117.133.0.0/16
```

这条配置让 Surge 对目标为该 IP 段的流量不走 TUN，WireGuard 的响应包直接从物理网卡（`en0`）发出，源地址正常。

加载配置后在 Mac 上用 tcpdump 验证：

```bash
sudo tcpdump -ni en0 udp port 51820
# 回包源地址应为 192.168.1.x，而非 198.18.0.1
```

### 各模式行为汇总

| Surge 模式 | 不做额外配置 | 加 tun-excluded-routes |
|-----------|------------|----------------------|
| 仅系统代理 | ✅ 正常工作 | 不需要 |
| 增强模式 | ❌ 回包源 IP 错误，握手失败 | ✅ 正常工作 |
| 两者同时开启 | ❌ 同增强模式 | ✅ 正常工作 |

> **注意**：`tun-excluded-routes` 是按目标 IP 排除，如果公司 IP 段变化需要手动更新。

---

## 服务管理

### 停止服务

```bash
# 临时关闭（重启 Mac 后自动恢复）
sudo wg-quick down wg0

# 彻底关闭（取消开机自启 + 停止服务）
sudo wg-quick down wg0
sudo launchctl unload -w /Library/LaunchDaemons/com.wireguard.wg0.plist
```

### 启动服务

```bash
# 立即启动
sudo wg-quick up wg0

# 重新注册开机自启（彻底关闭后恢复用）
sudo launchctl load -w /Library/LaunchDaemons/com.wireguard.wg0.plist
```

### 确认当前状态

```bash
sudo wg show
# 有输出 → 运行中
# 提示 "Unable to access interface" → 已停止
```

---

## 常用命令

```bash
# 查看 VPN 连接状态及流量统计
sudo wg show

# 重启 WireGuard
sudo wg-quick down wg0 && sudo wg-quick up wg0

# 查看日志
tail -f /var/log/wireguard-wg0.log
tail -f /var/log/wireguard-wg0.err

# 查看 pfctl NAT 规则是否生效
sudo pfctl -a wireguard -s nat

# 抓包调试（看 51820 端口流量）
sudo tcpdump -ni en0 udp port 51820
```

---

## 故障排查

### 握手一直失败（Handshake did not complete）

按顺序检查：

1. **服务端是否在运行**：`sudo wg show`，有输出说明在运行
2. **路由器端口映射是否配置**：确认 UDP 51820 已转发到 Mac 内网 IP
3. **DNS 是否指向正确 IP**：`curl ifconfig.me` 查看当前公网 IP，与域名解析结果对比
4. **抓包确认流量是否到达**：`sudo tcpdump -ni any udp port 51820`，让客户端重连，看有无输出

### 能 ping 通但网页打不开

典型的 MTU 问题。ping 的包小（32 字节），TCP/HTTPS 的大包超出 WireGuard 封装后的有效 MTU。

在客户端配置 `[Interface]` 中添加：

```ini
MTU = 1280
```

### Surge 开启增强模式时握手失败

WireGuard 回包源 IP 被 Surge 替换为 `198.18.0.1`，客户端拒绝。

在 Surge 配置的 `[General]` 中加入：

```ini
tun-excluded-routes = <公司电脑IP段，如 117.133.0.0/16>
```

### Windows 关闭 VPN 后 Mac 仍收到流量

正常现象。Windows WireGuard 服务（`WireGuardTunnel$work-macbook`）在"Deactivate"后可能仍在后台运行，`PersistentKeepalive = 25` 会每 25 秒发一个保活包。  
此外端口 51820 暴露在公网，互联网扫描器也会随机探测。  
WireGuard 会验证密钥，无效包直接丢弃，不影响安全。

### wg-quick 启动报 `Line unrecognized`

`wg0.conf` 中 PostUp/PostDown 使用了 `\` 换行，wg-quick 不支持多行。  
需将命令改为单行。参考 `setup-server.sh` 生成的格式。

### 接口检测到 Surge 的 utun 而非物理网卡

`route -n get default` 在 Surge Enhanced Mode 开启时返回 Surge 的虚拟接口。  
`setup-server.sh` 已改用 `networksetup -listallhardwareports` + `ipconfig getifaddr` 检测物理网卡，避免此问题。

---

## 安全说明

- **密钥文件不入 Git**：`.gitignore` 已排除 `*.key` 和 `clients/` 目录，不要手动 `git add` 密钥文件
- **服务端私钥权限 600**：存储在 `$(brew --prefix)/etc/wireguard/`，只有 root 可读
- **客户端配置文件权限 600**：生成后妥善保管，泄露等同于泄露私钥
- **定期轮换密钥**：重新运行 `add-client.sh` 可为同一客户端生成新密钥，旧配置作废
