# DNS VLAN migration — move ns1/ns2 and the VIP off the Node VLAN

Status: **Planned.** Nothing below has been executed. Companion to
[`technitium-dns-ha.md`](technitium-dns-ha.md) (current design) and
[`../../scripts/technitium-keepalived/`](../../scripts/technitium-keepalived/) (VIP).

## Why

| | today | problem |
|---|---|---|
| VIP `192.168.7.7`, ns1 `192.168.7.8`, ns2 `192.168.7.9` | Node VLAN 7 | all three sit inside the Cilium LB-IPAM pool `192.168.7.0/25`; a Service can claim them by hand (the `192.168.7.30` Forgejo/CNPG collision was exactly this) |
| firewall | Node VLAN is in the **Internal** zone | every zone that needs DNS gets a three-address exception (IoT already has one); DNS servers can reach everything Internal can |
| blast radius | DNS shares a broadcast domain with 7 Talos nodes and BGP | a cluster-side incident (BGP flap, LB churn) can take the resolvers with it |

Target: a dedicated **DNS VLAN 5 / `192.168.5.0/24`** in its **own firewall zone (`Infra`)**, servers at
`192.168.5.7` (VIP), `192.168.5.8` (ns1), `192.168.5.9` (ns2). Same last octets as today.
VLAN 5 was the original DNS VLAN; cameras still probe `192.168.5.1:7442` as a stale Protect console
address, which becomes harmless again once the gateway exists (see §5).

## Guiding rule

**Nothing is torn down until the old addresses have been quiet for a week.** Both LXCs are
dual-homed for the whole migration, so every consumer can be flipped independently and rolled
back independently.

---

## 0. Pre-flight

- [ ] Confirm nothing on the UDM still references VLAN 5 (network list has no VLAN 5; the old
      `Block IoT to GW` address group with `192.168.5.1` was deleted 2026-09-08).
- [ ] Confirm VRID 53 is unused on the new segment — trivially true, VLAN 5 is new — but the
      unicast peers stay on VLAN 7 until §4, so nothing changes for VRRP until then.
- [ ] Take a Technitium backup on ns1 (Settings → Backup) and a UniFi settings backup.
- [ ] Snapshot both LXCs on Proxmox.

## 1. Network and zone (UniFi, ~10 min, no impact)

1. **Zone first, empty.** Settings → Policy Engine → Zones → create `Infra` with no networks.
   New zones default every pair to **Block All**, including intra-zone, and custom zones get **no
   automatic return-traffic rule**. Before any network joins the zone, create these policies
   (learned the hard way on 2026-09-08):

   | policy | src → dst | match | action | notes |
   |---|---|---|---|---|
   | Allow All (Infra to Infra) | Infra → Infra | any | allow | intra-zone |
   | Allow DNS to Infra | Internal, IoT, Cameras, Vpn → Infra | tcp_udp 53 | allow | one rule per source zone |
   | Allow Default to Infra | Internal → Infra, src network Default | any | allow | admin UI (53443), SSH, RFC2136 from the cluster comes from Node VLAN — see next row |
   | Allow RFC2136 to ns1 | Internal → Infra, src network Node VLAN, dst `192.168.5.8` | tcp_udp 53 | allow | covered by "Allow DNS" already; listed for clarity |
   | Allow Established and Related | Infra → Internal, Infra → IoT, Infra → Cameras, Infra → Vpn | RESPOND_ONLY, ESTABLISHED+RELATED | allow | clone of the existing Internal one; **required** |
   | Allow Infra to External | Infra → External | any | allow | recursion, NTP, cert-sync pull from NPMplus is Internal (Default) so covered by return traffic |
   | Allow Infra to Internal (NPMplus cert pull) | Infra → Internal, dst `192.168.0.5` | tcp 22 | allow | `technitium-cert-sync` pulls over SSH |
   | Block Infra to Internal | Infra → Internal | any | **block** (zone default; leave) | the segmentation win |

