# Task 3 Report: Workflow Facets and Installer Support

Worktree: `agent-workflow-facets` (base / reviewed head `828e28d`).
Status: **DONE** — all required checks green; commit made, not pushed.

## What was implemented

1. **`polytoken/facets/workflow-designer.md`** — designer facet with the brief's
   exact frontmatter (model pin `codex/gpt-5.6-luna`, fallback `[zai/glm-5.2]`,
   exact `tools`/`tools_deny`/`undeferred_tools`, `skills_allow
   [tag!research, brainstorming, agent-orchestration]`, exact
   `autonomous_hint`/`compaction_hint`, no `facet_transitions` block) plus the
   prompt contract: read-only direct tools with disclosed (non-runtime)
   delegation boundary; condition-based consultation limited to
   `agent-workflow-architect` and read-only specialists; max 4 concurrent, no
   duplicate active assignments; explicit `plan-reviewer` dispatch,
   rebut-or-fix loop, explicit operator approval, `handoff_plan` target
   `workflow-delivery` disclosed as a prompt contract (any target argument is
   technically accepted); ratatoskr inspect-before-execute/reconnect rules;
   three evidence tiers. Body starts with the facet base transclusion.

2. **`polytoken/facets/workflow-delivery.md`** — delivery facet with exact
   frontmatter (full mutation tool surface, plan tools denied,
   `facet_transitions.workflow-designer.allowed: true` with condition
   `Material redesign requires renewed planning and operator approval.`,
   approved-design hints), plus the prompt contract:
   `approval provenance unverified` default with plain reporting; material
   redesign returns to designer; risk-based worktree/branch isolation with
   exact `cwd` pass-through to writers; serialized overlap / bounded parallel
   writers with disjoint ownership and one integration owner; no overwrite of
   unexpected work; bounded-slice delegation to
   `agent-workflow-engineer`; change-class test policy (no TDD for
   prompts/docs, validate/effective exposure for declarative, RED/GREEN for
   executable); one-architect-review minimum with second fresh review for
   high-risk surfaces; evidence tiers; no remote writes; verify before
   `complete_goal`; ratatoskr rules.

3. **`scripts/install-polytoken.sh`** — minimal change: the subagent copy loop
   is restricted to top-level `*.md` (`find ... -maxdepth 1 -type f -name
   '*.md'`) and a new facet block copies top-level `*.md` from
   `polytoken/facets` to `$DEST/facets/` through the existing
   `copy_managed_file` conflict/diff/backup/idempotence behavior. No deletion
   of unrelated destination entries; installer remains a copy manager (no new
   preflight transaction).

4. **`scripts/test-install-polytoken.sh`** — TDD additions: P1 corrected to
   expect exactly 14 subagents + 2 facets; new scenarios covering
   top-level-only copy (backup/generated artifacts excluded for both facets
   and subagents), conflict decline (destinations preserved, no install) and
   overwrite variants, backup creation, unrelated destination facets/subagents
   preserved, and second-run idempotence (11 new assertions).

5. **`scripts/test-polytoken-workflow-facets.sh`** — dedicated contract
   harness, 8 modes: `--inventory`, `--validate-definitions`,
   `--designer-authority`, `--approval-contract`, `--delivery-policy`,
   `--ratatoskr`, `--live-gateway` (opt-in only), `--docs` (Task 4 stub that
   reports PENDING rather than passing). Default full run invokes the
   mandatory non-doc checks. Runtime evidence for authority, handoff,
   conditional transition, and MCP grants is taken against an **isolated
   `polytoken daemon`** (isolated global-config copy with only the managed
   facets/subagents, own sessions dir, fresh credential file, random local
   port) via documented endpoints: `GET /tools/effective?facet=`,
   `POST /facet`, `GET /state`, `POST /interrogative/{id}/respond`. If the
   isolated daemon cannot start, the affected runtime assertions **fail** —
   static checks never substitute.

## TDD evidence (installer behavior)

- **RED** — new expectations added to `test-install-polytoken.sh` first;
  command: `bash scripts/test-install-polytoken.sh` →
  `130 passed, 11 failed`. All 11 failures were the new facet/top-level
  expectations (P1 inventory expected 14 subagents + 2 facets; the installer
  installed 0 facets and any arbitrary subagent-dir file; top-level-only
  scenarios saw backups/artifacts installed).
- **GREEN** — after the minimal installer change: new scenarios pass, then
  full suite: `bash scripts/test-install-polytoken.sh` →
  `141 passed, 0 failed`. Re-verified fresh before commit: 141/141.
