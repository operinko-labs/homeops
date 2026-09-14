#!/bin/sh
# Count who still sends DNS to the legacy (Node VLAN) resolver addresses on this
# node, then emit one syslog line per (dst, src) pair to the syslog gateway so
# the answer lives in Loki:  {job="syslog", app="dns-legacy"}
#
# Runs for DURATION seconds (systemd timer fires it every 10 minutes).
set -u

IFACE="${IFACE:-eth0}"                                   # the VLAN 7 interface
LEGACY="${LEGACY:-192.168.7.7 192.168.7.8 192.168.7.9}"  # addresses being retired
DURATION="${DURATION:-60}"
SYSLOG_HOST="${SYSLOG_HOST:-192.168.7.6}"

filter=""
for ip in $LEGACY; do
  filter="${filter:+$filter or }dst host $ip"
done

# tcpdump -q line: "10:18:42.123 IP 192.168.0.221.55254 > 192.168.7.8.53: UDP, length 40"
# dst port 53 only (a plain "port 53" also catches upstream resolvers answering our recursion),
# and never count ns1/ns2 talking to each other (NOTIFY / zone transfers).
timeout "$DURATION" tcpdump -ni "$IFACE" -l -q "dst port 53 and ($filter) and not (src host 192.168.7.8 or src host 192.168.7.9)" 2>/dev/null \
  | awk '$4 == ">" { src=$3; dst=$5; sub(/\.[0-9]+:?$/, "", src); sub(/\.[0-9]+:?$/, "", dst); c[dst " " src]++ }
         END { for (k in c) print k, c[k] }' \
  | while read -r dst src n; do
      logger --rfc3164 -n "$SYSLOG_HOST" -P 514 -t dns-legacy "dst=$dst src=$src count=$n window=${DURATION}s"
    done
exit 0
