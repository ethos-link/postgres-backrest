#!/usr/bin/env bash
set -euo pipefail

# Render pgbackrest.conf from the template using env vars if template exists.
if [ -f /usr/local/share/pgbackrest/pgbackrest.conf.template ]; then
  envsubst < /usr/local/share/pgbackrest/pgbackrest.conf.template > /etc/pgbackrest/pgbackrest.conf
else
  # Generate a minimal default pgbackrest.conf
  cat > /etc/pgbackrest/pgbackrest.conf <<EOF
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

exec /usr/local/bin/docker-entrypoint.sh "$@"