#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
source "$REPO/home/lib/notify-event-watcher.sh"
source "$REPO/home/lib/notify-watcher-signals.sh"
pass=0; fail=0
ok(){ echo "ok: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
assert(){ if eval "$1"; then ok "$2"; else no "$2"; fi; }
NOTIFY_WATCHER_STATE_ROOT="$TMP/state"
NOTIFY_WATCHER_SIGNAL_SENDER=cap_send
NOTIFY_WATCHER_IDLE_DEBOUNCE=0.01
mkdir -p "$TMP/session"
printf '%s' '{"session_id":"sess","port":1234,"daemon_epoch":"epoch-1"}' > "$TMP/session/startup.json"
_epoch_dir="$TMP/session"
NOTIFY_WATCHER_TEST_SYNC=1
NOTIFY_WATCHER_REMINDER_DELAY=300
NOTIFY_WATCHER_SLEEP=true
PROBE_PATHS="$TMP/probe-paths"; : > "$PROBE_PATHS"
SENDS="$TMP/sends"; : > "$SENDS"
cap_send(){ printf '%s|%s|%s|%s\n' "$@" >> "$SENDS"; }

# Goal lifecycle seeds silently, then emits only completed/blocked transitions.
notify_watcher_probe(){ case "$2" in /goal) printf '%s' "$GOAL_JSON";; *) return 1;; esac; }
GOAL_JSON='{"current_goal":{"id":"g1","lifecycle":"active","summary":"private title"}}'
notify_watcher_goal_tick "$TMP/session" sess
[ ! -s "$SENDS" ] && ok 'goal lifecycle cold start is silent' || no 'goal lifecycle cold start is silent'
GOAL_JSON='{"current_goal":{"id":"g1","lifecycle":"completed","summary":"a bounded goal"}}'
notify_watcher_goal_tick "$TMP/session" sess
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = 1 ]' 'completed goal transition emits once'
assert 'grep -q "goal complete: a bounded goal" "$SENDS"' 'goal title is rendered boundedly'
notify_watcher_goal_tick "$TMP/session" sess
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = 1 ]' 'same goal transition is claimed once'
GOAL_JSON='{"current_goal":{"id":"g2","lifecycle":"blocked","summary":"blocked title"}}'
notify_watcher_goal_tick "$TMP/session" sess
assert 'grep -q "goal blocked: blocked title" "$SENDS"' 'blocked lifecycle transition emits'

# Idle probes are scripted; fake sleep gives deterministic timer seam.
NOTIFY_WATCHER_SLEEP=true
IDLE_GOAL_JSON='{"current_goal":null}'
JOBS_JSON='{"jobs":[{"state":"completed"}]}'
SYNC_JSON='{"interrogatives":[],"turn":{}}'
notify_watcher_probe(){
  printf '%s\n' "$2" >> "$PROBE_PATHS"
  case "$2" in
    /goal) printf '%s' "$IDLE_GOAL_JSON";;
    /jobs) printf '%s' "$JOBS_JSON";;
    /sync) printf '%s' "$SYNC_JSON";;
    *) return 1;;
  esac
}
frame='{"event":{"type":"message_complete","prompt_id":"p1"}}'
# Ensure goal is empty for idle path.
GOAL_JSON='{"current_goal":null}'; JOBS_JSON='{"jobs":[{"state":"completed"}]}'; SYNC_JSON='{"interrogatives":[],"turn":{}}'
notify_watcher_message_complete "$TMP/session" sess "$frame"
for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 0.01; done
assert 'grep -q "turn_idle|turn:p1" "$SENDS"' 'message_complete produces idle signal after quiet probes'
notify_watcher_message_complete "$TMP/session" sess "$frame"
assert '[ "$(grep -c "turn_idle|turn:p1" "$SENDS")" = 1 ]' 'idle signal is claimed once per prompt episode'

