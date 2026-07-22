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

- bjw-s `app-template` chart, `4.6.2` (same as other apps)

### `app/helmrelease.yaml`

- Single controller `trilium`, one replica, `Recreate` strategy (single
  writer, always)
- Image: `triliumnext/trilium`, pinned `<latest-tag>@sha256:<digest>`.
  **The tag and digest MUST be verified against the live registry/GitHub
  releases at implementation time** (latest known at design time: v0.104.0,
  released 2026-07-18). Pulls transit the Harbor mirror automatically.
- Port 8080; env `TRILIUM_DATA_DIR=/home/node/trilium-data`, `TZ`
- Liveness/readiness probes on `GET /api/health-check`
- securityContext: runAsUser/Group 1000, fsGroup 1000, no privilege
  escalation, drop ALL capabilities, seccomp RuntimeDefault
- Resources: requests 100m / 512Mi, limit 1Gi memory
- Persistence: `existingClaim: trilium` mounted at `/home/node/trilium-data`

### `app/httproute.yaml`

- Hostname `trilium.vaderrp.com` on `gateway-public` (namespace `network`)
- Annotation `external-dns.alpha.kubernetes.io/target: external.vaderrp.com`
- Filters: `traefik-warp` + `oidc-auth` middlewares (both already present in
  `tools` via `components/common`)
- Gatus annotations checking `/api/health-check`; homepage annotations
  (group Tools)

## Auth layering

- Authentik gates all external browser access via the shared `oidc-auth`
  traefik middleware
- Trilium's built-in single-password login stays enabled underneath
  (defense in depth; also the mechanism that issues ETAPI tokens)
- The shared middleware bypasses only `/api`; Trilium's ETAPI lives at
  `/etapi`, so the API is intentionally NOT reachable externally. MCP/API
  consumers talk to `trilium.tools.svc.cluster.local:8080` in-cluster.

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
- Authentik outage: external access blocked (fail closed); LAN/cluster
  access unaffected

## Verification

1. `flux get ks -A` shows `trilium` Ready; `flux get hr -n tools trilium` Ready
2. `https://trilium.vaderrp.com` redirects to Authentik, then loads the
   Trilium setup wizard
3. Gatus endpoint green on `/api/health-check`
4. VolSync ReplicationSource reports a successful snapshot after first run
   (or trigger via `just kube snapshot`)
