#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; TMP="$(mktemp -d)"; trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/infra/.git" "$TMP/analytics/.git" "$TMP/analytics/tests" "$TMP/bin" "$TMP/output"
printf '%s\n' 'FROM scratch' 'RUN Rscript tests/smoke_check.R' >"$TMP/analytics/Dockerfile"; : >"$TMP/analytics/tests/smoke_check.R"
printf '%s\n' 'MARIADB_NAME=cycling_platform_gold' 'MARIADB_USER=analytics' 'MARIADB_PASSWORD=test-secret-value' 'CARTO_BASEMAP_API_KEY=test-carto-value' >"$TMP/runtime.env"; chmod 600 "$TMP/runtime.env"
CALLS="$TMP/calls"; export CALLS FAIL_STAGE=""
cat >"$TMP/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$CALLS"; [[ "$1" == -C ]] || exit 2; repo="$2"; shift 2
case "$1 $2" in
  'status --porcelain') [[ "${FAIL_STAGE:-}" == dirty-infra && "$repo" == *infra ]] && printf ' M file\n'; [[ "${FAIL_STAGE:-}" == dirty-analytics && "$repo" == *analytics ]] && printf ' M file\n' ;;
  'remote get-url') if [[ "${FAIL_STAGE:-}" == bad-origin ]]; then printf '%s\n' https://example.invalid/wrong.git; else printf '%s\n' https://github.com/tim-jc/cycling-analytics.git; fi ;;
  'fetch origin') [[ "${FAIL_STAGE:-}" != fetch ]] ;;
  'rev-parse HEAD') [[ "$repo" == *infra ]] && printf '%s\n' infra-sha || printf '%s\n' analytics-sha ;;
  'rev-parse --verify') printf '%s\n' analytics-sha ;;
  'checkout --detach') [[ "$3" == analytics-sha ]] ;;
  *) printf 'unexpected git call: %s\n' "$*" >&2; exit 2 ;;
esac
MOCK
cat >"$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$CALLS"
case "$1 ${2:-}" in 'info ') [[ "${FAIL_STAGE:-}" != docker ]] ;; 'image inspect') printf '%s\n' sha256:analytics-image-id ;; *) exit 2 ;; esac
MOCK
cat >"$TMP/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' cycling-prod
MOCK
cat >"$TMP/bin/compose" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'compose %s\n' "$*" >>"$CALLS"
case "$1 ${2:-}" in
  'build cycling-analytics') [[ "${FAIL_STAGE:-}" != build ]] ;;
  'config --images') printf '%s\n' cycling-analytics:dev ;;
  'config --quiet') [[ "${FAIL_STAGE:-}" != compose-config ]] ;;
  *) printf 'unexpected compose call: %s\n' "$*" >&2; exit 2 ;;
esac
MOCK
chmod 700 "$TMP/bin/"*
owner="$(stat -c '%U:%G' "$TMP/output" 2>/dev/null || stat -f '%Su:%Sg' "$TMP/output")"
invoke(){ INFRASTRUCTURE_DIR="$TMP/infra" ANALYTICS_DIR="$TMP/analytics" COMPOSE_WRAPPER="$TMP/bin/compose" DOCKER_BIN="$TMP/bin/docker" GIT_BIN="$TMP/bin/git" HOSTNAME_BIN="$TMP/bin/hostname" DEPLOY_LOG="$TMP/deploy.log" DEPLOY_LOCK_DIR="$TMP/deploy.lock" RENDER_LOCK_DIR="$TMP/render.lock" RESTORE_LOCK_DIR="$TMP/restore.lock" ANALYTICS_ENV_FILE="$TMP/runtime.env" ANALYTICS_OUTPUT_DIR="$TMP/output" EXPECTED_RUNTIME_OWNER="$owner" "$ROOT/scripts/deploy_analytics.sh" "$@"; }
run_deploy(){ : >"$CALLS"; rmdir "$TMP/deploy.lock" 2>/dev/null || true; invoke "$@"; }
assert_clean_lock(){ [[ ! -d "$TMP/deploy.lock" ]] || { echo 'deployment lock leaked' >&2; exit 1; }; }

run_deploy >"$TMP/out"; assert_clean_lock
grep -q 'git .* fetch origin --prune --tags' "$CALLS"; grep -Fq 'rev-parse --verify origin/main^{commit}' "$CALLS"; grep -q 'checkout --detach analytics-sha' "$CALLS"
grep -q '^compose build cycling-analytics$' "$CALLS"; grep -q '^compose config --quiet$' "$CALLS"; grep -q 'docker image inspect.*cycling-analytics:dev' "$CALLS"
grep -q 'Image ID: sha256:analytics-image-id' "$TMP/out"; grep -q 'deployment_status: ready' "$TMP/deploy.log"; grep -q 'image_smoke_test_result: passed' "$TMP/deploy.log"; grep -q 'production_render_result: not-run' "$TMP/deploy.log"
if grep -Eq 'compose run|render_dashboard|bootstrap_platform|publish|validation|cron|schedule' "$CALLS"; then echo 'deployment crossed its non-rendering boundary' >&2; exit 1; fi
if grep -Eq 'test-secret-value|test-carto-value' "$TMP/deploy.log" "$TMP/out"; then echo 'deployment evidence leaked a secret' >&2; exit 1; fi

run_deploy --ref release-test >"$TMP/out"; grep -Fq 'rev-parse --verify release-test^{commit}' "$CALLS"; grep -q 'requested_ref: release-test' "$TMP/deploy.log"
for stage in dirty-infra dirty-analytics bad-origin docker fetch build compose-config; do export FAIL_STAGE="$stage"; if run_deploy >"$TMP/out" 2>"$TMP/err"; then echo "expected failure: $stage" >&2; exit 1; fi; assert_clean_lock; grep -q 'Deployment incomplete' "$TMP/err"; done
unset FAIL_STAGE

mkdir "$TMP/deploy.lock"; if invoke >"$TMP/out" 2>"$TMP/err"; then echo 'existing deployment lock accepted' >&2; exit 1; fi; [[ -d "$TMP/deploy.lock" ]]; rmdir "$TMP/deploy.lock"
for lock in render restore; do mkdir "$TMP/$lock.lock"; if invoke >"$TMP/out" 2>"$TMP/err"; then echo "$lock lock accepted" >&2; exit 1; fi; assert_clean_lock; rmdir "$TMP/$lock.lock"; done
mkdir "$TMP/platform-daily.lock" "$TMP/platform-validation.lock" "$TMP/platform-deployment.lock"; run_deploy >"$TMP/out"; assert_clean_lock; rmdir "$TMP/platform-daily.lock" "$TMP/platform-validation.lock" "$TMP/platform-deployment.lock"

printf '%s\n' 'MARIADB_HOST=cycling-mariadb' >>"$TMP/runtime.env"; if run_deploy >"$TMP/out" 2>"$TMP/err"; then echo 'Compose-owned endpoint accepted in runtime env' >&2; exit 1; fi; assert_clean_lock; grep -q 'MARIADB_HOST is Compose-owned' "$TMP/err"
printf '%s\n' 'analytics deployment tests: passed'
