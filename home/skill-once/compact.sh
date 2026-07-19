#!/bin/bash
set -euo pipefail
command -v dirname >/dev/null 2>&1 || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" 2>/dev/null || exit 0
# shellcheck source=state.sh
. "$SCRIPT_DIR/state.sh" 2>/dev/null || exit 0
trap skill_once_exit_cleanup EXIT
for cmd in cat jq; do command -v "$cmd" >/dev/null 2>&1 || exit 0; done
INPUT=$(cat 2>/dev/null) || exit 0
SESSION_ID=$(jq -r 'if type=="object" and (.session_id|type)=="string" then .session_id else empty end' <<<"$INPUT" 2>/dev/null) || exit 0
[ -n "$SESSION_ID" ] || exit 0
skill_once_init "$SESSION_ID" || exit 0
skill_once_lock "${SKILL_ONCE_TEST_OP_ID:-compact}" || exit 0
skill_once_clear || exit 0
exit 0
