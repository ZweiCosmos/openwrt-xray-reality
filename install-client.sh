#!/bin/sh
# One-click OpenWrt client: Xray VLESS+REALITY transparent proxy + CN split.
# Usage (root on OpenWrt):
#   ./install-client.sh
#   ./install-client.sh /path/client.env
#   ROUTE_MODE=hybrid ./install-client.sh
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${1:-${ROOT}/client.env}"
XRAY_HOME="${XRAY_HOME:-/opt/gfw-reality}"
TPROXY_PORT="${TPROXY_PORT:-12345}"
MARK="${MARK:-0x1}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }

need_root() {
  [ "$(id -u)" -eq 0 ] || { red "Run as root on OpenWrt"; exit 1; }
}

load_env() {
  if [ ! -f "${ENV_FILE}" ]; then
    red "Missing ${ENV_FILE} (from install-server.sh)"
    exit 1
  fi
  ylw "Using env: ${ENV_FILE}"
  CLEAN="$(mktemp)"
  tr -d '\r' < "${ENV_FILE}" > "${CLEAN}"
  # shellcheck disable=SC1090
  . "${CLEAN}"
  rm -f "${CLEAN}"

  if [ -z "${XRAY_UUID:-}" ] || [ -z "${XRAY_HOST:-}" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
    red "client.env incomplete (need XRAY_UUID, XRAY_HOST, REALITY_PUBLIC_KEY, ...)"
    exit 1
  fi
  XRAY_PORT="${XRAY_PORT:-443}"
  XRAY_FLOW="${XRAY_FLOW:-xtls-rprx-vision}"
  REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.microsoft.com}"
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"
  REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-chrome}"
  ROUTE_MODE="${ROUTE_MODE:-chnroute}"
}

detect_xray_asset() {
  # Map OpenWrt arch -> Xray release asset name
  arch="$(opkg print-architecture 2>/dev/null | awk 'NR==1{print $2}')"
  [ -n "${arch}" ] || arch="$(uname -m)"
  case "${arch}" in
    aarch64*|arm64*) echo "arm64-v8a" ;;
    arm_cortex-a7*|arm_cortex-a9*|arm_cortex-a15*|armv7*|arm*) echo "arm32-v7a" ;;
    mipsel*|mips_24kc*|mips_4kec*) echo "mips32le" ;;
    mips*) echo "mips32" ;;
    x86_64*|amd64*) echo "64" ;;
    i386*|i686*|x86*) echo "32" ;;
    *)
      red "Unsupported arch: ${arch}. Set XRAY_ASSET=arm64-v8a manually."
      exit 1
      ;;
  esac
}

install_pkgs() {
  ylw "[1/5] Installing packages..."
  opkg update
  opkg install curl ca-bundle unzip kmod-nft-tproxy kmod-inet-diag \
    iptables-mod-tproxy 2>/dev/null || true
  opkg install curl ca-bundle unzip || true
  # nft tproxy package name varies
  opkg install kmod-nft-tproxy 2>/dev/null || true
  command -v curl >/dev/null || { red "curl required"; exit 1; }
}

