#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" LANG=C.UTF-8 LC_ALL=C.UTF-8
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/static_config_common.sh
source "$SCRIPT_DIR/static_config_common.sh"
AGE_BIN="${AGE_BIN:-age}"; SCP_BIN="${SCP_BIN:-scp}"; SSH_BIN="${SSH_BIN:-ssh}"; CIPHER=""; IDENTITY=""; TARGET=""; HOST=""; DEST="/home/tim/cycling-infrastructure/compose/.env"; CONFIRM=false; TMP=""; STAGING=""
trap '[[ -z "$TMP" ]] || rm -rf -- "$TMP"; [[ -z "$STAGING" || -z "$TARGET" ]] || "$SSH_BIN" "$TARGET" rm -f -- "$STAGING" >/dev/null 2>&1 || true' EXIT
while (( $# )); do case "$1" in --ciphertext) CIPHER="${2:-}"; shift 2;; --identity) IDENTITY="${2:-}"; shift 2;; --target) TARGET="${2:-}"; shift 2;; --expected-hostname) HOST="${2:-}"; shift 2;; --destination) DEST="${2:-}"; shift 2;; --confirm-replace) CONFIRM=true; shift;; -h|--help) echo 'Usage: restore_static_config.sh --ciphertext FILE.age --identity FILE --target tim@host --expected-hostname HOST --confirm-replace'; exit 0;; *) static_fail "Unknown argument: $1";; esac; done
[[ -n "$CIPHER$IDENTITY$TARGET$HOST" && "$CONFIRM" == true ]] || static_fail 'Ciphertext, identity, target, expected hostname and --confirm-replace are required.'; static_target "$TARGET"; static_hostname "$HOST"; static_safe_path "$DEST"; static_require "$AGE_BIN"; static_require "$SCP_BIN"; static_require "$SSH_BIN"
"$SCRIPT_DIR/verify_static_config.sh" --ciphertext "$CIPHER" --identity "$IDENTITY"; TMP="$(mktemp -d "${TMPDIR:-/tmp}/cycling-static-restore.XXXXXX")"; "$AGE_BIN" --decrypt --identity "$IDENTITY" --output "$TMP/compose.env" "$CIPHER"; chmod 600 "$TMP/compose.env"; static_validate_plaintext "$TMP/compose.env"
STAGING="/home/tim/.compose.env.recovery.$$.tmp"; "$SCP_BIN" -p "$TMP/compose.env" "$TARGET:$STAGING"
"$SSH_BIN" "$TARGET" bash -s -- "$HOST" "$STAGING" "$DEST" <<'REMOTE'
set -euo pipefail
host="$1"; staging="$2"; dest="$3"; fail(){ printf '[restore-static-config] ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(hostname -s)" == "$host" ]] || fail 'Target hostname assertion failed.'
[[ -f "$staging" && ! -L "$staging" && "$(stat -c '%U:%G %a' "$staging")" == 'tim:tim 600' ]] || fail 'Transferred static configuration is unsafe.'
[[ -d "$(dirname "$dest")" && ! -L "$(dirname "$dest")" && ! -L "$dest" && ( ! -e "$dest" || -f "$dest" ) ]] || fail 'Destination is unsafe.'
install -m 0600 "$staging" "${dest}.candidate.$$"; mv -f -- "${dest}.candidate.$$" "$dest"; rm -f -- "$staging"
[[ "$(stat -c '%U:%G %a' "$dest")" == 'tim:tim 600' ]] || fail 'Restored static configuration metadata is incorrect.'
printf '[restore-static-config] Static Compose configuration atomically restored and metadata verified.\n'
REMOTE
STAGING=""; printf '[restore-static-config] Restore complete; run scripts/preflight.sh on the target.\n'
