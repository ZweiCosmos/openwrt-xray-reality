#!/bin/sh
# Apply / tear down selective routing for gfw-wg-bypass on OpenWrt (ash-safe).
set -e

CONF=/etc/gfw-wg-bypass/config
[ -f "${CONF}" ] && . "${CONF}"

WG_IF="${WG_IF:-wg0}"
WG_TABLE="${WG_TABLE:-162}"
WG_MARK="${WG_MARK:-0x162}"
WG_MODE="${WG_MODE:-chnroute}"
WG_ENDPOINT_IP="${WG_ENDPOINT_IP:-}"
SET_CN="gfw_cn4"
SET_GFW="gfw_proxy4"
LISTDIR=/etc/gfw-wg-bypass
NFT_TABLE="inet gfw_wg"

resolve_endpoint_ip() {
  if [ -n "${WG_ENDPOINT_IP}" ]; then
    echo "${WG_ENDPOINT_IP}"
    return
  fi
  host="$(uci -q get network.wg_peer.endpoint_host 2>/dev/null || true)"
  if [ -n "${host}" ]; then
    echo "${host}"
  fi
}

ensure_table_route() {
  if ! grep -q "[[:space:]]${WG_TABLE}[[:space:]]gfw_wg" /etc/iproute2/rt_tables 2>/dev/null; then
    echo "${WG_TABLE} gfw_wg" >> /etc/iproute2/rt_tables
  fi
}

wg_gateway() {
  addr="$(ip -4 -o addr show dev "${WG_IF}" 2>/dev/null | awk '{print $4}' | head -1)"
  if [ -n "${addr}" ]; then
    base="${addr%.*}"
    echo "${base}.1"
  else
    echo "10.66.66.1"
  fi
}

nft_flush() {
  nft delete table ${NFT_TABLE} 2>/dev/null || true
}

nft_base() {
  endpoint="$(resolve_endpoint_ip)"
  nft_flush

  ENDPOINT_RULES=""
  GFW_RULES=""
  MARK_RULES=""
  OUT_ENDPOINT=""
  OUT_GFW=""
  OUT_MARK=""

  if [ -n "${endpoint}" ]; then
    ENDPOINT_RULES="    # WireGuard endpoint must stay on underlay WAN
    ip daddr ${endpoint} return"
    OUT_ENDPOINT="    ip daddr ${endpoint} return"
  fi

  if [ "${WG_MODE}" = "gfwlist" ] || [ "${WG_MODE}" = "hybrid" ]; then
    GFW_RULES="    ip daddr @${SET_GFW} meta mark set ${WG_MARK} return"
    OUT_GFW="    ip daddr @${SET_GFW} meta mark set ${WG_MARK} return"
  fi

  if [ "${WG_MODE}" = "gfwlist" ]; then
    MARK_RULES="    # gfwlist-only: unmarked destinations stay direct"
    OUT_MARK=""
  else
    MARK_RULES="    # chnroute / hybrid: non-China -> WG
    meta mark set ${WG_MARK}"
    OUT_MARK="    meta mark set ${WG_MARK}"
  fi

  nft -f - <<EOF
table ${NFT_TABLE} {
  set ${SET_CN} {
    type ipv4_addr
    flags interval
    auto-merge
  }
  set ${SET_GFW} {
    type ipv4_addr
    flags interval
    auto-merge
  }

  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    iifname "${WG_IF}" return
    ip daddr { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255 } return
${ENDPOINT_RULES}
${GFW_RULES}
    ip daddr @${SET_CN} return
${MARK_RULES}
  }

  chain output {
    type route hook output priority mangle; policy accept;
    oifname "${WG_IF}" return
    ip daddr { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255 } return
${OUT_ENDPOINT}
${OUT_GFW}
    ip daddr @${SET_CN} return
${OUT_MARK}
  }
}
EOF
}

