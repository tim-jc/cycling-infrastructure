#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/compose" "$TMP/backups"
cp "$ROOT/compose/docker-compose.yml" "$TMP/compose/docker-compose.yml"
printf '%s\n' 'MARIADB_USER=cycling' 'MARIADB_PASSWORD=test' 'MARIADB_ROOT_PASSWORD=test-root' >"$TMP/compose/.env"

cat >"$TMP/reference-ready" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

cat >"$TMP/mock-hostname" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' 'cycling-recovery-test'
MOCK
cat >"$TMP/mock-id" <<'MOCK'
#!/usr/bin/env bash
case "$1" in -u) printf '%s\n' 1234 ;; -g) printf '%s\n' 5678 ;; *) exit 2 ;; esac
MOCK

cat >"$TMP/mock-docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
if [[ "$args" == compose* ]]; then
  [[ "${CYCLING_PLATFORM_EXECUTION_HOST:-}" == cycling-recovery-test ]]
  [[ "${CYCLING_PLATFORM_RUNTIME_UID:-}" == 1234 ]]
  [[ "${CYCLING_PLATFORM_RUNTIME_GID:-}" == 5678 ]]
fi
printf '%s\n' "$args" >>"$MOCK_DOCKER_CALLS"
case "$args" in
  "inspect --format "*) printf '%s\n' healthy ;;
  "compose "*" version"|"compose "*" config --quiet") : ;;
  "compose "*" ps -q mariadb") printf '%s\n' container-id ;;
  "compose "*" ps -q cycling-platform") : ;;
  *"DEFAULT_CHARACTER_SET_NAME"*) printf '%s\n' 'utf8mb4/utf8mb4_general_ci' ;;
  *"information_schema.SCHEMATA WHERE SCHEMA_NAME"*) printf '%s\n' 1 ;;
  *"information_schema.TABLES"*"information_schema.ROUTINES"*) printf '%s\n' 0 ;;
  *"USE cycling_platform_reference"*) printf '%s\n' 1 ;;
  *"TABLE_TYPE = 'BASE TABLE'"*) printf '%s\n' 0 ;;
  *"TABLE_SCHEMA = 'cycling_platform_reference'"*) printf '%s\n' 0 ;;
  "compose "*" exec -T mariadb sh -c "*) cat >/dev/null || true ;;
  *) printf 'unexpected mock Docker call: %s\n' "$args" >&2; exit 2 ;;
esac
MOCK
chmod 700 "$TMP/reference-ready" "$TMP/mock-docker" "$TMP/mock-hostname" "$TMP/mock-id"
export MOCK_DOCKER_CALLS="$TMP/docker-calls"

make_dump() { printf '%s\n' '-- test dump' | gzip >"$1"; }
make_set() {
  local prefix="$1" include_reference="$2" schema
  for schema in admin raw silver gold; do make_dump "${prefix}_cycling_platform_${schema}.sql.gz"; done
  if [[ "$include_reference" == yes ]]; then
    make_dump "${prefix}_cycling_platform_reference.sql.gz"
  fi
}
run_check() {
  COMPOSE_DIR="$TMP/compose" DOCKER_BIN="$TMP/mock-docker" \
    COMPOSE_HOSTNAME_BIN="$TMP/mock-hostname" COMPOSE_ID_BIN="$TMP/mock-id" \
    REFERENCE_READINESS_SCRIPT="$TMP/reference-ready" DATABASE_RESTORE_LOCK_DIR="$TMP/restore.lock" \
    "$ROOT/scripts/restore_platform_database.sh" --check-only "$1"
}
run_restore() {
  COMPOSE_DIR="$TMP/compose" DOCKER_BIN="$TMP/mock-docker" \
    COMPOSE_HOSTNAME_BIN="$TMP/mock-hostname" COMPOSE_ID_BIN="$TMP/mock-id" \
    REFERENCE_READINESS_SCRIPT="$TMP/reference-ready" DATABASE_RESTORE_LOCK_DIR="$TMP/restore.lock" \
    "$ROOT/scripts/restore_platform_database.sh" --confirm-empty-target \
      --expected-hostname "$(hostname -s)" "$1"
}

historical="$TMP/backups/2026-08-01_050000"
current="$TMP/backups/2026-08-02_050000"
incomplete="$TMP/backups/2026-08-03_050000"
make_set "$historical" no
make_set "$current" yes
make_set "$incomplete" no
make_dump "${incomplete}_cycling_platform_unexpected.sql.gz"

run_check "$historical" >"$TMP/out"
grep -q 'historical-four-file' "$TMP/out"
grep -q 'all six databases exist' "$TMP/out"
run_check "$current" >"$TMP/out"
grep -q 'current-five-file' "$TMP/out"
grep -q 'compose .* config --quiet' "$TMP/docker-calls"
run_restore "$historical" >"$TMP/out"
grep -q 'cycling_platform_reference remains empty for historical backup compatibility' "$TMP/out"
grep -q 'cycling_platform_stage exists (not restored)' "$TMP/out"
run_restore "$current" >"$TMP/out"
grep -q 'Restoring cycling_platform_reference' "$TMP/out"
grep -q 'Restore complete' "$TMP/out"
grep -q 'compose .* exec -T mariadb' "$TMP/docker-calls"
if run_check "$incomplete" >"$TMP/out" 2>"$TMP/err"; then
  echo 'malformed five-file set unexpectedly passed' >&2; exit 1
fi
grep -Eq 'must contain.*reference|Unexpected schema dump' "$TMP/err"

restore_script="$ROOT/scripts/restore_platform_database.sh"
grep -q "cycling_platform_admin cycling_platform_raw cycling_platform_reference cycling_platform_silver cycling_platform_gold" "$restore_script"

printf '%s\n' 'restore compatibility tests: passed'
