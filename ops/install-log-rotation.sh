#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ] || ! [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]]; then
  echo "Usage: sudo $0 POSTGRES_HOST_UID POSTGRES_HOST_GID" >&2
  exit 2
fi

# DESTDIR stages files for package/build validation without touching systemd.
destination="${DESTDIR:-}"
source_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$destination" ]; then
  [ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
  for dependency in logrotate gzip find envsubst systemctl; do
    command -v "$dependency" >/dev/null
  done
fi

export LOG_DIRECTORY=/var/log/ethos-postgres-18/pgbackrest
export LOG_UID="$1" LOG_GID="$2"
if [ -z "$destination" ]; then
  [ -d "$LOG_DIRECTORY" ] || { echo "Create the dedicated log bind mount first (see docs/logging.md)." >&2; exit 1; }
  [ "$(stat -c %u:%g "$LOG_DIRECTORY")" = "$LOG_UID:$LOG_GID" ] || {
    echo "Log directory ownership does not match supplied host IDs." >&2; exit 1;
  }
fi

install -d "$destination/etc" "$destination/etc/systemd/system" "$destination/usr/local/sbin"
envsubst '${LOG_DIRECTORY} ${LOG_UID} ${LOG_GID}' \
  <"$source_directory/pgbackrest-logrotate.conf.template" \
  >"$destination/etc/pgbackrest-logrotate.conf"
chmod 644 "$destination/etc/pgbackrest-logrotate.conf"
install -m 755 "$source_directory/rotate-pgbackrest-logs" "$destination/usr/local/sbin/rotate-pgbackrest-logs"
install -m 644 "$source_directory/pgbackrest-logrotate.service" "$source_directory/pgbackrest-logrotate.timer" \
  "$destination/etc/systemd/system/"

if [ -z "$destination" ]; then
  systemctl daemon-reload
  systemctl enable --now pgbackrest-logrotate.timer
  systemctl is-active --quiet pgbackrest-logrotate.timer
  systemctl list-timers pgbackrest-logrotate.timer --no-pager
else
  # Validate/enable the installed timer offline without starting host services.
  systemctl --root="$destination" enable pgbackrest-logrotate.timer
fi
