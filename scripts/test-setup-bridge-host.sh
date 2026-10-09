#!/usr/bin/env bash
# Offline installer tests with fake HOME, bridge checkout, and executable paths.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/discord-bridge/setup-bridge-host.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME="$TMP/home with spaces"; REPO="$TMP/runtime repo"; mkdir -p "$HOME" "$REPO/scripts" "$TMP/bin"
cat > "$REPO/scripts/bridge-host.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$REPO/scripts/bridge-host.sh"
cat > "$TMP/bin/polytoken" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/bin/polytoken"
PY="${TEST_PYTHON:-$(command -v python3)}"
# Make a minimal existing connector environment with a preserved relay secret.
mkdir -p "$HOME/.config/polytoken/discord-bridge"
printf '%s\n' '{"relay_address":"ws://127.0.0.1:8765","relay_token":"existing-relay-secret","sessions_dir":"/old/path"}' > "$HOME/.config/polytoken/discord-bridge/connector.json"
chmod 600 "$HOME/.config/polytoken/discord-bridge/connector.json"
printf '%s\n' 'DISCORD_BOT_TOKEN=discord-secret' 'DISCORD_GUILD_ID=123' 'DISCORD_CONTROL_CHANNEL_ID=456' 'DISCORD_OPERATOR_USER_ID=789' 'BRIDGE_STATE_DB=/preserved/state.sqlite' 'BRIDGE_WORKSPACE_ROOT=/tmp/work space' 'BRIDGE_RELAY_BIND=127.0.0.1:9876' 'BRIDGE_RELAY_ADVERTISE=ws://127.0.0.1:9876' 'BRIDGE_HOST_PYTHON=/obsolete/python' > "$HOME/.config/polytoken-discord.env"
unset BRIDGE_RELAY_TOKEN BRIDGE_RELAY_ADDRESS BRIDGE_CONNECTOR_CONFIG BRIDGE_POLYTOKEN_CONFIG_DIR BRIDGE_XDG_CONFIG_HOME BRIDGE_XDG_DATA_HOME
export HOME BRIDGE_REPO_DIR="$REPO" BRIDGE_POLYTOKEN_BIN="$TMP/bin/polytoken" BRIDGE_SETUP_PYTHON="$PY"
export BRIDGE_SETUP_SKIP_PYTHON_INSTALL=1 BRIDGE_SETUP_SKIP_LAUNCHCTL=1
mkdir -p "$HOME/.local/share/polytoken-discord/connector-venv/bin"
ln -s "$PY" "$HOME/.local/share/polytoken-discord/connector-venv/bin/python"
export BRIDGE_SESSIONS_DIR="$HOME/.local/share/polytoken"
export BRIDGE_SETUP_PLIST_DST="$HOME/Library/LaunchAgents/local.polytoken-discord-bridge.plist"
bash "$SCRIPT" >/dev/null
ENV_FILE="$HOME/.config/polytoken-discord.env"
JSON="$HOME/.config/polytoken/discord-bridge/connector.json"
"$PY" -c 'import os,sys; assert all(os.stat(p).st_mode & 0o777 == 0o600 for p in sys.argv[1:])' "$ENV_FILE" "$JSON"
grep -q '^DISCORD_BOT_TOKEN=discord-secret$' "$ENV_FILE"
grep -q '^DISCORD_GUILD_ID=123$' "$ENV_FILE"
grep -q '^BRIDGE_STATE_DB=/preserved/state.sqlite$' "$ENV_FILE"
grep -q "^BRIDGE_RELAY_ADVERTISE=ws://127.0.0.1:9876$" "$ENV_FILE"
grep -Fq "BRIDGE_WORKSPACE_ROOT='/tmp/work space'" "$ENV_FILE"
grep -q '^BRIDGE_RELAY_BIND=127.0.0.1:9876$' "$ENV_FILE"
grep -Fq "BRIDGE_HOST_PYTHON='$HOME/.local/share/polytoken-discord/connector-venv/bin/python'" "$ENV_FILE"
"$PY" - "$JSON" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
assert set(c)=={'relay_address','relay_token','sessions_dir','connector_python'}, c
assert c['relay_token']=='existing-relay-secret'
assert c['relay_address']=='ws://127.0.0.1:9876'
assert c['connector_python'].endswith('/connector-venv/bin/python')
PY
PLIST="$HOME/Library/LaunchAgents/local.polytoken-discord-bridge.plist"
"$PY" - "$PLIST" "$REPO" <<'PY'
import sys,xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1]).getroot(); text=open(sys.argv[1]).read()
assert sys.argv[2]+'/scripts/bridge-host.sh' in text
assert '&amp;' not in text or ET.fromstring(text)
assert 'local.polytoken-discord-bridge' in text
PY
before="$(shasum -a 256 "$PLIST" | awk '{print $1}')"
bash "$SCRIPT" >/dev/null
after="$(shasum -a 256 "$PLIST" | awk '{print $1}')"
[ "$before" = "$after" ]
# A fresh install generates one relay token and reuses it on update.
rm -f "$JSON"; sed -i.bak '/BRIDGE_RELAY_TOKEN=/d' "$ENV_FILE"; rm -f "$ENV_FILE.bak"
bash "$SCRIPT" >/dev/null
first="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["relay_token"])' "$JSON")"
bash "$SCRIPT" >/dev/null
second="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["relay_token"])' "$JSON")"
[ -n "$first" ] && [ "$first" = "$second" ]
"$PY" -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace("BRIDGE_RELAY_BIND=127.0.0.1:9876", "BRIDGE_RELAY_BIND=[::1]:9876"))' "$ENV_FILE"
bash "$SCRIPT" >/dev/null
"$PY" -c 'import json,sys; assert json.load(open(sys.argv[1]))["relay_address"] == "ws://[::1]:9876"' "$JSON"
printf 'PASS: native install preservation, 0600 JSON, absolute paths, idempotency, token generation/reuse, IPv6 consistency\n'
