#!/usr/bin/env bash
# Generate WireGuard server/client keypairs and sample configs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYDIR="${ROOT}/keys"
mkdir -p "${KEYDIR}"

need_wg() {
  if ! command -v wg >/dev/null 2>&1; then
    echo "wireguard-tools (wg) required. Install: apt install wireguard-tools" >&2
    exit 1
  fi
}

need_wg

gen_pair() {
  local name="$1"
  umask 077
  wg genkey | tee "${KEYDIR}/${name}.key" | wg pubkey > "${KEYDIR}/${name}.pub"
}

if [[ ! -f "${KEYDIR}/server.key" ]]; then
  gen_pair server
  echo "generated server keypair"
else
  echo "reuse existing server keypair"
fi

if [[ ! -f "${KEYDIR}/client.key" ]]; then
  gen_pair client
  echo "generated client keypair"
else
  echo "reuse existing client keypair"
fi

SERVER_PRIV="$(cat "${KEYDIR}/server.key")"
SERVER_PUB="$(cat "${KEYDIR}/server.pub")"
CLIENT_PRIV="$(cat "${KEYDIR}/client.key")"
CLIENT_PUB="$(cat "${KEYDIR}/client.pub")"

WG_PORT="${WG_PORT:-51820}"
WG_SERVER_ADDR="${WG_SERVER_ADDR:-10.66.66.1/24}"
WG_CLIENT_ADDR="${WG_CLIENT_ADDR:-10.66.66.2/32}"
WG_SERVER_PUBLIC_IP="${WG_SERVER_PUBLIC_IP:-YOUR_VPS_PUBLIC_IP}"

umask 077
cat > "${KEYDIR}/vps-wg0.conf" <<EOF
[Interface]
Address = ${WG_SERVER_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
# PostUp/PostDown added by vps/install.sh

[Peer]
# OpenWrt
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${WG_CLIENT_ADDR}
EOF

cat > "${KEYDIR}/openwrt-peer.env" <<EOF
WG_PRIVATE_KEY=${CLIENT_PRIV}
WG_SERVER_PUBLIC_KEY=${SERVER_PUB}
WG_SERVER_ENDPOINT=${WG_SERVER_PUBLIC_IP}:${WG_PORT}
WG_ADDRESS=10.66.66.2/24
WG_ALLOWED_IPS=0.0.0.0/0
WG_KEEPALIVE=25
EOF

chmod 600 "${KEYDIR}"/* 2>/dev/null || true

echo
echo "Server public key: ${SERVER_PUB}"
echo "Client public key: ${CLIENT_PUB}"
echo "Wrote:"
echo "  ${KEYDIR}/vps-wg0.conf"
echo "  ${KEYDIR}/openwrt-peer.env"
echo
echo "Set WG_SERVER_PUBLIC_IP before OpenWrt install, or edit openwrt-peer.env"
