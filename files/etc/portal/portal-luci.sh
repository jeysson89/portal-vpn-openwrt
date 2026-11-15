#!/bin/sh
CD=/etc/portal

# `ps | grep opera-proxy | head -1` can hit the procd `sh -c` wrapper or a stale
# orphan (PIDs are recycled on 256 MB), so the engine PID is taken from /proc by
# comm and the newest instance wins — otherwise PID/uptime in the UI lie
engine_pids() {
  for d in /proc/[0-9]*; do
    [ "$(cat $d/comm 2>/dev/null)" = "opera-proxy" ] && echo "${d#/proc/}"
  done
}

engine_pid() {
  best=""; bestt=-1
  for p in $(engine_pids); do
    t=$(awk '{print $22}' /proc/$p/stat 2>/dev/null)
    [ -n "$t" ] || t=0
    if [ "$t" -gt "$bestt" ]; then bestt="$t"; best="$p"; fi
  done
  echo "$best"
}

# regenerate sing-box config from the lists, restart it and re-apply the
# transparent policy (routes to `dev portal-tun` die with the tun device,
# so the policy must always be re-applied AFTER a sing-box restart)
apply_config() {
  genout=$($CD/filter-gen.sh 2>&1)
  case "$genout" in
    OK:*)
      # engine stopped on purpose: applying the policy would send the LAN into
      # a tunnel nobody serves, so only the files are regenerated
      if [ -f $CD/engine-paused ]; then
        echo "${1:-}Сохранено. $genout; движок остановлен, sing-box не перезапускался"
        return
      fi
      /etc/init.d/sing-box restart >/dev/null 2>&1
      sleep 10
      $CD/tun-policy.sh >/dev/null 2>&1
      ip link show portal-tun >/dev/null 2>&1 && t="tun UP" || t="tun ОТСУТСТВУЕТ"
      echo "${1:-}Сохранено. $genout; sing-box перезапущен: $t"
      ;;
    *) echo "$genout" ;;
  esac
}

# text file -> {"bypass":"line\nline\n"} JSON (one escaper for both lists)
jsontext() {
  printf '{"bypass":"'
  sed 's/\\/\\\\/g; s/"/\\"/g' "$1" 2>/dev/null | sed 's/$/\\n/' | tr -d '\n'
  printf '"}'
}

# sing-box recreates the tun asynchronously; fixed sleeps made the tabs feel
# stuck, so wait for the device instead (max 15 s, usually 3-5 s)
wait_tun() {
  i=0
  while [ $i -lt 15 ]; do
    ip link show portal-tun >/dev/null 2>&1 && return 0
    sleep 1
    i=$((i+1))
  done
  return 1
}

# bring the whole chain up: engine -> sing-box tun -> transparent policy
start_engine() {
  rm -f $CD/engine-paused
  # intent marker lives in /tmp: survives a manual stop/start but not a reboot,
  # so the watchdog can tell "crash after manual start" from "boot with autostart off"
  touch /tmp/portal-engine-intent
  /etc/init.d/portal start >/dev/null 2>&1
  sleep 6
  /etc/init.d/sing-box start >/dev/null 2>&1
  sleep 2
  $CD/tun-policy.sh >/dev/null 2>&1
  pid=$(engine_pid)
}

# `start` is a no-op for procd when the instance already runs, so a real restart
# needs init.d restart; the policy is re-applied afterwards because the old tun
# (and every route pointing at it) dies with the old sing-box process
restart_engine() {
  rm -f $CD/engine-paused
  touch /tmp/portal-engine-intent
  /etc/init.d/portal restart >/dev/null 2>&1
  sleep 6
  /etc/init.d/sing-box restart >/dev/null 2>&1
  sleep 3
  wait_tun
  $CD/tun-policy.sh >/dev/null 2>&1
  pid=$(engine_pid)
}

