#!/bin/sh
set -u

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/backup/dns-qmodem-$STAMP"
mkdir -p "$BACKUP"

log(){ echo "[$(date +%H:%M:%S)] $*"; }

for f in dhcp qmodem network firewall; do
  [ -f "/etc/config/$f" ] && cp -a "/etc/config/$f" "$BACKUP/$f"
done

log "ARCA DNS + QModem redial repair"

WAN_DEV="$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
WAN_IP="$(ip -4 -o addr show dev "${WAN_DEV:-wwan0}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"

if [ -z "${WAN_DEV:-}" ] || [ -z "${WAN_IP:-}" ]; then
  echo "ERROR: live IPv4 WAN path not detected; refusing to touch QModem dial state."
  exit 20
fi

log "Live WAN preserved: $WAN_DEV $WAN_IP"

# QModem is management-only in AbeyyWRT. Disable its own dial owner so it does
# not race netifd/luci-proto-qmi after the OpenWrt wwan interface is already up.
if [ -f /etc/config/qmodem ]; then
  log "Disable QModem auto-dial (management UI/AT/SMS remain installed)"
  if uci -q get qmodem.main >/dev/null 2>&1; then
    uci set qmodem.main.enable_dial='0'
  fi
  for s in $(uci show qmodem 2>/dev/null | sed -n "s/^\(qmodem\.[^.]*\)=modem-device$/\1/p"); do
    uci set "$s.enable_dial=0"
  done
  uci commit qmodem
fi

# Stop only the redial shell(s), not AT daemon, SMS service, modem scanner, or
# the live QMI netifd session.
for p in $(pgrep -f '/usr/share/qmodem/modem_dial.sh .* dial' 2>/dev/null || true); do
  log "Stopping QModem redial PID $p"
  kill "$p" 2>/dev/null || true
done
sleep 2

# Ensure netifd still owns/keeps the logical wwan interface.
WWAN_UP="$(ubus call network.interface.wwan status 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null || true)"
if [ "$WWAN_UP" != "true" ]; then
  log "netifd wwan was not marked up; issuing ifup wwan"
  ifup wwan 2>/dev/null || true
  n=0
  while [ "$n" -lt 20 ]; do
    ip -4 route show default 2>/dev/null | grep -q 'dev wwan0' && break
    sleep 1
    n=$((n+1))
  done
fi

# Collect carrier-provided DNS if netifd exposes it.
CARRIER_DNS=""
if command -v jsonfilter >/dev/null 2>&1; then
  STATUS="$(ubus call network.interface.wwan status 2>/dev/null || true)"
  for idx in 0 1 2 3; do
    d="$(printf '%s' "$STATUS" | jsonfilter -e "@[\"dns-server\"][$idx]" 2>/dev/null || true)"
    [ -n "$d" ] && CARRIER_DNS="$CARRIER_DNS $d"
  done
fi

log "Probe working upstream DNS directly over live WAN"
WORKING=""
for d in $CARRIER_DNS 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9; do
  [ -n "$d" ] || continue
  echo "$WORKING" | grep -qw "$d" && continue
  if timeout 5 nslookup cloudflare.com "$d" >/tmp/arca-dns-probe.$$ 2>&1; then
    log "DNS upstream works: $d"
    WORKING="$WORKING $d"
  else
    log "DNS upstream failed: $d"
  fi
done
rm -f /tmp/arca-dns-probe.$$ 2>/dev/null || true

if [ -z "${WORKING# }" ]; then
  echo
  echo "ERROR: no tested DNS resolver answered through $WAN_DEV."
  echo "Raw route and modem status follow:"
  ip -4 route
  ubus call network.interface.wwan status 2>/dev/null || true
  echo "Backup: $BACKUP"
  exit 30
fi

# Stop AGH during baseline recovery so only one process owns LAN port 53.
for s in adguardhome AdGuardHome; do
  [ -x "/etc/init.d/$s" ] && "/etc/init.d/$s" stop >/dev/null 2>&1 || true
done

log "Configure dnsmasq with verified explicit upstream resolvers"
uci set dhcp.@dnsmasq[0].port='53'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
for d in $WORKING; do
  uci add_list dhcp.@dnsmasq[0].server="$d"
done
uci commit dhcp

/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
sleep 3

DNS_LOCAL=FAIL
DNS_DIRECT=FAIL
PING=FAIL
HTTP=FAIL

ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1 && PING=PASS
first="$(echo "$WORKING" | awk '{print $1}')"
[ -n "$first" ] && timeout 5 nslookup cloudflare.com "$first" >/dev/null 2>&1 && DNS_DIRECT=PASS
timeout 5 nslookup cloudflare.com 127.0.0.1 >/dev/null 2>&1 && DNS_LOCAL=PASS

if command -v curl >/dev/null 2>&1; then
  code="$(curl -4 -sS --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' https://connectivitycheck.gstatic.com/generate_204 2>/dev/null || true)"
  case "$code" in 200|204|301|302) HTTP=PASS;; *) HTTP="FAIL($code)";; esac
else
  HTTP=NA
fi

# Memory: use MemAvailable, not the misleading total-free figure which counts
# reclaimable Linux page cache as occupied.
MT_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
MA_KB="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
MC_KB="$(awk '/^Cached:/ {print $2}' /proc/meminfo)"
MB_KB="$(awk '/^Buffers:/ {print $2}' /proc/meminfo)"
REAL_USED_KB=$((MT_KB-MA_KB))
REAL_PCT=$((REAL_USED_KB*100/MT_KB))

sleep 5
CPU_LINE="$(top -bn1 2>/dev/null | awk '/^CPU:|^%Cpu/ {print; exit}')"
TOPPROC="$(top -bn1 2>/dev/null | sed -n '5,15p')"

REDIAL_COUNT="$(pgrep -f '/usr/share/qmodem/modem_dial.sh .* dial' 2>/dev/null | wc -l | tr -d ' ')"

cat <<EOF

============================================================
 ARCA DNS / QMODEM REPAIR RESULT
============================================================
 WAN device        : $WAN_DEV
 WAN IPv4          : $WAN_IP
 Router ping       : $PING
 Direct DNS        : $DNS_DIRECT
 Local dnsmasq DNS : $DNS_LOCAL
 Router HTTPS      : $HTTP
 DNS upstream(s)   :${WORKING}
 QModem redial PIDs: $REDIAL_COUNT
 QModem ownership  : MANAGEMENT ONLY
 Backup            : $BACKUP
------------------------------------------------------------
 REAL MEMORY (MemAvailable method)
 Used              : $((REAL_USED_KB/1024)) MiB / $((MT_KB/1024)) MiB ($REAL_PCT%)
 Available         : $((MA_KB/1024)) MiB
 Cache             : $((MC_KB/1024)) MiB
 Buffers           : $((MB_KB/1024)) MiB
------------------------------------------------------------
 CPU snapshot
 ${CPU_LINE:-unavailable}
------------------------------------------------------------
 Top processes
${TOPPROC:-unavailable}
============================================================
EOF

if [ "$DNS_LOCAL" = PASS ] && [ "$HTTP" = PASS ]; then
  echo "BASELINE INTERNET: PASS"
  echo "Reconnect Wi-Fi once on each BE3600 client, then test browser/Speedtest."
  exit 0
fi

echo "BASELINE INTERNET: NOT FULLY PASS"
exit 40
