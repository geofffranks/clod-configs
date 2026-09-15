#!/usr/bin/env bash
# Install (or remove) the Polytoken session watchdog as a macOS LaunchAgent.
#
# The watchdog (home/session-watchdog.sh) pings Pushover when a Polytoken
# session's daemon dies while the session was recently active — daemon death
# kills in-flight turns without firing any hook, so a host-side watcher is the
# only reliable capture point. See the script header for the design.
#
# usage: install-session-watchdog.sh [--print] [--uninstall]
#   --print      render the LaunchAgent plist to stdout and exit (no install)
#   --uninstall  unload and remove the LaunchAgent
#
# Credentials: PUSHOVER_APP_TOKEN and PUSHOVER_USER_KEY are inherited from the
# invoking shell when set (baked into the plist, chmod 600). Without them the
# installer wires an env file instead and prints how to create it:
#   ~/.config/polytoken/watchdog.env   (sourced by the watchdog every scan)
set -euo pipefail

LABEL="dev.gf.polytoken-session-watchdog"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_SRC="$SELF_DIR/home/session-watchdog.sh"
PLIST_SRC="$SELF_DIR/launchd/$LABEL.plist"
SCRIPT_DST="${HOME}/.claude/session-watchdog.sh"
MAC_MODULE_SRC="$SELF_DIR/home/lib/notify-mac.sh"
MAC_MODULE_DST="${HOME}/.claude/lib/notify-mac.sh"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
ENV_FILE="${HOME}/.config/polytoken/watchdog.env"
LOG_FILE="${HOME}/Library/Logs/polytoken-session-watchdog.log"

action="install"
case "${1:-}" in
  --print) action="print" ;;
  --uninstall) action="uninstall" ;;
  "") ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

render_plist() {
  local envvars=""
  if [ -n "${PUSHOVER_APP_TOKEN:-}" ] && [ -n "${PUSHOVER_USER_KEY:-}" ]; then
    envvars="$(printf '    <key>PUSHOVER_APP_TOKEN</key>\n    <string>%s</string>\n    <key>PUSHOVER_USER_KEY</key>\n    <string>%s</string>\n' \
      "${PUSHOVER_APP_TOKEN}" "${PUSHOVER_USER_KEY}")"
  fi
  awk -v home="$HOME" -v envvars="$envvars" '
    { gsub(/@HOME@/, home)
      if ($0 ~ /@ENVPVARS@/) printf "%s", envvars; else print }' "$PLIST_SRC"
}

uninstall() {
  launchctl unload "$PLIST_DST" 2>/dev/null || true
  rm -f "$PLIST_DST"
  echo "removed $PLIST_DST (watchdog script and logs left in place)"
}

[ -f "$SCRIPT_SRC" ] || { echo "missing $SCRIPT_SRC" >&2; exit 1; }
[ -f "$PLIST_SRC" ] || { echo "missing $PLIST_SRC" >&2; exit 1; }

case "$action" in
  print)
    render_plist
    exit 0
    ;;
  uninstall)
    uninstall
    exit 0
    ;;
esac

# Install the watchdog script at the path the plist references (install.sh
# also copies it on every --target claude run; this keeps them in sync).
mkdir -p "$(dirname "$SCRIPT_DST")"
cp "$SCRIPT_SRC" "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"

# Also copy the credential-free mac Notification Center module so the
# watchdog-only install (no ~/.claude/lib from a full claude install) can
# resolve it from the sibling lib dir.
mkdir -p "$(dirname "$MAC_MODULE_DST")"
cp "$MAC_MODULE_SRC" "$MAC_MODULE_DST"

mkdir -p "$(dirname "$PLIST_DST")" "$(dirname "$LOG_FILE")"
if [ -z "${PUSHOVER_APP_TOKEN:-}" ] || [ -z "${PUSHOVER_USER_KEY:-}" ]; then
  echo "PUSHOVER_APP_TOKEN / PUSHOVER_USER_KEY not in environment."
  echo "The watchdog will read them from: $ENV_FILE"
  echo "Create it with (chmod 600):"
  echo "  printf 'PUSHOVER_APP_TOKEN=<app token>\nPUSHOVER_USER_KEY=<user key>\n' > $ENV_FILE && chmod 600 $ENV_FILE"
else
  echo "Baking Pushover credentials from the environment into the plist (chmod 600)."
  echo "They can be rotated later via $ENV_FILE instead."
fi

render_plist > "$PLIST_DST"
chmod 600 "$PLIST_DST"

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load -w "$PLIST_DST"

echo "installed: $PLIST_DST"
echo "watchdog:  $SCRIPT_DST (scans every 30s; first scan only records state)"
echo "logs:      $LOG_FILE"
echo "state:     ~/.local/share/polytoken/.session-watchdog/"
