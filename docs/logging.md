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

## Docker console logging

Keep `log-level-console=info` so foreground messages, warnings and errors reach
standard output/error. The shipped PostgreSQL archive command inherits Docker's
streams, so its foreground output appears in `docker logs`. Detached async workers
close those streams; preserve their file logging at `info`.

`docker exec ... pgbackrest backup` attaches output to the exec client, which
Docker does not automatically add to the container's main log stream. Use the
shipped helper for scheduled backup/expire commands:

```bash
docker exec --user postgres ethos-postgres-18 \
  pgbackrest-docker --stanza=main --type=full backup
# Expire is normally automatic after backup. For an existing standalone job:
docker exec --user postgres ethos-postgres-18 \
  pgbackrest-docker --stanza=main expire
```

`pgbackrest-docker` forwards both streams to PID 1's Docker-connected descriptors,
preserves the pgBackRest exit status, and disables file logging for that invocation
to avoid duplicate records. An explicit `--log-level-file=debug` still overrides
that setting. It starts no background process and cannot be used for
`archive-push`/`archive-get`, whose detached-worker diagnostics need file logging.
Use it inside this image, as the same `postgres` UID as PID 1, with `--init` and
without a TTY. Descriptor permission errors fail the command visibly.

Keep plain `pgbackrest` for interactive commands or machine-readable results
such as `docker exec ... pgbackrest --output=json info`: the helper deliberately
sends output to Docker rather than returning it to the exec client. Existing
external backup schedules must be updated to call the helper; this repository
contains no production backup scheduler. Plain pgBackRest retains its global
`info` file fallback, which the OS policy also rotates.

