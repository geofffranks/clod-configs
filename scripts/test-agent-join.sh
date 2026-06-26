#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/home/agent-join/hook.sh"
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 (got '$1' want '$2')"; fi; }
run(){ printf '%s' "$1" | HOME="$TMP" bash "$HOOK"; }   # $1 = stdin json
runc(){ jq -r '[.agents[]|select(.status=="RUNNING")]|length' "$1" 2>/dev/null; }  # count of RUNNING agents

TMP="$(mktemp -d)"; export TMP

# inertness: no ledger, Stop event -> empty stdout, exit 0
out="$(run '{"hook_event_name":"Stop","session_id":"s1"}')"; rc=$?
ok "$rc" "0" "inert Stop exit 0"
ok "$out" "" "inert Stop empty stdout"

# PostToolUse[Agent] records a RUNNING row keyed by agentId
disp='{"hook_event_name":"PostToolUse","session_id":"s2","tool_name":"Agent","tool_input":{"description":"Review auth tests"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"b77c3e1abc","outputFile":"/tmp/o/b77c3e1abc.output"}}'
printf '%s' "$disp" | HOME="$TMP" bash "$HOOK" >/dev/null
led="$TMP/.claude/agent-join/state/s2.json"
ok "$(jq -r '.agents["b77c3e1abc"].status' "$led" 2>/dev/null)" "RUNNING" "dispatch -> RUNNING row"
ok "$(jq -r '.agents["b77c3e1abc"].label' "$led" 2>/dev/null)" "Review auth tests" "dispatch label captured"
ok "$(jq -r '.agents["b77c3e1abc"].output_file' "$led" 2>/dev/null)" "/tmp/o/b77c3e1abc.output" "dispatch outputFile captured"
ok "$(runc "$led")" "1" "dispatch -> 1 RUNNING agent"

# SubagentStop flips the matching row DONE (output_file from dispatch is preserved)
sas='{"hook_event_name":"SubagentStop","session_id":"s2","agent_id":"b77c3e1abc","agent_transcript_path":"/tmp/t/agent-b77c3e1abc.jsonl"}'
printf '%s' "$sas" | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["b77c3e1abc"].status' "$led" 2>/dev/null)" "DONE" "SubagentStop -> DONE"
ok "$(jq -r '.agents["b77c3e1abc"].output_file' "$led" 2>/dev/null)" "/tmp/o/b77c3e1abc.output" "dispatch outputFile preserved (not overwritten)"
ok "$(runc "$led")" "0" "SubagentStop -> 0 RUNNING agents"

# UserPromptSubmit injects an orchestration-status block naming the unread agent
ups='{"hook_event_name":"UserPromptSubmit","session_id":"s2","prompt":"is it done yet"}'
out="$(printf '%s' "$ups" | HOME="$TMP" bash "$HOOK")"
ctx="$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out" 2>/dev/null)"
case "$ctx" in *"b77c3e1abc"*) ok 0 0 "injects unread agent id";; *) ok 1 0 "injects unread agent id";; esac
case "$ctx" in *"orchestration-status"*) ok 0 0 "injects status block";; *) ok 1 0 "injects status block";; esac

# Stop with a still-running subagent in background_tasks -> allow rest (no block)
busy='{"hook_event_name":"Stop","session_id":"s2","background_tasks":[{"id":"zzz","type":"subagent","status":"running"}]}'
ok "$(printf '%s' "$busy" | HOME="$TMP" bash "$HOOK")" "" "Stop allows rest while a subagent is running"
ok "$(jq -r '.agents["b77c3e1abc"].surfaced' "$led" 2>/dev/null)" "false" "no surface while still running"
# Stop guard: nothing running (background_tasks empty) + unread DONE -> block once
stop='{"hook_event_name":"Stop","session_id":"s2","background_tasks":[]}'
out1="$(printf '%s' "$stop" | HOME="$TMP" bash "$HOOK")"
ok "$(jq -r '.decision // ""' <<<"$out1" 2>/dev/null)" "block" "Stop blocks on unread completion"
case "$(jq -r '.reason // ""' <<<"$out1")" in *"b77c3e1abc"*) ok 0 0 "block reason names agent";; *) ok 1 0 "block reason names agent";; esac
ok "$(jq -r '.agents["b77c3e1abc"].surfaced' "$led" 2>/dev/null)" "true" "row marked surfaced"
# second Stop: all surfaced -> inert, empty stdout
out2="$(printf '%s' "$stop" | HOME="$TMP" bash "$HOOK")"
ok "$out2" "" "second Stop allows (no infinite loop)"

