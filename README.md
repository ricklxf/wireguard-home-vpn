🇨🇳 **CN** | [🇺🇸 EN](README_EN.md)

# WireGuard Home VPN

服务端跑在群晖 NAS（Docker）上，让公司电脑/手机的流量经由家里出网；同时家里的 Mac 上继续跑 Surge 全权分流，两者互不干扰。

## 架构

```
公司电脑 / 手机（客户端）
    │
    │  WireGuard 加密隧道（UDP 51820）
    │
家用路由器（端口映射 51820 → NAS）
    │
群晖 NAS（服务端，Docker 容器 --network host）
    ├─ wg0 接口解密，源地址 10.13.13.x
    │
    ├─ 外层：WireGuard 自己的握手/回包（源地址是 NAS 自己的 IP）
    │   └─ 走主路由表默认网关 → 家用路由器 → 直连互联网
    │
    └─ 内层：客户端解密后的真实流量（源地址 10.13.13.x）
        └─ ip rule 策略路由单独指向 → Mac 的 Surge 网关模式 → 按 Surge 规则分流出网
```

外层（隧道本身）和内层（隧道里的真实流量）走两条完全独立的路径，互不干扰——这是这套方案能同时满足"VPN 稳定连得上"和"流量走 Surge 分流"的关键。

## 为什么服务端选择 NAS，而不是直接跑在 Mac 上

最直接的做法是让 WireGuard 直接跑在家里那台运行 Surge 的 Mac 上。这在只需要"客户端能连回家"时没问题，但一旦同时要求"Surge 继续完整接管这台 Mac 的所有流量"，就会变成：**同一台机器上，Surge 要全权接管默认路由，WireGuard 服务端进程又要精确绕开它**——这在 macOS 上被反复验证走不通：

- Surge 的 `PROCESS-NAME`、`IN-PORT` 规则对 UDP 无效，命中数永远是 0
- macOS 的 `pf` 策略路由（`route-to`/`reply-to`）即使完全没有代理软件干扰，用在"本机自己生成的 UDP 回包"这种场景上依然大概率失败——这是 macOS 这个 pf fork 本身策略路由能力偏弱，不是被代理软件抢流量导致的
- 换一台"干净"的 Mac 也不行——只要那台机器自己开了任何 TUN 模式的代理客户端（Surge、Clash 内核等），都会拦截同机 WireGuard 的回包，这不是 Surge 独有的问题

而 Linux 的 `ip rule` 天生具备可靠的策略路由能力，第一次测试就成功。群晖等 NAS 底层就是 Linux，用 Docker 跑一个用户态 WireGuard 镜像即可，不用额外买硬件。

> 如果你的场景不需要"同一台机器上 Surge/Clash 全权接管 + WireGuard 共存"（比如家里就一台 Mac，且不跑常驻 TUN 代理），直接在 Mac 上用本仓库的 `setup-server.sh` 更省事，见文末「Mac 原生部署（无 Surge/Clash 共存需求时）」。

### 没有群晖时的平替设备

核心要求就两条：跑 Linux（有可靠的 `ip rule` 策略路由）、24 小时开机。满足这两条的设备都能替代群晖：

| 设备 | 可行性 | 说明 |
|---|---|---|
| 软路由 / OpenWrt 路由器 | 最佳 | WireGuard 常有内核模块支持，性能最好；策略路由原生支持；本身就是网关，天然不存在"回包绕路"的问题 |
| 树莓派 | 很好 | Pi Zero 2W（几十元到一百多）就够用；完整 Linux，`ip rule` 随便配；功耗极低，适合常年开机 |
| 闲置 x86 小主机 | 好 | 装 Debian/Ubuntu，能力等同树莓派，性能更强 |
| 群晖等 NAS | 很好 | 本文使用的方案，前提是已经有一台常年开机的 NAS |
| 云服务器 VPS | 场景不符 | 技术上最省事，但出口 IP 是机房的，不是家里的，失去了"回家出网"的意义 |
| Mac | 不适合与 Surge/Clash 共存 | 已反复验证 macOS pf 策略路由不可靠；只跑 WireGuard、不需要分流共存时可以用 |

---

## 前置条件

- 一台 24 小时开机、支持 Docker 的 NAS 或 Linux 主机（本文以群晖 DSM 7.2 为例）
- 家用路由器：支持端口映射
- 家里有固定公网 IP（或已配置好 DDNS）
- 如果 NAS 所在网络里有 Surge/Clash 这类分流工具、且希望内层流量也走它分流，需要该工具支持"网关模式"（作为局域网其他设备的网关），并记下它的虚拟网关 IP

