#!/bin/sh
# Safe policy routing for LAN clients -> portal-tun (IPv4 + IPv6).
# Rule "iif br-lan" matches only packets ARRIVING from LAN clients;
# router-originated traffic (SSH/LuCI replies, DHCP, dnsmasq upstream) stays on main table.
# Usage: tun-policy.sh        -> normal (boot/service) mode, no dead-man switch
#        tun-policy.sh test   -> test mode, auto-rollback after 90s unless confirmed
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
CD=/etc/portal
CONFIRM=/tmp/tun-confirmed
rm -f "$CONFIRM"

# down: give the LAN back to the normal routing (used when the engine is stopped)
if [ "$1" = "down" ]; then
  ip rule del iif br-lan table 100 2>/dev/null
  ip rule del to 8.8.8.8 table 100 2>/dev/null
  ip rule del from 192.168.200.0/24 table 100 2>/dev/null
  while ip rule del pref 9000 2>/dev/null; do :; done
  ip route flush table 100 2>/dev/null
  ip route del 8.8.8.8/32 dev portal-tun 2>/dev/null
  ip -6 rule del iif br-lan table 100 2>/dev/null
  ip -6 route flush table 100 2>/dev/null
  logger -t portal-tun "policy removed (down): LAN goes direct"
  exit 0
fi

if [ "$1" = "test" ]; then
  ( sleep 90
    if [ ! -f "$CONFIRM" ]; then
      ip rule del iif br-lan table 100 2>/dev/null
      ip rule del to 8.8.8.8 table 100 2>/dev/null
      ip route flush table 100 2>/dev/null
      ip route del 8.8.8.8/32 dev portal-tun 2>/dev/null
      ip -6 rule del iif br-lan table 100 2>/dev/null
      ip -6 route flush table 100 2>/dev/null
      logger -t portal-tun "DEADMAN ROLLBACK executed (no confirmation)"
    fi ) >/dev/null 2>&1 &
fi

ip link show portal-tun >/dev/null 2>&1 || { logger -t portal-tun "tun not found"; exit 1; }
# --- IPv4 ---
ip rule del iif br-lan table 100 2>/dev/null
ip rule del to 8.8.8.8 table 100 2>/dev/null
ip rule del from 192.168.200.0/24 table 100 2>/dev/null
ip route flush table 100 2>/dev/null
ip rule add iif br-lan table 100
ip rule add to 8.8.8.8 table 100
ip route add 192.168.200.0/24 dev br-lan table 100 2>/dev/null
ip route add 192.168.10.0/24 dev eth0 table 100 2>/dev/null
ip route add default dev portal-tun table 100
ip route del 8.8.8.8/32 dev portal-tun 2>/dev/null
ip route add 8.8.8.8/32 dev portal-tun metric 100
ip route add 8.8.8.8/32 via 192.168.10.1 dev eth0 metric 300 2>/dev/null
# --- IPv6 (clients -> tun; used by Telegram v6 DCs etc.) ---
ip -6 rule del iif br-lan table 100 2>/dev/null
ip -6 route flush table 100 2>/dev/null
ip -6 rule add iif br-lan table 100
ip -6 route add fd70:757c:7db8::/64 dev br-lan table 100 2>/dev/null
ip -6 route add fdfe:dcba:9876::/64 dev portal-tun table 100 2>/dev/null
ip -6 route add default dev portal-tun table 100
# --- per-device full bypass: IPs from dev-direct.txt skip the tunnel ---
# pref 9000 beats the iif br-lan rules (32765)
for p in $(ip rule | awk '{gsub(/:/,"",$1)} $1==9000{print $3}'); do ip rule del pref 9000 2>/dev/null; done
for p in $(ip -6 rule | awk '{gsub(/:/,"",$1)} $1==9000{print $3}'); do ip -6 rule del pref 9000 2>/dev/null; done
for d in $(awk 'NF' $CD/dev-direct.txt 2>/dev/null | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'); do
  ip rule add from $d lookup main pref 9000
done
logger -t portal-tun "per-device bypass: $(wc -l < $CD/dev-direct.txt 2>/dev/null) clients direct"
# per-device accounting (survives via this re-apply; counters reset on reboot)
nft list table inet portalacct >/dev/null 2>&1 || {
  nft add table inet portalacct
  nft add chain inet portalacct f '{ type filter hook forward priority -140; policy accept; }'
  nft add set inet portalacct up '{ type ipv4_addr; flags dynamic; counter; }'
  nft add set inet portalacct down '{ type ipv4_addr; flags dynamic; counter; }'
  nft add rule inet portalacct f ip saddr 192.168.200.0/24 update @up '{ ip saddr }'
  nft add rule inet portalacct f ip daddr 192.168.200.0/24 update @down '{ ip daddr }'
}
logger -t portal-tun "safe policy applied (v4+v6, iif br-lan)"
exit 0