- The facet harness is the contract test suite for two declarative
  definitions (change class: declarative — validate + activate + effective
  exposure, no forced RED/GREEN per the approved design). Its runtime
  assertions are real daemon calls; a daemon-start failure fails the mode.

## Required checks (commands and results, fresh pre-commit)

| Command | Result |
|---|---|
| `bash -n scripts/test-polytoken-workflow-facets.sh` | OK |
| `bash -n scripts/install-polytoken.sh` | OK |
| `bash -n scripts/test-install-polytoken.sh` | OK |
| `bash scripts/test-polytoken-workflow-facets.sh` (full default) | **121 passed, 0 failed**, exit 0 — transcript: `.superpowers/sdd/task-3-evidence.md` |
| focused `--inventory` | 8/8 |
| focused `--validate-definitions` | 16/16 + limitation note |
| focused `--designer-authority` | 22/22 (incl. 4 runtime) |
| focused `--approval-contract` | 26/26 (incl. 11 runtime) |
| focused `--delivery-policy` | 33/33 |
| focused `--ratatoskr` | 16/16 (incl. 4 runtime) |
| `--live-gateway` (no opt-in) | explicit SKIP (offline CI expected) |
| `--docs` | PENDING — reported as pending, not passed (Task 4) |
| `bash scripts/test-install-polytoken.sh` | 141 passed, 0 failed |
| `bash scripts/test-polytoken-subagents.sh` | all persona contract assertions passed (14/14); subagent definitions and harness unmodified |
| `polytoken --config-dir <isolated> validate facet|subagent …` | 2 facets + 14 subagents all pass |

### Runtime (daemon-backed) evidence highlights

- `GET /tools/effective?facet=workflow-designer` / `workflow-delivery`:
  designer exposes exactly its read-only surface (no `file_write`,
  `file_edit_search_replace`, `shell_exec|shell_monitor|shell_service`, `lsp`,
  `switch_facet`, `complete_goal`); delivery exposes all mutators and denies
  plan tools; both expose only the `mcp__ratatoskr__*` MCP namespace (no
  `tag!ALL_MCP` grants); model pin `codex/gpt-5.6-luna` resolves.
- Approved handoff: `POST /facet {"facet":"workflow-delivery"}` from designer →
  HTTP 200, `GET /state` shows active facet `workflow-delivery`; unknown facet
  → 422.
- Conditional return: delivery → designer raises a confirmation
  interrogative whose question is exactly `Material redesign requires
  renewed planning and operator approval.`; answering
  `POST /interrogative/{id}/respond {"kind":"confirmation_answer",
  "confirmed":true}` → 200, the in-flight `POST /facet` completes 200, and the
  session log records
  `{"type":"facet_switch","from_facet":"workflow-delivery",
  "to_facet":"workflow-designer",…}`. Unlisted transitions (execute→designer,
  designer→delivery) are unconditioned (immediate 200).

## Files changed

- A `polytoken/facets/workflow-designer.md`
- A `polytoken/facets/workflow-delivery.md`
- A `scripts/test-polytoken-workflow-facets.sh`
- M `scripts/install-polytoken.sh`
- M `scripts/test-install-polytoken.sh`

No README changes (Task 4). No subagent definitions or subagent harness
modified. Only these five files are committed; no push (per brief).

## Self-review findings (issues fixed pre-commit)

- **yq alt-operator semantics (harness, 2 sites):** `false // true` prints
  `true` (yq alt treats `false` as empty). This silently skipped enabling
  referenced disabled models (daemon boot failed: `subagent
  'agent-workflow-architect' references unknown model 'zai/glm-5.2'`) and
  suppressed the live-limitation note. Both helpers now read the raw value;
  a dead `disabled[]` block and unused `disabled_count` helper were removed.
- **Session-log path (harness):** the `session_id` field of `GET /state` is
  not the on-disk session directory name; the log is now located via
  `find $sessions/dir -name log.jsonl` (the isolated sessions dir belongs to
  the test daemon alone).
- **Async gateway connect (harness):** the daemon's ratatoskr connection
  lands ~10–20 s after boot; `--ratatoskr` now polls up to 60 s for
  `mcp__ratatoskr__*` to appear in the effective plan. Timeout is a real
  failure, not a static substitution.
- **Phrase drift (harness):** one delivery phrase was corrected to the
  facet's exact text: `executable (scripts, hooks, code, MCP)`.

## Limitations / honest reporting

