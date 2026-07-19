#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/home/skill-once/hook.sh"
COMPACT="$ROOT/home/skill-once/compact.sh"
FIX="$ROOT/scripts/fixtures/skill-once"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/config"; mkdir -p "$CFG"
run() { printf '%s' "$1" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" SKILL_ONCE_TTL="${2:-1800}" bash "$HOOK"; }
cache() { find "$CFG/skill-once" -name 'session-*.jsonl' -print -quit 2>/dev/null || true; }
rows() { local f; f="$(cache)"; [ -n "$f" ] && wc -l < "$f" | tr -d ' ' || printf '0'; }
pre="$(cat "$FIX/pre-example.json")"
post="$(cat "$FIX/post-example.json")"
fail_event="$(cat "$FIX/failure-example.json")"

# Shared state helper API smoke contract.
helper_tmp="$TMP/helper"; mkdir -p "$helper_tmp/config"
helper_script="$helper_tmp/caller.sh"
expected_helper_hash='78f3de8059006939'
expected_helper_cache="$helper_tmp/config/skill-once/session-$expected_helper_hash.jsonl"
expected_helper_session_lock="$helper_tmp/config/skill-once/.session-$expected_helper_hash.lock"
expected_helper_cleanup_lock="$helper_tmp/config/skill-once/.cleanup.lock"
printf '%s\n' 'set -euo pipefail' '. "$1/state.sh"' 'skill_once_init helper-session' 'test "${#SKILL_ONCE_SESSION_HASH}" -eq 16' 'test "$SKILL_ONCE_SESSION_HASH" = "78f3de8059006939"' 'test "$SKILL_ONCE_CACHE_FILE" = "$2/skill-once/session-78f3de8059006939.jsonl"' 'test "$SKILL_ONCE_SESSION_LOCK" = "$2/skill-once/.session-78f3de8059006939.lock"' 'test "$SKILL_ONCE_CLEANUP_LOCK" = "$2/skill-once/.cleanup.lock"' 'test "$SKILL_ONCE_CACHE_FILE" = "$3"' 'test "$SKILL_ONCE_SESSION_LOCK" = "$4"' 'test "$SKILL_ONCE_CLEANUP_LOCK" = "$5"' 'skill_once_lock helper' 'skill_once_append '\''{"skill":"helper","agent":"main","ts":1}'\''' 'test "$(wc -l < "$SKILL_ONCE_CACHE_FILE" | tr -d " ")" -eq 1' 'skill_once_remove helper main' 'test ! -s "$SKILL_ONCE_CACHE_FILE"' 'skill_once_append '\''{"skill":"helper","agent":"main","ts":1}'\''' 'skill_once_clear' 'test ! -e "$SKILL_ONCE_CACHE_FILE"' 'skill_once_exit_cleanup' >"$helper_script"
HOME="$TMP/home" AGENT_CONFIG_DIR="$helper_tmp/config" bash "$helper_script" "$ROOT/home/skill-once" "$helper_tmp/config" "$expected_helper_cache" "$expected_helper_session_lock" "$expected_helper_cleanup_lock"
test -z "$(find "$helper_tmp/config/skill-once" -maxdepth 1 \( -name '.session-*.lock' -o -name '.cleanup.lock' -o -name '.force.*' \) -print -quit 2>/dev/null)"

# Isolated adapter setup/source failures fail open without diagnostics or runtime artifacts.
adapter_failure_tmp="$TMP/adapter-failures"
for adapter_name in hook compact; do
  adapter_source="$ROOT/home/skill-once/$adapter_name.sh"
  adapter_input='{"session_id":"adapter-failure-session","hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"example"}}'
  [ "$adapter_name" = compact ] && adapter_input='{"session_id":"adapter-failure-session"}'
  for helper_mode in missing invalid; do
    adapter_dir="$adapter_failure_tmp/$adapter_name-$helper_mode"
    mkdir -p "$adapter_dir/home" "$adapter_dir/config"
    cp "$adapter_source" "$adapter_dir/$adapter_name.sh"
    case "$helper_mode" in
      missing) rm -f "$adapter_dir/state.sh" ;;
      invalid) printf '%s\\n' 'return 17' >"$adapter_dir/state.sh" ;;
    esac
    : >"$adapter_dir/stderr"
    before_snapshot="$(find "$adapter_dir" -mindepth 1 -print | sort)"
    set +e
    adapter_stdout="$(printf '%s' "$adapter_input" | HOME="$adapter_dir/home" AGENT_CONFIG_DIR="$adapter_dir/config" bash "$adapter_dir/$adapter_name.sh" 2>"$adapter_dir/stderr")"
    adapter_rc=$?
    set -e
    after_snapshot="$(find "$adapter_dir" -mindepth 1 -print | sort)"
    test "$adapter_rc" -eq 0
    test -z "$adapter_stdout"
    test ! -s "$adapter_dir/stderr"
    test "$after_snapshot" = "$before_snapshot"
    test -z "$(find "$adapter_dir" -type f \( -name 'session-*.jsonl' -o -name '.session-*.lock' -o -name '.cleanup.lock' -o -name '*.trace' -o -name 'acquired' -o -name 'hold' -o -name 'released' \) -print -quit)"
  done
done

# Missing helper dependencies and unreadable helper setup fail open silently.
failopen_tmp="$TMP/failopen"; mkdir -p "$failopen_tmp/home" "$failopen_tmp/config"
for missing_cmd in seq cat grep tail; do
  missing_bin="$failopen_tmp/bin-$missing_cmd"; mkdir -p "$missing_bin"
  for cmd in bash dirname date find jq mkdir mktemp mv rm rmdir sha256sum sleep cut; do ln -s "$(command -v "$cmd")" "$missing_bin/$cmd"; done
  before="$(find "$failopen_tmp/config" -print | sort)"
  set +e
  failout="$(printf '%s' "$post" | PATH="$missing_bin" HOME="$failopen_tmp/home" AGENT_CONFIG_DIR="$failopen_tmp/config" /bin/bash "$HOOK" 2>"$failopen_tmp/err")"; failrc=$?
  set -e
  test "$failrc" -eq 0; test -z "$failout"; test ! -s "$failopen_tmp/err"
  test "$(find "$failopen_tmp/config" -print | sort)" = "$before"
done
unreadable_cfg="$failopen_tmp/unreadable"; mkdir -p "$unreadable_cfg/skill-once"; chmod 000 "$unreadable_cfg/skill-once"
set +e
failout="$(printf '%s' "$post" | HOME="$failopen_tmp/home" AGENT_CONFIG_DIR="$unreadable_cfg" bash "$HOOK" 2>"$failopen_tmp/err")"; failrc=$?
set -e
chmod 700 "$unreadable_cfg/skill-once"
test "$failrc" -eq 0; test -z "$failout"; test ! -s "$failopen_tmp/err"
other_skill="$(cat "$FIX/pre-other-skill.json")"
other_agent="$(cat "$FIX/pre-other-agent.json")"

