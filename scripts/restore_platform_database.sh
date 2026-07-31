#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$PROJECT_ROOT/compose}"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
ENV_FILE="$COMPOSE_DIR/.env"
DOCKER_BIN="${DOCKER_BIN:-docker}"
export CYCLING_PLATFORM_EXECUTION_HOST="$(hostname -s)"
MODE="check-only"
BACKUP_SET_PREFIX=""
EXPECTED_TARGET_HOST=""
LOCK_DIR="/tmp/cycling-platform-database-restore.lock"

PERSISTENT_SCHEMAS=(
  cycling_platform_admin
  cycling_platform_raw
  cycling_platform_silver
  cycling_platform_gold
)
ALL_SCHEMAS=(
  cycling_platform_admin
  cycling_platform_raw
  cycling_platform_stage
  cycling_platform_silver
  cycling_platform_gold
)
BACKUP_FILES=()
COMPOSE=()

usage() {
  cat <<'USAGE'
Usage:
  restore_platform_database.sh [--check-only] BACKUP_SET_PREFIX
  restore_platform_database.sh --confirm-empty-target --expected-hostname HOST BACKUP_SET_PREFIX

BACKUP_SET_PREFIX identifies one four-file set without the schema suffix, for
example:
  /path/to/recovery/2026-07-27_050000

With no option, the script runs in check-only mode. A restore requires the
explicit --confirm-empty-target option, an exact target-host assertion, and still refuses any non-empty target.
USAGE
}

log() {
  printf '[restore-database] %s\n' "$*"
}

fail() {
  printf '[restore-database] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -d "$LOCK_DIR" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_env_value() {
  local key="$1"
  local value

  value="$(awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$ENV_FILE")"

  if [[ -z "$value" || "$value" == '""' || "$value" == "''" ]]; then
    fail "$key is missing or empty in $ENV_FILE"
  fi
}

mariadb_query() {
  local sql="$1"

  "${COMPOSE[@]}" exec -T mariadb sh -c '
    export MYSQL_PWD="$MARIADB_PASSWORD"
    exec mariadb \
      --user="$MARIADB_USER" \
      --batch \
      --skip-column-names \
      --raw \
      --execute "$1"
  ' query "$sql"
}

