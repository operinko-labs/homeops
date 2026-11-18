# Edge Traefik (replaces NPMplus) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the NPMplus LXC (VMID 107, 192.168.0.5) with a standalone, git-configured Traefik LXC named `edge`. Close the Host-header bypass on the public Forgejo path, and give a read-only Traefik dashboard for overview.

**Architecture:** A new Alpine LXC on meanie runs pinned Traefik and lego binaries under OpenRC. There is no Docker. `just forge apply-edge` pushes all config from `forge/`, the same way `apply-forgejo` and `apply-npmplus` already work. Public traffic (VPS haproxy over WireGuard) lands on its own entrypoint, and only the Forgejo router is attached to it. Every LAN route sits on an entrypoint with a LAN-only allowlist. At cutover the new LXC takes over 192.168.0.5, its WireGuard identity and its SSH host keys. That leaves Forgejo's sshd `Match Address`, the PerSourcePenalties exemption, the UDM policies and the Technitium cert-sync hosts unchanged.

**Tech Stack:** Traefik v3 (file provider), lego (ACME DNS-01 via Cloudflare), Alpine + OpenRC, minijinja-cli templates, SOPS (`forge/secrets.sops.yaml`), Renovate annotated regex manager.

**Spec:** No separate spec. The design came from the 2026-11-18 session: nginx HTTP/2 CVEs (CVE-2026-123633 / CVE-2026-123007) hit npmplus, which is internet-facing through the VPS. The decisions are fixed in Global Constraints below.

## Background facts (verified 2026-11-18)

- **npmplus is reachable from the internet.** VPS haproxy (`vps/config/haproxy.cfg`, `bk_forgejo_web`) passes SNI `forgejo.vaderrp.com` to `172.16.8.20:443` with no proxy in between. `bk_forgejo_ssh` sends `:22` to `172.16.8.20:22`.
- **The Host header bypass is live.** Through `--resolve forgejo.vaderrp.com:443:212.147.241.182`, a spoofed `Host:` reaches proxmox (200), pbs (200), ilo (200), vaultwarden (200), hass (200) and truenas (302). Only hosts with the npmplus `allow 192.168.0.0/16` access list answer 403. Traffic from the VPS arrives from its WireGuard address, `172.16.8.2`.
- **Certificates.** npmplus is the only ACME client, using DNS-01 through Cloudflare. Two certs are in use: `*.vaderrp.com`+`vaderrp.com` (`npm-12`) and `*.dns.vaderrp.com`+`dns.vaderrp.com`+`technitium.vaderrp.com` (`npm-15`). Both Technitium nodes pull `npm-15` hourly with `scripts/technitium-cert-sync/`. That's `ssh -p 2222 root@npmplus`, a forced command that tars `fullchain.pem` + `privkey.pem`, and pinned `known_hosts`. Two `cert-sync` keys sit in `/root/.ssh/authorized_keys` on LXC 107.
- **npmplus LXC facts.** It runs Alpine; its own sshd is on `:2222`; `:22` is the stream to `192.168.7.30:22`. Its globals are `client_max_body_size 0` and `proxy_read_timeout 86400s`. HSTS is cleared, so don't add it.
- **Which names actually use npmplus.** Only names whose LAN DNS resolves to 192.168.0.5 go through it. Its other entries are already bypassed: proxmox, unifi, truenas, ilo and minio resolve direct; ruoka and bambuddy resolve to the cluster; nextcloud and owncloud have no record; collabra is on Cloudflare; dns and `*.dns` resolve direct. minio-admin and pulse return 502 because their backends are gone. `npm.vaderrp.com` is NPMplus's own UI.

## Global Constraints