# ── NEW COVERAGE ───────────────────────────────────────────────────────────────
led3="$TMP/.claude/agent-join/state/s3.json"

# ── Scenario 1: SubagentStop re-fire idempotency (s4, two-agent setup) ────────
# Two agents dispatched (2 RUNNING). ONE completes via SubagentStop (1 RUNNING).
# Re-fire SubagentStop for the SAME completed agent: the transition is a fixed
# point (DONE stays DONE) and must not touch the other agent or overwrite the
# completed agent's output_file with the re-fire's transcript path.
led4="$TMP/.claude/agent-join/state/s4.json"
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s4","tool_name":"Agent","tool_input":{"description":"alpha task"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"cafe000010","outputFile":"/tmp/o/cafe000010.output"}}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s4","tool_name":"Agent","tool_input":{"description":"beta task"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"cafe000011","outputFile":"/tmp/o/cafe000011.output"}}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(runc "$led4")" "2" "s4 two agents dispatched: 2 RUNNING"

# first SubagentStop for cafe000010 -> DONE (2 RUNNING -> 1 RUNNING)
printf '%s' '{"hook_event_name":"SubagentStop","session_id":"s4","agent_id":"cafe000010","agent_transcript_path":"/tmp/t/cafe000010.jsonl"}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe000010"].status' "$led4" 2>/dev/null)" "DONE" "s4 SubagentStop first fire -> DONE"
ok "$(runc "$led4")" "1" "s4 first SubagentStop -> 1 RUNNING (one DONE, one RUNNING)"
ok "$(jq -r '.agents["cafe000011"].status' "$led4" 2>/dev/null)" "RUNNING" "s4 other agent still RUNNING after first SubagentStop"
# Inner output_file-preservation guard bite: the FIRST fire transitions RUNNING->DONE and must
# keep the dispatch output_file, NOT overwrite it with the transcript path. Drop the inner
# `if output_file==""` guard and this flips to /tmp/t/cafe000010.jsonl -> this assertion fails.
ok "$(jq -r '.agents["cafe000010"].output_file' "$led4" 2>/dev/null)" "/tmp/o/cafe000010.output" "s4 first SubagentStop: dispatch output_file preserved, not overwritten by transcript (inner guard bites)"

# re-fire SubagentStop for cafe000010 (already DONE): no-op — stays DONE, the dispatch
# output_file is NOT overwritten by the re-fire's transcript path, other agent untouched.
printf '%s' '{"hook_event_name":"SubagentStop","session_id":"s4","agent_id":"cafe000010","agent_transcript_path":"/tmp/t/cafe000010.jsonl"}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe000010"].status' "$led4" 2>/dev/null)" "DONE" "s4 SubagentStop re-fire: completed agent stays DONE"
ok "$(jq -r '.agents["cafe000010"].output_file' "$led4" 2>/dev/null)" "/tmp/o/cafe000010.output" "s4 SubagentStop re-fire: output_file preserved (idempotent, not overwritten)"
ok "$(runc "$led4")" "1" "s4 SubagentStop re-fire: still 1 RUNNING (other agent untouched)"

# ── Scenario 2: UserPromptSubmit reconcile from task-notification ─────────────
# Note: hook uses grep -oE '<task-id>[a-f0-9]+</task-id>' so agent IDs must be hex.
# dispatch xyz2 (cafe000002) and xyz3 (cafe000003)
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s3","tool_name":"Agent","tool_input":{"description":"xyz2 task"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"cafe000002","outputFile":"/tmp/o/cafe000002.output"}}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s3","tool_name":"Agent","tool_input":{"description":"xyz3 task"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"cafe000003","outputFile":"/tmp/o/cafe000003.output"}}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(runc "$led3")" "2" "s3 two agents dispatched: 2 RUNNING"

# UPS with <status>completed</status> for cafe000002 (xyz2)
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s3","prompt":"<task-notification><task-id>cafe000002</task-id><status>completed</status><output>all done</output></task-notification>"}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe000002"].status' "$led3" 2>/dev/null)" "DONE" "s3 UPS completed -> xyz2 flips DONE"
ok "$(runc "$led3")" "1" "s3 UPS completed -> 1 RUNNING left"

