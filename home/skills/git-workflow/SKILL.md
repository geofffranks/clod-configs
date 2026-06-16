---
name: git-workflow
description: Use when doing any git work in this environment — branching, committing, using worktrees, preparing a push/PR, or cleaning up branches/worktrees. Covers branching decisions, commit hygiene, worktree setup and cleanup, and how to work WITH the git-safe / branch-guard / no-remote-writes hooks. Defers to superpowers:finishing-a-development-branch (merge/PR mechanics) and superpowers:using-git-worktrees (worktree mechanics), and to each repo's CLAUDE.md for its specific branching model. Trigger on: "branch", "commit", "worktree", "push", "PR", "rebase", "clean up branches", or before any git state change.
---

# Git Workflow Skill

**When using this skill, begin by stating:** "I'm using the git-workflow skill — orienting on the repo's model, branching off the right base, and keeping commits/worktrees clean."

This skill covers everyday git **hygiene and decisions** in this environment. It does NOT restate git basics or the safety hooks — those are enforced automatically. It fills the gap between the guard hooks (enforcement) and per-repo CLAUDE.md (specific models).

**Defers to:**
- `superpowers:finishing-a-development-branch` — merge vs PR vs cleanup decisions at the end of work.
- `superpowers:using-git-worktrees` — the mechanics of creating/switching worktrees.
- **the repo's own `CLAUDE.md`** — the authoritative branching model for *that* repo. Always read it first.

## The guard hooks are allies, not obstacles

Three PreToolUse hooks enforce safety. Don't fight them — they encode intent:
- **branch-guard** — blocks commits to protected branches (`main`/`master`/`dev`). If blocked, you were about to commit to the wrong branch: **branch first.**
- **no-remote-writes** — blocks `git push` and `gh` writes. Pushing/PRing is a **user-authorized** act: ask before you push, never auto-push.
- **git-safe** — blocks destructive ops (hard reset, force-delete, clean -fd) that lose work. If blocked, stop and reconsider rather than working around it.

A block is a signal, not a roadblock. Adjust intent; don't escalate or bypass.

## 1. Orient before you touch git

Before branching or committing in any repo, learn its model — don't assume:
1. **Read the repo's `CLAUDE.md`** (or `.claude/rules/`) for its branching model.
2. `git remote -v` — is this a **fork** (separate `upstream` + `origin`) or your **own repo** (just `origin`)?
3. `git branch --show-current` and `git status -sb` — where am I, is the tree dirty?
4. Check open PRs and in-flight work however you track it (e.g. `gh pr list`, your ticket system).

**Fork vs own repo changes everything:**
- **Fork** (e.g. dcs-retribution): keep the default branch a **pristine mirror of `upstream`**. Branch features off `upstream/<default>`. PR to `upstream`. Never commit to the default branch.
- **Own repo** (e.g. ha-configs, spruce): branch off `origin/<default>`; PRs (if any) go to `origin`.

## 2. Branching

- **Never work on a protected branch.** Branch first (branch-guard enforces this). If you find yourself dirty on `main`/`dev`, stash, branch, then pop.
- **Base off the right branch** — the repo's default (or `upstream/<default>` for forks), freshly fetched. `git fetch && git switch -c <name> origin/<default>`.
- **Name by intent:** `feat/<slug>`, `fix/<issue>-<slug>`, `chore/<slug>`. Match the repo's existing convention if it differs.
- **One concern per branch.** If scope creeps into an unrelated change, branch again.

## 3. Commit hygiene

- **Granular commits — one logical change each.** A commit should be revertable and bisectable in isolation. Split unrelated changes; don't bundle a refactor with a feature.
- **Message style:** imperative subject (`Fix …`, `Add …`), ≤72 chars; the body explains **why**, not what. Reference the issue/PR.
- **Long or apostrophe-containing messages:** `Write` the body to a temp file and `git commit -F <file>` (not a heredoc). Apostrophes in `-m "it's fine"` are fine for one-liners.
- **Footer:** end Claude-authored commits with the `Co-Authored-By` line the harness specifies.
- **Don't commit:** generated artifacts, secrets, `.venv`/build output, or local tooling/state directories that aren't part of the project — git-exclude them by convention; verify with `git status` before staging.
- **Stage deliberately** — review `git diff --staged` before committing; never `git add -A` blind.

## 4. Worktrees & worktree hygiene

Use a worktree to work on a branch **in physical isolation** — essential for parallel agents (the Agent tool's `isolation: worktree`) or when you need the main checkout untouched. For simple single-branch work, a worktree is optional. (Mechanics: `superpowers:using-git-worktrees`.)

**Hygiene rules:**
- **One location, git-excluded:** put worktrees under `.worktrees/<branch>` inside the repo, and ensure `/.worktrees/` is in `.git/info/exclude`. Discoverable, and never committed.
- **Name the dir for the branch** it holds — no `tmp2`, `wt-final`.
- **One branch ↔ one worktree.** Git refuses to check a branch out twice; don't try to game it.
- **cwd is not your friend.** The Bash cwd can silently flip between turns. In worktree work, **always use `git -C <abs-path>`** and absolute paths; verify with `pwd` after any restart before committing. Committing from the wrong worktree is the classic worktree bug.
- **Clean up when done:** once a branch is merged or abandoned, `git worktree remove <path>` then delete the branch (`git branch -d`). Run `git worktree prune` periodically to clear stale entries. Don't let `.worktrees/` accumulate.
- **Never nest** a worktree inside another worktree or inside the main checkout's tracked tree.

## 5. Pushing & PRs

- **Push only when the user asks.** no-remote-writes blocks unsolicited pushes by design — that's the policy, not a bug.
- **Confirm the base** before opening a PR: forks → `upstream/<default>`; own repos → `origin/<default>`. Use `gh pr create --base <branch>`.
- **PR body** ends with the harness's generated-with footer.
- Hand off the merge/PR *decision* (merge now? PR? stack?) to `superpowers:finishing-a-development-branch`.

## 6. Branch & repo hygiene over time

- **Keep the default branch pristine** — for forks it mirrors `upstream`; never land feature commits there directly.
- **Delete merged local branches** (`git branch -d`); prune stale remotes (`git remote prune origin`) periodically.
- **A branch with no PR** and **an in-flight ticket with no pushed branch** are both drift — resolve them, don't let them rot.
- Track the work itself in your ticket system, not in commit messages or memory.

## Common mistakes

1. ❌ Committing on `dev`/`main` then realizing it. ✅ Orient first (§1); branch before the first commit.
2. ❌ Auto-pushing or opening a PR because the work "looks done." ✅ Push/PR are user-authorized; ask.
3. ❌ One giant commit mixing feature + refactor + formatting. ✅ Granular, one-concern commits.
4. ❌ Committing from the wrong worktree after a cwd flip. ✅ `git -C <abs-path>`, verify `pwd`.
5. ❌ Leaving merged branches/worktrees lying around. ✅ Remove + prune as you go.
6. ❌ Working around a guard-hook block. ✅ Treat the block as a signal; fix the intent.
