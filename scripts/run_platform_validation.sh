#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

COMPOSE_DIR="/home/tim/cycling-infrastructure/compose"
COMPOSE_WRAPPER="/home/tim/cycling-infrastructure/scripts/compose.sh"
LOG_DIR="/home/tim/cycling-infrastructure/logs"
LOCK_DIR="/tmp/cycling-platform-validation.lock"

mkdir -p "$LOG_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "$(date -Is) Validation already active; exiting." \
    >> "$LOG_DIR/platform_validation.log"
  exit 0
fi

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

cd "$COMPOSE_DIR"

echo "===== $(date -Is) START =====" >> "$LOG_DIR/platform_validation.log"

if "$COMPOSE_WRAPPER" run --rm \
  cycling-platform \
  ./scripts/run_platform_validation.sh \
  >> "$LOG_DIR/platform_validation.log" 2>&1; then
  status=0
else
  status=$?
fi

echo "===== $(date -Is) END status=$status =====" \
  >> "$LOG_DIR/platform_validation.log"

exit "$status"