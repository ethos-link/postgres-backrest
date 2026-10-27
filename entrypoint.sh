#!/usr/bin/env bash
set -euo pipefail

POSTGRES_CONFIG_FILE_DEFAULT="/etc/postgresql/postgresql.conf"
POSTGRES_HBA_FILE_DEFAULT="/etc/postgresql/pg_hba.conf"

POSTGRES_CONFIG_FILE="${POSTGRES_CONFIG_FILE:-$POSTGRES_CONFIG_FILE_DEFAULT}"
POSTGRES_HBA_FILE="${POSTGRES_HBA_FILE:-$POSTGRES_HBA_FILE_DEFAULT}"

# Resolve defaults in the shell; envsubst only expands variable references.
export PGBACKREST_REPO1_PATH="${PGBACKREST_REPO1_PATH:-/var/lib/pgbackrest}"
export PGBACKREST_REPO1_RETENTION_FULL="${PGBACKREST_REPO1_RETENTION_FULL:-7}"
export PGBACKREST_REPO1_RETENTION_DIFF="${PGBACKREST_REPO1_RETENTION_DIFF:-30}"
export PGBACKREST_PROCESS_MAX="${PGBACKREST_PROCESS_MAX:-4}"
export PGBACKREST_LOG_LEVEL_CONSOLE="${PGBACKREST_LOG_LEVEL_CONSOLE:-info}"
export PGBACKREST_LOG_LEVEL_FILE="${PGBACKREST_LOG_LEVEL_FILE:-debug}"
export PGBACKREST_LOG_PATH="${PGBACKREST_LOG_PATH:-/var/log/pgbackrest}"
export PGBACKREST_COMPRESS_TYPE="${PGBACKREST_COMPRESS_TYPE:-zst}"
export PGBACKREST_COMPRESS_LEVEL="${PGBACKREST_COMPRESS_LEVEL:-6}"
export PGBACKREST_PG1_PATH="${PGBACKREST_PG1_PATH:-${PGDATA:-/var/lib/postgresql/data}}"

# Render pgbackrest.conf from the template using env vars if template exists.
if [ -f /usr/local/share/pgbackrest/pgbackrest.conf.template ]; then
  envsubst </usr/local/share/pgbackrest/pgbackrest.conf.template >/etc/pgbackrest/pgbackrest.conf
else
  # Generate a minimal default pgbackrest.conf
  cat >/etc/pgbackrest/pgbackrest.conf <<EOF
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=7
repo1-retention-diff=30
process-max=4
log-level-console=info
log-path=/var/log/pgbackrest

[main]
pg1-path=/var/lib/postgresql/data
EOF
fi

has_postgres_setting() {
  local key="$1"
  shift

  for arg in "$@"; do
    case "$arg" in
    *"${key}="*)
      return 0
      ;;
    esac
  done

  return 1
}

args=("$@")

if [ "${#args[@]}" -gt 0 ] && [ "${args[0]}" = "postgres" ]; then
  if ! has_postgres_setting "config_file" "${args[@]}"; then
    args+=("-c" "config_file=${POSTGRES_CONFIG_FILE}")
  fi

  if ! has_postgres_setting "hba_file" "${args[@]}"; then
    args+=("-c" "hba_file=${POSTGRES_HBA_FILE}")
  fi
fi

exec /usr/local/bin/docker-entrypoint.sh "${args[@]}"

