# Technitium TLS bundle sync

NPMplus is the only ACME client. It issues one certificate covering
`technitium.vaderrp.com`, `*.dns.vaderrp.com` and `dns.vaderrp.com` via DNS-01
through Cloudflare, and each Technitium LXC pulls the result on a timer,
converts it to PKCS#12, and drops it where Technitium expects it.

Design rationale, including why the nodes pull rather than NPMplus pushing:
[`docs/networking/technitium-dns-ha.md`](../../docs/networking/technitium-dns-ha.md) §4.1.

## Why pull

A push would mean NPMplus holding an SSH credential able to write
`/etc/dns/ssl.pfx` on every DNS server — root-equivalent over the whole DNS
tier, held by the most network-exposed component in the chain. Pulling reverses
that: each node holds a read-only credential for one directory, and a
compromised NPMplus cannot write anything to a DNS server.

## Prerequisites

- NPMplus runs as a container with `/opt/npmplus:/data`, so the certificate it
  writes to `/data/tls/certbot/live/npm-15/` is visible on the **LXC
  filesystem** at `/opt/npmplus/tls/certbot/live/npm-15/`. Nothing inside the
  container is touched, so image updates cannot break this.
- A proxy host must stay attached to the certificate in NPMplus — it only
  renews certificates that have one, even if nothing routes through it.

## Install on NPMplus

The NPMplus LXC runs **Alpine** with OpenSSH. `privkey.pem` is root-owned
`0600`, so the key goes in root's `authorized_keys`; the forced command is what
makes that acceptable.

A fixed command is used rather than `rrsync`. Alpine does not package `rrsync`,
and recent versions are a Python script that would pull `python3` onto a
container host for no benefit — but the better reason is that `rrsync` exists to
safely parse client-supplied rsync flags, and a fixed command has no such
surface at all. `tar -h` also dereferences the `live/` symlinks server-side,
which is more direct than asking the client to do it.

```sh
# /usr/local/bin/cert-export on the NPMplus LXC, mode 0755
#!/bin/sh
exec tar -C /opt/npmplus/tls/certbot/live/npm-15 -czhf - fullchain.pem privkey.pem
```

`apk add tar` if busybox's tar does not accept `-h`.

```
# /root/.ssh/authorized_keys — APPEND, do not overwrite
command="/usr/local/bin/cert-export",restrict ssh-ed25519 AAAAC3Nza... ns1-cert-sync
```

> **Append.** This key can never open a shell, so if it replaces an existing key
> rather than joining it, SSH shell access to the LXC is gone and recovery is
> `pct enter <ctid>` from the Proxmox host.

`restrict` requires OpenSSH 7.2+ and implies `no-pty`, `no-port-forwarding`,
`no-agent-forwarding`, `no-X11-forwarding` and `no-user-rc`. On Dropbear, which
does not support it, list those individually instead.

Generate one key per node so either can be revoked independently:

```sh
ssh-keygen -t ed25519 -N '' -C 'ns1-cert-sync' -f /root/.ssh/technitium-cert-sync
```

Verify from the node — both commands must produce the same tarball, because the
forced command ignores whatever the client asks for:

```sh
ssh -T -p 2222 -i /root/.ssh/technitium-cert-sync root@npmplus | tar -tzf -
ssh -T -p 2222 -i /root/.ssh/technitium-cert-sync root@npmplus 'echo hello'
```

If the second prints `hello`, the forced command is not in effect and that key
has a full root shell.

Without `-T` you will also see `PTY allocation request failed on channel 0`.
That is `restrict` refusing a terminal — the fetch still succeeds, and `-T`
simply stops asking.

### Seed known_hosts before enabling the timer

The script runs `BatchMode=yes`, so an unknown host key is a hard failure rather
than a prompt. Root's `known_hosts` must already trust NPMplus on **each** node
before the timer runs unattended — the first interactive `ssh` does this, but
only on the node where it was run:

```sh
ssh-keyscan -p 2222 -t ed25519 npmplus >> /root/.ssh/known_hosts
```

Port 2222, not 22: NPMplus's own sshd moved there at the Forgejo cutover, and
its :22 is now the NPM+ stream to Forgejo, which answers with Forgejo's host key.
A known_hosts entry for a non-default port is keyed `[npmplus]:2222`.