# UPS with <status>failed</status> for cafe000003 (xyz3) — terminal status coverage
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s3","prompt":"<task-notification><task-id>cafe000003</task-id><status>failed</status><output>crashed</output></task-notification>"}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe000003"].status' "$led3" 2>/dev/null)" "DONE" "s3 UPS failed -> xyz3 flips DONE (terminal status)"
ok "$(runc "$led3")" "0" "s3 UPS failed -> 0 RUNNING left"

# Re-fire xyz2 completed notification: notified_count increments (the idempotency witness),
# status stays DONE, RUNNING count unchanged.
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s3","prompt":"<task-notification><task-id>cafe000002</task-id><status>completed</status><output>all done</output></task-notification>"}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe000002"].notified_count' "$led3" 2>/dev/null)" "2" "s3 UPS re-fire: notified_count increments (idempotent reconcile)"
ok "$(jq -r '.agents["cafe000002"].status' "$led3" 2>/dev/null)" "DONE" "s3 UPS re-fire: stays DONE"
ok "$(runc "$led3")" "0" "s3 UPS re-fire: still 0 RUNNING"

# ── Scenario 3: Stop reconcile-sweep on a missed completion (s5, isolated) ────
# Fresh session s5: single agent dispatched, no SubagentStop or UPS fired.
# Stop with background_tasks=[] must: (a) sweep RUNNING->DONE, (b) emit decision:block.
# s5 has no prior DONE rows, so the block assertion genuinely depends on the sweep.
# WITHOUT the sweep, cafe000004 stays RUNNING -> UNREAD=0 -> no block (assertion bites).
led5="$TMP/.claude/agent-join/state/s5.json"
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s5","tool_name":"Agent","tool_input":{"description":"xyz4 task"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"cafe000004","outputFile":"/tmp/o/cafe000004.output"}}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe000004"].status' "$led5" 2>/dev/null)" "RUNNING" "s5 xyz4 dispatched RUNNING (no completion fired)"

# Stop with background_tasks=[] (harness says nothing running) -> reconcile-sweep RUNNING->DONE + block
out_stop3="$(printf '%s' '{"hook_event_name":"Stop","session_id":"s5","background_tasks":[]}' | HOME="$TMP" bash "$HOOK")"
ok "$(jq -r '.agents["cafe000004"].status' "$led5" 2>/dev/null)" "DONE" "s5 Stop reconcile-sweep: missed agent RUNNING->DONE"
ok "$(jq -r '.decision // ""' <<<"$out_stop3" 2>/dev/null)" "block" "s5 Stop reconcile-sweep: emits decision:block for unread result"

# ── Scenario 4: stop_hook_active loop guard ───────────────────────────────────
# Setup: dispatch xyz5 (cafe000005) and flip DONE via SubagentStop so ledger has unread DONE row
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s3","tool_name":"Agent","tool_input":{"description":"xyz5 task"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"cafe000005","outputFile":"/tmp/o/cafe000005.output"}}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"SubagentStop","session_id":"s3","agent_id":"cafe000005","agent_transcript_path":"/tmp/t/cafe000005.jsonl"}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe000005"].status' "$led3" 2>/dev/null)" "DONE" "s3 xyz5 setup for loop guard: DONE+unread in ledger"

# Stop with stop_hook_active=true: loop guard fires before any reconcile/block -> empty stdout
out_active="$(printf '%s' '{"hook_event_name":"Stop","session_id":"s3","background_tasks":[],"stop_hook_active":true}' | HOME="$TMP" bash "$HOOK")"
ok "$out_active" "" "s3 stop_hook_active: loop guard short-circuits, empty stdout"

# ── S-C1: fail-safe background_tasks guard ────────────────────────────────────
# Dispatch cafe0000a1 -> RUNNING. Stop with absent/non-array background_tasks
# must NOT sweep (fail-safe). Stop with [] must sweep + block.
led6="$TMP/.claude/agent-join/state/s6.json"
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s6","tool_name":"Agent","tool_input":{"description":"sc1 task"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"cafe0000a1","outputFile":"/tmp/o/cafe0000a1.output"}}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe0000a1"].status' "$led6" 2>/dev/null)" "RUNNING" "s6 cafe0000a1 dispatched RUNNING"

