#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_WRAPPER="${COMPOSE_WRAPPER:-$SCRIPT_DIR/compose.sh}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
MODE="reconcile"
REFERENCE_DATABASE="cycling_platform_reference"
EXPECTED_CHARACTER_SET="utf8mb4"
EXPECTED_COLLATION="utf8mb4_general_ci"

log() { printf '[reference-database] %s\n' "$*"; }
fail() { printf '[reference-database] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: reconcile_reference_database.sh [--check-only]

Without options, idempotently creates/reconciles cycling_platform_reference and
its database-scoped application grant. --check-only verifies without changing it.
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

root_query() {
  local sql="$1"
  # Values expand only inside the container and are not printed.
  # shellcheck disable=SC2016
  "$COMPOSE_WRAPPER" exec -T mariadb sh -c '
    export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
    exec mariadb --user=root --batch --skip-column-names --raw --execute "$1"
  ' query "$sql"
}

app_query() {
  local sql="$1"
  # shellcheck disable=SC2016
  "$COMPOSE_WRAPPER" exec -T mariadb sh -c '
    export MYSQL_PWD="$MARIADB_PASSWORD"
    exec mariadb --user="$MARIADB_USER" --database=cycling_platform_reference --batch --skip-column-names --raw --execute "$1"
  ' query "$sql"
}

read_application_grants() {
  # Account validation and expansion occur only inside the container.
  # shellcheck disable=SC2016
  "$COMPOSE_WRAPPER" exec -T mariadb sh -c '
    export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
    case "$MARIADB_USER" in ""|*[!a-zA-Z0-9_.-]*) echo "Unsafe MariaDB application account name." >&2; exit 1;; esac
    exec mariadb --user=root --batch --skip-column-names --raw --execute "SHOW GRANTS FOR \`${MARIADB_USER}\`@\`%\`;"
  '
}

read_reference_settings() {
  root_query "
    SELECT COUNT(*),
           COALESCE(MAX(DEFAULT_CHARACTER_SET_NAME), '-'),
           COALESCE(MAX(DEFAULT_COLLATION_NAME), '-')
    FROM information_schema.SCHEMATA
    WHERE SCHEMA_NAME = '$REFERENCE_DATABASE';
  "
}

read -r schema_exists actual_charset actual_collation < <(read_reference_settings)

if [[ "$MODE" == "reconcile" ]]; then
  if [[ "$schema_exists" == "0" ]]; then
    root_query "CREATE DATABASE $REFERENCE_DATABASE CHARACTER SET $EXPECTED_CHARACTER_SET COLLATE $EXPECTED_COLLATION;"
    log "Created $REFERENCE_DATABASE with canonical charset and collation."
  elif [[ "$actual_charset" != "$EXPECTED_CHARACTER_SET" || "$actual_collation" != "$EXPECTED_COLLATION" ]]; then
    root_query "ALTER DATABASE $REFERENCE_DATABASE CHARACTER SET $EXPECTED_CHARACTER_SET COLLATE $EXPECTED_COLLATION;"
    log "Corrected $REFERENCE_DATABASE database defaults; existing table collations were not altered."
  else
    log "$REFERENCE_DATABASE database settings already canonical."
  fi

  grants_before="$(read_application_grants)"
  # shellcheck disable=SC2016
  if printf '%s\n' "$grants_before" | grep -Eq 'GRANT ALL PRIVILEGES ON `?cycling_platform_reference`?[.]\*'; then
    log "Reference database-scoped application privileges already present."
  else
    # Restrict the account identifier before composing administrative SQL.
    # shellcheck disable=SC2016
    "$COMPOSE_WRAPPER" exec -T mariadb sh -c '
      export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
      case "$MARIADB_USER" in ""|*[!a-zA-Z0-9_.-]*) echo "Unsafe MariaDB application account name." >&2; exit 1;; esac
      exec mariadb --user=root --execute "GRANT ALL PRIVILEGES ON cycling_platform_reference.* TO \`${MARIADB_USER}\`@\`%\`;"
    '
    log "Added Reference database-scoped application privileges."
  fi
fi

read -r schema_exists actual_charset actual_collation < <(read_reference_settings)
[[ "$schema_exists" == "1" ]] || fail "$REFERENCE_DATABASE is missing. Run this command without --check-only."
[[ "$actual_charset" == "$EXPECTED_CHARACTER_SET" ]] || fail "$REFERENCE_DATABASE character set is '$actual_charset', expected '$EXPECTED_CHARACTER_SET'."
[[ "$actual_collation" == "$EXPECTED_COLLATION" ]] || fail "$REFERENCE_DATABASE collation is '$actual_collation', expected '$EXPECTED_COLLATION'."

app_query "SELECT 1;" >/dev/null || fail "The configured application user cannot access $REFERENCE_DATABASE."

# Verify the intended database grant and reject any non-USAGE global grant.
grants="$(read_application_grants)"
# shellcheck disable=SC2016
printf '%s\n' "$grants" | grep -Eq 'GRANT ALL PRIVILEGES ON `?cycling_platform_reference`?[.]\*' ||
  fail "The application user lacks the intended database-scoped Reference grant."
if printf '%s\n' "$grants" | grep -E ' ON \*\.\* ' | grep -Evq '^GRANT USAGE ON \*\.\* '; then
  fail "The application user has unintended global privileges; review grants before continuing."
fi

log "Readiness passed: Reference exists, settings are canonical, application access is available, and no unintended global privilege was found."
