#!/bin/sh
# Refresh geoip.dat / geosite.dat for Xray on OpenWrt.
set -e

CONF=/etc/gfw-reality/config
[ -f "${CONF}" ] && . "${CONF}"

XRAY_HOME="${XRAY_HOME:-/opt/gfw-reality}"
mkdir -p "${XRAY_HOME}/share" "${XRAY_HOME}/bin"

fetch() {
  url="$1"
  out="$2"
  if curl -fsSL --connect-timeout 20 -o "${out}.tmp" "${url}"; then
    mv "${out}.tmp" "${out}"
    return 0
  fi
  if curl -fsSL --connect-timeout 20 -o "${out}.tmp" "https://ghfast.top/${url}"; then
    mv "${out}.tmp" "${out}"
    return 0
  fi
  rm -f "${out}.tmp"
  return 1
}

ok=0
for f in geoip.dat geosite.dat; do
  url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/${f}"
  echo "fetch ${f}"
  if fetch "${url}" "${XRAY_HOME}/share/${f}"; then
    cp -a "${XRAY_HOME}/share/${f}" "${XRAY_HOME}/bin/${f}"
    ok=1
    ls -la "${XRAY_HOME}/share/${f}"
  else
    echo "WARN: failed ${f}" >&2
  fi
done

if [ "${ok}" -eq 1 ] && [ -x /etc/init.d/gfw-reality ]; then
  /etc/init.d/gfw-reality restart || true
  sleep 1
  /usr/share/gfw-reality/apply-tproxy.sh reload || true
fi

echo "geo update done $(date)"
