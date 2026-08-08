#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# Orchestrator ordering, failure, hostname propagation and reboot-resume status.
mkdir -p "$TMP/stages"
for number in 30 10 20; do
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "%%s:%%s\\n" "%s" "$EXPECTED_HOSTNAME" >>"$BOOTSTRAP_TEST_CALLS"\n' "$number" >"$TMP/stages/$number-test.sh"
  chmod 700 "$TMP/stages/$number-test.sh"
done
export BOOTSTRAP_TEST_CALLS="$TMP/calls"
BOOTSTRAP_STAGE_DIRECTORY="$TMP/stages" "$ROOT/scripts/bootstrap.sh" >"$TMP/out"
printf '%s\n' '10:cycling-prod' '20:cycling-prod' '30:cycling-prod' >"$TMP/expected"
cmp -s "$TMP/expected" "$TMP/calls"
grep -q 'securely create compose/.env' "$TMP/out"
: >"$TMP/calls"
EXPECTED_HOSTNAME=cycling-recovery-test BOOTSTRAP_STAGE_DIRECTORY="$TMP/stages" "$ROOT/scripts/bootstrap.sh" >"$TMP/out"
grep -q '10:cycling-recovery-test' "$TMP/calls"
grep -q 'explicit expected-hostname override' "$TMP/out"
for invalid_hostname in '' '-bad-host'; do
  if EXPECTED_HOSTNAME="$invalid_hostname" BOOTSTRAP_STAGE_DIRECTORY="$TMP/stages" "$ROOT/scripts/bootstrap.sh" >"$TMP/out" 2>"$TMP/err"; then
    echo 'invalid expected-hostname override passed' >&2; exit 1
  fi
  grep -q 'EXPECTED_HOSTNAME\|sensible single-label hostname' "$TMP/err"
done

# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "fail\\n" >>"$BOOTSTRAP_TEST_CALLS"\nexit 9\n' >"$TMP/stages/20-test.sh"
chmod 700 "$TMP/stages/20-test.sh"; : >"$TMP/calls"
if BOOTSTRAP_STAGE_DIRECTORY="$TMP/stages" "$ROOT/scripts/bootstrap.sh" >"$TMP/out" 2>"$TMP/err"; then echo 'failed stage did not stop bootstrap' >&2; exit 1; fi
grep -q '^10:' "$TMP/calls"; grep -q '^fail$' "$TMP/calls"
if grep -q '^30:' "$TMP/calls"; then echo 'later stage ran after failure' >&2; exit 1; fi
grep -q '20-test.sh failed with status 9' "$TMP/err"

printf '#!/usr/bin/env bash\nexit 75\n' >"$TMP/stages/20-test.sh"; : >"$TMP/calls"
set +e
EXPECTED_HOSTNAME=cycling-recovery-test BOOTSTRAP_STAGE_DIRECTORY="$TMP/stages" "$ROOT/scripts/bootstrap.sh" >"$TMP/out" 2>&1
status=$?
set -e
[[ "$status" == 75 ]]; grep -q 'EXPECTED_HOSTNAME=cycling-recovery-test ./scripts/bootstrap.sh' "$TMP/out"

