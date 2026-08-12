#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; TMP="$(mktemp -d)"; trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/backups" "$TMP/remote" "$TMP/recovery"
cat >"$TMP/static.env" <<'ENV'
MARIADB_USER=cycling
MARIADB_PASSWORD=maria-test-secret
MARIADB_ROOT_PASSWORD=root-test-secret
MARIADB_PORT=3306
STRAVA_CLIENT_ID=client-id
STRAVA_CLIENT_SECRET=strava-test-secret
GOOGLE_HEALTH_CLIENT_ID=google-id
GOOGLE_HEALTH_CLIENT_SECRET=google-test-secret
NTFY_TOPIC=topic-test-secret
NTFY_BASE_URL=https://ntfy.sh
ENV
chmod 600 "$TMP/static.env"; printf '%s\n' AGE-TEST-IDENTITY >"$TMP/identity"; chmod 600 "$TMP/identity"
cat >"$TMP/bin/age" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
out=""; in=""; while (( $# )); do case "$1" in --recipient|--identity) shift 2;; --decrypt) shift;; --output) out="$2"; shift 2;; *) in="$1"; shift;; esac; done; cp "$in" "$out"
MOCK
chmod 700 "$TMP/bin/age"
AGE_BIN="$TMP/bin/age" "$ROOT/scripts/backup_static_config.sh" --source "$TMP/static.env" --recipient age1test --identity "$TMP/identity" --output "$TMP/recovery/compose.env.age" >"$TMP/out"
AGE_BIN="$TMP/bin/age" "$ROOT/scripts/verify_static_config.sh" --ciphertext "$TMP/recovery/compose.env.age" --identity "$TMP/identity" >"$TMP/out"
if grep -Eq 'maria-test-secret|strava-test-secret|google-test-secret|topic-test-secret' "$TMP/out" "$TMP/recovery/compose.env.age.metadata"; then echo 'static secret leaked' >&2; exit 1; fi
cp "$TMP/static.env" "$TMP/bad.env"; printf '%s\n' 'STRAVA_REFRESH_TOKEN=forbidden' >>"$TMP/bad.env"; chmod 600 "$TMP/bad.env"
if "$ROOT/scripts/verify_static_config.sh" --plaintext "$TMP/bad.env" >"$TMP/out" 2>"$TMP/err"; then echo 'refresh token accepted in static config' >&2; exit 1; fi
grep -q 'Forbidden.*STRAVA_REFRESH_TOKEN' "$TMP/err"
grep -v '^STRAVA_CLIENT_SECRET=' "$TMP/static.env" >"$TMP/missing.env"; chmod 600 "$TMP/missing.env"
if "$ROOT/scripts/verify_static_config.sh" --plaintext "$TMP/missing.env" >"$TMP/out" 2>"$TMP/err"; then echo 'missing Strava client secret accepted' >&2; exit 1; fi
grep -q 'STRAVA_CLIENT_SECRET' "$TMP/err"

make_dump(){ printf '%s\n' '-- dump' | gzip >"$1"; }
prefix="$TMP/backups/2026-08-11_050001"; for db in admin raw reference silver gold; do make_dump "${prefix}_cycling_platform_${db}.sql.gz"; done
"$ROOT/scripts/prepare_recovery_backup.sh" --backup-root "$TMP/backups" --backup-set 2026-08-11_050001 --target tim@test --expected-hostname test --destination /home/tim/recovery --check-only >"$TMP/out"
grep -q 'current-five-file' "$TMP/out"; grep -q '/home/tim/recovery/2026-08-11_050001' "$TMP/out"
rm "${prefix}_cycling_platform_reference.sql.gz"; "$ROOT/scripts/prepare_recovery_backup.sh" --backup-root "$TMP/backups" --backup-set 2026-08-11_050001 --target tim@test --expected-hostname test --check-only >"$TMP/out"; grep -q 'historical-four-file' "$TMP/out"
rm "${prefix}_cycling_platform_gold.sql.gz"; if "$ROOT/scripts/prepare_recovery_backup.sh" --backup-root "$TMP/backups" --backup-set 2026-08-11_050001 --target tim@test --expected-hostname test --check-only >"$TMP/out" 2>"$TMP/err"; then echo 'partial set accepted' >&2; exit 1; fi

cat >"$TMP/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' recovery-test
MOCK
cat >"$TMP/bin/compose" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == 'ps -aq mariadb' ]] && printf '%s\n' stopped-id
MOCK
cat >"$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' exited
MOCK
cat >"$TMP/bin/pgrep" <<'MOCK'
#!/usr/bin/env bash
[[ "${ACTIVE_RESTORE:-}" == yes ]]
MOCK
cat >"$TMP/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
"$@"
MOCK
chmod 700 "$TMP/bin/"*
mkdir -p "$TMP/mariadb/mysql" "$TMP/lock"; touch "$TMP/mariadb/mysql/partial"
if ACTIVE_RESTORE=yes HOSTNAME_BIN="$TMP/bin/hostname" COMPOSE_WRAPPER="$TMP/bin/compose" DOCKER_BIN="$TMP/bin/docker" PGREP_BIN="$TMP/bin/pgrep" SUDO_BIN="$TMP/bin/sudo" MARIADB_DATA_DIR="$TMP/mariadb" CANONICAL_MARIADB_DATA_DIR="$TMP/mariadb" DATABASE_RESTORE_LOCK_DIR="$TMP/lock" "$ROOT/scripts/reset_recovery_database_target.sh" --expected-hostname recovery-test --confirm-quarantine-reset >"$TMP/out" 2>"$TMP/err"; then echo 'active restore reset accepted' >&2; exit 1; fi
HOSTNAME_BIN="$TMP/bin/hostname" COMPOSE_WRAPPER="$TMP/bin/compose" DOCKER_BIN="$TMP/bin/docker" PGREP_BIN="$TMP/bin/pgrep" SUDO_BIN="$TMP/bin/sudo" RECOVERY_TARGET_OWNER="$(id -un)" RECOVERY_TARGET_GROUP="$(id -gn)" MARIADB_DATA_DIR="$TMP/mariadb" CANONICAL_MARIADB_DATA_DIR="$TMP/mariadb" DATABASE_RESTORE_LOCK_DIR="$TMP/lock" "$ROOT/scripts/reset_recovery_database_target.sh" --expected-hostname recovery-test --confirm-quarantine-reset >"$TMP/out"
[[ -d "$TMP/mariadb" && ! -d "$TMP/lock" ]]; find "$TMP" -maxdepth 1 -type d -name 'mariadb.partial-*' | grep -q .
if HOSTNAME_BIN="$TMP/bin/hostname" "$ROOT/scripts/reset_recovery_database_target.sh" --expected-hostname cycling-prod --confirm-quarantine-reset >"$TMP/out" 2>"$TMP/err"; then echo 'production reset accepted' >&2; exit 1; fi

grep -q 'run_silver.R repair' "$ROOT/docs/bootstrap-runbook.md" || { echo 'catch-up repair command undocumented' >&2; exit 1; }
grep -q 'production scheduling remains disabled' "$ROOT/docs/bootstrap-runbook.md" || { echo 'isolated schedule rule undocumented' >&2; exit 1; }
printf '%s\n' 'recovery workflow tests: passed'