before="$(wc -l < "$SENDS" | tr -d ' ')"
JOBS_JSON='{"jobs":[{"state":"running"}]}'
frame='{"event":{"type":"message_complete","prompt_id":"p2"}}'
notify_watcher_message_complete "$TMP/session" sess "$frame"
sleep 0.05
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'running job suppresses idle signal'

before="$(wc -l < "$SENDS" | tr -d ' ')"
JOBS_JSON='invalid'; notify_watcher_message_complete "$TMP/session" sess '{"event":{"type":"message_complete","prompt_id":"p3"}}'; sleep 0.05
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'malformed jobs response fails closed'

# Superseding candidate changes ticket so the older recheck cannot emit.
JOBS_JSON='{"jobs":[{"state":"completed"}]}'
state="$NOTIFY_WATCHER_STATE_ROOT/watch/sess"; mkdir -p "$state"
printf 'newer\n' > "$state/idle-ticket"
notify_watcher_idle_check /unused sess p-old old "$state"
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'superseded idle ticket cannot emit'

IDLE_GOAL_JSON='{"current_goal":{"id":"g","lifecycle":"active"}}'
notify_watcher_message_complete "$TMP/session" sess '{"event":{"type":"message_complete","prompt_id":"p-active"}}'
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'active goal suppresses idle'
IDLE_GOAL_JSON='{"current_goal":null}'
SYNC_JSON='{"interrogatives":[{"id":"q"}],"turn":{}}'
notify_watcher_message_complete "$TMP/session" sess '{"event":{"type":"message_complete","prompt_id":"p-question"}}'
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'open interrogative suppresses idle'
SYNC_JSON='{"interrogatives":[],"turn":{"phase":"running"}}'
notify_watcher_message_complete "$TMP/session" sess '{"event":{"type":"message_complete","prompt_id":"p-turn"}}'
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'pending turn suppresses idle'
SYNC_JSON='bad-json'
notify_watcher_message_complete "$TMP/session" sess '{"event":{"type":"message_complete","prompt_id":"p-probe-error"}}'
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'malformed sync probe suppresses idle'
# Reference accepts a direct jobs list; non-object nonempty turn is unknown and suppresses.
JOBS_JSON='[{"status":"DONE"}]'; SYNC_JSON='{"interrogatives":[]}'
notify_watcher_message_complete "$TMP/session" sess '{"event":{"type":"message_complete","prompt_id":"p-list"}}'
assert 'grep -q "turn_idle|turn:p-list" "$SENDS"' 'terminal direct jobs list and absent turn allow idle'
before="$(wc -l < "$SENDS" | tr -d ' ')"
SYNC_JSON='{"interrogatives":[],"turn":"busy"}'
notify_watcher_message_complete "$TMP/session" sess '{"event":{"type":"message_complete","prompt_id":"p-invalid-turn"}}'
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'unknown sync turn scalar suppresses idle'

