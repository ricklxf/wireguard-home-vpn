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
3. Generates `clients/work-macbook/work-macbook.conf` (includes `MTU = 1280` to avoid large packets being dropped) — written next to the script itself and owned by the user who ran `sudo`, not root, so Finder/AirDrop can access it directly with no extra steps
4. Hot-reloads the running WireGuard instance (no restart needed)
5. Prints a QR code for mobile import if `qrencode` is installed

### Step 4: Import the config on the work computer

| System | Method |
|------|------|
| macOS / Windows | Install the [WireGuard App](https://www.wireguard.com/install/), import the `.conf` file |
| Linux | `sudo wg-quick up /path/to/work-macbook.conf` |
| iOS / Android | Install the WireGuard App, scan the QR code |

Once enabled, `AllowedIPs = 0.0.0.0/0, ::/0` means **all traffic** (IPv4 + IPv6) is routed home through the VPN tunnel.

### Removing a client (lost device or no longer needed)

```bash
sudo bash remove-client.sh work-macbook
```

The script automatically:

1. Removes the peer from the running WireGuard instance (takes effect immediately, no restart needed)
2. Deletes the corresponding config from the server's `wg0.conf`
3. Deletes the locally stored keys and config file

Once removed, the device can no longer connect even if it still has the old `.conf` file.

> Don't share one config file across multiple devices — WireGuard identifies peers by private key, so multiple devices using the same config will fight over the connection and keep dropping. Generate a separate one per device with `add-client.sh`.

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

### `wg show wg0` / `add-client.sh` wrongly reports WireGuard as not running

**Symptom**: WireGuard is clearly running fine (other devices can connect and handshake), yet `sudo wg show wg0` fails with `Unable to access interface: No such file or directory`, and `add-client.sh` reports "WireGuard is not currently running" when generating a new client — the new client's peer never gets hot-loaded.

**Cause**: macOS has no native WireGuard kernel module, so `wg-quick` carries the tunnel over a generic `utun` interface (e.g. `utun4`). `wg0` is just an alias `wg-quick` keeps track of itself in `/var/run/wireguard/wg0.name`, used only by `wg-quick up`/`down` internally. The raw `wg` command doesn't understand that alias at all — it looks directly for `/var/run/wireguard/<interface-name>.sock`. Passing `wg0` makes it look for a nonexistent `wg0.sock`, while the real socket is named `utun4.sock`, so it always fails.

**Verify**:

```bash
sudo wg show
# Note the "interface: utunN" line, then query again with the real name
sudo wg show utunN
```

**Fix**: `add-client.sh` now automatically reads `/var/run/wireguard/wg0.name` to resolve the real interface name before operating on it — no manual intervention needed. If you're on an older version of the script, hot-load the new peer manually:

```bash
cat /var/run/wireguard/wg0.name   # shows the real interface name, e.g. utun4
sudo wg set utun4 peer <client public key> allowed-ips <client VPN IP>/32
```

### Can't find the generated client config in Finder / `ls` reports Permission denied

**Cause**: earlier versions of `add-client.sh` generated client files under `$(brew --prefix)/etc/wireguard/clients/`, a `700` directory owned by root (to protect the server's private key). The logged-in user and Finder have no permission to enter it — the file isn't missing, it's just inaccessible.

**Fix**: `add-client.sh` now generates client files in a `clients/` directory next to the script itself, and `chown`s them back to whichever user ran `sudo` — so they're accessible via Finder/AirDrop right away, no extra steps needed.

If your client files were generated by an older version of the script and are still under `$(brew --prefix)/etc/wireguard/clients/`, copy them out with `sudo` first:

```bash
sudo cp $(brew --prefix)/etc/wireguard/clients/<client-name>/<client-name>.conf ~/Desktop/
sudo chown $(whoami) ~/Desktop/<client-name>.conf
# After AirDropping it
rm ~/Desktop/<client-name>.conf
```

---

## Security notes

- **Key files are not committed to Git**: `.gitignore` excludes `*.key` and the `clients/` directory — don't manually `git add` key files
- **Server private key permissions 600**: stored in `$(brew --prefix)/etc/wireguard/`, readable only by root
- **Client config file permissions 600**: keep it safe after generation — leaking it is equivalent to leaking the private key
- **Rotate keys periodically**: re-running `add-client.sh` for the same client generates a new keypair, invalidating the old config
