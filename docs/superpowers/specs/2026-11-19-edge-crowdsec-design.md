# Edge Traefik: CrowdSec (design, DRAFT, awaiting Olli's decisions)

Drafted 2026-11-19 overnight. Third follow-up to the edge Traefik LXC, after real
client IPs and OIDC. **Not approved yet. The four decisions at the end are Olli's.**

## Intent

Ban abusive clients at the edge proxy: scanners, credential stuffing and
aggressive crawlers. It should use the real client IPs that edge now has (warp
on the Cloudflare path, PROXY protocol on the VPS path). It must be lighter to
run than the cluster CrowdSec that was archived ("crowdsec is being a pain").
That one suffered from LAPI CPU throttling, storage migrations and
registration-token mix-ups.

## What the traffic looks like

Data is edge's access log, 2026-11-18 22:03 → 2026-11-19 02:16, excluding LAN
and Olli's own WAN IP.

| Path | Requests | Notes |
|---|---|---|
| Direct to the WAN IP :443 (UDM forward, **bypassing Cloudflare**) | 865 | Almost all scanners. 136.117.218.174 (Google Cloud) sent 501 probes in one minute (`.env`, `wp-*`, `.git/`…). Mostly 404 on the bare IP or apex `vaderrp.com`. |
| VPS → `wan` (Forgejo) | 7758 | Until 00:39 every client showed as 172.16.8.2 (before PROXY protocol). After that, Meta's crawler (57.141.20.0/24, about 90 IPs) at about 20–30 requests a minute in total, roughly 1 per minute per IP. |
| Via Cloudflare | 218 | Light. Cloudflare's own edge already filters this path. |

Conclusions:
- The biggest single win is not CrowdSec: it is **only accepting Cloudflare on
  WAN :443**. Every direct-to-IP scanner above would disappear.
- Meta's crawler is too slow per IP for CrowdSec's behaviour scenarios.
  `robots.txt` on Forgejo (it respects it) or a rate limit fits better.
- CrowdSec is for what's left: scanners and brute force that do arrive through
  Cloudflare or the VPS, plus the community blocklist.

## Approaches

| Option | Trade-off | Recommended |
|---|---|---|
| **A. CrowdSec engine + LAPI natively on the edge LXC, Traefik bouncer plugin** | One small daemon with SQLite, reading Traefik's JSON access log, no Kubernetes. The bouncer is a third vendored Yaegi plugin, in stream mode (bans cached locally, synced every 60s). Sees both public paths at HTTP level with real IPs. | **Yes** |
| B. CrowdSec engine on edge + the Cloudflare bouncer (pushes bans to Cloudflare firewall lists) | Blocks at Cloudflare's edge before traffic reaches home, but covers only the Cloudflare path, not the VPS/Forgejo or direct-to-IP traffic. Needs a Cloudflare API token with firewall rights. | Possible later add-on |
| C. No CrowdSec: UDM source restriction + Forgejo `robots.txt` + Traefik `rateLimit` + Cloudflare's free bot protection | Nothing new to run, and covers most of what the log shows. But no behavioural bans and no community blocklist. | Do its parts anyway (see decisions 3 and 4) |

## Design (option A)

- **Engine:** `crowdsecurity/crowdsec` v1.8.2 release tarball
  (`crowdsec-release.tgz`), pinned in `forge/config/edge/versions.env` with a
  Renovate annotation. Alpine packages only the firewall bouncer.
  - The release ships no checksums file. Verify against the asset's
    `digest` from the GitHub releases API, which for v1.8.2 is `sha256:6e0b2add…`
    and matches a local download.
  - The `crowdsec` and `cscli` binaries are statically linked, checked, so
    they run on Alpine's musl without gcompat.
  - It is installed by
  `apply-edge.sh` with an OpenRC service, config under `/etc/crowdsec`, and
  SQLite under `/var/lib/crowdsec`. LAPI listens on 127.0.0.1:8080 only.
- **Acquisition:** `/var/log/traefik/access.log` (JSON), with the
  `crowdsecurity/traefik` collection, plus the `crowdsecurity/base-http-scenarios`
  and `http-cve` collections.
