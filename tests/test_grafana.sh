#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

export CYCLING_PLATFORM_EXECUTION_HOST=test-host
export CYCLING_RUNTIME_UID="$(id -u)"
export CYCLING_RUNTIME_GID="$(id -g)"
printf '%s\n' 'MARIADB_NAME=cycling_platform_gold' 'MARIADB_USER=analytics' \
  'MARIADB_PASSWORD=test' 'CARTO_BASEMAP_API_KEY=test' >"$TMP/analytics.env"
CYCLING_ANALYTICS_ENV_FILE="$TMP/analytics.env" docker compose \
  --env-file "$ROOT/compose/.env.example" \
  -f "$ROOT/compose/docker-compose.yml" config --format json >"$TMP/compose.json"

jq -e '
  .services.grafana.image == "grafana/grafana:13.2.1" and
  .services.grafana.restart == "unless-stopped" and
  .services.grafana.environment.GF_AUTH_ANONYMOUS_ENABLED == "false" and
  .services.grafana.environment.GF_USERS_ALLOW_SIGN_UP == "false" and
  .services.grafana.environment.GF_UNIFIED_ALERTING_ENABLED == "false" and
  any(.services.grafana.ports[]; .target == 3000 and .published == "3000" and .host_ip == "192.0.2.10") and
  any(.services.grafana.volumes[]; .source == "/srv/cycling/data/grafana" and .target == "/var/lib/grafana") and
  any(.services.grafana.volumes[]; .target == "/etc/grafana/provisioning" and .read_only == true) and
  any(.services.grafana.volumes[]; .target == "/etc/grafana/dashboards" and .read_only == true)
' "$TMP/compose.json" >/dev/null

datasource="$ROOT/compose/grafana/provisioning/datasources/cycling-platform-admin.yml"
grep -q 'uid: cycling-platform-admin' "$datasource"
grep -q 'url: mariadb:3306' "$datasource"
grep -q 'database: cycling_platform_admin' "$datasource"
grep -q 'editable: false' "$datasource"
grep -Fq 'user: $__env{MARIADB_GRAFANA_READER_USER}' "$datasource"
grep -Fq 'password: $__env{MARIADB_GRAFANA_READER_PASSWORD}' "$datasource"

dashboard="$ROOT/compose/grafana/dashboards/platform-operations.json"
jq -e '
  .title == "Platform Operations" and
  .uid == "cycling-platform-operations" and
  .editable == false and
  .refresh == "2m" and
  .time.from == "now-7d" and
  .timezone == "utc" and
  (has("alert") | not) and
  ([.panels[] | has("alert")] | any | not) and
  ([.panels[] | select(.type == "stat")] | length) == 3 and
  ([.panels[] | select(.type == "table")] | length) == 6 and
  ([.panels[] | select(.type == "row") | .title] == ["Current health", "Current operational debt", "Recent execution history"]) and
  ([.panels[] | select(.targets != null) | .targets[].datasource.uid] | all(. == "cycling-platform-admin")) and
  ([.panels[] | select(.targets != null) | .targets[].rawSql] | map(test("cycling_platform_(raw|silver|gold)")) | any | not) and
  ([.panels[] | select(.targets != null) | .targets[].rawSql] | map(test("INSERT|UPDATE|DELETE|CREATE|DROP"; "i")) | any | not)
' "$dashboard" >/dev/null

jq -e '
  ([.panels[] | select(.type == "stat") | .title] | sort) == (["Overall platform health", "Daily pipeline health", "Backup health"] | sort) and
  ([.panels[] | select(.type == "stat") | .targets[0].rawSql] | map(test("SELECT health_status")) | all) and
  ([.panels[] | select(.type == "stat") | .fieldConfig.defaults.mappings[0].options | has("HEALTHY") and has("WARNING") and has("CRITICAL") and has("UNKNOWN")] | all) and
  ([.panels[] | select(.type == "stat") | .options.reduceOptions.fields] | all(test("health"; "i")))
' "$dashboard" >/dev/null

jq -e '
  ([.panels[] | select(.targets != null) | .targets[].rawSql] | join("\n")) as $sql |
  ($sql | contains("v_platform_health_latest")) and
  ($sql | contains("v_operational_debt_latest")) and
  ($sql | contains("debt_key = '\''latest_daily_pipeline'\''")) and
  ($sql | contains("v_backup_health_latest")) and
  ($sql | contains("health_status <> '\''HEALTHY'\''")) and
  ($sql | contains("v_pipeline_run_history")) and
  ($sql | contains("v_pipeline_phase_history")) and
  ($sql | contains("v_validation_history")) and
  ($sql | contains("v_backup_history")) and
  ($sql | contains("v_google_health_daily_ingestion_failure_history")) and
  ($sql | test("MAX\\(pipeline_run_id\\)") | not) and
  ($sql | test("TIMESTAMPDIFF|INTERVAL [0-9]+ (HOUR|DAY)") | not) and
  ($sql | test("recovery_status.*CASE|CASE.*recovery_status") | not) and
  ([.panels[] | select(.title == "Conditions requiring attention") | .description] | first | test("No rows"))
