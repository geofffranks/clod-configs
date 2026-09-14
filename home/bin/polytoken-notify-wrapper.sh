#!/usr/bin/env bash
# polytoken-notify-wrapper: native launcher wrapper (candidate lifecycle owner).
# Runs the real polytoken TUI in the foreground, faithfully forwards its exit
# status, and records how the TUI ended as an inert notify-exit-record/v1 line.
# It NEVER sends notifications and never touches the TUI's signals beyond what
# a normal launcher receives. Portable bash (3.2+), jq-free.
set -u
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)"
# shellcheck source=../lib/notify-exit-record.sh
. "$_LIB/notify-exit-record.sh"
unset _LIB

command -v polytoken >/dev/null 2>&1 || { echo "polytoken-notify-wrapper: polytoken not on PATH" >&2; exit 127; }

started="$(date +%s)"
polytoken "$@"
status=$?
ended="$(date +%s)"

# Launch-scoped session identity: the newest session directory created or
# touched during this launch window. Empty means "no correlated session".
sessions_root="${POLY_SESSIONS_DIR:-$HOME/.local/share/polytoken/sessions}"
sess_dir="$(notify_exit_newest_session "$sessions_root" "$started" "$ended")"
session_id=""
[ -n "$sess_dir" ] && session_id="$(basename "$sess_dir")"

repo=""; branch=""
if command -v git >/dev/null 2>&1; then
  branch="$(git -C "$PWD" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  common="$(git -C "$PWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  case "$common" in *.git) common="${common%.git}";; esac
  common="${common%/}"; [ -n "$common" ] && repo="${common##*/}"
fi
title=""
if [ -n "$sess_dir" ] && [ -f "$sess_dir/session.json" ]; then
  title="$(grep -o '"session_title"[[:space:]]*:[[:space:]]*"[^"]*"' "$sess_dir/session.json" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//' || true)"
fi

notify_exit_emit "native-wrapper" "$session_id" "$status" "$started" "$ended" "$repo" "$branch" "$title" || true
exit "$status"
