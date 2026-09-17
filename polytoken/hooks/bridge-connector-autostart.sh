#!/usr/bin/env bash
# bridge-connector-autostart.sh — session_start hook that auto-starts the
# Discord bridge connector inside every polytoken-dev container launch.
#
# Fail-open invariance: this hook ALWAYS emits {outcome:"allow"} and exits 0
# in a few milliseconds, in every case (host session, container with/without
# bridge env, missing python/venv/launcher, any launcher failure). It never
# blocks, aborts, or slows a Polytoken session. All real work is deferred to a
# detached launcher child.
#
# Stdio discipline is load-bearing: `session_start` is blocking (30s deadline
# per handler) and must complete in ~ms, and both harnesses read this hook's
# stdout until EOF. The detached child redirects stdin to /dev/null and stdout
# + stderr into the persistent log *in the same setsid/nohup invocation*, so
# this hook's stdout pipe reaches EOF the moment the hook exits. Holding the
# pipe open for the child's lifetime would time the hook out and block the
# session.
set -u

# Drain the session_start event JSON polytoken writes to stdin.
cat >/dev/null

# Container gate: no-op (bare allow) outside the container.
if [ "$(id -un 2>/dev/null)" != "dev" ] && [ ! -f /.dockerenv ]; then
  printf '%s\n' '{"outcome":"allow"}'
  exit 0
fi

# Bridge env gate: autostart is opt-in per container via --env-file.
if [ -z "${BRIDGE_RELAY_TOKEN:-}" ]; then
  printf '%s\n' '{"outcome":"allow"}'
  exit 0
fi

CONFIG_DIR="${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}"
LAUNCHER="$CONFIG_DIR/hooks/bridge-connector-launcher.sh"
SESSIONS_DIR="${POLYTOKEN_SESSIONS_DIR:-/home/dev/.local/share/polytoken}"
LOG_FILE="${BRIDGE_CONNECTOR_LOG:-$SESSIONS_DIR/bridge/connector.log}"

# Ensure the bridge dir + log exist before the child detaches into them.
# Failure here must never fail the hook.
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
: >>"$LOG_FILE" 2>/dev/null || true

# Detach one launcher per session. setsid gives the child its own session so it
# survives this hook's exit; nohup is the same-shape fallback on hosts without
# setsid. The launcher owns the per-session flock, so a double session_start
# that spawns a second launcher fails the flock and exits 0 without a second
# connector.
if [ -x "$LAUNCHER" ]; then
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$LAUNCHER" >>"$LOG_FILE" 2>&1 </dev/null &
  else
    nohup bash "$LAUNCHER" >>"$LOG_FILE" 2>&1 </dev/null &
  fi
fi

# Exactly one allow line; the hook exits immediately.
printf '%s\n' '{"outcome":"allow"}'
exit 0
