#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" LANG=C.UTF-8 LC_ALL=C.UTF-8
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/static_config_common.sh
source "$SCRIPT_DIR/static_config_common.sh"
AGE_BIN="${AGE_BIN:-age}"; CIPHER=""; IDENTITY=""; METADATA=""; PLAINTEXT=""; TMP=""; PROFILE=compose
trap '[[ -z "$TMP" ]] || rm -rf -- "$TMP"' EXIT
while (( $# )); do case "$1" in --profile) PROFILE="${2:-}"; shift 2;; --ciphertext) CIPHER="${2:-}"; shift 2;; --identity) IDENTITY="${2:-}"; shift 2;; --metadata) METADATA="${2:-}"; shift 2;; --plaintext) PLAINTEXT="${2:-}"; shift 2;; -h|--help) echo 'Usage: verify_static_config.sh [--profile compose|cloudflare] (--plaintext FILE | --ciphertext FILE.age --identity FILE [--metadata FILE])'; exit 0;; *) static_fail "Unknown argument: $1";; esac; done
export STATIC_CONFIG_PROFILE="$PROFILE"
if [[ -n "$PLAINTEXT" ]]; then [[ -z "$CIPHER$IDENTITY" ]] || static_fail 'Choose one verification mode.'; static_validate_plaintext "$PLAINTEXT"; printf '[verify-static-config] Required static keys and exclusions verified.\n'; exit 0; fi
[[ -n "$CIPHER" && -n "$IDENTITY" ]] || static_fail 'Ciphertext and identity are required.'; METADATA="${METADATA:-$CIPHER.metadata}"
[[ -f "$CIPHER" && ! -L "$CIPHER" && -s "$CIPHER" && "$(static_mode "$CIPHER")" == 600 ]] || static_fail 'Ciphertext is absent, unsafe, empty, or not mode 0600.'
[[ -f "$IDENTITY" && ! -L "$IDENTITY" && "$(static_mode "$IDENTITY")" == 600 ]] || static_fail 'age identity is absent, unsafe, or not mode 0600.'
expected="$(static_metadata_digest "$METADATA")"; actual="$(static_sha256 "$CIPHER")"; [[ "$actual" == "$expected" ]] || static_fail 'Ciphertext digest does not match metadata.'
static_require "$AGE_BIN"; TMP="$(mktemp -d "${TMPDIR:-/tmp}/cycling-static-verify.XXXXXX")"; "$AGE_BIN" --decrypt --identity "$IDENTITY" --output "$TMP/compose.env" "$CIPHER"; chmod 600 "$TMP/compose.env"; static_validate_plaintext "$TMP/compose.env"
printf '[verify-static-config] Ciphertext digest, decryption, required keys and exclusions verified.\n'
