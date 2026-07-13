#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/scripts/fixtures/polytoken-hooks"

for f in pre-tool-shell-exec pre-tool-file-read pre-tool-skill post-compaction; do
  jq -e . "$FIX/$f.json" >/dev/null
done

PRE_TOOL_CONTRACT='
  (keys | sort) == ["call_id", "event", "input", "matcher_subject", "prompt_id", "tool_name"]
  and .event == "pre_tool_use"
  and (.prompt_id | type == "string" and length > 0)
  and (.call_id | type == "string" and length > 0)
'

jq -e "$PRE_TOOL_CONTRACT
  and .matcher_subject == \"shell_exec\"
  and .tool_name == \"shell_exec\"
  and (.input | keys | sort) == [\"command\", \"timeout_seconds\"]
  and .input.command == \"printf task1\"
  and .input.timeout_seconds == 30
" "$FIX/pre-tool-shell-exec.json" >/dev/null

jq -e "$PRE_TOOL_CONTRACT
  and .matcher_subject == \"file_read\"
  and .tool_name == \"file_read\"
  and (.input | keys | sort) == [\"limit\", \"max_bytes\", \"mode\", \"offset\", \"path\"]
  and (.input.path | type == \"string\" and endswith(\"/scripts/test-polytoken-contracts.sh\"))
  and .input.offset == 0
  and .input.limit == 200
  and .input.max_bytes == 32000
  and .input.mode == \"default\"
" "$FIX/pre-tool-file-read.json" >/dev/null

jq -e "$PRE_TOOL_CONTRACT
  and .matcher_subject == \"skill\"
  and .tool_name == \"skill\"
  and (.input | keys) == [\"name\"]
  and .input.name == \"using-superpowers\"
" "$FIX/pre-tool-skill.json" >/dev/null

jq -e '
  (keys | sort) == ["event", "matcher_subject"]
  and .event == "post_compaction"
  and .matcher_subject == "post_compaction"
' "$FIX/post-compaction.json" >/dev/null

printf 'polytoken contract fixtures: PASS\n'
