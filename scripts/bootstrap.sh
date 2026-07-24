#!/usr/bin/env bash

set -euo pipefail

PRODUCTION_ROOT="/srv/cycling"
OWNER="${SUDO_USER:-$USER}"

sudo mkdir -p \
  "${PRODUCTION_ROOT}/data/mariadb" \
  "${PRODUCTION_ROOT}/logs/platform"

sudo chown "${OWNER}:${OWNER}" \
  "${PRODUCTION_ROOT}" \
  "${PRODUCTION_ROOT}/data" \
  "${PRODUCTION_ROOT}/logs" \
  "${PRODUCTION_ROOT}/logs/platform"

printf 'Production directories ready under %s\n' "${PRODUCTION_ROOT}"
