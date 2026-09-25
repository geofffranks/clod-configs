#!/usr/bin/env bash
# Source lint only; inventory, exception rationale and limits are adjacent.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/jira-workflow-source-lint.py" "$ROOT" "$@"
