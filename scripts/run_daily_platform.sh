#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

COMPOSE_DIR="/home/tim/cycling-infrastructure/compose"
LOG_DIR="/home/tim/cycling-infrastructure/logs"
LOCK_DIR="/tmp/cycling-platform-daily.lock"

mkdir -p "$LOG_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "$(date -Is) Daily platform run already active; exiting." \
    >> "$LOG_DIR/platform_daily.log"
  exit 0
fi

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

cd "$COMPOSE_DIR"

echo "===== $(date -Is) START =====" >> "$LOG_DIR/platform_daily.log"

docker compose run --rm cycling-platform \
  >> "$LOG_DIR/platform_daily.log" 2>&1

status=$?

echo "===== $(date -Is) END status=$status =====" \
  >> "$LOG_DIR/platform_daily.log"

exit "$status"