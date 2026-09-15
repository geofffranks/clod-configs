#!/usr/bin/env bash
# Ensure the SSE event watcher (lib/notify-event-watcher.sh) is running; safe
# to call on every session_start. Host-side macOS installs can also run the
# watcher manually with nohup (docs/agent-notify.md); containers and Linux
# hosts have no scheduler, so the first session of a boot spawns one detached
# supervision loop here and later invocations no-op while it lives. The loop
# dies with its host and is re-spawned by the next session start.
#
# stdio is detached before the loop starts: both harnesses read hook
# stdout/stderr until EOF, and an inherited pipe would hold the hook open
# for the loop's lifetime (hook timeout ~30s).
#
# Configuration passes through to the watcher unchanged: every NOTIFY_WATCHER_*
# knob (sessions root, poll/freshness windows, sender) is inherited — the
# watcher resolves its sessions dir exactly like the watchdog resolves
# WATCHDOG_SESSIONS_DIR, so in-container sessions are covered because this hook
# runs inside the container, where the daemon's loopback port is reachable and
# the sessions root is the container's own. NOTIFY_WATCHER_LOOP_INTERVAL
# (default 30s) is this loop's restart delay when the watcher exits.
set -u

CONFIG_DIR="${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}"
SCRIPT="$CONFIG_DIR/lib/notify-event-watcher.sh"
[ -f "$SCRIPT" ] || exit 0
command -v flock >/dev/null 2>&1 || exit 0

STATE_ROOT="${AGENT_NOTIFY_STATE_DIR:-$CONFIG_DIR/.agent-notify}"
mkdir -p "$STATE_ROOT" 2>/dev/null || exit 0
PIDFILE="$STATE_ROOT/notify-watcher-keepalive.pid"
LOG_FILE="${NOTIFY_WATCHER_LOOP_LOG:-$STATE_ROOT/notify-watcher-loop.log}"

# Serialize spawners; the claim is released when this hook exits. The loop
# records its own pid as its first action, so liveness is checkable without
# racing the spawn.
exec 9>"$STATE_ROOT/notify-watcher-keepalive.lock" 2>/dev/null || exit 0
flock -n 9 || exit 0

if [ -f "$PIDFILE" ]; then
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) pid="" ;; esac
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    # The pid may have been recycled by an unrelated process; a real loop has
    # the watcher in its command line (Linux /proc; elsewhere trust the pid).
    if grep -q "notify-event-watcher" "/proc/$pid/cmdline" 2>/dev/null \
       || [ ! -d "/proc/$pid" ]; then
      exit 0
    fi
  fi
fi

if command -v setsid >/dev/null 2>&1; then
  setsid bash -c 'echo $$ > "$1"; while :; do bash "$2"; sleep "${NOTIFY_WATCHER_LOOP_INTERVAL:-30}"; done' \
    notify-watcher-loop "$PIDFILE" "$SCRIPT" >>"$LOG_FILE" 2>&1 </dev/null &
else
  bash -c 'echo $$ > "$1"; while :; do bash "$2"; sleep "${NOTIFY_WATCHER_LOOP_INTERVAL:-30}"; done' \
    notify-watcher-loop "$PIDFILE" "$SCRIPT" >>"$LOG_FILE" 2>&1 </dev/null &
fi
exit 0
