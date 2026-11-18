# Edge real client IPs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Backends behind the edge Traefik LXC see the visitor's real IP, on both the Cloudflare path and the VPS (Forgejo) path.

**Architecture:**
- **Cloudflare path:** `traefik-warp` is vendored as a Traefik local plugin and attached to the `websecure` entrypoint, where it sets `X-Real-IP` from `CF-Connecting-IP` only for sockets in Cloudflare's ranges.
- **VPS path:** haproxy sends PROXY protocol v2 to the `wan` entrypoint, and Forgejo trusts edge as its reverse proxy.
- **Testing:** smoke checks read edge's JSON access log for a uniquely tagged request.

**Tech Stack:** Traefik v3.7 local plugins (Yaegi), traefik-warp v1.1.5, haproxy PROXY v2, Forgejo `[security]`, bash smoke test.

**Spec:** `docs/superpowers/specs/2026-11-19-edge-real-client-ip-design.md`

## Global Constraints

- warp version `v1.1.5`, pinned in `forge/config/edge/versions.env` as `TRAEFIK_WARP_VERSION` with `# renovate: datasource=github-releases depName=l4rm4nd/traefik-warp`.
- The plugin is fetched by `apply-edge.sh` into `/var/lib/traefik/plugins-local/src/github.com/l4rm4nd/traefik-warp`, never at Traefik start.
- warp middleware config: `provider: cloudflare`, `autoRefresh: true`, `refreshInterval: 24h`. It is attached at entrypoint level on `websecure` only.
- `lan-only` keeps judging the socket IP: no `ipStrategy` change.
- `wan.proxyProtocol.trustedIPs: ["172.16.8.2/32"]`; haproxy `server edge 172.16.8.20:8443 send-proxy-v2`; Forgejo `REVERSE_PROXY_TRUSTED_PROXIES = 192.168.0.5`.
- Cutover order: Traefik, then haproxy, then Forgejo.
- Commit and push straight to homeops `main`, with no AI attribution. Run `bash forge/edge-smoke.sh 192.168.0.5 --wan` (WSL) green after each task.

## Review Focus

1. **A forged `CF-Connecting-IP` from a non-Cloudflare client** must not become `X-Real-IP`. Tested in Task 1 (`real-ip-spoof`).
2. **A Traefik restart with no internet** must still load the plugin: nothing is fetched at start. Task 1 Step 6 checks that the plugin directory persists and that a restart works.
3. **haproxy sending PROXY before Traefik expects it** would break Forgejo's public web path. The cutover order in Task 2, and its smoke run between steps, cover this.
4. **LAN clients** must keep their own IP as `X-Real-IP` (warp passes non-Cloudflare sockets through). Also tested by `real-ip-spoof`, which asserts a `192.168.` value.
5. **The allowlist** must still refuse Cloudflare visitors on non-public routes: the existing `lan-only-from-vps` check plus the real-CF pbs → 403 check in Task 1.

---

### Task 1: traefik-warp on the Cloudflare path

**Files:**
- Modify: `forge/edge-smoke.sh`: new checks `real-ip-cloudflare`, `real-ip-spoof`, `cf-allowlist-pbs`
- Modify: `forge/config/edge/versions.env`, `forge/apply-edge.sh`, `forge/config/edge/traefik.yaml`, `forge/config/edge/traefik.initd`, `forge/config/edge/dynamic.yaml.j2`

**Interfaces:**
- Produces: middleware `real-ip@file` (warp), the access-log field `request_X-Real-Ip`, and the smoke helper `logged <token> <jq-ish field>`, which Task 2 reuses for `ClientHost`.

- [ ] **Step 1: Write the failing smoke checks.** The helper `logged <token> <field>` SSHes to the edge LXC (`-p 2222 root@<ip>`), takes the last access-log line containing `<token>`, and prints that JSON field. Get the home WAN IP as `${SSH_CLIENT%% *}` from an SSH session to the VPS. The checks:
  - `real-ip-cloudflare`: GET `https://photos.vaderrp.com/?smoke=<token>` via `--resolve` to the Cloudflare IP that `dig -p 9953 @9.9.9.9` returns. Assert `logged <token> request_X-Real-Ip` equals the WAN IP.
  - `real-ip-spoof`: GET the same host via `--resolve` to `<lan-ip>` with `-H 'CF-Connecting-IP: 1.2.3.4'`. Assert that the logged `request_X-Real-Ip` starts with `192.168.`.
  - `cf-allowlist-pbs`: GET `https://pbs.vaderrp.com/` through the Cloudflare IP and expect `403`.
