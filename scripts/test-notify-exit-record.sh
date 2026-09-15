#!/usr/bin/env bash
# Tests for the inert notify-exit-record emitter and the native launcher wrapper.
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; T="$(mktemp -d)"; trap 'rm -r "$T"' EXIT
P=0; F=0; ok(){ echo "ok: $1"; P=$((P+1)); }; no(){ echo "FAIL: $1"; F=$((F+1)); }
# shellcheck source=../home/lib/notify-exit-record.sh
. "$R/home/lib/notify-exit-record.sh"
# All shipper/sender diagnostics stay in the temp tree, never the real HOME.
export AGENT_NOTIFY_LOG_DIR="$T/logs"
# Hygiene (AC6): notify_send now also carries the default-on mac Notification
# Center lane. Record osascript calls instead of ever popping a real alert on a
# mac dev host. (Only osascript is stubbed — a uname stub would break the
# host-switching date stubs below.) No assertion changes.
MACSTUB="$T/macstub"; mkdir -p "$MACSTUB"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${2:-}|${3:-}" >> "${OSA_LOG:-/dev/null}"\n' > "$MACSTUB/osascript"; chmod +x "$MACSTUB/osascript"
export PATH="$MACSTUB:$PATH"

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
# Timestamp fidelity (r3.8 B2): when the host date cannot render `-r <epoch>`
# (GNU date semantics), the record must carry the additive field
# ts_fidelity:"degraded" instead of silently substituting emission time;
# healthy hosts carry no marker. The side-effect variable drives the shipper.
STUBD="$T/stubdate"; mkdir -p "$STUBD"; REAL_DATE="$(command -v date)"
printf '#!/usr/bin/env bash\n[ "$1" = "-r" ] && exit 1\nexec %q "$@"\n' "$REAL_DATE" > "$STUBD/date"; chmod +x "$STUBD/date"
PATH="$STUBD:$PATH" POLY_NOTIFY_EXIT_DIR="$T/fidelity" notify_exit_emit "l" "fid" 1 1704067200 1704067300 "" "" "" && ok 'emit under degraded date' || no 'emit under degraded date'
dline="$(tail -1 "$T/fidelity/notify-exit.log")"
printf '%s' "$dline" | jq -e '.ts_fidelity=="degraded"' >/dev/null 2>&1 && ok 'degraded date marks ts_fidelity' || no 'degraded date marks ts_fidelity'
printf '%s' "$dline" | jq -e . >/dev/null 2>&1 && ok 'degraded record valid JSON' || no 'degraded record valid JSON'
printf '%s' "$dline" | jq -e '(.ended_at | fromdateiso8601) >= 0 and (.started_at | fromdateiso8601) >= 0' >/dev/null 2>&1 && ok 'degraded timestamps still RFC3339' || no 'degraded timestamps still RFC3339'
[ "${NOTIFY_EXIT_TS_FIDELITY:-}" = "degraded" ] && ok 'degraded fidelity variable set' || no 'degraded fidelity variable set'
# Clean path: a date that really renders `-r <epoch>` (BSD semantics) must
# produce a record with NO marker. Host-portable via a uname-switched stub:
# GNU date cannot render `-r <epoch>` at all, and on such hosts "degraded"
# is the contract-correct outcome for the real date.
BSDSTUB="$T/bsddate"; mkdir -p "$BSDSTUB"
printf '#!/usr/bin/env bash\nr=0; for a in "$@"; do [ "$a" = "-r" ] && r=1; done; [ "$r" = 1 ] || { exec %q "$@"; }\nwhile [ "$1" != "-r" ]; do shift; done; shift; ep="$1"; shift\ncase "$(uname -s)" in Darwin) exec %q -u -j -f %%s "$ep" "$@" ;; *) exec %q -u -d "@$ep" "$@" ;; esac\n' "$REAL_DATE" "$REAL_DATE" "$REAL_DATE" > "$BSDSTUB/date"; chmod +x "$BSDSTUB/date"
PATH="$BSDSTUB:$PATH" POLY_NOTIFY_EXIT_DIR="$T/fidelity2" notify_exit_emit "l" "clean" 1 1704067200 1704067300 "" "" "" && ok 'emit with rendering date' || no 'emit with rendering date'
[ "${NOTIFY_EXIT_TS_FIDELITY:-}" = "" ] && ok 'clean fidelity variable empty' || no 'clean fidelity variable empty'
printf '%s' "$(tail -1 "$T/fidelity2/notify-exit.log")" | jq -e '(has("ts_fidelity") | not) and (.started_at=="2024-01-01T00:00:00Z") and (.ended_at=="2024-01-01T00:01:40Z")' >/dev/null 2>&1 && ok 'healthy record has no ts_fidelity and true epochs' || no 'healthy record has no ts_fidelity and true epochs'
# Newest-session correlation (F1, plan r3.7/r3.8): a session directory CREATED
# (birthtime) inside [start, end + 5] wins; mtime is never consulted (the
# mis-attribution class). Birthtime unavailable or unreliable (non-GNU stat
# failure, Linux %W = 0) is ambiguity -> empty, never an mtime fallback.
# Supersedes the previous newest-mtime-in-window tests.
S="$T/sessions"; mkdir -p "$S/oldborn"; sleep 1; mkdir -p "$S/youngborn"; touch "$S/oldborn"
young_birth="$(stat -c %W "$S/youngborn" 2>/dev/null || stat -f %B "$S/youngborn" 2>/dev/null || echo 0)"
oldborn_birth="$(stat -c %W "$S/oldborn" 2>/dev/null || stat -f %B "$S/oldborn" 2>/dev/null || echo 0)"
[ "$young_birth" -gt 0 ] 2>/dev/null && [ "$oldborn_birth" -gt 0 ] 2>/dev/null && ok 'fixture has birthtime' || { echo "fixture birthtimes=$young_birth/$oldborn_birth"; no 'fixture has birthtime'; }
eq(){ [ "$1" = "$2" ] && ok "$3" || { echo "got=$1 want=$2"; no "$3"; }; }
eq "$(notify_exit_newest_session "$S" "$young_birth" "$young_birth")" "$S/youngborn" 'birthtime-in-window beats old-born dir touched in window'
eq "$(notify_exit_newest_session "$S" $((young_birth + 1)) $((young_birth + 100)))" "" 'born before window start excluded'
eq "$(notify_exit_newest_session "$S" $((oldborn_birth - 100)) $((oldborn_birth - 6)))" "" 'born after end+5 excluded'
eq "$(notify_exit_newest_session "$S" $((oldborn_birth - 100)) $((oldborn_birth - 5)))" "$S/oldborn" 'end+5 boundary inclusive'
eq "$(notify_exit_newest_session "$S" "$young_birth" $((young_birth + 4)))" "$S/youngborn" 'start boundary inclusive'
eq "$(notify_exit_newest_session "$T/nonexistent" 1 2)" "" 'missing root tolerated'
NOSTAT="$T/nostat"; mkdir -p "$NOSTAT"; printf '#!/usr/bin/env bash\nexit 1\n' > "$NOSTAT/stat"; chmod +x "$NOSTAT/stat"
eq "$(PATH="$NOSTAT:$PATH" notify_exit_newest_session "$S" "$young_birth" "$((young_birth + 5))")" "" 'stat failure is ambiguity, no mtime fallback'
ZEROSTAT="$T/zerostat"; mkdir -p "$ZEROSTAT"; printf '#!/usr/bin/env bash\ncase " $* " in *" -c %%W "*) echo 0 ;; *) exit 1 ;; esac\n' > "$ZEROSTAT/stat"; chmod +x "$ZEROSTAT/stat"
eq "$(PATH="$ZEROSTAT:$PATH" notify_exit_newest_session "$S" "$young_birth" "$((young_birth + 5))")" "" '%W=0 is ambiguity, no mtime fallback'