case "$1" in
status)
  pid=$(engine_pid)
  running=1; [ -z "$pid" ] && running=0
  relay=$(cat $CD/relay.conf 2>/dev/null)
  country=$(cat $CD/country.conf 2>/dev/null); [ -z "$country" ] && country=AM
  bcount=$(grep -cv -e '^#' -e '^$' $CD/filter-domains.txt 2>/dev/null)
  pool=$(wc -l < $CD/relay-pool.txt 2>/dev/null); [ -z "$pool" ] && pool=0
  up=0
  if [ -n "$pid" ] && [ -f /proc/$pid/stat ]; then
    start=$(awk '{print $22}' /proc/$pid/stat 2>/dev/null)
    now=$(awk '{print int($1)}' /proc/uptime)
    up=$((now - start / 100)); [ $up -lt 0 ] && up=0
  fi
  # autostart is only real when both the engine and sing-box are enabled
  auto=0
  ls /etc/rc.d/S[0-9][0-9]portal >/dev/null 2>&1 && ls /etc/rc.d/S[0-9][0-9]sing-box >/dev/null 2>&1 && auto=1
  paused=0; [ -f $CD/engine-paused ] && paused=1
  printf '{"running":%s,"pid":"%s","relay":"%s","country":"%s","bypass_count":%s,"pool":%s,"uptime":%s,"autostart":%s,"paused":%s}' \
    "$running" "${pid:-0}" "$relay" "$country" "${bcount:-0}" "$pool" "$up" "$auto" "$paused"
  ;;
exitip)
  # night relay latency reaches 10-16 s, so both echo services run in parallel
  # and the first valid answer wins
  T=/tmp/portal-exitip.$$
  curl -sS --max-time 18 -x http://127.0.0.1:18080 https://api.ipify.org > $T.1 2>/dev/null &
  curl -sS --max-time 18 -x http://127.0.0.1:18080 http://ifconfig.me/ip > $T.2 2>/dev/null &
  wait
  ip=$(cat $T.1 2>/dev/null)
  case "$ip" in
    *[0-9].[0-9]*|*:*) ;;
    *) ip=$(cat $T.2 2>/dev/null) ;;
  esac
  rm -f $T.1 $T.2
  case "$ip" in
    *[0-9].[0-9]*|*:*) printf '{"exit_ip":"%s"}' "$ip" ;;
    *) printf '{"exit_ip":""}' ;;
  esac
  ;;
test)
  ip=$(curl -sS --max-time 25 -x http://127.0.0.1:18080 https://api.ipify.org 2>/dev/null)
  case "$ip" in
    *[0-9].[0-9]*|*:*) printf '{"exit_ip":"%s"}' "$ip" ;;
    *) printf '{"error":"tunnel failed"}' ;;
  esac
  ;;
restart)
  restart_engine
  printf '{"restarted":1,"pid":"%s"}' "${pid:-0}"
  ;;
watch)
  (setsid $CD/portal-watch.sh >/dev/null 2>&1 </dev/null &)
  printf '{"watch_started":1}'
  ;;
start)
  start_engine
  if [ -n "$pid" ]; then printf '{"started":1,"pid":"%s"}' "$pid"; else printf '{"started":0,"pid":"0"}'; fi
  ;;
stop)
  touch $CD/engine-paused
  rm -f /tmp/portal-engine-intent
  /etc/init.d/portal stop >/dev/null 2>&1
  sleep 2
  for p in $(engine_pids); do kill $p 2>/dev/null; done
  sleep 1
  # stop sing-box too: without a tun device nothing can silently route the LAN
  # into a tunnel that has no engine (black hole); also saves RAM on 256 MB
  /etc/init.d/sing-box stop >/dev/null 2>&1
  sleep 2
  $CD/tun-policy.sh down >/dev/null 2>&1
  pid=$(engine_pid)
  if [ -z "$pid" ]; then printf '{"stopped":1}'; else printf '{"stopped":0,"pid":"%s"}' "$pid"; fi
  ;;
