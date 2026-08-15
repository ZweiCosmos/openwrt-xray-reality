#!/bin/sh
# Sanity checks for gfw-reality on OpenWrt
set -e

echo "== xray =="
if [ -x /opt/gfw-reality/bin/xray ]; then
  /opt/gfw-reality/bin/xray version | head -2
else
  echo "xray binary missing"
fi

echo "== service =="
/etc/init.d/gfw-reality status 2>/dev/null || true
pgrep -a xray 2>/dev/null || ps | grep -v grep | grep xray || true

echo "== listen =="
netstat -lntp 2>/dev/null | grep -E '12345|1080' || ss -lntp 2>/dev/null | grep -E '12345|1080' || true

echo "== nft =="
nft list table inet gfw_reality 2>/dev/null | head -40 || echo "nft table missing"

echo "== ip rule =="
ip rule show | grep -E 'fwmark|lookup 100' || true
ip route show table 100 2>/dev/null || true

echo "== socks probe (via REALITY) =="
if command -v curl >/dev/null 2>&1; then
  curl -m 15 -x socks5h://127.0.0.1:1080 -4 -fsS https://ifconfig.me && echo || echo "socks probe failed"
fi
