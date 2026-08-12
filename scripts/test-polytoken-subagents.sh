#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
command -v yq >/dev/null || { echo "yq is required" >&2; exit 1; }

files=(implementer reviewer validator researcher)
declare -A expected_model=(
  [implementer]='codex/gpt-5.6-luna'
  [reviewer]='zai/glm-5.2'
  [validator]='zai/glm-5.2'
  [researcher]='minime/google_gemma-4-26b-a4b-it'
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

assert_contract() {
  label="$1"
  path="$2"
  shift 2
  passed=true
  for required_text in "$@"; do
    if ! grep -Fq -- "$required_text" "$path"; then
      echo "$label: missing contract: $required_text" >&2
      CONTRACT_FAILURES=1
      passed=false
    fi
  done
  [[ "$passed" == false ]] || echo "$label"
}

assert_absent() {
  label="$1"
  path="$2"
  shift 2
  passed=true
  for stale_text in "$@"; do
    if grep -Fq -- "$stale_text" "$path"; then
      echo "$label: stale or contradictory wording: $stale_text" >&2
      CONTRACT_FAILURES=1
      passed=false
    fi
  done
  [[ "$passed" == false ]] || echo "$label"
}

validate_persona_contracts() {
  implementer=polytoken/subagents/implementer.md
  reviewer=polytoken/subagents/reviewer.md
  CONTRACT_FAILURES=0

  assert_contract persona_implementer_orient_red_green_verify_report "$implementer" \
    'Orient → RED/GREEN → Verify → Report'
  assert_contract persona_implementer_targeted_exploration_then_needs_context "$implementer" \
    'Start with the named files and their direct dependencies.' \
    'Before any out-of-scope read, state one unresolved question and perform one targeted lookup.' \
    'After two targeted searches or three extra file reads, if the question is still unresolved, return `NEEDS_CONTEXT`.'
  assert_contract persona_implementer_self_reviews_changed_hunks_only "$implementer" \
    'Self-review only the files and hunks you changed.' \
    'Never read the reviewer package.'
  assert_contract persona_reviewer_has_four_exact_modes "$reviewer" \
    'The mode is exactly one of: `initial-task`, `incremental-rereview`, `final-integration`, or `final-incremental-rereview`.'
  [[ "$(grep -oE '`(initial-task|incremental-rereview|final-integration|final-incremental-rereview)`' "$reviewer" | sort -u | wc -l)" == 4 ]] || { echo 'persona_reviewer_has_four_exact_modes: expected exactly four unique mode names' >&2; CONTRACT_FAILURES=1; }
  assert_contract persona_reviewer_reads_index_and_all_mode_required_shards "$reviewer" \
    'Read the review index first, then read every shard required by the selected mode; never sample required shards.'
  assert_contract persona_reviewer_limits_unchanged_source_to_named_risk "$reviewer" \
    'Read unchanged source only once for each named concrete risk.'
  assert_contract persona_bounded_grep_and_ranged_read "$implementer" \
    'Set `grep.max_results` to 20 or fewer, search one concept at a time, use ranged reads, and never repeat-read an unchanged artifact.'
  assert_contract persona_bounded_grep_and_ranged_read "$reviewer" \
    'Set `grep.max_results` to 20 or fewer, search one concept at a time, use ranged reads, and never repeat-read an unchanged artifact.'
  assert_contract persona_recovers_from_oversized_result "$implementer" \
    'If a result is approximately 50 KiB or larger, make the next operation narrower; do not make unsupported token-count claims.'
  assert_contract persona_recovers_from_oversized_result "$reviewer" \
    'If a result is approximately 50 KiB or larger, make the next operation narrower; do not make unsupported token-count claims.'
  assert_contract persona_reports_concise_test_evidence "$implementer" \
    'For test evidence, report the command, status, counts or summary, warnings, and only the relevant failure excerpt; put raw output in a named path.'
  assert_contract persona_uses_rtk_only_for_broad_text_and_supported_commands "$implementer" \
    'Use RTK only for broader plain-text searches and supported test or build commands, never for ordinary targeted reads.'
  assert_absent persona_negative_stale_or_contradictory_wording "$implementer" \
    'Read the entire repository before starting' \
    'Self-review the reviewer package'
  assert_absent persona_negative_stale_or_contradictory_wording "$reviewer" \
    'task-scoped or whole-branch' \
    'Read the diff file once' \
    'do not re-derive it'
  return "$CONTRACT_FAILURES"
}

validate_implementer_model_contract() {
  frontmatter=$(mktemp)
  trap 'rm -f "$frontmatter"' RETURN
  sed -n '2,/^---$/p' polytoken/subagents/implementer.md | sed '$d' > "$frontmatter"
  model=$(yq -r '.polytoken.model' "$frontmatter")
  [[ "$model" == 'codex/gpt-5.6-luna' ]] || { echo "focused_canonical_implementer_model_representation: expected raw provider/model source representation, got $model" >&2; return 1; }
  echo focused_canonical_implementer_model_representation
}

count_model_nodes() {
  FRONTMATTER="$1" python3 - <<'PY'
from pathlib import Path
import os, re

text = Path(os.environ['FRONTMATTER']).read_text()
clean = []
count = 0
quote = None
escaped = False
for ch in text:
    if quote == '#':
        if ch == '\n':
            quote = None
            clean.append(ch)
        else:
            clean.append(' ')
    elif quote:
        if quote == '"' and escaped:
            escaped = False
        elif quote == '"' and ch == '\\\\':
            escaped = True
        elif ch == quote:
            quote = None
        clean.append(' ' if ch != '\n' else '\n')
    elif ch in "'\"":
        quote = ch
        clean.append(' ')
    elif ch == '#':
        clean.append(' ')
        quote = '#'
    else:
        clean.append(ch)
clean_text = ''.join(clean)

for match in re.finditer(r'(?m)^([ ]*)polytoken\s*:\s*\n((?:[ ]+[^\n]*\n?)*)', clean_text):
    count += len(re.findall(r'(?m)^[ ]+model\s*:', match.group(2)))

for match in re.finditer(r'polytoken\s*:\s*\{', clean_text):
    start = match.end()
    depth = 1
    pos = start
    while pos < len(clean_text) and depth:
        if clean_text[pos] == '{': depth += 1
        elif clean_text[pos] == '}': depth -= 1
        pos += 1
    body = clean_text[start:pos - 1]
    count += len(re.findall(r'(?:^|[,{])\s*model\s*:', body))
print(count)
PY
}

validate_persona() {
  persona="$1"
  path="$2"
  [[ -f "$path" ]] || { echo "missing persona: $path" >&2; return 1; }
  frontmatter=$(mktemp)
  trap 'rm -f "$frontmatter"' RETURN
  [[ "$(grep -c '^---$' "$path")" == 2 ]] || { echo "$persona: expected one frontmatter delimiter pair" >&2; return 1; }
  [[ "$(sed -n '1p' "$path")" == '---' ]] || { echo "$persona: missing opening frontmatter delimiter" >&2; return 1; }
  [[ "$(sed -n '2,/^---$/p' "$path" | tail -n 1)" == '---' ]] || { echo "$persona: missing closing frontmatter delimiter" >&2; return 1; }
  sed -n '2,/^---$/p' "$path" | sed '$d' > "$frontmatter"
  yq -e '.' "$frontmatter" >/dev/null || { echo "$persona: malformed YAML" >&2; return 1; }
  MODEL_NODES=$(count_model_nodes "$frontmatter")
  [[ "$MODEL_NODES" == 1 ]] || { echo "$persona: expected exactly one structural polytoken.model node, got $MODEL_NODES" >&2; return 1; }
  model=$(yq -r '.polytoken.model' "$frontmatter")
  [[ "$model" == "${expected_model[$persona]}" ]] || { echo "$persona: unexpected model: $model" >&2; exit 1; }
  [[ "$model" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]] || { echo "$persona: model must use canonical raw provider/model source representation" >&2; exit 1; }
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
}

if [[ "${1:-}" == --model-contract ]]; then
  validate_implementer_model_contract
  validate_persona implementer polytoken/subagents/implementer.md
  exit 0
fi

if [[ "${1:-}" == --persona-contracts ]]; then
  validate_persona_contracts
  exit 0
fi

if [[ "${1:-}" == --mutation-tests ]]; then
  fixture_dir=$(mktemp -d)
  trap 'rm -rf "$fixture_dir"' EXIT
  declare -A fixtures=(
    [block]=$'polytoken:\n  model: expected\n  model: bad'
    [inline]=$'polytoken: {model: expected, model: bad}'
    [multiline]=$'polytoken: {\n  model: expected,\n  model: bad\n}'
    [single-quoted]=$'polytoken: {value: \'model: fake\'}'
    [double-quoted]=$'polytoken: {value: "model: fake"}'
    [comment]=$'polytoken: {value: safe} # model: fake'
    [comment-followed-model]=$'polytoken:\n  value: safe # model: fake\n  model: expected'
    [comment-between-duplicates]=$'polytoken:\n  model: expected # model: fake\n  value: safe\n  model: bad'
  )
  for fixture in block inline multiline single-quoted double-quoted comment comment-followed-model comment-between-duplicates; do
    fixture_file="$fixture_dir/$fixture.yaml"
    printf '%s\n' "${fixtures[$fixture]}" > "$fixture_file"
    nodes=$(count_model_nodes "$fixture_file")
    case "$fixture" in
      block|inline|multiline|comment-between-duplicates)
        [[ "$nodes" == 2 ]] || { echo "$fixture expected two model nodes, got $nodes" >&2; exit 1; }
        echo "$fixture duplicate mutation rejected (model nodes: $nodes)" ;;
      comment-followed-model)
        [[ "$nodes" == 1 ]] || { echo "$fixture expected one model node, got $nodes" >&2; exit 1; }
        echo "$fixture comment reset preserved model (model nodes: $nodes)" ;;
      *)
        [[ "$nodes" == 0 ]] || { echo "$fixture quoted/comment model text falsely counted: $nodes" >&2; exit 1; }
        echo "$fixture model text ignored (model nodes: $nodes)" ;;
    esac
  done
  exit 0
fi

validate_implementer_model_contract
validate_persona_contracts
for persona in "${files[@]}"; do
  validate_persona "$persona" "polytoken/subagents/$persona.md"
done
found=$(printf '%s\n' polytoken/subagents/*.md | sed 's#polytoken/subagents/##;s#\.md$##' | sort)
expected=$(printf '%s\n' "${files[@]}" | sort)
[[ "$found" == "$expected" ]] || { echo "persona allowlist mismatch" >&2; exit 1; }
echo "four model assignments verified"
echo "all persona contract assertions passed"
