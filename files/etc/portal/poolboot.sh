#!/bin/sh
# Bootstrap: fetch a fresh relay pool while the tunnel is down (so the pool
# cannot be resolved through the tunnel itself).
# The resolver must be reachable WITHOUT the tunnel: portal-env.sh gives the
# provider DNS / gateway instead of a hardcoded 192.168.10.1.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /etc/portal/portal-env.sh

ip_jsd=""
BS=""
for s in $WAN_DNS $WAN_GW 1.1.1.1; do
  ip_jsd=$(nslookup cdn.jsdelivr.net "$s" 2>/dev/null | awk '/^Address/{print $2}' \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | grep -v "^$s$" | head -1)
  [ -n "$ip_jsd" ] && { BS=$s; break; }
done
echo "jsdelivr IP: $ip_jsd (resolver: ${BS:-none})"
[ -n "$ip_jsd" ] || { echo "NO_DNS"; exit 1; }
mkdir -p /tmp/poolfetch
curl -sS --max-time 20 --resolve "cdn.jsdelivr.net:443:$ip_jsd" -o /tmp/poolfetch/http.txt "https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/http/data.txt" 2>/dev/null
curl -sS --max-time 20 --resolve "cdn.jsdelivr.net:443:$ip_jsd" -o /tmp/poolfetch/socks.txt "https://cdn.jsdelivr.net/gh/roosterkid/openproxylist@main/SOCKS5_RAW.txt" 2>/dev/null
wc -c /tmp/poolfetch/http.txt /tmp/poolfetch/socks.txt
{
  grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{2,5}' /tmp/poolfetch/http.txt 2>/dev/null | sed 's/^/http:\/\//' | sort -u
  grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{2,5}' /tmp/poolfetch/socks.txt 2>/dev/null | sed 's/^/socks5:\/\//' | sort -u
} > /etc/portal/relay-pool.txt
wc -l /etc/portal/relay-pool.txt
echo POOL_END
