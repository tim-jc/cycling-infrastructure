#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/analytics_schedule.sh
source "$SCRIPT_DIR/analytics_schedule.sh"
COMPOSE_DIR="${COMPOSE_DIR:-/home/tim/cycling-infrastructure/compose}"
COMPOSE_WRAPPER="${COMPOSE_WRAPPER:-/home/tim/cycling-infrastructure/scripts/compose.sh}"
LOG_DIR="${LOG_DIR:-/home/tim/cycling-infrastructure/logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/analytics_refresh.log}"
OUTPUT_DIR="${ANALYTICS_OUTPUT_DIR:-/srv/cycling/data/analytics/output}"
OUTPUT_FILE="${OUTPUT_FILE:-$OUTPUT_DIR/index.html}"
PUBLISHER="${ANALYTICS_PUBLISHER:-$SCRIPT_DIR/publish_analytics.sh}"
DEPLOY_LOCK_DIR="${DEPLOY_LOCK_DIR:-/tmp/cycling-analytics-deployment.lock}"
RENDER_LOCK_DIR="${RENDER_LOCK_DIR:-/tmp/cycling-analytics-render.lock}"
RESTORE_LOCK_DIR="${RESTORE_LOCK_DIR:-/tmp/cycling-platform-database-restore.lock}"
ANALYTICS_SCRIPT="${ANALYTICS_SCRIPT:-/home/tim/cycling-infrastructure/scripts/run_analytics_refresh.sh}"
CRONTAB_BIN="${CRONTAB_BIN:-crontab}"
RUNTIME_TMP_PARENT="${RUNTIME_TMP_PARENT:-/tmp}"
COMPOSE_ENV_FILE="${COMPOSE_ENV_FILE:-$COMPOSE_DIR/.env}"
CONTEXT_CONTAINER_DIR="/run/cycling-analytics-notification"
CONTEXT_CONTAINER_FILE="$CONTEXT_CONTAINER_DIR/context.txt"
LOCK_ACQUIRED=false
CONTEXT_DIR=""

timestamp() {
  "${DATE_BIN:-date}" -Is
}

log() {
  printf '%s %s\n' "$(timestamp)" "$*" >>"$LOG_FILE"
}

