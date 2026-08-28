#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/compose" "$TMP/logs" "$TMP/output" "$TMP/runtime"
printf '%s\n' 'NTFY_TOPIC=platform-topic-must-not-be-used' 'CYCLING_ANALYTICS_NTFY_TOPIC=analytics-topic' 'NTFY_BASE_URL=https://notify.invalid' >"$TMP/compose/.env"
CALLS="$TMP/calls"
export CALLS MOCK_OUTPUT_FILE="$TMP/output/index.html" MOCK_NOTIFICATION_BODY="$TMP/notification-body" MOCK_NOTIFICATION_ARGS="$TMP/notification-args"

cat >"$TMP/bin/compose" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'compose %s\n' "$*" >>"$CALLS"
context_dir=""
context_target=""
while (($#)); do
  case "$1" in
    --volume) context_dir="${2%%:*}"; shift 2 ;;
    --env) context_target="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' 'analytics container output'
if [[ "${MOCK_COMPOSE_STATUS:-0}" == 0 ]]; then
  if [[ "${MOCK_WRITE_CONTEXT:-yes}" == yes ]]; then
    [[ "$context_target" == 'DASHBOARD_NOTIFICATION_CONTEXT_FILE=/run/cycling-analytics-notification/context.txt' ]]
    printf '%s\n' 'Rendered: 27 Aug 12:00' 'YTD: 100 mi | 2 tons | 8 hr' 'Latest ride: 20 mi on 26 Aug' 'Next refresh: not scheduled' >"$context_dir/context.txt"
  fi
  if [[ "${MOCK_WRITE_OUTPUT:-yes}" == yes ]]; then
    printf '%s\n' '<html>fresh dashboard</html>' >"$MOCK_OUTPUT_FILE"
    touch -t 203001010000 "$MOCK_OUTPUT_FILE"
  fi
fi
exit "${MOCK_COMPOSE_STATUS:-0}"
MOCK

cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"$CALLS"
printf '%s\n' "$*" >"$MOCK_NOTIFICATION_ARGS"
body_file=""
while (($#)); do
  if [[ "$1" == --data-binary ]]; then body_file="${2#@}"; break; fi
  shift
done
[[ -n "$body_file" ]]
cp "$body_file" "$MOCK_NOTIFICATION_BODY"
exit "${MOCK_CURL_STATUS:-0}"
MOCK

cat >"$TMP/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
[[ "${MOCK_HOSTNAME_FAIL:-no}" != yes ]] || exit 1
printf '%s\n' cycling-prod
MOCK

cat >"$TMP/bin/date" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' '2026-08-27T12:00:00+01:00'
MOCK
chmod 700 "$TMP/bin/"*

invoke_wrapper() {
  COMPOSE_DIR="$TMP/compose" \
  COMPOSE_WRAPPER="$TMP/bin/compose" \
  LOG_DIR="$TMP/logs" \
  OUTPUT_FILE="$TMP/output/index.html" \
  DEPLOY_LOCK_DIR="$TMP/analytics-deploy.lock" \
  RENDER_LOCK_DIR="$TMP/analytics-render.lock" \
  RESTORE_LOCK_DIR="$TMP/restore.lock" \
  RUNTIME_TMP_PARENT="$TMP/runtime" \
  CURL_BIN="$TMP/bin/curl" \
  HOSTNAME_BIN="$TMP/bin/hostname" \
  DATE_BIN="$TMP/bin/date" \
  "$ROOT/scripts/run_analytics_refresh.sh"
}

reset_case() {
  : >"$CALLS"
  rm -f "$MOCK_NOTIFICATION_BODY" "$MOCK_NOTIFICATION_ARGS" "$TMP/output/index.html"
  rmdir "$TMP/analytics-render.lock" "$TMP/analytics-deploy.lock" "$TMP/restore.lock" 2>/dev/null || true
}

assert_runtime_clean() {
  [[ ! -d "$TMP/analytics-render.lock" ]]
  [[ -z "$(find "$TMP/runtime" -mindepth 1 -print -quit)" ]]
}

# Successful execution returns zero, captures output, consumes application
# context, validates fresh output and cleans transient state.
reset_case
MOCK_COMPOSE_STATUS=0 invoke_wrapper
status=$?
[[ "$status" == 0 ]]
assert_runtime_clean
grep -q '^compose run --rm --volume .*:/run/cycling-analytics-notification:rw --env DASHBOARD_NOTIFICATION_CONTEXT_FILE=/run/cycling-analytics-notification/context.txt cycling-analytics$' "$CALLS"
grep -q 'analytics container output' "$TMP/logs/analytics_refresh.log"
grep -q 'START =====' "$TMP/logs/analytics_refresh.log"
grep -q 'END status=0' "$TMP/logs/analytics_refresh.log"
grep -q '^Rendered: 27 Aug 12:00$' "$MOCK_NOTIFICATION_BODY"
grep -q '^Host: cycling-prod$' "$MOCK_NOTIFICATION_BODY"
grep -q '^YTD: 100 mi | 2 tons | 8 hr$' "$MOCK_NOTIFICATION_BODY"
grep -q '^Latest ride: 20 mi on 26 Aug$' "$MOCK_NOTIFICATION_BODY"
grep -q '^Next refresh: not scheduled$' "$MOCK_NOTIFICATION_BODY"
grep -q 'Title: Dashboard refreshed' "$MOCK_NOTIFICATION_ARGS"
grep -q 'https://notify.invalid/analytics-topic' "$MOCK_NOTIFICATION_ARGS"
if grep -Eq 'platform-topic-must-not-be-used|[Pp]ublish' "$MOCK_NOTIFICATION_ARGS" "$MOCK_NOTIFICATION_BODY"; then echo 'analytics notification used platform topic or claimed publication' >&2; exit 1; fi
# Missing analytics configuration never falls back to the platform topic.
# Notification remains best effort and does not change render status.
printf '%s\n' 'NTFY_TOPIC=platform-topic-must-not-be-used' 'NTFY_BASE_URL=https://notify.invalid' >"$TMP/compose/.env"
reset_case
MOCK_COMPOSE_STATUS=0 invoke_wrapper
[[ ! -e "$MOCK_NOTIFICATION_BODY" && ! -e "$MOCK_NOTIFICATION_ARGS" ]]
grep -q 'CYCLING_ANALYTICS_NTFY_TOPIC is not configured' "$TMP/logs/analytics_refresh.log"
if grep -q 'platform-topic-must-not-be-used' "$CALLS"; then echo 'missing analytics topic fell back to platform topic' >&2; exit 1; fi
printf '%s\n' 'NTFY_TOPIC=platform-topic-must-not-be-used' 'CYCLING_ANALYTICS_NTFY_TOPIC=' 'NTFY_BASE_URL=https://notify.invalid' >"$TMP/compose/.env"
reset_case
set +e
MOCK_COMPOSE_STATUS=29 invoke_wrapper
status=$?
set -e
[[ "$status" == 29 ]]
[[ ! -e "$MOCK_NOTIFICATION_BODY" && ! -e "$MOCK_NOTIFICATION_ARGS" ]]
grep -q 'preserving refresh status 29' "$TMP/logs/analytics_refresh.log"
if grep -q 'platform-topic-must-not-be-used' "$CALLS"; then echo 'empty analytics topic fell back to platform topic' >&2; exit 1; fi
# Host identity is a required host-side operational fact; failure is explicit
# and occurs before Compose execution.
printf '%s\n' 'NTFY_TOPIC=platform-topic-must-not-be-used' 'CYCLING_ANALYTICS_NTFY_TOPIC=analytics-topic' 'NTFY_BASE_URL=https://notify.invalid' >"$TMP/compose/.env"
reset_case
set +e
MOCK_HOSTNAME_FAIL=yes invoke_wrapper
status=$?
set -e
[[ "$status" == 1 ]]
assert_runtime_clean
if grep -q '^compose ' "$CALLS"; then echo 'hostname failure invoked Compose' >&2; exit 1; fi
grep -q 'cannot resolve the physical host short name' "$TMP/logs/analytics_refresh.log"

# Compose failure preserves the exact application status and notification
# transport failure cannot replace it.
reset_case
set +e
MOCK_COMPOSE_STATUS=42 invoke_wrapper
status=$?
set -e
[[ "$status" == 42 ]]
assert_runtime_clean
grep -q '^Host: cycling-prod$' "$MOCK_NOTIFICATION_BODY"
grep -q '^Operation: analytics refresh$' "$MOCK_NOTIFICATION_BODY"
grep -q '^Exit status: 42$' "$MOCK_NOTIFICATION_BODY"
grep -q 'https://notify.invalid/analytics-topic' "$MOCK_NOTIFICATION_ARGS"
grep -q 'END status=42' "$TMP/logs/analytics_refresh.log"

reset_case
set +e
MOCK_COMPOSE_STATUS=37 MOCK_CURL_STATUS=9 invoke_wrapper
status=$?
set -e
[[ "$status" == 37 ]]
assert_runtime_clean
grep -q 'preserving refresh status 37' "$TMP/logs/analytics_refresh.log"

# A notification transport failure after a valid render remains best effort.
reset_case
MOCK_COMPOSE_STATUS=0 MOCK_CURL_STATUS=9 invoke_wrapper
assert_runtime_clean
grep -q 'preserving successful render status 0' "$TMP/logs/analytics_refresh.log"

# A zero container status with no fresh persistent artefact fails validation.
reset_case
set +e
MOCK_COMPOSE_STATUS=0 MOCK_WRITE_OUTPUT=no invoke_wrapper
status=$?
set -e
[[ "$status" == 1 ]]
assert_runtime_clean
grep -q 'Output validation failed' "$TMP/logs/analytics_refresh.log"

# A duplicate render is a harmless skip; deployment and restore are blocking
# errors. Existing foreign locks are never removed.
reset_case; mkdir "$TMP/analytics-render.lock"
invoke_wrapper
[[ -d "$TMP/analytics-render.lock" ]]
if grep -q '^compose ' "$CALLS"; then echo 'duplicate render invoked Compose' >&2; exit 1; fi
rmdir "$TMP/analytics-render.lock"
for blocking_lock in analytics-deploy restore; do
  reset_case; mkdir "$TMP/$blocking_lock.lock"
  set +e; invoke_wrapper; status=$?; set -e
  [[ "$status" == 1 && -d "$TMP/$blocking_lock.lock" ]]
  if grep -q '^compose ' "$CALLS"; then echo "$blocking_lock lock invoked Compose" >&2; exit 1; fi
  rmdir "$TMP/$blocking_lock.lock"
done

# Platform locks are intentionally irrelevant to this read-only consumer.
reset_case
mkdir "$TMP/platform-daily.lock" "$TMP/platform-validation.lock" "$TMP/platform-deployment.lock"
MOCK_COMPOSE_STATUS=0 invoke_wrapper
assert_runtime_clean
rmdir "$TMP/platform-daily.lock" "$TMP/platform-validation.lock" "$TMP/platform-deployment.lock"

# No publication, Git or scheduling command is part of the wrapper.
if grep -Eq 'git (add|commit|push)|crontab|systemctl|publish' "$CALLS"; then
  echo 'analytics runtime crossed publication or scheduling boundary' >&2
  exit 1
fi
ANALYTICS_TEST_SECRET=must-not-appear MOCK_COMPOSE_STATUS=0 invoke_wrapper
if grep -R -q 'must-not-appear' "$TMP/logs" "$MOCK_NOTIFICATION_BODY" "$MOCK_NOTIFICATION_ARGS"; then echo 'runtime secret leaked' >&2; exit 1; fi

printf '%s\n' 'analytics refresh runtime tests: passed'
