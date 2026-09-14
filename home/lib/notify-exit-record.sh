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

# _notify_exit_render_ts <epoch>: render exactly this epoch via
# `date -u -r <epoch>` (r3.8 B2). Returns 0 only when the render succeeded and
# produced a well-formed RFC3339 UTC timestamp; otherwise falls back to
# emission time (still RFC3339 when the clock works) and returns 1 so the
# caller marks the record ts_fidelity:"degraded" — the fallback is never
# silent. Portable bash 3.2, jq-free.
_notify_exit_render_ts(){
  local t
  t="$(date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  case "$t" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) printf '%s' "$t"; return 0 ;;
  esac
  t="$(_notify_exit_iso)"
  case "$t" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) printf '%s' "$t" ;;
  esac
  return 1
}

# notify_exit_emit <launcher> <session_id|''> <status> <started_epoch> <ended_epoch> <repo|''> <branch|''> <title|''>
notify_exit_emit(){
  local launcher="$1" session_id="$2" status="$3" started="$4" ended="$5" repo="$6" branch="$7" title="$8"
  local dir line s_ts e_ts s_ok e_ok fidelity=""
  dir="$(notify_exit_dir)"
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || true
  s_ts="$(_notify_exit_render_ts "$started")"; s_ok=$?
  e_ts="$(_notify_exit_render_ts "$ended")"; e_ok=$?
  # r3.8: any per-field render failure degrades the whole record's timestamp
  # fidelity; clean records carry NO ts_fidelity field (additive v1 marker only).
  { [ "$s_ok" -eq 0 ] && [ "$e_ok" -eq 0 ]; } || fidelity="degraded"
  NOTIFY_EXIT_TS_FIDELITY="$fidelity"
  line="{\"v\":1,\"launcher\":$(_notify_exit_jsonstr "$launcher"),\"session_id\":$(_notify_exit_jsonstr "$session_id"),\"exit_status\":$status,\"signal\":$(_notify_exit_jsonstr "$(_notify_exit_signal "$status")"),\"started_at\":\"$s_ts\",\"ended_at\":\"$e_ts\"${fidelity:+,\"ts_fidelity\":\"$fidelity\"},\"identity\":{\"repo\":$(_notify_exit_jsonstr "$repo"),\"branch\":$(_notify_exit_jsonstr "$branch"),\"title\":$(_notify_exit_jsonstr "$title")}}"
  NOTIFY_EXIT_LAST_RECORD="$line"
  printf '%s\n' "$line" >> "$dir/notify-exit.log" 2>/dev/null || return 1
  chmod 600 "$dir/notify-exit.log" 2>/dev/null || true
  local max="${POLY_NOTIFY_EXIT_LOG_MAX_BYTES:-65536}"
  if [ "$(wc -c < "$dir/notify-exit.log" 2>/dev/null || echo 0)" -gt "$max" ]; then
    tail -c "$max" "$dir/notify-exit.log" > "$dir/notify-exit.log.tmp" 2>/dev/null && mv -f "$dir/notify-exit.log.tmp" "$dir/notify-exit.log" 2>/dev/null || true
  fi
  return 0
}

# Launch-scoped session correlation (F1, plan r3.7/r3.8, binds both producers).
# Prefers the session directory CREATED (birthtime) within the launch window
# [start, end + 5]; newest birthtime wins when several qualify. Where the
# birthtime is unavailable or unreliable (Linux `stat -c %W` = 0, non-GNU
# stat failure), the directory is not attributable and is skipped — if none
# qualify the result is empty, which consumers treat as diagnostic-skip. An
# mtime fallback is PROHIBITED: mtime correlates touches, not launches, and
# silently recreates the cross-session mis-attribution (F1 evidence).
notify_exit_newest_session(){
  local root="$1" start="$2" end="$3" d newest="" newest_b=0 b
  [ -d "$root" ] || return 0
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    b=$(stat -c %W "$d" 2>/dev/null) || b=$(stat -f %B "$d" 2>/dev/null) || b=0
    case "$b" in ''|*[!0-9]*) b=0 ;; esac
    [ "$b" -gt 0 ] || continue
    [ "$b" -ge "$start" ] && [ "$b" -le "$((end + 5))" ] && [ "$b" -gt "$newest_b" ] && { newest_b=$b; newest="$d"; }
  done
  [ -n "$newest" ] && printf '%s\n' "${newest%/}"
  return 0
}
