# Code Review Reporting

Produce a local report with: review identity and coverage (repository/PR or branch, base/head/merge-base, snapshot digest, capture interval, lane and verifier status, limitations); merge-readiness exactly `ready`, `not_ready`, or `blocked` with reason; PR/branch findings ranked by severity; pre-existing findings in a separate ranked bucket; follow-up dispositions; rejected/uncertain candidate counts; and coverage limitations.

Each finding has a stable ID, summary, exact location/evidence, impact, suggested fix, severity, confidence, and provenance evidence. Never merge pre-existing and PR-actionable buckets, infer resolution from a moved line or absence, or suppress rejected claims. Any missing, stale, unverifiable, or incomplete evidence produces `blocked`, never a clean or merge-ready result.
