#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8" LC_ALL="C.UTF-8"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STAGE_DIRECTORY="${BOOTSTRAP_STAGE_DIRECTORY:-$REPOSITORY_ROOT/bootstrap}"
DEFAULT_EXPECTED_HOSTNAME="cycling-prod"
REBOOT_REQUIRED_EXIT_STATUS=75
log() { printf '[bootstrap] %s\n' "$*"; }
fail() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "${EXPECTED_HOSTNAME+x}" == "x" ]]; then
  [[ -n "$EXPECTED_HOSTNAME" ]] || fail "EXPECTED_HOSTNAME must not be empty."
  if [[ ${#EXPECTED_HOSTNAME} -gt 63 || ! "$EXPECTED_HOSTNAME" =~ ^[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?$ ]]; then
    fail "EXPECTED_HOSTNAME must be a sensible single-label hostname (letters, numbers, and internal hyphens; maximum 63 characters)."
  fi
  log "Using explicit expected-hostname override '$EXPECTED_HOSTNAME' (production default: '$DEFAULT_EXPECTED_HOSTNAME')."
else
  EXPECTED_HOSTNAME="$DEFAULT_EXPECTED_HOSTNAME"
fi
export EXPECTED_HOSTNAME

[[ -d "$STAGE_DIRECTORY" ]] || fail "Bootstrap stage directory is missing: $STAGE_DIRECTORY"
stages=()
while IFS= read -r stage; do stages+=("$stage"); done < <(find "$STAGE_DIRECTORY" -maxdepth 1 -type f -name '[0-9][0-9]-*.sh' -print | LC_ALL=C sort)
(( ${#stages[@]} > 0 )) || fail "No numbered bootstrap stages found in $STAGE_DIRECTORY"
log "Starting staged host bootstrap for expected hostname '$EXPECTED_HOSTNAME'."
for stage in "${stages[@]}"; do
  [[ -x "$stage" ]] || fail "Bootstrap stage is not executable: $stage"
  stage_name="$(basename "$stage")"
  log "Running $stage_name"
  set +e
  "$stage"
  stage_status=$?
  set -e
  if (( stage_status == REBOOT_REQUIRED_EXIT_STATUS )); then
    log "$stage_name requires a reboot before bootstrap can continue."
    log "Reconnect, return to $REPOSITORY_ROOT, and rerun:"
    if [[ "$EXPECTED_HOSTNAME" == "$DEFAULT_EXPECTED_HOSTNAME" ]]; then log "  ./scripts/bootstrap.sh"; else log "  EXPECTED_HOSTNAME=$EXPECTED_HOSTNAME ./scripts/bootstrap.sh"; fi
    exit "$REBOOT_REQUIRED_EXIT_STATUS"
  fi
  (( stage_status == 0 )) || fail "$stage_name failed with status $stage_status; later stages were not run."
  log "Completed $stage_name"
done
log "Host bootstrap completed successfully."
log "Next: securely create compose/.env, run scripts/preflight.sh, then start and recover MariaDB."
log "Restore runtime credentials, deploy and validate the platform, and keep application cron disabled until recovery acceptance succeeds."
