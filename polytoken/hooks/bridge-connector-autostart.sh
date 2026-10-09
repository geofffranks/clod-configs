#!/usr/bin/env bash
# Start the native Discord connector without delaying session startup.
# Every failure is intentionally fail-open: session_start always receives one allow.
set -u
printf '%s\n' '{"outcome":"allow"}'
[ "${POLYTOKEN_BRIDGE_ENABLE:-0}" = 1 ] || exit 0

CONFIG="${BRIDGE_CONNECTOR_CONFIG:-$HOME/.config/polytoken/discord-bridge/connector.json}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="${BRIDGE_CONNECTOR_LAUNCHER:-$HERE/bridge-connector-launcher.sh}"
export BRIDGE_CONNECTOR_SYSTEM_PYTHON="${BRIDGE_CONNECTOR_SYSTEM_PYTHON:-${BRIDGE_HOST_PYTHON:-}}"
# The event's ID is authoritative. Never discover another/newest session.
SID="${POLYTOKEN_SESSION_ID:-}"
[ -n "$SID" ] || exit 0
[ -x "$LAUNCHER" ] || exit 0
# Detached stdio is essential: do not hold Polytoken's blocking hook pipe open.
nohup "$LAUNCHER" "$CONFIG" "$SID" </dev/null >/dev/null 2>&1 &
exit 0