- [ ] **Step 2: Run it.** `bash forge/edge-smoke.sh 192.168.0.5` → `real-ip-cloudflare` FAIL (field empty or a Cloudflare IP), `cf-allowlist-pbs` OK.
- [ ] **Step 3: Implement.**
  - `versions.env` gets `TRAEFIK_WARP_VERSION`.
  - `apply-edge.sh`: when `/var/lib/traefik/plugins-local/src/github.com/l4rm4nd/traefik-warp/.homeops-version` differs, download `https://github.com/l4rm4nd/traefik-warp/archive/$TRAEFIK_WARP_VERSION.tar.gz`, extract it with `--strip-components=1` into a fresh directory, swap it into place, write `.homeops-version`, and set `RESTART=1`. Own the tree `root:traefik`, readable.
  - `traefik.initd`: `directory="/var/lib/traefik"`.
  - `traefik.yaml`:
    - `experimental.localPlugins.traefikwarp.moduleName: github.com/l4rm4nd/traefik-warp`
    - `websecure.http.middlewares: [real-ip@file]`
    - `accessLog.fields.headers.names: {X-Real-Ip: keep, CF-Connecting-IP: keep}` (other headers keep the default, drop)
  - `dynamic.yaml.j2`: middleware `real-ip` with `plugin.traefikwarp` set to the constraint values.
- [ ] **Step 4: Apply and run.** `just forge apply-edge`, then `bash forge/edge-smoke.sh 192.168.0.5 --wan` → 0 failures. In Traefik's log, the plugin loads with no `ERR`.
- [ ] **Step 5: Check the offline-restart claim.** On edge, run `rc-service traefik restart`, then `ls /var/lib/traefik/plugins-local/src/github.com/l4rm4nd/traefik-warp/go.mod`, then re-run the smoke test → green. Nothing is downloaded at start; this is confirmed if the log has no plugin-download line.
- [ ] **Step 6: Commit and push.** Message: `feat(forge): real client IPs on edge's Cloudflare path (traefik-warp)`.

### Task 2: PROXY protocol on the VPS path, with Forgejo trusting edge

**Files:**
- Modify: `forge/edge-smoke.sh`: check `real-ip-vps`
- Modify: `forge/config/edge/traefik.yaml`, `vps/config/haproxy.cfg`, `forge/config/app.ini.j2`

**Interfaces:**
- Consumes: the Task 1 helper `logged`.

- [ ] **Step 1: Write the failing check.** `real-ip-vps`: GET `https://forgejo.vaderrp.com/?smoke=<token>` via `--resolve` to the VPS IP. Assert `logged <token> ClientHost` equals the home WAN IP.
- [ ] **Step 2: Run it.** `--wan` run → `real-ip-vps` FAIL `got=172.16.8.2`.
- [ ] **Step 3: Traefik first.** Add `wan.proxyProtocol.trustedIPs: ["172.16.8.2/32"]`, then `just forge apply-edge`. The `--wan` run should still show `wan-forgejo` OK; `real-ip-vps` still FAILs.
- [ ] **Step 4: haproxy.** Add `send-proxy-v2` to the `bk_forgejo_web` server line, then `just vps apply`. The `--wan` run → `real-ip-vps` OK, `wan-forgejo` OK.
- [ ] **Step 5: Forgejo.** In `[security]`, add `REVERSE_PROXY_TRUSTED_PROXIES = 192.168.0.5`, then `just forge apply-forgejo`. Verify: request `/?smoke=<token>` through the VPS, then `journalctl -u forgejo` on 192.168.7.30 shows that request from the home WAN IP, not 192.168.0.5.
- [ ] **Step 6: Commit and push.** Message: `feat(forge): real client IPs for Forgejo via PROXY protocol`. Update the edge memory note and the `forge/README.md` edge bullet to say real IPs are handled.
