# Matrix (Synapse + MAS + Element) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a federated Matrix homeserver for `@user:erinko.fi` with MAS login (local + Authentik), Element Web/X clients, S3 media on Versity and MatrixRTC calls through the VPS.

**Architecture:** Element's ESS Community chart (`matrix-stack` 26.10.1) in namespace `matrix`, with a Harbor-built Synapse image that adds `synapse-s3-storage-provider`, both databases on `postgres18`, secrets from one Vaultwarden item, our own HTTPRoutes on `gateway-public` (chart Ingresses deleted by a post-renderer), and LiveKit media reaching talos7 through the VPS over WireGuard.

**Tech Stack:** Flux HelmRelease + OCIRepository, CloudNativePG, External Secrets (`bitwarden-fields`), Gateway API (Traefik), VolSync/kopia, Forgejo Actions → Harbor, haproxy + nftables on the VPS, Gatus.

**Spec:** `docs/superpowers/specs/2026-10-16-matrix-synapse-design.md`

## Global Constraints

- `server_name: erinko.fi` — permanent once the first account exists.
- Hosts: `matrix.erinko.fi` (Synapse), `account.erinko.fi` (MAS), `chat.erinko.fi` (Element Web), `mrtc.erinko.fi` (MatrixRTC), `erinko.fi` (well-known).
- Chart: `oci://ghcr.io/element-hq/ess-helm/matrix-stack` tag `26.10.1`; HelmRelease name `matrix` (all chart resources are prefixed `matrix-`).
- Synapse image: `harbor.vaderrp.com/operinko-labs/synapse:<apps/synapse/VERSION>`, built `FROM oci.element.io/synapse:<VERSION>`; VERSION starts at `v1.163.0` (the chart's own pin). `synapse-s3-storage-provider==1.7.0`.
- Synapse runs as uid/gid `10091` (chart default).
- The deployed image tag lives in one place: `SYNAPSE_TAG` in `kubernetes/apps/matrix/matrix-stack/ks.yaml` (Flux postBuild substitution), tracked by Renovate against `harbor.vaderrp.com/operinko-labs/synapse`. `apps/synapse/VERSION` is tracked against `oci.element.io/synapse`. Upgrade = Renovate bumps VERSION → CI builds the Harbor tag → Renovate bumps `SYNAPSE_TAG`, so the cluster never references an unbuilt tag.
- S3: Versity `https://s3.vaderrp.com:9000`, bucket `synapse-media`, account `synapse-media`, region `us-east-1`.
- Postgres: cluster `postgres18`, host `postgres18-rw.database.svc.cluster.local:5432`; roles/DBs `synapse` (collate/ctype `C`, template0) and `mas`.
- MAS upstream provider ULID: `01M51PC86JKZ57T8BMGZCJC1F3`; Authentik issuer `https://auth.vaderrp.com/application/o/matrix/`.
- MatrixRTC: SFU on talos7, externalIP `172.16.8.12`, TCP 30001 + UDP 30002, `manualIP: 212.147.241.182`.
- homeops changes are committed and pushed straight to `main`. No `Co-Authored-By` or any AI attribution in commit messages.
- Mutating commands on the VPS and in Vaultwarden/Versity/Authentik/Cloudflare/Stalwart UIs are run by the user; the agent prepares files and commands.
- Curl checks against public hosts: run from WSL (`wsl.exe -d Ubuntu --exec curl …`); Windows curl fails TLS revocation checks on some hosts.
- Before every commit touching `kubernetes/`: `kubectl kustomize <changed app dir>` must render, and `flux-local`-style errors are not tolerated.

## File Structure

| Path | Responsibility |
|---|---|
| `apps/synapse/Dockerfile`, `apps/synapse/VERSION` | Custom Synapse image |
| `.forgejo/workflows/build-synapse.yaml` | Build + push to Harbor |
| `.renovate/customManagers.json5` | Track `VERSION` and Dockerfile ARG pins |
| `kubernetes/apps/database/cloudnative-pg/app/cluster/cluster18.yaml` | + managed roles `synapse`, `mas` |
| `kubernetes/apps/database/cloudnative-pg/app/cluster/{database,external-secret}-matrix.yaml` | DBs + role passwords |
| `kubernetes/apps/matrix/{kustomization,namespace}.yaml` | Namespace wiring |
| `kubernetes/apps/matrix/matrix-stack/ks.yaml` | Flux Kustomization (+ volsync component) |
| `kubernetes/apps/matrix/matrix-stack/app/external-secret.yaml` | `matrix-secrets` (all keys + config fragments) |
| `kubernetes/apps/matrix/matrix-stack/app/{ocirepository,helmrelease}.yaml` | ESS chart |
| `kubernetes/apps/matrix/matrix-stack/app/httproute.yaml` | Public routes |
| `kubernetes/apps/matrix/matrix-stack/app/cronjob-s3-drain.yaml` | Local media cache → S3 |
| `kubernetes/apps/network/gateways/app/gateway-public.yaml` | + `https-erinko-apex` listener |
| `kubernetes/apps/storage/minio-gdrive-sync/app/cronjob.yaml` | + `synapse-media` offsite |
| `kubernetes/apps/observability/gatus/app/gatus-config.yaml` | Matrix endpoints |
| `vps/config/haproxy.cfg`, `vps/config/homeops-rtc.nft`, `vps/config/homeops-rtc-nat.service`, `vps/apply.sh`, `vps/mod.just` | Call media forwarding |

---

### Task 0: Close PR #1439 and amend the spec

Rendering the chart (26.10.1) showed three spec details need correcting before anything is built.

**Files:**
- Modify: `docs/superpowers/specs/2026-10-16-matrix-synapse-design.md`

**Interfaces:**
- Produces: corrected spec that later tasks rely on.

- [ ] **Step 1: Edit the spec**

In the Secrets section, replace the sentence starting "Everything comes from one Vaultwarden item `matrix` via `bitwarden-fields`; the chart's `initSecrets` job is off." and its "Reason:" sentence with:

```markdown
Everything that matters comes from one Vaultwarden item `matrix` via
`bitwarden-fields`. The chart's `initSecrets` job stays **on**, but with every
secret below supplied it only generates the MatrixRTC appservice registration
and `SYNAPSE_EXTRA` into `matrix-generated` — throwaway values the chart can
regenerate. Disabling it fails rendering ("Secret configuration at
matrixRTC.appserviceRegistration is not present"). The signing key, MAS
encryption secret and private keys are never chart-generated: losing those
would break federation trust or every session.
```

In "Components and hostnames" and "Backups", change `PUID/PGID 991` to `PUID/PGID 10091` (the chart runs Synapse as 10091).

In "Calls (MatrixRTC via the VPS)", replace the bullet starting "Chart `exposedServices.rtcTcp` / `rtcMuxedUdp` set to `ClusterIP`; a new `service-livekit-wg.yaml`…" with:

```markdown
- Chart `exposedServices.rtcTcp` / `rtcMuxedUdp`: `portType: ClusterIP`,
  `externalIPs: ["172.16.8.12"]` (the chart supports both). The chart only
  emits `externalTrafficPolicy` for NodePort/LoadBalancer, so a HelmRelease
  `postRenderers` JSON patch adds `externalTrafficPolicy: Local` to
  `matrix-matrix-rtc-sfu-tcp` and `matrix-matrix-rtc-sfu-muxed-udp`. No
  separate Service file.
```

In "Upgrades", replace the "Synapse image" bullet with:

```markdown
- Synapse image: `apps/synapse/VERSION` is tracked by a Renovate regex manager
  against `oci.element.io/synapse` (the registry the chart itself uses); CI
  builds the Harbor tag on merge. The deployed tag is `SYNAPSE_TAG` in the
  app's Flux Kustomization (postBuild substitution, used by the HelmRelease and
  the drain CronJob), tracked against `harbor.vaderrp.com/operinko-labs/synapse`,
  so it only moves once the image exists. `synapse-s3-storage-provider` is
  version-pinned in the Dockerfile.
```

- [ ] **Step 2: Close the PR**

```bash
tea pulls close 1439 --repo operinko-labs/homeops
git push origin --delete feature/matrix-synapse
```

Before closing, add a comment: `tea comment 1439 "Superseded by docs/superpowers/specs/2026-10-16-matrix-synapse-design.md (ESS Community chart); implementation lands on main."`. If `tea comment` is unavailable, close without it.

Expected: `tea pulls ls --state closed --repo operinko-labs/homeops` lists 1439; `git ls-remote origin feature/matrix-synapse` prints nothing.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-10-16-matrix-synapse-design.md
git commit -m "docs(matrix): correct spec after rendering ESS 26.10.1"
git push origin main
```

---

### Task 1: Generate secrets and user prerequisites

**Files:** none in git. Output file: `<scratchpad>/matrix-vw-fields.txt` (mode 600; never print its contents into the transcript).

**Interfaces:**
- Produces: Vaultwarden item `matrix` (UUID recorded as `MATRIX_VW_ITEM` and used in Tasks 3 and 4) with fields `signing_key`, `macaroon`, `registration_shared_secret`, `encryption_secret`, `synapse_shared_secret`, `private_key_rsa` (base64 of PEM), `private_key_ecdsa_p256` (base64 of PEM), `livekit_secret`, `synapse_db_password`, `mas_db_password`, `s3_access_key`, `s3_secret_key`, `authentik_client_id`, `authentik_client_secret`, `smtp_username`, `smtp_password`. Versity bucket `synapse-media`. Authentik application slug `matrix`.

- [ ] **Step 1: Generate the values** (Git Bash or WSL; `SCRATCH` = this session's scratchpad)

```bash
set -euo pipefail
umask 077
out="$SCRATCH/matrix-vw-fields.txt"
rand() { openssl rand -hex 32; }
ver="a_$(openssl rand -hex 2)"
seed=$(openssl genpkey -algorithm ed25519 -outform DER | tail -c 32 | base64 | tr -d '=\n')
{
  echo "signing_key=ed25519 $ver $seed"
  echo "macaroon=$(rand)"
  echo "registration_shared_secret=$(rand)"
  echo "encryption_secret=$(rand)"
  echo "synapse_shared_secret=$(rand)"
  echo "private_key_rsa=$(openssl genrsa 4096 2>/dev/null | base64 -w0)"
  echo "private_key_ecdsa_p256=$(openssl ecparam -name prime256v1 -genkey -noout | base64 -w0)"
  echo "livekit_secret=$(rand)"
  echo "synapse_db_password=$(rand)"
  echo "mas_db_password=$(rand)"
  echo "s3_access_key=synapse-media"
  echo "s3_secret_key=$(rand)"
} > "$out"
wc -l "$out"
```

Expected: `12 …/matrix-vw-fields.txt`.

- [ ] **Step 2: Verify the signing key parses** (Docker Desktop is available locally)

```bash
key=$(grep '^signing_key=' "$out" | cut -d= -f2-)
docker run --rm --entrypoint python3 oci.element.io/synapse:v1.163.0 -c \
  "import sys,signedjson.key as k; a,v,s=sys.argv[1].split(); k.decode_signing_key_base64(a,v,s); print('ok')" "$key"
```

Expected: `ok`.

- [ ] **Step 3: User — Versity account and bucket**

Give the user these commands (root keys are in Vaultwarden item `9ae12023-3bdf-48b3-a626-f47044c6f43b`, fields `root_access_key`/`root_secret_key`; `S3_SK` = `s3_secret_key` from the file):

```bash
docker run --rm --network host --add-host s3.vaderrp.com:192.168.7.198 ghcr.io/versity/versitygw:v1.8.0 \
  admin -a "$S3_ROOT_AK" -s "$S3_ROOT_SK" --er https://s3.vaderrp.com:9002 \
  create-user -a synapse-media -s "$S3_SK" -r user
docker run --rm --network host --add-host s3.vaderrp.com:192.168.7.198 ghcr.io/versity/versitygw:v1.8.0 \
  admin -a "$S3_ROOT_AK" -s "$S3_ROOT_SK" --er https://s3.vaderrp.com:9002 \
  create-bucket --bucket synapse-media --owner synapse-media
```

Then the read-only offsite policy (same shape as the other buckets the `gdrive-sync` account reads), applied as root:

```bash
cat > "$SCRATCH/synapse-media-policy.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["gdrive-sync"]},
 "Action":["s3:GetObject","s3:ListBucket","s3:GetBucketLocation"],
 "Resource":["arn:aws:s3:::synapse-media","arn:aws:s3:::synapse-media/*"]}]}
