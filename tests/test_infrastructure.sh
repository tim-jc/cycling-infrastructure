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

# Container-side defense rejects unsafe credentials before the official entrypoint.
if MARIADB_PASSWORD=replace-me MARIADB_ROOT_PASSWORD=valid-root \
  "$ROOT/compose/mariadb/guarded-entrypoint.sh" mariadbd >"$TMP/out" 2>&1; then
  echo 'expected guarded entrypoint rejection' >&2; exit 1
fi
grep -q 'refusing first initialization' "$TMP/out"

export CYCLING_PLATFORM_EXECUTION_HOST="$(hostname -s)"
docker compose --env-file "$ROOT/compose/.env.example" \
  -f "$ROOT/compose/docker-compose.yml" config --quiet

# Static contracts that are intentionally host-specific and unsafe to execute here.
grep -q 'sudo install.*0600' "$ROOT/scripts/bootstrap.sh"
grep -q 'runtime.Renviron' "$ROOT/scripts/bootstrap.sh"
grep -q 'EXPECTED_TARGET_HOST' "$ROOT/scripts/restore_platform_database.sh"
grep -q 'CYCLING_PLATFORM_EXECUTION_HOST="$(hostname -s)"' "$ROOT/scripts/compose.sh"
! grep -q 'install_cron.sh"$' "$ROOT/scripts/bootstrap.sh"
grep -q 'recovery-rehearsal-template.md' "$ROOT/docs/bootstrap-runbook.md"
grep -q 'Rscript bootstrap_platform.R' "$ROOT/docs/bootstrap-runbook.md"
grep -q 'Rscript run_platform_validation.R --publication' "$ROOT/docs/bootstrap-runbook.md"
! grep -Eq '(^|[[:space:]])Rscript bootstrap_platform.R' "$ROOT/docs/bootstrap-runbook.md" || \
  grep -q 'compose.sh.*Rscript bootstrap_platform.R' "$ROOT/docs/bootstrap-runbook.md"

printf '%s\n' 'infrastructure hardening tests: passed'
