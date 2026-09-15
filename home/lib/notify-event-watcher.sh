#!/usr/bin/env bash
# SSE event watcher — attention lane (plan-002 r3.9 + operator "Choice C"
# dispatch). Long-running per-host loop that discovers live session daemons,
# connects to /events with the Bearer scheme, and notifies on exactly the six
# mapped events (everything else stays silent):
#
#   ask_user_question                 -> question_pending          (claim: interrogative_id)
#   interrogative[plan_handoff]       -> approval_pending          (claim: interrogative_id)
#   interrogative[goal_proposal]      -> approval_pending          (claim: interrogative_id)
#   goal_driver_update[completed]     -> goal_completed            (claim: goal.id+":completed")
#   turn_cancelled                    -> turn_cancelled            (claim: prompt_id+":cancelled")
#   interrogative[permission]         -> approval_pending          (claim: interrogative_id)
#
# Agent-raised permission interrogatives arrive with seq:null and are handled
# cursorless (freshness + claim only); operator-facing TUI permission prompts
# emit no event at all (a documented daemon limitation, so their mapping is dormant).
#
# Normative contracts implemented (plan r3.1/r3.9):
# - Baseline on connect: the first frame's seq starts the cursor; pre-connect
#   history is never notified (the stream only delivers post-connect frames;
#   reconnect replay is dropped by the seq cursor).
# - Freshness at processing time: missing/malformed emitted_at -> diagnostic
#   skip; age > 120s -> skip stale; emitted_at > +5s in the future -> skip
#   unverifiable. No clamping acceptance.
# - Clock-discontinuity backstop: a backward local-clock jump beyond +5s
#   suppresses the frame, rebaselines the clock, and is diagnostic-logged.
# - One alert per episode: atomic exclusive-create claims (notify-claim.sh)
#   before any send; dedup makes re-fires and re-renders no-ops. Where the
#   required ID is absent the frame is diagnostic-skipped — never a synthetic
#   key.
# - Non-mapped event types (session_idle, stream_discontinuity, hook_fired,
#   notification*, heartbeat, ...) are silently ignored. Only the `completed`
#   goal transition maps; `accepted`/`created`/... stay silent.
#
# STATE ROOT (documented choice): the hook's existing state root
#   ${AGENT_NOTIFY_STATE_DIR:-${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}/.agent-notify}
# is the single root shared by the hook path and this watcher so any future
# hook-path sender claims through the same per-session mechanism. Layout:
#   <root>/claims/<safe_session_id>/claim.<key>   atomic send claims
#   <root>/watch/<safe_session_id>/cursor         "seq N" + "clock EPOCH"
#
# RUN (deployment): install.sh/scripts/install-polytoken.sh copy and wire the
# watcher and its keepalive on non-macOS and containerized installs; on native
# macOS the installer wires the watchdog LaunchAgent but omits the watcher
# keepalive entry, so start the watcher manually there:
#   nohup bash "$HOME/path/to/repo/home/lib/notify-event-watcher.sh" \
#     >/dev/null 2>&1 &
#
# Dependencies: bash 3.2+, jq, curl. Sources the Slice 1 libraries additively;
# fail-open throughout: no credentials, no jq, or a dead daemon must never
# crash the loop nor delay anything.
set -u

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_LIB_DIR/notify-identity.sh" ] && . "$_LIB_DIR/notify-identity.sh"
[ -f "$_LIB_DIR/notify-send.sh" ] && . "$_LIB_DIR/notify-send.sh"
[ -f "$_LIB_DIR/notify-claim.sh" ] && . "$_LIB_DIR/notify-claim.sh"
unset _LIB_DIR