EOF
docker run --rm --network host --add-host s3.vaderrp.com:192.168.7.198 \
  -e AWS_ACCESS_KEY_ID="$S3_ROOT_AK" -e AWS_SECRET_ACCESS_KEY="$S3_ROOT_SK" -e AWS_DEFAULT_REGION=us-east-1 \
  -v "$SCRATCH:/w" amazon/aws-cli:2.31.0 --endpoint-url https://s3.vaderrp.com:9000 \
  s3api put-bucket-policy --bucket synapse-media --policy file:///w/synapse-media-policy.json
```

Verify as `synapse-media`: an `aws s3 cp` of a small file to `s3://synapse-media/probe` then `aws s3 rm` succeeds; `aws s3 ls` shows only `synapse-media`.

- [ ] **Step 4: User — Stalwart account**

Create an account `matrix@erinko.fi` in Stalwart that may send mail. Put its login in `smtp_username` and a generated password (`openssl rand -hex 24`, hex so it needs no YAML quoting) in `smtp_password`.

- [ ] **Step 5: User — Authentik OAuth2 provider + application**

Provider: OAuth2/OpenID, confidential client, redirect URI (strict) `https://account.erinko.fi/upstream/callback/01M51PC86JKZ57T8BMGZCJC1F3`, signing key = the Authentik self-signed certificate (RS256), scopes `openid`, `profile`, `email`, "Include claims in id_token" on. Application: name `Matrix`, slug `matrix`, bound to that provider. Put Client ID/Secret into `authentik_client_id`/`authentik_client_secret`.

- [ ] **Step 6: User — Vaultwarden item and firewall**

Create Vaultwarden item `matrix` with all 16 fields as hidden custom fields (names exactly as listed under Interfaces). Then `POST /sync` on `bitwarden-eso-provider`. If UpCloud's firewall is enabled on the VPS, allow inbound 30001/tcp and 30002/udp.

Expected: user reports the item UUID → record it as `MATRIX_VW_ITEM`. Delete `matrix-vw-fields.txt` and `synapse-media-policy.json` from the scratchpad.

---

### Task 2: Synapse image build

**Files:**
- Create: `apps/synapse/Dockerfile`, `apps/synapse/VERSION`, `.forgejo/workflows/build-synapse.yaml`
- Modify: `.renovate/customManagers.json5`

**Interfaces:**
- Produces: `harbor.vaderrp.com/operinko-labs/synapse:v1.163.0` (used by Tasks 5 and 6).

- [ ] **Step 1: Dockerfile and VERSION**

`apps/synapse/VERSION`:

```
v1.163.0
```

`apps/synapse/Dockerfile`:

```dockerfile
# Version comes from apps/synapse/VERSION via the build workflow
ARG SYNAPSE_VERSION
FROM oci.element.io/synapse:${SYNAPSE_VERSION}
# renovate: datasource=pypi depName=synapse-s3-storage-provider
ARG S3_PROVIDER_VERSION=1.7.0
RUN pip install --no-cache-dir "synapse-s3-storage-provider==${S3_PROVIDER_VERSION}" \
 && python3 -c "import s3_storage_provider" \
 && command -v s3_media_upload
```

- [ ] **Step 2: Local build test**

```bash
docker build --build-arg SYNAPSE_VERSION=$(cat apps/synapse/VERSION) -t synapse-local apps/synapse
docker run --rm --entrypoint s3_media_upload synapse-local upload --help | grep -- --endpoint-url
docker rmi synapse-local
```

