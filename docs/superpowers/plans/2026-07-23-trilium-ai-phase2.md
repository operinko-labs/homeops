# Trilium Phase 2 (MCP Proxy + Claude Code) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose Trilium's built-in MCP endpoint to the LAN through an authenticated Caddy sidecar, and enable the in-app Claude Code chat provider via an init-container-installed CLI.

**Architecture:** All changes are values/manifest edits inside the existing `kubernetes/apps/tools/trilium/app/` Flux app (official chart wrapping bjw-s common 5.0.1). No new Flux Kustomization. The sidecar shares the pod's network namespace so its upstream requests genuinely originate from loopback, satisfying Trilium's MCP guard; the sidecar adds the bearer-token auth Trilium's MCP lacks.

**Tech Stack:** bjw-s common values (multi-container, initContainers, configMaps, advancedMounts, multi-route), Caddy 2, `@anthropic-ai/claude-code` npm package, external-secrets.

**Spec:** `docs/superpowers/specs/2026-07-23-trilium-ai-phase2-design.md`

## Global Constraints

- **Verify all versions/digests against live sources at implementation time**: caddy image tag+digest (Docker Hub `library/caddy`, current 2.x), node slim image tag+digest (current LTS), `@anthropic-ai/claude-code` version (`npm view` or the GitHub releases). Do NOT trust versions from memory.
- Conventional commits, no Co-Authored-By / AI attribution. On "gpg: signing failed: Timeout", retry with `--no-gpg-sign`.
- No `${VAR}` strings in HelmRelease values (Flux postBuild substitutes them). Caddy `{env.*}` placeholders are fine (not Flux syntax).
- Native Windows helm/kubectl may be broken (mise); use `wsl bash -lc "<cmd>"` (repo at /mnt/c/Users/ollie/homeops).
- Vaultwarden item UUID `dbddf928-7c6a-49cb-93dc-37bb7b4285da`, property `ETAPI`, via `bitwarden-fields` ClusterSecretStore.
- MCP route is internal-only: `gateway-internal`, `route.scope: internal`, `external-dns.alpha.kubernetes.io/public: "false"`.

---

### Task 1: Extend ExternalSecret with the MCP token

**Files:**
- Modify: `kubernetes/apps/tools/trilium/app/external-secret.yaml`

**Interfaces:**
- Produces: Secret `trilium-secret` gains key `TRILIUM_MCP_TOKEN` (value = the Vaultwarden `ETAPI` field). Task 2's sidecar consumes it via `secretKeyRef`.

- [ ] **Step 1: Add the template key** — in `spec.target.template.data`, after the `TRILIUM_OAUTH_CLIENT_SECRET` line, add:

```yaml
        TRILIUM_MCP_TOKEN: "{{ .etapi }}"
```

- [ ] **Step 2: Add the data source** — append to `spec.data`:

```yaml
    - secretKey: etapi
      sourceRef:
        storeRef:
          name: bitwarden-fields
          kind: ClusterSecretStore
      remoteRef:
        key: dbddf928-7c6a-49cb-93dc-37bb7b4285da
        property: ETAPI
```

- [ ] **Step 3: Validate build**

Run: `wsl bash -lc "kubectl kustomize /mnt/c/Users/ollie/homeops/kubernetes/apps/tools/trilium/app >/dev/null && echo OK"`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/tools/trilium/app/external-secret.yaml
git commit -m "feat(trilium): add mcp bearer token to external-secret"
```

---

### Task 2: HelmRelease — sidecar, init container, ports, route, resources

**Files:**
- Modify: `kubernetes/apps/tools/trilium/app/helmrelease.yaml`

**Interfaces:**
- Consumes: Secret key `TRILIUM_MCP_TOKEN` (Task 1); existing chart structure (`controllers.main`, `service.main`, `route.main`).
- Produces: sidecar `mcp-proxy` on 8081; service port `mcp: 8081`; route `trilium-mcp.vaderrp.com`; Trilium env `TRILIUM_CLAUDE_CODE_PATH` + `CLAUDE_CONFIG_DIR`; memory limit 2Gi.

- [ ] **Step 1: Look up live versions (constraint: live check)**

```bash
gh api repos/anthropics/claude-code/releases/latest --jq .tag_name   # CLI version, strip leading v
wsl bash -lc "npm view @anthropic-ai/claude-code version"            # cross-check
# caddy digest for current 2.x tag:
TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/caddy:pull" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
curl -s -o /dev/null -w '%{header_json}' -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" "https://registry-1.docker.io/v2/library/caddy/manifests/2" | grep -io 'docker-content-digest[^,]*'
# node LTS slim digest (same pattern, repository:library/node, tag e.g. 24-slim)
```

Expected: a CLI version (e.g. `2.x.y`), a caddy `sha256:...`, a node `sha256:...`. Record all three; they replace the `<...>` placeholders below.

- [ ] **Step 2: Edit `helmrelease.yaml` values.** Apply ALL of the following edits (final `values:` shape shown per block):

(a) In `controllers.main`, add `initContainers` for the CLI install (sibling of `containers`):

```yaml
        initContainers:
          claude-install:
            image:
              repository: node
              tag: <NODE_LTS_SLIM_TAG>@sha256:<NODE_DIGEST>
            command:
              - npm
              - install
              - -g
              - --prefix
              - /opt/claude
              - "@anthropic-ai/claude-code@<CLI_VERSION>"
