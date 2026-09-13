#!/usr/bin/env bash
# Tests for home/hooks/watchdog-keepalive.sh: the session_start hook that
# keeps exactly one container-side watchdog scan loop alive. Uses a stub
# watchdog so the tests never touch real session state.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEPALIVE="$REPO/home/hooks/watchdog-keepalive.sh"
TMP="$(mktemp -d)"
CFG="$TMP/config"
mkdir -p "$CFG/hooks" "$TMP/state"
pass=0; fail=0
ok(){ echo "ok: $1"; pass=$((pass+1)); }; no(){ echo "FAIL: $1"; fail=$((fail+1)); }
export SCANS="$TMP/scans"
cat > "$CFG/hooks/session-watchdog.sh" <<'EOF'
#!/usr/bin/env bash
echo scan >> "${SCANS:?}"
EOF
chmod +x "$CFG/hooks/session-watchdog.sh"
: > "$SCANS"
scan_count(){ [ -f "$SCANS" ] && wc -l < "$SCANS" | tr -d ' ' || echo 0; }
scans_at_least(){ [ "$(scan_count)" -ge "$1" ]; }
wait_until(){ local deadline=$((SECONDS+5)); while [ "$SECONDS" -lt "$deadline" ]; do "$@" && return 0; sleep 0.02; done; return 1; }
pid_dead(){ ! kill -0 "$1" 2>/dev/null; }
pid_changed(){ local p; p="$(cat "$PIDFILE" 2>/dev/null || echo none)"; [ "$p" != "$1" ] && [ "$p" != none ]; }
run_ka(){ env -u PUSHOVER_APP_TOKEN -u PUSHOVER_USER_KEY -u PUSHOVER_TOKEN -u PUSHOVER_USER \
  POLYTOKEN_CONFIG_DIR="$CFG" WATCHDOG_STATE_DIR="$TMP/state" WATCHDOG_LOOP_LOG="$TMP/loop.log" WATCHDOG_LOOP_INTERVAL=0.05 bash "$KEEPALIVE"; }
PIDFILE="$TMP/state/loop.pid"
cleanup(){ [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; return 0; }
trap cleanup EXIT

# 1. First invocation spawns a loop that scans repeatedly.
run_ka
wait_until scans_at_least 3 && ok "keepalive spawns a scanning loop" || no "keepalive spawns a scanning loop"

# 2. Invocation while the loop lives is a no-op: same pid, loop still scanning.
p1="$(cat "$PIDFILE" 2>/dev/null || echo none)"
sleep 0.2; run_ka; sleep 0.2
p2="$(cat "$PIDFILE" 2>/dev/null || echo none)"
[ "$p1" = "$p2" ] && [ "$p1" != none ] && wait_until scans_at_least 10 \
  && ok "invocation while loop lives is a no-op" || no "invocation while loop lives is a no-op"

# 3. A dead loop is replaced by the next invocation.
kill "$p1" 2>/dev/null; wait_until pid_dead "$p1"; sleep 0.1
run_ka
wait_until pid_changed "$p1"
p3="$(cat "$PIDFILE" 2>/dev/null || echo none)"
[ -n "$p3" ] && [ "$p3" != "$p1" ] && kill -0 "$p3" 2>/dev/null && wait_until scans_at_least 20 \
  && ok "dead loop is replaced on next invocation" || no "dead loop is replaced on next invocation"
cleanup

# 4. Missing watchdog script fails open: no output, no state created. HOME is
# neutralized so the ~/.claude fallback also finds nothing.
out="$(env -u PUSHOVER_APP_TOKEN -u PUSHOVER_USER_KEY -u PUSHOVER_TOKEN -u PUSHOVER_USER \
  HOME="$TMP" POLYTOKEN_CONFIG_DIR="$TMP/empty" WATCHDOG_STATE_DIR="$TMP/nostate" bash "$KEEPALIVE")"
[ -z "$out" ] && [ ! -d "$TMP/nostate" ] && ok "missing watchdog script fails open" || no "missing watchdog script fails open"

[ "$fail" -eq 0 ] && echo "PASS: $pass" || echo "FAILURES: $fail/$((pass+fail))"; exit "$fail"
