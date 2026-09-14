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
  # Exit 0 with empty stdout = the event's proceed outcome in both harnesses
  # (Polytoken: accept; Claude Code: allow). Never print outcome JSON here:
  # Polytoken rejects unknown variants and logs the hook as malformed.
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
# Polytoken passes the session id via POLYTOKEN_SESSION_ID, not the stdin payload;
# Claude Code passes it in the JSON. Try env first, fall back to payload.
SESSION_RAW="${POLYTOKEN_SESSION_ID:-$(jq -r '.session_id // .sessionId // empty' <<<"$INPUT" 2>/dev/null || true)}"
[ -n "$SESSION_RAW" ] || exit 0
case "$EVENT" in
  UserPromptSubmit|pre_user_prompt) ;;
  Stop|Notification|stop|notification|post_model_turn|post_tool_use|pre_tool_use) ;;
  SubagentStop|subagent_stop) exit 0 ;;
  *) exit 0 ;;
esac
# Polytoken: ambient notifications (background job and subagent completions)
# are not requests for input, and while a saved-session goal is active the
# goal driver re-prompts on its own after `stop` — neither is "needs input".
# Only a goal-less end of turn may schedule a notice. An ambient notification
# is routed to the cancel path below: the session resumed without the user,
# so any send a prior `stop` scheduled (a turn that ended with work still in
# flight) would fire mid-work and is a false alarm.
if [ "$HARNESS" = polytoken ]; then
  if [ "$EVENT" = stop ] && [ "${POLYTOKEN_GOAL_ACTIVE:-}" = true ]; then exit 0; fi
fi

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

# A user prompt means the human is back; a polytoken ambient notification
# means the session resumed on its own; the answer to an ask_user_question
# (post_tool_use for that tool) means the blocking question was answered.
# All three invalidate a pending send.
if [ "$EVENT" = UserPromptSubmit ] || [ "$EVENT" = pre_user_prompt ] ||
   { [ "$HARNESS" = polytoken ] && [ "$EVENT" = notification ]; } ||
   { [ "$EVENT" = post_tool_use ] && [ "${POLYTOKEN_HOOK_MATCHER_SUBJECT:-}" = ask_user_question ]; }; then
  lock || exit 0
  rm -f "$STATE.gen" "$STATE.cancel"
  printf '%s\n' "$(date +%s%N 2>/dev/null || date +%s)" > "$STATE.cancel.tmp" && mv -f "$STATE.cancel.tmp" "$STATE.cancel"
  unlock
  exit 0
fi

GEN="$(date +%s%N 2>/dev/null || date +%s)-$$"
sanitize() {
  # Keep only bounded, printable identity metadata; $2 caps the length (default 64).
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -cd '[:alnum:] ._/@:-' | cut -c1-"${2:-64}"
}
trunc() {
  # sanitize + cap, with an explicit ellipsis when the text was cut.
  local s
  s="$(printf '%s' "$1" | tr '\r\n\t' '   ' | tr -cd '[:alnum:] ._/@:-')"
  if [ "${#s}" -gt "$2" ]; then
    printf '%s...' "${s:0:$2}"
  else
    printf '%s' "$s"
  fi
}
SAFE_SESSION="$(sanitize "$SESSION_RAW")"; [ -n "$SAFE_SESSION" ] || SAFE_SESSION="unknown"
# Session working directory. Precedence: payload cwd (Claude Code passes it;
# Polytoken does not), then the Polytoken session working-dir env, then the
# registered project path. Branch and repo name are derived from it below.
PROJECT_DIR="$(jq -r '.cwd // .project // empty' <<<"$INPUT" 2>/dev/null || true)"
if [ -z "$PROJECT_DIR" ] && [ "$HARNESS" = polytoken ]; then
  PROJECT_DIR="${POLYTOKEN_PROJECT_DIR:-}"
fi
[ -n "$PROJECT_DIR" ] || PROJECT_DIR="${POLYTOKEN_PROJECT_PATH:-}"
# Push content. Title names the conversation; body says where and what.
#   body:  <repo>[/<branch>]: <claude notice text | last assistant transcript
#          text | polytoken session.json preview/title | session id>
#   title: <claude transcript summary | polytoken record.json session_title |
#           polytoken session.json preview | "Agent"> Needs Input
SESSIONS_DIR=""
SESS_FILE_ID="${SAFE_SESSION//\//_}"
TRANSCRIPT=""
if [ "$HARNESS" = claude ]; then
  TRANSCRIPT="$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || true)"