```

(b) In `controllers.main.containers.trilium.env`, add:

```yaml
              TRILIUM_CLAUDE_CODE_PATH: /opt/claude/bin/claude
              CLAUDE_CONFIG_DIR: /home/node/trilium-data/.claude
```

(c) In `controllers.main.containers.trilium.resources.limits`, change `memory: 1Gi` → `memory: 2Gi`.

(d) In `controllers.main.containers`, add the sidecar:

```yaml
          mcp-proxy:
            image:
              repository: caddy
              tag: 2@sha256:<CADDY_DIGEST>
            env:
              TRILIUM_MCP_TOKEN:
                valueFrom:
                  secretKeyRef:
                    name: trilium-secret
                    key: TRILIUM_MCP_TOKEN
            probes:
              readiness:
                enabled: true
                type: TCP
                port: 8081
            resources:
              requests:
                cpu: 10m
                memory: 32Mi
              limits:
                memory: 128Mi
```

(e) Add top-level `configMaps:` (sibling of `controllers:`):

```yaml
    configMaps:
      caddyfile:
        data:
          Caddyfile: |
            {
              auto_https off
              admin off
            }
            :8081 {
              @mcp {
                path /mcp /mcp/*
                header Authorization "Bearer {env.TRILIUM_MCP_TOKEN}"
              }
              handle @mcp {
                reverse_proxy 127.0.0.1:8080 {
                  header_up Host localhost:8080
                  header_up -X-Forwarded-For
                }
              }
              @mcpNoAuth {
                path /mcp /mcp/*
              }
              handle @mcpNoAuth {
                respond 401
              }
              handle {
                respond 404
              }
            }
```

(f) Add top-level `persistence:` entries (merge into the existing `persistence:` block):

```yaml
      caddyfile:
        type: configMap
        identifier: caddyfile
        advancedMounts:
          main:
            mcp-proxy:
              - path: /etc/caddy/Caddyfile
                subPath: Caddyfile
                readOnly: true
      claude-bin:
        type: emptyDir
        advancedMounts:
          main:
            claude-install:
              - path: /opt/claude
            trilium:
              - path: /opt/claude
```

(g) In `service.main.ports`, add:

```yaml
          mcp:
            port: 8081
```

(h) Add `route.mcp` (sibling of `route.main`):

```yaml
      mcp:
        annotations:
          external-dns.alpha.kubernetes.io/public: "false"
        labels:
          route.scope: internal
        hostnames:
          - trilium-mcp.vaderrp.com
        parentRefs:
          - group: gateway.networking.k8s.io
            kind: Gateway
            name: gateway-internal
            namespace: network
        rules:
          - matches:
              - path:
                  type: PathPrefix
                  value: /
            backendRefs:
              - identifier: main
                port: 8081
```

- [ ] **Step 3: Render locally and verify**

```bash
wsl bash -lc 'cd /mnt/c/Users/ollie/homeops && python3 -c "
import yaml
d = yaml.safe_load(open(\"kubernetes/apps/tools/trilium/app/helmrelease.yaml\"))
yaml.safe_dump(d[\"spec\"][\"values\"], open(\"/tmp/trilium-values.yaml\",\"w\"))
" && helm template trilium oci://ghcr.io/triliumnext/helm-charts/trilium --version 2.0.0 -f /tmp/trilium-values.yaml > /tmp/trilium-rendered.yaml && grep -c "kind: HTTPRoute" /tmp/trilium-rendered.yaml'
```

Expected: `2` (main + mcp routes). Then:

```bash
wsl bash -lc 'grep -A3 "trilium-mcp.vaderrp.com" /tmp/trilium-rendered.yaml | head -8; grep -c "claude-install" /tmp/trilium-rendered.yaml; grep "TRILIUM_CLAUDE_CODE_PATH\|CLAUDE_CONFIG_DIR\|TRILIUM_MCP_TOKEN" /tmp/trilium-rendered.yaml; grep -B2 -A2 "Caddyfile" /tmp/trilium-rendered.yaml | head -12'
```

Expected: mcp route present with `gateway-internal` parent; claude-install init container rendered; all three env names present; Caddyfile ConfigMap + mount rendered. Also confirm the Caddyfile block survived YAML nesting intact (no stray indentation).

- [ ] **Step 4: Validate kustomize build**

Run: `wsl bash -lc "kubectl kustomize /mnt/c/Users/ollie/homeops/kubernetes/apps/tools/trilium/app >/dev/null && echo OK"`
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/tools/trilium/app/helmrelease.yaml
git commit -m "feat(trilium): add mcp proxy sidecar and claude code cli support"
```

---

### Task 3: Deploy and verify

**Interfaces:**
- Consumes: Tasks 1-2 merged to `main`.

- [ ] **Step 1: Push and reconcile**

```bash
git push origin main
flux reconcile source git flux-system -n flux-system
flux reconcile ks trilium -n tools --with-source
flux get hr trilium -n tools
```

Expected: HelmRelease Ready=True, new release revision. (Note: the `trilium` Kustomization lives in ns `tools`.) The pod rolls (Recreate): wait for `kubectl -n tools get pods -l app.kubernetes.io/name=trilium` → `2/2 Running` (trilium + mcp-proxy, after claude-install init completes).

- [ ] **Step 2: Verify secret key materialized**

```bash
kubectl -n tools get secret trilium-secret -o jsonpath='{.data.TRILIUM_MCP_TOKEN}' | head -c 8
```

Expected: non-empty base64 prefix. If empty/missing: check `kubectl -n tools describe externalsecret trilium-secret` (property `ETAPI` name mismatch is the likely cause — STOP and report).

- [ ] **Step 3: Verify the MCP guard chain in-cluster**

```bash
TOKEN=$(kubectl -n tools get secret trilium-secret -o jsonpath='{.data.TRILIUM_MCP_TOKEN}' | base64 -d)
kubectl -n tools run mcp-test --rm -i --restart=Never --image=curlimages/curl -- \
  -s -o /dev/null -w '%{http_code}\n' http://trilium.tools.svc.cluster.local:8081/mcp
kubectl -n tools run mcp-test2 --rm -i --restart=Never --image=curlimages/curl -- \
  -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" -H "Accept: application/json, text/event-stream" \
  -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
  http://trilium.tools.svc.cluster.local:8081/mcp
```

Expected: first prints `401`; second prints `200`. **If the second prints `401`**, Caddy's env placeholder in the header matcher did not substitute — apply the spec's fallback: move the Caddyfile into the ExternalSecret template (literal token rendered in), mount it from the secret instead of the ConfigMap, remove the configMaps entry, commit as `fix(trilium): render mcp caddyfile via external-secret`, redeploy, re-verify. **If it prints `403`**, Trilium rejected the source IP or Host header — check `header_up` lines against the rendered Caddyfile and capture `kubectl -n tools logs deploy/trilium -c mcp-proxy`.

- [ ] **Step 4: Verify the internal hostname (LAN DNS)**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://trilium-mcp.vaderrp.com/mcp
```

Expected: `401` (route + TLS work; no token supplied). Allow a couple of minutes for internal DNS.

- [ ] **Step 5: Verify the CLI installed and config dir landed on the PVC**

```bash
kubectl -n tools exec deploy/trilium -c trilium -- /opt/claude/bin/claude --version
kubectl -n tools exec deploy/trilium -c trilium -- sh -c 'echo $CLAUDE_CONFIG_DIR'
```

Expected: a version string matching the pinned CLI version; `/home/node/trilium-data/.claude`.

- [ ] **Step 6: Report status** — remaining user actions are Task 4; do not attempt them.

---

### Task 4: One-time login and client hookup (USER ACTION)

- [ ] **Step 1: Log the CLI in** (user):

```bash
kubectl -n tools exec -it deploy/trilium -c trilium -- /opt/claude/bin/claude /login
```

Follow the printed URL in a browser, paste the code back.

- [ ] **Step 2: Add the provider in Trilium** (user): Options → AI/LLM → Add AI Provider → **Claude Code** → Add Provider. Send a test chat message.

- [ ] **Step 3: Connect an MCP client** (user): add to the client config (e.g. Claude Code on the desktop):

```bash
claude mcp add --transport http trilium https://trilium-mcp.vaderrp.com/mcp --header "Authorization: Bearer <ETAPI value from Vaultwarden>"
```

Expected: Trilium tools listed in the client.

- [ ] **Step 4 (verification of persistence): restart the pod once** (`kubectl -n tools rollout restart deployment trilium`), confirm chat still works without re-login.
