#!/usr/bin/env bash
# Shared, fail-open per-session Pushover notifier for Claude Code and Polytoken.
set -u

HARNESS="${1:-}"
APP_TOKEN="${PUSHOVER_APP_TOKEN:-${PUSHOVER_TOKEN:-}}"
USER_KEY="${PUSHOVER_USER_KEY:-${PUSHOVER_USER:-}}"
case "$HARNESS" in
  claude) DEFAULT_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
  polytoken) DEFAULT_CONFIG_DIR="${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}" ;;
  *) exit 0 ;;
esac
STATE_DIR="${AGENT_NOTIFY_STATE_DIR:-$DEFAULT_CONFIG_DIR/.agent-notify}"
DELAY="${AGENT_NOTIFY_DELAY:-60}"
INPUT="$(cat 2>/dev/null || true)"

# pre_user_prompt must always allow, even when optional dependencies are absent.
if printf '%s' "$INPUT" | grep -Eq '"(event|hook_event_name)"[[:space:]]*:[[:space:]]*"(pre_user_prompt|UserPromptSubmit)"'; then
  printf '%s\n' '{"outcome":"allow"}'
  [ -n "$HARNESS" ] || exit 0
  EVENT=pre_user_prompt
else
  command -v jq >/dev/null 2>&1 || exit 0
  EVENT="$(jq -r '.hook_event_name // .event // ""' <<<"$INPUT" 2>/dev/null || true)"
fi

# All non-prompt events fail open when credentials are unavailable, before any
# state directory, worker, or network request is started.
[ -n "$HARNESS" ] || exit 0
[ -n "$APP_TOKEN" ] && [ -n "$USER_KEY" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
SESSION_RAW="$(jq -r '.session_id // .sessionId // empty' <<<"$INPUT" 2>/dev/null || true)"
[ -n "$SESSION_RAW" ] || exit 0
case "$EVENT" in
  UserPromptSubmit|pre_user_prompt) ;;
  Stop|Notification|stop|notification|post_model_turn|post_tool_use) ;;
  SubagentStop|subagent_stop) exit 0 ;;
  *) exit 0 ;;
esac

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
KEY_INPUT="${#HARNESS}:$HARNESS${#SESSION_RAW}:$SESSION_RAW"
if command -v sha256sum >/dev/null 2>&1; then
  KEY="$(printf '%s' "$KEY_INPUT" | sha256sum | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  KEY="$(printf '%s' "$KEY_INPUT" | shasum -a 256 | awk '{print $1}')"
else
  exit 0