' "$dashboard" >/dev/null

jq -e '
  ([.panels[] | select(.title == "Daily pipeline runs" or .title == "Validation history" or .title == "Backup attempts and recovery points" or .title == "Google Health ingestion incidents and recoveries") | .targets[0].rawSql] | all(contains("$__timeFilter") and test("LIMIT 50$"))) and
  ([.panels[] | select(.title == "Pipeline phases") | .targets[0].rawSql] | first | contains("CAST(${pipeline_run_id:sqlstring} AS UNSIGNED)") and contains("$__timeFilter") and test("LIMIT 50$")) and
  (.templating.list | length) == 1 and
  .templating.list[0].name == "pipeline_run_id" and
  .templating.list[0].multi == false and
  .templating.list[0].includeAll == false and
  (.templating.list[0].query | contains("v_pipeline_run_history") and contains("$__timeFilter") and test("LIMIT 50$"))
' "$dashboard" >/dev/null

reader_sql="$ROOT/compose/mariadb/reconcile-grafana-reader.sh"
grep -q 'REVOKE ALL PRIVILEGES, GRANT OPTION' "$reader_sql"
[[ "$(grep -c '^GRANT SELECT ON cycling_platform_admin\.v_' "$reader_sql")" == 8 ]]
for view_name in v_platform_health_latest v_pipeline_run_history v_operational_debt_latest v_pipeline_phase_history v_validation_history v_backup_health_latest v_backup_history v_google_health_daily_ingestion_failure_history; do
  grep -q "GRANT SELECT ON cycling_platform_admin\.$view_name" "$reader_sql"
done
if grep -Eq 'GRANT (ALL|INSERT|UPDATE|DELETE)|cycling_platform_(raw|silver|gold|reference)' "$reader_sql"; then
  echo 'Grafana reader SQL grants excessive access' >&2; exit 1
fi

cat >"$TMP/mariadb" <<'MOCK'
#!/bin/sh
cat >"$SQL_CAPTURE"
MOCK
chmod 700 "$TMP/mariadb"
SQL_CAPTURE="$TMP/sql" PATH="$TMP:$PATH" \
  MARIADB_USER=cycling \
  MARIADB_GRAFANA_READER_USER=cycling_grafana_reader \
  MARIADB_GRAFANA_READER_PASSWORD="reader-'quoted" \
  MARIADB_ROOT_PASSWORD=root-test \
  "$reader_sql"
grep -q "ALTER USER 'cycling_grafana_reader'@'%' IDENTIFIED BY 'reader-''quoted';" "$TMP/sql"
grep -q 'GRANT SELECT ON cycling_platform_admin.v_platform_health_latest' "$TMP/sql"
grep -q 'GRANT SELECT ON cycling_platform_admin.v_pipeline_run_history' "$TMP/sql"
grep -q 'GRANT SELECT ON cycling_platform_admin.v_operational_debt_latest' "$TMP/sql"
grep -q 'GRANT SELECT ON cycling_platform_admin.v_pipeline_phase_history' "$TMP/sql"
grep -q 'GRANT SELECT ON cycling_platform_admin.v_validation_history' "$TMP/sql"
grep -q 'GRANT SELECT ON cycling_platform_admin.v_backup_health_latest' "$TMP/sql"
grep -q 'GRANT SELECT ON cycling_platform_admin.v_backup_history' "$TMP/sql"
grep -q 'GRANT SELECT ON cycling_platform_admin.v_google_health_daily_ingestion_failure_history' "$TMP/sql"

cat >"$TMP/mock-docker" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == inspect ]]; then
  case "${MOCK_MARIADB_HEALTH:-healthy}" in
    starting-once)
      if [[ ! -e "$HEALTH_POLLS" ]]; then
        : >"$HEALTH_POLLS"
        printf '%s\n' starting
      else
        printf '%s\n' healthy
      fi ;;
    *) printf '%s\n' "${MOCK_MARIADB_HEALTH:-healthy}" ;;
  esac
