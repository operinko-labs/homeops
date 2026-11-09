# gpro-dev database sync

Monthly CronJob `gpro-dev-db-sync` (namespace `gpro`, 03:00 Europe/Helsinki on
the 1st) replaces `gpro_dev` with a sanitised copy of production. Design:
`operinko-labs/gpro` → `docs/superpowers/specs/2026-11-08-prod-to-dev-db-sync-design.md`.

Prod runs on CNPG cluster `postgres17` (PG 17), dev on `postgres18` (PG 18), so the
job dumps across versions using the PG 18 client image. Both clusters share the
same superuser secret.

## What it keeps from dev
- Users enabled in dev before the sync (matched by `gpro_manager_id`). Everyone
  else is disabled and has `api_key` set to NULL. To keep someone, enable them in
  dev's admin UI; their prod key comes across at the next sync.
- `service_worker_api_key` and `cron_job_schedule` rows.

Dev-only accounts (no matching prod `gpro_manager_id`, e.g. the seeded tester)
disappear on every sync.

## Steps (init containers, in order)
`dump-restore` → `migrate` → `sanitize` → `scale-down` → `wait-pods-gone` →
`swap` → `scale-up`, then `rollout-backend` / `rollout-worker`.
A failure in the first three steps leaves dev completely untouched.

If Flux upgrades the `gpro-main` HelmRelease (for example after an image bump) while dev is scaled to 0, the deployments come back at 1 replica early. That is harmless: `swap` blocks connections to the old database before terminating them, and the new database is already fully sanitised.

## Operate
```bash
# Run now (delete the previous manual job first if the name is taken)
kubectl delete job -n gpro gpro-dev-db-sync-manual --ignore-not-found
kubectl create job -n gpro --from=cronjob/gpro-dev-db-sync gpro-dev-db-sync-manual
kubectl logs -n gpro -f job/gpro-dev-db-sync-manual --all-containers --max-log-requests 10
# Pause: set `suspend: true` in db-sync-cronjob.yaml and commit.
```
`concurrencyPolicy: Forbid` does not cover jobs made with `kubectl create job --from`,
so do not overlap a manual run with the scheduled one (the 1st at 03:00).

## Recover
**Never scale dev up while `gpro_dev` is missing.** The backend's init-db container
would `createdb` an empty `gpro_dev`, and the next sync would then drop the real
`gpro_dev_old`. Rename `gpro_dev_old` back first.

`swap.sh` renames atomically (both renames and the re-enabling of connections run in
one transaction), so a missing `gpro_dev` should only happen after manual intervention.

- **Dev stuck at 0 replicas** (failed at `scale-down`, `wait-pods-gone`, `swap` or
  later): first check `gpro_dev` exists and accepts connections (see below), then
  `kubectl scale -n gpro deploy/gpro-dev-backend deploy/gpro-dev-worker --replicas=1`
- **`gpro_dev` missing**, as superuser, in this order:
  1. `ALTER DATABASE gpro_dev_old RENAME TO gpro_dev;`
  2. `ALTER DATABASE gpro_dev ALLOW_CONNECTIONS true;`
  3. only then scale dev up.
- **`gpro_dev` refuses connections** (failed right after `ALLOW_CONNECTIONS false`):
  `ALTER DATABASE gpro_dev ALLOW_CONNECTIONS true;`
  (`swap.sh` already attempts this itself, for `gpro_dev` and `gpro_dev_sync`, when
  the swap SQL fails, so this is only needed if that attempt also failed.)
- **After any failed run**, drop the leftover staging database; it may hold an
  unsanitised prod copy: `DROP DATABASE IF EXISTS gpro_dev_sync WITH (FORCE);`
- **Roll back a bad sync**: scale dev to 0, then, as superuser:
  ```sql
  ALTER DATABASE gpro_dev RENAME TO gpro_dev_bad;
  ALTER DATABASE gpro_dev_old RENAME TO gpro_dev;
  ALTER DATABASE gpro_dev ALLOW_CONNECTIONS true;
  ```
  (the old database may still have connections disabled), then scale dev to 1 and
  `DROP DATABASE gpro_dev_bad;`.

A superuser shell without credentials:
`kubectl exec -it -n database $(kubectl get clusters.postgresql.cnpg.io -n database postgres18 -o jsonpath='{.status.currentPrimary}') -c postgres -- psql`

## Test locally
`bash db-sync/test.sh` (Docker plus pull access to harbor.vaderrp.com).
