#!/usr/bin/env bash
# Raw SSE capture recorder (Task 3 verification instrument, plan-002).
# Reuses the watcher's own discovery/auth mechanics — sources
# home/lib/notify-event-watcher.sh (safe to source: its run-loop is guarded by
# a BASH_SOURCE check) for notify_watcher_discover / notify_watcher_curl_args —
# and appends raw SSE `data:` frames VERBATIM (prefix intact, no processing,
# no notification sends, no state-root writes) to a timestamped JSONL file for
# one session. Stop conditions: the daemon closes the stream, --max-seconds
# elapses, or SIGINT/SIGTERM — in every case the child curl is killed and
# waited on (no orphaned curl; no `timeout` dependency, macOS has none).
#
# Usage:
#   scripts/capture-sse-experiment.sh [--sessions-dir DIR] [--out DIR]
#                                     [--max-seconds N] (<session-dir> | --list)
#
# Output: <out-dir>/sse-capture-<UTC timestamp>-<safe-session-id>.jsonl
# (safe-session-id: tr -c 'A-Za-z0-9._-' '_' | cut -c1-128, same sanitization
# as the watcher's _nw_safe). Default out-dir is the current directory. The
# output file path is printed on stdout when the capture ends. Nothing else is
# written — never the notify state root, never log files.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=home/lib/notify-event-watcher.sh
source "$REPO/home/lib/notify-event-watcher.sh" || exit 1

sessions_dir=""
out_dir="."
max_seconds=300
session_dir=""
mode=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sessions-dir) [ $# -ge 2 ] || { echo "capture: --sessions-dir requires a value" >&2; exit 2; }
                    sessions_dir="$2"; shift 2 ;;
    --out)          [ $# -ge 2 ] || { echo "capture: --out requires a value" >&2; exit 2; }
                    out_dir="$2"; shift 2 ;;
    --max-seconds)  [ $# -ge 2 ] || { echo "capture: --max-seconds requires a value" >&2; exit 2; }
                    max_seconds="$2"; shift 2 ;;
    --list)         mode="list"; shift ;;
    *)              session_dir="$1"; shift ;;
  esac
done

if [ "$mode" = "list" ]; then
  [ -n "$sessions_dir" ] && NOTIFY_WATCHER_SESSIONS_DIR="$sessions_dir"
  export NOTIFY_WATCHER_SESSIONS_DIR
  notify_watcher_discover 2>/dev/null
  exit 0
fi

[ -n "$session_dir" ] || { echo "capture: no session directory given (use --list to find ready sessions)" >&2; exit 2; }
[ -d "$session_dir" ] || { echo "capture: not a session directory: $session_dir" >&2; exit 2; }
case "$max_seconds" in ''|*[!0-9]*) echo "capture: --max-seconds must be a non-negative integer" >&2; exit 2 ;; esac
[ -d "$out_dir" ] || { echo "capture: out directory does not exist: $out_dir" >&2; exit 2; }
[ -n "$sessions_dir" ] && NOTIFY_WATCHER_SESSIONS_DIR="$sessions_dir"
export NOTIFY_WATCHER_SESSIONS_DIR

# curl argv from the watcher's own auth mechanics.
curl_args=()
while IFS= read -r a; do curl_args+=("$a"); done < <(notify_watcher_curl_args "$session_dir" 2>/dev/null)
[ "${#curl_args[@]}" -gt 0 ] || { echo "capture: no usable curl args for session: $session_dir" >&2; exit 2; }

# Session id + safe name (same sanitization as the watcher's _nw_safe).
sid="$(jq -r '.session_id // empty' "$session_dir/startup.json" 2>/dev/null)"
[ -n "$sid" ] || sid="${session_dir##*/}"
safe="$(LC_ALL=C printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-128)"

stamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
# Collision-safe target: never truncate a prior capture — step a numeric
# suffix (…jsonl.1, .2, …) when the timestamped name is already taken.
base="$out_dir/sse-capture-$stamp-$safe"
outfile="$base.jsonl"
sfx=0
while [ -e "$outfile" ]; do
  sfx=$((sfx + 1))
  outfile="$base.jsonl.$sfx"
done
: > "$outfile"

# Background curl feeding a fifo; a reader loop copies only `data:` lines
# (verbatim, prefix intact) into the output file. Holding the fifo's write
# end open on fd 9 keeps the reader alive until we tear down.
work="$(mktemp -d "${TMPDIR:-/tmp}/sse-capture.XXXXXX")"
fifo="$work/stream.fifo"
mkfifo "$fifo" || { rm -rf "$work"; echo "capture: cannot create fifo" >&2; exit 1; }

cleanup(){
  [ -n "${curl_pid:-}" ] && kill "$curl_pid" 2>/dev/null
  # Close our fifo write end first so the reader can hit EOF. Scoped so the
  # redirection only silences this exec, not the shell's stderr permanently.
  { exec 9>&-; } 2>/dev/null
  # Drain grace: give the reader a bounded window (~2s) to flush any frames
  # still buffered in the fifo before killing it — no orphan is left either
  # way, but tail frames are not dropped on the normal or signal path.
  if [ -n "${reader_pid:-}" ]; then
    graced=0
    while kill -0 "$reader_pid" 2>/dev/null && [ "$graced" -lt 20 ]; do
      sleep 0.1
      graced=$((graced + 1))
    done
    kill "$reader_pid" 2>/dev/null
  fi
  [ -n "${curl_pid:-}" ] && wait "$curl_pid" 2>/dev/null
  [ -n "${reader_pid:-}" ] && wait "$reader_pid" 2>/dev/null
  rm -rf "$work" 2>/dev/null
}
trap 'cleanup; printf "%s\n" "$outfile"; exit 0' INT TERM HUP

( while IFS= read -r line; do
    case "$line" in
      data:*) printf '%s\n' "$line" >> "$outfile" ;;
    esac
  done ) < "$fifo" &
reader_pid=$!
exec 9>"$fifo"

curl "${curl_args[@]}" > "$fifo" 2>/dev/null &
curl_pid=$!

# Bounded wait loop: stream close, --max-seconds, or signal ends the capture.
elapsed=0
while kill -0 "$curl_pid" 2>/dev/null && [ "$elapsed" -lt "$max_seconds" ]; do
  sleep 1
  elapsed=$((elapsed + 1))
done

trap - INT TERM
# Capture curl's exit status (F6): if the daemon closed the stream or curl
# failed, curl has already exited and we can reap its status; if it is still
# running the stop is ours (--max-seconds) and cleanup kills it — no warning.
curl_rc=0
stopped_by_bound=0
if kill -0 "$curl_pid" 2>/dev/null; then
  stopped_by_bound=1
else
  wait "$curl_pid" 2>/dev/null
  curl_rc=$?
fi
cleanup
if [ "$stopped_by_bound" -eq 0 ] && [ "$curl_rc" -ne 0 ]; then
  printf 'capture: curl exited %d; stream may have failed\n' "$curl_rc" >&2
fi
printf '%s\n' "$outfile"
exit 0
