#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/compose" "$TMP/logs"
printf '%s\n' 'NTFY_TOPIC=test-topic' >"$TMP/compose/.env"

cat >"$TMP/bin/compose" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' 'container startup output'
[[ "${MOCK_APPLICATION_NOTIFIED:-no}" != yes ]] || printf '%s\n' 'CYCLING_PLATFORM_FAILURE_NOTIFICATION_SENT'
exit "${MOCK_COMPOSE_STATUS:-0}"
MOCK
cat >"$TMP/bin/curl" <<'MOCK'
#!/usr/bin/env bash
cat >"$MOCK_NOTIFICATION_BODY"
printf '%s\n' "$*" >"$MOCK_NOTIFICATION_ARGS"
exit "${MOCK_CURL_STATUS:-0}"
MOCK
cat >"$TMP/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' cycling-prod
MOCK
cat >"$TMP/bin/date" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' '2026-08-09T12:00:00+01:00'
MOCK
chmod 700 "$TMP/bin/"*

export MOCK_NOTIFICATION_BODY="$TMP/notification-body"
export MOCK_NOTIFICATION_ARGS="$TMP/notification-args"

run_wrapper() {
  rm -f "$MOCK_NOTIFICATION_BODY" "$MOCK_NOTIFICATION_ARGS"
  rm -rf "$TMP/daily.lock" "$TMP/deploy.lock"
  COMPOSE_DIR="$TMP/compose" \
  COMPOSE_WRAPPER="$TMP/bin/compose" \
  LOG_DIR="$TMP/logs" \
  DEPLOY_LOCK_DIR="$TMP/deploy.lock" \
  LOCK_DIR="$TMP/daily.lock" \
  CURL_BIN="$TMP/bin/curl" \
  HOSTNAME_BIN="$TMP/bin/hostname" \
  DATE_BIN="$TMP/bin/date" \
  "$ROOT/scripts/run_daily_platform.sh"
}

# Success returns zero and sends no outer notification.
MOCK_COMPOSE_STATUS=0 run_wrapper
[[ ! -e "$MOCK_NOTIFICATION_BODY" ]]

# Startup failure preserves its status and sends one context-only alert.
set +e
MOCK_COMPOSE_STATUS=42 run_wrapper
status=$?
set -e
[[ "$status" == 42 ]]
grep -q '^Host: cycling-prod$' "$MOCK_NOTIFICATION_BODY"
grep -q '^Pipeline: daily-platform$' "$MOCK_NOTIFICATION_BODY"
grep -q '^Exit status: 42$' "$MOCK_NOTIFICATION_BODY"
grep -q '^Context: Compose/container execution failed' "$MOCK_NOTIFICATION_BODY"
grep -q 'https://ntfy.sh/test-topic' "$MOCK_NOTIFICATION_ARGS"

# An application-confirmed failure notification suppresses the outer duplicate.
set +e
MOCK_COMPOSE_STATUS=23 MOCK_APPLICATION_NOTIFIED=yes run_wrapper
status=$?
set -e
[[ "$status" == 23 ]]
[[ ! -e "$MOCK_NOTIFICATION_BODY" ]]

# Notification transport failure never replaces the original container status.
set +e
MOCK_COMPOSE_STATUS=17 MOCK_CURL_STATUS=7 run_wrapper
status=$?
set -e
[[ "$status" == 17 ]]
grep -q 'preserving container status 17' "$TMP/logs/platform_daily.log"

printf '%s\n' 'daily platform outer failure notification tests: passed'
