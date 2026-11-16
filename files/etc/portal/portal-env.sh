#!/bin/sh
# Portal VPN network environment: the one place that knows which interface is
# LAN, which is WAN and what the upstream resolver is. Sourced by
# tun-policy.sh, poolboot.sh and portal-watch.sh so that nothing hardcodes
# br-lan / 192.168.200.0/24 / 192.168.10.1.
#
# Detection order: /etc/portal/net.conf -> UCI -> live kernel -> safe default.
#
# After sourcing:
#   LAN_IF      LAN device                      (br-lan)
#   LAN_NET     LAN IPv4 network                (192.168.200.0/24)
#   LAN6_NETS   LAN IPv6 prefixes, space separated (fd70:757c:7db8::/64)
#   WAN_IF      WAN device                      (eth0, pppoe-wan, ...)
#   WAN_NET     WAN IPv4 network of that device (192.168.10.0/24), may be empty
#   WAN_GW      WAN gateway                     (192.168.10.1), empty on ptp
#   WAN_DNS     upstream resolver for the pool bootstrap (192.168.10.1)
#
# Debug: /etc/portal/portal-env.sh show
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# pinned values win over detection
[ -f /etc/portal/net.conf ] && . /etc/portal/net.conf

# "a.b.c.d/len" -> network address in CIDR (busybox awk has no and())
net4() {
  echo "$1" | awk -F'[./]' 'NF>=5 {
    v = $1*16777216 + $2*65536 + $3*256 + $4
    p = $5+0
    b = (p <= 0) ? 4294967296 : ((p >= 32) ? 1 : 2^(32-p))
    v = int(v/b)*b
    printf "%d.%d.%d.%d/%d\n", int(v/16777216), int(v/65536)%256, int(v/256)%256, v%256, p
  }'
}

# ---- LAN ----
if [ -z "$LAN_IF" ]; then
  for i in $(uci -q get network.lan.device) $(uci -q get network.lan.ifname); do
    ip link show "$i" >/dev/null 2>&1 && { LAN_IF=$i; break; }
  done
fi
if [ -z "$LAN_IF" ]; then
  for d in /sys/class/net/br-*; do
    [ -d "$d" ] || continue
    i=${d##*/}
    ip -4 addr show dev "$i" 2>/dev/null | grep -q 'inet ' && { LAN_IF=$i; break; }
  done
fi
[ -n "$LAN_IF" ] || LAN_IF=br-lan

if [ -z "$LAN_NET" ]; then
  cidr=$(ip -4 addr show dev "$LAN_IF" 2>/dev/null | awk '/inet /{print $2; exit}')
  [ -n "$cidr" ] && LAN_NET=$(net4 "$cidr")
fi

if [ -z "$LAN6_NETS" ]; then
  LAN6_NETS=$(ip -6 route show dev "$LAN_IF" 2>/dev/null |
    awk '$1 ~ /\// && $1 != "default" {print $1}' | sort -u | tr '\n' ' ')
fi

# ---- WAN ----
if [ -z "$WAN_IF" ]; then
  for i in $(uci -q get network.wan.device) $(uci -q get network.wan.ifname); do
    ip link show "$i" >/dev/null 2>&1 && { WAN_IF=$i; break; }
  done
fi
if [ -z "$WAN_IF" ]; then
  WAN_IF=$(ip route show table main default 2>/dev/null |
    awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
fi
if [ -z "$WAN_GW" ]; then
  WAN_GW=$(ip route show table main default 2>/dev/null |
    awk '/^default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
fi
if [ -z "$WAN_NET" ] && [ -n "$WAN_IF" ]; then
  cidr=$(ip -4 addr show dev "$WAN_IF" 2>/dev/null | awk '/inet /{print $2; exit}')
  [ -n "$cidr" ] && WAN_NET=$(net4 "$cidr")
fi

# DNS of the provider: resolv.conf.auto is what dnsmasq upstream used before we
# forced noresolv; the gateway is a good fallback, 127.0.0.1 is useless here
if [ -z "$WAN_DNS" ]; then
  WAN_DNS=$(awk '/^nameserver/{print $2; exit}' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null)
  case "$WAN_DNS" in
    127.*|::1|"") WAN_DNS=$WAN_GW ;;
  esac
fi

if [ "$1" = "show" ]; then
  echo "LAN_IF=${LAN_IF:-}"
  echo "LAN_NET=${LAN_NET:-}"
  echo "LAN6_NETS=${LAN6_NETS:-}"
  echo "WAN_IF=${WAN_IF:-}"
  echo "WAN_NET=${WAN_NET:-}"
  echo "WAN_GW=${WAN_GW:-}"
  echo "WAN_DNS=${WAN_DNS:-}"
fi
