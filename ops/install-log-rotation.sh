#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] || ! [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]]; then
  echo "Usage: sudo $0 POSTGRES_HOST_UID POSTGRES_HOST_GID [ABSOLUTE_LOG_DIRECTORY]" >&2
  exit 2
fi

# DESTDIR stages files for package/build validation without touching systemd.
destination="${DESTDIR:-}"
source_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$destination" ]; then
  [ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
  for dependency in logrotate gzip find df envsubst systemctl; do
    command -v "$dependency" >/dev/null
  done
fi

export LOG_DIRECTORY="${3:-/var/log/ethos-postgres-18/pgbackrest}"
export LOG_UID="$1" LOG_GID="$2"
# Keep paths unambiguous in both logrotate and systemd, and reject locations
# hidden by ProtectHome/PrivateTmp. Do not interpolate systemd specifiers.
if ! [[ "$LOG_DIRECTORY" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then
  echo "Use an absolute log directory with only letters, digits, _, ., / and -." >&2
  exit 2
fi
case "$LOG_DIRECTORY/" in
  */../*|*/./*|*//*|/home/*|/root/*|/run/user/*|/tmp/*|/var/tmp/*)
    echo "Log directory must be normalized and outside home/private temporary directories." >&2
    exit 2
    ;;
esac
if [ -z "$destination" ]; then
  [ -d "$LOG_DIRECTORY" ] || { echo "Create the dedicated log bind mount first (see docs/logging.md)." >&2; exit 1; }
  [ "$(stat -c %u:%g "$LOG_DIRECTORY")" = "$LOG_UID:$LOG_GID" ] || {
    echo "Log directory ownership does not match supplied host IDs." >&2; exit 1;
  }
  # Read-only preflight: refuse enabling a timer that cannot safely copy logs.
  "$source_directory/rotate-pgbackrest-logs" --check-space "$LOG_DIRECTORY"
fi

install -d "$destination/etc" "$destination/etc/systemd/system" "$destination/usr/local/sbin"
envsubst '${LOG_DIRECTORY} ${LOG_UID} ${LOG_GID}' \
  <"$source_directory/pgbackrest-logrotate.conf.template" \
  >"$destination/etc/pgbackrest-logrotate.conf"
chmod 644 "$destination/etc/pgbackrest-logrotate.conf"
install -m 755 "$source_directory/rotate-pgbackrest-logs" "$destination/usr/local/sbin/rotate-pgbackrest-logs"
envsubst '${LOG_DIRECTORY}' <"$source_directory/pgbackrest-logrotate.service.template" \
  >"$destination/etc/systemd/system/pgbackrest-logrotate.service"
chmod 644 "$destination/etc/systemd/system/pgbackrest-logrotate.service"
install -m 644 "$source_directory/pgbackrest-logrotate.timer" "$destination/etc/systemd/system/"

if [ -z "$destination" ]; then
  systemctl daemon-reload
  systemctl enable --now pgbackrest-logrotate.timer
  systemctl is-active --quiet pgbackrest-logrotate.timer
  systemctl list-timers pgbackrest-logrotate.timer --no-pager
else
  # Validate/enable the installed timer offline without starting host services.
  systemctl --root="$destination" enable pgbackrest-logrotate.timer
fi