Expected: build succeeds; grep prints the `--endpoint-url ENDPOINT_URL` line.

- [ ] **Step 3: Workflow** — `.forgejo/workflows/build-synapse.yaml`

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/github-workflow.json
name: Build Synapse

on:
  push:
    branches:
      - main
    paths:
      - "apps/synapse/**"
      - ".forgejo/workflows/build-synapse.yaml"
  pull_request:
    branches:
      - main
    paths:
      - "apps/synapse/**"
  workflow_dispatch:
    inputs:
      force_push:
        description: "Force push image even on PR"
        required: false
        type: boolean
        default: false

jobs:
  build:
    runs-on: ubuntu-latest
    env:
      IMAGE_NAME: operinko-labs/synapse

    steps:
      - name: Checkout repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7

      - name: Resolve Harbor registry host
        run: |
          echo "REGISTRY=$(echo "${{ secrets.HARBOR_URL }}" | sed -E 's#^[a-zA-Z]+://##; s#/+$##')" >> "$GITHUB_ENV"

      - name: Read version from VERSION file
        id: version
        run: |
          VERSION=$(cat apps/synapse/VERSION | tr -d '[:space:]')
          echo "version=${VERSION}" >> $GITHUB_OUTPUT
          echo "Version: ${VERSION}"

      - name: Log in to Harbor
        if: github.event_name != 'pull_request' || inputs.force_push
        uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ secrets.HARBOR_USERNAME }}
          password: ${{ secrets.HARBOR_PASSWORD }}

      - name: Check if version already exists
        id: check
        run: |
          if docker manifest inspect ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.version.outputs.version }} > /dev/null 2>&1; then
            echo "exists=true" >> $GITHUB_OUTPUT
            echo "::notice::Version ${{ steps.version.outputs.version }} already exists, skipping build"
          else
            echo "exists=false" >> $GITHUB_OUTPUT
            echo "Version ${{ steps.version.outputs.version }} does not exist, will build"
          fi

      - name: Set up Docker Buildx
        if: steps.check.outputs.exists != 'true' || github.event_name == 'workflow_dispatch'
        uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4

      - name: Extract metadata
        if: steps.check.outputs.exists != 'true' || github.event_name == 'workflow_dispatch'
        id: meta
        uses: docker/metadata-action@dc802804100637a589fabce1cb79ff13a1411302 # v6
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=raw,value=${{ steps.version.outputs.version }}
            type=sha,prefix=sha-
            type=raw,value=latest,enable={{is_default_branch}}

      - name: Build and push Docker image
        if: steps.check.outputs.exists != 'true' || github.event_name == 'workflow_dispatch'
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7
        with:
          context: apps/synapse
          file: apps/synapse/Dockerfile
          # inputs.force_push is empty (not a boolean) on pull_request events;
          # compare explicitly so the expression always yields a boolean
          push: ${{ github.event_name != 'pull_request' || inputs.force_push == true }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          platforms: linux/amd64
          build-args: |
            SYNAPSE_VERSION=${{ steps.version.outputs.version }}
```

Before writing it, diff the action pins against `.forgejo/workflows/build-tempest-mcp.yaml` and use whatever that file pins at the time (Renovate may have bumped them).

- [ ] **Step 4: Renovate** — in `.renovate/customManagers.json5`

Add `"/(^|/)Dockerfile$/",` to the first manager's `managerFilePatterns` (so the `# renovate:` ARG pin is tracked), and append this manager to `customManagers`:

```json5
    {
      customType: "regex",
      // Upstream base for the custom Synapse image. Once CI has pushed the
      // new Harbor tag, SYNAPSE_TAG in kubernetes/apps/matrix/matrix-stack/ks.yaml
      // follows via its own `# renovate:` comment.
      description: "Synapse image VERSION",
      managerFilePatterns: ["/^apps/synapse/VERSION$/"],
      matchStrings: ["^(?<currentValue>v\\S+)"],
      depNameTemplate: "oci.element.io/synapse",
      datasourceTemplate: "docker",
    },
```

Verify JSON5 parses: `node -e "require('json5')" 2>/dev/null && node -e "console.log(Object.keys(require('json5').parse(require('fs').readFileSync('.renovate/customManagers.json5','utf8'))))"` — if `json5` isn't installed, `npx --yes json5 -c .renovate/customManagers.json5` (writes a `.json` next to it; delete that afterwards).

- [ ] **Step 5: Commit, push, verify the build**

```bash
git add apps/synapse .forgejo/workflows/build-synapse.yaml .renovate/customManagers.json5
git commit -m "feat(synapse): custom image with synapse-s3-storage-provider"
git push origin main
```

Expected: the "Build Synapse" run on Forgejo succeeds (check via the commit-status API, see memory `project_forgejo_actions_logs_access`); `docker manifest inspect harbor.vaderrp.com/operinko-labs/synapse:v1.163.0` returns a manifest.

---

### Task 3: Postgres roles and databases

**Files:**
- Modify: `kubernetes/apps/database/cloudnative-pg/app/cluster/cluster18.yaml` (`managed.roles`)
- Create: `kubernetes/apps/database/cloudnative-pg/app/cluster/database-matrix.yaml`, `kubernetes/apps/database/cloudnative-pg/app/cluster/external-secret-matrix.yaml`
- Modify: `kubernetes/apps/database/cloudnative-pg/app/cluster/kustomization.yaml`

**Interfaces:**
- Consumes: `MATRIX_VW_ITEM` (Task 1).
- Produces: databases `synapse` and `mas` on `postgres18`, owned by roles of the same names.

- [ ] **Step 1: Check headroom**

```bash
kubectl -n database exec postgres18-1 -c postgres -- df -h /var/lib/postgresql/data
```

If usage is above 60 % of 10Gi, change `storage.size: 10Gi` → `20Gi` in `cluster18.yaml` as part of this task.

- [ ] **Step 2: Roles** — append to `managed.roles` in `cluster18.yaml` (after `autoposter`):

```yaml
      - name: synapse
        ensure: present
        login: true
        superuser: false
        createdb: false
        createrole: false
        passwordSecret:
          name: postgres18-synapse-user
      - name: mas
        ensure: present
        login: true
        superuser: false
        createdb: false
        createrole: false
        passwordSecret:
          name: postgres18-mas-user
```

- [ ] **Step 3: `external-secret-matrix.yaml`** (replace `MATRIX_VW_ITEM` with the real UUID)

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: postgres18-synapse-user
  namespace: database
spec:
  refreshInterval: 1h
  target:
    name: postgres18-synapse-user
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      type: kubernetes.io/basic-auth
      metadata:
        labels:
          cnpg.io/reload: "true"
      data:
        username: synapse
        password: "{{ .db_password }}"
  data:
    - secretKey: db_password
      sourceRef:
        storeRef:
          name: bitwarden-fields
          kind: ClusterSecretStore
      remoteRef:
        key: MATRIX_VW_ITEM
        property: synapse_db_password
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: postgres18-mas-user
  namespace: database
spec:
  refreshInterval: 1h
  target:
    name: postgres18-mas-user
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      type: kubernetes.io/basic-auth
      metadata:
        labels:
          cnpg.io/reload: "true"
      data:
        username: mas
        password: "{{ .db_password }}"
  data:
    - secretKey: db_password
      sourceRef:
        storeRef:
          name: bitwarden-fields
          kind: ClusterSecretStore
      remoteRef:
        key: MATRIX_VW_ITEM
        property: mas_db_password
```

- [ ] **Step 4: `database-matrix.yaml`**

```yaml
---
# yaml-language-server: $schema=https://crd.movishell.pl/postgresql.cnpg.io/database_v1.json
# Synapse refuses to start on a database whose collation/ctype is not C
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: synapse-db
  namespace: database
spec:
  name: synapse
  owner: synapse
  cluster:
    name: postgres18
  encoding: UTF8
  localeCollate: C
  localeCType: C
  template: template0
---
# yaml-language-server: $schema=https://crd.movishell.pl/postgresql.cnpg.io/database_v1.json
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: mas-db
  namespace: database
spec:
  name: mas
  owner: mas
  cluster:
    name: postgres18
```

