#!/usr/bin/env bash
# no-remote-writes.sh
# Claude Code PreToolUse hook. Blocks `git push` and `gh` write
# subcommands. Allows everything else.
#
# Input (stdin, JSON): {"tool_name":"Bash","tool_input":{"command":"..."}}
# Output:
#   - When blocking: a JSON object on stdout with hookSpecificOutput.permissionDecision="deny"
#   - When allowing: empty stdout, exit 0
set -euo pipefail

emit_deny() {
  local reason="$1"
  jq -nc --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")
[ "$tool" = "Bash" ] || exit 0   # only operate on Bash

cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
[ -z "$cmd" ] && exit 0

# Normalize: strip git global flags (-C <dir>, -c k=v, --git-dir=p, etc.)
# so subcommand patterns match regardless of how git was invoked.
_normalize_git_flags() {
  local result
  result=$(python3 - "$1" <<'PYEOF' 2>/dev/null
import re, sys
TWO = {'-C','-c','--exec-path','--html-path','--man-path','--info-path',
       '--work-tree','--git-dir','--namespace','--super-prefix','--attr-source'}
def norm(seg):
    tok = seg.split()
    out, i = [], 0
    while i < len(tok):
        if tok[i] == 'git':
            out.append('git'); i += 1
            while i < len(tok) and tok[i].startswith('-'):
                i += 2 if tok[i] in TWO and i+1 < len(tok) else 1
            out.extend(tok[i:]); break
        else:
            out.append(tok[i]); i += 1
    return ' '.join(out)
parts = re.split(r'(\s*(?:&&|\|\||;)\s*)', sys.argv[1])
print(''.join(norm(p) if not re.match(r'^\s*(?:&&|\|\||;)\s*$',p) else p for p in parts))
PYEOF
)
  printf '%s' "${result:-$1}"
}
cmd=$(_normalize_git_flags "$cmd")

# --- git push: always block ---
# Anchor at command start OR after a shell separator.
if [[ "$cmd" =~ (^|[[:space:]]|;|\&\&|\|\|)git[[:space:]]+push([[:space:]]|$) ]]; then
  emit_deny "git push is blocked. Ask the user to push."
fi

# --- gh: default-deny with read-only allowlist ---
# Walk over each shell-separated segment; if any segment is `gh ...` and
# does not match a read-only pattern, deny the whole command.
#
# Simple split: replace separators with newlines, iterate.
segments=$(printf '%s' "$cmd" | sed -E 's/(\&\&|\|\||;)/\n/g')

while IFS= read -r seg; do
  # trim leading whitespace
  seg="${seg#"${seg%%[![:space:]]*}"}"
  # Strip leading ( for subshells
  seg="${seg#\(}"
  seg="${seg#"${seg%%[![:space:]]*}"}"

  # Only inspect segments starting with `gh` followed by whitespace
  [[ "$seg" =~ ^gh($|[[:space:]]) ]] || continue

  # Read-only allowlist
  if [[ "$seg" =~ ^gh[[:space:]]+(--version|--help|help|version|status|browse|search) ]]; then
    continue
  fi
  if [[ "$seg" =~ ^gh[[:space:]]+auth[[:space:]]+status ]]; then
    continue
  fi
  if [[ "$seg" =~ ^gh[[:space:]]+(pr|issue|repo|release|run|workflow|gist|cache|label|project|ruleset|codespace)[[:space:]]+(view|list|status|diff|checks|download)([[:space:]]|$) ]]; then
    continue
  fi
  if [[ "$seg" =~ ^gh[[:space:]]+api([[:space:]]|$) ]]; then
    # gh api: allow only if no -X / --method, or -X GET / --method GET
    if [[ "$seg" =~ -X[[:space:]]+(POST|PUT|PATCH|DELETE) ]] \
    || [[ "$seg" =~ --method[[:space:]]+(POST|PUT|PATCH|DELETE) ]]; then
      emit_deny "gh write commands are blocked. Ask the user to do this."
    fi
    continue
  fi

  # Anything else starting with `gh` is a write
  emit_deny "gh write commands are blocked. Ask the user to do this."
done <<<"$segments"

exit 0
