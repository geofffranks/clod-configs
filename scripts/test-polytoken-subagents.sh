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
test "$count" -eq 22
for f in polytoken/subagents/snapshot-review-*.md; do
  awk 'NR==1 && $0=="---"{next} /^---$/{exit} {print}' "$f" > "$T/frontmatter.yaml"
  yq -o=json '.polytoken' "$T/frontmatter.yaml" > "$T/snapshot.json"
  jq -e '.tools == ["file_read","glob","grep","skill"] and
    .undeferred_tools == .tools and .allow_subagent_spawn == false and
    .skills_allow == ["github-review-snapshot","code-review-evidence","polytoken:investigating-a-codebase","polytoken:modifying-polytoken","receiving-code-review"] and
    .skills_deny == [] and
    (.exit_tool_schema.required | index("source_revision") != null) and
    (.exit_tool_schema.required | index("scope_id") != null) and
    (.exit_tool_schema.required | index("evidence") != null) and
    (.exit_tool_schema.required | index("review_run_id") != null) and
    (.exit_tool_schema.required | index("snapshot_digest") != null) and
    (.exit_tool_schema.required | index("head_sha") != null) and
    (.exit_tool_schema.properties.findings.items.required | index("provenance") != null)' "$T/snapshot.json" >/dev/null
done
for name in review-adversarial review-correctness review-completeness review-maintainability review-general review-abstraction; do
  awk 'NR==1 && $0=="---"{next} /^---$/{exit} {print}' "polytoken/subagents/$name.md" > "$T/frontmatter.yaml"
  test "$(yq -r '.polytoken.tools | join(",")' "$T/frontmatter.yaml")" = 'tag!ALL,mcp__ratatoskr'
  test "$(yq -r '.polytoken.undeferred_tools | contains(["shell_exec"])' "$T/frontmatter.yaml")" = true
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
