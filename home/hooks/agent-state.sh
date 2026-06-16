#!/bin/bash
# Writes the agent's current activity state to a flag file the statusLine reads.
# Registered on multiple hook events; derives state from hook_event_name.
#   UserPromptSubmit / PreToolUse / PostToolUse / SubagentStop -> working
#   Stop                                                       -> idle
# The statusLine renders a colored badge from this. Permission/question states
# are intentionally omitted — Claude hides the status line during permission
# prompts, so they could never display.

STATE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.agent-state"

EVENT=""
if command -v jq >/dev/null 2>&1; then
  EVENT=$(jq -r '.hook_event_name // ""' 2>/dev/null)
fi

case "$EVENT" in
  Stop)        STATE=idle ;;
  UserPromptSubmit|PreToolUse|PostToolUse|SubagentStart|SubagentStop|Notification)
               STATE=working ;;
  *)           STATE=working ;;
esac

# Atomic-ish write; restrict perms.
printf '%s' "$STATE" > "$STATE_FILE.tmp" 2>/dev/null && mv -f "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null
chmod 600 "$STATE_FILE" 2>/dev/null
exit 0
