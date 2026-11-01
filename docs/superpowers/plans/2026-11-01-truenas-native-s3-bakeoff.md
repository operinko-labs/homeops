# TrueNAS native S3 (Object Interface) bake-off Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decide, with measurements, whether the TrueNAS 27 native S3 service can replace the versitygw app `s3`. This plan migrates nothing.

**Architecture:** Run the native `truenas_s3` daemon beside Versity on a second TLS listener (`192.168.7.198:9010`). Its buckets are BUCKET-layout datasets under a throwaway parent, `Nakkiallas/s3native`. Repeat the September 2026 bake-off against it with the real client stacks: rclone, kopia 0.23.1, CNPG barman-cloud and distribution (Harbor's registry). Then compare against the Versity numbers and tear everything down.

**Tech Stack:** TrueNAS 27.0 `midclt` (`s3.*`, `s3.accesskey.*`, `sharing.s3.*`), rclone on TrueNAS, Docker in WSL, kubectl.

**Spec:** No new spec. The baseline and method come from [2026-09-28-minio-to-versity-s3-design.md](../specs/2026-09-28-minio-to-versity-s3-design.md) ("Why Versity (bake-off summary)").

## Global Constraints

- **Start only on TrueNAS 27.0 or later, never an RC.** Check with `midclt call system.version`.
- **Production Versity must not be touched.** That means `192.168.7.198:9000/9001/9002`, the app `s3` and the dataset `Nakkiallas/s3/*`. The source copies read from it with the **root** keys and never write to it.
- **The native service gets one listener only:** `{"address": "192.168.7.198", "port": 9010, "tls": true}`, certificate `11` (`s3_acme2`, covers `s3.vaderrp.com`). Leave it off `0.0.0.0`, because a wildcard listener on port 9000 would clash with Versity.
- `managed_root_dataset` stays `""`, so clients cannot create buckets over S3. Buckets are created only with `sharing.s3.create`.
- **Stay clear of TrueNAS's busy windows:** 00:00Z (CNPG base backups), 02:30Z (mariadb-ha PhysicalBackup), 04:30Z (minio-gdrive-sync). Run the heavy copies in Helsinki daytime, and never during a scrub (`zpool status Nakkiallas`).
- Nothing in this plan goes into git except this file and the results doc in Task 7. The cluster objects from Task 5 are applied with kubectl and deleted again.
- Keep test keys only in `/mnt/Nakkiallas/s3/ops/creds.env` (root 600) as `NATIVE_*` lines. Never print secrets.

## Review Focus

1. **Owner lockout:** adding a grant to a bucket must not lock its owner out. That is the Versity failure behind the 2026-09-28 outage. Tested in Task 2, step 4.
2. **Server-side copy:** distribution moves blobs with `CopyObject`, and with `UploadPartCopy` above 5 GiB. Neither name appears in the daemon's audit-action list, so test both explicitly (Task 6, step 1).
3. **Reload during a transfer:** `sharing.s3.create` reloads the daemon. An upload that is already running must survive a bucket being added (Task 3, step 5).
4. **Large listings:** ListObjectsV2 over about 165k keys, with prefixes and delimiters. barman and kopia walk listings like that (Task 3, step 3; Task 4).
5. **MINTED multipart ETags:** by default, multipart objects get opaque ETags. rclone's integrity check and kopia must not report mismatches. Compare with `multipart_etag: COMPOSITE` (Task 3, step 4).

---

### Task 1: Enable the native service beside Versity

**Files:** none (TrueNAS state only)

**Interfaces:**
- Produces: the native S3 service on `https://s3.vaderrp.com:9010` (path-style), the parent dataset `Nakkiallas/s3native`, and the baseline Versity health from step 1.

- [ ] **Step 1: Preflight.** `ssh truenas_admin@192.168.0.221`, then `sudo -i`.
  - `midclt call system.version` must show 27.0 or later.
  - `zfs list -o name,avail Nakkiallas` must show at least 400G free. The volsync and cloudnative-pg copies need about 265 GiB; recheck their sizes with `du -sh /mnt/Nakkiallas/s3/buckets/{volsync,cloudnative-pg}`. If space is short, skip the cloudnative-pg copy and run the list test against volsync only.
  - `curl -fsS https://s3.vaderrp.com:9000/healthz` must return 200. Record it as the Versity baseline.
- [ ] **Step 2: Parent dataset.** `zfs create -o compression=lz4 -o xattr=sa -o recordsize=1M Nakkiallas/s3native`, with no periodic snapshot task.
- [ ] **Step 3: Configure and start.** Run `midclt call s3.update '{"listeners":[{"address":"192.168.7.198","port":9010,"tls":true}],"certificate":11,"region":"us-east-1"}'`, then `midclt call -j service.control START s3` and `midclt call service.update s3 '{"enable": true}'`. The region matches what every consumer signs for.
- [ ] **Step 4: Verify.**
  - `curl -s https://s3.vaderrp.com:9010/` returns an S3 XML error (`AccessDenied`) with a valid certificate. `curl -k` must not be needed.
  - `ss -ltnp | grep -E ':(9000|9010)\b'` shows Versity on 9000 and `truenas_s3` on 9010.
  - The Versity healthz from step 1 still returns 200.
  - `tail /var/log/truenas_s3.log` shows no errors.

### Task 2: Accounts and grants

**Interfaces:**
- Consumes: Task 1's service.
- Produces: local users `s3-bench` (bucket owner) and `s3-reader`. Their keys are in creds.env as `NATIVE_BENCH_ACCESS`/`NATIVE_BENCH_SECRET` and `NATIVE_READER_ACCESS`/`NATIVE_READER_SECRET`. Also the buckets `bench`, `bench-sync`, `copy-volsync`, `copy-cnpg`, `pg-bench` and `registry-bench`, each a dataset `Nakkiallas/s3native/<name>`.

- [ ] **Step 1: Users.** Create each with `midclt call user.create '{"username":"<u>","full_name":"S3 bake-off <u>","group_create":true,"password_disabled":true,"home":"/var/empty","shell":"/usr/sbin/nologin","smb":false}'`. Note each `uid` (`midclt call user.query '[["username","=","<u>"]]' | jq '.[0].uid'`).
- [ ] **Step 2: Keys.** `midclt call s3.accesskey.create '{"name":"bake-off <u>","username":"<u>"}' | jq -r '"NATIVE_<U>_ACCESS=\(.access_key)\nNATIVE_<U>_SECRET=\(.secret)"' >> /mnt/Nakkiallas/s3/ops/creds.env`. The secret is shown only at creation time.
- [ ] **Step 3: Buckets.**
  - For each name: `midclt call sharing.s3.create '{"name":"<b>","dataset":"Nakkiallas/s3native/<b>","owner":"s3-bench"}'`.
  - Set `zfs set sync=disabled Nakkiallas/s3native/<b>` on every bucket except `bench-sync`.
  - Record `zfs get -s local,received all Nakkiallas/s3native/bench`, which shows the properties the service set on a BUCKET dataset. If the service forces `sync`, note that.
- [ ] **Step 4: Grant test (Review Focus 1).**
  - Give `copy-volsync` the grant `[{"principal_type":"USER","xid":<s3-reader uid>,"access":"READONLY"}]` with `sharing.s3.update`.
  - Run these against `s3.vaderrp.com:9010` with the AWS CLI, from a throwaway `amazon/aws-cli` container in WSL with the keys passed as env vars.
  - As `s3-reader`, `ls` and `get` succeed and `put` fails with `AccessDenied`.
  - As `s3-bench` (the owner), `put`, `get` and `delete` on `copy-volsync` **still succeed**.
  - As `s3-reader`, `ls` on `bench` (no grant) fails.

### Task 3: Throughput, integrity and durability (rclone on TrueNAS)

**Interfaces:**
- Consumes: Task 2's keys and buckets. The source is Versity at `https://s3.vaderrp.com:9000` using the root pair from creds.env, and is read only.
- Produces: rows 1–6 of the results table in Task 7.

Define both remotes with env vars (`RCLONE_CONFIG_VERSITY_*`, `RCLONE_CONFIG_NATIVE_*`, `type=s3`, `provider=Other`, `force_path_style=true`) in a root-only script under `/root/bakeoff/`. Never put them on the command line.

- [ ] **Step 1: Copy in.** `time rclone copy versity:volsync native:copy-volsync --transfers 16 --checkers 32`. Compare with Versity's 410 s. Then repeat for `cloudnative-pg` → `copy-cnpg` if space allowed.
- [ ] **Step 2: Integrity.** `rclone check versity:volsync native:copy-volsync` (size and MD5) must report 0 differences. If multipart objects are skipped as "hash unavailable", count them and run `rclone check --download` on that subset only.
- [ ] **Step 3: Listing (Review Focus 4).** `time rclone size native:copy-cnpg` twice: cold, right after `midclt call -j service.control RESTART s3`, then warm, straight away. ARC stays warm either way, so note that next to the result. Compare with Versity's 54 s cold and 25.7 s warm. Also run `rclone lsf --dirs-only native:copy-cnpg/postgres18-v1/` to check delimiter listing.
- [ ] **Step 4: Multipart and ETags (Review Focus 5).**
  - Upload a 5 GiB random file with `time rclone copyto /root/bakeoff/5g.bin native:bench/5g.bin` and compare with 27 s.
  - Run `rclone check` on it.
  - Then set `multipart_etag: "COMPOSITE"` on `bench` (`sharing.s3.update`), upload the file again and check again. Record whether either mode makes `rclone check` complain.
- [ ] **Step 5: Reload under load (Review Focus 3).**
  - Start a second 5 GiB upload into `bench`.
  - While it runs, `sharing.s3.create` a bucket named `reload-probe`.
  - The upload must finish without errors, apart from ordinary rclone retries. Count them from `-v` output.
  - Delete `reload-probe` afterwards with `sharing.s3.delete` + `zfs destroy`.
- [ ] **Step 6: PUT latency (the fsync question).**
  - `rclone copy /root/bakeoff/small200/ native:bench-sync/lat/ --transfers 1`, where small200 is 200 files of 64 KiB. Time it, then repeat the same against `bench`.
  - Versity's numbers were 4 s per PUT with `sync=standard` and 0.06 s with `sync=disabled`.
  - Then delete `lat/` from both and run `zfs list -o name,used Nakkiallas/s3native/bench` straight away, then again a minute later, to see whether the space comes back immediately.

### Task 4: kopia (VolSync's mover)

**Interfaces:**
- Consumes: bucket `bench` and the `s3-bench` keys.
- Produces: row 7 of the results table.

- [ ] **Step 1: Fresh repo.** In WSL Docker, `kopia/kopia:0.23.1` (the cluster's version), run `repository create s3 --bucket bench --prefix kopia/ --endpoint s3.vaderrp.com:9010 --access-key … --secret-access-key …` with a throwaway repo password.
- [ ] **Step 2: Snapshot and verify.** September didn't record its test tree, so build a fresh one with `/root/bakeoff/mktree.sh`: 10 GiB made of 2,000 files of 1–64 MiB of random data, plus 20,000 files of 4 KiB. Time `snapshot create` on it, then `snapshot verify --verify-files-percent=100`. Compare with 16 s and 79 s.
- [ ] **Step 3: Maintenance.** `maintenance run --full --safety=none` must finish without errors. That is the path KopiaMaintenance uses.

### Task 5: CNPG barman-cloud (WAL archive and restore)

**Files:** throwaway manifests in the session scratchpad, not the repo

**Interfaces:**
- Consumes: bucket `pg-bench` and the `s3-bench` keys.
- Produces: row 8 of the results table.

- [ ] **Step 1: Throwaway cluster.** In namespace `database`, apply:
  - a Secret `native-bench-s3` holding the bench keys;
  - an `ObjectStore` `native-bench` with `destinationPath: s3://pg-bench/` and `endpointURL: https://s3.vaderrp.com:9010`, otherwise shaped like [objectstore18.yaml](../../../kubernetes/apps/database/cloudnative-pg/app/cluster/objectstore18.yaml);
  - a one-instance `Cluster` `bench-pg` (image `ghcr.io/cloudnative-pg/postgresql:18`, 1Gi on the default storage class) using the barman-cloud plugin with that ObjectStore as its WAL archive.
- [ ] **Step 2: Archive.** Create a table and insert rows. Run `SELECT pg_switch_wal()` three times. Take an on-demand `Backup` (method `plugin`, plugin `barman-cloud.cloudnative-pg.io`). It must reach `completed`, and the Cluster's `ContinuousArchiving` condition must be `True`.
- [ ] **Step 3: Restore.** Create `bench-pg-restore`, bootstrapped by `recovery` from that ObjectStore with `serverName: bench-pg`. It must become ready and contain the rows from step 2. The rows inserted after the backup prove that WAL restore works.
- [ ] **Step 4: Remove** both Clusters, the Backup, the ObjectStore and the Secret. `kubectl -n database get cluster` then shows only `postgres17`, `postgres18` and `torn-tracker-pg`.

### Task 6: Registry storage (Harbor's distribution driver)

**Interfaces:**
- Consumes: bucket `registry-bench` and the `s3-bench` keys.
- Produces: row 9 of the results table.

- [ ] **Step 1: Server-side copy (Review Focus 2).** As `s3-bench`, using the aws-cli container:
  - Upload a 1 GiB object `bench/1g.bin` and a 6 GiB object `bench/6g.bin`.
  - `s3api copy-object` from `bench/1g.bin` to `bench/1g-copy.bin` must succeed.
  - A multipart copy of `bench/6g.bin` (`create-multipart-upload`, then `upload-part-copy` with `--copy-source-range` in 1 GiB parts, then `complete-multipart-upload`) must also succeed.
  - The ETag or size of the result must match the source.
- [ ] **Step 2: Real driver.**
  - Run `distribution/distribution:3.0.0` in WSL Docker with the S3 storage driver: `regionendpoint` set to `https://s3.vaderrp.com:9010`, `bucket: registry-bench`, `forcepathstyle: true`, region `us-east-1`.
  - Push a 3 GiB or larger image, for example a locally built image with one large random layer.
  - Pull it back after `docker image rm`. The digest must match.
  - Push the same tag again, which forces a tag-link rewrite (a mutable object).
- [ ] **Step 3: Remove** the registry container. Leave `registry-bench` for Task 8.

### Task 7: Record results and decide

**Files:**
- Create: `docs/superpowers/specs/<run-date>-truenas-native-s3-bakeoff-results.md`

- [ ] **Step 1: Results table.** Use the September table's columns: Versity (Sept) and Native. Rows:
  1. copy volsync in
  2. integrity
  3. list 165k objects cold / warm
  4. 5 GiB multipart (MINTED / COMPOSITE)
  5. reload under load
  6. PUT latency with sync standard / disabled, and space reclaim
  7. kopia snapshot / verify / maintenance
  8. barman archive + restore
  9. CopyObject / UploadPartCopy / registry push-pull
  10. owner-lockout grant test
  11. metrics: does the daemon expose anything Prometheus can scrape? Check `/var/log/truenas_s3.log`, `ss -ltnp` and the 27.0 reporting UI.
  12. the BUCKET dataset properties recorded in Task 2, step 3

  Also add a short section on the operational differences: per-bucket datasets, grants instead of policies, the UI-certificate option, and the config backups in `.truenas_s3`.
- [ ] **Step 2: Verdict.** It is **go** only when all of these hold. Otherwise it is **no-go**, and the doc names the failing row.
  - Rows 2, 5 and 7–10 pass outright.
  - Rows 1, 4 and the kopia timings are within 1.5× of Versity.
  - PUT latency on a `sync=disabled` bucket is at most 0.2 s.
  - The feature is no longer marked Early Access in the running release.

  A **go** leads to a separate migration spec that copies the September cutover pattern (pre-copy, switch, catch-up `rclone copy`). It does not start here.
- [ ] **Step 3: Commit** the results doc to homeops `main` and push to `origin` (Forgejo). Update the memory note `project-minio-to-versity-migration` with one line on the verdict.

### Task 8: Tear down

- [ ] **Step 1: Deregister and destroy.**
  - Run `sharing.s3.delete` on every bake-off bucket. It **only deregisters**.
  - Then `zfs destroy -r Nakkiallas/s3native`, after showing the user `zfs list -r Nakkiallas/s3native` and getting a yes.
- [ ] **Step 2: Accounts.**
  - Delete the access keys (`s3.accesskey.delete`) and both users (`user.delete`, including their groups).
  - Remove the `NATIVE_*` lines from creds.env.
- [ ] **Step 3: Service off.** `midclt call service.update s3 '{"enable": false}'`, then `midclt call -j service.control STOP s3`. After a go verdict you can keep it running, but disable it if the migration isn't scheduled.
- [ ] **Step 4: Verify.**
  - `ss -ltnp | grep 9010` is empty.
  - `curl -fsS https://s3.vaderrp.com:9000/healthz` returns 200.
  - `zfs list Nakkiallas/s3native` reports that the dataset does not exist.
  - The next hourly VolSync run is green (`kubectl get replicationsources -A`, all with `lastSyncTime` after the bake-off).
