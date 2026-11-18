# Edge Traefik: real client IPs (design)

Approved 2026-11-19. First of four follow-ups to the edge Traefik LXC
(`docs/superpowers/plans/2026-11-18-edge-traefik-replaces-npmplus.md`). The
order is real IP, then OIDC, then CrowdSec, then Cloudflare settings in git
(only if something needs it).

## Intent

Every backend, and later the OIDC middleware and a CrowdSec bouncer, must see
the visitor's real IP, never a Cloudflare node or the VPS. Today edge receives
public traffic two ways, and neither carries the client IP through:

- **Cloudflare → UDM WAN :443 forward → `websecure` :443.** Thirteen
  Cloudflare-proxied CNAMEs point at `vaderrp.com` (DDNS, the home IP). The
  socket IP is a Cloudflare node.
- **VPS haproxy (SNI passthrough, WireGuard) → `wan` :8443.** This is Forgejo
  only. The socket IP is `172.16.8.2`.

## Approaches (Cloudflare path)

| Option | Trade-off | Picked? |
|---|---|---|
| Traefik built-in `forwardedHeaders.trustedIPs` + `ipStrategy` | No plugin, but the Cloudflare range list is maintained by hand. `X-Real-IP` stays the Cloudflare node, so each app would need reconfiguring. | No |
| **`traefik-warp`** (same as the cluster) | Sets `X-Real-IP` from `CF-Connecting-IP` only when the socket IP is in Cloudflare's ranges, and refreshes the ranges itself. Third-party plugin; the catalog download at startup is avoided by vendoring it. | **Yes**. Olli: the self-updating range list alone decides it. |
| `traefik-get-real-ip` + Cloudflare Transform Rule `X-From-Cdn` | Trusts a header rather than the socket, which is spoofable because the UDM forwards all of :443. Also needs Cloudflare rules managed as code. | No |

The VPS path has no CDN headers. PROXY protocol v2 (haproxy already uses it for
Stalwart) is the only sensible way.

## Design

**Cloudflare path:**
- `forge/config/edge/versions.env` gets `TRAEFIK_WARP_VERSION=v1.1.5` (the
  cluster's pin), annotated `datasource=github-releases depName=l4rm4nd/traefik-warp`.
- `apply-edge.sh` downloads `github.com/l4rm4nd/traefik-warp/archive/<ver>.tar.gz`
  into `/var/lib/traefik/plugins-local/src/github.com/l4rm4nd/traefik-warp` only
  when the recorded version differs, and restarts Traefik (plugins load at
  startup). This is the same unchecksummed archive the cluster's initContainer
  fetches. It is fetched at apply time, never at Traefik start.
- `traefik.yaml`: `experimental.localPlugins.traefikwarp.moduleName: github.com/l4rm4nd/traefik-warp`.
  `traefik.initd`: `directory=/var/lib/traefik` so Traefik finds `./plugins-local`.
- Dynamic config: a middleware `real-ip` (plugin `traefikwarp`, `provider: cloudflare`,
  `autoRefresh: true`, `refreshInterval: 24h`), attached as an entrypoint-level
  middleware on `websecure` so it applies to every route there.
- `lan-only` keeps using the socket IP (default `ipStrategy`), so a Cloudflare
  visitor can never pass as LAN whatever headers it sends.

**VPS path (Forgejo web):**
- `vps/config/haproxy.cfg`: `server edge 172.16.8.20:8443 send-proxy-v2`.
- `traefik.yaml`: `entryPoints.wan.proxyProtocol.trustedIPs: ["172.16.8.2/32"]`.
- `forge/config/app.ini.j2` `[security]`: `REVERSE_PROXY_TRUSTED_PROXIES = 192.168.0.5`.
  `REVERSE_PROXY_LIMIT` stays at 1.
- Cutover order: Traefik first (with `proxyProtocol` configured, Traefik also
  accepts connections that carry no PROXY header from a trusted IP, so nothing
  breaks), then haproxy, then Forgejo.

**Tests (added to `forge/edge-smoke.sh`, all failing before the change):**
- **Real Cloudflare path** (resolved via Quad9 :9953): the request reaches edge
  with `X-Real-Ip` equal to the home WAN IP. Checked in edge's access log, which
  needs the `X-Real-Ip` request header kept in the access-log fields.
- **VPS path:** a Forgejo request through the VPS is logged by edge with
  `ClientHost` equal to the home WAN IP, not `172.16.8.2`.
- **Spoofing:** a direct LAN request with a forged `CF-Connecting-IP: 1.2.3.4`
  is logged with `X-Real-Ip` equal to the LAN client, not 1.2.3.4.

## Non-goals

OIDC, CrowdSec/fail2ban and Cloudflare-as-code each get their own design.
git-over-SSH client IPs are also out: it is a TCP stream, so Forgejo keeps
seeing edge.

## Left to the builder

The exact access-log field config, how the smoke test reads the log (over SSH),
and the Forgejo apply step (`just forge apply-forgejo`).
