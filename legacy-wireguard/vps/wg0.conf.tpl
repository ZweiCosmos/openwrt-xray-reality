[Interface]
Address = __WG_SERVER_ADDR__
ListenPort = __WG_PORT__
PrivateKey = __SERVER_PRIV__
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -t nat -A POSTROUTING -s __WG_NET__ -o __WAN_IF__ -j MASQUERADE; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s __WG_NET__ -o __WAN_IF__ -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT

[Peer]
PublicKey = __CLIENT_PUB__
AllowedIPs = __WG_CLIENT_ADDR__
