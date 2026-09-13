#!/usr/bin/env bash
# Host-side watchdog: pings Pushover when a Polytoken session's daemon dies
# while the session was recently active.
#
# Why: a daemon death (crash, container restart, supervisor respawn) kills an
# in-flight turn without firing any hook — the process that would run hooks is
# gone — so turns can end silently (seen 2026-09-12 21:12: session daemon was
# replaced mid-tool and the session sat dead until the operator noticed).
# Every Polytoken daemon maintains a continuously-updated liveness journal at
#   <logs>/<started-at>-<pid>.liveness.jsonl
# next to its <started-at>-<pid>.log. Liveness going stale is therefore an
# unambiguous "this daemon is gone" signal, and the paired .log names the
# session it served.
#
# Run periodically (launchd StartInterval) as a single-shot scan:
#   fresh liveness   -> daemon alive; clears that session's death tombstone
#   stale liveness   -> daemon gone; ping once per episode when the session's
#                       log advanced within WATCHDOG_IDLE_LIMIT of the death
#   fresh *tui.crash.log -> TUI panic; ping once per crash log when the named
#                       session was recently active (a crash kills the process
#                       that would run hooks, so the scan is the only sensor)
# Suppressions: boot grace (first scan only tombstones), mass staleness
# (>= WATCHDOG_MASS new deaths in one scan reads as a host/container event,
# not per-session deaths), idle deaths, crash logs older than the idle limit,
# and a 3-attempt retry cap.
set -u

ENV_FILE="${WATCHDOG_ENV_FILE:-$HOME/.config/polytoken/watchdog.env}"
# Explicit process environment wins over the env file: a seeded file must
# never override credentials a caller (or a test mock) passed in.
_app="${PUSHOVER_APP_TOKEN:-${PUSHOVER_TOKEN:-}}"
_user="${PUSHOVER_USER_KEY:-${PUSHOVER_USER:-}}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
APP_TOKEN="${_app:-${PUSHOVER_APP_TOKEN:-${PUSHOVER_TOKEN:-}}}"
USER_KEY="${_user:-${PUSHOVER_USER_KEY:-${PUSHOVER_USER:-}}}"
unset _app _user
LOG_DIR="${WATCHDOG_LOG_DIR:-$HOME/.local/share/polytoken/logs}"
SESSIONS_DIR="${WATCHDOG_SESSIONS_DIR:-$HOME/.local/share/polytoken/sessions}"
STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/.local/share/polytoken/.session-watchdog}"
LIVENESS_STALE="${WATCHDOG_LIVENESS_STALE:-90}"
IDLE_LIMIT="${WATCHDOG_IDLE_LIMIT:-600}"
MASS="${WATCHDOG_MASS:-4}"

# All optional dependencies fail open before any state or network work.
command -v curl >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ -n "$APP_TOKEN" ] && [ -n "$USER_KEY" ] || exit 0
[ -d "$LOG_DIR" ] || exit 0
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

sanitize() {
  # Keep only bounded, printable identity metadata; $2 caps the length.
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -cd '[:alnum:] ._/@:-' | cut -c1-"${2:-64}"
}

mtime_of() {  # GNU/BSD stat, 0 when unreadable
  stat -Lc %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

session_for_stem() {  # the paired .log names the session it serves
  head -c 200000 "$LOG_DIR/$1.log" 2>/dev/null |
    grep -m1 -o '"session_id":"[^"]*"' | cut -d'"' -f4
}

now="$(date +%s)"
BOOT=0
[ -f "$STATE_DIR/.bootstrapped" ] || BOOT=1
QUEUE="$STATE_DIR/.queue.$$"
: > "$QUEUE"

for f in "$LOG_DIR"/*.liveness.jsonl; do
  [ -e "$f" ] || continue
  stem="$(basename "$f" .liveness.jsonl)"
  sess="$(session_for_stem "$stem")"
  [ -n "$sess" ] || continue
  sessfile="$(sanitize "$sess" 96)"
  tomb="$STATE_DIR/tomb-$sessfile"
  m="$(mtime_of "$f")"
  if [ "$((now - m))" -le "$LIVENESS_STALE" ]; then
    rm -f "$tomb"        # daemon alive: a previous death episode is over
    continue
  fi
  [ -f "$tomb" ] && continue
  # A journal whose last line disarms ended cleanly (TUI closed, session
  # replaced): the agent didn't die, it was retired. Tombstone silently.
  if tail -n 1 "$f" 2>/dev/null | grep -q '"type":"disarmed"'; then
    : > "$tomb"
    continue
  fi
  idle=$((now - "$(mtime_of "$SESSIONS_DIR/$sess/log.jsonl")"))
  if [ "$idle" -gt "$IDLE_LIMIT" ]; then
    : > "$tomb"          # daemon died while the session was already idle
    continue
  fi
  printf '%s %s\n' "$sess" "$idle" >> "$QUEUE"
done

# One session may have several stale daemons in a single scan (e.g. an old
# daemon dies around the time a replacement is already tombstone-clear); ping
# once per session, keeping the entry with the freshest session activity.
if [ -s "$QUEUE" ]; then
  sort -k1,1 -k2,2n "$QUEUE" 2>/dev/null | awk '!seen[$1]++' > "$QUEUE.d" && mv "$QUEUE.d" "$QUEUE"
fi

# Many simultaneous deaths = the host slept or a container restarted; that is
# one event, not one ping per session.
mass=0
while read -r _ _; do mass=$((mass + 1)); done < "$QUEUE"

send_ping() {  # $1 session, $2 idle seconds
  local sess="$1" idle="$2" sessfile sf rf preview title_part project body att n
  sessfile="$(sanitize "$sess" 96)"
  att="$STATE_DIR/att-$sessfile"
  n="$(cat "$att" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -ge 3 ]; then
    : > "$STATE_DIR/tomb-$sessfile"; rm -f "$att"; return 0
  fi
  sf="$SESSIONS_DIR/$sess/session.json"
  rf="$SESSIONS_DIR/$sess/record.json"
  preview="$(jq -r '.last_user_message_preview // ""' "$sf" 2>/dev/null || true)"
  title_part="$(jq -r '.session_title // ""' "$rf" 2>/dev/null || true)"
  [ -n "$title_part" ] || title_part="$preview"
  # Last assistant text says what the agent was doing when it died.
  body="$(grep '"type":"assistant"' "$SESSIONS_DIR/$sess/log.jsonl" 2>/dev/null | tail -5 |
    jq -r '[(.blocks // .message.content // [])[] | select(.type=="text") | .text] | last // empty' 2>/dev/null | tail -1)"
  [ -n "$body" ] || body="$preview"
  [ -n "$body" ] || body="session=$sess"
  project="$(jq -r '.project_path // ""' "$sf" 2>/dev/null || true)"
  project="$(sanitize "${project##*/}" 64)"; [ -n "$project" ] || project="unknown"
  title="$(sanitize "${title_part:-Agent}" 48) Agent Died"
  message="$(printf '%s: %s (last activity %dm ago)' "$project" "$(sanitize "$body" 160)" "$((idle / 60))")"
  # Claim the episode before delivering: a concurrent scanner sharing this
  # state must not double-ping the same death. Release the claim on failure
  # so the retry can run.
  : > "$STATE_DIR/tomb-$sessfile"
  if curl -sS --fail --max-time 10 -X POST https://api.pushover.net/1/messages.json \
    --data-urlencode "token=$APP_TOKEN" --data-urlencode "user=$USER_KEY" \
    --data-urlencode "title=$title" --data-urlencode "message=$message" >/dev/null 2>&1; then
    rm -f "$att"
  else
    rm -f "$STATE_DIR/tomb-$sessfile"
    echo $((n + 1)) > "$att"
  fi
}

