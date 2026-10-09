#!/usr/bin/env bash
# Install the native Discord relay and connector configuration (no startup pip).
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL=local.polytoken-discord-bridge
BRIDGE_REPO_DIR="${BRIDGE_REPO_DIR:-$HOME/workspace/discord-pt-stream}"
BRIDGE_WRAPPER="$BRIDGE_REPO_DIR/scripts/bridge-host.sh"
ENV_FILE="${POLYTOKEN_DISCORD_ENV:-$HOME/.config/polytoken-discord.env}"
CONNECTOR_CONFIG="${BRIDGE_CONNECTOR_CONFIG:-$HOME/.config/polytoken/discord-bridge/connector.json}"
PLIST_SRC="$SELF/discord-bridge/local.polytoken-discord-bridge.plist.example"
PLIST_DST="${BRIDGE_SETUP_PLIST_DST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
SPAWN_LAUNCHER="$HOME/.config/polytoken/discord-bridge/polytoken-native.sh"
STATE_DIR="$HOME/.local/share/polytoken-discord"
CONNECTOR_ENV="$STATE_DIR/connector-venv"
BOOTSTRAP_PYTHON="${BRIDGE_SETUP_PYTHON:-$(command -v python3 || true)}"
POLYTOKEN_BIN="${BRIDGE_POLYTOKEN_BIN:-$(command -v polytoken || true)}"
SESSIONS_DIR="${BRIDGE_SESSIONS_DIR:-$HOME/.local/share/polytoken}"
POLYTOKEN_CONFIG_DIR="${BRIDGE_POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}"
XDG_CONFIG_HOME="${BRIDGE_XDG_CONFIG_HOME:-${XDG_CONFIG_HOME:-$(dirname "$POLYTOKEN_CONFIG_DIR")}}"
XDG_DATA_HOME="${BRIDGE_XDG_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}"
CONFIG_ALLOWLIST="${BRIDGE_POLYTOKEN_CONFIG_DIRS:-$POLYTOKEN_CONFIG_DIR}"
DRY_RUN=0 UNINSTALL=0
for arg in "$@"; do case "$arg" in --dry-run) DRY_RUN=1;; --uninstall) UNINSTALL=1;; *) echo "unknown argument: $arg" >&2; exit 1;; esac; done
say(){ printf '==> %s\n' "$*"; }
if [ "$UNINSTALL" = 1 ]; then
  command -v launchctl >/dev/null 2>&1 && launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  [ "$DRY_RUN" = 1 ] || rm -f "$PLIST_DST"
  exit 0
fi
[ -x "$BOOTSTRAP_PYTHON" ] || { echo 'python3 required for installer-time shared environment provisioning' >&2; exit 1; }
[ -x "$POLYTOKEN_BIN" ] || { echo 'Polytoken executable required (set BRIDGE_POLYTOKEN_BIN)' >&2; exit 1; }
[ -x "$BRIDGE_WRAPPER" ] || { echo "missing bridge host wrapper: $BRIDGE_WRAPPER" >&2; exit 1; }
BRIDGE_REPO_DIR="$(cd "$BRIDGE_REPO_DIR" && pwd -P)"
BRIDGE_WRAPPER="$BRIDGE_REPO_DIR/scripts/bridge-host.sh"
BOOTSTRAP_PYTHON="$(cd "$(dirname "$BOOTSTRAP_PYTHON")" && pwd -P)/$(basename "$BOOTSTRAP_PYTHON")"
POLYTOKEN_BIN="$(cd "$(dirname "$POLYTOKEN_BIN")" && pwd -P)/$(basename "$POLYTOKEN_BIN")"
SESSIONS_DIR="$(mkdir -p "$SESSIONS_DIR" && cd "$SESSIONS_DIR" && pwd -P)"
# Read existing env data without sourcing it. Update only native host path/relay
# settings; preserve Discord token/IDs and BRIDGE_STATE_DB from existing file.
get_env(){ [ -r "$ENV_FILE" ] && grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed -E 's/^['"'"']|['"'"']$//g' || true; }
relay_token="${BRIDGE_RELAY_TOKEN:-$(get_env BRIDGE_RELAY_TOKEN)}"
state_db="$(get_env BRIDGE_STATE_DB)"; [ -n "$state_db" ] || state_db="$STATE_DIR/state.sqlite3"
relay_bind="$(get_env BRIDGE_RELAY_BIND)"; [ -n "$relay_bind" ] || relay_bind=127.0.0.1:8765
case "$relay_bind" in 127.0.0.1:*|localhost:*|'[::1]:'*) ;; *) echo 'BRIDGE_RELAY_BIND must be loopback-only' >&2; exit 1;; esac
relay_port="${relay_bind##*:}"
# Never retain legacy container/host advertisements: connector address follows the validated loopback listener.
case "$relay_bind" in
  '[::1]:'*) relay_advertise="ws://[::1]:$relay_port" ;;
  localhost:*) relay_advertise="ws://localhost:$relay_port" ;;
  *) relay_advertise="ws://127.0.0.1:$relay_port" ;;