- **Live config disables `zai/glm-5.2`** (pinned/fallback reference of
  managed definitions). The harness enables it **only in the isolated copy**
  and prints: `limitation: live config disables the referenced model(s)
  enabled only in the isolated copy: zai/glm-5.2`. It enables only
  referenced disabled models — enabling *all* disabled entries is rejected by
  the daemon's strict config check (`custom model overrides require a
  provider reference` for entries like `zai/glm-4.7`).
- **Validation semantics observed:** `polytoken validate facet` does not
  check model references; `polytoken validate subagent` does (6 managed
  subagents pin `zai/glm-5.2`).
- **Evidence tiers:** all runtime evidence here is container-local (isolated
  daemon + config). Model API liveness and gateway upstream health are
  host-tier evidence via ratatoskr and are not asserted by these checks.
- **Live gateway smoke** runs only with `POLYTOKEN_LIVE_GATEWAY=1`; default
  runs print an explicit SKIP, and the note documents that even the
  opt-in probe is reachability-only.
- **Docs validation** is intentionally PENDING for Task 4; the full run
  reports "not passed".
- **Approval mechanism in the runtime check:** the operator-approved handoff
  is exercised through the daemon's documented `POST /facet` controller API;
  the in-session operator approval itself is a prompt contract (the designer
  has no `switch_facet` and its prompt forbids switching without approval),
  which is exactly the disclosed boundary the design approves.

## Corrective descendant (b9ce51d follow-up)

- **RED reproduction:** `bash scripts/test-polytoken-workflow-facets.sh --selftest` on b9ce51d produced **16 passed, 1 failed**, specifically `cleanup: unresolved child workdir retained`, plus `wait_for: No record of process`.
- **Fix:** isolated the unresolved fixture under `/dev/shm` outside tracked temporary ancestors; made the unresolved fixture a confirmed-dead non-child PID; replaced unconditional waits with a bounded no-op reap helper for confirmed-dead PIDs. Existing cleanup behavior remains: independently process all PIDs, retain unresolved entries/workdirs, remove handled entries, and return failure.
- **GREEN:** `bash scripts/test-polytoken-workflow-facets.sh --selftest` → **17 passed, 0 failed**, no `No record of process` output; `bash -n scripts/test-polytoken-workflow-facets.sh` passed.
- **Broader validation:** `--approval-contract`, `--delivery-policy`, full `bash scripts/test-polytoken-workflow-facets.sh` (**143 passed, 0 failed**), and `bash scripts/test-polytoken-subagents.sh` all passed. Full harness retains pre-existing shell job notifications for killed daemon/fixture processes; the focused corrected path is clean.
- **Self-review:** only `scripts/test-polytoken-workflow-facets.sh` was modified; the cleanup contract and bounded deadlines remain intact. No additional concerns found.

## Commit

Committed on `feat/agent-workflow-facets` as
`a1c0754 feat: add workflow facets with installer support and contract
harness` (5 files, 967 insertions(+), 4 deletions(-)); working tree clean.
No push (per brief).

## Review fix batch (Important findings, fixed in one batch)

### Finding 1: `--delivery-policy` asserted only static frontmatter/prompt
contract — no runtime effective-tool evidence.

**Fix:** `run_delivery_policy` now starts the isolated daemon via the same
`require_daemon` contract as `--designer-authority` (daemon-start failure
FAILS the mode; static checks never substitute) and asserts against
`GET /tools/effective?facet=workflow-delivery`:

- `model` resolves to `codex/gpt-5.6-luna`;
- required mutation-surface tools exposed: `file_write`,
  `file_edit_search_replace`, `shell_exec`, `shell_monitor`, `shell_service`,
  `lsp`, `pushd`, `popd`, `switch_facet`, `job_cancel`, `todo_create`,
  `todo_update`, `todo_complete`, `todo_delete`, `todo_list`;
- `write_plan`, `edit_plan`, `handoff_plan` absent (denied);
- every `mcp__*` name in the effective plan is in `mcp__ratatoskr__*`.

Focused result (isolated daemon, container-local evidence):

```
=== delivery_effective_tools are mutation surface + plan tools denied (runtime) ===
  limitation: live config disables the referenced model(s) enabled only in the
              isolated copy: zai/glm-5.2
  ok: runtime: /tools/effective resolved workflow-delivery
  ok: runtime: delivery model pin resolves
  ok: runtime: required mutation-surface tools all exposed
  ok: runtime: plan tools denied (write_plan/edit_plan/handoff_plan absent)
  ok: runtime: effective MCP tools stay in ratatoskr namespace
