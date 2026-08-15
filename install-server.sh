#!/usr/bin/env bash
# One-click VPS installer: Xray VLESS + REALITY (+ Vision).
# Usage (root on VPS):
#   ./install-server.sh
#   REALITY_DEST=www.cloudflare.com XRAY_PORT=443 ./install-server.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
KEYDIR="${ROOT}/keys"
XRAY_DIR="${XRAY_DIR:-/usr/local/etc/xray}"
XRAY_BIN_DIR="${XRAY_BIN_DIR:-/usr/local/bin}"
OUT_ENV="${ROOT}/client.env"
OUT_BUNDLE="${ROOT}/client-bundle.tar.gz"

XRAY_PORT="${XRAY_PORT:-443}"
REALITY_DEST_HOST="${REALITY_DEST:-www.microsoft.com}"
REALITY_DEST="${REALITY_DEST_HOST}:443"
REALITY_SERVER_NAMES="${REALITY_SERVER_NAMES:-${REALITY_DEST_HOST}}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }

need_root() {
  [[ "$(id -u)" -eq 0 ]] || { red "Run as root: sudo $0"; exit 1; }
}

detect_public_ip() {
  if [[ -n "${SERVER_PUBLIC_IP:-}" ]]; then
    echo "${SERVER_PUBLIC_IP}"
    return
  fi
  local ip=""
  for url in \
    "https://ifconfig.me" \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com"
  do
    ip="$(curl -4 -fsS --connect-timeout 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "${ip}"
      return
    fi
  done
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

install_pkgs() {
  ylw "[1/6] Installing dependencies..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl unzip openssl ca-certificates jq 2>/dev/null \
      || apt-get install -y curl unzip openssl ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl unzip openssl ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl unzip openssl ca-certificates
  else
    red "Need apt/dnf + curl/unzip"
    exit 1
  fi
}

install_xray() {
  ylw "[2/6] Installing Xray-core..."
  if [[ -x "${XRAY_BIN_DIR}/xray" ]] && "${XRAY_BIN_DIR}/xray" version >/dev/null 2>&1; then
    ylw "  xray already present: $(${XRAY_BIN_DIR}/xray version | head -1)"
    return
  fi
  # Official installer
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  command -v xray >/dev/null || [[ -x /usr/local/bin/xray ]] || {
    red "Xray install failed"
    exit 1
  }
  # normalize path
  if [[ ! -x "${XRAY_BIN_DIR}/xray" && -x /usr/local/bin/xray ]]; then
    XRAY_BIN_DIR=/usr/local/bin
  fi
}

gen_credentials() {
  ylw "[3/6] Generating REALITY credentials..."
  mkdir -p "${KEYDIR}" "${XRAY_DIR}"
  umask 077

  if [[ -f "${KEYDIR}/uuid" ]]; then
    UUID="$(cat "${KEYDIR}/uuid")"
  else
    if command -v xray >/dev/null 2>&1; then
      UUID="$(xray uuid)"
    elif [[ -x /usr/local/bin/xray ]]; then
      UUID="$(/usr/local/bin/xray uuid)"
    else
      UUID="$(cat /proc/sys/kernel/random/uuid)"
    fi
    echo "${UUID}" > "${KEYDIR}/uuid"
  fi

  if [[ -f "${KEYDIR}/reality.json" ]]; then
    PRIVATE_KEY="$(jq -r .privateKey "${KEYDIR}/reality.json" 2>/dev/null || true)"
    PUBLIC_KEY="$(jq -r .publicKey "${KEYDIR}/reality.json" 2>/dev/null || true)"
  fi
  if [[ -z "${PRIVATE_KEY:-}" || -z "${PUBLIC_KEY:-}" || "${PRIVATE_KEY}" == "null" ]]; then
    # xray x25519 output: PrivateKey: xxx \n Password: xxx (public)  -- format varies by version
    local raw
    raw="$(xray x25519 2>/dev/null || /usr/local/bin/xray x25519)"
    PRIVATE_KEY="$(echo "${raw}" | awk -F': ' '/Private/{print $2; exit}')"
    PUBLIC_KEY="$(echo "${raw}" | awk -F': ' '/Public|Password/{print $2; exit}')"
    if [[ -z "${PRIVATE_KEY}" || -z "${PUBLIC_KEY}" ]]; then
      red "Failed to parse xray x25519 output:"
      echo "${raw}"
      exit 1
    fi
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg p "${PRIVATE_KEY}" --arg u "${PUBLIC_KEY}" \
        '{privateKey:$p, publicKey:$u}' > "${KEYDIR}/reality.json"
    else
      printf 'privateKey=%s\npublicKey=%s\n' "${PRIVATE_KEY}" "${PUBLIC_KEY}" > "${KEYDIR}/reality.env"
    fi
  fi

  if [[ -f "${KEYDIR}/short_id" ]]; then
    SHORT_ID="$(cat "${KEYDIR}/short_id")"
  else
    SHORT_ID="$(openssl rand -hex 4)"
    echo "${SHORT_ID}" > "${KEYDIR}/short_id"
  fi

  PUB_IP="$(detect_public_ip)"
  [[ -n "${PUB_IP}" ]] || { red "Cannot detect public IP; export SERVER_PUBLIC_IP=x.x.x.x"; exit 1; }
  echo "${PUB_IP}" > "${KEYDIR}/public_ip.txt"
}

write_server_config() {
  ylw "[4/6] Writing Xray server config..."
  mkdir -p "${XRAY_DIR}"
  cat > "${XRAY_DIR}/config.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SERVER_NAMES}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
  chmod 600 "${XRAY_DIR}/config.json"
}

open_firewall() {
  ylw "[5/6] Opening port ${XRAY_PORT}/tcp..."
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${XRAY_PORT}/tcp" || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${XRAY_PORT}/tcp" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
  fi
  # warn if something already bound
  if ss -lntp 2>/dev/null | grep -q ":${XRAY_PORT} " && ! ss -lntp 2>/dev/null | grep -q xray; then
    ylw "WARNING: port ${XRAY_PORT} may be in use by another service (nginx/caddy). Prefer a free port or stop it."
  fi
}

start_xray() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^xray.service'; then
    systemctl enable xray
    systemctl restart xray
  else
    # fallback service
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray VLESS REALITY
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${XRAY_BIN_DIR}/xray run -config ${XRAY_DIR}/config.json
Restart=on-failure
RestartSec=3
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now xray
    systemctl restart xray
  fi
  sleep 1
  systemctl --no-pager --full status xray | head -20 || true
  xray -test -config "${XRAY_DIR}/config.json" || /usr/local/bin/xray -test -config "${XRAY_DIR}/config.json"
}

