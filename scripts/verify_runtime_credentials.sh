#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="C.UTF-8" LC_ALL="C.UTF-8"
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runtime_credentials_common.sh
source "$SCRIPT_DIR/runtime_credentials_common.sh"

AGE_BIN="${AGE_BIN:-age}"
SSH_BIN="${SSH_BIN:-ssh}"
MODE=""
CIPHERTEXT=""
IDENTITY=""
METADATA=""
TARGET=""
EXPECTED_HOSTNAME=""
RUNTIME_PATH="/srv/cycling/config/platform/runtime.Renviron"
TEMP_DIR=""

usage() {
  cat <<'USAGE'
Usage:
  verify_runtime_credentials.sh --ciphertext FILE --identity FILE [--metadata FILE]
  verify_runtime_credentials.sh --target user@host --expected-hostname HOST [--runtime-path PATH]

Verifies encrypted recovery material or the restored remote runtime file without
printing credential values.
USAGE
}

cleanup() { [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"; }
trap cleanup EXIT

while (( $# )); do
  case "$1" in
    --ciphertext) [[ $# -ge 2 ]] || runtime_fail "--ciphertext requires a value."; CIPHERTEXT="$2"; MODE="ciphertext"; shift 2 ;;
    --identity) [[ $# -ge 2 ]] || runtime_fail "--identity requires a value."; IDENTITY="$2"; shift 2 ;;
    --metadata) [[ $# -ge 2 ]] || runtime_fail "--metadata requires a value."; METADATA="$2"; shift 2 ;;
    --target) [[ $# -ge 2 ]] || runtime_fail "--target requires a value."; TARGET="$2"; MODE="target"; shift 2 ;;
    --expected-hostname) [[ $# -ge 2 ]] || runtime_fail "--expected-hostname requires a value."; EXPECTED_HOSTNAME="$2"; shift 2 ;;
    --runtime-path) [[ $# -ge 2 ]] || runtime_fail "--runtime-path requires a value."; RUNTIME_PATH="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; runtime_fail "Unknown argument: $1" ;;
  esac
done

if [[ "$MODE" == "ciphertext" ]]; then
  [[ -n "$CIPHERTEXT" && -n "$IDENTITY" && -z "$TARGET" ]] || runtime_fail "Ciphertext verification requires --ciphertext and --identity only."
  [[ -f "$CIPHERTEXT" && ! -L "$CIPHERTEXT" && -s "$CIPHERTEXT" ]] || runtime_fail "Ciphertext is absent, empty, or unsafe: $CIPHERTEXT"
  [[ "$(runtime_file_mode "$CIPHERTEXT")" == 600 ]] || runtime_fail "Ciphertext must have mode 0600."
  [[ -f "$IDENTITY" && ! -L "$IDENTITY" && -r "$IDENTITY" ]] || runtime_fail "age identity is absent or unsafe: $IDENTITY"
  [[ "$(runtime_file_mode "$IDENTITY")" == 600 ]] || runtime_fail "age identity must have mode 0600."
  METADATA="${METADATA:-$CIPHERTEXT.metadata}"
  expected_digest="$(runtime_read_metadata_digest "$METADATA")"
  actual_digest="$(runtime_sha256 "$CIPHERTEXT")"
  [[ "$actual_digest" == "$expected_digest" ]] || runtime_fail "Ciphertext SHA-256 does not match its metadata."
  runtime_require_command "$AGE_BIN"
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cycling-runtime-verify.XXXXXX")"
  plaintext="$TEMP_DIR/runtime.Renviron"
  "$AGE_BIN" --decrypt --identity "$IDENTITY" --output "$plaintext" "$CIPHERTEXT"
  chmod 0600 "$plaintext"
  runtime_validate_plaintext "$plaintext"
  printf '[verify-runtime-credentials] Ciphertext digest and decryption verified.\n'
  for key in "${runtime_required_keys[@]}"; do printf '[verify-runtime-credentials] %s: present\n' "$key"; done
elif [[ "$MODE" == "target" ]]; then
  [[ -n "$TARGET" && -n "$EXPECTED_HOSTNAME" && -z "$CIPHERTEXT" && -z "$IDENTITY" ]] || runtime_fail "Target verification requires --target and --expected-hostname only."
  runtime_validate_target "$TARGET"
  runtime_validate_absolute_path "$RUNTIME_PATH"
  [[ "$EXPECTED_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || runtime_fail "Expected hostname is invalid."
  runtime_require_command "$SSH_BIN"
  "$SSH_BIN" "$TARGET" bash -s -- "$EXPECTED_HOSTNAME" "$RUNTIME_PATH" <<'REMOTE'
set -euo pipefail
expected_hostname="$1"; runtime_path="$2"; parent="$(dirname "$runtime_path")"
fail() { printf '[verify-runtime-credentials] ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(hostname -s)" == "$expected_hostname" ]] || fail "Target hostname assertion failed."
[[ -d "$parent" && ! -L "$parent" ]] || fail "Runtime credential directory is absent or unsafe."
[[ "$(stat -c '%U:%G' "$parent")" == 'tim:tim' && "$(stat -c '%a' "$parent")" == 700 ]] || fail "Runtime credential directory must be tim:tim mode 0700."
unexpected="$(find "$parent" -mindepth 1 -maxdepth 1 ! -name runtime.Renviron -print -quit)"
[[ -z "$unexpected" ]] || fail "Runtime credential directory contains an unexpected entry."
[[ -f "$runtime_path" && ! -L "$runtime_path" && -s "$runtime_path" ]] || fail "Runtime credential file is absent, empty, or unsafe."
[[ "$(stat -c '%U:%G' "$runtime_path")" == 'tim:tim' && "$(stat -c '%a' "$runtime_path")" == 600 ]] || fail "Runtime credential file must be tim:tim mode 0600."
for key in STRAVA_REFRESH_TOKEN GOOGLE_HEALTH_REFRESH_TOKEN; do
  awk -F= -v key="$key" '$1 == key { value=substr($0,index($0,"=")+1); if(length(value)>0) found=1 } END { exit(found?0:1) }' "$runtime_path" || fail "Required runtime credential key is missing or empty: $key"
  printf '[verify-runtime-credentials] %s: present\n' "$key"
done
printf '[verify-runtime-credentials] Target metadata and credential presence verified.\n'
REMOTE
else
  usage >&2
  runtime_fail "Select exactly one verification mode."
fi
