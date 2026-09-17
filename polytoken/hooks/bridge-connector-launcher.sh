#!/usr/bin/env bash
# bridge-connector-launcher.sh — detached connector launcher, child of the
# bridge-connector-autostart session_start hook.
#
# Runs in its own session (setsid/nohup) with stdio redirected into the
# persistent connector.log by the hook, so it never holds the hook's stdout
# pipe open for its own lifetime (session_start is blocking, 30s deadline).
# It owns the per-session flock: opened here as the FIRST action, kept through
# the readiness poll + venv ensure, and inherited across the exec of
# connector_main (the kernel lock then dies with the container, so a double
# session_start that spawns a second launcher fails the flock and exits 0
# without spawning a second connector).
#
# Order: flock (first) -> truncate/rotate log -> venv ensure -> identity ->
# readiness poll (1s x <=30s) -> exec connector_main. Every failure is logged
# loudly and exits nonzero; the session itself is never touched (fail-open).
#
# Secrecy: NO `set -x`, NO env dumps, never print BRIDGE_RELAY_TOKEN or any
# credential. The python binary is invoked by direct path. The log file is
# chmod 0600.
#
# Overrides (documented in polytoken-container/.env.example):
#   BRIDGE_CONNECTOR_PYTHON  absolute python to use instead of the venv
#   BRIDGE_VENV_DIR          connector venv (default $SESSIONS_DIR/bridge/venv)
#   BRIDGE_REPO_DIR          bridge repo checkout (default /Users/gfranks/workspace/discord-pt-stream)
#   BRIDGE_CONNECTOR_LOG     log path (default $SESSIONS_DIR/bridge/connector.log)
#   BRIDGE_CONNECTOR_LOG_KEEP         bounded log tail lines (default 2000)
#   BRIDGE_CONNECTOR_READY_ATTEMPTS   readiness poll attempts (default 30)
#   BRIDGE_CONNECTOR_READY_INTERVAL   readiness poll interval seconds (default 1)
set -u

SESSIONS_DIR="${POLYTOKEN_SESSIONS_DIR:-/home/dev/.local/share/polytoken}"
BRIDGE_DIR="$SESSIONS_DIR/bridge"
LOG_FILE="${BRIDGE_CONNECTOR_LOG:-$BRIDGE_DIR/connector.log}"
VENV_DIR="${BRIDGE_VENV_DIR:-$BRIDGE_DIR/venv}"
REPO_DIR="${BRIDGE_REPO_DIR:-/Users/gfranks/workspace/discord-pt-stream}"
PYPROJECT="$REPO_DIR/pyproject.toml"
FPRINT="$BRIDGE_DIR/pyproject.fingerprint"
LOCK="$BRIDGE_DIR/autostart.lock"
CONNECTOR_PYTHON="${BRIDGE_CONNECTOR_PYTHON:-}"
READY_ATTEMPTS="${BRIDGE_CONNECTOR_READY_ATTEMPTS:-30}"
READY_INTERVAL="${BRIDGE_CONNECTOR_READY_INTERVAL:-1}"
LOG_KEEP="${BRIDGE_CONNECTOR_LOG_KEEP:-2000}"

# Diagnostics go to stdout/stderr, which the hook redirected into the log, so
# they land in connector.log without a second pipe to manage. (When the launcher
# is run standalone for debugging, stdout is still where the messages appear.)
log() { printf '%s\n' "[bridge $(date -u +%FT%TZ)] $*" || true; }

mkdir -p "$BRIDGE_DIR" 2>/dev/null || true

# ---- 1. per-session flock (first action; kept through exec) ----
if command -v flock >/dev/null 2>&1; then
  if ! exec 9>"$LOCK" 2>/dev/null; then
    log "WARN cannot open $LOCK; continuing without dedupe"
  elif ! flock -n 9 2>/dev/null; then
    log "another connector launcher holds the lock for this container; exiting"
    exit 0
  fi
fi

# ---- 2. truncate/rotate connector.log to a bounded tail ----
if [ -f "$LOG_FILE" ]; then
  tail -n "$LOG_KEEP" "$LOG_FILE" >"${LOG_FILE}.tail" 2>/dev/null && \
    mv -f "${LOG_FILE}.tail" "$LOG_FILE" 2>/dev/null || rm -f "${LOG_FILE}.tail" 2>/dev/null || true
fi
: >>"$LOG_FILE" 2>/dev/null
chmod 600 "$LOG_FILE" 2>/dev/null

# Re-point our stdout/stderr at the current log inode: the rotation above may
# have replaced the file (mv), and the hook's detach redirect still points at
# the orphaned inode. With this, this launcher's diagnostics AND the exec'd
# connector both keep landing in connector.log even after a rotation.
exec >>"$LOG_FILE" 2>&1

log "launcher start (pid $$, session=${POLYTOKEN_SESSION_ID:-<unset>})"

