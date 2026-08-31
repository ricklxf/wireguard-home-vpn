[🇨🇳 CN](README.md) | 🇺🇸 **EN**

# WireGuard Home VPN

The server runs on a Synology NAS (Docker), routing traffic from a work computer or phone home through your house; meanwhile a Mac on the same network keeps running Surge with full traffic-splitting control, and the two don't interfere with each other.

## Architecture

```
Work computer / phone (client)
    │
    │  WireGuard encrypted tunnel (UDP 51820)
    │
Home router (port forward 51820 → NAS)
    │
Synology NAS (server, Docker container --network host)
    ├─ wg0 interface decrypts, source address 10.13.13.x
    │
    ├─ Outer layer: WireGuard's own handshake/reply packets (sourced from the NAS's own IP)
    │   └─ Uses the main routing table's default gateway → home router → straight to the internet
    │
    └─ Inner layer: the client's decrypted real traffic (sourced from 10.13.13.x)
        └─ Policy-routed via ip rule to → the Mac's Surge Gateway Mode → split per Surge's rules
```

The outer layer (the tunnel itself) and the inner layer (the real traffic inside the tunnel) take two completely independent paths that never interfere with each other — this is the key that lets this setup satisfy both "the VPN reliably connects" and "traffic goes through Surge's splitting" at the same time.

## Why the server lives on a NAS instead of directly on the Mac

The most direct approach is to run WireGuard right on the home Mac that already runs Surge. That's fine as long as all you need is "the client can connect home" — but the moment you also require "Surge keeps full control of everything this Mac does," it becomes: **on the same machine, Surge needs to fully own the default route, while the WireGuard server process needs to precisely route around it.** This has been repeatedly proven not to work on macOS:

- Surge's `PROCESS-NAME` and `IN-PORT` rules have no effect on UDP — hit count stays at 0
- macOS's `pf` policy routing (`route-to`/`reply-to`), even with zero interfering proxy software, still fails more often than not when applied to "a UDP reply the local machine itself generated" — this is a weakness of macOS's own pf fork's policy-routing support, not something caused by proxy software stealing traffic
- Switching to a "clean" Mac doesn't help either — as long as that machine runs ANY TUN-mode proxy client (Surge, a Clash core, etc.), it will intercept the same-machine WireGuard's replies. This isn't specific to Surge.

Linux's `ip rule`, on the other hand, has reliable native policy routing — it worked on the first try. A NAS like Synology runs Linux under the hood, so a userspace WireGuard image in Docker gets the job done without buying extra hardware.

> If your setup doesn't need "Surge/Clash fully owning the machine + WireGuard coexisting" (say, you only have one Mac at home and it doesn't run a persistent TUN proxy), it's simpler to just use this repo's `setup-server.sh` directly on the Mac — see "Native Mac deployment (when you don't need Surge/Clash coexistence)" at the bottom.

### Alternatives if you don't have a Synology

The core requirements are just two: runs Linux (for reliable `ip rule` policy routing), and stays on 24/7. Anything meeting both can substitute for a Synology:

| Device | Feasibility | Notes |
|---|---|---|
| Soft router / OpenWrt router | Best | Often has kernel-module WireGuard support for the best performance; native policy routing; it's already the gateway, so there's no "reply takes a different path" problem to begin with |
| Raspberry Pi | Great | A Pi Zero 2W (tens of dollars) is plenty; full Linux, `ip rule` configures freely; power draw is tiny, well suited to running 24/7 |
| Spare x86 mini PC | Good | Install Debian/Ubuntu — same capability as a Pi, more performance |
| Synology or similar NAS | Great | What this doc uses, assuming you already have a NAS running 24/7 |
| Cloud VPS | Wrong fit | Technically the easiest, but the exit IP belongs to the datacenter, not your home — defeats the whole point of "route home" |
| Mac | Not suited to coexisting with Surge/Clash | Repeatedly confirmed that macOS's pf policy routing is unreliable; fine if you're only running WireGuard with no splitting requirement |

---

## Prerequisites

- A NAS or Linux box that stays on 24/7 and supports Docker (this doc uses Synology DSM 7.2 as the example)
- Home router: supports port forwarding
- A static public IP at home (or DDNS already configured)
- If there's a Surge/Clash-style splitting tool somewhere on the network and you want the inner traffic to go through it too, that tool needs to support "Gateway Mode" (acting as the gateway for other LAN devices) — note down its virtual gateway IP

---

## Deploying the server

### Step 1: Generate the server keypair

On the NAS (or any machine that can run the `wg` command):

```bash
wg genkey | tee server_private.key | wg pubkey > server_public.key
```

### Step 2: Write `wg0.conf`

```bash
sudo mkdir -p /volume1/docker/wireguard
sudo tee /volume1/docker/wireguard/wg0.conf > /dev/null <<'EOF'
[Interface]
PrivateKey = <contents of server_private.key>
Address    = 10.13.13.1/24
ListenPort = 51820
PostUp     = iptables -t nat -A POSTROUTING -s 10.13.13.0/24 -o eth0 -j MASQUERADE; ip rule add from 10.13.13.0/24 lookup 100; ip route add default via 192.168.1.254 table 100
PostDown   = iptables -t nat -D POSTROUTING -s 10.13.13.0/24 -o eth0 -j MASQUERADE; ip rule del from 10.13.13.0/24 lookup 100 2>/dev/null || true; ip route del default via 192.168.1.254 table 100 2>/dev/null || true
EOF
sudo chmod 600 /volume1/docker/wireguard/wg0.conf
```

