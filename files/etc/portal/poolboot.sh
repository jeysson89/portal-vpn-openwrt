#!/bin/sh
# Bootstrap: fetch fresh relay pool without working tunnel
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
BS=192.168.10.1
ip_jsd=$(nslookup cdn.jsdelivr.net $BS 2>/dev/null | awk '/^Address/{print $2}' | grep -v "$BS" | head -1)
echo "jsdelivr IP: $ip_jsd"
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
