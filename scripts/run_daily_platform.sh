#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

COMPOSE_DIR="/home/tim/cycling-infrastructure/compose"
COMPOSE_WRAPPER="/home/tim/cycling-infrastructure/scripts/compose.sh"
LOG_DIR="/home/tim/cycling-infrastructure/logs"
DEPLOY_LOCK_DIR="/tmp/cycling-platform-deployment.lock"
LOCK_DIR="/tmp/cycling-platform-daily.lock"

mkdir -p "$LOG_DIR"

if [[ -d "$DEPLOY_LOCK_DIR" ]]; then
  echo "$(date -Is) Daily platform run blocked while platform deployment is active." >> "$LOG_DIR/platform_daily.log"
  exit 1
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "$(date -Is) Daily platform run already active; exiting." \
    >> "$LOG_DIR/platform_daily.log"
  exit 0
fi

# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

cd "$COMPOSE_DIR"

echo "===== $(date -Is) START =====" >> "$LOG_DIR/platform_daily.log"

if "$COMPOSE_WRAPPER" run --rm cycling-platform \
  >> "$LOG_DIR/platform_daily.log" 2>&1; then
  status=0
else
  status=$?
fi

echo "===== $(date -Is) END status=$status =====" \
  >> "$LOG_DIR/platform_daily.log"

exit "$status"