Configure Docker's existing logger to bound console log storage. The deployment
example uses the built-in `local` driver, with compression and fourteen 25 MiB
files. This is a size/file-count limit, **not fourteen days** of console retention.
Retain an existing centrally managed driver if one already supplies rotation and
retention. Docker owns these files; never run OS logrotate against Docker's log
storage. See [Docker logging](https://docs.docker.com/engine/logging/)
and the [local driver](https://docs.docker.com/engine/logging/drivers/local/).

## Native OS rotation of remaining file logs

Use a dedicated host bind mount:

```
/var/log/ethos-postgres-18/pgbackrest -> /var/log/pgbackrest
```

Logs survive container recreation and are visible to normal host tools. Preserve
both existing PostgreSQL and backup mounts:

```
/srv/platform/postgres-18           -> /var/lib/postgresql
/srv/platform/postgres-18/pgbackrest -> /var/lib/pgbackrest
```

The host needs systemd 249+ with its distribution's `logrotate.timer`,
`logrotate.service` and `systemd-tmpfiles-clean.timer`, plus logrotate, gzip,
findutils, coreutils and gettext-base. The installer adds configuration to these
existing OS facilities; there is no custom rotation service, scheduler, expiry
script, log tailer or additional container daemon.

| Installed configuration | Responsibility |
| --- | --- |
| `/etc/logrotate.d/pgbackrest` | Daily/25 MiB rotation, gzip, ownership and count limits |
| `/etc/systemd/system/logrotate.timer.d/pgbackrest-hourly.conf` | Check the existing host rotation policies hourly |
| `/etc/systemd/system/logrotate.service.d/pgbackrest.conf` | Allow the dedicated directory through OS service filesystem restrictions |
| `/etc/tmpfiles.d/pgbackrest.conf` | Native age cleanup of closed rotations from inactive commands |

The installer enables/starts the OS timers and restarts `logrotate.timer` to
apply its drop-in. The hourly schedule applies **host-wide**: daily/weekly
policies remain daily/weekly, while other size-based policies may also rotate
sooner. Inspect the host's existing configuration before deployment. Keep the
OS service's hardening and its standard state file; there is no second state file
or competing pgBackRest rotation job. The host's `/etc/logrotate.conf` must include
`/etc/logrotate.d`, as the distribution default does.

File policy:

- Rotate every `*.log` daily or when larger than 25 MiB at an hourly check.
- Gzip immediately into the `rotated/` subdirectory, created as `0750` with the
  supplied PostgreSQL host UID/GID. The live log inode and permissions survive.
- Keep up to 336 rotations per log (24 × 14), plus `maxage 14`.
- Logrotate only applies `maxage` when a live log rotates. For inactive or missing
  originals, the OS tmpfiles cleaner expires files in `rotated/` after fourteen
  days based on modification time (`m:14d`). Its stock daily schedule means age
  cleanup can lag by roughly a day. Viewing an old file does not extend retention.
- The cleaner never targets the directory containing live logs. Only closed
  diagnostic rotations belong in `rotated/`; do not put other files there.
- Missing and empty logs are harmless. Extra manual rotations can shorten history.

The installer renders rotation, expiry and filesystem-access paths from one host
directory argument, with the existing path as default. Custom paths must be
absolute and use only letters, digits, `_`, `.`, `/` and `-`, without trailing
slashes or `.`/`..` components. Avoid home/private temporary directories hidden by
OS service hardening. For a custom container `PGBACKREST_LOG_PATH`, mount the host
directory there and pass the host directory as the installer's third argument.

pgBackRest keeps an `O_APPEND` descriptor open and has no reopen hook used here.
Logrotate's `copytruncate` preserves it without signalling the archiver; renaming
a live log could leave a worker writing into the old inode indefinitely. There
is a small diagnostic-message-loss window between copy and truncate. These logs
are operational diagnostics, not authoritative audit/integrity evidence. WAL,
backup and data files are outside both policies. See the
[pgBackRest log implementation](https://github.com/pgbackrest/pgbackrest/blob/main/src/common/log.c),
[logrotate manual](https://github.com/logrotate/logrotate/blob/main/logrotate.8.in)
and [tmpfiles configuration](https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html).

Hourly checks are not a hard cap; fast writers can exceed 25 MiB between checks.
Copytruncate temporarily needs an uncompressed copy before compression. The
installer performs a read-only capacity check for all live log sizes plus the
largest log plus 64 MiB before enabling timers. Routine execution belongs entirely
to OS logrotate: this is **not a recurring disk-space reservation or I/O limit**.
Keep host free-space alerts; use a dedicated filesystem/quota for a hard capacity
limit. Preserve diagnostics and explicitly reclaim the incident log before the
first scheduled run if space is tight. No deployment step truncates live logs.

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
   COPY --chmod=755 pgbackrest-docker /usr/local/bin/pgbackrest-docker
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
       logging:
         driver: local
         options:
           max-size: "25m"
           max-file: "14"
           compress: "true"
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

6. Inspect the host's native schedulers and install dependencies/configuration:

   ```bash
   # Debian/Ubuntu host, if dependencies are missing:
   sudo apt-get update
   sudo apt-get install -y logrotate gzip findutils coreutils gettext-base
   systemctl cat logrotate.timer logrotate.service systemd-tmpfiles-clean.timer
   # Confirm the distribution config includes /etc/logrotate.d:
   sudo grep -E '^include[[:space:]]+/etc/logrotate.d' /etc/logrotate.conf
   postgres_uid=$(sudo stat -c %u /var/log/ethos-postgres-18/pgbackrest)
   postgres_gid=$(sudo stat -c %g /var/log/ethos-postgres-18/pgbackrest)
   sudo ./ops/install-log-rotation.sh "$postgres_uid" "$postgres_gid"
   # For a custom host directory, pass its own host UID/GID and path instead:
   # sudo ./ops/install-log-rotation.sh "$postgres_uid" "$postgres_gid" /srv/diagnostics/postgres
   systemctl is-enabled logrotate.timer
   systemctl is-active logrotate.timer systemd-tmpfiles-clean.timer
   systemctl list-timers logrotate.timer systemd-tmpfiles-clean.timer --all
   # A real normal rotation check for all host policies, when ready:
   sudo systemctl start logrotate.service
   sudo journalctl -u logrotate.service --since today --no-pager
   ```

   Installation starts the existing timers. Their first scheduled/catch-up run
   can rotate logs. The installer does not force rotation, truncate logs or
   restart PostgreSQL/Docker. Its capacity preflight is read-only and aborts
   before installation if insufficient; an already enabled OS timer continues
   to operate. Timer activation or config-validation failure is an incomplete
   deployment and must be resolved before leaving the host unattended.

   If an earlier revision of this PR was installed for testing, first disable
   `pgbackrest-logrotate.timer` and let its service finish. Remove only its old
   service/timer, `/etc/pgbackrest-logrotate.conf` and
   `/usr/local/sbin/rotate-pgbackrest-logs`; retain logs/state. Never run both the
   old pgBackRest job and OS logrotate against the same live files. Closed
   rotations from that older flat layout need an operator-managed move into
   `rotated/` to join native age cleanup; installation does not move/delete them.

7. Update existing scheduled backup/expire invocations to use `pgbackrest-docker`
   and verify their messages through `docker logs`. Keep PostgreSQL's
   `archive_command` using plain `pgbackrest`; no WAL behavior changes are needed.

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
  'zgrep -hE "WARN|ERROR|dropped|DROP" /var/log/pgbackrest/*.log /var/log/pgbackrest/rotated/*.gz | tail -n 100'
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
docker inspect --format '{{json .HostConfig.LogConfig}}' ethos-postgres-18
# Parse rotation decisions without changing any logs or state:
sudo logrotate --debug /etc/logrotate.conf
# Normal manual check through the existing OS service/state:
sudo systemctl start logrotate.service
# Native cleanup of only this policy's closed rotations:
sudo systemd-tmpfiles --clean /etc/tmpfiles.d/pgbackrest.conf
# Read-only preflight before any optional forced rotation:
./ops/install-log-rotation.sh --check-space /var/log/ethos-postgres-18/pgbackrest
```

For a forced rotation, stop `logrotate.timer`, wait for any running
`logrotate.service` to finish, run `sudo logrotate --force
/etc/logrotate.d/pgbackrest`, then restart `logrotate.timer` even if the forced
command fails. Use the same state options as the OS service if the host customized
them. Do not force twice in the same second (timestamp collision). Normal service
starts are preferred. Check both OS timers after installation and host reboot;
monitor native service failures and new archive errors after rotation.

Rollback the image through the normal maintenance process, retaining explicit
`info`, the corrected template, log mount and OS rotation. Change scheduled jobs
back to plain pgBackRest if the older image lacks `pgbackrest-docker`; they will
again write files governed by OS rotation. No database/data rollback is needed.

To remove this rotation integration, remove only `/etc/logrotate.d/pgbackrest`,
`/etc/tmpfiles.d/pgbackrest.conf`,
`/etc/systemd/system/logrotate.timer.d/pgbackrest-hourly.conf` and
`/etc/systemd/system/logrotate.service.d/pgbackrest.conf`, then run
`sudo systemctl daemon-reload` and `sudo systemctl restart logrotate.timer`.
Keep log files and the shared OS state. **Do not disable the OS logrotate or
tmpfiles timers**: they also maintain other applications. Removing the hourly
drop-in restores the prior host schedule; make sure another policy covers any
remaining pgBackRest files before removing its configuration.

## Validation

```bash
python3 tests/test_log_rotation.py
docker build --build-arg POSTGRES_VERSION="$(cat POSTGRES_VERSION)" \
  -t postgres-backrest:logging-test .
./tests/smoke-image.sh postgres-backrest:logging-test
```

Host tests invoke real OS logrotate and tmpfiles on temporary logs. They verify
threshold/daily rotation, compression, inactive-log expiry, append-descriptor
continuity, ownership/permissions, custom-directory consistency, installation
preflight, and offline integration with distribution-owned timers. They do not
start or alter host services. Staged OS units and their drop-ins pass
`systemd-analyze verify`.

Image tests use disposable containers, tmpfs data/repositories, temporary log
mounts and Docker's actual `local` logger. They verify console receipt from archive
commands and scheduled backup/expire jobs, command failure propagation, absence
of duplicate backup files, retained async file logging, default/explicit debug,
a real full backup and repository WAL receipt, and recreation persistence.
Archive IDs come from backup database metadata. CI runs both suites. Production
mount permissions, existing scheduler policies, logger settings and archive health
remain operator checks; nothing deploys automatically to the database host.
