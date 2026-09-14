#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/compose" "$TMP/logs"

cat >"$TMP/compose-mock" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_CALLS"
printf '%s\n' 'mock validation output'
exit "${MOCK_STATUS:-0}"
MOCK
cat >"$TMP/date-mock" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' '2026-09-13T22:00:00+01:00'
MOCK
chmod 700 "$TMP/compose-mock" "$TMP/date-mock"
export MOCK_CALLS="$TMP/compose-calls"

run_wrapper() {
  rm -f "$MOCK_CALLS"
  rm -rf "$TMP/validation.lock" "$TMP/deployment.lock"
  COMPOSE_DIR="$TMP/compose" \
  COMPOSE_WRAPPER="$TMP/compose-mock" \
  LOG_DIR="$TMP/logs" \
  DEPLOY_LOCK_DIR="$TMP/deployment.lock" \
  LOCK_DIR="$TMP/validation.lock" \
  DATE_BIN="$TMP/date-mock" \
  "$ROOT/scripts/run_platform_validation.sh"
}

MOCK_STATUS=0 run_wrapper
grep -Fxq 'run --rm cycling-platform Rscript run_platform_validation.R' "$MOCK_CALLS"
! grep -Fq './scripts/run_platform_validation.sh' "$MOCK_CALLS"
grep -Fq 'mock validation output' "$TMP/logs/platform_validation.log"
grep -Fq 'END status=0' "$TMP/logs/platform_validation.log"
[[ ! -d "$TMP/validation.lock" ]]

set +e
MOCK_STATUS=37 run_wrapper
status=$?
set -e
[[ "$status" == 37 ]]
grep -Fq 'mock validation output' "$TMP/logs/platform_validation.log"
grep -Fq 'END status=37' "$TMP/logs/platform_validation.log"
[[ ! -d "$TMP/validation.lock" ]]

printf '%s\n' 'platform validation wrapper tests: passed'
