# pgBackRest logging and rotation

## Configuration and cause

The old entrypoint exported `PGBACKREST_LOG_LEVEL_FILE=debug` unless explicitly
overridden. `envsubst` wrote that value into the global pgBackRest configuration.
The exported environment also reached PostgreSQL's archive command and its async
workers. There was no scheduler, logrotate configuration, or log cleanup in this
repository. Logs accumulated in the container's writable layer.

The entrypoint now defaults file logging to `info`, including its no-template
fallback. Console logging remains `info`; both include errors and warnings. The
shipped template uses the global settings for all stanzas and commands, including
async archive-push, backup and automatic backup expiration. No backup retention,
archive queue, authentication, networking or data paths have been changed.

| Setting | Default |
| --- | --- |
| `PGBACKREST_LOG_LEVEL_FILE` | `info` |
| `PGBACKREST_LOG_LEVEL_CONSOLE` | `info` |
| `PGBACKREST_LOG_PATH` | `/var/log/pgbackrest` |

pgBackRest command-line options take precedence over environment settings, which
take precedence over configuration files ([command reference](https://pgbackrest.org/command.html)). Command-specific configuration sections,
additional files in `/etc/pgbackrest/conf.d`, alternate `--config` paths, and
external backup scripts must also be audited. `docker exec` does not run the
entrypoint or inherit variables exported by it: it sees Docker's configured
environment plus the rendered configuration file. A hardcoded debug level in a
mounted template can therefore still affect commands run with `docker exec`.

Inspect the host-side template mounted at
`/usr/local/share/pgbackrest/pgbackrest.conf.template` in the container. Find its
host source using `docker inspect --format '{{json .Mounts}}' <container>`.
Preserve its repository credentials and other settings; replace only its logging
settings with these global entries, and remove any command/stanza debug overrides:

```ini
[global]
log-level-file=${PGBACKREST_LOG_LEVEL_FILE}
log-level-console=${PGBACKREST_LOG_LEVEL_CONSOLE}
log-path=${PGBACKREST_LOG_PATH}
```

Use simple `${VARIABLE}` references: `envsubst` does not expand shell fallback
expressions such as `${VARIABLE:-value}`. Older published image templates used
that syntax. Keep other production values intact while converting any such
references; the entrypoint supplies the defaults for the shipped variables.

Set `PGBACKREST_LOG_LEVEL_FILE=info` explicitly in the deployment too, so rollback
to an older image does not restore its debug default. Remove unintended debug
flags from scheduled backup/expire commands and `archive_command`. The repository's
archive command specifies only console `info`; it does not override file logging.

For one troubleshooting command, use:

```bash
docker exec --user postgres ethos-postgres-18 \
  pgbackrest --stanza=main --log-level-file=debug info
```

For archive workers, temporarily set `PGBACKREST_LOG_LEVEL_FILE=debug` in the
managed deployment and recreate the container during an approved maintenance
window. Restore `info` afterwards. Editing the template alone does not update an
already rendered file or an existing process environment. Prefer a command-level
override when investigating backup operations to avoid a database restart.

## Rotation design

Use a dedicated host bind mount:

```
/var/log/ethos-postgres-18/pgbackrest -> /var/log/pgbackrest
```

This keeps diagnostic logs outside the database and backup directories, makes
host disk accounting straightforward, and preserves logs across container
recreation. Keep the existing mounts exactly as deployed:

```
/srv/platform/postgres-18           -> /var/lib/postgresql
/srv/platform/postgres-18/pgbackrest -> /var/lib/pgbackrest
```

`ops/install-log-rotation.sh` installs a host systemd oneshot service and enables
and starts its hourly timer. No scheduler or additional daemon runs inside the
database container, and no dependency is added to the image. The host needs
systemd, logrotate, gzip, GNU find/df and envsubst (Debian/Ubuntu packages:
`logrotate gzip findutils coreutils gettext-base`). The timer also works while
Docker is stopped. It persists across host reboot and catches up after downtime. Monitor
service failures through the host's existing systemd monitoring.

The dedicated `/etc/pgbackrest-logrotate.conf` is deliberately outside
`/etc/logrotate.d`, so the host daily job cannot compete with this timer.
The installer renders the service and rotation policy from the same log directory,
including the expiry argument and systemd write allowlist. Its optional third
argument selects a different absolute host log directory. Paths must use only
letters, digits, `_`, `.`, `/` and `-`, without trailing slashes or `.`/`..`
components. Home and temporary directories hidden by the service sandbox are
rejected. Use a dedicated directory outside database/backup storage.

The oneshot runs with `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`
and `NoNewPrivileges=true`. Only the selected log directory and systemd-managed
state directory are writable, apart from its private temporary directories.

- Check every hour; rotate all `*.log` files daily, or earlier at **25 MiB**.
- Compress immediately with gzip, including the latest rotation.
- Keep up to **336** rotations per log (24 × 14), with **14-day** maximum age.
  Extra forced manual rotations can shorten that history.
- The hourly runner also expires matching timestamped rotations older than 14
  days when the original log is empty, missing or inactive. It does not traverse
  subdirectories, follow symlinks, or expire live `*.log` files.
- Use second-resolution timestamp suffixes to allow multiple daily rotations.
- Keep state at `/var/lib/pgbackrest-logrotate/status` on the host, independently
  of the container and PostgreSQL mounts.
- Use the PostgreSQL process's **host** UID/GID for rotation. `copytruncate`
  preserves the live inode, ownership and mode (pgBackRest normally creates
  `0640` logs). Missing and empty logs are harmless.

pgBackRest opens its log with `O_APPEND` and keeps the descriptor open; it has no
log-reopen hook used by this deployment. Renaming and creating a fresh file could
leave an async worker writing indefinitely into a rotated/deleted inode. Use
`copytruncate` to retain that descriptor without signalling or stopping archiving.
There is a small race between copying and truncating during which diagnostic
messages can be lost. This is not a lossless audit-log mechanism; database/WAL
and repository files are never involved. This tradeoff avoids interrupting WAL
archiving. See [pgBackRest's log implementation](https://github.com/pgbackrest/pgbackrest/blob/main/src/common/log.c)
and the [logrotate manual](https://github.com/logrotate/logrotate/blob/main/logrotate.8.in).
Treat these files as operational diagnostics, not authoritative audit or integrity
evidence. If lossless audit evidence is required, use a separately designed
durable logging pipeline; changing this retention policy cannot supply it.

The threshold is checked hourly, not a hard size cap. A fast writer can exceed
25 MiB between checks. Before enabling the timer, the installer performs a
read-only space check. Each scheduled invocation expires aged rotations first,
then requires available bytes for copies of **all live logs plus the largest
live log again plus 64 MiB**. This conservative estimate covers outstanding copies
and one incompressible gzip output. If space is insufficient, the job fails visibly
in the journal before copying or truncating any live log; it does not automatically
clean up oversized live logs. It retries on the next hourly invocation.

The check does not reserve disk space, bound I/O, or prevent a log/another writer
from growing after the check. File count and age are bounded, but no policy can
guarantee disk capacity under arbitrary log rates or scheduler failure. Use existing free-space alerts;
use a dedicated filesystem/quota if a hard allocation limit is required. Keep
production at `info`. For a custom container `PGBACKREST_LOG_PATH`, mount the host
log directory at that container path and pass the host directory as the installer's
third argument; reinstall to update rotation, expiry and the sandbox together.

## Deployment (operator run; no automatic database restart)

The repository contains no production Compose file or remote deployment access.
Merge these additions into the existing deployment definition; do not replace its
other settings. The example assumes ordinary rootful Docker without user namespace
remapping. With remapping/rootless Docker, use the mapped host UID/GID of the log
files for ownership and the installer, rather than their container IDs.

1. Build/publish a new immutable image revision through the normal release
   process. The repository currently targets a newer base than production.
   Furthermore, the existing Dockerfile runs `apt-get upgrade`: even choosing
   `POSTGRES_VERSION=18.4` can install newer PostgreSQL packages. To apply only
   this logging fix, derive from the exact currently running image instead of
   rebuilding its packages. On the deployment host, from this checkout:

   ```bash
   docker image tag "$(docker inspect --format '{{.Image}}' ethos-postgres-18)" \
     postgres-backrest:logging-base
   docker build -f - -t postgres-backrest:18.4-logging-r1 . <<'DOCKERFILE'
   FROM postgres-backrest:logging-base
   COPY --chmod=755 entrypoint.sh /usr/local/bin/pg-entrypoint.sh
   COPY pgbackrest.conf.template /usr/local/share/pgbackrest/pgbackrest.conf.template
   DOCKERFILE
   ```

   Compare `postgres --version` and `pgbackrest version` in both images before
   deployment. Publish/pin the resulting revision or digest through the existing
   deployment process if builds happen on a different host. This patch adds no
   image dependencies. It also includes the current simple-variable template;
   a production template mounted over it must be updated separately in step 2.

2. Audit the mounted template and invocation overrides described above. Record
   current mounts and logging settings without dumping repository secrets:

   ```bash
   docker inspect --format '{{json .Mounts}}' ethos-postgres-18
   docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' ethos-postgres-18 \
     | grep '^PGBACKREST_LOG_' || true
   docker exec --user postgres ethos-postgres-18 psql -U postgres -d postgres \
     -c 'SHOW archive_command;'
   ```

3. Before removing/recreating the old container, preserve its logs by copying them
   to the new dedicated directory. This does not truncate the source logs. Ensure
   there is enough free host space for the copy (roughly 900 MB in this incident).
   A live copy is a diagnostic snapshot; writes after the copy remain in the old
   container until it is removed. Capture recent errors again just before removal
   if needed. Do not enable rotation against this directory yet.

   ```bash
   postgres_uid=$(docker exec --user postgres ethos-postgres-18 id -u)
   postgres_gid=$(docker exec --user postgres ethos-postgres-18 id -g)
   sudo install -d -m 0750 -o "$postgres_uid" -g "$postgres_gid" \
     /var/log/ethos-postgres-18/pgbackrest
   sudo docker cp -a ethos-postgres-18:/var/log/pgbackrest/. \
     /var/log/ethos-postgres-18/pgbackrest/
   sudo chown "$postgres_uid:$postgres_gid" /var/log/ethos-postgres-18/pgbackrest
   sudo chmod 0750 /var/log/ethos-postgres-18/pgbackrest
   ```

4. Update the existing deployment to the new image and add these settings (use
   the actual service name). Preserve both existing data mounts and all other
   deployment settings. On SELinux hosts, label only this dedicated log mount
   with `:Z` if required by the host policy.

   ```yaml
   services:
     postgres:
       image: postgres-backrest:18.4-logging-r1
       init: true
       environment:
         PGBACKREST_LOG_LEVEL_FILE: info
         PGBACKREST_LOG_LEVEL_CONSOLE: info
         PGBACKREST_LOG_PATH: /var/log/pgbackrest
       volumes:
         - /var/log/ethos-postgres-18/pgbackrest:/var/log/pgbackrest
         # Keep existing data, backup, template and config mounts here.
   ```

   Recreate only the database container during the approved maintenance window
   using the existing deployment tool. Do not use `down -v`, initialize a new
   database, or change `PGDATA`. No supplied installer restarts Docker/PostgreSQL.

5. Verify the effective runtime configuration below. Perform the optional
   one-time oversized-log cleanup in the next section. The deployment itself
   never truncates existing logs. If cleanup is skipped, the first scheduled
   rotation will copy/compress the oversized log and needs enough space.

6. Install the host dependencies, then install and start the rotation timer:

   ```bash
   # Debian/Ubuntu host, if dependencies are not installed:
   sudo apt-get update
   sudo apt-get install -y logrotate gzip findutils coreutils gettext-base
   # Read the host IDs again if the image or user mapping has changed:
   postgres_uid=$(sudo stat -c %u /var/log/ethos-postgres-18/pgbackrest)
   postgres_gid=$(sudo stat -c %g /var/log/ethos-postgres-18/pgbackrest)
   sudo ./ops/install-log-rotation.sh "$postgres_uid" "$postgres_gid"
   # Custom host directory, if used instead (must already exist with these IDs):
   # sudo ./ops/install-log-rotation.sh "$postgres_uid" "$postgres_gid" /srv/diagnostics/postgres
   systemctl is-enabled pgbackrest-logrotate.timer
   systemctl is-active pgbackrest-logrotate.timer
   systemctl list-timers pgbackrest-logrotate.timer --all
   sudo systemctl start pgbackrest-logrotate.service
   sudo journalctl -u pgbackrest-logrotate.service --since today --no-pager
   ```

   The last `start` performs a real normal rotation check; omit it until ready to
   rotate existing logs. Installation starts the timer, whose first scheduled or
   catch-up execution also performs a normal rotation check. Installer failure is
   an incomplete deployment: verify that the timer is both enabled and active.
   An insufficient-space error aborts installation before changing installed files
   or enabling the timer. Preserve useful diagnostics and explicitly reclaim space
   with the one-time procedure below, then retry. During reinstall, an already
   active timer remains active; its runtime space check also refuses unsafe copies.

## One-time reclaim of the existing 863 MB log

Run this explicitly after the new image, info settings and log bind mount are
verified, before enabling the timer. The live copy of the old log now resides in
the dedicated log mount. These commands preserve the last 20,000 lines and the
last 500 warning/error lines before truncating **only** the named diagnostic log.
They preserve the log inode and do not stop or signal the archiver. A few diagnostic
lines written during capture/cleanup may be absent from the saved excerpt.

Run in Bash on the deployment host:

```bash
set -euo pipefail
container=ethos-postgres-18
diagnostic_dir="$HOME/pgbackrest-diagnostics-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$diagnostic_dir"
# Both captures must finish successfully before the explicit truncate.
docker exec --user postgres "$container" \
  tail -n 20000 /var/log/pgbackrest/main-archive-push-async.log \
  | gzip > "$diagnostic_dir/archive-last-20000-lines.log.gz"
docker exec --user postgres "$container" bash -o pipefail -ec \
  'awk "/WARN|ERROR/ { print }" /var/log/pgbackrest/main-archive-push-async.log | tail -n 500' \
  | gzip > "$diagnostic_dir/archive-recent-warnings-errors.log.gz"
gzip -t "$diagnostic_dir/"*.gz
chmod 0600 "$diagnostic_dir/"*.gz
# Explicit operator cleanup. No database, WAL or repository files are targeted.
docker exec --user postgres "$container" \
  truncate -s 0 /var/log/pgbackrest/main-archive-push-async.log
docker exec --user postgres "$container" \
  stat -c '%n %s bytes %u:%g %a' /var/log/pgbackrest/main-archive-push-async.log
```

The diagnostic directory is outside the rotating directory; retain or remove it
according to the incident's needs. To preserve the entire log instead of excerpts,
stream it through gzip to a separate diagnostic file and verify that file before
truncation. Do not rename/delete a live log or manipulate Docker `overlay2`.
Container recreation releases the old container's writable layer after Docker
removes it normally; truncating the copied bind-mounted log reclaims the additional
host copy. Never delete PostgreSQL WAL, archives, backup files or volumes.

## Effective settings and health checks

These checks do not change database or backup contents. Adapt database/user and
stanza names if production differs. `help` may write diagnostic log lines.

```bash
# Verify rendered logging entries without printing secrets.
docker exec --user postgres ethos-postgres-18 sh -c \
  'grep -nE "^\\[|^log-(level|path)" /etc/pgbackrest/pgbackrest.conf'
# These resolve native environment/config options, rather than just reading a template.
for command in archive-push archive-get backup expire restore check; do
  docker exec --user postgres ethos-postgres-18 \
    pgbackrest help "$command" log-level-file
done
# Expect "current: info". Compare actual command-begin lines for async/backup jobs,
# including any CLI overrides supplied by their schedulers.
docker exec --user postgres ethos-postgres-18 sh -c \
  'tail -n 100 /var/log/pgbackrest/main-archive-push-async.log'

docker exec --user postgres ethos-postgres-18 psql -U postgres -d postgres -x -c \
  'SELECT archived_count, failed_count, last_archived_wal, last_archived_time,
          last_failed_wal, last_failed_time, stats_reset FROM pg_stat_archiver;'
docker exec --user postgres ethos-postgres-18 \
  pgbackrest --stanza=main info
docker exec --user postgres ethos-postgres-18 \
  pgbackrest --stanza=main --output=json info
# Searches compressed and current logs. Exit 1 can mean no matching messages.
docker exec --user postgres ethos-postgres-18 sh -c \
  'zgrep -hE "WARN|ERROR|dropped|DROP" /var/log/pgbackrest/*.log* | tail -n 100'
docker logs --since 24h ethos-postgres-18 2>&1 \
  | grep -Ei 'archive|pgbackrest|warn|error' | tail -n 100
# Inspect only: ready files should drain as natural WAL activity progresses.
docker exec --user postgres ethos-postgres-18 sh -c \
  'find "$PGDATA/pg_wal/archive_status" -maxdepth 1 -type f -name "*.ready" -printf "%f %TY-%Tm-%Td %TH:%TM:%TS\n"'
```

The five historical failures are cumulative, not evidence of five currently
missing segments. Compare counters, timestamps, backlog, and repository results
across two observations during normal activity. Do not reset the statistics.
Successful `archive_command` execution is insufficient proof of remote receipt:
async acknowledgements and a configured `archive-push-queue-max` can mask dropped
WAL. Inspect the effective queue setting (`pgbackrest help archive-push
archive-push-queue-max`), async errors/successes and the destination itself. Do not
change queue limits or retry behavior as part of this logging fix.

For a specific closed WAL segment reported by `last_archived_wal`, verify it is
present in the actual destination using pgBackRest's repository listing. For the
existing local repo, replacing the example WAL and database archive ID with the
values from `info` (the archive ID might differ from `18-1` after stanza upgrades):

Choose a regular 24-character hexadecimal WAL name. `last_archived_wal` may
instead name a `.backup` or `.history` file; in that case select a closed segment
from the backup's archive metadata or the async success log.

```bash
# Read-only repository inspection; does not fetch through the async archive-get queue.
docker exec --user postgres ethos-postgres-18 \
  pgbackrest --stanza=main --repo=1 repo-ls archive/main
docker exec --user postgres ethos-postgres-18 \
  pgbackrest --stanza=main --repo=1 repo-ls \
  --filter='^000000010000000000000058-' archive/main/18-1/0000000100000000
```

A matching WAL filename proves object presence, not full recovery integrity. Verify
all configured repositories (`--repo=N`) and run regular isolated restore drills.
`info` reports backup metadata and archive ranges; it does not validate every WAL
segment. If a stronger check is needed, `pgbackrest --stanza=main check` actively
checks archiving, can request a WAL switch, and writes status/logs: schedule it
separately rather than treating it as read-only. The automated disposable-container
smoke test runs that check and a real backup; production commands above do not.

## Routine operations and rollback

```bash
sudo du -sh /var/log/ethos-postgres-18/pgbackrest
sudo df -h /var/log/ethos-postgres-18/pgbackrest
docker inspect --size --format '{{.SizeRw}}' ethos-postgres-18
# Parse and show rotation decisions, without changing logs/state:
sudo logrotate --debug --state /var/lib/pgbackrest-logrotate/status /etc/pgbackrest-logrotate.conf
# Normal manual check (same serialization as the timer):
sudo systemctl start pgbackrest-logrotate.service
# Explicit forced rotation, only if needed; avoid the hourly job running concurrently:
sudo systemctl stop pgbackrest-logrotate.timer
sudo /usr/local/sbin/rotate-pgbackrest-logs --check-space /var/log/ethos-postgres-18/pgbackrest
sudo logrotate --force --state /var/lib/pgbackrest-logrotate/status /etc/pgbackrest-logrotate.conf
sudo systemctl start pgbackrest-logrotate.timer
```

Do not force twice in the same second (timestamp collision). A forced invocation
should also wait for any running `pgbackrest-logrotate.service` to finish. Normal
service starts are preferred. Review journal failures and timer status after
installation and host reboot; monitor for new archive errors after rotation.

To roll back the image, deploy the previous image through the normal maintenance
process while retaining the explicit `info` environment, corrected mounted
template, log mount and host rotation. No data rollback is needed. To roll back
rotation separately, run `sudo systemctl disable --now
pgbackrest-logrotate.timer`, wait for a running service to finish, then remove
only the installed service/timer, `/etc/pgbackrest-logrotate.conf` and
`/usr/local/sbin/rotate-pgbackrest-logs`, and run `sudo systemctl daemon-reload`.
Keep log files and state for investigation. Disabling rotation requires another
rotation arrangement or logs will accumulate again.

## Validation

```bash
python3 tests/test_log_rotation.py
docker build --build-arg POSTGRES_VERSION="$(cat POSTGRES_VERSION)" \
  -t postgres-backrest:logging-test .
./tests/smoke-image.sh postgres-backrest:logging-test
```

Host tests use sparse temporary logs, actual logrotate/gzip, an open append
writer, old timestamps, missing/empty files, file ownership/modes, and an offline
systemd installation that actually enables the staged timer. They never enable
host services. Both default and custom installs undergo `systemd-analyze verify`;
tests assert equality of rotation, expiry and sandbox paths and reject ambiguous
paths. Simulated low-space tests verify that preflight is read-only, aged rotations
still expire, and live files remain intact. Image tests use only disposable
containers, tmpfs data/repositories and temporary logs; they verify default and explicit debug levels, fallback and
mounted templates, native effective settings through `docker exec`, a real full
backup, asynchronous archiving, and log/config persistence across recreation.
Repository checks derive the archive ID from the backup's database metadata.
CI runs both suites. Host timer execution, permissions under the deployment's
user mapping/SELinux policy, production template overrides, and archive health
remain required operator checks after deployment.
