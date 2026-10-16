# Matrix (Synapse + MAS + Element) on ESS Community — design

Date: 2026-10-16
Status: server side implemented 2026-10-16 (plan docs/superpowers/plans/2026-10-16-matrix-synapse.md); user checks pending (logins, media in S3, federated room, reset mail, just vps apply, call test)
Supersedes: PR #1439 (`feature/matrix-synapse`, opened 2026-06-05, never functional)

## Purpose

Self-host a Matrix homeserver for family and friends, with `@user:erinko.fi`
IDs, federation on, Element X (mobile) and Element Web as clients, voice/video
calls, and media stored in S3 rather than on a node-local volume.

## Why PR #1439 is replaced, not repaired

The PR predates several changes on main and almost none of it survives:

- The wildcard `erinko.fi` cert and the `*.erinko.fi` listener on
  `gateway-public` are already on main; its `gateway-internal` edit
  (webmail → `*.erinko.fi`) would clash with the `mail.erinko.fi` relay listener.
- The image build lived in `.github/workflows/`; GitHub Actions is disabled, so
  the image was never built.
- Media pointed at MinIO, which has been retired (Versity at `s3.vaderrp.com`).
- The database was created by an init container with the superuser; main now
  uses CNPG managed roles + `Database` CRDs.
- `federation_domain_whitelist: []` disabled federation entirely.
- No Matrix Authentication Service (MAS), which Element X requires.
- Bitwarden UUID placeholders were never filled; the data PVC (holding the
  signing key) had no backup; versions and Gatus annotations are stale.

Kept from the PR: the idea of a custom Synapse image with
`synapse-s3-storage-provider`, the S3 provider config, and the media drain CronJob.

## Approach

Element's first-party chart **ESS Community** (`matrix-stack`,
`oci://ghcr.io/element-hq/ess-helm/matrix-stack`) deploys Synapse, MAS,
Element Web, MatrixRTC (LiveKit SFU + JWT authoriser) and well-known
delegation, and keeps the MAS ↔ Synapse and MatrixRTC wiring correct across
upgrades. Community lacks S3 media (an ESS Pro feature), but the open-source
`synapse-s3-storage-provider` module plugs into it through the chart's own
hooks:

- `synapse.image` — overridden with our Harbor image.
- `synapse.additional.<name>.configSecret/configSecretKey` — extra
  `homeserver.yaml` fragments from a Secret (S3 provider, upload limit).
- `synapse.postgres` / `matrixAuthenticationService.postgres` — external DB.

Rejected: reworking the PR on bjw-s app-template (≈3× the YAML, and we would
own the MAS/LiveKit wiring), and keeping the PR without MAS (no Element X).

Traefik runs with `kubernetesIngress.enabled: false`, so the chart's Ingress
objects are deleted with a Flux `postRenderers` patch and replaced by our own
HTTPRoutes. Service names and ports for those routes are taken from
`helm template` output during implementation, not assumed.

## Components and hostnames

All in namespace `matrix` unless noted. `server_name: erinko.fi` — permanent
once the first account exists.

| Piece | Host / location |
|---|---|
| Synapse (custom image + S3 provider), via ESS HAProxy | `matrix.erinko.fi` |
| MAS — local accounts + Authentik upstream | `account.erinko.fi` |
| Element Web | `chat.erinko.fi` |
| MatrixRTC: LiveKit signalling (websocket) + JWT authoriser | `mrtc.erinko.fi` |
| MatrixRTC media: TCP 30001 + UDP 30002 | VPS `212.147.241.182` → WG → talos7 |
| Well-known delegation (`/.well-known/matrix/*`); other apex paths redirect to `chat.` | `erinko.fi` |
| Postgres: roles `synapse`, `mas` on `postgres18` | `database` ns |
| Media: bucket `synapse-media` | Versity `s3.vaderrp.com` |
| Synapse media cache PVC | `local-path` + `volsync-kopia` |
| Image build | `.forgejo/workflows/build-synapse.yaml`, built from `apps/synapse/VERSION`; the deployed tag is `SYNAPSE_TAG` (ks.yaml postBuild substitution) |

Disabled chart components: Hookshot, Element Admin, the bundled Postgres.

## Database

- Two managed roles on `postgres18` (`cluster18.yaml`), `synapse` and `mas`,
  with `passwordSecret`s `postgres18-synapse-user` / `postgres18-mas-user`
  rendered by ExternalSecrets in `database` (basic-auth type,
  `cnpg.io/reload: "true"`) — same as stalwart.
- `Database` CRDs: `synapse` with `encoding: UTF8`, `localeCollate: C`,
  `localeCType: C`, `template: template0` (Synapse refuses other collations);
  `mas` with defaults. Field support is checked against the installed CNPG
  operator (chart 0.27.0) during implementation.
