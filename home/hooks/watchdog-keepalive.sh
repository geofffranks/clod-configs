#!/usr/bin/env bash
# Ensure the session-watchdog scan loop is running; safe to call on every
# session_start. Host-side installs use launchd (scripts/install-session-
# watchdog.sh); containers have no scheduler, so the first session of a
# container boot spawns one detached loop here and later invocations no-op
# while it lives. The loop dies with its host and is re-spawned by the next
# session start.
#
# stdio is detached before the loop starts: both harnesses read hook
# stdout/stderr until EOF, and an inherited pipe would hold the hook open
# for the loop's lifetime (hook timeout ~30s).
#
# Configuration is inherited by the scan itself (WATCHDOG_LOG_DIR,
# WATCHDOG_SESSIONS_DIR, WATCHDOG_STATE_DIR, WATCHDOG_ENV_FILE, and
# WATCHDOG_LOOP_INTERVAL for the scan cadence, default 30s).
set -u

CONFIG_DIR="${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}"
SCRIPT="$CONFIG_DIR/hooks/session-watchdog.sh"
[ -f "$SCRIPT" ] || SCRIPT="$HOME/.claude/session-watchdog.sh"
[ -f "$SCRIPT" ] || exit 0
command -v flock >/dev/null 2>&1 || exit 0

STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/.local/share/polytoken/.session-watchdog}"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
PIDFILE="$STATE_DIR/loop.pid"
LOG_FILE="${WATCHDOG_LOOP_LOG:-$STATE_DIR/loop.log}"

# Serialize spawners; the claim is released when this hook exits. The loop
# records its own pid as its first action, so liveness is checkable without
# racing the spawn.
exec 9>"$STATE_DIR/loop.lock" 2>/dev/null || exit 0
flock -n 9 || exit 0

if [ -f "$PIDFILE" ]; then
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) pid="" ;; esac
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    # The pid may have been recycled by an unrelated process; a real loop has
    # the watchdog in its command line (Linux /proc; elsewhere trust the pid).
    if grep -q "session-watchdog" "/proc/$pid/cmdline" 2>/dev/null \
       || [ ! -d "/proc/$pid" ]; then
      exit 0
    fi
  fi
fi

if command -v setsid >/dev/null 2>&1; then
  # LIVENESS_STALE defaults to 180 here, not the scanner's 90: liveness ticks
  # can lag past 90s while a daemon is saturated with a heavy turn (observed
  # 2026-09-13), and a false "Agent Died" mid-work defeats the purpose.
  WATCHDOG_LIVENESS_STALE="${WATCHDOG_LIVENESS_STALE:-180}" \
  WATCHDOG_ENV_FILE="${WATCHDOG_ENV_FILE:-$CONFIG_DIR/watchdog.env}" \
  setsid bash -c 'echo $$ > "$1"; while :; do bash "$2"; sleep "${WATCHDOG_LOOP_INTERVAL:-30}"; done' \
    watchdog-loop "$PIDFILE" "$SCRIPT" >>"$LOG_FILE" 2>&1 </dev/null &
else
  WATCHDOG_LIVENESS_STALE="${WATCHDOG_LIVENESS_STALE:-180}" \
  WATCHDOG_ENV_FILE="${WATCHDOG_ENV_FILE:-$CONFIG_DIR/watchdog.env}" \
  bash -c 'echo $$ > "$1"; while :; do bash "$2"; sleep "${WATCHDOG_LOOP_INTERVAL:-30}"; done' \
    watchdog-loop "$PIDFILE" "$SCRIPT" >>"$LOG_FILE" 2>&1 </dev/null &
fi
exit 0
