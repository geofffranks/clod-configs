#!/usr/bin/env bash
# agent-join: deterministic outstanding-subagent ledger + stall guard.
# Generic Claude Code harness hook; no superpowers coupling. Fail-open always.
command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat 2>/dev/null) || exit 0
EVENT=$(jq -r '.hook_event_name // ""' <<<"$INPUT" 2>/dev/null) || exit 0
SID=$(jq -r '.session_id // ""' <<<"$INPUT" 2>/dev/null)
[ -n "$SID" ] && [ "$SID" != "null" ] || exit 0

STATE_DIR="${HOME}/.claude/agent-join/state"
LEDGER="${STATE_DIR}/${SID}.json"
# running_fallback is a DIAGNOSTIC counter only — no control-flow path reads it (actionable()
# scans .agents statuses; the Stop guard uses the authoritative .background_tasks). Kept for
# observability/test sanity; safe to drop in a future cleanup if it stops earning its keep.
DEFAULT='{"agents":{},"running_fallback":0}'

ledger_read(){ [ -f "$LEDGER" ] && cat "$LEDGER" 2>/dev/null || printf '%s' "$DEFAULT"; }
# Refuse to persist empty/invalid JSON: a jq error anywhere upstream would otherwise write a
# corrupt ledger and wedge the session (every later read re-errors). On bad input keep the last
# good state (fail-open). chmod 600 — the ledger names agents and their output_file paths.
ledger_write(){ printf '%s' "$1" | jq -e . >/dev/null 2>&1 || return 0; mkdir -p "$STATE_DIR"; printf '%s' "$1" > "${LEDGER}.tmp" 2>/dev/null && mv -f "${LEDGER}.tmp" "$LEDGER" 2>/dev/null && chmod 600 "$LEDGER" 2>/dev/null; }
# actionable: 0 (true) if any RUNNING agent or any unread DONE (surfaced==false)
actionable(){ jq -e '(.agents|to_entries|map(.value)|any(.status=="RUNNING")) or (.agents|to_entries|map(.value)|any(.status=="DONE" and (.surfaced|not)))' <<<"$1" >/dev/null 2>&1; }

L="$(ledger_read)"

