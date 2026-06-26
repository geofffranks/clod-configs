# cc-ukyn spike findings — real hook-event payloads (Task 2)

Captured live 2026-06-25 via `home/agent-join/probe.sh` registered on PostToolUse[Agent],
SubagentStop, UserPromptSubmit, Stop. These are the confirmed accessors Tasks 4–7 use.

## S1 — PostToolUse[Agent]: agentId + label + output

Field key is **`.tool_response`** (NOT `.tool_result` — the public doc is wrong for this build).
`.tool_response` is a **JSON object**, not a string. Verbatim:

```json
"tool_name":"Agent",
"tool_input":{"description":"Find TODOs in repo","prompt":"...","subagent_type":"Explore"},
"tool_response":{"isAsync":true,"status":"async_launched","agentId":"a18b91812cfdcf6b2",
  "description":"Find TODOs in repo","resolvedModel":"claude-sonnet-4-6","prompt":"...",
  "outputFile":"/private/tmp/.../tasks/a18b91812cfdcf6b2.output","canReadOutputFile":true}
```

Accessors:
- agentId  → `.tool_response.agentId`  (fallback `.tool_result.agentId` for other builds)
- label    → `.tool_input.description`
- output   → `.tool_response.outputFile`  (canonical, available at dispatch time)
- async?   → `.tool_response.isAsync == true` / `.tool_response.status == "async_launched"`

**Correction to plan:** the original `grep -oE 'agentId: <hex>'` on a string is WRONG — `tool_response`
is an object. Use `jq -r '.tool_response.agentId // .tool_result.agentId // ""'`.

## Linchpin — id-equality (make-or-break): PASS

PostToolUse `.tool_response.agentId` = `a18b91812cfdcf6b2`
SubagentStop `.agent_id`             = `a18b91812cfdcf6b2`
**Identical.** Correlation by agentId across the two events works. No id-mapping fallback needed.

## S5 — SubagentStop

```json
"hook_event_name":"SubagentStop","agent_id":"a18b91812cfdcf6b2","agent_type":"Explore",
"stop_hook_active":false,
"agent_transcript_path":".../subagents/agent-a18b91812cfdcf6b2.jsonl",
"last_assistant_message":"<the subagent's final result text>",
"background_tasks":[{"id":"a18b91812cfdcf6b2","type":"subagent","status":"running",...}]
```
- which agent finished → `.agent_id` (== dispatch agentId)
- result available via `.last_assistant_message` (inline) and `.agent_transcript_path` (file)
- NOTE: `agent_type` was `""` in one cross-session capture — do not rely on it for matching; use `agent_id`.
- output_file: prefer the `outputFile` captured at PostToolUse; `.agent_transcript_path` is a fallback.

## S2 — UserPromptSubmit DOES fire on task-notification turns: YES

A `UserPromptSubmit` event fired whose `.prompt` was the full notification:
```
<task-notification>
<task-id>a18b91812cfdcf6b2</task-id>
<output-file>/private/tmp/.../a18b91812cfdcf6b2.output</output-file>
<status>completed</status>
...<result>...</result>
</task-notification>
```
- `<task-id>` == the agentId (ledger key). Parse it from `.prompt`.
- `<status>` is one of **completed | failed | killed** — saw `failed` notifications from a crashed
  session ("Background agent ... was running when the previous Claude Code process exited"). The hook
  must treat ALL terminal statuses as "no longer running," not just `completed`.
- So the UserPromptSubmit reconcile path is LIVE (not merely opportunistic); it co-exists with the
  SubagentStop primary path (redundant, both fine).

## S4 — Stop

```json
"hook_event_name":"Stop","stop_hook_active":false,
"last_assistant_message":"...",
"background_tasks":[{"id":"a18b91812cfdcf6b2","type":"subagent","status":"running","description":"...","agent_type":"Explore"}]
```
When the dispatched agent had finished, `"background_tasks":[]`.
- **`.background_tasks` is the authoritative live running-subagent set** — better ground truth than a
  self-maintained counter. Running subagents = `.background_tasks | map(select(.type=="subagent" and .status=="running"))`.
- `.stop_hook_active` confirmed present → secondary loop-guard.

## S3 — injection shape (already confirmed from caveman hook)

`{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"..."}}` on stdout. ✓

## Cross-session note

probe.log interleaved events from THREE sessions (herdle test, foundry-mcp-tools, a crashed session).
Confirms the hook MUST key all state by `.session_id` — which the per-session ledger design already does.
