# Edge Traefik: OIDC login for admin UIs (design)

Approved 2026-11-19. Second follow-up to the edge Traefik LXC, after real
client IPs (`2026-11-19-edge-real-client-ip-design.md`), which this depends on.

## Intent

Olli wants to reach four LAN admin UIs from outside, behind the same Authentik
login the cluster uses: **Proxmox, TrueNAS, UniFi and PBS**. They are used in a
browser only, and by Olli alone. Authentik has registration disabled, and anyone
in it is trusted, so no group or username restriction is needed in Traefik. The
`traefik` provider's own binding allows the `authentik Read-only` group, which
every account gets automatically, so in effect any Authentik user.

## Approaches

| Option | Trade-off | Picked? |
|---|---|---|
| Same plugin, new Authentik application for edge | Independent revocation, but more Authentik objects | No |
| **Same plugin, reuse the cluster's `traefik` application** | Its redirect URI regex `https://.*\.vaderrp\.com/oidc/callback` already covers these hosts, so Authentik needs no changes. Anyone in Authentik is trusted. | **Yes** |
| Cloudflare Access | Stops traffic at Cloudflare, but the UDM forward still allows direct-to-IP requests, it's a different login, and it's Cloudflare config not in git | No |

## Design

- **Plugin:** `sevensolutions/traefik-oidc-auth` v0.22.0 (the cluster's pin),
  vendored by `apply-edge.sh` at apply time like warp. It goes in `versions.env`
  as `TRAEFIK_OIDC_AUTH_VERSION` with a Renovate annotation, and in
  `traefik.yaml` under `experimental.localPlugins`.
- **Credentials:** the cluster's `traefik` client ID, client secret and cookie
  encryption secret (Vaultwarden item `6a906531`, also in the cluster Secret
  `network/traefik-oidc-secret`), copied into `forge/secrets.sops.yaml`. Edge
  can't use External Secrets, so a rotation needs a re-copy and an apply. The
  README says so.
- **Middleware `oidc-auth`:**
  - Provider `https://auth.vaderrp.com/application/o/traefik/`, callback
    `/oidc/callback`, scopes `openid profile email`.
  - `BypassAuthenticationRule: HeaderRegexp(\`X-Real-Ip\`, \`^192\.168\.\`)`
    only. There are no API-path exemptions: the cluster's `/api` exemption would
    expose TrueNAS's and UniFi's APIs.
  - `X-Real-Ip` is trustworthy here because warp, the entrypoint middleware,
    runs first and fails closed.
- **Routes:**
  - `routes.yaml` gets `auth: oidc`. Such a router gets `[oidc-auth]` instead
    of `lan-only`, and is reachable from outside only through the login.
  - Proxmox (`https://192.168.3.90:8006`), TrueNAS (`https://192.168.0.221`) and
    UniFi (`https://192.168.0.1`) return as routes (self-signed, `insecure`).
    PBS switches from `lan-only` to `auth: oidc`.
  - Their LAN DNS keeps pointing straight at each box. Edge serves them for
    traffic from outside, and for anyone who hits edge directly.
- **Cluster dependency:** logins from outside need Authentik, which runs in the
  cluster. LAN access never does, because LAN requests skip the login.

## Tests

All are written first and fail before the change.

- From the VPS (a non-LAN client), each of the four answers `302` with a
  `Location` on `https://auth.vaderrp.com/`.
- Through real Cloudflare, the same.
- From the LAN, each answers with its backend's own status.
- `cf-allowlist-*` moves from pbs to a host that stays LAN-only.
- The interactive browser login is Olli's to try.

## Non-goals

CrowdSec, Cloudflare-as-code, OIDC for the public apps (Vaultwarden, Immich and
Plex have their own logins and mobile clients), and other LAN-only routes.
