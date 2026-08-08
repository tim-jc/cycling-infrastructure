#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="C.UTF-8" LC_ALL="C.UTF-8"
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runtime_credentials_common.sh
source "$SCRIPT_DIR/runtime_credentials_common.sh"

AGE_BIN="${AGE_BIN:-age}"
SCP_BIN="${SCP_BIN:-scp}"
SSH_BIN="${SSH_BIN:-ssh}"
CIPHERTEXT=""
IDENTITY=""
METADATA=""
TARGET=""
EXPECTED_HOSTNAME=""
RUNTIME_PATH="/srv/cycling/config/platform/runtime.Renviron"
CONFIRM_REPLACE=false
TEMP_DIR=""
REMOTE_STAGING=""

usage() {
  cat <<'USAGE'
Usage: restore_runtime_credentials.sh --ciphertext FILE.age --identity FILE \
  --target user@host --expected-hostname HOST --confirm-replace [--metadata FILE]

Verifies recovery metadata and ciphertext, decrypts locally, transfers through an
owner-only staging file, then atomically replaces runtime.Renviron on the target.
USAGE
}

cleanup() {
  [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
  if [[ -n "$REMOTE_STAGING" && -n "$TARGET" ]]; then
    "$SSH_BIN" "$TARGET" rm -f -- "$REMOTE_STAGING" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

while (( $# )); do
  case "$1" in
    --ciphertext) [[ $# -ge 2 ]] || runtime_fail "--ciphertext requires a value."; CIPHERTEXT="$2"; shift 2 ;;
    --identity) [[ $# -ge 2 ]] || runtime_fail "--identity requires a value."; IDENTITY="$2"; shift 2 ;;
    --metadata) [[ $# -ge 2 ]] || runtime_fail "--metadata requires a value."; METADATA="$2"; shift 2 ;;
    --target) [[ $# -ge 2 ]] || runtime_fail "--target requires a value."; TARGET="$2"; shift 2 ;;
    --expected-hostname) [[ $# -ge 2 ]] || runtime_fail "--expected-hostname requires a value."; EXPECTED_HOSTNAME="$2"; shift 2 ;;
    --runtime-path) [[ $# -ge 2 ]] || runtime_fail "--runtime-path requires a value."; RUNTIME_PATH="$2"; shift 2 ;;
    --confirm-replace) CONFIRM_REPLACE=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; runtime_fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$CIPHERTEXT" && -n "$IDENTITY" && -n "$TARGET" && -n "$EXPECTED_HOSTNAME" ]] || runtime_fail "Ciphertext, identity, target, and expected hostname are required."
[[ "$CONFIRM_REPLACE" == true ]] || runtime_fail "Restore requires the explicit --confirm-replace safeguard."
runtime_validate_target "$TARGET"
runtime_validate_absolute_path "$RUNTIME_PATH"
[[ "$EXPECTED_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || runtime_fail "Expected hostname is invalid."
METADATA="${METADATA:-$CIPHERTEXT.metadata}"
runtime_require_command "$AGE_BIN"; runtime_require_command "$SCP_BIN"; runtime_require_command "$SSH_BIN"

"$SCRIPT_DIR/verify_runtime_credentials.sh" --ciphertext "$CIPHERTEXT" --identity "$IDENTITY" --metadata "$METADATA"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cycling-runtime-restore.XXXXXX")"
plaintext="$TEMP_DIR/runtime.Renviron"
"$AGE_BIN" --decrypt --identity "$IDENTITY" --output "$plaintext" "$CIPHERTEXT"
chmod 0600 "$plaintext"
runtime_validate_plaintext "$plaintext"

REMOTE_STAGING="/home/tim/.runtime.Renviron.recovery.$(date -u '+%Y%m%dT%H%M%SZ').$$"
"$SCP_BIN" -p "$plaintext" "$TARGET:$REMOTE_STAGING"
"$SSH_BIN" "$TARGET" bash -s -- "$EXPECTED_HOSTNAME" "$REMOTE_STAGING" "$RUNTIME_PATH" <<'REMOTE'
set -euo pipefail
expected_hostname="$1"; staging="$2"; runtime_path="$3"; parent="$(dirname "$runtime_path")"; candidate="$parent/.runtime-renviron-restore.$$"
cleanup() { rm -f -- "$candidate" "$staging"; }
trap cleanup EXIT
fail() { printf '[restore-runtime-credentials] ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(hostname -s)" == "$expected_hostname" ]] || fail "Target hostname assertion failed."
for lock in /tmp/cycling-platform-daily.lock /tmp/cycling-platform-validation.lock /tmp/cycling-platform-deployment.lock /tmp/cycling-platform-database-restore.lock; do
  [[ ! -d "$lock" ]] || fail "A managed platform operation appears active: $lock"
done
if command -v docker >/dev/null 2>&1; then
  running_platform="$(docker ps --filter label=com.docker.compose.service=cycling-platform --format '{{.ID}}' 2>/dev/null || true)"
  [[ -z "$running_platform" ]] || fail "A cycling-platform container is running; stop it before credential restore."
fi
[[ -d "$parent" && ! -L "$parent" && "$(stat -c '%U:%G' "$parent")" == 'tim:tim' && "$(stat -c '%a' "$parent")" == 700 ]] || fail "Target runtime directory is absent or not tim:tim mode 0700."
unexpected="$(find "$parent" -mindepth 1 -maxdepth 1 ! -name runtime.Renviron -print -quit)"
[[ -z "$unexpected" ]] || fail "Target runtime directory contains an unexpected entry."
[[ -f "$staging" && ! -L "$staging" && "$(stat -c '%U:%G' "$staging")" == 'tim:tim' ]] || fail "Transferred staging file is unsafe."
[[ ! -L "$runtime_path" && ( ! -e "$runtime_path" || -f "$runtime_path" ) ]] || fail "Target runtime credential path is unsafe."
for key in STRAVA_REFRESH_TOKEN GOOGLE_HEALTH_REFRESH_TOKEN; do
  awk -F= -v key="$key" '$1 == key { value=substr($0,index($0,"=")+1); if(length(value)>0) found=1 } END { exit(found?0:1) }' "$staging" || fail "Required runtime credential key is missing or empty: $key"
done
install -m 0600 "$staging" "$candidate"
[[ "$(stat -c '%U:%G' "$candidate")" == 'tim:tim' ]] || fail "Restore candidate ownership is not tim:tim."
mv -f -- "$candidate" "$runtime_path"
trap - EXIT
rm -f -- "$staging"
printf '[restore-runtime-credentials] Atomic credential replacement completed.\n'
REMOTE
REMOTE_STAGING=""

"$SCRIPT_DIR/verify_runtime_credentials.sh" --target "$TARGET" --expected-hostname "$EXPECTED_HOSTNAME" --runtime-path "$RUNTIME_PATH"
printf '[restore-runtime-credentials] Restore and post-restore verification completed.\n'
