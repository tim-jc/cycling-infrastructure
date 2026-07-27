#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

log() {
  printf '[install-docker] %s\n' "$*"
}

fail() {
  printf '[install-docker] ERROR: %s\n' "$*" >&2
  exit 1
}

if ! command -v sudo >/dev/null 2>&1; then
  fail "sudo is required to install and manage Docker."
fi

if [[ ! -r /etc/os-release ]]; then
  fail "Cannot identify the operating system: /etc/os-release is unavailable."
fi

# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
  debian|raspbian)
    ;;
  *)
    fail "Unsupported operating system '${ID:-unknown}'; expected Debian or Raspberry Pi OS."
    ;;
esac

if [[ -z "${VERSION_CODENAME:-}" ]]; then
  fail "VERSION_CODENAME is missing from /etc/os-release."
fi

architecture="$(dpkg --print-architecture)"
if [[ "$architecture" != "arm64" ]]; then
  fail "Unsupported architecture '$architecture'; cycling-prod requires arm64."
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  log "Docker Engine and the Compose plugin are already installed."
else
  if command -v docker >/dev/null 2>&1; then
    fail "Docker is installed but 'docker compose' is unavailable. Resolve the existing Docker installation before rerunning."
  fi

  log "Configuring Docker's official Debian package repository."
  temporary_key="$(mktemp)"
  temporary_source="$(mktemp)"
  cleanup() {
    rm -f -- "$temporary_key" "$temporary_source"
  }
  trap cleanup EXIT

  curl --fail --silent --show-error --location \
    https://download.docker.com/linux/debian/gpg \
    --output "$temporary_key"

  printf '%s\n' \
    'Types: deb' \
    'URIs: https://download.docker.com/linux/debian' \
    "Suites: $VERSION_CODENAME" \
    'Components: stable' \
    "Architectures: $architecture" \
    'Signed-By: /etc/apt/keyrings/docker.asc' \
    >"$temporary_source"

  sudo install -d -m 0755 /etc/apt/keyrings
  sudo install -m 0644 "$temporary_key" /etc/apt/keyrings/docker.asc
  sudo install -m 0644 "$temporary_source" /etc/apt/sources.list.d/docker.sources

  sudo apt-get update
  sudo apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  log "Docker Engine and the Compose plugin were installed."
fi

sudo systemctl enable --now docker

sudo docker info >/dev/null
sudo docker compose version >/dev/null

log "Docker daemon and Compose plugin are available."
