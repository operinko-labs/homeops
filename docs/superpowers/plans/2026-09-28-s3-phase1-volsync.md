# S3 Phase 1 (Versity + VolSync cutover) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the production Versity gateway `s3.vaderrp.com` on TrueNAS and move the VolSync kopia repository (and its three other clients) from MinIO to it, today.

**Architecture:** versitygw TrueNAS catalog app `s3` serving `Nakkiallas/s3/buckets` on `192.168.7.198:9000` with a Let's Encrypt cert; DNS via CoreDNS hosts (cluster) and an internal-dns DNSEndpoint (LAN/Technitium). VolSync is cut over with writers paused: final `rclone sync`, SOPS secret switch, resume.

**Tech Stack:** TrueNAS 26.0 middleware (`midclt`), versitygw v1.8.0, rclone 1.75.1 (docker on TrueNAS), Flux, SOPS/age, VolSync (perfectra1n v0.17.11, kopia 0.22.3).

**Spec:** `docs/superpowers/specs/2026-09-28-minio-to-versity-s3-design.md`

## Global Constraints

- Hostname `s3.vaderrp.com`; API `192.168.7.198:9000`, WebUI `:9001`, admin `:9002`.
- Datasets: `Nakkiallas/s3/buckets` (`recordsize=1M`, `sync=disabled`, `xattr=sa`, `compression=lz4`, no periodic snapshots), `Nakkiallas/s3/iam` (defaults).
- Region `us-east-1`. One account per consumer, role `user`, owning its bucket.
- MinIO data is never modified; MinIO stays writable (rollback = revert secrets).
- Secrets never printed: generated on TrueNAS into root-only files; moved into SOPS by piping, never echoed.
- No AI attribution in commits/PRs. Commits in worktree `C:\Users\ollie\homeops-s3-spec`; PRs via `tea` on Forgejo; the user merges.
- Remote TrueNAS commands run as `ssh truenas_admin@192.168.0.221 sudo -n bash -s <<'R' … R` from WSL (heredoc scripts in the session scratchpad; long jobs detached with `setsid nohup`).
- Ops files live in `/mnt/Nakkiallas/s3/ops/` (root 700), outside the bucket root.

## File Structure

| File | Change |
|---|---|
| `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml` | add `192.168.7.198 s3.vaderrp.com` to hosts |
| `kubernetes/apps/storage/s3/ks.yaml` | new Flux Kustomization (DNS record for the TrueNAS-hosted gateway) |
| `kubernetes/apps/storage/s3/app/kustomization.yaml` | new |
| `kubernetes/apps/storage/s3/app/dnsendpoint.yaml` | new DNSEndpoint `s3.vaderrp.com A 192.168.7.198` (no `route.scope: external` label → internal-dns only) |
| `kubernetes/apps/storage/kustomization.yaml` | add `./s3/ks.yaml` |
| `kubernetes/apps/observability/gatus/app/s3-configmap.yaml` + `kustomization.yaml` | Gatus check `https://s3.vaderrp.com:9000/healthz` |
| `kubernetes/components/volsync-kopia/secret.sops.yaml` | `KOPIA_S3_ENDPOINT`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| `kubernetes/apps/storage/volsync/maintenance/secret.sops.yaml` | same three keys |
| `kubernetes/apps/storage/kopia/app/config.sops.yaml` | `repository.config` endpoint + keys |
| `kubernetes/apps/storage/kopia/app/secret.sops.yaml` | `accessKeyID`, `secretAccessKey` |

---

### Task 1: Remove the bake-off leftovers

**Interfaces:** Produces free ports 9100–9102 and no `Nakkiallas/s3test`.

- [ ] **Step 1:** Delete the app and dataset:
```bash
midclt call -j app.delete s3test-versity '{"remove_images": false, "remove_ix_volumes": true}'
zfs destroy -r Nakkiallas/s3test
```
- [ ] **Step 2: Verify:** `midclt call app.query '[["name","^","s3test"]]'` → `[]`; `zfs list Nakkiallas/s3test` → "dataset does not exist"; `docker ps | grep s3test` → empty.

