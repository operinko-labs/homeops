# forge/ — ForgeJo + runners on meanie

Design: `docs/superpowers/specs/2026-08-17-forgejo-authoritative-forge-design.md`

| Host | VMID | IP | Role |
|---|---|---|---|
| forgejo | 130 | 192.168.7.30 | Forgejo (native, SQLite), HTTP :3000, SSH :22 |
| forgejo-runner1 | 131 | 192.168.7.31 | forgejo-runner + Docker CE |
| forgejo-runner2 | 132 | 192.168.7.32 | forgejo-runner + Docker CE |
| npmplus | 107 | (existing) | TLS termination, :22 stream forward, WG peer to VPS |

- `just forge apply-forgejo|apply-runner 1|apply-runner 2|apply-npmplus` — idempotent config pushes
- `just forge setup` — Forgejo API-level state (org creation, migration of the GitHub repos allowlisted in `setup-forgejo.sh`, push mirrors, Actions secrets)
- `apply-runner` also installs a weekly `docker-prune.timer` (`docker system prune -af --volumes`, Sun 04:00) on each runner; without it CI leftovers fill the LXC's ZFS refquota and jobs fail with "disk quota exceeded".
- Provisioning: community-scripts (`ct/forgejo.sh`, `ct/forgejo-runner.sh`) run on meanie; re-provisioning = script + apply.
- Manual state not covered here (one-off CLI/API/UI steps, not re-run by `just forge setup`):
  - Authentik OIDC auth source: OAuth2/OIDC provider + application created in the Authentik UI (Task 3), then `forgejo admin auth add-oauth --provider openidConnect` run on the forge LXC (scopes `openid,email,profile`) to register it in Forgejo.
  - The `renovate` user: `forgejo admin user create` + `generate-access-token` on the forge LXC, then added to the `operinko-labs` org with write access (Owners/renovate team) — no API call, done by hand.
  - The Flux deploy key: `POST /repos/operinko-labs/homeops/keys` (read-only) against the Forgejo API, plus `bootstrap/forgejo-deploy-key.sops.yaml` added to the repo by hand.
  - GitHub Actions disablement on each mirrored GitHub repo (per-repo UI toggle, so mirror pushes don't double-run CI).
  - NPMplus proxy-host/stream UI entries (Task 5), Cloudflare + Technitium DNS records (Tasks 5–6).

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
- **npmplus (LXC 107, not 113 — see `docs/network-map.md`) is Alpine, not Debian.**
  It runs NPM+ in Docker with host networking; nginx binds `:80`/`:81`/`:443`
  directly, and the LXC's own OpenRC sshd listens on **:2222** (not :22), so both
  LAN and VPS SSH traffic to npmplus itself use `-p 2222`. Port 22 on npmplus's IP
  is reserved for the Forgejo git-SSH stream forward.
- **The proxy-path SSH is git-only.** Forgejo rides the forge LXC's system sshd; a
  `Match Address 192.168.0.5` block restricts logins arriving via the npmplus proxy
  path to the `git` user. Root SSH to the forge LXC only works direct to its LAN IP
  (192.168.7.30) or via a VPS→LAN jump, never through the npmplus-forwarded path.
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
