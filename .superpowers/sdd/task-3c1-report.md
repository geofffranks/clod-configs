# Task 3C1 report

Status: GREEN

## Scope

Implemented isolated failure coverage and production behavior for Task 3C1 cases 1–8 only. No cleanup cases 9–15, cleanup atomicity changes, stale-target global, installer changes, or artifact staging were added.

## Implementation

- Added `skill_once_test_fail_point`, gated by the active trace handshake and exact recognized value. For this task, only `append` is recognized.
- Added the append failure injection at the centralized `skill_once_append` boundary.
- Changed the hook lifecycle to acquire the addressed session lock before stale cleanup, retain that lock through cleanup and the selected operation, and avoid a second non-idempotent lock acquisition.
- Activated case 4 with an isolated trace directory, matching operation ID, and `SKILL_ONCE_TEST_FAIL_POINT=append`.
- Existing cases 1–3 and 5–8 remain isolated with delegated PATH wrappers and state/leak assertions.

## TDD evidence

- RED baseline: `bash scripts/test-skill-once.sh` passed before the new fail-point activation, demonstrating the existing cases did not exercise append fault injection. The task’s expected defects were confirmed by the prior isolated harness evidence: cleanup could mutate `.last-cleanup` while the addressed lock was pre-held, and directory-target append emitted `Is a directory` before suppression under the original ordering.
- RED integration during implementation: the first lock-first hook edit acquired the lock and then reacquired it in the operation branches; the focused test exited 4 silently. This proved the hook needed one selected operation label and one held lock, not a second lock.
- GREEN: `bash -n home/skill-once/state.sh home/skill-once/hook.sh home/skill-once/compact.sh scripts/test-skill-once.sh && bash scripts/test-skill-once.sh` -> `skill-once lifecycle: PASS`, with empty stderr. This includes all eight Task 3C1 cases and lifecycle/race coverage.

The committed baseline already had the required append redirection form `printf ... 2>/dev/null >>"$SKILL_ONCE_CACHE_FILE"`; it was verified unchanged rather than rewritten.

## Verification

- Syntax checks for state, hook, compact, and lifecycle test script: pass.
- `bash scripts/test-skill-once.sh`: pass, exact output `skill-once lifecycle: PASS`, stderr empty.
- `bash scripts/test-hook-config-root.sh`: pass, `hook config root: PASS`.
- `bash scripts/test-install.sh`: pass, `81 passed, 0 failed`.
- Stats prohibition grep: pass; no `stats.jsonl`, `.stats.lock`, or `append_stat` references.
- Sibling state-source grep: pass for hook and compact adapters.
- `git diff --check`: pass.

## Files changed

- `home/skill-once/state.sh`
- `home/skill-once/hook.sh`
- `scripts/test-skill-once.sh`
- This report remains uncommitted under `.superpowers/`.

## Self-review

The fail-point predicate is inactive unless the trace handshake has validated the operation ID and label, and it recognizes only `append` for 3C1. The hook holds exactly one addressed session lock while running cleanup and the operation, preserving the required lock-first ordering. The diff contains no cleanup atomicity work or 3C2-only state. All required checks passed with pristine adapter output.

## Concerns

None beyond the existing shell-based fail-open design. The report and plan/spec artifacts are intentionally uncommitted.

## Review-finding fixes

Fixed the six Important Task 3C1 review findings in `scripts/test-skill-once.sh` only:

- Case 1 hash wrappers now fail only on the adapter signatures and delegate all other calls.
- Case 6 jq wrapper now matches the production nine-argument invocation and filter at `$8`.
- Cases 1–8 and force-failure cases 5–7 capture stdout in files and assert those files are empty, preserving newline-only output detection.
- Case 4 keeps its seeded regular file, snapshots bytes immediately before invocation, and asserts byte identity, regular-file type, unchanged paths, and no trace markers.
- Case 8 now snapshots and compares the complete config path set.

## Review-finding verification

- `bash -n scripts/test-skill-once.sh`: pass.
- `bash scripts/test-skill-once.sh`: pass; exact output `skill-once lifecycle: PASS`.
- `bash scripts/test-hook-config-root.sh`: pass; exact output `hook config root: PASS`.
- `bash scripts/test-install.sh`: pass; exact summary `81 passed, 0 failed`.
- `git diff --check`: pass.

Files changed for this fix: `scripts/test-skill-once.sh` and this report. Production files remain unchanged.
