#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
echo "Building polytoken-dev:latest (DEV_UID=$(id -u))..."
# MCP servers are not baked or wrapped: every MCP lives behind the ratatoskr
# gateway on the macOS host (../ratatoskr/), reached over HTTP from containers.
docker build --no-cache --build-arg DEV_UID="$(id -u)" -t polytoken-dev:latest .