fi
STATE="$STATE_DIR/$KEY"
LOCK="$STATE.lock"
LOCK_MAX_WAIT="${AGENT_NOTIFY_LOCK_WAIT:-2}"
LOCK_TOKEN=""
LOCK_OWNER=""
lock() {
  local started now owner_pid owner_token candidate
  started="$(date +%s 2>/dev/null || printf '0')"
  while [ -e "$LOCK" ] || [ -L "$LOCK" ]; do
    # The published lock is a symlink to a fully initialized owner directory.
    # A partially written candidate is never visible at $LOCK.
    owner_pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    owner_token="$(cat "$LOCK/token" 2>/dev/null || true)"
    if [ -d "$LOCK" ] && ! printf '%s' "$owner_pid" | grep -Eq '^[0-9]+$'; then
      if [ -L "$LOCK" ]; then rm -f "$LOCK"; else rm -rf "$LOCK"; fi 2>/dev/null || return 1
      continue
    fi
    # Legacy/partial locks may have a valid PID but no token. Never reclaim
    # one whose owner is alive; only a failed liveness check permits recovery.
    if [ -d "$LOCK" ] && [ -z "$owner_token" ] && kill -0 "$owner_pid" 2>/dev/null; then
      : # bounded wait below; fail open rather than stealing a live lock
    elif [ -d "$LOCK" ] && [ -z "$owner_token" ]; then
      if [ -L "$LOCK" ]; then rm -f "$LOCK"; else rm -rf "$LOCK"; fi 2>/dev/null || return 1
      continue
    fi
    if printf '%s' "$owner_pid" | grep -Eq '^[0-9]+$' &&
       [ -n "$owner_token" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
      if [ -L "$LOCK" ]; then rm -f "$LOCK"; else rm -rf "$LOCK"; fi 2>/dev/null || return 1
      continue
    fi
    now="$(date +%s 2>/dev/null || printf '%s' "$started")"
    sleep 0.02
    [ "$((now - started))" -lt "$LOCK_MAX_WAIT" ] || return 1
  done
  LOCK_TOKEN="${BASHPID:-$$}-$(date +%s%N 2>/dev/null || date +%s)"
  candidate="$LOCK.owner.$LOCK_TOKEN"
  mkdir "$candidate" 2>/dev/null || return 1
  printf '%s\n' "${BASHPID:-$$}" > "$candidate/pid" || { rm -rf "$candidate"; return 1; }
  printf '%s\n' "$LOCK_TOKEN" > "$candidate/token" || { rm -rf "$candidate"; return 1; }
  : > "$candidate/heartbeat" || { rm -rf "$candidate"; return 1; }
  ln -s "$(basename "$candidate")" "$LOCK" 2>/dev/null || { rm -rf "$candidate"; LOCK_TOKEN=""; return 1; }
  LOCK_OWNER="$candidate"
}
unlock() {
  [ -n "$LOCK_TOKEN" ] && [ "$(cat "$LOCK/token" 2>/dev/null || true)" = "$LOCK_TOKEN" ] || return 0
  rm -f "$LOCK" 2>/dev/null || true
  [ -n "$LOCK_OWNER" ] && rm -rf "$LOCK_OWNER" 2>/dev/null || true
  LOCK_TOKEN=""
  LOCK_OWNER=""
}

if [ "$EVENT" = UserPromptSubmit ] || [ "$EVENT" = pre_user_prompt ]; then
  lock || exit 0
  rm -f "$STATE.gen" "$STATE.cancel"
  printf '%s\n' "$(date +%s%N 2>/dev/null || date +%s)" > "$STATE.cancel.tmp" && mv -f "$STATE.cancel.tmp" "$STATE.cancel"
  unlock
  exit 0
fi

GEN="$(date +%s%N 2>/dev/null || date +%s)-$$"
case "$EVENT" in
  Stop|stop) CATEGORY="agent stopped"; TITLE="Agent stopped" ;;
  Notification|notification|post_model_turn|post_tool_use) CATEGORY="agent attention"; TITLE="Agent attention" ;;
  *) CATEGORY="agent attention"; TITLE="Agent attention" ;;
esac
sanitize() {
  # Keep only bounded, printable identity metadata; event payload text is never used.
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -cd '[:alnum:] ._/@:-' | cut -c1-64
}
SAFE_SESSION="$(sanitize "$SESSION_RAW")"; [ -n "$SAFE_SESSION" ] || SAFE_SESSION="unknown"
PROJECT_RAW="$(jq -r '.cwd // .project // empty' <<<"$INPUT" 2>/dev/null || true)"
PROJECT="$(sanitize "${PROJECT_RAW##*/}")"; [ -n "$PROJECT" ] || PROJECT="unknown"
MESSAGE="$CATEGORY [$HARNESS session=$SAFE_SESSION project=$PROJECT]"
lock || exit 0
printf '%s\n' "$GEN" > "$STATE.gen.tmp" && mv -f "$STATE.gen.tmp" "$STATE.gen"
unlock
(
  sleep "$DELAY"
  lock || exit 0
  CURRENT="$(cat "$STATE.gen" 2>/dev/null || true)"
  [ "$CURRENT" = "$GEN" ] || { unlock; exit 0; }
  # Keep ownership lock through send, so cancellation/new generations cannot race it.
  curl -sS --fail --max-time 10 -X POST https://api.pushover.net/1/messages.json \
    --data-urlencode "token=$APP_TOKEN" --data-urlencode "user=$USER_KEY" \
    --data-urlencode "title=$TITLE" --data-urlencode "message=$MESSAGE" >/dev/null 2>&1 || { unlock; exit 0; }
  [ "$(cat "$STATE.gen" 2>/dev/null || true)" = "$GEN" ] && rm -f "$STATE.gen" "$STATE.cancel"
  unlock
) &
exit 0
