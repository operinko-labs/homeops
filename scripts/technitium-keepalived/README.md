# Technitium DNS VIP — Keepalived setup

Floats `192.168.5.7` between the two Technitium LXCs so the UDM can hand out one
DNS address instead of two, and so failover takes ~3 seconds rather than a
stub-resolver timeout.

| | |
|---|---|
| VIP | `192.168.5.7` |
| `ns1` | LXC 118 on `meanie`, `192.168.5.8`, Technitium **primary**, VRRP **MASTER** |
| `ns2` | LXC 100 on the NUC, `192.168.5.9`, Technitium secondary, VRRP BACKUP |

VRRP MASTER is on `ns1` so the VIP normally sits with the Technitium primary —
the node that is also the RFC2136 target for external-dns.

Design rationale:
[`docs/networking/technitium-dns-ha.md`](../../docs/networking/technitium-dns-ha.md) §6.

---

## Before you start

Five checks. The first two are the ones that ruin your afternoon if skipped.

### 1. Is VRID 53 already in use on this segment?

Two VRRP pairs sharing a VRID on the same L2 will fight over the same virtual
MAC. Watch for a minute on either node:

```sh
timeout 60 tcpdump -i eth1 -n 'proto 112'
```

Silence means 53 is free. If anything appears, note its VRID from the output and
pick a different number in both config files. The UDM is the likely candidate if
it has any redundancy configured.

### 2. Is `192.168.5.7` actually free?

```sh
ping -c3 192.168.5.7          # should fail
arping -c3 -I eth1 192.168.5.7  # should get no reply
```

It should be free — the DNS VLAN (`192.168.5.0/24`, DHCP off) holds only ns1,
ns2 and the VIP. The pair lived on the Node VLAN (`.7.7/.7.8/.7.9`) until
2026-10-25; it moved because those addresses sat inside the Cilium
`static-pool` block `192.168.7.0/25`, where a Service could claim them by hand
(see `docs/networking/dns-vlan-migration.md`).

### 3. Does the LXC have the capabilities keepalived needs?

VRRP needs raw sockets and the ability to add an address. Unprivileged Proxmox
containers keep `CAP_NET_ADMIN` and `CAP_NET_RAW` by default, but confirm rather
than assume:

```sh
capsh --print | grep -oE 'cap_net_admin|cap_net_raw'
```

Both should appear. If not, add to the container config on the Proxmox host:

```
lxc.cap.keep = net_admin net_raw
```

### 4. Is `dig` installed?

The health check needs it:

```sh
command -v dig || apt install -y bind9-dnsutils
```

### 5. Is Technitium listening on all addresses?

This is the one that silently produces a VIP that answers nothing. In the admin
UI, **Settings → General → DNS Server Local End Points** must be `0.0.0.0:53`
(and `[::]:53`) rather than a list of specific addresses — otherwise the server
will not answer on `.7` when the VIP lands.

Confirm the interface name is `eth1` while you are there:

```sh
ip -brief addr
```

---

## 1. Install keepalived on both nodes

```sh
apt update && apt install -y keepalived
```

Do not enable it yet — the shipped config is empty and starting it now just
produces noise.

## 2. Install the health check

On **both** nodes:

```sh
install -m 0755 -o root -g root check-technitium-dns.sh /etc/keepalived/
```

**`/etc/keepalived/`, not `/usr/local/bin/`.** Debian ships the latter as
`drwxrwsr-x root staff` — group-writable — and `enable_script_security` refuses
to execute a script whose directory anyone but root can write to, since a
`staff` member could swap it out from under a daemon running it as root.
`/etc/keepalived/` is `root:root`, and keeping the script beside the config that
references it is tidier anyway.

The check queries `vaderrp.com SOA` against `127.0.0.1` — a locally
authoritative name, chosen so an internet outage does not move the VIP. Both
nodes would be equally unable to resolve upstream, and moving it would help
nobody.

### Test it in both directions before trusting it

A health check that passes when it should is half the test. The half that
matters is whether it **fails** when it should — a check that cannot fail is
worse than no check at all, because it looks like protection while the VIP sits
on a dead server.

```sh
/etc/keepalived/check-technitium-dns.sh; echo "exit=$?"      # expect 0

systemctl stop technitium
/etc/keepalived/check-technitium-dns.sh; echo "exit=$?"      # expect 1
systemctl start technitium
```

If the second returns `0`, stop and fix the check before going any further —
everything downstream of it is decorative.

This is not hypothetical. The first version of this script wrapped `dig` in
`|| true`, discarding its exit code 9 for "no reply". Because dig writes
`;; communications error ... connection refused` to *stdout* rather than stderr,
the output was non-empty too, so both halves of the test passed against a server
that was not running.

## 3. Install the configs

Pick an auth password of **8 characters or fewer** — VRRPv2 truncates beyond
that, and a silent truncation mismatch is a miserable thing to debug. It is not
a security control, just a guard against a VRID collision with something
unrelated.

```sh
# on ns1
install -m 0600 keepalived-ns1.conf /etc/keepalived/keepalived.conf
# on ns2
install -m 0600 keepalived-ns2.conf /etc/keepalived/keepalived.conf

# then on both, replace CHANGEME with the same value
sed -i 's/CHANGEME/<yourpass>/' /etc/keepalived/keepalived.conf
```

## 4. Bring it up — ns1 first

```sh
systemctl enable --now keepalived
systemctl status keepalived --no-pager
ip -brief addr show eth1
```

`ip addr` should now show **both** `192.168.5.8` and `192.168.5.7` on `eth1`.
The journal should show the instance entering MASTER state:

```sh
journalctl -u keepalived -n 30 --no-pager
```