# Wrapper integration: stub polytoken with controlled exit; wrapper forwards and records.
# Restore the default log cap: the rotation test's small POLY_NOTIFY_EXIT_LOG_MAX_BYTES
# is still exported and would trim these records mid-line once fidelity fields lengthen them.
unset POLY_NOTIFY_EXIT_LOG_MAX_BYTES
W="$T/wrap"; mkdir -p "$W"; export POLY_NOTIFY_EXIT_DIR="$W/exit"; export POLY_SESSIONS_DIR="$T/nosessions"
printf '#!/usr/bin/env bash\nexit 7\n' > "$W/polytoken"; chmod +x "$W/polytoken"
PATH="$W:$PATH" bash "$R/home/bin/polytoken-notify-wrapper.sh" new >/dev/null 2>&1; st=$?
[ "$st" = 7 ] && ok 'wrapper forwards child exit' || no 'wrapper forwards child exit'
printf '%s' "$(tail -1 "$POLY_NOTIFY_EXIT_DIR/notify-exit.log")" | jq -e '.exit_status==7 and .launcher=="native-wrapper"' >/dev/null 2>&1 && ok 'wrapper records child status' || no 'wrapper records child status'
printf '#!/usr/bin/env bash\nkill -9 $$\n' > "$W/polytoken"; chmod +x "$W/polytoken"
PATH="$W:$PATH" bash "$R/home/bin/polytoken-notify-wrapper.sh" new >/dev/null 2>&1; st=$?
[ "$st" = 137 ] && ok 'wrapper forwards SIGKILL as 137' || no 'wrapper forwards SIGKILL as 137'
printf '%s' "$(tail -1 "$POLY_NOTIFY_EXIT_DIR/notify-exit.log")" | jq -e '.exit_status==137 and .signal=="KILL"' >/dev/null 2>&1 && ok 'SIGKILL record' || no 'SIGKILL record'

