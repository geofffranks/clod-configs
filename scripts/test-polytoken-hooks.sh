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
jq -e '. == {outcome:"deny",reason:"git push is blocked. Ask the user to push."}' <<<"$RUN_OUT" >/dev/null || fail "denial was not exact or input was rewritten: $RUN_OUT"

payload=$(jq '.input.command="rm -rf /"' <<<"$shell_payload")
run_adapter "$payload" bash-guard/hook.sh shell
assert_outcome "$RUN_OUT" deny
jq -e '.reason | contains("bash-guard")' <<<"$RUN_OUT" >/dev/null

payload=$(jq '.input.command="git commit -m test"' <<<"$shell_payload")
current_branch=$(git -C "$ROOT" branch --show-current)
run_adapter "$payload" branch-guard/hook.sh shell BRANCH_GUARD_PROTECTED="$current_branch"
assert_outcome "$RUN_OUT" deny
jq -e '.reason | contains("branch-guard")' <<<"$RUN_OUT" >/dev/null

# Linked-worktree regression: the hook launcher stays in the main checkout,
# while POLYTOKEN_CWD identifies a feature worktree. The feature branch must be
# evaluated, not the launcher branch.
WORKTREE_ROOT="$TMP/linked-worktree"
TEST_BRANCH="test-branch-guard-worktree-$$"
git -C "$ROOT" worktree add -q -b "$TEST_BRANCH" "$WORKTREE_ROOT" HEAD
run_adapter "$payload" branch-guard/hook.sh shell \
  POLYTOKEN_CWD="$WORKTREE_ROOT" \
  BRANCH_GUARD_PROTECTED="$(git -C "$ROOT" branch --show-current)"
assert_outcome "$RUN_OUT" allow
git -C "$ROOT" worktree remove "$WORKTREE_ROOT" >/dev/null
git -C "$ROOT" branch -d "$TEST_BRANCH" >/dev/null

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
jq -e --arg p "$TMP/read-target.txt" '.session_id == "stdin-session" and .tool_name == "Read" and .tool_input == {file_path:$p,offset:4,limit:9,max_bytes:32000} and (has("agent_id") | not)' "$TMP/captured" >/dev/null || fail "read adapter capture mismatch: $(cat "$TMP/captured")"
payload=$(jq '.input.max_bytes=17 | del(.input.offset,.input.limit)' <<<"$read_payload")
run_adapter "$payload" hooks/capture.sh read POLYTOKEN_CANONICAL_ROOT="$TMP/canonical" CAPTURE="$TMP/captured"
assert_outcome "$RUN_OUT" allow
jq -e --arg p "$TMP/read-target.txt" '.tool_input == {file_path:$p,max_bytes:17}' "$TMP/captured" >/dev/null
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

# C2: exact Grep canonical payload, schema rejection, and deterministic guard policy.
grep_payload=$(jq -nc '{event:"pre_tool_use",matcher_subject:"Grep",tool_name:"Grep",prompt_id:"p",call_id:"c",input:{pattern:"a|b",path:["."],include:"*.sh",context_lines:0,max_results:20,respect_ignore_files:true,include_hidden:false,unknown:"discard"}}')
run_adapter "$grep_payload" grep-guard/hook.sh grep
assert_outcome "$RUN_OUT" allow
jq -e '.input // empty' <<<"$RUN_OUT" >/dev/null 2>&1 && fail "adapter leaked input" || true

# The adapter emits the exact canonical Grep contract: tool name, array and
# string paths, preserved false/zero optionals, omitted absent optionals, and
# discarded unknown fields.
run_adapter "$grep_payload" hooks/capture.sh grep POLYTOKEN_CANONICAL_ROOT="$TMP/canonical" CAPTURE="$TMP/captured"
assert_outcome "$RUN_OUT" allow
jq -e '.hook_event_name == "PreToolUse" and .session_id == "fallback-session" and .tool_name == "Grep" and .tool_input == {pattern:"a|b",path:["."],include:"*.sh",context_lines:0,max_results:20,respect_ignore_files:true,include_hidden:false} and (has("unknown") | not)' "$TMP/captured" >/dev/null
string_grep_payload=$(jq '.input.path="." | del(.input.include) | .input.context_lines=0 | .input.respect_ignore_files=false | .input.include_hidden=false | .input.unknown="discard"' <<<"$grep_payload")
run_adapter "$string_grep_payload" hooks/capture.sh grep POLYTOKEN_CANONICAL_ROOT="$TMP/canonical" CAPTURE="$TMP/captured"
assert_outcome "$RUN_OUT" allow
jq -e '.hook_event_name == "PreToolUse" and .session_id == "fallback-session" and .tool_name == "Grep" and .tool_input == {pattern:"a|b",path:".",context_lines:0,max_results:20,respect_ignore_files:false,include_hidden:false} and (has("agent_id") | not) and (has("subagent_id") | not) and (has("include") | not) and (has("unknown") | not)' "$TMP/captured" >/dev/null

