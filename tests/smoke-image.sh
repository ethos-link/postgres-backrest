#!/usr/bin/env bash
set -euo pipefail
image="${1:-postgres-backrest:logging-test}"
name="pgbackrest-logging-test-$$"
temporary="$(mktemp -d)"
container_started=false
cleanup() {
  if "$container_started"; then docker rm -f "$name" >/dev/null; fi
  rm -rf "$temporary"
}
trap cleanup EXIT

for command in archive-push archive-get backup expire restore check; do
  output="$(docker run --rm --mount type=tmpfs,destination=/var/lib/postgresql \
    "$image" pgbackrest help "$command" log-level-file)"
  [[ "$output" == *'current: info'* ]]
done
output="$(docker run --rm --mount type=tmpfs,destination=/var/lib/postgresql \
  -e PGBACKREST_LOG_LEVEL_FILE=debug "$image" pgbackrest help backup log-level-file)"
[[ "$output" == *'current: debug'* ]]
# The Docker helper avoids file duplication but keeps explicit CLI debugging.
for level in off debug; do
  options=()
  if [ "$level" = debug ]; then options+=(--log-level-file=debug); fi
  output="$(docker run --rm --mount type=tmpfs,destination=/var/lib/postgresql \
    "$image" pgbackrest-docker "${options[@]}" help backup log-level-file)"
  [[ "$output" == *"current: $level"* ]]
done
output="$(docker run --rm --mount type=tmpfs,destination=/var/lib/postgresql \
  "$image" pgbackrest --log-level-file=debug help backup log-level-file)"
[[ "$output" == *'current: debug'* ]]
# Fallback configuration also respects default info and explicit debug.
for level in info debug; do
  output="$(docker run --rm --user root --entrypoint bash \
    --mount type=tmpfs,destination=/var/lib/postgresql \
    -e PGBACKREST_LOG_LEVEL_FILE="$level" "$image" -c \
    'rm /usr/local/share/pgbackrest/pgbackrest.conf.template
     exec setpriv --reuid=postgres --regid=postgres --init-groups pg-entrypoint.sh pgbackrest help backup log-level-file')"
  [[ "$output" == *"current: $level"* ]]
done

# The entrypoint's default export takes precedence over a custom template's
# hardcoded debug level for commands launched through the entrypoint.
printf '[global]\nlog-level-file=debug\n' > "$temporary/custom.template"
output="$(docker run --rm --mount type=tmpfs,destination=/var/lib/postgresql \
  -v "$temporary/custom.template:/usr/local/share/pgbackrest/pgbackrest.conf.template:ro,Z" \
  "$image" pgbackrest help backup log-level-file)"
[[ "$output" == *'current: info'* ]]