# Diagnostic kill-timer (env-gated): wrapper self-SIGKILLs its child after N
# seconds, so evidence collection never has to find processes by name.
printf '#!/usr/bin/env bash\nsleep 5\n' > "$W/polytoken"; chmod +x "$W/polytoken"
PATH="$W:$PATH" POLY_NOTIFY_KILL_AFTER=1 bash "$R/home/bin/polytoken-notify-wrapper.sh" new >/dev/null 2>&1; st=$?
[ "$st" = 137 ] && ok 'kill-timer forwards 137' || no 'kill-timer forwards 137'
printf '%s' "$(tail -1 "$POLY_NOTIFY_EXIT_DIR/notify-exit.log")" | jq -e '.exit_status==137 and .signal=="KILL"' >/dev/null 2>&1 && ok 'kill-timer record' || no 'kill-timer record'

# Container launcher: POLY_CONTAINER_NAME must reach the main `podman run` so
# evidence tooling can scope a kill to the exact container this run started.
RSHOME="$T/rshome"; mkdir -p "$RSHOME/workspace" "$RSHOME/.config/polytoken" "$RSHOME/bin"
RBIN="$T/rsbin"; mkdir -p "$RBIN"
printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' "$*" >> "$PODMAN_LOG"\nexit 0\n' > "$RBIN/podman"; chmod +x "$RBIN/podman"
PODMAN_LOG="$T/podman.log"; : > "$PODMAN_LOG"
( cd "$RSHOME/workspace" && PATH="$RBIN:$PATH" HOME="$RSHOME" PODMAN_LOG="$PODMAN_LOG" POLY_ENV_FILE="$T/none.env" POLY_CONTAINER_NAME="pt-test-c3" bash "$R/polytoken-container/run.sh" new ) >/dev/null 2>&1; rst=$?
[ "$rst" = 0 ] && ok 'run.sh completes under stub podman' || no 'run.sh completes under stub podman'
[ -f "$RSHOME/.local/share/polytoken-dev/notify-exit/notify-exit.log" ] && ok 'run.sh writes exit record' || no 'run.sh writes exit record'
tail -1 "$PODMAN_LOG" | grep -q -- '--name pt-test-c3' && ok 'POLY_CONTAINER_NAME reaches podman run' || no 'POLY_CONTAINER_NAME reaches podman run'

