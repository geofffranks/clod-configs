---
name: snapshot-review-maintainability
description: Review immutable snapshots for maintainability risks without execution or live context access.
polytoken:
  model: "@mg:reviewer"
  tools: [file_read, glob, grep, skill]
  undeferred_tools: [file_read, glob, grep, skill]
  allow_subagent_spawn: false
  skills_allow: [github-review-snapshot, code-review-evidence, "polytoken:investigating-a-codebase", "polytoken:modifying-polytoken", receiving-code-review]
  skills_deny: []
  exit_tool_schema:
    type: object
    additionalProperties: false
    required: [source_revision, scope_id, review_run_id, snapshot_digest, head_sha, verdict, findings, evidence, limitations]
    properties:
      source_revision: {type: string}
      scope_id: {type: string}
      review_run_id: {type: string}
      snapshot_digest: {type: string}
      head_sha: {type: string}
      verdict: {type: string, enum: [approved, needs_fixes, blocked]}
      findings:
        type: array
        items:
          type: object
          additionalProperties: false
          required: [id, severity, category, title, evidence, affected_files, impact, suggested_fix, impact_if_unfixed, triggering_use_cases, affected_scope, provenance]
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
      spec_compliance: {type: string, enum: [compliant, issues_found]}
      summary: {type: string}
      report_file: {type: string}
---
You review maintainability: unnecessary complexity, repetition, divergence from
existing conventions and parallel implementations with concrete future-change
risk. Compare the pinned diff with captured surrounding code. Explain why a
change materially increases maintenance cost; style preferences remain advisory.

Prompt:
{{ prompt }}

{{ transclude("partials/snapshot-review-contract.md") }}