# Reminder expiry follows the source: one 300s delay, no /sync expiry poll.
NOTIFY_WATCHER_TEST_SYNC=1
: > "$PROBE_PATHS"; before="$(wc -l < "$SENDS" | tr -d ' ')"
NOTIFY_WATCHER_STATE_ROOT="$TMP/question-state"
state="$NOTIFY_WATCHER_STATE_ROOT/watch/sess"
mkdir -p "$state"
notify_watcher_probe(){ printf '%s\n' "$2" >> "$PROBE_PATHS"; return 1; }
sleep_record(){ printf '%s\n' "$1" > "$TMP/reminder-delay"; }
NOTIFY_WATCHER_SLEEP=sleep_record
: > "$PROBE_PATHS"; probe_count_before="$(wc -l < "$PROBE_PATHS" | tr -d ' ')"
notify_watcher_question_arm "$TMP/session" sess q-expiry 'answer me'
question_state="$NOTIFY_WATCHER_STATE_ROOT/watch/sess"
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$((before+1))" ]' 'armed question sends exactly one delayed reminder'
assert '[ "$(cat "$TMP/reminder-delay")" = 300 ]' 'reminder waits the 300s default'
assert 'grep -q "still waiting for your answer: answer me" "$SENDS"' 'reminder body is bounded question text'
probe_count_after="$(wc -l < "$PROBE_PATHS" | tr -d ' ')"
assert '[ "$probe_count_after" = "$probe_count_before" ]' 'reminder expiry performs no probes'
first_ticket="$(cat "$question_state/question-ticket")"
notify_watcher_question_arm "$TMP/session" sess q-expiry 'duplicate frame'
assert '[ "$(cat "$question_state/question-ticket")" = "$first_ticket" ]' 'duplicate same-ID frame does not reset reminder timer'
assert '[ "$(grep -c "question_reminder" "$SENDS")" = 1 ]' 'duplicate same-ID frame cannot send twice'
# A new interrogative supersedes the previous armed token.
replace_new(){ printf '%s\n' 'epoch-2.q-new.replacement' > "$question_state/question-ticket"; }
NOTIFY_WATCHER_SLEEP=replace_new
before="$(wc -l < "$SENDS" | tr -d ' ')"
notify_watcher_question_arm "$TMP/session" sess q-old 'old question'
assert '[ "$(cat "$question_state/question-ticket")" = epoch-2.q-new.replacement ]' 'new question replaces prior reminder ticket'
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'superseded question reminder stays silent'
NOTIFY_WATCHER_SLEEP=true

# Fake delay callbacks invalidate the still-armed entry before expiry.
before="$(wc -l < "$SENDS" | tr -d ' ')"
cancel_at_delay(){ notify_watcher_question_cancel sess; }
NOTIFY_WATCHER_SLEEP=cancel_at_delay
notify_watcher_question_arm "$TMP/session" sess q-cancel 'cancel me'
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'observed cancellation suppresses armed reminder'
replace_at_delay(){ printf '%s' '{"session_id":"sess","port":1234,"daemon_epoch":"epoch-3"}' > "$TMP/session/startup.json"; }
NOTIFY_WATCHER_SLEEP=replace_at_delay
notify_watcher_question_arm "$TMP/session" sess q-epoch 'epoch question'
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'generation replacement suppresses armed reminder'
epoch_ticket="$(cat "$question_state/question-ticket")"
# Restart-drop: persisted question ticket alone does not reconstruct a worker.
NOTIFY_WATCHER_PROCESS_GENERATION='new-process-generation'; export NOTIFY_WATCHER_PROCESS_GENERATION
startup_epoch="$(_nws_current_epoch "$TMP/session")"
assert '[ "$startup_epoch" != "$epoch_ticket" ]' 'new watcher process has a distinct generation from armed timer'

# Stream wiring: observed resolution/cancellation/activity disarm the current
# question; question content alone never emits an immediate Pushover signal.
NOTIFY_WATCHER_SLEEP=false
notify_watcher_curl_args(){ printf '%s\n' -sS -N --max-time 0 -H 'Authorization: Bearer fake' 'http://127.0.0.1:1234/events'; }
stream_stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
curl(){ printf 'data: {"seq":1,"session_id":"sess","emitted_at":"%s","event":{"type":"ask_user_question","interrogative_id":"stream-q","payload":{"questions":[{"question":"Choose"}]}}}\n' "$stream_stamp"; printf 'data: {"seq":2,"session_id":"sess","emitted_at":"%s","event":{"type":"%s","resolved":true,"prompt_id":"fresh-prompt"}}\n' "$stream_stamp" "$STREAM_INVALIDATOR"; }
for STREAM_INVALIDATOR in interrogative_resolved turn_cancelled pending_turn_input_queued; do
  stream_root="$TMP/stream-$STREAM_INVALIDATOR"; NOTIFY_WATCHER_STATE_ROOT="$stream_root"
  notify_watcher_stream "$TMP/session"
  stream_ticket="$(cat "$stream_root/watch/sess/question-ticket" 2>/dev/null || true)"
  case "$stream_ticket" in cancel.*) ok "stream $STREAM_INVALIDATOR invalidates armed reminder";; *) no "stream $STREAM_INVALIDATOR invalidates armed reminder";; esac
