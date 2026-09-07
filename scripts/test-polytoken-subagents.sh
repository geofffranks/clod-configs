#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
command -v yq >/dev/null || { echo "yq is required" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "sha256sum is required" >&2; exit 1; }

# Data-driven managed inventory manifest.
# One entry per managed custom subagent definition; fields are pipe-separated:
#   name|model|description|fallback_models|tools|undeferred_tools|skills_allow|required|properties|enums|import_sha256
# description is the exact frontmatter description string;
# fallback_models/tools/undeferred_tools/required keep the exact frontmatter
# order and are comma-separated; properties is the sorted property set; enums
# is semicolon-separated field=v1,v2 entries; import_sha256 is set only for
# byte-preserved imports whose repository copy must never drift.
# Heterogeneous schema shapes are validated generically by validate_persona
# rather than per-role special cases.
subagent_manifest=(
  'implementer|codex/gpt-5.6-luna|Implement a single plan task via TDD — writes code, runs focused then full tests, commits, self-reviews, and reports status. Dispatch one per task with its task-brief file path and report-file path.|zai/glm-5.2|file_read,file_write,file_edit_search_replace,glob,grep,shell_exec|file_read,file_write,file_edit_search_replace,glob,grep,shell_exec||status,summary|commits,concerns,report_file,status,summary,test_summary|status=DONE,DONE_WITH_CONCERNS,BLOCKED,NEEDS_CONTEXT|'
  'reviewer|zai/glm-5.2|Review a code diff against its requirements and quality standards — returns a spec-compliance verdict and a quality verdict with severity-classified findings. Read-only with no write or shell tools. Handles task-scoped and whole-branch review.|codex/gpt-5.6-luna,minime/google_gemma-4-26b-a4b-it|file_read,glob,grep|file_read,glob,grep||verdict,summary|report_file,spec_compliance,summary,verdict|verdict=approved,needs_fixes;spec_compliance=compliant,issues_found|'
  'validator|zai/glm-5.2|Execute a validation plan end-to-end — runs each validation item, captures command output as evidence, judges pass/fail, and reports an overall verdict. Does not fix issues; reports them.|codex/gpt-5.6-luna,minime/google_gemma-4-26b-a4b-it|file_read,glob,grep,shell_exec,file_write|file_read,glob,grep,shell_exec,file_write||verdict,summary|report_file,summary,verdict|verdict=pass,fail,partial|'
  'researcher|minime/google_gemma-4-26b-a4b-it|Investigate a research question against the local codebase, the internet, or both, and return evidence-grounded findings.|codex/gpt-5.6-luna,zai/glm-5.2|file_read,grep,glob,web_search,web_fetch|grep,glob,web_search,web_fetch|tag!research|summary,files,sources|files,sources,summary||'
  'abstraction-reviewer|codex/gpt-5.6-luna(high)|Review bounded changes for leaky abstractions, boundary violations, boilerplate caused by poor interfaces, and low-level concepts leaking toward product or UI surfaces.|neuralwatt/qwen-3.8-27b(medium),zai/glm-5.3-flash(high)|file_read,glob,grep,shell_exec|file_read,glob,grep,shell_exec||source_revision,scope_id,verdict,summary,findings,limitations|findings,limitations,scope_id,source_revision,summary,verdict|verdict=approved,changes_required,blocked|880117c553322fe8c3d979636529ffef6327ebb4b0ab8264144c1fd77898843b'
  'completeness-reviewer|codex/gpt-5.6-luna(high)|Review bounded changes for placeholders, deferred layers, mocked production paths, missing wiring, unsupported errors, and partial end-to-end behavior.|neuralwatt/qwen-3.8-27b(medium),zai/glm-5.3-flash(high)|file_read,glob,grep,shell_exec|file_read,glob,grep,shell_exec||source_revision,scope_id,verdict,summary,findings,limitations|findings,limitations,scope_id,source_revision,summary,verdict|verdict=approved,changes_required,blocked|9551ccff8a90c34569444fa4ed47eec26294ddcf5a3535cfdec9634e278c43ad'
  'correctness-reviewer|codex/gpt-5.6-luna(high)|Review bounded changes for crashes, races, deadlocks, corruption, lifecycle and state-machine defects, unsafe cancellation, and recovery failures.|neuralwatt/qwen-3.8-27b(medium),zai/glm-5.3-flash(high)|file_read,glob,grep,shell_exec|file_read,glob,grep,shell_exec||source_revision,scope_id,verdict,summary,findings,limitations|findings,limitations,scope_id,source_revision,summary,verdict|verdict=approved,changes_required,blocked|ce4c7cb37a783bc9cc6e02df647bac4aee5f60eef2d1126e75ce02a953cab09d'
  'general-reviewer|codex/gpt-5.6-luna(high)|Review bounded changes broadly for specification compliance and engineering quality, returning independent severity-classified findings. Read-only except focused existing checks.|neuralwatt/qwen-3.8-27b(medium),zai/glm-5.3-flash(high)|file_read,glob,grep,shell_exec|file_read,glob,grep,shell_exec||source_revision,scope_id,verdict,summary,findings,limitations|findings,limitations,scope_id,source_revision,summary,verdict|verdict=approved,changes_required,blocked|50bcfa7b7054871ecce518d9d745d2ffddb840aea415371d8facf92bdc3aaf1c'
  'maintainability-reviewer|codex/gpt-5.6-luna(high)|Review bounded changes for duplication, competing implementations, needless complexity, high churn, and justified modularization opportunities without unrelated refactoring.|neuralwatt/qwen-3.8-27b(medium),zai/glm-5.3-flash(high)|file_read,glob,grep,shell_exec|file_read,glob,grep,shell_exec||source_revision,scope_id,verdict,summary,findings,limitations|findings,limitations,scope_id,source_revision,summary,verdict|verdict=approved,changes_required,blocked|fc13247814c3967d58a0524c49cb51d12bcb0bd539376dbb9548ad843b6f181d'
  'mobile-app-expert|codex/gpt-5.6-luna(high)|Advise on mobile lifecycle, permissions, native bridges, device variance, offline behavior, resource use, accessibility, platform conventions, and evidence limits. Read-only.|neuralwatt/qwen-3.8-27b(medium),zai/glm-5.3-flash(low)|file_read,glob,grep|file_read,glob,grep||source_revision,scope_id,summary,recommendation,alternatives,risks,assumptions,evidence,limitations|alternatives,assumptions,evidence,follow_up_opportunities,limitations,recommendation,risks,scope_id,source_revision,summary||1ce1e39d0a669ff063739a9a2737fd5fdbb90044fa19a65eee20b490a2d1751e'
  'software-architect|codex/gpt-5.6-sol(high)|Advise on software boundaries, contracts, data flow, lifecycle, migration, recovery, feasibility, alternatives, and plan risks. Read-only.|neuralwatt/deepseek-v4-flash-flex(high)|file_read,glob,grep|file_read,glob,grep||source_revision,scope_id,summary,recommendation,alternatives,risks,assumptions,evidence,limitations|alternatives,assumptions,evidence,follow_up_opportunities,limitations,recommendation,risks,scope_id,source_revision,summary||a4ad06c39aa4a76a6c812f0b03ae982442214871f6cfbc5d346746f8dddce52d'
  'software-engineer|codex/gpt-5.6-luna(high)|Implement or debug bounded repository work across Swift, TypeScript, React, and adjacent languages using repository conventions, tests, and explicit evidence.|neuralwatt/qwen-3.8-27b(medium),zai/glm-5.3-flash(low)|file_read,file_write,file_edit_search_replace,glob,grep,shell_exec|file_read,file_write,file_edit_search_replace,glob,grep,shell_exec||source_revision,scope_id,status,summary,changed_files,tests,concerns|changed_files,concerns,follow_up_opportunities,scope_id,source_revision,status,summary,tests|status=done,done_with_concerns,needs_context,blocked|da142e2ec4caa3c66b93e6b282d22a7a9046af76bcde9627652b7a4a2c1dd579'
  'agent-workflow-architect|zai/glm-5.2|Design and independently review Polytoken agent workflows for authority, usability, token efficiency, Docker/macOS boundaries, and ratatoskr routing.|codex/gpt-5.6-luna|file_read,glob,grep,web_search,web_fetch|file_read,glob,grep,web_search,web_fetch|tag!research|verdict,summary,recommendation,findings,evidence,risks,limitations,second_review_required|evidence,findings,limitations,recommendation,risks,second_review_required,summary,verdict|verdict=approved,needs_fixes,blocked|'
  'agent-workflow-engineer|codex/gpt-5.6-luna|Implement bounded Polytoken workflow changes with risk-based testing and explicit container/host evidence.|zai/glm-5.2|file_read,file_write,file_edit_search_replace,glob,grep,lsp,shell_exec,mcp__ratatoskr|file_read,file_write,file_edit_search_replace,glob,grep,lsp,shell_exec||status,summary,changed_files,checks,tdd_evidence,concerns,limitations|changed_files,checks,concerns,limitations,status,summary,tdd_evidence|status=DONE,DONE_WITH_CONCERNS,BLOCKED,NEEDS_CONTEXT|'
)

