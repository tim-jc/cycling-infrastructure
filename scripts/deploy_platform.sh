#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRASTRUCTURE_DIR="${INFRASTRUCTURE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PLATFORM_DIR="${PLATFORM_DIR:-/home/tim/cycling-platform}"
COMPOSE_WRAPPER="${COMPOSE_WRAPPER:-$SCRIPT_DIR/compose.sh}"
PREFLIGHT_SCRIPT="${PREFLIGHT_SCRIPT:-$SCRIPT_DIR/preflight.sh}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
GIT_BIN="${GIT_BIN:-git}"
DEPLOY_LOG="${DEPLOY_LOG:-$INFRASTRUCTURE_DIR/logs/platform_deployment.log}"
DEPLOY_LOCK_DIR="${DEPLOY_LOCK_DIR:-/tmp/cycling-platform-deployment.lock}"
DAILY_LOCK_DIR="${DAILY_LOCK_DIR:-/tmp/cycling-platform-daily.lock}"
VALIDATION_LOCK_DIR="${VALIDATION_LOCK_DIR:-/tmp/cycling-platform-validation.lock}"
RESTORE_LOCK_DIR="${RESTORE_LOCK_DIR:-/tmp/cycling-platform-database-restore.lock}"
REFERENCE_READINESS_SCRIPT="${REFERENCE_READINESS_SCRIPT:-$SCRIPT_DIR/reconcile_reference_database.sh}"
REF="origin/main"
EXPECTED_PLATFORM_ORIGIN="${EXPECTED_PLATFORM_ORIGIN:-https://github.com/tim-jc/cycling-platform.git}"
EVIDENCE_FILE=""
CURRENT_STAGE="argument parsing"
LOCK_ACQUIRED=false
START_TIME="$(date '+%Y-%m-%dT%H:%M:%S%z')"

usage() {
  cat <<'USAGE'
Usage: deploy_platform.sh [--ref BRANCH_TAG_OR_COMMIT] [--evidence-file FILE]

Normal deployment fetches and deploys origin/main. An explicit --ref selects a
branch, tag, or commit for deterministic recovery or rollback. A successful
production deployment always builds, validates Compose, runs platform bootstrap
and migrations, then runs publication validation. It never runs ingestion or
changes schedules.
USAGE
}

log() {
  printf '[deploy-platform] %s\n' "$*"
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$CURRENT_STAGE" "$*" >>"$DEPLOY_LOG"
}

fail() {
  printf '[deploy-platform] ERROR [%s]: %s\n' "$CURRENT_STAGE" "$*" >&2
  exit 1
}

cleanup() {
  local status=$?
  if [[ "$LOCK_ACQUIRED" == true ]]; then
    rmdir "$DEPLOY_LOCK_DIR" 2>/dev/null || true
  fi
  if (( status != 0 )); then
    printf '%s [%s] deployment_status=failed\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$CURRENT_STAGE" >>"$DEPLOY_LOG" 2>/dev/null || true
    printf '[deploy-platform] Deployment incomplete; schedules were unchanged. Resolve the %s failure, verify repository/database state, and rerun.\n' "$CURRENT_STAGE" >&2
  fi
  return "$status"
}
trap cleanup EXIT