done
STREAM_INVALIDATOR=assistant_text
NOTIFY_WATCHER_STATE_ROOT="$TMP/stream-assistant-text"
notify_watcher_stream "$TMP/session"
stream_epoch="$(_nws_current_epoch "$TMP/session")"
case "$(cat "$NOTIFY_WATCHER_STATE_ROOT/watch/sess/question-ticket" 2>/dev/null || true)" in "$stream_epoch.stream-q."*) ok 'assistant output does not invalidate pending question';; *) no 'assistant output does not invalidate pending question';; esac
NOTIFY_WATCHER_STATE_ROOT="$TMP/question-state"
# The signal path rejects replay/stale/wrong-session frames before arming.
mkdir -p "$TMP/question-state/watch/sess"
printf 'seq 12\nclock 0\n' > "$TMP/question-state/watch/sess/cursor"
now_epoch="$(date +%s)"
now_stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
replay_frame="$(jq -nc --arg t "$now_stamp" '{seq:12,session_id:"sess",emitted_at:$t,event:{type:"message_complete",prompt_id:"p-replay"}}')"
if _nw_signal_eligible "$TMP/session" "$replay_frame" "$now_epoch"; then no 'duplicate seq cannot arm idle candidate'; else ok 'duplicate seq cannot arm idle candidate'; fi
fresh_frame="$(jq -nc --arg t "$now_stamp" '{seq:13,session_id:"sess",emitted_at:$t,event:{type:"message_complete",prompt_id:"p-fresh"}}')"
if _nw_signal_eligible "$TMP/session" "$fresh_frame" "$now_epoch"; then ok 'fresh sequenced frame is signal-eligible'; else no 'fresh sequenced frame is signal-eligible'; fi
if _nw_signal_eligible "$TMP/session" "$(jq -c '.session_id="other"' <<<"$fresh_frame")" "$now_epoch"; then no 'wrong session cannot arm signal'; else ok 'wrong session cannot arm signal'; fi
if _nw_signal_eligible "$TMP/session" "$(jq -c '.emitted_at="2020-01-01T00:00:00Z"' <<<"$fresh_frame")" "$now_epoch"; then no 'stale frame cannot arm signal'; else ok 'stale frame cannot arm signal'; fi
# Malformed message_complete has no valid activity evidence; it must not disarm.
NOTIFY_WATCHER_STATE_ROOT="$TMP/invalid-message-state"; mkdir -p "$NOTIFY_WATCHER_STATE_ROOT/watch/sess"
printf 'armed\n' > "$NOTIFY_WATCHER_STATE_ROOT/watch/sess/question-ticket"
STREAM_INVALIDATOR=message_complete
curl(){ printf 'data: {"seq":1,"session_id":"sess","emitted_at":"%s","event":{"type":"message_complete","prompt_id":42}}\n' "$stream_stamp"; }
notify_watcher_stream "$TMP/session"
assert '[ "$(cat "$NOTIFY_WATCHER_STATE_ROOT/watch/sess/question-ticket")" = armed ]' 'invalid message_complete does not cancel reminder'
NOTIFY_WATCHER_STATE_ROOT="$TMP/question-state"

