# VPS Declarative Management (`vps/` module) — Design

**Date:** 2026-07-03
**Status:** Approved

## Context

The Stalwart mail server in the cluster depends on an UpCloud VPS (`wg-haproxy`,
212.147.241.182, Ubuntu 26.04 LTS, 1C/1GB/10GB, 3€/mo) that relays all public mail
traffic over a WireGuard tunnel terminating on talos7's machine-level `wg0`:

- **haproxy** — inbound: ports 25/143/465/587/993/995/4190/443 → Stalwart at
  `172.16.8.10`. Port 25 uses PROXY v2 so Stalwart sees real client IPs (DNSBL/SPF).
  Port 443 SNI-splits `webmail.erinko.fi` → Traefik (`172.16.8.11`), rest → Stalwart.
- **Postfix** — outbound smarthost only. Listens solely on WG IP `172.16.8.2`,
  `mynetworks = 172.16.8.0/24`, delivers directly to destination MXes (clean egress
  IP/PTR, VPS-side retry queue).
- **WireGuard** — `wg-quick@wg0`; peer is talos7 (`172.16.8.1`, keepalive 25s).
- **fail2ban** (sshd jail, SSH on port 2222) and **unattended-upgrades** (installed,
  but no automatic reboots).

The VPS is a hand-managed snowflake: none of this configuration is in git, and
package updates/reboots are manual.

### Rejected alternative

Joining the VPS to the cluster as a Talos node via KubeSpan was evaluated and
rejected: Cilium's agent request (700Mi) exceeds the 1GB plan; the cluster's
`routingMode: native` + `autoDirectNodeRoutes` assumes a single L2 segment;
`loadBalancer.mode: dsr` breaks for WAN ingress; KubeSpan would route all home
east-west traffic through WireGuard (losing 9000-MTU performance); and a public
node greatly widens the blast radius. Replacing haproxy/postfix with plain
nftables DNAT was also rejected: it would lose PROXY v2 client IPs, SNI routing,
and the smarthost egress path.

## Design

### 1. Repo layout

```
vps/
├── mod.just                 # module: just vps apply / just vps ssh
├── secrets.sops.yaml        # VPS WireGuard private key (new .sops.yaml rule)
├── apply.sh                 # idempotent remote apply script
└── config/
    ├── haproxy.cfg                  # as currently on the VPS
    ├── postfix-main.cf              # minus dead transport_maps reference
    ├── wg0.conf.j2                  # private key injected at render time
    ├── sshd-hardening.conf          # port 2222, key-only auth
    ├── fail2ban-jail.local          # sshd jail on port 2222
    └── unattended-upgrades.conf     # see §3
```

Registered in the root `.justfile` as `mod vps "vps"`.

### 2. Apply flow

`just vps apply`:
1. Renders `wg0.conf` from `wg0.conf.j2` + `secrets.sops.yaml` (sops + minijinja,
   same pattern as `just talos render-config`).
2. Pushes `config/` + `apply.sh` to the VPS over ssh port 2222.
3. Runs `apply.sh` remotely: installs packages (`haproxy postfix wireguard
   fail2ban unattended-upgrades needrestart`), diff-installs each config file,
   reloads only services whose config changed (haproxy reload is hitless;
   `wg-quick@wg0` restart drops the tunnel ~1s).

Idempotent from a vanilla Ubuntu image. **Disaster recovery:** create UpCloud VM
with SSH key → `just vps apply`. No pull machinery on the box.

### 3. Updates and reboots

`unattended-upgrades` configured with `Automatic-Reboot "true"` at 04:30
Europe/Helsinki (only when reboot-required), plus `needrestart` in automatic mode
for service restarts after library updates. A reboot costs ~1 minute of mail
downtime; sending MTAs retry, Postfix's queue is on disk, IMAP clients reconnect.

### 4. WireGuard key rotation — ✅ completed 2026-07-03

talos7's WG private key had been committed in plaintext to this public repo
(`talos/nodes/talos7.yaml.j2`). Fixed: new keypair generated; private key moved
to `talos/secrets.sops.yaml` as `talos7_wg_private_key`; node patch now templates
it; `talos/mod.just` render-config now feeds SOPS data into node-patch rendering;
VPS peer updated; rotation verified end-to-end (fresh handshake + Stalwart SMTP
banner from the public internet). No git-history rewrite: rotation makes the
leaked key worthless.

### 5. Deferred: allowed-ips narrowing

The VPS's `allowed-ips` include the pod (`10.42.0.0/16`) and service
(`10.96.0.0/16`) CIDRs. Pod CIDR is required today: Stalwart connects to Postfix
at `172.16.8.2` sourced from its pod IP. Narrowing requires cluster-side SNAT of
pod→WG traffic first. Left as future hardening.

## Success criteria

1. `just vps apply` against the current VPS converges with no service disruption
   and no manual steps.
2. `just vps apply` against a fresh Ubuntu VM produces a working relay (verified
   by SMTP banner through the tunnel).
3. Unattended security updates apply and the box reboots itself when required,
   with mail flow resuming unaided.
4. No secrets in the repo outside SOPS-encrypted files.
