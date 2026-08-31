#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

cat >"$TMP/analytics.env" <<'ENV'
MARIADB_HOST=mariadb
MARIADB_PORT=3306
MARIADB_NAME=cycling_platform_gold
MARIADB_USER=test
MARIADB_PASSWORD=test
CARTO_BASEMAP_API_KEY=test
ENV
chmod 0600 "$TMP/analytics.env"
CYCLING_PLATFORM_EXECUTION_HOST=cycling-test \
CYCLING_RUNTIME_UID="$(id -u)" \
CYCLING_RUNTIME_GID="$(id -g)" \
CYCLING_ANALYTICS_ENV_FILE="$TMP/analytics.env" \
CYCLING_ANALYTICS_OUTPUT_DIR="$TMP/site" \
docker compose \
  --env-file "$ROOT/compose/.env.example" \
  --file "$ROOT/compose/docker-compose.yml" \
  config --format json >"$TMP/rendered.json"
working_dir="$(jq -r '.services["cloudflare-pages-publisher"].working_dir // "/"' "$TMP/rendered.json")"

if ! docker info >/dev/null 2>&1; then
  printf '%s\n' 'Cloudflare publisher real-CLI runtime test: skipped (Docker daemon unavailable)'
  exit 0
fi

mkdir -p "$TMP/site"
cat >"$TMP/site/index.js" <<'FUNCTION'
export function onRequest() {
  return new Response("offline runtime check");
}
FUNCTION

docker build --quiet \
  --tag cycling-cloudflare-pages-publisher:wrangler-4.33.1 \
  "$ROOT/compose/cloudflare-pages-publisher" >/dev/null

output="$TMP/output"
if ! docker run --rm \
  --network none \
  --read-only \
  --tmpfs /tmp \
  --workdir "$working_dir" \
  --volume "$TMP/site:/site:ro" \
  cycling-cloudflare-pages-publisher:wrangler-4.33.1 \
  pages functions build /site --outfile /tmp/worker.js >"$output" 2>&1; then
  cat "$output" >&2
  exit 1
fi

if grep -Fq '/.wrangler/tmp' "$output"; then
  echo 'Wrangler attempted to initialise mutable state under the read-only root.' >&2
  exit 1
fi

printf '%s\n' 'Cloudflare publisher real-CLI runtime test: passed'
