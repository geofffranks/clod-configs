#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/scripts/fixtures/polytoken-hooks"
for f in pre-tool-shell-exec pre-tool-file-read pre-tool-skill post-compaction; do
  jq -e . "$FIX/$f.json" >/dev/null
done
jq -e '.event == "pre_tool_use" and .tool_name == "shell_exec" and (.input.command | type == "string")' "$FIX/pre-tool-shell-exec.json" >/dev/null
jq -e '.event == "pre_tool_use" and .tool_name == "file_read" and (.input.path | type == "string")' "$FIX/pre-tool-file-read.json" >/dev/null
jq -e '.event == "pre_tool_use" and .tool_name == "skill" and (.input.name | type == "string")' "$FIX/pre-tool-skill.json" >/dev/null
jq -e '.event == "post_compaction"' "$FIX/post-compaction.json" >/dev/null
printf 'polytoken contract fixtures: PASS\n'