validate_backup_set() {
  local backup_directory
  local prefix_name
  local database
  local expected_file
  local candidate
  local -a matching_files

  backup_directory="$(dirname "$BACKUP_SET_PREFIX")"
  prefix_name="$(basename "$BACKUP_SET_PREFIX")"

  [[ -d "$backup_directory" ]] || fail "Backup directory not found: $backup_directory"
  [[ "$prefix_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]] ||
    fail "Backup prefix must have format YYYY-MM-DD_HHMMSS: $prefix_name"

  for database in "${PERSISTENT_SCHEMAS[@]}"; do
    expected_file="${BACKUP_SET_PREFIX}_${database}.sql.gz"
    [[ -f "$expected_file" ]] || fail "Required backup file not found: $expected_file"
    [[ ! -L "$expected_file" ]] || fail "Backup files must not be symbolic links: $expected_file"
    [[ -s "$expected_file" ]] || fail "Backup file is empty: $expected_file"
    gzip -t "$expected_file" || fail "gzip integrity validation failed: $expected_file"
    BACKUP_FILES+=("$expected_file")
  done

  shopt -s nullglob
  matching_files=("${BACKUP_SET_PREFIX}"_cycling_platform_*.sql.gz)
  shopt -u nullglob

  if (( ${#matching_files[@]} != 4 )); then
    fail "Backup prefix must identify exactly four platform dump files; found ${#matching_files[@]}."
  fi

  for candidate in "${matching_files[@]}"; do
    case "$candidate" in
      "${BACKUP_SET_PREFIX}_cycling_platform_admin.sql.gz"|\
      "${BACKUP_SET_PREFIX}_cycling_platform_raw.sql.gz"|\
      "${BACKUP_SET_PREFIX}_cycling_platform_silver.sql.gz"|\
      "${BACKUP_SET_PREFIX}_cycling_platform_gold.sql.gz")
        ;;
      *)
        fail "Unexpected schema dump for backup prefix: $candidate"
        ;;
    esac
  done

  log "Backup set is complete, matched, non-empty, and gzip-valid: $prefix_name"
}

validate_target() {
  local container_id
  local health_status
  local schema
  local schema_count
  local object_count
  local running_platform_containers

  [[ -f "$COMPOSE_FILE" ]] || fail "Compose file not found: $COMPOSE_FILE"
  [[ -f "$ENV_FILE" ]] || fail "Compose environment file not found: $ENV_FILE"
  [[ -r "$ENV_FILE" ]] || fail "Compose environment file is not readable: $ENV_FILE"

  require_env_value MARIADB_USER
  require_env_value MARIADB_PASSWORD
  require_env_value MARIADB_ROOT_PASSWORD

  COMPOSE=(
    "$DOCKER_BIN" compose
    --project-directory "$COMPOSE_DIR"
    --env-file "$ENV_FILE"
    --file "$COMPOSE_FILE"
  )

  "${COMPOSE[@]}" version >/dev/null || fail "Docker Compose is unavailable."
  "${COMPOSE[@]}" config --quiet >/dev/null || fail "Compose configuration is invalid."

  container_id="$("${COMPOSE[@]}" ps -q mariadb)"
  [[ -n "$container_id" ]] || fail "MariaDB Compose service is not running."

  health_status="$("$DOCKER_BIN" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id")"
  [[ "$health_status" == "healthy" ]] ||
    fail "MariaDB Compose service is not healthy (status: ${health_status:-unknown})."

  running_platform_containers="$("${COMPOSE[@]}" ps -q cycling-platform)"
  [[ -z "$running_platform_containers" ]] ||
    fail "A cycling-platform Compose container is running; stop jobs before recovery."

  for schema in "${ALL_SCHEMAS[@]}"; do
    schema_count="$(mariadb_query "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$schema';")"
    [[ "$schema_count" == "1" ]] || fail "Required target schema does not exist: $schema"
  done

  object_count="$(mariadb_query "
    SELECT
      (SELECT COUNT(*) FROM information_schema.TABLES
        WHERE TABLE_SCHEMA IN ('cycling_platform_admin','cycling_platform_raw','cycling_platform_silver','cycling_platform_gold')) +
      (SELECT COUNT(*) FROM information_schema.ROUTINES
        WHERE ROUTINE_SCHEMA IN ('cycling_platform_admin','cycling_platform_raw','cycling_platform_silver','cycling_platform_gold')) +
      (SELECT COUNT(*) FROM information_schema.TRIGGERS
        WHERE TRIGGER_SCHEMA IN ('cycling_platform_admin','cycling_platform_raw','cycling_platform_silver','cycling_platform_gold')) +
      (SELECT COUNT(*) FROM information_schema.EVENTS
        WHERE EVENT_SCHEMA IN ('cycling_platform_admin','cycling_platform_raw','cycling_platform_silver','cycling_platform_gold'));
  ")"

  [[ "$object_count" =~ ^[0-9]+$ ]] || fail "Could not determine whether the target schemas are empty."
  (( object_count == 0 )) ||
    fail "Persistent target schemas contain $object_count database object(s). Restore is allowed only into a fresh empty target."

  log "MariaDB is healthy; all five schemas exist; persistent target schemas are empty."
}

restore_database() {
  local database="$1"
  local backup_file="$2"

  log "Restoring $database from $(basename "$backup_file")"
  gzip -cd "$backup_file" |
    "${COMPOSE[@]}" exec -T mariadb sh -c '
      export MYSQL_PWD="$MARIADB_PASSWORD"
      exec mariadb --user="$MARIADB_USER" "$1"
    ' restore "$database"
}

validate_restored_data() {
  local schema
  local table_count
  local silver_activities_exists
  local silver_summary
  local schema_count

  log "Read-only post-restore validation:"
  for schema in "${PERSISTENT_SCHEMAS[@]}"; do
    table_count="$(mariadb_query "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$schema' AND TABLE_TYPE = 'BASE TABLE';")"
    [[ "$table_count" =~ ^[0-9]+$ ]] || fail "Could not count tables in $schema."
    printf '  %-28s tables=%s\n' "$schema" "$table_count"
  done

  silver_activities_exists="$(mariadb_query "
    SELECT COUNT(*) FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = 'cycling_platform_silver'
      AND TABLE_NAME = 'activities'
      AND TABLE_TYPE = 'BASE TABLE';
  ")"

  if [[ "$silver_activities_exists" == "1" ]]; then
    silver_summary="$(mariadb_query "
      SELECT CONCAT(
        'rows=', COUNT(*),
        ' min_start_date_local=', COALESCE(DATE_FORMAT(MIN(start_date_local), '%Y-%m-%d'), 'NULL'),
        ' max_start_date_local=', COALESCE(DATE_FORMAT(MAX(start_date_local), '%Y-%m-%d'), 'NULL')
      )
      FROM cycling_platform_silver.activities;
    ")"
    printf '  cycling_platform_silver.activities %s\n' "$silver_summary"
  else
    printf '  cycling_platform_silver.activities not present; count/date-range check skipped.\n'
  fi

  schema_count="$(mariadb_query "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'cycling_platform_stage';")"
  [[ "$schema_count" == "1" ]] || fail "Stage schema is missing after restore."
  printf '  cycling_platform_stage exists (not restored).\n'
}

if (( $# == 0 )); then
  usage >&2
  exit 2
fi
if (( $# == 1 )) && [[ "$1" == "--help" || "$1" == "-h" ]]; then
  usage
  exit 0
fi

while (( $# > 1 )); do
  case "$1" in
    --check-only)
      MODE="check-only"
      shift
      ;;
    --confirm-empty-target)
      MODE="restore"
      shift
      ;;
    --expected-hostname)
      [[ $# -ge 2 ]] || fail "--expected-hostname requires a value."
      EXPECTED_TARGET_HOST="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if (( $# != 1 )); then
  usage >&2
  exit 2
fi
BACKUP_SET_PREFIX="${1%/}"

if [[ "$MODE" == "restore" ]]; then
  [[ -n "$EXPECTED_TARGET_HOST" ]] || fail "Restore requires --expected-hostname with the intentional target host."
  actual_target_host="$(hostname -s)"
  [[ "$actual_target_host" == "$EXPECTED_TARGET_HOST" ]] ||
    fail "Target host assertion failed: expected '$EXPECTED_TARGET_HOST', detected '$actual_target_host'."
  log "Target host assertion accepted: $actual_target_host"
elif [[ -n "$EXPECTED_TARGET_HOST" && "$(hostname -s)" != "$EXPECTED_TARGET_HOST" ]]; then
  fail "Check-only target host assertion failed."
fi

require_command awk
require_command basename
require_command dirname
require_command gzip
require_command "$DOCKER_BIN"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "Another database restore check or restore appears active: $LOCK_DIR"
fi
trap cleanup EXIT

validate_backup_set
validate_target

if [[ "$MODE" == "check-only" ]]; then
  log "Check-only validation passed. No database changes were made."
  exit 0
fi

log "Explicit disaster-recovery confirmation accepted; target emptiness was independently verified."
for index in "${!PERSISTENT_SCHEMAS[@]}"; do
  restore_database "${PERSISTENT_SCHEMAS[$index]}" "${BACKUP_FILES[$index]}"
done

validate_restored_data
log "Restore complete. ETL and production scheduling were not run or enabled."
