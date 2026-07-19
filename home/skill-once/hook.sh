#!/bin/bash
set -euo pipefail
command -v dirname >/dev/null 2>&1 || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" 2>/dev/null || exit 0
# shellcheck source=state.sh
. "$SCRIPT_DIR/state.sh" 2>/dev/null || exit 0
trap skill_once_exit_cleanup EXIT
[ "${SKILL_ONCE_DISABLED:-0}" = 1 ] && exit 0
for cmd in cat date jq; do command -v "$cmd" >/dev/null 2>&1 || exit 0; done
INPUT=$(cat 2>/dev/null) || exit 0
jq -e 'type=="object" and (.hook_event_name|type)=="string" and (.tool_name|type)=="string" and (.session_id|type)=="string" and (.session_id|length)>0 and (.tool_input|type)=="object" and (.tool_input.skill|type)=="string" and (.tool_input.skill|length)>0 and ((.tool_input|has("args")|not) or (.tool_input.args|type)=="string") and ((has("agent_id")|not) or (.agent_id|type)=="string")' >/dev/null 2>&1 <<<"$INPUT" || exit 0
EVENT=$(jq -r .hook_event_name <<<"$INPUT") || exit 0
TOOL_NAME=$(jq -r .tool_name <<<"$INPUT") || exit 0
SKILL=$(jq -r .tool_input.skill <<<"$INPUT") || exit 0
ARGS=$(jq -r '.tool_input.args // ""' <<<"$INPUT") || exit 0
SESSION_ID=$(jq -r .session_id <<<"$INPUT") || exit 0
AGENT_ID=$(jq -r '.agent_id // ""' <<<"$INPUT") || exit 0
[ "$TOOL_NAME" = Skill ] || exit 0
case "$EVENT" in PreToolUse|PostToolUse) ;; *) exit 0 ;; esac
TTL=${SKILL_ONCE_TTL:-1800}; case "$TTL" in ''|*[!0-9]*) exit 0 ;; esac
AGENT_KEY=${AGENT_ID:-main}; NOW=$(date +%s) || exit 0
skill_once_init "$SESSION_ID" || exit 0
OP_LABEL=${SKILL_ONCE_TEST_OP_ID:-}
if [ -z "$OP_LABEL" ]; then
  if [ "$EVENT" = PostToolUse ]; then OP_LABEL=post
  elif grep -qiE '(^|[[:space:]])--?force([[:space:]]|$)' <<<"$ARGS"; then OP_LABEL=force
  else OP_LABEL=pre
  fi
fi
skill_once_lock "$OP_LABEL" || exit 0
skill_once_cleanup_stale "$NOW" || true
if [ "$EVENT" = PostToolUse ]; then
  line=$(jq -cn --arg skill "$SKILL" --arg agent "$AGENT_KEY" --argjson ts "$NOW" '{skill:$skill,agent:$agent,ts:$ts}') || exit 0
  skill_once_append "$line" || exit 0
  exit 0
fi
if grep -qiE '(^|[[:space:]])--?force([[:space:]]|$)' <<<"$ARGS"; then
  skill_once_remove "$SKILL" "$AGENT_KEY" || exit 0
  exit 0
fi
jq_out="$(jq -r --arg s "$SKILL" --arg a "$AGENT_KEY" 'select(.skill == $s and .agent == $a) | .ts' "$SKILL_ONCE_CACHE_FILE" 2>/dev/null)" || jq_out=""
CACHED_TS="$(tail -1 <<<"$jq_out" 2>/dev/null)" || CACHED_TS=""
[[ "$CACHED_TS" =~ ^[0-9]+$ ]] || CACHED_TS=""
if [ -n "$CACHED_TS" ] && [ $((NOW-CACHED_TS)) -lt "$TTL" ]; then
  MINUTES_AGO=$(((NOW-CACHED_TS)/60))
  REASON="skill-once: '${SKILL}' was successfully loaded in this agent context (${MINUTES_AGO}m ago). Its full body is already in your context above — scroll up and re-read it instead of reloading. If a context summary dropped the body, re-invoke with args containing --force."
  jq -cn --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
