#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/pass.sh"
printf '#!/usr/bin/env bash\nexit 19\n' >"$TMP/fail.sh"
printf '#!/usr/bin/env bash\ntouch %q\n' "$TMP/should-not-run" >"$TMP/not-run.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nfalse\ntouch %q\n' "$TMP/false-passed" >"$TMP/strict-child.sh"
chmod 0700 "$TMP/"*.sh

set +e
"$ROOT/tests/run_all.sh" "$TMP/pass.sh" "$TMP/fail.sh" "$TMP/not-run.sh" >/dev/null 2>&1
result=$?
set -e

[[ "$result" == 19 ]] || { echo "aggregate test harness did not preserve the failing test status: $result" >&2; exit 1; }
[[ ! -e "$TMP/should-not-run" ]] || { echo 'aggregate test harness continued after a failure' >&2; exit 1; }

set +e
"$TMP/strict-child.sh" >/dev/null 2>&1
result=$?
set -e
[[ "$result" != 0 ]] || { echo 'strict child test converted a failed assertion into success' >&2; exit 1; }
[[ ! -e "$TMP/false-passed" ]] || { echo 'strict child test continued to a false-positive completion marker' >&2; exit 1; }

for test_file in "$ROOT"/tests/test_*.sh; do
  sed -n '2p' "$test_file" | grep -Fxq 'set -euo pipefail' || {
    echo "test script lacks the strict failure contract: $test_file" >&2
    exit 1
  }
done

printf '%s\n' 'aggregate test harness regression: passed'
