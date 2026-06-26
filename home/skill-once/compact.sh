#!/bin/bash
# skill-once: PostCompact hook — clears the session skill-load cache after a
# context compaction. Compaction drops skill bodies from context, so after it
# every skill must be reloadable. This resets the cache that hook.sh maintains.
#
# Install: Add to .claude/settings.json hooks.PostCompact
# See also: hook.sh (the PreToolUse hook that tracks skill loads)

set -euo pipefail

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

CACHE_DIR="${HOME}/.claude/skill-once"

if command -v sha256sum >/dev/null 2>&1; then
  SESSION_HASH=$(echo -n "$SESSION_ID" | sha256sum | cut -c1-16)
else
  SESSION_HASH=$(echo -n "$SESSION_ID" | shasum -a 256 | cut -c1-16)
fi

CACHE_FILE="${CACHE_DIR}/session-${SESSION_HASH}.jsonl"
STATS_FILE="${CACHE_DIR}/stats.jsonl"

CLEARED=0
if [ -f "$CACHE_FILE" ]; then
  CLEARED=$(wc -l < "$CACHE_FILE" | tr -d ' ')
  rm -f "$CACHE_FILE"
fi

NOW=$(date +%s)
if [ "$CLEARED" -gt 0 ]; then
  echo "{\"ts\":${NOW},\"session\":\"${SESSION_HASH}\",\"event\":\"compact\",\"cleared\":${CLEARED}}" >> "$STATS_FILE"
fi

exit 0