manifest_names() {
  printf '%s\n' "${subagent_manifest[@]}" | cut -d'|' -f1
}

manifest_entry() {
  local wanted="$1" entry
  for entry in "${subagent_manifest[@]}"; do
    if [[ "${entry%%|*}" == "$wanted" ]]; then
      printf '%s\n' "$entry"
      return 0
    fi
  done
  return 1
}

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
  assert_contract persona_implementer_path_dispatch "$implementer" \
    'The dispatch supplies paths to the manifest, task brief, and report file.'
  assert_contract persona_implementer_targeted_exploration_then_needs_context "$implementer" \
    'Start with the named files and their direct dependencies.' \
    'Before any out-of-scope read, state one unresolved question and perform one targeted lookup.' \
    'After two targeted searches or three extra file reads, if the question is still unresolved, return `NEEDS_CONTEXT` rather than guessing.'
  assert_contract persona_implementer_self_reviews_changed_hunks_only "$implementer" \
    'Self-review only the files and hunks you changed.' \
    'Never read the reviewer package.'
  assert_contract persona_reviewer_path_dispatch "$reviewer" \
    'The dispatch supplies paths to the review index, task brief, diff shards, and' \
    'report file.'
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
    'Review the entire repository before starting' \
    'Read the diff file once' \
    'do not re-derive it'
  workflow_architect=polytoken/subagents/agent-workflow-architect.md
  workflow_engineer=polytoken/subagents/agent-workflow-engineer.md

  assert_contract persona_workflow_architect_requires_dispatch_context "$workflow_architect" \
    'The dispatch names the phase, scope ID, source revision, requested' \
    'these is missing, return `blocked` and name the gap; do not guess.'
  assert_contract persona_workflow_architect_is_read_only "$workflow_architect" \
    'You are read-only. You never edit files, run shell commands, fix your own' \
    'findings, or spawn subagents — not even for a defect you just found.'
  assert_contract persona_workflow_architect_evidence_and_severity "$workflow_architect" \
    'Separate observed evidence from inference; cite paths with line numbers or' \
    'URLs for every claim. Classify each finding by severity; state limitations.'
  assert_contract persona_workflow_architect_second_review_triggers "$workflow_architect" \
    'Mark `second_review_required` true when the work touches permissions,' \
    'authority, approval gates, delegation, autonomous behavior, MCP routing,'
  assert_contract persona_workflow_architect_ratatoskr_routing "$workflow_architect" \
    'all MCP through ratatoskr with inspect-before-execute behavior;'
  assert_contract persona_workflow_architect_final_compliance "$workflow_architect" \
    'verify final source-revision compliance against the approved'

  assert_contract persona_workflow_engineer_requires_dispatch_context "$workflow_engineer" \
    'required checks, prohibited actions, and report expectations. If the' \
    'approved design is insufficient, stop and return `NEEDS_CONTEXT`; never'
  assert_contract persona_workflow_engineer_risk_based_test_policy "$workflow_engineer" \
    '- Declarative facet, subagent, and config work: no forced RED/GREEN;' \
    '- Executable script, hook, code, or MCP behavior: RED/GREEN TDD, then'
  assert_contract persona_workflow_engineer_tool_discipline "$workflow_engineer" \
    'use LSP for symbol navigation, and `shell_exec` only for real commands.'
  assert_contract persona_workflow_engineer_ratatoskr_only "$workflow_engineer" \
    'Use ratatoskr for all MCP: list servers, inspect a tool schema, then' \
    'execute. Reconnect only on auth or token expiry. Never set up or'
  assert_contract persona_workflow_engineer_evidence_boundaries "$workflow_engineer" \
    'Report every check labeled container-local, ratatoskr-mediated host, or'
  assert_contract persona_workflow_engineer_stays_bounded "$workflow_engineer" \
    'Stay bounded: no remote writes, no destructive actions, and no nested'
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

