#!/bin/sh
# nftables TPROXY: LAN (br-lan) -> Xray dokodemo. China split is inside Xray routing.
set -e

CONF=/etc/gfw-reality/config
[ -f "${CONF}" ] && . "${CONF}"

TPROXY_PORT="${TPROXY_PORT:-12345}"
MARK="${MARK:-0x1}"
XRAY_HOST="${XRAY_HOST:-}"
LAN_IF="${LAN_IF:-br-lan}"
TABLE="inet gfw_reality"

nft_flush() {
  nft delete table ${TABLE} 2>/dev/null || true
}

nft_apply() {
  BYPASS_HOST=""
  if [ -n "${XRAY_HOST}" ]; then
    BYPASS_HOST="ip daddr ${XRAY_HOST} return"
  fi

  nft_flush
  nft -f - <<EOF
table ${TABLE} {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;

    iifname != "${LAN_IF}" return
    meta mark ${MARK} return
    meta mark 255 return

    ip daddr { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16,
               172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255 } return

    ${BYPASS_HOST}

    meta l4proto { tcp, udp } tproxy to :${TPROXY_PORT} meta mark set ${MARK}
  }
}
EOF

  while ip rule del fwmark "${MARK}" lookup 100 2>/dev/null; do :; done
  ip rule add fwmark "${MARK}" lookup 100 priority 100
  ip route flush table 100 2>/dev/null || true
  ip route add local 0.0.0.0/0 dev lo table 100

  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true

  echo "tproxy active: ${LAN_IF} -> :${TPROXY_PORT} (mark ${MARK})"
}

cmd="${1:-start}"
case "${cmd}" in
  stop)
    nft_flush
    while ip rule del fwmark "${MARK}" lookup 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null || true
    ;;
  start|reload)
    nft_apply
    ;;
  *)
    echo "usage: $0 start|stop|reload" >&2
    exit 1
    ;;
esac
