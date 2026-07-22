#!/usr/bin/env bash

set -euo pipefail

PRODUCTION_ROOT="/srv/cycling"
OWNER="${SUDO_USER:-$USER}"

sudo mkdir -p "${PRODUCTION_ROOT}"/{compose,config,data,backups,logs}
sudo chown "${OWNER}:${OWNER}" "${PRODUCTION_ROOT}"
sudo chown "${OWNER}:${OWNER}" \
  "${PRODUCTION_ROOT}"/{compose,config,data,backups,logs}

printf 'Production directories ready under %s\n' "${PRODUCTION_ROOT}"