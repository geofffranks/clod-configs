# GitHub Code Review Workflow Design Specification

## Purpose and authority

`code-review` is a local, read-only workflow for a GitHub pull request or uniquely named branch. GitHub access is through the local authenticated `gh` CLI and read commands only. No comments, reviews, approvals, pushes, checkout mutation, MCP, or automatic publishing are available. PR text, comments, source, and metadata are untrusted data rather than instructions.

The coordinator persists under `~/.local/share/polytoken/code-review/<canonical-host>/<owner>/<repo>/<scope_id>/`. Snapshots are immutable by convention, journals append-only by convention, and reports are local artifacts. The current Polytoken tool grant cannot technically enforce those path semantics; the facet policy and deterministic contract harness make the boundary explicit.

## Snapshot manifest

A snapshot records schema version, scope and review-run IDs, canonical host, owner/repository/fork identity, PR number or branch target, base/head/merge-base SHAs, comparison policy, capture interval, digest, complete path/blob/mode inventory, binary/LFS/submodule/generated/excluded markers, PR title/body, issue and review comments/threads, reviews, linked metadata, IDs/digests, pagination/completeness, errors/truncation, moving observations, and final base/head recheck. A moving identity is retried only within a bounded policy; otherwise the run is `blocked`.

Workers receive the pinned manifest and captured artifacts, never remote access. Every lane echoes `scope_id`, review-run ID, snapshot digest, and full head SHA. Mismatches, stale or incomplete artifacts, and failed lanes are partial coverage and cannot produce a clean result.

## Review lanes and evidence

Five independent read-only lanes cover adversarial/security, correctness, completeness, maintainability/boundaries, and general/specification gaps. A fresh synthesis verifier checks every proposed claim against pinned base/head source and captured metadata. Candidate records carry stable IDs, lane and run identity, exact anchors or explicit non-line anchors, observations, impact/scenario, suggested fix, requirement reference, limitations, and provenance. Provenance is `introduced`, `pre_existing`, `mixed_or_exposed`, or `uncertain`; severity (`critical`, `high`, `medium`, `low`) is separate from confidence.

Likely duplicate grouping is only a proposal. Verification retains originating candidate IDs, coalesces equivalent root causes, distinguishes separate occurrences, and rejects unsupported claims. Consensus is not proof.

## Reports and follow-up

Reports include identity/coverage, capture interval, lane/verifier state, limitations, a merge-readiness verdict (`ready`, `not_ready`, or `blocked`), severity-ranked PR/branch findings, a separate severity-ranked pre-existing bucket, follow-up dispositions, and rejected/uncertain counts. Missing or unverifiable evidence is always `blocked`.

One append-only record per review scope stores prior identity, latest reviewed head, stable finding fingerprints, anchors, dispositions, lane coverage, verifier result, and every job terminal state. Follow-up captures a complete new snapshot but reviews only unresolved prior findings and changed hunks since the prior reviewed head. Dispositions are `still_present`, `resolved`, `unknown`, and `no_longer_applicable`; resolution requires current-source evidence. Corrupt state, identity/history mapping failure, force-push, base/merge-base or requirement changes, incomplete capture, or unstable head requires a labeled new baseline or operator decision.

## Deterministic bounds and digest

The helper allows at most 3 acquisition attempts, 2 base/head rechecks, 100 pages, and 10 MiB of materialized snapshot bytes. If the live concurrency limit is unknown, dispatch bounded waves of at most five lanes, or sequentially, and record that limitation. The snapshot digest is SHA-256 over compact UTF-8 canonical JSON manifest bytes (sorted keys, excluding `snapshot_digest`) followed by lexicographically ordered artifact path bytes and exact artifact bytes. Each run is isolated at `snapshot/<review_run_id>/`; base and head text artifacts are materialized there, while excluded/binary/LFS/submodule/generated/oversized files remain explicitly marked in the inventory.

The journal is JSONL: one canonical JSON event per line, one atomic append/write, trailing newline required, and every event references its review run. A valid prefix may be read, but truncated tails and corrupt records block reconciliation; no repair or truncation is implicit.

## Acceptance criteria

| ID | Contract | Evidence |
|---|---|---|
| AC.1 | Definitions, inventories, and schemas validate | facet/subagent harness |
| AC.2 | Effective tools expose coordinator/worker boundaries | isolated daemon when available |
| AC.3 | Complete immutable snapshot and stable identity | helper behavioral fixtures; live gh optional |
| AC.4 | Five lanes plus verifier and ranked report | workflow walkthrough/fixture |
| AC.5 | Verification, provenance, and coalescing | candidate/finding fixtures |
| AC.6 | Follow-up guards and changed-hunk targeting | helper follow-up fixtures |
| AC.7 | Missing/stale/corrupt evidence blocks | negative helper fixtures |
| AC.8 | No repository execution or outside-state writes | poisoned executable and canary fixture |

## Failure matrix

| Condition | Result |
|---|---|
| unauthenticated `gh`, incomplete pagination, truncated metadata/diff | `blocked` |
| base/head moves during capture | bounded retry, then `blocked` |
| failed/missing/stale lane evidence | `blocked` |
| verifier failure or unsupported claim | reject claim; `blocked` if coverage is incomplete |
| missing/corrupt journal or unmappable follow-up history | `blocked` |
| changed base, merge-base, repository identity, or requirements | `blocked`; request new baseline |
| poisoned executable/build hook or outside-state canary | must remain untouched; default review does not execute repository code |