esac
workspace="$(get_env BRIDGE_WORKSPACE_ROOT)"; [ -n "$workspace" ] || workspace="$HOME/workspace"
workspace="$(mkdir -p "$workspace" && cd "$workspace" && pwd -P)"
connector_addr="${BRIDGE_RELAY_ADDRESS:-$relay_advertise}"
connector_existing="$CONNECTOR_CONFIG"
if [ -z "$relay_token" ] && [ -r "$connector_existing" ]; then
  relay_token="$("$BOOTSTRAP_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("relay_token", ""))' "$connector_existing")"
fi
if [ -z "$relay_token" ] && [ "$DRY_RUN" = 0 ]; then
  relay_token="$("$BOOTSTRAP_PYTHON" -c 'import secrets; print(secrets.token_urlsafe(32))')"
fi
connector_token="$relay_token"
mkdir -p "$(dirname "$CONNECTOR_CONFIG")" "$STATE_DIR" "$(dirname "$PLIST_DST")" "$HOME/Library/Logs" "$(dirname "$SPAWN_LAUNCHER")"
if [ "$DRY_RUN" = 1 ]; then
  say "would update native host settings in $ENV_FILE (preserving Discord credentials/IDs/state DB)"
  say "would provision shared connector environment at $CONNECTOR_ENV and owner-only config $CONNECTOR_CONFIG"
  say "would install $PLIST_DST; launchd label remains $LABEL"
  exit 0
fi
# Keep the spawn launcher in a stable user-config location, independent of this checkout.
install -m 700 "$SELF/scripts/polytoken-native.sh" "$SPAWN_LAUNCHER"
# Installer-time shared environment provisioning. No pip activity occurs at startup.
if [ "${BRIDGE_SETUP_SKIP_PYTHON_INSTALL:-0}" != 1 ]; then
  "$BOOTSTRAP_PYTHON" -m venv "$CONNECTOR_ENV"
  "$CONNECTOR_ENV/bin/python" -m pip install --quiet -e "$BRIDGE_REPO_DIR[live,connector]"
fi
SYSTEM_PYTHON="$CONNECTOR_ENV/bin/python"
CONNECTOR_PYTHON="${BRIDGE_CONNECTOR_PYTHON:-$SYSTEM_PYTHON}"
[ -x "$SYSTEM_PYTHON" ] || { echo "shared host/connector Python unavailable: $SYSTEM_PYTHON (run installer without BRIDGE_SETUP_SKIP_PYTHON_INSTALL=1)" >&2; exit 1; }
CONNECTOR_PYTHON="$SYSTEM_PYTHON"
export CONNECTOR_CONFIG="$CONNECTOR_CONFIG" connector_addr connector_token SESSIONS_DIR CONNECTOR_PYTHON
"$SYSTEM_PYTHON" - <<'PY'
import json, os, pathlib, tempfile
p=pathlib.Path(os.environ['CONNECTOR_CONFIG'])
obj={'relay_address':os.environ['connector_addr'],'relay_token':os.environ['connector_token'],
     'sessions_dir':os.environ['SESSIONS_DIR'],'connector_python':os.environ['CONNECTOR_PYTHON']}
fd,tmp=tempfile.mkstemp(dir=p.parent,prefix='.connector-')
try:
 os.fchmod(fd,0o600)
 with os.fdopen(fd,'w') as f: json.dump(obj,f); f.write('\n')
 os.replace(tmp,p); os.chmod(p,0o600)
finally:
 if os.path.exists(tmp): os.unlink(tmp)