### Task 2: Certificate for s3.vaderrp.com

**Interfaces:** Produces TrueNAS certificate named `s3_acme` (id recorded as `$S3_CERT_ID` in `/mnt/Nakkiallas/s3/ops/ids.env`).

- [ ] **Step 1:** Create the key/CSR (mirrors CSR id 4 `minio`: EC P-384):
```bash
midclt call -j certificate.create '{"name":"s3","create_type":"CERTIFICATE_CREATE_CSR","key_type":"EC","ec_curve":"SECP384R1","digest_algorithm":"SHA256","common":"s3.vaderrp.com","san":["s3.vaderrp.com"]}'
```
- [ ] **Step 2:** Issue via ACME with authenticator 1 (`vaderrp_cf`, Cloudflare), CSR id from step 1:
```bash
midclt call -j certificate.create '{"name":"s3_acme","create_type":"CERTIFICATE_CREATE_ACME","csr_id":<CSR_ID>,"tos":true,"acme_directory_uri":"https://acme-v02.api.letsencrypt.org/directory","renew_days":10,"dns_mapping":{"DNS:s3.vaderrp.com":1}}'
```
If TrueNAS 26 rejects the CSR flow, create the ACME cert directly with the same `dns_mapping` and key parameters (check `midclt call certificate.create` schema error for the accepted fields).
- [ ] **Step 3: Verify:** `certificate.query [["name","=","s3_acme"]]` shows `common: s3.vaderrp.com`, issuer Let's Encrypt, `until` ~90 days out. Record id in `ids.env`.

### Task 3: Datasets

- [ ] **Step 1:**
```bash
midclt call pool.dataset.create '{"name":"Nakkiallas/s3","comments":"Versity S3 gateway (s3.vaderrp.com)"}'
midclt call pool.dataset.create '{"name":"Nakkiallas/s3/buckets","recordsize":"1M","sync":"DISABLED","compression":"LZ4","atime":"OFF"}'
midclt call pool.dataset.create '{"name":"Nakkiallas/s3/iam"}'
mkdir -m 700 -p /mnt/Nakkiallas/s3/ops
chown 568:568 /mnt/Nakkiallas/s3/buckets /mnt/Nakkiallas/s3/iam
```
- [ ] **Step 2: Verify:** `zfs get -o name,property,value recordsize,sync,xattr,compression -r Nakkiallas/s3` matches Global Constraints; `midclt call pool.snapshottask.query` has no task covering `Nakkiallas/s3` (recursive tasks on `Nakkiallas` would — if one exists, add an exclude for `Nakkiallas/s3`).

### Task 4: Bind MinIO to 192.168.0.221 only

`app.update` replaces whole sections — send the complete `network` block (from `app.config minio`) with only `host_ips` changed.

- [ ] **Step 1:**
```bash
midclt call -j app.update minio '{"values":{"network":{"api_port":{"bind_mode":"published","host_ips":["192.168.0.221"],"port_number":9000},"console_port":{"bind_mode":"published","host_ips":["192.168.0.221"],"port_number":9002},"certificate_id":5,"dns_opts":[],"domain":"minio.vaderrp.com","networks":[]}}}'
```
- [ ] **Step 2: Verify:** `ss -ltn | grep ':9000 '` shows only `192.168.0.221:9000`; `curl -s -o /dev/null -w '%{http_code}' https://minio.vaderrp.com:9000/minio/health/live --resolve minio.vaderrp.com:9000:192.168.0.221` → 200; `app.config minio` still has root creds/storage unchanged; minio-console (targets `https://192.168.0.221:9000/`) loads. In-cluster: `kubectl -n storage logs job/<latest volsync mover>` unaffected at the next hourly run.

