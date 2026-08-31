#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" LANG="C.UTF-8" LC_ALL="C.UTF-8"
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/static_config_common.sh
source "$SCRIPT_DIR/static_config_common.sh"
OUTPUT_DIR="${ANALYTICS_OUTPUT_DIR:-/srv/cycling/data/analytics/output}"
CREDENTIAL_FILE="${CLOUDFLARE_CREDENTIAL_FILE:-/srv/cycling/config/analytics/cloudflare.env}"
EXPECTED_OWNER="${EXPECTED_CLOUDFLARE_CREDENTIAL_OWNER:-tim:tim}"
COMPOSE_WRAPPER="${COMPOSE_WRAPPER:-$SCRIPT_DIR/compose.sh}"
RENDER_LOCK_DIR="${RENDER_LOCK_DIR:-/tmp/cycling-analytics-render.lock}"
DEPLOY_LOCK_DIR="${DEPLOY_LOCK_DIR:-/tmp/cycling-analytics-deployment.lock}"
RESTORE_LOCK_DIR="${RESTORE_LOCK_DIR:-/tmp/cycling-platform-database-restore.lock}"
FROM_REFRESH=false; LOCK_ACQUIRED=false
usage(){ printf '%s\n' 'Usage: publish_analytics.sh [--from-refresh]' 'Publishes the complete production analytics artefact to Cloudflare Pages.'; }
fail(){ printf '[publish-analytics] ERROR: %s\n' "$*" >&2; exit 1; }
file_owner(){ stat -c '%U:%G' "$1" 2>/dev/null || stat -f '%Su:%Sg' "$1"; }
cleanup(){ local status=$?; [[ "$LOCK_ACQUIRED" != true ]] || rmdir "$RENDER_LOCK_DIR" 2>/dev/null || true; return "$status"; }
trap cleanup EXIT
while (($#)); do case "$1" in --from-refresh) FROM_REFRESH=true; shift;; --help|-h) usage; exit 0;; *) usage >&2; fail "Unknown argument: $1";; esac; done
for lock in "$DEPLOY_LOCK_DIR" "$RESTORE_LOCK_DIR"; do [[ ! -d "$lock" ]] || fail "Conflicting operation appears active: $lock"; done
if [[ "$FROM_REFRESH" == true ]]; then
  [[ -d "$RENDER_LOCK_DIR" ]] || fail '--from-refresh requires the parent analytics render lock.'
else
  mkdir "$RENDER_LOCK_DIR" 2>/dev/null || fail "Analytics refresh or publication appears active: $RENDER_LOCK_DIR"
  LOCK_ACQUIRED=true
fi
[[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || fail "Analytics output directory is absent or unsafe: $OUTPUT_DIR"
[[ -f "$OUTPUT_DIR/index.html" && ! -L "$OUTPUT_DIR/index.html" && -s "$OUTPUT_DIR/index.html" ]] || fail 'Analytics artefact requires a non-empty regular index.html.'
[[ -d "$OUTPUT_DIR/index_files" && ! -L "$OUTPUT_DIR/index_files" ]] || fail 'Analytics artefact requires a regular index_files directory.'
[[ -n "$(find "$OUTPUT_DIR/index_files" -mindepth 1 -type f -print -quit)" ]] || fail 'Analytics artefact index_files directory is empty.'
[[ -f "$CREDENTIAL_FILE" && ! -L "$CREDENTIAL_FILE" && -r "$CREDENTIAL_FILE" ]] || fail "Cloudflare credential file is absent, unreadable, or unsafe: $CREDENTIAL_FILE"
[[ "$(static_mode "$CREDENTIAL_FILE")" == 600 ]] || fail 'Cloudflare credential file must have mode 0600.'
[[ "$(file_owner "$CREDENTIAL_FILE")" == "$EXPECTED_OWNER" ]] || fail "Cloudflare credential file must be owned by $EXPECTED_OWNER."
STATIC_CONFIG_PROFILE=cloudflare static_validate_plaintext "$CREDENTIAL_FILE"
CLOUDFLARE_ACCOUNT_ID="$(static_value CLOUDFLARE_ACCOUNT_ID "$CREDENTIAL_FILE")"
CLOUDFLARE_API_TOKEN="$(static_value CLOUDFLARE_API_TOKEN "$CREDENTIAL_FILE")"
export CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN
[[ -x "$COMPOSE_WRAPPER" ]] || fail "Compose wrapper is missing or not executable: $COMPOSE_WRAPPER"
printf '[publish-analytics] Publishing complete analytics artefact to Cloudflare Pages project cycling-analytics.\n'
if "$COMPOSE_WRAPPER" run --rm --no-deps --env CLOUDFLARE_ACCOUNT_ID --env CLOUDFLARE_API_TOKEN cloudflare-pages-publisher; then
  printf '[publish-analytics] Cloudflare Pages publication succeeded: https://cycling-analytics-8bs.pages.dev\n'
else
  status=$?; fail "Cloudflare Pages Direct Upload failed with status $status; the local rendered artefact was retained."
fi
