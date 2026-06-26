---
name: agent-orchestration
description: Use when dispatching multiple asynchronous subagents (the Agent tool, optionally resumed via SendMessage) and waiting on their completions — establishes correlation-by-agentId discipline and how to read the agent-join hook's injected ground truth so a finished subagent is never mistaken for a duplicate.
---

# Agent Orchestration Skill

**When using this skill, begin by stating:** "Using agent-orchestration to track these subagents by id."

You are about to run several subagents concurrently. The failure this prevents: a finished subagent's completion gets misread as a duplicate of an earlier agent's, and you stall waiting on work already done.

## Rules

1. **Correlate by agentId, never by label or summary.** Two agents named "Review auth …" are different agents; only the hex agentId distinguishes them. When a completion arrives, match it to the id you dispatched.
2. **Trust `<orchestration-status>` over memory.** The agent-join hook injects an authoritative block listing RUNNING and DONE/unread agents by id. If it disagrees with your recollection, the block is right.
3. **A Stop-deny means results are ready.** If the harness refuses to let you rest and says agents completed with unread results, read them (TaskOutput) and proceed — do not re-wait.
4. **Dispatch shape:** multiple Agent calls in one response run in parallel; one per response is sequential. Resuming an agent via SendMessage reuses that agent's context.
5. **A re-notification is not new work.** The same agent may notify more than once on each rest; a `dup-note` in the status block flags it. Only act again if you sent that agent a follow-up.

## When you are waiting

End your turn only while at least one agent is genuinely RUNNING per the status block. If the block shows zero RUNNING, you are not waiting — read any unread results and continue.
