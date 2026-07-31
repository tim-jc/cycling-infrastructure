#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/data" "$TMP/config"
printf '%s\n' 'STRAVA_REFRESH_TOKEN=test-only' >"$TMP/config/runtime.Renviron"
chmod 600 "$TMP/config/runtime.Renviron"

write_env() {
  cat >"$TMP/.env" <<EOF
MARIADB_USER=cycling
MARIADB_PASSWORD=$1
MARIADB_ROOT_PASSWORD=$2
MARIADB_PORT=3306
STRAVA_CLIENT_ID=test
STRAVA_CLIENT_SECRET=test
GOOGLE_HEALTH_CLIENT_ID=test
GOOGLE_HEALTH_CLIENT_SECRET=test
NTFY_TOPIC=test
EOF
  chmod 600 "$TMP/.env"
}
run_preflight() {
  ENV_FILE="$TMP/.env" MARIADB_DATA_DIR="$TMP/data" \
    RUNTIME_RENVIRON="$TMP/config/runtime.Renviron" \
    "$ROOT/scripts/preflight.sh"
}

write_env replace-me valid-root-test-value
if run_preflight >"$TMP/out" 2>&1; then
  echo 'expected placeholder application password rejection' >&2; exit 1
fi
grep -q 'known unsafe placeholder' "$TMP/out"
write_env valid-app-test-value password
if run_preflight >"$TMP/out" 2>&1; then
  echo 'expected placeholder root password rejection' >&2; exit 1
fi

write_env valid-app-test-value valid-root-test-value
env_before="$(cksum "$TMP/.env")"
runtime_before="$(cksum "$TMP/config/runtime.Renviron")"
run_preflight >"$TMP/out"
[[ "$(cksum "$TMP/.env")" == "$env_before" ]]
[[ "$(cksum "$TMP/config/runtime.Renviron")" == "$runtime_before" ]]
grep -q 'appears new' "$TMP/out"
mkdir -p "$TMP/data/mysql"
run_preflight >"$TMP/out"
grep -q 'already initialized' "$TMP/out"

# Exercise the guard with a mock official entrypoint; never start MariaDB here.
cat >"$TMP/mock-docker-entrypoint.sh" <<'MOCK'
#!/bin/sh
: >"$CYCLING_MARIADB_ARGV_FILE"
for argument in "$@"; do
  printf '%s\n' "$argument" >>"$CYCLING_MARIADB_ARGV_FILE"
done
MOCK
chmod 700 "$TMP/mock-docker-entrypoint.sh"

run_guard() {
  local data_directory="$1"
  shift
  CYCLING_MARIADB_DATA_DIR="$data_directory" \
    CYCLING_MARIADB_OFFICIAL_ENTRYPOINT="$TMP/mock-docker-entrypoint.sh" \
    CYCLING_MARIADB_ARGV_FILE="$TMP/argv" \
    MARIADB_PASSWORD=valid-app-test-value \
    MARIADB_ROOT_PASSWORD=valid-root-test-value \
    "$ROOT/compose/mariadb/guarded-entrypoint.sh" "$@"
}

# No arguments default to the image's intended mariadbd command.
mkdir -p "$TMP/new-data"
run_guard "$TMP/new-data" >"$TMP/out" 2>&1
[[ "$(cat "$TMP/argv")" == "mariadbd" ]]
grep -q 'passed credential safety checks' "$TMP/out"

# Explicit arguments are forwarded exactly and are not replaced by the fallback.
run_guard "$TMP/new-data" mariadbd --verbose "two words" >"$TMP/out" 2>&1
printf '%s\n' mariadbd --verbose 'two words' >"$TMP/expected-argv"
cmp -s "$TMP/expected-argv" "$TMP/argv"

# Unsafe new-directory credentials fail before invoking the official entrypoint.
rm -f "$TMP/argv"
if CYCLING_MARIADB_DATA_DIR="$TMP/new-data" \
  CYCLING_MARIADB_OFFICIAL_ENTRYPOINT="$TMP/mock-docker-entrypoint.sh" \
  CYCLING_MARIADB_ARGV_FILE="$TMP/argv" \
  MARIADB_PASSWORD=replace-me MARIADB_ROOT_PASSWORD=valid-root \
  "$ROOT/compose/mariadb/guarded-entrypoint.sh" >"$TMP/out" 2>&1; then
  echo 'expected guarded entrypoint rejection' >&2; exit 1
fi
grep -q 'refusing first initialization' "$TMP/out"
[[ ! -e "$TMP/argv" ]]

# Existing data emits the initialization-variable warning and still starts MariaDB.
mkdir -p "$TMP/existing-data/mysql"
run_guard "$TMP/existing-data" >"$TMP/out" 2>&1
[[ "$(cat "$TMP/argv")" == "mariadbd" ]]
grep -q 'Existing data directory detected' "$TMP/out"

CYCLING_PLATFORM_EXECUTION_HOST="$(hostname -s)"
export CYCLING_PLATFORM_EXECUTION_HOST
docker compose --env-file "$ROOT/compose/.env.example" \
  -f "$ROOT/compose/docker-compose.yml" config >"$TMP/compose-rendered.yml"
grep -A2 '^    entrypoint:' "$TMP/compose-rendered.yml" | grep -q 'cycling-guarded-entrypoint.sh'
grep -A2 '^    command:' "$TMP/compose-rendered.yml" | grep -q 'mariadbd'

# Static contracts that are intentionally host-specific and unsafe to execute here.
grep -q 'sudo install.*0600' "$ROOT/scripts/bootstrap.sh"
grep -q 'runtime.Renviron' "$ROOT/scripts/bootstrap.sh"
grep -q 'EXPECTED_TARGET_HOST' "$ROOT/scripts/restore_platform_database.sh"
# Literal source contract; command substitution is intentionally not expanded.
# shellcheck disable=SC2016
grep -q 'CYCLING_PLATFORM_EXECUTION_HOST="$(hostname -s)"' "$ROOT/scripts/compose.sh"
# Literal source contract; the dollar sign must not expand here.
# shellcheck disable=SC2016
if grep -Eq '^[[:space:]]*"\$SCRIPT_DIR/install_cron\.sh"' "$ROOT/scripts/bootstrap.sh"; then
  echo 'bootstrap must not install production cron' >&2
  exit 1
fi
grep -q 'recovery-rehearsal-template.md' "$ROOT/docs/bootstrap-runbook.md"
grep -q 'Rscript bootstrap_platform.R' "$ROOT/docs/bootstrap-runbook.md"
grep -q 'Rscript run_platform_validation.R --publication' "$ROOT/docs/bootstrap-runbook.md"
if grep -Eq '(^|[[:space:]])Rscript bootstrap_platform.R' "$ROOT/docs/bootstrap-runbook.md" &&
  ! grep -q 'compose.sh.*Rscript bootstrap_platform.R' "$ROOT/docs/bootstrap-runbook.md"; then
  echo 'platform bootstrap must use the Compose path' >&2
  exit 1
fi

printf '%s\n' 'infrastructure hardening tests: passed'
