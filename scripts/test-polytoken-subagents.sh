#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
command -v yq >/dev/null || { echo "yq is required" >&2; exit 1; }

files=(implementer reviewer validator researcher plan-reviewer plan-writer)
declare -A expected_model=(
  [implementer]='<polytoken-ref type="model" name="codex/gpt-5.6-luna(medium)"/>'
  [reviewer]='<polytoken-ref type="model" name="codex/gpt-5.6-sol(medium)"/>'
  [validator]='<polytoken-ref type="model" name="zai/glm-5.2(high)"/>'
  [researcher]='<polytoken-ref type="model" name="codex/gpt-5.6-sol(medium)"/>'
  [plan-reviewer]='<polytoken-ref type="model" name="zai/glm-5.2(high)"/>'
  [plan-writer]='<polytoken-ref type="model" name="codex/gpt-5.6-luna(medium)"/>'
)
declare -A expected_tools=(
  [implementer]='[file_read, file_write, file_edit_search_replace, glob, grep, shell_exec]'
  [reviewer]='[file_read, glob, grep]'
  [validator]='[file_read, glob, grep, shell_exec, file_write]'
  [researcher]='[file_read, grep, glob, web_search, web_fetch]'
  [plan-reviewer]='[file_read, glob, grep]'
  [plan-writer]='[file_read, file_write, file_edit_search_replace, glob, grep]'
)
declare -A expected_undeferred=(
  [implementer]='[file_read, file_write, file_edit_search_replace, glob, grep, shell_exec]'
  [reviewer]='[file_read, glob, grep]'
  [validator]='[file_read, glob, grep, shell_exec, file_write]'
  [researcher]='[grep, glob, web_search, web_fetch]'
  [plan-reviewer]='[file_read, glob, grep]'
  [plan-writer]='[file_read, file_write, file_edit_search_replace, glob, grep]'
)
declare -A expected_required=(
  [implementer]='[status, summary]'
  [reviewer]='[verdict, summary]'
  [validator]='[verdict, summary]'
  [researcher]='[summary, files, sources]'
  [plan-reviewer]='[verdict, summary, report_file]'
  [plan-writer]='[status, summary, plan_file, files_considered, open_questions]'
)
declare -A expected_enum_fields=(
  [implementer]='status=DONE,DONE_WITH_CONCERNS,BLOCKED,NEEDS_CONTEXT'
  [reviewer]='verdict=approved,needs_fixes spec_compliance=compliant,issues_found'
  [validator]='verdict=pass,fail,partial'
  [plan-reviewer]='verdict=approved,needs_fixes'
  [plan-writer]='status=DONE,DONE_WITH_CONCERNS,BLOCKED,NEEDS_CONTEXT'
)
declare -A expected_properties=(
  [implementer]='commits concerns report_file status summary test_summary'
  [reviewer]='report_file spec_compliance summary verdict'
  [validator]='report_file summary verdict'
  [researcher]='files sources summary'
  [plan-reviewer]='report_file summary verdict'
  [plan-writer]='files_considered open_questions plan_file status summary'
)

for persona in "${files[@]}"; do
  path="polytoken/subagents/$persona.md"
  [[ -f "$path" ]] || { echo "missing persona: $path" >&2; exit 1; }
  frontmatter=$(mktemp)
  trap 'rm -f "$frontmatter"' EXIT
  [[ "$(grep -c '^---$' "$path")" == 2 ]] || { echo "$persona: expected one frontmatter delimiter pair" >&2; exit 1; }
  [[ "$(sed -n '1p' "$path")" == '---' ]] || { echo "$persona: missing opening frontmatter delimiter" >&2; exit 1; }
  [[ "$(sed -n '2,/^---$/p' "$path" | tail -n 1)" == '---' ]] || { echo "$persona: missing closing frontmatter delimiter" >&2; exit 1; }
  sed -n '2,/^---$/p' "$path" | sed '$d' > "$frontmatter"
  yq -e '.' "$frontmatter" >/dev/null || { echo "$persona: malformed YAML" >&2; exit 1; }
  MODEL_NODES=$(FRONTMATTER="$frontmatter" python3 - <<'PY'
from pathlib import Path
import os
count = 0
stack = []
for raw in Path(os.environ['FRONTMATTER']).read_text().splitlines():
    if not raw.strip() or raw.lstrip().startswith('#'):
        continue
    indent = len(raw) - len(raw.lstrip(' '))
    key, sep, _ = raw.strip().partition(':')
    if not sep:
        continue
    key = key.strip().strip('"\'')
    while stack and stack[-1][0] >= indent:
        stack.pop()
    path = '.'.join(item[1] for item in stack + [(indent, key)])
    if path == 'polytoken.model':
        count += 1
    if raw.rstrip().endswith(':'):
        stack.append((indent, key))
print(count)
PY
)
  [[ "$MODEL_NODES" == 1 ]] || { echo "$persona: expected exactly one structural polytoken.model node, got $MODEL_NODES" >&2; exit 1; }
  model=$(yq -r '.polytoken.model' "$frontmatter")
  [[ "$model" == "${expected_model[$persona]}" ]] || { echo "$persona: unexpected model: $model" >&2; exit 1; }
  MODEL="$model" python3 - <<'PY'
