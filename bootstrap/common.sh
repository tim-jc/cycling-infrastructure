#!/usr/bin/env bash
# shellcheck disable=SC2034 # Shared values are consumed by the sourcing stage scripts.
bootstrap_expected_user="${BOOTSTRAP_EXPECTED_USER:-tim}"
bootstrap_expected_group="${BOOTSTRAP_EXPECTED_GROUP:-tim}"
bootstrap_expected_home="${BOOTSTRAP_EXPECTED_HOME:-/home/tim}"
bootstrap_expected_timezone="${BOOTSTRAP_EXPECTED_TIMEZONE:-Europe/London}"
bootstrap_production_root="${BOOTSTRAP_PRODUCTION_ROOT:-/srv/cycling}"
bootstrap_os_release_file="${BOOTSTRAP_OS_RELEASE_FILE:-/etc/os-release}"
bootstrap_reboot_required_file="${BOOTSTRAP_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}"
bootstrap_sudo="${BOOTSTRAP_SUDO_BIN:-sudo}"
stage_name="$(basename "${BASH_SOURCE[1]}")"; stage_name="${stage_name%.sh}"
stage_log() { printf '[%s] %s\n' "$stage_name" "$*"; }
stage_fail() { printf '[%s] ERROR: %s\n' "$stage_name" "$*" >&2; exit 1; }
require_sudo() { command -v "$bootstrap_sudo" >/dev/null 2>&1 || stage_fail "sudo is required; configure the tim account with administrative access during OS imaging."; }
validate_host_identity() {
  local target_user account_home short_hostname architecture
  [[ -n "${EXPECTED_HOSTNAME:-}" ]] || stage_fail "EXPECTED_HOSTNAME was not supplied by the bootstrap orchestrator."
  [[ -r "$bootstrap_os_release_file" ]] || stage_fail "Cannot identify the operating system: $bootstrap_os_release_file is unavailable."
  # shellcheck disable=SC1090
  source "$bootstrap_os_release_file"
  case "${ID:-}" in debian|raspbian) ;; *) stage_fail "Unsupported operating system '${ID:-unknown}'; install Raspberry Pi OS Lite 64-bit first." ;; esac
  architecture="$(${BOOTSTRAP_DPKG_BIN:-dpkg} --print-architecture)"
  [[ "$architecture" == "arm64" ]] || stage_fail "Unsupported architecture '$architecture'; cycling-prod requires Raspberry Pi OS Lite 64-bit on arm64."
  target_user="${SUDO_USER:-$(${BOOTSTRAP_ID_BIN:-id} -un)}"
  [[ "$target_user" == "$bootstrap_expected_user" ]] || stage_fail "Run bootstrap as '$bootstrap_expected_user'; detected '$target_user'."
  ${BOOTSTRAP_GETENT_BIN:-getent} passwd "$bootstrap_expected_user" >/dev/null || stage_fail "Required user '$bootstrap_expected_user' does not exist."
  account_home="$(${BOOTSTRAP_GETENT_BIN:-getent} passwd "$bootstrap_expected_user" | cut -d: -f6)"
  [[ "$account_home" == "$bootstrap_expected_home" ]] || stage_fail "User '$bootstrap_expected_user' must have home '$bootstrap_expected_home'; detected '${account_home:-missing}'."
  short_hostname="$(${BOOTSTRAP_HOSTNAME_BIN:-hostname} -s)"
  [[ "$short_hostname" == "$EXPECTED_HOSTNAME" ]] || stage_fail "Hostname must be '$EXPECTED_HOSTNAME'; detected '$short_hostname'. Configure it during OS imaging, then reboot."
}