- [ ] **Step 5: kustomization** — add `./database-matrix.yaml` after `./database-autoposter.yaml` and `./external-secret-matrix.yaml` after `./external-secret-stalwart.yaml`. Then `kubectl kustomize kubernetes/apps/database/cloudnative-pg/app/cluster > /dev/null` must succeed.

- [ ] **Step 6: Commit, push, reconcile, verify**

```bash
git add kubernetes/apps/database/cloudnative-pg/app/cluster
git commit -m "feat(database): synapse and mas roles and databases on postgres18"
git push origin main
flux -n database reconcile ks cloudnative-pg --with-source
```

Verify:

```bash
kubectl -n database get externalsecret postgres18-synapse-user postgres18-mas-user   # STATUS SecretSynced
kubectl -n database get database synapse-db mas-db                                    # APPLIED true
kubectl -n database exec postgres18-1 -c postgres -- psql -tAc \
  "select datname, datcollate, datctype, pg_get_userbyid(datdba) from pg_database where datname in ('synapse','mas')"
```

Expected: `synapse|C|C|synapse` and `mas|<cluster default>|<cluster default>|mas`.

---

### Task 4: `matrix` namespace, secrets and media PVC

**Files:**
- Create: `kubernetes/apps/matrix/kustomization.yaml`, `kubernetes/apps/matrix/namespace.yaml`, `kubernetes/apps/matrix/matrix-stack/ks.yaml`, `kubernetes/apps/matrix/matrix-stack/app/kustomization.yaml`, `kubernetes/apps/matrix/matrix-stack/app/external-secret.yaml`

**Interfaces:**
- Consumes: `MATRIX_VW_ITEM`.
- Produces: Secret `matrix-secrets` in `matrix` with keys `synapse_db_password`, `mas_db_password`, `signing_key`, `macaroon`, `registration_shared_secret`, `encryption_secret`, `synapse_shared_secret`, `private_key_rsa`, `private_key_ecdsa_p256`, `livekit_secret`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `database.yaml`, `synapse-s3.yaml`, `mas-auth.yaml`. PVC `synapse` (local-path, from the volsync component). Flux Kustomization `matrix-stack` in namespace `matrix`.

- [ ] **Step 1: Namespace wiring**

`kubernetes/apps/matrix/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: matrix
resources:
  - ./namespace.yaml
  - ./matrix-stack/ks.yaml
components:
  - ../../components/common
```

`kubernetes/apps/matrix/namespace.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
  name: _
  labels:
    goldilocks.fairwinds.com/vpa-update-mode: "auto"
    goldilocks.fairwinds.com/enabled: "true"
```

- [ ] **Step 2: `matrix-stack/ks.yaml`**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: matrix-stack
  namespace: flux-system
spec:
  targetNamespace: matrix
  commonMetadata:
    labels:
      app.kubernetes.io/name: matrix-stack
  path: "./kubernetes/apps/matrix/matrix-stack/app"
  prune: true
  dependsOn:
    - name: volsync
      namespace: storage
    - name: cloudnative-pg
      namespace: database
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  wait: false
  components:
    - ../../../../components/volsync-kopia
  interval: 30m
  retryInterval: 1m
  timeout: 15m
  postBuild:
    substitute:
      # PVC is the Synapse media cache; the chart mounts it via existingClaim
      APP: synapse
      VOLSYNC_COPYMETHOD: Direct
      VOLSYNC_CAPACITY: 10Gi
      VOLSYNC_STORAGECLASS: local-path
      # ESS runs Synapse as 10091:10091
      VOLSYNC_PUID: "10091"
      VOLSYNC_PGID: "10091"
      # Custom image (apps/synapse); used by the HelmRelease and the drain CronJob
      # renovate: datasource=docker depName=harbor.vaderrp.com/operinko-labs/synapse
      SYNAPSE_TAG: v1.163.0
```

Check the `dependsOn` names/namespaces against `flux get ks -A | grep -E 'volsync|cloudnative-pg'` and fix them if they differ.

- [ ] **Step 3: `app/external-secret.yaml`** (replace `MATRIX_VW_ITEM`)

Note the Go-template escape for MAS's own Jinja templates: `{{ "{{ user.name }}" }}` renders literally as `{{ user.name }}`.

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: matrix-secrets
spec:
  refreshInterval: 1h
  target:
    name: matrix-secrets
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      data:
        synapse_db_password: "{{ .synapse_db_password }}"
        mas_db_password: "{{ .mas_db_password }}"
        signing_key: "{{ .signing_key }}"
        macaroon: "{{ .macaroon }}"
        registration_shared_secret: "{{ .registration_shared_secret }}"
        encryption_secret: "{{ .encryption_secret }}"
        synapse_shared_secret: "{{ .synapse_shared_secret }}"
        # Stored base64-encoded in Vaultwarden: custom fields are single-line
        private_key_rsa: "{{ .private_key_rsa | b64dec }}"
        private_key_ecdsa_p256: "{{ .private_key_ecdsa_p256 | b64dec }}"
        livekit_secret: "{{ .livekit_secret }}"
        # Drain CronJob (boto3 env + psycopg2 args for s3_media_upload)
        AWS_ACCESS_KEY_ID: "{{ .s3_access_key }}"
        AWS_SECRET_ACCESS_KEY: "{{ .s3_secret_key }}"
        database.yaml: |
          user: synapse
          password: "{{ .synapse_db_password }}"
          database: synapse
          host: postgres18-rw.database.svc.cluster.local
          port: 5432
        synapse-s3.yaml: |
          media_storage_providers:
            - module: s3_storage_provider.S3StorageProviderBackend
              store_local: true
              store_remote: true
              store_synchronous: true
              config:
                bucket: synapse-media
                region_name: us-east-1
                endpoint_url: https://s3.vaderrp.com:9000
                access_key_id: "{{ .s3_access_key }}"
                secret_access_key: "{{ .s3_secret_key }}"
        mas-auth.yaml: |
          passwords:
            enabled: true
          email:
            from: '"Matrix" <matrix@erinko.fi>'
            reply_to: '"Matrix" <matrix@erinko.fi>'
            transport: smtp
            mode: starttls
            # Public name, not the Service: Stalwart's cert only covers its
            # public hostnames and MAS verifies TLS
            hostname: mail.erinko.fi
            port: 587
            username: "{{ .smtp_username }}"
            password: "{{ .smtp_password }}"
          upstream_oauth2:
            providers:
              - id: 01M51PC86JKZ57T8BMGZCJC1F3
                human_name: Authentik
                issuer: https://auth.vaderrp.com/application/o/matrix/
                client_id: "{{ .authentik_client_id }}"
                client_secret: "{{ .authentik_client_secret }}"
                token_endpoint_auth_method: client_secret_basic
                scope: "openid profile email"
                claims_imports:
                  localpart:
                    action: require
                    template: "{{ "{{ user.preferred_username }}" }}"
                  displayname:
                    action: suggest
                    template: "{{ "{{ user.name }}" }}"
                  email:
                    action: suggest
                    template: "{{ "{{ user.email }}" }}"
                    set_email_verification: always
  data:
    - secretKey: synapse_db_password
      sourceRef: &store
        storeRef:
          name: bitwarden-fields
          kind: ClusterSecretStore
      remoteRef: {key: &item MATRIX_VW_ITEM, property: synapse_db_password}
    - {secretKey: mas_db_password, sourceRef: *store, remoteRef: {key: *item, property: mas_db_password}}
    - {secretKey: signing_key, sourceRef: *store, remoteRef: {key: *item, property: signing_key}}
    - {secretKey: macaroon, sourceRef: *store, remoteRef: {key: *item, property: macaroon}}
    - {secretKey: registration_shared_secret, sourceRef: *store, remoteRef: {key: *item, property: registration_shared_secret}}
    - {secretKey: encryption_secret, sourceRef: *store, remoteRef: {key: *item, property: encryption_secret}}
    - {secretKey: synapse_shared_secret, sourceRef: *store, remoteRef: {key: *item, property: synapse_shared_secret}}
    - {secretKey: private_key_rsa, sourceRef: *store, remoteRef: {key: *item, property: private_key_rsa}}
    - {secretKey: private_key_ecdsa_p256, sourceRef: *store, remoteRef: {key: *item, property: private_key_ecdsa_p256}}
    - {secretKey: livekit_secret, sourceRef: *store, remoteRef: {key: *item, property: livekit_secret}}
    - {secretKey: s3_access_key, sourceRef: *store, remoteRef: {key: *item, property: s3_access_key}}
    - {secretKey: s3_secret_key, sourceRef: *store, remoteRef: {key: *item, property: s3_secret_key}}
    - {secretKey: authentik_client_id, sourceRef: *store, remoteRef: {key: *item, property: authentik_client_id}}
    - {secretKey: authentik_client_secret, sourceRef: *store, remoteRef: {key: *item, property: authentik_client_secret}}
    - {secretKey: smtp_username, sourceRef: *store, remoteRef: {key: *item, property: smtp_username}}
    - {secretKey: smtp_password, sourceRef: *store, remoteRef: {key: *item, property: smtp_password}}
```

