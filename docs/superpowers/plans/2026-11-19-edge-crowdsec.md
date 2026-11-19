# Edge CrowdSec Implementation Plan (DRAFT, waiting on the spec's decisions)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Behavioural bans on edge: CrowdSec reads Traefik's access log with real client IPs, and a Traefik bouncer enforces 403s on both public entrypoints.

**Architecture:**
- The CrowdSec engine and LAPI run natively on the edge LXC: a static release binary, SQLite, and LAPI on 127.0.0.1:8080.
- A custom parser takes the source IP from the logged `X-Real-Ip`.
- `maxlerebourg/crowdsec-bouncer-traefik-plugin` is vendored via `install_plugin` and attached after `real-ip`, in stream mode, failing open.

**Tech Stack:** CrowdSec v1.8.2, crowdsec-bouncer-traefik-plugin v1.8.2, Traefik 3.7, OpenRC, bash smoke test.

**Spec:** `docs/superpowers/specs/2026-11-19-edge-crowdsec-design.md`. Read its **Decisions** section first. This plan assumes the recommended answers:
- CAPI on, console off;
- 403 remediation;
- the UDM source restriction and Forgejo `robots.txt` handled as separate small plans.

If Olli answers differently, adjust Task 1 Step 3 (CAPI) and Task 2 Step 3 (remediation) before executing.

## Global Constraints

