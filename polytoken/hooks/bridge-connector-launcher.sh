#!/usr/bin/env bash
# Detached exact-session launcher; installer writes the adjacent interpreter path.
set -u
CONFIG="${1:-${BRIDGE_CONNECTOR_CONFIG:-$HOME/.config/polytoken/discord-bridge/connector.json}}"
SID="${2:-${POLYTOKEN_SESSION_ID:-}}"
[ -n "$SID" ] || exit 0
PYTHON="${BRIDGE_CONNECTOR_SYSTEM_PYTHON:-}"
if [ -z "$PYTHON" ] && [ -r "$CONFIG.python" ]; then IFS= read -r PYTHON < "$CONFIG.python"; fi
case "$PYTHON" in /*) ;; *) exit 0;; esac
[ -x "$PYTHON" ] || exit 0
exec "$PYTHON" - "$CONFIG" "$SID" <<'PY'
import fcntl, json, os, re, subprocess, sys, time
from pathlib import Path
try:
 config=Path(sys.argv[1]); sid=sys.argv[2]
 if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}',sid): sys.exit(0)
 st=config.stat()
 if st.st_uid != os.getuid() or st.st_mode & 0o077: sys.exit(0)
 cfg=json.loads(config.read_text()); sessions=Path(cfg['sessions_dir'])
 python=cfg['connector_python']; relay=cfg['relay_address']; token=cfg['relay_token']
 if not sessions.is_absolute() or not Path(python).is_absolute() or not Path(python).is_file(): sys.exit(0)
 state=sessions/'discord-bridge'; state.mkdir(mode=0o700,parents=True,exist_ok=True)
 lock=open(state/(sid+'.lock'),'a'); os.chmod(lock.name,0o600)
 try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 except BlockingIOError: sys.exit(0)
 deadline=time.monotonic()+30
 while True:
  try:
   meta=json.loads((sessions/'sessions-v1'/sid/'startup.json').read_text())
   if meta.get('session_id') == sid and meta.get('state') == 'ready': break
  except (OSError,ValueError): pass
  if time.monotonic() >= deadline: sys.exit(0)
  time.sleep(.1)
 env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':os.environ.get('HOME',''),
      'BRIDGE_CONNECTOR_CONFIG':str(config),'POLYTOKEN_SESSION_ID':sid,
      'POLYTOKEN_SESSIONS_DIR':str(sessions)}
 log_path=state/(sid+'.log')
 with open(log_path,'a') as log:
  os.chmod(log_path,0o600)
  child=subprocess.Popen([python,'-m','discord_bridge.connector_main'],env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=log,close_fds=True)
  sys.exit(child.wait())
except SystemExit: raise
except Exception: sys.exit(0)  # Detached failure stays fail-open and secret-free.
PY