setautostart)
  case "$2" in
    on)
      /etc/init.d/portal enable >/dev/null 2>&1
      /etc/init.d/portalstats enable >/dev/null 2>&1
      /etc/init.d/portaltun enable >/dev/null 2>&1
      # sing-box without the engine would build a tun nobody serves
      /etc/init.d/sing-box enable >/dev/null 2>&1
      printf '{"enabled":1}'
      ;;
    off)
      /etc/init.d/portal disable >/dev/null 2>&1
      /etc/init.d/portalstats disable >/dev/null 2>&1
      /etc/init.d/portaltun disable >/dev/null 2>&1
      /etc/init.d/sing-box disable >/dev/null 2>&1
      printf '{"enabled":0}'
      ;;
    *) printf '{"error":"bad arg"}' ;;
  esac
  ;;
setrelay)
  case "$2" in
    http://*|https://*|socks5://*|socks5h://*)
      echo "$2" > $CD/relay.conf
      [ -f $CD/engine-paused ] || { /etc/init.d/portal restart >/dev/null 2>&1; sleep 3; }
      printf '{"relay":"%s"}' "$(cat $CD/relay.conf)"
      ;;
    *) printf '{"error":"bad relay url"}' ;;
  esac
  ;;
setcountry)
  case "$2" in
    AM|EU)
      echo "$2" > $CD/country.conf
      [ -f $CD/engine-paused ] || { /etc/init.d/portal restart >/dev/null 2>&1; sleep 3; }
      printf '{"country":"%s"}' "$(cat $CD/country.conf)"
      ;;
    *) printf '{"error":"bad country"}' ;;
  esac
  ;;
getwhite|getfilter|getbypass)
  jsontext $CD/filter-domains.txt
  ;;
getblack)
  jsontext $CD/filter-black.txt
  ;;
applygen)
  apply_config
  ;;
setwhite|setfilter|setbypass)
  printf '%s' "$2" | tr -d '\r' > $CD/filter-domains.txt
  apply_config
  ;;
setblack)
  printf '%s' "$2" | tr -d '\r' > $CD/filter-black.txt
  apply_config
  ;;
devlist)
  echo "#lease"
  awk '$4=="*"{print $3" -"} $4!="*"{print $3" "$4}' /tmp/dhcp.leases 2>/dev/null
  echo "#direct"
  awk 'NF' $CD/dev-direct.txt 2>/dev/null
  echo "#full"
  awk 'NF' $CD/dev-full.txt 2>/dev/null
  echo "#proxy"
  awk 'NF' $CD/dev-proxy.txt 2>/dev/null
  echo DEVLIST_END
  ;;
setdevs)
  printf '%s' "$2" | tr ',' '\n' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' > $CD/dev-direct.txt
  printf '%s' "$3" | tr ',' '\n' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' > $CD/dev-full.txt
  printf '%s' "$4" | tr ',' '\n' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' > $CD/dev-proxy.txt
  apply_config "Устройства: сквозной=$(wc -l < $CD/dev-direct.txt 2>/dev/null), полный=$(wc -l < $CD/dev-full.txt 2>/dev/null), обход=$(wc -l < $CD/dev-proxy.txt 2>/dev/null). "
  ;;
presets)
  echo "#white"
  cat $CD/presets-white.txt 2>/dev/null
  echo "#black"
  cat $CD/presets-black.txt 2>/dev/null
  echo PRESETS_END
  ;;
logs)
  logread 2>/dev/null | grep -E 'portal|opera-proxy' | tail -40
  ;;
logssb)
  logread 2>/dev/null | grep sing-box | tail -30
  ;;