- Versions go in `forge/config/edge/versions.env` with Renovate annotations:
  - `CROWDSEC_VERSION=v1.8.2`, verified against the GitHub release asset `digest` (the API's `assets[].digest` for `crowdsec-release.tgz`);
  - `TRAEFIK_CROWDSEC_BOUNCER_VERSION=v1.8.2`, via `install_plugin`.
- LAPI binds 127.0.0.1:8080 only. Its bouncer API key goes in `forge/secrets.sops.yaml` as `edge_crowdsec_bouncer_key` and is registered with `cscli bouncers add traefik -k <key>`, idempotently.
- Whitelists: `192.168.0.0/16`, `172.16.8.0/24`, `80.223.184.52`, Cloudflare's published ranges, and `crowdsecurity/whitelist-good-actors`.
- Bouncer config:
  - `crowdsecMode: stream`, `updateIntervalSeconds: 60`, `updateMaxFailure: -1`;
  - `forwardedHeadersCustomName: X-Real-Ip`, `clientTrustedIPs: ["192.168.0.0/16"]`;
  - `remediationStatusCode: 403`.
- Entrypoint middlewares: `websecure: [real-ip@file, crowdsec@file]`, `wan: [real-ip@file, crowdsec@file]`.
- LXC 120 memory goes to 1024 MiB (`pct set 120 --memory 1024` on meanie, recorded in the README).
- Commit and push to homeops `main`, with no AI attribution. `bash forge/edge-smoke.sh 192.168.0.5 --wan` must be green at the end of each task.

## Review Focus

1. **A Cloudflare node IP must never be banned:** that would block every visitor. Covered by the parser test, plus the Cloudflare whitelist.
2. **LAN, Olli's WAN IP and the VPS must never be banned:** Task 2's self-ban test.
3. **A CrowdSec or LAPI outage must not take edge down:** Task 2's fail-open test.
4. **The bouncer must read the same `X-Real-Ip` that warp sets on both entrypoints:** Task 2's ban test via both the VPS and Cloudflare.
5. **A third Yaegi plugin must load, and a compile failure must not linger unnoticed:** the apply checks traefik.log for `Plugins loaded` with all three names.

---

### Task 1: CrowdSec engine on edge

**Files:**
- Modify: `forge/apply-edge.sh`, `forge/config/edge/versions.env`, `forge/mod.just`
- Create:
  - `forge/config/edge/crowdsec/acquis.yaml`
  - `forge/config/edge/crowdsec/parsers/s02-enrich/homeops-real-ip.yaml`
  - `forge/config/edge/crowdsec/parsers/s02-enrich/homeops-whitelist.yaml`
  - `forge/config/edge/crowdsec/config.yaml.local`
  - `forge/config/edge/crowdsec.initd`
- Test: `forge/config/edge/crowdsec/tests/` (two Traefik JSON log lines: Cloudflare path and VPS path)

- [ ] **Step 1: Write the failing test**, `forge/edge-crowdsec-test.sh`, run on edge:
  - `cscli explain --file <cf-line> --type traefik` shows `source_ip` = the line's `request_X-Real-Ip`.
  - The VPS line shows its `ClientHost`.
  - A LAN line ends as whitelisted.
- [ ] **Step 2: Run it** → FAIL (CrowdSec isn't installed).
- [ ] **Step 3: Implement.**
  - `apply-edge.sh`:
    - Fetch and verify `crowdsec-release.tgz` against the GitHub API digest.
    - Install `crowdsec` and `cscli` to `/usr/local/bin` and `/etc/crowdsec` from the tarball's config defaults, only on first install.
    - `cscli collections install crowdsecurity/traefik crowdsecurity/base-http-scenarios crowdsecurity/http-cve crowdsecurity/whitelist-good-actors`.
    - Install the repo's acquis and parsers.
    - CAPI per the decision: `cscli capi register`, once.
    - OpenRC service.
  - Custom parser `homeops-real-ip`: when `evt.Unmarshaled.traefik["request_X-Real-Ip"]` is non-empty, set `evt.Meta.source_ip` from it.
- [ ] **Step 4: Apply and test.** `just forge apply-edge`, run the test → PASS. `cscli metrics` shows the access log being read.
- [ ] **Step 5: Commit** with `feat(forge): CrowdSec engine on edge reading Traefik's access log`.

### Task 2: Traefik bouncer

**Files:**
- Modify: `forge/apply-edge.sh` (`install_plugin`), `forge/config/edge/traefik.yaml`, `forge/config/edge/dynamic.yaml.j2`, `forge/edge-smoke.sh`, `forge/secrets.sops.yaml`, `forge/README.md`

- [ ] **Step 1: Write the failing smoke checks** (in `--wan` mode). The test client is **the VPS's own public IP (212.147.241.182)**. It's not whitelisted, and the VPS can reach edge both ways with that IP as the real client:
  - through Cloudflare: `curl --resolve <host>:443:<cf_ip>` from the VPS gives `X-Real-Ip` = the VPS IP;
  - through its own haproxy: `curl --resolve forgejo.vaderrp.com:443:212.147.241.182` from the VPS gives the PROXY-protocol client = the VPS IP.

  The checks:
  - `crowdsec-ban-*`: `cscli decisions add -i 212.147.241.182 -d 3m -R smoke-test` on edge. Poll for up to 75s (stream sync is 60s): a VPS probe of `photos.vaderrp.com` through Cloudflare and of `forgejo.vaderrp.com` through haproxy must both get **403**. Then `cscli decisions delete -i 212.147.241.182`, and both answer normally again within 75s.
  - `crowdsec-fail-open`: `rc-service crowdsec stop` on edge, wait 75s, the full route loop still passes, then start it again.
  - `crowdsec-no-self-ban`: 30 quick 404s from the LAN (`/smoke-404-<n>`) and 30 via Cloudflare from Olli's WAN, then `cscli decisions list -i 192.168.0.84 -i 80.223.184.52` is empty.
- [ ] **Step 2: Run** → the ban checks FAIL (no bouncer).
- [ ] **Step 3: Implement.**
  - Vendor the plugin.
  - Add the `crowdsec` middleware with the Global Constraints values, and the key from sops.
  - Change the entrypoint middleware lists.
  - `pct set 120 --memory 1024`.
  - README section: `cscli metrics`, `cscli decisions list`, how to unban, CAPI note.
- [ ] **Step 4: Apply, and run the full smoke `--wan`** → 0 failures. traefik.log lists three plugins loaded.
- [ ] **Step 5: Commit** with `feat(forge): CrowdSec bouncer on edge's public entrypoints`.

### Task 3: Monitoring

- [ ] A Gatus endpoint, "edge crowdsec LAPI", on a LAN-only router `crowdsec-health` (`Host(edge.vaderrp.com) && PathPrefix(/crowdsec-health)` → `http://127.0.0.1:8080/health`, with `lan-only`). Condition `[STATUS] == 200`, ntfy alert. Test RED first via the Gatus API (endpoint absent), then GREEN.
- [ ] Commit with `feat(gatus): watch edge CrowdSec`.
