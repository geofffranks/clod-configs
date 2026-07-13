# Task 6 Report — Make canonical skills accurate in both harnesses

**Status:** DONE
**Commit:** `4d70d0d` — `docs: make shared skills harness-aware` (branch `feature/polytoken-install`)

## Files committed (exactly four, per task-6-brief.md Step 5)

- `home/skills/git-workflow/SKILL.md` — frontmatter parse error repaired; cwd rule made harness-aware.
- `home/skills/agent-session-retro/SKILL.md` — instruction-file references made harness-neutral.
- `home/skills/agent-orchestration/SKILL.md` — restructured into shared discipline + Claude Code + Polytoken sections.
- `scripts/test-polytoken-artifacts.sh` — temporary git-workflow expected-failure gate removed; semantic portability assertions added.

No other skills, native artifacts, installer, or upstream suites were modified.

## TDD red/green evidence

### Critical prerequisite (frontmatter repair)

The brief and prompt flagged a blocking defect first: `home/skills/git-workflow/SKILL.md` failed `polytoken validate skill` with `mapping values are not allowed in this context at line 2 column 512`. The cause was a plain (unquoted) YAML scalar description containing `Trigger on: "` — the `: ` (colon-space) is parsed as a mapping indicator inside a plain scalar. Verified the failure before touching it:

```bash
polytoken validate skill home/skills/git-workflow/SKILL.md
# Error: validate skill failed: ... mapping values are not allowed in this context at line 2 column 512   (rc=1)
```

Fix: wrapped the description in single quotes and escaped the single internal apostrophe (`repo's` → `repo''s`, the YAML single-quote escape). Verified green in isolation before proceeding:

```bash
polytoken validate skill home/skills/git-workflow/SKILL.md   # rc=0
```

### Red (test written first, watched it fail)

With the frontmatter repaired, the test edits were made next: the entire expected-failure branch (`normalize_diagnostic`, `is_known_git_workflow_failure`, the `GIT_WORKFLOW_SKILL` variable, both mutation guards, the branched loop, and the gate echo) was deleted and replaced with a plain "every skill must validate" loop plus the new semantic portability assertions. Running before any prose porting:

```bash
bash scripts/test-polytoken-artifacts.sh
# all four skills validate (gate correctly removed), then:
# FAIL: home/skills/agent-orchestration/SKILL.md must document the Claude Code workflow   (rc=1)
```

The suite failed at the first portability assertion — the expected, correct reason. `agent-orchestration` lacked the `## Claude Code` / `## Polytoken` sections; `agent-session-retro` had no `AGENTS.md`; `git-workflow` had no `shell_exec`.

### Green (after porting the three bodies, HEAD `4d70d0d`)

```bash
for f in home/skills/*/SKILL.md; do polytoken validate skill "$f"; done
# all four validate (rc=0)

bash scripts/test-polytoken-artifacts.sh
# OK: all polytoken artifact assertions passed   (rc=0)

bash scripts/test-install.sh
# === 77 passed, 0 failed ===   (rc=0)
```

### Hygiene

```bash
bash -n scripts/test-polytoken-artifacts.sh   # rc=0 (syntax OK)
git diff --check HEAD~1                        # rc=0 (no whitespace errors)
```

## How the brief's requirements were met

- **Step 1 — failing semantic portability assertions.** Added assertions that (a) require `agent-orchestration` to carry **both** workflows — `## Claude Code` + `## Polytoken`, `SendMessage`, `agent-join`, `subagent`, `job_block`/`job_result`, `auto-drained`; (b) require `agent-session-retro` to mention **both** `CLAUDE.md` and `AGENTS.md`; (c) require `git-workflow` to name **both** `Bash` and `shell_exec`. These reject harness-only prose, including the old "multiple Agent calls" rule with no Polytoken branch.
- **Gate removal.** The temporary git-workflow expected-failure branch (and its `normalize_diagnostic`/mutation-guard scaffolding) is gone; the loop now fails loudly on *any* validation failure, so a regression cannot pass silently.
- **Step 3 — `agent-orchestration`.** Reframed as shared correlation discipline (correlate by id; trust authoritative state over memory; a re-notification is not new work; end the turn only while something is running) followed by two explicit subsections. *Claude Code:* Agent/SendMessage, correlate by agentId, trust the agent-join `<orchestration-status>` block, Stop-deny means results ready. *Polytoken:* `subagent`, retain job id, `job_block`/`job_result`/`job_status`, trust auto-drained notifications + native sidebar state, no agent-join ledger/Stop-deny. Matches the brief's template.
- **Step 3 — `agent-session-retro`.** Every instruction-file reference now reads "the harness instruction file (`CLAUDE.md` or `AGENTS.md`)" (description, purpose, improvement template, process-doc guidance, success criteria, integration, example). The word `CLAUDE.md` is retained alongside `AGENTS.md` so both harnesses see themselves named.
- **Step 3 — `git-workflow`.** Retained a single shared git policy. The one rule where tool behavior actually differs — cwd persistence in worktrees — now names both "Claude's `Bash` and Polytoken's `shell_exec`." The Claude-only "Agent tool's `isolation: worktree`" parenthetical was generalized to "parallel agents that need isolated checkouts." The description deferral was neutralized to "the repo's instruction file (`CLAUDE.md` or `AGENTS.md`)."
- **Step 4 — both suites green.** Validate loop, `test-polytoken-artifacts.sh`, and `test-install.sh` all pass (see evidence above).

## Concerns

1. **Portability assertions are keyword-based, not semantic.** They assert presence of tool names / section headers rather than correct *usage*. This is deliberate — the assertions must run as greps against prose — so a future edit could satisfy them by mentioning `shell_exec` in an unrelated sentence. The risk is bounded because the assertions are paired (both harnesses must appear together) and the skills are small, but a reviewer eyeballing the prose is the real quality gate.

2. **`git-workflow` still reads "the guard hooks are allies" with PreToolUse framing.** The three hooks (branch-guard / no-remote-writes / git-safe) are enforced identically in both harnesses (the `polytoken/hooks.json` adapter mirrors the Claude hooks), so the prose remains accurate for both. This was intentionally left as-is per the brief's scope ("retain one shared git policy"), but a reviewer may want a one-line nod that the same guards run in Polytoken.

3. **`doc-writing` was intentionally not edited.** It validates and carries no harness-specific claims, so it required no porting; the all-skills loop confirms it stays green.

## Fix Review

- Neutralized the shared `git-workflow` body’s instruction-file references: bare `CLAUDE.md` now uses “the harness instruction file (`CLAUDE.md` or `AGENTS.md`)”; `.claude/rules/` now reads “or equivalent instruction rules directory”.
- Replaced the Claude-specific `PreToolUse` event name with “pre-tool-use guard hooks” while retaining the three guard descriptions and safety policy.
- Replaced “Claude-authored commits” with “agent-authored commits”; retained the `Co-Authored-By` footer policy.
- Verification: `polytoken validate skill home/skills/git-workflow/SKILL.md` passed; `bash scripts/test-polytoken-artifacts.sh` passed; `bash scripts/test-install.sh` passed (`77 passed, 0 failed`); targeted residual phrase scan and `git diff --check` passed.
- Commit: `fix: neutralize git-workflow harness-specific prose`
