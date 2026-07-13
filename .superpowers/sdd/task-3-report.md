# Task 3 report: Polytoken hook protocol adapter

## Status

Complete. The adapter normalizes captured Polytoken hook payloads into the canonical Claude-shaped contract, runs existing canonical policy scripts without modifying them, and translates their results into exactly one Polytoken outcome object.

## TDD evidence

### RED

1. Created `scripts/test-polytoken-hooks.sh` before production code.
2. Ran `bash scripts/test-polytoken-hooks.sh` while `polytoken/hooks/adapter.sh` was absent.
3. Observed exit 1 at the first assertion: `FAIL: stdout was not exactly one JSON object:` (empty stdout because the adapter did not exist).
4. During self-review, added a symlink-escape regression before containment hardening and observed an error-path mismatch, proving the new traversal case exercised unresolved behavior.

### GREEN

Fresh aggregate command after implementation and self-review:

```text
$ bash scripts/test-polytoken-contracts.sh
polytoken contract fixtures: PASS
$ bash scripts/test-polytoken-hooks.sh
polytoken hook adapter: PASS
$ bash scripts/test-hook-config-root.sh
hook config root: PASS
$ bash -n polytoken/hooks/adapter.sh scripts/test-polytoken-hooks.sh
$ shellcheck -e SC2016 polytoken/hooks/adapter.sh scripts/test-polytoken-hooks.sh
$ git diff --check
task 3 aggregate verification: PASS
```

The focused suite covers lexical and symlink traversal rejection; argument, mapping, malformed-input, missing/non-executable hook errors; jq-built shell/read/skill/compact normalization; dynamic prompt/call IDs; stdin session precedence and environment fallback; optional agent identity; canonical allow/deny behavior for no-remote-writes, bash-guard, branch-guard, and git-safe; first/duplicate read and skill state; state isolation under `POLYTOKEN_CONFIG_DIR`; both compaction resets; exactly one stdout object; stderr passthrough; malformed, multiple, unsupported, unexpected event output; and nonzero canonical exits.

## Files

- `polytoken/hooks/adapter.sh`
- `scripts/test-polytoken-hooks.sh`
- `.superpowers/sdd/task-3-report.md`

Canonical policy scripts and fixture captures were not modified.

## Commits

- Implementation: `c478f80` (`feat: adapt canonical hooks for Polytoken`)
- Report: recorded by the subsequent report-only commit.

## Self-review

- Confirmed every adapter outcome path exits zero and writes one JSON object to stdout.
- Confirmed canonical diagnostics are replayed only to stderr.
- Confirmed canonical output is slurped and must contain exactly one JSON object.
- Confirmed `post_compaction` accepts only empty successful canonical output.
- Hardened path handling beyond lexical `..` rejection by checking realpath containment before execution.
- Confirmed staged implementation changed only the two requested code/test files.

## Concerns

- Realpath containment uses `python3`; this repository's canonical hooks already depend on Python in policy paths, but an installation without Python receives an explicit error outcome rather than running a path without containment validation.
- The canonical read-once script chooses `stat` flags from `OSTYPE`. The focused test detects the available `stat` dialect because this harness exposes GNU `stat` on a Darwin-style filesystem path; production behavior remains canonical and unmodified.
- ShellCheck SC2016 is suppressed only for the test file's intentionally single-quoted strings that generate temporary hook scripts; all other ShellCheck checks pass.

## Fix Review

### Status

All Task 3 review findings are fixed in implementation commit `81f390f1689d30774bc6834c3980b240fa69e2be` (`fix: validate canonical hook output structure`).

### RED evidence

Added test-first coverage for missing, null, and wrong-type `hookSpecificOutput`, `permissionDecision`, and deny `permissionDecisionReason`. Every case requires exit 0, exactly one JSON object with `outcome == "error"`, and the exact `malformed canonical output` message. Before the production change:

```text
$ bash scripts/test-polytoken-hooks.sh
FAIL: wrong structural error: {"outcome":"error","message":"polytoken hook hooks/structural-output.sh: unsupported canonical decision"}
[exit 1]
```

This first failure proved a parseable but structurally invalid object bypassed malformed-output classification; the reviewed wrong-type intermediate case also reached an unguarded jq operation under `set -e`.

### GREEN evidence

Exact commands and results after the fix:

```text
$ bash scripts/test-polytoken-contracts.sh && bash scripts/test-polytoken-hooks.sh && bash scripts/test-hook-config-root.sh
polytoken contract fixtures: PASS
polytoken hook adapter: PASS
hook config root: PASS
[exit 0]

$ bash -n polytoken/hooks/adapter.sh scripts/test-polytoken-hooks.sh scripts/test-polytoken-contracts.sh scripts/test-hook-config-root.sh && shellcheck polytoken/hooks/adapter.sh && shellcheck -e SC2016 scripts/test-polytoken-hooks.sh && shellcheck scripts/test-polytoken-contracts.sh scripts/test-hook-config-root.sh
[exit 0; no output]

$ git diff --check
[exit 0; no output]
```

### Review findings addressed

- Guarded canonical schema validation now requires object `hookSpecificOutput`, string `permissionDecision`, and a string `permissionDecisionReason` for deny before nested translation.
- Remaining decision extraction and deny translation jq calls are explicitly guarded and map failure to one error outcome with exit 0.
- Focused tests cover all nine missing/null/wrong-type structural cases and preserve structurally valid unknown string decisions as `unsupported canonical decision`.
- The identity spy now injects and asserts runtime `subagent_id` forwarding alongside `agent_id`.
- `run_adapter` now sets `HOME="$TMP/home"`, making legacy `$HOME/.claude` leak assertions exercise the adapter process's actual HOME.

### Self-review

- Verified the canonical policy remains unchanged: allow and deny translations are identical for valid output, unknown string decisions remain unsupported, and compact still rejects nonempty output.
- Verified every new malformed-structure case emits exactly one error object and exits 0 through the focused suite.
- Verified no adapter interface, path-containment check, stderr isolation, state-root behavior, or canonical hook/fixture file changed.
- Reviewed the committed diff: only `polytoken/hooks/adapter.sh` and `scripts/test-polytoken-hooks.sh` changed in the implementation commit.

### Fix concerns

None beyond the pre-existing portability concerns above.
