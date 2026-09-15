#!/usr/bin/env bash
# Offline suite for scripts/capture-sse-experiment.sh (Task 3 verification
# instrument). Mock curl is the only curl reachable on PATH for the whole run
# (no network egress); mock streams are canned, so no sockets are needed.
# Mirrors scripts/test-notify-event-watcher.sh style.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -r "$TMP"' EXIT
pass=0; fail=0
ok(){ echo "ok: $1"; pass=$((pass+1)); }; no(){ echo "FAIL: $1"; fail=$((fail+1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || { echo "got: [$1] expected: [$2]"; no "$3"; }; }

CAP="$REPO/scripts/capture-sse-experiment.sh"
NW_LIB="$REPO/home/lib/notify-event-watcher.sh"

# Mock curl: logs its argv, then plays a canned SSE stream (mix of data:,
# event:, and keepalive comment lines) and exits — closing the stream.
CANNED="$TMP/canned.sse"
cat > "$CANNED" <<'FRAMES'
data: {"seq":1,"kind":"one"}
event: heartbeat
: keepalive
data: {"seq":2,"kind":"two"}
data: {"seq":3,"kind":"three"}
FRAMES
cat > "$TMP/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "$TMP/curl.calls"
cat "$CANNED"
EOF
chmod +x "$TMP/curl"
PATH="$TMP:$PATH"
export PATH

# Fake sessions tree shaped like the watcher suite's fixtures.
SD="$TMP/sessions"; mkdir -p "$SD/ready-a" "$SD/notready"
printf '{"state":"ready","session_id":"ready-a","port":42967,"credential_file_path":"%s/ready-a/credential.json"}' "$SD/ready-a" > "$SD/ready-a/startup.json"
printf '{"kind":"bearer","token":"tok-abc","version":1}' > "$SD/ready-a/credential.json"
printf '{"state":"starting","session_id":"notready","port":42968}' > "$SD/notready/startup.json"

# --- presence ---------------------------------------------------------------
if [ -f "$CAP" ]; then ok "capture script exists"; else no "capture script exists"; fi
[ -f "$NW_LIB" ] && ok "watcher library exists" || no "watcher library exists"

# --- case 7: --list prints ready session, excludes non-ready ---------------
out="$(NOTIFY_WATCHER_SESSIONS_DIR="$SD" bash "$CAP" --list 2>/dev/null)"
assert_eq "$out" "$SD/ready-a" "--list prints only the ready session dir"

# --- cases 1, 2, 4, 5, 6: verbatim capture, single file, no state writes ---
OUT="$TMP/out"; STATE="$TMP/state"; mkdir -p "$OUT" "$STATE"
out="$(NOTIFY_WATCHER_SESSIONS_DIR="$SD" NOTIFY_WATCHER_STATE_ROOT="$STATE" \
  bash "$CAP" "$SD/ready-a" --out "$OUT" --max-seconds 10 2>/dev/null)"
rc=$?
assert_eq "$(find "$OUT" -name '*.jsonl' | wc -l | tr -d ' ')" 1 "exactly one .jsonl file created in out dir"
GEN="$(find "$OUT" -name '*.jsonl')"
[ "$rc" -eq 0 ] && ok "capture exits zero on stream close" || no "capture exits zero on stream close"
assert_eq "$out" "$GEN" "capture prints the output file path on stdout"

assert_eq "$(cat "$GEN")" \
"data: {\"seq\":1,\"kind\":\"one\"}
data: {\"seq\":2,\"kind\":\"two\"}
data: {\"seq\":3,\"kind\":\"three\"}" \
"data: frames recorded verbatim, in order, with prefix; event:/comment lines excluded"

# Case 5: no state-root writes.
[ -z "$(ls -A "$STATE" 2>/dev/null)" ] && ok "state root stays empty after capture" || no "state root stays empty after capture"

# Case 6: curl argv shape — mock curl was the only curl, aimed at loopback.
calls="$(cat "$TMP/curl.calls" 2>/dev/null)"
assert_eq "$(echo "$calls" | grep -c '^curl ')" 1 "exactly one curl invocation (mock only, no egress)"
case "$calls" in
  *"curl -sS -N --max-time 0 -H Authorization: Bearer tok-abc http://127.0.0.1:42967/events"*)
    ok "curl args match notify_watcher_curl_args shape (Bearer + loopback /events)" ;;
  *) echo "got: [$calls]"; no "curl args match notify_watcher_curl_args shape (Bearer + loopback /events)" ;;
esac

# Output filename shape: sse-capture-<UTC timestamp>-<safe-session-id>.jsonl
base="$(basename "$GEN")"
case "$base" in
  sse-capture-????-??-??T??-??-??Z-ready-a.jsonl) ok "output filename matches sse-capture-<UTC>-<safe-id>.jsonl" ;;
  *) echo "got: [$base]"; no "output filename matches sse-capture-<UTC>-<safe-id>.jsonl" ;;