: "${NOTIFY_WATCHER_SESSIONS_DIR:=${POLYTOKEN_SESSIONS_DIR:-${AGENT_NOTIFY_SESSIONS_DIR:-$HOME/.local/share/polytoken/sessions}}}"
: "${NOTIFY_WATCHER_STATE_ROOT:=${AGENT_NOTIFY_STATE_DIR:-${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}/.agent-notify}}"
: "${NOTIFY_WATCHER_POLL_SECONDS:=5}"
: "${NOTIFY_WATCHER_FRESH_SECONDS:=120}"
: "${NOTIFY_WATCHER_FUTURE_TOLERANCE:=5}"
: "${NOTIFY_WATCHER_CLOCK_TOLERANCE:=5}"
: "${NOTIFY_WATCHER_SENDER:=notify_watcher_default_send}"

# RFC3339 date-time -> whole-second epoch (r3.4 wire contract: sub-second
# precision is irrelevant at the 120s/5s tolerances). Non-zero exit on a
# missing or malformed stamp.
notify_watcher_epoch(){
  local s="${1:-}"
  [ -n "$s" ] || return 1
  s="${s%Z}"; s="${s%%.*}"
  case "$(uname -s 2>/dev/null)" in
    Darwin|*BSD*) date -u -j -f "%Y-%m-%dT%H:%M:%S" "$s" +%s 2>/dev/null ;;
    *) date -u -d "$s" +%s 2>/dev/null ;;
  esac
}

