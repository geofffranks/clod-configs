#!/usr/bin/env bash
# Loader/frontmatter checks only; prompt adherence is content/scenario review.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
command -v polytoken >/dev/null
command -v yq >/dev/null
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
count=0
for f in polytoken/subagents/*.md; do
  polytoken validate subagent "$ROOT/$f"
  awk 'NR==1 && $0=="---"{next} /^---$/{exit} {print}' "$f" > "$T/frontmatter.yaml"
  test "$(yq -r '.name' "$T/frontmatter.yaml")" = "$(basename "$f" .md)"
  test "$(yq -r '.polytoken.allow_subagent_spawn' "$T/frontmatter.yaml")" = false
  count=$((count + 1))
done
test "$count" -eq 16
for name in review-adversarial review-correctness review-completeness review-maintainability review-general review-abstraction; do
  awk 'NR==1 && $0=="---"{next} /^---$/{exit} {print}' "polytoken/subagents/$name.md" > "$T/frontmatter.yaml"
  yq -o=json '.polytoken.exit_tool_schema' "$T/frontmatter.yaml" > "$T/schema.json"
  # Snapshot-specific schema fields remain conditional, not ordinary-delivery prerequisites.
  jq -e '.required == ["verdict","findings","limitations"] and
    (.then.required | index("snapshot_digest") != null) and
    (.then.required | index("head_sha") != null) and
    (.then.required | index("scope_id") != null) and
    (.then.properties.findings.items.required | index("provenance") != null)' "$T/schema.json" >/dev/null
done
# Official loader rejects mismatched names; no executable prompt-policy replica.
printf '%s\n' '---' 'name: wrong-name' '---' 'Test definition.' > "$T/mismatched.md"
if polytoken validate subagent "$T/mismatched.md" > "$T/negative.log" 2>&1; then
  echo 'FAIL: mismatched definition name accepted' >&2; exit 1
fi
echo "PASS: $count subagents parsed; no nested spawning; snapshot schema conditional; invalid name rejected"