- Backups: existing barman `objectstore18` + `scheduledbackup18`.
- Sizing: `postgres18` is a single 10Gi instance shared with stalwart and
  autoposter. Federated Synapse DBs grow with room state; check current usage
  during implementation and bump `storage.size` if headroom is thin
  (`resizeInUseVolumes` is on).

## Secrets

Everything that matters comes from one Vaultwarden item `matrix` via
`bitwarden-fields`. The chart's `initSecrets` job stays **on**, but with every
secret below supplied it only generates the MatrixRTC appservice registration
and `SYNAPSE_EXTRA` into `matrix-generated` — throwaway values the chart can
regenerate. Disabling it fails rendering ("Secret configuration at
matrixRTC.appserviceRegistration is not present"). The signing key, MAS
encryption secret and private keys are never chart-generated: losing those
would break federation trust or every session.

Fields:

| Field | Used by |
|---|---|
| `signing_key`, `macaroon`, `registration_shared_secret` | Synapse |
| `encryption_secret`, `private_key_rsa`, `private_key_ecdsa_p256`, `synapse_shared_secret` | MAS |
| `livekit_secret` | MatrixRTC |
| `synapse_db_password`, `mas_db_password` | Postgres roles + chart |
| `s3_access_key`, `s3_secret_key` | S3 provider + drain CronJob |
| `authentik_client_id`, `authentik_client_secret` | MAS upstream OAuth2 |
| `smtp_username`, `smtp_password` | MAS email via Stalwart |

One ExternalSecret in `matrix` renders `matrix-secrets` (plain keys plus the
templated `homeserver.yaml` / `mas-config.yaml` fragments); chart values point
into it with `secret`/`secretKey` and `configSecret`/`configSecretKey`. The DB
passwords are also rendered in `database` for the CNPG roles.

Values are generated locally into the scratchpad (signing key with Synapse's
`generate_signing_key` from the image, the rest with `openssl`); the user
pastes them into Vaultwarden and POSTs `/sync` on `bitwarden-eso-provider`.

## S3 media

- Bucket `synapse-media` with its own access key on Versity — created by hand
  (no git-managed bucket provisioning).
- `synapse.additional` fragment:
  `media_storage_providers: [{module: s3_storage_provider.S3StorageProviderBackend, store_local: true, store_remote: true, store_synchronous: true, config: {endpoint_url: https://s3.vaderrp.com, bucket: synapse-media, ...}}]`.
- Drain CronJob (from the PR, adapted to the ESS media PVC): daily
  `s3_media_upload update <media dir> 7d` then `upload --delete`, so the local
  cache keeps ~7 days (`store_synchronous` puts every file in S3 before the
  client gets a reply, so the local copy is only a cache and must not fill the
  10Gi PVC). The job is bounded by `activeDeadlineSeconds: 7200`. The PVC is
  RWO on `local-path`; the job co-schedules on Synapse's node.
- Offsite: confirm `synapse-media` is included in the GDrive offsite sync after
  the MinIO → Versity move.

## Authentication (MAS)

- Local accounts: `passwords.enabled: true`, created with
  `mas-cli manage register-user`; password reset mail via Stalwart SMTP.
- Authentik: `upstream_oauth2` provider; the user creates the OAuth2
  provider/application in the Authentik UI (no blueprints in git). Redirect
  URI `https://account.erinko.fi/upstream/callback/<provider id>`, username
  from `preferred_username`.
- Open registration off.
- Chart 26.10.1 does not emit `org.matrix.msc2965.authentication` in the
  client well-known; clients discover MAS via `/_matrix/client/v1/auth_metadata`.

## Networking

### HTTP

All hosts above attach to `gateway-public` (cloudflared tunnel), HTTPRoutes
labelled `route.scope: external` so external-dns creates proxied records.

- `*.erinko.fi` hosts use the existing `https-erinko` listener.
- The apex needs a new `https-erinko-apex` listener (hostname `erinko.fi`,
  cert `erinko-fi-production-tls`, which already covers the apex), shaped like
  `https-ruskonkesateatteri-apex`.
- Apex DNS already points at the tunnel (done by the user 2026-10-16; resolves
  to Cloudflare).
- Federation is delegated to `matrix.erinko.fi:443`; port 8448 is not used.
- Synapse `max_upload_size: 100M` (Cloudflare free-plan body limit).
- Bot Fight Mode is already off (since the Gramps 1010 issue). If the
  Federation Tester still reports 1010, a free-plan Configuration Rule can
  disable Browser Integrity Check for `matrix.erinko.fi`.

### Calls (MatrixRTC via the VPS)

Same pattern as Stalwart / `service-traefik-wg.yaml`:

- SFU pinned to talos7 (`matrixRTC.sfu.nodeSelector`) — only talos7 has `wg0`.
- Chart `exposedServices.rtcTcp` / `rtcMuxedUdp`: `portType: ClusterIP`,
  `externalIPs: ["172.16.8.12"]` (the chart supports both). The chart only
  emits `externalTrafficPolicy` for NodePort/LoadBalancer, so a HelmRelease
  `postRenderers` JSON patch adds `externalTrafficPolicy: Local` to
  `matrix-matrix-rtc-sfu-tcp` and `matrix-matrix-rtc-sfu-muxed-udp`. No
  separate Service file.
- `useStunToDiscoverPublicIP: false`, `manualIP: 212.147.241.182`.
- VPS (`vps/` module, applied by the user with `just vps …`):
  - haproxy `frontend ft_rtc_tcp` `:30001` → `172.16.8.12:30001`.
  - nftables DNAT UDP `:30002` → `172.16.8.12:30002` **with masquerade**:
    without SNAT the SFU's replies would leave via the home WAN and be lost.
    LiveKit then sees every client as `172.16.8.2`, distinguished by port.
  - UpCloud firewall (if enabled): allow 30001/tcp, 30002/udp.
- LAN clients hairpin via the VPS; acceptable.

## Backups

| Data | Covered by |
|---|---|
| Synapse + MAS DBs | `postgres18` barman |
| Signing key, all secrets | Vaultwarden `matrix` item |
| Media | Versity bucket (+ offsite sync, to confirm) |
| Synapse media cache PVC | `volsync-kopia` (`Direct`, PUID/PGID 10091) |

## Monitoring

Gatus endpoints in `gatus-config.yaml` (not annotations), ntfy alerts:

- `https://matrix.erinko.fi/_matrix/client/versions` → 200
- `https://erinko.fi/.well-known/matrix/server` → body contains `matrix.erinko.fi`
- `https://account.erinko.fi/.well-known/openid-configuration` → 200
- `https://chat.erinko.fi` → 200
- hourly `https://federationtester.matrix.org/api/report?server_name=erinko.fi`
  → `[BODY].FederationOK == true`

Chart ServiceMonitors enabled where offered (Synapse, MAS, HAProxy, LiveKit).

## Upgrades

- Chart: `OCIRepository` on `matrix-stack`, Renovate-managed.
- Synapse image: `apps/synapse/VERSION` is tracked by a Renovate regex manager
  against `oci.element.io/synapse` (the registry the chart itself uses); CI
  builds the Harbor tag on merge. The deployed tag is `SYNAPSE_TAG` in the
  app's Flux Kustomization (postBuild substitution, used by the HelmRelease and
  the drain CronJob), tracked against `harbor.vaderrp.com/operinko-labs/synapse`,
  so it only moves once the image exists. `synapse-s3-storage-provider` is
  version-pinned in the Dockerfile.
