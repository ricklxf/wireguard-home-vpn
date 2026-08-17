🇨🇳 **CN** | [🇺🇸 EN](README_EN.md)

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
3. 生成 `clients/work-macbook/work-macbook.conf`（含 `MTU = 1280`，避免大包被丢弃）——生成在脚本所在目录下，属主是执行 `sudo` 的那个用户而不是 root，Finder/AirDrop 不用额外操作就能直接访问
4. 热更新运行中的 WireGuard（无需重启）
5. 若已安装 `qrencode`，打印二维码供手机扫码导入

### 第四步：在公司电脑上导入配置

| 系统 | 方式 |
|------|------|
| macOS / Windows | 安装 [WireGuard App](https://www.wireguard.com/install/)，导入 `.conf` 文件 |
| Linux | `sudo wg-quick up /path/to/work-macbook.conf` |
| iOS / Android | 安装 WireGuard App，扫描二维码 |

启用后，`AllowedIPs = 0.0.0.0/0, ::/0` 表示**全部流量**（IPv4 + IPv6）都经 VPN 隧道回家出网。

### 删除客户端（设备丢失或不再使用时）

```bash
sudo bash remove-client.sh work-macbook
```

脚本自动完成：

1. 从运行中的 WireGuard 摘除该 peer（立即生效，无需重启）
2. 从服务端 `wg0.conf` 里删除对应配置
3. 删除本地保存的密钥和配置文件

删除后即使设备上还留着旧的 `.conf` 文件，也无法再连接。

> 不要一份配置文件给多台设备共用——WireGuard 按私钥识别 peer，多台设备用同一份配置会互相抢占连接，导致反复掉线。每台设备都应该单独用 `add-client.sh` 生成一份。

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

## 服务端搬到群晖 / Linux（当客户端 IP 不固定、又要保留 Surge 完整接管时）

### 背景：`tun-excluded-routes` 方案的边界

上一节的 `tun-excluded-routes` 方案能让 Windows 稳定连回家，前提是**客户端的公网 IP 落在一个提前配置好的固定网段里**（比如公司出口 117.133.0.0/16）。这个前提对手机不成立——手机在外面用流量或不同 WiFi，公网 IP 每次都不一样，没法用一份静态排除列表覆盖。

而且如果要求"Surge 继续完整接管这台 Mac 的所有流量"（不是只排除 WireGuard 那一段），问题会变成：**同一台机器上，既要 Surge 全权接管默认路由，又要 WireGuard 的服务端进程精确绕开它**。这在 macOS 上被证明走不通：

- **`PROCESS-NAME,wireguard-go,DIRECT`**：对 UDP 无效（Surge 处理 UDP 时不看这条规则，命中数永远是 0）
- **`AND,((PROTOCOL,UDP),(IN-PORT,51820)),DIRECT`**：同样无效，Surge 的 Rule 引擎主要针对"进程主动发起连接"，不覆盖"本机监听端口被动回包"这种场景
- **pf 的 `route-to`**：即使把包强制指定走物理网卡，Surge 依然能在更底层（很可能是 Network Extension 框架）截获并改写源地址——`route-to` 改变的是路由表层面的选路，Surge 的拦截根本不经过这一层判断
- **换一台不跑 Surge/Clash 的 "干净" Mac**：如果那台机器本身也装了 Clash 内核的代理客户端（比如 OKZ）并开着 TUN 模式，会复现一模一样的问题——**任何在本机开 TUN 模式的代理客户端，都会拦截同机 WireGuard 服务端的回包**，这不是 Surge 独有的问题
- **pf 的 `route-to`/`reply-to` 用在"本机自己生成的 UDP 回包"上，在完全没有代理软件干扰的 Mac 上单独测试依然大概率失败**——这是 macOS 这个 pf fork 本身策略路由能力偏弱的问题，不是被代理软件抢流量导致的

### 能用的方案：Linux 的 `ip rule` 策略路由

macOS 缺的这块能力，Linux 的 `ip rule` 天生就有，而且可靠：

```bash
# 只有源地址是 VPN 子网的流量，才走这张单独的路由表
ip rule add from 10.13.13.0/24 lookup 100
ip route add default via 192.168.1.254 table 100   # 192.168.1.254 是 Surge 网关模式的虚拟网关
```

WireGuard 自己生成的握手/回包（源地址是本机 IP，不是 `10.13.13.x`）根本不会匹配这条规则，天然走主路由表的默认网关（家用路由器），不经过 Surge；只有客户端解密后的真实流量（源地址是 `10.13.13.x`）会被单独拎出来送进 Surge 网关。两层互不干扰，第一次测试就成功，跟 macOS 上折腾一整晚形成鲜明对比。

### 部署方式：Docker 容器 + `--network host`

不需要专门装 Linux，群晖这类 NAS（DSM 底层是 Linux）用 Docker 就能跑：

```bash
# 拉取用户态 WireGuard 镜像（不依赖内核版本，DSM 升级也不受影响）
docker pull masipcat/wireguard-go:latest

# 用 --network host 让容器直接操作宿主机的网络栈（wg0 接口、路由表、iptables 都在宿主机层面生效）
docker run -d \
  --name wireguard \
  --network host \
  --cap-add NET_ADMIN \
  --cap-add SYS_MODULE \
  --device /dev/net/tun \
  -v /volume1/docker/wireguard/wg0.conf:/etc/wireguard/wg0.conf \
  --restart unless-stopped \
  masipcat/wireguard-go:latest
```

`wg0.conf` 沿用原来 Mac 服务端的私钥和已注册的 peer（**私钥原样迁移，不要重新生成**），这样客户端的 `Endpoint`、服务端公钥都不用变，Windows/手机的配置文件一个字都不用改：

```ini
[Interface]
PrivateKey = <原服务端私钥，原样迁移>
Address    = 10.13.13.1/24
ListenPort = 51820
PostUp     = iptables -t nat -A POSTROUTING -s 10.13.13.0/24 -o eth0 -j MASQUERADE; ip rule add from 10.13.13.0/24 lookup 100; ip route add default via 192.168.1.254 table 100
PostDown   = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -o eth0 -j MASQUERADE; ip rule del from 10.13.13.0/24 lookup 100 2>/dev/null || true; ip route del default via 192.168.1.254 table 100 2>/dev/null || true

# Client: work-macbook
[Peer]
PublicKey  = <客户端公钥>
AllowedIPs = 10.13.13.2/32

# Client: iphone
[Peer]
PublicKey  = <客户端公钥>
AllowedIPs = 10.13.13.3/32
```

`eth0` 换成 NAS 实际的物理网卡名，`192.168.1.254` 换成 Surge 网关模式实际的虚拟网关地址。

路由器的端口映射（UDP 51820）目标 IP 改成 NAS 的内网 IP，其余不变。

### 验证

```bash
# 容器内查看握手状态
docker exec wireguard wg show
# 应该能看到 latest handshake 和持续增长的 transfer 数据，不是只有 endpoint 没有握手时间

# 宿主机上抓包确认外层握手走的是路由器，不是 Surge
tcpdump -ni eth0 udp port 51820
# 回包源地址应该是 NAS 自己的内网 IP，且行为应该是密集的双向小包（握手完成后的正常数据），
# 不是每 5 秒一次孤零零的 148 字节握手重试包（那是握手一直没成功的典型症状）

# 客户端侧确认分流生效
# 手机浏览器打开 ip.sb / ipinfo.io，出口 IP 应该是 Surge 代理节点的 IP，不是家里的公网 IP
```

### 七个关键坑

1. **不要把"Surge 拦截 WireGuard 回包"和"macOS pf 策略路由本身不可靠"当成一回事**：即使换到一台完全没装任何代理软件的干净 Mac，本机自己生成的 UDP 回包用 `route-to`/`reply-to` 单独测试依然大概率失败。只有排除掉 Surge/Clash 这些因素，回到最简单的"默认网关直接指向路由器、不做任何策略路由"，才能确认握手链路本身没问题——这是必须先钉死的 baseline，否则会在错误的假设上反复浪费时间。

2. **任何在本机开 TUN 模式的代理客户端都会拦截同机 WireGuard 的回包，不只是 Surge**：换到另一台 Mac 之前，先确认那台机器上是否也装了 Clash 内核之类的代理工具（`ps aux | grep -i clash` 或查看是否有额外的 `utun` 接口带着 `198.18.x.x` 这种 fake-ip 网段的地址）。

3. **验证"流量到底被谁处理"，不能只看包在哪块网卡上出现过**：同一局域网段内，交换机/路由器有时候会让流量在"没有实际处理这个连接"的机器网卡上也被抓到（顺路可见），必须用 `wg show` 确认该机器上有没有真实的握手记录和流量统计，而不是靠 `tcpdump` 抓到包就下结论。

4. **Surge/Clash 的"网关模式"要求设备真的通过它的 DHCP 获取网络配置，不能只是运行时改一下默认路由**：用 `route change default <虚拟网关IP>` 这种命令行操作往往不会真正生效或不稳定，必须在系统网络设置里手动配置完整的 TCP/IP（IP、子网掩码、网关、DNS 全部指定），或者让设备重新走一次 DHCP 由代理软件的 DHCP 服务器分配。

5. **macOS 的 `pf.conf` 里，NAT 规则和过滤规则（`route-to`/`reply-to`/`pass`）需要分别声明 `nat-anchor` 和普通 `anchor`，二者是两套独立的锚点**：只声明了 `nat-anchor "wireguard"` 时，往同名 anchor 里加载过滤规则（比如 `route-to`）不会报错，但也根本不会生效，容易误判"规则加了但没用"，其实是锚点声明本身就不完整。

6. **`pf` 的状态表（state table）不会因为新加了规则就自动失效**：如果客户端一直在用同一个源端口反复重试连接，新加的 `route-to`/`reply-to` 规则对已经建立的连接状态不生效，必须 `pfctl -F states` 清空状态表，并且让客户端**完全断开重连**（换一个新的源端口）才能验证新规则是否真的起作用，否则会得到"规则加了但还是不行"的假阴性结论。

7. **TCP 服务受 pf `route-to`/`reply-to` 不稳定的影响，比 UDP 服务小得多**：macOS pf 对 TCP 的连接状态追踪明显比 UDP 可靠，如果只是让某个本机 TCP 服务（比如远程桌面工具的 WebSocket 端口）绕开 Surge/Clash 的网关接管，`reply-to` 大概率能稳定生效，不需要像 WireGuard（UDP）这样被迫换到 Linux 设备。

---

## Windows 客户端分流方案（内网走公司，外网走家里）

需求：公司电脑连 VPN 后，访问公司内网（打印机、内网系统）走公司本地网络，其余流量（含被墙网站）经家里出网。

### 为什么不能靠 AllowedIPs 排除网段

直觉做法是把公司内网段从 `AllowedIPs` 里排除（用互补 CIDR 列表覆盖除公司网段外的所有地址）。实测在 Windows 上会失败：

- **官方 WireGuard Windows 客户端内置防泄漏保护**：当 `AllowedIPs` 约等于覆盖全部 IPv4 地址空间时（无论写一条 `0.0.0.0/0` 还是拆成几十条碎片 CIDR），客户端会在标准路由表之外，用 Windows Filtering Platform 再加一层拦截，专门屏蔽"绕过隧道"的流量——这是它的安全特性，不是 bug，但会连带误伤自己所在网段的正常通信。
- 现象：`route print` 显示的路由表完全正确（公司网段走物理网卡的 on-link 路由），但 `ping`/`tracert` 到同网段设备依然 `General failure`。断开 VPN 立即恢复，`netsh int ip reset` + 重启也无效——说明问题不在路由表或系统状态，而在客户端自身的过滤逻辑。

### 正确方案：Table = off + 手动路由

让 WireGuard 客户端完全不接管路由表，绕开它内置的防泄漏逻辑，改用标准 Windows 路由手动控制：

```ini
[Interface]
PrivateKey = <客户端私钥>
Address    = 10.13.13.2/24
DNS        = 8.8.8.8, 8.8.4.4
Table      = off

[Peer]
PublicKey  = <服务端公钥>
Endpoint   = <家里公网IP或域名>:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

`AllowedIPs` 保持 `0.0.0.0/0`（这只影响加密路由判断，不再驱动系统路由表），`Table = off` 让路由表完全交给我们手动管理。

### 手动路由脚本（管理员权限运行）

```batch
@echo off
setlocal enabledelayedexpansion

set RETRY=0
:wait
set WG_IF=
for /f "tokens=1" %%i in ('netsh interface ipv4 show interfaces ^| findstr /C:"<客户端名称，如 work-macbook>"') do set WG_IF=%%i
if "!WG_IF!"=="" (
    set /a RETRY+=1
    if !RETRY! GEQ 30 exit /b
    timeout /t 2 >nul
    goto wait
)

route delete 0.0.0.0 mask 0.0.0.0 10.13.13.1 >nul 2>&1
route add 0.0.0.0 mask 0.0.0.0 10.13.13.1 metric 1 IF !WG_IF! -p
route add <公司内网段> mask <掩码> <公司本地网关> metric 1 -p
```

等待循环最多重试 30 次（约 60 秒），超时直接退出，不再无限等待——原因见下面第 6 个坑。

第一条是"默认全走隧道"，第二条起是"精确排除走本地"——Windows 路由按最长前缀匹配优先，精确网段路由永远赢过 `0.0.0.0/0`，不需要考虑添加顺序。

所有路由都加 `-p`（持久化）防止睡眠/唤醒或短暂断网后被系统清掉；默认路由这条在加之前先 `route delete`（忽略报错）清一次，避免重启后接口编号变化导致旧的持久化记录卡在错误接口上、阻塞新路由写入。

### 六个关键坑

1. **`route add` 不指定接口时可能绑错网卡**：网关写对了（`10.13.13.1`），但 Windows 自动判断"哪张网卡能到达这个网关"时，有时会错误地绑定到物理网卡而非 WireGuard 隧道网卡，导致路由形同虚设。必须用 `IF <接口编号>` 显式指定，编号通过 `route print -4`（查看 `Interface List` 里 "WireGuard Tunnel" 对应的编号）获取，每次重启可能变化，脚本里建议动态查询而非写死。

2. **`PostUp`/`PostDown` 在 Windows 客户端上可能完全不执行**：部分版本的官方 GUI 客户端不会运行配置文件里的 `PostUp`/`PostDown` 脚本（日志里也不会有任何相关记录），不要假设它一定生效，务必用 `route print` 实测验证。不生效时改用手动批处理脚本，或注册 Windows 计划任务在开机/连接后触发。

3. **批处理多命令分隔符**：Windows `cmd.exe` 用 `&` 连接多条命令，不是 Unix 风格的 `;`（`;` 在部分场景会被当成注释符处理，导致整行被忽略）。

4. **不带 `-p` 的路由会在没有重启的情况下消失**：笔记本睡眠/唤醒、WiFi 短暂断开重连都可能触发系统清理非持久化路由，症状是"机器没重启，VPN 内网访问突然又不通了"。用 `route print -4` 能看到该路由确实不见了。解决办法是给路由都加 `-p`；但如果同时用了 `IF <接口编号>` 硬编码接口，持久化记录在真正重启后可能因为接口编号变化而失效或错位，所以开机脚本里要在添加前先 `route delete` 清一次兜底。

5. **接口"别名"和"描述"不是一回事，脚本按名字查询接口时容易查错**：`route print -4` 的 `Interface List` 里显示的是驱动描述（通常固定为 "WireGuard Tunnel"），而 `netsh interface ipv4 show interfaces` 显示的是接口**别名**，别名等于导入配置时的隧道/客户端名称（如 `work-macbook`），不是 "WireGuard Tunnel"。用 `netsh` 查询时如果按描述文本去匹配，会永远匹配不到——脚本里的等待循环会卡死不退出（计划任务查询会显示 `Status: Running` 且 `Last Result: 267009` 长期不变）。脚本里 `findstr` 要匹配的是**客户端名称**，不是 "WireGuard Tunnel"。

6. **手动断开重连 WireGuard 后路由会再次失效，`-p` 也救不了**：`-p` 持久化解决的是"网卡还在、路由被系统清空"的场景（睡眠/唤醒、短暂断网）；但手动 Deactivate 再 Activate 时，WireGuard 的虚拟网卡是被整个销毁重建的，绑定在旧网卡对象上的路由随之失效，跟持久化与否无关。只在开机时触发一次的计划任务覆盖不到这种情况，必须换成网络状态变化事件触发（见下）。同时等待循环不能写成无限等待：事件触发可能因为纯 WiFi 抖动而不涉及 WireGuard，若循环无限等下去，配合任务的 `IgnoreNew`（防止并发）设置会导致任务一直卡在"运行中"，后续 WireGuard 真正重连时的触发事件被直接丢弃——所以脚本必须有超时退出。

### 让路由脚本在开机和 WireGuard 重连时都自动运行

前提：WireGuard 隧道本身已设置开机自动连接。

将上面的路由脚本保存为 `C:\Scripts\wg-routes.bat`，管理员 PowerShell 执行一次（仅需一次）：

```powershell
$action = New-ScheduledTaskAction -Execute "C:\Scripts\wg-routes.bat"
$trigger1 = New-ScheduledTaskTrigger -AtStartup

$class = Get-CimClass MSFT_TaskEventTrigger root/Microsoft/Windows/TaskScheduler
$trigger2 = New-CimInstance -CimClass $class -ClientOnly
$trigger2.Subscription = @'
<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000 or EventID=10001)]]</Select></Query></QueryList>
'@
$trigger2.Enabled = $true

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName "WireGuard-Routes" -Action $action -Trigger @($trigger1,$trigger2) -Principal $principal -Settings $settings -Force
```

以 `SYSTEM` 权限触发，不弹 UAC 确认。`EventID 10000/10001`（网络已连接/已断开）在任意网卡状态变化时都会触发一次，包括 WireGuard 断开重连；脚本本身是幂等的（默认路由先删再加，其余路由带 `-p` 已存在也不报错），触发得比实际需要更频繁也无害。`IgnoreNew` 防止事件密集触发时脚本并发跑，前提是脚本自身有超时退出（见上面第 6 个坑），否则一次卡死的等待会挡住后续所有触发。

### 公司内网专属网站访问不了（403 / 假 IP）

现象：公司某些系统只允许内网 IP 访问，连 VPN 后打开报 403 或直接打不开。

原因：DNS 查询也会经隧道到家里，如果家里 Mac 跑了 Surge 增强模式，DNS 会被拦截返回 Surge 的虚拟 IP（`198.18.0.0/15` 段），公司服务器不认这个假 IP。

排查：

```cmd
nslookup <域名>
```

对比连 VPN 前后解析结果是否一致，若连 VPN 后解析出 `198.18.x.x` 就是这个原因。

解决：不依赖 DNS，直接在 Windows hosts 文件里写死真实 IP（管理员 CMD）：

```cmd
echo <真实IP> <域名> >> C:\Windows\System32\drivers\etc\hosts
```

同时把该 IP 所在网段加入上面的"手动路由"脚本，确保这个 IP 走本地网络而非隧道。

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

### 重启后无法访问局域网内其他设备（VPN 内网互通失败）

**现象**：WireGuard 隧道正常（`ping 10.13.13.1` 通），但无法访问服务端同一局域网内的其他设备（如 `192.168.1.x`），重启前一切正常。

**原因**：macOS BSD `sed` 在替换字符串中不把 `\n` 解析为换行符，导致 `setup-server.sh` 未能将 `nat-anchor "wireguard"` 写入 `/etc/pf.conf`。重启前 pf 的内存状态恰好生效；重启后 macOS 用 `/etc/pf.conf` 重新初始化 pf，anchor 引用缺失，NAT 不再生效，来自客户端的包源地址未被替换，目标设备的回包走默认网关后丢失。

**验证**：

```bash
# 如果输出为空，说明 anchor 引用缺失
grep 'wireguard' /etc/pf.conf
```

**修复**：

```bash
sudo cp /etc/pf.conf /etc/pf.conf.bak
sudo sed -i '' 's|nat-anchor "com\.apple/\*"|nat-anchor "com.apple/*"\
nat-anchor "wireguard"|' /etc/pf.conf