# Async launch (kill-timer) must still hand the child the wrapper's stdin:
# POSIX gives backgrounded children /dev/null stdin unless stdin is
# explicitly redirected — that is what broke the PTY evidence run.
printf '#!/usr/bin/env bash\nread -r line || exit 9\n[ "$line" = "ping" ] && exit 42 || exit 1\n' > "$W/polytoken"; chmod +x "$W/polytoken"
printf 'ping\n' | PATH="$W:$PATH" POLY_NOTIFY_KILL_AFTER=3 bash "$R/home/bin/polytoken-notify-wrapper.sh" new >/dev/null 2>&1; st=$?
[ "$st" = 42 ] && ok 'kill-timer child inherits stdin' || no 'kill-timer child inherits stdin'

# Lifecycle shipper (r3.7 closed-world + common-cause collapse; r3.8 fidelity
# gate): after the exit record is emitted, ONLY a 137/KILL record with clean
# timestamp fidelity and a correlated session_id reaches the shared sender —
# exactly one send per floored-15s batch key, with the affected-session count
# from the notify-exit.log in the body and the exact repo/branch (session_id)
# title. Everything else diagnostic-logs a suppression and never sends.
SHIP="$T/shipper"; mkdir -p "$SHIP/bin" "$SHIP/logs"; SHIP_CALLS="$SHIP/calls"; : > "$SHIP_CALLS"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$SHIP_CALLS" > "$SHIP/bin/curl"; chmod +x "$SHIP/bin/curl"
if [ -f "$R/home/lib/notify-shipper.sh" ]; then
  # shellcheck source=../home/lib/notify-shipper.sh
  . "$R/home/lib/notify-shipper.sh"
  shiptest(){ PATH="$SHIP/bin:$PATH" POLY_NOTIFY_EXIT_DIR="$SHIP/exit" PUSHOVER_APP_TOKEN=t PUSHOVER_USER_KEY=u AGENT_NOTIFY_PUSHOVER_URL=http://127.0.0.1:9 NOTIFY_EXIT_TS_FIDELITY="$1" notify_exit_ship "test-launcher" "$2" "$3" "$4" "$5" "claude-config" "feat/notify-cleanup" ""; }
  wait_calls(){ local n="$1" i=0; while [ "$i" -lt 60 ]; do [ "$(wc -l < "$SHIP_CALLS" 2>/dev/null || echo 0)" -ge "$n" ] && return 0; sleep 0.05; i=$((i+1)); done; return 1; }
  ended="$(date +%s)"
  # Seed the shared store: two fidelity-clean 137/KILL records in the same
  # 15s batch and one suppressed 0-exit record (rendering-date stub keeps
  # the fixture fidelity-clean on any host).
  PATH="$BSDSTUB:$PATH" POLY_NOTIFY_EXIT_DIR="$SHIP/exit" notify_exit_emit "test-launcher" "ghost-a" 137 $((ended-3)) "$ended" "" "" ""
  PATH="$BSDSTUB:$PATH" POLY_NOTIFY_EXIT_DIR="$SHIP/exit" notify_exit_emit "test-launcher" "ghost-b" 137 $((ended-1)) "$ended" "" "" ""
  PATH="$BSDSTUB:$PATH" POLY_NOTIFY_EXIT_DIR="$SHIP/exit" notify_exit_emit "test-launcher" "clean0" 0 $((ended-2)) $((ended-1)) "" "" ""
  shiptest "" "live-sess" 137 "$((ended-10))" "$ended"
  if wait_calls 1; then ok 'qualifying record ships'; else no 'qualifying record ships'; fi
  grep -q '|tui_abnormal_exit|' "$T/logs/notify.log" && ok 'attempt diagnostic-logged with event' || no 'attempt diagnostic-logged with event'
  grep -Eq '\|sent($|=)' "$T/logs/notify.log" && ok 'send result diagnostic-logged' || no 'send result diagnostic-logged'
  grep -Fq 'title=claude-config/feat/notify-cleanup (live-sess)' "$SHIP_CALLS" && ok 'exact title contract repo/branch (session_id)' || no 'exact title contract repo/branch (session_id)'
  grep -Fq '2 session(s) affected' "$SHIP_CALLS" && ok 'body counts batch records' || no 'body counts batch records'
  grep -Fq 'TUI terminated abnormally' "$SHIP_CALLS" && ok 'body names the reason' || no 'body names the reason'
  # Common-cause collapse: a second death in the same 15s batch loses the
  # claim, diagnostic-logs, and never sends twice.
  shiptest "" "live-sess2" 137 "$((ended-5))" "$ended"
  if ! wait_calls 2; then ok 'common-cause collapse: one send per batch'; else no 'common-cause collapse: one send per batch'; fi
  grep -q 'suppressed:claim-loser' "$T/logs/notify.log" && ok 'claim loser diagnostic-logged' || no 'claim loser diagnostic-logged'
  # A distinct later window ships again.
  shiptest "" "live-sess3" 137 "$((ended-10))" "$((ended+20))"
  if wait_calls 2; then ok 'distinct batch window ships'; else no 'distinct batch window ships'; fi
  # Closed world: nothing else may reach the sender; each suppresses with a
  # bounded diagnostic entry.
  before="$(wc -l < "$SHIP_CALLS")"
  shiptest "" "s" 0 1 2; shiptest "" "s" 1 1 2; shiptest "" "s" 129 1 2; shiptest "" "s" 130 1 2; shiptest "" "s" 143 1 2
  shiptest "degraded" "s" 137 1 2
  shiptest "" "" 137 1 2
  [ "$(wc -l < "$SHIP_CALLS")" = "$before" ] && ok 'closed world: no send for 0/1/129/130/143/degraded/no-session' || no 'closed world: no send for 0/1/129/130/143/degraded/no-session'
  grep -q 'suppressed:status=0' "$T/logs/notify.log" && ok 'clean exit suppression logged' || no 'clean exit suppression logged'
  grep -q 'suppressed:status=143' "$T/logs/notify.log" && ok 'HUP/TERM/INT suppression logged' || no 'HUP/TERM/INT suppression logged'
  grep -q 'suppressed:ts_fidelity=degraded' "$T/logs/notify.log" && ok 'degraded fidelity suppression logged' || no 'degraded fidelity suppression logged'
  grep -q 'suppressed:no-session' "$T/logs/notify.log" && ok 'uncorrelated suppression logged' || no 'uncorrelated suppression logged'
  # Claim namespace hygiene.
  [ "$(stat -c %a "$SHIP/exit/claims" 2>/dev/null || stat -f %Lp "$SHIP/exit/claims")" = 700 ] && ok 'claims dir 700 under exit dir' || no 'claims dir 700 under exit dir'
  claim_ok=1; for cf in "$SHIP/exit/claims"/claim.*; do [ "$(stat -c %a "$cf" 2>/dev/null || stat -f %Lp "$cf")" = 600 ] || claim_ok=0; done
  [ "$claim_ok" = 1 ] && ok 'claim files 600' || no 'claim files 600'
  # Fail-open end-to-end through the native wrapper: SIGKILL of a correlated
  # session ships once; missing credentials stay silent; exit status unchanged.
  # The polytoken stub creates the session dir mid-launch so its birthtime is
  # deterministically inside the launch window.
  E2E="$T/e2e"; mkdir -p "$E2E/bin"; E2E_CALLS="$E2E/calls"; : > "$E2E_CALLS"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$E2E_CALLS" > "$E2E/bin/curl"; chmod +x "$E2E/bin/curl"
  printf '#!/usr/bin/env bash\nmkdir -p "$POLY_SESSIONS_DIR/e2e-sess"\nkill -9 $$\n' > "$W/polytoken"; chmod +x "$W/polytoken"
  PATH="$BSDSTUB:$E2E/bin:$W:$PATH" POLY_NOTIFY_EXIT_DIR="$E2E/exit" POLY_SESSIONS_DIR="$E2E/sessions" PUSHOVER_APP_TOKEN=t PUSHOVER_USER_KEY=u AGENT_NOTIFY_PUSHOVER_URL=http://127.0.0.1:9 bash "$R/home/bin/polytoken-notify-wrapper.sh" new >/dev/null 2>&1; est=$?
  [ "$est" = 137 ] && ok 'e2e wrapper exit status unchanged' || no 'e2e wrapper exit status unchanged'
  i=0; while [ "$i" -lt 60 ] && [ ! -s "$E2E_CALLS" ]; do sleep 0.05; i=$((i+1)); done
  grep -Fq '(e2e-sess)' "$E2E_CALLS" && ok 'e2e ships correlated session title' || no 'e2e ships correlated session title'
  grep -Fq '1 session(s) affected' "$E2E_CALLS" && ok 'e2e counts its own record' || no 'e2e counts its own record'
  # Without credentials the sender is a silent no-op: still no network, no crash.
  mkdir -p "$E2E/exit2"; : > "$E2E_CALLS"
  PATH="$BSDSTUB:$E2E/bin:$W:$PATH" POLY_NOTIFY_EXIT_DIR="$E2E/exit2" POLY_SESSIONS_DIR="$E2E/sessions" PUSHOVER_APP_TOKEN= PUSHOVER_USER_KEY= bash "$R/home/bin/polytoken-notify-wrapper.sh" new >/dev/null 2>&1; est2=$?
  [ "$est2" = 137 ] && [ ! -s "$E2E_CALLS" ] && ok 'e2e without credentials stays silent and fail-open' || no 'e2e without credentials stays silent and fail-open'
else
  no "shipper library exists"
fi
# Container lane: run.sh trap ships 137/KILL records from the host data root.
# The podman stub creates the session dir mid-launch (deterministic birthtime
# inside the launch window) and exits 137 like a killed container would.
RSHOME2="$T/rshome2"; mkdir -p "$RSHOME2/workspace" "$RSHOME2/.config/polytoken" "$RSHOME2/bin" "$RSHOME2/.local/share/polytoken-dev"
RBIN2="$T/rsbin2"; mkdir -p "$RBIN2"
printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' "$*" >> "$PODMAN_LOG2"\nmkdir -p "$HOME/.local/share/polytoken-dev/sessions/runsh-sess"\nexit 137\n' > "$RBIN2/podman"; chmod +x "$RBIN2/podman"
RUNSH_CALLS="$T/runsh-calls"; : > "$RUNSH_CALLS"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$RUNSH_CALLS" > "$RBIN2/curl"; chmod +x "$RBIN2/curl"
( cd "$RSHOME2/workspace" && PATH="$RBIN2:$BSDSTUB:$PATH" HOME="$RSHOME2" PODMAN_LOG2="$T/podman2.log" POLY_ENV_FILE="$T/none2.env" POLY_CONTAINER_NAME="pt-test-c4" PUSHOVER_APP_TOKEN=t PUSHOVER_USER_KEY=u AGENT_NOTIFY_PUSHOVER_URL=http://127.0.0.1:9 bash "$R/polytoken-container/run.sh" new ) >/dev/null 2>&1; rst2=$?
[ "$rst2" = 137 ] && ok 'run.sh preserves 137 exit under set -e' || no 'run.sh preserves 137 exit under set -e'
i=0; while [ "$i" -lt 60 ] && [ ! -s "$RUNSH_CALLS" ]; do sleep 0.05; i=$((i+1)); done
grep -Fq '(runsh-sess)' "$RUNSH_CALLS" && ok 'run.sh trap ships correlated record' || no 'run.sh trap ships correlated record'
grep -q 'suppressed:status=0' "$T/logs/notify.log" && ok 'run.sh status-0 trap suppressed with diagnostic' || no 'run.sh status-0 trap suppressed with diagnostic'

[ "$P" -gt 0 ] && [ "$F" -eq 0 ] && echo "PASS: $P" || echo "FAILURES: $F/$((P+F))"; exit "$F"
