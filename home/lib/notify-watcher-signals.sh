#!/usr/bin/env bash
# Quiet-notify signals for the SSE watcher. All network and time dependencies
# are injectable; diagnostics contain bounded reason codes, never payloads.
set -u
: "${NOTIFY_WATCHER_IDLE_DEBOUNCE:=10}"
: "${NOTIFY_WATCHER_PROBE_TIMEOUT:=5}"
: "${NOTIFY_WATCHER_RESPONSE_MAX:=65536}"
: "${NOTIFY_WATCHER_REMINDER_DELAY:=300}"
: "${NOTIFY_WATCHER_SIGNAL_SENDER:=notify_watcher_default_signal_send}"
: "${NOTIFY_WATCHER_SLEEP:=sleep}"
# Initialize once in the watcher shell so command-substitution callers inherit a
# stable process generation when optional daemon_epoch metadata is absent.
: "${NOTIFY_WATCHER_PROCESS_GENERATION:=$$.$RANDOM.$(date +%s)}"

_nws_signal(){
  local sid="$1" typ="$2" signal="$3" lifecycle="${4:-}" title="${5:-}" text
  case "$typ" in
    goal_lifecycle) case "$lifecycle" in completed) text="goal complete";; blocked) text="goal blocked";; *) return 0;; esac; [ -n "$title" ] && text="$text: $title";;
    turn_idle) text="idle — nothing running, no goal active";;
    question_reminder) text="still waiting for your answer: $title";; *) return 0;;
  esac
  "$NOTIFY_WATCHER_SIGNAL_SENDER" "$sid" "$typ" "$signal" "$text" || true
}

# Strict /goal response parser; empty means no current goal.
notify_watcher_goal_parse(){
  jq -er 'if (has("current_goal")|not) or .current_goal==null then "none\t\t"
    elif (.current_goal|type)=="object" and (.current_goal.lifecycle|type)=="string" and (.current_goal.id|type)=="string" and (.current_goal.id|length)>0 and (.current_goal.id|length)<=128 then
    (.current_goal.lifecycle|ascii_downcase) as $life | if (["active","paused","blocked","completed"]|index($life)) != null then [$life,.current_goal.id,((.current_goal.summary // "")|if type=="string" then .[:200] else "" end)]|@tsv else error("invalid lifecycle") end
    else error("invalid goal response") end' 2>/dev/null
}

# Authenticated localhost JSON probe; cap bytes while streaming via curl max-filesize,
# check actual file size, and never include response/token in diagnostics.
notify_watcher_probe(){
  local dir="$1" path="$2" port cred token curl_cmd="${NOTIFY_WATCHER_CURL:-curl}" tmp bytes rc
  port="$(jq -er '.port|select(type=="number" and .>0 and floor==.)' "$dir/startup.json" 2>/dev/null)" || return 1
  cred="$(jq -r '.credential_file_path // empty' "$dir/startup.json" 2>/dev/null)"; [ -n "$cred" ] && [ -f "$cred" ] || cred="$dir/credential.json"
  token="$(jq -er '.token|select(type=="string" and length>0 and length<=4096)' "$cred" 2>/dev/null)" || return 1
  case "$path" in /goal|/jobs|/sync) :;; *) return 1;; esac
  tmp="${TMPDIR:-/tmp}/notify-probe.$$.${RANDOM}.tmp"
  (umask 077; : > "$tmp") 2>/dev/null || return 1
  "$curl_cmd" -fsS --max-time "$NOTIFY_WATCHER_PROBE_TIMEOUT" --max-filesize "$NOTIFY_WATCHER_RESPONSE_MAX" -H "Authorization: Bearer $token" -o "$tmp" "http://127.0.0.1:$port$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
  bytes="$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')"
  case "$bytes" in ''|*[!0-9]*) rm -f "$tmp"; return 1;; esac
  [ "$bytes" -le "$NOTIFY_WATCHER_RESPONSE_MAX" ] || { rm -f "$tmp"; return 1; }
  cat "$tmp" 2>/dev/null; rc=$?; rm -f "$tmp"; return "$rc"
}