mkdir "$temporary/logs"
chmod 777 "$temporary/logs"
# Two disposable containers demonstrate regeneration and log persistence.
for iteration in 1 2; do
  docker run -d --init --name "$name" \
    --log-driver local --log-opt max-size=25m --log-opt max-file=14 --log-opt compress=true \
    --mount type=tmpfs,destination=/var/lib/postgresql \
    --mount type=tmpfs,destination=/var/lib/pgbackrest,tmpfs-mode=0777 \
    -v "$temporary/logs:/var/log/pgbackrest:Z" \
    -e POSTGRES_PASSWORD=temporary-test-password "$image" \
    postgres -c shared_buffers=32MB -c max_wal_size=128MB -c min_wal_size=32MB >/dev/null
  container_started=true
  ready=false
  for attempt in {1..60}; do
    if docker exec "$name" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then ready=true; break; fi
    sleep 1
  done
  if ! "$ready"; then docker logs "$name"; exit 1; fi
  docker exec "$name" bash -ec \
    'test "$(sed -n "s/^log-level-file=//p" /etc/pgbackrest/pgbackrest.conf)" = info'
  # docker exec does not inherit entrypoint exports: verify rendered config too.
  output="$(docker exec "$name" pgbackrest help archive-push log-level-file)"
  [[ "$output" == *'current: info'* ]]
  if [ "$iteration" -eq 1 ]; then
    docker exec "$name" pgbackrest --stanza=main stanza-create
    docker exec "$name" pgbackrest --stanza=main check
    failures_before="$(docker exec "$name" psql -U postgres -Atc 'SELECT failed_count FROM pg_stat_archiver')"
    docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -c \
      "CREATE TABLE logging_smoke AS SELECT 42 AS answer;"
    # Scheduled commands explicitly forward both streams to Docker's logger,
    # with file logging disabled for that invocation to avoid duplicate records.
    docker exec "$name" pgbackrest-docker --stanza=main --type=full backup
    docker exec "$name" sh -ec 'test ! -e /var/log/pgbackrest/main-backup.log; test ! -e /var/log/pgbackrest/main-expire.log'
    output="$(docker logs "$name" 2>&1)"
    [[ "$output" == *'backup command end: completed successfully'* ]]
    [[ "$output" == *'expire command end: completed successfully'* ]]
    # CLI errors must retain their exit status and reach Docker too.
    if docker exec "$name" pgbackrest-docker --invalid-docker-logging-probe; then
      echo 'Expected a nonzero status for an invalid pgBackRest option.' >&2
      exit 1
    fi
    output="$(docker logs "$name" 2>&1)"
    [[ "$output" == *"invalid-docker-logging-probe"* ]]
    # Async commands must not accidentally lose their detached-worker logs.
    if docker exec "$name" pgbackrest-docker --stanza=main archive-push; then
      echo 'Expected the Docker helper to reject archive commands.' >&2
      exit 1
    fi
    docker exec "$name" pgbackrest --stanza=main --output=json info > "$temporary/info.json"
    python3 - "$temporary/info.json" <<'PY'
import json, sys
stanza = json.load(open(sys.argv[1]))[0]
assert stanza['status']['code'] == 0, stanza
assert stanza['backup'], stanza
assert stanza['archive'][0]['max'], stanza
PY
    docker exec "$name" pgbackrest --stanza=main check
    output="$(docker logs "$name" 2>&1)"
    [[ "$output" == *'archive-push command begin'* ]]
    failures_after="$(docker exec "$name" psql -U postgres -Atc 'SELECT failed_count FROM pg_stat_archiver')"
    test "$failures_before" = "$failures_after"
    # Check real async command logging and actual repository receipt, beyond
    # PostgreSQL's archive-command success counter.
    docker exec "$name" bash -ec \
      'grep -q -- "--log-level-file=info" /var/log/pgbackrest/main-archive-push-async.log
       ! grep -qE "[[:space:]]DEBUG:" /var/log/pgbackrest/*.log'
    # A backup history filename can be last_archived_wal; check the known closed
    # data segment recorded by backup metadata instead.
    archive_metadata="$(python3 - "$temporary/info.json" <<'PY'
import json, sys
stanza = json.load(open(sys.argv[1]))[0]
backup = stanza['backup'][-1]
archive = next(item for item in stanza['archive']
               if item['database'] == backup['database'])
print(backup['archive']['stop'], archive['id'])
PY
)"
    read -r wal archive_id <<< "$archive_metadata"
    output="$(docker exec "$name" pgbackrest --stanza=main --repo=1 repo-ls \
      --filter="^$wal-" "archive/main/$archive_id/${wal:0:16}")"
    [[ "$output" == *"$wal-"* ]]
    docker exec "$name" psql -U postgres -v ON_ERROR_STOP=1 -c \
      'SELECT archived_count, failed_count, last_archived_wal FROM pg_stat_archiver;'
    docker exec "$name" sh -ec 'test -s /var/log/pgbackrest/main-archive-push-async.log; printf "persistence marker\n" >> /var/log/pgbackrest/persistence.log'
  else
    docker exec "$name" sh -ec 'test "$(cat /var/log/pgbackrest/persistence.log)" = "persistence marker"'
  fi
  docker rm -f "$name" >/dev/null
  container_started=false
done
echo 'PASS: Docker logging, effective settings, explicit debug, backup, async archive and recreation'
