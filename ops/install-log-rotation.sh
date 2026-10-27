#!/usr/bin/env bash
set -euo pipefail

check_space() {
  # One-time read-only capacity check before enabling the OS scheduler. Routine
  # rotation is entirely owned by logrotate; capacity monitoring stays on the host.
  local total=0 largest=0 sizes bytes available required
  local directory="$1"
  sizes="$(find "$directory" -maxdepth 1 -type f -name '*.log' -printf '%s\n')"
  while IFS= read -r bytes; do
    [ -n "$bytes" ] || continue
    total=$((total + bytes))
    if ((bytes > largest)); then largest="$bytes"; fi
  done <<< "$sizes"
  available="$(df -B1 --output=avail "$directory" | tail -n 1)"
  required=$((total + largest + 64 * 1024 * 1024))
  if ((total > 0 && available < required)); then
    echo "Insufficient rotation space: need $required bytes, have $available. Preserve diagnostics and explicitly reclaim space before installation." >&2
    exit 1
  fi
}

if [ "$#" -eq 2 ] && [ "$1" = --check-space ]; then
  check_space "$2"
  exit 0
fi

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] || ! [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]]; then
  echo "Usage: sudo $0 POSTGRES_HOST_UID POSTGRES_HOST_GID [ABSOLUTE_LOG_DIRECTORY]" >&2
  echo "       $0 --check-space LOG_DIRECTORY (read-only)" >&2
  exit 2
fi

# DESTDIR stages configuration and enables OS timers offline for validation.
destination="${DESTDIR:-}"
source_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export LOG_DIRECTORY="${3:-/var/log/ethos-postgres-18/pgbackrest}"
export LOG_UID="$1" LOG_GID="$2"
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
  [ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
  for dependency in logrotate gzip find df envsubst systemctl systemd-tmpfiles; do
    command -v "$dependency" >/dev/null
  done
  systemctl cat logrotate.timer logrotate.service systemd-tmpfiles-clean.timer >/dev/null
  if ! grep -Eq '^[[:space:]]*include[[:space:]]+"?/etc/logrotate.d/?"?([[:space:]]|$)' /etc/logrotate.conf; then
    echo "The OS /etc/logrotate.conf must include /etc/logrotate.d." >&2
    exit 1
  fi
  [ -d "$LOG_DIRECTORY" ] || { echo "Create the dedicated log bind mount first (see docs/logging.md)." >&2; exit 1; }
  [ "$(stat -c %u:%g "$LOG_DIRECTORY")" = "$LOG_UID:$LOG_GID" ] || {
    echo "Log directory ownership does not match supplied host IDs." >&2; exit 1;
  }
  check_space "$LOG_DIRECTORY"
fi

install -d "$destination/etc/logrotate.d" "$destination/etc/tmpfiles.d" \
  "$destination/etc/systemd/system/logrotate.timer.d" \
  "$destination/etc/systemd/system/logrotate.service.d"
envsubst '${LOG_DIRECTORY} ${LOG_UID} ${LOG_GID}' \
  <"$source_directory/pgbackrest-logrotate.conf.template" >"$destination/etc/logrotate.d/pgbackrest"
envsubst '${LOG_DIRECTORY}' <"$source_directory/pgbackrest-tmpfiles.conf.template" \
  >"$destination/etc/tmpfiles.d/pgbackrest.conf"
envsubst '${LOG_DIRECTORY}' <"$source_directory/logrotate-service.conf.template" \
  >"$destination/etc/systemd/system/logrotate.service.d/pgbackrest.conf"
chmod 644 "$destination/etc/logrotate.d/pgbackrest" "$destination/etc/tmpfiles.d/pgbackrest.conf" \
  "$destination/etc/systemd/system/logrotate.service.d/pgbackrest.conf"
install -m 644 "$source_directory/logrotate-hourly.conf" \
  "$destination/etc/systemd/system/logrotate.timer.d/pgbackrest-hourly.conf"

if [ -z "$destination" ]; then
  logrotate --debug /etc/logrotate.conf
  # Validate this age policy without running cleanup or creating/truncating files.
  systemd-tmpfiles --create /etc/tmpfiles.d/pgbackrest.conf
  systemctl daemon-reload
  systemctl enable --now logrotate.timer
  systemctl restart logrotate.timer
  systemctl add-wants timers.target systemd-tmpfiles-clean.timer
  systemctl start systemd-tmpfiles-clean.timer
  systemctl is-active --quiet logrotate.timer systemd-tmpfiles-clean.timer
  systemctl list-timers logrotate.timer systemd-tmpfiles-clean.timer --no-pager
else
  systemctl --root="$destination" enable logrotate.timer
  systemctl --root="$destination" add-wants timers.target systemd-tmpfiles-clean.timer
fi
