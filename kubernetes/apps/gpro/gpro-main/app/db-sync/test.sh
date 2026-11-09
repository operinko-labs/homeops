#!/usr/bin/env bash
# Local end-to-end test for the gpro-dev database sync scripts.
# Starts two throwaway Postgres servers mirroring the cluster: 17 holding a fake
# "prod" (gpro) and 18 holding dev (gpro_dev), both migrated with the real gpro-backend image, runs the sync steps inside the
# real client image and asserts the results. Not deployed to the cluster.
# Needs docker and pull access to harbor.vaderrp.com. Usage: bash test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NET=dbsync-test-net
PROD=dbsync-test-prod
DEV=dbsync-test-dev
PROD_IMAGE=postgres:17.6-alpine
DEV_IMAGE=postgres:18.3-alpine
CLIENT_IMAGE=ghcr.io/cloudnative-pg/postgresql:18.3
APP_TAG="$(awk '/gpro-backend$/ { getline; print $2; exit }' "$HERE/../helmrelease.yaml")"
MIGRATE_IMAGE="harbor.vaderrp.com/operinko-labs/gpro-backend:$APP_TAG"
WORK="$(mktemp -d)"
chmod 777 "$WORK" # the client image runs as uid 26

remove_containers() {
  docker rm -f "$PROD" "$DEV" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
cleanup() {
  remove_containers
  rm -rf "$WORK"
}
trap cleanup EXIT

# psql as superuser on the dev server, SQL on stdin.
sql() { docker exec -i "$DEV" psql -X -q -v ON_ERROR_STOP=1 -U postgres "$@"; }
# Single-value query as superuser on the dev server: q <db> <sql>
q() { docker exec "$DEV" psql -X -At -U postgres -d "$1" -c "$2"; }
# Same, on the prod server: qp <db> <sql>
qp() { docker exec "$PROD" psql -X -At -U postgres -d "$1" -c "$2"; }
assert_eq() {
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1: expected '$3', got '$2'" >&2
    exit 1
  fi
  echo "ok: $1"
}

# Run the backend's Drizzle migrations: migrate <host> <db> <user> <password>
migrate() {
  docker run --rm --network "$NET" -e NODE_ENV=production \
    -e POSTGRESDB_HOST="$1" -e POSTGRESDB_PORT=5432 -e POSTGRESDB_DATABASE="$2" \
    -e POSTGRESDB_USER="$3" -e POSTGRESDB_PASSWORD="$4" \
    "$MIGRATE_IMAGE" node dist/db/migrate.js >/dev/null
}

# Run one sync script in the client image: run_step <script> [extra docker args]
# Extra args come after the defaults, so a later -e overrides an earlier one.
run_step() {
  local script="$1"
  shift
  docker run --rm --network "$NET" -v "$HERE:/scripts:ro" -v "$WORK:/work" \
    -e SRC_HOST="$PROD" -e SRC_DB=gpro -e SRC_USER=gpro_prod -e SRC_PASS=prodpw \
    -e DEV_HOST="$DEV" -e DEV_DB=gpro_dev -e DEV_USER=gpro_devrole -e DEV_PASS=devpw \
    -e SUPER_USER=postgres -e SUPER_PASS=superpw \
    -e STAGING_DB=gpro_dev_sync -e OLD_DB=gpro_dev_old -e WORK_DIR=/work \
    "$@" --entrypoint bash "$CLIENT_IMAGE" "/scripts/$script"
}

setup() {
  remove_containers # stale leftovers from an interrupted run
  docker network create "$NET" >/dev/null
  docker run -d --name "$PROD" --network "$NET" -e POSTGRES_PASSWORD=superpw \
    "$PROD_IMAGE" >/dev/null
  docker run -d --name "$DEV" --network "$NET" -e POSTGRES_PASSWORD=superpw \
    "$DEV_IMAGE" >/dev/null
  # TCP check: the image's temporary init server listens on the socket only.
  local c
  for c in "$PROD" "$DEV"; do
    until docker exec "$c" pg_isready -q -h 127.0.0.1 -U postgres; do sleep 1; done
  done
  docker exec -i "$PROD" psql -X -q -v ON_ERROR_STOP=1 -U postgres <<'SQL'
CREATE ROLE gpro_prod LOGIN PASSWORD 'prodpw';
CREATE DATABASE gpro OWNER gpro_prod;
SQL
  sql <<'SQL'
CREATE ROLE gpro_devrole LOGIN PASSWORD 'devpw';
CREATE DATABASE gpro_dev OWNER gpro_devrole;
SQL
  migrate "$PROD" gpro gpro_prod prodpw
  migrate "$DEV" gpro_dev gpro_devrole devpw

  # Fake prod: everyone enabled with keys, plus prod-only key, schedule, tokens.
  docker exec -i "$PROD" psql -X -q -v ON_ERROR_STOP=1 -U gpro_prod -d gpro <<'SQL'
INSERT INTO "user" (username, email, gpro_manager_id, api_key, enabled) VALUES
  ('alice', 'a@example.test', 101, 'key-a', true),
  ('bob',   'b@example.test', 102, 'key-b', true),
  ('carol', 'c@example.test', 103, 'key-c', true),
  ('dave',  'd@example.test', 104, 'key-d', true),
  ('erin',  'e@example.test', 105, NULL,    true);
INSERT INTO service_worker_api_key (name, api_key, gpro_manager_id)
  VALUES ('prod-key', 'prod-secret', 900);
INSERT INTO cron_job_schedule (name, cron_expression) VALUES ('test-prod-only', '0 1 * * *');
INSERT INTO cron_job_run_log (schedule_id, job_name)
  SELECT id, name FROM cron_job_schedule WHERE name = 'test-prod-only';
INSERT INTO refresh_token (token_hash, user_id, expires_at)
  SELECT 'hash-' || id, id, now() + interval '1 day' FROM "user";
INSERT INTO password_reset_token (user_id, token, expires_at)
  SELECT id, 'tok-' || id, now() + interval '1 hour' FROM "user";
SQL

  # Fake dev: 101 and 103 enabled, 102 disabled, 999 dev-only, tester with no manager ID.
  docker exec -i "$DEV" psql -X -q -v ON_ERROR_STOP=1 -U gpro_devrole -d gpro_dev <<'SQL'
INSERT INTO "user" (username, email, gpro_manager_id, api_key, enabled) VALUES
  ('alice-dev', 'a@example.test', 101, 'old-key-a', true),
  ('bob-dev',   'b@example.test', 102, NULL,        false),
  ('carol-dev', 'c@example.test', 103, 'old-key-c', true),
  ('ghost',     'g@example.test', 999, 'key-g',     true),
  ('tester',    't@example.test', NULL, NULL,       true);
INSERT INTO service_worker_api_key (name, api_key, gpro_manager_id)
  VALUES ('dev-key', 'dev-secret', 901);
INSERT INTO cron_job_schedule (name, cron_expression, enabled)
  VALUES ('test-dev-only', '0 2 * * *', false);
SQL

  # Dev state the sync must keep (migrations may have seeded extra rows; keep those too).
  DEV_SWK_BEFORE="$(q gpro_dev "SELECT string_agg(name, ',' ORDER BY name) FROM service_worker_api_key")"
  DEV_CRON_BEFORE="$(q gpro_dev "SELECT string_agg(name || ':' || enabled, ',' ORDER BY name) FROM cron_job_schedule")"
  DEV_SWK_COUNT="$(q gpro_dev 'SELECT count(*) FROM service_worker_api_key')"
  DEV_CRON_COUNT="$(q gpro_dev 'SELECT count(*) FROM cron_job_schedule')"
}

# Unsafe names must abort before touching anything.
test_guard() {
  local out
  if out="$(run_step dump-restore.sh -e STAGING_DB=gpro 2>&1)"; then
    echo "FAIL: dump-restore accepted STAGING_DB equal to SRC_DB" >&2
    exit 1
  fi
  assert_eq "guard: staging == source rejected" "$(grep -c 'FATAL' <<<"$out")" "1"
  if out="$(run_step dump-restore.sh -e DEV_DB=gpro 2>&1)"; then
    echo "FAIL: dump-restore accepted DEV_DB without _dev suffix" >&2
    exit 1
  fi
  assert_eq "guard: DEV_DB suffix enforced" "$(grep -c 'FATAL' <<<"$out")" "1"
  assert_eq "guard: prod data intact" "$(qp gpro 'SELECT count(*) FROM "user"')" "5"
}

test_dump_restore() {
  run_step dump-restore.sh
  assert_eq "staging has prod users" \
    "$(q gpro_dev_sync "SELECT string_agg(username, ',' ORDER BY username) FROM \"user\" WHERE gpro_manager_id BETWEEN 100 AND 999")" \
    "alice,bob,carol,dave,erin"
  assert_eq "staging tables owned by dev role" \
    "$(q gpro_dev_sync "SELECT count(*) FROM pg_tables WHERE schemaname IN ('public', 'drizzle') AND tableowner <> 'gpro_devrole'")" \
    "0"
  assert_eq "staging has drizzle migrations table" \
    "$(q gpro_dev_sync 'SELECT count(*) > 0 FROM drizzle.__drizzle_migrations')" "t"
  assert_eq "saved enabled manager IDs" "$(paste -sd, "$WORK/enabled_ids.txt")" "101,103,999"
  assert_eq "saved counts" "$(paste -sd' ' "$WORK/counts.env")" \
    "SWK_COUNT=$DEV_SWK_COUNT CRON_COUNT=$DEV_CRON_COUNT"
  assert_eq "preserved dump has dev key" "$(grep -c "'dev-key'" "$WORK/preserved.sql")" "1"
  assert_eq "preserved dump lacks prod key" "$(grep -c "'prod-key'" "$WORK/preserved.sql" || true)" "0"
  assert_eq "dev untouched" "$(q gpro_dev 'SELECT count(*) FROM "user"')" "5"
}

