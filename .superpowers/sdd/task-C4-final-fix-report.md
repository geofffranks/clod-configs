# C4 final-review fix batch report

## Implemented

- Tightened `home/grep-guard/hook.sh` canonical validation so `max_results` must be an integer from 1 through 20. Adapter malformed-input handling remains unchanged, and canonical denials do not rewrite input.
- Added `home/grep-guard` and `home/large-read-guard` to the README Polytoken compatibility source inventory.
- Corrected `scripts/test-install-polytoken.sh` to assert the four shipped subagents: `implementer.md`, `researcher.md`, `reviewer.md`, and `validator.md`.
- Removed the duplicated bounded-exploration sentence from `polytoken/subagents/implementer.md`, preserving the exact persona contract wording required by the existing suite.
- Added focused Darwin/BSD portability assertions for `home/large-read-guard/hook.sh`. The hook now invokes `stat`, `readlink`, and `dirname` without GNU-only `--` operands while preserving one-hop symlink handling and fail-open behavior.
- Attempted real implementer and reviewer controller probes. The installed controller reports both facets as unregistered; exact commands and output are recorded in `.superpowers/sdd/c4-subagent-probes.md`. README documents this controller-only limitation and retains prompt-level protections.

## TDD evidence

### RED

Command:

```bash
bash scripts/test-polytoken-hooks.sh
```

Initial adapter-level lower-bound assertion produced the expected adapter error (`malformed Polytoken input`) because adapter canonicalization intentionally rejects non-positive `max_results`. The assertion was corrected to invoke the canonical guard directly, preserving the adapter contract.

The corrected canonical RED invocation produced no JSON decision for `max_results=0` (and therefore failed the exact-one-object assertion), demonstrating the missing canonical lower-bound denial. The Darwin portability assertions were added in the same focused test batch with utility shims that reject GNU `--` operands.

### GREEN

Command:

```bash
bash scripts/test-polytoken-hooks.sh
```

Result: `polytoken hook adapter: PASS`.

## Verification

- `bash scripts/test-polytoken-hooks.sh` — PASS.
- `bash scripts/test-polytoken-subagents.sh` — PASS; all persona/model/contract assertions passed.
- `bash scripts/test-polytoken-contracts.sh` — PASS (`polytoken contract fixtures: PASS`).
- `bash scripts/test-polytoken-artifacts.sh` — PASS (`OK: all polytoken artifact assertions passed`).
- `POLYTOKEN_USER_CONFIG_DIR=/home/dev/.config/polytoken bash scripts/test-install-polytoken.sh` — PASS, `104 passed, 0 failed`; valid live config was present at `/home/dev/.config/polytoken/config.yaml`.
- `bash -n home/grep-guard/hook.sh home/large-read-guard/hook.sh scripts/test-polytoken-hooks.sh scripts/test-install-polytoken.sh scripts/test-polytoken-subagents.sh scripts/test-polytoken-contracts.sh scripts/test-polytoken-artifacts.sh` — PASS.
- JSON validation with `jq -e` for `polytoken/hooks.json` and all `scripts/fixtures/polytoken-hooks/*.json` — PASS.
- YAML validation with `yq -e` for `polytoken/config.recommended.yaml` and `polytoken/permissions.recommended.yaml` — PASS.
- Final focused rerun after all edits: `bash scripts/test-polytoken-hooks.sh` — PASS; JSON/YAML validation — PASS.

## Subagent probe evidence

See `.superpowers/sdd/c4-subagent-probes.md`. Both attempted commands failed before session creation with:

```text
Error:   × exec facet "implementer" is not registered
Error:   × exec facet "reviewer" is not registered
```

No unsupported subagent hook-execution claim is made.

## Files changed

Tracked:

- `README.md`
- `home/grep-guard/hook.sh`
- `home/large-read-guard/hook.sh`
- `polytoken/subagents/implementer.md`
- `scripts/test-install-polytoken.sh`
- `scripts/test-polytoken-hooks.sh`

Required evidence/report artifacts:

- `.superpowers/sdd/c4-subagent-probes.md`
- `.superpowers/sdd/task-C4-final-fix-report.md`

No `polytoken-container/Dockerfile` or unrelated tracked file was changed.

## Self-review

- Confirmed grep lower-bound validation is canonical-only and does not weaken adapter malformed-input behavior.
- Confirmed large-read Darwin changes are limited to supported utility invocation syntax; one-hop and nested-link fail-open assertions remain covered.
- Confirmed README limitation language does not claim ordinary hooks execute inside unregistered subagent facets.
- Confirmed installer inventory matches the four files actually shipped by source and installer.
- Confirmed final changed-path inspection contains only the six intended tracked paths plus the two required ignored evidence/report artifacts.

## Concerns

Real implementer/reviewer subagent hook execution could not be exercised because the installed Polytoken controller does not register those facets. This is documented truthfully; prompt-level protections remain the supported guard.
