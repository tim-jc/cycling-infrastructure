#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

COMPOSE_DIR="${COMPOSE_DIR:-/home/tim/cycling-infrastructure/compose}"
COMPOSE_WRAPPER="${COMPOSE_WRAPPER:-/home/tim/cycling-infrastructure/scripts/compose.sh}"
LOG_DIR="${LOG_DIR:-/home/tim/cycling-infrastructure/logs}"
DEPLOY_LOCK_DIR="${DEPLOY_LOCK_DIR:-/tmp/cycling-platform-deployment.lock}"
LOCK_DIR="${LOCK_DIR:-/tmp/cycling-platform-validation.lock}"
DATE_BIN="${DATE_BIN:-date}"

mkdir -p "$LOG_DIR"

if [[ -d "$DEPLOY_LOCK_DIR" ]]; then
  echo "$($DATE_BIN -Is) Validation blocked while platform deployment is active." >> "$LOG_DIR/platform_validation.log"
  exit 1
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "$($DATE_BIN -Is) Validation already active; exiting." \
    >> "$LOG_DIR/platform_validation.log"
  exit 0
fi

# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

cd "$COMPOSE_DIR"

echo "===== $($DATE_BIN -Is) START =====" >> "$LOG_DIR/platform_validation.log"

if "$COMPOSE_WRAPPER" run --rm \
  cycling-platform \
  Rscript run_platform_validation.R \
  >> "$LOG_DIR/platform_validation.log" 2>&1; then
  status=0
else
  status=$?
fi

echo "===== $($DATE_BIN -Is) END status=$status =====" \
  >> "$LOG_DIR/platform_validation.log"

exit "$status"
