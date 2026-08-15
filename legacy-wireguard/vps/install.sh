#!/usr/bin/env bash
# Install WireGuard server + IP forward + SNAT (MASQUERADE) on VPS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYDIR="${ROOT}/keys"

WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_SERVER_ADDR="${WG_SERVER_ADDR:-10.66.66.1/24}"
WG_CLIENT_ADDR="${WG_CLIENT_ADDR:-10.66.66.2/32}"
WG_NET="${WG_NET:-10.66.66.0/24}"

detect_wan() {
  if [[ -n "${WAN_IF:-}" ]]; then
    echo "${WAN_IF}"
    return
  fi
  ip -4 route show default | awk '{print $5; exit}'
}

need_root() {
  [[ "$(id -u)" -eq 0 ]] || { echo "run as root" >&2; exit 1; }
}

install_pkgs() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y wireguard wireguard-tools iptables iptables-persistent 2>/dev/null \
      || apt-get install -y wireguard wireguard-tools iptables
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wireguard-tools iptables
  else
    echo "unsupported distro; install wireguard-tools manually" >&2
    exit 1
  fi
}

need_root

if [[ ! -f "${KEYDIR}/vps-wg0.conf" ]]; then
  echo "missing ${KEYDIR}/vps-wg0.conf — run bin/gen-keys.sh first" >&2
  exit 1
fi

WAN_IF="$(detect_wan)"
if [[ -z "${WAN_IF}" ]]; then
  echo "cannot detect WAN interface; set WAN_IF=eth0" >&2
  exit 1
fi

echo "WAN interface: ${WAN_IF}"
install_pkgs

mkdir -p /etc/wireguard
umask 077
cp "${KEYDIR}/vps-wg0.conf" "/etc/wireguard/${WG_IF}.conf"

# Inject NAT hooks if not present
if ! grep -q PostUp "/etc/wireguard/${WG_IF}.conf"; then
  tmp="$(mktemp)"
  awk -v wan="${WAN_IF}" -v net="${WG_NET}" '
    BEGIN { added=0 }
    /^\[Interface\]/ { print; next }
    /^PrivateKey/ && !added {
      print
      print "PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -t nat -A POSTROUTING -s " net " -o " wan " -j MASQUERADE; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT"
      print "PostDown = iptables -t nat -D POSTROUTING -s " net " -o " wan " -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT"
      added=1
      next
    }
    { print }
  ' "/etc/wireguard/${WG_IF}.conf" > "${tmp}"
  mv "${tmp}" "/etc/wireguard/${WG_IF}.conf"
  chmod 600 "/etc/wireguard/${WG_IF}.conf"
fi

# Persist IP forward
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-wireguard-forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
sysctl --system >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1

# Firewall: allow WG UDP (ufw if present)
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${WG_PORT}/udp" || true
  ufw route allow in on "${WG_IF}" || true
fi

systemctl enable --now "wg-quick@${WG_IF}"
systemctl restart "wg-quick@${WG_IF}"

echo
echo "VPS WireGuard up:"
wg show
echo
echo "SNAT: ${WG_NET} -> MASQUERADE out ${WAN_IF}"
echo "Open UDP ${WG_PORT} on any cloud security group / firewall."
