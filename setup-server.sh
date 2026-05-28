#!/usr/bin/env bash
# 在家里的 macOS 上运行（需要 sudo）
# 用途：安装 WireGuard 服务端，配置 NAT，开机自启
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ "$(uname)" != "Darwin" ]] && err "此脚本仅支持 macOS"
[[ $EUID -ne 0 ]] && err "请使用 sudo 运行：sudo bash $0"

# ── 安装依赖 ───────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
    warn "未检测到 Homebrew，正在安装..."
    sudo -u "$SUDO_USER" /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

BREW_PREFIX=$(sudo -u "$SUDO_USER" brew --prefix 2>/dev/null || brew --prefix)

if ! command -v wg &>/dev/null; then
    log "安装 wireguard-tools..."
    sudo -u "$SUDO_USER" brew install wireguard-tools
fi

# ── 路径与参数 ─────────────────────────────────────────────────────────────
WG_DIR="${BREW_PREFIX}/etc/wireguard"
WG_PORT=51820
VPN_SUBNET="10.13.13.0"
SERVER_VPN_IP="10.13.13.1"

mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

# 检测出口网络接口（连接互联网的那个）
WAN_IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
[[ -z "$WAN_IFACE" ]] && err "无法自动检测网络接口，请检查网络连接"
log "出口网络接口: $WAN_IFACE"

# ── 生成服务端密钥 ─────────────────────────────────────────────────────────
if [[ ! -f "$WG_DIR/server_private.key" ]]; then
    log "生成服务端密钥对..."
    wg genkey | tee "$WG_DIR/server_private.key" | wg pubkey > "$WG_DIR/server_public.key"
    chmod 600 "$WG_DIR/server_private.key"
else
    log "复用已有服务端密钥"
fi

SERVER_PRIVATE=$(cat "$WG_DIR/server_private.key")
SERVER_PUBLIC=$(cat  "$WG_DIR/server_public.key")

# ── 修改 /etc/pf.conf，添加 wireguard anchor（仅首次）──────────────────────
PF_CONF="/etc/pf.conf"
if ! grep -q 'wireguard' "$PF_CONF" 2>/dev/null; then
    log "备份并更新 /etc/pf.conf..."
    cp "$PF_CONF" "${PF_CONF}.bak.wireguard"
    # 在 nat-anchor "com.apple/*" 后插入 wireguard anchor
    sed -i '' 's|nat-anchor "com\.apple/\*"|nat-anchor "com.apple/*"\nnat-anchor "wireguard"|' "$PF_CONF"
fi

# ── 生成 wg0.conf ──────────────────────────────────────────────────────────
log "生成 ${WG_DIR}/wg0.conf..."
cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE}
Address    = ${SERVER_VPN_IP}/24
ListenPort = ${WG_PORT}

# PostUp：开启 IP 转发 + NAT
PostUp   = sysctl -w net.inet.ip.forwarding=1; \\
           echo 'nat on ${WAN_IFACE} from ${VPN_SUBNET}/24 to any -> (${WAN_IFACE})' \\
           | pfctl -a wireguard -f - 2>/dev/null; \\
           pfctl -e 2>/dev/null || true

# PostDown：清除 NAT 规则，关闭 IP 转发
PostDown = pfctl -a wireguard -F all 2>/dev/null || true; \\
           sysctl -w net.inet.ip.forwarding=0 2>/dev/null || true
EOF
chmod 600 "$WG_DIR/wg0.conf"

# ── 创建 LaunchDaemon（开机自启）──────────────────────────────────────────
PLIST="/Library/LaunchDaemons/com.wireguard.wg0.plist"
log "配置 LaunchDaemon: $PLIST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.wireguard.wg0</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BREW_PREFIX}/bin/wg-quick</string>
        <string>up</string>
        <string>wg0</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/var/log/wireguard-wg0.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/wireguard-wg0.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"

# ── 启动 WireGuard ─────────────────────────────────────────────────────────
log "启动 WireGuard..."
wg-quick down wg0 2>/dev/null || true
wg-quick up wg0

echo ""
echo "═══════════════════════════════════════════════════"
log "服务端初始化完成！"
echo ""
echo "  服务端公钥 : ${SERVER_PUBLIC}"
echo "  VPN 子网   : ${VPN_SUBNET}/24"
echo "  监听端口   : ${WG_PORT}/UDP"
echo ""
warn "还需手动完成一步（路由器设置）："
echo "  在家用路由器上，将 UDP ${WG_PORT} 端口转发到"
echo "  此 Mac 的内网 IP（$(ipconfig getifaddr "$WAN_IFACE" 2>/dev/null || echo '请自行查看')）"
echo ""
echo "  配置完路由器后，运行："
echo "    sudo bash add-client.sh <公司电脑公网IP或名称>"
echo "═══════════════════════════════════════════════════"
