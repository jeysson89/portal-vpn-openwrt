#!/bin/sh
# Per-device traffic accounting for portal-tun; called by cron every minute.
# Counters live in the nft sets inet portalacct up/down (created by tun-policy.sh),
# so this script only snapshots them into /tmp/portal-devices.log.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
DN=$(nft list set inet portalacct down 2>/dev/null)
UP=$(nft list set inet portalacct up 2>/dev/null)
[ -n "$UP" ] || exit 0
ts=$(date +%s)
for ip in $(echo "$UP" | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}'); do
  ub=$(echo "$UP" | sed -n "s/.*$ip counter packets [0-9]* bytes \([0-9]*\).*/\1/p" | head -1)
  db=$(echo "$DN" | sed -n "s/.*$ip counter packets [0-9]* bytes \([0-9]*\).*/\1/p" | head -1)
  [ -n "$ub" ] && [ -n "$db" ] && echo "$ts $ip $db $ub" >> /tmp/portal-devices.log
done
tail -n 5000 /tmp/portal-devices.log > /tmp/pd.tmp 2>/dev/null && mv /tmp/pd.tmp /tmp/portal-devices.log