2. **Network.** Settings → Networks → New: name `DNS`, VLAN `5`, gateway `192.168.5.1/24`,
   **DHCP off**, IGMP snooping off, mDNS off, zone **Infra**, IPv6 none.
3. Ports: the LXC hosts (`meanie` on Agg SFP+ 5 after cable day, NUC on Pro Max port 14) use the
   default "all VLANs tagged" profile, so VLAN 5 is already carried. Nothing to change on switches.

Verify: from a Default-VLAN host, `ping 192.168.5.1` answers.

## 2. Dual-home the servers (Proxmox + LXC, ~20 min, no impact)

For **each** LXC (118 on meanie = ns1, 100 on the NUC = ns2):

1. Proxmox → LXC → Network → Add `net1`: bridge `vmbr0`, VLAN tag `5`, static
   `192.168.5.8/24` (ns1) / `192.168.5.9/24` (ns2), **no gateway** (default route stays on
   VLAN 7 until §4).
2. Inside the LXC: `ip addr` shows `eth1` with the new address. `ping 192.168.5.1`.
3. Technitium listens on all interfaces by default (Settings → General → Local End Points
   `[::]:53`). If it was pinned to `192.168.7.x`, add the `192.168.5.x` endpoint. Web UI likewise.
4. Verify from a Default host: `dig @192.168.5.8 vaderrp.com` and `dig @192.168.5.9 ...` answer.

Keepalived — add the second VIP to the **existing** `vrrp_instance DNS_VIP` on both nodes so
failover stays atomic (both VIPs move together):

```
virtual_ipaddress {
    192.168.7.7/24 dev eth0
    192.168.5.7/24 dev eth1
}
```

`systemctl reload keepalived` on ns2 first, then ns1. Verify: `ip addr show eth1` on ns1 has
`192.168.5.7`; `dig @192.168.5.7 vaderrp.com` answers; stop Technitium on ns1 for 10 s and watch
both VIPs land on ns2, then come back.

Unicast peers (`unicast_src_ip` / `unicast_peer`) stay on `192.168.7.x` for now.

## 3. Flip consumers (each independent, each reversible)

Order is by ease of rollback. Run the check after each group.

### 3a. UniFi DHCP option (all clients that trust DHCP)

Settings → Networks → each of Default, Camera, IoT, Management, Node VLAN → DHCP DNS Server
`192.168.5.7`. Clients pick it up at lease renewal (24 h lease; most renew at 12 h).
API equivalent: `PUT /api/s/default/rest/networkconf/{id}` with the **full** object and
`dhcpd_dns_1` changed (partial bodies are rejected with `api.err.MissingIPAddress`).

### 3b. Talos nodes

`talos/machineconfig.yaml.j2` nameservers `192.168.7.8`, `192.168.7.9` → `192.168.5.8`,
`192.168.5.9`. `just talos apply-node <node>` for all seven; nameserver changes apply live, no
reboot. `talosctl -n <ip> get resolvers` confirms.

### 3c. homeops (one PR)

| file | change |
|---|---|
| `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml` | `forward . 192.168.5.8 192.168.5.9` |
| `kubernetes/apps/network/cluster-dns/app/helmrelease.yaml` | `--rfc2136-host=192.168.5.8` |
| `kubernetes/apps/network/internal-dns/app/helmrelease.yaml` | `--rfc2136-host=192.168.5.8` |
| `kubernetes/apps/media/maintainerr/app/httproute.yaml`, `.../prowlarr/app/httproute.yaml` | `dns-resolver: tcp://192.168.5.8:53` |
| `kubernetes/apps/observability/gatus/app/gatus-config.yaml` | DNS check target `192.168.5.7` |
| `kubernetes/apps/observability/gatus/app/storj-configmap.yaml` | `dns-resolver: tcp://192.168.5.8:53` |

RFC2136 is the one to watch: after merge, create a throwaway HTTPRoute and confirm external-dns
writes the record to ns1 (`dig @192.168.5.8 <name>`).

### 3d. UniFi firewall

- "Allow IoT to cluster DNS" (IoT → Internal, `192.168.7.7/8/9:53`) becomes redundant once the
  Infra zone rules exist; delete it after IoT clients have renewed leases.
