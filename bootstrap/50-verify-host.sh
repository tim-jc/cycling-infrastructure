#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$STAGE_DIR/.." && pwd)"
# shellcheck source=bootstrap/common.sh
source "$STAGE_DIR/common.sh"
require_sudo
validate_host_identity
for command in bash cron curl git gzip docker; do
  command -v "$command" >/dev/null 2>&1 || stage_fail "Required command is unavailable: $command"
done
${BOOTSTRAP_DOCKER_BIN:-docker} compose version >/dev/null 2>&1 || stage_fail "The Docker Compose plugin is unavailable."
for check in 'is-active docker' 'is-enabled docker' 'is-active cron' 'is-enabled cron'; do
  read -r action service <<<"$check"
  "$bootstrap_sudo" "${BOOTSTRAP_SYSTEMCTL_BIN:-systemctl}" "$action" --quiet "$service" || stage_fail "$service service failed $action verification."
done
if [[ -f "$REPOSITORY_ROOT/compose/.env" ]]; then
  "$REPOSITORY_ROOT/scripts/preflight.sh"
else
  stage_log "compose/.env is intentionally absent; create and protect it during the next recovery phase."
fi
stage_log "Host baseline verification passed. MariaDB was not started, data was not restored and application cron was not installed."