Flow mappings are fine under the repo's `.yamllint` (default `braces` rule: no spaces inside `{}`), so keep them without inner spaces. Run `yamllint kubernetes/apps/matrix` (or the `lint.yaml` workflow's command) before committing.

- [ ] **Step 4: `app/kustomization.yaml`**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - external-secret.yaml
```

- [ ] **Step 5: Render, commit, push, verify**

```bash
kubectl kustomize kubernetes/apps/matrix > /dev/null
kubectl kustomize kubernetes/apps/matrix/matrix-stack/app > /dev/null
git add kubernetes/apps/matrix
git commit -m "feat(matrix): namespace, secrets and media PVC"
git push origin main
flux reconcile ks cluster-apps -n flux-system --with-source
```

Verify:

```bash
flux get ks -A | grep matrix-stack                                   # Ready True
kubectl -n matrix get externalsecret matrix-secrets                  # SecretSynced
kubectl -n matrix get secret matrix-secrets -o json | jq -r '.data | keys[]'   # the 15 keys listed under Interfaces
kubectl -n matrix get secret matrix-secrets -o jsonpath='{.data.mas-auth\.yaml}' | base64 -d | grep 'template:'
kubectl -n matrix get secret matrix-secrets -o jsonpath='{.data.private_key_rsa}' | base64 -d | head -1
kubectl -n matrix get pvc synapse                                    # Pending (WaitForFirstConsumer) is expected
```

Expected: the `template:` lines read `"{{ user.preferred_username }}"` etc. literally; the RSA key starts with `-----BEGIN PRIVATE KEY-----`.

---

### Task 5: ESS core stack, routes and apex listener (MatrixRTC off)

**Files:**
- Create: `kubernetes/apps/matrix/matrix-stack/app/ocirepository.yaml`, `kubernetes/apps/matrix/matrix-stack/app/helmrelease.yaml`, `kubernetes/apps/matrix/matrix-stack/app/httproute.yaml`
- Modify: `kubernetes/apps/matrix/matrix-stack/app/kustomization.yaml`, `kubernetes/apps/network/gateways/app/gateway-public.yaml`

**Interfaces:**
- Consumes: Secret `matrix-secrets`, PVC `synapse`, DBs `synapse`/`mas`, `SYNAPSE_TAG` substitution (Task 4), image `harbor.vaderrp.com/operinko-labs/synapse:v1.163.0` (Task 2).
- Produces (chart Services used by routes): `matrix-synapse:8008` (HAProxy → Synapse), `matrix-matrix-authentication-service:8080`, `matrix-element-web:80`, `matrix-well-known:8010`; StatefulSet `matrix-synapse-main` mounting PVC `synapse` at `/media` (media store `/media/media_store`); Deployment `matrix-matrix-authentication-service`.

- [ ] **Step 1: `ocirepository.yaml`**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: matrix-stack
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 26.10.1
  url: oci://ghcr.io/element-hq/ess-helm/matrix-stack
```

- [ ] **Step 2: `helmrelease.yaml`**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: matrix
spec:
  interval: 30m
  # First install runs the init-secrets, config-check and DB migration hooks
  timeout: 15m
  chartRef:
    kind: OCIRepository
    name: matrix-stack
  maxHistory: 2
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  postRenderers:
    - kustomize:
        patches:
          # Traefik runs with kubernetesIngress disabled; routing lives in
          # httproute.yaml instead
          - target:
              kind: Ingress
            patch: |
              $patch: delete
              apiVersion: networking.k8s.io/v1
              kind: Ingress
              metadata:
                name: unused
  values:
    serverName: erinko.fi

    # Only the MatrixRTC appservice registration is left for it to generate;
    # everything that must survive comes from matrix-secrets
    initSecrets:
      enabled: true

    postgres:
      enabled: false
    hookshot:
      enabled: false
    elementAdmin:
      enabled: false
    matrixRTC:
      enabled: false

    synapse:
      image:
        registry: harbor.vaderrp.com
        repository: operinko-labs/synapse
        tag: ${SYNAPSE_TAG}
      ingress:
        host: matrix.erinko.fi
      postgres:
        host: postgres18-rw.database.svc.cluster.local
        port: 5432
        user: synapse
        database: synapse
        sslMode: prefer
        password:
          secret: matrix-secrets
          secretKey: synapse_db_password
      media:
        storage:
          existingClaim: synapse
      signingKey:
        secret: matrix-secrets
        secretKey: signing_key
      macaroon:
        secret: matrix-secrets
        secretKey: macaroon
      registrationSharedSecret:
        secret: matrix-secrets
        secretKey: registration_shared_secret
      additional:
        s3:
          configSecret: matrix-secrets
          configSecretKey: synapse-s3.yaml

    matrixAuthenticationService:
      ingress:
        host: account.erinko.fi
      postgres:
        host: postgres18-rw.database.svc.cluster.local
        port: 5432
        user: mas
        database: mas
        sslMode: prefer
        password:
          secret: matrix-secrets
          secretKey: mas_db_password
      encryptionSecret:
        secret: matrix-secrets
        secretKey: encryption_secret
      synapseSharedSecret:
        secret: matrix-secrets
        secretKey: synapse_shared_secret
      privateKeys:
        rsa:
          secret: matrix-secrets
          secretKey: private_key_rsa
        ecdsaPrime256v1:
          secret: matrix-secrets
          secretKey: private_key_ecdsa_p256
      additional:
        auth:
          configSecret: matrix-secrets
          configSecretKey: mas-auth.yaml

    elementWeb:
      ingress:
        host: chat.erinko.fi
```

- [ ] **Step 3: Render the chart with these values and confirm names**

```bash
yq '.spec.values' kubernetes/apps/matrix/matrix-stack/app/helmrelease.yaml > "$SCRATCH/ess-values.yaml"
helm.exe template matrix oci://ghcr.io/element-hq/ess-helm/matrix-stack --version 26.10.1 -n matrix -f "$SCRATCH/ess-values.yaml" \
  | yq 'select(.kind == "Service") | .metadata.name + " " + (.spec.ports | map(.port) | join(","))'
