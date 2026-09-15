#!/usr/bin/env bash
# Host-side watchdog: posts to the local macOS Notification Center (credential-
# free, on by default on a native mac host) and to Pushover (optional) when a
# Polytoken session's daemon dies while the session was recently active.
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
#   any fresh liveness -> session alive; clears that session's death tombstone
#   all liveness stale -> daemon gone; ping once per episode when the session's
#                         log advanced within WATCHDOG_IDLE_LIMIT of the death
#   fresh *tui.crash.log -> TUI panic; ping once per crash log when the named
#                       session was recently active (a crash kills the process
#                       that would run hooks, so the scan is the only sensor)
#
# Liveness is decided PER SESSION, not per file: a session is alive when ANY
# of its liveness journals is fresh. A daemon replacement leaves a stale
# leftover journal beside the fresh one for the same session; deciding per
# file let that stale sibling re-arm a death and re-ping every scan (the
# 2026-09-14 "Agent Died" flood). Only when EVERY journal for a session is
# stale is a death considered (once per episode, unchanged). Long-stale
# leftover journals for dead daemons are purged (WATCHDOG_PURGE_OLD_DAYS,
# default 7 days; 0 disables); a live session's journal is never purged.
#
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
# Best-effort source of the shared identity library (sole title/body-tag
# formatter) and the credential-free mac Notification Center lane: the
# watchdog lives at $DEST/hooks/ (native) or ~/.claude/ (watchdog-only
# install); both modules sit at the sibling lib dir in either layout.
_IDENTITY_SRC=""
_NOTIFY_MAC_SRC=""
for _cand in \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib" \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)"; do
  if [ -z "$_IDENTITY_SRC" ] && [ -f "$_cand/notify-identity.sh" ]; then _IDENTITY_SRC="$_cand/notify-identity.sh"; fi
  if [ -z "$_NOTIFY_MAC_SRC" ] && [ -f "$_cand/notify-mac.sh" ]; then _NOTIFY_MAC_SRC="$_cand/notify-mac.sh"; fi
done
[ -n "$_IDENTITY_SRC" ] && . "$_IDENTITY_SRC"
[ -n "$_NOTIFY_MAC_SRC" ] && . "$_NOTIFY_MAC_SRC"
unset _IDENTITY_SRC _NOTIFY_MAC_SRC _cand
LOG_DIR="${WATCHDOG_LOG_DIR:-$HOME/.local/share/polytoken/logs}"
SESSIONS_DIR="${WATCHDOG_SESSIONS_DIR:-$HOME/.local/share/polytoken/sessions}"
STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/.local/share/polytoken/.session-watchdog}"
LIVENESS_STALE="${WATCHDOG_LIVENESS_STALE:-90}"
IDLE_LIMIT="${WATCHDOG_IDLE_LIMIT:-600}"
MASS="${WATCHDOG_MASS:-4}"
PURGE_DAYS="${WATCHDOG_PURGE_OLD_DAYS:-7}"   # 0 disables stale-journal purge
case "$PURGE_DAYS" in ''|*[!0-9]*) PURGE_DAYS=0 ;; esac   # non-numeric => disabled

# jq is required for title/body enrichment in BOTH lanes (mac and Pushover);
# curl is required only for Pushover. Fail open before any state or network work.
command -v jq >/dev/null 2>&1 || exit 0
[ -d "$LOG_DIR" ] || exit 0
pushover_ok=0
[ -n "$APP_TOKEN" ] && [ -n "$USER_KEY" ] && command -v curl >/dev/null 2>&1 && pushover_ok=1
[ "$pushover_ok" = 1 ] || notify_mac_available || exit 0
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
LIVE="$STATE_DIR/.live.$$"
: > "$LIVE"
# Clean our per-scan scratch files if this single-shot scan is interrupted.
trap 'rm -f "$QUEUE" "$LIVE"' INT TERM