# Stop with NO background_tasks key -> empty stdout, status stays RUNNING
out_sc1_absent="$(printf '%s' '{"hook_event_name":"Stop","session_id":"s6"}' | HOME="$TMP" bash "$HOOK")"
ok "$out_sc1_absent" "" "s6 Stop absent background_tasks -> empty stdout (fail-safe: must not sweep)"
ok "$(jq -r '.agents["cafe0000a1"].status' "$led6" 2>/dev/null)" "RUNNING" "s6 Stop absent background_tasks -> status stays RUNNING"

# Stop with background_tasks as non-array scalar -> empty stdout, status stays RUNNING
out_sc1_scalar="$(printf '%s' '{"hook_event_name":"Stop","session_id":"s6","background_tasks":"oops"}' | HOME="$TMP" bash "$HOOK")"
ok "$out_sc1_scalar" "" "s6 Stop non-array background_tasks -> empty stdout (fail-safe: must not sweep)"
ok "$(jq -r '.agents["cafe0000a1"].status' "$led6" 2>/dev/null)" "RUNNING" "s6 Stop non-array background_tasks -> status stays RUNNING"

# Stop with background_tasks=[] (present empty array) -> reconcile sweep + block
out_sc1_arr="$(printf '%s' '{"hook_event_name":"Stop","session_id":"s6","background_tasks":[]}' | HOME="$TMP" bash "$HOOK")"
ok "$(jq -r '.decision // ""' <<<"$out_sc1_arr" 2>/dev/null)" "block" "s6 Stop empty-array background_tasks -> decision:block (sweep fires when array present)"
ok "$(jq -r '.agents["cafe0000a1"].status' "$led6" 2>/dev/null)" "DONE" "s6 Stop empty-array background_tasks -> cafe0000a1 reconciled to DONE"

# ── S-C2: idempotent PostToolUse (duplicate dispatch must not clobber DONE/surfaced row) ──
# Dispatch cafe0000b1, SubagentStop it (DONE), surface via Stop [], then re-dispatch same id.
led7="$TMP/.claude/agent-join/state/s7.json"
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s7","tool_name":"Agent","tool_input":{"description":"b1 task"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"cafe0000b1","outputFile":"/tmp/o/cafe0000b1.output"}}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"SubagentStop","session_id":"s7","agent_id":"cafe0000b1","agent_transcript_path":"/tmp/t/cafe0000b1.jsonl"}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe0000b1"].status' "$led7" 2>/dev/null)" "DONE" "s7 cafe0000b1 DONE after SubagentStop"
printf '%s' '{"hook_event_name":"Stop","session_id":"s7","background_tasks":[]}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe0000b1"].surfaced' "$led7" 2>/dev/null)" "true" "s7 cafe0000b1 surfaced after Stop"

# Re-dispatch same id: must be no-op (status stays DONE, surfaced stays true, NOT re-added as RUNNING)
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s7","tool_name":"Agent","tool_input":{"description":"b1 task again"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"cafe0000b1","outputFile":"/tmp/o/cafe0000b1.output"}}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe0000b1"].status' "$led7" 2>/dev/null)" "DONE" "s7 re-dispatch: status stays DONE (idempotent insert, no clobber)"
ok "$(jq -r '.agents["cafe0000b1"].surfaced' "$led7" 2>/dev/null)" "true" "s7 re-dispatch: surfaced stays true (no clobber)"
ok "$(runc "$led7")" "0" "s7 re-dispatch: still 0 RUNNING (not re-added as RUNNING — no clobber)"

# ── S-C3: UPS processes ALL bundled task-ids (loop-all fix, charset-agnostic) ─
# Dispatch two agents; fire ONE UPS with BOTH completion notifications bundled.
# Locks the loop-all-task-ids fix (replaced head -1): both must flip to DONE.
led8="$TMP/.claude/agent-join/state/s8.json"
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s8","tool_name":"Agent","tool_input":{"description":"c1 task"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"cafe0000c1","outputFile":"/tmp/o/cafe0000c1.output"}}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s8","tool_name":"Agent","tool_input":{"description":"c2 task"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"cafe0000c2","outputFile":"/tmp/o/cafe0000c2.output"}}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(runc "$led8")" "2" "s8 two agents dispatched: 2 RUNNING"

