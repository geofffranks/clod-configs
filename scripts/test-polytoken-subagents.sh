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
# byte-preserved imports whose repository copy must never drift. The optional
# item_properties field validates closed nested candidate/finding schemas.
# Heterogeneous schema shapes are validated generically by validate_persona
# rather than per-role special cases.
subagent_manifest=(
  'implementer|zai/glm-5.3-flash(low)|Implement a single plan task via TDD — writes code, runs focused then full tests, commits, self-reviews, and reports status. Dispatch one per task with its task-brief file path and report-file path.|codex/gpt-5.6-luna(high)|file_read,file_write,file_edit_search_replace,glob,grep,shell_exec,skill|file_read,file_write,file_edit_search_replace,glob,grep,shell_exec,skill|brainstorming,git-workflow,using-git-worktrees,systematic-debugging,test-driven-development,verification-before-completion,polytoken:investigating-a-codebase,polytoken:modifying-polytoken|source_revision,scope_id,outcome_type,success,summary,evidence|commits,concerns,evidence,outcome_type,report_file,scope_id,source_revision,success,summary,test_summary|outcome_type=done,done_with_concerns,needs_context,blocked|'
  'validator|zai/glm-5.3-flash(high)|Execute a validation plan end-to-end — runs each validation item, captures command output as evidence, judges pass/fail, and reports an overall verdict. Does not fix issues; reports them.|codex/gpt-5.6-luna(high)|file_read,glob,grep,shell_exec,file_write,skill|file_read,glob,grep,shell_exec,file_write,skill|systematic-debugging,verification-before-completion,polytoken:investigating-a-codebase,polytoken:modifying-polytoken|source_revision,scope_id,verdict,summary,evidence|evidence,report_file,scope_id,source_revision,summary,verdict|verdict=pass,fail,partial|'
  'researcher|zai/glm-5.3-flash(high)|Investigate a research question against the local codebase, the internet, or both, and return evidence-grounded findings.|codex/gpt-5.6-luna(high)|file_read,grep,glob,web_search,web_fetch|grep,glob,web_search,web_fetch|tag!research,polytoken:researching-on-the-internet,polytoken:investigating-a-codebase,polytoken:modifying-polytoken|source_revision,scope_id,summary,files,sources,evidence|evidence,files,scope_id,source_revision,sources,summary||'
  'mobile-app-expert|zai/glm-5.3-flash(low)|Advise on mobile lifecycle, permissions, native bridges, device variance, offline behavior, resource use, accessibility, platform conventions, and evidence limits. Read-only.|codex/gpt-5.6-luna(high)|file_read,glob,grep,skill|file_read,glob,grep,skill|polytoken:investigating-a-codebase,polytoken:modifying-polytoken|source_revision,scope_id,summary,recommendation,alternatives,risks,assumptions,evidence,limitations|alternatives,assumptions,evidence,follow_up_opportunities,limitations,recommendation,risks,scope_id,source_revision,summary||fe3f8a981bb7c319d42fe8a947b19cc57d45216a287c4f15738ecaeb64f43b28'
  'software-architect|codex/gpt-6-astra(low)|Advise on software boundaries, contracts, data flow, lifecycle, migration, recovery, feasibility, alternatives, and plan risks. Read-only.||file_read,glob,grep,skill|file_read,glob,grep,skill|brainstorming,polytoken:investigating-a-codebase,polytoken:modifying-polytoken|source_revision,scope_id,summary,recommendation,evidence|alternatives,assumptions,evidence,follow_up_opportunities,limitations,recommendation,risks,scope_id,source_revision,summary||55db43e2f65b823bbbef315856bada1ac77f264295a93d1cd432e689217d6d59'
  'software-engineer|zai/glm-5.3-flash(low)|Implement or debug bounded repository work across Swift, TypeScript, React, and adjacent languages using repository conventions, tests, and explicit evidence.|codex/gpt-5.6-luna(high)|file_read,file_write,file_edit_search_replace,glob,grep,shell_exec,skill|file_read,file_write,file_edit_search_replace,glob,grep,shell_exec,skill|brainstorming,git-workflow,using-git-worktrees,systematic-debugging,test-driven-development,verification-before-completion,polytoken:investigating-a-codebase,polytoken:modifying-polytoken|source_revision,scope_id,outcome_type,success,summary,changed_files,tests,evidence,concerns|changed_files,concerns,evidence,follow_up_opportunities,outcome_type,scope_id,source_revision,success,summary,tests|outcome_type=done,done_with_concerns,needs_context,blocked|'
  'agent-workflow-architect|zai/glm-5.3-flash(high)|Design and independently review Polytoken agent workflows for authority, usability, token efficiency, Docker/macOS boundaries, and ratatoskr routing.|codex/gpt-6-astra(medium)|file_read,glob,grep,web_search,web_fetch,skill|file_read,glob,grep,web_search,web_fetch,skill|tag!research,brainstorming,agent-orchestration,polytoken:modifying-polytoken,polytoken:researching-on-the-internet,polytoken:investigating-a-codebase,doc-writing,agent-session-retro|source_revision,scope_id,verdict,summary,recommendation,findings,evidence,risks,limitations,second_review_required|evidence,findings,limitations,recommendation,risks,scope_id,second_review_required,source_revision,summary,verdict|verdict=approved,needs_fixes,blocked|'
  'agent-workflow-engineer|zai/glm-5.3-flash(high)|Implement bounded Polytoken workflow changes with risk-based testing and explicit container/host evidence.|codex/gpt-5.6-luna(medium)|file_read,file_write,file_edit_search_replace,glob,grep,lsp,shell_exec,skill,mcp__ratatoskr|file_read,file_write,file_edit_search_replace,glob,grep,lsp,shell_exec,skill|tag!research,brainstorming,agent-orchestration,git-workflow,using-git-worktrees,systematic-debugging,test-driven-development,receiving-code-review,requesting-code-review,verification-before-completion,artifact-retention-policy,polytoken:modifying-polytoken,polytoken:researching-on-the-internet,polytoken:investigating-a-codebase,doc-writing,agent-session-retro|source_revision,scope_id,outcome_type,success,summary,changed_files,checks,tdd_evidence,concerns,limitations|changed_files,checks,concerns,limitations,outcome_type,scope_id,source_revision,success,summary,tdd_evidence|outcome_type=done,done_with_concerns,needs_context,blocked|'
  'review-adversarial|zai/glm-5.3-flash(high)|Review pinned code-review snapshots and bounded changes for security and abuse paths, without network, shell, or mutation access.|codex/gpt-5.6-luna(high)|file_read,glob,grep,skill|file_read,glob,grep,skill|github-review-snapshot,code-review-evidence,polytoken:investigating-a-codebase,polytoken:modifying-polytoken,receiving-code-review|source_revision,scope_id,verdict,findings,evidence,limitations|evidence,findings,head_sha,limitations,report_file,review_run_id,scope_id,snapshot_digest,source_revision,spec_compliance,summary,verdict|verdict=approved,needs_fixes,blocked;spec_compliance=compliant,issues_found|'
  'review-completeness|zai/glm-5.3-flash(high)|Review pinned code-review snapshots and bounded changes for missing wiring, placeholders, mocked production paths, unsupported errors, and partial end-to-end behavior.|codex/gpt-5.6-luna(high)|file_read,glob,grep,skill|file_read,glob,grep,skill|github-review-snapshot,code-review-evidence,polytoken:investigating-a-codebase,polytoken:modifying-polytoken,receiving-code-review|source_revision,scope_id,verdict,findings,evidence,limitations|evidence,findings,head_sha,limitations,report_file,review_run_id,scope_id,snapshot_digest,source_revision,spec_compliance,summary,verdict|verdict=approved,needs_fixes,blocked;spec_compliance=compliant,issues_found|'
  'review-correctness|zai/glm-5.3-flash(high)|Review pinned code-review snapshots and bounded changes for crashes, races, deadlocks, corruption, lifecycle and state-machine defects, unsafe cancellation, and recovery failures.|codex/gpt-5.6-luna(high)|file_read,glob,grep,skill|file_read,glob,grep,skill|github-review-snapshot,code-review-evidence,polytoken:investigating-a-codebase,polytoken:modifying-polytoken,receiving-code-review|source_revision,scope_id,verdict,findings,evidence,limitations|evidence,findings,head_sha,limitations,report_file,review_run_id,scope_id,snapshot_digest,source_revision,spec_compliance,summary,verdict|verdict=approved,needs_fixes,blocked;spec_compliance=compliant,issues_found|'
  'review-general|zai/glm-5.3-flash(high)|Review pinned code-review snapshots and bounded changes for specification compliance and cross-cutting quality; carries the Lappie task-review modes with severity-classified findings.|codex/gpt-5.6-luna(high)|file_read,glob,grep,skill|file_read,glob,grep,skill|github-review-snapshot,code-review-evidence,polytoken:investigating-a-codebase,polytoken:modifying-polytoken,receiving-code-review|source_revision,scope_id,verdict,findings,evidence,limitations|evidence,findings,head_sha,limitations,report_file,review_run_id,scope_id,snapshot_digest,source_revision,spec_compliance,summary,verdict|verdict=approved,needs_fixes,blocked;spec_compliance=compliant,issues_found|'
  'review-maintainability|zai/glm-5.3-flash(high)|Review pinned code-review snapshots and bounded changes for duplication, competing implementations, needless complexity, leaky boundaries, and ownership or churn risks.|codex/gpt-5.6-luna(high)|file_read,glob,grep,skill|file_read,glob,grep,skill|github-review-snapshot,code-review-evidence,polytoken:investigating-a-codebase,polytoken:modifying-polytoken,receiving-code-review|source_revision,scope_id,verdict,findings,evidence,limitations|evidence,findings,head_sha,limitations,report_file,review_run_id,scope_id,snapshot_digest,source_revision,spec_compliance,summary,verdict|verdict=approved,needs_fixes,blocked;spec_compliance=compliant,issues_found|'
  'review-abstraction|zai/glm-5.3-flash(high)|Review pinned code-review snapshots and bounded changes for leaky abstractions, boundary violations, boilerplate caused by poor interfaces, and low-level concepts leaking toward product or UI surfaces.|codex/gpt-5.6-luna(high)|file_read,glob,grep,skill|file_read,glob,grep,skill|github-review-snapshot,code-review-evidence,polytoken:investigating-a-codebase,polytoken:modifying-polytoken,receiving-code-review|source_revision,scope_id,verdict,findings,evidence,limitations|evidence,findings,head_sha,limitations,report_file,review_run_id,scope_id,snapshot_digest,source_revision,spec_compliance,summary,verdict|verdict=approved,needs_fixes,blocked;spec_compliance=compliant,issues_found|'
  'review-synthesis-verifier|zai/glm-5.3-flash(high)|Fresh-context verifier that validates proposed code-review claims against pinned source and captured metadata.|codex/gpt-5.6-luna(high)|file_read,glob,grep,skill|file_read,glob,grep,skill|github-review-snapshot,code-review-evidence,code-review-reporting|source_revision,scope_id,review_run_id,snapshot_digest,head_sha,verdict,verified_findings,rejected_candidate_ids,evidence,limitations|evidence,head_sha,limitations,rejected_candidate_ids,review_run_id,scope_id,snapshot_digest,source_revision,verdict,verified_findings|verdict=verified,blocked|'
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

validate_implementer_model_contract() {
  frontmatter=$(mktemp)
  trap 'rm -f "$frontmatter"' RETURN
  sed -n '2,/^---$/p' polytoken/subagents/implementer.md | sed '$d' > "$frontmatter"
  model=$(yq -r '.polytoken.model' "$frontmatter")
  [[ "$model" == 'zai/glm-5.3-flash(low)' ]] || { echo "focused_canonical_implementer_model_representation: expected raw provider/model source representation, got $model" >&2; return 1; }
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
  case "$persona" in
    review-adversarial|review-correctness|review-completeness|review-maintainability|review-general|review-abstraction)
      nested_field='findings'
      nested_props='affected_files affected_scope anchor candidate_id category confidence evidence evidence_refs id impact impact_if_unfixed lane limitations observations path provenance requirement_ref routing_note scenario severity suggested_fix title triggering_use_cases'
      # Unified findings schema: snapshot-rich fields are optional; the bounded
      # core is required, so required is a strict subset of props.
      nested_required='affected_files category evidence id impact severity suggested_fix title'
      ;;
    review-synthesis-verifier)
      nested_field='verified_findings'
      nested_props='affected_paths affected_scope anchors confidence disposition evidence finding_id impact impact_if_unfixed originating_candidate_ids provenance severity suggested_fix summary title triggering_use_cases'
      nested_required="$nested_props"
      ;;
    *) nested_field='' ;;
  esac
  if [[ -n "$nested_field" ]]; then
    item_path="$schema.properties.$nested_field.items"
    [[ "$(yq -r "$item_path.type" "$frontmatter")" == object ]] || { echo "$persona: $nested_field items must be objects" >&2; return 1; }
    [[ "$(yq -r "$item_path.additionalProperties | tostring" "$frontmatter")" == false ]] || { echo "$persona: $nested_field item schema must be closed" >&2; return 1; }
    actual_nested=$(yq -r "$item_path.properties | keys | sort | join(\" \" )" "$frontmatter")
    [[ "$actual_nested" == "$nested_props" ]] || { echo "$persona: $nested_field item property mismatch: $actual_nested" >&2; return 1; }
    actual_nested_required=$(yq -r "$item_path.required | sort | join(\" \" )" "$frontmatter")
    [[ "$actual_nested_required" == "$nested_required" ]] || { echo "$persona: $nested_field item required mismatch: $actual_nested_required" >&2; return 1; }
    echo "$persona nested $nested_field schema verified"
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
  validate_inventory
  while IFS= read -r persona; do
    validate_persona "$persona"
  done < <(manifest_names)
  echo "all machine-consumed persona contracts passed"
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

