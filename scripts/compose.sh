#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$PROJECT_ROOT/compose}"

CYCLING_PLATFORM_EXECUTION_HOST="$(hostname -s)"
export CYCLING_PLATFORM_EXECUTION_HOST
[[ -n "$CYCLING_PLATFORM_EXECUTION_HOST" ]] || {
  printf '[compose] ERROR: physical host identity is empty.\n' >&2
  exit 1
}

if ! CYCLING_PLATFORM_RUNTIME_UID="$(id -u tim)" || ! CYCLING_PLATFORM_RUNTIME_GID="$(id -g tim)"; then
  printf '[compose] ERROR: the required tim account is unavailable; run host bootstrap first.\n' >&2
  exit 1
fi
[[ "$CYCLING_PLATFORM_RUNTIME_UID" =~ ^[0-9]+$ && "$CYCLING_PLATFORM_RUNTIME_GID" =~ ^[0-9]+$ ]] || {
  printf '[compose] ERROR: could not resolve the numeric UID/GID for the required tim account.\n' >&2
  exit 1
}
export CYCLING_PLATFORM_RUNTIME_UID CYCLING_PLATFORM_RUNTIME_GID

exec docker compose \
  --project-directory "$COMPOSE_DIR" \
  --env-file "$COMPOSE_DIR/.env" \
  --file "$COMPOSE_DIR/docker-compose.yml" \
  "$@"
