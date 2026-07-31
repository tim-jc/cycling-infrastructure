#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$PROJECT_ROOT/compose}"

export CYCLING_PLATFORM_EXECUTION_HOST="$(hostname -s)"
[[ -n "$CYCLING_PLATFORM_EXECUTION_HOST" ]] || {
  printf '[compose] ERROR: physical host identity is empty.\n' >&2
  exit 1
}

exec docker compose \
  --project-directory "$COMPOSE_DIR" \
  --env-file "$COMPOSE_DIR/.env" \
  --file "$COMPOSE_DIR/docker-compose.yml" \
  "$@"