# Strict goal response rejects malformed lifecycle and truncates title to 200 chars.
if printf '%s' '{"current_goal":{"id":"x","lifecycle":"weird"}}' | notify_watcher_goal_parse >/dev/null 2>&1; then no 'invalid lifecycle rejected'; else ok 'invalid lifecycle rejected'; fi
# Epoch replacement silently reseeds goal state and fences the old episode.
goal_send_count="$(wc -l < "$SENDS" | tr -d ' ')"
printf '%s' '{"session_id":"sess","port":1234,"daemon_epoch":"epoch-2"}' > "$TMP/session/startup.json"
GOAL_JSON='{"current_goal":{"id":"g2","lifecycle":"active"}}'
notify_watcher_goal_tick "$TMP/session" sess
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$goal_send_count" ]' 'epoch replacement cold-seeds without duplicate alert'
# An overlapping new watcher may take ownership while an old /goal probe is
# in flight. The old result must not overwrite its newly seeded baseline.
prior_process_generation="$NOTIFY_WATCHER_PROCESS_GENERATION"
NOTIFY_WATCHER_PROCESS_GENERATION=old-goal-poller
NOTIFY_WATCHER_STATE_ROOT="$TMP/goal-overlap-state"
notify_watcher_probe(){ [ "$2" = /goal ] && printf '%s' '{"current_goal":{"id":"g-overlap","lifecycle":"active"}}'; }
notify_watcher_goal_tick "$TMP/session" sess
assert '[ -s "$NOTIFY_WATCHER_STATE_ROOT/watch/sess/goal-state" ]' 'goal overlap fixture seeds valid prior state'
notify_watcher_probe(){
  if [ "$2" = /goal ]; then
    printf 'new-goal-poller\n' > "$NOTIFY_WATCHER_STATE_ROOT/watch/sess/process-generation"
    printf 'new-baseline\n' > "$NOTIFY_WATCHER_STATE_ROOT/watch/sess/goal-state"
    printf '%s' '{"current_goal":{"id":"g-overlap","lifecycle":"completed"}}'
  else return 1; fi
}
before="$(wc -l < "$SENDS" | tr -d ' ')"
notify_watcher_goal_tick "$TMP/session" sess
assert '[ "$(cat "$NOTIFY_WATCHER_STATE_ROOT/watch/sess/goal-state")" = new-baseline ] && [ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'stale goal probe cannot overwrite new watcher baseline or send'
# Independently change daemon metadata during a probe while the same watcher
# process still owns state; persisted epoch is still old until another tick.
NOTIFY_WATCHER_STATE_ROOT="$TMP/goal-epoch-overlap-state"
printf '%s' '{"session_id":"sess","port":1234,"daemon_epoch":"epoch-before"}' > "$TMP/session/startup.json"
notify_watcher_probe(){ [ "$2" = /goal ] && printf '%s' '{"current_goal":{"id":"g-epoch","lifecycle":"active"}}'; }
notify_watcher_goal_tick "$TMP/session" sess
notify_watcher_probe(){
  if [ "$2" = /goal ]; then
    printf '%s' '{"session_id":"sess","port":1234,"daemon_epoch":"epoch-after"}' > "$TMP/session/startup.json"
    printf '%s' '{"current_goal":{"id":"g-epoch","lifecycle":"completed"}}'
  else return 1; fi
}
before="$(wc -l < "$SENDS" | tr -d ' ')"
notify_watcher_goal_tick "$TMP/session" sess
assert '[ "$(cat "$NOTIFY_WATCHER_STATE_ROOT/watch/sess/goal-state")" != *completed* ] && [ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'daemon epoch rollover during probe cannot commit stale goal or send'
NOTIFY_WATCHER_PROCESS_GENERATION="$prior_process_generation"
NOTIFY_WATCHER_STATE_ROOT="$TMP/question-state"
# Null epoch is permitted by source metadata; process-local fallback is stable in-process.
printf '%s' '{"session_id":"sess","port":1234}' > "$TMP/session/startup.json"
first_epoch="$(_nws_current_epoch "$TMP/session")"
second_epoch="$(_nws_current_epoch "$TMP/session")"
assert '[ "$first_epoch" = "$second_epoch" ]' 'missing daemon_epoch uses stable process-local generation'
printf '%s\n' "$first_epoch" > "$question_state/epoch"
printf 'armed\n' > "$question_state/question-ticket"
NOTIFY_WATCHER_PROCESS_GENERATION="${first_epoch##*:}"; export NOTIFY_WATCHER_PROCESS_GENERATION
notify_watcher_shutdown
assert '[ "$(cat "$question_state/question-ticket")" != armed ]' 'watcher shutdown invalidates in-memory reminder ticket'
# A stable explicit daemon_epoch must not let an old detached worker send after
# watcher-process replacement. The fake delay performs the replacement before
# the real callback resumes; both timer families use this same process fence.
NOTIFY_WATCHER_STATE_ROOT="$TMP/restart-state"
printf '%s' '{"session_id":"sess","port":1234,"daemon_epoch":"stable-epoch"}' > "$TMP/session/startup.json"
NOTIFY_WATCHER_PROCESS_GENERATION=old-watcher
restart_at_delay(){ printf 'new-watcher\n' > "$NOTIFY_WATCHER_STATE_ROOT/watch/sess/process-generation"; }
NOTIFY_WATCHER_SLEEP=restart_at_delay
before="$(wc -l < "$SENDS" | tr -d ' ')"
notify_watcher_question_arm "$TMP/session" sess q-restart 'do not send'
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'outstanding reminder drops on watcher restart with stable epoch'
NOTIFY_WATCHER_PROCESS_GENERATION=old-watcher
restart_probe_calls="$(wc -l < "$PROBE_PATHS" | tr -d ' ')"
notify_watcher_message_complete "$TMP/session" sess '{"event":{"type":"message_complete","prompt_id":"p-restart"}}'
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'outstanding idle check drops on watcher restart with stable epoch'
assert '[ "$(wc -l < "$PROBE_PATHS" | tr -d " ")" = "$restart_probe_calls" ]' 'restart fence suppresses idle before any probe'
# R4: invalidate at the final lock boundary, after the timer's initial checks.
NOTIFY_WATCHER_STATE_ROOT="$TMP/final-check-state"
NOTIFY_WATCHER_PROCESS_GENERATION=final-check-owner
NOTIFY_WATCHER_SLEEP=true
_nws_lock_original="$(declare -f _nws_lock)"
eval "${_nws_lock_original/_nws_lock ()/_nws_lock_real ()}"
final_check_acquires=0
_nws_lock(){
  final_check_acquires=$((final_check_acquires+1))
  if [ "$final_check_acquires" = 2 ]; then
    _nws_lock_real "$1" || return 1
    printf 'invalidated\n' > "$1/question-ticket"
    _nws_unlock "$1"
  fi
  _nws_lock_real "$1"
}
before="$(wc -l < "$SENDS" | tr -d ' ')"
notify_watcher_question_arm "$TMP/session" sess q-final-check 'must suppress'
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'final locked reminder check suppresses pre-claim invalidation'
# Idle has the same final check/claim boundary after all three valid probes.
NOTIFY_WATCHER_STATE_ROOT="$TMP/final-idle-state"
NOTIFY_WATCHER_PROCESS_GENERATION=final-idle-owner
IDLE_GOAL_JSON='{"current_goal":null}'; JOBS_JSON='{"jobs":[]}'; SYNC_JSON='{"interrogatives":[],"turn":{}}'
notify_watcher_probe(){ case "$2" in /goal) printf '%s' "$IDLE_GOAL_JSON";; /jobs) printf '%s' "$JOBS_JSON";; /sync) printf '%s' "$SYNC_JSON";; esac; }
_nws_lock(){
  final_check_acquires=$((final_check_acquires+1))
  if [ "$final_check_acquires" = 2 ]; then
    _nws_lock_real "$1" || return 1
    printf 'invalidated\n' > "$1/idle-ticket"
    _nws_unlock "$1"
  fi
  _nws_lock_real "$1"
}
final_check_acquires=0
before="$(wc -l < "$SENDS" | tr -d ' ')"
notify_watcher_message_complete "$TMP/session" sess '{"event":{"type":"message_complete","prompt_id":"p-final-idle"}}'
assert '[ "$(wc -l < "$SENDS" | tr -d " ")" = "$before" ]' 'final locked idle check suppresses pre-claim invalidation'
assert '[ ! -e "$NOTIFY_WATCHER_STATE_ROOT/claims/sess/claim.turn_stable-epoch_p-final-idle_idle" ]' 'invalidated idle episode was not claimed'
eval "$_nws_lock_original"
# R2: old shutdown waiting for the lock must not overwrite a new owner's
# generation or freshly armed ticket after the new owner releases the lock.
NOTIFY_WATCHER_STATE_ROOT="$TMP/overlap-state"
NOTIFY_WATCHER_PROCESS_GENERATION=new-watcher
NOTIFY_WATCHER_SLEEP=false
notify_watcher_question_arm "$TMP/session" sess q-overlap 'new owner'
overlap_state="$NOTIFY_WATCHER_STATE_ROOT/watch/sess"
overlap_ticket="$(cat "$overlap_state/question-ticket")"
_nws_lock "$overlap_state"
( NOTIFY_WATCHER_PROCESS_GENERATION=old-watcher; NWS_LOCK_OWNER=''; notify_watcher_shutdown ) & overlap_pid=$!
sleep 0.1
_nws_unlock "$overlap_state"
wait "$overlap_pid"
assert '[ "$(cat "$overlap_state/process-generation")" = new-watcher ] && [ "$(cat "$overlap_state/question-ticket")" = "$overlap_ticket" ]' 'old shutdown cannot invalidate new watcher ticket after lock handoff'
# Best-effort stale-owner recovery is operator-approved; no stale lock may
# permanently suppress a session after its owner dies. The two-reclaimer
# successor-unlink race remains a documented accepted risk, not a guarantee.
stale_state="$TMP/stale-lock/watch/sess"; mkdir -p "$stale_state/.signal-owner.dead"
printf '99999999\n' > "$stale_state/.signal-owner.dead/pid"
ln -s .signal-owner.dead "$stale_state/.signal-lock"
if _nws_lock "$stale_state"; then
  [ "$(readlink "$stale_state/.signal-lock")" != .signal-owner.dead ] && ok 'dead lock owner is reclaimed for unattended recovery' || no 'dead lock owner is reclaimed for unattended recovery'
  _nws_unlock "$stale_state"