esac

# --- case 3: --max-seconds stop condition, no orphaned curl -----------------
cat > "$TMP/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "$TMP/curl.calls"
printf 'data: {"seq":1,"kind":"first"}\n'
while :; do sleep 0.1; done
EOF
chmod +x "$TMP/curl"
OUT2="$TMP/out2"; mkdir -p "$OUT2"
start="$(date +%s)"
out="$(NOTIFY_WATCHER_SESSIONS_DIR="$SD" NOTIFY_WATCHER_STATE_ROOT="$STATE" \
  bash "$CAP" "$SD/ready-a" --out "$OUT2" --max-seconds 2 2>/dev/null)"
rc=$?
end="$(date +%s)"
[ "$rc" -eq 0 ] && ok "bounded capture exits zero at --max-seconds" || no "bounded capture exits zero at --max-seconds"
[ $((end - start)) -le 10 ] && ok "bounded capture terminated on its own within bound" || no "bounded capture terminated on its own within bound"
sleep 0.5
if pgrep -f "sleep 0.1$" >/dev/null 2>&1 || pgrep -x sleep >/dev/null 2>&1; then
  # the child curl's sleep loop may still linger — identify precisely
  :
fi
# Orphan check: the child curl's infinite loop used the mock script; check via
# the recorder's own kill/wait semantics — no curl process remains in the
# process table other than unrelated ones.
orphans="$(ps -eo command 2>/dev/null | grep -F "$TMP/curl" | grep -v grep || true)"
[ -z "$orphans" ] && ok "child curl killed, no orphan remains" || { echo "orphans: [$orphans]"; no "child curl killed, no orphan remains"; }
assert_eq "$(find "$OUT2" -name '*.jsonl' | wc -l | tr -d ' ')" 1 "bounded capture writes exactly one file"
first="$(head -n 1 "$(find "$OUT2" -name '*.jsonl' | head -n 1)")"
assert_eq "$first" 'data: {"seq":1,"kind":"first"}' "bounded capture recorded the frame before the bound"

# --- F5: filename collision — existing target must not be truncated ---------
# Same-second run against an out dir already holding the would-be filename:
# the prior capture stays intact and the new frames land in a .1 suffixed file.
OUT4="$TMP/out4"; mkdir -p "$OUT4"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
PRE="$OUT4/sse-capture-$STAMP-ready-a.jsonl"
printf 'PRIOR CAPTURE — DO NOT TRUNCATE\n' > "$PRE"
cat > "$TMP/curl" <<'EOF'
#!/usr/bin/env bash
printf 'data: {"seq":9,"kind":"collide"}\n'
EOF
chmod +x "$TMP/curl"
out="$(NOTIFY_WATCHER_SESSIONS_DIR="$SD" NOTIFY_WATCHER_STATE_ROOT="$STATE" \
  bash "$CAP" "$SD/ready-a" --out "$OUT4" --max-seconds 10 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && ok "collision run exits zero" || no "collision run exits zero"
assert_eq "$(cat "$PRE")" "PRIOR CAPTURE — DO NOT TRUNCATE" "pre-existing capture file is not truncated on collision"
SUF="$(find "$OUT4" -name '*.jsonl.*' | head -n 1)"
case "$SUF" in
  "$PRE".1) ok "collision capture lands in .1 suffixed file" ;;
  *) echo "got: [$SUF] expected [$PRE.1]"; no "collision capture lands in .1 suffixed file" ;;
esac
case "$out" in
  "$PRE".1) ok "collision run prints the suffixed output path" ;;
  *) echo "got: [$out]"; no "collision run prints the suffixed output path" ;;
esac
[ -n "$(grep -F 'data: {"seq":9,"kind":"collide"}' "$SUF" 2>/dev/null)" ] && \
  ok "suffixed file holds the new frames" || no "suffixed file holds the new frames"