- Every config file lives in git under `forge/`, and secrets live in `forge/secrets.sops.yaml`. Nothing is configured by hand on the LXC except the one-off provisioning in Task 3, which must be recorded in `forge/README.md`.
- Traefik version: same minor as the cluster (`docker.io/traefik:v3.7.6` at time of writing). lego version: the latest GitHub release at execution time. Pin both in `forge/config/edge/versions.env` with `# renovate: datasource=github-releases depName=traefik/traefik` / `depName=go-acme/lego` annotations. The existing customManager already matches `.env`.
- Download binaries from GitHub releases and verify them against the release's checksums file before installing. No Harbor dependency: the edge proxy has to work while the cluster is down.
- Entrypoints: `web` :80 (redirect to https), `websecure` :443 (LAN), `wan` :8443 (VPS path only), `ssh` :22 (TCP).
- `websecure` gets a LAN-only `ipAllowList` of `192.168.0.0/16`, attached at the entrypoint so no route can skip it.
- Only the `forgejo` router is attached to `wan`. Any other Host on `wan` gets a 404.
- Entrypoint `respondingTimeouts.readTimeout: 0`, `writeTimeout: 0`, `idleTimeout: 180s`. This matches npmplus's unlimited bodies and long reads; Traefik v3's 60s readTimeout default breaks large uploads.
- No HTTP/3, no HSTS, and no certResolver in Traefik. Certificates come from files written by lego.
- Dashboard at `edge.vaderrp.com`: `api@internal`, LAN allowlist plus `basicAuth`, read-only. There is no `api.insecure`, so it isn't served on :8080.
- The new LXC ends up as 192.168.0.5, with LXC 107's SSH host keys and the `npmplus_wg_private_key` WireGuard key.
- Commits go straight to homeops `main` (see the repo's PR-vs-main convention), with no AI attribution.

## Review Focus

1. **A spoofed Host on the public path:** `--resolve forgejo.vaderrp.com:443:212.147.241.182 -H 'Host: pbs.vaderrp.com'` must return 404, never the PBS page. Tested in Task 2, run in Task 5.
2. **Large and long uploads** (Immich `photos`, Vaultwarden attachments, Jellyfin/Plex streams): they must not be cut at 60s. Covered by the timeout constraint, plus a timed upload check in Task 3.
3. **Technitium cert-sync** must keep working with no change on the DNS nodes: same host key, same forced command and the same tarball member names (`fullchain.pem`, `privkey.pem`). Checked in Task 5 from ns1.
4. **Self-signed HTTPS backends** (cups, vaultwarden, pbs, technitium) must proxy without TLS errors. Use the `insecure` serversTransport, covered by the smoke test's per-route expected codes.
5. **A lego renewal** must reach Traefik without a restart. The file provider has `watch: true`, the hook copies atomically, and Task 3 tests it by forcing a renewal.

---

### Task 1: Stopgap — block Host-spoofing on npmplus's VPS path

This is independent of the migration, so do it first. Task 5 removes it when 107 is shut down.

**Files:**
- Modify (on LXC 107, not in git): `/opt/npmplus/custom_nginx/server_proxy.conf`. It's empty today, and every proxy host includes it.
- Modify: `forge/README.md`. Add a one-line note in "Manual state not covered here".

- [ ] **Step 1: Record the failing check**

Run from WSL:
```bash
for h in forgejo pbs vaultwarden hass emqx; do printf '%s ' $h; curl -sk -o /dev/null -w '%{http_code}\n' -m 10 --resolve forgejo.vaderrp.com:443:212.147.241.182 -H "Host: $h.vaderrp.com" https://forgejo.vaderrp.com/; done
```
Expected now: `forgejo 303`, `pbs 200`, `vaultwarden 200`, `hass 200`, `emqx 403`. The three 200s are the bug.

- [ ] **Step 2: Write the snippet into `/opt/npmplus/custom_nginx/server_proxy.conf`**

```nginx
# Requests via the VPS WireGuard peer may only reach forgejo.vaderrp.com
set $edge_wan "";
if ($remote_addr ~ "^172\.16\.8\.") { set $edge_wan "w"; }
if ($host != "forgejo.vaderrp.com") { set $edge_wan "${edge_wan}o"; }
if ($edge_wan = "wo") { return 421; }
```
Then `docker exec npmplus nginx -t && docker exec npmplus nginx -s reload`.

- [ ] **Step 3: Re-run the Step 1 loop**

Expected: `forgejo 303`, and `421` for each of the other four. Also run the LAN baseline (the Task 2 smoke script, `--lan-only` against 192.168.0.5) or spot-check `curl --resolve pbs.vaderrp.com:443:192.168.0.5` → 200. This proves LAN clients are unaffected.

- [ ] **Step 4: Commit the README note**

```bash
git add forge/README.md
git commit -m "docs(forge): note the npmplus VPS host-spoofing stopgap"
```

---

### Task 2: Route inventory and smoke test

**Files:**
- Create: `forge/config/edge/routes.yaml`, the only list of proxied hosts
- Create: `forge/edge-smoke.sh`

**Interfaces:**
- Produces: `routes.yaml` with top-level key `edge_routes:`, a list of `{name, host, url, insecure?: bool, expect: int, wan?: bool}`. Tasks 3–5 render and test from this.
- Produces: `forge/edge-smoke.sh <lan-ip> [--wan]`. It exits 0 only if every route on `<lan-ip>:443` returns its `expect` code, the dashboard returns 401 without credentials, `:22` presents the Forgejo host key, and (with `--wan`) the public path passes the checks in Step 3.

- [ ] **Step 1: Write `routes.yaml`**

These are the 18 live routes. `expect` is the 2026-11-18 baseline through npmplus:

| name | host | url | insecure | expect |
|---|---|---|---|---|
| tdarr | tdarr.vaderrp.com | http://192.168.0.97:8265 | | 200 |
| valetudo | valetudo.vaderrp.com | http://192.168.0.62:80 | | 200 |
| emqx | emqx.vaderrp.com | http://192.168.55.234:18083 | | 200 |
| z2m | z2m.vaderrp.com | http://192.168.55.218:8099 | | 200 |
| nodered | nodered.vaderrp.com | http://192.168.55.65:1880 | | 200 |
| esphome | esphome.vaderrp.com | http://192.168.55.235:6052 | | 200 |
| cups | cups.vaderrp.com | https://192.168.0.215:631 | yes | 200 |
| hass | hass.vaderrp.com | http://192.168.0.40:8123 | | 200 |
| vaultwarden | vaultwarden.vaderrp.com | https://192.168.0.136:8000 | yes | 200 |
| myspeed | myspeed.vaderrp.com | http://192.168.55.14:5216 | | 200 |
| storj | storj.vaderrp.com | http://192.168.0.221:20909 | | 200 |
| pbs | pbs.vaderrp.com | https://192.168.0.183:8007 | yes | 200 |
| photos | photos.vaderrp.com | http://192.168.0.221:30041 | | 200 |
| immich-power-tools | immich-power-tools.vaderrp.com | http://192.168.0.221:30042 | | 200 |
| technitium | technitium.vaderrp.com | https://192.168.5.7:53443 | yes | 200 |
| forgejo | forgejo.vaderrp.com | http://192.168.7.30:3000 | | 303 (wan: true) |
| jellyfin | jellyfin.vaderrp.com | http://192.168.0.116:8096 | | 302 |
| plex | plex.vaderrp.com | http://192.168.0.7:32400 | | 401 |

Leave a YAML comment listing the dropped entries and why, so nobody re-adds them: proxmox, unifi, truenas, ilo and minio (DNS goes direct); ruoka and bambuddy (cluster); nextcloud, owncloud and the collabra entries (no LAN record); minio-admin and pulse (502, backend gone); npm (replaced by the dashboard).

- [ ] **Step 2: Write `forge/edge-smoke.sh`**

Read routes with `yq -r '.edge_routes[] | [.host, .expect] | @tsv'`. For each route, `curl -sk -o /dev/null -w '%{http_code}' -m 15 --resolve "$host:443:$ip" "https://$host/"` and compare to `expect`. Also check:
- `https://edge.vaderrp.com/dashboard/` via `--resolve` returns 401.
- `ssh-keyscan -p 22 -t ed25519 $ip` matches `ssh-keyscan -p 22 -t ed25519 192.168.7.30`.
- `openssl s_client -connect $ip:443 -servername technitium.vaderrp.com` shows `technitium.vaderrp.com` in its SANs.

Print one `OK|FAIL name got/expected` line per check and exit non-zero on any FAIL.

- [ ] **Step 3: Add the `--wan` checks**

Through `--resolve forgejo.vaderrp.com:443:212.147.241.182`:
- No Host override returns 303.
- `-H "Host: $h"` for pbs, vaultwarden and hass must **not** return 2xx or 3xx. That accepts npmplus's 421 now and edge's 404 later.

- [ ] **Step 4: Run it against npmplus to validate the test itself**

Run: `bash forge/edge-smoke.sh 192.168.0.5 --wan`
Expected: every route OK. The ssh check is OK. Dashboard is FAIL: npmplus has no `edge.vaderrp.com`, and that's expected now. The wan checks are OK once Task 1 is done.

- [ ] **Step 5: Run it against an unused IP to confirm it can fail**

Run: `bash forge/edge-smoke.sh 192.168.0.6`. Expected: everything FAILs and the exit code is non-zero.

- [ ] **Step 6: Commit**

```bash
git add forge/config/edge/routes.yaml forge/edge-smoke.sh
git commit -m "feat(forge): edge route inventory and smoke test"
```

---

### Task 3: Provision the `edge` LXC with Traefik and lego (temporary IP)

**Files:**
- Create: `forge/config/edge/versions.env`: `TRAEFIK_VERSION=` and `LEGO_VERSION=` with Renovate annotations
- Create: `forge/config/edge/traefik.yaml`: static config (entrypoints, file provider `/etc/traefik/dynamic` with `watch: true`, accessLog to `/var/log/traefik/access.log` as JSON, `api.dashboard: true`, `api.insecure: false`)
- Create: `forge/config/edge/dynamic.yaml.j2`: routers, services, middlewares and serversTransports generated from `edge_routes`, plus the `tls.certificates` entries
- Create: `forge/config/edge/lego.env.j2`: `CLOUDFLARE_DNS_API_TOKEN={{ edge_cloudflare_dns_token }}`, `LEGO_EMAIL={{ edge_acme_email }}`
- Create: `forge/config/edge/traefik.initd`: OpenRC script running as user `traefik`, `output_log`/`error_log` under `/var/log/traefik/`
- Create: `forge/config/edge/edge-cert-hook.sh`: lego renew hook
- Create: `forge/config/edge/edge-cert-renew.sh`: the daily cron entry point
- Create: `forge/config/edge/logrotate-traefik`
- Create: `forge/apply-edge.sh`: idempotent installer, in the same style as `apply-npmplus.sh`, printing `changed:` / `no changes`
- Modify: `forge/mod.just`: `edge_ip` variable and an `apply-edge` recipe
- Modify: `forge/secrets.sops.yaml`: add `edge_cloudflare_dns_token`, `edge_acme_email` and `edge_dashboard_htpasswd` (the dashboard user is added in Task 4)

**Interfaces:**
- Consumes: `edge_routes` (Task 2) and `npmplus_wg_private_key` (existing; not used until Task 5)
- Produces: certs at `/etc/edge/certs/<lego-name>/{fullchain,privkey}.pem`, where `<lego-name>` is `_.vaderrp.com` or `_.dns.vaderrp.com`, owned `root:traefik` with modes `0644`/`0640`. Task 5's cert-export reads `/etc/edge/certs/_.dns.vaderrp.com/`.
- Produces: `just forge apply-edge` (renders, stages to `/root/.homeops-staging`, runs `apply-edge.sh`, removes staging)

- [ ] **Step 1: Provision the LXC on meanie (one-off; record it in README)**

- Copy `net0` bridge, tag and gateway, `unprivileged` and `features` from `pct config 107`.
- `pct create <free VMID> <latest stable Alpine template from pveam> --hostname edge --cores 2 --memory 512 --rootfs <same storage as 107>:4 --onboot 1 --net0 ...,ip=<temp-ip>/24`.
- Temp IP is `192.168.0.6` if `ping -c2` and the UniFi client list show it free. Otherwise pick the next free one.
- Inside the LXC: `apk add openssh tar curl logrotate libcap-utils ca-certificates`, sshd `Port 2222`, and root `authorized_keys` from LXC 107 minus the two `cert-sync` lines. Those come in Task 5.

- [ ] **Step 2: Add the secrets**

- `edge_cloudflare_dns_token`: the token from the file named by `dns_cloudflare_credentials` in `/opt/npmplus/tls/certbot/renewal/npm-12.conf` on 107.
- `edge_acme_email`: the same email as the npmplus certbot account.
- `edge_dashboard_htpasswd`: `htpasswd -nbB olli <new password>`, with the password stored in Vaultwarden.

Edit with `sops forge/secrets.sops.yaml`.

- [ ] **Step 3: Write the static and dynamic config**

`traefik.yaml`:
- Entrypoints per Global Constraints.
- `web` redirects to `websecure`.
- `websecure.http.middlewares: [lan-only@file]`.
- The `wan` entrypoint has no middleware. Its only router is forgejo, and unmatched Hosts get Traefik's default 404.
- Transport timeouts per constraints on `websecure` and `wan`.

`dynamic.yaml.j2`, generated for each route:
- An HTTP router `rule: Host(`{{ host }}`)`, `entryPoints: [websecure]`, plus `wan` if `wan: true`, and `tls: {}`.
- A service `loadBalancer.servers[0].url: {{ url }}`, with `serversTransport: insecure` when `insecure`.

Also in `dynamic.yaml.j2`:
- A TCP router `ssh`: `HostSNI(`*`)` on entrypoint `ssh` → `192.168.7.30:22`.
- Middleware `lan-only`: `ipAllowList.sourceRange: [192.168.0.0/16]`.
- `serversTransports.insecure.insecureSkipVerify: true`.
- `tls.certificates` for both lego names, plus `tls.stores.default.defaultCertificate` set to the `_.vaderrp.com` pair.

- [ ] **Step 4: Write `apply-edge.sh`**

Its jobs:
- Source `versions.env`.
- For each binary, download the release tarball and its checksums file, then `sha256sum -c`. Install only if the version differs (`/usr/local/bin/traefik version`, `lego --version`), and after installing run `setcap cap_net_bind_service=+ep /usr/local/bin/traefik`.
- Create the `traefik` user and group.
- Install `/etc/traefik/traefik.yaml`, `/etc/traefik/dynamic/edge.yaml`, `/etc/edge/lego.env` (0600), the init script, the hook, renew script, logrotate file, and `/etc/periodic/daily/edge-cert-renew`.
- On the first run, when `/var/lib/lego/certificates` is empty, run `lego ... run --run-hook /usr/local/bin/edge-cert-hook` for both domain sets.
- `rc-update add traefik default`.
- On a binary or static-config change, restart. A dynamic-only change needs nothing, because the file provider reloads it.

lego invocation: `lego --path /var/lib/lego --email "$LEGO_EMAIL" --dns cloudflare --accept-tos --domains '*.vaderrp.com' --domains vaderrp.com run`. The second set is `--domains '*.dns.vaderrp.com' --domains dns.vaderrp.com --domains technitium.vaderrp.com`.

`edge-cert-renew.sh`: `lego ... renew --days 30 --renew-hook /usr/local/bin/edge-cert-hook` for both sets.

`edge-cert-hook.sh`: derive `<lego-name>` from `basename "$LEGO_CERT_PATH" .crt`. Copy `$LEGO_CERT_PATH` → `fullchain.pem.tmp` and `$LEGO_CERT_KEY_PATH` → `privkey.pem.tmp`, set ownership and modes, then `mv` each into place.

- [ ] **Step 5: Add the `apply-edge` recipe to `forge/mod.just`**

Use the same shape as `apply-npmplus`, against `edge_ip` (the temp IP for now) on ssh port 2222. Render with `{ sops -d forge/secrets.sops.yaml; cat forge/config/edge/routes.yaml; } | minijinja-cli <tmpl> --format yaml -` for `dynamic.yaml.j2` and `lego.env.j2`. Copy the static files as they are.

- [ ] **Step 6: Apply and run the smoke test**

Run: `just forge apply-edge`. Expected: `changed:` listing every file, and `rc-service traefik status` started.

Run: `bash forge/edge-smoke.sh <temp-ip>`. Expected: every route OK and ssh OK. Dashboard is FAIL until Task 4.

- [ ] **Step 7: Run `just forge apply-edge` again**

Expected: `no changes`.

- [ ] **Step 8: Test a hot cert reload**

Run `lego ... renew --days 999 --renew-hook ...` for the `_.dns.vaderrp.com` set, which forces a reissue. Then compare `openssl s_client -connect <temp-ip>:443 -servername technitium.vaderrp.com | openssl x509 -noout -serial` before and after.

Expected: a new serial, with no Traefik restart (`rc-service traefik status` uptime unchanged).

- [ ] **Step 9: Run a long-upload check**

`curl -sk --resolve photos.vaderrp.com:443:<temp-ip> -o /dev/null -w '%{http_code} %{time_total}\n' --limit-rate 1M -X POST -F "f=@<a 150 MB file>" https://photos.vaderrp.com/api/assets`.

Expected: Immich's own answer (401 unauthenticated), after more than 60s. The point is that Traefik doesn't reset the connection; a 401 that arrives after the full upload passes.

- [ ] **Step 10: Commit**

```bash
git add forge/config/edge forge/apply-edge.sh forge/mod.just forge/secrets.sops.yaml
git commit -m "feat(forge): edge Traefik LXC with lego certificates"
```

---

### Task 4: Dashboard

**Files:**
- Modify: `forge/config/edge/dynamic.yaml.j2`. Add router `dashboard`: `Host(`edge.vaderrp.com`)`, entryPoints `[websecure]`, service `api@internal`, middleware `dashboard-auth` (`basicAuth.users: ["{{ edge_dashboard_htpasswd }}"]`).
- Manual: Technitium A record `edge.vaderrp.com` → 192.168.0.5. Until cutover, test with `--resolve` against the temp IP.

- [ ] **Step 1: Confirm the dashboard check fails**

Run: `bash forge/edge-smoke.sh <temp-ip>`. Expected: dashboard `FAIL got 404 expected 401`.

- [ ] **Step 2: Add the router and middleware, then `just forge apply-edge`**

Expected: `changed: dynamic`, with no Traefik restart.

- [ ] **Step 3: Re-run the smoke test, then open the dashboard**

Expected: all OK. Then open `https://edge.vaderrp.com/dashboard/` in a browser with a hosts override or after cutover. Log in and confirm the HTTP routers (18 + dashboard), the TCP router `ssh`, and the `wan` entrypoint showing only `forgejo`.

- [ ] **Step 4: Add the record and commit**

Add the Technitium record, then:
```bash
git add forge/config/edge/dynamic.yaml.j2
git commit -m "feat(forge): edge Traefik dashboard"
```

---

### Task 5: Cutover (IP, WireGuard, host keys, cert-sync, VPS port)

**Files:**
- Modify: `forge/apply-edge.sh`. Add a WireGuard block, the same logic as `apply-npmplus.sh`, using `forge/config/wg0-npmplus.conf.j2` rendered as `wg0.conf`.
- Modify: `forge/mod.just`. Set `edge_ip := '192.168.0.5'` and render `wg0-npmplus.conf.j2` in `apply-edge`.
- Create: `forge/config/edge/cert-export`, the forced command: `exec tar -C /etc/edge/certs/_.dns.vaderrp.com -czhf - fullchain.pem privkey.pem`, installed by `apply-edge.sh` at `/usr/local/bin/cert-export` (0755).
- Modify: `vps/config/haproxy.cfg`. In `backend bk_forgejo_web`, change the server line to `server edge 172.16.8.20:8443`, and update the comment on the `use_backend` line.

**Interfaces:**
- Consumes: the Task 3 cert path. The cert-sync tarball member names stay `fullchain.pem` and `privkey.pem`.

- [ ] **Step 1: Prepare without disrupting anything**

- On 107: `pct snapshot 107 pre-edge-cutover` (on meanie).
- Copy `/etc/ssh/ssh_host_*` from 107 into the edge LXC, and append the two `cert-sync` lines from 107's `/root/.ssh/authorized_keys` unchanged. Their `command="/usr/local/bin/cert-export",restrict` already names the path this task installs.
- Commit the apply-edge, haproxy and cert-export changes, but don't apply yet.

- [ ] **Step 2: Cut over (Forgejo web/SSH is down for about two minutes)**

1. On meanie: `pct set 107 --onboot 0 && pct stop 107`.
2. `pct set <edge VMID> --net0 ...,ip=192.168.0.5/24 && pct reboot <edge VMID>`.
3. `just forge apply-edge`. Expected: `changed: wg0.conf ...` and a WireGuard handshake shown.
4. `just vps apply`.
5. On the VPS: `haproxy -c -f /etc/haproxy/haproxy.cfg` must be valid, and `wg show wg0 latest-handshakes` must list a recent handshake from 172.16.8.20.

- [ ] **Step 3: Run the full smoke test**

Run: `bash forge/edge-smoke.sh 192.168.0.5 --wan`.

Expected: all OK. In particular, the spoofed Host for pbs, vaultwarden and hass on the public path now returns **404**, `:22` presents the Forgejo key, and the dashboard returns 401.

- [ ] **Step 4: Check that cert-sync still works, from ns1 (192.168.5.8)**

Run `systemctl start technitium-cert-sync && journalctl -u technitium-cert-sync -n 5`. Expected: exit 0, with no host-key error. Then run `ssh -T -p 2222 -i /root/.ssh/technitium-cert-sync root@npmplus 'echo hello' | tar -tzf -`. Expected: it lists the two PEMs and does not print `hello`. Repeat on ns2.

- [ ] **Step 5: Check the real clients**

- `git fetch` on a homeops checkout (SSH through edge).
- `flux get sources git -A`: homeops is Ready after `flux reconcile source git -n flux-system flux-system`.
- A Forgejo Actions run picks up and finishes (runners talk to `forgejo.vaderrp.com`).
- Open hass and vaultwarden in a browser.

- [ ] **Step 6: Rollback, only if Steps 3–5 fail**

1. `pct stop <edge VMID>`.
2. `pct set 107 --onboot 1 && pct start 107`.
3. Revert the haproxy line to `:443` and `just vps apply`.
4. The Task 1 stopgap is still in 107's config.

- [ ] **Step 7: Commit**

```bash
git add forge/apply-edge.sh forge/mod.just forge/config/edge/cert-export vps/config/haproxy.cfg
git commit -m "feat(forge): cut Forgejo and LAN proxying over to edge Traefik"
```

---

### Task 6: Documentation and decommission

**Files:**
- Modify: `forge/README.md`. Change the host table row `npmplus | 107` to `edge | <VMID> | 192.168.0.5 | Traefik + lego, :22 stream, WG peer to VPS`. Replace the npmplus execution notes with edge equivalents: ssh `:2222`, the cert paths, and that `routes.yaml` is the only list of proxied hosts. Add an "Upgrades" line: Renovate bumps `versions.env`, then run `just forge apply-edge`.
- Modify: `forge/mod.just`. Remove the `apply-npmplus` recipe and the `npmplus_*` variables. `wg0-npmplus.conf.j2` keeps its name, because the secret key name `npmplus_wg_private_key` stays.
- Delete: `forge/apply-npmplus.sh`
- Modify: `scripts/technitium-cert-sync/README.md`. Change the "Install on NPMplus" section to the edge LXC and `/etc/edge/certs/_.dns.vaderrp.com`; lego replaces NPMplus as the only ACME client.
- Modify: `docs/network-map.md`. Change LXC 107 npmplus to the edge LXC.
- Modify: `kubernetes/apps/observability/gatus/app/gatus-config.yaml`. Change only the comment near line 108 that names NPMplus as the cert source.

- [ ] **Step 1: Make the edits and confirm nothing still points at the old setup**

Run `grep -rnI 'npmplus\|NPMplus' --exclude-dir=.git --exclude-dir=.claude --exclude-dir=.superpowers forge scripts docs/network-map.md kubernetes vps`. Expected: hits only in `wg0-npmplus.conf.j2`, the `npmplus_wg_private_key` reference, historical plans and specs, and the technitium-cert-sync `SRC_HOST` default `root@npmplus`. Keep the DNS name `npmplus` → 192.168.0.5 as an alias, so the DNS nodes need no change.

- [ ] **Step 2: Commit and push**

```bash
git add -A forge scripts/technitium-cert-sync/README.md docs/network-map.md kubernetes/apps/observability/gatus/app/gatus-config.yaml
git commit -m "docs(forge): edge Traefik replaces NPMplus"
git push
```

- [ ] **Step 3: Remove the old setup after 7 quiet days**

- Delete the Technitium record `npm.vaderrp.com`.
- Take a PBS backup of 107.
- `pct destroy 107`.
- Remove the `pre-edge-cutover` snapshot reference from notes.
