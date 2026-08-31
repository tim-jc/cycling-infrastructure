#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  status=$?
  rm -rf -- "$TMP"
  return "$status"
}
trap cleanup EXIT
mkdir -p "$TMP/infra/.git" "$TMP/platform/.git" "$TMP/bin" "$TMP/locks"
CALLS="$TMP/calls"
export CALLS FAIL_STAGE="" MOCK_ORIGIN="https://github.com/tim-jc/cycling-platform"

cat >"$TMP/bin/mock-git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$CALLS"
[[ "$1" == "-C" ]] || exit 2
repo="$2"
shift 2
case "$1 $2" in
  'status --porcelain')
    [[ "${FAIL_STAGE:-}" == "dirty-infra" && "$repo" == *infra ]] && printf ' M file\n'
    [[ "${FAIL_STAGE:-}" == "dirty-platform" && "$repo" == *platform ]] && printf ' M file\n'
    ;;
  'remote get-url') printf '%s\n' "$MOCK_ORIGIN" ;;
  'fetch --prune') [[ "${FAIL_STAGE:-}" != "revision" ]] ;;
  'rev-parse HEAD')
    if [[ "$repo" == *infra ]]; then printf '%s\n' infra-commit-sha; else printf '%s\n' platform-commit-sha; fi
    ;;
  'rev-parse --verify') printf '%s\n' platform-commit-sha ;;
  'checkout --detach') : ;;
  *) printf 'unexpected git call: %s\n' "$*" >&2; exit 2 ;;
esac
MOCK

cat >"$TMP/bin/mock-docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$CALLS"
case "$1 ${2:-}" in
  'info ') [[ "${FAIL_STAGE:-}" != "docker" ]] ;;
  'image inspect') printf '%s\n' sha256:image-id ;;
  'inspect --format')
    if [[ "${FAIL_STAGE:-}" == "mariadb-health" ]]; then printf '%s\n' unhealthy; else printf '%s\n' healthy; fi
    ;;
  *) printf 'unexpected docker call: %s\n' "$*" >&2; exit 2 ;;
esac
MOCK

cat >"$TMP/bin/mock-preflight" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' preflight >>"$CALLS"
[[ "${FAIL_STAGE:-}" != "preflight" ]]
MOCK

cat >"$TMP/bin/mock-reference-readiness" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "reference-readiness $*" >>"$CALLS"
[[ "${FAIL_STAGE:-}" != "reference-readiness" ]]
MOCK

cat >"$TMP/bin/mock-compose" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'compose %s\n' "$*" >>"$CALLS"
case "$1" in
  build) [[ "${FAIL_STAGE:-}" != "build" ]] ;;
  config)
    if [[ "$2" == "--images" ]]; then
      printf '%s\n' cycling-platform:dev
    else
      [[ "${FAIL_STAGE:-}" != "compose-config" ]]
    fi
    ;;
  ps)
    if [[ "$*" == *'mariadb'* ]]; then
      printf '%s\n' mariadb-container-id
    elif [[ "${FAIL_STAGE:-}" == "platform-running" ]]; then
      printf '%s\n' platform-container-id
    fi
    ;;
  run)
    if [[ "$*" == *'bootstrap_platform.R'* ]]; then
      [[ "${FAIL_STAGE:-}" != "bootstrap" ]]
    elif [[ "$*" == *'scripts/reference/publish_reference_data.R'* ]]; then
      [[ "${FAIL_STAGE:-}" != "reference-publication" ]]
    elif [[ "$*" == *'run_platform_validation.R --publication'* ]]; then
      [[ "${FAIL_STAGE:-}" != "validation" ]]
    else
      printf 'unexpected compose run: %s\n' "$*" >&2
      exit 2
    fi
    ;;
  *) printf 'unexpected compose call: %s\n' "$*" >&2; exit 2 ;;
esac
MOCK
chmod 700 "$TMP/bin/"*

run_deploy() {
  : >"$CALLS"
  rm -rf "$TMP/deploy.lock"
  INFRASTRUCTURE_DIR="$TMP/infra" \
  PLATFORM_DIR="$TMP/platform" \
  COMPOSE_WRAPPER="$TMP/bin/mock-compose" \
  PREFLIGHT_SCRIPT="$TMP/bin/mock-preflight" \
  REFERENCE_READINESS_SCRIPT="$TMP/bin/mock-reference-readiness" \
  DOCKER_BIN="$TMP/bin/mock-docker" \
  GIT_BIN="$TMP/bin/mock-git" \
  DEPLOY_LOG="$TMP/deploy.log" \
  DEPLOY_LOCK_DIR="$TMP/deploy.lock" \
  DAILY_LOCK_DIR="$TMP/daily.lock" \
  VALIDATION_LOCK_DIR="$TMP/validation.lock" \
  RESTORE_LOCK_DIR="$TMP/restore.lock" \
  "$ROOT/scripts/deploy_platform.sh"
}

line_number() { grep -n "$1" "$CALLS" | head -n 1 | cut -d: -f1; }
assert_not_called() { ! grep -q "$1" "$CALLS"; }

# Successful order and evidence.
if ! run_deploy >"$TMP/out" 2>"$TMP/err"; then
  cat "$TMP/err" >&2
  exit 1