# 重载规则集并重新写入 anchor 规则
sudo pfctl -f /etc/pf.conf
echo 'nat on en0 inet from 10.13.13.0/24 to any -> (en0)' | sudo pfctl -a wireguard -f -
```

`setup-server.sh` 已修复此 bug，重新运行脚本可一次性修复。

### `wg show wg0` / `add-client.sh` 误判 WireGuard 未运行

**现象**：明明 WireGuard 正常在跑（其他设备能连、能握手），但 `sudo wg show wg0` 报 `Unable to access interface: No such file or directory`，`add-client.sh` 生成新客户端时提示"WireGuard 当前未运行"，新客户端的 peer 没有被热加载。

**原因**：macOS 没有原生 WireGuard 内核模块，`wg-quick` 用通用的 `utun` 接口（如 `utun4`）承载隧道，`wg0`只是`wg-quick`自己在 `/var/run/wireguard/wg0.name` 里记的一个别名，仅供 `wg-quick up/down` 自己使用。原始的 `wg` 命令并不认这个别名，它直接找 `/var/run/wireguard/<接口名>.sock`——传入 `wg0` 时找的是不存在的 `wg0.sock`，而实际的 socket 叫 `utun4.sock`，所以必然报错。

**验证**：

```bash
sudo wg show
# 看 "interface: utunN" 这一行，用真实名字重新查
sudo wg show utunN
```

**修复**：`add-client.sh` 已改为自动读取 `/var/run/wireguard/wg0.name` 解析出真实接口名再操作，无需手动干预。若使用旧版脚本，手动热加载新 peer：

```bash
cat /var/run/wireguard/wg0.name   # 查看真实接口名，如 utun4
sudo wg set utun4 peer <客户端公钥> allowed-ips <客户端VPN IP>/32
```

### 生成的客户端配置文件在 Finder 里找不到 / `ls` 报 Permission denied

**原因**：早期版本的 `add-client.sh` 把客户端文件生成在 `$(brew --prefix)/etc/wireguard/clients/` 下，这个目录权限是 `700`、属主是 root（保护服务端私钥），当前登录用户和 Finder 都没权限进入，不是文件不存在。

**修复**：`add-client.sh` 已改为把客户端文件生成在脚本所在目录下的 `clients/`，并 `chown` 回执行 `sudo` 的那个用户，生成后可以直接用 Finder/AirDrop 访问，无需额外操作。

若你的客户端文件是用旧版脚本生成、还留在 `$(brew --prefix)/etc/wireguard/clients/` 下，用 `sudo` 复制出来再传输：

```bash
sudo cp $(brew --prefix)/etc/wireguard/clients/<客户端名>/<客户端名>.conf ~/Desktop/
sudo chown $(whoami) ~/Desktop/<客户端名>.conf
# AirDrop 传完后
rm ~/Desktop/<客户端名>.conf
```

---

## 安全说明

- **密钥文件不入 Git**：`.gitignore` 已排除 `*.key` 和 `clients/` 目录，不要手动 `git add` 密钥文件
- **服务端私钥权限 600**：存储在 `$(brew --prefix)/etc/wireguard/`，只有 root 可读
- **客户端配置文件权限 600**：生成后妥善保管，泄露等同于泄露私钥
- **定期轮换密钥**：重新运行 `add-client.sh` 可为同一客户端生成新密钥，旧配置作废