load_cn_set() {
  f="${LISTDIR}/china_ipv4.txt"
  if [ ! -f "${f}" ]; then
    echo "missing ${f}; run update-lists.sh" >&2
    return 1
  fi
  nft flush set ${NFT_TABLE} ${SET_CN}
  batch=""
  n=0
  while read -r cidr; do
    [ -z "${cidr}" ] && continue
    case "${cidr}" in
      \#*) continue ;;
    esac
    if [ -z "${batch}" ]; then
      batch="${cidr}"
    else
      batch="${batch}, ${cidr}"
    fi
    n=$((n + 1))
    if [ $((n % 400)) -eq 0 ]; then
      nft add element ${NFT_TABLE} ${SET_CN} { ${batch} }
      batch=""
    fi
  done < "${f}"
  if [ -n "${batch}" ]; then
    nft add element ${NFT_TABLE} ${SET_CN} { ${batch} }
  fi
  echo "loaded China CIDRs: ${n}"
}

load_gfw_ips_placeholder() {
  f="${LISTDIR}/gfw_extra_ipv4.txt"
  nft flush set ${NFT_TABLE} ${SET_GFW} 2>/dev/null || true
  if [ ! -f "${f}" ]; then
    return 0
  fi
  batch=""
  n=0
  while read -r cidr; do
    [ -z "${cidr}" ] && continue
    case "${cidr}" in
      \#*) continue ;;
    esac
    if [ -z "${batch}" ]; then
      batch="${cidr}"
    else
      batch="${batch}, ${cidr}"
    fi
    n=$((n + 1))
    if [ $((n % 200)) -eq 0 ]; then
      nft add element ${NFT_TABLE} ${SET_GFW} { ${batch} }
      batch=""
    fi
  done < "${f}"
  if [ -n "${batch}" ]; then
    nft add element ${NFT_TABLE} ${SET_GFW} { ${batch} }
  fi
  echo "loaded gfw extra IPs: ${n}"
}

ip_rules() {
  gw="$(wg_gateway)"

  ip route flush table "${WG_TABLE}" 2>/dev/null || true
  ip route add default via "${gw}" dev "${WG_IF}" table "${WG_TABLE}" 2>/dev/null \
    || ip route add default dev "${WG_IF}" table "${WG_TABLE}"

  while ip rule del fwmark "${WG_MARK}" table "${WG_TABLE}" 2>/dev/null; do :; done
  ip rule add fwmark "${WG_MARK}" table "${WG_TABLE}" priority 100

  while ip rule del iif "${WG_IF}" table main 2>/dev/null; do :; done
}

dnsmasq_gfw() {
  conf="/tmp/dnsmasq.d/gfw-wg-nftset.conf"
  mkdir -p /tmp/dnsmasq.d
  if [ "${WG_MODE}" = "chnroute" ]; then
    rm -f "${conf}"
    return
  fi
  if [ -f "${LISTDIR}/dnsmasq_gfwlist_nftset.conf" ]; then
    cp "${LISTDIR}/dnsmasq_gfwlist_nftset.conf" "${conf}"
  else
    echo "warning: no gfwlist dnsmasq conf yet" >&2
  fi
  /etc/init.d/dnsmasq restart 2>/dev/null || true
}

cmd="${1:-start}"

case "${cmd}" in
  stop)
    nft_flush
    ip route flush table "${WG_TABLE}" 2>/dev/null || true
    while ip rule del fwmark "${WG_MARK}" table "${WG_TABLE}" 2>/dev/null; do :; done
    rm -f /tmp/dnsmasq.d/gfw-wg-nftset.conf
    ;;
  start|reload)
    ensure_table_route
    if ! ip link show "${WG_IF}" >/dev/null 2>&1; then
      echo "interface ${WG_IF} not up yet" >&2
      exit 1
    fi
    nft_base
    load_cn_set
    load_gfw_ips_placeholder
    ip_rules
    dnsmasq_gfw
    echo "gfw-wg-bypass routing active (mode=${WG_MODE})"
    ;;
  *)
    echo "usage: $0 start|stop|reload" >&2
    exit 1
    ;;
esac
