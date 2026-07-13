---
name: agent-orchestration
description: Use when dispatching multiple asynchronous subagents and waiting on their completions — establishes correlation-by-id discipline and how to read each harness's authoritative state so a finished subagent is never mistaken for a duplicate.
---

# Agent Orchestration Skill

**When using this skill, begin by stating:** "Using agent-orchestration to track these subagents by id."

You are about to run several subagents concurrently. The failure this prevents: a finished subagent's completion gets misread as a duplicate of an earlier agent's, and you stall waiting on work already done.

## Shared correlation discipline (both harnesses)

These rules apply regardless of harness:

1. **Correlate by id, never by label or summary.** Two agents named "Review auth …" are different agents; only the unique id distinguishes them. When a completion arrives, match it to the id you dispatched.
2. **Trust authoritative state over memory.** Each harness exposes ground truth about which agents are running vs done. If it disagrees with your recollection, the harness is right.
3. **A re-notification is not new work.** The same agent may surface more than once; a duplicate-completion flag tells you so. Only act again if you sent that agent a follow-up.
4. **End your turn only while at least one agent is genuinely running.** If authoritative state shows zero running, you are not waiting — read any unread results and continue.

## Claude Code

Use the **Agent** tool to dispatch subagents and **SendMessage** to resume one in its existing context; multiple Agent calls in a single response run in parallel, one per response is sequential.

- **Correlate by agentId** (the hex id the Agent tool returns), never by label.
- **Trust the agent-join hook's `<orchestration-status>` block** over memory. It lists RUNNING and DONE/unread agents by id and flags `dup-note` re-notifications.
- **A Stop-deny means results are ready.** If the harness refuses to let you rest and says agents completed with unread results, read them (TaskOutput) and proceed — do not re-wait.

## Polytoken

Use the **`subagent`** tool to dispatch work. Retain the **job id** it returns.

- **Correlate by job id**, never by label.
- **Use `job_block` to wait** while an agent runs, and **`job_result` for its completed output**. Check `job_status` if you are unsure of a job's state.
- **Trust auto-drained completion notifications and native sidebar state.** Polytoken drains a finished subagent's output into your context automatically and surfaces live job state in the sidebar — do not recreate or wait on an agent-join ledger, and there is no Stop-deny handshake to satisfy.