# Single UPS carrying two <task-notification> blocks (charset-agnostic ids)
bundled_ups='{"hook_event_name":"UserPromptSubmit","session_id":"s8","prompt":"<task-notification><task-id>cafe0000c1</task-id><status>completed</status><output>done1</output></task-notification> <task-notification><task-id>cafe0000c2</task-id><status>completed</status><output>done2</output></task-notification>"}'
printf '%s' "$bundled_ups" | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe0000c1"].status' "$led8" 2>/dev/null)" "DONE" "s8 bundled UPS: cafe0000c1 -> DONE"
ok "$(jq -r '.agents["cafe0000c2"].status' "$led8" 2>/dev/null)" "DONE" "s8 bundled UPS: cafe0000c2 -> DONE (loop processes all ids, not just first)"

# ── S-fallback: SubagentStop with unmatched id must NOT mark wrong agent ───────
# Dispatch d1 and d2. Fire SubagentStop with id NOT in ledger (cafe0000ZZ).
# Locks the removed wrong-agent fallback: neither d1 nor d2 may flip.
led9="$TMP/.claude/agent-join/state/s9.json"
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s9","tool_name":"Agent","tool_input":{"description":"d1 task"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"cafe0000d1","outputFile":"/tmp/o/cafe0000d1.output"}}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s9","tool_name":"Agent","tool_input":{"description":"d2 task"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"cafe0000d2","outputFile":"/tmp/o/cafe0000d2.output"}}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe0000d1"].status' "$led9" 2>/dev/null)" "RUNNING" "s9 cafe0000d1 dispatched RUNNING"
ok "$(jq -r '.agents["cafe0000d2"].status' "$led9" 2>/dev/null)" "RUNNING" "s9 cafe0000d2 dispatched RUNNING"

# SubagentStop with id NOT in ledger: both d1 and d2 must stay RUNNING
printf '%s' '{"hook_event_name":"SubagentStop","session_id":"s9","agent_id":"cafe0000ZZ","agent_transcript_path":"/tmp/t/cafe0000ZZ.jsonl"}' \
  | HOME="$TMP" bash "$HOOK" >/dev/null
ok "$(jq -r '.agents["cafe0000d1"].status' "$led9" 2>/dev/null)" "RUNNING" "s9 unmatched SubagentStop: cafe0000d1 stays RUNNING (no wrong-agent fallback)"
ok "$(jq -r '.agents["cafe0000d2"].status' "$led9" 2>/dev/null)" "RUNNING" "s9 unmatched SubagentStop: cafe0000d2 stays RUNNING (no wrong-agent fallback)"

# S10 (high-pass fix): a non-terminal background_task status (pending/queued/starting) counts as
# still-live -> Stop must NOT sweep/block it (was: only "running" counted, so pending got swept).
printf '%s' '{"hook_event_name":"PostToolUse","session_id":"s10","tool_name":"Agent","tool_input":{"description":"P"},"tool_response":{"isAsync":true,"agentId":"cafe0000e1","outputFile":"/o/p"}}' | HOME="$TMP" bash "$HOOK" >/dev/null
led10="$TMP/.claude/agent-join/state/s10.json"
out=$(printf '%s' '{"hook_event_name":"Stop","session_id":"s10","background_tasks":[{"type":"subagent","status":"pending","id":"cafe0000e1"}]}' | HOME="$TMP" bash "$HOOK")
ok "$out" "" "s10 pending background_task -> Stop allows rest (no false block)"
ok "$(jq -r '.agents["cafe0000e1"].status' "$led10" 2>/dev/null)" "RUNNING" "s10 pending background_task -> not swept to DONE"
out=$(printf '%s' '{"hook_event_name":"Stop","session_id":"s10","background_tasks":[{"type":"subagent","status":"queued","id":"cafe0000e1"}]}' | HOME="$TMP" bash "$HOOK")
ok "$out" "" "s10 queued background_task -> Stop allows rest"