# validate_inventory: fail if a managed definition is missing, if a byte-
# preserved import drifted from its recorded SHA-256, or if any top-level
# backup/generated file appears in polytoken/subagents besides the manifest set.
validate_inventory() {
  local failures=0 found expected entry name file sha actual
  found=$(find polytoken/subagents -maxdepth 1 -type f | sed 's#polytoken/subagents/##;s#\.md$##' | sort)
  expected=$(manifest_names | sort)
  if [[ "$found" != "$expected" ]]; then
    echo "managed_subagent_inventory_and_hashes: top-level inventory mismatch" >&2
    diff <(printf '%s\n' "$found") <(printf '%s\n' "$expected") >&2 || true
    failures=1
  fi
  for entry in "${subagent_manifest[@]}"; do
    IFS='|' read -r name _ _ _ _ _ _ _ _ _ sha <<<"$entry"
    file="polytoken/subagents/$name.md"
    [[ -n "${sha:-}" ]] || continue
    if [[ ! -f "$file" ]]; then
      echo "managed_subagent_inventory_and_hashes: missing import: $name" >&2
      failures=1
      continue
    fi
    actual=$(sha256sum "$file" | cut -d' ' -f1)
    if [[ "$actual" != "$sha" ]]; then
      echo "managed_subagent_inventory_and_hashes: import drift: $name ($actual != $sha)" >&2
      failures=1
    fi
  done
  [[ "$failures" == 0 ]] || return 1
  echo "managed_subagent_inventory_and_hashes: ${#subagent_manifest[@]} managed definitions, imports byte-preserved"
}

