#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/compose/.env}"
DATA_DIR="${MARIADB_DATA_DIR:-/srv/cycling/data/mariadb}"
RUNTIME_RENVIRON="${RUNTIME_RENVIRON:-/srv/cycling/config/platform/runtime.Renviron}"
PLATFORM_CONFIG_DIR="$(dirname "$RUNTIME_RENVIRON")"
EXPECTED_RUNTIME_OWNER="${EXPECTED_RUNTIME_OWNER:-tim:tim}"

fail() { printf '[preflight] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[preflight] %s\n' "$*"; }

read_env_value() {
  awk -F= -v key="$1" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if ((substr(value,1,1) == "\"" && substr(value,length(value),1) == "\"") ||
          (substr(value,1,1) == "\047" && substr(value,length(value),1) == "\047")) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$ENV_FILE"
}

unsafe_password() {
  local normalized
  normalized="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    ''|replace-me|replace_me|changeme|change-me|password|example|example-password|example_password)
      return 0 ;;
    *) return 1 ;;
  esac
}

[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || fail "Create a regular $ENV_FILE from compose/.env.example, protect it with mode 0600, and supply real credentials."
[[ -r "$ENV_FILE" ]] || fail "$ENV_FILE is not readable."

mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE")"
[[ "$mode" == "600" ]] || fail "$ENV_FILE must have mode 0600; detected $mode."

for key in MARIADB_USER MARIADB_PASSWORD MARIADB_ROOT_PASSWORD MARIADB_PORT; do
  value="$(read_env_value "$key")"
  [[ -n "$value" ]] || fail "$key is missing or empty in $ENV_FILE."
  if [[ "$key" == MARIADB_PASSWORD || "$key" == MARIADB_ROOT_PASSWORD ]]; then
    unsafe_password "$value" && fail "$key uses a known unsafe placeholder. Replace it before MariaDB startup."
  fi
done

[[ -d "$PLATFORM_CONFIG_DIR" && ! -L "$PLATFORM_CONFIG_DIR" ]] || fail "Required dedicated platform configuration directory is absent or unsafe: $PLATFORM_CONFIG_DIR."
platform_config_mode="$(stat -c '%a' "$PLATFORM_CONFIG_DIR" 2>/dev/null || stat -f '%Lp' "$PLATFORM_CONFIG_DIR")"
platform_config_owner="$(stat -c '%U:%G' "$PLATFORM_CONFIG_DIR" 2>/dev/null || stat -f '%Su:%Sg' "$PLATFORM_CONFIG_DIR")"
[[ "$platform_config_mode" == "700" ]] || fail "$PLATFORM_CONFIG_DIR must have mode 0700; detected $platform_config_mode."
[[ "$platform_config_owner" == "$EXPECTED_RUNTIME_OWNER" ]] || fail "$PLATFORM_CONFIG_DIR must be owned by $EXPECTED_RUNTIME_OWNER; detected $platform_config_owner."
unexpected_entry="$(find "$PLATFORM_CONFIG_DIR" -mindepth 1 -maxdepth 1 ! -name runtime.Renviron -print -quit)"
[[ -z "$unexpected_entry" ]] || fail "$PLATFORM_CONFIG_DIR must be dedicated to runtime.Renviron; unexpected entry: $unexpected_entry"
[[ -f "$RUNTIME_RENVIRON" && ! -L "$RUNTIME_RENVIRON" ]] || fail "Required runtime credential file is absent or unsafe: $RUNTIME_RENVIRON. Run bootstrap and restore the authoritative file."
runtime_mode="$(stat -c '%a' "$RUNTIME_RENVIRON" 2>/dev/null || stat -f '%Lp' "$RUNTIME_RENVIRON")"
runtime_owner="$(stat -c '%U:%G' "$RUNTIME_RENVIRON" 2>/dev/null || stat -f '%Su:%Sg' "$RUNTIME_RENVIRON")"
[[ "$runtime_mode" == "600" ]] || fail "$RUNTIME_RENVIRON must have mode 0600; detected $runtime_mode."
[[ "$runtime_owner" == "$EXPECTED_RUNTIME_OWNER" ]] || fail "$RUNTIME_RENVIRON must be owned by $EXPECTED_RUNTIME_OWNER; detected $runtime_owner. Repair ownership before running platform jobs."

if [[ -d "$DATA_DIR/mysql" ]]; then
  log "MariaDB data directory is already initialized. Compose MARIADB_* changes do not rotate existing database users; use the documented SQL rotation procedure."
else
  log "MariaDB data directory appears new; safe non-placeholder initialization credentials are present."
fi

CYCLING_PLATFORM_EXECUTION_HOST="$(hostname -s)"
export CYCLING_PLATFORM_EXECUTION_HOST
[[ -n "$CYCLING_PLATFORM_EXECUTION_HOST" ]] || fail "Could not determine the physical host identity."
log "Execution host: $CYCLING_PLATFORM_EXECUTION_HOST"
log "Preflight passed without displaying secrets."
