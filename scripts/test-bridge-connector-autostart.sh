#!/usr/bin/env bash
# Offline native connector hook contract tests: no relay, launchd, or pip.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/polytoken/hooks/bridge-connector-autostart.sh"
LAUNCHER="$ROOT/polytoken/hooks/bridge-connector-launcher.sh"
TMP="$(mktemp -d)"
trap 'if [ -f "$TMP/sessions/pid" ]; then kill "$(cat "$TMP/sessions/pid")" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/config" "$TMP/sessions/sessions-v1/sess-one" "$TMP/sessions/sessions-v1/other"
printf '%s\n' '{"session_id":"sess-one","state":"ready"}' > "$TMP/sessions/sessions-v1/sess-one/startup.json"
printf '%s\n' '{"session_id":"other","state":"ready"}' > "$TMP/sessions/sessions-v1/other/startup.json"
cat > "$TMP/config.json" <<JSON
{"relay_address":"ws://127.0.0.1:8765","relay_token":"secret-test-token","sessions_dir":"$TMP/sessions","connector_python":"$TMP/fake-python"}
JSON
chmod 600 "$TMP/config.json"
cat > "$TMP/fake-python" <<'PY'
#!/usr/bin/python3
import os,sys,time
if sys.argv[1:] == ['-m','discord_bridge.connector_main']:
    with open(os.environ['POLYTOKEN_SESSIONS_DIR']+'/catalog','a') as f: f.write(os.environ.get('POLYTOKEN_SESSION_ID','')+'\n')
    open(os.environ['POLYTOKEN_SESSIONS_DIR']+'/pid','w').write(str(os.getpid()))
    time.sleep(30)
PY
PYTHON_PATH="$(python -c 'import sys; print(sys.executable)')"
"$PYTHON_PATH" - "$TMP/fake-python" "$PYTHON_PATH" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); text=p.read_text(); p.write_text('#!'+sys.argv[2]+'\n'+text.split('\n',1)[1])
PY
chmod +x "$TMP/fake-python"
export HOME="$TMP" BRIDGE_CONNECTOR_CONFIG="$TMP/config.json" BRIDGE_CONNECTOR_LAUNCHER="$LAUNCHER"
export BRIDGE_CONNECTOR_SYSTEM_PYTHON="$(python -c 'import sys; print(sys.executable)')"

# Missing ID remains immediate fail-open and does not guess another session.
out="$(env -u POLYTOKEN_SESSION_ID bash "$HOOK")"
[ "$out" = '{"outcome":"allow"}' ] || { echo "wrong no-id output: $out" >&2; exit 1; }
[ ! -e "$TMP/sessions/pid" ] || { echo 'launched without exact session ID' >&2; exit 1; }

# An explicitly named ready session starts; a startup record for another ID
# must never be substituted if the requested ID is absent or not ready.
export POLYTOKEN_SESSION_ID=sess-one POLYTOKEN_SESSIONS_DIR="$TMP/sessions"
# Session without explicit opt-in must remain a bare allow with no child.
out="$(bash "$HOOK")"
[ "$out" = '{"outcome":"allow"}' ] && [ ! -e "$TMP/sessions/pid" ]
export POLYTOKEN_BRIDGE_ENABLE=1
out="$(bash "$HOOK")"
[ "$out" = '{"outcome":"allow"}' ] || { echo "wrong output: $out" >&2; exit 1; }
for _ in $(seq 1 80); do [ -s "$TMP/sessions/catalog" ] && break; sleep .05; done
[ "$(cat "$TMP/sessions/catalog")" = 'sess-one' ] || { echo 'connector identity/config mismatch' >&2; exit 1; }

# Concurrent duplicate invocations are deduplicated by the lifetime flock.
bash "$HOOK" >/dev/null & a=$!
bash "$HOOK" >/dev/null & b=$!
wait "$a"; wait "$b"
sleep .1
[ "$(wc -l < "$TMP/sessions/catalog" | tr -d ' ')" = 1 ] || { echo 'duplicate connector launched' >&2; exit 1; }

# Explicit missing ID never chooses the other ready session.
out="$(POLYTOKEN_SESSION_ID=missing bash "$HOOK")"
[ "$out" = '{"outcome":"allow"}' ] || { echo 'missing session did not fail open' >&2; exit 1; }
[ "$(wc -l < "$TMP/sessions/catalog" | tr -d ' ')" = 1 ] || { echo 'fallback session was selected' >&2; exit 1; }

# Broken config/runtime still returns allow, and errors never disclose token.
kill "$(cat "$TMP/sessions/pid")" 2>/dev/null || true
rm -f "$TMP/sessions/pid"; printf '{bad\n' > "$TMP/config.json"
out="$(bash "$HOOK")"
[ "$out" = '{"outcome":"allow"}' ] || { echo 'failure path not fail-open' >&2; exit 1; }
sleep .1
grep -qF 'secret-test-token' "$TMP/sessions/discord-bridge/connector.log" 2>/dev/null && { echo 'secret leaked to log' >&2; exit 1; } || true
printf 'PASS: immediate allow, exact session only, flock dedupe, failure fail-open, secret hygiene\n'