=== 38 passed, 0 failed ===   (bash scripts/test-polytoken-workflow-facets.sh --delivery-policy)
```

RED evidence for finding 1: the committed (`a1c0754`) `--delivery-policy`
mode reported `33 passed, 0 failed` with **zero** daemon interaction (all
assertions were static `expect_fm`/`expect_in`), demonstrating the required
runtime evidence was absent.

### Finding 2: cleanup tracked only `DAEMON_PID` in process-local state;
background children (notably the conditional-transition curl) could leak,
`wait` was unbounded, and workdirs were removed while children were live.

**Fix (all in `scripts/test-polytoken-workflow-facets.sh`):**

- Shared tracker: every background coprocess — isolated daemon
  (`start_daemon` retry paths + `stop_daemon`), the conditional-transition
  curl in `--approval-contract`, selftest fixtures — is registered in the
  global `CHILD_PIDS`; no `background` coprocess left untracked.
- `kill_child`: `kill -TERM` → poll `proc_dead` every 0.2s for at most
  `TERM_TIMEOUT` (2s) → escalate `kill -KILL` → bounded reap poll → `wait`.
  Every wait is bounded; a stale/foreign pid is a no-op.
- `cleanup` (EXIT + interrupt): handles the daemon, then every tracked
  child, then removes workdirs **only after** all children are handled;
  empties both arrays (idempotent on re-entry).
- Interrupt safety: `trap on_interrupt INT TERM` runs the same bounded
  `cleanup` and exits 130/143 — no path leaves children or temp dirs.
- The selftest's own waits are bounded (20s interrupt bound, 5s startup
  bound) with an explicit leak-guard KILL, so a broken interrupt path can
  never hang the suite (the RED run proved the pre-fix unbounded `wait`
  hung and required a 120s `timeout` kill).

### Deterministic focused tests added (`--selftest`, also in full run)

New mode `--selftest` (11 assertions, ~6s, no daemon, no network). Covers
the failure and stalling paths directly:

1. `cleanup` kills a TERM-able background child;
2. a TERM-ignoring stalling child (`sh -c 'trap "" TERM; while :; do …'`)
   is escalated to KILL;
3. workdirs are removed only after children are handled;
4. the child tracker is emptied after the pass (no stale pids);
5. INT handler round: the exact `on_interrupt` handler executes in a
   subshell with a real tracked child + workdir — exit 130, child killed,
   workdir removed;
6. TERM signal round: the harness's own fixture co-process (real script
   spawn with a tracked long-lived child and workdir) receives real
   `SIGTERM` → exits 143 within 20s, child killed, workdir removed.

GREEN evidence (fresh, single command):

```
$ bash scripts/test-polytoken-workflow-facets.sh --selftest
  ok: cleanup: TERM-able child killed
  ok: cleanup: TERM-ignoring child escalated to KILL
  ok: cleanup: workdir removed after children handled
  ok: cleanup: child tracker emptied after reap
  ok: handler (INT): on_interrupt exited with status 130
  ok: handler (INT): tracked child killed
  ok: handler (INT): workdir removed after children handled
  limitation: SIGINT is ignored on entry in this environment (not trap-able);
              the INT handler was executed directly. Interactive terminals
              (Ctrl-C trap-able) get the same handler via the INT trap.
  ok: fixture (TERM): started with tracked child under a real workdir
  ok: fixture (TERM): interrupt exited with status 143 within 20s
  ok: fixture (TERM): tracked child killed on interruption
  ok: fixture (TERM): workdir removed after children handled on interruption
=== 11 passed, 0 failed ===   (exit 0, wall ~5.6s)
```

RED evidence (same mode vs. pre-fix code):

```
$ bash scripts/test-polytoken-workflow-facets.sh --selftest   # before fix
  FAIL: cleanup: TERM-able child killed (pid … still alive)
  FAIL: cleanup: TERM-ignoring child escalated to KILL (pid … still alive)
  ok:  cleanup: workdir removed after children handled
  FAIL: cleanup: child tracker emptied after reap (2 left)
  …then the suite itself hung on an unbounded wait against a signaled
  fixture and only returned via the 120s `timeout` kill (exit 124).