### Task 5: Install the `s3` app

**Interfaces:** Produces root keys `S3_ROOT_AK`/`S3_ROOT_SK` in `/mnt/Nakkiallas/s3/ops/creds.env` (root 600); endpoints per Global Constraints.

- [ ] **Step 1:** Generate root keys into `creds.env` (`S3_ROOT_AK=root-$(openssl rand -hex 4)`, `S3_ROOT_SK=$(openssl rand -hex 24)`).
- [ ] **Step 2:** `app.create` (source `creds.env`, build JSON in a root-only temp file, delete afterwards):
```json
{"app_name":"s3","catalog_app":"versitygw","train":"community","values":{
 "versity":{"root_user_access_key":"$S3_ROOT_AK","root_user_secret_access_key":"$S3_ROOT_SK","additional_envs":[],
   "additional_global_flags":[
     {"flag":"--iam-dir","value":"/iam"},
     {"flag":"--webui-gateways","value":"https://s3.vaderrp.com:9000"},
     {"flag":"--webui-admin-gateways","value":"https://s3.vaderrp.com:9002"},
     {"flag":"--cors-allow-origin","value":"https://s3.vaderrp.com:9001"}],
   "additional_posix_flags":[]},
 "network":{"host_network":false,
   "api_port":{"bind_mode":"published","host_ips":["192.168.7.198"],"port_number":9000},
   "webui_port":{"bind_mode":"published","host_ips":["192.168.7.198"],"port_number":9001},
   "admin_port":{"bind_mode":"published","host_ips":["192.168.7.198"],"port_number":9002},
   "certificate_id":$S3_CERT_ID,"admin_certificate_id":$S3_CERT_ID},
 "run_as":{"user":568,"group":568},
 "storage":{"buckets":{"type":"host_path","host_path_config":{"acl_enable":false,"path":"/mnt/Nakkiallas/s3/buckets"}},
   "additional_storage":[{"type":"host_path","mount_path":"/iam","host_path_config":{"acl_enable":false,"path":"/mnt/Nakkiallas/s3/iam"}}]},
 "resources":{"limits":{"cpus":8,"memory":8192}}}}
```
- [ ] **Step 3: Verify:** app `RUNNING`; `curl -s -o /dev/null -w '%{http_code}' --resolve s3.vaderrp.com:9000:192.168.7.198 https://s3.vaderrp.com:9000/healthz` → 200 with a valid chain (no `-k`); cert subject `CN=s3.vaderrp.com` on 9000/9001/9002.

### Task 6: DNS + Gatus (PR 1 — merge before Task 8)

**Files:** see File Structure (CoreDNS, `storage/s3/*`, `storage/kustomization.yaml`, Gatus).

- [ ] **Step 1:** CoreDNS hosts block becomes:
```
              192.168.0.221 minio.vaderrp.com
              192.168.7.198 truenas.vaderrp.com
              192.168.7.198 s3.vaderrp.com
              fallthrough
```
- [ ] **Step 2:** `kubernetes/apps/storage/s3/app/dnsendpoint.yaml`:
```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/externaldns.k8s.io/dnsendpoint_v1alpha1.json
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: s3
spec:
  # Versity S3 gateway on TrueNAS (Node VLAN). No route.scope label: internal-dns only.
  endpoints:
    - dnsName: s3.vaderrp.com
      recordType: A
      targets: ["192.168.7.198"]
```
`app/kustomization.yaml` lists `./dnsendpoint.yaml`; `ks.yaml` follows the repo's standard Flux Kustomization shape (copy `storage/minio-gdrive-sync/ks.yaml`, name `s3`, path `./kubernetes/apps/storage/s3/app`, no components/postBuild); add `- ./s3/ks.yaml` to `storage/kustomization.yaml`.
- [ ] **Step 3:** `observability/gatus/app/s3-configmap.yaml` (shape of `storj-configmap.yaml`), one endpoint:
```yaml
      - name: "S3 gateway"
        group: Storage
        url: "https://s3.vaderrp.com:9000/healthz"
        interval: 5m
        client:
          timeout: 15s
        conditions:
          - "[STATUS] == 200"
          - "[CERTIFICATE_EXPIRATION] > 240h"
        alerts:
          - type: pushover
            send-on-resolved: true
            failure-threshold: 3
            success-threshold: 5
```
and add it to the Gatus `kustomization.yaml`.
- [ ] **Step 4:** `kubectl kustomize` each changed dir renders; commit `feat(storage): DNS and health check for s3.vaderrp.com`; push branch; `tea pr create`; user merges.
- [ ] **Step 5: Verify:** `nslookup s3.vaderrp.com 192.168.5.8` → `192.168.7.198`; from a pod: `kubectl run -n storage dnscheck --rm -i --restart=Never --image=curlimages/curl -- curl -s -o /dev/null -w '%{http_code}' https://s3.vaderrp.com:9000/healthz` → 200; Gatus shows "S3 gateway" green.

