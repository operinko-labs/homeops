# MinIO → Versity S3 Gateway migration — design

Date: 2026-09-28
Status: phase 1 (target setup + VolSync) done 2026-09-28; phases 2+ pending

## Purpose

Replace the TrueNAS MinIO app (plus the community minio-console) with the
Versity S3 Gateway (versitygw). MinIO's open-source project is effectively
unmaintained for self-hosters, and the console had already been stripped of
most functionality.

## Why Versity (bake-off summary)

Both TrueNAS community apps — versitygw v1.8.0 (app 1.1.14) and Garage v2.4.1
(app 1.2.8) — were installed side by side on 2026-09-28 against a copy of the
real `volsync` (20.6k objects, 58 GiB) and `cloudnative-pg` (165k objects,
205 GiB) buckets. Throwaway dataset `Nakkiallas/s3test`.

| | MinIO | Versity | Garage |
|---|---|---|---|
| Copy `volsync` in | — | 410 s | 881 s |
| List 165k objects, cold / warm | 390–1118 s / 15.5 s | 54 s / 25.7 s | 16.5 s / 15.7 s |
| Integrity vs MinIO (size+md5) | — | 0 mismatches | 0 mismatches |
| barman backup-list, WAL restore→archive→restore | — | OK | OK |
| kopia fresh repo: snapshot / verify 100% | — | 16 s / 79 s | 29 s / 165 s |
| 5 GiB multipart upload | — | 27 s | 49 s |
| Space freed after delete | — | immediate | 30–50 min (resync queue) |
| Per-consumer accounts isolate buckets | — | yes | yes |
| Prometheus metrics | — | no (statsd only) | yes |

Versity wins on write/verify speed (~2×), immediate space reclaim, objects
stored as plain files on ZFS (browsable/restorable without the gateway),
built-in TLS from a TrueNAS certificate, and a web UI preferred over
garage-webui. Object lock/versioning are available but not wanted.

Findings that shape this design:

- **Versity fsyncs every object.** The pool's only SLOG is a Samsung 850 EVO
  (no PLP); with `sync=standard` a PUT took ~4 s (4 obj/s), with
  `sync=disabled` 0.06 s. MinIO and Garage do not fsync per object by default,
  so `sync=disabled` gives the same durability as today (loss of the last few
  seconds on power cut; UPS-backed).
- **The web UI needs a certificate matching the browsed hostname** plus
  `--webui-gateways`, `--webui-admin-gateways` and `--cors-allow-origin`
  pointing at that hostname; otherwise it reports "cannot reach gateway".
- **`midclt app.update` replaces whole value sections** (a partial `network`
  block reset the ports). The TrueNAS UI always submits the full form.

## Scope

Migrated buckets: `cloudnative-pg`, `volsync`, `harbor`, `mariadb`,
`parsedmarc`, `n8n`.

Left behind (die with MinIO): `kopia` (stale repo, last write 2026-02-16; the
live repo is in `volsync`) and `stalwart` (two objects from a failed test,
2026-05-11). MinIO service accounts `loki`, `elasticsearch`, `falco-talon`
are dead and get no equivalent.

Out of scope: replacing the SLOG, the 2.5 TiB of stale snapshots on the MinIO
dataset (removed only at decommission, with explicit confirmation).

## Target on TrueNAS

**Datasets** (host paths, deliberately outside `ix-apps` so app updates don't
snapshot the data — the MinIO dataset accumulated 2.5 TiB that way):

| Dataset | Settings | Purpose |
|---|---|---|
| `Nakkiallas/s3/buckets` | `recordsize=1M`, `sync=disabled`, `xattr=sa`, `compression=lz4`, no periodic snapshots | bucket root (every subdirectory is a bucket) |
| `Nakkiallas/s3/iam` | defaults (`sync=standard`) | `--iam-dir` (`users.json`); must not live under the bucket root |

Backups carry their own retention; the offsite copy is minio-gdrive-sync.

**App**: versitygw catalog app, name `s3`.

- API `192.168.7.198:9000`, WebUI `:9001`, admin `:9002` — bound to the Node
  VLAN address (host IP) so cluster traffic stays on-VLAN and skips UDM
  inter-VLAN routing/IPS.