Then confirm the VIP actually serves DNS, which is the thing that matters:

```sh
dig @192.168.5.7 vaderrp.com SOA +short
```

If the address is up but this returns nothing, revisit pre-flight check 5.

## 5. Bring up ns2

```sh
systemctl enable --now keepalived
ip -brief addr show eth1     # should NOT have .7
journalctl -u keepalived -n 30 --no-pager
```

`ns2` must stay in BACKUP state and must **not** hold the VIP. If both nodes
have `.7`, they cannot see each other's advertisements — check that `auth_pass`
matches exactly, that the unicast addresses are the right way round, and that
nothing is filtering IP protocol 112 between them.

## 6. Test failover

Three separate failure modes. Test all three — they exercise different paths.

**Keepalived stops** (clean handover):

```sh
# ns1
systemctl stop keepalived
# ns2 — .7 should appear within ~3s
ip -brief addr show eth1
dig @192.168.5.7 vaderrp.com SOA +short
# ns1 — restore, VIP should come back
systemctl start keepalived
```

**Technitium dies but the host lives** — this is the one a plain VRRP setup
misses and the `vrrp_script` exists for:

```sh
# ns1
systemctl stop technitium
# within ~10s (interval 5, fall 2) ns2 should take the VIP
# ns1
systemctl start technitium
```

If the VIP does **not** move, check in this order:

1. `/etc/keepalived/check-technitium-dns.sh; echo "exit=$?"` — must be `1` while
   Technitium is stopped. If it is `0`, the check is broken, not keepalived.
2. `journalctl -u keepalived --since "5 min ago"` — look for
   `VRRP_Script(chk_technitium) failed` and a priority change. Its absence means
   keepalived is not acting on the script.
3. `ls -ld "$(dirname /etc/keepalived/check-technitium-dns.sh)"` — the directory
   must not be writable by anyone but root, or `enable_script_security` silently
   declines to run the script. This is why it lives in `/etc/keepalived/` rather
   than `/usr/local/bin/` (step 2).

**The whole node disappears:**

```sh
# from the Proxmox host
pct stop 118
```

Watch from a third machine throughout:

```sh
while true; do dig @192.168.5.7 vaderrp.com SOA +short | head -1; sleep 1; done
```

A gap of a second or two during handover is expected. A gap that does not
recover is not.

## 7. Point things at it

- **DNS records.** `dns.vaderrp.com` A → `192.168.5.7`. Also move
  `technitium.vaderrp.com` from `.8` to `.7` if you want the admin UI to follow
  the VIP — the certificate covers both names.
- **UDM DHCP option 6** → `.7` only. This is the original goal: one address for
  clients you cannot conveniently hand two.
- **Leave `machine.network.nameservers` and the CoreDNS forward list on the real
  IPs.** Two entries cost nothing there and are strictly more robust than
  depending on VRRP. Only DHCP clients need the VIP.
- **Leave `--rfc2136-host` at `192.168.5.8`.** Dynamic updates must reach the
  cluster *primary*, not whichever node happens to hold the VIP.

## 8. Monitoring

Add to `kubernetes/apps/observability/gatus/app/gatus-config.yaml` once the VIP
is live — not before, or it alerts on something that does not exist yet:

```yaml
  - name: technitium VIP
    group: Network
    url: "192.168.5.7"
    interval: 1m
    dns:
      query-name: "vaderrp.com"
      query-type: "SOA"
    conditions:
      - "[DNS_RCODE] == NOERROR"
    alerts:
      - type: ntfy
        send-on-resolved: true
        failure-threshold: 3
        success-threshold: 5
```

This catches the case the per-node checks cannot: both nodes healthy, but the
VIP held by nobody.

## Rollback

```sh
systemctl disable --now keepalived     # on both nodes
```

The address disappears with the daemon. Revert UDM DHCP to `.8`/`.9` and the
setup is exactly as it was — nothing here changes Technitium's own
configuration.

---
## Access from outside the house

**Decided: VPN only (UniFi Teleport). No port forwarding.**

Forwarding `853`/`443` at the UDM to the VIP would work, but a split-horizon
resolver is a poor thing to expose, for a reason that is easy to miss:

> **Recursion ACLs do not protect authoritative zones.** Technitium's "Allow
> Recursion Only For Private Networks" governs *recursive* lookups. The internal
> `vaderrp.com` zone is **authoritative**, and authoritative answers are served
> to anyone who asks, ACL or not.

So a public DoT endpoint would resolve `sonarr.vaderrp.com`,
`harbor.vaderrp.com`, `proxmox.vaderrp.com` and the rest straight to their
internal addresses — the whole service inventory and IP layout, to anyone who
can guess a hostname. The endpoint is not obscure either: the certificate's SANs
are in public Certificate Transparency logs.

Fixing that means per-zone **Query Access** restrictions, plus QPM rate limiting
for the open-resolver side, plus never forwarding `53`. A VPN gets encrypted DNS
*and* internal name resolution with none of it, so that is the path taken.

### What this means in practice

Teleport clients arrive on the LAN, so nothing special is needed — split-horizon
already resolves `dns.vaderrp.com` to `192.168.5.7` for them, and the
certificate covers that name. Setting **UDM DHCP option 6 to `.7`** generally
covers VPN clients too; confirm on the phone with a lookup once connected.

### One gotcha worth knowing

**Do not set Android's Private DNS to `dns.vaderrp.com` permanently.** That
setting is system-wide and applies whether or not Teleport is connected, and it
**fails closed** — with no public record for the name and no route to `.7`, DNS
breaks entirely rather than falling back. Leave Private DNS on Automatic and let
the VPN supply the resolver.

The same reasoning applies to any DoT client configured by hostname on a device
that leaves the network.
