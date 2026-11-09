#!/usr/bin/env bash
# Shared helpers for the gpro-dev database sync scripts (sourced, not executed).
# See README.md in this directory for the env contract.
set -euo pipefail

# Exit 1 if any named env var is empty or unset.
require_env() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      echo "FATAL: required env var $name is empty" >&2
      exit 1
    fi
  done
}

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# psql as the superuser on the maintenance database of the dev host.
super_psql() {
  PGPASSWORD="$SUPER_PASS" psql -X -v ON_ERROR_STOP=1 \
    -h "$DEV_HOST" -p "${DEV_PORT:-5432}" -U "$SUPER_USER" -d postgres "$@"
}

# psql as the dev app role: dev_psql <db> [psql args]
dev_psql() {
  local db="$1"
  shift
  PGPASSWORD="$DEV_PASS" psql -X -v ON_ERROR_STOP=1 \
    -h "$DEV_HOST" -p "${DEV_PORT:-5432}" -U "$DEV_USER" -d "$db" "$@"
}

# Refuse any name combination that could drop or rename the production database.
guard_db_names() {
  require_env SRC_DB DEV_DB STAGING_DB OLD_DB
  case "$DEV_DB" in
    *_dev) ;;
    *)
      echo "FATAL: DEV_DB '$DEV_DB' must end in _dev" >&2
      exit 1
      ;;
  esac
  local name
  for name in "$DEV_DB" "$STAGING_DB" "$OLD_DB"; do
    if [ "$name" = "$SRC_DB" ]; then
      echo "FATAL: database '$name' equals SRC_DB" >&2
      exit 1
    fi
  done
  if [ "$DEV_DB" = "$STAGING_DB" ] || [ "$DEV_DB" = "$OLD_DB" ] || [ "$STAGING_DB" = "$OLD_DB" ]; then
    echo "FATAL: DEV_DB, STAGING_DB and OLD_DB must all differ" >&2
    exit 1
  fi
}