- Certificate: TrueNAS ACME certificate `s3_acme2` (id 11) for
  `s3.vaderrp.com`, issued from CSR `s3_key2` (id 10) via Let's Encrypt using
  authenticator 1 (`vaderrp_cf`, same as `minio_acme`), `renew_days` 10. Used
  for API, WebUI and admin.
- Global flags: `--iam-dir /iam`,
  `--webui-gateways https://s3.vaderrp.com:9000`,
  `--webui-admin-gateways https://s3.vaderrp.com:9002`,
  `--cors-allow-origin https://s3.vaderrp.com:9001`. Region stays the default
  `us-east-1`, matching every consumer.
- After MinIO is shut down: widen the bindings to `0.0.0.0`.

**MinIO change**: bind MinIO API/console to `192.168.0.221` only so
`192.168.7.198:9000` is free. Consumers use `minio.vaderrp.com` → `.221`, so
only a few seconds of restart are visible.

**DNS**:
- CoreDNS hosts entry `192.168.7.198 s3.vaderrp.com` in
  `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml`, next to
  `truenas.vaderrp.com` (the NFS/iSCSI move proved every node reaches `.198`).
- LAN record for `s3.vaderrp.com` so the WebUI and the desktop KopiaUI work.

## Accounts

Root keys: admin only, stored in Vaultwarden item `9ae12023-3bdf-48b3-a626-f47044c6f43b`
(fields `root_access_key`, `root_secret_key`, `volsync_access_key`,
`volsync_secret_key`); later phases add each consumer's keys there. One Versity account per
consumer (role `user`, owner of its bucket via `admin create-bucket --owner`),
keys stored in Vaultwarden:

| Account | Bucket | Current credential source |
|---|---|---|
| `cnpg` | `cloudnative-pg` | `cloudnative-pg-secret` (SOPS, `database/cloudnative-pg/app/operator/secret.sops.yaml`) |
| `mariadb` | `mariadb` | `mariadb-s3-secret` ← Vaultwarden `ed32aa71` (shared `ncpg-access` key) |
| `harbor` | `harbor` | Vaultwarden `84fb75c3` fields `aws_access_key`/`aws_secret_key` |
| `volsync` | `volsync` | SOPS: `components/volsync-kopia/secret.sops.yaml` and `storage/volsync/maintenance/secret.sops.yaml`; also the in-cluster kopia web UI (`storage/kopia/app/config.sops.yaml` + `secret.sops.yaml`), the desktop KopiaUI, and four `*-volsync-secret`s of the leo-cal and ruskonkesateatteri sites — ExternalSecrets in their app repos that read every value from Vaultwarden item `a03efec6` (`ruskonkesateatteri-secret`); switched 2026-09-28 by editing that item (after an `rclone copy minio:volsync s3:volsync` merge). After a Vaultwarden edit, `POST /sync` on `bitwarden-eso-provider:8087` before force-syncing ExternalSecrets |
| `parsedmarc` | `parsedmarc` | Vaultwarden `f736bb43` (`aws_*` fields incl. `aws_endpoint`) |
| `n8n` | `n8n` | n8n credential in the n8n UI (not in git) |
| `gdrive-sync` | read-only on all six | Vaultwarden `ed32aa71` via minio-gdrive-sync external-secret |

`gdrive-sync` read access is granted with a bucket policy on each bucket.
Separating mariadb and gdrive-sync from the shared `ncpg-access` key is part
of the change.

## Cutover

Common pattern, per consumer:

1. Pre-copy the bucket MinIO → `s3` with rclone while live.
2. Switch the consumer's endpoint + credentials to
   `https://s3.vaderrp.com:9000`; new writes land on Versity.
3. Catch-up `rclone copy` (never `sync`) MinIO → `s3` for anything written
   before the switch. Safe because these writers produce immutable,
   uniquely-named objects; the two with mutable files pause instead.