test_sanitize() {
  migrate "$DEV" gpro_dev_sync gpro_devrole devpw # mirrors the CronJob's migrate container

  # A wrong expected count must abort on the matching assertion and roll everything back.
  local out var msg
  cp "$WORK/counts.env" "$WORK/counts.env.good"
  for var in SWK_COUNT CRON_COUNT; do
    if [ "$var" = SWK_COUNT ]; then msg='service-worker keys, expected'; else msg='cron schedules, expected'; fi
    sed -i "s/^$var=.*/$var=99/" "$WORK/counts.env"
    if out="$(run_step sanitize.sh 2>&1)"; then
      echo "FAIL: sanitize accepted a wrong $var" >&2
      exit 1
    fi
    assert_eq "wrong $var rejected by its assertion" "$(grep -c "$msg" <<<"$out")" "1"
    assert_eq "failed sanitize ($var) rolled back" \
      "$(q gpro_dev_sync 'SELECT count(*) > 0 FROM refresh_token')" "t"
    cp "$WORK/counts.env.good" "$WORK/counts.env"
  done
  rm "$WORK/counts.env.good"

  run_step sanitize.sh
  assert_eq "only dev's enabled users enabled" \
    "$(q gpro_dev_sync 'SELECT string_agg(gpro_manager_id::text, $$,$$ ORDER BY gpro_manager_id) FROM "user" WHERE enabled')" \
    "101,103"
  assert_eq "API keys kept only for enabled users" \
    "$(q gpro_dev_sync "SELECT string_agg(gpro_manager_id || '=' || coalesce(api_key, '-'), ',' ORDER BY gpro_manager_id) FROM \"user\" WHERE gpro_manager_id BETWEEN 100 AND 999")" \
    "101=key-a,102=-,103=key-c,104=-,105=-"
  assert_eq "dev's service-worker keys kept" \
    "$(q gpro_dev_sync "SELECT string_agg(name, ',' ORDER BY name) FROM service_worker_api_key")" \
    "$DEV_SWK_BEFORE"
  assert_eq "dev's cron schedules kept" \
    "$(q gpro_dev_sync "SELECT string_agg(name || ':' || enabled, ',' ORDER BY name) FROM cron_job_schedule")" \
    "$DEV_CRON_BEFORE"
  assert_eq "tokens and run log wiped" \
    "$(q gpro_dev_sync "SELECT (SELECT count(*) FROM refresh_token) || '|' || (SELECT count(*) FROM password_reset_token) || '|' || (SELECT count(*) FROM cron_job_run_log)")" \
    "0|0|0"
  assert_eq "service-worker key sequence usable" \
    "$(q gpro_dev_sync "WITH i AS (INSERT INTO service_worker_api_key (name, api_key, gpro_manager_id) VALUES ('seq-check', 'x', 1) RETURNING 1) SELECT 'inserted' FROM i")" \
    "inserted"
  q gpro_dev_sync "DELETE FROM service_worker_api_key WHERE name = 'seq-check'" >/dev/null
  assert_eq "cron schedule sequence usable" \
    "$(q gpro_dev_sync "WITH i AS (INSERT INTO cron_job_schedule (name, cron_expression) VALUES ('seq-check', '* * * * *') RETURNING 1) SELECT 'inserted' FROM i")" \
    "inserted"
  q gpro_dev_sync "DELETE FROM cron_job_schedule WHERE name = 'seq-check'" >/dev/null
}

