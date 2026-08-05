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
"${BOOTSTRAP_INSTALL_DOCKER_SCRIPT:-$REPOSITORY_ROOT/scripts/install_docker.sh}"
${BOOTSTRAP_GETENT_BIN:-getent} group docker >/dev/null || stage_fail "Docker installation did not create the docker group."
if ! ${BOOTSTRAP_ID_BIN:-id} -nG "$bootstrap_expected_user" | tr ' ' '\n' | grep -Fxq docker; then
  stage_log "Adding $bootstrap_expected_user to the docker group."
  "$bootstrap_sudo" "${BOOTSTRAP_USERMOD_BIN:-usermod}" -aG docker "$bootstrap_expected_user"
fi
if ! ${BOOTSTRAP_ID_BIN:-id} -nG | tr ' ' '\n' | grep -Fxq docker; then
  stage_log "Docker-group membership is not active in this session; reconnect after bootstrap before using Docker without sudo."
else
  ${BOOTSTRAP_DOCKER_BIN:-docker} info >/dev/null 2>&1 || stage_fail "The current session belongs to docker but cannot access the daemon."
fi
stage_log "Docker Engine, Compose plugin, service and group configuration are ready."