case "$EVENT" in
  PostToolUse)
    # Non-Agent / non-async dispatches are not tracked: plain exit (no ledger effect).
    [ "$(jq -r '.tool_name // ""' <<<"$INPUT")" = "Agent" ] || exit 0
    # S1 (spike-confirmed): tool_response is a JSON OBJECT (not a string); this build
    # uses `.tool_response` (doc's `.tool_result` kept as fallback). agentId, outputFile,
    # and the label are all structured fields. Only record async dispatches.
    [ "$(jq -r '.tool_response.isAsync // .tool_result.isAsync // false' <<<"$INPUT")" = "true" ] || exit 0
    AID=$(jq -r '.tool_response.agentId // .tool_result.agentId // ""' <<<"$INPUT")
    [ -n "$AID" ] && [ "$AID" != "null" ] || exit 0
    LABEL=$(jq -r '.tool_input.description // ""' <<<"$INPUT")
    OUT=$(jq -r '.tool_response.outputFile // .tool_result.outputFile // ""' <<<"$INPUT")
    # Idempotent insert: NEVER clobber an existing row. A duplicate PostToolUse for an
    # already-tracked agent (or a reused agentId) must not reset a DONE/surfaced row back to
    # RUNNING/surfaced:false, which would re-enter the inject/block paths for a read result.
    L=$(jq --arg id "$AID" --arg lbl "$LABEL" --arg out "$OUT" \
        'if (.agents|has($id)) then . else .agents[$id]={label:$lbl,status:"RUNNING",output_file:$out,notified_count:0,surfaced:false} | .running_fallback+=1 end' <<<"$L")
    ledger_write "$L"
    exit 0 ;;
  SubagentStop)
    actionable "$L" || exit 0
    # S5 (spike-confirmed): SubagentStop carries `.agent_id`, equal to the agentId captured
    # at PostToolUse (Task 2 linchpin PASSED). No result field; the subagent's transcript is
    # `.agent_transcript_path`. output_file was already set from the dispatch outputFile —
    # only backfill it from the transcript path if it was empty.
    AID=$(jq -r '.agent_id // ""' <<<"$INPUT")
    TPATH=$(jq -r '.agent_transcript_path // .transcript_path // ""' <<<"$INPUT")
    # Correlate STRICTLY by agent_id (== dispatch agentId; linchpin verified). If it is absent
    # or unmatched, do NOTHING — never guess a different RUNNING row: with 2+ concurrent agents
    # that would mark the wrong one DONE and swap its result file. A genuinely-finished agent we
    # failed to match is recovered by the Stop reconcile-sweep via authoritative background_tasks.
    # Trade-off: on a (hypothetical) build that never sends background_tasks AND an unmatched
    # agent_id, the sweep can't recover it — accepted, vs. the worse data-swap of guessing a row.
    # Idempotent: transition only on RUNNING->DONE (SubagentStop and UserPromptSubmit both fire).
    if [ -n "$AID" ] && [ "$(jq -r --arg id "$AID" '.agents[$id]//empty' <<<"$L")" != "" ]; then
      L=$(jq --arg id "$AID" --arg tp "$TPATH" 'if .agents[$id].status=="RUNNING" then .agents[$id].status="DONE" | (if (.agents[$id].output_file // "")=="" then .agents[$id].output_file=$tp else . end) | .running_fallback=([.running_fallback-1,0]|max) else . end' <<<"$L")
      ledger_write "$L"
    fi
    exit 0 ;;
  UserPromptSubmit)
    actionable "$L" || exit 0
    # (a) Reconcile from task-notification(s) (spike S2 CONFIRMED: UserPromptSubmit fires on
    # notification turns and `.prompt` holds the full <task-notification>; <task-id> == agentId).
    # Multiple completions can bundle into ONE turn -> process EVERY <task-id>, not just the
    # first. Match the id charset-agnostically (<task-id>...</task-id>), not lowercase-hex only.
    # Terminal status is completed|failed|killed — all mean "no longer running" (a crashed
    # session emits failed). A <task-notification> only ever fires when an agent comes to REST,
    # so every <task-id> in the prompt is a completion — there is no "still-running" notification
    # to mis-flip. notified_count bumps on every notification (drives dup-notes); the
    # status/decrement transition fires once, on RUNNING->DONE (idempotent vs SubagentStop).
    PROMPT=$(jq -r '.prompt // ""' <<<"$INPUT")
    if grep -qE '<status>(completed|failed|killed)</status>' <<<"$PROMPT"; then
      while IFS= read -r TID; do
        [ -n "$TID" ] || continue
        L=$(jq --arg id "$TID" 'if .agents[$id] then .agents[$id].notified_count+=1 | (if .agents[$id].status=="RUNNING" then .agents[$id].status="DONE" | .running_fallback=([.running_fallback-1,0]|max) else . end) else . end' <<<"$L")
      done < <(grep -oE '<task-id>[^<]+</task-id>' <<<"$PROMPT" | sed -E 's/<\/?task-id>//g')
      ledger_write "$L"
    fi
    actionable "$L" || exit 0
    # (b) Build and inject the status block.
    RUN=$(jq -r '[.agents|to_entries[]|select(.value.status=="RUNNING")|"  RUNNING  \(.key)  \(.value.label)"]|join("\n")' <<<"$L")
    UNREAD=$(jq -r '[.agents|to_entries[]|select(.value.status=="DONE" and (.value.surfaced|not))|"  DONE/unread  \(.key)  \(.value.label)  result:\(.value.output_file)"]|join("\n")' <<<"$L")
    DUPS=$(jq -r '[.agents|to_entries[]|select(.value.notified_count>1)|"  dup-note: \(.key) notified \(.value.notified_count)x — a re-notification, not new work"]|join("\n")' <<<"$L")
    BLOCK=$(printf '<orchestration-status>\nCorrelate completions by agentId, never by label.\n%s\n%s\n%s\n</orchestration-status>' "$RUN" "$UNREAD" "$DUPS")
    jq -cn --arg c "$BLOCK" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
    exit 0 ;;
  Stop)
    actionable "$L" || exit 0
    # Doc-sanctioned loop guard: never block two stops in a row (surfaced also prevents it).
    [ "$(jq -r '.stop_hook_active // false' <<<"$INPUT")" = "true" ] && exit 0
    # `.background_tasks` is the harness's AUTHORITATIVE live running-subagent set (spike).
    # Count any subagent NOT in a terminal state as still-live (running/pending/queued/starting):
    # matching only "running" would let a not-yet-started agent be swept to DONE and false-blocked.
    # If it reports any live subagent, we are genuinely waiting -> allow rest.
    BG_RUNNING=$(jq -r 'if (.background_tasks|type)=="array" then ([.background_tasks[]|select(.type=="subagent" and (.status as $s | ["completed","failed","killed","done"]|index($s)|not))]|length) else 0 end' <<<"$INPUT" 2>/dev/null)
    case "$BG_RUNNING" in ''|*[!0-9]*) BG_RUNNING=0 ;; esac
    [ "$BG_RUNNING" -gt 0 ] && exit 0
    # Reconcile stale RUNNING rows to DONE ONLY when background_tasks is genuinely present as an
    # array (authoritative "nothing running"). If the field is absent/malformed we must NOT sweep
    # — fabricating completions there would falsely block agents that are actually still running.
    if [ "$(jq -r '(.background_tasks|type)=="array"' <<<"$INPUT" 2>/dev/null)" = "true" ]; then
      L=$(jq '.agents |= with_entries(if .value.status=="RUNNING" then .value.status="DONE" else . end) | .running_fallback=0' <<<"$L")
    fi
    UNREAD=$(jq -r '[.agents|to_entries[]|select(.value.status=="DONE" and (.value.surfaced|not))|.key]|length' <<<"$L")
    if [ "$UNREAD" -eq 0 ]; then ledger_write "$L"; exit 0; fi
    DETAIL=$(jq -r '[.agents|to_entries[]|select(.value.status=="DONE" and (.value.surfaced|not))|"\(.key) (\(.value.label)) result:\(.value.output_file)"]|join("; ")' <<<"$L")
    REASON="You are NOT waiting — these subagents already completed and their results are unread: ${DETAIL}. Read each result (its output_file / TaskOutput) and proceed; do not treat the completion notifications as duplicates."
    # Emit the block BEFORE persisting surfaced=true. If the process dies between the two, the
    # worst case is a harmless re-block on the next Stop — never a silently-disarmed guard, which
    # a persist-then-emit ordering would risk (crash after the write = permanent silent stall).
    jq -cn --arg r "$REASON" '{decision:"block",reason:$r}'
    L=$(jq '.agents |= with_entries(if (.value.status=="DONE" and (.value.surfaced|not)) then .value.surfaced=true else . end)' <<<"$L")
    ledger_write "$L"
    exit 0 ;;
  *) actionable "$L" || exit 0 ;;
esac
exit 0