# frontmatter_exit_restore <a_live> <a_orig> <r_live> <r_orig> <backup_dir>:
# EXIT-time self-heal for --frontmatter-mutations. Invokes checked_restore
# INDEPENDENTLY for each file (no && short-circuit: a first-restore failure
# must never prevent the second restore from running) and records both
# statuses. Removes the backup dir only if BOTH restores verified
# byte-identical. On any failure it preserves the backup (recovery bytes),
# reports both statuses loudly, and exits nonzero — the explicit exit is
# required because a bare nonzero return from within an EXIT trap does not
# change the process exit status.
frontmatter_exit_restore() {
  local a_live="$1" a_orig="$2" r_live="$3" r_orig="$4" backup_dir="$5"
  local rc_a=0 rc_r=0
  checked_restore "$a_live" "$a_orig" || rc_a=$?
  checked_restore "$r_live" "$r_orig" || rc_r=$?
  if [[ $rc_a -eq 0 && $rc_r -eq 0 ]]; then
    rm -rf "$backup_dir"
    return 0
  fi
  echo "frontmatter mutation EXIT restore FAILED (architect rc=$rc_a, reviewer rc=$rc_r); recovery bytes preserved in $backup_dir" >&2
  exit 1
}

# FOCUSED FAILURE-PATH TEST for the restore contract. Failure is injected
# deterministically by PATH-shadowing cp with a failing stub, so the injection
# is privilege-independent (unlike chmod-based write protection, which root
# bypasses). Three scenarios:
#   A: checked_restore with an impossible restore must fail loudly (nonzero,
#      diagnostic on stderr), keep the recovery bytes (orig) intact, and leave
#      the mutated live file unclobbered.
#   B: the EXIT-time handler with the FIRST restore failing: the second restore
#      must still be invoked and its status recorded, the backup dir must be
#      preserved, and the process must exit nonzero.
#   C: the EXIT-time handler success path: both files restored
#      byte-identically, the backup dir removed, exit zero.
# Sandboxes only; touches no managed definition.
if [[ "${1:-}" == --frontmatter-restore-failure ]]; then
  restore_dirs=()
  cleanup_restore_dirs() {
    local d
    for d in ${restore_dirs[@]+"${restore_dirs[@]}"}; do rm -rf "$d" 2>/dev/null || true; done
  }
  trap cleanup_restore_dirs EXIT
  fail_restore_mode() { echo "restore failure-path: $1" >&2; exit 1; }

  # PATH shadow: makes every cp invocation fail deterministically.
  stub_dir=$(mktemp -d) && restore_dirs+=("$stub_dir")
  printf '#!/bin/sh\nexit 97\n' > "$stub_dir/cp"
  chmod +x "$stub_dir/cp"

  # --- Scenario A: checked_restore, deterministic restore failure --------
  sandbox=$(mktemp -d) && restore_dirs+=("$sandbox")
  printf 'original-bytes\n' > "$sandbox/orig"
  printf 'MUTATED\n'        > "$sandbox/live"
  out=""; rc=0
  out=$(PATH="$stub_dir:$PATH" checked_restore "$sandbox/live" "$sandbox/orig" 2>&1) && rc=0 || rc=$?
  [[ $rc -eq 1 ]] || fail_restore_mode "A: checked_restore did not fail on impossible restore (rc=$rc)"
  [[ "$out" == "frontmatter restore failed: $sandbox/live" ]] \
    || fail_restore_mode "A: failure was not reported loudly (output: $out)"
  cmp -s "$sandbox/orig" <(printf 'original-bytes\n') || fail_restore_mode "A: recovery bytes lost"
  cmp -s "$sandbox/live" <(printf 'MUTATED\n') || fail_restore_mode "A: live clobbered by an unverified restore"
  echo "restore failure A: loud failure + recovery bytes preserved"

  # --- Scenario B: first EXIT-restore fails; second must still run -------
  sel_dir=$(mktemp -d) && restore_dirs+=("$sel_dir")
  # Selective stub: fails only for the architect live target, so the first
  # restore fails and the second must still execute.
  real_cp=$(command -v cp)
  {
    printf '#!/bin/sh\n'
    printf 'case "$*" in *architect.live*) exit 97;; esac\n'
    printf 'exec %s "$@"\n' "$real_cp"
  } > "$sel_dir/cp"
  chmod +x "$sel_dir/cp"

  sandbox=$(mktemp -d) && restore_dirs+=("$sandbox")
  printf 'architect-original\n' > "$sandbox/architect.orig"
  printf 'architect-MUTATED\n'  > "$sandbox/architect.live"
  printf 'reviewer-original\n'  > "$sandbox/reviewer.orig"
  printf 'reviewer-MUTATED\n'   > "$sandbox/reviewer.live"
  backup="$sandbox/backup"
  mkdir "$backup"
  cp "$sandbox/architect.orig" "$backup/architect.orig"
  cp "$sandbox/reviewer.orig"  "$backup/reviewer.orig"
  out=""; rc=0
  out=$(PATH="$sel_dir:$PATH" frontmatter_exit_restore \
        "$sandbox/architect.live" "$backup/architect.orig" \
        "$sandbox/reviewer.live"  "$backup/reviewer.orig" "$backup" 2>&1) && rc=0 || rc=$?
  [[ $rc -eq 1 ]] || fail_restore_mode "B: exit handler did not exit nonzero after restore failure (rc=$rc)"
  cmp -s "$sandbox/reviewer.live" "$sandbox/reviewer.orig" \
    || fail_restore_mode "B: second restore did not run after the first failed"
  [[ "$out" == *"architect rc=1"* && "$out" == *"reviewer rc=0"* ]] \
    || fail_restore_mode "B: both restore statuses were not recorded (output: $out)"
  cmp -s "$sandbox/architect.live" <(printf 'architect-MUTATED\n') \
    || fail_restore_mode "B: failed restore was reported as successful"
  cmp -s "$backup/architect.orig" "$sandbox/architect.orig" \
    && cmp -s "$backup/reviewer.orig" "$sandbox/reviewer.orig" \
    || fail_restore_mode "B: backup (recovery bytes) not preserved"
  echo "restore failure B: first failure does not skip the second; backup preserved; exit nonzero"

  # --- Scenario C: EXIT-restore success path ------------------------------
  sandbox=$(mktemp -d) && restore_dirs+=("$sandbox")
  printf 'architect-original\n' > "$sandbox/architect.orig"
  printf 'architect-MUTATED\n'  > "$sandbox/architect.live"
  printf 'reviewer-original\n'  > "$sandbox/reviewer.orig"
  printf 'reviewer-MUTATED\n'   > "$sandbox/reviewer.live"
  backup="$sandbox/backup"
  mkdir "$backup"
  cp "$sandbox/architect.orig" "$backup/architect.orig"
  cp "$sandbox/reviewer.orig"  "$backup/reviewer.orig"
  out=""; rc=0
  out=$(frontmatter_exit_restore \
        "$sandbox/architect.live" "$backup/architect.orig" \
        "$sandbox/reviewer.live"  "$backup/reviewer.orig" "$backup" 2>&1) && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || fail_restore_mode "C: success path exited nonzero (rc=$rc, output: $out)"
  cmp -s "$sandbox/architect.live" "$sandbox/architect.orig" \
    && cmp -s "$sandbox/reviewer.live" "$sandbox/reviewer.orig" \
    || fail_restore_mode "C: files not restored byte-identically"
  [[ ! -d "$backup" ]] || fail_restore_mode "C: backup dir not removed after both restores verified"
  echo "restore success C: both restored byte-identically; backup removed"
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
  lane=polytoken/subagents/review-correctness.md

  # Preserve the untouched originals; these are the sole recovery bytes.
  cp "$architect" "$backup/architect.orig"
  cp "$lane"   "$backup/lane.orig"

  # Over-written EXIT trap: self-heals any mid-mutation failure via
  # frontmatter_exit_restore, which restores BOTH files independently
  # (records both statuses — a first-restore failure must never prevent the
  # second from running), deletes the backup dir ONLY if both restores verify
  # byte-identical, otherwise preserves it and exits 1 loudly.
  trap 'frontmatter_exit_restore "$architect" "$backup/architect.orig" "$lane" "$backup/lane.orig" "$backup"' EXIT

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

  # --- Mutation 2: drop the fallback_models entry (review-correctness) ----
  awk '{ if (done || $0 != "    - codex/gpt-5.6-luna(high)") print; else done = 1 }' \
      "$lane" > "$backup/m2.md"
  if cmp -s "$lane" "$backup/m2.md"; then
    echo "frontmatter mutation 2 had no effect" >&2
    exit 1
  fi
  mv "$backup/m2.md" "$lane"
  mutation_rejected review-correctness
  checked_restore "$lane" "$backup/lane.orig"
  echo "frontmatter mutation 2 restored: review-correctness"

  # --- Mutation 3: same-membership reorder of tools (review-correctness) --
  # The unified lanes pin a single fallback, so fallback_models has no order
  # to reorder; the same order-sensitive comparison contract is exercised on
  # the tools array instead (same membership, different order must still be
  # rejected by the exact-order tools check).
  awk '{ if ($0 == "  tools: [file_read, glob, grep, skill]") print "  tools: [glob, file_read, grep, skill]"; else print }' \
      "$lane" > "$backup/m3.md"
  if cmp -s "$lane" "$backup/m3.md"; then
    echo "frontmatter mutation 3 had no effect" >&2
    exit 1
  fi
  mv "$backup/m3.md" "$lane"
  mutation_rejected review-correctness
  checked_restore "$lane" "$backup/lane.orig"
  echo "frontmatter mutation 3 restored: review-correctness"

  # Final belt-and-suspenders verification before EXIT trap cleanup.
  cmp -s "$architect" "$backup/architect.orig" || { echo "final verify failed: agent-workflow-architect" >&2; exit 1; }
  cmp -s "$lane"      "$backup/lane.orig"      || { echo "final verify failed: review-correctness" >&2; exit 1; }
  echo "frontmatter mutation files restored byte-identically"
  exit 0
fi

if [[ "${1:-}" == --inventory ]]; then
  validate_inventory
  exit 0
fi

validate_implementer_model_contract
validate_inventory
while IFS= read -r persona; do
  validate_persona "$persona"
done < <(manifest_names)
echo "${#subagent_manifest[@]} model assignments verified"
echo "all machine-consumed persona contracts passed; Markdown content review is manual"