| # | Consumer | Specifics | Downtime |
|---|---|---|---|
| 1 | VolSync | KopiaUI stays shut down (already repointed to `s3.vaderrp.com` by the user); `just kube volsync suspend` does NOT apply here — it targets `volsync-system`, which this cluster doesn't use. The procedure that actually worked: `flux -n storage suspend kustomization volsync volsync-maintenance kopia`; `flux -n storage suspend helmrelease volsync kopia`; patch `KopiaMaintenance daily` `spec.enabled=false`; scale deployments `volsync` and `kopia` to 0; final `rclone sync`; push the switched SOPS secrets; resume in reverse (helmreleases, then kustomizations, then `KopiaMaintenance.enabled=true`); scale `volsync` and `kopia` deployments back to 1 by hand (Flux does not restore replica counts on resume); reconcile all Kustomizations so components re-render with the new secrets; reconnect KopiaUI with the new `volsync` keys, preferably as its own identity (e.g. `ollie@desktop`) instead of `volsync@maintenance` so it never runs maintenance | ~1 hourly snapshot |
| 2 | parsedmarc | Update Vaultwarden fields (incl. `aws_endpoint`), force-sync ES | none |
| 3 | n8n | User updates the S3 credential in the n8n UI | none |
| 4 | mariadb | Switch both `PhysicalBackup`s in `database/mariadb/ha/backup.yaml` (+ new secret) outside the nightly backup window | none |
| 5 | Harbor | Pre-copy; scale registry to 0; final sync; switch `regionendpoint` + creds; scale up. Tag links are mutable files. Verify Talos's registry mirrors fall back to upstream while Harbor is down. | minutes |
| 6 | CNPG | Switch `endpointURL` in `objectstore.yaml` and `objectstore18.yaml`, keep `serverName`s (`postgres17-v8`, `postgres18-v1`) so the recovery window is continuous; catch up. Verify immediately that WAL archiving continues (the plugin's empty-archive check is expected to run only at bootstrap) and that a WAL restore works. | none |
| 7 | minio-gdrive-sync | Point the rclone `minio` remote at `s3.vaderrp.com:9000` with the `gdrive-sync` account; drop `kopia` and `stalwart` from `BUCKETS` (their Drive copies stay). First run with `--dry-run` must show no mass re-upload (rclone preserved mtimes in metadata during the copy); if it does, stop and redesign. | none |

VolSync goes first and on day one (2026-09-28): the desktop KopiaUI
autostarts on reboot and is already pointed at `s3.vaderrp.com`, so the
target setup (datasets, app, certificate, DNS, MinIO rebind) plus the
`volsync` account and cutover must all land that day. Fallback if it slips:
point KopiaUI back at `minio.vaderrp.com` or disable its autostart.

Target: all cutovers within about a week, since offsite sync lags for
already-moved buckets until step 7.

**Rollback** (per consumer, any time before decommission): revert its
endpoint/credential change. MinIO keeps all data and stays writable; objects
written to Versity after the switch can be `rclone copy`'d back.

## Monitoring

- Gatus endpoint for `https://s3.vaderrp.com:9000/healthz` lives directly in
  `kubernetes/apps/observability/gatus/app/gatus-config.yaml` (the file the
  HelmRelease actually mounts — a `gatus.io/enabled` ConfigMap, the shape
  `storj-configmap.yaml` uses, is never loaded by anything): status 200 and
  certificate expiry > 240h, alerting via the existing `ntfy` provider.
- Backup health keeps coming from the consumers (CNPG archiving, VolSync,
  mariadb backups).
- No statsd exporter for now.

## Decommission

After a ~7-day soak and one real restore test each for CNPG, VolSync and
mariadb:

1. Stop and delete the `minio` and `minio-console` apps.
2. Remove the `minio.vaderrp.com` CoreDNS entry and `scrapeconfig-minio.yaml`
   (+ its kustomization line).
3. Widen Versity bindings to `0.0.0.0`.
4. Delete the MinIO dataset and its snapshots (~2.5 TiB) — explicit
   confirmation required.
5. Remove the dead MinIO credentials from Vaultwarden, and delete the
   `Nakkiallas/s3test` bake-off dataset and apps if still present.
6. Update CLAUDE.md (TrueNAS `.221` no longer hosts MinIO) and the
   minio-gdrive-sync design doc references.
7. ~~Remove the orphaned `network/technitium` leftovers~~ — done 2026-09-28
   (user-approved): RS, RD, both PVCs, `technitium-*` secrets and the orphan
   `technitium-ns1-production` Certificate deleted.