routing)
  echo "== sing-box =="
  p=$(ps | grep 'sing-box run' | grep -v grep | awk '{print $1}' | head -1)
  if [ -n "$p" ]; then echo "запущен, PID $p"; else echo "НЕ ЗАПУЩЕН"; fi
  ip link show portal-tun >/dev/null 2>&1 && echo "tun: portal-tun UP" || echo "tun: ОТСУТСТВУЕТ"
  echo "== ip rule v4 (table 100) =="
  ip rule | grep 100
  echo "== ip rule v6 (table 100) =="
  ip -6 rule | grep 100
  echo "== таблица 100 v4 =="
  ip route show table 100
  if ip route show table 100 | grep -q '^default dev portal-tun'; then
    echo "-> default через portal-tun: ЕСТЬ (LAN в VPN)"
  else
    echo "-> default через portal-tun: НЕТ — LAN идёт напрямую (политика не применена)"
  fi
  echo "== таблица 100 v6 =="
  ip -6 route show table 100
  echo "== firewall lan zone devices =="
  uci -q get firewall.@zone[0].device | tr ' ' '\n'
  echo "== dnsmasq =="
  echo "noresolv=$(uci -q get dhcp.@dnsmasq[0].noresolv) filter_aaaa=$(uci -q get dhcp.@dnsmasq[0].filter_aaaa) server=$(uci -q get dhcp.@dnsmasq[0].server)"
  echo "== RA / DHCPv6 =="
  echo "ra=$(uci -q get dhcp.lan.ra) ra_default=$(uci -q get dhcp.lan.ra_default) ra_slaac=$(uci -q get dhcp.lan.ra_slaac) dhcpv6=$(uci -q get dhcp.lan.dhcpv6)"
  echo "== конфиг sing-box =="
  cfg=$(wc -c < /etc/sing-box/config.json)
  echo "размер: ${cfg} байт (конфиг генерируется из filter-domains.txt скриптом filter-gen.sh)"
  /usr/bin/sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 && echo "check: OK" || echo "check: FAIL"
  ;;
applypolicy)
  if [ -f $CD/engine-paused ]; then
    echo "Движок остановлен: политика не применяется, иначе LAN уйдёт в мёртвый туннель. Сначала «Запустить» на вкладке «Статус»."
    exit 0
  fi
  /etc/portal/tun-policy.sh 2>/dev/null
  echo "tun-policy применена: правил v4=$(ip rule | grep -c 100) v6=$(ip -6 rule | grep -c 100)"
  ;;
restartsb)
  if [ -f $CD/engine-paused ]; then
    echo "Движок остановлен: sing-box не перезапускается. Сначала «Запустить» на вкладке «Статус»."
    exit 0
  fi
  /etc/init.d/sing-box restart >/dev/null 2>&1
  sleep 10
  # restarting sing-box recreates portal-tun: routes in table 100 die with the
  # device, so the policy has to be re-applied or the LAN falls back to direct
  $CD/tun-policy.sh >/dev/null 2>&1
  ip link show portal-tun >/dev/null 2>&1 && t="tun UP" || t="tun ОТСУТСТВУЕТ"
  echo "sing-box перезапущен: $t, правил v4=$(ip rule | grep -c 100) v6=$(ip -6 rule | grep -c 100)"
  ;;
routetest)
  ip rule add to 1.1.1.1 table 100 2>/dev/null
  r1=$(curl -sSk --max-time 20 -o /dev/null -w '%{http_code} за %{time_total}с' https://1.1.1.1 2>/dev/null)
  ip rule del to 1.1.1.1 table 100 2>/dev/null
  r2=$(curl -sSk --max-time 20 -o /dev/null -w '%{http_code} за %{time_total}с' -A Mozilla/5.0 https://ya.ru 2>/dev/null)
  r3=$(curl -sSk --max-time 25 -x http://127.0.0.1:18080 -o /dev/null -w '%{http_code} за %{time_total}с' https://www.google.com 2>/dev/null)
  echo "1.1.1.1 через tun: $r1 (301 = ок)"
  echo "ya.ru напрямую: $r2 (302 = ок)"
  echo "google через opera: $r3 (200 = ок)"
  ;;
statslive)
  # cumulative counters since the tun device was created: no cron/state file
  # needed, and they reset together with the tunnel (single source of truth)
  S=/sys/class/net/portal-tun/statistics
  live=0; rx=0; tx=0
  if [ -d "$S" ]; then
    live=1
    rx=$(cat $S/rx_bytes 2>/dev/null); tx=$(cat $S/tx_bytes 2>/dev/null)
  fi
  printf '{"tun":%s,"tot_rx":%s,"tot_tx":%s}' "$live" "${rx:-0}" "${tx:-0}"
  ;;
fastgraph)
  cat /tmp/portal-traffic-fast.log 2>/dev/null
  ;;
devices)
  awk '{a[$2]=$3" "$4} END{for(i in a) print i" "a[i]}' /tmp/portal-devices.log 2>/dev/null | while read ip db ub; do
    name=$(awk -v i="$ip" '$3==i{print $4; exit}' /tmp/dhcp.leases 2>/dev/null)
    echo "$ip ${name:--} $db $ub"
  done
  ;;
