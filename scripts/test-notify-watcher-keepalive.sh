#!/usr/bin/env bash
# Tests for home/hooks/notify-watcher-keepalive.sh: the session_start hook that
# keeps exactly one SSE event-watcher supervision loop alive. Uses a stub
# watcher so the tests never touch real session state or the network.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEPALIVE="$REPO/home/hooks/notify-watcher-keepalive.sh"
TMP="$(mktemp -d)"
CFG="$TMP/config"
mkdir -p "$CFG/lib" "$TMP/state"
pass=0; fail=0
ok(){ echo "ok: $1"; pass=$((pass+1)); }; no(){ echo "FAIL: $1"; fail=$((fail+1)); }
export WATCHES="$TMP/watches"
cat > "$CFG/lib/notify-event-watcher.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "watch ${NOTIFY_WATCHER_FRESH_SECONDS:-unset}" >> "${WATCHES:?}"
EOF
chmod +x "$CFG/lib/notify-event-watcher.sh"
: > "$WATCHES"
watch_count(){ [ -f "$WATCHES" ] && wc -l < "$WATCHES" | tr -d ' ' || echo 0; }
watches_at_least(){ [ "$(watch_count)" -ge "$1" ]; }
wait_until(){ local deadline=$((SECONDS+5)); while [ "$SECONDS" -lt "$deadline" ]; do "$@" && return 0; sleep 0.02; done; return 1; }
pid_dead(){ ! kill -0 "$1" 2>/dev/null; }
pid_changed(){ local p; p="$(cat "$PIDFILE" 2>/dev/null || echo none)"; [ "$p" != "$1" ]; }
loop_procs(){ ps -eo args 2>/dev/null | grep -c '[n]otify-watcher-loop' || true; }
run_ka(){ env -u PUSHOVER_APP_TOKEN -u PUSHOVER_USER_KEY -u PUSHOVER_TOKEN -u PUSHOVER_USER \
  POLYTOKEN_CONFIG_DIR="$CFG" AGENT_NOTIFY_STATE_DIR="$TMP/state" NOTIFY_WATCHER_LOOP_INTERVAL=0.05 bash "$KEEPALIVE"; }
PIDFILE="$TMP/state/notify-watcher-keepalive.pid"
cleanup(){ [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; return 0; }
trap cleanup EXIT

# 1. First invocation spawns a loop that runs the watcher repeatedly.
run_ka
wait_until watches_at_least 3 && ok "keepalive spawns a watcher loop" && [ -s "$PIDFILE" ] \
  && ok "loop records its pid" || no "keepalive spawns a watcher loop (pid recording)"

# 2. Invocation while the loop lives is a no-op: same pid, watcher still running.
p1="$(cat "$PIDFILE" 2>/dev/null || echo none)"
sleep 0.2; run_ka; sleep 0.2
p2="$(cat "$PIDFILE" 2>/dev/null || echo none)"
[ "$p1" = "$p2" ] && [ "$p1" != none ] && wait_until watches_at_least 10 \
  && ok "invocation while loop lives is a no-op" || no "invocation while loop lives is a no-op"

# 3. NOTIFY_WATCHER_* env is inherited by the supervised watcher: a re-spawn
# under a knob passes the knob through to the stub (it records what it saw).
kill "$p1" 2>/dev/null; wait_until pid_dead "$p1"; : > "$WATCHES"; sleep 0.1
NOTIFY_WATCHER_FRESH_SECONDS=777 run_ka
wait_until grep -q 'watch 777' "$WATCHES" && ok "NOTIFY_WATCHER_* env reaches the watcher" \
  || no "NOTIFY_WATCHER_* env reaches the watcher"
p_env="$(cat "$PIDFILE" 2>/dev/null || echo none)"

# 4. A dead loop is replaced by the next invocation.
kill "$p_env" 2>/dev/null; wait_until pid_dead "$p_env"; sleep 0.1
run_ka
wait_until pid_changed "$p_env"
p3="$(cat "$PIDFILE" 2>/dev/null || echo none)"
[ -n "$p3" ] && [ "$p3" != "$p_env" ] && kill -0 "$p3" 2>/dev/null && wait_until watches_at_least 5 \
  && ok "dead loop is replaced on next invocation" || no "dead loop is replaced on next invocation"

# 5. A recycled pid (live process that is not the loop) is replaced on Linux,
# where the /proc cmdline check can tell them apart. Non-Linux trusts the pid.
if [ -d "/proc/$$" ]; then
  kill "$p3" 2>/dev/null; wait_until pid_dead "$p3"; sleep 0.1
  recycled="$(sleep 30 & echo $!)"
  printf '%s\n' "$recycled" > "$PIDFILE"
  run_ka
  wait_until pid_changed "$recycled"
  p4="$(cat "$PIDFILE" 2>/dev/null || echo none)"
  [ -n "$p4" ] && [ "$p4" != "$recycled" ] && kill -0 "$p4" 2>/dev/null \
    && ok "recycled live pid is replaced (Linux /proc check)" || no "recycled live pid is replaced (Linux /proc check)"
  kill "$recycled" 2>/dev/null
else
  echo "SKIP: recycled-pid check requires /proc" >&2
fi

# 6. A garbage pidfile (non-numeric) does not wedge the keepalive: it re-spawns.
kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true; sleep 0.1
printf 'junk\n' > "$PIDFILE"
run_ka
wait_until pid_changed junk
p5="$(cat "$PIDFILE" 2>/dev/null || echo none)"
case "$p5" in ''|*[!0-9]*) no "garbage pidfile is replaced" ;; *) kill -0 "$p5" 2>/dev/null && ok "garbage pidfile is replaced" || no "garbage pidfile is replaced" ;; esac