_nws_current_epoch(){
  local dir="$1" epoch port sid
  epoch="$(jq -r 'if (.daemon_epoch|type)=="string" and (.daemon_epoch|length)>0 and (.daemon_epoch|length)<=128 then .daemon_epoch else empty end' "$dir/startup.json" 2>/dev/null)"
  [ -n "$epoch" ] && { printf '%s\n' "$epoch"; return 0; }
  # The reference metadata permits a missing epoch. In that case use a
  # process-local generation so old timer workers cannot cross watcher restart.
  port="$(jq -r '.port // empty' "$dir/startup.json" 2>/dev/null)"
  sid="$(jq -r '.session_id // empty' "$dir/startup.json" 2>/dev/null)"
  [ -n "$port" ] && [ -n "$sid" ] || return 1
  printf 'process:%s:%s:%s\n' "$sid" "$port" "$NOTIFY_WATCHER_PROCESS_GENERATION"
}
_nws_process_live(){
  local state="$1"
  [ "$(cat "$state/process-generation" 2>/dev/null || true)" = "$NOTIFY_WATCHER_PROCESS_GENERATION" ]
}
# Portable per-session serialization (macOS has no stock flock). An owner
# directory is fully initialized before its symlink is published. Never steal
# a live owner; a dead owner can be reclaimed. Contention fails closed.
_nws_lock(){
  local state="$1" lock="$1/.signal-lock" owner pid i=0 candidate
  mkdir -p "$state" 2>/dev/null || return 1
  while [ -e "$lock" ] || [ -L "$lock" ]; do
    # Operator-approved best-effort recovery: a dead PID may be reclaimed.
    # There is a residual check/unlink race if two reclaimers overlap; the
    # accepted policy favors unattended recovery over strict exclusion.
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    case "$pid" in ''|*[!0-9]*) ;; *)
      if ! kill -0 "$pid" 2>/dev/null; then
        owner="$(readlink "$lock" 2>/dev/null || true)"
        case "$owner" in .signal-owner.*)
          rm -f "$lock" 2>/dev/null || return 1
          rm -rf "$state/$owner" 2>/dev/null || true
          continue;;
        esac
      fi;;
    esac
    i=$((i+1)); [ "$i" -lt 40 ] || return 1
    sleep 0.05
  done
  candidate=".signal-owner.${BASHPID:-$$}.$RANDOM"
  mkdir "$state/$candidate" 2>/dev/null || return 1
  printf '%s\n' "${BASHPID:-$$}" > "$state/$candidate/pid" || { rmdir "$state/$candidate" 2>/dev/null; return 1; }
  ln -s "$candidate" "$lock" 2>/dev/null || { rm -rf "$state/$candidate"; return 1; }
  NWS_LOCK_OWNER="$candidate"
}
_nws_unlock(){
  local state="$1" owner="${NWS_LOCK_OWNER:-}"
  [ -n "$owner" ] || return 0
  if [ "$(readlink "$state/.signal-lock" 2>/dev/null || true)" = "$owner" ] &&
     [ "$(cat "$state/$owner/pid" 2>/dev/null || true)" = "${BASHPID:-$$}" ]; then
    rm -f "$state/.signal-lock" 2>/dev/null || true
    rm -rf "$state/$owner" 2>/dev/null || true
  fi
  NWS_LOCK_OWNER=""
}
# Caller holds the session lock through its ticket write.
_nws_session_process(){
  local state="$1" current
  current="$(cat "$state/process-generation" 2>/dev/null || true)"
  if [ "$current" != "$NOTIFY_WATCHER_PROCESS_GENERATION" ]; then
    printf '%s\n' "$NOTIFY_WATCHER_PROCESS_GENERATION" > "$state/process-generation" 2>/dev/null || return 1
    printf 'restart\n' > "$state/question-ticket" 2>/dev/null || true
    printf 'restart\n' > "$state/idle-ticket" 2>/dev/null || true
  fi
}
_nws_reminder_wait(){
  local dir="$1" sid="$2" id="$3" text="$4" ticket="$5" state="$6" epoch="$7" current
  "${NOTIFY_WATCHER_SLEEP}" "$NOTIFY_WATCHER_REMINDER_DELAY" || return 0
  _nws_process_live "$state" || return 0
  [ "$(cat "$state/question-ticket" 2>/dev/null || true)" = "$ticket" ] || return 0
  current="$(_nws_current_epoch "$dir")"
  [ -n "$epoch" ] && [ "$current" = "$epoch" ] || { _nws_diag reminder-generation-ended "$sid"; return 0; }
  # Coordinate the final armed->sending decision with cancellation/restart.
  # After the claim wins, transport acceptance is irreversible.
  _nws_lock "$state" || return 0
  if ! _nws_process_live "$state" || [ "$(cat "$state/question-ticket" 2>/dev/null || true)" != "$ticket" ]; then
    _nws_unlock "$state"; return 0
  fi
  notify_claim_acquire "$NOTIFY_WATCHER_STATE_ROOT/claims/$(_nw_safe "$sid")" "question:$epoch:$id" || { _nws_unlock "$state"; return 0; }
  printf 'sending.%s\n' "$ticket" > "$state/question-ticket" 2>/dev/null || true
  _nws_unlock "$state"
  _nws_signal "$sid" question_reminder "question:$epoch:$id" "" "$text"
}
notify_watcher_question_arm(){
  local dir="$1" sid="$2" id="$3" text="$4" state ticket epoch safe
  [ -n "$id" ] || return 0
  epoch="$(_nws_current_epoch "$dir")"; [ -n "$epoch" ] || return 0
  safe="$(_nw_safe "$sid")"
  state="$NOTIFY_WATCHER_STATE_ROOT/watch/$safe"; _nws_lock "$state" || return 0
  _nws_session_process "$state" || { _nws_unlock "$state"; return 0; }
  # Persist generation to fence stale timer workers, while the timer itself is
  # process-local and is never reconstructed after watcher restart.
  if [ -f "$state/epoch" ] && [ "$(cat "$state/epoch" 2>/dev/null)" != "$epoch" ]; then
    printf 'epoch-change\n' > "$state/question-ticket" 2>/dev/null || true
  fi
  printf '%s\n' "$epoch" > "$state/epoch" 2>/dev/null || { _nws_unlock "$state"; return 0; }
  # An already-armed/sent question is not re-armed by a duplicate SSE frame.
  case "$(cat "$state/question-ticket" 2>/dev/null || true)" in "$epoch.$id."*|"sending.$epoch.$id."*) _nws_unlock "$state"; return 0;; esac
  ticket="${epoch}.${id}.$(date +%s).$$.$RANDOM"
  printf '%s\n' "$ticket" > "$state/question-ticket" 2>/dev/null || { _nws_unlock "$state"; return 0; }
  _nws_unlock "$state"
  if [ "${NOTIFY_WATCHER_TEST_SYNC:-}" = 1 ]; then
    _nws_reminder_wait "$dir" "$sid" "$id" "$text" "$ticket" "$state" "$epoch"
  else
    ( _nws_reminder_wait "$dir" "$sid" "$id" "$text" "$ticket" "$state" "$epoch" ) >/dev/null 2>&1 </dev/null &
  fi
}
notify_watcher_question_cancel(){
  local sid="$1" state
  state="$NOTIFY_WATCHER_STATE_ROOT/watch/$(_nw_safe "$sid")"
  _nws_lock "$state" || return 0
  if _nws_process_live "$state"; then
    printf 'cancel.%s.%s\n' "$$" "$RANDOM" > "$state/question-ticket" 2>/dev/null || true
  fi
  _nws_unlock "$state"
}
notify_watcher_shutdown(){
  local state current sid
  current="${NOTIFY_WATCHER_PROCESS_GENERATION:-}"
  [ -n "$current" ] || return 0
  for state in "$NOTIFY_WATCHER_STATE_ROOT"/watch/*; do
    [ -d "$state" ] || continue
    _nws_lock "$state" || continue
    if [ "$(cat "$state/process-generation" 2>/dev/null || true)" = "$current" ]; then
      printf 'shutdown.%s\n' "$$" > "$state/question-ticket" 2>/dev/null || true
      printf 'shutdown.%s\n' "$$" > "$state/idle-ticket" 2>/dev/null || true
      printf 'shutdown\n' > "$state/process-generation" 2>/dev/null || true
    fi
    _nws_unlock "$state"
  done
}

notify_watcher_idle_check(){
  local dir="$1" sid="$2" pid="$3" ticket="$4" state="$5" goal jobs sync row life epoch
  _nws_process_live "$state" || return 0
  [ "$(cat "$state/idle-ticket" 2>/dev/null || true)" = "$ticket" ] || return 0
  goal="$(notify_watcher_probe "$dir" /goal)" || { _nws_diag probe-failed-goal "$sid"; return 0; }
  row="$(printf '%s' "$goal" | notify_watcher_goal_parse)" || { _nws_diag invalid-goal "$sid"; return 0; }
  life="${row%%$'\t'*}"; [ "$life" != active ] && [ "$life" != blocked ] || return 0
  jobs="$(notify_watcher_probe "$dir" /jobs)" || { _nws_diag probe-failed-jobs "$sid"; return 0; }
  jq -e '((if type=="array" then . elif type=="object" then .jobs else null end) as $list | ($list|type)=="array" and all($list[]; (if type=="object" then (.state // .status) else null end) as $state | ($state|type)=="string" and ($state|ascii_downcase|IN("completed","done","succeeded","failed","cancelled","finished","stopped"))))' <<<"$jobs" >/dev/null 2>&1 || { _nws_diag invalid-or-busy-jobs "$sid"; return 0; }
  sync="$(notify_watcher_probe "$dir" /sync)" || { _nws_diag probe-failed-sync "$sid"; return 0; }
  jq -e 'type=="object" and (.interrogatives|type)=="array" and (.interrogatives|length)==0 and ((has("turn")|not) or .turn==null or (.turn|type)=="object" and (.turn|length)==0)' <<<"$sync" >/dev/null 2>&1 || { _nws_diag invalid-or-busy-sync "$sid"; return 0; }
  epoch="$(_nws_current_epoch "$dir")"; [ -n "$epoch" ] || return 0
  case "$ticket" in "$epoch".*) :;; *) return 0;; esac
  # Recheck and claim atomically with lifecycle invalidation. No network probe
  # runs under this lock; accepted sends cannot be retracted afterward.
  _nws_lock "$state" || return 0
  if ! _nws_process_live "$state" || [ "$(cat "$state/idle-ticket" 2>/dev/null || true)" != "$ticket" ]; then
    _nws_unlock "$state"; return 0
  fi
  notify_claim_acquire "$NOTIFY_WATCHER_STATE_ROOT/claims/$(_nw_safe "$sid")" "turn:$epoch:$pid:idle" || { _nws_unlock "$state"; return 0; }
  printf 'sending.%s\n' "$ticket" > "$state/idle-ticket" 2>/dev/null || true
  _nws_unlock "$state"
  _nws_signal "$sid" turn_idle "turn:$pid"
}
notify_watcher_message_complete(){
  local dir="$1" sid="$2" frame="$3" pid state ticket
  pid="$(jq -r 'if (.event.type=="message_complete") and (.event.prompt_id|type)=="string" and (.event.prompt_id|length)>0 and (.event.prompt_id|length)<=128 then .event.prompt_id else empty end' <<<"$frame" 2>/dev/null)"
  [ -n "$pid" ] || return 0
  case "$NOTIFY_WATCHER_IDLE_DEBOUNCE" in ''|*[!0-9.]*|.*.*) _nws_diag invalid-debounce "$sid"; return 0;; esac
  local epoch
  epoch="$(_nws_current_epoch "$dir")"; [ -n "$epoch" ] || return 0
  state="$NOTIFY_WATCHER_STATE_ROOT/watch/$(_nw_safe "$sid")"; _nws_lock "$state" || return 0
  _nws_session_process "$state" || { _nws_unlock "$state"; return 0; }
  ticket="${epoch}.${pid}.$(date +%s).$$.$RANDOM"
  printf '%s\n' "$ticket" > "$state/idle-ticket" 2>/dev/null || { _nws_unlock "$state"; return 0; }
  _nws_unlock "$state"
  if [ "${NOTIFY_WATCHER_TEST_SYNC:-}" = 1 ]; then
    "${NOTIFY_WATCHER_SLEEP}" "$NOTIFY_WATCHER_IDLE_DEBOUNCE" && notify_watcher_idle_check "$dir" "$sid" "$pid" "$ticket" "$state"
  else
    ( "${NOTIFY_WATCHER_SLEEP}" "$NOTIFY_WATCHER_IDLE_DEBOUNCE" && notify_watcher_idle_check "$dir" "$sid" "$pid" "$ticket" "$state" ) >/dev/null 2>&1 </dev/null &
  fi
}
notify_watcher_goal_tick(){
  local dir="$1" sid="$2" state row previous life gid title key epoch old_epoch
  state="$NOTIFY_WATCHER_STATE_ROOT/watch/$(_nw_safe "$sid")"; _nws_lock "$state" || return 0
  _nws_session_process "$state" || { _nws_unlock "$state"; return 0; }
  epoch="$(_nws_current_epoch "$dir")"; [ -n "$epoch" ] || { _nws_unlock "$state"; return 0; }
  old_epoch="$(cat "$state/epoch" 2>/dev/null || true)"
  if [ "$old_epoch" != "$epoch" ]; then
    printf '%s\n' "$epoch" > "$state/epoch" 2>/dev/null || { _nws_unlock "$state"; return 0; }
    printf 'epoch-change\n' > "$state/question-ticket" 2>/dev/null || true
    printf 'epoch-change\n' > "$state/idle-ticket" 2>/dev/null || true
    rm -f "$state/goal-state" 2>/dev/null || true
  fi
  _nws_unlock "$state"
  row="$(notify_watcher_probe "$dir" /goal | notify_watcher_goal_parse)" || { _nws_diag invalid-goal "$sid"; return 0; }
  _nws_lock "$state" || return 0
  if ! _nws_process_live "$state" ||
     [ "$(cat "$state/epoch" 2>/dev/null || true)" != "$epoch" ] ||
     [ "$(_nws_current_epoch "$dir")" != "$epoch" ]; then
    _nws_unlock "$state"; return 0
  fi
  previous="$(cat "$state/goal-state" 2>/dev/null || true)"
  printf '%s\n' "$row" > "$state/goal-state" 2>/dev/null || { _nws_unlock "$state"; return 0; }
  life="${row%%$'\t'*}"
  if [ -z "$previous" ] || [ "$row" = "$previous" ] || { [ "$life" != completed ] && [ "$life" != blocked ]; }; then
    _nws_unlock "$state"; return 0
  fi
  IFS=$'\t' read -r life gid title <<<"$row"; key="goal:$epoch:$gid:$life"
  notify_claim_acquire "$NOTIFY_WATCHER_STATE_ROOT/claims/$(_nw_safe "$sid")" "$key" || { _nws_unlock "$state"; return 0; }
  _nws_unlock "$state"
  _nws_signal "$sid" goal_lifecycle "$key" "$life" "$title"
}
_nws_diag(){ notify_source=event-watcher notify_event="$1" notify_session="$2" notify_diag "quiet-notify suppressed" 2>/dev/null || true; }
notify_watcher_default_signal_send(){
  local sid="$1" kind="$2" key="$3" text="$4"
  [ -n "${PUSHOVER_APP_TOKEN:-}" ] && [ -n "${PUSHOVER_USER_KEY:-}" ] || return 0
  notify_source=event-watcher notify_event="$kind" notify_session="$sid" notify_title="($sid)" notify_body="[sse:$kind]$text" notify_send_pushover_only
}
