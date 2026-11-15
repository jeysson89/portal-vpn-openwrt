#!/bin/sh
# Keeps the transparent policy applied for as long as the tunnel exists.
# portaltun starts BEFORE sing-box (rc order S99portaltun < S99sing-box), so a
# single tun-policy.sh call at boot silently fails ("tun not found"); this waits
# for portal-tun, applies the policy and then idles as the procd instance.

# fw4 zones are per-interface: portal-tun must belong to the lan zone, otherwise
# forwarded LAN traffic into the tunnel is dropped by the firewall
lanzone=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='lan'$/\1/p" | head -1)
if [ -n "$lanzone" ]; then
  devs=$(uci -q get firewall.$lanzone.device)
  if ! printf '%s\n' $devs | grep -qx portal-tun; then
    uci set firewall.$lanzone.device="${devs:+$devs }portal-tun"
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
    logger -t portal-tun "portal-tun added to lan firewall zone"
  fi
fi

while ! ip route show table 100 2>/dev/null | grep -q '^default dev portal-tun'; do
  # engine paused on purpose: never rebuild the policy, just wait for a start
  if [ -f /etc/portal/engine-paused ]; then
    sleep 30
    continue
  fi
  ip link show portal-tun >/dev/null 2>&1 && /etc/portal/tun-policy.sh >/dev/null 2>&1
  sleep 5
done
exec sleep infinity