PY
# Bootstrap the detached launcher without relying on an interactive PATH.
printf '%s\n' "$SYSTEM_PYTHON" > "$CONNECTOR_CONFIG.python"
chmod 600 "$CONNECTOR_CONFIG.python"
# Preserve every existing host env line except settings whose old values are
# invalid for native sessions; append/update paths as explicit absolute values.
export ENV_FILE relay_token state_db relay_bind relay_advertise SYSTEM_PYTHON POLYTOKEN_BIN SESSIONS_DIR workspace CONNECTOR_CONFIG SPAWN_LAUNCHER POLYTOKEN_CONFIG_DIR XDG_CONFIG_HOME XDG_DATA_HOME CONFIG_ALLOWLIST
"$SYSTEM_PYTHON" - <<'PY'
import os, pathlib, shlex, tempfile
p=pathlib.Path(os.environ['ENV_FILE']); lines=p.read_text().splitlines() if p.exists() else []
updates={'BRIDGE_RELAY_TOKEN':os.environ['relay_token'],'BRIDGE_RELAY_BIND':os.environ['relay_bind'],
'BRIDGE_RELAY_ADVERTISE':os.environ['relay_advertise'],'BRIDGE_STATE_DB':os.environ['state_db'],
'BRIDGE_HOST_PYTHON':os.environ['SYSTEM_PYTHON'],'BRIDGE_POLYTOKEN_BIN':os.environ['POLYTOKEN_BIN'],
'BRIDGE_SESSIONS_DIR':os.environ['SESSIONS_DIR'],'BRIDGE_WORKSPACE_ROOT':os.environ['workspace'],
'BRIDGE_CONNECTOR_CONFIG':os.environ['CONNECTOR_CONFIG'],
'BRIDGE_POLYTOKEN_CONFIG_DIR':os.environ['POLYTOKEN_CONFIG_DIR'],
'BRIDGE_XDG_CONFIG_HOME':os.environ['XDG_CONFIG_HOME'],
'BRIDGE_XDG_DATA_HOME':os.environ['XDG_DATA_HOME'],
'BRIDGE_POLYTOKEN_CONFIG_DIRS':os.environ['CONFIG_ALLOWLIST'],
'BRIDGE_SPAWN_LAUNCHER':os.environ['SPAWN_LAUNCHER']}
seen=set(); out=[]
for line in lines:
 key=line.partition('=')[0]
 if key in updates:
  if key not in seen: out.append(key+'='+shlex.quote(updates[key])); seen.add(key)
 else: out.append(line)
for k,v in updates.items():
 if k not in seen: out.append(k+'='+shlex.quote(v))
p.parent.mkdir(parents=True,exist_ok=True)
fd,tmp=tempfile.mkstemp(dir=p.parent,prefix='.bridge-env-')
try:
 os.fchmod(fd,0o600)
 with os.fdopen(fd,'w') as f: f.write('\n'.join(out)+'\n')
 os.replace(tmp,p); os.chmod(p,0o600)
finally:
 if os.path.exists(tmp): os.unlink(tmp)
PY
export PLIST_HOME="$HOME" PLIST_REPO="$BRIDGE_REPO_DIR" PLIST_PYTHON="$SYSTEM_PYTHON" PLIST_WRAPPER="$BRIDGE_WRAPPER" PLIST_ENV="$ENV_FILE"
"$SYSTEM_PYTHON" - "$PLIST_SRC" "$PLIST_DST" <<'PY'
import os,pathlib,sys,tempfile,xml.etree.ElementTree as ET
src,dst=map(pathlib.Path,sys.argv[1:]); text=src.read_text()
for k in ('HOME','REPO','PYTHON','WRAPPER','ENV'):
 text=text.replace('@'+k+'@',os.environ['PLIST_'+k].replace('&','&amp;').replace('<','&lt;').replace('>','&gt;'))
ET.fromstring(text); dst.parent.mkdir(parents=True,exist_ok=True)
fd,tmp=tempfile.mkstemp(dir=dst.parent,prefix='.bridge-plist-')
with os.fdopen(fd,'w') as f:f.write(text)
os.chmod(tmp,0o644); os.replace(tmp,dst)
PY
if command -v launchctl >/dev/null 2>&1 && [ "${BRIDGE_SETUP_SKIP_LAUNCHCTL:-0}" != 1 ]; then
 launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
 launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
fi
say "installed native bridge; env preserves Discord credentials, IDs, and state DB"
