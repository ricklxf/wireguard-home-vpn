[🇨🇳 CN](README.md) | 🇺🇸 **EN**

# WireGuard Home VPN

Route all traffic from a work computer through a home macOS machine.

## Architecture

```
Work computer (client)
    │
    │  WireGuard encrypted tunnel (UDP 51820)
    │
Home router (port forward 51820 → Mac)
    │
Home Mac (server)
    ├─ WireGuard decryption
    ├─ IP forwarding (net.inet.ip.forwarding)
    ├─ pfctl NAT (source address rewrite)
    └─── Home broadband ─── Internet
```

## Prerequisites

- Home Mac: macOS 12+, with [Homebrew](https://brew.sh) installed
- Home router: supports port forwarding
- A static public IP at home (or DDNS already configured)

---

## Usage

### Step 1: Initialize the server on the home Mac

```bash
sudo bash setup-server.sh
```

The script automatically:

1. Installs `wireguard-tools` (via Homebrew)
2. Generates the server's Curve25519 keypair, stored in `$(brew --prefix)/etc/wireguard/`
3. Auto-detects the physical WAN interface (excluding virtual utun interfaces created by software like Surge)
4. Generates `wg0.conf` with single-line PostUp/PostDown (wg-quick doesn't support `\` line continuation)
5. Registers a `wireguard` anchor in `/etc/pf.conf` (auto-backs up the original file on first run)
6. Registers the service under `/Library/LaunchDaemons/` to start on boot

### Step 2: Configure port forwarding on the home router

Forward **UDP 51820** to the home Mac's LAN IP.

> The exact steps vary by router brand, usually under "Virtual Server" or "Port Forwarding".
> Find the Mac's LAN IP in System Settings → Network, or run `ipconfig getifaddr en0`.

Port forwarding fields:

| Field | Value |
|------|----|
| Protocol | UDP |
| External port | 51820 |
| Internal IP | Mac's LAN IP |
| Internal port | 51820 |

### Step 3: Generate a client config for the work computer

```bash
sudo bash add-client.sh work-macbook <home public IP or domain>
```

The script automatically:

1. Generates a client keypair
2. Assigns a VPN subnet IP (`10.13.13.x`, auto-incrementing)
3. Generates `clients/work-macbook/work-macbook.conf` (includes `MTU = 1280` to avoid large packets being dropped)
4. Hot-reloads the running WireGuard instance (no restart needed)
5. Prints a QR code for mobile import if `qrencode` is installed

### Step 4: Import the config on the work computer

| System | Method |
|------|------|
| macOS / Windows | Install the [WireGuard App](https://www.wireguard.com/install/), import the `.conf` file |
| Linux | `sudo wg-quick up /path/to/work-macbook.conf` |
| iOS / Android | Install the WireGuard App, scan the QR code |

Once enabled, `AllowedIPs = 0.0.0.0/0, ::/0` means **all traffic** (IPv4 + IPv6) is routed home through the VPN tunnel.

---

## Verification

After connecting, on the work computer:

```bash
# The exit IP should show your home public IP
curl https://ifconfig.me

# Ping the VPN gateway
ping 10.13.13.1

# Ping an external host (verify forwarding and NAT)
ping 8.8.8.8
```

Check connection status on the server:

```bash
sudo wg show
# Should show peer, handshake time, traffic stats
```

---

## How it works

### WireGuard protocol

- Built on **UDP**, low latency, NAT-traversal friendly
- Fixed crypto suite: Curve25519 (key exchange) + ChaCha20-Poly1305 (encryption) + BLAKE2s (hashing)
- No negotiation phase, so no room for "misconfiguration" — minimal attack surface
- ~4000 lines of code, independently audited (Trail of Bits, 2019)
- Merged into Linux kernel 5.6 in 2020; macOS uses the userspace `wireguard-go`

### TUN virtual interface

`wg-quick up wg0` creates a virtual network interface on the system (named `utun*` on macOS).
Outbound app traffic is routed to `utun*`, encrypted by WireGuard, and sent out the real interface;
incoming UDP packets are decrypted and written back to `utun*`, transparent to upper-layer apps.

### IP forwarding

```bash
sysctl -w net.inet.ip.forwarding=1
```

By default macOS only forwards packets destined for itself; enabling this lets the kernel forward "passing-through" packets,
so the work computer's traffic can reach the internet via the Mac.

### pfctl NAT

The work computer's VPN IP (`10.13.13.x`) is a private address the internet doesn't recognize.
The NAT rule rewrites the source address of outbound packets to the Mac's own IP:

```
Original packet: src=10.13.13.2  dst=8.8.8.8
After NAT:       src=192.168.1.4  dst=8.8.8.8   ← what the internet sees
Reply:           src=8.8.8.8     dst=192.168.1.4
Restored:        src=8.8.8.8     dst=10.13.13.2 ← sent back to the work computer
```

pfctl restores reply packets automatically via its connection state table — no manual intervention needed.

### MTU

WireGuard encapsulation adds roughly 60 bytes of header overhead.
The client config defaults to `MTU = 1280` (a conservative value) to prevent large packets from exceeding the physical NIC's MTU (1500) and being dropped.
ICMP pings are small and unaffected; without an MTU setting, large TCP/HTTPS packets often produce the "ping works but web pages won't load" symptom.

### LaunchDaemon (start on boot)

Registered under `/Library/LaunchDaemons/`, runs as root at system startup,
and brings up WireGuard automatically even before any user logs in.

---

## Surge compatibility

If the home Mac also runs Surge, extra configuration is needed — otherwise WireGuard's reply packets get hijacked by Surge.

### Root cause

Surge's Enhanced Mode takes over the system routing table, so all outbound traffic goes through Surge's virtual interface.
When WireGuard sends a reply packet to the work computer, Surge intercepts it and **rewrites the source address to Surge's virtual IP (`198.18.0.1`)**.
The work computer doesn't recognize this address, and the handshake fails.

> A `PROCESS-NAME,wireguard-go,DIRECT` rule has no effect on UDP — Surge still forwards UDP via its virtual IP regardless of a DIRECT rule.

### Fix

In Surge's config file, add the work computer's IP range to `tun-excluded-routes` under `[General]`:

```ini
[General]
tun-excluded-routes = 117.133.0.0/16
```

This tells Surge not to route traffic destined for that IP range through its TUN, so WireGuard's reply packets go out directly via the physical NIC (`en0`) with the correct source address.

After reloading the config, verify with tcpdump on the Mac:

```bash
sudo tcpdump -ni en0 udp port 51820
# Reply source address should be 192.168.1.x, not 198.18.0.1
```

### Behavior summary by mode

| Surge mode | No extra config | With tun-excluded-routes |
|-----------|------------|----------------------|
| System proxy only | ✅ Works | Not needed |
| Enhanced Mode | ❌ Wrong reply source IP, handshake fails | ✅ Works |
| Both enabled | ❌ Same as Enhanced Mode | ✅ Works |

> **Note**: `tun-excluded-routes` excludes by destination IP — update it manually if the work computer's IP range changes.

---

## Windows client split-tunneling (company LAN local, everything else via home)

Goal: once connected, traffic to the company LAN (printer, internal systems) should stay local, while everything else (including blocked sites) should route home through the tunnel.

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

:wait
set WG_IF=
for /f "tokens=1" %%i in ('netsh interface ipv4 show interfaces ^| findstr /C:"WireGuard Tunnel"') do set WG_IF=%%i
if "!WG_IF!"=="" (
    timeout /t 2 >nul
    goto wait
)

route add 0.0.0.0 mask 0.0.0.0 10.13.13.1 metric 1 IF !WG_IF!
route add <company subnet> mask <netmask> <company local gateway> metric 1
```

The first line is "route everything through the tunnel by default"; subsequent lines are "precise exceptions that stay local." Windows routing uses longest-prefix-match first, so a precise subnet route always wins over `0.0.0.0/0` regardless of the order they're added in.

### Three key gotchas

1. **`route add` may bind to the wrong interface if you don't specify one explicitly**: the gateway is correct (`10.13.13.1`), but Windows's automatic guess at "which NIC can reach this gateway" sometimes incorrectly picks the physical NIC instead of the WireGuard tunnel interface, silently making the route useless. You must specify `IF <interface index>` explicitly. Get the index from `route print -4` (look for "WireGuard Tunnel" in the `Interface List`) — it can change across reboots, so query it dynamically in scripts rather than hardcoding it.

2. **`PostUp`/`PostDown` may not execute at all on the Windows client**: some versions of the official GUI client silently skip the `PostUp`/`PostDown` scripts in the config file (with no trace in the logs either). Don't assume it works — always verify with `route print`. If it doesn't fire, fall back to a manual batch script, or register a Windows Scheduled Task triggered at boot/connect.

3. **Batch command separator**: Windows `cmd.exe` chains multiple commands with `&`, not the Unix-style `;` (which can be treated as a comment marker in some contexts, silently dropping the rest of the line).

### Running the routing script automatically at boot

Prerequisite: the WireGuard tunnel itself is already set to auto-connect at boot.

Save the script above as `C:\Scripts\wg-routes.bat`, then run once in an elevated PowerShell:

```powershell
$action = New-ScheduledTaskAction -Execute "C:\Scripts\wg-routes.bat"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "WireGuard-Routes" -Action $action -Trigger $trigger -Principal $principal -Settings $settings
```

This runs as `SYSTEM` at boot with no UAC prompt. The script has a built-in wait loop that polls until the WireGuard tunnel interface is ready before adding routes, avoiding failures from running too early at boot.

### An internal-only company site is unreachable (403 / fake IP)

Symptom: some internal company systems only allow access from an internal IP; after connecting to the VPN, they return 403 or won't load at all.

Cause: DNS queries also go through the tunnel to home. If the home Mac runs Surge in Enhanced Mode, DNS gets intercepted and returns one of Surge's virtual IPs (the `198.18.0.0/15` range), which the company server doesn't recognize.

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

## Service management

### Stop the service

```bash
# Temporary stop (auto-resumes after Mac restart)
sudo wg-quick down wg0

# Full stop (disable auto-start + stop service)
sudo wg-quick down wg0
sudo launchctl unload -w /Library/LaunchDaemons/com.wireguard.wg0.plist
```

### Start the service

```bash
# Start immediately
sudo wg-quick up wg0

# Re-register auto-start (after a full stop)
sudo launchctl load -w /Library/LaunchDaemons/com.wireguard.wg0.plist
```

### Check current status

```bash
sudo wg show
# Output shown → running
# "Unable to access interface" → stopped
```

---

## Common commands

```bash
# View VPN connection status and traffic stats
sudo wg show

# Restart WireGuard
sudo wg-quick down wg0 && sudo wg-quick up wg0

# View logs
tail -f /var/log/wireguard-wg0.log
tail -f /var/log/wireguard-wg0.err

# Check whether pfctl NAT rules are active
sudo pfctl -a wireguard -s nat

# Packet capture for debugging (port 51820 traffic)
sudo tcpdump -ni en0 udp port 51820
```

---

## Troubleshooting

### Handshake keeps failing (Handshake did not complete)

Check in order:

1. **Is the server running?**: `sudo wg show` — output means it's running
2. **Is port forwarding configured on the router?**: confirm UDP 51820 is forwarded to the Mac's LAN IP
3. **Does DNS point to the right IP?**: `curl ifconfig.me` to check the current public IP against the domain's resolved address
4. **Confirm traffic is arriving**: `sudo tcpdump -ni any udp port 51820`, reconnect the client, and check for output

### Ping works but web pages won't load

Classic MTU issue. Pings are small (32 bytes); TCP/HTTPS packets are large and exceed WireGuard's effective MTU after encapsulation.

Add this to the client's `[Interface]` section:

```ini
MTU = 1280
```

### Handshake fails when Surge Enhanced Mode is on

WireGuard's reply source IP gets rewritten to `198.18.0.1` by Surge, and the client rejects it.

Add this to Surge's config under `[General]`:

```ini
tun-excluded-routes = <work computer's IP range, e.g. 117.133.0.0/16>
```

### Mac still receives traffic after Windows disconnects the VPN

This is expected. The Windows WireGuard service (`WireGuardTunnel$work-macbook`) may keep running in the background after "Deactivate," and `PersistentKeepalive = 25` sends a keepalive packet every 25 seconds.
Also, port 51820 is exposed publicly, so internet scanners will probe it randomly.
WireGuard validates keys and drops invalid packets outright — this doesn't affect security.

### wg-quick fails to start with `Line unrecognized`

`wg0.conf`'s PostUp/PostDown used `\` line continuation, which wg-quick doesn't support for multi-line commands.
Convert the command to a single line. See the format generated by `setup-server.sh`.

### Interface detection picks up Surge's utun instead of the physical NIC

`route -n get default` returns Surge's virtual interface when Surge Enhanced Mode is on.
`setup-server.sh` now uses `networksetup -listallhardwareports` + `ipconfig getifaddr` to detect the physical NIC instead, avoiding this issue.

### Can't reach other devices on the LAN after a reboot (VPN-to-LAN connectivity broken)

**Symptom**: the WireGuard tunnel itself works fine (`ping 10.13.13.1` succeeds), but other devices on the server's LAN (e.g. `192.168.1.x`) are unreachable — everything worked before the reboot.

**Cause**: macOS's BSD `sed` doesn't interpret `\n` in a replacement string as a newline, so `setup-server.sh` failed to write `nat-anchor "wireguard"` into `/etc/pf.conf`. Before the reboot, pf's in-memory state happened to still be active; after rebooting, macOS reinitializes pf from `/etc/pf.conf`, the anchor reference is missing, NAT no longer applies, the client's packet source address isn't rewritten, and the target device's reply gets lost via the default gateway.

**Verify**:

```bash
# Empty output means the anchor reference is missing
grep 'wireguard' /etc/pf.conf
```

**Fix**:

```bash
sudo cp /etc/pf.conf /etc/pf.conf.bak
sudo sed -i '' 's|nat-anchor "com\.apple/\*"|nat-anchor "com.apple/*"\
nat-anchor "wireguard"|' /etc/pf.conf

# Reload the ruleset and rewrite the anchor rules
sudo pfctl -f /etc/pf.conf
echo 'nat on en0 inet from 10.13.13.0/24 to any -> (en0)' | sudo pfctl -a wireguard -f -
```

`setup-server.sh` has been fixed — re-running the script now fixes this in one shot.

---

## Security notes

- **Key files are not committed to Git**: `.gitignore` excludes `*.key` and the `clients/` directory — don't manually `git add` key files
- **Server private key permissions 600**: stored in `$(brew --prefix)/etc/wireguard/`, readable only by root
- **Client config file permissions 600**: keep it safe after generation — leaking it is equivalent to leaking the private key
- **Rotate keys periodically**: re-running `add-client.sh` for the same client generates a new keypair, invalidating the old config
