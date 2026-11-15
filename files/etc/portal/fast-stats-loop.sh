#!/bin/sh
# Fast sampler for portal-tun traffic (5 s interval), runs as procd instance.
# Appends lines: ts dur drx dtx  (drx/dtx = bytes over the dur-second window)
S=/sys/class/net/portal-tun/statistics
L=/tmp/portal-traffic-fast.log
ST=/tmp/portal-traffic-fast.state
touch $L 2>/dev/null
while true; do
  [ -d $S ] || { sleep 5; continue; }
  rx=$(cat $S/rx_bytes 2>/dev/null)
  tx=$(cat $S/tx_bytes 2>/dev/null)
  [ -n "$rx" ] || { sleep 5; continue; }
  ts=$(date +%s)
  if [ -f $ST ]; then
    read -r prx ptx pts < $ST
    if [ "$ts" -gt "$pts" ] 2>/dev/null; then
      drx=$((rx - prx)); dtx=$((tx - ptx))
      [ $drx -lt 0 ] && drx=0
      [ $dtx -lt 0 ] && dtx=0
      dur=$((ts - pts))
      [ $dur -lt 1 ] && dur=1
      echo "$ts $dur $drx $dtx" >> $L
      tail -n 90 $L > $L.tmp 2>/dev/null && mv $L.tmp $L
      echo "$rx $tx $ts" > $ST
    fi
  else
    echo "$rx $tx $ts" > $ST
  fi
  sleep 5
done
