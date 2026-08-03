#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  status=$?
  rm -rf -- "$TMP"
  return "$status"
}
trap cleanup EXIT
mkdir -p "$TMP/data" "$TMP/config"
chmod 700 "$TMP/config"
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
grep -q 'source: /srv/cycling/config/platform$' "$TMP/compose-rendered.yml"
grep -q 'target: /run/cycling-platform$' "$TMP/compose-rendered.yml"
if grep -q 'source: /srv/cycling/config/platform/runtime.Renviron$' "$TMP/compose-rendered.yml"; then
  echo 'runtime credential file must not be mounted as a bind-mount target' >&2
  exit 1
fi

# Prove the dedicated filesystem supports the sibling-file atomic replace.
printf '%s\n' 'STRAVA_REFRESH_TOKEN=before-rename' >"$TMP/config/runtime.Renviron"
chmod 600 "$TMP/config/runtime.Renviron"
printf '%s\n' 'STRAVA_REFRESH_TOKEN=host-after-rename' >"$TMP/config/.runtime-renviron-host-test"
chmod 600 "$TMP/config/.runtime-renviron-host-test"
mv "$TMP/config/.runtime-renviron-host-test" "$TMP/config/runtime.Renviron"
grep -q '^STRAVA_REFRESH_TOKEN=host-after-rename$' "$TMP/config/runtime.Renviron"

# With a Docker daemon, prove the same operation through the rendered mount boundary.
if docker info >/dev/null 2>&1; then
  docker run --rm --entrypoint sh \
    --volume "$TMP/config:/run/cycling-platform:rw" \
    mariadb:11 -c '
      set -eu
      target=/run/cycling-platform/runtime.Renviron
      temporary=/run/cycling-platform/.runtime-renviron-test
      test -r "$target"
      test -w "$target"
      printf "%s\n" "STRAVA_REFRESH_TOKEN=container-after-rename" >"$temporary"
      chmod 600 "$temporary"
      mv "$temporary" "$target"
      test -r "$target"
      test -w "$target"
    '
  grep -q '^STRAVA_REFRESH_TOKEN=container-after-rename$' "$TMP/config/runtime.Renviron"
else
  printf '%s\n' 'container atomic-rename test: skipped (Docker daemon unavailable)'
fi
[[ "$(stat -c '%a' "$TMP/config/runtime.Renviron" 2>/dev/null || stat -f '%Lp' "$TMP/config/runtime.Renviron")" == "600" ]]

# Preflight rejects unrelated entries because the whole directory is exposed.
printf '%s\n' unrelated >"$TMP/config/unrelated-file"
if run_preflight >"$TMP/out" 2>&1; then
  echo 'expected dedicated platform configuration directory rejection' >&2
  exit 1
fi
grep -q 'must be dedicated to runtime.Renviron' "$TMP/out"
rm -f "$TMP/config/unrelated-file"

# Static contracts that are intentionally host-specific and unsafe to execute here.
grep -q 'sudo install.*0600' "$ROOT/scripts/bootstrap.sh"
# Literal bootstrap source contract; expansion is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq 'if [[ ! -e "$RUNTIME_RENVIRON" ]]' "$ROOT/scripts/bootstrap.sh"
grep -q 'sudo chmod 0700' "$ROOT/scripts/bootstrap.sh"
grep -q 'runtime.Renviron' "$ROOT/scripts/bootstrap.sh"
[[ "$(stat -c '%a' "$TMP/config" 2>/dev/null || stat -f '%Lp' "$TMP/config")" == "700" ]]
grep -q 'EXPECTED_TARGET_HOST' "$ROOT/scripts/restore_platform_database.sh"
# Literal source contract; command substitution is intentionally not expanded.
# shellcheck disable=SC2016
grep -q 'CYCLING_PLATFORM_EXECUTION_HOST="$(hostname -s)"' "$ROOT/scripts/compose.sh"
# Deployment image identity must not depend on an existing service container.
grep -q '^REF="origin/main"$' "$ROOT/scripts/deploy_platform.sh"
"$ROOT/scripts/deploy_platform.sh" --help | grep -q 'deploys origin/main'
grep -q 'config --images' "$ROOT/scripts/deploy_platform.sh"
# Literal command-variable source contract.
# shellcheck disable=SC2016
grep -q '"$DOCKER_BIN" image inspect' "$ROOT/scripts/deploy_platform.sh"
if grep -q 'compose.sh" images -q' "$ROOT/scripts/deploy_platform.sh"; then
  echo 'deployment image identity must not use compose images -q' >&2
  exit 1
fi
# Literal source contract; the dollar sign must not expand here.
# shellcheck disable=SC2016
if grep -Eq '^[[:space:]]*"\$SCRIPT_DIR/install_cron\.sh"' "$ROOT/scripts/bootstrap.sh"; then
  echo 'bootstrap must not install production cron' >&2
  exit 1
fi
grep -q 'recovery-rehearsal-template.md' "$ROOT/docs/bootstrap-runbook.md"
grep -q 'Rscript bootstrap_platform.R' "$ROOT/docs/bootstrap-runbook.md"
grep -q 'Rscript run_platform_validation.R --publication' "$ROOT/docs/bootstrap-runbook.md"
# Literal deployment source contracts.
# shellcheck disable=SC2016
grep -q '"$COMPOSE_WRAPPER" run --rm cycling-platform Rscript bootstrap_platform.R' \
  "$ROOT/scripts/deploy_platform.sh"
# shellcheck disable=SC2016
grep -q '"$COMPOSE_WRAPPER" run --rm cycling-platform Rscript run_platform_validation.R --publication' \
  "$ROOT/scripts/deploy_platform.sh"

printf '%s\n' 'infrastructure hardening tests: passed'
