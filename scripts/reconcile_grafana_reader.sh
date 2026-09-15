#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_WRAPPER="${COMPOSE_WRAPPER:-$SCRIPT_DIR/compose.sh}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
MODE="reconcile"

log() { printf '[grafana-reader] %s\n' "$*"; }
fail() { printf '[grafana-reader] ERROR: %s\n' "$*" >&2; exit 1; }

if (( $# > 1 )); then fail 'Usage: reconcile_grafana_reader.sh [--check-only]'; fi
if (( $# == 1 )); then
  case "$1" in
    --check-only) MODE="check-only" ;;
    --help|-h) printf '%s\n' 'Usage: reconcile_grafana_reader.sh [--check-only]'; exit 0 ;;
    *) fail 'Usage: reconcile_grafana_reader.sh [--check-only]' ;;
  esac
fi

command -v "$DOCKER_BIN" >/dev/null 2>&1 || fail "Docker is unavailable."
[[ -x "$COMPOSE_WRAPPER" ]] || fail "Compose wrapper is unavailable: $COMPOSE_WRAPPER"
container_id="$($COMPOSE_WRAPPER ps -q mariadb)"
[[ -n "$container_id" ]] || fail "MariaDB Compose service is not running."
health_status="$($DOCKER_BIN inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id")"
[[ "$health_status" == "healthy" ]] || fail "MariaDB is not healthy (status: ${health_status:-unknown})."

if [[ "$MODE" == "reconcile" ]]; then
  "$COMPOSE_WRAPPER" exec -T mariadb /usr/local/bin/cycling-reconcile-grafana-reader.sh
  log "Reconciled the Grafana reader and removed privilege drift."
fi

if ! grants="$($COMPOSE_WRAPPER exec -T mariadb sh -c '
  export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
  exec mariadb --user=root --batch --skip-column-names --raw --execute "SHOW GRANTS FOR \`${MARIADB_GRAFANA_READER_USER}\`@\`%\`;"
' 2>&1)"; then
  fail "The configured Grafana reader is missing or unreadable; run without --check-only."
fi

select_health="$(printf '%s\n' "$grants" | grep -Ec '^GRANT SELECT ON `?cycling_platform_admin`?[.]`?v_platform_health_latest`? TO ' || true)"
select_pipeline="$(printf '%s\n' "$grants" | grep -Ec '^GRANT SELECT ON `?cycling_platform_admin`?[.]`?v_pipeline_run_history`? TO ' || true)"
[[ "$select_health" == 1 && "$select_pipeline" == 1 ]] || fail "Grafana reader lacks the exact approved view grants."
unexpected="$(printf '%s\n' "$grants" | grep '^GRANT ' | grep -Ev '^GRANT USAGE ON \*\.\* TO |^GRANT SELECT ON `?cycling_platform_admin`?[.]`?(v_platform_health_latest|v_pipeline_run_history)`? TO ' || true)"
[[ -z "$unexpected" ]] || fail "Grafana reader has privileges outside the two-view contract."

view_contract="$($COMPOSE_WRAPPER exec -T mariadb sh -c '
  export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
  exec mariadb --user=root --batch --skip-column-names --raw --execute "
    SELECT COUNT(*)
    FROM information_schema.views
    WHERE table_schema = '\''cycling_platform_admin'\''
      AND table_name IN ('\''v_platform_health_latest'\'', '\''v_pipeline_run_history'\'')
      AND security_type = '\''DEFINER'\''
      AND definer IS NOT NULL;"
')"
[[ "$view_contract" == 2 ]] || fail "Approved Admin views are absent or do not use durable DEFINER security."

"$COMPOSE_WRAPPER" exec -T mariadb sh -c '
  export MYSQL_PWD="$MARIADB_GRAFANA_READER_PASSWORD"
  mariadb --host=127.0.0.1 --user="$MARIADB_GRAFANA_READER_USER" --batch --skip-column-names --execute "SELECT health_status FROM cycling_platform_admin.v_platform_health_latest; SELECT run_status FROM cycling_platform_admin.v_pipeline_run_history ORDER BY pipeline_run_id DESC LIMIT 1;" >/dev/null
  if mariadb --host=127.0.0.1 --user="$MARIADB_GRAFANA_READER_USER" --execute "SELECT pipeline_run_id FROM cycling_platform_admin.pipeline_run LIMIT 1;" >/dev/null 2>&1; then exit 41; fi
  if mariadb --host=127.0.0.1 --user="$MARIADB_GRAFANA_READER_USER" --execute "SELECT activity_id FROM cycling_platform_silver.activities LIMIT 1;" >/dev/null 2>&1; then exit 42; fi
  if mariadb --host=127.0.0.1 --user="$MARIADB_GRAFANA_READER_USER" --execute "SELECT activity_id FROM cycling_platform_raw.activities LIMIT 1;" >/dev/null 2>&1; then exit 43; fi
  if mariadb --host=127.0.0.1 --user="$MARIADB_GRAFANA_READER_USER" --execute "SELECT activity_id FROM cycling_platform_gold.activity_achievements LIMIT 1;" >/dev/null 2>&1; then exit 44; fi
  if mariadb --host=127.0.0.1 --user="$MARIADB_GRAFANA_READER_USER" --execute "INSERT INTO cycling_platform_admin.pipeline_run () VALUES ();" >/dev/null 2>&1; then exit 45; fi
  if mariadb --host=127.0.0.1 --user="$MARIADB_GRAFANA_READER_USER" --execute "UPDATE cycling_platform_admin.pipeline_run SET run_status = run_status WHERE 1 = 0;" >/dev/null 2>&1; then exit 46; fi
  if mariadb --host=127.0.0.1 --user="$MARIADB_GRAFANA_READER_USER" --execute "DELETE FROM cycling_platform_admin.pipeline_run WHERE 1 = 0;" >/dev/null 2>&1; then exit 47; fi
'

log "Readiness passed: SELECT on exactly two approved Admin views; base tables and analytical schemas are denied; INSERT, UPDATE and DELETE are denied."