fi
MOCK
cat >"$TMP/mock-compose" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'ps -q mariadb') printf '%s\n' container-id ;;
  'exec -T mariadb sh -s') cat >"$RECONCILE_CAPTURE" ;;
  *'SHOW GRANTS FOR'*)
    printf '%s\n' 'GRANT USAGE ON *.* TO `cycling_grafana_reader`@`%`'
    printf '%s\n' 'GRANT SELECT ON `cycling_platform_admin`.`v_platform_health_latest` TO `cycling_grafana_reader`@`%`'
    printf '%s\n' 'GRANT SELECT ON `cycling_platform_admin`.`v_pipeline_run_history` TO `cycling_grafana_reader`@`%`'
    printf '%s\n' 'GRANT SELECT ON `cycling_platform_admin`.`v_operational_debt_latest` TO `cycling_grafana_reader`@`%`'
    printf '%s\n' 'GRANT SELECT ON `cycling_platform_admin`.`v_pipeline_phase_history` TO `cycling_grafana_reader`@`%`'
    printf '%s\n' 'GRANT SELECT ON `cycling_platform_admin`.`v_validation_history` TO `cycling_grafana_reader`@`%`'
    printf '%s\n' 'GRANT SELECT ON `cycling_platform_admin`.`v_backup_health_latest` TO `cycling_grafana_reader`@`%`'
    printf '%s\n' 'GRANT SELECT ON `cycling_platform_admin`.`v_backup_history` TO `cycling_grafana_reader`@`%`'
    printf '%s\n' 'GRANT SELECT ON `cycling_platform_admin`.`v_google_health_daily_ingestion_failure_history` TO `cycling_grafana_reader`@`%`'
    ;;
  *'information_schema.views'*) printf '%s\n' 8 ;;
  *) : ;;
esac
MOCK
chmod 700 "$TMP/mock-docker" "$TMP/mock-compose"
RECONCILE_CAPTURE="$TMP/reconcile-source" HEALTH_POLLS="$TMP/health-polls" \
  COMPOSE_WRAPPER="$TMP/mock-compose" DOCKER_BIN="$TMP/mock-docker" \
  "$ROOT/scripts/reconcile_grafana_reader.sh" >"$TMP/reader-out"
grep -q 'exactly eight approved Admin views' "$TMP/reader-out"
[[ "$(grep -c '^GRANT SELECT ON cycling_platform_admin\.v_' "$TMP/reconcile-source")" == 8 ]]
grep -q 'v_google_health_daily_ingestion_failure_history' "$TMP/reconcile-source"

HEALTH_POLLS="$TMP/health-polls" COMPOSE_WRAPPER="$TMP/mock-compose" DOCKER_BIN="$TMP/mock-docker" \
  "$ROOT/scripts/reconcile_grafana_reader.sh" --check-only >"$TMP/reader-out"
grep -q 'exactly eight approved Admin views' "$TMP/reader-out"

# A freshly reconciled MariaDB container may report starting before healthy.
HEALTH_POLLS="$TMP/health-polls" MOCK_MARIADB_HEALTH=starting-once \
  COMPOSE_WRAPPER="$TMP/mock-compose" DOCKER_BIN="$TMP/mock-docker" \
  "$ROOT/scripts/reconcile_grafana_reader.sh" --check-only >"$TMP/reader-out"
[[ -f "$TMP/health-polls" ]]
grep -q 'exactly eight approved Admin views' "$TMP/reader-out"

# A terminal health failure must not proceed to reader SQL validation.
if MOCK_MARIADB_HEALTH=unhealthy COMPOSE_WRAPPER="$TMP/mock-compose" \
   DOCKER_BIN="$TMP/mock-docker" \
   "$ROOT/scripts/reconcile_grafana_reader.sh" --check-only >"$TMP/reader-out" 2>"$TMP/reader-err"; then
  echo 'unhealthy MariaDB unexpectedly passed the Grafana reader gate' >&2; exit 1
fi
grep -q 'status: unhealthy' "$TMP/reader-err"
grep -q 'INSERT INTO cycling_platform_admin.pipeline_run' "$ROOT/scripts/reconcile_grafana_reader.sh"
grep -q 'UPDATE cycling_platform_admin.pipeline_run' "$ROOT/scripts/reconcile_grafana_reader.sh"
grep -q 'DELETE FROM cycling_platform_admin.pipeline_run' "$ROOT/scripts/reconcile_grafana_reader.sh"

grep -q 'grafana/grafana:13.2.1' "$ROOT/scripts/deploy_grafana.sh"
grep -q '/api/health' "$ROOT/compose/docker-compose.yml"
grep -q 'data/grafana' "$ROOT/bootstrap/40-create-directories.sh"

if grep -R -E 'GF_SECURITY_ADMIN_PASSWORD:[[:space:]]+[^"$]' \
  "$ROOT/compose" --exclude='.env.example'; then
  echo 'A literal Grafana administrator password appears committed' >&2; exit 1
fi

printf '%s\n' 'Grafana vertical-slice contracts: passed'
