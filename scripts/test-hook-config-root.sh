#!/usr/bin/env bash
# Root-isolation test: the canonical read-once/skill-once hooks must honor
# AGENT_CONFIG_DIR and write cache files ONLY beneath it, never beneath
# $HOME/.claude. Both compact scripts must also honor AGENT_CONFIG_DIR.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/config"
printf 'content\n' > "$TMP/input.txt"

# Canonical Claude-shaped payloads
read_payload=$(jq -nc --arg p "$TMP/input.txt" '{tool_name:"Read",session_id:"root-test",tool_input:{file_path:$p}}')
printf '%s' "$read_payload" | HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" bash "$ROOT/home/read-once/hook.sh" >/dev/null

skill_pre_payload='{"hook_event_name":"PreToolUse","tool_name":"Skill","session_id":"root-test","tool_input":{"skill":"doc-writing","args":""}}'
skill_post_payload='{"hook_event_name":"PostToolUse","tool_name":"Skill","session_id":"root-test","tool_input":{"skill":"doc-writing","args":""}}'
printf '%s' "$skill_pre_payload" | HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" bash "$ROOT/home/skill-once/hook.sh" >/dev/null
test -z "$(find "$TMP/config/skill-once" -name 'session-*.jsonl' -print -quit 2>/dev/null)"
printf '%s' "$skill_post_payload" | HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" bash "$ROOT/home/skill-once/hook.sh" >/dev/null

# Cache dirs and session files appear only under AGENT_CONFIG_DIR after actual writes.
test -d "$TMP/config/read-once"
test -d "$TMP/config/skill-once"
test ! -e "$TMP/home/.claude/read-once"
test ! -e "$TMP/home/.claude/skill-once"
test -n "$(find "$TMP/config/read-once" -name 'session-*.jsonl' 2>/dev/null)"
test -n "$(find "$TMP/config/skill-once" -name 'session-*.jsonl' 2>/dev/null)"

compact_payload='{"session_id":"root-test"}'
printf '%s' "$compact_payload" | HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" bash "$ROOT/home/read-once/compact.sh" >/dev/null
printf '%s' "$compact_payload" | HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" bash "$ROOT/home/skill-once/compact.sh" >/dev/null

# Session cache entries are now gone beneath AGENT_CONFIG_DIR
test -z "$(find "$TMP/config/read-once" -name 'session-*.jsonl' 2>/dev/null)"
test -z "$(find "$TMP/config/skill-once" -name 'session-*.jsonl' 2>/dev/null)"

# Relative sibling sourcing works from an unrelated cwd and a path containing spaces.
mkdir -p "$TMP/copied dir/skill-once" "$TMP/config-copy"
cp "$ROOT/home/skill-once/"{hook.sh,compact.sh,state.sh} "$TMP/copied dir/skill-once/"
(
  cd /tmp
  printf '%s' "$skill_post_payload" | HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config-copy" bash "$TMP/copied dir/skill-once/hook.sh"
  test -n "$(find "$TMP/config-copy/skill-once" -name 'session-*.jsonl' -print -quit)"
  printf '%s' "$compact_payload" | HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config-copy" bash "$TMP/copied dir/skill-once/compact.sh"
  test -z "$(find "$TMP/config-copy/skill-once" -name 'session-*.jsonl' -print -quit)"
)

printf 'hook config root: PASS\n'
