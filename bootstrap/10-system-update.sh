#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" LANG="C.UTF-8" LC_ALL="C.UTF-8" DEBIAN_FRONTEND="noninteractive"
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap/common.sh
source "$STAGE_DIR/common.sh"
require_sudo; validate_host_identity
current_timezone="$(${BOOTSTRAP_TIMEDATECTL_BIN:-timedatectl} show --property=Timezone --value)"
if [[ "$current_timezone" != "$bootstrap_expected_timezone" ]]; then
  stage_log "Setting timezone to $bootstrap_expected_timezone (was ${current_timezone:-unknown})."
  "$bootstrap_sudo" "${BOOTSTRAP_TIMEDATECTL_BIN:-timedatectl}" set-timezone "$bootstrap_expected_timezone"
else stage_log "Timezone is already $bootstrap_expected_timezone."; fi
${BOOTSTRAP_LOCALE_BIN:-locale} -a | grep -Eiq '^C\.UTF-?8$|^C\.utf8$' || stage_fail "The C.UTF-8 locale is unavailable. Repair the base OS locale before continuing."
stage_log "Refreshing package metadata and applying the full OS upgrade."
"$bootstrap_sudo" "${BOOTSTRAP_APT_GET_BIN:-apt-get}" update
"$bootstrap_sudo" "${BOOTSTRAP_APT_GET_BIN:-apt-get}" full-upgrade -y
if [[ -e "$bootstrap_reboot_required_file" ]]; then stage_log "REBOOT REQUIRED: updates require a reboot; later stages were not run."; exit 75; fi
stage_log "System update completed; no reboot is currently required."