elif [ "$HARNESS" = polytoken ]; then
  SESSIONS_DIR="${POLYTOKEN_SESSIONS_DIR:-${AGENT_NOTIFY_SESSIONS_DIR:-$HOME/.local/share/polytoken/sessions}}"
  TRANSCRIPT="$SESSIONS_DIR/$SESS_FILE_ID/log.jsonl"
fi
RESP=""
case "$EVENT" in
  Notification|notification|post_model_turn|post_tool_use)
    if [ "$HARNESS" = claude ]; then
      RESP="$(trunc "$(jq -r '.message // empty' <<<"$INPUT" 2>/dev/null || true)" 160)"
    fi
    ;;
  pre_tool_use)
    # The pending question is the thing the human is being asked for.
    RESP="$(trunc "$(jq -r '.input.questions[0].question // empty' <<<"$INPUT" 2>/dev/null || true)" 160)"
    ;;
esac
if [ -z "$RESP" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  L="$(grep '"type":"assistant"' "$TRANSCRIPT" 2>/dev/null | tail -5 |
       jq -r '[(.blocks // .message.content // [])[] | select(.type=="text") | .text] | first // empty' 2>/dev/null | tail -1)"
  RESP="$(trunc "$L" 160)"
fi
TITLE_PART=""
if [ "$HARNESS" = polytoken ]; then
  [ -z "$RESP" ] && {
    L="$(jq -r '.last_user_message_preview // ""' "$SESSIONS_DIR/$SESS_FILE_ID/session.json" 2>/dev/null || true)"
    [ -n "$L" ] || L="$(jq -r '.session_title // ""' "$SESSIONS_DIR/$SESS_FILE_ID/record.json" 2>/dev/null || true)"
    RESP="$(trunc "$L" 160)"
  }
  TITLE_PART="$(jq -r '.session_title // ""' "$SESSIONS_DIR/$SESS_FILE_ID/record.json" 2>/dev/null || true)"
  [ -n "$TITLE_PART" ] || TITLE_PART="$(jq -r '.inferred_title // ""' "$SESSIONS_DIR/$SESS_FILE_ID/session.json" 2>/dev/null || true)"
  [ -n "$TITLE_PART" ] || TITLE_PART="$(jq -r '.last_user_message_preview // ""' "$SESSIONS_DIR/$SESS_FILE_ID/session.json" 2>/dev/null || true)"
elif [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TITLE_PART="$(grep '"type":"summary"' "$TRANSCRIPT" 2>/dev/null | tail -1 | jq -r '.summary // empty' 2>/dev/null || true)"
fi
# A polytoken session may have moved into a worktree after start; the session
# log's cwd trail is where the agent most recently worked, so prefer it over
# any start-of-session project directories.
if [ "$HARNESS" = polytoken ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  LOG_CWD="$(grep -o '"cwd":"[^"]*"' "$TRANSCRIPT" 2>/dev/null | tail -1 | cut -d'"' -f4)"
  case "$LOG_CWD" in /*) [ -d "$LOG_CWD" ] && PROJECT_DIR="$LOG_CWD" ;; esac
fi
if [ -z "$PROJECT_DIR" ] && [ "$HARNESS" = polytoken ]; then
  PROJECT_DIR="$(jq -r '.project_path // ""' "$SESSIONS_DIR/$SESS_FILE_ID/session.json" 2>/dev/null || true)"
fi
BRANCH=""
REPO_NAME=""
if [ -n "$PROJECT_DIR" ] && command -v git >/dev/null 2>&1; then
  BRANCH="$(sanitize "$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)" 64)"
  # Name the repo after its common (main) checkout, so a session running in a
  # linked worktree still displays the repo it belongs to — with its own branch.
  COMMON_DIR="$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  COMMON_DIR="${COMMON_DIR%.git}"; COMMON_DIR="${COMMON_DIR%/}"
  [ -n "$COMMON_DIR" ] && REPO_NAME="${COMMON_DIR##*/}"
fi
PROJECT="$(sanitize "${REPO_NAME:-${PROJECT_DIR##*/}}")"; [ -n "$PROJECT" ] || PROJECT="unknown"
TITLE="$(trunc "${TITLE_PART:-Agent}" 48)"
PREVIEW="${RESP:-session=$SAFE_SESSION}"
if [ -n "$BRANCH" ]; then
  MESSAGE="$PROJECT/$BRANCH: $PREVIEW"
else
  MESSAGE="$PROJECT: $PREVIEW"
fi
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
) </dev/null >/dev/null 2>&1 &
# Detached stdio is load-bearing: harnesses (Polytoken daemon, Claude Code)
# read the hook's stdout/stderr until EOF. An inherited pipe would keep the
# hook "running" for the whole DELAY+send and trip the ~30s hook timeout.
exit 0
