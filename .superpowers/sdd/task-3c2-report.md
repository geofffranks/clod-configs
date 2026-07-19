# Task 3C2 review-fix report

## Implemented

- Removed the unused `run_cleanup_case` helper.
- Updated case 10 to assert the cleanup marker checksum is preserved when `cleanup-marker-write` is injected.
- Reworked cases 11 and 12 to use distinct caller and stale-session hashes. Case 11 now verifies busy-target retention, continued deletion of a second stale target, and caller append. Case 12 verifies stale-delete failure retains the stale file and releases its target lock while the caller append succeeds.
- Updated cases 13, 14, and inert bogus/partial controls to use PostToolUse events, verify the caller cache entry, and enforce a sub-3-second elapsed bound.
- Replaced the vacuous adapter mismatch control with a helper-level `skill_once_lock` label-mismatch test that verifies no trace markers are created.

## TDD evidence

- RED: The baseline lifecycle script passed while cases 11/12 were vacuous and the mismatch assertion was deliberately skipped; the new focused assertions therefore exposed the missing behavioral coverage. During iteration, the first corrected run failed at case 10 because the checksum was still aimed at the stale file rather than the preserved marker.
- GREEN: `bash -n scripts/test-skill-once.sh && bash scripts/test-skill-once.sh` passed with pristine output: `skill-once lifecycle: PASS`.

## Verification

- `bash -n scripts/test-skill-once.sh` — passed.
- `bash scripts/test-skill-once.sh` — passed; printed `skill-once lifecycle: PASS` with empty stderr.
- `bash scripts/test-install.sh` — passed; `81 passed, 0 failed`.
- `bash scripts/test-hook-config-root.sh` — passed; `hook config root: PASS`.

## Files changed

- `scripts/test-skill-once.sh`
- `.superpowers/sdd/task-3c2-report.md`

## Self-review and concerns

The production `home/skill-once/state.sh` was not changed; its target-unlock fix was already present as specified. No remaining concerns.