run_adapter '{"input":{"pattern":"x","path":".","max_results":21}}' grep-guard/hook.sh grep
assert_outcome "$RUN_OUT" deny
jq -e '.reason | contains("max_results") and contains("rtk grep") and contains("Input was not rewritten")' <<<"$RUN_OUT" >/dev/null

# Missing max_results is malformed at the adapter boundary, while the
# canonical guard itself deterministically denies without rewriting input.
missing_max='{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Grep","tool_input":{"pattern":"x","path":"."}}'
set +e
canonical_missing=$(printf '%s' "$missing_max" | bash "$ROOT/home/grep-guard/hook.sh")
canonical_missing_rc=$?
set -e
test "$canonical_missing_rc" -eq 0 || fail "canonical missing-max invocation exited $canonical_missing_rc"
assert_one_json "$canonical_missing"
jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("max_results") and contains("Input was not rewritten"))' <<<"$canonical_missing" >/dev/null
expect_error '{"input":{"pattern":"x","path":"."}}' grep-guard/hook.sh grep "malformed Polytoken input"

for bad_input in \
  '{"pattern":"x","path":".","context_lines":-1,"max_results":1}' \
  '{"pattern":7,"path":".","max_results":1}' \
  '{"pattern":"x","path":{},"max_results":1}' \
  '{"pattern":"x","path":".","max_results":1,"include":false}'; do
  bad=$(jq -nc --argjson i "$bad_input" '{event:"pre_tool_use",matcher_subject:"Grep",tool_name:"Grep",input:$i}')
  expect_error "$bad" grep-guard/hook.sh grep "malformed Polytoken input"
done

# Normative top-level scanner boundaries and malformed patterns.
for pattern in 'a|b|c|d|e' '(a|b)|c' 'a\|b|c' 'a\|b|c|d|e|f' '[a|b]|c'; do
  payload=$(jq --arg p "$pattern" '.input.pattern=$p | .input.max_results=20' <<<"$grep_payload")
  run_adapter "$payload" grep-guard/hook.sh grep
  assert_outcome "$RUN_OUT" allow
 done
for pattern in 'a|b|c|d|e|f' '(a|b|c' '[a|b'; do
  payload=$(jq --arg p "$pattern" '.input.pattern=$p | .input.max_results=20' <<<"$grep_payload")
  run_adapter "$payload" grep-guard/hook.sh grep
  assert_outcome "$RUN_OUT" deny
  jq -e '.reason | contains("grep-guard")' <<<"$RUN_OUT" >/dev/null
 done

