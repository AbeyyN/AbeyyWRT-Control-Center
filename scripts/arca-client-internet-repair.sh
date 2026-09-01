#!/bin/sh
set -u

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/backup/client-internet-$STAMP"
mkdir -p "$BACKUP"

log(){ echo "[$(date +%H:%M:%S)] $*"; }

log "AbeyyWRT client internet rescue starting"
log "This script preserves the live QMI/wwan session"

for f in network firewall dhcp sqm; do
  [ -f "/etc/config/$f" ] && cp -a "/etc/config/$f" "$BACKUP/$f"
done

{
  echo '=== BEFORE: board ==='
  ubus call system board 2>/dev/null || true
  echo '=== BEFORE: routes ==='
  ip -4 route 2>/dev/null || true
  echo '=== BEFORE: wwan ==='
  ubus call network.interface.wwan status 2>/dev/null || true
  echo '=== BEFORE: top ==='
  top -bn1 2>/dev/null | head -n 30 || true
  echo '=== BEFORE: firewall ==='
  uci show firewall 2>/dev/null || true
  echo '=== BEFORE: dhcp ==='
  uci show dhcp 2>/dev/null || true
} > "$BACKUP/before.txt" 2>&1

# Safety gate: router itself must already have the cellular WAN path online.
WAN_DEV="$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
WAN_IP="$(ip -4 -o addr show dev "${WAN_DEV:-wwan0}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"

if [ -z "${WAN_DEV:-}" ]; then
  log "ERROR: no IPv4 default route. Refusing to disturb the modem session."
  exit 20
fi

log "Detected live WAN device: $WAN_DEV ${WAN_IP:+($WAN_IP)}"

# Router path sanity check. Do not abort on ICMP filtering; HTTP can still work.
ROUTER_NET=0
ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1 && ROUTER_NET=1
if command -v curl >/dev/null 2>&1; then
  code="$(curl -4 -sS --connect-timeout 4 --max-time 8 -o /dev/null -w '%{http_code}' https://connectivitycheck.gstatic.com/generate_204 2>/dev/null || true)"
  case "$code" in 200|204|301|302) ROUTER_NET=1;; esac
fi

if [ "$ROUTER_NET" -ne 1 ]; then
  log "WARNING: router outbound verification failed, but live default route exists. Continuing firewall/DNS repair."
fi

log "Enable IPv4 forwarding"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
if grep -q '^net.ipv4.ip_forward=' /etc/sysctl.conf 2>/dev/null; then
  sed -i 's/^net\.ipv4\.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

# Locate or create standard LAN/WAN zones.
LANZONE="$(uci show firewall 2>/dev/null | sed -n "s/^\(firewall\.[^.]*\)\.name='lan'$/\1/p" | head -n1)"
WANZONE="$(uci show firewall 2>/dev/null | sed -n "s/^\(firewall\.[^.]*\)\.name='wan'$/\1/p" | head -n1)"

if [ -z "$LANZONE" ]; then
  z="$(uci add firewall zone)"
  LANZONE="firewall.$z"
  uci set "$LANZONE.name=lan"
  uci set "$LANZONE.input=ACCEPT"
  uci set "$LANZONE.output=ACCEPT"
  uci set "$LANZONE.forward=ACCEPT"
fi

if [ -z "$WANZONE" ]; then
  z="$(uci add firewall zone)"
  WANZONE="firewall.$z"
  uci set "$WANZONE.name=wan"
  uci set "$WANZONE.input=REJECT"
  uci set "$WANZONE.output=ACCEPT"
  uci set "$WANZONE.forward=REJECT"
fi

log "Repair LAN/WAN zone membership and NAT"
uci -q del_list "$LANZONE.network=lan" 2>/dev/null || true
uci add_list "$LANZONE.network=lan"
uci set "$LANZONE.input=ACCEPT"
uci set "$LANZONE.output=ACCEPT"
uci set "$LANZONE.forward=ACCEPT"

# Keep existing WAN members, but force the successful cellular logical network into WAN.
uci -q del_list "$WANZONE.network=wwan" 2>/dev/null || true
uci add_list "$WANZONE.network=wwan"
uci set "$WANZONE.masq=1"
uci set "$WANZONE.mtu_fix=1"
uci set "$WANZONE.output=ACCEPT"

# Guarantee exactly at least one LAN -> WAN forwarding.
HAS_FWD=0
for s in $(uci show firewall 2>/dev/null | sed -n "s/^\(firewall\.[^.]*\)=forwarding$/\1/p"); do
  src="$(uci -q get "$s.src" 2>/dev/null || true)"
  dst="$(uci -q get "$s.dest" 2>/dev/null || true)"
  [ "$src" = lan ] && [ "$dst" = wan ] && HAS_FWD=1
 done
if [ "$HAS_FWD" -eq 0 ]; then
  f="$(uci add firewall forwarding)"
  uci set "firewall.$f.src=lan"
  uci set "firewall.$f.dest=wan"
fi

