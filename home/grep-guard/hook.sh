#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
deny() { jq -cn --arg r "grep-guard: $1 Input was not rewritten." '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
if ! jq -e 'type == "object" and .tool_name == "Grep" and (.tool_input | type == "object") and (.tool_input.pattern | type == "string") and ((.tool_input.path | type == "string") or (.tool_input.path | type == "array" and all(.[]; type == "string")))' >/dev/null 2>&1 <<<"$input"; then exit 0; fi
if ! jq -e '.tool_input | has("max_results") and (.max_results | type == "number" and floor == .)' >/dev/null 2>&1 <<<"$input"; then
  deny "max_results is required; use a corrected bounded Grep call (for example, max_results: 20). For broad plain-text discovery, use rtk grep."
fi
pattern=$(jq -r '.tool_input.pattern' <<<"$input")
max_results=$(jq -r '.tool_input.max_results' <<<"$input")
[ "$max_results" -le 20 ] || deny "max_results must be at most 20; use a corrected bounded Grep call (for example, max_results: 20). For broad plain-text discovery, use rtk grep."
alternatives=$(jq -nr --arg p "$pattern" 'reduce ($p | explode[]) as $c ({n:1,depth:0,class:false,escape:false,bad:false}; if .bad then . elif .escape then .escape=false elif $c == 92 then .escape=true elif .class then if $c == 93 then .class=false else . end elif $c == 91 then .class=true elif $c == 40 then .depth += 1 elif $c == 41 then if .depth == 0 then .bad=true else .depth -= 1 end elif $c == 124 and .depth == 0 then .n += 1 else . end) | if .escape or .class or .depth != 0 or .bad then error("malformed") else .n end' 2>/dev/null) || deny "malformed pattern (unmatched character class or parentheses); use a corrected bounded Grep call. For broad plain-text discovery, use rtk grep."
[ "$alternatives" -le 5 ] || deny "pattern has more than five top-level alternatives; use a corrected bounded Grep call (for example, split the search or reduce alternatives). For broad plain-text discovery, use rtk grep."
exit 0