---

## 部署服务端

### 第一步：生成服务端密钥对

在 NAS 上（或任意能跑 `wg` 命令的机器上）：

```bash
wg genkey | tee server_private.key | wg pubkey > server_public.key
```

### 第二步：写 `wg0.conf`

```bash
sudo mkdir -p /volume1/docker/wireguard
sudo tee /volume1/docker/wireguard/wg0.conf > /dev/null <<'EOF'
[Interface]
PrivateKey = <server_private.key 的内容>
Address    = 10.13.13.1/24
ListenPort = 51820
PostUp     = iptables -t nat -A POSTROUTING -s 10.13.13.0/24 -o eth0 -j MASQUERADE; ip rule add from 10.13.13.0/24 lookup 100; ip route add default via 192.168.1.254 table 100
PostDown   = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -o eth0 -j MASQUERADE; ip rule del from 10.13.13.0/24 lookup 100 2>/dev/null || true; ip route del default via 192.168.1.254 table 100 2>/dev/null || true
EOF
sudo chmod 600 /volume1/docker/wireguard/wg0.conf
```

- `eth0` 换成 NAS 实际的物理网卡名
- `192.168.1.254` 换成 Surge/Clash 网关模式实际的虚拟网关地址；如果不需要内层流量分流，把 `ip rule`/`ip route` 那两条去掉，只留 `iptables` 那条 NAT 规则即可，等同于普通的 WireGuard 服务端

此时 `wg0.conf` 里还没有任何 `[Peer]`（客户端），见下面「添加客户端」。

### 第三步：Docker 启动容器

```bash
docker pull masipcat/wireguard-go:latest

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

`--network host` 让容器直接操作宿主机的网络栈——`wg0` 接口、路由表、`iptables` 规则都在宿主机层面生效，这也是 `ip rule` 策略路由能生效的前提。镜像不依赖内核版本（用户态实现），DSM 升级不受影响。

### 第四步：路由器端口映射

将 **UDP 51820** 端口转发到 NAS 的内网 IP。

| 字段 | 值 |
|------|----|
| 协议 | UDP |
| 外部端口 | 51820 |
| 内部 IP | NAS 的内网 IP |
| 内部端口 | 51820 |

---

## 添加 / 删除客户端

服务端没有自动化脚本（这块沿用手动流程），每台设备三步：

### 添加

**1. 生成客户端密钥对、分配 VPN 子网 IP**（`10.13.13.x`，从 `.2` 开始递增，`.1` 是服务端自己）：

```bash
wg genkey | tee client_private.key | wg pubkey > client_public.key
```

**2. 把 `[Peer]` 追加进服务端 `wg0.conf`**：

```bash
sudo tee -a /volume1/docker/wireguard/wg0.conf > /dev/null <<EOF

# Client: <设备名>
[Peer]
PublicKey  = <client_public.key 的内容>
AllowedIPs = 10.13.13.x/32
EOF
```

**3. 热加载到运行中的容器**（不用重启容器）：

```bash
docker exec wireguard wg set wg0 peer <client_public.key 的内容> allowed-ips 10.13.13.x/32
```

**4. 生成客户端配置文件**：

```ini
[Interface]
PrivateKey = <client_private.key 的内容>
Address    = 10.13.13.x/24
DNS        = 8.8.8.8, 8.8.4.4
MTU        = 1280

[Peer]
PublicKey           = <server_public.key 的内容>
Endpoint            = <家里公网IP或域名>:51820
AllowedIPs          = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

导入方式：

