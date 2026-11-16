#!/bin/sh
# Safe policy routing for LAN clients -> portal-tun (IPv4 + IPv6).
# Rule "iif <lan>" matches only packets ARRIVING from LAN clients;
# router-originated traffic (SSH/LuCI replies, DHCP, dnsmasq upstream) stays on main table.
# Interfaces/networks come from portal-env.sh (UCI + kernel), never hardcoded.
# Usage: tun-policy.sh        -> normal (boot/service) mode, no dead-man switch
#        tun-policy.sh test   -> test mode, auto-rollback after 90s unless confirmed
#        tun-policy.sh down   -> remove the policy, LAN goes direct
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
CD=/etc/portal
. $CD/portal-env.sh
CONFIRM=/tmp/tun-confirmed
rm -f "$CONFIRM"

# remove every rule/route this script may have added (used by "down" and the
# dead-man rollback)
policy_del() {
  [ -n "$LAN_IF" ] && {
    ip rule del iif "$LAN_IF" table 100 2>/dev/null
    ip -6 rule del iif "$LAN_IF" table 100 2>/dev/null
  }
  ip rule del to 8.8.8.8 table 100 2>/dev/null
  [ -n "$LAN_NET" ] && ip rule del from "$LAN_NET" table 100 2>/dev/null
  while ip rule del pref 9000 2>/dev/null; do :; done
  ip route flush table 100 2>/dev/null
  ip route del 8.8.8.8/32 dev portal-tun 2>/dev/null
  ip -6 route flush table 100 2>/dev/null
}

if [ "$1" = "down" ]; then
  policy_del
  logger -t portal-tun "policy removed (down): LAN goes direct"
  exit 0
fi

if [ "$1" = "test" ]; then
  ( sleep 90
    if [ ! -f "$CONFIRM" ]; then
      policy_del
      logger -t portal-tun "DEADMAN ROLLBACK executed (no confirmation)"
    fi ) >/dev/null 2>&1 &
fi

ip link show portal-tun >/dev/null 2>&1 || { logger -t portal-tun "tun not found"; exit 1; }
[ -n "$LAN_IF" ] || { logger -t portal-tun "LAN interface not detected"; exit 1; }

# --- IPv4 ---
policy_del
ip rule add iif "$LAN_IF" table 100
ip rule add to 8.8.8.8 table 100
[ -n "$LAN_NET" ] && ip route add "$LAN_NET" dev "$LAN_IF" table 100 2>/dev/null
[ -n "$WAN_NET" ] && ip route add "$WAN_NET" dev "$WAN_IF" table 100 2>/dev/null
ip route add default dev portal-tun table 100
ip route del 8.8.8.8/32 dev portal-tun 2>/dev/null
ip route add 8.8.8.8/32 dev portal-tun metric 100
# fallback for dnsmasq upstream if the tun is gone (metric beats the LAN rule)
[ -n "$WAN_GW" ] && ip route add 8.8.8.8/32 via "$WAN_GW" dev "$WAN_IF" metric 300 2>/dev/null
# --- IPv6 (clients -> tun; used by Telegram v6 DCs etc.) ---
ip -6 rule add iif "$LAN_IF" table 100
for p in $LAN6_NETS; do
  ip -6 route add "$p" dev "$LAN_IF" table 100 2>/dev/null
done
ip -6 route add fdfe:dcba:9876::/64 dev portal-tun table 100 2>/dev/null
ip -6 route add default dev portal-tun table 100
# --- per-device full bypass: IPs from dev-direct.txt skip the tunnel ---
# pref 9000 beats the iif rule (32765)
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
  [ -n "$LAN_NET" ] && nft add rule inet portalacct f ip saddr "$LAN_NET" update @up '{ ip saddr }'
  [ -n "$LAN_NET" ] && nft add rule inet portalacct f ip daddr "$LAN_NET" update @down '{ ip daddr }'
}
logger -t portal-tun "policy applied: iif $LAN_IF ($LAN_NET) -> portal-tun, wan $WAN_IF ($WAN_GW)"
exit 0
