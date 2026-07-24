#!/usr/bin/env bash
set -euo pipefail

PLATFORM_DIR="/home/tim/cycling-platform"
COMPOSE_DIR="/home/tim/cycling-infrastructure/compose"

echo "Updating cycling-platform..."
git -C "$PLATFORM_DIR" pull --ff-only

echo "Building cycling-platform image..."
cd "$COMPOSE_DIR"
docker compose build cycling-platform

echo "Deployment complete."
docker compose images cycling-platform
