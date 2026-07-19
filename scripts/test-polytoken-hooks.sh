#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/scripts/fixtures/polytoken-hooks"
ADAPTER="$ROOT/polytoken/hooks/adapter.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/config" "$TMP/canonical/hooks" "$TMP/home"
printf 'adapter fixture\n' > "$TMP/read-target.txt"
if stat -c '%Y' "$TMP/read-target.txt" >/dev/null 2>&1; then
  TEST_OSTYPE=linux-gnu
else
  TEST_OSTYPE=darwin
fi

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_one_json() {
  local value=$1
  jq -s -e 'length == 1 and (.[0] | type == "object")' <<<"$value" >/dev/null || fail "stdout was not exactly one JSON object: $value"
}
assert_outcome() {
  local value=$1 expected=$2
  assert_one_json "$value"
  jq -e --arg expected "$expected" '.outcome == $expected' <<<"$value" >/dev/null || fail "expected outcome $expected: $value"
}
run_adapter() {
  local payload=$1 path=$2 mapping=$3
  shift 3
  RUN_STDOUT="$TMP/stdout"
  RUN_STDERR="$TMP/stderr"
  set +e
  printf '%s' "$payload" | env \
    HOME="$TMP/home" \
    POLYTOKEN_CANONICAL_ROOT="$ROOT/home" \
    POLYTOKEN_CONFIG_DIR="$TMP/config" \
    POLYTOKEN_SESSION_ID="fallback-session" \
    OSTYPE="$TEST_OSTYPE" \
    "$@" bash "$ADAPTER" "$path" "$mapping" >"$RUN_STDOUT" 2>"$RUN_STDERR"
  RUN_RC=$?
  set -e
  RUN_OUT=$(cat "$RUN_STDOUT")
}
expect_error() {
  local payload=$1 path=$2 mapping=$3 fragment=$4
  run_adapter "$payload" "$path" "$mapping"
  test "$RUN_RC" -eq 0 || fail "adapter error outcome exited $RUN_RC"
  assert_outcome "$RUN_OUT" error
  jq -e --arg fragment "$fragment" '.message | contains($fragment)' <<<"$RUN_OUT" >/dev/null || fail "missing error fragment '$fragment': $RUN_OUT"
}

shell_payload=$(cat "$FIX/pre-tool-shell-exec.json")
read_payload=$(jq --arg p "$TMP/read-target.txt" 'del(.input.offset,.input.limit) | .input.path=$p' "$FIX/pre-tool-file-read.json")
skill_payload=$(cat "$FIX/pre-tool-skill.json")
compact_payload=$(cat "$FIX/post-compaction.json")

# Canonical allow/deny translation for all shell policies.
run_adapter "$shell_payload" hooks/no-remote-writes.sh shell
assert_outcome "$RUN_OUT" allow
payload=$(jq '.input.command="git push"' <<<"$shell_payload")
run_adapter "$payload" hooks/no-remote-writes.sh shell
assert_outcome "$RUN_OUT" deny
jq -e '.reason | contains("git push")' <<<"$RUN_OUT" >/dev/null

payload=$(jq '.input.command="rm -rf /"' <<<"$shell_payload")
run_adapter "$payload" bash-guard/hook.sh shell
assert_outcome "$RUN_OUT" deny
jq -e '.reason | contains("bash-guard")' <<<"$RUN_OUT" >/dev/null

payload=$(jq '.input.command="git commit -m test"' <<<"$shell_payload")
current_branch=$(git -C "$ROOT" branch --show-current)
run_adapter "$payload" branch-guard/hook.sh shell BRANCH_GUARD_PROTECTED="$current_branch"
assert_outcome "$RUN_OUT" deny
jq -e '.reason | contains("branch-guard")' <<<"$RUN_OUT" >/dev/null

payload=$(jq '.input.command="git reset --hard HEAD"' <<<"$shell_payload")
run_adapter "$payload" git-safe/hook.sh shell
assert_outcome "$RUN_OUT" deny
jq -e '.reason | contains("git-safe")' <<<"$RUN_OUT" >/dev/null

# Read state: first allow, duplicate deny, state only below POLYTOKEN_CONFIG_DIR.
run_adapter "$read_payload" read-once/hook.sh read READ_ONCE_MODE=deny
assert_outcome "$RUN_OUT" allow
run_adapter "$read_payload" read-once/hook.sh read READ_ONCE_MODE=deny
assert_outcome "$RUN_OUT" deny
jq -e '.reason | contains("already in context")' <<<"$RUN_OUT" >/dev/null
test -n "$(find "$TMP/config/read-once" -name 'session-*.jsonl' -print -quit)" || fail "read state missing under config root"
test ! -e "$TMP/home/.claude/read-once" || fail "read state leaked to HOME"

