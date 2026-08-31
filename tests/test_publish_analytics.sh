#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
# shellcheck disable=SC2154
trap 'test_status=$?; rm -rf -- "$TMP"; exit "$test_status"' EXIT
mkdir -p "$TMP/bin" "$TMP/output/index_files"
printf '<html>dashboard</html>\n' >"$TMP/output/index.html"
printf 'dependency\n' >"$TMP/output/index_files/app.js"
printf 'CLOUDFLARE_ACCOUNT_ID=a3bd40c6603f35a6c5baf7952c167823\nCLOUDFLARE_API_TOKEN=publisher-test-secret\n' >"$TMP/cloudflare.env"
chmod 0600 "$TMP/cloudflare.env"
CALLS="$TMP/calls"; export CALLS
cat >"$TMP/bin/compose" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$CLOUDFLARE_ACCOUNT_ID" == a3bd40c6603f35a6c5baf7952c167823 ]]
[[ "$CLOUDFLARE_API_TOKEN" == publisher-test-secret ]]
printf 'compose %s account-ok token-present\n' "$*" >>"$CALLS"
exit "${PUBLISH_STATUS:-0}"
MOCK
chmod 0700 "$TMP/bin/compose"
invoke(){
  ANALYTICS_OUTPUT_DIR="$TMP/output" \
  CLOUDFLARE_CREDENTIAL_FILE="$TMP/cloudflare.env" \
  EXPECTED_CLOUDFLARE_CREDENTIAL_OWNER="${EXPECTED_CLOUDFLARE_CREDENTIAL_OWNER:-$(id -un):$(id -gn)}" \
  COMPOSE_WRAPPER="$TMP/bin/compose" \
  RENDER_LOCK_DIR="$TMP/render.lock" \
  DEPLOY_LOCK_DIR="$TMP/deploy.lock" \
  RESTORE_LOCK_DIR="$TMP/restore.lock" \
  "$ROOT/scripts/publish_analytics.sh" "$@"
}
reset_fixture(){
  : >"$CALLS"; rm -rf "$TMP/render.lock" "$TMP/deploy.lock" "$TMP/restore.lock" "$TMP/output/index_files"
  mkdir -p "$TMP/output/index_files"; printf 'dependency\n' >"$TMP/output/index_files/app.js"
  printf '<html>dashboard</html>\n' >"$TMP/output/index.html"
  printf 'CLOUDFLARE_ACCOUNT_ID=a3bd40c6603f35a6c5baf7952c167823\nCLOUDFLARE_API_TOKEN=publisher-test-secret\n' >"$TMP/cloudflare.env"; chmod 0600 "$TMP/cloudflare.env"
}
reset_fixture; invoke >"$TMP/out" 2>"$TMP/err"
grep -Fxq 'compose run --rm --no-deps --env CLOUDFLARE_ACCOUNT_ID --env CLOUDFLARE_API_TOKEN cloudflare-pages-publisher account-ok token-present' "$CALLS"
[[ ! -d "$TMP/render.lock" ]]
grep -q 'project cycling-analytics' "$TMP/out"
if grep -R -q 'publisher-test-secret' "$TMP/out" "$TMP/err" "$CALLS"; then echo 'publisher leaked token' >&2; exit 1; fi

reset_fixture; rm "$TMP/cloudflare.env"
if invoke >"$TMP/out" 2>"$TMP/err"; then echo 'missing credentials accepted' >&2; exit 1; fi
[[ ! -s "$CALLS" && ! -d "$TMP/render.lock" ]]

reset_fixture; chmod 0644 "$TMP/cloudflare.env"
if invoke >"$TMP/out" 2>"$TMP/err"; then echo 'unsafe credential mode accepted' >&2; exit 1; fi
[[ ! -s "$CALLS" ]]

reset_fixture
if EXPECTED_CLOUDFLARE_CREDENTIAL_OWNER=nobody:nogroup invoke >"$TMP/out" 2>"$TMP/err"; then echo 'wrong credential owner accepted' >&2; exit 1; fi
[[ ! -s "$CALLS" ]]

reset_fixture; printf 'CLOUDFLARE_API_TOKEN=publisher-test-secret\n' >"$TMP/cloudflare.env"
if invoke >"$TMP/out" 2>"$TMP/err"; then echo 'missing account ID accepted' >&2; exit 1; fi
[[ ! -s "$CALLS" ]]

reset_fixture; printf 'CLOUDFLARE_ACCOUNT_ID=a3bd40c6603f35a6c5baf7952c167823\nCLOUDFLARE_API_TOKEN=\n' >"$TMP/cloudflare.env"
if invoke >"$TMP/out" 2>"$TMP/err"; then echo 'missing token accepted' >&2; exit 1; fi
[[ ! -s "$CALLS" ]]

reset_fixture; printf 'CLOUDFLARE_ACCOUNT_ID=wrong\nCLOUDFLARE_API_TOKEN=publisher-test-secret\n' >"$TMP/cloudflare.env"
if invoke >"$TMP/out" 2>"$TMP/err"; then echo 'wrong account accepted' >&2; exit 1; fi
[[ ! -s "$CALLS" ]]

reset_fixture; rm "$TMP/output/index.html"
if invoke >"$TMP/out" 2>"$TMP/err"; then echo 'missing index accepted' >&2; exit 1; fi
[[ ! -s "$CALLS" ]]

reset_fixture; rm "$TMP/output/index_files/app.js"
if invoke >"$TMP/out" 2>"$TMP/err"; then echo 'empty dependencies accepted' >&2; exit 1; fi
[[ ! -s "$CALLS" ]]

reset_fixture
if PUBLISH_STATUS=17 invoke >"$TMP/out" 2>"$TMP/err"; then echo 'Wrangler failure accepted' >&2; exit 1; fi
grep -q 'status 17' "$TMP/err"; [[ ! -d "$TMP/render.lock" ]]

reset_fixture; mkdir "$TMP/render.lock"
if invoke >"$TMP/out" 2>"$TMP/err"; then echo 'concurrent render accepted' >&2; exit 1; fi
[[ -d "$TMP/render.lock" && ! -s "$CALLS" ]]
reset_fixture; mkdir "$TMP/render.lock"; invoke --from-refresh >"$TMP/out" 2>"$TMP/err"; [[ -d "$TMP/render.lock" ]]

printf '%s\n' 'analytics Cloudflare publisher tests: passed'