# Pre-check and explicit failure sequence never record success; retry remains allowed.
test -z "$(run "$pre")"
test "$(rows)" = 0
test -z "$(run "$fail_event")"
test "$(rows)" = 0
test -z "$(run "$pre")"

# Event selection proves success; tool_response content is irrelevant.
test -z "$(run "$post")"
test "$(rows)" = 1
jq -e 'select(.skill=="example" and .agent=="agent-a" and (.ts|type)=="number")' "$(cache)" >/dev/null
out="$(run "$pre")"
jq -e '.hookSpecificOutput.hookEventName=="PreToolUse" and .hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason|contains("successfully loaded"))' <<<"$out" >/dev/null
test -z "$(run "$other_skill")"
test -z "$(run "$other_agent")"
test -z "$(run "$(jq '.hook_event_name="PostToolUse"' <<<"$other_agent")")"
test "$(rows)" = 2

# Force removes only the matching prior success and never creates a replacement.
force="$(jq '.hook_event_name="PreToolUse" | .tool_input.args="--force"' <<<"$pre")"
test -z "$(run "$force")"
test "$(rows)" = 1
test -z "$(run "$pre")"
test "$(rows)" = 1

# A post-success refresh restores denial. Expiration itself does not append.
run "$post" >/dev/null
now="$(date +%s)"
jq -c --argjson old "$((now - 2))" 'if .skill=="example" and .agent=="agent-a" then .ts=$old else . end' "$(cache)" > "$(cache).tmp"
mv "$(cache).tmp" "$(cache)"
test -z "$(run "$pre" 1)"
test "$(rows)" = 2
run "$post" 1 >/dev/null
test "$(rows)" = 3
jq -e '.hookSpecificOutput.permissionDecision=="deny"' <<<"$(run "$pre" 1800)" >/dev/null

# Missing fields, unrelated tools/events, and disabled mode fail open without rows.
before="$(rows)"
for payload in \
  '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"s","tool_input":{"skill":""}}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"","tool_input":{"skill":"example"}}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Read","session_id":"s","tool_input":{"skill":"example"}}' \
  '{"hook_event_name":"Notification","tool_name":"Skill","session_id":"s","tool_input":{"skill":"example"}}' \
  '{"hook_event_name":{"bad":true},"tool_name":"Skill","session_id":"s","tool_input":{"skill":"example"}}' \
  '{"hook_event_name":null,"tool_name":"Skill","session_id":"s","tool_input":{"skill":"example"}}' \
  '{"hook_event_name":"PostToolUse","tool_name":{"bad":true},"session_id":"s","tool_input":{"skill":"example"}}' \
  '{"hook_event_name":"PostToolUse","tool_name":null,"session_id":"s","tool_input":{"skill":"example"}}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":["s"],"tool_input":{"skill":"example"}}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":null,"tool_input":{"skill":"example"}}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"s","tool_input":[{"skill":"example"}]}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"s","tool_input":null}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"s","tool_input":{"skill":{"bad":true}}}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"s","tool_input":{"skill":null}}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"s","agent_id":["agent"],"tool_input":{"skill":"example"}}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"s","agent_id":null,"tool_input":{"skill":"example"}}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"s","tool_input":{"skill":"example","args":false}}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"s","tool_input":{"skill":"example","args":null}}' \
  '[]' \
  '{bad json'; do
  set +e
  malformed_out="$(run "$payload")"; malformed_rc=$?
  set -e
  test "$malformed_rc" -eq 0
  test -z "$malformed_out"
done
test "$(rows)" = "$before"
set +e
invalid_ttl_out="$(printf '%s' "$post" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" SKILL_ONCE_TTL=not-a-number bash "$HOOK")"; invalid_ttl_rc=$?
set -e
test "$invalid_ttl_rc" -eq 0
test -z "$invalid_ttl_out"
test "$(rows)" = "$before"
invalid_cfg="$TMP/invalid-ttl-config"
test ! -e "$invalid_cfg"
printf '%s' "$post" | HOME="$TMP/home" AGENT_CONFIG_DIR="$invalid_cfg" SKILL_ONCE_TTL=not-a-number bash "$HOOK" >/dev/null
test ! -e "$invalid_cfg"
test -z "$(printf '%s' "$post" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" SKILL_ONCE_DISABLED=1 bash "$HOOK")"
test "$(rows)" = "$before"
test -z "$(printf '%s' "$post" | PATH=/nonexistent HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" /bin/bash "$HOOK")"
test "$(rows)" = "$before"

# Main and subagent keys remain independent.
main_post="$(jq 'del(.agent_id)' <<<"$post")"
run "$main_post" >/dev/null
jq -e '.hookSpecificOutput.permissionDecision=="deny"' <<<"$(run "$(jq 'del(.agent_id) | .hook_event_name="PreToolUse"' <<<"$pre")")" >/dev/null

# Concurrent successful posts append both different agents.
concurrent_session="concurrent-session"
pa="$(jq --arg s "$concurrent_session" '.session_id=$s | .agent_id="concurrent-a"' <<<"$post")"
pb="$(jq --arg s "$concurrent_session" '.session_id=$s | .agent_id="concurrent-b"' <<<"$post")"
printf '%s' "$pa" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$HOOK" & p1=$!
printf '%s' "$pb" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$HOOK" & p2=$!
wait "$p1"; wait "$p2"
concurrent_file="$(grep -l 'concurrent-a' "$CFG"/skill-once/session-*.jsonl)"
jq -s -e 'map(select(.skill=="example")|.agent) | index("concurrent-a") != null and index("concurrent-b") != null' "$concurrent_file" >/dev/null

# Deterministic concurrency: a PostToolUse racing force must preserve unrelated rows and JSON integrity.
race_session="post-force-session"
race_hash="$(printf '%s' "$race_session" | sha256sum | cut -c1-16)"
race_lock="$CFG/skill-once/.session-${race_hash}.lock"
race_a="$(jq --arg s "$race_session" '.session_id=$s | .agent_id="race-a"' <<<"$post")"
race_b="$(jq --arg s "$race_session" '.session_id=$s | .agent_id="race-b"' <<<"$post")"
race_c="$(jq --arg s "$race_session" '.session_id=$s | .agent_id="race-c"' <<<"$post")"
printf '%s' "$race_a" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$HOOK"
printf '%s' "$race_b" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$HOOK"
race_force="$(jq --arg s "$race_session" '.session_id=$s | .agent_id="race-a" | .hook_event_name="PreToolUse" | .tool_input.args="--force"' <<<"$post")"
mkdir "$race_lock"
printf '%s' "$race_c" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$HOOK" & race_post_pid=$!
sleep 0.05
printf '%s' "$race_force" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$HOOK" & race_force_pid=$!
sleep 0.1
kill -0 "$race_post_pid"; kill -0 "$race_force_pid"
rmdir "$race_lock"
wait "$race_post_pid"; wait "$race_force_pid"
race_file="$(find "$CFG/skill-once" -name 'session-*.jsonl' -print | while read -r f; do grep -q 'race-' "$f" && printf '%s\n' "$f" && break; done)"
test -n "$race_file"
jq -s -e 'all(.[]; type=="object") and (map(.agent) | index("race-a") == null) and (map(.agent) | index("race-b") != null) and (map(.agent) | index("race-c") != null)' "$race_file" >/dev/null
! grep -Fq '.force.' <(find "$CFG/skill-once" -maxdepth 1 -type f -printf '%f\n')