```

The rendered Synapse image reads `harbor.vaderrp.com/operinko-labs/synapse:${SYNAPSE_TAG}` here; Flux substitutes it. Expected (subset): `matrix-synapse 8008,8009`, `matrix-matrix-authentication-service 8080,8081`, `matrix-element-web 80`, `matrix-well-known 8010`. Use standalone `helm.exe` (WSL helm hangs). If names differ, use the rendered names in Step 4.

- [ ] **Step 4: `httproute.yaml`** — mirrors the chart's Ingress rules (MAS-handled login/refresh/logout paths on the homeserver host go to MAS; Gateway API picks the longest matching prefix).

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: synapse
  labels:
    route.scope: external
  annotations:
    external-dns.alpha.kubernetes.io/target: external.vaderrp.com
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: gateway-public
      namespace: network
  hostnames:
    - matrix.erinko.fi
  rules:
    # Legacy auth endpoints are served by MAS (delegated auth)
    - matches:
        - path: {type: PathPrefix, value: /_matrix/client/api/v1/login}
        - path: {type: PathPrefix, value: /_matrix/client/api/v1/refresh}
        - path: {type: PathPrefix, value: /_matrix/client/api/v1/logout}
        - path: {type: PathPrefix, value: /_matrix/client/r0/login}
        - path: {type: PathPrefix, value: /_matrix/client/r0/refresh}
        - path: {type: PathPrefix, value: /_matrix/client/r0/logout}
        - path: {type: PathPrefix, value: /_matrix/client/v3/login}
        - path: {type: PathPrefix, value: /_matrix/client/v3/refresh}
        - path: {type: PathPrefix, value: /_matrix/client/v3/logout}
        - path: {type: PathPrefix, value: /_matrix/client/unstable/login}
        - path: {type: PathPrefix, value: /_matrix/client/unstable/refresh}
        - path: {type: PathPrefix, value: /_matrix/client/unstable/logout}
      filters: &warp
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: traefik-warp
      backendRefs:
        - name: matrix-matrix-authentication-service
          port: 8080
    - matches:
        - path: {type: PathPrefix, value: /_matrix}
        - path: {type: PathPrefix, value: /_synapse}
      filters: *warp
      backendRefs:
        - name: matrix-synapse
          port: 8008
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: matrix-authentication-service
  labels:
    route.scope: external
  annotations:
    external-dns.alpha.kubernetes.io/target: external.vaderrp.com
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: gateway-public
      namespace: network
  hostnames:
    - account.erinko.fi
  rules:
    - matches:
        - path: {type: PathPrefix, value: /}
      filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: traefik-warp
      backendRefs:
        - name: matrix-matrix-authentication-service
          port: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: element-web
  labels:
    route.scope: external
  annotations:
    external-dns.alpha.kubernetes.io/target: external.vaderrp.com
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: gateway-public
      namespace: network
  hostnames:
    - chat.erinko.fi
  rules:
    - matches:
        - path: {type: PathPrefix, value: /}
      filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: traefik-warp
      backendRefs:
        - name: matrix-element-web
          port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: well-known
  labels:
    route.scope: external
  annotations:
    external-dns.alpha.kubernetes.io/target: external.vaderrp.com
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: gateway-public
      namespace: network
  hostnames:
    - erinko.fi
  rules:
    # ESS HAProxy serves /.well-known/matrix/* and redirects everything else
    # to chat.erinko.fi
    - matches:
        - path: {type: PathPrefix, value: /}
      filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: traefik-warp
      backendRefs:
        - name: matrix-well-known
          port: 8010
```

Confirm the `traefik-warp` Middleware exists in `matrix` after Task 4 (`kubectl -n matrix get middlewares.traefik.io`); it comes from `components/common`.

- [ ] **Step 5: Apex listener** — in `gateway-public.yaml`, insert after the `https-erinko` listener:

```yaml
    - name: https-erinko-apex
      protocol: HTTPS
      port: 443
      hostname: "erinko.fi"
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: erinko-fi-production-tls
```

- [ ] **Step 6: kustomization** — `app/kustomization.yaml` resources become `external-secret.yaml`, `helmrelease.yaml`, `httproute.yaml`, `ocirepository.yaml`. Render both changed dirs with `kubectl kustomize`.

- [ ] **Step 7: Commit, push, reconcile**

```bash
git add kubernetes/apps/matrix kubernetes/apps/network/gateways/app/gateway-public.yaml
git commit -m "feat(matrix): ESS stack with Synapse, MAS and Element Web"
git push origin main
flux -n network reconcile ks gateways --with-source
flux -n matrix reconcile ks matrix-stack --with-source
```

(Find the real ks names with `flux get ks -A | grep -E 'gateways|matrix'`.)

- [ ] **Step 8: Verify the deployment**

```bash
flux -n matrix get hr matrix                      # Ready True
kubectl -n matrix get pods                        # all Running/Completed
kubectl -n matrix get ingress                     # No resources found
kubectl -n network get gateway gateway-public -o yaml | yq '.status.listeners[] | select(.name == "https-erinko-apex") | .conditions[] | select(.type == "Programmed") | .status'   # True
kubectl -n matrix logs sts/matrix-synapse-main | grep -i -E 's3|storage provider|error' | head
```

From WSL:

```bash
curl -s https://erinko.fi/.well-known/matrix/server
curl -s https://erinko.fi/.well-known/matrix/client
curl -s -o /dev/null -w '%{http_code}\n' https://matrix.erinko.fi/_matrix/client/versions
curl -s https://account.erinko.fi/.well-known/openid-configuration | jq -r .issuer
curl -s -o /dev/null -w '%{http_code}\n' https://chat.erinko.fi/
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://erinko.fi/
```

Expected: `{"m.server":"matrix.erinko.fi:443"}` (or with spaces); client JSON has `m.homeserver.base_url` `https://matrix.erinko.fi` and an `org.matrix.msc2965.authentication` issuer `https://account.erinko.fi/`; `200`; `https://account.erinko.fi/`; `200`; `30x https://chat.erinko.fi…`.

- [ ] **Step 9: Verify accounts and media (with the user)**

```bash
kubectl -n matrix exec deploy/matrix-matrix-authentication-service -- mas-cli manage register-user --help
```

Then register the user's admin account with the flags that help shows (typically `mas-cli manage register-user <username> --password <pw> --admin --yes`); the user chooses the username and password. Check, with the user:
1. Log in at `https://chat.erinko.fi` with the local account.
2. Log in on Element X (homeserver `erinko.fi`) with "Authentik" → lands as `@<authentik username>:erinko.fi`.
3. Upload an image in a room, then list the bucket as `synapse-media` (aws-cli container as in Task 1 Step 3): an object under `local_content/…` exists.
4. `curl -s 'https://federationtester.matrix.org/api/report?server_name=erinko.fi' | jq .FederationOK` → `true`. If the report shows a Cloudflare 1010, the user adds a free-plan Configuration Rule turning Browser Integrity Check off for `matrix.erinko.fi`, then retest.
5. Join a small federated room (not `#matrix:matrix.org` — huge rooms bloat the database) and exchange a message.
6. Password reset mail for the local account arrives (exercises MAS → `mail.erinko.fi:587`). If MAS logs a TLS or connect error, record it and continue; mail is not blocking for chat.

---

### Task 6: S3 drain CronJob and offsite copy

**Files:**
- Create: `kubernetes/apps/matrix/matrix-stack/app/cronjob-s3-drain.yaml`
- Modify: `kubernetes/apps/matrix/matrix-stack/app/kustomization.yaml`, `kubernetes/apps/storage/minio-gdrive-sync/app/cronjob.yaml`

**Interfaces:**
- Consumes: PVC `synapse` (mounted `/media`, media store `/media/media_store`), Secret keys `database.yaml`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`; `SYNAPSE_TAG` substitution (Task 4).

- [ ] **Step 1: `cronjob-s3-drain.yaml`**

```yaml
---
# Synapse writes media to S3 synchronously and also keeps a local copy
# (store_local). This removes local copies not accessed for 30 days once they
# are confirmed in S3. Manual run:
#   kubectl -n matrix create job --from=cronjob/synapse-s3-drain synapse-s3-drain-manual
apiVersion: batch/v1
kind: CronJob
metadata:
  name: synapse-s3-drain
