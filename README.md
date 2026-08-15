# OpenWrt Xray REALITY

One-click **VLESS + REALITY + Vision** for a VPS + OpenWrt transparent proxy.

China / domestic traffic stays on the ISP path (`geoip:cn`, `geosite:cn`). Other traffic exits via your VPS public IP.

```
LAN (br-lan)
  → nft TPROXY → Xray
       ├─ CN / private → direct (ISP)
       └─ else         → VLESS + REALITY → VPS → Internet
```

## Why REALITY (not plain WireGuard)

Plain WireGuard UDP is easy to fingerprint. VLESS + REALITY mimics a real HTTPS site and resists active probing better under aggressive DPI (e.g. GFW).

## Quick start

### 1. VPS (Debian / Ubuntu)

```bash
git clone https://github.com/<your-anon-account>/openwrt-xray-reality.git
cd openwrt-xray-reality
sudo ./install-server.sh
```

Optional:

```bash
XRAY_PORT=443 REALITY_DEST=www.cloudflare.com sudo ./install-server.sh
```

Produces `client.env` and `client-bundle.tar.gz`.

### 2. OpenWrt (23.05+, nftables)

```bash
scp client-bundle.tar.gz root@OPENWRT:/tmp/
ssh root@OPENWRT
cd /tmp && tar xzf client-bundle.tar.gz && ./install-client.sh
```

Routing modes:

| `ROUTE_MODE` | Behavior |
|--------------|----------|
| `chnroute` (default) | Non-CN → proxy |
| `gfwlist` | GFW-list domains → proxy |
| `hybrid` | GFW domains + non-CN → proxy |
| `global` | All → proxy |

```bash
ROUTE_MODE=hybrid ./install-client.sh
```

### 3. Verify

```bash
sh openwrt/verify.sh
curl -x socks5h://127.0.0.1:1080 -4 https://ifconfig.me
```

## Requirements

- VPS with public IPv4; TCP **443** free (or set `XRAY_PORT`)
- OpenWrt with enough space for Xray (~15–30 MB) and `kmod-nft-tproxy`
- First client install needs GitHub (or a mirror) **or** a preloaded `Xray-linux-<arch>.zip` in `/tmp/`

## Layout

```
install-server.sh          # VPS one-click
install-client.sh          # OpenWrt one-click
openwrt/apply-tproxy.sh    # nft TPROXY
openwrt/update-geo.sh      # geoip/geosite refresh
openwrt/verify.sh
legacy-wireguard/          # old WG split-tunnel (not recommended under hard DPI)
```

## Disclaimer

This project is for learning, research, and protecting privacy where you are legally allowed to do so. **You are responsible for complying with local laws and your VPS provider’s terms.** The authors provide no warranty.

## Credits

- [Xray-core](https://github.com/XTLS/Xray-core) / REALITY
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) geo data

## License

[MIT](LICENSE)
