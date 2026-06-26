#!/usr/bin/env bash
# cc-ukyn agent-join validation — exercises the automated acceptance steps (A1-A9).
# Run from repo root: bash scripts/validate-agent-join.sh
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
HOOK="$REPO/home/agent-join/hook.sh"
SET="$REPO/home/settings.recommended.json"
P=0; F=0
chk(){ if eval "$2" >/dev/null 2>&1; then P=$((P+1)); echo "  ok  $1"; else F=$((F+1)); echo "  FAIL $1"; fi; }

echo "A1. unit suite"
if bash scripts/test-agent-join.sh >/dev/null 2>&1; then P=$((P+1)); echo "  ok  test-agent-join PASS"; else F=$((F+1)); echo "  FAIL test-agent-join"; fi
echo "A2. install suite"
if bash scripts/test-install.sh >/dev/null 2>&1; then P=$((P+1)); echo "  ok  test-install PASS"; else F=$((F+1)); echo "  FAIL test-install"; fi
echo "A3-A6 static"
chk "A3 hook valid bash"            "bash -n '$HOOK'"
chk "A4 settings valid json"        "jq -e . '$SET'"
chk "A5 PostToolUse[Agent] reg"     "jq -e '.hooks.PostToolUse|map(select(.matcher==\"Agent\"))|map(.hooks[].command)|any(.==\"~/.claude/agent-join/hook.sh\")' '$SET'"
chk "A5 SubagentStop reg"           "jq -e '.hooks.SubagentStop|map(.hooks[].command)|any(.==\"~/.claude/agent-join/hook.sh\")' '$SET'"
chk "A5 UserPromptSubmit reg"       "jq -e '.hooks.UserPromptSubmit|map(.hooks[].command)|any(.==\"~/.claude/agent-join/hook.sh\")' '$SET'"
chk "A5 Stop reg"                   "jq -e '.hooks.Stop|map(.hooks[].command)|any(.==\"~/.claude/agent-join/hook.sh\")' '$SET'"
chk "A6 install.sh chmods hook"     "grep -q 'agent-join/hook.sh' install.sh"

echo "A7-A8 end-to-end"
TMP="$(mktemp -d)"
r(){ printf '%s' "$1" | HOME="$TMP" bash "$HOOK"; }
eq(){ if [ "$2" = "$3" ]; then P=$((P+1)); echo "  ok  $1"; else F=$((F+1)); echo "  FAIL $1 (got '$2' want '$3')"; fi; }
# A7 inertness
eq "A7 inert Stop (no ledger) -> empty" "$(r '{"hook_event_name":"Stop","session_id":"v0"}')" ""
# A8 data flow: two same-named agents
r '{"hook_event_name":"PostToolUse","session_id":"v1","tool_name":"Agent","tool_input":{"description":"Review auth"},"tool_response":{"isAsync":true,"agentId":"v1a","outputFile":"/o/a"}}' >/dev/null
r '{"hook_event_name":"PostToolUse","session_id":"v1","tool_name":"Agent","tool_input":{"description":"Review auth"},"tool_response":{"isAsync":true,"agentId":"v1b","outputFile":"/o/b"}}' >/dev/null
L="$TMP/.claude/agent-join/state/v1.json"
eq "A8 v1a RUNNING" "$(jq -r '.agents.v1a.status' "$L")" "RUNNING"
eq "A8 v1b RUNNING" "$(jq -r '.agents.v1b.status' "$L")" "RUNNING"
r '{"hook_event_name":"SubagentStop","session_id":"v1","agent_id":"v1b","agent_transcript_path":"/t/v1b"}' >/dev/null
eq "A8 v1b DONE after SubagentStop" "$(jq -r '.agents.v1b.status' "$L")" "DONE"
eq "A8 v1a still RUNNING" "$(jq -r '.agents.v1a.status' "$L")" "RUNNING"
inj="$(r '{"hook_event_name":"UserPromptSubmit","session_id":"v1","prompt":"anything"}')"
case "$inj" in *v1b*orchestration-status*|*orchestration-status*v1b*) eq "A8 inject names unread v1b" yes yes ;; *) eq "A8 inject names unread v1b" no yes ;; esac
r '{"hook_event_name":"SubagentStop","session_id":"v1","agent_id":"v1a","agent_transcript_path":"/t/v1a"}' >/dev/null
b1="$(r '{"hook_event_name":"Stop","session_id":"v1","background_tasks":[]}')"
case "$b1" in *'"decision":"block"'*) eq "A8 Stop blocks once" yes yes ;; *) eq "A8 Stop blocks once" no yes ;; esac
eq "A8 second Stop inert (no loop)" "$(r '{"hook_event_name":"Stop","session_id":"v1","background_tasks":[]}')" ""
# A9 spot: pending not swept
r '{"hook_event_name":"PostToolUse","session_id":"v2","tool_name":"Agent","tool_input":{"description":"P"},"tool_response":{"isAsync":true,"agentId":"v2a","outputFile":"/o/p"}}' >/dev/null
eq "A9 pending Stop -> no block" "$(r '{"hook_event_name":"Stop","session_id":"v2","background_tasks":[{"type":"subagent","status":"pending","id":"v2a"}]}')" ""
eq "A9 pending not swept" "$(jq -r '.agents.v2a.status' "$TMP/.claude/agent-join/state/v2.json")" "RUNNING"
rm -rf "$TMP"

echo
echo "VALIDATION: pass=$P fail=$F"
[ "$F" = 0 ]
