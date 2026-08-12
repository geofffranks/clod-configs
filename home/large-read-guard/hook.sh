#!/usr/bin/env bash
set -uo pipefail
input=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object" and .tool_name == "Read" and (.tool_input | type == "object") and (.tool_input.file_path | type == "string")' >/dev/null 2>&1 <<<"$input" || exit 0
path=$(jq -r '.tool_input.file_path' <<<"$input")
if jq -e '(.tool_input | has("max_bytes") and (.max_bytes | type == "number" and floor == . and . > 0)) or (.tool_input | has("offset") and has("limit") and (.offset | type == "number" and floor == . and . >= 0) and (.limit | type == "number" and floor == . and . > 0))' >/dev/null 2>&1 <<<"$input"; then exit 0; fi
if jq -e '(.tool_input | has("offset") or has("limit") or has("max_bytes"))' >/dev/null 2>&1 <<<"$input"; then exit 0; fi
base=${POLYTOKEN_CWD:-${PWD:-.}}
if [[ "$path" != /* ]]; then
  command -v python3 >/dev/null 2>&1 || exit 0
  path=$(python3 - "$base" "$path" <<'PY' 2>/dev/null
import os, sys
base, value = sys.argv[1:]
base = os.path.abspath(base)
candidate = os.path.abspath(os.path.join(base, value))
if os.path.commonpath((base, candidate)) != base:
    raise SystemExit(1)
print(candidate)
PY
  ) || exit 0
fi
# Resolve exactly one link. The target itself must not be another link.
target=$path
if [ -L "$path" ]; then
  link=$(readlink -- "$path" 2>/dev/null) || exit 0
  case "$link" in
    /*) target=$link ;;
    *) target="$(dirname -- "$path")/$link" ;;
  esac
  [ -L "$target" ] && exit 0
fi
[ -r "$target" ] || exit 0
if [[ "$OSTYPE" == darwin* ]]; then
  snapshot() { stat -f '%HT|%z|%d|%i|%m' -- "$1" 2>/dev/null; }
else
  snapshot() { stat -c '%F|%s|%d|%i|%Y' -- "$1" 2>/dev/null; }
fi
before=$(snapshot "$target") || exit 0
kind=${before%%|*}
[ "$kind" = "regular file" ] || [ "$kind" = "Regular File" ] || exit 0
before_size=${before#*|}; before_size=${before_size%%|*}
# Re-stat after the access/type checks; a changed identity or size fails open.
after=$(snapshot "$target") || exit 0
if [ "$before" != "$after" ]; then
  printf '%s\n' 'large-read-guard: metadata changed; allowing read' >&2
  exit 0
fi
name=${target##*/}; limit=256000
case "$name" in *.[dD][iI][fF][fF]|*.[pP][aA][tT][cC][hH]|*.[lL][oO][gG]) limit=51200 ;; esac
if [ "$before_size" -gt "$limit" ]; then jq -cn --arg r "large-read-guard: unbounded Read denied for oversized regular file ($before_size bytes); provide a positive max_bytes or non-negative offset with a positive limit. Input was not rewritten." '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; fi
exit 0
