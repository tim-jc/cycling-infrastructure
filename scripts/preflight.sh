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

[[ -f "$RUNTIME_RENVIRON" && ! -L "$RUNTIME_RENVIRON" ]] || fail "Required runtime credential file is absent or unsafe: $RUNTIME_RENVIRON. Run bootstrap and restore the authoritative file."
runtime_mode="$(stat -c '%a' "$RUNTIME_RENVIRON" 2>/dev/null || stat -f '%Lp' "$RUNTIME_RENVIRON")"
[[ "$runtime_mode" == "600" ]] || fail "$RUNTIME_RENVIRON must have mode 0600; detected $runtime_mode."

if [[ -d "$DATA_DIR/mysql" ]]; then
  log "MariaDB data directory is already initialized. Compose MARIADB_* changes do not rotate existing database users; use the documented SQL rotation procedure."
else
  log "MariaDB data directory appears new; safe non-placeholder initialization credentials are present."
fi

export CYCLING_PLATFORM_EXECUTION_HOST="$(hostname -s)"
[[ -n "$CYCLING_PLATFORM_EXECUTION_HOST" ]] || fail "Could not determine the physical host identity."
log "Execution host: $CYCLING_PLATFORM_EXECUTION_HOST"
log "Preflight passed without displaying secrets."