# ---- 3. venv ensure (persistent, fingerprint-keyed, editable install) ----
# Returns 0 with CONNECTOR_PYTHON set to a working interpreter; fail-open.
ensure_venv() {
  if [ -n "$CONNECTOR_PYTHON" ]; then
    if [ -x "$CONNECTOR_PYTHON" ]; then
      log "using BRIDGE_CONNECTOR_PYTHON=$CONNECTOR_PYTHON"
      return 0
    fi
    log "WARN BRIDGE_CONNECTOR_PYTHON not executable: $CONNECTOR_PYTHON"
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || { log "WARN python3 unavailable"; return 1; }
  if [ ! -f "$PYPROJECT" ]; then
    log "WARN $PYPROJECT missing (set BRIDGE_REPO_DIR); cannot fingerprint; trying system python3"
    if python3 -c 'import discord_bridge.connector_main' >/dev/null 2>&1; then
      CONNECTOR_PYTHON="$(command -v python3)"
      return 0
    fi
    log "WARN discord_bridge not importable from system python3"
    return 1
  fi
  local fp
  fp="$(sha256sum "$PYPROJECT" 2>/dev/null | awk '{print $1}')-$(python3 -c 'import sys; print(sys.version_info[:2])' 2>/dev/null)"
  if [ -x "$VENV_DIR/bin/python" ] && [ -f "$FPRINT" ] \
     && [ "$(cat "$FPRINT" 2>/dev/null)" = "$fp" ] \
     && "$VENV_DIR/bin/python" -c 'import discord_bridge.connector_main, websockets, aiohttp' >/dev/null 2>&1; then
    CONNECTOR_PYTHON="$VENV_DIR/bin/python"
    log "venv current (fingerprint unchanged)"
    return 0
  fi
  if [ ! -x "$VENV_DIR/bin/python" ]; then
    log "creating venv at $VENV_DIR"
    python3 -m venv "$VENV_DIR" >>"$LOG_FILE" 2>&1 || { log "WARN venv creation failed"; return 1; }
  fi
  log "ensuring connector extra in $VENV_DIR (fingerprint $fp)"
  if ! "$VENV_DIR/bin/pip" install --quiet -e "$REPO_DIR[connector]" >>"$LOG_FILE" 2>&1; then
    log "WARN editable connector install failed (offline?); keeping existing venv"
  else
    printf '%s\n' "$fp" >"$FPRINT" 2>/dev/null || true
  fi
  if "$VENV_DIR/bin/python" -c 'import discord_bridge.connector_main, websockets, aiohttp' >/dev/null 2>&1; then
    CONNECTOR_PYTHON="$VENV_DIR/bin/python"
    return 0
  fi
  log "WARN connector not importable from $VENV_DIR/bin/python; connector will not start"
  return 1
}

if ! ensure_venv; then
  log "connector auto-start aborted (venv/python unavailable); session unaffected"
  exit 1
fi

# ---- 4. identity derivation (D2) ----
SID="${POLYTOKEN_SESSION_ID:-}"
if [ -z "$SID" ]; then
  # Fallback: newest ready startup.json + freshness + pid-liveness tiebreak.
  SID="$("$CONNECTOR_PYTHON" -m discord_bridge.session_select --sessions-v1 "$SESSIONS_DIR/sessions-v1" 2>>"$LOG_FILE" || true)"
  if [ -n "$SID" ]; then
    log "derived session $SID from sessions-v1 (no POLYTOKEN_SESSION_ID)"
  fi
fi
if [ -z "$SID" ]; then
  log "WARN no POLYTOKEN_SESSION_ID and no ready startup to derive from"
  exit 1
fi

CID="${BRIDGE_CONTAINER_ID:-$(hostname 2>/dev/null || true)}"
if [ -z "$CID" ]; then
  log "WARN cannot derive container id (hostname empty); set BRIDGE_CONTAINER_ID"
  exit 1
fi
# Hex preflight is warn-only: a false-fail must never silently disable
# autostart. The relay-side container.py validator stays authoritative for /kill.
if ! printf '%s' "$CID" | grep -Eq '^[0-9a-f]{12,64}$'; then
  log "WARN container id '$CID' fails hex preflight ^[0-9a-f]{12,64}$; applying as-is (set BRIDGE_CONTAINER_ID to override; relay validates /kill)"
fi
XID="${BRIDGE_CONNECTOR_ID:-bridge-$CID}"

export POLYTOKEN_SESSION_ID="$SID"
export BRIDGE_CONTAINER_ID="$CID"
export BRIDGE_CONNECTOR_ID="$XID"
log "identity: session=$SID container=$CID connector=$XID"

# ---- 5. readiness poll (1s x <=30s) before exec ----
META="$SESSIONS_DIR/sessions-v1/$SID/startup.json"
i=0
while [ "$i" -lt "$READY_ATTEMPTS" ]; do
  if [ -f "$META" ] && jq -e --arg s "$SID" '.state == "ready" and .session_id == $s' "$META" >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  [ "$i" -lt "$READY_ATTEMPTS" ] && sleep "$READY_INTERVAL"
done
if [ "$i" -ge "$READY_ATTEMPTS" ]; then
  log "session $SID did not reach ready within ${READY_ATTEMPTS}s; exiting nonzero (session unaffected)"
  exit 1
fi
log "session $SID ready; exec connector"

# ---- 6. exec connector_main (fd 9 flock survives across exec) ----
exec "$CONNECTOR_PYTHON" -m discord_bridge.connector_main