| 系统 | 方式 |
|------|------|
| macOS / Windows | 安装 [WireGuard App](https://www.wireguard.com/install/)，导入 `.conf` 文件 |
| Linux | `sudo wg-quick up /path/to/xxx.conf` |
| iOS / Android | 安装 WireGuard App，用 `qrencode -t ansiutf8 < xxx.conf` 生成二维码扫码导入 |

> 不要一份配置文件给多台设备共用——WireGuard 按私钥识别 peer，多台设备用同一份配置会互相抢占连接，导致反复掉线。每台设备都单独生成一份。

### 删除

```bash
# 从运行中的容器摘除（立即生效）
docker exec wireguard wg set wg0 peer <该设备的公钥> remove

# 从 wg0.conf 里手动删掉对应的 [Peer] 块，防止容器重启后又加载回来
sudo nano /volume1/docker/wireguard/wg0.conf
```

删除后即使设备上还留着旧的 `.conf` 文件，也无法再连接。

---

## Windows 客户端分流方案（内网走公司，外网走家里）

需求：公司电脑连 VPN 后，访问公司内网（打印机、内网系统）走公司本地网络，其余流量（含被墙网站）经家里出网。这部分是**客户端侧**的配置，跟服务端具体跑在哪台机器上无关，服务端从 Mac 搬到 NAS 之后，Windows 这边的配置和路由脚本完全不用改。

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

原因：DNS 查询也会经隧道到家里，如果服务端所在网络里的分流工具（Surge/Clash）开着 fake-ip，DNS 会被拦截返回假 IP（`198.18.0.0/15` 段之类），公司服务器不认这个假 IP。

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

## 验证

连上 VPN 后，在客户端上：

```bash
# 出口 IP 应该显示家里的公网 IP（如果内层流量走了分流工具的代理节点，会显示节点的 IP）
curl -4 https://ifconfig.me

# ping VPN 网关
ping 10.13.13.1

# ping 外网（验证转发和 NAT）
ping 8.8.8.8
```

在服务端容器里查看连接状态：

```bash
docker exec wireguard wg show
# 能看到 peer、握手时间、流量统计——只有 endpoint 没有 "latest handshake" 说明还没握手成功
```

宿主机抓包确认外层握手确实走了直连而不是被分流工具拦截：

```bash
tcpdump -ni eth0 udp port 51820
# 回包源地址应该是 NAS 自己的内网 IP；握手成功后应能看到密集的双向不定长数据包，
# 而不是每 5 秒一次孤零零的 148 字节握手重试包（后者是握手一直没成功的典型症状）
```

---

## 原理说明

### WireGuard 协议

- 基于 **UDP**，延迟低，NAT 穿透友好
- 加密套件固定：Curve25519（密钥交换）+ ChaCha20-Poly1305（加密）+ BLAKE2s（哈希）
- 无协商过程，没有"配置错误"的空间，攻击面极小
- 代码量约 4000 行，经过独立安全审计（2019 年 Trail of Bits）
- 2020 年合并进 Linux 内核 5.6；本方案用的用户态实现 `wireguard-go` 不依赖内核版本，适合跑在 Docker 容器里

### TUN 虚拟网卡

`wg-quick up wg0` 在系统里创建一张虚拟网卡（Linux 上通常直接叫 `wg0`，macOS 上是 `utun*`）。应用发出的包经路由表送往这张虚拟网卡，WireGuard 加密后从真实网卡发出；收到的 UDP 包解密后写回虚拟网卡，对上层应用透明。

### IP 转发 + NAT

```bash
sysctl -w net.ipv4.ip_forward=1   # Linux；macOS 是 net.inet.ip.forwarding
```

默认系统只转发目标是本机的包，开启后内核会转发"路过的包"。客户端的 VPN IP（`10.13.13.x`）是私有地址，互联网不认识，NAT 规则把出包的源地址替换成服务端自己的 IP：

```
原始包：src=10.13.13.2  dst=8.8.8.8
经 NAT：src=192.168.1.110  dst=8.8.8.8   ← 互联网看到的
回包：  src=8.8.8.8       dst=192.168.1.110
还原：  src=8.8.8.8       dst=10.13.13.2 ← 送回给客户端
```

Linux 上用 `iptables -t nat -A POSTROUTING ... -j MASQUERADE` 实现，连接状态表自动完成回包还原。

### 内外分层路由（策略路由）

`ip rule` 按**源地址**把流量分流到不同的路由表：WireGuard 自己生成的握手/回包源地址是服务端本机 IP，走主路由表（默认网关，直连出网）；客户端解密后的真实流量源地址是 `10.13.13.x`，被单独的 `ip rule from 10.13.13.0/24 lookup 100` 拦下，走 table 100 里配置的网关（比如 Surge 的网关模式虚拟 IP）。两条路径完全独立，互不影响。

### MTU

WireGuard 封装会增加约 60 字节的头部开销。客户端配置默认设置 `MTU = 1280`（保守值），避免大包超出物理网卡 MTU（1500）被丢弃。ICMP ping 包小，不受影响；TCP/HTTPS 的大包如不设置 MTU 容易出现"能 ping 通但无法浏览网页"的现象。

### 容器持久化

`--restart unless-stopped` 让 Docker 在 NAS 重启后自动拉起容器；容器内 `wg-quick` 每次启动都会重新执行 `PostUp` 里的策略路由和 NAT 规则，不依赖任何手动干预。

---

## 服务管理

```bash
# 停止
docker stop wireguard

# 启动
docker start wireguard

# 重启（配置改了之后用这个让 PostUp 重新执行）
docker restart wireguard

# 查看日志
docker logs wireguard

# 确认当前状态
docker exec wireguard wg show
```

---

## 常用命令

```bash
# 查看 VPN 连接状态及流量统计
docker exec wireguard wg show

# 重启 WireGuard
docker restart wireguard

# 查看容器日志
docker logs -f wireguard

# 查看 NAT / 策略路由是否生效
docker exec wireguard iptables -t nat -L POSTROUTING -n
docker exec wireguard ip rule list
docker exec wireguard ip route show table 100

# 抓包调试（宿主机上跑，看 51820 端口流量）
tcpdump -ni eth0 udp port 51820
```

---

## 故障排查

### 握手一直失败（Handshake did not complete）

按顺序检查：

1. **服务端是否在运行**：`docker exec wireguard wg show`，有输出说明在运行
2. **路由器端口映射是否配置**：确认 UDP 51820 已转发到服务端的内网 IP，且目标 IP 是最新的（改过部署位置后容易忘记同步改路由器）
3. **公网 IP / DDNS 是否正确**：`curl -4 ifconfig.me` 查看当前公网 IP，与客户端 `Endpoint` 填的域名解析结果对比
4. **抓包确认流量是否到达**：`tcpdump -ni eth0 udp port 51820`，让客户端重连，看有无输出——完全没有输出说明包在半路就被丢了（客户端所在网络限制、路由器规则等），有输出但只有单向说明服务端有回应但客户端收不到（NAT/防火墙问题）

### 能 ping 通但网页打不开

典型的 MTU 问题。ping 的包小（32 字节），TCP/HTTPS 的大包超出 WireGuard 封装后的有效 MTU。

在客户端配置 `[Interface]` 中添加：

```ini
MTU = 1280
```

### 服务端所在网络也跑着 Surge/Clash，握手包被拦截、回包源地址变成假 IP

详见上面「为什么服务端选择 NAS，而不是直接跑在 Mac 上」——如果坚持要在同一台跑 Surge/Clash 的机器上部署 WireGuard 服务端，这个问题基本无法从配置层面根治，唯一可靠的解法是把服务端搬到一台不跑 TUN 代理的 Linux 设备（NAS、树莓派等），用 `ip rule` 做策略路由。

### 服务端所在网络的网关是软路由（OpenWrt 之类），软路由里也有透明代理

跟"同一台主机自己跑代理客户端"不是同一类问题，风险明显更低：

- 今晚踩的坑是"**本机自己生成的 UDP 回包**被本机的 TUN 代理拦截"——这是 macOS `pf` 机制本身的缺陷
- 软路由作为**网关**代理"经过它的流量"是更常规的场景（本文内层流量走 Surge 网关模式就是这个模式，而且成功了），只要软路由能**精确排除** WireGuard 服务端自己的握手/回包（服务端自己的 IP、UDP 51820 端口）不被拦截即可

多数软路由跑在 Linux/OpenWrt 上，底层用 `iptables`/`nftables` 做流量重定向，"排除特定端口/IP 不重定向"是标准能力，可靠性远高于 macOS 的 `pf`。部署完用同一套方法验证：

```bash
tcpdump -ni <服务端物理网卡> udp port 51820
# 回包源地址应该是服务端自己真实的内网 IP，不是被软路由改写成的虚拟/代理地址
```

### 客户端断开 VPN 后服务端仍收到流量

正常现象。客户端的 WireGuard 服务在"Deactivate"后可能仍在后台运行，`PersistentKeepalive = 25` 会每 25 秒发一个保活包。此外服务端端口暴露在公网，互联网扫描器也会随机探测。WireGuard 会验证密钥，无效包直接丢弃，不影响安全。

### 特定网站间歇性打不开：Surge 网关模式转发流量拿不到假 IP 保护

**现象**：Mac 本机（Surge Enhanced Mode）访问某网站完全正常，但手机等经 WireGuard 转发进来的设备访问同一网站却间歇性/持续打不开，抓包看是 DNS 解析拿到了错误/被污染的结果。

**原因**：Surge 的 Fake-IP 抗污染机制只保护"本机自己发起的流量"——本机查询时直接在本地分配一个假地址，不用真的问外部 DNS，天然不会被污染。但"网关模式转发进来的流量"（内层客户端流量，见前面架构图）不会套用这层保护，会退回到真实 DNS 解析，如果上游对特定域名有污染/过滤，就会间歇性失败。

已验证**无效**的修复方向（配置本身生效了，但没解决问题，不用再重复尝试）：
- `hijack-dns` 加通配符（`hijack-dns = *:53, ...`）
- `tun-included-routes` 手动纳入转发设备所在网段
- `gateway-restricted-to-lan = false`
- `include-all-networks` / `include-local-networks` 打开

**真正有效的修复**：部署本地 DNS 服务（如 AdGuard Home），把它的**上游 DNS 换成加密的**（DoH/DoT，而不是明文 IP），让客户端设备的 DNS **直接指向这台本地 DNS 服务，绕开 Surge 网关模式这一层**。这也是为什么手机 WireGuard 客户端配置里的 `DNS =` 不建议指向 Surge 网关虚拟 IP，而应指向自建的加密 DNS 服务。

**踩过的坑**：曾尝试用 Mihomo（Clash Meta）的 TUN + `auto-route` 在 NAS 上单独实现一层假 IP 保护、转发给 Surge 处理。**在自己模拟的测试流量上完全正常，一接入真实转发流量（其他设备发起的连接）就导致大范围断网**（用到的常见 App 全部连不上）——`auto-route` 生成的路由规则，会让真实转发流量的应答包走上跟本机测试流量不一样的路径，这类问题没法靠本机模拟测试提前发现。NAS 已有多张自定义路由表（策略路由）时，不建议在没有充分测试环境的情况下贸然引入这类会自动接管路由的工具。

**顺带发现**：如果本地 DNS 服务是用 Docker 部署、且端口映射是 `0.0.0.0:53`（监听所有网卡），那么宿主机拥有的**任意一个网络接口地址**（不只是主局域网 IP，包括 WireGuard 隧道自己的网关地址）都能直接查到它，不需要额外配置端口转发。

### 网关模式转发流量访问 Google / YouTube 等走 QUIC 的网站很慢或打不开

**现象**：Surge 本机（Enhanced Mode）访问 Google、YouTube 这类网站很快，但网关模式转发进来的设备（如公司电脑）访问同样的网站经常卡很久才打开，甚至看起来像是完全打不开；国内网站不受影响。

**原因**：Surge 的 `[General]` 里 `udp-policy-not-supported-behaviour = REJECT` 这类设置，对本机流量能在"选中的策略不支持 UDP 转发"时立刻快速失败——浏览器马上从 QUIC（HTTP/3，走 UDP 443）降级到普通 TCP，几乎无感知。但网关模式转发流量不会触发同一套快速失败逻辑，UDP 包更像是被静默丢弃，转发设备只能干等自己操作系统级别的 UDP 超时（比 Surge 主动拒绝慢得多），表现为卡顿、间歇性打不开。

**验证**：在本地 DNS 服务（如 AdGuard Home）的查询日志里能看到转发设备在短时间内反复重新查询同一个域名——这是浏览器因为连接一直没建立起来、反复重试导致的，不是 DNS 出了问题。

**修复**：在 `[Rule]` 最顶部（最高优先级）加一条全局规则，直接拦截 QUIC（UDP 443），逼所有设备统一走 TCP，不用等 UDP 超时：

```
AND,((PROTOCOL,UDP),(DEST-PORT,443)),REJECT
```

**副作用**：这条规则全局生效，不区分域名、不区分国内外。对普通网页浏览没有影响（自动降级 TCP，无感知）；但会连带拦掉依赖 UDP 传输媒体流、且恰好也用了 443 端口的实时通信应用（视频通话、部分游戏），可能导致通话质量下降甚至连不上。加规则后建议实测一下常用的视频通话软件。

### Surge 模块（.sgmodule）无法修改 `[Proxy]` / `[Proxy Group]`

**坑**：曾想用一个只在特定设备（如手机）本地安装、不随主配置同步的模块，往里面塞一段 WireGuard 出口定义和对应的策略、策略组成员，实现"只有这台设备用这条线路，其他同步了同一份主配置的设备不受影响"。安装后测试完全不生效。

**原因**：Surge 官方文档明确写明，模块不能调整 `[Proxy]` 和 `[Proxy Group]` 的内容，不管是覆盖还是追加都不支持。`[WireGuard *]` 这类小节模块可以改，但策略定义（`[Proxy]`）和策略组成员列表（`[Proxy Group]`）这两层，模块动不了——即使模块里写了对应内容，也会被静默忽略。

**正确做法**：改用 Surge 的条件表达式（requirement expressions），直接写在主配置文件里（照常走同步），按平台/设备区分同一个 key 的不同定义：

```
[Proxy Group]
Singapore = fallback, PoolA, 特定线路, url=..., interval=120, timeout=3  //!REQUIREMENT SYSTEM=='iOS'
Singapore = fallback, PoolA, url=..., interval=120, timeout=3  //!REQUIREMENT SYSTEM=='macOS'
```

需要 Surge iOS 5.11.0+ / Mac 5.7.0+（简写版 `#!IOS-ONLY` 等需要更新的版本）。

**踩过的坑**：条件表达式是按"行"生效的，如果把一个必填字段齐全的小节（比如 `[WireGuard xxx]`）里**每一行**都加上同一个条件，条件不满足的平台上，整个小节会变成一个空壳（只剩标题、没有任何字段），触发 "Invalid WireGuard config" 报错——不是解析器 bug，是这个空壳本身就不合法（缺 private-key、peer 等必填字段）。应该只在真正需要按平台区分的那一层（比如策略组的成员列表）加条件，基础定义（`[WireGuard xxx]`、`[Proxy]`）保持无条件、所有平台都拿到完整定义。

### 旧版 iptables（legacy 1.8.3）`-I`/`-A` 插入 POSTROUTING 链时落错子链

**现象**：在 NAS（群晖等 Linux 系统，iptables 走 legacy 模式）上用 `iptables -t nat -I POSTROUTING <位置> ...` 往顶层 POSTROUTING 链插规则，插入命令本身不报错，但事后用 `iptables -S POSTROUTING` 或 `-L POSTROUTING` 查看，规则却出现在了 Docker 管理的 `DEFAULT_POSTROUTING` 子链里，顶层链完全没变化，规则形同虚设。用同样方式尝试 `-D` 删除某条早先由容器 PostUp 脚本创建的顶层规则时，会报 `No chain/target/match by that name`，即使 `-S` 显示这条规则明明存在、文本逐字一致。

**原因**：这条原始规则是容器内部（跟宿主机不同的 iptables 构建/版本）创建的，宿主机上直接用的 iptables 在做精确匹配删除时，即使文本渲染出来一样，底层编码对不上，导致删除失败；用 `-I` 插入新规则到顶层链时，也会被某种机制错误归位到 Docker 管理的子链。

**修复**：改到**创建这条规则的同一个容器内部**去操作（`docker exec <容器名> iptables -t nat ...`），用的是同一份 iptables 二进制，增删都能正确命中顶层链。

**顺带的教训**：改动 NAT 规则前，先用完整的 `iptables -t nat -S`（不带链名参数）确认规则真实落点，`-L <链名>` / `-S <链名>` 带上具体链名查询在这类环境下可能不可靠。

---

## Mac 原生部署（无 Surge/Clash 共存需求时）

如果不需要跟同机的 Surge/Clash 分流工具共存（比如家里只有一台 Mac 常年开机，没有额外的分流需求），可以直接用本仓库自带的脚本在 Mac 上跑，更省事：

```bash
sudo bash setup-server.sh                              # 初始化服务端
sudo bash add-client.sh <设备名> <家里公网IP或域名>       # 生成客户端配置
sudo bash remove-client.sh <设备名>                      # 删除客户端
```

脚本自动处理密钥生成、`pf` NAT 规则、`LaunchDaemon` 开机自启、客户端配置生成。原理和踩坑跟上面的 NAS 方案是同一套 WireGuard 机制，差异主要在 macOS 特有的 `pfctl`/`LaunchDaemon`，脚本内部已经处理，不需要手动干预。

---

## 安全说明

- **密钥文件不入 Git**：`.gitignore` 已排除 `*.key` 和 `clients/` 目录，不要手动 `git add` 密钥文件
- **服务端私钥权限 600**：无论是 NAS 上的 `wg0.conf` 还是 Mac 上 `$(brew --prefix)/etc/wireguard/`，都只应该 root/管理员可读
- **客户端配置文件权限 600**：生成后妥善保管，泄露等同于泄露私钥
- **定期轮换密钥**：为设备重新生成一份新密钥即可让旧配置作废
