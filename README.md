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
3. 生成 `wg0.conf`，写入 PostUp/PostDown 钩子管理 pfctl NAT 规则
4. 向 `/etc/pf.conf` 注册 `wireguard` anchor（首次运行自动备份原文件）
5. 在 `/Library/LaunchDaemons/` 注册服务，开机自动启动

### 第二步：在家用路由器上配置端口映射

将 **UDP 51820** 端口转发到家里 Mac 的内网 IP。

> 具体操作因路由器品牌而异，通常在「虚拟服务器」或「端口映射」菜单下设置。
> Mac 内网 IP 在系统设置 → 网络 里查看，或运行 `ipconfig getifaddr en0`。

### 第三步：生成公司电脑的客户端配置

```bash
sudo bash add-client.sh work-macbook <家里的公网IP>
```

脚本自动完成：

1. 生成客户端密钥对
2. 分配 VPN 子网 IP（`10.13.13.x`，自动递增）
3. 生成 `clients/work-macbook/work-macbook.conf`
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

# 可以 ping 到服务端的 VPN IP
ping 10.13.13.1
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
NAT 规则将出包的源地址替换为 Mac 自己的公网/内网 IP：

```
原始包：src=10.13.13.2  dst=8.8.8.8
经 NAT：src=192.168.1.5  dst=8.8.8.8   ← 互联网看到的
回包：  src=8.8.8.8     dst=192.168.1.5
还原：  src=8.8.8.8     dst=10.13.13.2 ← 送回给公司电脑
```

pfctl 通过连接状态表自动完成回包还原，无需手动干预。

### LaunchDaemon（开机自启）

注册在 `/Library/LaunchDaemons/`，系统启动时以 root 身份运行，  
用户未登录时也会自动拉起 WireGuard。

---

## 与 Surge 的兼容性

如果家里 Mac 同时运行了 Surge，行为如下：

| Surge 模式 | 公司电脑流量是否经过 Surge |
|-----------|--------------------------|
| 仅系统代理（System Proxy） | ❌ 不经过。系统代理工作在应用层，感知不到内核转发的包 |
| 增强模式（Enhanced Mode） | ✅ 经过。Surge 的 TUN 接管路由表，转发包会命中分流规则 |
| 两者同时开启 | ✅ 同增强模式，Enhanced Mode 覆盖，分流规则生效 |

开启增强模式后，公司电脑的流量会按照 Surge 的规则分流，  
行为与家里 Mac 本机应用完全一致。

**验证方式**：连上 VPN 后，在 Surge 的「请求记录」里查看是否出现公司电脑发出的请求。

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

# 手动停止（不影响开机自启配置）
sudo wg-quick down wg0

# 查看 pfctl NAT 规则是否生效
sudo pfctl -a wireguard -s nat
```

---

## 安全说明

- **密钥文件不入 Git**：`.gitignore` 已排除 `*.key` 和 `clients/` 目录，不要手动 `git add` 密钥文件
- **服务端私钥权限 600**：存储在 `$(brew --prefix)/etc/wireguard/`，只有 root 可读
- **客户端配置文件权限 600**：生成后妥善保管，泄露等同于泄露私钥
- **定期轮换密钥**：重新运行 `add-client.sh` 可为同一客户端生成新密钥，旧配置作废