# ── S11 read-detection (followup): a tool whose input names a DONE-unread agent's id or
# output_file marks it surfaced, so the Stop guard does not re-block an already-read result.
led11="$TMP/.claude/agent-join/state/s11.json"
run '{"hook_event_name":"PostToolUse","session_id":"s11","tool_name":"Agent","tool_input":{"description":"R1"},"tool_response":{"isAsync":true,"agentId":"cafe0000f1","outputFile":"/tmp/o/cafe0000f1.output"}}' >/dev/null
run '{"hook_event_name":"SubagentStop","session_id":"s11","agent_id":"cafe0000f1"}' >/dev/null
ok "$(jq -r '.agents["cafe0000f1"].surfaced' "$led11")" "false" "s11 DONE result starts unread"
# read via TaskOutput referencing the agentId
run '{"hook_event_name":"PostToolUse","session_id":"s11","tool_name":"TaskOutput","tool_input":{"task_id":"cafe0000f1"}}' >/dev/null
ok "$(jq -r '.agents["cafe0000f1"].surfaced' "$led11")" "true" "s11 TaskOutput(agentId) -> surfaced (read detected)"
ok "$(run '{"hook_event_name":"Stop","session_id":"s11","background_tasks":[]}')" "" "s11 Stop after read -> no block (result already consumed)"

# S12: read via Read(output_file path) also surfaces
led12="$TMP/.claude/agent-join/state/s12.json"
run '{"hook_event_name":"PostToolUse","session_id":"s12","tool_name":"Agent","tool_input":{"description":"R2"},"tool_response":{"isAsync":true,"agentId":"cafe0000f2","outputFile":"/tmp/o/cafe0000f2.output"}}' >/dev/null
run '{"hook_event_name":"SubagentStop","session_id":"s12","agent_id":"cafe0000f2"}' >/dev/null
run '{"hook_event_name":"PostToolUse","session_id":"s12","tool_name":"Read","tool_input":{"file_path":"/tmp/o/cafe0000f2.output"}}' >/dev/null
ok "$(jq -r '.agents["cafe0000f2"].surfaced' "$led12")" "true" "s12 Read(output_file) -> surfaced (read detected)"

# S13 (negative): an UNRELATED tool read must NOT surface, and an unread result STILL blocks.
led13="$TMP/.claude/agent-join/state/s13.json"
run '{"hook_event_name":"PostToolUse","session_id":"s13","tool_name":"Agent","tool_input":{"description":"R3"},"tool_response":{"isAsync":true,"agentId":"cafe0000f3","outputFile":"/tmp/o/cafe0000f3.output"}}' >/dev/null
run '{"hook_event_name":"SubagentStop","session_id":"s13","agent_id":"cafe0000f3"}' >/dev/null
run '{"hook_event_name":"PostToolUse","session_id":"s13","tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}' >/dev/null
ok "$(jq -r '.agents["cafe0000f3"].surfaced' "$led13")" "false" "s13 unrelated Read -> not surfaced"
ok "$(jq -r '.decision // ""' <<<"$(run '{"hook_event_name":"Stop","session_id":"s13","background_tasks":[]}')")" "block" "s13 unread result still blocks (stall-prevention intact)"

# ── S-outer: SubagentStop outer RUNNING-guard bite (empty output_file, no backfill on re-fire) ──
# Dispatch with NO outputFile -> output_file="". UPS completes it -> DONE (output_file stays "").
# A later SubagentStop re-fire carrying a transcript must NOT backfill: the outer status==RUNNING
# guard short-circuits the whole transition on the already-DONE row. Drop the outer guard and the
# inner `if output_file==""` backfill runs -> output_file becomes the transcript path -> fails.
led14="$TMP/.claude/agent-join/state/s14.json"
run '{"hook_event_name":"PostToolUse","session_id":"s14","tool_name":"Agent","tool_input":{"description":"E1"},"tool_response":{"isAsync":true,"agentId":"cafe0000e9"}}' >/dev/null
ok "$(jq -r '.agents["cafe0000e9"].output_file' "$led14" 2>/dev/null)" "" "s14 dispatch without outputFile -> empty output_file"
run '{"hook_event_name":"UserPromptSubmit","session_id":"s14","prompt":"<task-notification><task-id>cafe0000e9</task-id><status>completed</status></task-notification>"}' >/dev/null
ok "$(jq -r '.agents["cafe0000e9"].status' "$led14" 2>/dev/null)" "DONE" "s14 UPS completed -> DONE (output_file still empty)"
run '{"hook_event_name":"SubagentStop","session_id":"s14","agent_id":"cafe0000e9","agent_transcript_path":"/tmp/t/cafe0000e9.jsonl"}' >/dev/null
ok "$(jq -r '.agents["cafe0000e9"].output_file' "$led14" 2>/dev/null)" "" "s14 SubagentStop re-fire on DONE row -> transcript NOT backfilled (outer RUNNING guard bites)"