# Polytoken has no supported skill mapping: it must fail before touching canonical state.
expect_error "$skill_payload" skill-once/hook.sh skill "unsupported mapping: skill"
test ! -e "$TMP/config/skill-once" || fail "unsupported skill mapping created state"

# Read compaction clears the fallback session and returns an event-specific allow.
run_adapter "$compact_payload" read-once/compact.sh compact
assert_outcome "$RUN_OUT" allow
test -z "$(find "$TMP/config/read-once" -name 'session-*.jsonl' -print -quit)" || fail "read state survived compaction"
run_adapter "$read_payload" read-once/hook.sh read READ_ONCE_MODE=deny
assert_outcome "$RUN_OUT" allow

# Spy canonical hook verifies normalization, session fallback, dynamic IDs, identity, and event names.
printf '%s\n' '#!/usr/bin/env bash' 'input=$(cat)' 'printf "%s" "$input" > "$CAPTURE"' 'if [ "$(jq -r .hook_event_name <<<"$input")" = PostCompact ]; then exit 0; fi' 'jq -nc '\''{hookSpecificOutput:{permissionDecision:"allow"}}'\''' > "$TMP/canonical/hooks/capture.sh"
chmod +x "$TMP/canonical/hooks/capture.sh"

payload=$(jq '.prompt_id="runtime-prompt-A" | .call_id="runtime-call-A" | .agent_id="agent-A" | .subagent_id="subagent-A"' <<<"$shell_payload")
run_adapter "$payload" hooks/capture.sh shell POLYTOKEN_CANONICAL_ROOT="$TMP/canonical" CAPTURE="$TMP/captured"
assert_outcome "$RUN_OUT" allow
jq -e '.hook_event_name == "PreToolUse" and .session_id == "fallback-session" and .tool_name == "Bash" and .tool_input == {command:"printf task1"} and .agent_id == "agent-A" and .subagent_id == "subagent-A" and (has("prompt_id") | not) and (has("call_id") | not)' "$TMP/captured" >/dev/null
payload=$(jq '.prompt_id="runtime-prompt-B" | .call_id="runtime-call-B" | .session_id="stdin-session" | .input.offset=4 | .input.limit=9' <<<"$read_payload")
run_adapter "$payload" hooks/capture.sh read POLYTOKEN_CANONICAL_ROOT="$TMP/canonical" CAPTURE="$TMP/captured"
assert_outcome "$RUN_OUT" allow
jq -e --arg p "$TMP/read-target.txt" '.session_id == "stdin-session" and .tool_name == "Read" and .tool_input == {file_path:$p,offset:4,limit:9} and (has("agent_id") | not)' "$TMP/captured" >/dev/null
run_adapter "$compact_payload" hooks/capture.sh compact POLYTOKEN_CANONICAL_ROOT="$TMP/canonical" CAPTURE="$TMP/captured"
assert_outcome "$RUN_OUT" allow
jq -e '.hook_event_name == "PostCompact" and .session_id == "fallback-session" and .tool_name == "" and .tool_input == {}' "$TMP/captured" >/dev/null

# Invalid invocation/input/path failures are explicit single-object outcomes.
expect_error "$shell_payload" ../hooks/no-remote-writes.sh shell "invalid canonical path"
expect_error "$shell_payload" hooks/../hooks/no-remote-writes.sh shell "invalid canonical path"
expect_error "$shell_payload" /hooks/no-remote-writes.sh shell "invalid canonical path"
expect_error "$shell_payload" hooks/missing.sh shell "canonical hook unavailable"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'touch "$ESCAPE_MARKER"' 'jq -nc '\''{hookSpecificOutput:{permissionDecision:"allow"}}'\''' > "$TMP/outside.sh"
chmod +x "$TMP/outside.sh"
ln -s "$TMP/outside.sh" "$TMP/canonical/hooks/escape.sh"
run_adapter "$shell_payload" hooks/escape.sh shell POLYTOKEN_CANONICAL_ROOT="$TMP/canonical" ESCAPE_MARKER="$TMP/escaped"
assert_outcome "$RUN_OUT" error
test ! -e "$TMP/escaped" || fail "canonical symlink escaped root and executed"
expect_error "$shell_payload" hooks/no-remote-writes.sh unknown "unsupported mapping"
expect_error '{bad json' hooks/no-remote-writes.sh shell "malformed Polytoken input"

