#!/usr/bin/env bash
# Pure notification identity/body formatting helpers.
set -u

_notify_clean_controls() { printf '%s' "$1" | tr '\r\n\t' '   '; }
notify_identity_title() {
  local session_id="${1:-}" repo="${2:-}" branch="${3:-}" session_title="${4:-}" base
  [ -n "$session_id" ] || return 2
  session_id="$(_notify_clean_controls "$session_id")"
  repo="$(_notify_clean_controls "$repo")"; branch="$(_notify_clean_controls "$branch")"
  session_title="$(_notify_clean_controls "$session_title")"
  [ -n "$session_id" ] || return 2
  base=""
  [ -n "$repo" ] && base="$repo"
  [ -n "$branch" ] && { [ -n "$base" ] && base="$base/$branch" || base="$branch"; }
  [ -n "$base" ] || base="($session_id)"
  [ "$base" = "($session_id)" ] || base="$base ($session_id)"
  [ -n "$session_title" ] && base="$base - $session_title"
  [ "${#base}" -le "${AGENT_NOTIFY_MAX_LENGTH:-1024}" ] || return 3
  printf '%s\n' "$base"
}
notify_identity_resolve() {
  local session_id="${1:-}" project_dir="${2:-}" title="${3:-}" repo="" branch="" common=""
  [ -n "$session_id" ] || return 2
  if [ -n "$project_dir" ] && command -v git >/dev/null 2>&1; then
    branch="$(git -C "$project_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    common="$(git -C "$project_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    case "$common" in *.git) common="${common%.git}";; esac
    common="${common%/}"; [ -n "$common" ] && repo="${common##*/}"
  fi
  notify_identity_title "$session_id" "$repo" "$branch" "$title"
}
notify_identity_body() {
  local reason="${1:-}" error="${2:-}" question="${3:-}" detail
  reason="$(_notify_clean_controls "$reason")"; error="$(_notify_clean_controls "$error")"; question="$(_notify_clean_controls "$question")"
  detail="$reason"; [ -n "$error" ] && detail="$detail: $error"; [ -n "$question" ] && detail="$detail: $question"
  printf '%s\n' "${detail:0:${AGENT_NOTIFY_BODY_LIMIT:-512}}"
}
