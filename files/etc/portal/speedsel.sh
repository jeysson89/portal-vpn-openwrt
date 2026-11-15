#!/bin/sh
# Relay selection v3: bandwidth-based (direct relay test, no registration needed).
# Guards Telegram: measures DC reachability BEFORE and AFTER switch; rolls back
# if the new relay kills DCs that the old one served.
CD=/etc/portal
LOCK=/tmp/portal-speedsel.lock
# stale lock (killed run) must not disable relay selection forever
if [ -d "$LOCK" ]; then
  lpid=$(cat "$LOCK/pid" 2>/dev/null)
  [ -n "$lpid" ] && [ -d /proc/$lpid ] && exit 0
  rm -rf "$LOCK"
fi
mkdir -p "$LOCK" 2>/dev/null || exit 0
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

POOL=$CD/relay-pool.txt
off=$(( $(date +%s) / 300 ))
CANDS=$( { cat $CD/relay-seeds.txt 2>/dev/null; awk -v off="$off" 'NR % 11 == off % 11' $POOL 2>/dev/null | head -30; } | sort -u )

# pool/seed lines already carry the scheme (http://IP:PORT, socks5://IP:PORT);
# only bare "IP:PORT" entries get http:// prefixed
norm() { case "$1" in *://*) printf '%s' "$1" ;; *) printf 'http://%s' "$1" ;; esac; }

bw_of() { curl -sS --max-time 10 -x "$1" -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=2000000' 2>/dev/null; }
dc_ok() {
  c=$(curl -sSk --max-time 8 -x http://127.0.0.1:18080 -o /dev/null -w '%{http_code}' https://149.154.167.50 2>/dev/null)
  [ "$c" != "000" ] && return 0
  c=$(curl -sSk --max-time 8 -x http://127.0.0.1:18080 -o /dev/null -w '%{http_code}' 'https://[2001:67c:4e8:f004::9]' 2>/dev/null)
  [ "$c" != "000" ] && return 0
  return 1
}
engine_bw() { curl -sS --max-time 20 -x http://127.0.0.1:18080 -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=2000000' 2>/dev/null; }

old=$(cat $CD/relay.conf 2>/dev/null)
old_dc=0; dc_ok && old_dc=1
old_ebw=$(engine_bw)
logger -t portal-relaysel "start: old=$old dc=$old_dc engine_bw=${old_ebw}B/s"

best=""; best_bw=0
for r in $CANDS; do
  [ -n "$r" ] || continue
  r=$(norm "$r")
  [ "$r" = "$old" ] && continue
  b=$(bw_of "$r" 2>/dev/null)
  [ -z "$b" ] && continue
  fast=$(awk -v b="$b" 'BEGIN{print (b>250000)?1:0}')
  [ "$fast" = "1" ] || continue
  logger -t portal-relaysel "candidate $r bw=${b}B/s"
  better=$(awk -v b="$b" -v m="$best_bw" 'BEGIN{print (b>m)?1:0}')
  [ "$better" = "1" ] && { best="$r"; best_bw=$b; }
done

if [ -z "$best" ]; then
  logger -t portal-relaysel "no fast relay found, keeping $old"
  echo "NO_FAST_RELAY"
  exit 0
fi

# a switch costs a 15 s engine restart: only do it for a real improvement
gain=$(awk -v b="$best_bw" -v o="${old_ebw:-0}" 'BEGIN{print (b>o*1.1)?1:0}')
if [ "$gain" != "1" ]; then
  logger -t portal-relaysel "best $best (${best_bw}B/s) is not better than current ${old_ebw}B/s, keeping $old"
  echo "NO_GAIN"
  exit 0
fi

echo "$best" > $CD/relay.conf
logger -t portal-relaysel "selected $best (${best_bw}B/s), restarting engine"
/etc/init.d/portal restart >/dev/null 2>&1
sleep 15

new_dc=0; dc_ok && new_dc=1
new_ebw=$(engine_bw)
logger -t portal-relaysel "after switch: dc=$new_dc engine_bw=${new_ebw}B/s"

# rollback if DCs died (were ok before, broken now)
if [ -n "$old" ] && [ "$old_dc" = "1" ] && [ "$new_dc" = "0" ]; then
  logger -t portal-relaysel "Telegram DC lost on new relay, rolling back to $old"
  echo "$old" > $CD/relay.conf
  /etc/init.d/portal restart >/dev/null 2>&1
  sleep 15
  dc_ok && logger -t portal-relaysel "rollback ok, DCs restored" || logger -t portal-relaysel "rollback done, DCs still failing (path issue)"
  echo "ROLLED_BACK_TO=$old"
  exit 0
fi

st=$(curl -sS --max-time 12 -x http://127.0.0.1:18080 -o /dev/null -w '%{time_total}' https://api.ipify.org 2>/dev/null)
logger -t portal-relaysel "switched to $best, engine check ${st}s"
echo "SELECTED=$best BW=${best_bw} ENGINE=${st}s"
