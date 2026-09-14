#!/usr/bin/env bash
# notify-exit-record emitter (candidate lifecycle owner, inert diagnostics).
# Writes notify-exit-record/v1 JSON lines describing how a launched TUI ended.
# No network, no notifications: files only, restrictive permissions, size-bounded.
# Portable bash (3.2+) and jq-free so it runs on the macOS host.
set -u

notify_exit_dir(){ printf '%s\n' "${POLY_NOTIFY_EXIT_DIR:-$HOME/.local/share/polytoken/notify-exit}"; }

_notify_exit_clean(){ LC_ALL=C printf '%s' "$1" | tr '[:cntrl:]' ' ' | cut -c1-256; }
_notify_exit_jsonstr(){ local s; s="$(_notify_exit_clean "$1")"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
_notify_exit_signal(){ local st="$1"; if [ "$st" -ge 128 ] 2>/dev/null; then kill -l "$st" 2>/dev/null | tr -d ' ' || printf ''; else printf ''; fi; }
_notify_exit_iso(){ date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf ''; }

# notify_exit_emit <launcher> <session_id|''> <status> <started_epoch> <ended_epoch> <repo|''> <branch|''> <title|''>
notify_exit_emit(){
  local launcher="$1" session_id="$2" status="$3" started="$4" ended="$5" repo="$6" branch="$7" title="$8"
  local dir line
  dir="$(notify_exit_dir)"
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || true
  line="{\"v\":1,\"launcher\":$(_notify_exit_jsonstr "$launcher"),\"session_id\":$(_notify_exit_jsonstr "$session_id"),\"exit_status\":$status,\"signal\":$(_notify_exit_jsonstr "$(_notify_exit_signal "$status")"),\"started_at\":\"$(date -u -r "$started" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || _notify_exit_iso)\",\"ended_at\":\"$(date -u -r "$ended" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || _notify_exit_iso)\",\"identity\":{\"repo\":$(_notify_exit_jsonstr "$repo"),\"branch\":$(_notify_exit_jsonstr "$branch"),\"title\":$(_notify_exit_jsonstr "$title")}}"
  printf '%s\n' "$line" >> "$dir/notify-exit.log" 2>/dev/null || return 1
  chmod 600 "$dir/notify-exit.log" 2>/dev/null || true
  local max="${POLY_NOTIFY_EXIT_LOG_MAX_BYTES:-65536}"
  if [ "$(wc -c < "$dir/notify-exit.log" 2>/dev/null || echo 0)" -gt "$max" ]; then
    tail -c "$max" "$dir/notify-exit.log" > "$dir/notify-exit.log.tmp" 2>/dev/null && mv -f "$dir/notify-exit.log.tmp" "$dir/notify-exit.log" 2>/dev/null || true
  fi
  return 0
}

# Newest session directory whose mtime falls inside [start_epoch, end_epoch].
# Best effort: empty output means "no correlated session this window".
notify_exit_newest_session(){
  local root="$1" start="$2" end="$3" d newest="" newest_m=0 m
  [ -d "$root" ] || return 0
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    m=$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo 0)
    [ "$m" -ge "$start" ] && [ "$m" -le "$((end + 5))" ] && [ "$m" -gt "$newest_m" ] && { newest_m=$m; newest="$d"; }
  done
  [ -n "$newest" ] && printf '%s\n' "${newest%/}"
  return 0
}
