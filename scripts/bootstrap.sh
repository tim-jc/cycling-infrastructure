#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

EXPECTED_USER="tim"
EXPECTED_HOME="/home/tim"
DEFAULT_EXPECTED_HOSTNAME="cycling-prod"
EXPECTED_TIMEZONE="Europe/London"
PRODUCTION_ROOT="/srv/cycling"
PLATFORM_CONFIG_DIR="$PRODUCTION_ROOT/config/platform"
RUNTIME_RENVIRON="$PLATFORM_CONFIG_DIR/runtime.Renviron"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-$(id -un)}"
REQUIRED_PACKAGES=(
  bash
  ca-certificates
  coreutils
  cron
  curl
  diffutils
  findutils
  git
  grep
  hostname
  locales
  mawk
  sed
)

log() {
  printf '[bootstrap] %s\n' "$*"
}

fail() {
  printf '[bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ "${EXPECTED_HOSTNAME+x}" == "x" ]]; then
  if [[ -z "$EXPECTED_HOSTNAME" ]]; then
    fail "EXPECTED_HOSTNAME must not be empty."
  fi
  if [[ ${#EXPECTED_HOSTNAME} -gt 63 ||
    ! "$EXPECTED_HOSTNAME" =~ ^[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?$ ]]; then
    fail "EXPECTED_HOSTNAME must be a sensible single-label hostname (letters, numbers, and internal hyphens; maximum 63 characters)."
  fi
  log "Using explicit expected-hostname override '$EXPECTED_HOSTNAME' (production default: '$DEFAULT_EXPECTED_HOSTNAME')."
else
  EXPECTED_HOSTNAME="$DEFAULT_EXPECTED_HOSTNAME"
fi

if ! command -v sudo >/dev/null 2>&1; then
  fail "sudo is required; configure the tim account with administrative access during OS imaging."
fi

if [[ ! -r /etc/os-release ]]; then
  fail "Cannot identify the operating system: /etc/os-release is unavailable."
fi

# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
  debian|raspbian)
    ;;
  *)
    fail "Unsupported operating system '${ID:-unknown}'; install Raspberry Pi OS Lite 64-bit first."
    ;;
esac

architecture="$(dpkg --print-architecture)"
if [[ "$architecture" != "arm64" ]]; then
  fail "Unsupported architecture '$architecture'; cycling-prod requires Raspberry Pi OS Lite 64-bit on arm64."
fi

if [[ "$TARGET_USER" != "$EXPECTED_USER" ]]; then
  fail "Run this bootstrap as '$EXPECTED_USER' (directly or through sudo); detected '$TARGET_USER'."
fi

if ! getent passwd "$EXPECTED_USER" >/dev/null; then
  fail "Required user '$EXPECTED_USER' does not exist. Create it during OS imaging."
fi
account_home="$(getent passwd "$EXPECTED_USER" | cut -d: -f6)"
if [[ "$account_home" != "$EXPECTED_HOME" ]]; then
  fail "User '$EXPECTED_USER' must have home '$EXPECTED_HOME'; detected '${account_home:-missing}'. Configure the account during OS imaging."
fi

short_hostname="$(hostname -s)"
if [[ "$short_hostname" != "$EXPECTED_HOSTNAME" ]]; then
  fail "Hostname must be '$EXPECTED_HOSTNAME'; detected '$short_hostname'. Configure it during OS imaging, then reboot."
fi

log "Installing required host packages."
sudo apt-get update
sudo apt-get install -y "${REQUIRED_PACKAGES[@]}"

if ! locale -a | grep -Eiq '^C\.UTF-?8$|^C\.utf8$'; then
  fail "The C.UTF-8 locale is unavailable after installing locales."
fi

current_timezone="$(timedatectl show --property=Timezone --value)"
if [[ "$current_timezone" != "$EXPECTED_TIMEZONE" ]]; then
  log "Setting timezone to $EXPECTED_TIMEZONE (was ${current_timezone:-unknown})."
  sudo timedatectl set-timezone "$EXPECTED_TIMEZONE"
fi

sudo systemctl enable --now cron

"$SCRIPT_DIR/install_docker.sh"

if ! getent group docker >/dev/null; then
  fail "Docker installation did not create the docker group."
fi

if ! id -nG "$EXPECTED_USER" | tr ' ' '\n' | grep -Fxq docker; then
  log "Adding $EXPECTED_USER to the docker group."
  sudo usermod -aG docker "$EXPECTED_USER"
fi

mariadb_directory_was_created=false
if [[ ! -d "$PRODUCTION_ROOT/data/mariadb" ]]; then
  mariadb_directory_was_created=true
fi

sudo mkdir -p \
  "$PRODUCTION_ROOT/data/mariadb" \
  "$PRODUCTION_ROOT/logs/platform" \
  "$PLATFORM_CONFIG_DIR"

sudo chown "$EXPECTED_USER:$EXPECTED_USER" \
  "$PRODUCTION_ROOT" \
  "$PRODUCTION_ROOT/data" \
  "$PRODUCTION_ROOT/logs" \
  "$PRODUCTION_ROOT/logs/platform" \
  "$PRODUCTION_ROOT/config" \
  "$PLATFORM_CONFIG_DIR"

sudo chmod 0755 \
  "$PRODUCTION_ROOT" \
  "$PRODUCTION_ROOT/data" \
  "$PRODUCTION_ROOT/logs" \
  "$PRODUCTION_ROOT/logs/platform"
sudo chmod 0700 \
  "$PRODUCTION_ROOT/config" \
  "$PLATFORM_CONFIG_DIR"

if [[ "$mariadb_directory_was_created" == true ]]; then
  sudo chown "$EXPECTED_USER:$EXPECTED_USER" "$PRODUCTION_ROOT/data/mariadb"
  sudo chmod 0750 "$PRODUCTION_ROOT/data/mariadb"
  log "Created the empty MariaDB data directory."
else
  log "Preserved ownership and permissions inside the existing MariaDB data directory."
fi

if [[ -L "$RUNTIME_RENVIRON" ]]; then
  fail "$RUNTIME_RENVIRON must not be a symbolic link; replace it with a regular credential file."
fi
if [[ -e "$RUNTIME_RENVIRON" && ! -f "$RUNTIME_RENVIRON" ]]; then
  fail "$RUNTIME_RENVIRON exists but is not a regular file; repair it before running Compose."
fi
if [[ ! -e "$RUNTIME_RENVIRON" ]]; then
  sudo install -o "$EXPECTED_USER" -g "$EXPECTED_USER" -m 0600 \
    /dev/null "$RUNTIME_RENVIRON"
  log "Created the empty platform runtime credential file."
else
  sudo chown "$EXPECTED_USER:$EXPECTED_USER" "$RUNTIME_RENVIRON"
  sudo chmod 0600 "$RUNTIME_RENVIRON"
  log "Preserved the existing platform runtime credentials and enforced owner-only access."
fi

runtime_owner="$(stat -c '%U:%G' "$RUNTIME_RENVIRON")"
runtime_mode="$(stat -c '%a' "$RUNTIME_RENVIRON")"

if [[ "$runtime_owner" != "$EXPECTED_USER:$EXPECTED_USER" ]]; then
  fail "$RUNTIME_RENVIRON has ownership '$runtime_owner'; expected '$EXPECTED_USER:$EXPECTED_USER'."
fi

if [[ "$runtime_mode" != "600" ]]; then
  fail "$RUNTIME_RENVIRON has mode '$runtime_mode'; expected '600'."
fi

for command in bash cron curl git docker; do
  command -v "$command" >/dev/null 2>&1 ||
    fail "Required command is unavailable after bootstrap: $command"
done

docker compose version >/dev/null 2>&1 ||
  fail "The Docker Compose plugin is unavailable."

sudo systemctl is-active --quiet docker || fail "Docker service is not active."
sudo systemctl is-enabled --quiet docker || fail "Docker service is not enabled."
sudo systemctl is-active --quiet cron || fail "Cron service is not active."
sudo systemctl is-enabled --quiet cron || fail "Cron service is not enabled."

log "Host prerequisites, production directories, and runtime credential mount are ready."

if ! id -nG | tr ' ' '\n' | grep -Fxq docker; then
  log "Log out and reconnect before running Docker without sudo; docker-group membership is not active in this session."
else
  docker info >/dev/null 2>&1 ||
    fail "Docker is installed but the current session cannot access the daemon."
fi

log "Production cron entries were not installed intentionally. After secrets, data recovery, and validation, run:"
log "  $SCRIPT_DIR/install_cron.sh"
