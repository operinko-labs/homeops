# dns-legacy-watch — who still queries the old DNS addresses?

Part of the [DNS VLAN migration](../../docs/networking/dns-vlan-migration.md). While
`ns1`/`ns2` are dual-homed, this tells you which clients still send DNS to the legacy Node VLAN
addresses (`192.168.7.7/8/9`) so they can be re-pointed one by one, and when the list is empty
the old addresses can be retired.

The primary mechanism is a **logged allow policy on the UDM** (runbook §3e), which needs no
install and shows every routed query. This script is the optional complement: the UDM cannot see
hosts on the Node VLAN itself (they reach the resolvers at layer 2), and it logs one line per
query rather than a summary. Each node captures on its VLAN 7 interface for 60 seconds every
10 minutes and sends one syslog line per `(dst, src)` pair to the syslog gateway
(`192.168.7.6`), stored in Loki under `{job="syslog", app="dns-legacy"}`.

## Install (both LXCs, as root)

```sh
apt-get install -y tcpdump          # bsdutils (logger) and coreutils (timeout) are already there
install -m 0755 dns-legacy-watch.sh /usr/local/sbin/
install -m 0644 dns-legacy-watch.service dns-legacy-watch.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now dns-legacy-watch.timer
systemctl start dns-legacy-watch.service   # one run now; takes 60 s
```

`ns2` never holds the VIP while `ns1` is up, so it can narrow the capture with
`systemctl edit dns-legacy-watch.service` → `Environment=LEGACY="192.168.7.9"`. Not required.

Unprivileged LXCs keep `CAP_NET_RAW`, which is all tcpdump needs; if the capture prints nothing
at all, check `capsh --print` inside the container (same check as the keepalived README).

## Reading the result

Grafana Explore, Loki datasource:

```logql
sum by (src, dst) (count_over_time({job="syslog", app="dns-legacy"} | json | line_format "{{.log}}" | logfmt [24h]))
```

Last time a source was seen on a legacy address:

```logql
{job="syslog", app="dns-legacy"} | json | line_format "{{.log}}" | logfmt | src="192.168.0.221"
```

Expect the list to shrink as consumers are flipped. When a 7-day window shows nothing except the
resolvers themselves (`192.168.7.8` ↔ `192.168.7.9` zone transfers, `127.0.0.1`), §4 of the
runbook can proceed.

## Remove

```sh
systemctl disable --now dns-legacy-watch.timer
rm /etc/systemd/system/dns-legacy-watch.{service,timer} /usr/local/sbin/dns-legacy-watch.sh
systemctl daemon-reload
```
