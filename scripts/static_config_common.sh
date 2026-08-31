#!/usr/bin/env bash

static_required_keys=(MARIADB_USER MARIADB_PASSWORD MARIADB_ROOT_PASSWORD MARIADB_PORT STRAVA_CLIENT_ID STRAVA_CLIENT_SECRET GOOGLE_HEALTH_CLIENT_ID GOOGLE_HEALTH_CLIENT_SECRET NTFY_TOPIC CYCLING_ANALYTICS_NTFY_TOPIC)
static_forbidden_keys=(STRAVA_REFRESH_TOKEN GOOGLE_HEALTH_REFRESH_TOKEN CYCLING_PLATFORM_EXECUTION_HOST CYCLING_RUNTIME_UID CYCLING_RUNTIME_GID CYCLING_PLATFORM_RUNTIME_UID CYCLING_PLATFORM_RUNTIME_GID)
cloudflare_required_keys=(CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN)
CLOUDFLARE_CANONICAL_ACCOUNT_ID="a3bd40c6603f35a6c5baf7952c167823"

static_fail() { printf '[static-config] ERROR: %s\n' "$*" >&2; exit 1; }
static_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
static_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else static_fail 'Neither sha256sum nor shasum is available.'; fi
}
static_require() { command -v "$1" >/dev/null 2>&1 || static_fail "Required command is unavailable: $1"; }
static_safe_path() { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != */../* && "$1" != *'/..' ]] || static_fail "Unsafe absolute path: $1"; }
static_target() { [[ "$1" =~ ^tim@[A-Za-z0-9._:-]+$ ]] || static_fail 'Target must have the form tim@host.'; }
static_hostname() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || static_fail 'Expected hostname is invalid.'; }

static_value() {
  awk -F= -v key="$1" '$1 == key { value=substr($0,index($0,"=")+1); sub(/^[[:space:]]+/,"",value); sub(/[[:space:]]+$/,"",value); if ((substr(value,1,1)=="\"" && substr(value,length(value),1)=="\"") || (substr(value,1,1)=="\047" && substr(value,length(value),1)=="\047")) value=substr(value,2,length(value)-2); print value; exit }' "$2"
}

static_validate_plaintext() {
  local file="$1" key value unexpected
  [[ -f "$file" && ! -L "$file" && -s "$file" ]] || static_fail 'Static configuration plaintext is absent, empty, or unsafe.'
  [[ "$(static_mode "$file")" == 600 ]] || static_fail 'Static configuration plaintext must have mode 0600.'
  if [[ "${STATIC_CONFIG_PROFILE:-compose}" == cloudflare ]]; then
    for key in "${cloudflare_required_keys[@]}"; do
      [[ "$(grep -Ec "^[[:space:]]*${key}=" "$file" || true)" == 1 ]] ||
        static_fail "Required Cloudflare key must occur exactly once: $key"
      value="$(static_value "$key" "$file")"
      [[ -n "$value" ]] || static_fail "Required Cloudflare key is empty: $key"
    done
    [[ "$(static_value CLOUDFLARE_ACCOUNT_ID "$file")" == "$CLOUDFLARE_CANONICAL_ACCOUNT_ID" ]] ||
      static_fail 'Cloudflare account ID does not match the canonical production account.'
    unexpected="$(awk -F= '
      /^[[:space:]]*($|#)/ { next }
      $1 != "CLOUDFLARE_ACCOUNT_ID" && $1 != "CLOUDFLARE_API_TOKEN" { print $1; exit }
    ' "$file")"
    [[ -z "$unexpected" ]] || static_fail "Unexpected key is present in Cloudflare credential file: $unexpected"
    return 0
  fi
  [[ "${STATIC_CONFIG_PROFILE:-compose}" == compose ]] || static_fail 'Unknown static configuration profile.'
  for key in "${static_required_keys[@]}"; do
    value="$(static_value "$key" "$file")"
    [[ -n "$value" ]] || static_fail "Required static configuration key is missing or empty: $key"
  done
  for key in "${static_forbidden_keys[@]}"; do
    if grep -Eq "^[[:space:]]*${key}=" "$file"; then static_fail "Forbidden generated or mutable key is present: $key"; fi
  done
  [[ "$(static_value MARIADB_PORT "$file")" =~ ^[0-9]+$ ]] || static_fail 'MARIADB_PORT must be numeric.'
}

static_metadata_digest() {
  local file="$1" digest
  [[ -f "$file" && ! -L "$file" && "$(static_mode "$file")" == 600 ]] || static_fail 'Static configuration metadata is absent or not mode 0600.'
  grep -Fxq "format=cycling-static-${STATIC_CONFIG_PROFILE:-compose}-age-v1" "$file" || static_fail 'Static configuration metadata format is unsupported.'
  digest="$(awk -F= '$1=="ciphertext_sha256" {print $2; exit}' "$file")"
  [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || static_fail 'Static configuration metadata digest is invalid.'
  printf '%s\n' "$digest" | tr '[:upper:]' '[:lower:]'
}
