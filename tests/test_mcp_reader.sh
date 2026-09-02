#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
STATE="$TMP/state"
CALLS="$TMP/calls"
export STATE CALLS

cat >"$TMP/mock-docker" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == inspect ]] && printf '%s\n' healthy
MOCK

cat >"$TMP/mock-compose" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CALLS"
if [[ "$*" == "ps -q mariadb" ]]; then printf '%s\n' container-id; exit 0; fi
state=missing
[[ -f "$STATE" ]] && state="$(cat "$STATE")"
case "$*" in
  *"SHOW GRANTS FOR"*)
    [[ "$state" != missing ]] || exit 1
    printf '%s\n' 'GRANT USAGE ON *.* TO `cycling_mcp_reader`@`%`'
    printf '%s\n' 'GRANT SELECT ON `cycling_platform_silver`.* TO `cycling_mcp_reader`@`%`'
    [[ "$state" != excess ]] || printf '%s\n' 'GRANT INSERT ON `cycling_platform_admin`.* TO `cycling_mcp_reader`@`%`'
    ;;
  *"/usr/local/bin/cycling-reconcile-mcp-reader.sh"*) printf '%s' exact >"$STATE" ;;
esac
MOCK
chmod 700 "$TMP/mock-docker" "$TMP/mock-compose"

run_reader() {
  COMPOSE_WRAPPER="$TMP/mock-compose" DOCKER_BIN="$TMP/mock-docker" \
    "$ROOT/scripts/reconcile_mcp_reader.sh" "$@"
}

if run_reader --check-only >"$TMP/out" 2>"$TMP/err"; then
  echo 'missing cycling-mcp account unexpectedly passed' >&2; exit 1
fi
grep -q 'missing or unreadable' "$TMP/err"

run_reader >"$TMP/out"
grep -q 'removed privilege drift' "$TMP/out"
grep -q 'Readiness passed' "$TMP/out"
run_reader --check-only >"$TMP/out"
grep -q 'exactly SELECT on cycling_platform_silver' "$TMP/out"

printf '%s' excess >"$STATE"
if run_reader --check-only >"$TMP/out" 2>"$TMP/err"; then
  echo 'excess cycling-mcp privilege unexpectedly passed' >&2; exit 1
fi
grep -q 'privileges outside' "$TMP/err"
run_reader >"$TMP/out"
[[ "$(cat "$STATE")" == exact ]]

grep -q '/usr/local/bin/cycling-reconcile-mcp-reader.sh' "$CALLS"

cat >"$TMP/mariadb" <<'MOCK'
#!/bin/sh
cat >"$SQL_CAPTURE"
MOCK
chmod 700 "$TMP/mariadb"
SQL_CAPTURE="$TMP/sql" PATH="$TMP:$PATH" \
  MARIADB_USER=cycling \
  MARIADB_MCP_READER_USER=cycling_mcp_reader \
  MARIADB_MCP_READER_PASSWORD="test-reader-'quoted" \
  MARIADB_ROOT_PASSWORD=test-root \
  "$ROOT/compose/mariadb/reconcile-mcp-reader.sh"
grep -q "ALTER USER 'cycling_mcp_reader'@'%' IDENTIFIED BY 'test-reader-''quoted';" "$TMP/sql"
grep -q "REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'cycling_mcp_reader'@'%';" "$TMP/sql"
grep -q "GRANT SELECT ON cycling_platform_silver\.\* TO 'cycling_mcp_reader'@'%';" "$TMP/sql"

init_sql="$ROOT/compose/mariadb/init/10-create-platform-databases.sh"
grep -q "CREATE USER IF NOT EXISTS '\$sql_mcp_user'@'%'" "$init_sql"
grep -q "GRANT SELECT ON cycling_platform_silver\.\* TO '\$sql_mcp_user'@'%'" "$init_sql"
if grep -Eq "GRANT (ALL|INSERT|UPDATE|DELETE).*TO '\$sql_mcp_user'" "$init_sql"; then
  echo 'fresh initialization gave the cycling-mcp account a write or broad grant' >&2; exit 1
fi

grep -q 'reconcile_mcp_reader.sh' "$ROOT/scripts/start_mariadb.sh"
printf '%s\n' 'cycling-mcp reader tests: passed'
