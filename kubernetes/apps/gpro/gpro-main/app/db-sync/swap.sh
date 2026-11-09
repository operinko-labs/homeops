#!/usr/bin/env bash
# Step 5 of the gpro-dev database sync. Dev's backend and worker must already be
# scaled to 0. Renames DEV_DB -> OLD_DB and STAGING_DB -> DEV_DB, dropping the
# previous OLD_DB first. Recovery steps: README.md in this directory.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

require_env DEV_HOST DEV_USER DEV_PASS SUPER_USER SUPER_PASS
guard_db_names

dev_exists="$(super_psql -At -v dev="$DEV_DB" <<<"SELECT count(*) FROM pg_database WHERE datname = :'dev'")"
if [ "$dev_exists" -eq 0 ]; then
  echo "FATAL: $DEV_DB does not exist (half-done swap?); refusing to run so $OLD_DB is not dropped" >&2
  exit 1
fi

users="$(dev_psql "$STAGING_DB" -At -c 'SELECT count(*) FROM public."user"')"
if [ "$users" -eq 0 ]; then
  echo "FATAL: $STAGING_DB has no users; refusing to swap" >&2
  exit 1
fi

log "Swapping: $DEV_DB -> $OLD_DB, $STAGING_DB -> $DEV_DB"
if ! super_psql -q -v dev="$DEV_DB" -v staging="$STAGING_DB" -v old="$OLD_DB" <<'SQL'
DROP DATABASE IF EXISTS :"old" WITH (FORCE);
ALTER DATABASE :"dev" ALLOW_CONNECTIONS false;
SELECT pg_catalog.set_config('dbsync.dbs', :'dev' || ',' || :'staging', false);
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname IN (:'dev', :'staging') AND pid <> pg_backend_pid();
-- Terminated backends exit asynchronously; wait up to 10 s for them to go.
DO $$
BEGIN
  FOR i IN 1..20 LOOP
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM pg_stat_activity
       WHERE datname = ANY (string_to_array(current_setting('dbsync.dbs'), ','))
         AND pid <> pg_backend_pid());
    PERFORM pg_sleep(0.5);
  END LOOP;
  IF EXISTS (
    SELECT 1 FROM pg_stat_activity
     WHERE datname = ANY (string_to_array(current_setting('dbsync.dbs'), ','))
       AND pid <> pg_backend_pid()) THEN
    RAISE EXCEPTION 'swap: sessions still connected after 10 s';
  END IF;
END
$$;
ALTER DATABASE :"dev" RENAME TO :"old";
ALTER DATABASE :"old" ALLOW_CONNECTIONS true;
ALTER DATABASE :"staging" RENAME TO :"dev";
SQL
then
  echo "FATAL: swap failed; attempting to re-enable connections on $DEV_DB" >&2
  super_psql -q -v dev="$DEV_DB" <<<'ALTER DATABASE :"dev" ALLOW_CONNECTIONS true;' || true
  exit 1
fi
log "Swap complete"