set +e
printf '%s' "$shell_payload" | bash "$ADAPTER" >"$TMP/noargs.out" 2>"$TMP/noargs.err"
noargs_rc=$?
set -e
test "$noargs_rc" -eq 0 || fail "argument error exited $noargs_rc"
noargs_out=$(cat "$TMP/noargs.out")
assert_outcome "$noargs_out" error
jq -e '.message | contains("usage")' <<<"$noargs_out" >/dev/null

# Canonical stdout and stderr are isolated; malformed/multiple/nonzero/unsupported outputs are errors.
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "canonical diagnostic\\n" >&2' 'printf "not-json\\n"' > "$TMP/canonical/hooks/bad-output.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "{\\"hookSpecificOutput\\":{\\"permissionDecision\\":\\"allow\\"}}\\n{\\"extra\\":true}\\n"' > "$TMP/canonical/hooks/two-output.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "nonzero diagnostic\\n" >&2' 'exit 7' > "$TMP/canonical/hooks/nonzero.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'jq -nc '\''{hookSpecificOutput:{permissionDecision:"ask"}}'\''' > "$TMP/canonical/hooks/unsupported.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'jq -nc '\''{hookSpecificOutput:{permissionDecision:"allow"}}'\''' > "$TMP/canonical/hooks/compact-output.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s\n" "$STRUCTURAL_OUTPUT"' > "$TMP/canonical/hooks/structural-output.sh"
chmod +x "$TMP/canonical/hooks/"*.sh

run_adapter "$shell_payload" hooks/bad-output.sh shell POLYTOKEN_CANONICAL_ROOT="$TMP/canonical"
assert_outcome "$RUN_OUT" error
jq -e '.message == "polytoken hook hooks/bad-output.sh: malformed canonical output"' <<<"$RUN_OUT" >/dev/null
test "$(cat "$RUN_STDERR")" = "canonical diagnostic" || fail "canonical stderr not isolated/preserved"
run_adapter "$shell_payload" hooks/two-output.sh shell POLYTOKEN_CANONICAL_ROOT="$TMP/canonical"
assert_outcome "$RUN_OUT" error
jq -e '.message | contains("malformed canonical output")' <<<"$RUN_OUT" >/dev/null
run_adapter "$shell_payload" hooks/nonzero.sh shell POLYTOKEN_CANONICAL_ROOT="$TMP/canonical"
assert_outcome "$RUN_OUT" error
jq -e '.message | contains("canonical hook exited 7")' <<<"$RUN_OUT" >/dev/null
test "$(cat "$RUN_STDERR")" = "nonzero diagnostic" || fail "nonzero stderr not preserved"
run_adapter "$shell_payload" hooks/unsupported.sh shell POLYTOKEN_CANONICAL_ROOT="$TMP/canonical"
assert_outcome "$RUN_OUT" error
jq -e '.message | contains("unsupported canonical decision")' <<<"$RUN_OUT" >/dev/null

# Parseable JSON with missing, null, or wrong-typed required fields is malformed canonical output.
structural_outputs=(
  '{}'
  '{"hookSpecificOutput":null}'
  '{"hookSpecificOutput":"invalid"}'
  '{"hookSpecificOutput":{}}'
  '{"hookSpecificOutput":{"permissionDecision":null}}'
  '{"hookSpecificOutput":{"permissionDecision":7}}'
  '{"hookSpecificOutput":{"permissionDecision":"deny"}}'
  '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":null}}'
  '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":false}}'
)
for structural_output in "${structural_outputs[@]}"; do
  run_adapter "$shell_payload" hooks/structural-output.sh shell POLYTOKEN_CANONICAL_ROOT="$TMP/canonical" STRUCTURAL_OUTPUT="$structural_output"
  test "$RUN_RC" -eq 0 || fail "structurally malformed canonical output exited $RUN_RC: $structural_output"
  assert_outcome "$RUN_OUT" error
  jq -e '.message == "polytoken hook hooks/structural-output.sh: malformed canonical output"' <<<"$RUN_OUT" >/dev/null || fail "wrong structural error: $RUN_OUT"
done

run_adapter "$compact_payload" hooks/compact-output.sh compact POLYTOKEN_CANONICAL_ROOT="$TMP/canonical"
assert_outcome "$RUN_OUT" error
jq -e '.message | contains("unexpected canonical output")' <<<"$RUN_OUT" >/dev/null

printf 'polytoken hook adapter: PASS\n'
