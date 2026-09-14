#!/usr/bin/env bash
# Tests for the inert notify-exit-record emitter and the native launcher wrapper.
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; T="$(mktemp -d)"; trap 'rm -r "$T"' EXIT
P=0; F=0; ok(){ echo "ok: $1"; P=$((P+1)); }; no(){ echo "FAIL: $1"; F=$((F+1)); }
# shellcheck source=../home/lib/notify-exit-record.sh
. "$R/home/lib/notify-exit-record.sh"

# Emitter: valid v1 line with signal derivation and identity fields.
export POLY_NOTIFY_EXIT_DIR="$T/exit"
notify_exit_emit "native-wrapper" "sess-1" 137 1704067200 1704067300 "repo" "feat/x" "My Title" && ok 'emit ok status' || no 'emit ok status'
line="$(tail -1 "$POLY_NOTIFY_EXIT_DIR/notify-exit.log")"
printf '%s' "$line" | jq -e '.v==1 and .launcher=="native-wrapper" and .session_id=="sess-1" and .exit_status==137 and .signal=="KILL" and .identity.repo=="repo" and .identity.branch=="feat/x" and .identity.title=="My Title"' >/dev/null 2>&1 && ok 'record fields + KILL signal' || no 'record fields + KILL signal'
# Missing session id / empty identity are recorded as empty strings (skip downstream).
notify_exit_emit "container-run.sh" "" 0 1704067200 1704067205 "" "" "" && ok 'emit empty identity' || no 'emit empty identity'
printf '%s' "$(tail -1 "$POLY_NOTIFY_EXIT_DIR/notify-exit.log")" | jq -e '.exit_status==0 and .signal=="" and .session_id==""' >/dev/null 2>&1 && ok 'clean exit, empty signal/session' || no 'clean exit, empty signal/session'
# Control chars sanitized; quotes escaped.
notify_exit_emit "l" $'bad\033[31m"q"\\"id"' 143 1704067200 1704067201 "" "" "" && ok 'emit hostile fields' || no 'emit hostile fields'
printf '%s' "$(tail -1 "$POLY_NOTIFY_EXIT_DIR/notify-exit.log")" | jq -e '.session_id | contains("\u001b") | not' >/dev/null 2>&1 && ok 'control chars removed' || no 'control chars removed'
printf '%s' "$(tail -1 "$POLY_NOTIFY_EXIT_DIR/notify-exit.log")" | jq -e . >/dev/null 2>&1 && ok 'hostile fields still valid JSON' || no 'hostile fields still valid JSON'
# Perms and rotation.
[ "$(stat -c %a "$POLY_NOTIFY_EXIT_DIR" 2>/dev/null || stat -f %Lp "$POLY_NOTIFY_EXIT_DIR")" = 700 ] && ok 'dir 700' || no 'dir 700'
[ "$(stat -c %a "$POLY_NOTIFY_EXIT_DIR/notify-exit.log" 2>/dev/null || stat -f %Lp "$POLY_NOTIFY_EXIT_DIR/notify-exit.log")" = 600 ] && ok 'log 600' || no 'log 600'
POLY_NOTIFY_EXIT_LOG_MAX_BYTES=256 notify_exit_emit "l" "rot" 1 1704067200 1704067201 "" "" ""
export POLY_NOTIFY_EXIT_LOG_MAX_BYTES=256
for i in 1 2 3 4 5; do notify_exit_emit "l" "rot-fill-$i-with-padding-padding-padding" 1 1704067200 1704067201 "" "" ""; done
[ "$(wc -c < "$POLY_NOTIFY_EXIT_DIR/notify-exit.log")" -le 256 ] && ok 'rotation caps size' || no 'rotation caps size'
# Newest-session window resolution.
S="$T/sessions"; mkdir -p "$S/older" "$S/newer"; touch -t 202401010000 "$S/older"; now_e=$(date +%s); touch -d "@$now_e" "$S/newer" 2>/dev/null || touch "$S/newer"
eq(){ [ "$1" = "$2" ] && ok "$3" || { echo "got=$1 want=$2"; no "$3"; }; }
eq "$(notify_exit_newest_session "$S" $((now_e-10)) $((now_e)))" "$S/newer" 'newest session in window'
eq "$(notify_exit_newest_session "$S" 1 2)" "" 'no session outside window'
eq "$(notify_exit_newest_session "$T/nonexistent" 1 2)" "" 'missing root tolerated'

# Wrapper integration: stub polytoken with controlled exit; wrapper forwards and records.
W="$T/wrap"; mkdir -p "$W"; export POLY_NOTIFY_EXIT_DIR="$W/exit"; export POLY_SESSIONS_DIR="$T/nosessions"
printf '#!/usr/bin/env bash\nexit 7\n' > "$W/polytoken"; chmod +x "$W/polytoken"
PATH="$W:$PATH" bash "$R/home/bin/polytoken-notify-wrapper.sh" new >/dev/null 2>&1; st=$?
[ "$st" = 7 ] && ok 'wrapper forwards child exit' || no 'wrapper forwards child exit'
printf '%s' "$(tail -1 "$POLY_NOTIFY_EXIT_DIR/notify-exit.log")" | jq -e '.exit_status==7 and .launcher=="native-wrapper"' >/dev/null 2>&1 && ok 'wrapper records child status' || no 'wrapper records child status'
printf '#!/usr/bin/env bash\nkill -9 $$\n' > "$W/polytoken"; chmod +x "$W/polytoken"
PATH="$W:$PATH" bash "$R/home/bin/polytoken-notify-wrapper.sh" new >/dev/null 2>&1; st=$?
[ "$st" = 137 ] && ok 'wrapper forwards SIGKILL as 137' || no 'wrapper forwards SIGKILL as 137'
printf '%s' "$(tail -1 "$POLY_NOTIFY_EXIT_DIR/notify-exit.log")" | jq -e '.exit_status==137 and .signal=="KILL"' >/dev/null 2>&1 && ok 'SIGKILL record' || no 'SIGKILL record'

[ "$P" -gt 0 ] && [ "$F" -eq 0 ] && echo "PASS: $P" || echo "FAILURES: $F/$((P+F))"; exit "$F"
