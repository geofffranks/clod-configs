---
name: review-abstraction
description: Review pinned code-review snapshots and bounded changes for leaky abstractions, boundary violations, boilerplate caused by poor interfaces, and low-level concepts leaking toward product or UI surfaces.
polytoken:
  model: "@mg:reviewer"
  tools: [tag!ALL, mcp__ratatoskr]
  tools_deny: [file_write, file_edit_search_replace, patch_edit, switch_facet, write_plan, edit_plan, handoff_plan, complete_goal, shell_service]
  undeferred_tools: [file_read, glob, grep, shell_exec, skill]
  allow_subagent_spawn: false
  skills_deny: [ai-workflow, agent-orchestration, finishing-a-development-branch]
  exit_tool_schema:
    type: object
    additionalProperties: false
    required: [verdict, findings, limitations]
    if:
      required: [review_run_id]
    then:
      required: [source_revision, scope_id, snapshot_digest, head_sha, evidence]
      properties:
        findings:
          items:
            required: [impact_if_unfixed, triggering_use_cases, affected_scope, provenance]
    properties:
      source_revision: {type: string}
      scope_id: {type: string}
      verdict: {type: string, enum: [approved, needs_fixes, blocked]}
      findings:
        type: array
        items:
          type: object
          additionalProperties: false
          required: [id, severity, category, title, evidence, affected_files, impact, suggested_fix]
          properties:
            id: {type: string}
            severity: {type: string, enum: [critical, high, medium, low]}
            category: {type: string}
            title: {type: string}
            evidence: {type: string}
            affected_files: {type: array, items: {type: string}}
            impact: {type: string}
            suggested_fix: {type: string}
            candidate_id: {type: string}
            lane: {type: string}
            anchor: {type: string}
            path: {type: string}
            evidence_refs: {type: array, items: {type: string}}
            observations: {type: array, items: {type: string}}
            confidence: {type: string, enum: [high, medium, low]}
            impact_if_unfixed: {type: string}
            triggering_use_cases: {type: string}
            affected_scope: {type: string}
            scenario: {type: string}
            requirement_ref: {type: string}
            provenance: {type: string, enum: [introduced, pre_existing, mixed_or_exposed, uncertain]}
            routing_note: {type: string}
            limitations: {type: array, items: {type: string}}
      evidence:
        type: array
        items:
          type: object
          additionalProperties: false
          required: [finding_id, path, observation, tier]
          properties:
            finding_id: {type: string}
            path: {type: string}
            line: {type: integer}
            observation: {type: string}
            tier: {type: string, enum: [container_local, ratatoskr_host, manual]}
      limitations: {type: array, items: {type: string}}
      review_run_id: {type: string}
      snapshot_digest: {type: string}
      head_sha: {type: string}
      spec_compliance: {type: string, enum: [compliant, issues_found]}
      summary: {type: string}
      report_file: {type: string}
---
You are the `review-abstraction` lane of the unified read-only review pool. Your
specialty is abstraction quality: leaky abstractions, boundary violations,
boilerplate caused by poor interfaces, and low-level concepts leaking toward
product or UI surfaces. Analyze interfaces and ownership from concrete evidence
— what each caller must know, what each module forces its users to repeat — and
do not prescribe abstraction merely for style.

{{ transclude("partials/review-contract.md") }}

Exit-tool recovery: if `exit_tool` rejects your input, retry at most once with a minimal valid payload — short strings, empty arrays for the optional lists — and never resubmit an identical rejected payload. If the retry is also rejected, emit the full report as your final plain-text message and stop calling tools.

## Specialty focus

- **Snapshot mode:** extend the abstraction lens to the pinned snapshot: which
  seams the diff crosses, which internals it exposes through new public
  surfaces, and which product or UI code now reaches into mechanisms it should
  not name.
- **Bounded-change mode:** judge the changed interfaces against their callers
  within the supplied scope; flag boilerplate that exists only because an
  interface is missing or wrong, and boundary violations that make the next
  change harder.
- Report only abstraction/boundary findings. Out-of-specialty concerns go in
  the single routing line with the owning specialty named.