spec:
  schedule: "30 3 * * *"
  timeZone: Europe/Helsinki
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          # RWO local-path PVC: must land on Synapse's node
          affinity:
            podAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchLabels:
                      app.kubernetes.io/name: synapse-main
                  topologyKey: kubernetes.io/hostname
          securityContext:
            runAsNonRoot: true
            runAsUser: 10091
            runAsGroup: 10091
            fsGroup: 10091
            seccompProfile: {type: RuntimeDefault}
          containers:
            - name: drain
              image: harbor.vaderrp.com/operinko-labs/synapse:${SYNAPSE_TAG}
              workingDir: /work
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  cp /secrets/database.yaml /work/database.yaml
                  s3_media_upload --no-progress update /media/media_store 30d
                  s3_media_upload --no-progress upload /media/media_store synapse-media \
                    --delete --endpoint-url https://s3.vaderrp.com:9000
              env:
                - {name: AWS_DEFAULT_REGION, value: us-east-1}
                - name: AWS_ACCESS_KEY_ID
                  valueFrom: {secretKeyRef: {name: matrix-secrets, key: AWS_ACCESS_KEY_ID}}
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom: {secretKeyRef: {name: matrix-secrets, key: AWS_SECRET_ACCESS_KEY}}
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities: {drop: ["ALL"]}
              resources:
                requests: {cpu: 10m, memory: 128Mi}
                limits: {memory: 512Mi}
              volumeMounts:
                - {name: media, mountPath: /media}
                - {name: work, mountPath: /work}
                - name: secrets
                  mountPath: /secrets/database.yaml
                  subPath: database.yaml
                  readOnly: true
          volumes:
            - name: media
              persistentVolumeClaim:
                claimName: synapse
            - name: work
              emptyDir: {}
            - name: secrets
              secret:
                secretName: matrix-secrets
```

`app.kubernetes.io/name: synapse-main` is the label the chart (26.10.1) puts on the Synapse pod; confirm with `kubectl -n matrix get pod -l app.kubernetes.io/name=synapse-main` before committing.

- [ ] **Step 2: Offsite** — in `kubernetes/apps/storage/minio-gdrive-sync/app/cronjob.yaml` change `value: "cloudnative-pg mariadb volsync parsedmarc n8n"` to `value: "cloudnative-pg mariadb volsync parsedmarc n8n synapse-media"`.

- [ ] **Step 3: kustomization** — add `cronjob-s3-drain.yaml` to `app/kustomization.yaml`; render both changed dirs.

- [ ] **Step 4: Commit, push, verify**

```bash
git add kubernetes/apps/matrix kubernetes/apps/storage/minio-gdrive-sync/app/cronjob.yaml
git commit -m "feat(matrix): drain Synapse media cache to S3, add bucket to offsite sync"
git push origin main
flux -n matrix reconcile ks matrix-stack --with-source
kubectl -n matrix create job --from=cronjob/synapse-s3-drain synapse-s3-drain-manual
kubectl -n matrix wait --for=condition=complete job/synapse-s3-drain-manual --timeout=10m
kubectl -n matrix logs job/synapse-s3-drain-manual
kubectl -n matrix delete job synapse-s3-drain-manual
```

Expected: job completes; log shows the update/upload summary (nothing older than 30 days yet, so 0 deletions is correct). Offsite: after the next minio-gdrive-sync run, its log contains `=== syncing synapse-media ===` without errors.

---

### Task 7: MatrixRTC calls through the VPS

**Files:**
- Modify: `kubernetes/apps/matrix/matrix-stack/app/helmrelease.yaml`, `kubernetes/apps/matrix/matrix-stack/app/httproute.yaml`
- Modify: `vps/config/haproxy.cfg`, `vps/apply.sh`, `vps/mod.just`
- Create: `vps/config/homeops-rtc.nft`, `vps/config/homeops-rtc-nat.service`

**Interfaces:**
- Consumes: `livekit_secret` in `matrix-secrets`.
- Produces: Services `matrix-matrix-rtc-sfu-tcp` (30001/TCP) and `matrix-matrix-rtc-sfu-muxed-udp` (30002/UDP) on externalIP `172.16.8.12`, `externalTrafficPolicy: Local`; `matrix-matrix-rtc-authorisation-service:8080`, `matrix-matrix-rtc-sfu:7880`.

- [ ] **Step 1: HelmRelease** — replace

```yaml
    matrixRTC:
      enabled: false
```

with

```yaml
    matrixRTC:
      enabled: true
      ingress:
        host: mrtc.erinko.fi
      livekitAuth:
        secret:
          secret: matrix-secrets
          secretKey: livekit_secret
      sfu:
        # Media reaches the SFU via the VPS; clients must be told its address
        useStunToDiscoverPublicIP: false
        manualIP: 212.147.241.182
        # Only talos7 has wg0 (the tunnel to the VPS)
        nodeSelector:
          kubernetes.io/hostname: talos7
        exposedServices:
          rtcTcp:
            portType: ClusterIP
            externalIPs: ["172.16.8.12"]
          rtcMuxedUdp:
            portType: ClusterIP
            externalIPs: ["172.16.8.12"]
```

and add to `postRenderers[0].kustomize.patches`:

```yaml
          # Cilium DSR: only talos7 can answer over wg0, so tunnel traffic must
          # stay on the local SFU (same reason as service-traefik-wg.yaml). The
          # chart only sets this for NodePort/LoadBalancer.
          - target:
              kind: Service
              name: matrix-matrix-rtc-sfu-(tcp|muxed-udp)
            patch: |
              - op: add
                path: /spec/externalTrafficPolicy
                value: Local
```

- [ ] **Step 2: Render check**

```bash
yq '.spec.values' kubernetes/apps/matrix/matrix-stack/app/helmrelease.yaml > "$SCRATCH/ess-values.yaml"
helm.exe template matrix oci://ghcr.io/element-hq/ess-helm/matrix-stack --version 26.10.1 -n matrix -f "$SCRATCH/ess-values.yaml" \
  | yq 'select(.kind == "Service" and (.metadata.name | test("rtc"))) | .metadata.name + " " + (.spec.externalIPs // [] | join(",")) + " " + (.spec.ports | map(.port + "/" + (.protocol // "TCP")) | join(","))'
```

Expected: `matrix-matrix-rtc-sfu-tcp 172.16.8.12 30001/TCP`, `matrix-matrix-rtc-sfu-muxed-udp 172.16.8.12 30002/UDP`, `matrix-matrix-rtc-sfu  7880/TCP,6789/TCP`, `matrix-matrix-rtc-authorisation-service  8080/TCP`.

- [ ] **Step 3: Route** — append to `httproute.yaml`:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: matrix-rtc
  labels:
    route.scope: external
  annotations:
    external-dns.alpha.kubernetes.io/target: external.vaderrp.com
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: gateway-public
      namespace: network
  hostnames:
    - mrtc.erinko.fi
  rules:
    - matches:
        - path: {type: PathPrefix, value: /sfu/get}
        - path: {type: PathPrefix, value: /get_token}
        - path: {type: PathPrefix, value: /delegate_delayed_leave}
      filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: traefik-warp
      backendRefs:
        - name: matrix-matrix-rtc-authorisation-service
          port: 8080
    # LiveKit signalling websocket
    - matches:
        - path: {type: PathPrefix, value: /}
      filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: traefik-warp
      backendRefs:
        - name: matrix-matrix-rtc-sfu
          port: 7880
```

- [ ] **Step 4: Commit, push, verify the cluster side**

```bash
kubectl kustomize kubernetes/apps/matrix/matrix-stack/app > /dev/null
git add kubernetes/apps/matrix
git commit -m "feat(matrix): MatrixRTC with LiveKit on talos7 behind the VPS"
git push origin main
flux -n matrix reconcile ks matrix-stack --with-source
kubectl -n matrix get pods -o wide | grep rtc-sfu                         # Running on talos7
kubectl -n matrix get svc matrix-matrix-rtc-sfu-tcp matrix-matrix-rtc-sfu-muxed-udp -o custom-columns=N:.metadata.name,IP:.spec.externalIPs,ETP:.spec.externalTrafficPolicy
```

Expected: SFU on talos7; both services show `[172.16.8.12]` and `Local`. From WSL: `curl -s https://erinko.fi/.well-known/matrix/client | jq '."org.matrix.msc4143.rtc_foci"'` lists a `livekit` focus with `https://mrtc.erinko.fi`.

