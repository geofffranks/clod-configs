#!/usr/bin/env bash
# container-awareness.sh — session_start hook.
# Briefs the model when it is running inside the polytoken-dev Docker container,
# so it uses $HOME / container paths and respects the mount boundary. Emits
# additional_context only inside the container; a bare allow everywhere else.
set -euo pipefail

# Drain the session_start event JSON polytoken writes to stdin.
cat >/dev/null

if [[ "$(id -un 2>/dev/null)" == "dev" ]] || [[ -f /.dockerenv ]]; then
  jq -nc --arg ctx 'You are running inside the polytoken-dev Docker container (user "dev", $HOME=/home/dev).
- Mounted host paths (the only filesystem reachable): /home/dev/workspace (your repos), /home/dev/.config/polytoken (shared config), /home/dev/bin (scripts), and ~/.gitconfig (read-only include). All other host paths (e.g. /Users/...) are invisible. Prefer $HOME / ~ / /home/dev paths; never write /Users/<user> into code or config.
- Toolchain: python/node/go are managed by mise (honors .tool-versions); brew tools live at /home/linuxbrew/.linuxbrew/bin.
- The container is ephemeral (--rm): anything outside the mounted paths is lost on exit.
- The herdle lifecycle gatekeeper builds from source on first use (no prebuilt binary in the container). Lifecycle gates ARE enforced; the first gated tool call in a session takes a few seconds to compile, then the cached binary is near-instant.' \
    '{outcome:"allow",additional_context:$ctx}'
else
  jq -nc '{outcome:"allow"}'
fi
