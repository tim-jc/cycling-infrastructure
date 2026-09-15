#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_WRAPPER="${COMPOSE_WRAPPER:-$SCRIPT_DIR/compose.sh}"
PREFLIGHT_SCRIPT="${PREFLIGHT_SCRIPT:-$SCRIPT_DIR/preflight.sh}"
READER_SCRIPT="${READER_SCRIPT:-$SCRIPT_DIR/reconcile_grafana_reader.sh}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

"$PREFLIGHT_SCRIPT"
"$COMPOSE_WRAPPER" config --quiet
"$READER_SCRIPT"
"$COMPOSE_WRAPPER" pull grafana

image_ref="$($COMPOSE_WRAPPER config --images | grep '^grafana/grafana:' | head -1)"
[[ "$image_ref" == "grafana/grafana:13.2.1" ]] || {
  printf '[deploy-grafana] ERROR: unexpected image reference: %s\n' "$image_ref" >&2
  exit 1
}
architecture="$($DOCKER_BIN image inspect --format '{{.Architecture}}' "$image_ref")"
[[ "$architecture" == "arm64" ]] || {
  printf '[deploy-grafana] ERROR: image architecture is %s, expected arm64.\n' "$architecture" >&2
  exit 1
}

"$COMPOSE_WRAPPER" up -d grafana
container_id="$($COMPOSE_WRAPPER ps -q grafana)"
for _ in {1..30}; do
  health="$($DOCKER_BIN inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id")"
  [[ "$health" == "healthy" ]] && break
  [[ "$health" == "unhealthy" || "$health" == "exited" || "$health" == "dead" ]] && break
  sleep 2
done
[[ "${health:-unknown}" == "healthy" ]] || {
  printf '[deploy-grafana] ERROR: Grafana did not become healthy (%s).\n' "${health:-unknown}" >&2
  exit 1
}
"$READER_SCRIPT" --check-only
printf '[deploy-grafana] Grafana 13.2.1 is healthy; datasource and dashboard acceptance remain owner-verified through the authenticated LAN UI.\n'
