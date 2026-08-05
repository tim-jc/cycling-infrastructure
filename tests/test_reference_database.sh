#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
STATE="$TMP/state"
CALLS="$TMP/calls"
GRANTED="$TMP/granted"
export STATE CALLS GRANTED

cat >"$TMP/mock-docker" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "inspect" ]] && printf '%s\n' healthy
MOCK

cat >"$TMP/mock-compose" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CALLS"
if [[ "$*" == "ps -q mariadb" ]]; then printf '%s\n' container-id; exit 0; fi
args="$*"
state="missing"
[[ -f "$STATE" ]] && state="$(cat "$STATE")"
case "$args" in
  *"FROM information_schema.SCHEMATA"*)
    case "$state" in
      missing) printf '%s\n' '0 - -' ;;
      wrong) printf '%s\n' '1 utf8mb4 utf8mb4_unicode_ci' ;;
      *) printf '%s\n' '1 utf8mb4 utf8mb4_general_ci' ;;
    esac ;;
  *"CREATE DATABASE cycling_platform_reference"*) printf '%s' canonical >"$STATE" ;;
  *"ALTER DATABASE cycling_platform_reference"*) printf '%s' canonical >"$STATE" ;;
  *"GRANT ALL PRIVILEGES ON cycling_platform_reference"*) : >"$GRANTED" ;;
  *"SHOW GRANTS FOR"*)
    printf '%s\n' 'GRANT USAGE ON *.* TO `cycling`@`%`'
    [[ -f "$GRANTED" ]] && printf '%s\n' 'GRANT ALL PRIVILEGES ON `cycling_platform_reference`.* TO `cycling`@`%`'
    if [[ "$state" == global ]]; then printf '%s\n' 'GRANT SELECT ON *.* TO `cycling`@`%`'; fi ;;
  *"--database=cycling_platform_reference"*) [[ "$state" != inaccessible ]] ;;
esac
MOCK
chmod 700 "$TMP/mock-docker" "$TMP/mock-compose"

run_reference() {
  COMPOSE_WRAPPER="$TMP/mock-compose" DOCKER_BIN="$TMP/mock-docker" \
    "$ROOT/scripts/reconcile_reference_database.sh" "$@"
}

if run_reference --check-only >"$TMP/out" 2>"$TMP/err"; then
  echo 'missing Reference unexpectedly passed readiness' >&2; exit 1
fi
grep -q 'is missing' "$TMP/err"

if ! run_reference >"$TMP/out" 2>"$TMP/err"; then cat "$TMP/out" "$TMP/err" >&2; exit 1; fi
grep -q 'Created cycling_platform_reference' "$TMP/out"
grep -q 'Added Reference database-scoped' "$TMP/out"
grep -q 'Readiness passed' "$TMP/out"
if ! run_reference >"$TMP/out" 2>"$TMP/err"; then cat "$TMP/out" "$TMP/err" >&2; exit 1; fi
grep -q 'already canonical' "$TMP/out"
grep -q 'privileges already present' "$TMP/out"

printf '%s' wrong >"$STATE"
if ! run_reference >"$TMP/out" 2>"$TMP/err"; then cat "$TMP/out" "$TMP/err" >&2; exit 1; fi
grep -q 'Corrected cycling_platform_reference' "$TMP/out"

printf '%s' global >"$STATE"
if run_reference --check-only >"$TMP/out" 2>"$TMP/err"; then
  echo 'unintended global grant unexpectedly passed readiness' >&2; exit 1
fi
grep -q 'unintended global privileges' "$TMP/err"

printf '%s' inaccessible >"$STATE"
if run_reference --check-only >"$TMP/out" 2>"$TMP/err"; then
  echo 'inaccessible Reference unexpectedly passed readiness' >&2; exit 1
fi
grep -q 'cannot access' "$TMP/err"

init_sql="$ROOT/compose/mariadb/init/10-create-platform-databases.sh"
grep -q 'CREATE DATABASE IF NOT EXISTS cycling_platform_reference CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci' "$init_sql"
grep -q 'GRANT ALL PRIVILEGES ON cycling_platform_reference\.\*' "$init_sql"
[[ "$(grep -c '^CREATE DATABASE IF NOT EXISTS cycling_platform_' "$init_sql")" == 6 ]]
for schema in admin raw stage silver gold reference; do
  grep -Eq "CREATE DATABASE IF NOT EXISTS cycling_platform_${schema} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci" "$init_sql"
done
if grep -Eq 'GRANT ALL PRIVILEGES ON [*][.]' "$init_sql"; then
  echo 'fresh initialization introduced a global privilege' >&2; exit 1
fi

printf '%s\n' 'reference database tests: passed'
