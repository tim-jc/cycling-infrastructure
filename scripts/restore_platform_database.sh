#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$PROJECT_ROOT/compose}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
# shellcheck source=scripts/compose_contract.sh
source "$SCRIPT_DIR/compose_contract.sh"
MODE="check-only"
BACKUP_SET_PREFIX=""
EXPECTED_TARGET_HOST=""
LOCK_DIR="${DATABASE_RESTORE_LOCK_DIR:-/tmp/cycling-platform-database-restore.lock}"
DEPLOY_LOCK_DIR="/tmp/cycling-platform-deployment.lock"
REFERENCE_READINESS_SCRIPT="${REFERENCE_READINESS_SCRIPT:-$SCRIPT_DIR/reconcile_reference_database.sh}"

DURABLE_SCHEMAS=(
  cycling_platform_admin
  cycling_platform_raw
  cycling_platform_reference
  cycling_platform_silver
  cycling_platform_gold
)
ALL_SCHEMAS=(
  cycling_platform_admin
  cycling_platform_raw
  cycling_platform_stage
  cycling_platform_reference
  cycling_platform_silver
  cycling_platform_gold
)
RESTORE_SCHEMAS=()
BACKUP_FILES=()
BACKUP_FORMAT=""
COMPOSE=()

usage() {
  cat <<'USAGE'
Usage:
  restore_platform_database.sh [--check-only] BACKUP_SET_PREFIX
  restore_platform_database.sh --confirm-empty-target --expected-hostname HOST BACKUP_SET_PREFIX

BACKUP_SET_PREFIX identifies one matched set without the schema suffix, for
example:
  /path/to/recovery/2026-07-27_050000

Historical sets contain Admin, Raw, Silver and Gold. Current sets additionally
contain Reference. Stage is never restored.

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

  # Expanded by the container shell, not this host shell.
  # shellcheck disable=SC2016
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

  for database in cycling_platform_admin cycling_platform_raw cycling_platform_silver cycling_platform_gold; do
    expected_file="${BACKUP_SET_PREFIX}_${database}.sql.gz"
    [[ -f "$expected_file" ]] || fail "Required backup file not found: $expected_file"
    [[ ! -L "$expected_file" ]] || fail "Backup files must not be symbolic links: $expected_file"
    [[ -s "$expected_file" ]] || fail "Backup file is empty: $expected_file"
    gzip -t "$expected_file" || fail "gzip integrity validation failed: $expected_file"
  done

  shopt -s nullglob
  matching_files=("${BACKUP_SET_PREFIX}"_cycling_platform_*.sql.gz)
  shopt -u nullglob

  case "${#matching_files[@]}" in
    4)
      BACKUP_FORMAT="historical-four-file"
      RESTORE_SCHEMAS=(cycling_platform_admin cycling_platform_raw cycling_platform_silver cycling_platform_gold)
      ;;
    5)
      BACKUP_FORMAT="current-five-file"
      RESTORE_SCHEMAS=(cycling_platform_admin cycling_platform_raw cycling_platform_reference cycling_platform_silver cycling_platform_gold)
      [[ -f "${BACKUP_SET_PREFIX}_cycling_platform_reference.sql.gz" ]] ||
        fail "A five-file set must contain the matched cycling_platform_reference dump."
      ;;
    *)
      fail "Backup prefix must identify a valid historical four-file or current five-file platform set; found ${#matching_files[@]}."
      ;;
  esac

  for candidate in "${matching_files[@]}"; do
    case "$candidate" in
      "${BACKUP_SET_PREFIX}_cycling_platform_admin.sql.gz"|\
      "${BACKUP_SET_PREFIX}_cycling_platform_raw.sql.gz"|\
      "${BACKUP_SET_PREFIX}_cycling_platform_reference.sql.gz"|\
      "${BACKUP_SET_PREFIX}_cycling_platform_silver.sql.gz"|\
      "${BACKUP_SET_PREFIX}_cycling_platform_gold.sql.gz")
        ;;
      *)
        fail "Unexpected schema dump for backup prefix: $candidate"
        ;;
    esac
  done

  for database in "${RESTORE_SCHEMAS[@]}"; do
    expected_file="${BACKUP_SET_PREFIX}_${database}.sql.gz"
    [[ -f "$expected_file" && ! -L "$expected_file" && -s "$expected_file" ]] ||
      fail "Required backup file is absent, empty, or unsafe: $expected_file"
    gzip -t "$expected_file" || fail "gzip integrity validation failed: $expected_file"
    BACKUP_FILES+=("$expected_file")
  done

  log "Backup set is complete, matched, non-empty, and gzip-valid: $prefix_name ($BACKUP_FORMAT)"
}