- **Real IPs:** a small custom enrich parser (stage s02) sets
  `evt.Meta.source_ip` from the logged `request_X-Real-Ip` when it is present.
  Without it, the stock Traefik parser would use `ClientHost`, which is a
  Cloudflare node, and CrowdSec would ban Cloudflare. A test feeds a Cloudflare
  log line and asserts the visitor IP.
- **Whitelists:** the LAN (192.168.0.0/16), the VPS and WireGuard
  (172.16.8.0/24), Olli's WAN IP, Cloudflare's ranges (defence in depth) and
  `crowdsecurity/whitelist-good-actors`.
- **Bouncer:** `maxlerebourg/crowdsec-bouncer-traefik-plugin` v1.8.2, vendored
  via `install_plugin`, as an entrypoint middleware on `websecure` and `wan`
  after `real-ip`:
  - `crowdsecMode: stream`
  - `forwardedHeadersCustomName: X-Real-Ip`
  - `clientTrustedIPs: [192.168.0.0/16]`
  - `remediationStatusCode: 403`
  - `updateMaxFailure: -1`: fail open if LAPI is down, so a CrowdSec problem
    never takes down edge.
- **warp on `wan` too:** `real-ip` is added to `wan`'s entrypoint middlewares,
  so `X-Real-Ip` is warp-controlled on both entrypoints. On `wan` the socket is
  already the real client (PROXY protocol), so warp just copies it.
- **Resources:** raise LXC 120 from 512 MiB to 1 GiB.
- **Observability:** a Gatus check on LAPI health via a tiny `/health` route
  that is LAN-only. `cscli` decision and alert counts go in the morning-style
  report, and `cscli metrics` in the README.

## Tests (to be written first)

1. **Parser unit test (`cscli explain`):**
   - A Cloudflare-path log line yields `source_ip` = the `X-Real-Ip` value.
   - A VPS-path line yields `ClientHost`.
2. **Ban path:** `cscli decisions add -i <test IP> -d 5m`, then a probe from
   the VPS with that `X-Real-Ip` must get 403 within about 60s (stream sync).
   Then delete the decision.
3. **Fail-open:** stop CrowdSec, reload Traefik, and the full smoke test must
   still be green.
4. **No self-ban:** a burst of 404s from the LAN and from Olli's WAN IP creates
   no decision.
5. **The existing smoke suite stays green.**

## Decisions for Olli (each changes what gets built)

1. **Community blocklist (CAPI):** register with CrowdSec's Central API?
   - **Pro:** it pulls about 15–30k known-bad IPs, refreshed every 2 hours.
   - **Con:** it shares attacker IPs and scenario names with CrowdSec.
   - Console enrollment is a separate, further opt-in.
   - Recommendation: **yes to CAPI, no to console**.
2. **Remediation:**
   - **Plain 403 (recommended).**
   - **Captcha via Cloudflare Turnstile:** needs a Turnstile site and secret,
     and helps humans misflagged on shared IPs.
3. **Accept only Cloudflare on WAN :443 (UDM port forward source):** the
   biggest win in the data, independent of CrowdSec.
   - Cloudflare's ranges change rarely, but they do change. In keeping with
     the preference for self-maintaining config, a small daily job (a
     CronJob in the cluster, via the UniFi API with the existing key) would
     sync a UniFi IP group from Cloudflare's published lists.
   - Recommendation: **yes**, as its own small plan before CrowdSec.
4. **Forgejo `robots.txt`** disallowing AI crawlers (`meta-externalagent`,
   `GPTBot`, `ClaudeBot`, `CCBot`…), shipped by `apply-forgejo`. Recommendation:
   **yes**, as a tiny change. CrowdSec won't catch them, since each IP is too
   slow.

## Non-goals (v1)

- Vaultwarden, Forgejo and Authentik application-log brute-force scenarios
  (they need log shipping from their hosts; v2).
- The Cloudflare bouncer (option B).
- AppSec/WAF mode.
- Bringing CrowdSec back to the cluster.
