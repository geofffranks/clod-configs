#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
QUOTA_DIR="${POLYTOKEN_QUOTA_DIR:-$ROOT_DIR/../polytoken-quota}"
QUOTA_DIR="$(cd "$QUOTA_DIR" 2>/dev/null && pwd || true)"
DOCKER_BIN="${DOCKER_BIN:-podman}"

if [[ ! -f "$QUOTA_DIR/go.mod" || ! -d "$QUOTA_DIR/cmd/polytoken-quota" ]]; then
  echo "polytoken-quota checkout not found at $QUOTA_DIR" >&2
  echo "Set POLYTOKEN_QUOTA_DIR to a checkout containing go.mod and cmd/polytoken-quota." >&2
  exit 1
fi

echo "Building polytoken-dev:latest (DEV_UID=$(id -u), quota=$QUOTA_DIR)..."
# MCP servers are not baked or wrapped: every MCP lives behind the ratatoskr
# gateway on the macOS host (../ratatoskr/), reached over HTTP from containers.
cd "$SCRIPT_DIR"
DOCKER_BUILDKIT=1 "$DOCKER_BIN" build --no-cache \
  --build-arg DEV_UID="$(id -u)" \
  --build-context quota="$QUOTA_DIR" \
  -t polytoken-dev:latest \
  .