- Swap `eth0` for the NAS's actual physical interface name
- Swap `192.168.1.254` for the actual virtual gateway address of your Surge/Clash Gateway Mode; if you don't need inner-traffic splitting at all, drop the `ip rule`/`ip route` lines and keep only the `iptables` NAT rule — that's equivalent to a plain WireGuard server

At this point `wg0.conf` has no `[Peer]` entries yet — see "Adding clients" below.

### Step 3: Start the Docker container

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

`--network host` lets the container operate directly on the host's network stack — the `wg0` interface, routing table, and `iptables` rules all take effect at the host level, which is the prerequisite for `ip rule` policy routing to work at all. The image doesn't depend on kernel version (userspace implementation), so DSM upgrades don't affect it.

### Step 4: Router port forwarding

Forward **UDP 51820** to the NAS's LAN IP.

| Field | Value |
|------|----|
| Protocol | UDP |
| External port | 51820 |
| Internal IP | NAS's LAN IP |
| Internal port | 51820 |

---

## Adding / removing clients

There's no automation script for the server side (this part stays manual) — three steps per device:

### Adding

**1. Generate the client keypair and assign a VPN subnet IP** (`10.13.13.x`, incrementing from `.2` — `.1` is the server itself):

```bash
wg genkey | tee client_private.key | wg pubkey > client_public.key
```

**2. Append the `[Peer]` block to the server's `wg0.conf`**:

```bash
sudo tee -a /volume1/docker/wireguard/wg0.conf > /dev/null <<EOF

# Client: <device name>
[Peer]
PublicKey  = <contents of client_public.key>
AllowedIPs = 10.13.13.x/32
EOF
```

**3. Hot-load it into the running container** (no container restart needed):

```bash
docker exec wireguard wg set wg0 peer <contents of client_public.key> allowed-ips 10.13.13.x/32
```

**4. Generate the client config file**:

```ini
[Interface]
PrivateKey = <contents of client_private.key>
Address    = 10.13.13.x/24
DNS        = 8.8.8.8, 8.8.4.4
MTU        = 1280

[Peer]
PublicKey           = <contents of server_public.key>
Endpoint            = <home public IP or domain>:51820
AllowedIPs          = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

Import methods:

| System | Method |
|------|------|
| macOS / Windows | Install the [WireGuard App](https://www.wireguard.com/install/), import the `.conf` file |
| Linux | `sudo wg-quick up /path/to/xxx.conf` |
| iOS / Android | Install the WireGuard App, generate a QR code with `qrencode -t ansiutf8 < xxx.conf` and scan it |

> Don't share one config file across multiple devices — WireGuard identifies peers by private key, so multiple devices using the same config will fight over the connection and keep dropping. Generate a separate one per device.

### Removing

```bash
# Remove from the running container (takes effect immediately)
docker exec wireguard wg set wg0 peer <that device's public key> remove

# Manually delete the corresponding [Peer] block from wg0.conf, so it doesn't get reloaded on the next container restart
sudo nano /volume1/docker/wireguard/wg0.conf
```

Once removed, the device can no longer connect even if it still has the old `.conf` file.

---

## Windows client split-tunneling (company LAN local, everything else via home)

Goal: once connected, traffic to the company LAN (printer, internal systems) should stay local, while everything else (including blocked sites) should route home through the tunnel. This part is entirely **client-side** configuration — unrelated to which machine hosts the server. Now that the server has moved from the Mac to the NAS, none of Windows's configuration or routing scripts need to change at all.

### Why excluding a subnet via AllowedIPs doesn't work

The intuitive approach is to exclude the company subnet from `AllowedIPs` (covering everything except that subnet via a complementary CIDR list). In practice this fails on Windows:

- **The official WireGuard Windows client has built-in leak protection**: when `AllowedIPs` effectively covers nearly the entire IPv4 address space (whether as a single `0.0.0.0/0` entry or dozens of fragmented CIDRs), the client adds an extra filtering layer via Windows Filtering Platform, on top of the normal routing table, specifically to block traffic that "bypasses the tunnel." This is a deliberate security feature, not a bug — but it also breaks legitimate traffic to the client's own local subnet.
- Symptom: `route print` shows a perfectly correct routing table (the company subnet routed on-link via the physical NIC), yet `ping`/`tracert` to a device on the same subnet still returns `General failure`. Disconnecting the VPN fixes it immediately; `netsh int ip reset` plus a reboot does not — proving the problem isn't the routing table or corrupted system state, but the client's own filtering logic.

### The correct fix: Table = off + manual routes

Stop WireGuard from managing the routing table at all, bypassing its built-in leak protection, and control routing manually with standard Windows routes instead:

```ini
[Interface]
PrivateKey = <client private key>
Address    = 10.13.13.2/24
DNS        = 8.8.8.8, 8.8.4.4
Table      = off