# The CronJob's pipeline, minus the kubectl steps.
full_sync() {
  # Host-side edits in test_sanitize (sed -i, cp) left files the uid-26 client can't rewrite.
  find "$WORK" -maxdepth 1 -type f -user "$(id -u)" -exec chmod a+rw {} +
  run_step dump-restore.sh
  migrate "$DEV" gpro_dev_sync gpro_devrole devpw
  run_step sanitize.sh
  run_step swap.sh
}

test_swap() {
  run_step swap.sh
  assert_eq "dev now holds prod users" \
    "$(q gpro_dev "SELECT string_agg(username, ',' ORDER BY username) FROM \"user\" WHERE gpro_manager_id BETWEEN 100 AND 999")" \
    "alice,bob,carol,dave,erin"
  assert_eq "dev-only users gone" \
    "$(q gpro_dev "SELECT count(*) FROM \"user\" WHERE username IN ('ghost', 'tester')")" "0"
  assert_eq "previous dev kept as old" \
    "$(q gpro_dev_old "SELECT count(*) FROM \"user\" WHERE username = 'ghost'")" "1"
  assert_eq "staging renamed away" \
    "$(q postgres "SELECT count(*) FROM pg_database WHERE datname = 'gpro_dev_sync'")" "0"
  assert_eq "old db accepts connections" \
    "$(q postgres "SELECT datallowconn FROM pg_database WHERE datname = 'gpro_dev_old'")" "t"
  assert_eq "prod untouched" \
    "$(qp gpro "SELECT count(*) FILTER (WHERE enabled) || '/' || count(*) || '/' || (SELECT count(*) FROM refresh_token) FROM \"user\"")" \
    "5/5/5"
}