validate_persona() {
  persona="$1"
  path="polytoken/subagents/$persona.md"
  entry=$(manifest_entry "$persona") || { echo "managed manifest missing entry: $persona" >&2; exit 1; }
  IFS='|' read -r _ m_model m_desc m_fallbacks m_tools m_undeferred m_skills_allow m_required m_properties m_enums _ <<<"$entry"
  [[ -f "$path" ]] || { echo "missing persona: $path" >&2; return 1; }
  frontmatter=$(mktemp)
  trap 'rm -f "$frontmatter"' RETURN
  [[ "$(grep -c '^---$' "$path")" == 2 ]] || { echo "$persona: expected one frontmatter delimiter pair" >&2; return 1; }
  [[ "$(sed -n '1p' "$path")" == '---' ]] || { echo "$persona: missing opening frontmatter delimiter" >&2; return 1; }
  [[ "$(sed -n '2,/^---$/p' "$path" | tail -n 1)" == '---' ]] || { echo "$persona: missing closing frontmatter delimiter" >&2; return 1; }
  sed -n '2,/^---$/p' "$path" | sed '$d' > "$frontmatter"
  yq -e '.' "$frontmatter" >/dev/null || { echo "$persona: malformed YAML" >&2; return 1; }
  [[ "$(yq -r '.name' "$frontmatter")" == "$persona" ]] || { echo "$persona: frontmatter name must match the definition file name" >&2; exit 1; }
  MODEL_NODES=$(count_model_nodes "$frontmatter")
  [[ "$MODEL_NODES" == 1 ]] || { echo "$persona: expected exactly one structural polytoken.model node, got $MODEL_NODES" >&2; return 1; }
  model=$(yq -r '.polytoken.model' "$frontmatter")
  [[ "$model" == "$m_model" ]] || { echo "$persona: unexpected model: $model" >&2; exit 1; }
  [[ "$(yq -r '.description' "$frontmatter")" == "$m_desc" ]] || { echo "$persona: description contract mismatch" >&2; exit 1; }
  expected_fallbacks_json=$(printf '[%s]\n' "${m_fallbacks//,/, }" | yq -o=json -I=0 '.')
  [[ "$(yq -o=json -I=0 '.polytoken.fallback_models' "$frontmatter")" == "$expected_fallbacks_json" ]] || { echo "$persona: fallback_models contract mismatch" >&2; exit 1; }
  tools=$(yq -o=json -I=0 '.polytoken.tools' "$frontmatter")
  undeferred=$(yq -o=json -I=0 '.polytoken.undeferred_tools' "$frontmatter")
  expected_tools_json=$(printf '[%s]\n' "${m_tools//,/, }" | yq -o=json -I=0 '.')
  expected_undeferred_json=$(printf '[%s]\n' "${m_undeferred//,/, }" | yq -o=json -I=0 '.')
  [[ "$tools" == "$expected_tools_json" ]] || { echo "$persona: tools contract mismatch" >&2; exit 1; }
  [[ "$undeferred" == "$expected_undeferred_json" ]] || { echo "$persona: undeferred tools contract mismatch" >&2; exit 1; }
  [[ "$(yq -r '.polytoken.allow_subagent_spawn | tostring' "$frontmatter")" == false ]] || { echo "$persona: spawn must be false" >&2; exit 1; }
  if [[ -z "$m_skills_allow" ]]; then
    expected_skills='[]'
  else
    expected_skills="[$m_skills_allow]"
  fi
  [[ "$(yq -o=json -I=0 '.polytoken.skills_allow' "$frontmatter")" == "$(printf '%s\n' "$expected_skills" | yq -o=json -I=0 '.')" ]] || { echo "$persona: skills_allow contract mismatch" >&2; exit 1; }
  [[ "$(yq -o=json -I=0 '.polytoken.skills_deny' "$frontmatter")" == '[]' ]] || { echo "$persona: skills_deny contract mismatch" >&2; exit 1; }
  schema='.polytoken.exit_tool_schema'
  [[ "$(yq -r "$schema.type" "$frontmatter")" == object && "$(yq -r "$schema.additionalProperties | tostring" "$frontmatter")" == false ]] || { echo "$persona: schema is not closed object" >&2; exit 1; }
  [[ "$(yq -o=json -I=0 "$schema.required" "$frontmatter")" == "$(printf '[%s]\n' "${m_required//,/, }" | yq -o=json -I=0 '.')" ]] || { echo "$persona: required schema mismatch" >&2; exit 1; }
  actual_properties=$(yq -r "$schema.properties | keys | sort | join(\" \")" "$frontmatter")
  [[ "$actual_properties" == "${m_properties//,/ }" ]] || { echo "$persona: property set mismatch: $actual_properties" >&2; exit 1; }
  while read -r field; do
    [[ "$(yq -r "$schema.properties.$field.type" "$frontmatter")" != null ]] || { echo "$persona: required field $field is not declared in properties" >&2; exit 1; }
  done < <(tr ',' '\n' <<<"$m_required")
  while read -r prop; do
    ptype=$(yq -r "$schema.properties.$prop.type" "$frontmatter")
    case "$ptype" in
      object)
        [[ "$(yq -r "$schema.properties.$prop.additionalProperties | tostring" "$frontmatter")" == false ]] || { echo "$persona: object property $prop must be closed" >&2; exit 1; }
        ;;
      array)
        itype=$(yq -r "$schema.properties.$prop.items.type" "$frontmatter")
        [[ "$itype" == string || "$itype" == object ]] || { echo "$persona: array property $prop must contain strings or objects" >&2; exit 1; }
        if [[ "$itype" == object ]]; then
          [[ "$(yq -r "$schema.properties.$prop.items.additionalProperties | tostring" "$frontmatter")" == false ]] || { echo "$persona: object items of $prop must be closed" >&2; exit 1; }
        fi
        ;;
      string) ;;
      boolean) ;;
      *)
        echo "$persona: property $prop has unsupported type: $ptype" >&2
        exit 1
        ;;
    esac
  done < <(yq -r "$schema.properties | keys[]" "$frontmatter")
  if [[ -n "$m_enums" ]]; then
    IFS=';' read -ra enum_fields <<<"$m_enums"
    for enum_field in "${enum_fields[@]}"; do
      field=${enum_field%%=*}
      expected_enum=${enum_field#*=}
      actual=$(yq -r "$schema.properties.$field.enum | join(\",\")" "$frontmatter")
      [[ "$actual" == "$expected_enum" ]] || { echo "$persona: $field enum mismatch" >&2; exit 1; }
    done
  fi
  rm -f "$frontmatter"; trap - EXIT
  echo "$persona contract verified"
}