[Peer]
PublicKey  = <server public key>
Endpoint   = <home public IP or domain>:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

Keep `AllowedIPs` at `0.0.0.0/0` (it now only affects cryptokey routing, not the system routing table); `Table = off` hands the routing table entirely to us.

### Manual routing script (run as administrator)

```batch
@echo off
setlocal enabledelayedexpansion

set RETRY=0
:wait
set WG_IF=
for /f "tokens=1" %%i in ('netsh interface ipv4 show interfaces ^| findstr /C:"<client name, e.g. work-macbook>"') do set WG_IF=%%i
if "!WG_IF!"=="" (
    set /a RETRY+=1
    if !RETRY! GEQ 30 exit /b
    timeout /t 2 >nul
    goto wait
)

route delete 0.0.0.0 mask 0.0.0.0 10.13.13.1 >nul 2>&1
route add 0.0.0.0 mask 0.0.0.0 10.13.13.1 metric 1 IF !WG_IF! -p
route add <company subnet> mask <netmask> <company local gateway> metric 1 -p
```

The wait loop retries at most 30 times (~60 seconds) and then exits instead of waiting forever — see gotcha #6 below for why.

The first line is "route everything through the tunnel by default"; subsequent lines are "precise exceptions that stay local." Windows routing uses longest-prefix-match first, so a precise subnet route always wins over `0.0.0.0/0` regardless of the order they're added in.

Every route is marked `-p` (persistent) so it survives sleep/wake cycles or brief network drops without being silently cleared by the OS. The default route is deleted (errors ignored) right before being re-added, so a stale persistent entry left over from a previous boot — potentially bound to a now-invalid interface index — can't block the fresh one from being added.

### Six key gotchas

1. **`route add` may bind to the wrong interface if you don't specify one explicitly**: the gateway is correct (`10.13.13.1`), but Windows's automatic guess at "which NIC can reach this gateway" sometimes incorrectly picks the physical NIC instead of the WireGuard tunnel interface, silently making the route useless. You must specify `IF <interface index>` explicitly. Get the index from `route print -4` (look for "WireGuard Tunnel" in the `Interface List`) — it can change across reboots, so query it dynamically in scripts rather than hardcoding it.

2. **`PostUp`/`PostDown` may not execute at all on the Windows client**: some versions of the official GUI client silently skip the `PostUp`/`PostDown` scripts in the config file (with no trace in the logs either). Don't assume it works — always verify with `route print`. If it doesn't fire, fall back to a manual batch script, or register a Windows Scheduled Task triggered at boot/connect.

3. **Batch command separator**: Windows `cmd.exe` chains multiple commands with `&`, not the Unix-style `;` (which can be treated as a comment marker in some contexts, silently dropping the rest of the line).

4. **Routes without `-p` can vanish with no reboot involved**: laptop sleep/wake or a brief Wi-Fi drop-and-reconnect can trigger Windows to clear non-persistent routes — the symptom is "the machine never restarted, but VPN-side LAN access just stopped working." `route print -4` will confirm the route is simply gone. The fix is to mark routes `-p`; but if a route also hardcodes `IF <interface index>`, a persisted entry can become stale or misbound after an actual reboot changes that index, so the boot script should `route delete` first as a safety net before re-adding.

5. **Interface "alias" and "description" are not the same thing, and scripts that match by name easily query the wrong one**: `route print -4`'s `Interface List` shows the driver *description* (usually literally "WireGuard Tunnel"), while `netsh interface ipv4 show interfaces` shows the interface's **alias**, which equals the tunnel/client name given at import time (e.g. `work-macbook`), not "WireGuard Tunnel". If a script queries via `netsh` but matches against the description text, it will never find a match — the wait loop hangs forever (a scheduled task query will show `Status: Running` with `Last Result: 267009` stuck indefinitely). The `findstr` pattern in the script must match the **client name**, not "WireGuard Tunnel".

6. **Manually disconnecting and reconnecting WireGuard breaks the routes again, and `-p` doesn't save you**: `-p` persistence handles the case where the adapter stays put but the OS clears its routes (sleep/wake, a brief network drop). But a manual Deactivate/Activate actually tears down and recreates WireGuard's virtual adapter entirely, so any route bound to the old adapter object becomes invalid regardless of persistence. A Scheduled Task that only fires at boot never covers this — it needs to also trigger on network state-change events (see below). And the wait loop must NOT be unbounded: an event trigger can fire for reasons unrelated to WireGuard (e.g. plain Wi-Fi flapping), and if the loop waits forever, combined with the task's `IgnoreNew` setting (to prevent concurrent runs) it will get stuck "running" forever and silently swallow the next legitimate trigger when WireGuard actually reconnects — hence the script needs a timeout.

### Running the routing script automatically at boot and on WireGuard reconnect

Prerequisite: the WireGuard tunnel itself is already set to auto-connect at boot.

Save the script above as `C:\Scripts\wg-routes.bat`, then run once in an elevated PowerShell:

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