else
  no 'dead lock owner is reclaimed for unattended recovery'
fi
NOTIFY_WATCHER_STATE_ROOT="$TMP/question-state"
large="$(printf 'x%.0s' {1..240})"
row="$(printf '%s' "{\"current_goal\":{\"id\":\"x\",\"lifecycle\":\"completed\",\"summary\":\"$large\"}}" | notify_watcher_goal_parse)"
assert '[ "${#row}" -le 220 ]' 'goal title response is bounded'

# Probe client constructs exact loopback/Bearer request with timeout and byte cap.
mkdir -p "$TMP/probe"; jq -n --arg cred "$TMP/probe/credential.json" '{state:"ready",session_id:"sess",port:43123,credential_file_path:$cred,daemon_epoch:"epoch-2"}' > "$TMP/probe/startup.json"
printf '%s' '{"token":"probe-secret"}' > "$TMP/probe/credential.json"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$PROBE_CALLS"\nwhile [ "$#" -gt 0 ]; do [ "$1" = -o ] && { shift; printf "{}" > "$1"; break; }; shift; done\n' > "$TMP/curl-probe"
chmod +x "$TMP/curl-probe"; PROBE_CALLS="$TMP/probe-calls"
NOTIFY_WATCHER_CURL="$TMP/curl-probe" PROBE_CALLS="$PROBE_CALLS" bash -c 'source "$1"; notify_watcher_probe "$2" /goal >/dev/null' _ "$REPO/home/lib/notify-watcher-signals.sh" "$TMP/probe"
probe_call="$(cat "$PROBE_CALLS")"
case "$probe_call" in *'Authorization: Bearer probe-secret'*) auth_ok=1;; *) auth_ok=0;; esac
case "$probe_call" in *'--max-time 5'*) timeout_ok=1;; *) timeout_ok=0;; esac
case "$probe_call" in *'--max-filesize 65536'*) size_ok=1;; *) size_ok=0;; esac
case "$probe_call" in *'http://127.0.0.1:43123/goal'*) endpoint_ok=1;; *) endpoint_ok=0;; esac
[ "$auth_ok" = 1 ] && [ "$timeout_ok" = 1 ] && [ "$size_ok" = 1 ] && [ "$endpoint_ok" = 1 ] && ok 'probe uses Bearer, explicit timeout/size, exact loopback endpoint' || no 'probe uses Bearer, explicit timeout/size, exact loopback endpoint'
case "$probe_call" in *'/sync'*) no 'goal probe uses only requested endpoint';; *) ok 'goal probe uses only requested endpoint';; esac
# Probe failures, oversized response, malformed JSON stay silent and redacted.
printf '#!/usr/bin/env bash\nexit 22\n' > "$TMP/curl-fail"; chmod +x "$TMP/curl-fail"
if NOTIFY_WATCHER_CURL="$TMP/curl-fail" bash -c 'source "$1"; notify_watcher_probe "$2" /goal' _ "$REPO/home/lib/notify-watcher-signals.sh" "$TMP/probe" >/dev/null 2>&1; then no 'HTTP/timeout probe failure is rejected'; else ok 'HTTP/timeout probe failure is rejected'; fi
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done\nprintf "%%s" "$RAW" > "$out"\n' > "$TMP/curl-body"; chmod +x "$TMP/curl-body"
RAW="$(printf 'x%.0s' {1..65537})"; export RAW
if NOTIFY_WATCHER_CURL="$TMP/curl-body" bash -c 'source "$1"; notify_watcher_probe "$2" /goal' _ "$REPO/home/lib/notify-watcher-signals.sh" "$TMP/probe" >/dev/null 2>&1; then no 'oversized response rejected'; else ok 'oversized response rejected'; fi
RAW='not-json'; export RAW
if NOTIFY_WATCHER_CURL="$TMP/curl-body" bash -c 'source "$1"; body="$(notify_watcher_probe "$2" /goal)"; printf "%s" "$body" | jq -e . >/dev/null' _ "$REPO/home/lib/notify-watcher-signals.sh" "$TMP/probe" >/dev/null 2>&1; then no 'malformed JSON response rejected'; else ok 'malformed JSON response rejected'; fi
[ ! -s "${AGENT_NOTIFY_LOG_DIR:-/nonexistent}/notify.log" ] 2>/dev/null || ! grep -Eq 'probe-secret|not-json' "${AGENT_NOTIFY_LOG_DIR:-/nonexistent}/notify.log" && ok 'probe diagnostics do not reveal credential or raw body' || no 'probe diagnostics do not reveal credential or raw body'
# Pushover-only sender has no Notification Center path; ordinary sender remains dual-channel.
awk '/notify_send_pushover_only\(\)/,/^}/' "$REPO/home/lib/notify-send.sh" > "$TMP/po-only"
if grep -q 'notify_mac_send' "$TMP/po-only"; then no 'quiet sender avoids Notification Center'; else ok 'quiet sender avoids Notification Center'; fi
grep -q 'notify_mac_send' "$REPO/home/lib/notify-send.sh" && ok 'ordinary sender retains Notification Center' || no 'ordinary sender retains Notification Center'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
