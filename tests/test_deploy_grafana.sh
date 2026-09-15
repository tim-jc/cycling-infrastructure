#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export CALLS="$TMP/calls" STATE="$TMP/state"

cat >"$TMP/preflight" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' preflight >>"$CALLS"
MOCK

cat >"$TMP/compose" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'compose %s\n' "$*" >>"$CALLS"
case "$*" in
  'config --quiet') : ;;
  'up -d --no-deps mariadb') printf '%s' reconciled >"$STATE" ;;
  'pull grafana') : ;;
  'config --images') printf '%s\n' grafana/grafana:13.2.1 ;;
  'up -d grafana') [[ "$(cat "$STATE")" == reconciled ]] ;;
  'ps -q grafana') printf '%s\n' grafana-id ;;
  *) printf 'unexpected Compose command: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK

cat >"$TMP/reader" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'reader %s\n' "$*" >>"$CALLS"
[[ "$(cat "$STATE")" == reconciled ]] || {
  printf '%s\n' 'reader attempted against unreconciled MariaDB' >&2
  exit 1
}
MOCK

cat >"$TMP/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$CALLS"
case "$*" in
  'image inspect --format {{.Architecture}} grafana/grafana:13.2.1') printf '%s\n' arm64 ;;
  'inspect --format {{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}} grafana-id') printf '%s\n' healthy ;;
  *) printf 'unexpected Docker command: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK
chmod 700 "$TMP/preflight" "$TMP/compose" "$TMP/reader" "$TMP/docker"

deploy() {
  PREFLIGHT_SCRIPT="$TMP/preflight" COMPOSE_WRAPPER="$TMP/compose" \
    READER_SCRIPT="$TMP/reader" DOCKER_BIN="$TMP/docker" \
    "$ROOT/scripts/deploy_grafana.sh"
}

assert_sequence() {
  cat >"$TMP/expected" <<'EXPECTED'
preflight
compose config --quiet
compose up -d --no-deps mariadb
reader 
compose pull grafana
compose config --images
docker image inspect --format {{.Architecture}} grafana/grafana:13.2.1
compose up -d grafana
compose ps -q grafana
docker inspect --format {{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}} grafana-id
reader --check-only
EXPECTED
  cmp "$TMP/expected" "$CALLS"
}

# First deployment starts from a container without the new bind mount.
printf '%s' legacy >"$STATE"
deploy >"$TMP/out"
assert_sequence
grep -q 'Grafana 13.2.1 is healthy' "$TMP/out"

# A subsequent deployment runs the same safe, idempotent reconciliation path.
: >"$CALLS"
deploy >"$TMP/out"
assert_sequence

# A failed MariaDB reconciliation must stop before any reader or Grafana work.
cat >"$TMP/compose-fail" <<'MOCK'
#!/usr/bin/env bash
printf 'compose %s\n' "$*" >>"$CALLS"
[[ "$*" != 'up -d --no-deps mariadb' ]]
MOCK
chmod 700 "$TMP/compose-fail"
: >"$CALLS"
if PREFLIGHT_SCRIPT="$TMP/preflight" COMPOSE_WRAPPER="$TMP/compose-fail" \
   READER_SCRIPT="$TMP/reader" DOCKER_BIN="$TMP/docker" \
   "$ROOT/scripts/deploy_grafana.sh" >"$TMP/out" 2>"$TMP/err"; then
  echo 'failed MariaDB reconciliation was ignored' >&2; exit 1
fi
if grep -Eq '^reader |^compose pull grafana|^compose up -d grafana' "$CALLS"; then
  echo 'reader or Grafana work ran after failed MariaDB reconciliation' >&2; exit 1
fi

# The deployer changes neither data mounts nor production schedules.
grep -Fq '/srv/cycling/data/mariadb:/var/lib/mysql' "$ROOT/compose/docker-compose.yml"
if grep -Eq '\b(crontab|install_cron|run_daily_platform)\b' "$ROOT/scripts/deploy_grafana.sh"; then
  echo 'Grafana deployment crossed the scheduling boundary' >&2; exit 1
fi

printf '%s\n' 'Grafana first-deployment ordering tests: passed'