scanstatus)
  if grep -q SCAN_DONE /tmp/scan-speed.log 2>/dev/null; then
    cat /tmp/scan-speed.log
  elif [ -f /tmp/scan-speed.log ]; then
    cat /tmp/scan-speed.log; echo "[скан ещё идёт...]"
  else
    echo "скан не запускался"
  fi
  ;;
pings)
  pj() {
    r=$(ping -c 1 -W 2 "$1" 2>/dev/null | grep -o 'time=[0-9.]*' | cut -d= -f2)
    if [ -n "$r" ]; then printf '{"ok":1,"ms":%s}' "$r"; else printf '{"ok":0,"ms":null}'; fi
  }
  tj() {
    t=$(curl -sSk --max-time 15 -x http://127.0.0.1:18080 -o /dev/null -w '%{time_total}' "$1" 2>/dev/null)
    if [ $? = 0 ] && [ -n "$t" ]; then
      awk -v t="$t" 'BEGIN{printf "{\"ok\":1,\"ms\":%.0f}", t*1000}'
    else
      printf '{"ok":0,"ms":null}'
    fi
  }
  # all probes in parallel: sequential run took up to 50 s and the tab looked stuck
  T=/tmp/portal-pings.$$
  pj ya.ru              > $T.ya 2>/dev/null &
  pj mail.ru            > $T.mail 2>/dev/null &
  pj gosuslugi.ru       > $T.gosuslugi 2>/dev/null &
  pj 1.1.1.1            > $T.wan 2>/dev/null &
  tj https://www.gstatic.com/generate_204 > $T.tun_gstatic 2>/dev/null &
  tj https://www.youtube.com/generate_204 > $T.tun_youtube 2>/dev/null &
  curl -sS --max-time 18 -x http://127.0.0.1:18080 https://api.ipify.org > $T.eip 2>/dev/null &
  curl -sS --max-time 18 -x http://127.0.0.1:18080 http://ifconfig.me/ip > $T.eip2 2>/dev/null &
  wait
  eip=$(cat $T.eip 2>/dev/null)
  case "$eip" in *[0-9].[0-9]*|*:*) : ;; *) eip=$(cat $T.eip2 2>/dev/null) ;; esac
  case "$eip" in *[0-9].[0-9]*|*:*) : ;; *) eip="" ;; esac
  printf '{"exit_ip":"%s","ya":%s,"mail":%s,"gosuslugi":%s,"wan":%s,"tun_gstatic":%s,"tun_youtube":%s}' \
    "$eip" \
    "$(cat $T.ya 2>/dev/null)" "$(cat $T.mail 2>/dev/null)" "$(cat $T.gosuslugi 2>/dev/null)" "$(cat $T.wan 2>/dev/null)" \
    "$(cat $T.tun_gstatic 2>/dev/null)" "$(cat $T.tun_youtube 2>/dev/null)"
  rm -f $T.* $T
  ;;
*) printf '{"error":"unknown action"}' ;;
esac
