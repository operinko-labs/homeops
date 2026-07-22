# Trilium Phase 2: MCP Access + Claude Code Chat Provider

**Date:** 2026-07-23
**Status:** Draft (pending user review)
**Builds on:** `2026-07-22-trilium-design.md` (Trilium deployed and live)

## Context

Trilium v0.104 ships two first-party AI integrations we want:

1. **Built-in MCP server** at `/mcp` on the main port (8080). Guarded by
   (a) the `mcpEnabled` option (already enabled by the user in the UI),
   (b) a loopback-source-IP check, and (c) a Host-header allow-list
   (`localhost`/`127.0.0.1`/`[::1]`, port-qualified or bare). It has **no
   authentication** — loopback is the auth. Source:
   `apps/server/src/routes/mcp.ts`.
2. **Claude Code chat provider** — Trilium drives a locally installed
   `claude` CLI via the Claude Agent SDK (bring-your-own-binary mode).
   Resolution: `TRILIUM_CLAUDE_CODE_PATH` env override, else `claude` on
   PATH; probed with `--version`; requires a one-time `claude /login` on
   the machine. Source:
   `apps/server/src/services/llm/providers/claude_binary.ts`.

Decisions made: deliver both in one change to the existing HelmRelease;
MCP exposed **internal-only**; the user's existing Vaultwarden item
(`dbddf928-7c6a-49cb-93dc-37bb7b4285da`) now has an `ETAPI` custom field
whose value doubles as the MCP proxy bearer token.

## Design

All changes live in `kubernetes/apps/tools/trilium/app/` (official chart,
bjw-s common 5.0.1 values).

### Part A — MCP sidecar proxy

A `caddy` sidecar container in the Trilium pod (same network namespace, so
its upstream connection to `127.0.0.1:8080` genuinely originates from
loopback):

- Container `mcp-proxy`, image `caddy` (pin current 2.x tag@digest at
  implementation time; pulls transit Harbor), listening on **8081**
- Caddyfile (mounted from a chart `configMaps:` entry):
  - Only the `/mcp` path is proxied; everything else 404s
  - Requires `Authorization: Bearer <token>` where the token comes from
    env `TRILIUM_MCP_TOKEN` (Caddy `{env.*}` placeholder); non-matching
    requests get 401
  - `reverse_proxy 127.0.0.1:8080` with `Host` rewritten to
    `localhost:8080` (DNS-rebinding allow-list) and `X-Forwarded-For`
    stripped (Trilium's `trustedReverseProxy` would otherwise surface the
    real client IP and fail the loopback check)
- `TRILIUM_MCP_TOKEN` env from the existing `trilium-secret`: the
  ExternalSecret gains a third templated key mapping the Vaultwarden
  item's `ETAPI` property
- `service.main` gains port `mcp: 8081`
- New chart-generated route `route.mcp`: hostname
  `trilium-mcp.vaderrp.com`, parentRef `gateway-internal` (ns `network`),
  label `route.scope: internal`, annotation
  `external-dns.alpha.kubernetes.io/public: "false"`, backendRef to the
  8081 port. No traefik-warp (internal), no oidc middleware (bearer token
  is the auth; MCP clients can't do OIDC redirects).

Caveat verified against source: with the sidecar in-pod, checks (b) and
(c) pass legitimately; the bearer gate is ours. If Caddy's header matcher
turns out not to support `{env.*}` placeholders at implementation time,
fall back to rendering the token into the Caddyfile via the
ExternalSecret template (secret-mounted Caddyfile) rather than weakening
auth.

### Part B — Claude Code CLI for in-app chat

- Init container `claude-install` (stock `node` LTS slim image, pinned
  tag@digest): `npm install -g --prefix /opt/claude
  @anthropic-ai/claude-code@<version>` (pin the current version at
  implementation time), installing into an `emptyDir` volume shared with
  the main container at `/opt/claude`. Reinstall happens on pod
  recreation; needs npm registry egress at startup (accepted).
- Main container env:
  - `TRILIUM_CLAUDE_CODE_PATH=/opt/claude/bin/claude` (the CLI's
    entrypoint script; the Trilium image is node-based so the
    `#!/usr/bin/env node` shebang resolves)
  - `CLAUDE_CONFIG_DIR=/home/node/trilium-data/.claude` — inside the
    existing `trilium` PVC, so login credentials survive restarts AND are
    VolSync-backed-up with the notes
- Memory limit raised 1Gi → **2Gi** (each chat spawns a Claude Code
  process); requests unchanged
- One-time manual step after rollout: `kubectl -n tools exec -it
  deploy/trilium -c trilium -- /opt/claude/bin/claude /login`, complete
  the OAuth flow from a browser, then add the "Claude Code" provider in
  Trilium's AI settings (UI)

## Failure modes

- Sidecar down → MCP endpoint unavailable; Trilium itself unaffected
- npm registry unreachable at pod start → init container fails, pod won't
  start; mitigated by pinned version (layer-cached npm tarball is NOT
  cached across nodes — accepted for a homelab)
- Token rotation: rotate the `ETAPI` field in Vaultwarden; ExternalSecret
  refreshes within 1h (or force with `just kube sync-es`)
- Claude login expiry → in-app chat errors with the provider's actionable
  message; re-run the exec login

## Verification

1. `flux get hr -n tools trilium` Ready after change
2. In-cluster: `curl -s http://trilium.tools.svc.cluster.local:8081/mcp`
   → 401 without token; with `Authorization: Bearer <ETAPI value>` →
   MCP protocol response (405/406-style or JSON-RPC error to a bare GET is
   acceptable — proves the guard chain passed)
3. `https://trilium-mcp.vaderrp.com/mcp` resolves on LAN and gives the
   same 401/200 behavior
4. MCP client (Claude Code on the user's machine) connects with the
   bearer token and lists Trilium tools
5. After `claude /login` exec: Trilium UI → AI settings → add Claude Code
   provider succeeds (its `--version` probe passes); a test chat responds
6. Pod restart: login persists (CLAUDE_CONFIG_DIR on PVC), CLI
   reinstalls, chat still works
