# Trilium Notes Deployment Design

**Date:** 2026-07-22
**Status:** Approved

## Context

Goal: a self-hosted PKM/note-taking app with a real web app, accessible from
outside the network, with an API (MCP access preferred). Logseq was evaluated
first: its new DB-version web app + self-hosted sync server is viable, but sync
auth requires logging in through Logseq's official AWS Cognito pool — a forced
third-party account — which disqualified it. SilverBullet, Joplin, Memos, and
Outline were considered; Joplin has no self-hostable web client, and the
API/MCP requirement favored Trilium (TriliumNext) with its first-class ETAPI
REST API and several maintained community MCP servers.

Requirements:

- Web app, hosted in-cluster (`tools` namespace), reachable externally
- No forced third-party account; external access gated by Authentik
- API required, MCP preferred
- Single user (owner only)
- Starting fresh (no data migration)

Known constraint: Trilium is SQLite-only; upstream has rejected PostgreSQL
support (TriliumNext discussion #4438). Accepted with the mitigations below.

## Design

New Flux app at `kubernetes/apps/tools/trilium/`, following the existing
bambuddy/radarr patterns:

### `ks.yaml`

- Flux Kustomization `trilium`, targetNamespace `tools`
- Component: `../../../../components/volsync-kopia`; `dependsOn: volsync`
- postBuild substitutions: `APP: trilium`, `VOLSYNC_CAPACITY: 10Gi`,
  `VOLSYNC_PUID: "1000"`, `VOLSYNC_PGID: "1000"` (default `local-path`
  storage class — node-local SSD)

### `app/ocirepository.yaml`

- **Official 1st-party chart** (policy: app-template is a fallback only):
  `oci://ghcr.io/triliumnext/helm-charts/trilium`, chart version `2.0.0`
  (appVersion v0.104.0). **Verify latest chart/app version against the live
  registry at implementation time.** The chart wraps bjw-s common 5.0.1, so
  all common-library values apply. Charts are cosign-signed (keyless);
  optionally add Flux `spec.verify` cosign verification.

### `app/helmrelease.yaml`

The chart's defaults already provide: image `triliumnext/trilium:v0.104.0`,
fixperms init container, startup/readiness/liveness probes on
`/api/health-check`, config.ini ConfigMap with `trustedReverseProxy: true`,
port 8080, fsGroup 1000, and a retained PVC. Our values only override:

- `controllers.main.containers.trilium.env`: `TZ` + native OIDC against
  Authentik (no proxy middleware):
  - `TRILIUM_OAUTH_BASE_URL=https://trilium.vaderrp.com`
  - `TRILIUM_OAUTH_ISSUER_BASE_URL=https://auth.vaderrp.com/application/o/trilium/.well-known/openid-configuration`
    (MUST be set explicitly — unset silently defaults to Google, TriliumNext#6444)
  - `TRILIUM_OAUTH_ISSUER_NAME=Authentik`
  - client ID/secret via `envFrom`/`valueFrom` referencing the secret from a
    new `app/external-secret.yaml` (1Password)
  - Plus whatever enable flag the current config docs require (consult
    https://docs.triliumnotes.org/user-guide/setup/server/openid-connect at
    implementation time)
- `persistence.data.existingClaim: trilium` (VolSync component provisions
  the PVC; disables the chart-created one)
- Resources: requests 100m / 512Mi, limit 1Gi memory
- `configini.general.instanceName: trilium`
- Single replica (chart default) — SQLite, one writer

### Routing (in HelmRelease values, no separate httproute.yaml)

- bjw-s common `route:` key generates the HTTPRoute from chart values:
  hostname `trilium.vaderrp.com`, parentRef `gateway-public` (ns `network`)
- Route annotations: `external-dns.alpha.kubernetes.io/target:
  external.vaderrp.com`, gatus check on `/api/health-check`, homepage
  (group Tools); label `route.scope: external`
- Filter: `traefik-warp` ExtensionRef only (no `oidc-auth` middleware —
  auth is handled natively by Trilium's OIDC). Verified: common 5.0.1
  supports `route.<id>.rules[].filters` (covered by upstream unit tests).

## Auth

- Trilium's native OIDC handles login, with Authentik as the provider —
  no proxy-auth middleware on the route
- Manual prerequisite in Authentik: create an OAuth2/OpenID provider +
  application (slug `trilium`), redirect URI
  `https://trilium.vaderrp.com/callback`; store client ID/secret in
  1Password for the ExternalSecret
- ETAPI (`/etapi`) is externally reachable but token-authenticated
  (tokens minted in the Trilium UI). Accepted; MCP/API consumers still
  talk to `trilium.tools.svc.cluster.local:8080` in-cluster.

## SQLite corruption mitigations

Prior *arr corruption incidents stemmed from SQLite on network filesystems /
unclean shutdowns. Here:

1. `local-path` (node-local SSD) — no NFS in the write path
2. Single replica + `Recreate` — never two writers
3. Trilium's built-in automatic backups (daily/weekly/monthly copies of
   `document.db` inside the data dir, hence inside the PVC)
4. VolSync/kopia nightly PVC snapshots; restore via
   `just kube volsync-restore tools trilium`
5. Optional later: desktop app as a sync client = a full live replica

## Phase 2 — MCP server (separate follow-up)

Deferred until Trilium is running because the ETAPI token is generated in the
Trilium UI. Plan: deploy a community Trilium MCP server (candidates:
OVDEN13/trilium-mcp static Go binary, or trilium-fastmcp) as a small
deployment in `tools`, ETAPI token via ExternalSecret from 1Password,
exposed following the existing log-aggregator/tempest-mcp pattern. Evaluate
candidate images for an actually-published container image at that point.

## Error handling / failure modes

- Pod restart: stateless besides PVC; probes gate traffic until healthy
- Node failure: local-path PVC ties the pod to its node; recovery = VolSync
  restore onto another node (accepted for a single-user app)
- Authentik outage: OIDC login unavailable (fail closed for new sessions);
  existing Trilium sessions and in-cluster ETAPI access unaffected

## Verification

1. `flux get ks -A` shows `trilium` Ready; `flux get hr -n tools trilium` Ready
2. `https://trilium.vaderrp.com` loads, OIDC login round-trips through
   Authentik (not Google!), then the Trilium setup wizard appears
3. Gatus endpoint green on `/api/health-check`
4. VolSync ReplicationSource reports a successful snapshot after first run
   (or trigger via `just kube snapshot`)
