#!/usr/bin/env bash
set -uo pipefail
input=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object" and .tool_name == "Read" and (.tool_input | type == "object") and (.tool_input.file_path | type == "string")' >/dev/null 2>&1 <<<"$input" || exit 0
path=$(jq -r '.tool_input.file_path' <<<"$input")
if jq -e '(.tool_input | has("max_bytes") and (.max_bytes | type == "number" and floor == . and . > 0)) or (.tool_input | has("offset") and has("limit") and (.offset | type == "number" and floor == . and . >= 0) and (.limit | type == "number" and floor == . and . > 0))' >/dev/null 2>&1 <<<"$input"; then exit 0; fi
if jq -e '(.tool_input | has("offset") or has("limit") or has("max_bytes"))' >/dev/null 2>&1 <<<"$input"; then exit 0; fi
base=${POLYTOKEN_CWD:-${PWD:-.}}
if [[ "$path" != /* ]]; then path="$base/$path"; fi
resolved=$(realpath -e -- "$path" 2>/dev/null) || exit 0
if [[ "$OSTYPE" == darwin* ]]; then
  kind=$(stat -f '%HT' -- "$resolved" 2>/dev/null) || exit 0
  size=$(stat -f '%z' -- "$resolved" 2>/dev/null) || exit 0
else
  kind=$(stat -c '%F' -- "$resolved" 2>/dev/null) || exit 0
  size=$(stat -c '%s' -- "$resolved" 2>/dev/null) || exit 0
fi
[ "$kind" = "regular file" ] || [ "$kind" = "Regular File" ] || exit 0
name=${resolved##*/}; limit=256000
case "$name" in *.[dD][iI][fF][fF]|*.[pP][aA][tT][cC][hH]|*.[lL][oO][gG]) limit=51200 ;; esac
if [ "$size" -gt "$limit" ]; then jq -cn --arg r "large-read-guard: unbounded Read denied for oversized regular file ($size bytes); provide a positive max_bytes or non-negative offset with a positive limit. Input was not rewritten." '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; fi
exit 0
