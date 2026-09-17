#!/usr/bin/env bash
# Offline test matrix for the bridge connector auto-start hook and launcher
# (polytoken/hooks/bridge-connector-autostart.sh + bridge-connector-launcher.sh).
#
# Covers the acceptance-critical behavior without any live connector, venv, or
# relay:
#   - host no-op: bare allow, no spawn
#   - container gate + bridge env gate (container without env -> bare allow)
#   - container with env + POLYTOKEN_SESSION_ID -> allow + connector exec
#   - missing session_id -> derived via session_select fallback
#   - missing python/venv -> allow + loud log, session unaffected
#   - double invocation (flock) -> exactly one connector process
#   - bad hostname format -> warn-only, connector still execs
#   - non-ready startup.json -> poll -> timeout -> launcher exits nonzero
#   - hook returns <1s with exactly one allow JSON line
#   - child survives after the hook process exits (stdio/pipe discipline)
#   - forced failure leaves connector.log free of $BRIDGE_RELAY_TOKEN
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/polytoken/hooks/bridge-connector-autostart.sh"
LAUNCHER="$REPO/polytoken/hooks/bridge-connector-launcher.sh"
TMP="$(mktemp -d)"
trap 'cleanup' EXIT

pass=0; fail=0
ok(){ echo "  ok: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
sc(){ echo; echo "=== $1 ==="; }

cleanup(){
  [ -f "$TMP/connector.pid" ] && kill "$(cat "$TMP/connector.pid" 2>/dev/null)" 2>/dev/null || true
  rm -rf "$TMP" 2>/dev/null || true
}

# ---- sandbox: fake config-root hooks dir, sessions root, log ----
mkdir -p "$TMP/config/hooks" "$TMP/sessions/sessions-v1/a-session" "$TMP/state"
cp "$HOOK" "$TMP/config/hooks/bridge-connector-autostart.sh"
cp "$LAUNCHER" "$TMP/config/hooks/bridge-connector-launcher.sh"
chmod +x "$TMP/config/hooks/"*.sh

LOG="$TMP/state/connector.log"
CATALOG="$TMP/state/catalog"   # every connector exec appends its env here

# ---- stub "connector_main"-compatible python ----
# The launcher calls BRIDGE_CONNECTOR_PYTHON -m discord_bridge.connector_main;
# this stub records identity + env, writes a pidfile, and sleeps so tests can
# observe liveness (and exactly-once). It also implements the tiny
# session_select fallback lookup (newest ready startup.json) the launcher
# invokes with `-m discord_bridge.session_select --sessions-v1 DIR`.
cat > "$TMP/config/hooks/fake-connector-python" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-m" ] && [ "\${2:-}" = "discord_bridge.session_select" ]; then
  # newest ready startup.json under the given sessions-v1 dir
  dir=\${4:-}
  best=""
  for f in "\$dir"/*/startup.json; do
    [ -f "\$f" ] || continue
    sid="\$(jq -r .session_id "\$f" 2>/dev/null || true)"
    st="\$(jq -r .state "\$f" 2>/dev/null || true)"
    [ -n "\$sid" ] && [ "\$st" = "ready" ] || continue
    [ -n "\$best" ] || best="\$f"
    [ "\$f" -nt "\$best" ] && best="\$f"
  done
  if [ -n "\$best" ]; then jq -r .session_id "\$best"; exit 0; fi
  exit 1
fi
if [ "\${1:-}" = "-m" ] && [ "\${2:-}" = "discord_bridge.connector_main" ]; then
  echo "category=connector session=\${POLYTOKEN_SESSION_ID:-} container=\${BRIDGE_CONTAINER_ID:-} connector=\${BRIDGE_CONNECTOR_ID:-}" >> "\$CATALOG"
  echo \$\$ > "\$PIDFILE"
  while :; do sleep 60; done
fi
exit 0
EOF
chmod +x "$TMP/config/hooks/fake-connector-python"

# ---- helpers ----
PIDFILE="$TMP/connector.pid"
: > "$CATALOG"
started_log() { grep -q "connector auto-start\|exec connector\|did not reach ready\|WARN" "$LOG" 2>/dev/null; }
wait_log() {  # wait_log FRAGMENT
  local deadline=$((SECONDS+10))
  while [ "$SECONDS" -lt "$deadline" ]; do
    grep -q "$1" "$LOG" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}
connector_alive() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }
connector_count() { grep -c "category=connector" "$CATALOG" 2>/dev/null | tr -d ' ' || echo 0; }
reset_state() {
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
  rm -f "$PIDFILE" "$TMP/sessions/bridge/autostart.lock" 2>/dev/null || true
  : > "$LOG"; : > "$CATALOG"
}
wait_until() { # wait_until CMD... — poll a predicate for up to 5s
  local deadline=$((SECONDS+5))
  while [ "$SECONDS" -lt "$deadline" ]; do
    "$@" && return 0
    sleep 0.05
  done
  return 1
}

# run_hook OUTPUT_VAR ...  — invokes the hook with the sandbox env. Callers pass
# extra env pairs; the hook stdin gets the fake session_start event. Does NOT
# reset state (so the double-invocation test can observe accumulated catalog).
run_hook() {
  local outvar="$1"; shift
  local stdout=""
  local rc=0
  set +e
  stdout="$(printf '%s' '{"session_id":"a-session"}' | env \
    HOME="$TMP/home" \
    POLYTOKEN_CONFIG_DIR="$TMP/config" \
    POLYTOKEN_SESSIONS_DIR="$TMP/sessions" \
    BRIDGE_CONNECTOR_LOG="$LOG" \
    BRIDGE_CONNECTOR_PYTHON="$TMP/config/hooks/fake-connector-python" \
    CATALOG="$CATALOG" PIDFILE="$PIDFILE" \
    "$@" \
    bash "$HOOK" 2>"$TMP/hook.err")"
  rc=$?
  set -e
  eval "$outvar=\$stdout"
  return "$rc"
}

# host-role id stub: a PATH shim so the hook sees a non-dev user (host context).
mkdir -p "$TMP/hostbin"
printf '#!/usr/bin/env bash\necho hostuser\n' > "$TMP/hostbin/id"
chmod +x "$TMP/hostbin/id"

# ---- 1. host no-op ----
sc "1. host session -> bare allow, no spawn, <1s"
: > "$LOG"
SECONDS=0
out="$(printf '%s' '{}' | env HOME="$TMP/home" POLYTOKEN_CONFIG_DIR="$TMP/config" \
  POLYTOKEN_SESSIONS_DIR="$TMP/sessions" BRIDGE_CONNECTOR_LOG="$LOG" \
  PATH="$TMP/hostbin:$PATH" bash "$HOOK" 2>/dev/null)"
rc=$?
[ "$SECONDS" -lt 1 ] && ok "hook returns <1s (got ${SECONDS}s)" || no "hook returns <1s (got ${SECONDS}s)"
[ "$rc" -eq 0 ] && ok "hook exits 0" || no "hook exits 0 (got $rc)"
[ "$out" = '{"outcome":"allow"}' ] && ok "bare allow JSON" || no "bare allow JSON: $out"
[ ! -f "$PIDFILE" ] && ok "no connector spawned on host" || no "no connector spawned on host"

# ---- 2. container without bridge env -> bare allow, no spawn ----
sc "2. container, no BRIDGE_RELAY_TOKEN -> bare allow, no spawn"
out="$(printf '%s' '{}' | env -u BRIDGE_RELAY_TOKEN HOME="$TMP/home" POLYTOKEN_CONFIG_DIR="$TMP/config" \
  POLYTOKEN_SESSIONS_DIR="$TMP/sessions" BRIDGE_CONNECTOR_LOG="$LOG" \
  bash "$HOOK" 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && [ "$out" = '{"outcome":"allow"}' ] && ok "bare allow without env" || no "bare allow without env: rc=$rc out=$out"
[ ! -f "$PIDFILE" ] && ok "no connector spawned" || no "no connector spawned"

# ---- 3. container with env + POLYTOKEN_SESSION_ID -> one connector ----
sc "3. container with env + session id -> connector execs with derived identity"
mkdir -p "$TMP/sessions/sessions-v1/a-session"
printf '%s\n' '{"state":"ready","session_id":"a-session"}' > "$TMP/sessions/sessions-v1/a-session/startup.json"
reset_state
out="$(printf '%s' '{"session_id":"a-session"}' | env -u BRIDGE_RELAY_TOKEN HOME="$TMP/home" POLYTOKEN_CONFIG_DIR="$TMP/config" \
  POLYTOKEN_SESSIONS_DIR="$TMP/sessions" BRIDGE_CONNECTOR_LOG="$LOG" \
  BRIDGE_RELAY_TOKEN=test-relay-token POLYTOKEN_SESSION_ID=a-session \
  BRIDGE_CONTAINER_ID="$(hostname)" BRIDGE_CONNECTOR_READY_ATTEMPTS=1 \
  BRIDGE_CONNECTOR_PYTHON="$TMP/config/hooks/fake-connector-python" \
  CATALOG="$CATALOG" PIDFILE="$PIDFILE" \
  bash "$HOOK" 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && [ "$out" = '{"outcome":"allow"}' ] && ok "allow emitted" || no "allow emitted: rc=$rc out=$out"
wait_log "exec connector" && ok "connector exec'd (ready state polled)" || no "connector exec'd (ready state polled)"
wait_log "identity: session=a-session" && ok "launcher derived session from env" || no "launcher derived session from env"
[ "$(grep 'category=connector' "$CATALOG" | head -1 | grep -c 'session=a-session')" = 1 ] \
  && ok "connector inherited POLYTOKEN_SESSION_ID=a-session" || no "connector inherited POLYTOKEN_SESSION_ID"
[ "$(connector_count)" = 1 ] && ok "exactly one connector record" || no "exactly one connector record ($(connector_count))"
wait_until connector_alive && ok "connector child alive after hook exit (stdio discipline)" || no "connector child alive after hook exit"

# ---- 4. missing session_id -> session_select fallback ----
sc "4. missing POLYTOKEN_SESSION_ID -> derived via newest-ready fallback"
# a-session already ready; drop env var
reset_state
out="$(printf '%s' '{}' | env -u BRIDGE_RELAY_TOKEN -u POLYTOKEN_SESSION_ID HOME="$TMP/home" \
  POLYTOKEN_CONFIG_DIR="$TMP/config" POLYTOKEN_SESSIONS_DIR="$TMP/sessions" BRIDGE_CONNECTOR_LOG="$LOG" \
  BRIDGE_RELAY_TOKEN=test-relay-token BRIDGE_CONNECTOR_READY_ATTEMPTS=1 \
  BRIDGE_CONNECTOR_PYTHON="$TMP/config/hooks/fake-connector-python" \
  CATALOG="$CATALOG" PIDFILE="$PIDFILE" \
  bash "$HOOK" 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && [ "$out" = '{"outcome":"allow"}' ] && ok "allow emitted without env session id" || no "allow emitted without env session id"
wait_log "derived session a-session" && ok "session_select fallback picked a-session" || no "session_select fallback picked a-session"
[ "$(connector_count)" = 1 ] && ok "exactly one connector after fallback" || no "exactly one connector after fallback"

# ---- 5. missing python/venv -> allow + loud log, no connector, session fine ----
sc "5. missing python/venv -> allow + loud log, no connector"
reset_state
out="$(printf '%s' '{}' | env -u BRIDGE_RELAY_TOKEN HOME="$TMP/home" POLYTOKEN_CONFIG_DIR="$TMP/config" \
  POLYTOKEN_SESSIONS_DIR="$TMP/sessions" BRIDGE_CONNECTOR_LOG="$LOG" \
  BRIDGE_RELAY_TOKEN=test-relay-token POLYTOKEN_SESSION_ID=a-session \
  BRIDGE_CONNECTOR_PYTHON="$TMP/config/hooks/does-not-exist" \
  bash "$HOOK" 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && [ "$out" = '{"outcome":"allow"}' ] && ok "allow even with broken python" || no "allow even with broken python"
wait_log "BRIDGE_CONNECTOR_PYTHON not executable" && ok "launcher logged the failure loudly" || no "launcher logged the failure loudly"
[ ! -f "$PIDFILE" ] && ok "no connector spawned" || no "no connector spawned"

# ---- 6. double session_start (flock dedupe) -> exactly one connector ----
sc "6. double invocation -> flock holds, exactly one connector"
reset_state
run_hook OUT1 BRIDGE_RELAY_TOKEN=test-relay-token POLYTOKEN_SESSION_ID=a-session BRIDGE_CONNECTOR_READY_ATTEMPTS=1
wait_log "exec connector"
run_hook OUT2 BRIDGE_RELAY_TOKEN=test-relay-token POLYTOKEN_SESSION_ID=a-session BRIDGE_CONNECTOR_READY_ATTEMPTS=1
sleep 0.3
[ "$OUT1" = '{"outcome":"allow"}' ] && [ "$OUT2" = '{"outcome":"allow"}' ] \
  && ok "both invocations allow" || no "both invocations allow ($OUT1 / $OUT2)"
[ "$(connector_count)" = 1 ] && ok "exactly one connector after double hook" || no "exactly one connector after double hook ($(connector_count))"

# ---- 7. bad hostname format -> warn-only, connector still execs ----
sc "7. non-hex hostname -> warn-only, identity still applied"
reset_state
run_hook OUT3 BRIDGE_RELAY_TOKEN=test-relay-token POLYTOKEN_SESSION_ID=a-session \
  BRIDGE_CONTAINER_ID=not-a-hex-id BRIDGE_CONNECTOR_READY_ATTEMPTS=1
wait_log "fails hex preflight" && ok "warn-only hex preflight logged" || no "warn-only hex preflight logged"
[ "$(grep 'category=connector' "$CATALOG" | tail -1 | grep -c 'container=not-a-hex-id')" = 1 ] \
  && ok "non-hex container id still applied" || no "non-hex container id still applied"
wait_until connector_alive && ok "connector still exec'd" || no "connector still exec'd"

# ---- 8. non-ready startup.json -> poll -> timeout -> launcher exits nonzero ----
sc "8. non-ready startup.json -> poll timeout -> launcher exit nonzero (session unaffected)"
mkdir -p "$TMP/sessions2/sessions-v1/nr-session"
printf '%s\n' '{"state":"starting","session_id":"nr-session"}' > "$TMP/sessions2/sessions-v1/nr-session/startup.json"
: > "$LOG"; rm -f "$PIDFILE"; : > "$CATALOG"
set +e
( POLYTOKEN_SESSIONS_DIR="$TMP/sessions2" BRIDGE_CONNECTOR_LOG="$LOG" \
  BRIDGE_RELAY_TOKEN=test-relay-token POLYTOKEN_SESSION_ID=nr-session \
  BRIDGE_CONNECTOR_PYTHON="$TMP/config/hooks/fake-connector-python" \
  BRIDGE_CONNECTOR_READY_ATTEMPTS=1 BRIDGE_CONNECTOR_READY_INTERVAL=0 \
  bash "$LAUNCHER" >>"$LOG" 2>&1 )
lrc=$?
set -e
[ "$lrc" -ne 0 ] && ok "launcher exits nonzero on poll timeout" || no "launcher exits nonzero on poll timeout (rc=$lrc)"
grep -q "did not reach ready" "$LOG" && ok "timeout logged" || no "timeout logged"
[ ! -f "$PIDFILE" ] && ok "no connector spawned on timeout" || no "no connector spawned on timeout"
# The hook itself must still return allow even while the launcher times out.
out="$(printf '%s' '{}' | env HOME="$TMP/home" POLYTOKEN_CONFIG_DIR="$TMP/config" \
  POLYTOKEN_SESSIONS_DIR="$TMP/sessions2" BRIDGE_CONNECTOR_LOG="$LOG" BRIDGE_RELAY_TOKEN=test-relay-token \
  POLYTOKEN_SESSION_ID=nr-session BRIDGE_CONNECTOR_READY_ATTEMPTS=1 BRIDGE_CONNECTOR_READY_INTERVAL=0 \
  bash "$HOOK" 2>/dev/null)"
[ "$out" = '{"outcome":"allow"}' ] && ok "hook allow while launcher times out" || no "hook allow while launcher times out"

# ---- 9. secret hygiene: relay token never reaches connector.log ----
sc "9. forced failure leaves connector.log free of \$BRIDGE_RELAY_TOKEN"
SECRET="relay-secret-7f3a9c"
reset_state
run_hook OUT4 BRIDGE_RELAY_TOKEN="$SECRET" POLYTOKEN_SESSION_ID=a-session \
  BRIDGE_CONNECTOR_PYTHON="$TMP/config/hooks/does-not-exist"
wait_log "BRIDGE_CONNECTOR_PYTHON not executable"
if grep -qF "$SECRET" "$LOG" 2>/dev/null; then
  no "connector.log contains BRIDGE_RELAY_TOKEN"
else
  ok "connector.log free of BRIDGE_RELAY_TOKEN"
fi
# Run through the full launcher failure (bad python) too and re-check.
: > "$LOG"
run_hook OUT5 BRIDGE_RELAY_TOKEN="$SECRET" POLYTOKEN_SESSION_ID=a-session \
  BRIDGE_CONTAINER_ID=bad!chars BRIDGE_CONNECTOR_PYTHON="$TMP/config/hooks/does-not-exist"
wait_log "BRIDGE_CONNECTOR_PYTHON not executable"
if grep -qF "$SECRET" "$LOG" 2>/dev/null; then
  no "connector.log contains token after bad-hostname failure"
else
  ok "connector.log token-free after bad-hostname failure"
fi

# ---- 10. exact one-line allow on a normal path ----
sc "10. exactly one allow JSON line, no trailing content"
reset_state
out="$(printf '%s' '{}' | env -u BRIDGE_RELAY_TOKEN HOME="$TMP/home" POLYTOKEN_CONFIG_DIR="$TMP/config" \
  POLYTOKEN_SESSIONS_DIR="$TMP/sessions" BRIDGE_CONNECTOR_LOG="$LOG" BRIDGE_RELAY_TOKEN=test-relay-token \
  POLYTOKEN_SESSION_ID=a-session BRIDGE_CONNECTOR_READY_ATTEMPTS=1 bash "$HOOK" 2>/dev/null)"
lines="$(printf '%s\n' "$out" | grep -c . )"
[ "$lines" -eq 1 ] && [ "$out" = '{"outcome":"allow"}' ] \
  && ok "stdout is exactly one allow JSON line" || no "stdout is exactly one allow JSON line (lines=$lines out=$out)"

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