# --- F6: unreachable daemon — curl exits non-zero, recorder still exits 0 ---
OUT5="$TMP/out5"; mkdir -p "$OUT5"
cat > "$TMP/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$TMP/curl"
err="$TMP/f6.err"
out="$(NOTIFY_WATCHER_SESSIONS_DIR="$SD" NOTIFY_WATCHER_STATE_ROOT="$STATE" \
  bash "$CAP" "$SD/ready-a" --out "$OUT5" --max-seconds 10 2>"$err")"
rc=$?
[ "$rc" -eq 0 ] && ok "curl-exit-7 capture still exits zero (stream end is a normal stop)" || no "curl-exit-7 capture still exits zero (stream end is a normal stop)"
[ -f "$out" ] && ok "curl-exit-7 run still produces the output file" || no "curl-exit-7 run still produces the output file"
case "$(cat "$err")" in
  *"capture: curl exited 7"*) ok "stderr carries the curl-failure diagnostic" ;;
  *) echo "got stderr: [$(cat "$err")]"; no "stderr carries the curl-failure diagnostic" ;;
esac
# Clean-close path must NOT warn:
err2="$TMP/f6b.err"
cat > "$TMP/curl" <<EOF
#!/usr/bin/env bash
cat "$CANNED"
EOF
chmod +x "$TMP/curl"
OUT6="$TMP/out6"; mkdir -p "$OUT6"
NOTIFY_WATCHER_SESSIONS_DIR="$SD" NOTIFY_WATCHER_STATE_ROOT="$STATE" \
  bash "$CAP" "$SD/ready-a" --out "$OUT6" --max-seconds 10 2>"$err2" >/dev/null
case "$(cat "$err2")" in
  *"curl exited"*) echo "got stderr: [$(cat "$err2")]"; no "clean close emits no warning" ;;
  *) ok "clean close emits no warning" ;;
esac

# --- F7: burst of frames right before the mock curl exits is not lost -------
OUT7="$TMP/out7"; mkdir -p "$OUT7"
BURST="$TMP/burst.sse"
{
  i=1
  while [ "$i" -le 200 ]; do
    printf 'data: {"seq":%d,"kind":"burst"}\n' "$i"
    i=$((i+1))
  done
} > "$BURST"
cat > "$TMP/curl" <<EOF
#!/usr/bin/env bash
cat "$BURST"
EOF
chmod +x "$TMP/curl"
out="$(NOTIFY_WATCHER_SESSIONS_DIR="$SD" NOTIFY_WATCHER_STATE_ROOT="$STATE" \
  bash "$CAP" "$SD/ready-a" --out "$OUT7" --max-seconds 10 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && ok "burst capture exits zero" || no "burst capture exits zero"
assert_eq "$(grep -c '^data: ' "$out")" 200 "burst capture records all 200 frames (no tail loss at teardown)"
assert_eq "$(head -n 1 "$out")" 'data: {"seq":1,"kind":"burst"}' "burst capture preserves first frame"
assert_eq "$(tail -n 1 "$out")" 'data: {"seq":200,"kind":"burst"}' "burst capture preserves last frame (drained reader)"

# --- case 8: failure path — nonexistent session dir -------------------------
OUT3="$TMP/out3"; mkdir -p "$OUT3"
if bash "$CAP" "$TMP/does-not-exist" --out "$OUT3" >/dev/null 2>&1; then
  no "nonexistent session dir exits non-zero"
else
  ok "nonexistent session dir exits non-zero"
fi
assert_eq "$(find "$OUT3" -type f | wc -l | tr -d ' ')" 0 "no output file on failure path"

# --- nothing dialed out (mock curl is the only curl on PATH) ----------------
calls="$(cat "$TMP/curl.calls" 2>/dev/null)"
loopback_only=true
while IFS= read -r c; do
  [ -n "$c" ] || continue
  case "$c" in *"http://127.0.0.1:"*) ;; *) loopback_only=false ;; esac
done <<EOF2
$calls
EOF2
$loopback_only && ok "every curl call was aimed at loopback only" || no "every curl call was aimed at loopback only"

[ "$fail" -eq 0 ] && echo "PASS: $pass" || echo "FAILURES: $fail/$((pass+fail))"; exit "$fail"
