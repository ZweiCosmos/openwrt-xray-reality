#!/usr/bin/env bash
# Install WireGuard client + selective GFW routing on OpenWrt (fw4/nft).
# Modes: chnroute | gfwlist | hybrid
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYENV="${ROOT}/keys/openwrt-peer.env"
WG_IF="${WG_IF:-wg0}"
WG_TABLE="${WG_TABLE:-162}"
WG_MARK="${WG_MARK:-0x162}"
WG_MODE="${WG_MODE:-chnroute}"

need_root() {
  [[ "$(id -u)" -eq 0 ]] || { echo "run as root on OpenWrt" >&2; exit 1; }
}

load_env() {
  if [[ -f "${KEYENV}" ]]; then
    # shellcheck disable=SC1090
    set -a
    # strip possible Windows CR
    source <(tr -d '\r' < "${KEYENV}")
    set +a
  fi
  : "${WG_PRIVATE_KEY:?set WG_PRIVATE_KEY or create keys/openwrt-peer.env}"
  : "${WG_SERVER_PUBLIC_KEY:?set WG_SERVER_PUBLIC_KEY}"
  : "${WG_SERVER_ENDPOINT:?set WG_SERVER_ENDPOINT like x.x.x.x:51820}"
  WG_ADDRESS="${WG_ADDRESS:-10.66.66.2/24}"
  WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-0.0.0.0/0}"
  WG_KEEPALIVE="${WG_KEEPALIVE:-25}"
}

install_pkgs() {
  opkg update
  # dnsmasq-full needed for nftset (gfwlist/hybrid)
  if opkg list-installed | grep -q '^dnsmasq '; then
    opkg remove dnsmasq --force-depends || true
  fi
  opkg install wireguard-tools luci-proto-wireguard \
    kmod-wireguard ip-full \
    dnsmasq-full curl ca-bundle || true
  # resolve symlinks for ip
  if ! command -v ip >/dev/null 2>&1; then
    echo "ip-full required" >&2
    exit 1
  fi
}

uci_wg() {
  # Remove prior interface if re-running
  while uci -q delete network."${WG_IF}"; do :; done
  while uci -q delete network.wg_peer; do :; done

  uci batch <<EOF
set network.${WG_IF}=interface
set network.${WG_IF}.proto='wireguard'
set network.${WG_IF}.private_key='${WG_PRIVATE_KEY}'
set network.${WG_IF}.listen_port='0'
add_list network.${WG_IF}.addresses='${WG_ADDRESS}'
set network.${WG_IF}.mtu='1280'
set network.${WG_IF}.nohostroute='1'

set network.wg_peer=wireguard_${WG_IF}
set network.wg_peer.public_key='${WG_SERVER_PUBLIC_KEY}'
set network.wg_peer.endpoint_host='${WG_SERVER_ENDPOINT%%:*}'
set network.wg_peer.endpoint_port='${WG_SERVER_ENDPOINT##*:}'
set network.wg_peer.persistent_keepalive='${WG_KEEPALIVE}'
set network.wg_peer.route_allowed_ips='0'
add_list network.wg_peer.allowed_ips='${WG_ALLOWED_IPS}'
EOF

  # Firewall zone: treat WG like WAN for forward
  if ! uci -q get firewall.wg >/dev/null; then
    uci batch <<EOF
set firewall.wg=zone
set firewall.wg.name='wg'
set firewall.wg.input='REJECT'
set firewall.wg.output='ACCEPT'
set firewall.wg.forward='REJECT'
set firewall.wg.masq='0'
set firewall.wg.mtu_fix='1'
add_list firewall.wg.network='${WG_IF}'

set firewall.lan_wg=forwarding
set firewall.lan_wg.src='lan'
set firewall.lan_wg.dest='wg'
EOF
  fi
  uci commit network
  uci commit firewall
}

install_routing_helper() {
  mkdir -p /usr/share/gfw-wg-bypass /etc/gfw-wg-bypass
  cp -a "${ROOT}/openwrt/update-lists.sh" /usr/share/gfw-wg-bypass/
  cp -a "${ROOT}/openwrt/apply-routing.sh" /usr/share/gfw-wg-bypass/
  chmod +x /usr/share/gfw-wg-bypass/*.sh
  mkdir -p /etc/hotplug.d/iface
  cp -a "${ROOT}/openwrt/hotplug-iface-99-gfw-wg-bypass" /etc/hotplug.d/iface/99-gfw-wg-bypass
  chmod +x /etc/hotplug.d/iface/99-gfw-wg-bypass

  cat > /etc/gfw-wg-bypass/config <<EOF
WG_IF=${WG_IF}
WG_TABLE=${WG_TABLE}
WG_MARK=${WG_MARK}
WG_MODE=${WG_MODE}
WG_ENDPOINT_IP=${WG_SERVER_ENDPOINT%%:*}
EOF

  cat > /etc/init.d/gfw-wg-bypass <<'INIT'
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1

start_service() {
  /usr/share/gfw-wg-bypass/apply-routing.sh start
}

stop_service() {
  /usr/share/gfw-wg-bypass/apply-routing.sh stop
}

reload_service() {
  /usr/share/gfw-wg-bypass/apply-routing.sh reload
}
INIT
  chmod +x /etc/init.d/gfw-wg-bypass
  /etc/init.d/gfw-wg-bypass enable

  # Daily list refresh at 04:17
  if ! grep -q 'gfw-wg-bypass/update-lists' /etc/crontabs/root 2>/dev/null; then
    mkdir -p /etc/crontabs
    echo '17 4 * * * /usr/share/gfw-wg-bypass/update-lists.sh >/tmp/gfw-wg-update.log 2>&1' >> /etc/crontabs/root
    /etc/init.d/cron enable 2>/dev/null || true
    /etc/init.d/cron restart 2>/dev/null || true
  fi
}

need_root
load_env
install_pkgs
uci_wg
install_routing_helper

/etc/init.d/network reload
sleep 2
/usr/share/gfw-wg-bypass/update-lists.sh
/etc/init.d/gfw-wg-bypass restart
/etc/init.d/firewall restart

echo
echo "OpenWrt WG client installed. Mode=${WG_MODE}"
wg show || true
echo "Check: traceroute -n 1.1.1.1  (via tunnel) vs 223.5.5.5 (direct)"
