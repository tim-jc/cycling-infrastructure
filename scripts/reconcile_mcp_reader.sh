#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_WRAPPER="${COMPOSE_WRAPPER:-$SCRIPT_DIR/compose.sh}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
MODE="reconcile"

log() { printf '[mcp-reader] %s\n' "$*"; }
fail() { printf '[mcp-reader] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: reconcile_mcp_reader.sh [--check-only]

Without options, idempotently reconciles the cycling-mcp account to exactly
SELECT on cycling_platform_silver.*. --check-only verifies without changing it.
USAGE
}

if (( $# > 1 )); then usage >&2; exit 2; fi
if (( $# == 1 )); then
  case "$1" in
    --check-only) MODE="check-only" ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
fi

command -v "$DOCKER_BIN" >/dev/null 2>&1 || fail "Docker is unavailable."
[[ -x "$COMPOSE_WRAPPER" ]] || fail "Compose wrapper is unavailable: $COMPOSE_WRAPPER"

container_id="$($COMPOSE_WRAPPER ps -q mariadb)"
[[ -n "$container_id" ]] || fail "MariaDB Compose service is not running."
health_status=""
for _ in {1..24}; do
  health_status="$($DOCKER_BIN inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id")"
  [[ "$health_status" == "healthy" ]] && break
  [[ "$health_status" == "unhealthy" || "$health_status" == "exited" || "$health_status" == "dead" ]] && break
  sleep 5
done
[[ "$health_status" == "healthy" ]] || fail "MariaDB is not healthy (status: ${health_status:-unknown})."

read_grants() {
  # Account validation and SQL expansion occur only inside the container.
  # shellcheck disable=SC2016
  "$COMPOSE_WRAPPER" exec -T mariadb sh -c '
    export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
    case "$MARIADB_MCP_READER_USER" in ""|*[!a-zA-Z0-9_.-]*) echo "Unsafe MariaDB cycling-mcp account name." >&2; exit 1;; esac
    exec mariadb --user=root --batch --skip-column-names --raw --execute "SHOW GRANTS FOR \`${MARIADB_MCP_READER_USER}\`@\`%\`;"
  '
}

if [[ "$MODE" == "reconcile" ]]; then
  "$COMPOSE_WRAPPER" exec -T mariadb /usr/local/bin/cycling-reconcile-mcp-reader.sh
  log "Reconciled the cycling-mcp account and removed privilege drift."
fi

if ! grants="$(read_grants 2>&1)"; then
  [[ "$MODE" == "check-only" ]] && fail "The configured cycling-mcp account is missing or unreadable; run without --check-only."
  fail "Could not inspect the configured cycling-mcp account."
fi

# SHOW GRANTS must contain only implicit USAGE plus exactly the intended grant.
# shellcheck disable=SC2016
select_count="$(printf '%s\n' "$grants" | grep -Ec '^GRANT SELECT ON `?cycling_platform_silver`?[.][*] TO ' || true)"
[[ "$select_count" == 1 ]] || fail "The cycling-mcp account lacks the exact Silver SELECT grant."
# shellcheck disable=SC2016
unexpected="$(printf '%s\n' "$grants" | grep '^GRANT ' | grep -Ev '^GRANT USAGE ON \*\.\* TO |^GRANT SELECT ON `?cycling_platform_silver`?[.][*] TO ' || true)"
[[ -z "$unexpected" ]] || fail "The cycling-mcp account has privileges outside the exact read-only contract."

log "Readiness passed: exactly SELECT on cycling_platform_silver.* and no other database or global privileges."