# Deterministic concurrent force operations preserve each other’s unrelated rows.
force_session="force-session"
force_hash="$(printf '%s' "$force_session" | sha256sum | cut -c1-16)"
force_lock="$CFG/skill-once/.session-${force_hash}.lock"
for agent in force-a force-b force-c; do
  jq --arg s "$force_session" --arg a "$agent" '.session_id=$s | .agent_id=$a' <<<"$post" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$HOOK"
done
mkdir "$force_lock"
force_pids=()
for agent in force-a force-b; do
  jq --arg s "$force_session" --arg a "$agent" '.session_id=$s | .agent_id=$a | .hook_event_name="PreToolUse" | .tool_input.args="--force"' <<<"$post" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$HOOK" &
  force_pids+=("$!")
done
sleep 0.1
kill -0 "${force_pids[0]}"; kill -0 "${force_pids[1]}"
rmdir "$force_lock"
wait "${force_pids[0]}"; wait "${force_pids[1]}"
force_file="$(find "$CFG/skill-once" -name 'session-*.jsonl' -print | while read -r f; do grep -q 'force-' "$f" && printf '%s\n' "$f" && break; done)"
jq -s -e 'all(.[]; type=="object") and (map(.agent) | index("force-a") == null) and (map(.agent) | index("force-b") == null) and ((map(select(.agent=="force-c")) | length) == 1)' "$force_file" >/dev/null

# A held lock is bounded and fails open rather than hanging.
held_session="held-session"
lock_dir="$CFG/skill-once/.session-$(printf '%s' "$held_session" | sha256sum | cut -c1-16).lock"
mkdir "$lock_dir"
held_before="$(rows)"
held_payload="$(jq --arg s "$held_session" '.session_id=$s' <<<"$post")"
set +e
lock_start="$(date +%s%N)"
held_out="$(timeout 5s bash -c 'printf "%s" "$1" | HOME="$2" AGENT_CONFIG_DIR="$3" bash "$4"' _ "$held_payload" "$TMP/home" "$CFG" "$HOOK")"
held_rc=$?
lock_elapsed=$((($(date +%s%N)-lock_start)/1000000))
set -e
rm -rf "$lock_dir"
test "$held_rc" -eq 0
test -z "$held_out"
test "$(rows)" = "$held_before"
test "$lock_elapsed" -lt 5000

# Compaction clears only its session; a later successful post recreates it.
compact_session="compact-post-session"
compact_hash="$(printf '%s' "$compact_session" | sha256sum | cut -c1-16)"
compact_file="$CFG/skill-once/session-${compact_hash}.jsonl"
jq --arg s "$compact_session" '.session_id=$s | .agent_id="compact-agent"' <<<"$post" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$HOOK"
printf '%s' "{\"session_id\":\"$compact_session\"}" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$COMPACT"
test ! -e "$compact_file"
printf '%s' "$(jq --arg s "$compact_session" '.session_id=$s | .agent_id="post-agent"' <<<"$post")" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$HOOK"
jq -s -e 'length == 1 and .[0].agent == "post-agent"' "$compact_file" >/dev/null
printf '%s' "{\"session_id\":\"$compact_session\"}" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$COMPACT"
test ! -e "$compact_file"

# Periodic cleanup removes stale session files but keeps current state.
stale="$CFG/skill-once/session-stale.jsonl"; printf '%s\n' '{"skill":"old","agent":"main","ts":1}' > "$stale"
touch -t 200001010000 "$stale"
printf '0\n' > "$CFG/skill-once/.last-cleanup"
run "$post" >/dev/null
test ! -e "$stale"
test -n "$(cache)"