read_compose_env_value() {
  local key="$1"
  [[ -f "$COMPOSE_ENV_FILE" ]] || return 0
  awk -v key="$key" '
    index($0, key "=") == 1 {
      value = substr($0, length(key) + 2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$COMPOSE_ENV_FILE"
}

send_notification() {
  local title="$1"
  local priority="$2"
  local tags="$3"
  local body_file="$4"
  local topic="${CYCLING_ANALYTICS_NTFY_TOPIC:-}"
  local base_url="${NTFY_BASE_URL:-}"
  local dashboard_url="https://cycling-analytics-8bs.pages.dev"

  [[ -n "$topic" ]] || topic="$(read_compose_env_value CYCLING_ANALYTICS_NTFY_TOPIC)"
  [[ -n "$base_url" ]] || base_url="$(read_compose_env_value NTFY_BASE_URL)"
  [[ -n "$base_url" ]] || base_url="https://ntfy.sh"
  if [[ -z "$topic" ]]; then
    log "Notification skipped: CYCLING_ANALYTICS_NTFY_TOPIC is not configured; NTFY_TOPIC is platform-owned and will not be used."
    return 1
  fi

  "${CURL_BIN:-curl}" \
    --fail \
    --silent \
    --show-error \
    --max-time 15 \
    --header "Title: $title" \
    --header "Priority: $priority" \
    --header "Tags: $tags" \
    --header "Click: $dashboard_url" \
    --data-binary "@$body_file" \
    "${base_url%/}/$topic" >/dev/null
}

# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  local status=$?
  if [[ -n "$CONTEXT_DIR" ]]; then
    rm -f -- "$CONTEXT_DIR/context.txt" "$CONTEXT_DIR/success.txt" "$CONTEXT_DIR/failure.txt" "$CONTEXT_DIR/output-start.marker"
    rmdir "$CONTEXT_DIR" 2>/dev/null || true
  fi
  if [[ "$LOCK_ACQUIRED" == true ]]; then
    rmdir "$RENDER_LOCK_DIR" 2>/dev/null || true
  fi
  return "$status"
}
trap cleanup EXIT

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

if [[ -d "$DEPLOY_LOCK_DIR" ]]; then
  log "Analytics refresh blocked while analytics deployment is active."
  exit 1
fi
if [[ -d "$RESTORE_LOCK_DIR" ]]; then
  log "Analytics refresh blocked while database restore is active."
  exit 1
fi
[[ -x "$PUBLISHER" ]] || { log "Analytics publisher is missing or not executable: $PUBLISHER"; exit 1; }
if ! mkdir "$RENDER_LOCK_DIR" 2>/dev/null; then
  log "Analytics refresh already active; exiting without overlap."
  exit 0
fi
LOCK_ACQUIRED=true

[[ -x "$COMPOSE_WRAPPER" ]] || { log "Compose wrapper is missing or not executable: $COMPOSE_WRAPPER"; exit 1; }
[[ -d "$RUNTIME_TMP_PARENT" && -w "$RUNTIME_TMP_PARENT" ]] || { log "Runtime temporary parent is unavailable: $RUNTIME_TMP_PARENT"; exit 1; }
if ! execution_host="$(${HOSTNAME_BIN:-hostname} -s 2>/dev/null)" || [[ -z "$execution_host" ]]; then
  log "Analytics refresh cannot resolve the physical host short name; refusing to render."
  exit 1
fi
CONTEXT_DIR="$(mktemp -d "$RUNTIME_TMP_PARENT/cycling-analytics-notification.XXXXXX")"
chmod 0700 "$CONTEXT_DIR"
context_file="$CONTEXT_DIR/context.txt"
success_file="$CONTEXT_DIR/success.txt"
failure_file="$CONTEXT_DIR/failure.txt"

next_refresh_text="not scheduled"
canonical_cron_line="$(analytics_cron_line "$ANALYTICS_SCRIPT")"
if command -v "$CRONTAB_BIN" >/dev/null 2>&1 &&
  "$CRONTAB_BIN" -l 2>/dev/null | grep -Fqx "$canonical_cron_line"; then
  current_hhmm="$("${DATE_BIN:-date}" +%H%M)"
  next_refresh_text="$(analytics_next_refresh_text "$current_hhmm")" || {
    log "Unable to calculate analytics schedule context from current time; using 'not scheduled'."
    next_refresh_text="not scheduled"
  }
fi

output_marker="$CONTEXT_DIR/output-start.marker"
touch "$output_marker"

printf '===== %s START =====\n' "$(timestamp)" >>"$LOG_FILE"
status=0
failure_stage="render"
if "$COMPOSE_WRAPPER" run --rm \
  --volume "$CONTEXT_DIR:$CONTEXT_CONTAINER_DIR:rw" \
  --env "DASHBOARD_NOTIFICATION_CONTEXT_FILE=$CONTEXT_CONTAINER_FILE" \
  --env "CYCLING_ANALYTICS_NEXT_REFRESH_TEXT=$next_refresh_text" \
  cycling-analytics >>"$LOG_FILE" 2>&1; then
  status=0
else
  status=$?
fi

if (( status == 0 )); then
  if [[ ! -f "$OUTPUT_FILE" || ! -s "$OUTPUT_FILE" || ! "$OUTPUT_FILE" -nt "$output_marker" ]]; then
    status=1
    log "Output validation failed: $OUTPUT_FILE must be a non-empty regular file newer than this refresh start."
  elif [[ ! -d "$OUTPUT_DIR/index_files" || -z "$(find "$OUTPUT_DIR/index_files" -mindepth 1 -type f -print -quit)" ]]; then
    status=1
    log "Output validation failed: $OUTPUT_DIR/index_files must contain supporting files."
  fi
fi

if (( status == 0 )); then
  log "Render and local artefact validation succeeded; starting Cloudflare publication."
  if ANALYTICS_OUTPUT_DIR="$OUTPUT_DIR" "$PUBLISHER" --from-refresh >>"$LOG_FILE" 2>&1; then
    log "Cloudflare publication succeeded."
  else
    status=$?
    failure_stage="publication"
    log "Cloudflare publication failed with status $status; the valid local rendered artefact was retained."
  fi
fi

if (( status == 0 )); then
  if [[ -f "$context_file" && -s "$context_file" ]]; then
    log "Application notification context received for published dashboard."
    awk -v host="$execution_host" 'NR == 1 { print; print "Host: " host; next } { print }' \
      "$context_file" >"$success_file"
    if send_notification "Dashboard published" default "bike,chart_with_upwards_trend" "$success_file" >>"$LOG_FILE" 2>&1; then
      log "Success notification sent."
    else
      log "Success notification could not be sent; preserving successful render status 0."
    fi
  else
    printf 'Rendered: %s\nHost: %s\nStatus: production dashboard rendered and published\nNext refresh: %s\n' \
      "$(timestamp)" "$execution_host" "$next_refresh_text" >"$success_file"
    log "Application notification context was unavailable; using a published-dashboard fallback."
    if send_notification "Dashboard published" default "bike,chart_with_upwards_trend" "$success_file" >>"$LOG_FILE" 2>&1; then
      log "Fallback success notification sent."
    else
      log "Success notification could not be sent; preserving successful render status 0."
    fi
  fi
fi

if (( status != 0 )); then
  if [[ "$failure_stage" == publication ]]; then
    printf 'Host: %s\nOperation: analytics refresh and publication\nFailed stage: publication\nRender result: succeeded; local artefact retained\nStatus: FAILED\nExit status: %s\nTimestamp: %s\n\nDetails: inspect %s\n' \
      "$execution_host" "$status" "$(timestamp)" "$LOG_FILE" >"$failure_file"
  else
    printf 'Host: %s\nOperation: analytics refresh and publication\nFailed stage: render\nPublication result: not attempted\nStatus: FAILED\nExit status: %s\nTimestamp: %s\n\nDetails: inspect %s\n' \
      "$execution_host" "$status" "$(timestamp)" "$LOG_FILE" >"$failure_file"
  fi
  failure_title="cycling-analytics ${failure_stage} failed"
  if send_notification "$failure_title" high warning "$failure_file" >>"$LOG_FILE" 2>&1; then
    log "Failure notification sent."
  else
    log "Failure notification could not be sent; preserving refresh status $status."
  fi
fi

printf '===== %s END status=%s =====\n' "$(timestamp)" "$status" >>"$LOG_FILE"
exit "$status"
