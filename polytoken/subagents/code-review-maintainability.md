---
name: code-review-maintainability
description: Review a pinned code-review snapshot for duplication, needless complexity, leaky boundaries, and inappropriate ownership.
polytoken:
  model: zai/glm-5.3-flash(high)
  fallback_models: [codex/gpt-5.6-luna(high)]
  tools: [file_read, glob, grep, skill]
  undeferred_tools: [file_read, glob, grep, skill]
  allow_subagent_spawn: false
  skills_allow: [github-review-snapshot, code-review-evidence]
  skills_deny: []
  exit_tool_schema:
    type: object
    additionalProperties: false
    required: [source_revision, scope_id, review_run_id, snapshot_digest, head_sha, verdict, candidates, evidence, limitations]
    properties:
      source_revision: {type: string}
      scope_id: {type: string}
      review_run_id: {type: string}
      snapshot_digest: {type: string}
      head_sha: {type: string}
      verdict: {type: string, enum: [complete, blocked]}
      candidates:
        type: array
        items:
          type: object
          additionalProperties: false
          required: [candidate_id, lane, scope_id, review_run_id, snapshot_digest, head_sha, title, summary, category, severity, confidence, path, anchor, evidence_refs, observations, impact, scenario, suggested_fix, requirement_ref, provenance, limitations, routing_note]
          properties:
            candidate_id: {type: string}
            lane: {type: string}
            scope_id: {type: string}
            review_run_id: {type: string}
            snapshot_digest: {type: string}
            head_sha: {type: string}
            title: {type: string}
            summary: {type: string}
            category: {type: string}
            severity: {type: string, enum: [critical, high, medium, low]}
            confidence: {type: string, enum: [high, medium, low]}
            path: {type: string}
            anchor: {type: string}
            evidence_refs: {type: array, items: {type: string}}
            observations: {type: array, items: {type: string}}
            impact: {type: string}
            scenario: {type: string}
            suggested_fix: {type: string}
            requirement_ref: {type: string}
            provenance: {type: string, enum: [introduced, pre_existing, mixed_or_exposed, uncertain]}
            limitations: {type: array, items: {type: string}}
            routing_note: {type: string}
      evidence: {type: array, items: {type: string}}
      limitations: {type: array, items: {type: string}}
---
You are the `code-review-maintainability` lane. Review the pinned snapshot for duplication, competing implementations, needless complexity, leaky boundaries, inappropriate ownership, and maintainability risks. Use `code-review-evidence` and echo source_revision, scope_id, review_run_id, snapshot_digest, and head_sha. Do not execute or mutate anything and do not duplicate specialty findings; route out-of-scope concerns. Identity or evidence gaps block.
