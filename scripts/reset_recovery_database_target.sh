#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" LANG=C.UTF-8 LC_ALL=C.UTF-8
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_WRAPPER="${COMPOSE_WRAPPER:-$SCRIPT_DIR/compose.sh}"; DOCKER_BIN="${DOCKER_BIN:-docker}"; PGREP_BIN="${PGREP_BIN:-pgrep}"; SUDO_BIN="${SUDO_BIN:-sudo}"
DATA_DIR="${MARIADB_DATA_DIR:-/srv/cycling/data/mariadb}"; CANONICAL_DATA_DIR="${CANONICAL_MARIADB_DATA_DIR:-/srv/cycling/data/mariadb}"; LOCK_DIR="${DATABASE_RESTORE_LOCK_DIR:-/tmp/cycling-platform-database-restore.lock}"; HOSTNAME_BIN="${HOSTNAME_BIN:-hostname}"; HOST=""; CONFIRM=false
TARGET_OWNER="${RECOVERY_TARGET_OWNER:-tim}"; TARGET_GROUP="${RECOVERY_TARGET_GROUP:-tim}"
fail(){ printf '[reset-recovery-target] ERROR: %s\n' "$*" >&2; exit 1; }
metadata(){ stat -c '%U:%G %a' "$1" 2>/dev/null || stat -f '%Su:%Sg %Lp' "$1"; }
usage(){ echo 'Usage: reset_recovery_database_target.sh --expected-hostname NON_PRODUCTION_HOST --confirm-quarantine-reset'; }
while (( $# )); do case "$1" in --expected-hostname) HOST="${2:-}"; shift 2;; --confirm-quarantine-reset) CONFIRM=true; shift;; -h|--help) usage; exit 0;; *) fail "Unknown argument: $1";; esac; done
[[ "$HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || fail 'Expected hostname is invalid.'; [[ "$HOST" != cycling-prod ]] || fail 'This helper refuses the production hostname cycling-prod.'; [[ "$CONFIRM" == true ]] || fail 'Explicit --confirm-quarantine-reset is required.'
actual="$($HOSTNAME_BIN -s)"; [[ "$actual" == "$HOST" ]] || fail "Hostname assertion failed: expected $HOST, detected $actual."
[[ "$DATA_DIR" == "$CANONICAL_DATA_DIR" && ! -L "$DATA_DIR" ]] || fail 'MariaDB data directory is not the canonical safe path.'
command -v "$DOCKER_BIN" >/dev/null 2>&1 || fail 'Docker is unavailable.'; command -v "$PGREP_BIN" >/dev/null 2>&1 || fail 'pgrep is unavailable.'; command -v "$SUDO_BIN" >/dev/null 2>&1 || fail 'sudo is unavailable.'
container_id="$($COMPOSE_WRAPPER ps -aq mariadb)"; if [[ -n "$container_id" ]]; then state="$($DOCKER_BIN inspect --format '{{.State.Status}}' "$container_id")"; [[ "$state" != running && "$state" != restarting ]] || fail "MariaDB must be stopped; current state is $state."; fi
if "$PGREP_BIN" -f '[r]estore_platform_database[.]sh' >/dev/null 2>&1; then fail 'A database restore process is still running; do not reset or remove its lock.'; fi
[[ -d "$DATA_DIR" ]] || fail 'MariaDB data directory does not exist.'
stamp="$(date -u '+%Y%m%dT%H%M%SZ')"; quarantine="${DATA_DIR}.partial-${stamp}"
[[ ! -e "$quarantine" ]] || fail "Quarantine path already exists: $quarantine"
"$SUDO_BIN" mv -- "$DATA_DIR" "$quarantine"
"$SUDO_BIN" install -d -o "$TARGET_OWNER" -g "$TARGET_GROUP" -m 0750 "$DATA_DIR"
[[ "$(metadata "$DATA_DIR")" == "$TARGET_OWNER:$TARGET_GROUP 750" ]] || fail 'Fresh MariaDB directory metadata verification failed.'
if [[ -d "$LOCK_DIR" ]]; then rmdir "$LOCK_DIR" || fail 'Restore lock is not an empty managed lock directory; inspect it manually.'; fi
printf '[reset-recovery-target] Partial target quarantined: %s\n' "$quarantine"
printf '[reset-recovery-target] Fresh target ready: %s (tim:tim 0750)\n' "$DATA_DIR"
printf '[reset-recovery-target] Next: start MariaDB, then rerun restore --check-only.\n'