install_xray_bin() {
  ylw "[2/5] Installing Xray binary + geo data..."
  mkdir -p "${XRAY_HOME}/bin" "${XRAY_HOME}/share" /var/log/xray

  if [ -x "${XRAY_HOME}/bin/xray" ] && [ "${FORCE_XRAY_REINSTALL:-0}" != "1" ]; then
    ylw "  reuse ${XRAY_HOME}/bin/xray"
  else
    asset="${XRAY_ASSET:-$(detect_xray_asset)}"
    tmp="$(mktemp -d)"
    # Offline path: drop zip on router first (chicken-egg if GitHub blocked)
    pre="/tmp/Xray-linux-${asset}.zip"
    if [ -f "${pre}" ]; then
      ylw "  using preloaded ${pre}"
      cp "${pre}" "${tmp}/xray.zip"
    else
      ver="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
      [ -n "${ver}" ] || ver="v25.12.8"
      url="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${asset}.zip"
      ylw "  download ${url}"
      if ! curl -fsSL -o "${tmp}/xray.zip" "${url}"; then
        ylw "  retry mirror..."
        curl -fsSL -o "${tmp}/xray.zip" "https://ghfast.top/${url}" || {
          red "Download failed. On a PC with GitHub access:"
          red "  scp Xray-linux-${asset}.zip root@OPENWRT:/tmp/"
          red "  then rerun ./install-client.sh"
          exit 1
        }
      fi
    fi
    unzip -o "${tmp}/xray.zip" -d "${tmp}/out"
    install -m 755 "${tmp}/out/xray" "${XRAY_HOME}/bin/xray"
    rm -rf "${tmp}"
  fi

  # geoip / geosite (Loyalsoldier - better CN coverage)
  for f in geoip.dat geosite.dat; do
    if [ ! -f "${XRAY_HOME}/share/${f}" ] || [ "${FORCE_GEO_UPDATE:-0}" = "1" ]; then
      ylw "  fetch ${f}"
      url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/${f}"
      if ! curl -fsSL -o "${XRAY_HOME}/share/${f}" "${url}"; then
        curl -fsSL -o "${XRAY_HOME}/share/${f}" "https://ghfast.top/${url}" || true
      fi
    fi
  done
  # also place beside binary (xray default search)
  ln -sf "${XRAY_HOME}/share/geoip.dat" "${XRAY_HOME}/bin/geoip.dat" 2>/dev/null || \
    cp -a "${XRAY_HOME}/share/geoip.dat" "${XRAY_HOME}/bin/" 2>/dev/null || true
  ln -sf "${XRAY_HOME}/share/geosite.dat" "${XRAY_HOME}/bin/geosite.dat" 2>/dev/null || \
    cp -a "${XRAY_HOME}/share/geosite.dat" "${XRAY_HOME}/bin/" 2>/dev/null || true

  "${XRAY_HOME}/bin/xray" version | head -3
}

