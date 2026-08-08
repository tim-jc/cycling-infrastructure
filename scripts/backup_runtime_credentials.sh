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
SOURCE="tim@cycling-prod.local"
SOURCE_PATH="/srv/cycling/config/platform/runtime.Renviron"
EXPECTED_HOSTNAME="cycling-prod"
RECIPIENT=""
IDENTITY=""
OUTPUT=""
TEMP_DIR=""
OUTPUT_TEMP=""
METADATA_TEMP=""

usage() {
  cat <<'USAGE'
Usage: backup_runtime_credentials.sh --recipient AGE_RECIPIENT --identity FILE \
  --output FILE.age [--source user@host] [--expected-hostname HOST] [--source-path PATH]

Pulls runtime.Renviron, encrypts it with age, decrypts and compares the candidate,
then atomically publishes ciphertext plus non-secret recovery metadata.
USAGE
}

cleanup() {
  [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
  [[ -z "$OUTPUT_TEMP" ]] || rm -f -- "$OUTPUT_TEMP"
  [[ -z "$METADATA_TEMP" ]] || rm -f -- "$METADATA_TEMP"
}
trap cleanup EXIT

while (( $# )); do
  case "$1" in
    --recipient) [[ $# -ge 2 ]] || runtime_fail "--recipient requires a value."; RECIPIENT="$2"; shift 2 ;;
    --identity) [[ $# -ge 2 ]] || runtime_fail "--identity requires a value."; IDENTITY="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || runtime_fail "--output requires a value."; OUTPUT="$2"; shift 2 ;;
    --source) [[ $# -ge 2 ]] || runtime_fail "--source requires a value."; SOURCE="$2"; shift 2 ;;
    --expected-hostname) [[ $# -ge 2 ]] || runtime_fail "--expected-hostname requires a value."; EXPECTED_HOSTNAME="$2"; shift 2 ;;
    --source-path) [[ $# -ge 2 ]] || runtime_fail "--source-path requires a value."; SOURCE_PATH="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; runtime_fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$RECIPIENT" && -n "$IDENTITY" && -n "$OUTPUT" ]] || runtime_fail "--recipient, --identity, and --output are required."
runtime_validate_target "$SOURCE"
runtime_validate_absolute_path "$SOURCE_PATH"
[[ "$EXPECTED_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || runtime_fail "Expected hostname is invalid."
runtime_validate_absolute_path "$OUTPUT"
[[ "$OUTPUT" == *.age ]] || runtime_fail "--output must use the .age suffix."
[[ ! -L "$OUTPUT" && ! -L "$OUTPUT.metadata" ]] || runtime_fail "Output paths must not be symbolic links."
[[ ! -e "$OUTPUT" || -f "$OUTPUT" ]] || runtime_fail "Ciphertext output exists but is not a regular file."
[[ ! -e "$OUTPUT.metadata" || -f "$OUTPUT.metadata" ]] || runtime_fail "Metadata output exists but is not a regular file."
output_directory="$(dirname "$OUTPUT")"
[[ -d "$output_directory" && -w "$output_directory" ]] || runtime_fail "Output directory is absent or not writable: $output_directory"
[[ -f "$IDENTITY" && ! -L "$IDENTITY" && -r "$IDENTITY" ]] || runtime_fail "age identity is absent or unsafe: $IDENTITY"
[[ "$(runtime_file_mode "$IDENTITY")" == 600 ]] || runtime_fail "age identity must have mode 0600."
runtime_require_command "$AGE_BIN"
runtime_require_command "$SCP_BIN"
runtime_require_command "$SSH_BIN"

"$SCRIPT_DIR/verify_runtime_credentials.sh" --target "$SOURCE" \
  --expected-hostname "$EXPECTED_HOSTNAME" --runtime-path "$SOURCE_PATH"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cycling-runtime-backup.XXXXXX")"
plaintext="$TEMP_DIR/runtime.Renviron"
verified_plaintext="$TEMP_DIR/runtime.Renviron.verified"
"$SCP_BIN" "$SOURCE:$SOURCE_PATH" "$plaintext"
chmod 0600 "$plaintext"
runtime_validate_plaintext "$plaintext"

OUTPUT_TEMP="$(mktemp "$output_directory/.runtime.Renviron.age.XXXXXX")"
rm -f -- "$OUTPUT_TEMP"
"$AGE_BIN" --recipient "$RECIPIENT" --output "$OUTPUT_TEMP" "$plaintext"
chmod 0600 "$OUTPUT_TEMP"
[[ -s "$OUTPUT_TEMP" ]] || runtime_fail "age produced an empty ciphertext candidate."
"$AGE_BIN" --decrypt --identity "$IDENTITY" --output "$verified_plaintext" "$OUTPUT_TEMP"
chmod 0600 "$verified_plaintext"
runtime_validate_plaintext "$verified_plaintext"
cmp -s "$plaintext" "$verified_plaintext" || runtime_fail "Decrypted candidate does not match the pulled runtime credential file."

digest="$(runtime_sha256 "$OUTPUT_TEMP")"
completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
METADATA_TEMP="$(mktemp "$output_directory/.runtime.Renviron.metadata.XXXXXX")"
chmod 0600 "$METADATA_TEMP"
{
  printf 'format=cycling-runtime-credentials-age-v1\n'
  printf 'backup_completed_at_utc=%s\n' "$completed_at"
  printf 'source=%s\n' "$SOURCE"
  printf 'source_path=%s\n' "$SOURCE_PATH"
  printf 'ciphertext_file=%s\n' "$(basename "$OUTPUT")"
  printf 'ciphertext_sha256=%s\n' "$digest"
} >"$METADATA_TEMP"

mv -f -- "$OUTPUT_TEMP" "$OUTPUT"
OUTPUT_TEMP=""
mv -f -- "$METADATA_TEMP" "$OUTPUT.metadata"
METADATA_TEMP=""
chmod 0600 "$OUTPUT" "$OUTPUT.metadata"

printf '[backup-runtime-credentials] Backup completed and cryptographically verified.\n'
printf '[backup-runtime-credentials] Source: %s\n' "$SOURCE"
printf '[backup-runtime-credentials] Completed: %s\n' "$completed_at"
printf '[backup-runtime-credentials] Ciphertext: %s\n' "$OUTPUT"
printf '[backup-runtime-credentials] SHA-256: %s\n' "$digest"