# Host/update-stage fixture.
mkdir -p "$TMP/bin"
printf '%s\n' 'ID=raspbian' 'VERSION_CODENAME=bookworm' >"$TMP/os-release"
cat >"$TMP/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
"$@"
MOCK
cat >"$TMP/bin/dpkg" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${TEST_ARCH:-arm64}"
MOCK
cat >"$TMP/bin/id" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == '-un' ]]; then printf '%s\n' "${TEST_USER:-tim}"; else printf '%s\n' "${TEST_GROUPS:-tim docker}"; fi
MOCK
cat >"$TMP/bin/getent" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == passwd ]]; then printf 'tim:x:1000:1000::%s:/bin/bash\n' "${TEST_HOME:-/home/tim}"; else printf '%s\n' 'docker:x:999:tim'; fi
MOCK
cat >"$TMP/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${TEST_HOSTNAME:-cycling-prod}"
MOCK
cat >"$TMP/bin/timedatectl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == show ]] && printf '%s\n' 'Europe/London'
exit 0
MOCK
cat >"$TMP/bin/locale" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' 'C.UTF-8'
MOCK
cat >"$TMP/bin/apt-get" <<'MOCK'
#!/usr/bin/env bash
printf 'apt %s\n' "$*" >>"$TEST_STAGE_CALLS"
MOCK
cat >"$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$TEST_STAGE_CALLS"
MOCK
chmod 700 "$TMP/bin/"*
export TEST_STAGE_CALLS="$TMP/stage-calls"
stage_env=(env EXPECTED_HOSTNAME=cycling-prod BOOTSTRAP_OS_RELEASE_FILE="$TMP/os-release" BOOTSTRAP_SUDO_BIN="$TMP/bin/sudo" BOOTSTRAP_DPKG_BIN="$TMP/bin/dpkg" BOOTSTRAP_ID_BIN="$TMP/bin/id" BOOTSTRAP_GETENT_BIN="$TMP/bin/getent" BOOTSTRAP_HOSTNAME_BIN="$TMP/bin/hostname" BOOTSTRAP_TIMEDATECTL_BIN="$TMP/bin/timedatectl" BOOTSTRAP_LOCALE_BIN="$TMP/bin/locale" BOOTSTRAP_APT_GET_BIN="$TMP/bin/apt-get" BOOTSTRAP_SYSTEMCTL_BIN="$TMP/bin/systemctl" BOOTSTRAP_REBOOT_REQUIRED_FILE="$TMP/reboot-required")

: >"$TMP/stage-calls"; "${stage_env[@]}" "$ROOT/bootstrap/10-system-update.sh" >"$TMP/out"
grep -q 'apt update' "$TMP/stage-calls"; grep -q 'apt full-upgrade -y' "$TMP/stage-calls"
touch "$TMP/reboot-required"; set +e; "${stage_env[@]}" "$ROOT/bootstrap/10-system-update.sh" >"$TMP/out"; status=$?; set -e
[[ "$status" == 75 ]]; grep -q 'REBOOT REQUIRED' "$TMP/out"; rm "$TMP/reboot-required"

for assignment in 'TEST_ARCH=amd64:Unsupported architecture' 'TEST_USER=wrong:Run bootstrap as' 'TEST_HOME=/wrong:must have home' 'TEST_HOSTNAME=wrong:Hostname must be'; do
  variable="${assignment%%:*}"; message="${assignment#*:}"
  if env "$variable" "${stage_env[@]:1}" "$ROOT/bootstrap/10-system-update.sh" >"$TMP/out" 2>"$TMP/err"; then echo "invalid host fixture passed: $variable" >&2; exit 1; fi
  grep -q "$message" "$TMP/err"
done
printf '%s\n' 'ID=ubuntu' >"$TMP/os-release"
if "${stage_env[@]}" "$ROOT/bootstrap/10-system-update.sh" >"$TMP/out" 2>"$TMP/err"; then echo 'unsupported OS passed' >&2; exit 1; fi
grep -q 'Unsupported operating system' "$TMP/err"
printf '%s\n' 'ID=raspbian' 'VERSION_CODENAME=bookworm' >"$TMP/os-release"

# Package stage is repeatable.
: >"$TMP/stage-calls"; "${stage_env[@]}" "$ROOT/bootstrap/20-install-packages.sh"; "${stage_env[@]}" "$ROOT/bootstrap/20-install-packages.sh"
[[ "$(grep -c '^apt install -y ' "$TMP/stage-calls")" == 2 ]]; grep -q ' gzip ' "$TMP/stage-calls"