Compare the fingerprint against the one the other node already accepted rather
than trusting whatever answers:

```sh
ssh-keygen -lf /root/.ssh/known_hosts -F '[npmplus]:2222'
```

## Install on each Technitium node

```sh
install -m 0755 technitium-cert-sync.sh /usr/local/bin/
install -m 0644 technitium-cert-sync.service technitium-cert-sync.timer /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now technitium-cert-sync.timer

# First run, watching the output
systemctl start technitium-cert-sync.service
journalctl -u technitium-cert-sync.service -n 20
```

Run it under systemd rather than by hand for the first test. The unit sandboxes
the filesystem, so a script that works from a shell can still fail as a service
— `ProtectHome` and `ProtectSystem` between them decide whether `/root/.ssh` and
`/etc/dns` are even visible. A direct `./technitium-cert-sync.sh` proves
nothing about whether the timer will work.

Then in the Technitium admin UI, Settings → Optional Protocols:

- **TLS Certificate File Path**: `/etc/dns/ssl.pfx`
- **TLS Certificate Password**: leave empty

Clustering replicates both of those settings, so the path and password must be
identical on every node. The bundle contents are identical too, since one
certificate is distributed.

## Configuration

The script reads four optional environment variables, all with defaults that
match this deployment. Override via a systemd drop-in if needed:

| Variable | Default | Meaning |
|---|---|---|
| `SRC_HOST` | `root@npmplus` | Host serving the bundle |
| `SRC_PORT` | `2222` | NPMplus's own sshd (its :22 is the stream to Forgejo) |
| `SSH_KEY` | `/root/.ssh/technitium-cert-sync` | Key matching the forced command |
| `OUT` | `/etc/dns/ssl.pfx` | Where Technitium reads the bundle |
| `WORK` | `/var/lib/technitium-cert` | Scratch and last-synced copy |

The certificate ID lives in `/usr/local/bin/cert-export` on NPMplus rather than
here. If the certificate is recreated it becomes `npm-16`, `npm-17` and so on,
and that script needs updating — on one host, not on every node.

## Verifying

```sh
systemctl list-timers technitium-cert-sync.timer
openssl pkcs12 -in /etc/dns/ssl.pfx -passin pass: -nokeys | openssl x509 -noout -subject -dates -ext subjectAltName
```

Then check encrypted DNS actually serves it:

```sh
kdig -d +tls @ns1.dns.vaderrp.com google.com      # DoT, port 853
kdig -d +https @ns1.dns.vaderrp.com google.com    # DoH, port 443
```

`kdig` is in the `knot-dnsutils` package.

## Failure modes

- **A broken pull is invisible from the outside.** Nothing about a node serving
  a stale certificate looks wrong until it expires and clients start refusing
  the handshake. The Gatus checks on `:853` in
  `kubernetes/apps/observability/gatus/` exist for exactly this, with a `240h`
  threshold matched to NPMplus running `ACME_PROFILE=classic` (90-day certs).
  If that profile ever changes back to `shortlived`, those thresholds have to
  come down with it — `240h` against a 160-hour certificate alerts permanently.
- **The script never clobbers a good bundle.** If the fetch fails or returns an
  empty file it exits non-zero without touching `/etc/dns/ssl.pfx`, leaving the
  previous certificate in place until the next run. Failures surface in
  `journalctl -u technitium-cert-sync`.
- **The `-legacy` OpenSSL flags** mirror the old in-cluster initContainer. They
  are *not* required for the bundle to be readable — OpenSSL 3.5 on Debian 13
  reads the result back without `-legacy` — so they are inherited caution rather
  than a demonstrated need, and dropping them for modern defaults is untested
  but plausible.
- **The certificate has no Common Name.** Let's Encrypt's `shortlived` profile
  omits it, so `openssl x509 -subject` prints an empty `subject=` and the SAN
  extension is marked critical (which RFC 5280 requires when the subject is
  empty). NPMplus' own compose file warns that "clients incorrectly requiring a
  Certificate Common Name break when using certs from the shortlived/tlsserver
  profile". If Technitium turns out to be one of them, set `ACME_PROFILE=classic`
  on NPMplus for a 90-day certificate that carries a CN — which would also end
  the six-day renewal treadmill, at the cost of applying to every NPMplus
  certificate.
