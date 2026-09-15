#!/usr/bin/env bash
# Pure notification identity/body formatting helpers.
#
# This library is the SOLE formatter for every notification lane (hook, SSE
# watcher, watchdog, shipper):
#   - notify_identity_title / notify_identity_resolve build the shared title
#     `<repo>[/<branch>] (<session_id>)[ - <session-title>]`.
#   - notify_identity_session_title best-effort enriches the optional
#     session-title component from Polytoken session metadata.
#   - notify_alert_tag assembles the canonical `[<source:type>] ` body prefix.
#   - notify_identity_body bounds the untagged body content.
set -u

_notify_clean_controls() { LC_ALL=C printf '%s' "$1" | tr '[:cntrl:]' ' '; }
notify_identity_title() {
  local session_id="${1:-}" repo="${2:-}" branch="${3:-}" session_title="${4:-}" base has_component=false
  [ -n "$session_id" ] || return 2
  session_id="$(_notify_clean_controls "$session_id")"
  repo="$(_notify_clean_controls "$repo")"; branch="$(_notify_clean_controls "$branch")"
  session_title="$(_notify_clean_controls "$session_title")"
  [ -n "$session_id" ] || return 2
  base=""
  [ -n "$repo" ] && { base="$repo"; has_component=true; }
  [ -n "$branch" ] && { [ -n "$base" ] && base="$base/$branch" || base="$branch"; has_component=true; }
  [ -n "$base" ] || base="($session_id)"
  [ "$has_component" = true ] && base="$base ($session_id)"
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
  # Project-basename fallback: when git yields no repo (not a checkout, git
  # missing, or the path gone) a non-empty project dir still names the repo,
  # keeping non-git project dirs readable; "(<sid>)" only when project
  # identity is genuinely absent.
  [ -n "$repo" ] || { [ -n "$project_dir" ] && repo="${project_dir##*/}"; }
  notify_identity_title "$session_id" "$repo" "$branch" "$title"
}
# Best-effort session-title enrichment: record.json .session_title, then
# session.json .inferred_title, then session.json .last_user_message_preview.
# Sanitized to the notifier charset (alnum plus space . _ / @ : -), bounded to
# 48 chars; prints an empty string on ANY failure (missing jq, missing or
# unreadable files, malformed JSON). Always returns 0 so `set -e` callers are
# unaffected; an empty output simply omits the title segment.
notify_identity_session_title() {
  local sessions_dir="${1:-}" session_id="${2:-}" file_id value=""
  [ -n "$sessions_dir" ] && [ -n "$session_id" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  file_id="${session_id//\//_}"   # slash-bearing ids cannot escape the dir
  value="$(jq -r '.session_title // ""' "$sessions_dir/$file_id/record.json" 2>/dev/null || true)"
  [ -n "$value" ] || value="$(jq -r '.inferred_title // ""' "$sessions_dir/$file_id/session.json" 2>/dev/null || true)"
  [ -n "$value" ] || value="$(jq -r '.last_user_message_preview // ""' "$sessions_dir/$file_id/session.json" 2>/dev/null || true)"
  LC_ALL=C printf '%s' "$value" | tr '\r\n\t' '   ' | tr -cd '[:alnum:] ._/@:-' | cut -c1-48
  return 0
}
# Canonical `[<source:type>] ` body tag. The vocabulary is a fixed, closed set:
#   hook:needs_input                                  consolidated attention alert
#   sse:question_pending sse:approval_pending         watcher (diagnostic source
#   sse:goal_completed                                "event-watcher")
#   watchdog:agent_died watchdog:tui_crash            session watchdog lanes
#   shipper:tui_abnormal_exit                         lifecycle shipper
# Pure string assembly; cannot fail, so a body is always taggable (fail-open).
notify_alert_tag() {
  printf '[%s:%s] ' "${1:-}" "${2:-}"
}
notify_identity_body() {
  local reason="${1:-}" error="${2:-}" question="${3:-}" detail
  reason="$(_notify_clean_controls "$reason")"; error="$(_notify_clean_controls "$error")"; question="$(_notify_clean_controls "$question")"
  detail="$reason"; [ -n "$error" ] && detail="$detail: $error"; [ -n "$question" ] && detail="$detail: $question"
  printf '%s\n' "${detail:0:${AGENT_NOTIFY_BODY_LIMIT:-512}}"
}
