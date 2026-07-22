# Trilium Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Trilium Notes to the `tools` namespace via Flux, using the official TriliumNext Helm chart, with native Authentik OIDC login, external access at `trilium.vaderrp.com`, and VolSync-backed storage.

**Architecture:** One new Flux app at `kubernetes/apps/tools/trilium/` following the existing bambuddy/radarr patterns: a Flux `Kustomization` (with the volsync-kopia component providing the PVC and backups), an `OCIRepository` pointing at the official chart, an `ExternalSecret` pulling OAuth credentials from Vaultwarden, and a `HelmRelease` whose values also generate the HTTPRoute (bjw-s common `route:` key — no separate httproute.yaml).

**Tech Stack:** Flux CD, official `trilium` Helm chart 2.0.0 (wraps bjw-s common 5.0.1), external-secrets (Vaultwarden ClusterSecretStores), VolSync/kopia, Traefik Gateway API (`gateway-public`), Authentik OIDC.

**Spec:** `docs/superpowers/specs/2026-07-22-trilium-design.md`

## Global Constraints

- **Verify latest versions against live sources at implementation time** — chart version from `gh api repos/TriliumNext/helm-charts/releases/latest` (latest known: chart `trilium-2.0.0`, appVersion `v0.104.0`). Do NOT trust versions from memory.
- Commit messages: conventional commits, **no Co-Authored-By / AI attribution** (user rule).
- If `git commit` fails with "gpg: signing failed: Timeout", retry with `--no-gpg-sign` (user-approved).
- All new manifests must match existing repo patterns (copy shapes from `kubernetes/apps/tools/bambuddy/` and `kubernetes/apps/media/radarr/`).
- No `${VAR}` strings may appear in HelmRelease values (Flux postBuild would substitute them; none are needed here).
- Secrets come from Vaultwarden via `bitwarden-fields` ClusterSecretStore (the CLAUDE.md claim of 1Password is stale).
- The cluster is reachable; `flux`, `kubectl`, `helm`, `gh` are available (run via WSL if a tool is missing on Windows: `wsl <cmd>`).

---

### Task 1: Authentik provider + Vaultwarden secret (USER ACTION — checkpoint)

This task is manual clicking in two web UIs. Everything later depends on its outputs.

**Interfaces:**
- Produces: Authentik OAuth2 provider with issuer `https://auth.vaderrp.com/application/o/trilium/`; a Vaultwarden item whose **UUID** and two custom field names (`TRILIUM_OAUTH_CLIENT_ID`, `TRILIUM_OAUTH_CLIENT_SECRET`) Task 3 references.

- [ ] **Step 1: Create the Authentik provider + application** (user, in Authentik admin UI at `https://auth.vaderrp.com`)
  - Applications → Providers → Create → **OAuth2/OpenID Provider**
    - Name: `trilium`
    - Authorization flow: the same implicit/explicit flow used by existing providers
    - Client type: **Confidential**
    - Redirect URI (strict): `https://trilium.vaderrp.com/callback`
    - Signing key: default
    - Copy the generated **Client ID** and **Client Secret**
  - Applications → Applications → Create
    - Name: `Trilium`, slug: `trilium` (slug MUST be `trilium` — it forms the issuer URL)
    - Provider: the `trilium` provider just created

- [ ] **Step 2: Store credentials in Vaultwarden** (user)
  - Create a new item named `trilium` (any type; Secure Note is fine)
  - Add two **custom fields** (hidden type):
    - `TRILIUM_OAUTH_CLIENT_ID` = the Client ID
    - `TRILIUM_OAUTH_CLIENT_SECRET` = the Client Secret
  - Copy the item's UUID (visible in the URL when the item is open, e.g. `7f1eaab5-591b-47c5-bab0-a12cac833bc2`)

- [ ] **Step 3: Record the UUID** — paste it into this plan file replacing `VAULTWARDEN-ITEM-UUID` in Task 3, or hand it to the implementer.

- [ ] **Step 4: Sanity-check the issuer URL resolves**

```bash
curl -sf https://auth.vaderrp.com/application/o/trilium/.well-known/openid-configuration | head -c 200
```

Expected: JSON starting with `{"issuer":"https://auth.vaderrp.com/application/o/trilium/"...`. A 404 means the application slug is not `trilium`.

---

### Task 2: Scaffold the Flux app (ks, OCIRepository, kustomizations)

