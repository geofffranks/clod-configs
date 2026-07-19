#!/usr/bin/env bash
set -uo pipefail

emit_error() {
  jq -nc --arg message "polytoken hook ${canonical_path:-adapter}: $1" '{outcome:"error",message:$message}'
  exit 0
}

canonical_path="${1:-adapter}"
if [ "$#" -ne 2 ]; then
  emit_error "usage: adapter.sh CANONICAL_RELATIVE_PATH MAPPING"
fi
mapping=$2

command -v jq >/dev/null 2>&1 || emit_error "jq is required"

# Require a plain relative path with no empty, dot, or dot-dot components.
case "$canonical_path" in
  /*|*//*|./*|*/./*|*/.|../*|*/../*|*/..|.|..) emit_error "invalid canonical path" ;;
esac
[ -n "$canonical_path" ] || emit_error "invalid canonical path"

input=$(cat 2>/dev/null) || emit_error "malformed Polytoken input"
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$input"; then
  emit_error "malformed Polytoken input"
fi

case "$mapping" in
  shell)
    hook_event=PreToolUse
    canonical_tool=Bash
    canonical_input=$(jq -c '{command:(.input.command // "")}' <<<"$input") || emit_error "malformed Polytoken input"
    ;;
  read)
    hook_event=PreToolUse
    canonical_tool=Read
    canonical_input=$(jq -c '{file_path:(.input.path // ""),offset:(.input.offset // null),limit:(.input.limit // null)} | with_entries(select(.value != null))' <<<"$input") || emit_error "malformed Polytoken input"
    ;;
  skill)
    hook_event=$(jq -r 'if .event == "post_tool_use" then "PostToolUse" else "PreToolUse" end' <<<"$input") || emit_error "malformed Polytoken input"
    canonical_tool=Skill
    canonical_input=$(jq -c '{skill:(.input.name // ""),args:""}' <<<"$input") || emit_error "malformed Polytoken input"
    ;;
  compact)
    hook_event=PostCompact
    canonical_tool=""
    canonical_input='{}'
    ;;
  *) emit_error "unsupported mapping: $mapping" ;;
esac

export AGENT_CONFIG_DIR="${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}"
canonical_root="${POLYTOKEN_CANONICAL_ROOT:-$AGENT_CONFIG_DIR/compat}"
canonical_script="$canonical_root/$canonical_path"
if command -v python3 >/dev/null 2>&1; then
  if ! python3 - "$canonical_root" "$canonical_script" <<'PY' >/dev/null 2>&1
import os
import sys
root = os.path.realpath(sys.argv[1])
target = os.path.realpath(sys.argv[2])
if os.path.commonpath((root, target)) != root:
    raise SystemExit(1)
PY
  then
    emit_error "canonical path escapes root"
  fi
else
  emit_error "python3 is required for canonical path validation"
fi
[ -f "$canonical_script" ] && [ -x "$canonical_script" ] || emit_error "canonical hook unavailable"

# Polytoken's captured contract has no session id, so use the configured runtime
# id as fallback. Preserve identity only when a runtime payload supplies it.
canonical_stdin=$(jq -nc \
  --argjson source "$input" \
  --arg event "$hook_event" \
  --arg fallback_session "${POLYTOKEN_SESSION_ID:-}" \
  --arg tool "$canonical_tool" \
  --argjson tool_input "$canonical_input" '
    {hook_event_name:$event,
     session_id:($source.session_id // $fallback_session),
     tool_name:$tool,
     tool_input:$tool_input}
    + (if ($source.agent_id? | type) == "string" then {agent_id:$source.agent_id} else {} end)
    + (if ($source.subagent_id? | type) == "string" then {subagent_id:$source.subagent_id} else {} end)
  ') || emit_error "malformed Polytoken input"

stdout_file=$(mktemp "${TMPDIR:-/tmp}/polytoken-hook-out.XXXXXX") || emit_error "unable to capture canonical output"
stderr_file=$(mktemp "${TMPDIR:-/tmp}/polytoken-hook-err.XXXXXX") || {
  rm -f "$stdout_file"
  emit_error "unable to capture canonical output"
}
trap 'rm -f "$stdout_file" "$stderr_file"' EXIT

set +e
printf '%s' "$canonical_stdin" | "$canonical_script" >"$stdout_file" 2>"$stderr_file"
canonical_rc=$?
set -e
cat "$stderr_file" >&2

if [ "$canonical_rc" -ne 0 ]; then
  emit_error "canonical hook exited $canonical_rc"
fi

if [ ! -s "$stdout_file" ]; then
  jq -nc '{outcome:"allow"}'
  exit 0
fi

# jq -s both validates the entire stream and proves it contains exactly one object.
if ! canonical_output=$(jq -sc 'if length == 1 and (.[0] | type == "object") then .[0] else error("invalid stream") end' "$stdout_file" 2>/dev/null); then
  emit_error "malformed canonical output"
fi

if [ "$mapping" = compact ]; then
  emit_error "unexpected canonical output"
fi

if ! jq -e '
  try (
    (.hookSpecificOutput | type) == "object"
    and (.hookSpecificOutput.permissionDecision | type) == "string"
    and (if .hookSpecificOutput.permissionDecision == "deny"
         then (.hookSpecificOutput.permissionDecisionReason | type) == "string"
         else true
         end)
  ) catch false
' >/dev/null 2>&1 <<<"$canonical_output"; then
  emit_error "malformed canonical output"
fi

if ! decision=$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$canonical_output" 2>/dev/null); then
  emit_error "malformed canonical output"
fi
case "$decision" in
  deny)
    if ! jq -c '{outcome:"deny",reason:.hookSpecificOutput.permissionDecisionReason}' <<<"$canonical_output"; then
      emit_error "malformed canonical output"
    fi
    ;;
  allow)
    jq -nc '{outcome:"allow"}'
    ;;
  *) emit_error "unsupported canonical decision" ;;
esac
exit 0
