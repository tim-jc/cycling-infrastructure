#!/usr/bin/env bash

runtime_required_keys=(STRAVA_REFRESH_TOKEN GOOGLE_HEALTH_REFRESH_TOKEN)

runtime_fail() {
  printf '[runtime-credentials] ERROR: %s\n' "$*" >&2
  exit 1
}

runtime_require_command() {
  command -v "$1" >/dev/null 2>&1 || runtime_fail "Required command is unavailable: $1"
}

runtime_file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

runtime_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    runtime_fail "Neither sha256sum nor shasum is available."
  fi
}

runtime_validate_plaintext() {
  local path="$1" key
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || runtime_fail "Runtime credential plaintext is absent, empty, or unsafe."
  [[ "$(runtime_file_mode "$path")" == 600 ]] || runtime_fail "Runtime credential plaintext must have mode 0600."
  for key in "${runtime_required_keys[@]}"; do
    awk -F= -v key="$key" '
      $1 == key {
        value = substr($0, index($0, "=") + 1)
        if (length(value) > 0) found = 1
      }
      END { exit(found ? 0 : 1) }
    ' "$path" || runtime_fail "Required runtime credential key is missing or empty: $key"
  done
}

runtime_validate_target() {
  [[ "$1" =~ ^tim@[A-Za-z0-9._:-]+$ ]] || runtime_fail "Target must have the form tim@host using a safe hostname or address."
}

runtime_validate_absolute_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != */../* && "$1" != *'/..' ]] || runtime_fail "Path must be an absolute path containing only safe characters: $1"
}

runtime_read_metadata_digest() {
  local metadata="$1" digest
  [[ -f "$metadata" && ! -L "$metadata" ]] || runtime_fail "Ciphertext metadata is absent or unsafe: $metadata"
  [[ "$(runtime_file_mode "$metadata")" == 600 ]] || runtime_fail "Ciphertext metadata must have mode 0600."
  grep -Fxq 'format=cycling-runtime-credentials-age-v1' "$metadata" || runtime_fail "Ciphertext metadata format is unsupported."
  awk -F= '$1 == "backup_completed_at_utc" && $2 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ { found=1 } END { exit(found?0:1) }' "$metadata" || runtime_fail "Ciphertext metadata timestamp is missing or invalid."
  digest="$(awk -F= '$1 == "ciphertext_sha256" { print substr($0, index($0, "=") + 1); exit }' "$metadata")"
  [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || runtime_fail "Ciphertext metadata does not contain a valid SHA-256 digest."
  printf '%s\n' "$digest" | tr '[:upper:]' '[:lower:]'
}
