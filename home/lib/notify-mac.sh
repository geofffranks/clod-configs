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

# notify_mac_send <title> <body> — post to Notification Center, always 0.
notify_mac_send() {
  local title="${1:-}" body="${2:-}" perl_bin="" rc=0
  [ "${_notify_mac_ok:-0}" = "1" ] || return 0
  # No content, no alert (also keeps the notify-send.sh self-execute path a
  # silent no-op when called with unset title/body).
  [ -n "$title" ] || [ -n "$body" ] || return 0
  # Bounded send. macOS ships no `timeout`, so every osascript invocation runs
  # under a perl alarm(5) backstop. SIGALRM persists across exec (POSIX), so a
  # wedged osascript is killed at 5s and can never hang the caller (or extend
  # the agent-notify/watchdog lock longer than the existing bounded windows).
  perl_bin="$(command -v perl 2>/dev/null || true)"
  [ -n "$perl_bin" ] || return 0
  # argv + here-doc: title/body travel as osascript argv items (no shell or
  # AppleScript quoting needed) and sanitized text is already quote-safe.
  "$perl_bin" -e 'alarm 5; exec @ARGV' osascript - "$title" "$body" \
    <<'APPLESCRIPT' 2>/dev/null
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # Reuse the existing rotated notify.log (no new log file) only when the
    # diagnostic harness is present and a source is identified.
    if command -v notify_diag >/dev/null 2>&1 && [ -n "${notify_source:-}" ]; then
      notify_diag mac-failed >/dev/null 2>&1 || true
    fi
  fi
  return 0
}
