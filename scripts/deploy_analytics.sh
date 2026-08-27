#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" LANG=C.UTF-8 LC_ALL=C.UTF-8
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRASTRUCTURE_DIR="${INFRASTRUCTURE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ANALYTICS_DIR="${ANALYTICS_DIR:-/home/tim/cycling-analytics}"
COMPOSE_WRAPPER="${COMPOSE_WRAPPER:-$SCRIPT_DIR/compose.sh}"; DOCKER_BIN="${DOCKER_BIN:-docker}"; GIT_BIN="${GIT_BIN:-git}"; HOSTNAME_BIN="${HOSTNAME_BIN:-hostname}"
DEPLOY_LOG="${DEPLOY_LOG:-$INFRASTRUCTURE_DIR/logs/analytics_deployment.log}"
DEPLOY_LOCK_DIR="${DEPLOY_LOCK_DIR:-/tmp/cycling-analytics-deployment.lock}"; RENDER_LOCK_DIR="${RENDER_LOCK_DIR:-/tmp/cycling-analytics-render.lock}"; RESTORE_LOCK_DIR="${RESTORE_LOCK_DIR:-/tmp/cycling-platform-database-restore.lock}"
ANALYTICS_ENV_FILE="${ANALYTICS_ENV_FILE:-/srv/cycling/config/analytics/runtime.Renviron}"; ANALYTICS_OUTPUT_DIR="${ANALYTICS_OUTPUT_DIR:-/srv/cycling/data/analytics/output}"; EXPECTED_RUNTIME_OWNER="${EXPECTED_RUNTIME_OWNER:-tim:tim}"
EXPECTED_ANALYTICS_ORIGIN="${EXPECTED_ANALYTICS_ORIGIN:-https://github.com/tim-jc/cycling-analytics.git}"
REF=origin/main; EVIDENCE_FILE=""; CURRENT_STAGE="argument parsing"; LOCK_ACQUIRED=false; START_TIME="$(date '+%Y-%m-%dT%H:%M:%S%z')"
usage(){ cat <<'USAGE'
Usage: deploy_analytics.sh [--ref BRANCH_TAG_OR_COMMIT] [--evidence-file FILE]

Normal deployment fetches and deploys origin/main. An explicit --ref selects a
specific revision. Success builds and identifies the smoke-tested image and
quietly validates Compose. It never renders, publishes, or changes schedules.
USAGE
}
log(){ printf '[deploy-analytics] %s\n' "$*"; printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$CURRENT_STAGE" "$*" >>"$DEPLOY_LOG"; }
fail(){ printf '[deploy-analytics] ERROR [%s]: %s\n' "$CURRENT_STAGE" "$*" >&2; exit 1; }
cleanup(){ local status=$?; [[ "$LOCK_ACQUIRED" != true ]] || rmdir "$DEPLOY_LOCK_DIR" 2>/dev/null || true; if ((status)); then printf '%s [%s] deployment_status=failed\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$CURRENT_STAGE" >>"$DEPLOY_LOG" 2>/dev/null || true; printf '[deploy-analytics] Deployment incomplete. Resolve the %s failure and rerun; no render or schedule change was attempted.\n' "$CURRENT_STAGE" >&2; fi; return "$status"; }
trap cleanup EXIT
file_mode(){ stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
file_owner(){ stat -c '%U:%G' "$1" 2>/dev/null || stat -f '%Su:%Sg' "$1"; }
normalize_github_origin(){ local origin="$1" repository; case "$origin" in https://github.com/*) repository="${origin#https://github.com/}";; git@github.com:*) repository="${origin#git@github.com:}";; *) printf '%s\n' "$origin"; return;; esac; repository="${repository%.git}"; printf 'github.com/%s\n' "$repository"; }
env_key_count(){ grep -Ec "^[[:space:]]*$1=" "$ANALYTICS_ENV_FILE" || true; }
env_key_has_value(){ awk -F= -v key="$1" '$1==key {v=substr($0,index($0,"=")+1); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); if ((substr(v,1,1)=="\"" && substr(v,length(v),1)=="\"") || (substr(v,1,1)=="\047" && substr(v,length(v),1)=="\047")) v=substr(v,2,length(v)-2); if(length(v)) found=1} END{exit(found?0:1)}' "$ANALYTICS_ENV_FILE"; }
write_evidence(){ local destination="$1" finish="$2"; { printf 'deployment_started_at: %s\n' "$START_TIME"; printf 'deployment_finished_at: %s\n' "$finish"; printf 'deployment_host: %s\n' "$deployment_host"; printf 'infrastructure_commit: %s\n' "$infrastructure_commit"; printf 'requested_ref: %s\n' "$REF"; printf 'cycling_analytics_commit: %s\n' "$actual_commit"; printf 'cycling_analytics_image_ref: %s\n' "$image_ref"; printf 'cycling_analytics_image_id: %s\n' "$image_id"; printf '%s\n' 'runtime_config_structure: passed' 'output_directory_structure: passed' 'image_build_result: passed' 'image_smoke_test_result: passed' 'compose_validation_result: passed' 'production_render_result: not-run' 'deployment_status: ready'; } >>"$destination"; }
while (($#)); do case "$1" in --ref) [[ $# -ge 2 && -n "$2" ]] || fail '--ref requires a non-empty value.'; REF="$2"; shift 2;; --evidence-file) [[ $# -ge 2 && -n "$2" ]] || fail '--evidence-file requires a non-empty value.'; EVIDENCE_FILE="$2"; shift 2;; -h|--help) usage; exit 0;; *) usage >&2; fail "Unknown argument: $1";; esac; done
mkdir -p "$(dirname "$DEPLOY_LOG")"; : >>"$DEPLOY_LOG"
CURRENT_STAGE="concurrency preflight"
mkdir "$DEPLOY_LOCK_DIR" 2>/dev/null || fail "Another analytics deployment appears active: $DEPLOY_LOCK_DIR"; LOCK_ACQUIRED=true
for lock in "$RENDER_LOCK_DIR" "$RESTORE_LOCK_DIR"; do [[ ! -d "$lock" ]] || fail "Conflicting operation appears active: $lock"; done
CURRENT_STAGE=preflight
deployment_host="$($HOSTNAME_BIN -s)"; [[ -n "$deployment_host" ]] || fail 'Could not determine the physical host short name.'; log "Deployment started at $START_TIME on host $deployment_host."
for command in "$GIT_BIN" "$DOCKER_BIN"; do command -v "$command" >/dev/null || fail "Required command is unavailable: $command"; done
[[ -x "$COMPOSE_WRAPPER" ]] || fail "Compose wrapper is missing or not executable: $COMPOSE_WRAPPER"
[[ -d "$INFRASTRUCTURE_DIR/.git" && -d "$ANALYTICS_DIR/.git" ]] || fail 'Required infrastructure or analytics repository is absent.'
[[ -z "$("$GIT_BIN" -C "$INFRASTRUCTURE_DIR" status --porcelain)" ]] || fail 'Infrastructure working tree is dirty; commit, preserve, or resolve changes before deployment.'
[[ -z "$("$GIT_BIN" -C "$ANALYTICS_DIR" status --porcelain)" ]] || fail 'Analytics working tree is dirty; commit, preserve, or resolve changes before deployment.'
"$DOCKER_BIN" info >/dev/null 2>&1 || fail 'Docker daemon is unavailable to the current user.'
[[ -f "$ANALYTICS_ENV_FILE" && ! -L "$ANALYTICS_ENV_FILE" && -r "$ANALYTICS_ENV_FILE" ]] || fail "Analytics runtime env file is absent, unreadable, or unsafe: $ANALYTICS_ENV_FILE"
[[ "$(file_mode "$ANALYTICS_ENV_FILE")" == 600 && "$(file_owner "$ANALYTICS_ENV_FILE")" == "$EXPECTED_RUNTIME_OWNER" ]] || fail "$ANALYTICS_ENV_FILE must be owned by $EXPECTED_RUNTIME_OWNER with mode 0600."
for key in MARIADB_NAME MARIADB_USER MARIADB_PASSWORD CARTO_BASEMAP_API_KEY; do [[ "$(env_key_count "$key")" == 1 ]] || fail "$key must occur exactly once in the analytics runtime env file."; env_key_has_value "$key" || fail "$key is empty in the analytics runtime env file."; done
for key in MARIADB_HOST MARIADB_PORT; do [[ "$(env_key_count "$key")" == 0 ]] || fail "$key is Compose-owned and must be removed from the analytics runtime env file."; done
[[ -d "$ANALYTICS_OUTPUT_DIR" && ! -L "$ANALYTICS_OUTPUT_DIR" && -w "$ANALYTICS_OUTPUT_DIR" ]] || fail "Analytics output directory is absent, unsafe, or not writable: $ANALYTICS_OUTPUT_DIR"
[[ "$(file_owner "$ANALYTICS_OUTPUT_DIR")" == "$EXPECTED_RUNTIME_OWNER" ]] || fail "$ANALYTICS_OUTPUT_DIR must be owned by $EXPECTED_RUNTIME_OWNER."
export CYCLING_ANALYTICS_ENV_FILE="$ANALYTICS_ENV_FILE"
infrastructure_commit="$("$GIT_BIN" -C "$INFRASTRUCTURE_DIR" rev-parse HEAD)"; origin_url="$("$GIT_BIN" -C "$ANALYTICS_DIR" remote get-url origin)"
[[ -n "$origin_url" ]] || fail 'Analytics origin remote is missing.'
[[ "$(normalize_github_origin "$origin_url")" == "$(normalize_github_origin "$EXPECTED_ANALYTICS_ORIGIN")" ]] || fail "Analytics origin is unexpected: $origin_url"
log "Infrastructure commit: $infrastructure_commit"; log "Analytics origin: $origin_url"; log 'Runtime configuration and output directory structure passed.'
CURRENT_STAGE="revision selection"
"$GIT_BIN" -C "$ANALYTICS_DIR" fetch origin --prune --tags; log "Selected revision: $REF"
analytics_commit="$("$GIT_BIN" -C "$ANALYTICS_DIR" rev-parse --verify "$REF^{commit}")" || fail "Cannot resolve intended revision: $REF"
"$GIT_BIN" -C "$ANALYTICS_DIR" checkout --detach "$analytics_commit"; actual_commit="$("$GIT_BIN" -C "$ANALYTICS_DIR" rev-parse HEAD)"; [[ "$actual_commit" == "$analytics_commit" ]] || fail 'Checked-out revision does not match resolved commit.'; log "Analytics commit: $actual_commit"
CURRENT_STAGE="image contract"
[[ -f "$ANALYTICS_DIR/Dockerfile" && -f "$ANALYTICS_DIR/tests/smoke_check.R" ]] || fail 'Selected analytics revision lacks the Dockerfile smoke-test contract.'
grep -Eq '^[[:space:]]*RUN[[:space:]]+Rscript[[:space:]]+tests/smoke_check[.]R([[:space:]]|$)' "$ANALYTICS_DIR/Dockerfile" || fail 'Selected Dockerfile does not run tests/smoke_check.R during the build.'; log 'Required offline image smoke test is present.'
CURRENT_STAGE="image build"; log 'Building cycling-analytics image; the Dockerfile smoke test is mandatory.'
"$COMPOSE_WRAPPER" build cycling-analytics
image_ref="$("$COMPOSE_WRAPPER" config --images | awk '/^cycling-analytics:/ {print; exit}')"; [[ -n "$image_ref" ]] || fail 'Configured analytics image reference could not be determined.'
image_id="$("$DOCKER_BIN" image inspect --format '{{.Id}}' "$image_ref" 2>/dev/null || true)"; [[ -n "$image_id" ]] || fail 'Built image identity could not be determined.'; log "Image reference: $image_ref"; log "Image ID: $image_id"; log 'Image build and offline smoke test passed.'
CURRENT_STAGE="Compose validation"; log 'Validating rendered Compose configuration without printing it.'; "$COMPOSE_WRAPPER" config --quiet >/dev/null
CURRENT_STAGE=evidence; finish_time="$(date '+%Y-%m-%dT%H:%M:%S%z')"; write_evidence "$DEPLOY_LOG" "$finish_time"
if [[ -n "$EVIDENCE_FILE" ]]; then [[ -d "$(dirname "$EVIDENCE_FILE")" && -w "$(dirname "$EVIDENCE_FILE")" ]] || fail 'Evidence output directory is unavailable.'; write_evidence "$EVIDENCE_FILE" "$finish_time"; log "Appended deployment evidence to $EVIDENCE_FILE"; fi
CURRENT_STAGE=complete; log "Deployment ready at $finish_time. Image build/smoke test and Compose validation passed; no production render ran and schedules were unchanged."
