#!/usr/bin/env bash

# Best-effort infrastructure notification for failures outside the platform's
# application notification boundary. This file is sourced by host wrappers.

read_compose_env_value() {
  local key="$1"
  local env_file="$2"

  [[ -f "$env_file" ]] || return 0

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
  ' "$env_file"
}

send_platform_outer_failure_notification() {
  local exit_status="$1"
  local pipeline="${2:-daily-platform}"
  local env_file="${COMPOSE_ENV_FILE:-${COMPOSE_DIR:-.}/.env}"
  local topic="${NTFY_TOPIC:-}"
  local base_url="${NTFY_BASE_URL:-}"
  local host body

  [[ -n "$topic" ]] || topic="$(read_compose_env_value NTFY_TOPIC "$env_file")"
  [[ -n "$base_url" ]] || base_url="$(read_compose_env_value NTFY_BASE_URL "$env_file")"
  [[ -n "$base_url" ]] || base_url="https://ntfy.sh"

  if [[ -z "$topic" ]]; then
    printf '[platform-wrapper] Infrastructure failure notification skipped: NTFY_TOPIC is not configured.\n' >&2
    return 1
  fi

  host="$(${HOSTNAME_BIN:-hostname} -s 2>/dev/null || printf unknown)"
  body="Host: $host
Pipeline: $pipeline
Status: FAILED
Exit status: $exit_status
Timestamp: $(${DATE_BIN:-date} -Is)

Context: Compose/container execution failed before the platform confirmed that its application failure notification was sent.
Details: inspect the host platform_daily.log."

  printf '%s\n' "$body" | "${CURL_BIN:-curl}" \
    --fail \
    --silent \
    --show-error \
    --max-time 15 \
    --header "Title: cycling-platform outer failure" \
    --header "Priority: high" \
    --header "Tags: warning" \
    --data-binary @- \
    "${base_url%/}/$topic" >/dev/null
}