# Failed swaps must leave dev and the old copy alone.
test_swap_refusals() {
  # Empty staging: refused, dev unchanged and still connectable.
  sql <<'SQL'
CREATE DATABASE gpro_dev_sync OWNER gpro_devrole;
SQL
  docker exec "$DEV" psql -X -q -v ON_ERROR_STOP=1 -U gpro_devrole -d gpro_dev_sync \
    -c 'CREATE TABLE public."user" (id int)'
  local out
  if out="$(run_step swap.sh 2>&1)"; then
    echo "FAIL: swap accepted an empty staging database" >&2
    exit 1
  fi
  assert_eq "empty staging refused" "$(grep -c 'has no users' <<<"$out")" "1"
  assert_eq "dev unchanged after refused swap" \
    "$(q gpro_dev "SELECT count(*) FROM \"user\" WHERE gpro_manager_id BETWEEN 100 AND 999")" "5"
  assert_eq "dev still accepts connections" \
    "$(q postgres "SELECT datallowconn FROM pg_database WHERE datname = 'gpro_dev'")" "t"
  q postgres 'DROP DATABASE gpro_dev_sync' >/dev/null

  # Missing dev db (half-done swap): refused before anything is dropped.
  if out="$(run_step swap.sh -e DEV_DB=missing_dev 2>&1)"; then
    echo "FAIL: swap ran with a missing DEV_DB" >&2
    exit 1
  fi
  assert_eq "missing dev db refused" "$(grep -c 'does not exist' <<<"$out")" "1"
  assert_eq "old db survives refused swap" \
    "$(q postgres "SELECT count(*) FROM pg_database WHERE datname = 'gpro_dev_old'")" "1"
}

# A second month: the enabled set carries over, a live dev session is terminated,
# and the previous old db is replaced.
test_second_run() {
  docker exec -d "$DEV" psql -U gpro_devrole -d gpro_dev -c 'SELECT pg_sleep(600)'
  local sleepers=0 i
  for i in $(seq 10); do
    sleepers="$(q postgres "SELECT count(*) FROM pg_stat_activity WHERE datname = 'gpro_dev' AND usename = 'gpro_devrole' AND query LIKE '%pg_sleep(600)%' AND pid <> pg_backend_pid()")"
    [ "$sleepers" -gt 0 ] && break
    sleep 1
  done
  assert_eq "second run: live dev session established" "$sleepers" "1"
  full_sync
  assert_eq "second run: live session terminated" \
    "$(q postgres "SELECT count(*) FROM pg_stat_activity WHERE query LIKE '%pg_sleep(600)%' AND pid <> pg_backend_pid()")" "0"
  assert_eq "second run: enabled set carried over" \
    "$(q gpro_dev 'SELECT string_agg(gpro_manager_id::text, $$,$$ ORDER BY gpro_manager_id) FROM "user" WHERE enabled')" \
    "101,103"
  assert_eq "second run: old db is the first sync's result" \
    "$(q gpro_dev_old "SELECT count(*) FROM \"user\" WHERE username = 'ghost'")" "0"
  assert_eq "second run: dev keys still dev's" \
    "$(q gpro_dev "SELECT string_agg(name, ',' ORDER BY name) FROM service_worker_api_key")" \
    "$DEV_SWK_BEFORE"
}

main() {
  setup
  test_guard
  test_dump_restore
  test_sanitize
  test_swap
  test_swap_refusals
  test_second_run
  echo "ALL PASSED"
}

main "$@"