Runs as `SYSTEM`, no UAC prompt. `EventID 10000/10001` (network connected/disconnected) fires on any adapter state change, including a WireGuard disconnect/reconnect. The script is idempotent (delete-then-add for the default route; other routes use `-p` and just report "already exists" harmlessly), so firing more often than strictly necessary is safe. `IgnoreNew` prevents overlapping runs when events fire in bursts — but that only works because the script itself has a timeout (gotcha #6 above); otherwise one stuck wait would block every subsequent trigger.

### An internal-only company site is unreachable (403 / fake IP)

Symptom: some internal company systems only allow access from an internal IP; after connecting to the VPN, they return 403 or won't load at all.

Cause: DNS queries also go through the tunnel to home. If a splitting tool (Surge/Clash) on the server's network has fake-ip enabled, DNS gets intercepted and returns a fake IP (something in the `198.18.0.0/15` range, say), which the company server doesn't recognize.

Diagnose:

```cmd
nslookup <domain>
```

Compare the resolved result with and without the VPN connected. If it resolves to `198.18.x.x` while connected, this is the cause.

Fix: bypass DNS entirely and hardcode the real IP in the Windows hosts file (elevated CMD):

```cmd
echo <real IP> <domain> >> C:\Windows\System32\drivers\etc\hosts
```

Also add that IP's subnet to the "manual routing" script above, so it routes locally instead of through the tunnel.

---

## Verification

After connecting, on the client:

```bash
# The exit IP should show your home public IP (or the splitting tool's proxy node IP, if inner traffic is being split)
curl -4 https://ifconfig.me

# Ping the VPN gateway
ping 10.13.13.1

# Ping an external host (verify forwarding and NAT)
ping 8.8.8.8
```

Check connection status inside the server container:

```bash
docker exec wireguard wg show
# Should show peer, handshake time, traffic stats — an endpoint with no "latest handshake"
# means the handshake hasn't actually succeeded yet
```

On the host, confirm the outer handshake really goes direct and isn't being intercepted by a splitting tool:

```bash
tcpdump -ni eth0 udp port 51820
# The reply's source address should be the NAS's own LAN IP; once the handshake succeeds you should
# see dense, bidirectional, variably-sized packets — not a lone 148-byte handshake-retry packet
# every 5 seconds (the classic sign of a stuck handshake)
```

---

## How it works

### WireGuard protocol

- Built on **UDP**, low latency, NAT-traversal friendly
- Fixed crypto suite: Curve25519 (key exchange) + ChaCha20-Poly1305 (encryption) + BLAKE2s (hashing)
- No negotiation phase, so no room for "misconfiguration" — minimal attack surface
- ~4000 lines of code, independently audited (Trail of Bits, 2019)
- Merged into Linux kernel 5.6 in 2020; the userspace implementation `wireguard-go` used here doesn't depend on kernel version, which is exactly why it fits nicely inside a Docker container

### TUN virtual interface

`wg-quick up wg0` creates a virtual network interface on the system (usually literally called `wg0` on Linux, `utun*` on macOS). Outbound app traffic is routed to this virtual interface, encrypted by WireGuard, and sent out the real interface; incoming UDP packets are decrypted and written back to the virtual interface, transparent to upper-layer apps.

### IP forwarding + NAT

```bash
sysctl -w net.ipv4.ip_forward=1   # Linux; macOS uses net.inet.ip.forwarding
```

By default the system only forwards packets destined for itself; enabling this lets the kernel forward "passing-through" packets. The client's VPN IP (`10.13.13.x`) is a private address the internet doesn't recognize, so a NAT rule rewrites the source address of outbound packets to the server's own IP:

```
Original packet: src=10.13.13.2    dst=8.8.8.8
After NAT:       src=192.168.1.110 dst=8.8.8.8   ← what the internet sees
Reply:           src=8.8.8.8       dst=192.168.1.110
Restored:        src=8.8.8.8       dst=10.13.13.2 ← sent back to the client
```

On Linux this is `iptables -t nat -A POSTROUTING ... -j MASQUERADE`; the connection state table restores reply packets automatically.

### Outer/inner split routing (policy routing)

`ip rule` splits traffic into different routing tables by **source address**: WireGuard's own handshake/reply packets are sourced from the server's own IP, so they use the main routing table (the default gateway, straight out to the internet); the client's decrypted real traffic is sourced from `10.13.13.x`, which gets pulled out specifically by `ip rule from 10.13.13.0/24 lookup 100` and routed via whatever gateway table 100 points to (e.g. Surge's Gateway Mode virtual IP). The two paths are entirely independent and never affect each other.

### MTU

WireGuard encapsulation adds roughly 60 bytes of header overhead. The client config defaults to `MTU = 1280` (a conservative value) to prevent large packets from exceeding the physical NIC's MTU (1500) and being dropped. ICMP pings are small and unaffected; without an MTU setting, large TCP/HTTPS packets often produce the "ping works but web pages won't load" symptom.

### Container persistence

`--restart unless-stopped` makes Docker automatically bring the container back up after the NAS reboots; every time the container starts, `wg-quick` re-executes the policy routing and NAT rules in `PostUp` — no manual intervention needed.

---

## Service management