# Docker stage reuses the existing installer and is repeatable.
cat >"$TMP/bin/install-docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' install-docker >>"$TEST_STAGE_CALLS"
MOCK
cat >"$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod 700 "$TMP/bin/install-docker" "$TMP/bin/docker"
: >"$TMP/stage-calls"
docker_env=(env BOOTSTRAP_EXPECTED_USER=tim BOOTSTRAP_SUDO_BIN="$TMP/bin/sudo" BOOTSTRAP_GETENT_BIN="$TMP/bin/getent" BOOTSTRAP_ID_BIN="$TMP/bin/id" BOOTSTRAP_DOCKER_BIN="$TMP/bin/docker" BOOTSTRAP_INSTALL_DOCKER_SCRIPT="$TMP/bin/install-docker")
"${docker_env[@]}" "$ROOT/bootstrap/30-install-docker.sh"
"${docker_env[@]}" "$ROOT/bootstrap/30-install-docker.sh"
[[ "$(grep -c '^install-docker$' "$TMP/stage-calls")" == 2 ]]

# Directory stage preserves credential inode/content and MariaDB internals.
current_user="$(id -un)"; current_group="$(id -gn)"; production_root="$TMP/srv/cycling"
inode_of() { stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1"; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
file_owner() { stat -c '%U:%G' "$1" 2>/dev/null || stat -f '%Su:%Sg' "$1"; }
directory_env=(env BOOTSTRAP_EXPECTED_USER="$current_user" BOOTSTRAP_EXPECTED_GROUP="$current_group" BOOTSTRAP_EXPECTED_HOME="$HOME" BOOTSTRAP_PRODUCTION_ROOT="$production_root" BOOTSTRAP_SUDO_BIN="$TMP/bin/sudo")
"${directory_env[@]}" "$ROOT/bootstrap/40-create-directories.sh"
printf '%s\n' 'SECRET=preserve-me' >"$production_root/config/platform/runtime.Renviron"; chmod 600 "$production_root/config/platform/runtime.Renviron"
mkdir -p "$production_root/data/mariadb/mysql"; printf '%s\n' preserve >"$production_root/data/mariadb/mysql/marker"
credential_inode="$(inode_of "$production_root/config/platform/runtime.Renviron")"; marker_inode="$(inode_of "$production_root/data/mariadb/mysql/marker")"
"${directory_env[@]}" "$ROOT/bootstrap/40-create-directories.sh"
[[ "$(inode_of "$production_root/config/platform/runtime.Renviron")" == "$credential_inode" ]]; grep -q 'SECRET=preserve-me' "$production_root/config/platform/runtime.Renviron"
[[ "$(file_mode "$production_root/config/platform")" == 700 ]]
[[ "$(file_mode "$production_root/config/platform/runtime.Renviron")" == 600 ]]
[[ "$(file_owner "$production_root/config/platform")" == "$current_user:$current_group" ]]
[[ "$(file_owner "$production_root/config/platform/runtime.Renviron")" == "$current_user:$current_group" ]]
[[ "$(inode_of "$production_root/data/mariadb/mysql/marker")" == "$marker_inode" ]]; grep -q preserve "$production_root/data/mariadb/mysql/marker"
[[ ! -e "$ROOT/compose/.env" ]]
mv "$production_root/config/platform/runtime.Renviron" "$TMP/credential-save"; ln -s "$TMP/credential-save" "$production_root/config/platform/runtime.Renviron"
if "${directory_env[@]}" "$ROOT/bootstrap/40-create-directories.sh" >"$TMP/out" 2>"$TMP/err"; then echo 'credential symlink passed' >&2; exit 1; fi
grep -q 'must not be a symbolic link' "$TMP/err"
unlink "$production_root/config/platform/runtime.Renviron"; mkdir "$production_root/config/platform/runtime.Renviron"
if "${directory_env[@]}" "$ROOT/bootstrap/40-create-directories.sh" >"$TMP/out" 2>"$TMP/err"; then echo 'credential directory passed' >&2; exit 1; fi
grep -q 'not a regular file' "$TMP/err"

if rg -q 'start_mariadb|compose\.sh.*up|install_cron|crontab' "$ROOT/scripts/bootstrap.sh" "$ROOT/bootstrap"; then
  echo 'bootstrap starts MariaDB or installs application scheduling' >&2; exit 1
fi
printf '%s\n' 'staged bootstrap tests: passed'