- `rsyslogd`/SIEM targets are unaffected (they point at the syslog gateway, not DNS).

### 3e. Hand-configured hosts

From Technitium's top-clients (last month, 2026-09-09). **Clients on ns2's list query
`192.168.7.9` explicitly** — the VIP lives on ns1 — so they are all static configs:

| host | note |
|---|---|
| TrueNAS `192.168.0.221` | Network → Global Configuration: primary `.9`, secondary `.8` |
| Plex `192.168.0.7` | container/VM resolv.conf |
| Fritz!Box `192.168.0.81` | IP-client DNS settings |
| NPMplus `192.168.0.5` | LXC resolv.conf (also the cert-sync source) |
| Talos nodes `192.168.7.21–27` | §3b |
| `192.168.55.154` (Versuni device), `192.168.55.16` (WeatherFlow hub) | static on the device |
| `192.168.0.13` (phone), `192.168.0.84` (OlliPC), `192.168.0.247` (meanie iLO), `192.168.0.29`, `192.168.0.97` (TDarr), `192.168.0.40` (HA), `192.168.0.183` (PBS), `192.168.3.90/.91` (Proxmox in-band) | occasional; likely secondary-resolver fallbacks — fix when found |

Direct users of `192.168.7.8` cannot be separated from VIP users in Technitium's log (same
server answers both). Get them with a 10-minute capture on ns1 before §4:

```sh
tcpdump -ni eth0 -q 'udp port 53 and dst host 192.168.7.8' | awk '{print $3}' | cut -d. -f1-4 | sort | uniq -c | sort -rn
```

Known so far: ESPHome garage opener `192.168.55.59` (`dns1: 192.168.7.7`, `dns2: 192.168.7.8`),
meanie iLO `192.168.0.247`.

Also notable in the inventory: `192.168.2.7` (~27 k queries/month) is from a subnet that does not
exist on the UDM — most likely the Halli Express site over the site-to-site VPN. It must be
re-pointed too, or the VPN zone rules must allow it to reach Infra on 53 (they do in §1).

## 4. Watch, then retire (after a quiet week)

1. Daily during the week, on ns1: the tcpdump above for `dst host 192.168.7.8 or 192.168.7.7`,
   and on ns2 for `192.168.7.9`. Expect the list to shrink to nothing.
2. When quiet: move VRRP unicast to VLAN 5 (`unicast_src_ip 192.168.5.8`, peer `192.168.5.9`)
   and drop `192.168.7.7` from `virtual_ipaddress`; reload ns2 then ns1.
3. Set the LXCs' default gateway to `192.168.5.1` on `net1`, remove `net0` (VLAN 7).
4. Technitium cluster: primary/secondary addresses (Settings → Cluster) to `.5.8` / `.5.9`;
   update the `ns1.dns.vaderrp.com` / `ns2.dns.vaderrp.com` A records. The TLS certificate
   (`*.dns.vaderrp.com`, see `technitium-cert-sync`) is name-based and unaffected.
5. Delete the "Allow IoT to cluster DNS" policy (§3d) if not already done.
6. Add `192.168.5.7–9` nowhere near a Cilium pool: they are on a different VLAN now, which was
   the point.

## 5. Side effects to expect

- Cameras probing `192.168.5.1:7442` (stale console address) start hitting the UDM's real
  VLAN 5 interface — Cameras → Gateway is allowed, so this stops being blocked and stops
  needing the silent-drop policy entry for `192.168.5.1` (keep `192.168.4.1` in it).
- The `unpoller`/Grafana UniFi dashboards gain a `DNS` network; nothing to do.
- Gatus DNS checks fail between §3c merge and Flux reconcile; expected, seconds.

## Rollback

Every step in §3 is one value back to `192.168.7.x`; §1–2 leave the old addresses untouched, so
nothing needs undoing unless the migration is abandoned, in which case remove `net1` from the
LXCs, the second VIP line, and the `DNS` network + `Infra` zone in that order.
