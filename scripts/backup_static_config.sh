#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" LANG=C.UTF-8 LC_ALL=C.UTF-8
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/static_config_common.sh
source "$SCRIPT_DIR/static_config_common.sh"
AGE_BIN="${AGE_BIN:-age}"; RECIPIENT=""; IDENTITY=""; SOURCE=""; OUTPUT=""; TMP=""; PROFILE=compose
usage(){ printf '%s\n' 'Usage: backup_static_config.sh [--profile compose|cloudflare] --source FILE --recipient AGE_RECIPIENT --identity FILE --output FILE.age'; }
trap '[[ -z "$TMP" ]] || rm -rf -- "$TMP"' EXIT
while (( $# )); do case "$1" in --profile) PROFILE="${2:-}"; shift 2;; --source) SOURCE="${2:-}"; shift 2;; --recipient) RECIPIENT="${2:-}"; shift 2;; --identity) IDENTITY="${2:-}"; shift 2;; --output) OUTPUT="${2:-}"; shift 2;; -h|--help) usage; exit 0;; *) static_fail "Unknown argument: $1";; esac; done
[[ -n "$SOURCE" && -n "$RECIPIENT" && -n "$IDENTITY" && -n "$OUTPUT" ]] || static_fail 'Source, recipient, identity and output are required.'
export STATIC_CONFIG_PROFILE="$PROFILE"
static_safe_path "$(cd "$(dirname "$SOURCE")" && pwd -P)/$(basename "$SOURCE")"; static_safe_path "$OUTPUT"; [[ "$OUTPUT" == *.age ]] || static_fail 'Output must end in .age.'
[[ -f "$IDENTITY" && ! -L "$IDENTITY" && "$(static_mode "$IDENTITY")" == 600 ]] || static_fail 'age identity must be a regular mode-0600 file.'
static_require "$AGE_BIN"; static_validate_plaintext "$SOURCE"
outdir="$(dirname "$OUTPUT")"; [[ -d "$outdir" && -w "$outdir" ]] || static_fail 'Output directory is unavailable.'
[[ ! -L "$OUTPUT" && ! -L "$OUTPUT.metadata" ]] || static_fail 'Output paths must not be symlinks.'
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cycling-static-backup.XXXXXX")"; candidate="$outdir/.compose.env.age.$$"; metadata="$outdir/.compose.env.metadata.$$"
trap 'rm -rf -- "$TMP"; rm -f -- "$candidate" "$metadata"' EXIT
"$AGE_BIN" --recipient "$RECIPIENT" --output "$candidate" "$SOURCE"; chmod 600 "$candidate"; [[ -s "$candidate" ]] || static_fail 'age produced empty ciphertext.'
"$AGE_BIN" --decrypt --identity "$IDENTITY" --output "$TMP/verified.env" "$candidate"; chmod 600 "$TMP/verified.env"; static_validate_plaintext "$TMP/verified.env"; cmp -s "$SOURCE" "$TMP/verified.env" || static_fail 'Decrypted candidate differs from source.'
digest="$(static_sha256 "$candidate")"; completed="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'format=cycling-static-%s-age-v1\nbackup_completed_at_utc=%s\nciphertext_file=%s\nciphertext_sha256=%s\n' "$PROFILE" "$completed" "$(basename "$OUTPUT")" "$digest" >"$metadata"; chmod 600 "$metadata"
mv -f -- "$candidate" "$OUTPUT"; mv -f -- "$metadata" "$OUTPUT.metadata"; chmod 600 "$OUTPUT" "$OUTPUT.metadata"
printf '[backup-static-config] Verified encrypted backup created: %s\n[backup-static-config] SHA-256: %s\n' "$OUTPUT" "$digest"