# A session is ALIVE when ANY of its liveness journals is fresh. A daemon
# replacement leaves a stale leftover journal for the same session beside the
# fresh one; deciding per file would let that stale sibling re-arm a death
# and re-ping every scan (the 2026-09-14 "Agent Died" flood). First pass:
# record every session that currently has at least one fresh journal.
for f in "$LOG_DIR"/*.liveness.jsonl; do
  [ -e "$f" ] || continue
  stem="$(basename "$f" .liveness.jsonl)"
  sess="$(session_for_stem "$stem")"
  [ -n "$sess" ] || continue
  sessfile="$(sanitize "$sess" 96)"
  [ -n "$sessfile" ] || continue   # fully-stripped ids must not collapse identity
  if [ "$((now - "$(mtime_of "$f")"))" -le "$LIVENESS_STALE" ]; then
    printf '%s\n' "$sessfile" >> "$LIVE"
  fi
done

for f in "$LOG_DIR"/*.liveness.jsonl; do
  [ -e "$f" ] || continue
  stem="$(basename "$f" .liveness.jsonl)"
  sess="$(session_for_stem "$stem")"
  [ -n "$sess" ] || continue
  sessfile="$(sanitize "$sess" 96)"
  [ -n "$sessfile" ] || continue
  tomb="$STATE_DIR/tomb-$sessfile"
  # Fresh at evaluation time (F1): a daemon that (re)started between the LIVE
  # pass and here is alive by definition and must never be evaluated as a
  # death, even though the LIVE snapshot predates it.
  if [ "$((now - "$(mtime_of "$f")"))" -le "$LIVENESS_STALE" ]; then
    rm -f "$tomb"
    continue
  fi
  if grep -Fxq -- "$sessfile" "$LIVE"; then
    rm -f "$tomb"        # live session: a prior death episode is over; a stale
    continue             # sibling must never re-arm it
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
  # A session that never received a prompt leaves no unanswered human
  # behind: any exit, however abrupt, is tombstoned silently.
  grep -q '"type":"user"' "$SESSIONS_DIR/$sess/log.jsonl" 2>/dev/null || {
    : > "$tomb"
    continue
  }
  printf '%s %s\n' "$sess" "$idle" >> "$QUEUE"
done

# One session may have several stale daemons in a single scan (e.g. an old
# daemon dies around the time a replacement is already tombstone-clear); ping
# once per session, keeping the entry with the freshest session activity.
if [ -s "$QUEUE" ]; then
  sort -k1,1 -k2,2n "$QUEUE" 2>/dev/null | awk '!seen[$1]++' > "$QUEUE.d.$$" && mv "$QUEUE.d.$$" "$QUEUE"
fi

# Many simultaneous deaths = the host slept or a container restarted; that is
# one event, not one ping per session.
mass=0
while read -r _ _; do mass=$((mass + 1)); done < "$QUEUE"

send_ping() {  # $1 session, $2 idle seconds
  local sess="$1" idle="$2" sessfile sf preview project body title message att n
  sessfile="$(sanitize "$sess" 96)"
  att="$STATE_DIR/att-$sessfile"
  n="$(cat "$att" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -ge 3 ]; then
    : > "$STATE_DIR/tomb-$sessfile"; rm -f "$att"; return 0
  fi
  sf="$SESSIONS_DIR/$sess/session.json"
  preview="$(jq -r '.last_user_message_preview // ""' "$sf" 2>/dev/null || true)"
  # Last assistant text says what the agent was doing when it died.
  body="$(grep '"type":"assistant"' "$SESSIONS_DIR/$sess/log.jsonl" 2>/dev/null | tail -5 |
    jq -r '[(.blocks // .message.content // [])[] | select(.type=="text") | .text] | last // empty' 2>/dev/null | tail -1)"
  [ -n "$body" ] || body="$preview"
  [ -n "$body" ] || body="session=$sess"
  project="$(jq -r '.project_path // ""' "$sf" 2>/dev/null || true)"
  # Title carries the identity (resolver derives repo/branch + basename
  # fallback; the enrichment helper supplies the session title); the glanceable
  # human lead-in stays in the tagged body. Fail-open: any title failure falls
  # back to "(<sid>)" — the alert is never suppressed by formatting.
  title="$(notify_identity_resolve "$sess" "$project" "$(notify_identity_session_title "$SESSIONS_DIR" "$sess")")" || title=""
  [ -n "$title" ] || title="($sess)"
  project="$(sanitize "${project##*/}" 64)"; [ -n "$project" ] || project="unknown"
  message="$(notify_alert_tag watchdog agent_died)$(printf 'Agent died — %s: %s (last activity %dm ago)' "$project" "$(sanitize "$body" 160)" "$((idle / 60))")"
  # Claim the episode before delivering: a concurrent scanner sharing this
  # state must not double-ping the same death. Release the claim on failure
  # so the retry can run.
  : > "$STATE_DIR/tomb-$sessfile"
  notify_mac_send "$title" "$message" 2>/dev/null || true
  if [ "$pushover_ok" = 1 ]; then
    if curl -sS --fail --max-time 10 -X POST https://api.pushover.net/1/messages.json \
      --data-urlencode "token=$APP_TOKEN" --data-urlencode "user=$USER_KEY" \
      --data-urlencode "title=$title" --data-urlencode "message=$message" >/dev/null 2>&1; then
      rm -f "$att"
    else
      rm -f "$STATE_DIR/tomb-$sessfile"
      echo $((n + 1)) > "$att"
    fi
  fi
}