validate_target() {
  local container_id
  local health_status
  local schema
  local schema_count
  local object_count
  local running_platform_containers
  local reference_settings

  compose_contract_init || fail "Canonical Compose runtime initialization failed."
  COMPOSE=("${CYCLING_COMPOSE[@]}")

  [[ -f "$COMPOSE_FILE" ]] || fail "Compose file not found: $COMPOSE_FILE"
  [[ -f "$ENV_FILE" ]] || fail "Compose environment file not found: $ENV_FILE"
  [[ -r "$ENV_FILE" ]] || fail "Compose environment file is not readable: $ENV_FILE"

  require_env_value MARIADB_USER
  require_env_value MARIADB_PASSWORD
  require_env_value MARIADB_ROOT_PASSWORD

  "${COMPOSE[@]}" version >/dev/null || fail "Docker Compose is unavailable."
  "${COMPOSE[@]}" config --quiet >/dev/null || fail "Compose configuration is invalid."

  container_id="$("${COMPOSE[@]}" ps -q mariadb)"
  [[ -n "$container_id" ]] || fail "MariaDB Compose service is not running."

  health_status="$("$DOCKER_BIN" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id")"
  [[ "$health_status" == "healthy" ]] ||
    fail "MariaDB Compose service is not healthy (status: ${health_status:-unknown})."

  [[ -x "$REFERENCE_READINESS_SCRIPT" ]] || fail "Reference readiness helper is unavailable: $REFERENCE_READINESS_SCRIPT"
  COMPOSE_DIR="$COMPOSE_DIR" DOCKER_BIN="$DOCKER_BIN" "$REFERENCE_READINESS_SCRIPT" --check-only ||
    fail "Reference database readiness failed."

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
        WHERE TABLE_SCHEMA IN ('cycling_platform_admin','cycling_platform_raw','cycling_platform_reference','cycling_platform_silver','cycling_platform_gold')) +
      (SELECT COUNT(*) FROM information_schema.ROUTINES
        WHERE ROUTINE_SCHEMA IN ('cycling_platform_admin','cycling_platform_raw','cycling_platform_reference','cycling_platform_silver','cycling_platform_gold')) +
      (SELECT COUNT(*) FROM information_schema.TRIGGERS
        WHERE TRIGGER_SCHEMA IN ('cycling_platform_admin','cycling_platform_raw','cycling_platform_reference','cycling_platform_silver','cycling_platform_gold')) +
      (SELECT COUNT(*) FROM information_schema.EVENTS
        WHERE EVENT_SCHEMA IN ('cycling_platform_admin','cycling_platform_raw','cycling_platform_reference','cycling_platform_silver','cycling_platform_gold'));
  ")"

  [[ "$object_count" =~ ^[0-9]+$ ]] || fail "Could not determine whether the target schemas are empty."
  (( object_count == 0 )) ||
    fail "Persistent target schemas contain $object_count database object(s). Restore is allowed only into a fresh empty target."

  reference_settings="$(mariadb_query "SELECT CONCAT(DEFAULT_CHARACTER_SET_NAME, '/', DEFAULT_COLLATION_NAME) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'cycling_platform_reference';")"
  [[ "$reference_settings" == "utf8mb4/utf8mb4_general_ci" ]] ||
    fail "Reference database settings are '$reference_settings', expected utf8mb4/utf8mb4_general_ci."
  mariadb_query "USE cycling_platform_reference; SELECT 1;" >/dev/null ||
    fail "The configured application user cannot access cycling_platform_reference."

  log "MariaDB is healthy; all six databases exist; durable target databases are empty; Reference settings and access are ready."
}

restore_database() {
  local database="$1"
  local backup_file="$2"

  log "Restoring $database from $(basename "$backup_file")"
  # The single-quoted script is expanded by the container shell.
  # shellcheck disable=SC2016
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
  local reference_settings
  local reference_table_count

  log "Read-only post-restore validation:"
  for schema in "${DURABLE_SCHEMAS[@]}"; do
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

  reference_settings="$(mariadb_query "SELECT CONCAT(DEFAULT_CHARACTER_SET_NAME, '/', DEFAULT_COLLATION_NAME) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'cycling_platform_reference';")"
  [[ "$reference_settings" == "utf8mb4/utf8mb4_general_ci" ]] || fail "Reference settings changed during restore."
  mariadb_query "USE cycling_platform_reference; SELECT 1;" >/dev/null || fail "Reference is not accessible after restore."
  if [[ "$BACKUP_FORMAT" == "historical-four-file" ]]; then
    reference_table_count="$(mariadb_query "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'cycling_platform_reference';")"
    [[ "$reference_table_count" == "0" ]] || fail "Historical restore must leave Reference empty."
    printf '  cycling_platform_reference remains empty for historical backup compatibility.\n'
  fi
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

[[ ! -d "$DEPLOY_LOCK_DIR" ]] || fail "Platform deployment appears active: $DEPLOY_LOCK_DIR"
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
for index in "${!RESTORE_SCHEMAS[@]}"; do
  restore_database "${RESTORE_SCHEMAS[$index]}" "${BACKUP_FILES[$index]}"
done

validate_restored_data
log "Restore complete. ETL and production scheduling were not run or enabled."