# Rescue mode: remove SQM from the forwarding datapath and use software flow-offload.
# This is intentionally temporary until client connectivity and CPU are verified.
log "Temporarily disable SQM and enable software flow offload"
if uci -q show sqm >/dev/null 2>&1; then
  for q in $(uci show sqm 2>/dev/null | sed -n "s/^\(sqm\.[^.]*\)=queue$/\1/p"); do
    uci set "$q.enabled=0"
  done
  uci commit sqm
fi
[ -x /etc/init.d/sqm ] && /etc/init.d/sqm stop >/dev/null 2>&1 || true

uci set firewall.@defaults[0].flow_offloading='1' 2>/dev/null || true
uci set firewall.@defaults[0].flow_offloading_hw='0' 2>/dev/null || true
uci commit firewall

# DNS rescue. AGH is a common post-flash conflict when router itself has Internet
# but clients receive a dead local resolver. Stop it for baseline recovery.
log "Restore plain dnsmasq DNS for LAN clients"
for s in adguardhome AdGuardHome; do
  if [ -x "/etc/init.d/$s" ]; then
    "/etc/init.d/$s" stop >/dev/null 2>&1 || true
  fi
done

if uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1; then
  uci set dhcp.@dnsmasq[0].port='53'
  uci set dhcp.@dnsmasq[0].noresolv='0'
  uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
fi

# Hand out ARCA itself as both gateway and DNS. Remove stale custom DHCP options
# from previous firmware because duplicated option 3/6 can strand AP clients.
if uci -q get dhcp.lan >/dev/null 2>&1; then
  LAN_IP="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
  [ -n "$LAN_IP" ] || LAN_IP='192.168.1.1'
  uci -q delete dhcp.lan.dhcp_option 2>/dev/null || true
  uci add_list dhcp.lan.dhcp_option="3,$LAN_IP"
  uci add_list dhcp.lan.dhcp_option="6,$LAN_IP"
fi
uci commit dhcp

# Stop only the optional connectivity poller during rescue; leave QMI/QModem alone.
for s in internet-detector internet_detector; do
  [ -x "/etc/init.d/$s" ] && "/etc/init.d/$s" stop >/dev/null 2>&1 || true
 done

log "Reload firewall and DNS without bouncing wwan"
/etc/init.d/firewall restart >/dev/null 2>&1 || /etc/init.d/firewall reload >/dev/null 2>&1 || true
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
sleep 4

# Show effective nft rules useful for postmortem.
{
  echo '=== AFTER: routes ==='
  ip -4 route 2>/dev/null || true
  echo '=== AFTER: ip_forward ==='
  sysctl net.ipv4.ip_forward 2>/dev/null || true
  echo '=== AFTER: port53 ==='
  ss -lntup 2>/dev/null | grep ':53 ' || netstat -lnptu 2>/dev/null | grep ':53 ' || true
  echo '=== AFTER: firewall ==='
  uci show firewall 2>/dev/null || true
  echo '=== AFTER: dhcp ==='
  uci show dhcp 2>/dev/null || true
  echo '=== AFTER: nft forward/nat snippets ==='
  nft list ruleset 2>/dev/null | grep -Ei 'forward|masquerade|masq|wwan|br-lan' | head -n 120 || true
  echo '=== AFTER: top ==='
  top -bn1 2>/dev/null | head -n 30 || true
} > "$BACKUP/after.txt" 2>&1

# Final router-level checks.
PING=FAIL
DNS=FAIL
HTTP=NA
ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1 && PING=PASS
nslookup cloudflare.com 127.0.0.1 >/dev/null 2>&1 && DNS=PASS
if command -v curl >/dev/null 2>&1; then
  code="$(curl -4 -sS --connect-timeout 4 --max-time 8 -o /dev/null -w '%{http_code}' https://connectivitycheck.gstatic.com/generate_204 2>/dev/null || true)"
  case "$code" in 200|204|301|302) HTTP=PASS;; *) HTTP="FAIL($code)";; esac
fi

CPU_IDLE="$(top -bn1 2>/dev/null | awk '/^CPU:|^%Cpu/ {print; exit}')"
TOPPROC="$(top -bn1 2>/dev/null | sed -n '5,14p')"

cat <<EOF

============================================================
 ARCA CLIENT INTERNET RESCUE COMPLETE
============================================================
 WAN device : $WAN_DEV
 WAN IPv4   : ${WAN_IP:-unknown}
 Router ping: $PING
 Router DNS : $DNS
 Router HTTP: $HTTP
 SQM        : TEMPORARILY OFF
 Flow offld : SOFTWARE ON
 DNS mode   : dnsmasq baseline
 Backup     : $BACKUP
============================================================

IMPORTANT FOR WIFI/AP CLIENTS:
1. Toggle Wi-Fi OFF then ON once, OR reconnect to the BE3600 SSID.
2. Client should receive gateway/DNS from ARCA again.
3. Test a website, then Speedtest.

CPU snapshot:
${CPU_IDLE:-unavailable}

Top processes:
${TOPPROC:-unavailable}
============================================================
EOF

exit 0