send_crash_ping() {  # $1 session, $2 crash-log stem, $3 crash-log path, $4 age seconds
  local sess="$1" stem="$2" crash="$3" age="$4" sessfile att n sf preview project msg title message
  att="$STATE_DIR/att-crash-$stem"
  n="$(cat "$att" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -ge 3 ]; then
    : > "$STATE_DIR/crash-$stem"; rm -f "$att"; return 0
  fi
  sf="$SESSIONS_DIR/$sess/session.json"
  preview="$(jq -r '.last_user_message_preview // ""' "$sf" 2>/dev/null || true)"
  # The panic line says what died; session metadata says where.
  msg="$(sed -n 's/^Message:[[:space:]]*//p' "$crash" 2>/dev/null | head -1)"
  [ -n "$msg" ] || msg="$preview"
  [ -n "$msg" ] || msg="session=$sess"
  project="$(jq -r '.project_path // ""' "$sf" 2>/dev/null || true)"
  # Identity title via the shared resolver + enrichment helper (see send_ping);
  # the tagged human lead-in stays in the body. Fail-open "(<sid>)" fallback.
  title="$(notify_identity_resolve "$sess" "$project" "$(notify_identity_session_title "$SESSIONS_DIR" "$sess")")" || title=""
  [ -n "$title" ] || title="($sess)"
  project="$(sanitize "${project##*/}" 64)"; [ -n "$project" ] || project="unknown"
  message="$(notify_alert_tag watchdog tui_crash)$(printf 'TUI crashed — %s: %s (last activity %dm ago)' "$project" "$(sanitize "$msg" 160)" "$((age / 60))")"
  # Claim the crash episode before delivering (same anti-double-ping rule
  # as daemon deaths); release the claim on failure so the retry can run.
  : > "$STATE_DIR/crash-$stem"
  notify_mac_send "$title" "$message" 2>/dev/null || true
  if [ "$pushover_ok" = 1 ]; then
    if curl -sS --fail --max-time 10 -X POST https://api.pushover.net/1/messages.json \
      --data-urlencode "token=$APP_TOKEN" --data-urlencode "user=$USER_KEY" \
      --data-urlencode "title=$title" --data-urlencode "message=$message" >/dev/null 2>&1; then
      rm -f "$att"
    else
      rm -f "$STATE_DIR/crash-$stem"
      echo $((n + 1)) > "$att"
    fi
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
  # Never-prompted sessions have no work to lose: stay silent.
  grep -q '"type":"user"' "$SESSIONS_DIR/$sess/log.jsonl" 2>/dev/null || {
    : > "$STATE_DIR/crash-$stem"
    continue
  }
  send_crash_ping "$sess" "$stem" "$f" "$age"
done

# T2: purge liveness journals (and their paired .log) for daemons that are
# confirmed dead and long since stopped serving a live session. The
# fresh-sibling rule above already makes leftovers inert, so this is defensive
# hygiene against unbounded accumulation. A live session's journal is never
# removed: deletion is gated on the session having no fresh journal in the
# current scan (LIVE, re-derived from live mtimes this run), re-checked here so
# a journal for a live session is never a purge candidate.
if [ "${PURGE_DAYS:-0}" -gt 0 ]; then
  old_cut=$((now - PURGE_DAYS * 86400))
  for f in "$LOG_DIR"/*.liveness.jsonl; do
    [ -e "$f" ] || continue
    [ "$(mtime_of "$f")" -le "$old_cut" ] || continue
    stem="$(basename "$f" .liveness.jsonl)"
    sess="$(session_for_stem "$stem")"
    if [ -n "$sess" ]; then
      sessfile="$(sanitize "$sess" 96)"
      [ -n "$sessfile" ] || continue
      grep -Fxq -- "$sessfile" "$LIVE" && continue   # live session: never purge
    fi
    # A journal whose paired .log names no session is anonymous: no session can
    # be live without a resolvable fresh journal, so an old anonymous journal
    # is never a live session's and is safe to purge as hygiene.
    rm -f "$f" "$LOG_DIR/$stem.log"
  done
fi

rm -f "$QUEUE" "$LIVE"
: > "$STATE_DIR/.bootstrapped"
exit 0
