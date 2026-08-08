#!/usr/bin/env bash

# Canonical environment and command construction for every operation that
# parses the project Compose file. Compose interpolates all services even when
# the requested command targets MariaDB alone.
compose_contract_init() {
  local helper_dir project_root
  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  project_root="$(cd "$helper_dir/.." && pwd)"

  COMPOSE_DIR="${COMPOSE_DIR:-$project_root/compose}"
  COMPOSE_FILE="${COMPOSE_FILE:-$COMPOSE_DIR/docker-compose.yml}"
  ENV_FILE="${ENV_FILE:-$COMPOSE_DIR/.env}"
  DOCKER_BIN="${DOCKER_BIN:-docker}"
  COMPOSE_HOSTNAME_BIN="${COMPOSE_HOSTNAME_BIN:-hostname}"
  COMPOSE_ID_BIN="${COMPOSE_ID_BIN:-id}"

  if ! CYCLING_PLATFORM_EXECUTION_HOST="$($COMPOSE_HOSTNAME_BIN -s)" || [[ -z "$CYCLING_PLATFORM_EXECUTION_HOST" ]]; then
    printf '[compose-contract] ERROR: could not determine the physical host short name.\n' >&2
    return 1
  fi
  if ! CYCLING_PLATFORM_RUNTIME_UID="$($COMPOSE_ID_BIN -u tim)" ||
     ! CYCLING_PLATFORM_RUNTIME_GID="$($COMPOSE_ID_BIN -g tim)"; then
    printf '[compose-contract] ERROR: the required tim account is unavailable; run host bootstrap first.\n' >&2
    return 1
  fi
  if [[ ! "$CYCLING_PLATFORM_RUNTIME_UID" =~ ^[0-9]+$ || ! "$CYCLING_PLATFORM_RUNTIME_GID" =~ ^[0-9]+$ ]]; then
    printf '[compose-contract] ERROR: could not resolve a valid numeric UID/GID for the required tim account.\n' >&2
    return 1
  fi

  export CYCLING_PLATFORM_EXECUTION_HOST
  export CYCLING_PLATFORM_RUNTIME_UID CYCLING_PLATFORM_RUNTIME_GID
  # Consumed by the scripts that source this helper.
  # shellcheck disable=SC2034
  CYCLING_COMPOSE=(
    "$DOCKER_BIN" compose
    --project-directory "$COMPOSE_DIR"
    --env-file "$ENV_FILE"
    --file "$COMPOSE_FILE"
  )
}