send_crash_ping() {  # $1 session, $2 crash-log stem, $3 crash-log path, $4 age seconds
  local sess="$1" stem="$2" crash="$3" age="$4" sessfile att n sf rf preview title_part msg project title message
  att="$STATE_DIR/att-crash-$stem"
  n="$(cat "$att" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -ge 3 ]; then
    : > "$STATE_DIR/crash-$stem"; rm -f "$att"; return 0
  fi
  sf="$SESSIONS_DIR/$sess/session.json"
  rf="$SESSIONS_DIR/$sess/record.json"
  preview="$(jq -r '.last_user_message_preview // ""' "$sf" 2>/dev/null || true)"
  title_part="$(jq -r '.session_title // ""' "$rf" 2>/dev/null || true)"
  [ -n "$title_part" ] || title_part="$preview"
  # The panic line says what died; session metadata says where.
  msg="$(sed -n 's/^Message:[[:space:]]*//p' "$crash" 2>/dev/null | head -1)"
  [ -n "$msg" ] || msg="$preview"
  [ -n "$msg" ] || msg="session=$sess"
  project="$(jq -r '.project_path // ""' "$sf" 2>/dev/null || true)"
  project="$(sanitize "${project##*/}" 64)"; [ -n "$project" ] || project="unknown"
  title="$(sanitize "${title_part:-Agent}" 48) TUI Crashed"
  message="$(printf '%s: %s (last activity %dm ago)' "$project" "$(sanitize "$msg" 160)" "$((age / 60))")"
  # Claim the crash episode before delivering (same anti-double-ping rule
  # as daemon deaths); release the claim on failure so the retry can run.
  : > "$STATE_DIR/crash-$stem"
  if curl -sS --fail --max-time 10 -X POST https://api.pushover.net/1/messages.json \
    --data-urlencode "token=$APP_TOKEN" --data-urlencode "user=$USER_KEY" \
    --data-urlencode "title=$title" --data-urlencode "message=$message" >/dev/null 2>&1; then
    rm -f "$att"
  else
    rm -f "$STATE_DIR/crash-$stem"
    echo $((n + 1)) > "$att"
  fi
}

if [ "$BOOT" = 1 ]; then
  # First scan after install: record the world as-is, ping nothing.
  while read -r sess _; do : > "$STATE_DIR/tomb-$(sanitize "$sess" 96)"; done < "$QUEUE"
elif [ "$mass" -ge "$MASS" ]; then
  while read -r sess _; do : > "$STATE_DIR/tomb-$(sanitize "$sess" 96)"; done < "$QUEUE"
else
  while read -r sess idle; do send_ping "$sess" "$idle"; done < "$QUEUE"
fi

# TUI crash logs are scanned regardless of daemon liveness: the panic kills
# the TUI mid-turn without any hook firing. One ping per crash log; crashes
# older than the idle limit, or naming no session, tombstone silently.
for f in "$LOG_DIR"/*tui.crash.log; do
  [ -e "$f" ] || continue
  stem="$(basename "$f" .log)"
  [ -f "$STATE_DIR/crash-$stem" ] && continue
  m="$(mtime_of "$f")"
  age=$((now - m))
  if [ "$age" -gt "$IDLE_LIMIT" ]; then
    : > "$STATE_DIR/crash-$stem"
    continue
  fi
  sess="$(sanitize "$(sed -n 's/^Session:[[:space:]]*//p' "$f" 2>/dev/null | head -1)" 96)"
  [ -n "$sess" ] || { : > "$STATE_DIR/crash-$stem"; continue; }
  send_crash_ping "$sess" "$stem" "$f" "$age"
done

rm -f "$QUEUE"
: > "$STATE_DIR/.bootstrapped"
exit 0