# C3 focused large-read metadata policy coverage.
LARGE_READ_HOOK="$ROOT/home/large-read-guard/hook.sh"
LARGE_READ_TMP="$TMP/large-read"; mkdir -p "$LARGE_READ_TMP/project"
python3 - "$LARGE_READ_TMP/project/big.diff" 51200 <<'PY'
import sys
open(sys.argv[1], 'wb').write(b'x' * int(sys.argv[2]))
PY
large_read_run() {
  local path=$1 extra='{}'
  [ "$#" -gt 1 ] && extra=$2
  jq -nc --arg p "$path" --argjson e "$extra" '{tool_name:"Read",tool_input:({file_path:$p} + $e)}' |
    POLYTOKEN_CWD="$LARGE_READ_TMP/project" bash "$LARGE_READ_HOOK"
}
large_read_decision() { local out; if [ "$#" -gt 1 ]; then out=$(large_read_run "$1" "$2"); else out=$(large_read_run "$1"); fi; if [ -n "$out" ]; then jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$out"; else printf 'allow\n'; fi; }
[ "$(large_read_decision "$LARGE_READ_TMP/project/big.diff")" = allow ] || fail "C3 51200 boundary"
python3 - "$LARGE_READ_TMP/project/big.diff" 51201 <<'PY'
import sys
open(sys.argv[1], 'wb').write(b'x' * int(sys.argv[2]))
PY
[ "$(large_read_decision "$LARGE_READ_TMP/project/big.diff")" = deny ] || fail "C3 51201 boundary"
cp "$LARGE_READ_TMP/project/big.diff" "$LARGE_READ_TMP/project/BIG.DIFF"
[ "$(large_read_decision "$LARGE_READ_TMP/project/BIG.DIFF")" = deny ] || fail "C3 case-insensitive suffix"
printf x > "$LARGE_READ_TMP/project/small.log"
ln -s "$LARGE_READ_TMP/project/small.log" "$LARGE_READ_TMP/project/one.log"
[ "$(large_read_decision "$LARGE_READ_TMP/project/one.log")" = allow ] || fail "C3 one-hop symlink"
ln -s "$LARGE_READ_TMP/project/one.log" "$LARGE_READ_TMP/project/two.log"
[ "$(large_read_decision "$LARGE_READ_TMP/project/two.log")" = allow ] || fail "C3 nested symlink fail-open"
python3 - "$LARGE_READ_TMP/big.diff" 51201 <<'PY'
import sys
open(sys.argv[1], 'wb').write(b'x' * int(sys.argv[2]))
PY
[ "$(large_read_decision "../big.diff")" = allow ] || fail "C3 containment traversal"
[ -s "$LARGE_READ_TMP/big.diff" ] || fail "C3 containment fixture missing"
[ "$(large_read_decision "$LARGE_READ_TMP/project/big.diff" '{"max_bytes":1}')" = allow ] || fail "C3 max_bytes bound"
[ "$(large_read_decision "$LARGE_READ_TMP/project/big.diff" '{"offset":0,"limit":1}')" = allow ] || fail "C3 offset/limit bound"
[ "$(large_read_decision "$LARGE_READ_TMP/project/big.diff" '{"max_bytes":0}')" = allow ] || fail "C3 malformed max_bytes"
[ "$(large_read_decision "$LARGE_READ_TMP/project/big.diff" '{"offset":-1,"limit":1}')" = allow ] || fail "C3 malformed offset"
[ "$(large_read_decision "$LARGE_READ_TMP/project/big.diff" '{"offset":0}')" = allow ] || fail "C3 malformed incomplete bounds"
printf x > "$LARGE_READ_TMP/project/bounds.txt"
python3 - "$LARGE_READ_TMP/project/bounds.txt" 256000 <<'PY'
import sys
open(sys.argv[1], 'wb').write(b'x' * int(sys.argv[2]))
PY
[ "$(large_read_decision "$LARGE_READ_TMP/project/bounds.txt")" = allow ] || fail "C3 256000 boundary"
python3 - "$LARGE_READ_TMP/project/bounds.txt" 256001 <<'PY'
import sys
open(sys.argv[1], 'wb').write(b'x' * int(sys.argv[2]))
PY
[ "$(large_read_decision "$LARGE_READ_TMP/project/bounds.txt")" = deny ] || fail "C3 256001 boundary"
mkdir "$LARGE_READ_TMP/project/directory"
[ "$(large_read_decision "$LARGE_READ_TMP/project/directory")" = allow ] || fail "C3 directory fail-open"
mkfifo "$LARGE_READ_TMP/project/special"
[ "$(large_read_decision "$LARGE_READ_TMP/project/special")" = allow ] || fail "C3 special fail-open"
if [ "$(id -u)" -ne 0 ]; then
  printf x > "$LARGE_READ_TMP/project/unreadable.diff"; chmod 000 "$LARGE_READ_TMP/project/unreadable.diff"
  [ "$(large_read_decision "$LARGE_READ_TMP/project/unreadable.diff")" = allow ] || fail "C3 unreadable fail-open"
  chmod 600 "$LARGE_READ_TMP/project/unreadable.diff"
fi
# Force a metadata race by replacing the file between the hook's two snapshots.
cp "$LARGE_READ_TMP/project/big.diff" "$LARGE_READ_TMP/project/race.diff"
race_stat="$LARGE_READ_TMP/race-stat"; mkdir -p "$race_stat"
printf '%s\n' 0 > "$race_stat/count"
cp "$LARGE_READ_TMP/project/big.diff" "$race_stat/replacement"
printf '%s\n' '#!/usr/bin/env bash' 'set -eu' 'count=$(cat "$RACE_STAT_DIR/count")' 'printf "%s\n" $((count + 1)) > "$RACE_STAT_DIR/count"' 'result=$(/usr/bin/stat "$@")' 'if [ "$count" -eq 0 ]; then mv "$RACE_STAT_DIR/replacement" "$RACE_TARGET"; fi' 'printf "%s\n" "$result"' > "$race_stat/stat"
chmod +x "$race_stat/stat"
# The first stat reports the original inode, then the wrapper atomically swaps in a distinct inode.
race_out=$(RACE_STAT_DIR="$race_stat" RACE_TARGET="$LARGE_READ_TMP/project/race.diff" PATH="$race_stat:$PATH" large_read_run "$LARGE_READ_TMP/project/race.diff" 2>"$race_stat/stderr")
race_err=$(cat "$race_stat/stderr")
[ -z "$race_out" ] || fail "C3 race emitted stdout: $race_out"
[ "$race_err" = "large-read-guard: metadata changed; allowing read" ] || fail "C3 race diagnostic: $race_err"

printf 'polytoken hook adapter: PASS\n'
