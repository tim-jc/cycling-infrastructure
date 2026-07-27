#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

START_MARKER="# >>> CYCLING_PLATFORM_START >>>"
END_MARKER="# <<< CYCLING_PLATFORM_END <<<"
EXPECTED_USER="tim"
PRODUCTION_ROOT="/home/tim/cycling-infrastructure"
DAILY_SCRIPT="$PRODUCTION_ROOT/scripts/run_daily_platform.sh"
VALIDATION_SCRIPT="$PRODUCTION_ROOT/scripts/run_platform_validation.sh"
MODE="install"

usage() {
  cat <<'USAGE'
Usage: install_cron.sh [--dry-run|--show|--help]

  --dry-run  Print the complete crontab that would be installed.
  --show     Print only the canonical managed block.
  --help     Show this help.
USAGE
}

managed_block() {
  printf '%s\n' \
    "$START_MARKER" \
    "0 2 * * * $DAILY_SCRIPT" \
    "30 3 * * * $VALIDATION_SCRIPT" \
    "$END_MARKER"
}

fail() {
  printf '[install-cron] ERROR: %s\n' "$*" >&2
  exit 1
}

if (( $# > 1 )); then
  usage >&2
  exit 2
fi

if (( $# == 1 )); then
  case "$1" in
    --dry-run)
      MODE="dry-run"
      ;;
    --show)
      managed_block
      exit 0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
fi

if [[ "$(id -un)" != "$EXPECTED_USER" ]]; then
  fail "Run this script as '$EXPECTED_USER', not through sudo."
fi

command -v crontab >/dev/null 2>&1 || fail "crontab is unavailable; run scripts/bootstrap.sh first."

if [[ "$MODE" == "install" ]]; then
  repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  [[ "$repository_root" == "$PRODUCTION_ROOT" ]] ||
    fail "The infrastructure repository must be located at $PRODUCTION_ROOT."
  [[ -x "$DAILY_SCRIPT" ]] || fail "Required executable is missing: $DAILY_SCRIPT"
  [[ -x "$VALIDATION_SCRIPT" ]] || fail "Required executable is missing: $VALIDATION_SCRIPT"
fi

existing_file="$(mktemp)"
filtered_file="$(mktemp)"
proposed_file="$(mktemp)"
cleanup() {
  rm -f -- "$existing_file" "$filtered_file" "$proposed_file"
}
trap cleanup EXIT

if ! crontab -l >"$existing_file" 2>/dev/null; then
  : >"$existing_file"
fi

start_count="$(grep -Fxc "$START_MARKER" "$existing_file" || true)"
end_count="$(grep -Fxc "$END_MARKER" "$existing_file" || true)"
if [[ "$start_count" != "$end_count" ]]; then
  fail "Managed cron markers are unbalanced; repair the crontab manually before rerunning."
fi

if ! awk -v start="$START_MARKER" -v end="$END_MARKER" '
  $0 == start {
    if (in_managed_block) exit 1
    in_managed_block = 1
    next
  }
  $0 == end {
    if (!in_managed_block) exit 1
    in_managed_block = 0
    next
  }
  END { if (in_managed_block) exit 1 }
' "$existing_file"; then
  fail "Managed cron markers are malformed; repair the crontab manually before rerunning."
fi

awk -v start="$START_MARKER" -v end="$END_MARKER" '
  $0 == start { in_managed_block = 1; next }
  $0 == end { in_managed_block = 0; next }
  !in_managed_block { print }
' "$existing_file" >"$filtered_file"

# Remove trailing blank lines before appending one canonical block.
awk '
  { lines[NR] = $0 }
  $0 !~ /^[[:space:]]*$/ { last_content = NR }
  END {
    for (line = 1; line <= last_content; line++) {
      print lines[line]
    }
  }
' "$filtered_file" >"$proposed_file"

if [[ -s "$proposed_file" ]]; then
  printf '\n' >>"$proposed_file"
fi
managed_block >>"$proposed_file"

if cmp -s "$existing_file" "$proposed_file"; then
  printf '[install-cron] Managed cron block is already current; no changes made.\n'
  exit 0
fi

if [[ "$MODE" == "dry-run" ]]; then
  printf '[install-cron] Crontab would be updated to:\n'
  cat "$proposed_file"
  exit 0
fi

crontab "$proposed_file"
printf '[install-cron] Installed the cycling-platform managed cron block and preserved unrelated entries.\n'