if [[ "${1:-}" == --model-contract ]]; then
  validate_implementer_model_contract
  validate_persona implementer
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

# checked_restore <live> <orig>: restore the live file from the preserved
# original, then verify byte identity. On a failed copy or a failed verify it
# must report loudly (return nonzero) and leave the recovery bytes (orig)
# untouched — it never deletes them itself.
checked_restore() {
  local live="$1" orig="$2"
  if ! cp -f "$orig" "$live" 2>/dev/null; then
    echo "frontmatter restore failed: $live" >&2
    return 1
  fi
  if ! cmp -s "$live" "$orig"; then
    echo "frontmatter restore verify failed: $live" >&2
    return 1
  fi
  return 0
}

# FOCUSED FAILURE-PATH TEST for the restore contract. A checked restore that
# cannot overwrite an unwritable live file must (a) fail loudly and (b)
# preserve the recovery bytes (the original) rather than report success or
# lose them. Uses an isolated sandbox; touches no managed definition.
if [[ "${1:-}" == --frontmatter-restore-failure ]]; then
  sandbox=$(mktemp -d)
  printf 'original-bytes\n' > "$sandbox/orig"
  printf 'MUTATED\n' > "$sandbox/live"
  # Make the restore impossible: live's content is not writable (444) and its
  # directory is not writable (555), so cp -f cannot overwrite or recreate it.
  chmod 444 "$sandbox/live"
  chmod 555 "$sandbox"
  rc=0
  checked_restore "$sandbox/live" "$sandbox/orig" || rc=$?
  chmod 644 "$sandbox/live" 2>/dev/null
  chmod 755 "$sandbox"
  if [[ $rc == 0 ]]; then
    echo "restore failure-path: checked_restore swallowed a failed restore (rc=0)" >&2
    rm -rf "$sandbox"
    exit 1
  fi
  if [[ ! -f "$sandbox/orig" ]] || ! cmp -s "$sandbox/orig" <(printf 'original-bytes\n'); then
    echo "restore failure-path: recovery bytes were lost" >&2
    rm -rf "$sandbox"
    exit 1
  fi
  if ! cmp -s "$sandbox/live" <(printf 'MUTATED\n'); then
    echo "restore failure-path: live was clobbered by an unverified restore" >&2
    rm -rf "$sandbox"
    exit 1
  fi
  echo "restore failure-path: loud failure + recovery bytes preserved"
  rm -rf "$sandbox"
  exit 0