# 7. Concurrent invocations still leave exactly one loop (flock serialization).
kill "$p5" 2>/dev/null; wait_until pid_dead "$p5"; : > "$WATCHES"; sleep 0.1
run_ka & run_ka & wait
run_ka
sleep 0.2
[ "$(loop_procs)" = "1" ] && [ -s "$PIDFILE" ] && wait_until watches_at_least 3 \
  && ok "concurrent invocations keep exactly one loop" || no "concurrent invocations keep exactly one loop"
cleanup

# 8. Missing watcher script fails open: no output, no state created. HOME is
# neutralized so no fallback location finds anything either.
out="$(env -u PUSHOVER_APP_TOKEN -u PUSHOVER_USER_KEY -u PUSHOVER_TOKEN -u PUSHOVER_USER \
  HOME="$TMP" POLYTOKEN_CONFIG_DIR="$TMP/empty" AGENT_NOTIFY_STATE_DIR="$TMP/nostate" bash "$KEEPALIVE")"
[ -z "$out" ] && [ ! -d "$TMP/nostate" ] && ok "missing watcher script fails open" || no "missing watcher script fails open"

# 9. No flock on PATH fails soft before any state is created. The empty PATH
# dir leaves command -v flock unresolved while builtins keep the hook running.
mkdir -p "$TMP/noflock"
out="$(env -u PUSHOVER_APP_TOKEN -u PUSHOVER_USER_KEY -u PUSHOVER_TOKEN -u PUSHOVER_USER \
  PATH="$TMP/noflock" POLYTOKEN_CONFIG_DIR="$CFG" AGENT_NOTIFY_STATE_DIR="$TMP/noflock-state" /bin/bash "$KEEPALIVE")"
[ -z "$out" ] && [ ! -d "$TMP/noflock-state" ] && ok "missing flock fails soft" || no "missing flock fails soft"

# 10. Wiring: the canonical hooks.json carries exactly one session_start entry
# for this hook, and hook names stay unique across the file.
jq -e '([.[] | select(.name == "notify-watcher-keepalive")] | length == 1)
       and ([.[] | select(.name == "notify-watcher-keepalive")][0] | .event == "session_start"
            and (.handler.bash | contains("hooks/notify-watcher-keepalive.sh")))
       and (([.[].name] | length) == ([.[].name] | unique | length))' "$REPO/polytoken/hooks.json" >/dev/null \
  && ok "hooks.json carries the unique session_start entry" || no "hooks.json carries the unique session_start entry"

[ "$fail" -eq 0 ] && echo "PASS: $pass" || echo "FAILURES: $fail/$((pass+fail))"; exit "$fail"