# Compaction removes only the addressed session's state.
printf '%s' '{"session_id":"skill-once-session"}' | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$COMPACT"
test -z "$(grep -l 'agent-a' "$CFG"/skill-once/session-*.jsonl 2>/dev/null || true)"
test -e "$concurrent_file"
# Deterministic ordered race evidence (Task 3B). Every order is marker-driven.
TRACE="$TMP/trace"
mkdir -p "$TRACE"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
session_hash() { printf '%s' "$1" | sha256sum | cut -c1-16; }
session_file() { printf '%s/skill-once/session-%s.jsonl' "$CFG" "$(session_hash "$1")"; }
assert_clean_runtime() {
  ! find "$CFG/skill-once" -maxdepth 1 \( -name '.session-*.lock' -o -name '.cleanup.lock' -o -name '.force.*' \) -print -quit 2>/dev/null | grep -q .
  ! find "$TRACE" -maxdepth 1 \( -name '*.acquired' -o -name '*.hold' -o -name '*.released' -o -name '*.contending' \) -print -quit 2>/dev/null | grep -q .
}
start_op() {
  local op=$1 script=$2 payload=$3 out=$4 err=$5
  printf '%s' "$payload" | HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" \
    SKILL_ONCE_TEST_TRACE_DIR="$TRACE" SKILL_ONCE_TEST_OP_ID="$op" \
    bash "$script" >"$out" 2>"$err" &
  LAST_PID=$!
}
wait_marker() {
  local marker=$1 i=1
  while [ "$i" -le 500 ]; do
    [ -e "$marker" ] && return 0
    sleep 0.01
    i=$((i + 1))
  done
  fail "marker not observed: $marker"
}
reset_race() {
  rm -f "$CFG"/skill-once/session-*.jsonl "$CFG"/skill-once/.session-*.lock "$CFG"/skill-once/.cleanup.lock "$CFG"/skill-once/.force.* "$TRACE"/*
  : > "$CFG/skill-once/.last-cleanup"
}
assert_agents() {
  local file=$1 expected=$2
  jq -s -e --argjson expected "$expected" \
    'all(.[]; type=="object") and ([.[].agent]|sort)==($expected|sort) and length==($expected|length)' \
    "$file" >/dev/null
}
run_ordered_pair() {
  local first=$1 first_script=$2 first_payload=$3 second=$4 second_script=$5 second_payload=$6
  local real_mkdir second_lock wrapper_bin
  real_mkdir=$(command -v mkdir)
  second_lock="$CFG/skill-once/.session-$(session_hash "$(jq -r '.session_id' <<<"$first_payload")").lock"
  wrapper_bin="$TMP/mkdir-$second"
  mkdir -p "$wrapper_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'set -u' 'real_mkdir="'"$real_mkdir"'"' '"$real_mkdir" "$@"' 'rc=$?' 'if [ "$rc" -ne 0 ] && [ "$#" -eq 1 ] && [ "$1" = "'"$second_lock"'" ]; then' '  (set -C; : > "'"$TRACE/$second.contending"'" 2>/dev/null || true)' 'fi' 'exit "$rc"' >"$wrapper_bin/mkdir"
  chmod +x "$wrapper_bin/mkdir"
  : >"$TRACE/$first.hold"
  test -e "$TRACE/$first.hold" || fail "could not create hold marker: $first"
  start_op "$first" "$first_script" "$first_payload" "$TMP/$first.out" "$TMP/$first.err"; local p1=$LAST_PID
  wait_marker "$TRACE/$first.acquired"
  : >"$TRACE/$second.hold"
  PATH="$wrapper_bin:$PATH" start_op "$second" "$second_script" "$second_payload" "$TMP/$second.out" "$TMP/$second.err"; local p2=$LAST_PID
  wait_marker "$TRACE/$second.contending"
  test -d "$second_lock" || fail "first does not own exact shared session lock"
  [ ! -e "$TRACE/$second.acquired" ] || fail "$second acquired before $first released"
  rm "$TRACE/$first.hold"
  wait_marker "$TRACE/$first.released"
  wait_marker "$TRACE/$second.acquired"
  rm "$TRACE/$second.hold"
  wait "$p1"; wait "$p2"
  test ! -s "$TMP/$first.out"; test ! -s "$TMP/$first.err"
  test ! -s "$TMP/$second.out"; test ! -s "$TMP/$second.err"
  rm -f "$TRACE/$first.released" "$TRACE/$second.released" "$TRACE/$second.contending"
}

race_post() { jq --arg s "$1" --arg a "$2" '.session_id=$s | .agent_id=$a' <<<"$post"; }
race_force() { jq --arg s "$1" --arg a "$2" '.session_id=$s | .agent_id=$a | .hook_event_name="PreToolUse" | .tool_input.args="--force"' <<<"$post"; }
race_compact() { jq --arg s "$1" '.session_id=$s' <<<"{\"session_id\":\"$1\"}"; }

# post skill new vs force skill target: target,keep -> keep,new in both orders.
race_session=ordered-post-force
reset_race
printf '%s\n' '{"skill":"example","agent":"target","ts":1}' '{"skill":"example","agent":"keep","ts":1}' >"$(session_file "$race_session")"
run_ordered_pair post-new "$HOOK" "$(race_post "$race_session" new)" force-target "$HOOK" "$(race_force "$race_session" target)"
assert_agents "$(session_file "$race_session")" '["keep","new"]'; assert_clean_runtime
reset_race
printf '%s\n' '{"skill":"example","agent":"target","ts":1}' '{"skill":"example","agent":"keep","ts":1}' >"$(session_file "$race_session")"
run_ordered_pair force-target "$HOOK" "$(race_force "$race_session" target)" post-new "$HOOK" "$(race_post "$race_session" new)"
assert_agents "$(session_file "$race_session")" '["keep","new"]'; assert_clean_runtime

# force skill force-a vs force-b: force-a,force-b,keep -> keep in both orders.
race_session=ordered-force-force
reset_race
printf '%s\n' '{"skill":"example","agent":"force-a","ts":1}' '{"skill":"example","agent":"force-b","ts":1}' '{"skill":"example","agent":"keep","ts":1}' >"$(session_file "$race_session")"
run_ordered_pair force-a "$HOOK" "$(race_force "$race_session" force-a)" force-b "$HOOK" "$(race_force "$race_session" force-b)"
assert_agents "$(session_file "$race_session")" '["keep"]'; assert_clean_runtime
reset_race
printf '%s\n' '{"skill":"example","agent":"force-a","ts":1}' '{"skill":"example","agent":"force-b","ts":1}' '{"skill":"example","agent":"keep","ts":1}' >"$(session_file "$race_session")"
run_ordered_pair force-b "$HOOK" "$(race_force "$race_session" force-b)" force-a "$HOOK" "$(race_force "$race_session" force-a)"
assert_agents "$(session_file "$race_session")" '["keep"]'; assert_clean_runtime

# compact vs post skill new: old -> new when compact acquires first, absent when post acquires first.
race_session=ordered-compact-post
reset_race
printf '%s\n' '{"skill":"old","agent":"old","ts":1}' >"$(session_file "$race_session")"
run_ordered_pair compact "$COMPACT" "$(race_compact "$race_session")" post-new "$HOOK" "$(race_post "$race_session" new)"
assert_agents "$(session_file "$race_session")" '["new"]'; assert_clean_runtime
reset_race
printf '%s\n' '{"skill":"old","agent":"old","ts":1}' >"$(session_file "$race_session")"
run_ordered_pair post-new "$HOOK" "$(race_post "$race_session" new)" compact "$COMPACT" "$(race_compact "$race_session")"
test ! -e "$(session_file "$race_session")"; assert_clean_runtime

# cleanup vs active stale session: held target remains; released target is deleted later.
cleanup_session=ordered-cleanup; cleanup_hash=$(session_hash "$cleanup_session"); stale_file=$(session_file "$cleanup_session")
cleanup_holder="$TMP/cleanup-holder.sh"
cleanup_caller="$TMP/cleanup-caller.sh"
printf '%s\n' 'set -euo pipefail' '. "$1/state.sh"' 'skill_once_init "$2"' 'skill_once_lock cleanup-holder' 'printf acquired > "$3/acquired"' 'while [ -e "$3/cleanup-holder.hold" ]; do sleep 0.01; done' 'set +e' 'skill_once_exit_cleanup' 'exit 0' >"$cleanup_holder"
printf '%s\n' 'set -euo pipefail' ". \"$ROOT/home/skill-once/state.sh\"" "skill_once_init \"$cleanup_session\"" 'set +e' 'skill_once_cleanup_stale "$(date +%s)"; cleanup_rc=$?' 'skill_once_exit_cleanup' 'exit "$cleanup_rc"' >"$cleanup_caller"
reset_cleanup() { reset_race; printf '%s\n' '{"skill":"old","agent":"stale","ts":1}' >"$stale_file"; touch -t 200001010000 "$stale_file"; printf '0\n' >"$CFG/skill-once/.last-cleanup"; }
reset_cleanup
: >"$TRACE/cleanup-holder.hold"
HOME="$TMP/home" AGENT_CONFIG_DIR="$CFG" bash "$cleanup_holder" "$ROOT/home/skill-once" "$cleanup_session" "$TRACE" & holder_pid=$!
wait_marker "$TRACE/acquired"
test -e "$TRACE/cleanup-holder.hold" || fail "holder hold marker missing"
kill -0 "$holder_pid" 2>/dev/null || fail "holder exited while hold marker exists"
test -d "$CFG/skill-once/.session-$cleanup_hash.lock" || fail "holder does not own exact target lock"
start_op cleanup "$cleanup_caller" "" "$TMP/cleanup.out" "$TMP/cleanup.err"; cleanup_pid=$LAST_PID
wait "$cleanup_pid"; [ -e "$stale_file" ] || fail "active stale cleanup removed target"; [ ! -s "$TMP/cleanup.out" ] || fail "cleanup stdout nonempty"; [ ! -s "$TMP/cleanup.err" ] || fail "cleanup stderr nonempty"
rm "$TRACE/cleanup-holder.hold"; wait "$holder_pid"; rm -f "$TRACE/acquired" "$TRACE/cleanup-holder.released"
assert_clean_runtime
reset_cleanup
start_op cleanup "$cleanup_caller" "" "$TMP/cleanup.out" "$TMP/cleanup.err"; cleanup_pid=$LAST_PID
wait "$cleanup_pid"; [ ! -e "$stale_file" ] || fail "released stale cleanup retained target"; [ ! -s "$TMP/cleanup.out" ] || fail "later cleanup stdout nonempty"; [ ! -s "$TMP/cleanup.err" ] || fail "later cleanup stderr nonempty"
assert_clean_runtime

# Task 3C1 cases 1-8: isolated initialization/session mutation failures.
case1="$TMP/3c1-case1"; mkdir -p "$case1/home" "$case1/config" "$case1/bin"
real_sha256sum="$(command -v sha256sum)"; real_shasum="$(command -v shasum)"
printf '%s\n' '#!/usr/bin/env bash' 'real="'"$real_sha256sum"'"' 'if [ "$#" -eq 0 ]; then exit 127; fi' 'exec "$real" "$@"' >"$case1/bin/sha256sum"
printf '%s\n' '#!/usr/bin/env bash' 'real="'"$real_shasum"'"' 'if [ "$#" -eq 2 ] && [ "$1" = -a ] && [ "$2" = 256 ]; then exit 127; fi' 'exec "$real" "$@"' >"$case1/bin/shasum"
chmod +x "$case1/bin/sha256sum" "$case1/bin/shasum"
before="$(find "$case1/config" -printf '%y %p\n' | sort)"; set +e
printf '%s' "$post" | PATH="$case1/bin:$PATH" HOME="$case1/home" AGENT_CONFIG_DIR="$case1/config" bash "$HOOK" >"$case1/out" 2>"$case1/err"; rc=$?; set -e
test "$rc" -eq 0; test ! -s "$case1/out"; test ! -s "$case1/err"; test "$(find "$case1/config" -printf '%y %p\n' | sort)" = "$before"

case2="$TMP/3c1-case2"; mkdir -p "$case2/home" "$case2/config" "$case2/bin"
real_mkdir="$(command -v mkdir)"
printf '%s\n' '#!/usr/bin/env bash' 'real_mkdir="'"$real_mkdir"'"' 'if [ "$#" -eq 2 ] && [ "$1" = -p ] && [ "$2" = "'"$case2/config/skill-once"'" ]; then exit 127; fi' 'exec "$real_mkdir" "$@"' >"$case2/bin/mkdir"; chmod +x "$case2/bin/mkdir"
before="$(find "$case2/config" -printf '%y %p\n' | sort)"; set +e
printf '%s' "$post" | PATH="$case2/bin:$PATH" HOME="$case2/home" AGENT_CONFIG_DIR="$case2/config" bash "$HOOK" >"$case2/out" 2>"$case2/err"; rc=$?; set -e
test "$rc" -eq 0; test ! -s "$case2/out"; test ! -s "$case2/err"; test "$(find "$case2/config" -printf '%y %p\n' | sort)" = "$before"

case3="$TMP/3c1-case3"; mkdir -p "$case3/home" "$case3/config/skill-once"
case3_session=case3-session; case3_hash="$(printf '%s' "$case3_session" | "$real_sha256sum" | cut -c1-16)"; case3_lock="$case3/config/skill-once/.session-$case3_hash.lock"
mkdir "$case3_lock"; before="$(find "$case3/config" -printf '%y %p\n' | grep -v " $case3_lock$" | sort)"; start="$(date +%s%N)"; set +e
printf '%s' "$(jq --arg s "$case3_session" '.session_id=$s' <<<"$post")" | timeout 5s env HOME="$case3/home" AGENT_CONFIG_DIR="$case3/config" bash "$HOOK" >"$case3/out" 2>"$case3/err"; rc=$?; set -e
elapsed=$((($(date +%s%N)-start)/1000000)); test "$rc" -eq 0; test "$elapsed" -lt 5000; test ! -s "$case3/out"; test ! -s "$case3/err"; test -d "$case3_lock"; after="$(find "$case3/config" -printf '%y %p\n' | grep -v " $case3_lock$" | sort)"; test "$after" = "$before" || { printf 'case3 paths changed\nbefore=%s\nafter=%s\n' "$before" "$after" >&2; exit 1; }; rm -rf "$case3_lock"

case4="$TMP/3c1-case4"; mkdir -p "$case4/home" "$case4/config/skill-once"
case4_session=case4-session; mkdir -p "$case4/trace"; case4_hash="$(printf '%s' "$case4_session" | "$real_sha256sum" | cut -c1-16)"; case4_file="$case4/config/skill-once/session-$case4_hash.jsonl"
printf '%s\n' "$(date +%s)" >"$case4/config/skill-once/.last-cleanup"
printf '%s\n' '{"skill":"prior","agent":"main","ts":1}' >"$case4_file"; before_bytes="$("$real_sha256sum" "$case4_file")"; before_paths="$(find "$case4/config" -printf '%y %p\n' | sort)"; set +e
printf '%s' "$(jq --arg s "$case4_session" '.session_id=$s' <<<"$post")" | HOME="$case4/home" AGENT_CONFIG_DIR="$case4/config" SKILL_ONCE_TEST_TRACE_DIR="$case4/trace" SKILL_ONCE_TEST_OP_ID=case4 SKILL_ONCE_TEST_FAIL_POINT=append bash "$HOOK" >"$case4/out" 2>"$case4/err"; rc=$?; set -e
test "$rc" -eq 0; test ! -s "$case4/out"; test ! -s "$case4/err"; test "$("$real_sha256sum" "$case4_file")" = "$before_bytes"; test -f "$case4_file"; test "$(find "$case4/config" -printf '%y %p\n' | sort)" = "$before_paths"; test -z "$(find "$case4/config/skill-once" -maxdepth 1 \( -name '.session-*.lock' -o -name '.cleanup.lock' -o -name '.force.*' \) -printf '%y %p\n' -quit)"; test -z "$(find "$case4/trace" \( -name '*.acquired' -o -name '*.hold' \) -printf '%y %p\n' -quit)"

make_force_seed() { local root=$1 session=$2 hash file; hash="$(printf '%s' "$session" | "$real_sha256sum" | cut -c1-16)"; file="$root/config/skill-once/session-$hash.jsonl"; printf '%s\n' '{"skill":"example","agent":"main","ts":1}' '{"skill":"keep","agent":"main","ts":2}' >"$file"; }
run_force_failure_case() {
  local num=$1 mode=$2; local root="$TMP/3c1-case$num"; local session="case$num-session"; local hash file before_bytes before_paths out rc
  mkdir -p "$root/home" "$root/config/skill-once" "$root/bin"; printf '%s\n' "$(date +%s)" >"$root/config/skill-once/.last-cleanup"; make_force_seed "$root" "$session"; hash="$(printf '%s' "$session" | "$real_sha256sum" | cut -c1-16)"; file="$root/config/skill-once/session-$hash.jsonl"; before_bytes="$("$real_sha256sum" "$file")"; before_paths="$(find "$root/config" -printf '%y %p\n' | sort)"
  case "$mode" in
    mktemp) printf '%s\n' '#!/usr/bin/env bash' 'real="'"$(command -v mktemp)"'"' 'if [ "$#" -eq 1 ] && [ "$1" = "'"$root/config/skill-once/.force.XXXXXX"'" ]; then exit 127; fi' 'exec "$real" "$@"' >"$root/bin/mktemp" ;;
    jq) printf '%s\n' '#!/usr/bin/env bash' 'real="'"$(command -v jq)"'"' 'if [ "$#" -eq 9 ] && [ "$1" = -c ] && [ "$2" = --arg ] && [ "$3" = s ] && [ "$5" = --arg ] && [ "$6" = a ]; then exit 127; fi' 'exec "$real" "$@"' >"$root/bin/jq" ;;
    mv) printf '%s\n' '#!/usr/bin/env bash' 'real="'"$(command -v mv)"'"' 'if [ "$#" -eq 3 ] && [ "$1" = -f ] && [[ "$2" = *"/.force."* ]] && [ "$3" = "'"$file"'" ]; then exit 127; fi' 'exec "$real" "$@"' >"$root/bin/mv" ;;
  esac
  chmod +x "$root/bin/$mode"; set +e
  printf '%s' "$(jq --arg s "$session" '.session_id=$s | .tool_input.args="--force" | .hook_event_name="PreToolUse"' <<<"$post")" | PATH="$root/bin:$PATH" HOME="$root/home" AGENT_CONFIG_DIR="$root/config" bash "$HOOK" >"$root/out" 2>"$root/err"; rc=$?; set -e
  test "$rc" -eq 0; test ! -s "$root/out"; test ! -s "$root/err"; test "$("$real_sha256sum" "$file")" = "$before_bytes"; test "$(find "$root/config" -printf '%y %p\n' | sort | grep -v '/\.force\.' || true)" = "$before_paths"; test -z "$(find "$root/config/skill-once" -maxdepth 1 \( -name '.session-*.lock' -o -name '.cleanup.lock' -o -name '.force.*' \) -printf '%y %p\n' -quit)"
}
run_force_failure_case 5 mktemp
run_force_failure_case 6 jq
run_force_failure_case 7 mv

case8="$TMP/3c1-case8"; mkdir -p "$case8/home" "$case8/config/skill-once" "$case8/bin"
case8_session=case8-session; case8_hash="$(printf '%s' "$case8_session" | "$real_sha256sum" | cut -c1-16)"; case8_file="$case8/config/skill-once/session-$case8_hash.jsonl"; printf '%s\n' "$(date +%s)" >"$case8/config/skill-once/.last-cleanup"; printf '%s\n' '{"skill":"prior","agent":"main","ts":1}' >"$case8_file"; before_bytes="$("$real_sha256sum" "$case8_file")"; before_paths="$(find "$case8/config" -printf '%y %p\n' | sort)"; real_rm="$(command -v rm)"
printf '%s\n' '#!/usr/bin/env bash' 'real="'"$real_rm"'"' 'if [ "$#" -eq 2 ] && [ "$1" = -f ] && [ "$2" = "'"$case8_file"'" ]; then exit 127; fi' 'exec "$real" "$@"' >"$case8/bin/rm"; chmod +x "$case8/bin/rm"; set +e
printf '%s' "$(jq --arg s "$case8_session" '{session_id:$s}' <<<"$post")" | PATH="$case8/bin:$PATH" HOME="$case8/home" AGENT_CONFIG_DIR="$case8/config" bash "$COMPACT" >"$case8/out" 2>"$case8/err"; rc=$?; set -e
test "$rc" -eq 0; test ! -s "$case8/out"; test ! -s "$case8/err"; test "$("$real_sha256sum" "$case8_file")" = "$before_bytes"; test "$(find "$case8/config" -printf '%y %p\n' | sort)" = "$before_paths"; test -z "$(find "$case8/config/skill-once" -maxdepth 1 \( -name '.session-*.lock' -o -name '.cleanup.lock' -o -name '.force.*' \) -printf '%y %p\n' -quit)"

# Task 3C2 cases 9-15: cleanup failures, atomic marker, and inert controls.
# Case 9: a pre-held cleanup lock is bounded, fail-open, and non-mutating.
case9="$TMP/3c2-case9"; mkdir -p "$case9/home" "$case9/config/skill-once"; printf '123\n' >"$case9/config/skill-once/.last-cleanup"; mkdir "$case9/config/skill-once/.cleanup.lock"; before_paths="$(find "$case9/config" -printf '%y %p\n' | sort)"; start="$(date +%s%N)"; set +e
case9_payload="$(jq '.hook_event_name="PreToolUse"' <<<"$post")"; printf '%s' "$case9_payload" | HOME="$case9/home" AGENT_CONFIG_DIR="$case9/config" SKILL_ONCE_TEST_TRACE_DIR="$case9/trace" SKILL_ONCE_TEST_OP_ID=case9-session bash "$HOOK" >"$case9/out" 2>"$case9/err"; rc=$?; set -e
elapsed=$((($(date +%s%N)-start)/1000000)); test "$rc" -eq 0; test "$elapsed" -lt 5000; test ! -s "$case9/out"; test ! -s "$case9/err"; test "$(find "$case9/config" -printf '%y %p\n' | sort)" = "$before_paths"; rm -rf "$case9/config/skill-once/.cleanup.lock"
# Cases 10 and 12: fail-point boundaries prove marker rollback and stale preservation/release.
case10="$TMP/3c2-case10"; mkdir -p "$case10/home" "$case10/config/skill-once" "$case10/trace"; printf '123\n' >"$case10/config/skill-once/.last-cleanup"; case10_marker="$case10/config/skill-once/.last-cleanup"; before_bytes="$($real_sha256sum "$case10_marker")"; case10_session=case10-session; case10_hash="$(session_hash "$case10_session")"; case10_file="$case10/config/skill-once/session-$case10_hash.jsonl"; printf '%s\n' '{"skill":"prior","agent":"main","ts":1}' >"$case10_file"; touch -t 200001010000 "$case10_file"; set +e
printf '%s' "$(jq --arg s "$case10_session" '{session_id:$s,hook_event_name:"PostToolUse",tool_name:"Skill",tool_input:{skill:"example"}}' <<<"$post")" | HOME="$case10/home" AGENT_CONFIG_DIR="$case10/config" SKILL_ONCE_TEST_TRACE_DIR="$case10/trace" SKILL_ONCE_TEST_OP_ID="$case10_session" SKILL_ONCE_TEST_FAIL_POINT=cleanup-marker-write bash "$HOOK" >"$case10/out" 2>"$case10/err"; rc=$?; set -e
test "$rc" -eq 0; test ! -s "$case10/out"; test ! -s "$case10/err"; test "$(cat "$case10/config/skill-once/.last-cleanup")" = 123; test "$($real_sha256sum "$case10_marker")" = "$before_bytes"; test -z "$(find "$case10/config/skill-once" -maxdepth 1 \( -name '.session-*.lock' -o -name '.cleanup.lock' -o -name '.cleanup.*' \) -print -quit)"
case12="$TMP/3c2-case12"; mkdir -p "$case12/home" "$case12/config/skill-once" "$case12/trace"; printf '0\n' >"$case12/config/skill-once/.last-cleanup"; case12_session=case12-caller; case12_hash="$(session_hash "$case12_session")"; case12_stale_hash="$(session_hash case12-stale)"; case12_file="$case12/config/skill-once/session-$case12_stale_hash.jsonl"; case12_caller_file="$case12/config/skill-once/session-$case12_hash.jsonl"; printf '%s\n' '{"skill":"prior","agent":"main","ts":1}' >"$case12_file"; touch -t 200001010000 "$case12_file"; set +e
printf '%s' "$(jq --arg s "$case12_session" '{session_id:$s,hook_event_name:"PostToolUse",tool_name:"Skill",tool_input:{skill:"example"}}' <<<"$post")" | HOME="$case12/home" AGENT_CONFIG_DIR="$case12/config" SKILL_ONCE_TEST_TRACE_DIR="$case12/trace" SKILL_ONCE_TEST_OP_ID="$case12_session" SKILL_ONCE_TEST_FAIL_POINT=stale-delete bash "$HOOK" >"$case12/out" 2>"$case12/err"; rc=$?; set -e
test "$rc" -eq 0; test ! -s "$case12/out"; test ! -s "$case12/err"; test -e "$case12_file"; test -s "$case12_caller_file"; grep -Fq '"example"' "$case12_caller_file"; test -z "$(find "$case12/config/skill-once" -maxdepth 1 -name ".session-$case12_stale_hash.lock" -print -quit)"
# Case 12b: target-unlock failure — stale file deleted, marker not advanced, no lock leak via exit cleanup.
tu="$TMP/3c2-target-unlock"; mkdir -p "$tu/home" "$tu/config/skill-once" "$tu/trace"; printf '0\n' >"$tu/config/skill-once/.last-cleanup"; tu_session=tu-caller; tu_hash="$(session_hash "$tu_session")"; tu_stale_hash="$(session_hash tu-stale)"; tu_file="$tu/config/skill-once/session-$tu_stale_hash.jsonl"; tu_caller_file="$tu/config/skill-once/session-$tu_hash.jsonl"; printf '%s\n' '{"skill":"prior","agent":"main","ts":1}' >"$tu_file"; touch -t 200001010000 "$tu_file"; set +e
printf '%s' "$(jq --arg s "$tu_session" '{session_id:$s,hook_event_name:"PostToolUse",tool_name:"Skill",tool_input:{skill:"example"}}' <<<"$post")" | HOME="$tu/home" AGENT_CONFIG_DIR="$tu/config" SKILL_ONCE_TEST_TRACE_DIR="$tu/trace" SKILL_ONCE_TEST_OP_ID="$tu_session" SKILL_ONCE_TEST_FAIL_POINT=target-unlock bash "$HOOK" >"$tu/out" 2>"$tu/err"; rc=$?; set -e
test "$rc" -eq 0; test ! -s "$tu/out"; test ! -s "$tu/err"; test ! -e "$tu_file"; test -s "$tu_caller_file"; grep -Fq '"example"' "$tu_caller_file"; test -z "$(find "$tu/config/skill-once" -maxdepth 1 -name ".session-$tu_stale_hash.lock" -print -quit)"; test "$(cat "$tu/config/skill-once/.last-cleanup")" = "0"; test -z "$(find "$tu/config/skill-once" -maxdepth 1 \( -name '.session-*.lock' -o -name '.cleanup.lock' -o -name '.force.*' -o -name '.cleanup.*' \) -print -quit)"
# Case 11: busy stale target is retained while cleanup continues.
case11="$TMP/3c2-case11"; mkdir -p "$case11/home" "$case11/config/skill-once" "$case11/trace"; printf '0\n' >"$case11/config/skill-once/.last-cleanup"; case11_session=case11-caller; case11_hash="$(session_hash "$case11_session")"; case11_caller_file="$case11/config/skill-once/session-$case11_hash.jsonl"; case11_stale1_hash="$(session_hash case11-stale-busy)"; case11_stale2_hash="$(session_hash case11-stale-free)"; case11_file1="$case11/config/skill-once/session-$case11_stale1_hash.jsonl"; case11_file2="$case11/config/skill-once/session-$case11_stale2_hash.jsonl"; printf '%s\n' '{"skill":"stale-one","agent":"main","ts":1}' >"$case11_file1"; printf '%s\n' '{"skill":"stale-two","agent":"main","ts":1}' >"$case11_file2"; touch -t 200001010000 "$case11_file1" "$case11_file2"; mkdir "$case11/config/skill-once/.session-$case11_stale1_hash.lock"; printf '%s' "$(jq --arg s "$case11_session" '{session_id:$s,hook_event_name:"PostToolUse",tool_name:"Skill",tool_input:{skill:"example"}}' <<<"$post")" | HOME="$case11/home" AGENT_CONFIG_DIR="$case11/config" SKILL_ONCE_TEST_TRACE_DIR="$case11/trace" SKILL_ONCE_TEST_OP_ID="$case11_session" bash "$HOOK" >"$case11/out" 2>"$case11/err"; test -e "$case11_file1"; test ! -e "$case11_file2"; test -d "$case11/config/skill-once/.session-$case11_stale1_hash.lock"; test -s "$case11_caller_file"; grep -Fq '"example"' "$case11_caller_file"; test ! -s "$case11/out"; test ! -s "$case11/err"; rm -rf "$case11/config/skill-once/.session-$case11_stale1_hash.lock"
# Cases 13-15 and inert controls.
case13="$TMP/3c2-case13"; mkdir -p "$case13/home" "$case13/config"; case13_session=case13-caller; case13_hash="$(session_hash "$case13_session")"; case13_file="$case13/config/skill-once/session-$case13_hash.jsonl"; start="$(date +%s%N)"; printf '%s' "$(jq --arg s "$case13_session" '.session_id=$s | .hook_event_name="PostToolUse"' <<<"$post")" | HOME="$case13/home" AGENT_CONFIG_DIR="$case13/config" SKILL_ONCE_TEST_TRACE_DIR="$case13/missing" SKILL_ONCE_TEST_OP_ID=case13 SKILL_ONCE_TEST_FAIL_POINT=append bash "$HOOK" >"$case13/out" 2>"$case13/err"; elapsed=$((($(date +%s%N)-start)/1000000)); test "$elapsed" -lt 3000; test ! -s "$case13/out"; test ! -s "$case13/err"; test -s "$case13_file"; grep -Fq '"example"' "$case13_file"; test -z "$(find "$case13/config" -type f -name '*.acquired' -print -quit)"
case14="$TMP/3c2-case14"; mkdir -p "$case14/home" "$case14/config" "$case14/trace"; case14_session=case14-caller; case14_hash="$(session_hash "$case14_session")"; case14_file="$case14/config/skill-once/session-$case14_hash.jsonl"; start="$(date +%s%N)"; printf '%s' "$(jq --arg s "$case14_session" '.session_id=$s | .hook_event_name="PostToolUse"' <<<"$post")" | HOME="$case14/home" AGENT_CONFIG_DIR="$case14/config" SKILL_ONCE_TEST_TRACE_DIR="$case14/trace" SKILL_ONCE_TEST_OP_ID='../bad' SKILL_ONCE_TEST_FAIL_POINT=append bash "$HOOK" >"$case14/out" 2>"$case14/err"; elapsed=$((($(date +%s%N)-start)/1000000)); test "$elapsed" -lt 3000; test ! -s "$case14/out"; test ! -s "$case14/err"; test -s "$case14_file"; grep -Fq '"example"' "$case14_file"; test -z "$(find "$case14/trace" -type f -print -quit)"
case15="$TMP/3c2-case15"; mkdir -p "$case15/home" "$case15/config" "$case15/trace"; : >"$case15/trace/case15.hold"; start="$(date +%s%N)"; set +e; printf '%s' "$post" | HOME="$case15/home" AGENT_CONFIG_DIR="$case15/config" SKILL_ONCE_TEST_TRACE_DIR="$case15/trace" SKILL_ONCE_TEST_OP_ID=case15 bash "$HOOK" >"$case15/out" 2>"$case15/err"; rc=$?; set -e; elapsed=$((($(date +%s%N)-start)/1000000)); test "$rc" -eq 0; test "$elapsed" -ge 4500; test "$elapsed" -lt 7000; test ! -s "$case15/out"; test ! -s "$case15/err"; test -z "$(find "$case15/trace" -type f -name '*.acquired' -print -quit)"
# Unknown and partial controls are inert but still perform normal PostToolUse append.
for n in bogus partial-dir partial-id; do root="$TMP/3c2-inert-$n"; mkdir -p "$root/home" "$root/config" "$root/trace"; session="inert-$n-session"; hash="$(session_hash "$session")"; file="$root/config/skill-once/session-$hash.jsonl"; case "$n" in partial-dir) envs="SKILL_ONCE_TEST_TRACE_DIR=$root/trace";; partial-id) envs="SKILL_ONCE_TEST_OP_ID=inert";; *) envs="SKILL_ONCE_TEST_TRACE_DIR=$root/trace SKILL_ONCE_TEST_OP_ID=inert SKILL_ONCE_TEST_FAIL_POINT=bogus";; esac; start="$(date +%s%N)"; env $envs HOME="$root/home" AGENT_CONFIG_DIR="$root/config" bash -c 'printf "%s" "$1" | jq --arg s "$3" ".session_id=\$s | .hook_event_name=\"PostToolUse\"" | bash "$2"' _ "$post" "$HOOK" "$session" >"$root/out" 2>"$root/err"; elapsed=$((($(date +%s%N)-start)/1000000)); test "$elapsed" -lt 3000; test ! -s "$root/out"; test ! -s "$root/err"; test -s "$file"; grep -Fq '"example"' "$file"; test -z "$(find "$root/trace" -type f -print -quit)"; done
# Label mismatch: helper trace guard must reject a differing lock label.
mismatch_root="$TMP/3c2-inert-mismatch"; mkdir -p "$mismatch_root/config/skill-once" "$mismatch_root/trace"
state_dir="$(cd "$(dirname "$HOOK")" && pwd)"
HOME="$mismatch_root/home" AGENT_CONFIG_DIR="$mismatch_root/config" SKILL_ONCE_TEST_TRACE_DIR="$mismatch_root/trace" SKILL_ONCE_TEST_OP_ID=expected-id bash -c '. "$1/state.sh"; skill_once_init "test-session" && skill_once_lock "different-label" && skill_once_unlock' _ "$state_dir"
test $? -eq 0; test -z "$(find "$mismatch_root/trace" -type f -print -quit)"

# Corrupted cache state fails open: nonnumeric timestamp and malformed trailing JSON.
mal_hash="$(printf '%s' "skill-once-session" | sha256sum | cut -c1-16)"
mal_file="$CFG/skill-once/session-$mal_hash.jsonl"
printf '%s\n' '{"skill":"example","agent":"agent-a","ts":"not-a-number"}' >"$mal_file"
set +e; mal_out="$(run "$pre")"; mal_rc=$?; set -e
test "$mal_rc" -eq 0; test -z "$mal_out"
printf '%s\n' '{"skill":"example","agent":"agent-a","ts":1}' '{bad json' >"$mal_file"
set +e; mal_out="$(run "$pre")"; mal_rc=$?; set -e
test "$mal_rc" -eq 0; test -z "$mal_out"
rm -f "$mal_file"

printf 'skill-once lifecycle: PASS\n'
