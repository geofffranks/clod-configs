#!/usr/bin/env bash
# Install/remove the Jira dispatcher LaunchAgent; activation is operator-owned.
# usage: install-jira-dispatcher.sh [--print | --uninstall]
set -euo pipefail

LABEL="dev.gf.polytoken-jira-dispatcher"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_SRC="$SELF_DIR/jira-dispatcher"
PLIST_SRC="$SELF_DIR/launchd/$LABEL.plist"
DATA_DIR="$HOME/.local/share/polytoken/jira-dispatcher"
LIB_DIR="$DATA_DIR/lib"
CONFIG="$DATA_DIR/config.json"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_FILE="$HOME/Library/Logs/polytoken-jira-dispatcher.log"

[ "$#" -le 1 ] || { echo "usage: $0 [--print | --uninstall]" >&2; exit 2; }
action="install"
case "${1:-}" in
  --print) action="print" ;;
  --uninstall) action="uninstall" ;;
  "") ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

render_plist() {
  # Escape XML text, including home paths containing ampersands.
  local home="$HOME"
  home="${home//&/\&amp;}"
  home="${home//</\&lt;}"
  home="${home//>/\&gt;}"
  awk -v home="$home" '{
    line=$0; rendered=""
    while ((pos=index(line, "@HOME@")) > 0) {
      rendered=rendered substr(line, 1, pos-1) home
      line=substr(line, pos+6)
    }
    print rendered line
  }' "$PLIST_SRC"
}

if [ "$action" = "uninstall" ]; then
  command -v launchctl >/dev/null || { echo "missing dependency: launchctl" >&2; exit 1; }
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST_DST" 2>/dev/null || true
  rm -f "$PLIST_DST"
  echo "removed: $PLIST_DST (runtime, config, state, worker sessions and logs retained)"
  exit 0
fi
[ -f "$PLIST_SRC" ] || { echo "missing $PLIST_SRC" >&2; exit 1; }
if [ "$action" = "print" ]; then
  render_plist
  exit 0
fi

# Fail before installation if any required executable or runtime source is absent.
for dependency in python3 git polytoken launchctl plutil; do
  command -v "$dependency" >/dev/null || { echo "missing dependency: $dependency" >&2; exit 1; }
done
for source in dispatcher.py config.py DESIGN.md README.md; do
  [ -f "$RUNTIME_SRC/$source" ] || { echo "missing $RUNTIME_SRC/$source" >&2; exit 1; }
done

mkdir -p "$LIB_DIR" "$(dirname "$PLIST_DST")" "$(dirname "$LOG_FILE")"
for source in "$RUNTIME_SRC"/*.py "$RUNTIME_SRC/DESIGN.md" "$RUNTIME_SRC/README.md"; do
  cp "$source" "$LIB_DIR/"
done
# Use the runtime's own default schema. Never overwrite an operator config.
if [ ! -e "$CONFIG" ]; then
  python3 "$LIB_DIR/dispatcher.py" init-config
  [ -f "$CONFIG" ] || { echo "init-config did not create $CONFIG" >&2; exit 1; }
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if c.get("active") is False else "default config must be inactive")' "$CONFIG"
fi

render_plist > "$PLIST_DST"
chmod 600 "$PLIST_DST"
plutil -lint "$PLIST_DST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

echo "installed: $PLIST_DST"
echo "runtime:   $LIB_DIR"
echo "config:    $CONFIG (existing configuration preserved)"
echo "logs:      $LOG_FILE"
echo "Install is not activation. The dispatcher must stay inactive until you explicitly activate it."
echo "First run: python3 \"$LIB_DIR/dispatcher.py\" preflight"
echo "Activation: edit \"$CONFIG\" and set the JSON field \"active\" to true."
echo "Source merge, installation and operational activation are separate actions."
