#!/usr/bin/env bash
# 在家里的 macOS 服务端上运行（需要 sudo）
# 用途：为一台新设备生成 WireGuard 客户端配置
# 用法：sudo bash add-client.sh <客户端名称> <家里的公网IP>
#   示例：sudo bash add-client.sh work-macbook 123.45.67.89
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ "$(uname)" != "Darwin" ]] && err "此脚本仅支持 macOS"
[[ $EUID -ne 0 ]] && err "请使用 sudo 运行：sudo bash $0 <名称> <公网IP>"

BREW_PREFIX=$(brew --prefix)
WG_DIR="${BREW_PREFIX}/etc/wireguard"

[[ ! -f "$WG_DIR/wg0.conf" ]]        && err "找不到 wg0.conf，请先运行 setup-server.sh"
[[ ! -f "$WG_DIR/server_public.key" ]] && err "找不到服务端公钥"

# ── 参数 ───────────────────────────────────────────────────────────────────
CLIENT_NAME="${1:-}"
PUBLIC_IP="${2:-}"

if [[ -z "$CLIENT_NAME" ]]; then
    read -rp "客户端名称（如 work-macbook）: " CLIENT_NAME
fi
CLIENT_NAME="${CLIENT_NAME// /-}"   # 空格换成连字符

if [[ -z "$PUBLIC_IP" ]]; then
    read -rp "家里的公网 IP 地址: " PUBLIC_IP
fi

# ── 分配 VPN IP ────────────────────────────────────────────────────────────
SERVER_PUBLIC=$(cat "$WG_DIR/server_public.key")
WG_PORT=$(awk '/^ListenPort/{print $3}' "$WG_DIR/wg0.conf")

# 找已用的最大末位 IP，加 1 分配给新客户端
LAST_OCTET=$(grep -oE '10\.13\.13\.([0-9]+)/32' "$WG_DIR/wg0.conf" 2>/dev/null \
    | grep -oE '\.[0-9]+/' | grep -oE '[0-9]+' | sort -n | tail -1 || echo "1")
CLIENT_IP="10.13.13.$((LAST_OCTET + 1))"

# ── 生成客户端密钥 ─────────────────────────────────────────────────────────
CLIENT_DIR="$WG_DIR/clients/$CLIENT_NAME"
mkdir -p "$CLIENT_DIR"
chmod 700 "$CLIENT_DIR"

log "生成密钥对..."
wg genkey | tee "$CLIENT_DIR/private.key" | wg pubkey > "$CLIENT_DIR/public.key"
chmod 600 "$CLIENT_DIR/private.key"

CLIENT_PRIVATE=$(cat "$CLIENT_DIR/private.key")
CLIENT_PUBLIC=$(cat  "$CLIENT_DIR/public.key")

# ── 写入客户端配置文件 ─────────────────────────────────────────────────────
CONFIG_FILE="$CLIENT_DIR/${CLIENT_NAME}.conf"
log "生成 ${CONFIG_FILE}..."
cat > "$CONFIG_FILE" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE}
Address    = ${CLIENT_IP}/24
DNS        = 8.8.8.8, 8.8.4.4
# MTU 设为 1280 避免大包被丢弃（WireGuard 封装有额外开销）
MTU        = 1280

[Peer]
PublicKey           = ${SERVER_PUBLIC}
Endpoint            = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs          = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
chmod 600 "$CONFIG_FILE"

# ── 把新 Peer 追加到服务端 wg0.conf ───────────────────────────────────────
cat >> "$WG_DIR/wg0.conf" <<EOF

# Client: ${CLIENT_NAME}
[Peer]
PublicKey  = ${CLIENT_PUBLIC}
AllowedIPs = ${CLIENT_IP}/32
EOF

# ── 热更新服务端（无需重启 WireGuard）────────────────────────────────────
if wg show wg0 &>/dev/null 2>&1; then
    log "热加载新 Peer 到运行中的 WireGuard..."
    wg set wg0 peer "$CLIENT_PUBLIC" allowed-ips "${CLIENT_IP}/32"
else
    warn "WireGuard 当前未运行，配置已写入，下次启动生效"
fi

# ── 打印二维码（便于手机端扫码导入）──────────────────────────────────────
if command -v qrencode &>/dev/null; then
    echo ""
    log "扫码导入（WireGuard 手机 App）："
    qrencode -t ansiutf8 < "$CONFIG_FILE"
else
    warn "安装 qrencode 可生成二维码：brew install qrencode"
fi

echo ""
echo "═══════════════════════════════════════════════════"
log "客户端 '${CLIENT_NAME}' 配置完成！"
echo ""
echo "  VPN IP    : ${CLIENT_IP}"
echo "  配置文件  : ${CONFIG_FILE}"
echo ""
echo "公司电脑导入方式："
echo "  macOS / Windows  → 打开 WireGuard App，导入上面的 .conf 文件"
echo "  Linux            → sudo wg-quick up ${CONFIG_FILE}"
echo "═══════════════════════════════════════════════════"