import os, re
pattern = r'<polytoken-ref type="model" name="[a-z0-9._-]+/[a-z0-9._-]+(?:\([a-z0-9._-]+\))?"/>'
assert re.fullmatch(pattern, os.environ["MODEL"]), os.environ["MODEL"]
PY
  tools=$(yq -o=json -I=0 '.polytoken.tools' "$frontmatter")
  undeferred=$(yq -o=json -I=0 '.polytoken.undeferred_tools' "$frontmatter")
  expected_tools_json=$(printf '%s\n' "${expected_tools[$persona]}" | yq -o=json -I=0 '.')
  expected_undeferred_json=$(printf '%s\n' "${expected_undeferred[$persona]}" | yq -o=json -I=0 '.')
  [[ "$tools" == "$expected_tools_json" ]] || { echo "$persona: tools contract mismatch" >&2; exit 1; }
  [[ "$undeferred" == "$expected_undeferred_json" ]] || { echo "$persona: undeferred tools contract mismatch" >&2; exit 1; }
  [[ "$(yq -r '.polytoken.allow_subagent_spawn | tostring' "$frontmatter")" == false ]] || { echo "$persona: spawn must be false" >&2; exit 1; }
  case "$persona" in
    researcher) expected_skills='[tag!research]' ;;
    plan-writer) expected_skills='[writing-plans]' ;;
    *) expected_skills='[]' ;;
  esac
  [[ "$(yq -o=json -I=0 '.polytoken.skills_allow' "$frontmatter")" == "$(printf '%s\n' "$expected_skills" | yq -o=json -I=0 '.')" ]] || { echo "$persona: skills_allow contract mismatch" >&2; exit 1; }
  [[ "$(yq -o=json -I=0 '.polytoken.skills_deny' "$frontmatter")" == '[]' ]] || { echo "$persona: skills_deny contract mismatch" >&2; exit 1; }
  schema='.polytoken.exit_tool_schema'
  [[ "$(yq -r "$schema.type" "$frontmatter")" == object && "$(yq -r "$schema.additionalProperties | tostring" "$frontmatter")" == false ]] || { echo "$persona: schema is not closed object" >&2; exit 1; }
  [[ "$(yq -o=json -I=0 "$schema.required" "$frontmatter")" == "$(printf '%s\n' "${expected_required[$persona]}" | yq -o=json -I=0 '.')" ]] || { echo "$persona: required schema mismatch" >&2; exit 1; }
  actual_properties=$(yq -r "$schema.properties | keys | sort | join(\" \")" "$frontmatter")
  [[ "$actual_properties" == "${expected_properties[$persona]}" ]] || { echo "$persona: property set mismatch: $actual_properties" >&2; exit 1; }
  while read -r field; do [[ "$(yq -r "$schema.properties.$field.type" "$frontmatter")" == string ]] || { echo "$persona: $field must be string" >&2; exit 1; }; done < <(yq -r "$schema.properties | keys[]" "$frontmatter" | grep -E '^(status|summary|verdict|plan_file|spec_compliance|test_summary|concerns|report_file)$')
  while read -r field; do [[ "$(yq -r "$schema.properties.$field.type" "$frontmatter")" == array ]] || { echo "$persona: $field must be array" >&2; exit 1; }; [[ "$(yq -r "$schema.properties.$field.items.type" "$frontmatter")" == string ]] || { echo "$persona: $field items must be string" >&2; exit 1; }; done < <(yq -r "$schema.required[]" "$frontmatter" | grep -E '^(files|sources|commits|files_considered|open_questions)$' || true)
  for enum_field in ${expected_enum_fields[$persona]:-}; do
    field=${enum_field%%=*}
    expected_enum=${enum_field#*=}
    actual=$(yq -r "$schema.properties.$field.enum | join(\",\")" "$frontmatter")
    [[ "$actual" == "$expected_enum" ]] || { echo "$persona: $field enum mismatch" >&2; exit 1; }
  done
  if [[ "$persona" == plan-writer ]]; then
    python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve()
allowed = root / "docs/superpowers/plans/2026-07-18-cc-1wi2-subagent-models-plan-writer.md"
for raw, ok in ((str(allowed), True), (str(root / "docs/superpowers/plans/subdir/../" / allowed.name), True), (str(root / "docs/superpowers/plans/../../outside.md"), False), (str(root / "docs/superpowers/specs/x.md"), False)):
    candidate = Path(raw).resolve()
    result = candidate == allowed and candidate.parent == (root / "docs/superpowers/plans").resolve()
    assert result is ok, (raw, candidate, result)
PY
    grep -Fq 'Canonicalize and validate the requested output path before writing anything.' "$path" || { echo "plan-writer: missing canonicalize instruction" >&2; exit 1; }
    grep -Fq 'the requested plan artifact, and reject the request if the canonical path is outside' "$path" || { echo "plan-writer: missing canonical rejection instruction" >&2; exit 1; }
    grep -Fq 'Do not silently substitute a' "$path" && grep -Fq 'the reason and the requested path in `plan_file`.' "$path" || { echo "plan-writer: missing no-substitution/report instruction" >&2; exit 1; }
    grep -Fq 'the requested path in `plan_file`.' "$path" || { echo "plan-writer: missing exact plan_file reporting instruction" >&2; exit 1; }
    grep -Fq 'Report the plan path, every repository file directly read or examined in `files_considered`' "$path" || { echo "plan-writer: missing report contract" >&2; exit 1; }
  fi
  rm -f "$frontmatter"; trap - EXIT
  echo "$persona contract verified"
done
found=$(printf '%s\n' polytoken/subagents/*.md | sed 's#polytoken/subagents/##;s#\.md$##' | sort)
expected=$(printf '%s\n' "${files[@]}" | sort)
[[ "$found" == "$expected" ]] || { echo "persona allowlist mismatch" >&2; exit 1; }
echo "six model assignments verified"
echo "all persona contract assertions passed"
