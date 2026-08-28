#!/usr/bin/env bash

# Infrastructure is the single owner of the Pi production analytics schedule.
ANALYTICS_CRON_EXPRESSION="30 2,20 * * *"

analytics_cron_line() {
  local refresh_script="$1"
  printf '%s %s\n' "$ANALYTICS_CRON_EXPRESSION" "$refresh_script"
}

analytics_next_refresh_text() {
  local current_hhmm="$1"

  [[ "$current_hhmm" =~ ^[0-2][0-9][0-5][0-9]$ ]] || return 1
  (( 10#${current_hhmm:0:2} <= 23 )) || return 1

  if (( 10#$current_hhmm < 230 )); then
    printf '%s\n' '02:30'
  elif (( 10#$current_hhmm < 2030 )); then
    printf '%s\n' '20:30'
  else
    printf '%s\n' '02:30'
  fi
}
