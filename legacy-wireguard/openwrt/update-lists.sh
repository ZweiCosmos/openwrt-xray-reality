#!/bin/sh
# Refresh China CIDR + gfwlist → dnsmasq nftset conf on OpenWrt (ash-safe).
set -e

CONF=/etc/gfw-wg-bypass/config
[ -f "${CONF}" ] && . "${CONF}"

LISTDIR="${LISTDIR:-/etc/gfw-wg-bypass}"
WG_MODE="${WG_MODE:-chnroute}"
mkdir -p "${LISTDIR}"

GFWLIST_URL="https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt"

fetch() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --retry 2 "$url" -o "$out"
  else
    wget -q -O "$out" "$url"
  fi
}

update_china() {
  tmp="$(mktemp)"
  ok=0
  for url in \
    "https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt" \
    "https://ispip.clang.cn/all_cn.txt"
  do
    echo "fetch China CIDR: ${url}"
    if fetch "${url}" "${tmp}"; then
      grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "${tmp}" > "${LISTDIR}/china_ipv4.txt" || true
      if [ -s "${LISTDIR}/china_ipv4.txt" ]; then
        ok=1
        break
      fi
    fi
  done
  rm -f "${tmp}"
  if [ "${ok}" -ne 1 ]; then
    echo "failed to download China IP list" >&2
    exit 1
  fi
  # busybox sed: -i and basic regex
  sed -i 's|^\([0-9.]*\)$|\1/32|' "${LISTDIR}/china_ipv4.txt"
  echo "China CIDRs: $(wc -l < "${LISTDIR}/china_ipv4.txt")"
}

update_gfwlist() {
  if [ "${WG_MODE}" = "chnroute" ]; then
    rm -f "${LISTDIR}/dnsmasq_gfwlist_nftset.conf"
    return
  fi

  raw="$(mktemp)"
  decoded="$(mktemp)"
  echo "fetch gfwlist"
  fetch "${GFWLIST_URL}" "${raw}"
  base64 -d "${raw}" > "${decoded}" 2>/dev/null || base64 --decode "${raw}" > "${decoded}"

  out="${LISTDIR}/dnsmasq_gfwlist_nftset.conf"
  : > "${out}"
  awk '
    /^!/ { next }
    /^\[/ { next }
    /^@@/ { next }
    /^[ \t]*$/ { next }
    {
      line=$0
      gsub(/^\|+/, "", line)
      gsub(/^\./, "", line)
      split(line, a, /[\/^]/
      d=a[1]
      if (d ~ /^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/) {
        print d
      }
    }
  ' "${decoded}" | sort -u | while read -r dom; do
    echo "nftset=/${dom}/4#inet#gfw_wg#gfw_proxy4"
  done > "${out}"

  rm -f "${raw}" "${decoded}"
  echo "gfwlist domains: $(wc -l < "${out}")"
}

update_china
update_gfwlist

if [ -x /usr/share/gfw-wg-bypass/apply-routing.sh ]; then
  /usr/share/gfw-wg-bypass/apply-routing.sh reload || true
fi

echo "lists updated at $(date)"
