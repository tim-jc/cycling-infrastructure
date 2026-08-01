#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

PLATFORM_DIR="/home/tim/cycling-platform"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF="origin/main"
EVIDENCE_FILE=""

usage() {
  cat <<'USAGE'
Usage: deploy_platform.sh [--ref BRANCH_TAG_OR_COMMIT] [--evidence-file FILE]

Fetches origin, resolves the selected revision, checks it out detached, records
its commit SHA, validates Compose, and rebuilds without running ETL. With no
--ref, the freshly fetched origin/main is deployed. Use an exact recorded SHA
for deterministic recovery, rehearsal, or rollback.
USAGE
}
fail() { printf '[deploy-platform] ERROR: %s\n' "$*" >&2; exit 1; }

while (( $# )); do
  case "$1" in
    --ref) [[ $# -ge 2 ]] || fail '--ref requires a value.'; REF="$2"; shift 2 ;;
    --evidence-file) [[ $# -ge 2 ]] || fail '--evidence-file requires a value.'; EVIDENCE_FILE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done
[[ -d "$PLATFORM_DIR/.git" ]] || fail "Platform repository is absent: $PLATFORM_DIR"
[[ -z "$(git -C "$PLATFORM_DIR" status --porcelain)" ]] || fail 'Platform working tree is dirty; preserve or resolve changes before recovery deployment.'

origin_url="$(git -C "$PLATFORM_DIR" remote get-url origin)"
[[ -n "$origin_url" ]] || fail 'Platform origin remote is missing.'
printf '[deploy-platform] Origin: %s\n' "$origin_url"
git -C "$PLATFORM_DIR" fetch --prune --tags origin
printf '[deploy-platform] Selected revision: %s
' "$REF"
commit="$(git -C "$PLATFORM_DIR" rev-parse --verify "$REF^{commit}")" || fail "Cannot resolve intended revision: $REF"
git -C "$PLATFORM_DIR" checkout --detach "$commit"
actual="$(git -C "$PLATFORM_DIR" rev-parse HEAD)"
[[ "$actual" == "$commit" ]] || fail 'Checked-out revision does not match resolved commit.'
printf '[deploy-platform] Platform commit: %s\n' "$actual"

"$SCRIPT_DIR/preflight.sh"
"$SCRIPT_DIR/compose.sh" config --quiet
"$SCRIPT_DIR/compose.sh" build cycling-platform
image_ref="$(
  "$SCRIPT_DIR/compose.sh" config --images \
    | awk '/^cycling-platform:/ { print; exit }'
)"
[[ -n "$image_ref" ]] || fail 'Configured cycling-platform image reference could not be determined.'
image_id="$(docker image inspect --format '{{.Id}}' "$image_ref" 2>/dev/null || true)"
[[ -n "$image_id" ]] || fail 'Built image identity could not be determined.'
printf '[deploy-platform] Image reference: %s\n' "$image_ref"
printf '[deploy-platform] Image ID: %s\n' "$image_id"

if [[ -n "$EVIDENCE_FILE" ]]; then
  { printf 'cycling_platform_commit: %s\n' "$actual"; printf 'cycling_platform_image_id: %s\n' "$image_id"; } >>"$EVIDENCE_FILE"
  printf '[deploy-platform] Appended deployment identity to %s\n' "$EVIDENCE_FILE"
fi
printf '%s\n' '[deploy-platform] Deployment build complete; no ETL was run.'
