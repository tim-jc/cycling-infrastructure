#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" LANG=C.UTF-8 LC_ALL=C.UTF-8
BACKUP_ROOT=""; SET=""; TARGET=""; HOST=""; DEST="/home/tim/recovery"; SCP_BIN="${SCP_BIN:-scp}"; SSH_BIN="${SSH_BIN:-ssh}"; MODE=transfer
fail(){ printf '[prepare-recovery-backup] ERROR: %s\n' "$*" >&2; exit 1; }
usage(){ echo 'Usage: prepare_recovery_backup.sh --backup-root DIR --backup-set YYYY-MM-DD_HHMMSS --target tim@host --expected-hostname HOST [--destination DIR] [--check-only | --verify-only]'; }
while (( $# )); do case "$1" in --backup-root) BACKUP_ROOT="${2:-}"; shift 2;; --backup-set) SET="${2:-}"; shift 2;; --target) TARGET="${2:-}"; shift 2;; --expected-hostname) HOST="${2:-}"; shift 2;; --destination) DEST="${2:-}"; shift 2;; --check-only) [[ "$MODE" == transfer ]] || fail 'Choose only one mode.'; MODE=check; shift;; --verify-only) [[ "$MODE" == transfer ]] || fail 'Choose only one mode.'; MODE=verify; shift;; -h|--help) usage; exit 0;; *) fail "Unknown argument: $1";; esac; done
[[ -d "$BACKUP_ROOT" && ! -L "$BACKUP_ROOT" ]] || fail 'Backup root is absent or unsafe.'; [[ "$SET" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]] || fail 'Backup set must be YYYY-MM-DD_HHMMSS.'
[[ "$TARGET" =~ ^tim@[A-Za-z0-9._:-]+$ ]] || fail 'Target must have the form tim@host.'; [[ "$HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || fail 'Expected hostname is invalid.'; [[ "$DEST" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail 'Destination must be a safe absolute path.'
files=("$BACKUP_ROOT/${SET}_cycling_platform_admin.sql.gz" "$BACKUP_ROOT/${SET}_cycling_platform_raw.sql.gz")
reference="$BACKUP_ROOT/${SET}_cycling_platform_reference.sql.gz"; [[ ! -e "$reference" || ( -f "$reference" && ! -L "$reference" ) ]] || fail 'Reference backup is unsafe.'; [[ ! -e "$reference" ]] || files+=("$reference")
files+=("$BACKUP_ROOT/${SET}_cycling_platform_silver.sql.gz" "$BACKUP_ROOT/${SET}_cycling_platform_gold.sql.gz")
shopt -s nullglob; candidates=("$BACKUP_ROOT/${SET}"_cycling_platform_*.sql.gz); shopt -u nullglob
[[ "${#candidates[@]}" == 4 || "${#candidates[@]}" == 5 ]] || fail "Selected prefix has ${#candidates[@]} files; expected a complete historical four-file or current five-file set."
for file in "${files[@]}"; do [[ -f "$file" && ! -L "$file" && -s "$file" ]] || fail "Required backup file is absent, empty, or unsafe: $file"; gzip -t "$file" || fail "gzip verification failed: $file"; done
for file in "${candidates[@]}"; do found=false; for expected in "${files[@]}"; do [[ "$file" != "$expected" ]] || found=true; done; [[ "$found" == true ]] || fail "Unexpected or mixed schema file: $file"; done
format=historical-four-file; [[ "${#files[@]}" == 5 ]] && format=current-five-file
printf '[prepare-recovery-backup] Validated %s set %s (%s files).\n' "$format" "$SET" "${#files[@]}"
[[ "$MODE" != check ]] || { printf '[prepare-recovery-backup] Restore prefix after transfer: %s/%s\n' "$DEST" "$SET"; exit 0; }
command -v "$SSH_BIN" >/dev/null 2>&1 || fail 'ssh is unavailable.'
if [[ "$MODE" == transfer ]]; then
  command -v "$SCP_BIN" >/dev/null 2>&1 || fail 'scp is unavailable.'
  if ! "$SSH_BIN" "$TARGET" bash -s -- "$HOST" "$DEST" <<'REMOTE'
set -euo pipefail
[[ "$(hostname -s)" == "$1" ]] || { echo '[prepare-recovery-backup] ERROR: target hostname assertion failed.' >&2; exit 1; }
install -d -m 0700 "$2"; [[ "$(stat -c '%U:%G %a' "$2")" == 'tim:tim 700' ]] || exit 1
REMOTE
  then fail 'Target preparation failed before transfer; no transfer was attempted.'; fi
  if ! "$SCP_BIN" -p "${files[@]}" "$TARGET:$DEST/"; then fail 'Backup transfer failed; rerunning the command is safe.'; fi
  printf '[prepare-recovery-backup] Transfer completed; starting independent remote verification.\n'
else
  printf '[prepare-recovery-backup] Transfer skipped; verifying the existing remote files.\n'
fi
remote_names=(); for file in "${files[@]}"; do remote_names+=("$(basename "$file")"); done
if ! "$SSH_BIN" "$TARGET" bash -s -- "$HOST" "$DEST" "${remote_names[@]}" <<'REMOTE'
set -euo pipefail
host="$1"; dest="$2"; shift 2; [[ "$(hostname -s)" == "$host" ]] || exit 1
for name in "$@"; do file="$dest/$name"; [[ -f "$file" && ! -L "$file" && -s "$file" ]] || exit 1; gzip -t "$file"; done
REMOTE
then fail 'Post-transfer verification failed or SSH was lost. Files may already be complete; rerun with --verify-only to avoid retransferring them.'; fi
printf '[prepare-recovery-backup] Remote completeness and gzip verification passed.\n[prepare-recovery-backup] Restore prefix: %s/%s\n' "$DEST" "$SET"
