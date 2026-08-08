#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/recovery"

printf '%s\n' 'AGE-SECRET-KEY-TEST' >"$TMP/identity.txt"
chmod 600 "$TMP/identity.txt"
printf '%s\n' \
  'STRAVA_REFRESH_TOKEN=strava-secret-test-value' \
  'GOOGLE_HEALTH_REFRESH_TOKEN=google-secret-test-value' >"$TMP/source.Renviron"
chmod 600 "$TMP/source.Renviron"
export MOCK_RUNTIME_SOURCE="$TMP/source.Renviron"
export MOCK_RESTORE_CAPTURE="$TMP/restored.Renviron"
export MOCK_SSH_CALLS="$TMP/ssh-calls"
hash_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

cat >"$TMP/bin/age" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output=""; input=""
while (( $# )); do
  case "$1" in
    --recipient|--identity) shift 2 ;;
    --decrypt) shift ;;
    --output) output="$2"; shift 2 ;;
    *) input="$1"; shift ;;
  esac
done
[[ "${MOCK_AGE_FAIL:-}" != yes ]] || exit 9
cp "$input" "$output"
MOCK

cat >"$TMP/bin/scp" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -p ]]; then
  cp "$2" "$MOCK_RESTORE_CAPTURE"
else
  cp "$MOCK_RUNTIME_SOURCE" "$2"
fi
MOCK

cat >"$TMP/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_SSH_CALLS"
if [[ "$*" == *'bash -s --'* ]]; then
  remote_script="$(cat)"
  if [[ "${MOCK_REMOTE_ROOT_OWNED:-}" == yes ]]; then
    printf '%s\n' '[verify-runtime-credentials] ERROR: Runtime credential file must be tim:tim mode 0600.' >&2
    exit 1
  fi
  if [[ "$remote_script" == *'Atomic credential replacement completed'* ]]; then
    printf '%s\n' '[restore-runtime-credentials] Atomic credential replacement completed.'
  else
    printf '%s\n' '[verify-runtime-credentials] STRAVA_REFRESH_TOKEN: present'
    printf '%s\n' '[verify-runtime-credentials] GOOGLE_HEALTH_REFRESH_TOKEN: present'
    printf '%s\n' '[verify-runtime-credentials] Target metadata and credential presence verified.'
  fi
fi
MOCK
chmod 700 "$TMP/bin/"*

if SSH_BIN="$TMP/bin/ssh" "$ROOT/scripts/verify_runtime_credentials.sh" \
  --target root@cycling-recovery-test.local \
  --expected-hostname cycling-recovery-test >"$TMP/out" 2>"$TMP/err"; then
  echo 'non-tim recovery target unexpectedly passed validation' >&2; exit 1
fi
grep -q 'form tim@host' "$TMP/err"

ciphertext="$TMP/recovery/runtime.Renviron.age"
AGE_BIN="$TMP/bin/age" SCP_BIN="$TMP/bin/scp" SSH_BIN="$TMP/bin/ssh" \
  "$ROOT/scripts/backup_runtime_credentials.sh" \
  --recipient age1testrecipient --identity "$TMP/identity.txt" \
  --output "$ciphertext" >"$TMP/out"
[[ -s "$ciphertext" && -s "$ciphertext.metadata" ]]
[[ "$(stat -c '%a' "$ciphertext" 2>/dev/null || stat -f '%Lp' "$ciphertext")" == 600 ]]
grep -q '^ciphertext_sha256=[0-9a-f]\{64\}$' "$ciphertext.metadata"
grep -q 'cryptographically verified' "$TMP/out"
if grep -q 'strava-secret-test-value\|google-secret-test-value' "$TMP/out" "$ciphertext.metadata"; then
  echo 'backup output exposed a credential value' >&2; exit 1
fi

compliant_digest="$(hash_file "$ciphertext")"
if MOCK_REMOTE_ROOT_OWNED=yes AGE_BIN="$TMP/bin/age" SCP_BIN="$TMP/bin/scp" SSH_BIN="$TMP/bin/ssh" \
  "$ROOT/scripts/backup_runtime_credentials.sh" --recipient age1testrecipient \
  --identity "$TMP/identity.txt" --output "$ciphertext" >"$TMP/out" 2>"$TMP/err"; then
  echo 'backup accepted a root-owned remote runtime file' >&2; exit 1
fi
grep -q 'must be tim:tim mode 0600' "$TMP/err"
[[ "$(hash_file "$ciphertext")" == "$compliant_digest" ]]