# Session directory names whose startup.json reports state "ready" and a
# numeric port. Prints one session directory path per line.
notify_watcher_discover(){
  local d
  for d in "$NOTIFY_WATCHER_SESSIONS_DIR"/*/startup.json; do
    [ -f "$d" ] || continue
    jq -er 'select(.state == "ready") | .port | select(type == "number" and . > 0)' "$d" >/dev/null 2>&1 \
      && printf '%s\n' "${d%/startup.json}"
  done
}

# curl argument vector (one per line) for a session directory's /events
# stream: Bearer token verbatim from the credential file named by
# startup.json (fallback: the session's own credential.json). No timeout on
# the stream itself (--max-time 0); the daemon closing the socket ends it.
notify_watcher_curl_args(){
  local dir="${1:-}" port cred token
  [ -n "$dir" ] && [ -f "$dir/startup.json" ] || return 1
  port="$(jq -r '.port // empty' "$dir/startup.json" 2>/dev/null)" || return 1
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  cred="$(jq -r '.credential_file_path // empty' "$dir/startup.json" 2>/dev/null)"
  [ -n "$cred" ] && [ -f "$cred" ] || cred="$dir/credential.json"
  token="$(jq -r '.token // empty' "$cred" 2>/dev/null)" || return 1
  [ -n "$token" ] || return 1
  printf '%s\n' -sS -N --max-time 0 \
    -H "Authorization: Bearer $token" \
    "http://127.0.0.1:$port/events"
}

_nw_safe(){ LC_ALL=C printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-128; }

_nw_skip(){
  notify_source=event-watcher notify_event="skip:${1:-unknown}" notify_session="${2:-unknown}" \
    notify_diag "skipped ${3:-}" 2>/dev/null || true
  printf 'skip %s seq=%s\n' "${1:-unknown}" "${4:-}" 2>/dev/null
  return 0
}

_nw_cursor_write(){ # <watch_dir> <seq> <clock_epoch>
  mkdir -p "$1" 2>/dev/null || return 1
  { printf 'seq %s\n' "$2"; printf 'clock %s\n' "$3"; } > "$1/cursor.tmp" 2>/dev/null || return 1
  mv -f "$1/cursor.tmp" "$1/cursor" 2>/dev/null || return 1
  return 0
}

# Pure frame processor: mapping + freshness + baseline + claims + send. Takes
# the frame JSON (the SSE `data:` payload) and the local now in epoch seconds;
# tests feed frames directly without sockets. The sender is injectable via
# NOTIFY_WATCHER_SENDER (default notify_watcher_default_send); captured send
# lines are printed to stdout as "send <kind> key=<key>".
notify_watcher_process_frame(){
  local frame="${1:-}" now="${2:-}" sid seq emitted etype
  local cursorless=0
  command -v jq >/dev/null 2>&1 || { _nw_skip no-jq unknown; return 0; }
  [ -n "$frame" ] && [ -n "$now" ] || { _nw_skip bad-args unknown; return 0; }
  case "$now" in ''|*[!0-9]*) _nw_skip bad-clock unknown; return 0 ;; esac

  sid="$(jq -r '.session_id // empty' <<<"$frame" 2>/dev/null)"
  seq="$(jq -r '.seq // empty' <<<"$frame" 2>/dev/null)"
  emitted="$(jq -r '.emitted_at // empty' <<<"$frame" 2>/dev/null)"
  etype="$(jq -r '.event.type // empty' <<<"$frame" 2>/dev/null)"
  [ -n "$sid" ] || { _nw_skip no-session unknown; return 0; }
  case "$seq" in ''|*[!0-9]*|0)
    if [ "$etype" = "interrogative" ] && [ -n "$(jq -r 'select((.event.interrogative_id | type) == "string" and length > 0) | .event.interrogative_id' <<<"$frame" 2>/dev/null)" ]; then
      cursorless=1; seq=""
    else
      _nw_skip bad-seq "$sid" "$seq"; return 0
    fi ;;
  esac

  local safe watch claims cursor last_seq=0 last_clock=0
  safe="$(_nw_safe "$sid")"
  watch="$NOTIFY_WATCHER_STATE_ROOT/watch/$safe"
  claims="$NOTIFY_WATCHER_STATE_ROOT/claims/$safe"
  cursor="$watch/cursor"
  if [ -f "$cursor" ]; then
    last_seq="$(awk '$1=="seq"{print $2}' "$cursor" 2>/dev/null)"
    last_clock="$(awk '$1=="clock"{print $2}' "$cursor" 2>/dev/null)"
    case "$last_seq" in ''|*[!0-9]*) last_seq=0 ;; esac
    case "$last_clock" in ''|*[!0-9]*) last_clock=0 ;; esac
  fi

  # Clock-discontinuity backstop: apparent ages are untrustworthy across a
  # backward jump beyond the tolerance; suppress, rebaseline, diagnostic-log.
  if [ "$last_clock" -gt 0 ] && [ "$((last_clock - now))" -gt "$NOTIFY_WATCHER_CLOCK_TOLERANCE" ]; then
    [ "$cursorless" -eq 0 ] && _nw_cursor_write "$watch" "$last_seq" "$now" || true
    notify_source=event-watcher notify_event=clock-discontinuity notify_session="$sid" \
      notify_diag "backward jump $last_clock->$now; suppressed frame seq=$seq; rebaselined" 2>/dev/null || true
    printf 'skip clock-discontinuity seq=%s\n' "$seq"
    return 0
  fi

  # Baseline / replay: the first processed frame starts the cursor; anything
  # at or below it was already seen (or predates connect) and stays silent.
  if [ "$cursorless" -eq 0 ] && [ "$last_seq" -gt 0 ] && [ "$seq" -le "$last_seq" ]; then
    _nw_cursor_write "$watch" "$last_seq" "$now" || true
    _nw_skip replay "$sid" "$seq"
    return 0
  fi

  local emax=0
  if [ -n "$emitted" ]; then emax="$(notify_watcher_epoch "$emitted" 2>/dev/null)" || emax=0; fi
  if [ -z "$emitted" ] || [ "$emax" -le 0 ]; then
    [ "$cursorless" -eq 0 ] && _nw_cursor_write "$watch" "$seq" "$now" || true
    _nw_skip malformed-timestamp "$sid" "$seq"
    return 0
  fi
  local age=$((now - emax))
  if [ "$age" -gt "$NOTIFY_WATCHER_FRESH_SECONDS" ]; then
    [ "$cursorless" -eq 0 ] && _nw_cursor_write "$watch" "$seq" "$now" || true
    _nw_skip stale "$sid" "$seq"
    return 0
  fi
  if [ "$age" -lt 0 ] && [ "$((-age))" -gt "$NOTIFY_WATCHER_FUTURE_TOLERANCE" ]; then
    [ "$cursorless" -eq 0 ] && _nw_cursor_write "$watch" "$seq" "$now" || true
    _nw_skip unverifiable "$sid" "$seq"
    return 0
  fi

  # Cursor advances once the envelope checks pass — mapped or not.
  [ "$cursorless" -eq 0 ] && _nw_cursor_write "$watch" "$seq" "$now" || true

  # Mapping (the watcher's six mapped events — see the header above).
  local kind="" key="" body="" iid count first summary gid
  case "$etype" in
    ask_user_question)
      iid="$(jq -r '.event.interrogative_id // empty' <<<"$frame" 2>/dev/null)"
      [ -n "$iid" ] || { _nw_skip missing-interrogative-id "$sid" "$seq"; return 0; }
      count="$(jq -r 'if (.event.payload.questions | type) == "array" then (.event.payload.questions | length) else empty end' <<<"$frame" 2>/dev/null)"
      [ -n "$count" ] || { _nw_skip missing-questions "$sid" "$seq"; return 0; }
      first="$(jq -r '.event.payload.questions[0].question // empty' <<<"$frame" 2>/dev/null)"
      first="$(_nw_clean_line "$first" 80)"
      if [ "$count" -eq 1 ]; then body="1 question needs your answer"; else body="$count questions need your answer"; fi
      [ -n "$first" ] && body="$body — $first"
      kind="question_pending"; key="$iid"
      ;;
    interrogative)
      local itype
      itype="$(jq -r '.event.interrogative_type // empty' <<<"$frame" 2>/dev/null)"
      iid="$(jq -r '.event.interrogative_id // empty' <<<"$frame" 2>/dev/null)"
      case "$itype" in
        plan_handoff)  kind="approval_pending"; key="$iid"; body="approve plan handoff" ;;
        goal_proposal) kind="approval_pending"; key="$iid"; body="accept goal proposal" ;;
        permission)
          local tname
          kind="approval_pending"; key="$iid"
          body="permission needed to run a command"
          tname="$(jq -r '.event.permission_tool_call.tool_name as $t | select(($t|type) == "string" and ($t|length) > 0) | $t' <<<"$frame" 2>/dev/null)"
          [ -n "$tname" ] && body="permission needed: $(_nw_clean_line "$tname" 80)"
          ;;
        *) return 0 ;;  # outside the notification allowlist: silent
      esac
      [ -n "$key" ] || { _nw_skip missing-interrogative-id "$sid" "$seq"; return 0; }
      ;;
    goal_driver_update)
      local transition
      transition="$(jq -r '.event.transition // empty' <<<"$frame" 2>/dev/null)"
      [ "$transition" = "completed" ] || return 0
      gid="$(jq -r '.event.goal.id // empty' <<<"$frame" 2>/dev/null)"
      [ -n "$gid" ] || { _nw_skip missing-goal-id "$sid" "$seq"; return 0; }
      key="$gid:completed"
      summary="$(jq -r '.event.goal.summary // .event.goal.terminal_reason.detail // empty' <<<"$frame" 2>/dev/null)"
      body="goal completed: $(_nw_clean_line "$summary" 200)"
      kind="goal_completed"
      ;;
    turn_cancelled)
      local cpid creason
      cpid="$(jq -r '.event.prompt_id as $p | select(($p|type) == "string" and ($p|length) > 0) | $p' <<<"$frame" 2>/dev/null)"
      [ -n "$cpid" ] || { _nw_skip missing-prompt-id "$sid" "$seq"; return 0; }
      creason="$(jq -r '.event.reason as $r | select(($r|type) == "string" and ($r|length) > 0) | $r' <<<"$frame" 2>/dev/null)"
      body="turn cancelled"
      [ -n "$creason" ] && body="turn cancelled — $(_nw_clean_line "$creason" 80)"
      kind="turn_cancelled"; key="$cpid:cancelled"
      ;;
    *) return 0 ;;  # every non-mapped family: silent
  esac

  # Episode claim before any send: exactly one winner per key (r3.1 claim
  # boundary); losers are suppressed re-fires/re-renders.
  notify_claim_acquire "$claims" "$key" || { _nw_skip claim-dedup "$sid" "$seq"; return 0; }

  "$NOTIFY_WATCHER_SENDER" "$sid" "$kind" "$key" "$body" || true
  printf 'send %s key=%s\n' "$kind" "$key"
  return 0
}

_nw_clean_line(){
  LC_ALL=C printf '%s' "${1:-}" | tr '[:cntrl:]' ' ' | cut -c1-"${2:-80}"
}

# Production sender: session-title enrichment (best-effort, shared identity
# library) folded into the identity title — repo/branch (session_id)[ - title],
# failing open to "(sid)" — then the shared one-shot fail-open sender with the
# canonical [sse:<kind>] body tag. Decoration lives ONLY here, so frame
# mapping and claim tests stay byte-stable. No credentials in scope means
# notify_send no-ops.
notify_watcher_default_send(){
  local sid="${1:-}" kind="${2:-}" key="${3:-}" body="${4:-}" title project stitle
  project=""
  if [ -f "$NOTIFY_WATCHER_SESSIONS_DIR/${sid//\//_}/session.json" ]; then
    project="$(jq -r '.project_path // empty' \
      "$NOTIFY_WATCHER_SESSIONS_DIR/${sid//\//_}/session.json" 2>/dev/null)"
  fi
  stitle="$(notify_identity_session_title "$NOTIFY_WATCHER_SESSIONS_DIR" "$sid")"
  title="$(notify_identity_resolve "$sid" "$project" "$stitle" 2>/dev/null)" || title=""
  [ -n "$title" ] || title="($sid)"
  notify_source=event-watcher notify_event="$kind" notify_session="$sid" \
  notify_title="$title" notify_body="$(notify_alert_tag sse "$kind")$body" notify_send
  return 0
}

# One streaming connection for one session directory. Returns when the daemon
# closes the stream or curl exits (fail-open; the run loop re-discovers).
notify_watcher_stream(){
  local dir="${1:-}" line frame
  [ -n "$dir" ] || return 0
  local args=() a
  while IFS= read -r a; do args+=("$a"); done < <(notify_watcher_curl_args "$dir" 2>/dev/null)
  [ "${#args[@]}" -gt 0 ] || return 0
  while IFS= read -r line; do
    case "$line" in
      data:*)
        frame="${line#data: }"
        [ "$frame" = "$line" ] && frame="${line#data:}"
        notify_watcher_process_frame "$frame" "$(date +%s 2>/dev/null || printf 0)" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(curl "${args[@]}" 2>/dev/null)
  return 0
}

# Long-running per-host loop: discover ready daemons, keep one stream each,
# re-discover on the poll interval. Best-effort stream de-duplication via a
# liveness-checked pid file per session.
notify_watcher_run(){
  local dir sid safe pidfile pid
  while :; do
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      sid="$(jq -r '.session_id // empty' "$dir/startup.json" 2>/dev/null)"
      [ -n "$sid" ] || sid="${dir##*/}"
      safe="$(_nw_safe "$sid")"
      pidfile="$NOTIFY_WATCHER_STATE_ROOT/watch/$safe/stream.pid"
      if [ -f "$pidfile" ]; then
        pid="$(cat "$pidfile" 2>/dev/null)"
        case "$pid" in ''|*[!0-9]*) pid="" ;; esac
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then continue; fi
      fi
      mkdir -p "$NOTIFY_WATCHER_STATE_ROOT/watch/$safe" 2>/dev/null || true
      ( notify_watcher_stream "$dir" ) >/dev/null 2>&1 </dev/null &
      printf '%s\n' "$!" > "$pidfile" 2>/dev/null || true
    done < <(notify_watcher_discover 2>/dev/null)
    sleep "$NOTIFY_WATCHER_POLL_SECONDS" 2>/dev/null || sleep 5
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then notify_watcher_run; exit 0; fi