**Files:**
- Create: `kubernetes/apps/tools/trilium/ks.yaml`
- Create: `kubernetes/apps/tools/trilium/app/kustomization.yaml`
- Create: `kubernetes/apps/tools/trilium/app/ocirepository.yaml`
- Modify: `kubernetes/apps/tools/kustomization.yaml` (add one line)

**Interfaces:**
- Produces: Flux Kustomization `trilium` (flux-system ns, target ns `tools`) with postBuild var `APP: trilium` → volsync-kopia component provisions PVC named `trilium`; OCIRepository named `trilium` that Task 4's HelmRelease references via `chartRef`.

- [ ] **Step 1: Verify the latest chart release (constraint: live check)**

```bash
gh api repos/TriliumNext/helm-charts/releases/latest --jq '.tag_name'
```

Expected: `trilium-2.0.0` (or newer — if newer, use that chart version in `ocirepository.yaml` below and re-check the chart's values for renames before continuing; also check `gh api repos/TriliumNext/Trilium/releases/latest --jq .tag_name` for the app version the chart ships).

- [ ] **Step 2: Create `kubernetes/apps/tools/trilium/ks.yaml`**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: trilium
  namespace: flux-system
spec:
  decryption:
    provider: sops
  targetNamespace: tools
  commonMetadata:
    labels:
      app.kubernetes.io/name: trilium
  path: "./kubernetes/apps/tools/trilium/app"
  prune: true
  components:
    - ../../../../components/volsync-kopia
  dependsOn:
    - name: volsync
      namespace: storage
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  wait: false
  interval: 30m
  retryInterval: 1m
  timeout: 5m
  postBuild:
    substitute:
      APP: trilium
      VOLSYNC_CAPACITY: 10Gi
      VOLSYNC_PUID: "1000"
      VOLSYNC_PGID: "1000"
```

- [ ] **Step 3: Create `kubernetes/apps/tools/trilium/app/kustomization.yaml`**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - external-secret.yaml
  - helmrelease.yaml
  - ocirepository.yaml
```

(Note: `external-secret.yaml` and `helmrelease.yaml` are created in Tasks 3–4; `kubectl kustomize` will fail until then — that's expected.)

- [ ] **Step 4: Create `kubernetes/apps/tools/trilium/app/ocirepository.yaml`**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: trilium
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 2.0.0
  url: oci://ghcr.io/triliumnext/helm-charts/trilium
```

- [ ] **Step 5: Register the app in `kubernetes/apps/tools/kustomization.yaml`** — add `  - ./trilium/ks.yaml` to `resources:`, keeping alphabetical order:

```yaml
resources:
  - ./namespace.yaml
  - ./bambuddy/ks.yaml
  - ./birdnet-go/ks.yaml
  - ./headlamp/ks.yaml
  - ./log-aggregator/ks.yaml
  - ./n8n/ks.yaml
  - ./parsedmarc/ks.yaml
  - ./tainer/ks.yaml
  - ./trilium/ks.yaml
```

- [ ] **Step 6: Verify the chart pulls and inspect default values**

```bash
helm show values oci://ghcr.io/triliumnext/helm-charts/trilium --version 2.0.0 | head -30
```

Expected: values YAML starting with the `controllers:` block (`main` controller, `fixperms` init container). Confirms registry path, tag, and that value key names match Task 4.

- [ ] **Step 7: Commit**

```bash
git add kubernetes/apps/tools/trilium/ kubernetes/apps/tools/kustomization.yaml
git commit -m "feat(trilium): scaffold flux app with official helm chart"
```

---

### Task 3: ExternalSecret for OAuth credentials

**Files:**
- Create: `kubernetes/apps/tools/trilium/app/external-secret.yaml`

**Interfaces:**
- Consumes: Vaultwarden item UUID from Task 1 (`VAULTWARDEN-ITEM-UUID` below MUST be replaced with it).
- Produces: Kubernetes Secret `trilium-secret` in ns `tools` with keys `TRILIUM_OAUTH_CLIENT_ID` and `TRILIUM_OAUTH_CLIENT_SECRET` — consumed by Task 4 via `envFrom`.

- [ ] **Step 1: Create `kubernetes/apps/tools/trilium/app/external-secret.yaml`** (replace `VAULTWARDEN-ITEM-UUID` with the real UUID from Task 1):

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: trilium-secret
  namespace: tools
spec:
  refreshInterval: 1h
  target:
    name: trilium-secret
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      data:
        TRILIUM_OAUTH_CLIENT_ID: "{{ .client_id }}"
        TRILIUM_OAUTH_CLIENT_SECRET: "{{ .client_secret }}"
  data:
    - secretKey: client_id
      sourceRef:
        storeRef:
          name: bitwarden-fields
          kind: ClusterSecretStore
      remoteRef:
        key: VAULTWARDEN-ITEM-UUID
        property: TRILIUM_OAUTH_CLIENT_ID
    - secretKey: client_secret
      sourceRef:
        storeRef:
          name: bitwarden-fields
          kind: ClusterSecretStore
      remoteRef:
        key: VAULTWARDEN-ITEM-UUID
        property: TRILIUM_OAUTH_CLIENT_SECRET
```

- [ ] **Step 2: Verify no placeholder remains**

```bash
grep -c "VAULTWARDEN-ITEM-UUID" kubernetes/apps/tools/trilium/app/external-secret.yaml
```

Expected: `0` (grep exits 1). If not, stop — Task 1 output was not filled in.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/tools/trilium/app/external-secret.yaml
git commit -m "feat(trilium): add oauth credentials external-secret"
```

---

### Task 4: HelmRelease with OIDC env and route

**Files:**
- Create: `kubernetes/apps/tools/trilium/app/helmrelease.yaml`

**Interfaces:**
- Consumes: OCIRepository `trilium` (Task 2), Secret `trilium-secret` with keys `TRILIUM_OAUTH_CLIENT_ID`/`TRILIUM_OAUTH_CLIENT_SECRET` (Task 3), PVC `trilium` (volsync component, Task 2).
- Produces: HelmRelease `trilium` → Deployment + Service `trilium` (port 8080) + chart-generated HTTPRoute `trilium` on `gateway-public`.

Chart defaults already provide: image `triliumnext/trilium:v0.104.0`, fixperms init, probes on `/api/health-check`, config.ini with `trustedReverseProxy: true`, port 8080, fsGroup 1000, single replica. Values below only override what the spec requires.

- [ ] **Step 1: Create `kubernetes/apps/tools/trilium/app/helmrelease.yaml`**

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: trilium
spec:
  interval: 30m
  chartRef:
    kind: OCIRepository
    name: trilium
  maxHistory: 2
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  values:
    controllers:
      main:
        containers:
          trilium:
            env:
              TZ: Europe/Helsinki
              TRILIUM_OAUTH_BASE_URL: https://trilium.vaderrp.com
              # MUST be explicit: unset silently falls back to Google (TriliumNext/Trilium#6444)
              TRILIUM_OAUTH_ISSUER_BASE_URL: https://auth.vaderrp.com/application/o/trilium/.well-known/openid-configuration
              TRILIUM_OAUTH_ISSUER_NAME: Authentik
            envFrom:
              - secretRef:
                  name: trilium-secret
            resources:
              requests:
                cpu: 100m
                memory: 512Mi
              limits:
                memory: 1Gi

    configini:
      general:
        instanceName: trilium

    persistence:
      data:
        existingClaim: trilium

    route:
      main:
        annotations:
          external-dns.alpha.kubernetes.io/target: external.vaderrp.com
          gatus.home-operations.com/enabled: "true"
          gatus.home-operations.com/endpoint: |
            group: Tools
            url: "https://trilium.vaderrp.com/api/health-check"
            conditions:
              - "[STATUS] == 200"
          gethomepage.dev/enabled: "true"
          gethomepage.dev/group: Tools
          gethomepage.dev/name: Trilium
          gethomepage.dev/icon: trilium.png
          gethomepage.dev/href: https://trilium.vaderrp.com
          gethomepage.dev/pod-selector: app.kubernetes.io/name=trilium
        labels:
          route.scope: external
        hostnames:
          - trilium.vaderrp.com
        parentRefs:
          - group: gateway.networking.k8s.io
            kind: Gateway
            name: gateway-public
            namespace: network
        rules:
          - matches:
              - path:
                  type: PathPrefix
                  value: /
            filters:
              - type: ExtensionRef
                extensionRef:
                  group: traefik.io
                  kind: Middleware
                  name: traefik-warp
            backendRefs:
              - identifier: main
                port: 8080
```

- [ ] **Step 2: Render the chart locally with these values to prove they're valid**

```bash
python -c "
import yaml, sys
d = yaml.safe_load(open('kubernetes/apps/tools/trilium/app/helmrelease.yaml'))
yaml.safe_dump(d['spec']['values'], open('/tmp/trilium-values.yaml','w'))
"
helm template trilium oci://ghcr.io/triliumnext/helm-charts/trilium --version 2.0.0 -f /tmp/trilium-values.yaml > /tmp/trilium-rendered.yaml
grep -c "kind: HTTPRoute" /tmp/trilium-rendered.yaml
```

Expected: `helm template` succeeds; grep prints `1`. If helm errors on `backendRefs[0].identifier`, replace that entry with `- name: trilium` + `port: 8080` and re-render.

- [ ] **Step 3: Verify the rendered route and env**

```bash
grep -A3 "extensionRef" /tmp/trilium-rendered.yaml
grep "TRILIUM_OAUTH_ISSUER_BASE_URL" -A1 /tmp/trilium-rendered.yaml
grep -B2 -A2 "existingClaim\|claimName" /tmp/trilium-rendered.yaml | head -20
```

Expected: extensionRef shows `name: traefik-warp`; issuer URL env present on the trilium container; deployment volume references `claimName: trilium` (not a chart-created PVC).

- [ ] **Step 4: Validate the whole app directory builds**

```bash
kubectl kustomize kubernetes/apps/tools/trilium/app >/dev/null && echo OK
kubectl kustomize kubernetes/apps/tools >/dev/null && echo OK
```

Expected: `OK` twice.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/tools/trilium/app/helmrelease.yaml
git commit -m "feat(trilium): add helmrelease with native oidc and external route"
```

---

### Task 5: Deploy and verify

**Interfaces:**
- Consumes: everything above, merged to `main` (Flux deploys from `main`).

- [ ] **Step 1: Push to main**

```bash
git push origin main
```

- [ ] **Step 2: Reconcile and watch**

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile ks cluster-apps -n flux-system
flux get ks trilium -n flux-system
flux get hr trilium -n tools
```

Expected: Kustomization `trilium` Ready=True; HelmRelease `trilium` Ready=True (release v1 installed). If the HelmRelease is stuck, `kubectl -n tools describe hr trilium` and `kubectl -n tools get events --sort-by='.metadata.creationTimestamp' | tail -20`.

- [ ] **Step 3: Verify the secret synced**

```bash
kubectl -n tools get externalsecret trilium-secret
```

Expected: `SecretSynced` / Ready=True. If `SecretSyncedError`, the Vaultwarden UUID or field names in Task 3 are wrong.

- [ ] **Step 4: Verify the pod is healthy and API responds in-cluster**

```bash
kubectl -n tools get pods -l app.kubernetes.io/name=trilium
kubectl -n tools run curl-test --rm -i --restart=Never --image=curlimages/curl -- -sf http://trilium.tools.svc.cluster.local:8080/api/health-check
```

Expected: pod `1/1 Running`; curl prints `{"status":"ok"}` (or similar 200 JSON body).

- [ ] **Step 5: Verify the route and DNS**

```bash
kubectl -n tools get httproute trilium
curl -sI https://trilium.vaderrp.com/api/health-check | head -1
```

Expected: route lists hostname `trilium.vaderrp.com`; curl returns `HTTP/2 200` once external-dns has created the CNAME (allow a few minutes).

- [ ] **Step 6: OIDC round-trip (USER ACTION — checkpoint)** — open `https://trilium.vaderrp.com` in a browser. Expected: Trilium login page shows a "Sign in with Authentik" (NOT Google) option; completing it lands in the Trilium setup wizard. Complete the wizard (server instance, defaults are fine).

- [ ] **Step 7: Trigger and verify a VolSync snapshot**

```bash
# Note: this cluster's VolSync uses the spec.trigger.manual field, not the
# volsync.backube/manual annotation (see kubernetes/mod.just snapshot recipe).
kubectl -n tools patch replicationsource trilium --type merge -p "{\"spec\":{\"trigger\":{\"manual\":\"$(date +%s)\"}}}"
sleep 60
kubectl -n tools get replicationsource trilium -o jsonpath='{.status.lastManualSync}{"\n"}{.status.latestMoverStatus.result}{"\n"}'
```

Expected: a recent timestamp and `Successful`.

- [ ] **Step 8: Final commit if any fixups were needed, otherwise done**

```bash
git status
```

Expected: clean tree. Phase 2 (MCP server) is a separate follow-up per the spec — do NOT start it in this plan.