while (( $# )); do
  case "$1" in
    --ref)
      [[ $# -ge 2 && -n "$2" ]] || fail '--ref requires a non-empty value.'
      REF="$2"
      shift 2
      ;;
    --evidence-file)
      [[ $# -ge 2 && -n "$2" ]] || fail '--evidence-file requires a non-empty value.'
      EVIDENCE_FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      ;;
  esac
done

mkdir -p "$(dirname "$DEPLOY_LOG")"
: >>"$DEPLOY_LOG"

CURRENT_STAGE="concurrency preflight"
if ! mkdir "$DEPLOY_LOCK_DIR" 2>/dev/null; then
  fail "Another deployment appears active: $DEPLOY_LOCK_DIR"
fi
LOCK_ACQUIRED=true
for conflicting_lock in "$DAILY_LOCK_DIR" "$VALIDATION_LOCK_DIR" "$RESTORE_LOCK_DIR"; do
  [[ ! -d "$conflicting_lock" ]] || fail "Conflicting operation appears active: $conflicting_lock"
done

CURRENT_STAGE="preflight"
log "Deployment started at $START_TIME on host $(hostname -s)."
for command in "$GIT_BIN" "$DOCKER_BIN"; do
  command -v "$command" >/dev/null 2>&1 || fail "Required command is unavailable: $command"
done
[[ -x "$COMPOSE_WRAPPER" ]] || fail "Compose wrapper is missing or not executable: $COMPOSE_WRAPPER"
[[ -x "$PREFLIGHT_SCRIPT" ]] || fail "Preflight script is missing or not executable: $PREFLIGHT_SCRIPT"
[[ -x "$REFERENCE_READINESS_SCRIPT" ]] || fail "Reference database readiness script is missing or not executable: $REFERENCE_READINESS_SCRIPT"
[[ -d "$INFRASTRUCTURE_DIR/.git" ]] || fail "Infrastructure repository is absent: $INFRASTRUCTURE_DIR"
[[ -d "$PLATFORM_DIR/.git" ]] || fail "Platform repository is absent: $PLATFORM_DIR"
[[ -z "$("$GIT_BIN" -C "$INFRASTRUCTURE_DIR" status --porcelain)" ]] || fail 'Infrastructure working tree is dirty; commit, preserve, or resolve changes before deployment.'
[[ -z "$("$GIT_BIN" -C "$PLATFORM_DIR" status --porcelain)" ]] || fail 'Platform working tree is dirty; commit, preserve, or resolve changes before deployment.'
"$DOCKER_BIN" info >/dev/null 2>&1 || fail 'Docker daemon is unavailable to the current user.'
"$PREFLIGHT_SCRIPT"

infrastructure_commit="$("$GIT_BIN" -C "$INFRASTRUCTURE_DIR" rev-parse HEAD)"
origin_url="$("$GIT_BIN" -C "$PLATFORM_DIR" remote get-url origin)"
[[ -n "$origin_url" ]] || fail 'Platform origin remote is missing.'
case "$origin_url" in
  "$EXPECTED_PLATFORM_ORIGIN"|git@github.com:tim-jc/cycling-platform.git)
    ;;
  *)
    fail "Platform origin is unexpected: $origin_url"
    ;;
esac
log "Infrastructure commit: $infrastructure_commit"
log "Platform origin: $origin_url"

CURRENT_STAGE="revision selection"
"$GIT_BIN" -C "$PLATFORM_DIR" fetch --prune --tags origin
log "Selected revision: $REF"
platform_commit="$("$GIT_BIN" -C "$PLATFORM_DIR" rev-parse --verify "$REF^{commit}")" || fail "Cannot resolve intended revision: $REF"
"$GIT_BIN" -C "$PLATFORM_DIR" checkout --detach "$platform_commit"
actual_commit="$("$GIT_BIN" -C "$PLATFORM_DIR" rev-parse HEAD)"
[[ "$actual_commit" == "$platform_commit" ]] || fail 'Checked-out revision does not match the resolved commit.'
log "Platform commit: $actual_commit"

CURRENT_STAGE="image build"
log 'Building cycling-platform image.'
"$COMPOSE_WRAPPER" build cycling-platform
image_ref="$("$COMPOSE_WRAPPER" config --images | awk '/^cycling-platform:/ { print; exit }')"
[[ -n "$image_ref" ]] || fail 'Configured cycling-platform image reference could not be determined.'
image_id="$("$DOCKER_BIN" image inspect --format '{{.Id}}' "$image_ref" 2>/dev/null || true)"
[[ -n "$image_id" ]] || fail 'Built image identity could not be determined.'
log "Image reference: $image_ref"
log "Image ID: $image_id"

CURRENT_STAGE="Compose validation"
log 'Validating rendered Compose configuration without printing it.'
"$COMPOSE_WRAPPER" config --quiet >/dev/null

CURRENT_STAGE="MariaDB health"
mariadb_container_id="$("$COMPOSE_WRAPPER" ps -q mariadb)"
[[ -n "$mariadb_container_id" ]] || fail 'MariaDB service is not running; start it with scripts/start_mariadb.sh and rerun deployment.'
mariadb_health="$("$DOCKER_BIN" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$mariadb_container_id")"
[[ "$mariadb_health" == "healthy" ]] || fail "MariaDB service is not healthy (status: ${mariadb_health:-unknown})."
running_platform="$("$COMPOSE_WRAPPER" ps -q cycling-platform)"
[[ -z "$running_platform" ]] || fail 'A cycling-platform container is already running; wait for it to finish before deployment.'
log 'MariaDB is healthy and no platform job is active.'

CURRENT_STAGE="Reference database readiness"
"$REFERENCE_READINESS_SCRIPT" --check-only
log 'Reference database readiness passed.'

CURRENT_STAGE="bootstrap/migration"
log 'Running required platform bootstrap and migrations.'
"$COMPOSE_WRAPPER" run --rm cycling-platform Rscript bootstrap_platform.R
log 'Platform bootstrap and migrations passed.'

CURRENT_STAGE="publication validation"
log 'Running required publication validation.'
"$COMPOSE_WRAPPER" run --rm cycling-platform Rscript run_platform_validation.R --publication
log 'Publication validation passed.'

CURRENT_STAGE="evidence"
finish_time="$(date '+%Y-%m-%dT%H:%M:%S%z')"
{
  printf 'deployment_started_at: %s\n' "$START_TIME"
  printf 'deployment_finished_at: %s\n' "$finish_time"
  printf 'deployment_host: %s\n' "$(hostname -s)"
  printf 'infrastructure_commit: %s\n' "$infrastructure_commit"
  printf 'cycling_platform_commit: %s\n' "$actual_commit"
  printf 'cycling_platform_image_ref: %s\n' "$image_ref"
  printf 'cycling_platform_image_id: %s\n' "$image_id"
  printf 'bootstrap_result: passed\n'
  printf 'publication_validation_result: passed\n'
  printf 'deployment_status: ready\n'
} >>"$DEPLOY_LOG"
if [[ -n "$EVIDENCE_FILE" ]]; then
  {
    printf 'deployment_started_at: %s\n' "$START_TIME"
    printf 'deployment_finished_at: %s\n' "$finish_time"
    printf 'deployment_host: %s\n' "$(hostname -s)"
    printf 'infrastructure_commit: %s\n' "$infrastructure_commit"
    printf 'cycling_platform_commit: %s\n' "$actual_commit"
    printf 'cycling_platform_image_ref: %s\n' "$image_ref"
    printf 'cycling_platform_image_id: %s\n' "$image_id"
    printf 'bootstrap_result: passed\n'
    printf 'publication_validation_result: passed\n'
    printf 'deployment_status: ready\n'
  } >>"$EVIDENCE_FILE"
  log "Appended deployment evidence to $EVIDENCE_FILE"
fi

CURRENT_STAGE="complete"
log "Deployment ready at $finish_time. Bootstrap and publication validation passed; no ingestion ran and schedules were unchanged."