fi
build_line="$(line_number '^compose build cycling-platform$')"
config_line="$(line_number '^compose config --quiet$')"
bootstrap_line="$(line_number 'bootstrap_platform.R')"
publication_line="$(line_number 'scripts/reference/publish_reference_data.R')"
validation_line="$(line_number 'run_platform_validation.R --publication')"
reference_line="$(line_number '^reference-readiness --check-only$')"
(( build_line < config_line && config_line < reference_line && reference_line < bootstrap_line && bootstrap_line < publication_line && publication_line < validation_line ))
grep -q 'Infrastructure commit: infra-commit-sha' "$TMP/out"
grep -q 'Platform commit: platform-commit-sha' "$TMP/out"
grep -q 'Image ID: sha256:image-id' "$TMP/out"
grep -q 'Reference publication passed' "$TMP/out"
grep -q 'Deployment ready' "$TMP/out"
grep -q 'bootstrap_result: passed' "$TMP/deploy.log"
grep -q 'reference_publication_result: passed' "$TMP/deploy.log"
grep -q 'publication_validation_result: passed' "$TMP/deploy.log"
grep -q 'deployment_status: ready' "$TMP/deploy.log"
if grep -Eq 'run_daily|Rscript platform\.R|run_silver|run_gold|install_cron|crontab' "$CALLS"; then
  echo 'deployment invoked ingestion or scheduling' >&2
  exit 1
fi
if grep -q '^compose config$' "$CALLS"; then
  echo 'deployment printed unredacted Compose configuration' >&2
  exit 1
fi
if grep -q 'publish_planned_events.R' "$CALLS"; then
  echo 'deployment invoked an individual Reference publisher' >&2
  exit 1
fi

for accepted_origin in https://github.com/tim-jc/cycling-platform.git git@github.com:tim-jc/cycling-platform.git; do
  export MOCK_ORIGIN="$accepted_origin"
  run_deploy >"$TMP/out" 2>"$TMP/err"
done
for rejected_origin in https://github.com/other/cycling-platform https://github.com/tim-jc/other https://github.com/tim-jc/cycling-platform-lookalike https://example.invalid/tim-jc/cycling-platform.git; do
  export MOCK_ORIGIN="$rejected_origin"
  if run_deploy >"$TMP/out" 2>"$TMP/err"; then printf 'incorrect origin accepted: %s\n' "$rejected_origin" >&2; exit 1; fi
done
export EXPECTED_PLATFORM_ORIGIN=https://github.com/example/platform-fork.git MOCK_ORIGIN=https://github.com/example/platform-fork
run_deploy >"$TMP/out" 2>"$TMP/err"
export MOCK_ORIGIN=https://github.com/tim-jc/cycling-platform
if run_deploy >"$TMP/out" 2>"$TMP/err"; then echo 'explicit expected-origin override was bypassed' >&2; exit 1; fi
unset EXPECTED_PLATFORM_ORIGIN
export MOCK_ORIGIN=https://github.com/tim-jc/cycling-platform

# Every gate stops later stages and never claims readiness.
for stage in preflight docker build compose-config mariadb-health reference-readiness bootstrap reference-publication validation; do
  export FAIL_STAGE="$stage"
  if run_deploy >"$TMP/out" 2>"$TMP/err"; then
    printf 'expected deployment failure at %s\n' "$stage" >&2
    exit 1
  fi
  if grep -q 'Deployment ready' "$TMP/out"; then
    printf 'failed stage %s incorrectly claimed readiness\n' "$stage" >&2
    exit 1
  fi
  grep -q 'Deployment incomplete' "$TMP/err"
  case "$stage" in
    preflight|docker) assert_not_called '^compose build' ;;
    build) assert_not_called 'compose config --quiet' ;;
    compose-config) assert_not_called 'bootstrap_platform.R' ;;
    mariadb-health) assert_not_called 'bootstrap_platform.R' ;;
    reference-readiness) assert_not_called 'bootstrap_platform.R' ;;
    bootstrap) assert_not_called 'publish_reference_data.R' ;;
    reference-publication)
      assert_not_called 'run_platform_validation.R --publication'
      grep -q 'Resolve the Reference publication failure' "$TMP/err"
      ;;
    validation) grep -q 'bootstrap_platform.R' "$CALLS" ;;
  esac
done
unset FAIL_STAGE

if grep -E -q 'publish_reference_data|publish_planned_events' \
  "$ROOT/scripts/run_daily_platform.sh" \
  "$ROOT/scripts/run_platform_validation.sh" \
  "$ROOT/scripts/install_cron.sh"; then
  echo 'Reference publication must not be scheduled' >&2
  exit 1
fi

# Lock contention fails before preflight/build and leaves the existing lock.
mkdir -p "$TMP/deploy.lock"
if INFRASTRUCTURE_DIR="$TMP/infra" PLATFORM_DIR="$TMP/platform" \
  COMPOSE_WRAPPER="$TMP/bin/mock-compose" PREFLIGHT_SCRIPT="$TMP/bin/mock-preflight" \
  DOCKER_BIN="$TMP/bin/mock-docker" GIT_BIN="$TMP/bin/mock-git" \
  REFERENCE_READINESS_SCRIPT="$TMP/bin/mock-reference-readiness" \
  DEPLOY_LOG="$TMP/deploy.log" DEPLOY_LOCK_DIR="$TMP/deploy.lock" \
  DAILY_LOCK_DIR="$TMP/daily.lock" VALIDATION_LOCK_DIR="$TMP/validation.lock" \
  RESTORE_LOCK_DIR="$TMP/restore.lock" \
  "$ROOT/scripts/deploy_platform.sh" >"$TMP/out" 2>"$TMP/err"; then
  echo 'expected deployment lock contention failure' >&2
  exit 1
fi
grep -q 'Another deployment appears active' "$TMP/err"
[[ -d "$TMP/deploy.lock" ]]

printf '%s\n' 'deploy platform gate tests: passed'
