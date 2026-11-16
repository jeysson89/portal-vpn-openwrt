#!/bin/sh
# Portal watchdog v4 - FULL AUTO mode:
#  1. tunnel check via engine
#  2. slow engine -> speedsel (bw-based relay choice + Telegram rollback)
#  3. tunnel down -> kill duplicate engines, refresh pool (bootstrap DNS),
#     sweep alive relays from pool, switch, restart, verify; up to 3 attempts
#  4. guards sing-box/tun/policy/firewall chain
CD=/etc/portal
# LAN/WAN detection (never hardcode br-lan / 192.168.x)
. $CD/portal-env.sh
# manual pause: engine stopped on purpose from LuCI — watchdog must not revive it
[ -f $CD/engine-paused ] && exit 0
# autostart off + no manual-start marker (/tmp dies on reboot): stay off after boot
auto=0
ls /etc/rc.d/S[0-9][0-9]portal >/dev/null 2>&1 && ls /etc/rc.d/S[0-9][0-9]sing-box >/dev/null 2>&1 && auto=1
if [ "$auto" = "0" ] && [ ! -f /tmp/portal-engine-intent ]; then exit 0; fi
LOCK=/tmp/portal-watch.lock
# a killed run leaves the lock behind: only honour it while its PID is alive
if [ -d "$LOCK" ]; then
  lpid=$(cat "$LOCK/pid" 2>/dev/null)
  [ -n "$lpid" ] && [ -d /proc/$lpid ] && exit 0
  rm -rf "$LOCK"
fi
mkdir -p "$LOCK" 2>/dev/null || exit 0
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

log() { logger -t portal-watch "$1"; }

# PID list by /proc comm: `ps | grep opera-proxy` also matches a procd `sh -c`
# wrapper (killing it does not stop the engine but can trigger a respawn)
engine_pids() {
  for d in /proc/[0-9]*; do
    [ "$(cat $d/comm 2>/dev/null)" = "opera-proxy" ] && echo "${d#/proc/}"
  done
}

# the transparent chain is only complete with BOTH the rule and the default
# route: after a sing-box restart the rule survives but the route does not
policy_broken() {
  ip link show portal-tun >/dev/null 2>&1 || return 1
  ip rule 2>/dev/null | grep -q "iif $LAN_IF" || return 0
  ip route show table 100 2>/dev/null | grep -q '^default dev portal-tun' || return 0
  return 1
}

tunnel_ok() {
  curl -sS --max-time 20 -x http://127.0.0.1:18080 -o /dev/null https://api.ipify.org 2>/dev/null
}

restart_engine() {
  # kill ALL opera-proxy instances first (restart leaves duplicates)
  for p in $(engine_pids); do kill $p 2>/dev/null; done
  sleep 2
  /etc/init.d/portal start >/dev/null 2>&1
  /etc/init.d/sing-box start >/dev/null 2>&1
  sleep 15
}

if tunnel_ok; then
  # --- guards for transparent chain ---
  if ! ip link show portal-tun >/dev/null 2>&1; then
    log "portal-tun missing, starting sing-box"
    /etc/init.d/sing-box start >/dev/null 2>&1
    sleep 8
  fi
  if policy_broken; then
    log "policy incomplete (rule or default route missing), re-applying tun-policy"
    /etc/portal/tun-policy.sh
  fi
  # --- slow engine -> speedsel (bw + Telegram rollback) ---
  # the Opera relay legitimately answers in 5-10 s at night, so the threshold is
  # generous and relay probing runs at most once per 30 min (it is expensive)
  spd=$(curl -sS --max-time 20 -x http://127.0.0.1:18080 -o /dev/null -w '%{time_total}' https://api.ipify.org 2>/dev/null)
  slow=$(awk -v t="${spd:-99}" 'BEGIN{print (t>12.0)?1:0}')
  if [ "$slow" = "1" ]; then
    last=$(cat /tmp/portal-last-speedsel 2>/dev/null)
    [ -n "$last" ] || last=0
    age=$(( $(date +%s) - last ))
    if [ $age -ge 1800 ]; then
      log "engine slow (${spd}s), speedsel"
      date +%s > /tmp/portal-last-speedsel
      /etc/portal/speedsel.sh >/dev/null 2>&1
    else
      log "engine slow (${spd}s), speedsel skipped (last run ${age}s ago)"
    fi
  fi
  exit 0
fi

log "tunnel DOWN, auto-recovery started"
n=$(engine_pids | wc -l)
[ "$n" -gt 1 ] && log "duplicate engines ($n), killing all"

attempt=0
while [ $attempt -lt 3 ]; do
  attempt=$((attempt+1))
  # refresh pool via bootstrap DNS (works with dead tunnel)
  sh $CD/poolboot.sh >/dev/null 2>&1
  plines=$(wc -l < $CD/relay-pool.txt 2>/dev/null)
  log "attempt $attempt: pool refreshed ($plines relays), sweeping..."
  sh $CD/sweep.sh > /tmp/sweep-last.log 2>&1
  if grep -q '^BEST=' /tmp/sweep-last.log 2>/dev/null; then
    best=$(grep '^BEST=' /tmp/sweep-last.log | sed 's/^BEST=//; s/ BW=.*//')
    log "sweep found alive relay: $best, restarting engine"
    restart_engine
    if tunnel_ok; then
      st=$(curl -sS --max-time 12 -x http://127.0.0.1:18080 -o /dev/null -w '%{time_total}' https://api.ipify.org 2>/dev/null)
      log "TUNNEL RESTORED via $best (${st}s)"
      # re-apply transparent chain just in case
      policy_broken && /etc/portal/tun-policy.sh
      exit 0
    fi
    log "engine up but tunnel still down, next attempt"
  else
    log "sweep: no alive relays this pass"
  fi
done

log "auto-recovery failed after $attempt attempts; will retry next cycle (engine keeps retrying registration)"
exit 0
