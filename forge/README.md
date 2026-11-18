# forge/ — ForgeJo + runners on meanie

Design: `docs/superpowers/specs/2026-08-17-forgejo-authoritative-forge-design.md`

| Host | VMID | IP | Role |
|---|---|---|---|
| forgejo | 130 | 192.168.7.30 | Forgejo (native, SQLite), HTTP :3000, SSH :22 |
| forgejo-runner1 | 131 | 192.168.7.31 | forgejo-runner + Docker CE |
| forgejo-runner2 | 132 | 192.168.7.32 | forgejo-runner + Docker CE |
| edge | 120 | 192.168.0.5 | Traefik + lego (TLS termination, LAN proxy hosts, :22 stream to Forgejo), WG peer to VPS, dashboard at `edge.vaderrp.com/dashboard/` |

- `just forge apply-forgejo|apply-runner 1|apply-runner 2|apply-edge` — idempotent config pushes
- `bash forge/edge-smoke.sh 192.168.0.5 --wan` (from WSL) — checks every edge route, the dashboard, the :22 stream, the certificates and that the public path only reaches Forgejo
- `just forge setup` — Forgejo API-level state (org creation, migration of the GitHub repos allowlisted in `setup-forgejo.sh`, push mirrors, Actions secrets)
- `apply-runner` also installs a weekly `docker-prune.timer` (`docker system prune -af --volumes`, Sun 04:00) on each runner; without it CI leftovers fill the LXC's ZFS refquota and jobs fail with "disk quota exceeded".
- Provisioning: community-scripts (`ct/forgejo.sh`, `ct/forgejo-runner.sh`) run on meanie; re-provisioning = script + apply. The edge LXC is a plain `pct create` from the Alpine template (unprivileged, `vmbr0`, 192.168.0.5/24 with MAC `BC:24:11:83:03:37`, `tank-zfs` 4G, 512M), then `apk add openssh tar curl logrotate libcap-utils ca-certificates`, sshd on `Port 2222`, root `authorized_keys`, and `just forge apply-edge`.
- Manual state not covered here (one-off CLI/API/UI steps, not re-run by `just forge setup`):
  - Authentik OIDC auth source: OAuth2/OIDC provider + application created in the Authentik UI (Task 3), then `forgejo admin auth add-oauth --provider openidConnect` run on the forge LXC (scopes `openid,email,profile`) to register it in Forgejo.
  - The `renovate` user: `forgejo admin user create` + `generate-access-token` on the forge LXC, then added to the `operinko-labs` org with write access (Owners/renovate team) — no API call, done by hand.
  - The Flux deploy key: `POST /repos/operinko-labs/homeops/keys` (read-only) against the Forgejo API, plus `bootstrap/forgejo-deploy-key.sops.yaml` added to the repo by hand.
  - GitHub Actions disablement on each mirrored GitHub repo (per-repo UI toggle, so mirror pushes don't double-run CI).
  - Cloudflare + Technitium DNS records (Tasks 5–6).
  - The edge LXC's SSH host keys are NPMplus's old ones, and root's `authorized_keys` holds the two `cert-sync` forced-command keys for `scripts/technitium-cert-sync/`; both were copied from LXC 107 by hand at the 2026-11-18 cutover (`docs/superpowers/plans/2026-11-18-edge-traefik-replaces-npmplus.md`).

## Upgrades

Not automated for Forgejo and the runners (Renovate doesn't see those LXC binaries). The edge LXC's Traefik and lego are pinned in `forge/config/edge/versions.env`, which Renovate does bump; run `just forge apply-edge` after merging. Last done 2026-10-21: Forgejo 16.0.2 → 17.0.0, runners 13.0.0 → 13.2.0.

- **Forgejo:** `pct snapshot 130 pre-forgejo-<ver>` on meanie (the rollback — the first start migrates the SQLite DB, so the old binary can't simply be put back), download `forgejo-<ver>-linux-amd64` + `.sha256` + `.asc` from the Codeberg release, check both (key `EB114F5E6C0DC2BCDD183550A4B61A2DC5923710`), then `systemctl stop forgejo`, install as `/opt/forgejo/forgejo-<ver>`, repoint the `/opt/forgejo/forgejo` symlink, start, and wait for `/api/healthz`. Migrations are logged as `Migration[...]` in the journal.
- **Runners:** same binary + `.sha256` + `.asc` pattern from `code.forgejo.org/forgejo/runner/releases/download/v<ver>/`, replacing `/usr/local/bin/forgejo-runner`. Restart only when `docker ps --filter name=FORGEJO-ACTIONS-TASK` is empty: the config has no `shutdown_timeout`, so a restart cancels running jobs. The in-cluster runner (`kubernetes/apps/actions-runner-system/forgejo-runner`) is an image tag Renovate bumps.
- The `/usr/bin/update` community-script helpers on the LXCs would also work, but they fetch and run a remote script unpinned; the manual path above is verified.

## New repos

`just forge setup` only migrates GitHub repos listed in the explicit manifest at the top of `setup-forgejo.sh` (it no longer auto-enumerates GitHub — that kept resurrecting repos deleted from the Forgejo org). To onboard an existing GitHub repo, add it to that manifest and re-run `just forge setup`; to remove one, delete it in Forgejo *and* drop its manifest line. It does not cover Forgejo-first repos. To add a new one:

1. Create the repo on Forgejo: org `operinko-labs`, private.
2. Create the GitHub twin: `gh repo create operinko-labs/<name> --private`.
3. Add the push mirror: `POST /api/v1/repos/operinko-labs/<name>/push_mirrors` with `remote_address` (the GitHub repo URL), `remote_username` (`operinko-labs`), `remote_password` (the GitHub mirror PAT from `forge/secrets.sops.yaml`), `interval: "8h0m0s"`, `sync_on_commit: true` — same shape `setup-forgejo.sh` uses for migrated repos.

## Execution notes / deviations

Operational facts learned while building this module that aren't obvious from the code:

- **The Forgejo migrate API is synchronous and slow.** `POST /repos/migrate` blocks
  server-side for the full clone/import (issues, PRs, releases, wiki) and does not
  return until it's done. The `homeops` repo (~1700 issues) took roughly 50 minutes;
  a client-side timeout below ~2h will chop the connection mid-migration and can
  leave a half-imported repo. `setup-forgejo.sh`'s migrate call uses a long
  `--max-time`; never shorten it below 7200s.
- **The edge LXC (120) is Alpine with OpenRC, no Docker.** Traefik binds `:80`,
  `:443` (LAN, plus the UDM's WAN `:443` forward for the Cloudflare-proxied
  names; every route gets the `192.168.0.0/16` allowlist unless `routes.yaml`
  marks it `public: true`), `:8443` (the VPS path, Forgejo only) and `:22` (TCP stream to Forgejo's sshd). Its own sshd listens on
  **:2222**, so SSH to the LXC itself uses `-p 2222`. `routes.yaml` is the only
  list of proxied hosts.
- **Real client IPs.** On `:443`, the vendored `traefik-warp` plugin
  (`/var/lib/traefik/plugins-local`, fetched by `apply-edge`, never at start) sets
  `X-Real-IP` from `CF-Connecting-IP` only for Cloudflare's ranges; `lan-only` still
  judges the socket IP. On `:8443` haproxy sends PROXY v2, and Forgejo trusts
  192.168.0.5 (`REVERSE_PROXY_TRUSTED_PROXIES`). git-over-SSH still shows edge.
- **lego's zone lookups use Quad9 on port 9953.** LAN `:53` is DNAT'd to
  Technitium, whose internal `dns.vaderrp.com` zone would make lego look for a
  Cloudflare zone that does not exist; propagation is a fixed 90s wait for the same
  reason (`forge/config/edge/edge-cert-renew.sh`).
- **Authentik login (`auth: oidc` routes: proxmox, truenas, unifi, pbs).** The
  vendored `traefik-oidc-auth` plugin reuses the cluster's `traefik` Authentik
  application. Each such route also gets a `<name>-lan` router
  (``ClientIP(`192.168.0.0/16`)``, socket IP) without the plugin, because the
  plugin runs Authentik discovery before any bypass and answers 500 when the
  cluster is down. Browsers from outside get a 302 to Authentik, anything else a
  401, forged LAN headers included. Its client ID, secret
  and cookie key are **copies** in `forge/secrets.sops.yaml`
  (`edge_oidc_*`) of the cluster Secret `network/traefik-oidc-secret` (Vaultwarden
  item `6a906531`): after rotating them there, re-copy and `just forge apply-edge`.
  Logins from outside need the cluster (Authentik); LAN access never does.
- **WireGuard only starts on 192.168.0.5.** `apply-edge.sh` skips `wg0` on any
  other address, because a second host with the same key steals the VPS tunnel.
- **The proxy-path SSH is git-only.** Forgejo rides the forge LXC's system sshd; a
  `Match Address 192.168.0.5` block restricts logins arriving via the edge proxy
  path to the `git` user. Root SSH to the forge LXC only works direct to its LAN IP
  (192.168.7.30) or via a VPS→LAN jump, never through the edge-forwarded path.
- **Runner registration tokens are single-use.** Generate one fresh per runner
  immediately before the apply that consumes it; never reuse or cache one.
- **Staged community-scripts provisioning lives on meanie, not in git.**
  `/root/forgejo/` on meanie holds the mirror-rewritten `install.func` (points at
  `git.community-scripts.org` instead of `raw.githubusercontent.com`, which is
  flaky/rate-limited from meanie), a patched `build.func`
  (`FUNCTIONS_FILE_PATH="$(cat /root/forgejo/install.func)"`), seeded ASCII-art
  header caches, and the `run-forgejo.sh` / `run-runner.sh <1|2>` /
  `repair-runner-install.sh` wrappers. Unattended runs of these community scripts
  also need `mode=default` (skips the whiptail menu — otherwise it needs a TTY),
  `TERM` set to a real value (otherwise `clear` inside `header_info()` aborts the
  run with "TERM environment variable not set"), and — for the runner script
  specifically — a non-empty `var_runner_labels` exported (the install script only
  guards the forgejo-instance/uuid/token vars for unattended runs, not this one; an
  empty value hits an interactive `read` with no tty and fails). None of this
  staging is reproducible from git alone — if `/root/forgejo/` on meanie is ever
  cleaned, these fixes need to be re-derived before re-provisioning a LXC.
- **Runner jobs get the host's Docker socket.** `container.docker_host` is
  `unix:///var/run/docker.sock` (docker-outside-of-docker), which the buildx-based
  CI workflows need. This means a workflow running on a runner is effectively root
  on that runner's LXC. Accepted for this single-tenant homelab; would not be safe
  for untrusted PRs.
- **Renovate can't resolve its own container image through the Harbor proxy.** The
  `ghcr.io/renovatebot/renovate` self-lookup (via the `registryAliases` remap to
  `harbor.vaderrp.com/ghcr`) returns `no-result` rather than a version list, so
  Renovate silently skips proposing updates for its own pin. Non-blocking (a WARN,
  not a failure) — everything else resolves normally; that one line needs an
  occasional manual bump.
