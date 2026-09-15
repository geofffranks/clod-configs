#!/usr/bin/env bash
# macOS Notification Center sender for the agent-notify / watchdog family.
# Sourced (never executed). Bash 3.2-safe (macOS system bash).
#
# Design: this is a credential-free, mac-only complement to the optional
# Pushover sender. It is ON by default when running natively on a real macOS
# host (Darwin + /usr/bin/osascript present) and AGENT_NOTIFY_MAC is not "0".
# Everywhere else it is inert — a no-op that returns 0 and never blocks.
#
# Fail-open contract: notify_mac_send always returns 0. It posts to the local
# Notification Center when available; otherwise (non-macOS, the Linux Docker
# container, osascript stripped, or AGENT_NOTIFY_MAC=0) it is a silent no-op.
set -u

# Computed once at source time. A single guard covers non-macOS, the Linux
# container, and stripped environments: osascript exists only on a real macOS
# GUI host, so checking `command -v osascript` (not `uname` alone) at the call
# site is the whole gate.
_notify_mac_ok=0
if [ "${AGENT_NOTIFY_MAC:-1}" != "0" ] \
   && [ "$(uname 2>/dev/null)" = "Darwin" ] \
   && command -v osascript >/dev/null 2>&1; then
  _notify_mac_ok=1
fi

# Predicate used by callers to loosen their otherwise credential-only gates:
# returns 0 (available) when the mac lane is enabled and usable.
notify_mac_available() {
  [ "${_notify_mac_ok:-0}" = "1" ]
}

# _notify_mac_terminal_bundle — detect a running terminal app and return its bundle ID.
# Checks known terminals in preference order; falls back to com.apple.Terminal (always
# present on macOS). Sets AGENT_NOTIFY_TERMINAL_BUNDLE to override auto-detection.
_notify_mac_terminal_bundle() {
  [ -n "${AGENT_NOTIFY_TERMINAL_BUNDLE:-}" ] && {
    printf '%s\n' "$AGENT_NOTIFY_TERMINAL_BUNDLE"; return 0
  }
  local name bundle
  while IFS='|' read -r name bundle; do
    pgrep -x "$name" >/dev/null 2>&1 && { printf '%s\n' "$bundle"; return 0; }
  done <<'TERMINALS'
Ghostty|com.mitchellh.ghostty
kitty|net.kovidgoyal.kitty
iTerm2|com.googlecode.iterm2
Terminal|com.apple.Terminal
TERMINALS
  # No terminal detected; fall back to Terminal.app which is always installed.
  printf '%s\n' "com.apple.Terminal"
  return 0
}

# _notify_mac_script — path to the stable named AppleScript file.
# A fixed, persistent file avoids the temp-GUID-file problem: when osascript
# reads from stdin (`-`) macOS creates a new UUID-named temp .scpt on every
# call, associates the notification with Script Editor + that GUID file, and
# clicking the notification opens Script Editor with a now-gone temp script.
# Using a stable named file lets macOS remember the permission grant and gives
# the notification a consistent click-target.
_notify_mac_script="${XDG_DATA_HOME:-$HOME/.local/share}/agent-notify/notify.applescript"

# _notify_mac_ensure_script — idempotent: write the script file once.
_notify_mac_ensure_script() {
  [ -f "$_notify_mac_script" ] && return 0
  local dir
  dir="$(dirname "$_notify_mac_script")"
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || true
  printf '%s\n' \
    'on run argv' \
    '  display notification (item 2 of argv) with title (item 1 of argv)' \
    'end run' \
    > "$_notify_mac_script" 2>/dev/null || return 1
  chmod 600 "$_notify_mac_script" 2>/dev/null || true
  return 0
}

# notify_mac_send <title> <body> — post to Notification Center, always 0.
notify_mac_send() {
  local title="${1:-}" body="${2:-}" perl_bin="" rc=0
  [ "${_notify_mac_ok:-0}" = "1" ] || return 0
  # No content, no alert (also keeps the notify-send.sh self-execute path a
  # silent no-op when called with unset title/body).
  [ -n "$title" ] || [ -n "$body" ] || return 0
  # Bounded send. macOS ships no `timeout`, so every invocation runs under a
  # perl alarm(5) backstop. SIGALRM persists across exec (POSIX), so a wedged
  # process is killed at 5s and can never hang the caller.
  perl_bin="$(command -v perl 2>/dev/null || true)"
  [ -n "$perl_bin" ] || return 0

  # Prefer terminal-notifier when available: it sends the notification with the
  # terminal app's icon (-sender) and activates the terminal on click (-activate),
  # matching Claude Code's built-in notification behavior as closely as possible.
  local tn_bin bundle
  tn_bin="$(command -v terminal-notifier 2>/dev/null || true)"
  if [ -n "$tn_bin" ]; then
    bundle="$(_notify_mac_terminal_bundle)"
    "$perl_bin" -e 'alarm 5; exec @ARGV' \
      "$tn_bin" -title "$title" -message "$body" \
      -sender "$bundle" -activate "$bundle" \
      2>/dev/null
    return 0
  fi

  # Fallback: stable named AppleScript file. A fixed path avoids the macOS
  # temp-GUID association that links the notification to Script Editor and an
  # already-deleted temp .scpt on every click.
  _notify_mac_ensure_script || return 0
  "$perl_bin" -e 'alarm 5; exec @ARGV' osascript "$_notify_mac_script" "$title" "$body" \
    2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if command -v notify_diag >/dev/null 2>&1 && [ -n "${notify_source:-}" ]; then
      notify_diag mac-failed >/dev/null 2>&1 || true
    fi
  fi
  return 0
}