### Task 7: `volsync` account and bucket

**Interfaces:** Produces `VOLSYNC_AK=volsync`, `VOLSYNC_SK` in `creds.env`; bucket `volsync` owned by `volsync`.

- [ ] **Step 1:** (admin CLI via `docker run --rm --network host --add-host s3.vaderrp.com:192.168.7.198 ghcr.io/versity/versitygw:v1.8.0 admin -a $S3_ROOT_AK -s $S3_ROOT_SK --er https://s3.vaderrp.com:9002`)
```
create-user -a volsync -s $VOLSYNC_SK -r user
create-bucket --bucket volsync --owner volsync
```
- [ ] **Step 2: Verify** with rclone as `volsync`: `rcat` + `lsf` + `deletefile` on `volsync` succeed; `lsd` shows only `volsync`.

### Task 8: Pre-copy (writers live)

- [ ] **Step 1:** `rclone.env` in `ops/` with remotes `minio` (root keys from `app.config minio`, endpoint `https://192.168.0.221:9000`, `--no-check-certificate` only for this remote's IP-vs-name mismatch) and `s3` (`volsync` keys, endpoint `https://s3.vaderrp.com:9000`, `--add-host`). Detached: `rclone sync minio:volsync s3:volsync --transfers 16 --checkers 32 --s3-no-check-bucket` (~7 min).
- [ ] **Step 2: Verify:** `rclone check minio:volsync s3:volsync --one-way` → only objects newer than the copy start missing; 0 hash/size differences except kopia's mutable metadata.

### Task 9: Secrets PR (PR 2 — do NOT merge until Task 10 step 3)

- [ ] **Step 1:** For each file, set values by piping from TrueNAS, never echoing (`sops --set '["stringData"]["AWS_SECRET_ACCESS_KEY"] "<value>"'` built inside a pipeline):
  - `components/volsync-kopia/secret.sops.yaml` and `storage/volsync/maintenance/secret.sops.yaml`: `KOPIA_S3_ENDPOINT=s3.vaderrp.com:9000`, `AWS_ACCESS_KEY_ID=volsync`, `AWS_SECRET_ACCESS_KEY=$VOLSYNC_SK` (`KOPIA_REPOSITORY`/`KOPIA_S3_BUCKET` unchanged).
  - `storage/kopia/app/config.sops.yaml`: `repository.config` → `"endpoint": "s3.vaderrp.com:9000"`, new `accessKeyID`/`secretAccessKey`.
  - `storage/kopia/app/secret.sops.yaml`: `accessKeyID`, `secretAccessKey`.
  If the auto-mode classifier blocks moving the key off TrueNAS, stop and hand this step to the user (`sops edit` with the key from `creds.env`).
- [ ] **Step 2: Verify:** `sops -d … | grep KOPIA_S3_ENDPOINT` shows the new endpoint in both files; `sops -d` of all four succeeds; `kubectl kustomize` renders. Commit `feat(volsync): move kopia repository to s3.vaderrp.com`; push; `tea pr create`. Do not merge.

### Task 10: Cutover (writers paused)

- [ ] **Step 1: Pause writers.**
```bash
flux -n storage suspend kustomization volsync volsync-maintenance kopia
flux -n storage suspend helmrelease volsync kopia
kubectl -n storage scale deployment volsync kopia --replicas 0
kubectl -n storage patch kopiamaintenance daily --type merge -p '{"spec":{"enabled":false}}'
kubectl get pods -A | grep -E 'volsync-src|kopia-maint'   # wait until none running
```
(`just kube volsync` targets `volsync-system`, which is wrong for this cluster — don't use it.) Confirm the desktop KopiaUI is closed.
- [ ] **Step 2:** Final `rclone sync minio:volsync s3:volsync` (propagates deletions from maintenance); then `rclone check` → 0 differences.
- [ ] **Step 3:** User merges PR 2. `flux reconcile source git flux-system -n flux-system`; `flux -n storage resume kustomization volsync-maintenance kopia volsync`; `flux -n storage resume helmrelease volsync kopia`; `flux reconcile ks` for every app Kustomization that includes the volsync-kopia component (`just kube sync-ks`).
- [ ] **Step 4: Verify secrets:** every `*-volsync-secret` in the cluster has `KOPIA_S3_ENDPOINT=s3.vaderrp.com:9000`:
```bash
kubectl get secret -A -o json | jq -r '.items[] | select(.metadata.name|endswith("-volsync-secret")) | "\(.metadata.namespace)/\(.metadata.name) \(.data.KOPIA_S3_ENDPOINT|@base64d)"' | sort | uniq -c -f1
```
Expect 32 lines, all `s3.vaderrp.com:9000`. Deployments `volsync` and `kopia` back to 1 replica; KopiaMaintenance `enabled: true` (Flux restores it).

### Task 11: Verify on Versity

- [ ] **Step 1:** Manually trigger one small ReplicationSource (`kubectl -n <ns> patch replicationsource <app> --type merge -p '{"spec":{"trigger":{"manual":"s3-cutover"}}}'`) → `status.lastManualSync == s3-cutover`, mover job succeeds, new `_log`/`p*` objects appear in `/mnt/Nakkiallas/s3/buckets/volsync` and nothing new in MinIO.
- [ ] **Step 2:** In-cluster kopia UI loads and lists snapshots for all apps.
- [ ] **Step 3:** Restore test: `just kube volsync-restore <ns> <small app>` for a non-critical app (or browse + download a file in the kopia UI if a restore would disrupt it).
- [ ] **Step 4:** Next hourly run (:00): all ReplicationSources succeed (`kubectl get replicationsource -A` — `LAST SYNC` updated, no errors).
- [ ] **Step 5:** Trigger maintenance once (`kubectl -n storage patch kopiamaintenance daily --type merge -p '{"spec":{"trigger":{"manual":"s3-cutover"}}}'` if supported, else wait for schedule) → job succeeds.

### Task 12: Hand-off

- [ ] **Step 1:** User reconnects desktop KopiaUI to `s3.vaderrp.com:9000` with `volsync` / `VOLSYNC_SK` (read via `ssh truenas_admin@192.168.0.221 sudo cat /mnt/Nakkiallas/s3/ops/creds.env`), ideally as `ollie@desktop`.
- [ ] **Step 2:** User stores `S3_ROOT_*` and `VOLSYNC_*` in Vaultwarden.
- [ ] **Step 3:** Mark phase 1 done in the spec (status line), commit.

**Rollback (any point before decommission):** revert PR 2 (MinIO data untouched), resume writers. Before Task 10 step 3 nothing in the cluster points at Versity.
