#!/bin/bash
# skill-once: PreToolUse hook for Claude Code Skill tool
# Prevents the same skill body from being re-injected into context within a
# session. The Skill tool dumps the ENTIRE skill markdown on every invocation
# and the model has no memory it already loaded it 200k tokens ago. On a repeat
# invocation of a skill already loaded this session, this hook DENIES the call
# and tells the model the body is already in context (scroll up).
#
# Per-agent: dedup is namespaced by `agent_id` (present on subagent tool calls,
# absent on the main thread -> "main"). Subagents run in their OWN fresh context,
# so a skill the main thread loaded is NOT in a subagent's context. Without this
# split a subagent would be denied a skill it never loaded and pointed at a body
# it cannot see. Each subagent (and two concurrent subagents) is isolated.
#
# Force escape: if the skill `args` contain "--force" (or "force"), the deny is
# skipped and that (agent, skill) cache entry is cleared so it reloads cleanly.
# Use this when context was summarized and the body genuinely dropped.
#
# Compaction-aware: the companion PostCompact hook (compact.sh) clears the
# per-session cache, so after a real compaction every skill can reload. A TTL
# (default 1800s) is a belt-and-suspenders fallback for partial summarization
# that doesn't fire PostCompact.
#
# Install: Add to .claude/settings.json hooks.PreToolUse with matcher "Skill".
# Savings: one skill body = ~150-400 lines = ~2k-6k tokens per prevented reload.
#
# Config (env vars):
#   SKILL_ONCE_TTL=1800     Seconds before a cached skill load expires (default 1800)
#   SKILL_ONCE_DISABLED=1   Disable the hook entirely

set -euo pipefail

if [ "${SKILL_ONCE_DISABLED:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
if [ "$TOOL_NAME" != "Skill" ]; then
  exit 0
fi

SKILL=$(echo "$INPUT" | jq -r '.tool_input.skill // empty')
ARGS=$(echo "$INPUT" | jq -r '.tool_input.args // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

# Per-agent namespace. Subagent tool calls carry an `agent_id` (unique per
# dispatched subagent); the main thread's input has none. Subagents run in their
# OWN fresh context, so a skill the MAIN thread loaded is NOT in a subagent's
# context — deduping across that boundary would deny a subagent a skill it never
# loaded and point it at a body it cannot see. Namespacing by agent_id keeps each
# subagent (and two concurrent subagents) isolated; "main" is the main thread.
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
AGENT_KEY="${AGENT_ID:-main}"

if [ -z "$SKILL" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

CACHE_DIR="${HOME}/.claude/skill-once"
mkdir -p "$CACHE_DIR"

TTL="${SKILL_ONCE_TTL:-1800}"
NOW=$(date +%s)

# Auto-cleanup: drop session caches older than 24h (at most once/hour)
CLEANUP_MARKER="${CACHE_DIR}/.last-cleanup"
LAST_CLEANUP=$(cat "$CLEANUP_MARKER" 2>/dev/null || echo 0)
LAST_CLEANUP=${LAST_CLEANUP:-0}
if [ $(( NOW - LAST_CLEANUP )) -gt 3600 ]; then
  find "$CACHE_DIR" -name 'session-*.jsonl' -mtime +1 -delete 2>/dev/null || true
  echo "$NOW" > "$CLEANUP_MARKER"
fi

# Portable session hash (must match compact.sh)
if command -v sha256sum >/dev/null 2>&1; then
  SESSION_HASH=$(echo -n "$SESSION_ID" | sha256sum | cut -c1-16)
else
  SESSION_HASH=$(echo -n "$SESSION_ID" | shasum -a 256 | cut -c1-16)
fi
CACHE_FILE="${CACHE_DIR}/session-${SESSION_HASH}.jsonl"
STATS_FILE="${CACHE_DIR}/stats.jsonl"

# Force escape — model explicitly wants a reload (e.g. body dropped post-summary)
if echo "$ARGS" | grep -qiE '(^|[[:space:]])--?force([[:space:]]|$)'; then
  # Drop any prior entry for this (agent, skill) pair so it caches fresh on reload
  if [ -f "$CACHE_FILE" ]; then
    jq -c --arg s "$SKILL" --arg a "$AGENT_KEY" \
      'select(.skill != $s or .agent != $a)' "$CACHE_FILE" > "${CACHE_FILE}.tmp" 2>/dev/null || true
    mv -f "${CACHE_FILE}.tmp" "$CACHE_FILE" 2>/dev/null || true
  fi
  echo "{\"skill\":\"${SKILL}\",\"agent\":\"${AGENT_KEY}\",\"ts\":${NOW}}" >> "$CACHE_FILE"
  echo "{\"ts\":${NOW},\"skill\":\"${SKILL}\",\"agent\":\"${AGENT_KEY}\",\"session\":\"${SESSION_HASH}\",\"event\":\"force\"}" >> "$STATS_FILE"
  exit 0
fi

# Look up the last load of this skill BY THIS AGENT in this session
CACHED_TS=""
if [ -f "$CACHE_FILE" ]; then
  CACHED_TS=$(jq -r --arg s "$SKILL" --arg a "$AGENT_KEY" \
    'select(.skill == $s and .agent == $a) | .ts' "$CACHE_FILE" 2>/dev/null | tail -1 || echo "")
fi

if [ -n "$CACHED_TS" ]; then
  ENTRY_AGE=$(( NOW - CACHED_TS ))
  if [ "$ENTRY_AGE" -lt "$TTL" ]; then
    # This agent already loaded this skill, within TTL — DENY the reload.
    MINUTES_AGO=$(( ENTRY_AGE / 60 ))
    echo "{\"ts\":${NOW},\"skill\":\"${SKILL}\",\"agent\":\"${AGENT_KEY}\",\"session\":\"${SESSION_HASH}\",\"event\":\"hit\"}" >> "$STATS_FILE"
    REASON="skill-once: '${SKILL}' already loaded this session (${MINUTES_AGO}m ago). Its full body is already in your context above — scroll up and re-read it instead of reloading. If the body was dropped by a context summary and you genuinely cannot find it, re-invoke with args containing --force to reload."
    jq -cn --arg r "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
    exit 0
  fi
  # Expired — fall through to allow + refresh timestamp
fi

# First load by this agent this session (or expired) — record and allow
echo "{\"skill\":\"${SKILL}\",\"agent\":\"${AGENT_KEY}\",\"ts\":${NOW}}" >> "$CACHE_FILE"
EVENT="miss"
[ -n "$CACHED_TS" ] && EVENT="expired"
echo "{\"ts\":${NOW},\"skill\":\"${SKILL}\",\"agent\":\"${AGENT_KEY}\",\"session\":\"${SESSION_HASH}\",\"event\":\"${EVENT}\"}" >> "$STATS_FILE"
exit 0