# ── S15 (false-surface, bug1): a tool that merely MENTIONS an agentId must NOT surface it ──────
# Exact leaf-value match, not substring: a Bash `echo agent=<id>` is not a read. With the old
# substring `inside()`, this false-surfaced the row and the Stop guard skipped a real unread
# result — the exact stall the feature prevents. Must stay unread and STILL block.
led15="$TMP/.claude/agent-join/state/s15.json"
run '{"hook_event_name":"PostToolUse","session_id":"s15","tool_name":"Agent","tool_input":{"description":"G1"},"tool_response":{"isAsync":true,"agentId":"cafe0000g1","outputFile":"/tmp/o/cafe0000g1.output"}}' >/dev/null
run '{"hook_event_name":"SubagentStop","session_id":"s15","agent_id":"cafe0000g1"}' >/dev/null
run '{"hook_event_name":"PostToolUse","session_id":"s15","tool_name":"Bash","tool_input":{"command":"echo agent=cafe0000g1 status"}}' >/dev/null
ok "$(jq -r '.agents["cafe0000g1"].surfaced' "$led15" 2>/dev/null)" "false" "s15 Bash mentioning agentId -> NOT surfaced (exact match, not substring)"
ok "$(jq -r '.decision // ""' <<<"$(run '{"hook_event_name":"Stop","session_id":"s15","background_tasks":[]}')")" "block" "s15 unread result STILL blocks (no false-surface stall)"

# ── S16 (false-surface, bug2): reading <output_file>.bak must NOT surface (output_file is a prefix) ──
led16="$TMP/.claude/agent-join/state/s16.json"
run '{"hook_event_name":"PostToolUse","session_id":"s16","tool_name":"Agent","tool_input":{"description":"G2"},"tool_response":{"isAsync":true,"agentId":"cafe0000g2","outputFile":"/tmp/o/cafe0000g2.output"}}' >/dev/null
run '{"hook_event_name":"SubagentStop","session_id":"s16","agent_id":"cafe0000g2"}' >/dev/null
run '{"hook_event_name":"PostToolUse","session_id":"s16","tool_name":"Read","tool_input":{"file_path":"/tmp/o/cafe0000g2.output.bak"}}' >/dev/null
ok "$(jq -r '.agents["cafe0000g2"].surfaced' "$led16" 2>/dev/null)" "false" "s16 Read of <output_file>.bak -> NOT surfaced (exact match, not prefix)"

# ── S17 (false-surface, bug3): short id that is a substring of another agent's output_file path ──
# A id='cafe' (short), B output_file='/tmp/o/cafe0000g3.output'. Reading B's result surfaces B
# only; A's short id is a substring of B's path but must NOT surface under exact leaf matching.
led17="$TMP/.claude/agent-join/state/s17.json"
run '{"hook_event_name":"PostToolUse","session_id":"s17","tool_name":"Agent","tool_input":{"description":"A"},"tool_response":{"isAsync":true,"agentId":"cafe","outputFile":"/tmp/o/cafe.output"}}' >/dev/null
run '{"hook_event_name":"SubagentStop","session_id":"s17","agent_id":"cafe"}' >/dev/null
run '{"hook_event_name":"PostToolUse","session_id":"s17","tool_name":"Agent","tool_input":{"description":"B"},"tool_response":{"isAsync":true,"agentId":"cafe0000g3","outputFile":"/tmp/o/cafe0000g3.output"}}' >/dev/null
run '{"hook_event_name":"SubagentStop","session_id":"s17","agent_id":"cafe0000g3"}' >/dev/null
run '{"hook_event_name":"PostToolUse","session_id":"s17","tool_name":"Read","tool_input":{"file_path":"/tmp/o/cafe0000g3.output"}}' >/dev/null
ok "$(jq -r '.agents["cafe0000g3"].surfaced' "$led17" 2>/dev/null)" "true" "s17 reading B output -> B surfaced (exact match fires for real read)"
ok "$(jq -r '.agents["cafe"].surfaced' "$led17" 2>/dev/null)" "false" "s17 short id 'cafe' substring of B path -> A NOT surfaced (no prefix collision)"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" = 0 ]
