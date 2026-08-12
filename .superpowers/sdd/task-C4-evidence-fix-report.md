# C4 evidence wording fix report

## Implemented

- Corrected the bounded README evidence wording in `README.md`.
- The README now states that the installed controller rejected both implementer and reviewer probes before session creation because those facets were unregistered, so ordinary subagent hook execution could not be tested.
- Preserved the prompt-level bounded-search and ranged-read protections and did not claim controller-only hook enforcement as observed runtime coverage.
- Did not alter `.superpowers/sdd/c4-subagent-probes.md` or unrelated files.

## Verification

- `bash scripts/test-polytoken-subagents.sh` — PASS; all persona contract assertions passed.
- `bash scripts/test-polytoken-hooks.sh` — PASS (`polytoken hook adapter: PASS`).
- `bash scripts/test-polytoken-contracts.sh` — PASS (`polytoken contract fixtures: PASS`).
- `bash scripts/test-polytoken-artifacts.sh` — PASS (`OK: all polytoken artifact assertions passed`).
- `POLYTOKEN_USER_CONFIG_DIR="$HOME/.config/polytoken" bash scripts/test-install-polytoken.sh` — PASS (`104 passed, 0 failed`).
- `git diff --check` — PASS.

## TDD evidence

This task was a bounded documentation-only correction; no executable behavior or tests were added, so RED/GREEN test steps were not applicable. The required regression and artifact suites were run after the README edit.

## Files changed

- `README.md`
- `.superpowers/sdd/task-C4-evidence-fix-report.md`

The probe evidence file and all unrelated files remain unchanged.

## Self-review

- Confirmed the README wording matches the authoritative probe evidence: both facets were unregistered and both probes failed before session creation.
- Confirmed the prompt-level protection sentence remains present.
- Confirmed the working-tree diff before report creation contained only the intended README wording change.
- Confirmed `git diff --check` passed.

## Concerns

Ordinary implementer/reviewer subagent hook execution remains untested because the installed controller does not register those facets. This is documented as an evidence limitation; no runtime enforcement claim is made.