emit_client() {
  ylw "[6/6] Writing client.env + bundle..."
  PUB_IP="$(cat "${KEYDIR}/public_ip.txt")"
  # resolve public key if only in reality.env
  if [[ -z "${PUBLIC_KEY:-}" && -f "${KEYDIR}/reality.json" ]]; then
    PUBLIC_KEY="$(jq -r .publicKey "${KEYDIR}/reality.json")"
  fi
  if [[ -z "${PUBLIC_KEY:-}" && -f "${KEYDIR}/reality.env" ]]; then
    # shellcheck disable=SC1090
    . "${KEYDIR}/reality.env"
  fi

  umask 077
  cat > "${OUT_ENV}" <<EOF
# Generated by install-server.sh (VLESS + REALITY + Vision)
# Copy to OpenWrt and run: ./install-client.sh
XRAY_UUID=${UUID}
XRAY_HOST=${PUB_IP}
XRAY_PORT=${XRAY_PORT}
XRAY_FLOW=xtls-rprx-vision
REALITY_PUBLIC_KEY=${PUBLIC_KEY}
REALITY_SHORT_ID=${SHORT_ID}
REALITY_SERVER_NAME=${REALITY_SERVER_NAMES}
REALITY_FINGERPRINT=chrome
# OpenWrt routing mode: chnroute | gfwlist | hybrid | global
ROUTE_MODE=chnroute
EOF
  chmod 600 "${OUT_ENV}"

  tar -C "${ROOT}" -czf "${OUT_BUNDLE}" \
    client.env \
    install-client.sh \
    openwrt \
    2>/dev/null || tar -C "${ROOT}" -czf "${OUT_BUNDLE}" client.env install-client.sh

  grn "============================================================"
  grn " SERVER OK  (VLESS + REALITY + Vision)"
  grn "============================================================"
  echo "Endpoint     : ${PUB_IP}:${XRAY_PORT}"
  echo "SNI / dest   : ${REALITY_SERVER_NAMES} -> ${REALITY_DEST}"
  echo "UUID         : ${UUID}"
  echo "Public key   : ${PUBLIC_KEY}"
  echo "Short ID     : ${SHORT_ID}"
  echo
  echo "Client files:"
  echo "  ${OUT_ENV}"
  echo "  ${OUT_BUNDLE}"
  echo
  ylw "On your PC -> OpenWrt:"
  echo "  scp ${OUT_BUNDLE} root@OPENWRT_IP:/tmp/"
  echo "  ssh root@OPENWRT_IP"
  echo "  cd /tmp && tar xzf client-bundle.tar.gz && ./install-client.sh"
}

need_root
install_pkgs
install_xray
gen_credentials
write_server_config
open_firewall
start_xray
emit_client