- [ ] **Step 5: VPS files**

`vps/config/homeops-rtc.nft`:

```
#!/usr/sbin/nft -f
# MatrixRTC muxed UDP -> LiveKit on talos7 (externalIP 172.16.8.12) over wg0.
# haproxy cannot carry UDP. Masquerade so replies return through the tunnel;
# without it LiveKit would answer real client IPs via the home WAN.
# Own table: never touches fail2ban's iptables-nft rules (do NOT enable
# nftables.service — its stock config flushes the whole ruleset).
table ip homeops_rtc
delete table ip homeops_rtc
table ip homeops_rtc {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "eth0" udp dport 30002 counter dnat to 172.16.8.12:30002
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "wg0" ip daddr 172.16.8.12 udp dport 30002 masquerade
  }
}
```

`vps/config/homeops-rtc-nat.service`:

```ini
[Unit]
Description=homeops MatrixRTC UDP forwarding to the cluster
After=network-online.target wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables.d/homeops-rtc.nft
ExecStop=/usr/sbin/nft delete table ip homeops_rtc

[Install]
WantedBy=multi-user.target
```

`vps/config/haproxy.cfg` — insert before `# Forgejo git SSH`:

```
# MatrixRTC ICE/TCP fallback -> LiveKit on talos7 (UDP 30002 is nftables DNAT,
# see homeops-rtc.nft)
frontend ft_rtc_tcp
    bind :::30001
    default_backend bk_rtc_tcp

backend bk_rtc_tcp
    server livekit 172.16.8.12:30001
```

`vps/apply.sh` — insert before `# --- ensure everything is enabled`:

```bash
# --- MatrixRTC UDP forwarding --------------------------------------------------
rtc_changed=0
if install_file homeops-rtc.nft /etc/nftables.d/homeops-rtc.nft 644; then rtc_changed=1; fi
if install_file homeops-rtc-nat.service /etc/systemd/system/homeops-rtc-nat.service 644; then
  systemctl daemon-reload
  rtc_changed=1
fi
if ((rtc_changed)); then
  nft -c -f /etc/nftables.d/homeops-rtc.nft
  systemctl restart homeops-rtc-nat.service
fi
```

and add `homeops-rtc-nat` to the `systemctl enable --quiet …` line.

`vps/mod.just` — append `{{ vps_dir }}/config/homeops-rtc.nft {{ vps_dir }}/config/homeops-rtc-nat.service` to the `scp` file list (before `{{ vps_dir }}/apply.sh`).

Syntax checks (read-only, safe to run): `bash -n vps/apply.sh`; `ssh -p 2222 root@212.147.241.182 'nft -c -f -' < vps/config/homeops-rtc.nft`; `ssh -p 2222 root@212.147.241.182 'cat > /tmp/hc.cfg && haproxy -c -f /tmp/hc.cfg; rm -f /tmp/hc.cfg' < vps/config/haproxy.cfg`. Note: the `nft -c` check reads `table ip homeops_rtc` / `delete table` as a pair; it must report no error.

- [ ] **Step 6: Commit, push; user applies**

```bash
git add vps
git commit -m "feat(vps): forward MatrixRTC TCP 30001 and UDP 30002 to LiveKit"
git push origin main
```

User runs (from WSL, where `just` works):

```bash
just vps apply
```

Expected output lists `changed:` for haproxy.cfg, homeops-rtc.nft and the unit. Verify read-only:

```bash
ssh -p 2222 root@212.147.241.182 'nft list table ip homeops_rtc; systemctl is-enabled homeops-rtc-nat; ss -ltnp | grep 30001'
```

- [ ] **Step 7: Call test (with the user)**

1. From a phone on mobile data (Wi-Fi off), start a video call in Element X with a LAN client on Element Web. Both see and hear each other for 30 s.
2. While the call runs: `ssh -p 2222 root@212.147.241.182 'nft list table ip homeops_rtc'` shows a non-zero `counter packets` on the dnat rule, and `kubectl -n matrix logs deploy/matrix-matrix-rtc-sfu | grep -i -E 'participant|ice' | tail` shows two participants.
3. If the call connects only over TCP (LiveKit logs `tcp` candidates), recheck the UpCloud firewall for 30002/udp.

---

### Task 8: Gatus endpoints

**Files:**
- Modify: `kubernetes/apps/observability/gatus/app/gatus-config.yaml`

- [ ] **Step 1: Endpoints** — add a `Matrix` group at the end of `endpoints:` (same alert block as the existing entries):

```yaml
  - name: matrix homeserver
    group: Matrix
    url: "https://matrix.erinko.fi/_matrix/client/versions"
    interval: 5m
    client:
      dns-resolver: tcp://1.1.1.1:53
    conditions:
      - "[STATUS] == 200"
    alerts:
      - type: ntfy
        send-on-resolved: true
        failure-threshold: 3
        success-threshold: 5
  - name: matrix well-known delegation
    group: Matrix
    url: "https://erinko.fi/.well-known/matrix/server"
    interval: 5m
    client:
      dns-resolver: tcp://1.1.1.1:53
    conditions:
      - "[STATUS] == 200"
      - "[BODY] == pat(*matrix.erinko.fi*)"
    alerts:
      - type: ntfy
        send-on-resolved: true
        failure-threshold: 3
        success-threshold: 5
  - name: matrix authentication service
    group: Matrix
    url: "https://account.erinko.fi/.well-known/openid-configuration"
    interval: 5m
    client:
      dns-resolver: tcp://1.1.1.1:53
    conditions:
      - "[STATUS] == 200"
    alerts:
      - type: ntfy
        send-on-resolved: true
        failure-threshold: 3
        success-threshold: 5
  - name: element web
    group: Matrix
    url: "https://chat.erinko.fi/"
    interval: 5m
    client:
      dns-resolver: tcp://1.1.1.1:53
    conditions:
      - "[STATUS] == 200"
    alerts:
      - type: ntfy
        send-on-resolved: true
        failure-threshold: 3
        success-threshold: 5
  - name: matrix federation
    group: Matrix
    url: "https://federationtester.matrix.org/api/report?server_name=erinko.fi"
    interval: 1h
    client:
      timeout: 30s
    conditions:
      - "[STATUS] == 200"
      - "[BODY].FederationOK == true"
    alerts:
      - type: ntfy
        send-on-resolved: true
        failure-threshold: 2
        success-threshold: 2
```

The file is Flux-substituted (`$${WEB_PORT}` at the top): these entries contain no `${`, so no escaping is needed.

- [ ] **Step 2: Commit, push, verify**

```bash
git add kubernetes/apps/observability/gatus/app/gatus-config.yaml
git commit -m "feat(gatus): Matrix endpoints"
git push origin main
flux -n observability reconcile ks gatus --with-source
kubectl -n observability port-forward svc/gatus 18080:80 >/dev/null 2>&1 &
sleep 3; curl -s localhost:18080/api/v1/endpoints/statuses | jq -r '.[] | select(.group == "Matrix") | .name + " " + (.results[-1].success | tostring)'
kill %1
```

Expected: five Matrix endpoints, all `true` (the federation one may need up to an hour for its first result). Check the Gatus Service name/port with `kubectl -n observability get svc` before port-forwarding.

---

### Task 9: Wrap-up

- [ ] Update the spec's `Status:` line to `implemented 2026-MM-DD` with any deviations found during execution, commit `docs(matrix): mark design implemented`, push.
- [ ] Save a project memory (`project_matrix_ess.md`) with the non-obvious facts: initSecrets must stay on (appservice registration), chart Ingresses deleted by post-renderer, SFU pinned to talos7 + VPS nftables table `homeops_rtc` (never enable `nftables.service`), `apps/synapse/VERSION` must not lag the chart's Synapse pin and `SYNAPSE_TAG` (ks.yaml) only follows once Harbor has the tag, `server_name` is permanent.

## Deferred (not in this plan)

TURN/TLS on 443 (see spec "Deferred"), Hookshot/bridges, Element Admin, Synapse workers.