```bash
# Stop
docker stop wireguard

# Start
docker start wireguard

# Restart (use this after changing the config, to re-run PostUp)
docker restart wireguard

# View logs
docker logs wireguard

# Check current status
docker exec wireguard wg show
```

---

## Common commands

```bash
# View VPN connection status and traffic stats
docker exec wireguard wg show

# Restart WireGuard
docker restart wireguard

# View container logs
docker logs -f wireguard

# Check whether NAT / policy routing is active
docker exec wireguard iptables -t nat -L POSTROUTING -n
docker exec wireguard ip rule list
docker exec wireguard ip route show table 100

# Packet capture for debugging (run on the host, watch port 51820 traffic)
tcpdump -ni eth0 udp port 51820
```

---

## Troubleshooting

### Handshake keeps failing (Handshake did not complete)

Check in order:

1. **Is the server running?**: `docker exec wireguard wg show` — output means it's running
2. **Is port forwarding configured on the router?**: confirm UDP 51820 is forwarded to the server's LAN IP, and that the target IP is current (easy to forget updating the router after moving the deployment)
3. **Is the public IP / DDNS correct?**: `curl -4 ifconfig.me` to check the current public IP against what the client's `Endpoint` domain resolves to
4. **Confirm traffic is arriving**: `tcpdump -ni eth0 udp port 51820`, reconnect the client, and check for output — no output at all means the packet got dropped somewhere along the way (a restriction on the client's network, a router rule, etc.); output in only one direction means the server is replying but the client isn't receiving it (a NAT/firewall issue)

### Ping works but web pages won't load

Classic MTU issue. Pings are small (32 bytes); TCP/HTTPS packets are large and exceed WireGuard's effective MTU after encapsulation.

Add this to the client's `[Interface]` section:

```ini
MTU = 1280
```

### The server's network also runs Surge/Clash, and handshake packets get intercepted with the reply's source address rewritten to a fake IP

See "Why the server lives on a NAS instead of directly on the Mac" above — if you insist on deploying the WireGuard server on the same machine that runs Surge/Clash, this problem is essentially unfixable at the configuration level. The only reliable solution is to move the server to a Linux device that doesn't run a TUN proxy (a NAS, a Raspberry Pi, etc.) and use `ip rule` for policy routing.

### The server's network gateway is a soft router (OpenWrt-style), and the soft router also does transparent proxying

This is a different category of problem from "the same host itself running a proxy client," and the risk is noticeably lower:

- Tonight's actual failure was "**a UDP reply the local machine itself generated**" getting intercepted by that same machine's TUN proxy — a weakness of macOS's own `pf` mechanism.
- A soft router acting as the **gateway** proxying "traffic passing through it" is a much more conventional setup (this is exactly the mode this doc's inner-traffic-via-Surge-Gateway-Mode uses, and it worked) — it just needs to **precisely exclude** the WireGuard server's own handshake/reply traffic (the server's own IP, UDP port 51820) from being intercepted.

Most soft routers run on Linux/OpenWrt, and under the hood use `iptables`/`nftables` for traffic redirection — "exclude a specific port/IP from redirection" is a standard capability there, far more reliable than macOS's `pf`. Verify with the same method after deploying:

```bash
tcpdump -ni <server's physical interface> udp port 51820
# The reply's source address should be the server's own genuine LAN IP,
# not a virtual/proxy address rewritten by the soft router
```

### The client still sends traffic to the server after disconnecting the VPN

This is expected. The client's WireGuard service may keep running in the background after "Deactivate," and `PersistentKeepalive = 25` sends a keepalive packet every 25 seconds. Also, the server's port is exposed publicly, so internet scanners will probe it randomly. WireGuard validates keys and drops invalid packets outright — this doesn't affect security.

### A recurring root cause: gateway-mode traffic just isn't treated the same as local traffic

The next two writeups (DNS Fake-IP protection, QUIC hanging) look like two unrelated symptoms on the surface, but **they share the same root cause**: Surge has a whole set of optimizations and protections for traffic it originates itself (Enhanced Mode) — Fake-IP, fast UDP rejection, and so on — but most of these don't apply to traffic arriving through Gateway Mode (forwarded in from other devices via routing). Gateway Mode behaves more like transparent forwarding in Surge — it doesn't inherit the special treatment local traffic gets. **Never assume a Surge config verified working for local traffic also works for forwarded traffic — always test it separately from an actual forwarding device.** Here are the two concrete manifestations of this found so far:

### A specific site is intermittently unreachable: Surge's gateway-mode traffic doesn't get Fake-IP protection

**Symptom**: The Mac itself (Surge Enhanced Mode) can reach a given site with no issues, but another device (e.g. a phone) whose traffic is forwarded in over WireGuard fails to reach the same site intermittently or persistently. A packet capture shows the DNS resolution returning a wrong/poisoned result.

**Cause**: Surge's Fake-IP anti-pollution mechanism only protects traffic the Mac itself originates (Enhanced Mode) — for its own queries, Surge assigns a fake address locally without ever asking an external DNS server, so it's naturally immune to pollution. Traffic forwarded in through gateway mode (the inner client traffic described in the architecture diagram above) doesn't get this same protection — it falls back to real DNS resolution, and if the upstream resolver is poisoned/filtered for a given domain, lookups fail intermittently.

Fixes that were tried and confirmed **ineffective** (they applied cleanly but didn't solve the problem — don't retry these):
- `hijack-dns` with a wildcard (`hijack-dns = *:53, ...`)
- Manually adding the forwarding device's subnet to `tun-included-routes`
- `gateway-restricted-to-lan = false`
- Enabling `include-all-networks` / `include-local-networks`

**The fix that actually works**: Run a local DNS service (e.g. AdGuard Home), switch its **upstream to an encrypted resolver** (DoH/DoT, not a plain IP), and point the forwarding device's DNS **directly at this local DNS service, bypassing Surge's gateway mode entirely**. This is also why the phone's WireGuard client config should set `DNS =` to a self-hosted encrypted DNS service rather than Surge's gateway virtual IP.

**A pitfall hit along the way**: We tried running Mihomo (Clash Meta) in TUN mode with `auto-route` on the NAS as a standalone Fake-IP layer that would forward to Surge. **It worked perfectly against self-simulated test traffic, but caused widespread outages the moment real forwarded traffic (connections from other devices) hit it** — every commonly used app stopped connecting. The routes `auto-route` installs send reply packets for real forwarded traffic down a different path than the traffic generated by local test simulations, so this class of failure can't be caught by testing from the host alone. If the NAS already has multiple custom routing tables (policy routing) in place, don't introduce a tool that auto-takes-over routing like this without a proper test environment.

**A side discovery**: If the local DNS service is deployed via Docker with its port mapped to `0.0.0.0:53` (listening on all interfaces), then *any* network interface address on the host — not just its main LAN IP, but also the WireGuard tunnel's own gateway address — can query it directly, with no extra port-forwarding needed.

### Gateway-forwarded traffic to Google / YouTube and other QUIC-heavy sites is slow or won't load

Another manifestation of the **same root cause** as the DNS Fake-IP issue above — this time it's not DNS resolution, it's UDP handling that treats local and forwarded traffic differently.

**Symptom**: Surge's own host (Enhanced Mode) loads Google/YouTube quickly, but devices whose traffic is forwarded through Gateway Mode (e.g. a work computer) often hang for a long time on the same sites, sometimes appearing to fail outright. Domestic sites are unaffected.

**Cause**: settings like `udp-policy-not-supported-behaviour = REJECT` in Surge's `[General]` let local traffic fail fast when the selected policy doesn't support UDP forwarding — the browser immediately falls back from QUIC (HTTP/3, over UDP 443) to plain TCP, essentially unnoticeable. Gateway-forwarded traffic doesn't get the same fast-fail treatment — the UDP packets are effectively dropped silently, and the forwarding device is left waiting on its own OS-level UDP timeout (much longer than Surge's own active rejection), which shows up as hanging or intermittent failures.

**Verification**: the local DNS service's (e.g. AdGuard Home) query log will show the forwarding device repeatedly re-querying the same domain in a short window — that's the browser retrying because the connection never actually established, not a DNS problem.

**A fix tried first that turned out ineffective for gateway-forwarded traffic**: add a global rule at the very top of `[Rule]` to reject QUIC outright:

```
AND,((PROTOCOL,UDP),(DEST-PORT,443)),REJECT
```

This rule **does work for traffic Surge's own host originates** (redundant with `udp-policy-not-supported-behaviour = REJECT`, which already covers that case — harmless to keep as a belt-and-suspenders measure). It **has no effect on gateway-forwarded traffic** — a packet capture confirmed the forwarding device kept sending UDP 443 traffic exactly as before, unchanged. Same root cause as the Fake-IP issue above: Surge's rule layer simply doesn't treat gateway-forwarded traffic the same as local traffic, so a rule verified to work locally can't be assumed to apply to forwarded traffic too.

**The fix that actually works**: move the interception down to the network layer (the NAS's own `iptables`), which doesn't depend on how Surge's gateway mode handles anything. Because this particular NAS's kernel has no `REJECT` target module available (`Couldn't load target 'REJECT'`), DNAT the traffic to a port nothing is listening on instead — the kernel will automatically send back an "ICMP port unreachable," achieving the same effect as an active rejection (as opposed to a silent DROP, which lets the client know immediately that this path is closed and fall back to TCP right away instead of waiting out a timeout):

```bash
# Add to wg0.conf's PostUp (with a mirrored -D command in PostDown for cleanup)
iptables -t nat -A PREROUTING -s 10.13.13.0/24 -p udp --dport 443 -j DNAT --to-destination <NAS's LAN IP>:1
```

**A gotcha along the way**: adding this rule directly on the host with `iptables -A PREROUTING ...` gets silently misfiled into Docker's `DEFAULT_PREROUTING` sub-chain — the top-level chain is untouched and the rule has no effect (same root cause as the POSTROUTING gotcha described earlier). It has to be run from **inside the same container that created the other NAT rules in `wg0.conf`** (`docker exec <container> iptables -t nat -A PREROUTING ...`) to land correctly in the top-level chain.

**Side effect**: this rule blocks UDP 443 globally by source subnet (`10.13.13.0/24`, the WireGuard client subnet) — it doesn't distinguish domains or domestic vs. international traffic. Regular web browsing is unaffected (silent fallback to TCP), but it will also block real-time communication apps (video calls, some games) that rely on UDP for media transport if they happen to also use port 443 — call quality may degrade or the call may fail to connect. Test your usual video-calling apps after adding this rule.

### A Surge module (.sgmodule) cannot modify `[Proxy]` / `[Proxy Group]`

**The trap**: tried using a module installed locally on only one device (e.g. a phone), not synced with the main profile, to smuggle in a WireGuard exit definition plus its matching proxy and policy-group membership — the goal being "only this device uses this route; other devices sharing the same synced main profile are unaffected." After installing it, testing showed it simply had no effect.

**Cause**: Surge's official docs explicitly state that modules cannot adjust the content of `[Proxy]` or `[Proxy Group]` — neither override nor append is supported. `[WireGuard *]` sections can be modified by a module, but the policy definition (`[Proxy]`) and policy-group membership (`[Proxy Group]`) layers cannot — even if a module contains matching content, it's silently ignored.

**The correct approach**: use Surge's requirement expressions instead, written directly in the main (synced) profile, to give the same key different definitions per platform/device:

```
[Proxy Group]
Singapore = fallback, PoolA, SpecificRoute, url=..., interval=120, timeout=3  //!REQUIREMENT SYSTEM=='iOS'
Singapore = fallback, PoolA, url=..., interval=120, timeout=3  //!REQUIREMENT SYSTEM=='macOS'
```

Requires Surge iOS 5.11.0+ / Mac 5.7.0+ (the shorthand forms like `#!IOS-ONLY` need newer versions still).

**A gotcha along the way**: requirement expressions take effect per line. If every single line of a section with mandatory fields (e.g. `[WireGuard xxx]`) is tagged with the same condition, then on a platform where the condition doesn't match, the entire section collapses into an empty shell — just the header, no fields at all — which triggers an "Invalid WireGuard config" error. This isn't a parser bug; the empty shell genuinely is invalid (missing required fields like private-key, peer). Only tag the layer that actually needs to differ per platform (e.g. the policy group's member list) with a condition — keep the base definitions (`[WireGuard xxx]`, `[Proxy]`) unconditional so every platform gets the complete definition.

### Legacy iptables (1.8.3) misfiles `-I`/`-A` inserts into the wrong POSTROUTING sub-chain

**Symptom**: on a NAS (Synology or similar Linux box running legacy-mode iptables), running `iptables -t nat -I POSTROUTING <position> ...` to insert a rule into the top-level POSTROUTING chain succeeds with no error — but checking afterward with `iptables -S POSTROUTING` or `-L POSTROUTING` shows the rule landed inside Docker's `DEFAULT_POSTROUTING` sub-chain instead; the top-level chain is untouched and the rule has no effect. Trying to `-D` delete an existing top-level rule that was originally created by a container's PostUp script fails with `No chain/target/match by that name`, even though `-S` shows the rule present with byte-for-byte matching text.

**Cause**: that original rule was created from inside a container (a different iptables build/version than the host's). Even though the rendered text looks identical, the host's own iptables can't match it byte-for-byte at the delete step due to differing internal encoding; and inserting new rules into the top-level chain via `-I` gets mis-filed into a Docker-managed sub-chain by some underlying mechanism.

**Fix**: operate from inside **the same container that created the rule** (`docker exec <container> iptables -t nat ...`) — using the exact same iptables binary, both additions and deletions correctly hit the top-level chain.

**Takeaway**: before touching NAT rules, confirm the rule's real location with a full `iptables -t nat -S` (no chain argument) — querying with an explicit chain name (`-L <chain>` / `-S <chain>`) can be unreliable in this kind of environment.

### A specific device times out querying a self-hosted service on the NAS, even though the server's own log shows it was "handled": policy routing misroutes the NAS's own replies to devices on the same subnet

**Symptom**: a client device (e.g. a work computer) times out querying a local service hosted on the NAS (e.g. AdGuard Home's DNS), consistently taking around ten seconds; the exact behavior varies by domain queried and by client device (some devices are fine, others reproduce the timeout every time); the server's own log shows the query was "processed" in under a millisecond — looking completely healthy; a packet capture on the NAS shows the client's query arriving, but no reply packet ever going back out.

**Cause**: if the NAS has a policy route like `ip rule add from 10.13.13.0/24 lookup 100` set up to divert forwarded traffic from the WireGuard client subnet (say `10.13.13.0/24`) to another machine for processing — this rule matches on "source address falls within this subnet," and the NAS's own WireGuard interface address (say `10.13.13.1`) numerically falls within that same subnet too. When the NAS itself — not forwarding someone else's traffic, but originating its own, e.g. a local service replying to a client's query — needs to send a packet to another device on that same subnet, that packet's source address ALSO matches this rule, and gets misrouted as if it were forwarded client traffic, sent somewhere completely unrelated instead of going straight back out the WireGuard interface. This bug only affects the specific pattern of "the NAS itself originates traffic destined for another device on the same subnet" — it doesn't affect the far more common "client reaches the outside internet" case, so it can go unnoticed for a long time until this particular path happens to get tested directly.

**Verification**:
```bash
# Simulate: when the NAS itself (the service's own address) replies to a client device, which route does the kernel actually pick?
ip route get <client address> from <NAS's own WireGuard interface address>
```
If the output shows it going through a policy routing table (e.g. `table 100`) with a gateway pointing at some other device, rather than directly `dev wg0`, that's this bug.

**Fix**: add a higher-priority rule (lower number = higher priority for `ip rule`) that carves the NAS's own originated traffic out of that policy route, letting it use the main routing table normally:
```bash
ip rule add from <NAS's own WireGuard interface address> lookup main priority 100
```
This must sit ahead of the original policy-routing rule to take effect — remember to add it to the boot-persistence script too, or it won't survive a reboot.

### Whole-chain audit: undersized UDP kernel buffers causing intermittent drops, and a fairer qdisc

Ran a full audit of the chain (NAS hardware, kernel parameters, NIC offload, container resource limits, etc.). Most of it turned out to already be in reasonable shape (CPU governor is `performance`, TSO/GSO/GRO are on, conntrack is nowhere near its limit, the `wireguard` container has no CPU/memory limit) — but two real issues turned up.

**Issue 1: real UDP receive-buffer overflow**

```bash
cat /proc/net/snmp | grep -i udp
# Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors ...
# Watch RcvbufErrors specifically — nonzero means packets were actually dropped
```

`net.core.rmem_max`/`wmem_max` default to just 208KB (the generic Linux default — never tuned for this box). When WireGuard's (51820) or AdGuard's (53) UDP socket hits a burst (a video stream, several connections opening at once) and the application can't read fast enough, the kernel buffer fills up and packets get dropped before `wireguard-go`/AdGuard ever sees them. None of this shows up in NIC counters (`ip -s link`) or WireGuard's own handshake logs — only `RcvbufErrors` reveals it, which makes it easy to miss entirely.

**Fix**:
```bash
sysctl -w net.core.rmem_max=2500000 net.core.rmem_default=2500000
sysctl -w net.core.wmem_max=2500000 net.core.wmem_default=2500000
```

**Issue 2: eth0's qdisc is `pfifo_fast`, with no fairness between flows**

The default `pfifo_fast` only sorts packets into three priority bands based on the TOS field; within a band it's strictly FIFO. A single sustained large flow (a big download) can make small packets from other connections (DNS lookups, TCP handshakes) queue up behind it, which shows up as "the page just froze for a second."

**Pitfall hit while fixing this**: the standard recommendation is `fq_codel` (built-in active queue management, fair *and* low-latency), but this Synology's kernel (`4.4.302`, an old DSM branch) simply never compiled the `sch_fq_codel` module in:
```bash
modprobe sch_fq_codel
# modprobe: FATAL: Module sch_fq_codel not found.
```
`/lib/modules/$(uname -r)/kernel/net/sched/` doesn't even exist on this box — the whole pluggable-qdisc mechanism was stripped out of the kernel build, not just missing a package.

**Workaround**: use `sfq` (Stochastic Fair Queuing) instead — it's built into the kernel and needs no extra module. It lacks fq_codel's latency-based active dropping, but it does give concurrent connections a fair share of bandwidth so one large flow can't starve the rest:
```bash
tc qdisc replace dev eth0 root sfq
```

Both fixes are now in `/usr/local/etc/rc.d/custom-routes.sh` so they're reapplied automatically on every boot.

**Left untouched: client-side MTU**

The client configs currently use a conservative `MTU = 1280`, while the wg0 interface itself actually negotiates up to `1420`. Bumping it should shave a little encapsulation overhead, but that change lives in the client (the WireGuard app config on the iPhone/Windows side) — nothing to do on the server for this one. Test it after changing it, especially on cellular, where some carriers add enough of their own encapsulation overhead that 1420 could start dropping packets.

---

## Native Mac deployment (when you don't need Surge/Clash coexistence)

If you don't need to coexist with a Surge/Clash splitting tool on the same machine (say, you only have one Mac at home running 24/7, with no additional splitting requirement), it's simpler to just run this repo's built-in scripts directly on the Mac:

```bash
sudo bash setup-server.sh                                 # initialize the server
sudo bash add-client.sh <device name> <home public IP or domain>   # generate a client config
sudo bash remove-client.sh <device name>                  # remove a client
```

The scripts handle key generation, `pf` NAT rules, `LaunchDaemon` auto-start, and client config generation automatically. The underlying mechanism and gotchas are the same WireGuard fundamentals as the NAS approach above — the differences are macOS-specific bits (`pfctl`/`LaunchDaemon`), which the scripts already handle internally without manual intervention.

---

## Security notes

- **Key files are not committed to Git**: `.gitignore` excludes `*.key` and the `clients/` directory — don't manually `git add` key files
- **Server private key permissions 600**: whether it's `wg0.conf` on the NAS or `$(brew --prefix)/etc/wireguard/` on a Mac, it should only be readable by root/an administrator
- **Client config file permissions 600**: keep it safe after generation — leaking it is equivalent to leaking the private key
- **Rotate keys periodically**: generating a fresh keypair for a device invalidates its old config
