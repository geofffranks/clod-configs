---
name: code-review-reporting
description: Render evidence-grounded code-review reports with ranked actionable and pre-existing findings.
---

# Code Review Reporting

Produce a local report with: review identity and coverage (repository/PR or branch, base/head/merge-base, snapshot digest, capture interval, lane and verifier status, limitations); merge-readiness exactly `ready`, `not_ready`, or `blocked` with reason; PR/branch findings ranked by severity; pre-existing findings in a separate ranked bucket; follow-up dispositions; rejected/uncertain finding counts; and coverage limitations.

Each finding has a stable ID, summary, exact location/evidence, **What happens if left unfixed** (`impact_if_unfixed`, including concrete consequence and severity rationale), **Triggering use cases / reproduction conditions** (`triggering_use_cases`, with concrete inputs, workflows, states, or environmental conditions), and **Affected scope** (`affected_scope`, including exposed users/components/data/operations and meaningful non-triggering boundaries), plus a suggested fix, severity, confidence, and provenance evidence. Reject vague, speculative, or unsupported consequence, trigger, or scope claims. Never merge pre-existing and PR-actionable buckets, infer resolution from a moved line or absence, or suppress rejected claims. Any missing, stale, unverifiable, or incomplete evidence produces `blocked`, never a clean or merge-ready result.
