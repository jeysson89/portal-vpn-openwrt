#!/bin/sh
# Sweep fresh pool: find relays accepting new connections NOW, pick fastest
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
CD=/etc/portal
off=$(( $(date +%s) / 120 ))
alive=""
i=0
for r in $(awk -v off="$off" 'NR % 37 == off % 37' $CD/relay-pool.txt | head -60); do
  [ -n "$r" ] || continue
  c=$(curl -sS --max-time 4 -x "$r" -o /dev/null -w '%{http_code}' https://www.example.com/ 2>/dev/null)
  [ "$c" != "000" ] && [ -n "$c" ] && { echo "ALIVE $r"; alive="$alive $r"; i=$((i+1)); }
  [ $i -ge 6 ] && break
done
[ -z "$alive" ] && { echo "NO_ALIVE"; exit 1; }
best=""; best_bw=0
for r in $alive; do
  b=$(curl -sS --max-time 15 -x "$r" -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=1000000' 2>/dev/null)
  echo "$r bw=${b}B/s"
  cmp=$(awk -v b="${b:-0}" -v m="$best_bw" 'BEGIN{print (b>m)?1:0}')
  [ "$cmp" = "1" ] && { best_bw=$b; best="$r"; }
done
# never blank relay.conf: an empty value makes the engine fall back to defaults
[ -n "$best" ] || { echo "NO_BEST"; exit 1; }
echo "BEST=$best BW=$best_bw"
echo "$best" > $CD/relay.conf
echo "SWEEP_DONE"
