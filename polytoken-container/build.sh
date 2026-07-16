#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
echo "Building polytoken-dev:latest (DEV_UID=$(id -u))..."
# MCP Go servers are NOT baked — they run from source via `go run` wrappers over
# the mounted ~/workspace repos, so edits apply with no rebuild.
docker build --build-arg DEV_UID="$(id -u)" -t polytoken-dev:latest .
