#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/notify_platform_outer_failure.sh
source "$SCRIPT_DIR/notify_platform_outer_failure.sh"

COMPOSE_DIR="${COMPOSE_DIR:-/home/tim/cycling-infrastructure/compose}"
COMPOSE_WRAPPER="${COMPOSE_WRAPPER:-/home/tim/cycling-infrastructure/scripts/compose.sh}"
LOG_DIR="${LOG_DIR:-/home/tim/cycling-infrastructure/logs}"
DEPLOY_LOCK_DIR="${DEPLOY_LOCK_DIR:-/tmp/cycling-platform-deployment.lock}"
LOCK_DIR="${LOCK_DIR:-/tmp/cycling-platform-daily.lock}"
LOG_FILE="$LOG_DIR/platform_daily.log"

timestamp() {
  "${DATE_BIN:-date}" -Is
}

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

if [[ -d "$DEPLOY_LOCK_DIR" ]]; then
  echo "$(timestamp) Daily platform run blocked while platform deployment is active." >> "$LOG_FILE"
  exit 1
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "$(timestamp) Daily platform run already active; exiting." \
    >> "$LOG_FILE"
  exit 0
fi

# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

cd "$COMPOSE_DIR"

run_start_line="$(( $(wc -l < "$LOG_FILE" 2>/dev/null || printf 0) + 1 ))"

echo "===== $(timestamp) START =====" >> "$LOG_FILE"

if "$COMPOSE_WRAPPER" run --rm cycling-platform \
  >> "$LOG_FILE" 2>&1; then
  status=0
else
  status=$?
fi

echo "===== $(timestamp) END status=$status =====" \
  >> "$LOG_FILE"

if ((status != 0)) &&
   ! tail -n "+$run_start_line" "$LOG_FILE" |
     grep -q '^CYCLING_PLATFORM_FAILURE_NOTIFICATION_SENT$'; then
  if ! send_platform_outer_failure_notification "$status" "daily-platform"; then
    echo "$(timestamp) Infrastructure failure notification could not be sent; preserving container status $status." \
      >> "$LOG_FILE"
  fi
fi

exit "$status"