```

Expected-failure rationale: the pre-fix `cleanup` only knew `DAEMON_PID`,
so untracked background children survive; the interrupt path had no
bounded-wait structure at all — both failures are exactly the reviewed
defects, not environment noise.

### Rerun matrix (fresh, post-fix, pre-commit)

| Command | Result |
|---|---|
| `bash -n scripts/test-polytoken-workflow-facets.sh` | OK |
| `bash -n scripts/install-polytoken.sh` | OK |
| `bash -n scripts/test-install-polytoken.sh` | OK |
| `bash scripts/test-polytoken-workflow-facets.sh --selftest` | 11/11, exit 0 |
| `bash scripts/test-polytoken-workflow-facets.sh --delivery-policy` | 38/38 (incl. 5 runtime on isolated daemon), exit 0 |
| `bash scripts/test-polytoken-workflow-facets.sh` (full default) | **137 passed, 0 failed**, exit 0 — transcript: `.superpowers/sdd/task-3-evidence-refresh.md` |
| `bash scripts/test-install-polytoken.sh` | 141 passed, 0 failed, exit 0 |
| `bash scripts/test-polytoken-subagents.sh` | all persona contract assertions passed (14/14), exit 0 |

Full-run delta vs. the first task-3 run: 121 → 137 (+5 delivery runtime,
+11 selftest). Docs remain explicitly PENDING (Task 4), reported as not
passed.

### Environmental limitation found while testing (documented, not hidden)

This sandbox's tool wrappers enter with **SIGINT ignored**; bash cannot
trap a signal ignored on entry. Probe evidence: an in-tree fixture bash
survived 100s of SIGINT, while the same fixture under SIGTERM ran the full
interrupt path (cleanup + `exit 143`) in seconds. The harness therefore
still installs the INT trap (correct for interactive terminals, where
Ctrl-C is trap-able), and `--selftest` detects the condition with a
bounded probe (`int_trap_probe`): when SIGINT is untrap-able it executes
the identical `on_interrupt` handler directly in a subshell (real tracked
child + real workdir) and prints the explicit limitation line above, so
the environment is never mistaken for harness behavior.

### Self-review notes for this batch

- Scope: only `scripts/test-polytoken-workflow-facets.sh` changed (the
  sole file allowed; no task-3 source needed another change — verified by
  test-driven evidence, i.e. all runtime assertions pass against existing
  facet definitions).
- No unbounded waits remain: daemon health loop (≤30s), ratatoskr appear
  wait (≤60s, designed), conditional curl (`--max-time 60` + tracked +
  `kill_child` backstop), selftest waits (≤20s) — all bounded and
  signal-safe.
- `kill_child` is a no-op for dead/foreign pids (`kill -0` probe +
  `<defunct>` check), so double-handling (explicit reap then cleanup) is
  safe.
- Subshell-scoped tracker in the INT handler round: the subshell
  re-declares `CHILD_PIDS`/`WORK_DIRS` with only its own entries — an
  earlier draft inherited the parent arrays and `on_interrupt` deleted
  the selftest's own output dir mid-run (caught by the focused run and
  fixed before reporting).

Files changed in this batch: `scripts/test-polytoken-workflow-facets.sh`
only. No push (per brief).

## Incremental review fix evidence (current pass)

- `kill_child` now polls bounded TERM/KILL deadlines, waits only after confirmed death/zombie state, and returns failure with a still-alive/unreapable diagnostic otherwise.
- Daemon PIDs are registered in the shared tracker; the daemon comment now identifies `DAEMON_PID` as a convenience alias.
- Conditional transition uses bounded polling plus shared lifecycle cleanup; timeout/failure records failed approval assertions and cannot hang.
- Deterministic selftests cover still-alive simulation and transition timeout without long waits.
- GREEN: `--selftest` 14/14; `--approval-contract` 26/26; `bash -n` OK. Wait audit found no production bare/unbounded wait; remaining waits are selftest reaps after bounded death polls.

## Ownership-aware reaping corrective evidence

- RED: before this correction, `reap_child` was an unconditional no-op and there was no zombie-collection assertion; confirmed-dead shell-owned children could remain zombies until shell exit.
- GREEN implementation: added explicit `CHILD_OWNED[pid]` metadata populated at every registration path (daemon retries, conditional curl, lifecycle fixtures, probes, and selftests). `reap_child` invokes `wait` only when metadata confirms current-shell ownership; foreign/non-child PIDs never reach `wait`. Cleanup rebuilds ownership metadata with unresolved PID state, preventing stale/mismatched entries.
- Focused regression: `bash scripts/test-polytoken-workflow-facets.sh --selftest` → **19 passed, 0 failed**, stderr empty. New assertions verify a shell-owned exited child is collected (PID no longer exists) and a confirmed-dead non-child remains quiet (no stderr).
- Required verification: focused modes `--inventory`, `--validate-definitions`, `--designer-authority`, `--approval-contract`, `--delivery-policy`, `--ratatoskr`, and `--selftest` all passed; full workflow harness → **145 passed, 0 failed**; `bash scripts/test-polytoken-subagents.sh` passed all persona assertions; `bash -n scripts/test-polytoken-workflow-facets.sh` OK; `git diff --check` OK.
- Broader stderr: expected shell job notifications for intentionally KILLed daemon/fixture processes and one `wait_for: No record of process` diagnostic in the existing forced lifecycle path; exit statuses remained successful. No focused-selftest stderr noise.