- Review step for every chart bump: the chart's own Synapse pin no longer
  applies, so check `apps/synapse/VERSION` (which the deployed `SYNAPSE_TAG`
  is built from) is not behind the chart's Synapse pin.

## Rollout

homeops changes go straight to main, one commit per phase.

0. Close PR #1439 with a pointer to this spec; delete `feature/matrix-synapse`.
1. User prerequisites: Vaultwarden `matrix` item from generated values +
   `/sync`; Versity bucket + key; Authentik OAuth2 provider; UpCloud firewall.
2. Image: `apps/synapse/` + `.forgejo/workflows/build-synapse.yaml`.
   Verify: tag present in Harbor.
3. Database: roles, `Database` CRDs, ExternalSecrets. Verify: `\l` shows
   `synapse` with collate/ctype `C`.
4. Core stack: `matrix` ns, ESS HelmRelease (MatrixRTC off), HTTPRoutes, apex
   listener, drain CronJob, volsync. Verify: health + well-known answer;
   `mas-cli` account and Authentik SSO both log in on Element Web and
   Element X; an uploaded image appears in the bucket; Federation Tester
   passes; join a small federated room (avoid huge public rooms — DB bloat).
5. Calls: MatrixRTC on, chart `exposedServices` (ClusterIP + `externalIPs: ["172.16.8.12"]`) plus the `postRenderers` `externalTrafficPolicy: Local` patch, VPS haproxy + nftables
   (user applies). Verify: a call between a LAN client and a phone on mobile
   data.
6. Gatus endpoints; confirm offsite sync of `synapse-media`.

Rollback: suspend the HelmRelease, or delete the `matrix` namespace and the
two databases. `server_name` cannot be changed after the first account.

## Deferred

- **TURN/TLS on 443.** Only helps clients on networks that block UDP 30002 and
  TCP 30001 (corporate/guest Wi-Fi, hotels): turns "call fails to connect"
  into "connects", with TCP-level quality. Cost when needed: VPS haproxy SNI
  passthrough rule `turn.erinko.fi` → `172.16.8.12:30003`, a DNS-only
  `turn.erinko.fi` → `212.147.241.182` record, a `turn.erinko.fi` Certificate
  in `matrix`, `exposedServices.turnTLS` on (ClusterIP + externalIPs, same as rtcTcp).
- Hookshot / bridges, Element Admin, Synapse workers.
