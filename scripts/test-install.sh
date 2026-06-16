#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Seed a pre-existing settings.json WITH a permissions block to prove it survives.
cat > "$TMP/settings.json" <<'JSON'
{ "permissions": { "allow": ["Bash(echo:*)"] }, "theme": "light" }
JSON

CLAUDE_CONFIG_DIR="$TMP" "$REPO/install.sh"

echo "--- assertions ---"
test -f "$TMP/statusline.sh"                       && echo "ok: statusline copied"
test -f "$TMP/bash-guard/hook.sh"                  && echo "ok: guard hook copied"
test -x "$TMP/hooks/agent-state.sh"                && echo "ok: hook executable"
test ! -f "$TMP/settings.recommended.json"         && echo "ok: fragment not copied verbatim"
jq -e '.permissions.allow[0] == "Bash(echo:*)"' "$TMP/settings.json" >/dev/null \
                                                   && echo "ok: existing permissions preserved"
jq -e '.env.ANTHROPIC_MODEL == "opus"' "$TMP/settings.json" >/dev/null \
                                                   && echo "ok: env merged"
jq -e '.hooks.PreToolUse | length == 6' "$TMP/settings.json" >/dev/null \
                                                   && echo "ok: hooks merged"
ls "$TMP"/settings.json.bak-* >/dev/null 2>&1      && echo "ok: settings backed up"
echo "ALL PASS"
