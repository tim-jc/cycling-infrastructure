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
  (.panels | length) == 2 and
  ([.panels[].targets[].rawSql] | map(test("v_platform_health_latest|v_pipeline_run_history")) | all) and
  ([.panels[].targets[].rawSql] | map(test("cycling_platform_(raw|silver|gold)")) | any | not)
' "$dashboard" >/dev/null

reader_sql="$ROOT/compose/mariadb/reconcile-grafana-reader.sh"
grep -q 'REVOKE ALL PRIVILEGES, GRANT OPTION' "$reader_sql"
[[ "$(grep -c '^GRANT SELECT ON cycling_platform_admin\.v_' "$reader_sql")" == 2 ]]
grep -q 'v_platform_health_latest' "$reader_sql"
grep -q 'v_pipeline_run_history' "$reader_sql"
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
  *'SHOW GRANTS FOR'*)
    printf '%s\n' 'GRANT USAGE ON *.* TO `cycling_grafana_reader`@`%`'
    printf '%s\n' 'GRANT SELECT ON `cycling_platform_admin`.`v_platform_health_latest` TO `cycling_grafana_reader`@`%`'
    printf '%s\n' 'GRANT SELECT ON `cycling_platform_admin`.`v_pipeline_run_history` TO `cycling_grafana_reader`@`%`'
    ;;
  *'information_schema.views'*) printf '%s\n' 2 ;;
  *) : ;;
esac
MOCK
chmod 700 "$TMP/mock-docker" "$TMP/mock-compose"
HEALTH_POLLS="$TMP/health-polls" COMPOSE_WRAPPER="$TMP/mock-compose" DOCKER_BIN="$TMP/mock-docker" \
  "$ROOT/scripts/reconcile_grafana_reader.sh" --check-only >"$TMP/reader-out"
grep -q 'exactly two approved Admin views' "$TMP/reader-out"

# A freshly reconciled MariaDB container may report starting before healthy.
HEALTH_POLLS="$TMP/health-polls" MOCK_MARIADB_HEALTH=starting-once \
  COMPOSE_WRAPPER="$TMP/mock-compose" DOCKER_BIN="$TMP/mock-docker" \
  "$ROOT/scripts/reconcile_grafana_reader.sh" --check-only >"$TMP/reader-out"
[[ -f "$TMP/health-polls" ]]
grep -q 'exactly two approved Admin views' "$TMP/reader-out"

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