write_xray_config() {
  ylw "[3/5] Writing Xray client config (mode=${ROUTE_MODE})..."
  mkdir -p "${XRAY_HOME}"
  cp "${ENV_FILE}" "${XRAY_HOME}/client.env"

  # routing rules by mode
  case "${ROUTE_MODE}" in
    global)
      RULES='
        {"type":"field","ip":["geoip:private"],"outboundTag":"direct"},
        {"type":"field","port":"0-65535","outboundTag":"proxy"}'
      ;;
    gfwlist)
      RULES='
        {"type":"field","ip":["geoip:private","geoip:cn"],"outboundTag":"direct"},
        {"type":"field","domain":["geosite:cn"],"outboundTag":"direct"},
        {"type":"field","domain":["geosite:gfw"],"outboundTag":"proxy"},
        {"type":"field","domain":["geosite:greatfire"],"outboundTag":"proxy"},
        {"type":"field","port":"0-65535","outboundTag":"direct"}'
      ;;
    hybrid)
      RULES='
        {"type":"field","ip":["geoip:private"],"outboundTag":"direct"},
        {"type":"field","domain":["geosite:gfw","geosite:greatfire"],"outboundTag":"proxy"},
        {"type":"field","ip":["geoip:cn"],"outboundTag":"direct"},
        {"type":"field","domain":["geosite:cn"],"outboundTag":"direct"},
        {"type":"field","port":"0-65535","outboundTag":"proxy"}'
      ;;
    chnroute|*)
      RULES='
        {"type":"field","ip":["geoip:private","geoip:cn"],"outboundTag":"direct"},
        {"type":"field","domain":["geosite:cn"],"outboundTag":"direct"},
        {"type":"field","port":"0-65535","outboundTag":"proxy"}'
      ;;
  esac

  cat > "${XRAY_HOME}/config.json" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      {
        "address": "https://1.1.1.1/dns-query",
        "domains": ["geosite:geolocation-!cn"],
        "expectIPs": ["geoip:!cn"]
      },
      {
        "address": "223.5.5.5",
        "domains": ["geosite:cn"],
        "expectIPs": ["geoip:cn"]
      },
      "localhost"
    ],
    "queryStrategy": "UseIPv4",
    "tag": "dns-in"
  },
  "inbounds": [
    {
      "tag": "tproxy-in",
      "port": ${TPROXY_PORT},
      "listen": "0.0.0.0",
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    },
    {
      "tag": "socks-in",
      "port": 1080,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${XRAY_HOST}",
            "port": ${XRAY_PORT},
            "users": [
              {
                "id": "${XRAY_UUID}",
                "encryption": "none",
                "flow": "${XRAY_FLOW}"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "fingerprint": "${REALITY_FINGERPRINT}",
          "serverName": "${REALITY_SERVER_NAME}",
          "publicKey": "${REALITY_PUBLIC_KEY}",
          "shortId": "${REALITY_SHORT_ID}",
          "spiderX": "/"
        },
        "sockopt": {
          "tcpFastOpen": true,
          "tcpNoDelay": true,
          "mark": 255
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "streamSettings": {
        "sockopt": {
          "mark": 255
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    },
    {
      "tag": "dns-out",
      "protocol": "dns"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type":"field","inboundTag":["dns-in"],"outboundTag":"dns-out"},
      {"type":"field","ip":["${XRAY_HOST}"],"outboundTag":"direct"},
${RULES}
    ]
  }
}
EOF

  # persist runtime config
  mkdir -p /etc/gfw-reality
  cat > /etc/gfw-reality/config <<EOF
XRAY_HOME=${XRAY_HOME}
TPROXY_PORT=${TPROXY_PORT}
MARK=${MARK}
XRAY_HOST=${XRAY_HOST}
XRAY_PORT=${XRAY_PORT}
ROUTE_MODE=${ROUTE_MODE}
LAN_IF=${LAN_IF:-br-lan}
EOF
}

install_service_and_routing() {
  ylw "[4/5] Installing service + nft tproxy..."
  mkdir -p /usr/share/gfw-reality /etc/hotplug.d/iface

  cp -a "${ROOT}/openwrt/apply-tproxy.sh" /usr/share/gfw-reality/
  cp -a "${ROOT}/openwrt/update-geo.sh" /usr/share/gfw-reality/
  chmod +x /usr/share/gfw-reality/*.sh

  if [ -f "${ROOT}/openwrt/hotplug-iface-99-gfw-reality" ]; then
    cp -a "${ROOT}/openwrt/hotplug-iface-99-gfw-reality" /etc/hotplug.d/iface/99-gfw-reality
    chmod +x /etc/hotplug.d/iface/99-gfw-reality
  fi

  cat > /etc/init.d/gfw-reality <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command ${XRAY_HOME}/bin/xray run -config ${XRAY_HOME}/config.json
  procd_set_param respawn
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
  # apply nft after xray listens
  ( sleep 1; /usr/share/gfw-reality/apply-tproxy.sh start ) &
}

stop_service() {
  /usr/share/gfw-reality/apply-tproxy.sh stop || true
}

reload_service() {
  /usr/share/gfw-reality/apply-tproxy.sh reload || true
}
EOF
  chmod +x /etc/init.d/gfw-reality
  /etc/init.d/gfw-reality enable

  # weekly geo update
  if ! grep -q 'gfw-reality/update-geo' /etc/crontabs/root 2>/dev/null; then
    mkdir -p /etc/crontabs
    echo '30 4 * * 1 /usr/share/gfw-reality/update-geo.sh >/tmp/gfw-reality-geo.log 2>&1' >> /etc/crontabs/root
    /etc/init.d/cron enable 2>/dev/null || true
    /etc/init.d/cron restart 2>/dev/null || true
  fi
}

bring_up() {
  ylw "[5/5] Starting..."
  /etc/init.d/gfw-reality restart
  sleep 2
  /usr/share/gfw-reality/apply-tproxy.sh start

  if [ -x "${ROOT}/openwrt/verify.sh" ]; then
    sh "${ROOT}/openwrt/verify.sh" || true
  fi

  grn "============================================================"
  grn " CLIENT OK  (VLESS + REALITY, mode=${ROUTE_MODE})"
  grn "============================================================"
  echo "Server   : ${XRAY_HOST}:${XRAY_PORT}"
  echo "SNI      : ${REALITY_SERVER_NAME}"
  echo "TPROXY   : :${TPROXY_PORT}"
  echo "SOCKS    : 127.0.0.1:1080 (router-local test)"
  echo
  echo "Test from a LAN client, or on router:"
  echo "  curl -x socks5h://127.0.0.1:1080 -4 https://ifconfig.me"
  echo "  curl -4 https://www.baidu.com -o /dev/null -w '%{http_code}\\n'"
}

need_root
load_env
[ -f "${ROOT}/openwrt/apply-tproxy.sh" ] || { red "Missing openwrt/ helpers - use client-bundle.tar.gz"; exit 1; }
install_pkgs
install_xray_bin
write_xray_config
install_service_and_routing
bring_up
