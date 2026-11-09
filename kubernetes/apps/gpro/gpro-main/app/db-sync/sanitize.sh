#!/usr/bin/env bash
# Step 3 of the gpro-dev database sync (after migrations have run on STAGING_DB):
# scrub production-only state and re-apply dev's preserved state from WORK_DIR.
# Runs sanitize.sql in a single transaction; any failed assertion rolls back.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

require_env DEV_HOST DEV_USER DEV_PASS WORK_DIR
guard_db_names

# shellcheck disable=SC1091
. "$WORK_DIR/counts.env"
require_env SWK_COUNT CRON_COUNT
KEEP_COUNT="$(grep -c . "$WORK_DIR/enabled_ids.txt" || true)"

log "Sanitising $STAGING_DB (keeping $KEEP_COUNT enabled users)"
cd "$WORK_DIR" # sanitize.sql reads preserved.sql and enabled_ids.txt by relative path
dev_psql "$STAGING_DB" -q --single-transaction \
  -v keep_count="$KEEP_COUNT" -v swk_count="$SWK_COUNT" -v cron_count="$CRON_COUNT" \
  -f "$SCRIPT_DIR/sanitize.sql"
log "Sanitise complete"
