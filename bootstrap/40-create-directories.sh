#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap/common.sh
source "$STAGE_DIR/common.sh"
require_sudo
platform_config_dir="$bootstrap_production_root/config/platform"
runtime_renviron="$platform_config_dir/runtime.Renviron"
mariadb_dir="$bootstrap_production_root/data/mariadb"
mariadb_directory_was_created=false
[[ -d "$mariadb_dir" ]] || mariadb_directory_was_created=true
"$bootstrap_sudo" mkdir -p "$mariadb_dir" "$bootstrap_production_root/logs/platform" "$platform_config_dir"
"$bootstrap_sudo" chown "$bootstrap_expected_user:$bootstrap_expected_group" "$bootstrap_production_root" "$bootstrap_production_root/data" "$bootstrap_production_root/logs" "$bootstrap_production_root/logs/platform" "$bootstrap_production_root/config" "$platform_config_dir"
"$bootstrap_sudo" chmod 0755 "$bootstrap_production_root" "$bootstrap_production_root/data" "$bootstrap_production_root/logs" "$bootstrap_production_root/logs/platform"
"$bootstrap_sudo" chmod 0700 "$bootstrap_production_root/config" "$platform_config_dir"
if [[ "$mariadb_directory_was_created" == true ]]; then
  "$bootstrap_sudo" chown "$bootstrap_expected_user:$bootstrap_expected_group" "$mariadb_dir"
  "$bootstrap_sudo" chmod 0750 "$mariadb_dir"
  stage_log "Created the empty MariaDB data directory."
else
  stage_log "Preserved ownership, permissions and contents inside the existing MariaDB data directory."
fi
[[ ! -L "$runtime_renviron" ]] || stage_fail "$runtime_renviron must not be a symbolic link."
[[ ! -e "$runtime_renviron" || -f "$runtime_renviron" ]] || stage_fail "$runtime_renviron exists but is not a regular file."
if [[ ! -e "$runtime_renviron" ]]; then
  "$bootstrap_sudo" install -o "$bootstrap_expected_user" -g "$bootstrap_expected_group" -m 0600 /dev/null "$runtime_renviron"
  stage_log "Created the empty platform runtime credential file."
else
  "$bootstrap_sudo" chown "$bootstrap_expected_user:$bootstrap_expected_group" "$runtime_renviron"
  "$bootstrap_sudo" chmod 0600 "$runtime_renviron"
  stage_log "Preserved the existing runtime credential file and enforced owner-only access."
fi
unexpected_entry="$(find "$platform_config_dir" -mindepth 1 -maxdepth 1 ! -name runtime.Renviron -print -quit)"
[[ -z "$unexpected_entry" ]] || stage_fail "$platform_config_dir must be dedicated to runtime.Renviron; unexpected entry: $unexpected_entry"
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
file_owner() { stat -c '%U:%G' "$1" 2>/dev/null || stat -f '%Su:%Sg' "$1"; }
for directory in "$bootstrap_production_root" "$bootstrap_production_root/data" "$bootstrap_production_root/logs" "$bootstrap_production_root/logs/platform"; do
  [[ "$(file_owner "$directory")" == "$bootstrap_expected_user:$bootstrap_expected_group" && "$(file_mode "$directory")" == 755 ]] || stage_fail "$directory must be $bootstrap_expected_user:$bootstrap_expected_group mode 0755."
done
for directory in "$bootstrap_production_root/config" "$platform_config_dir"; do
  [[ "$(file_owner "$directory")" == "$bootstrap_expected_user:$bootstrap_expected_group" && "$(file_mode "$directory")" == 700 ]] || stage_fail "$directory must be $bootstrap_expected_user:$bootstrap_expected_group mode 0700."
done
[[ "$(file_owner "$runtime_renviron")" == "$bootstrap_expected_user:$bootstrap_expected_group" && "$(file_mode "$runtime_renviron")" == 600 ]] || stage_fail "$runtime_renviron must be $bootstrap_expected_user:$bootstrap_expected_group mode 0600."
stage_log "Production data, log and protected runtime-configuration paths are ready."
