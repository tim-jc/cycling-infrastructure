#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if (( $# )); then
  tests=("$@")
else
  tests=("$TEST_DIR"/test_*.sh)
fi

for test_file in "${tests[@]}"; do
  printf 'RUN %s\n' "$test_file"
  bash "$test_file"
done

printf '%s\n' 'all infrastructure tests: passed'
