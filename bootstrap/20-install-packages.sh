#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"
export DEBIAN_FRONTEND="noninteractive"
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap/common.sh
source "$STAGE_DIR/common.sh"
require_sudo
packages=(bash ca-certificates coreutils cron curl diffutils findutils git grep gzip hostname locales mawk sed)
stage_log "Installing required host packages idempotently."
"$bootstrap_sudo" "${BOOTSTRAP_APT_GET_BIN:-apt-get}" install -y "${packages[@]}"
"$bootstrap_sudo" "${BOOTSTRAP_SYSTEMCTL_BIN:-systemctl}" enable --now cron
stage_log "Required packages and cron service are ready."