fi

if [[ "${1:-}" == --frontmatter-mutations ]]; then
  # Deliberate temporary mutations of managed definition frontmatter. Each
  # mutation must be rejected by validate_persona, and each live file must be
  # restored by checked_restore which verifies byte identity.
  #
  # SAFETY CONTRACT:
  #   * The ORIGINAL (untouched) byte sequence is preserved once per file in
  #     the backup dir. These are the "recovery bytes".
  #   * Every restore is performed by checked_restore: it cp's the orig over
  #     the live file and then cmp-verifies identity. If either step fails it
  #     returns nonzero (loudly) WITHOUT deleting orig.
  #   * The backup dir is deleted ONLY after ALL restore-and-verify cycles
  #     have succeeded. If any restore fails the backup is left in place so
  #     the operator can recover manually.
  #   * The EXIT trap is a last-resort self-heal that also obeys the same
  #     checked_restore contract: it never swallows a cp/cmp failure into an
  #     rm -rf.
  backup=$(mktemp -d)
  architect=polytoken/subagents/agent-workflow-architect.md
  reviewer=polytoken/subagents/reviewer.md

  # Preserve the untouched originals; these are the sole recovery bytes.
  cp "$architect" "$backup/architect.orig"
  cp "$reviewer"   "$backup/reviewer.orig"

  # Over-written EXIT trap: self-heals any mid-mutation failure by running
  # checked_restore on BOTH files. Deletes the backup dir ONLY if both
  # restores are verified byte-identical; otherwise preserves it and fails
  # loudly (exit 1).
  trap '
    if checked_restore "$architect" "$backup/architect.orig" \
       && checked_restore "$reviewer" "$backup/reviewer.orig"; then
      rm -rf "$backup"
    else
      echo "frontmatter mutation EXIT restore FAILED; recovery bytes preserved in $backup" >&2
      exit 1
    fi
  ' EXIT

  mutation_rejected() {
    persona="$1"
    # Run the validator in a subshell with the EXIT trap cleared so that a
    # validate_persona failure does not trigger the parent restore logic
    # behind the caller's back. Exit 0 means "rejected" (good).
    if (trap - EXIT; validate_persona "$persona" >/dev/null 2>&1); then
      echo "frontmatter mutation not detected: $persona still validates" >&2
      exit 1
    fi
    echo "frontmatter mutation rejected: $persona"
  }

  # --- Mutation 1: changed required description (agent-workflow-architect) --
  awk '/^description:/ && !done { sub(/routing\.$/, "gateway routing."); done = 1 } { print }' \
      "$architect" > "$backup/m1.md"
  if cmp -s "$architect" "$backup/m1.md"; then
    echo "frontmatter mutation 1 had no effect" >&2
    exit 1
  fi
  mv "$backup/m1.md" "$architect"
  mutation_rejected agent-workflow-architect
  checked_restore "$architect" "$backup/architect.orig"
  echo "frontmatter mutation 1 restored: agent-workflow-architect"

  # --- Mutation 2: drop one of two fallback_models (reviewer) ------------
  awk '{ if (done || $0 != "  - codex/gpt-5.6-luna") print; else done = 1 }' \
      "$reviewer" > "$backup/m2.md"
  if cmp -s "$reviewer" "$backup/m2.md"; then
    echo "frontmatter mutation 2 had no effect" >&2
    exit 1
  fi
  mv "$backup/m2.md" "$reviewer"
  mutation_rejected reviewer
  checked_restore "$reviewer" "$backup/reviewer.orig"
  echo "frontmatter mutation 2 restored: reviewer"

  # --- Mutation 3: same-membership reorder of fallback_models (reviewer) --
  # Reviewer has two fallbacks; swapping them (same membership, different
  # order) must be rejected by the order-sensitive fallback comparison.
  awk '
    $0 == "  - codex/gpt-5.6-luna" { swap = 1; next }
    $0 == "  - minime/google_gemma-4-26b-a4b-it" && swap {
      print "  - minime/google_gemma-4-26b-a4b-it"
      print "  - codex/gpt-5.6-luna"
      swap = 0; next
    }
    { print }
  ' "$reviewer" > "$backup/m3.md"
  if cmp -s "$reviewer" "$backup/m3.md"; then
    echo "frontmatter mutation 3 had no effect" >&2
    exit 1
  fi
  mv "$backup/m3.md" "$reviewer"
  mutation_rejected reviewer
  checked_restore "$reviewer" "$backup/reviewer.orig"
  echo "frontmatter mutation 3 restored: reviewer"

  # Final belt-and-suspenders verification before EXIT trap cleanup.
  cmp -s "$architect" "$backup/architect.orig" || { echo "final verify failed: agent-workflow-architect" >&2; exit 1; }
  cmp -s "$reviewer"   "$backup/reviewer.orig"   || { echo "final verify failed: reviewer" >&2; exit 1; }
  echo "frontmatter mutation files restored byte-identically"
  exit 0
fi

if [[ "${1:-}" == --inventory ]]; then
  validate_inventory
  exit 0
fi

validate_implementer_model_contract
validate_persona_contracts
validate_inventory
while IFS= read -r persona; do
  validate_persona "$persona"
done < <(manifest_names)
echo "${#subagent_manifest[@]} model assignments verified"
echo "all persona contract assertions passed"
