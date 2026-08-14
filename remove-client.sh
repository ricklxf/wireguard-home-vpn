#!/usr/bin/env bash
# 在家里的 macOS 服务端上运行（需要 sudo）
# 用途：删除一个 WireGuard 客户端，撤销其访问权限
# 用法：sudo bash remove-client.sh <客户端名称>
#   示例：sudo bash remove-client.sh iphone
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ "$(uname)" != "Darwin" ]] && err "此脚本仅支持 macOS"
[[ $EUID -ne 0 ]] && err "请使用 sudo 运行：sudo bash $0 <客户端名称>"

BREW_PREFIX=$(brew --prefix)
WG_DIR="${BREW_PREFIX}/etc/wireguard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CLIENT_NAME="${1:-}"
if [[ -z "$CLIENT_NAME" ]]; then
    read -rp "要删除的客户端名称: " CLIENT_NAME
fi

CLIENT_DIR="$SCRIPT_DIR/clients/$CLIENT_NAME"
[[ ! -d "$CLIENT_DIR" ]]          && err "找不到客户端 '$CLIENT_NAME'（$CLIENT_DIR 不存在）"
[[ ! -f "$CLIENT_DIR/public.key" ]] && err "找不到 $CLIENT_DIR/public.key"

CLIENT_PUBLIC=$(cat "$CLIENT_DIR/public.key")

# ── 从运行中的接口摘掉这个 peer（立即生效）──────────────────────────────
# macOS 上 wg-quick 用 utunN 作为真实接口，wg0 只是 /var/run/wireguard/wg0.name
# 里记录的别名，原始的 wg 命令不认这个别名，必须解析出真实接口名再操作
WG_REAL_IF=""
[[ -f /var/run/wireguard/wg0.name ]] && WG_REAL_IF=$(cat /var/run/wireguard/wg0.name)

if [[ -n "$WG_REAL_IF" ]] && wg show "$WG_REAL_IF" &>/dev/null 2>&1; then
    log "从运行中的 WireGuard 摘除 peer..."
    wg set "$WG_REAL_IF" peer "$CLIENT_PUBLIC" remove
else
    warn "WireGuard 当前未运行，跳过热移除"
fi

# ── 从 wg0.conf 里删掉对应的 [Peer] 块 ───────────────────────────────────
log "从 wg0.conf 移除配置..."
awk -v marker="# Client: ${CLIENT_NAME}" '
    $0 == marker { skip=1; next }
    skip && /^\[Peer\]/   { next }
    skip && /^PublicKey/  { next }
    skip && /^AllowedIPs/ { skip=0; next }
    { print }
' "$WG_DIR/wg0.conf" > "$WG_DIR/wg0.conf.tmp"
mv "$WG_DIR/wg0.conf.tmp" "$WG_DIR/wg0.conf"
chmod 600 "$WG_DIR/wg0.conf"

# ── 删除密钥和配置文件 ────────────────────────────────────────────────────
log "删除客户端文件..."
rm -rf "$CLIENT_DIR"

echo ""
log "客户端 '${CLIENT_NAME}' 已删除，无法再连接"