before_digest="$(hash_file "$ciphertext")"
printf '%s\n' 'STRAVA_REFRESH_TOKEN=still-secret' >"$TMP/source.Renviron"
chmod 600 "$TMP/source.Renviron"
if AGE_BIN="$TMP/bin/age" SCP_BIN="$TMP/bin/scp" SSH_BIN="$TMP/bin/ssh" \
  "$ROOT/scripts/backup_runtime_credentials.sh" --recipient age1testrecipient \
  --identity "$TMP/identity.txt" --output "$ciphertext" >"$TMP/out" 2>"$TMP/err"; then
  echo 'backup with a missing token unexpectedly passed' >&2; exit 1
fi
grep -q 'GOOGLE_HEALTH_REFRESH_TOKEN' "$TMP/err"
[[ "$(hash_file "$ciphertext")" == "$before_digest" ]]
printf '%s\n' \
  'STRAVA_REFRESH_TOKEN=strava-secret-test-value' \
  'GOOGLE_HEALTH_REFRESH_TOKEN=google-secret-test-value' >"$TMP/source.Renviron"
chmod 600 "$TMP/source.Renviron"

AGE_BIN="$TMP/bin/age" "$ROOT/scripts/verify_runtime_credentials.sh" \
  --ciphertext "$ciphertext" --identity "$TMP/identity.txt" >"$TMP/out"
grep -q 'Ciphertext digest and decryption verified' "$TMP/out"
grep -q 'STRAVA_REFRESH_TOKEN: present' "$TMP/out"
if grep -q 'secret-test-value' "$TMP/out"; then echo 'verification exposed a credential value' >&2; exit 1; fi

cp "$ciphertext" "$TMP/ciphertext.before"
printf '%s\n' corrupt >>"$ciphertext"
if AGE_BIN="$TMP/bin/age" "$ROOT/scripts/verify_runtime_credentials.sh" --ciphertext "$ciphertext" --identity "$TMP/identity.txt" >"$TMP/out" 2>"$TMP/err"; then
  echo 'corrupt ciphertext passed verification' >&2; exit 1
fi
grep -q 'does not match its metadata' "$TMP/err"
mv "$TMP/ciphertext.before" "$ciphertext"

if AGE_BIN="$TMP/bin/age" SCP_BIN="$TMP/bin/scp" SSH_BIN="$TMP/bin/ssh" \
  "$ROOT/scripts/restore_runtime_credentials.sh" --ciphertext "$ciphertext" \
  --identity "$TMP/identity.txt" --target tim@cycling-recovery-test.local \
  --expected-hostname cycling-recovery-test >"$TMP/out" 2>"$TMP/err"; then
  echo 'restore without confirmation unexpectedly passed' >&2; exit 1
fi
grep -q -- '--confirm-replace' "$TMP/err"

: >"$TMP/ssh-calls"
AGE_BIN="$TMP/bin/age" SCP_BIN="$TMP/bin/scp" SSH_BIN="$TMP/bin/ssh" \
  "$ROOT/scripts/restore_runtime_credentials.sh" --ciphertext "$ciphertext" \
  --identity "$TMP/identity.txt" --target tim@cycling-recovery-test.local \
  --expected-hostname cycling-recovery-test --confirm-replace >"$TMP/out"
cmp -s "$TMP/source.Renviron" "$TMP/restored.Renviron"
grep -q 'Restore and post-restore verification completed' "$TMP/out"
grep -q 'Target metadata and credential presence verified' "$TMP/out"
if grep -q 'secret-test-value' "$TMP/out"; then echo 'restore output exposed a credential value' >&2; exit 1; fi

# Static remote contracts: exact host assertion, dedicated directory, atomic move and metadata checks.
grep -q 'hostname -s' "$ROOT/scripts/restore_runtime_credentials.sh"
grep -q 'mv -f --.*runtime_path' "$ROOT/scripts/restore_runtime_credentials.sh"
grep -q 'install -m 0600' "$ROOT/scripts/restore_runtime_credentials.sh"
grep -q "stat -c '%U:%G'.*candidate" "$ROOT/scripts/restore_runtime_credentials.sh"
grep -q "mode 0700" "$ROOT/scripts/verify_runtime_credentials.sh"
grep -q "mode 0600" "$ROOT/scripts/verify_runtime_credentials.sh"

printf '%s\n' 'runtime credential workflow tests: passed'
