#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANALYTICS_ROOT="$(cd "$ROOT/../cycling-analytics" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

cat >"$TMP/analytics.env" <<'ENV'
MARIADB_HOST=cycling-mariadb
MARIADB_PORT=9999
MARIADB_NAME=cycling_platform_gold
MARIADB_USER=analytics-test
MARIADB_PASSWORD=not-a-real-secret
CARTO_BASEMAP_API_KEY=not-a-real-key
ENV
chmod 600 "$TMP/analytics.env"

export CYCLING_PLATFORM_EXECUTION_HOST=cycling-test
export CYCLING_RUNTIME_UID=1234
export CYCLING_RUNTIME_GID=5678
export CYCLING_ANALYTICS_ENV_FILE="$TMP/analytics.env"

docker compose \
  --env-file "$ROOT/compose/.env.example" \
  --file "$ROOT/compose/docker-compose.yml" \
  config --format json >"$TMP/rendered.json"

jq -e --arg context "$ANALYTICS_ROOT" '
  .services["cycling-analytics"] as $analytics |
  ($analytics.build.context == $context) and
  ($analytics.build.dockerfile == "Dockerfile") and
  ($analytics.image == "cycling-analytics:dev") and
  ($analytics.restart == "no") and
  ($analytics.user == "1234:5678") and
  ($analytics.depends_on.mariadb.condition == "service_healthy") and
  ($analytics.environment.MARIADB_HOST == "mariadb") and
  ($analytics.environment.MARIADB_PORT == "3306") and
  ($analytics.environment.MARIADB_NAME == "cycling_platform_gold") and
  ($analytics.environment.CARTO_BASEMAP_API_KEY == "not-a-real-key") and
  ($analytics.volumes | any(
    .type == "bind" and
    .source == "/srv/cycling/data/analytics/output" and
    .target == "/app/output"
  )) and
  ($analytics.networks.default == null)
' "$TMP/rendered.json" >/dev/null

if ! jq -e '
  .services["cloudflare-pages-publisher"] as $publisher |
  ($publisher.image == "cycling-cloudflare-pages-publisher:wrangler-4.33.1") and
  ($publisher.restart == "no") and ($publisher.read_only == true) and
  ($publisher.working_dir == "/tmp") and
  ($publisher.tmpfs == ["/tmp"]) and
  ($publisher.command == ["pages", "deploy", "/site", "--project-name", "cycling-analytics"]) and
  ($publisher.environment.CLOUDFLARE_API_TOKEN == null) and
  ($publisher.environment.CLOUDFLARE_ACCOUNT_ID == null) and
  ($publisher.volumes | any(.source == "/srv/cycling/data/analytics/output" and .target == "/site" and .read_only == true))
' "$TMP/rendered.json" >/dev/null; then
  echo 'rendered publisher service does not preserve the complete Cloudflare Pages command and isolation contract' >&2
  exit 1
fi

# The dedicated env file must not leak analytics-only values into peer services.
jq -e '
  (.services.mariadb.environment.CARTO_BASEMAP_API_KEY == null) and
  (.services["cycling-platform"].environment.CARTO_BASEMAP_API_KEY == null) and
  (.services.mariadb.environment.MARIADB_NAME == null) and
  (.services["cycling-platform"].environment.MARIADB_NAME == null)
' "$TMP/rendered.json" >/dev/null

# Existing service contracts remain intact.
jq -e '
  (.services.mariadb.image == "mariadb:11") and
  (.services.mariadb.restart == "unless-stopped") and
  (.services["cycling-platform"].image == "cycling-platform:dev") and
  (.services["cycling-platform"].restart == "no") and
  (.services["cycling-platform"].user == "1234:5678") and
  (.services["cycling-platform"].depends_on.mariadb.condition == "service_healthy")
' "$TMP/rendered.json" >/dev/null

# Literal Compose interpolation contract; expansion is intentionally disabled.
# shellcheck disable=SC2016
grep -Fq '${CYCLING_ANALYTICS_ENV_FILE:-/srv/cycling/config/analytics/runtime.Renviron}' \
  "$ROOT/compose/docker-compose.yml"
if grep -Eq 'CARTO_BASEMAP_API_KEY:[[:space:]]+[^$]' "$ROOT/compose/docker-compose.yml"; then
  echo 'analytics secret value must not be committed in Compose' >&2
  exit 1
fi

grep -Fq 'FROM node:22.18.0-bookworm-slim' "$ROOT/compose/cloudflare-pages-publisher/Dockerfile"
grep -Fq 'WRANGLER_VERSION=4.33.1' "$ROOT/compose/cloudflare-pages-publisher/Dockerfile"
grep -Fxq 'ENTRYPOINT ["wrangler"]' "$ROOT/compose/cloudflare-pages-publisher/Dockerfile"
if grep -Eq '^[[:space:]]*CMD[[:space:]]' "$ROOT/compose/cloudflare-pages-publisher/Dockerfile"; then
  echo 'publisher image must not define production arguments; Compose owns the complete command' >&2
  exit 1
fi
if grep -R -q 'CLOUDFLARE_API_TOKEN=' "$ROOT/compose"; then
  echo 'Cloudflare token must not be present in Compose or publisher image' >&2
  exit 1
fi

printf '%s\n' 'analytics Compose tests: passed'
