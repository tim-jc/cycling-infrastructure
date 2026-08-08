#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/compose" "$TMP/bin"
: >"$TMP/compose/.env"
: >"$TMP/compose/docker-compose.yml"

cat >"$TMP/bin/hostname" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' 'cycling-recovery-test'
MOCK
cat >"$TMP/bin/id" <<'MOCK'
#!/usr/bin/env bash
[[ "${MOCK_ID_MISSING:-}" != yes ]] || exit 1
if [[ "${MOCK_ID_INVALID:-}" == yes ]]; then printf '%s\n' invalid; exit 0; fi
case "$1" in -u) printf '%s\n' 1234 ;; -g) printf '%s\n' 5678 ;; *) exit 2 ;; esac
MOCK
cat >"$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf 'host=%s uid=%s gid=%s args=' \
  "${CYCLING_PLATFORM_EXECUTION_HOST:-}" \
  "${CYCLING_PLATFORM_RUNTIME_UID:-}" \
  "${CYCLING_PLATFORM_RUNTIME_GID:-}" >"$MOCK_COMPOSE_CALL"
printf '%q ' "$@" >>"$MOCK_COMPOSE_CALL"
printf '\n' >>"$MOCK_COMPOSE_CALL"
MOCK
chmod 700 "$TMP/bin/"*
export MOCK_COMPOSE_CALL="$TMP/call"

COMPOSE_DIR="$TMP/compose" DOCKER_BIN="$TMP/bin/docker" \
  COMPOSE_HOSTNAME_BIN="$TMP/bin/hostname" COMPOSE_ID_BIN="$TMP/bin/id" \
  "$ROOT/scripts/compose.sh" config --quiet
grep -q 'host=cycling-recovery-test uid=1234 gid=5678' "$TMP/call"
grep -q 'compose .*--project-directory .*--env-file .*--file .*config --quiet' "$TMP/call"

if MOCK_ID_MISSING=yes COMPOSE_DIR="$TMP/compose" DOCKER_BIN="$TMP/bin/docker" \
  COMPOSE_HOSTNAME_BIN="$TMP/bin/hostname" COMPOSE_ID_BIN="$TMP/bin/id" \
  "$ROOT/scripts/compose.sh" config --quiet >"$TMP/out" 2>"$TMP/err"; then
  echo 'missing tim account unexpectedly passed' >&2; exit 1
fi
grep -q 'required tim account is unavailable' "$TMP/err"

if MOCK_ID_INVALID=yes COMPOSE_DIR="$TMP/compose" DOCKER_BIN="$TMP/bin/docker" \
  COMPOSE_HOSTNAME_BIN="$TMP/bin/hostname" COMPOSE_ID_BIN="$TMP/bin/id" \
  "$ROOT/scripts/compose.sh" config --quiet >"$TMP/out" 2>"$TMP/err"; then
  echo 'invalid tim UID/GID unexpectedly passed' >&2; exit 1
fi
grep -q 'valid numeric UID/GID' "$TMP/err"

# Project Compose parsing may occur only through the canonical contract.
direct_callers="$(rg -l 'docker compose|"\$DOCKER_BIN" compose' "$ROOT/scripts" | sort)"
expected_callers="$(printf '%s\n' \
  "$ROOT/scripts/compose_contract.sh" \
  "$ROOT/scripts/install_docker.sh" | sort)"
[[ "$direct_callers" == "$expected_callers" ]] || {
  printf 'unexpected direct Compose caller(s):\n%s\n' "$direct_callers" >&2
  exit 1
}

printf '%s\n' 'Compose runtime contract tests: passed'
