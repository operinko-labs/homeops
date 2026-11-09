#!/usr/bin/env bash
# Step 1 of the gpro-dev database sync: rebuild STAGING_DB from the production
# database and export dev's own state (enabled users, service-worker keys, cron
# schedules) from the current DEV_DB into WORK_DIR.
# Reads SRC_DB and DEV_DB; writes only STAGING_DB and WORK_DIR.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

require_env SRC_HOST SRC_USER SRC_PASS DEV_HOST DEV_USER DEV_PASS SUPER_USER SUPER_PASS WORK_DIR
guard_db_names

log "Recreating staging database $STAGING_DB"
super_psql -q -v db="$STAGING_DB" -v owner="$DEV_USER" <<'SQL'
DROP DATABASE IF EXISTS :"db" WITH (FORCE);
CREATE DATABASE :"db" OWNER :"owner";
SQL

log "Exporting dev-only state from $DEV_DB"
mkdir -p "$WORK_DIR"
dev_psql "$DEV_DB" -At \
  -c 'SELECT gpro_manager_id FROM public."user" WHERE enabled AND gpro_manager_id IS NOT NULL ORDER BY 1' \
  > "$WORK_DIR/enabled_ids.txt"
dev_psql "$DEV_DB" -At -F= > "$WORK_DIR/counts.env" <<'SQL'
SELECT 'SWK_COUNT', count(*) FROM public.service_worker_api_key;
SELECT 'CRON_COUNT', count(*) FROM public.cron_job_schedule;
SQL
PGPASSWORD="$DEV_PASS" pg_dump -h "$DEV_HOST" -p "${DEV_PORT:-5432}" -U "$DEV_USER" -d "$DEV_DB" \
  --data-only --column-inserts --no-owner --no-acl \
  -t public.service_worker_api_key -t public.cron_job_schedule \
  > "$WORK_DIR/preserved.sql"
log "Saved $(grep -c . "$WORK_DIR/enabled_ids.txt" || true) enabled manager IDs"

log "Copying $SRC_DB into $STAGING_DB"
PGPASSWORD="$SRC_PASS" pg_dump -h "$SRC_HOST" -p "${SRC_PORT:-5432}" -U "$SRC_USER" -d "$SRC_DB" \
  -Fc --no-owner --no-acl \
  | PGPASSWORD="$DEV_PASS" pg_restore -h "$DEV_HOST" -p "${DEV_PORT:-5432}" -U "$DEV_USER" \
    -d "$STAGING_DB" --no-owner --no-acl --exit-on-error
log "Restore complete"
