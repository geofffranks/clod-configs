---
name: finishing-a-development-branch
description: Use after relevant automated validation passes on eligible branch work to ask whether to finalize before or after human checks, safely squash and clean up when chosen, and hand off manual steps. Does not push, merge, or open PRs.
---

# Finishing a Development Branch

## Applicability

Use only when branch/worktree finalization or a human manual-validation handoff is genuinely part of approved work. This is not a default consequence of a plan. A small Markdown, metadata, or config cleanup on the current workspace finishes with focused verification and a concise report instead only when approved scope excludes branch finalization and the change has no executable, authority, permission, or tool-configuration behavior change. A mixed change or a branch explicitly requiring finalization is not exempt.

Do not create or retain validation artifacts without a durable need (a required deliverable or evidence needed for an ongoing handoff). Reuse fresh session/CI evidence; a separate validation document is not required.

**Announce at start:** "I'm using the finishing-a-development-branch skill to complete this work."

## 1. Verify automated validation

Check the relevant automated tests, configuration parsers/renders, and other approved checks after the last mutation affecting them. Reuse fresh evidence rather than rerunning equivalent commands merely because this skill was entered. If validation fails, stop finalization, repair within scope, and rerun affected checks. Do not ask the timing question or claim the branch is finished while required checks fail.

## 2. Offer the human the order of finalization

Before squashing or removing any worktree, present concrete manual checks with expected results, prerequisites, and a workable branch/commit checkout or retained workspace for each option. Verify that a proposed checkout actually exists and remains usable after cleanup; a path to a worktree about to be removed is not a viable handoff. Before ending the turn, ask the operator with `ask_user_question`: **"Should I finalize the branch now, before your manual checks, or wait until you report their results?"** Record the answer and outstanding checks for later turns and compaction. Do not interpret silence as a choice.

- **Validate first:** Leave the branch and workspace intact. Report status and the outstanding checks, then end the turn; never call `block_goal` to wait for the human. If a check fails, return to scoped repair and affected automated checks, then present updated steps and the ordering choice as needed. On a reported pass, proceed to finalization below; do not claim to have performed the human's checks yourself.
- **Finalize first:** Proceed below immediately. After successful applicable finalization, report the verified branch/commit disposition and manual checks still pending. Completing the saved implementation goal does not assert human validation, delivery acceptance, integration, or ticket closure. If the saved goal explicitly includes human acceptance or integration, resolve that scope conflict instead of silently completing it.

No active saved goal means no `complete_goal` call or fabricated goal status. Complete an active saved implementation goal with `complete_goal` once automated validation passes, the intended work is committed, and every required in-scope finalization step has succeeded or been deferred by the ordering answer, labeling manual checks pending. When branch finalization is out of approved scope, the same rule applies after focused verification succeeds.

## 3. Finalize the branch safely

Commit intended changes before finalization. Inspect base, branch history, upstream and matching remote refs, staged/unstaged state, and registered worktrees. If an upstream or matching remote ref exists, do not rewrite that history; report the conflict for human disposition. If there are multiple local-only branch commits and a squash is applicable, perform it without overwriting unrelated work, then verify the resulting commit and branch reachability. A branch already containing one appropriate commit needs no rewrite. Do not rewrite shared or externally owned refs; pause and report conflicts rather than forcing them. If the squash changes executable/configuration behavior or invalidates validation evidence, rerun affected automated checks before cleanup.

Worktree cleanup is permitted only if **all** of these are true:

1. A contemporaneous session/job creation record identifies the exact path, current session/job owner, purpose, and disposable cleanup intent. Cross-check the owner against the current session/job and the exact registered path and branch/HEAD in `git worktree list --porcelain` against the creation record before removal. A summary reconstructed after compaction is not proof of creation; retain the worktree if original attribution is unavailable or registration differs. Directory names (`.worktrees/`, `worktrees/`) and `GIT_DIR`/`GIT_COMMON` identify layout, **not ownership**. Never remove a harness-owned, named, unknown, or unowned worktree.
2. Every intended change is committed, the target worktree is clean (including staged and untracked files), and the resulting commit is reachable from the retained branch/ref. Inspect ignored files too (`git status --ignored` or `git clean -nXd`); preserve the worktree if any ignored content may be needed, unless the human explicitly authorizes removal of that specific ignored content in this session; do not infer authorization from the plan or agent notes. Do not force removal or discard unrelated work.
3. The validated human handoff names a usable checkout or branch after removal, and removal is run from outside the target worktree.
4. `git worktree remove <exact-path>` succeeds, and `git worktree list --porcelain` confirms that exact registration is absent. Do not broadly prune unrelated registrations. A required cleanup that fails is a failed finalization, not success; report the failure and do not claim success.

When no ownership record exists, retain the worktree and report that intentional retention; it is an acceptable safe disposition, not a cleanup failure. When no worktree exists, report that there is none to remove. Never remove the retained branch merely because its worktree was removed. Do not push, merge, open a PR, offer to do those as part of this skill, or advance a ticket to Done/Canceled; integration and acceptance remain human-owned.

## 4. Handoff and goal disposition

Report the automated evidence, final branch and commit, verified worktree status, remaining risks, and exact manual steps and expected results with a viable checkout. Complete an active saved implementation goal with `complete_goal` once automated validation passes, the intended work is committed, and every required in-scope finalization step has either succeeded or been deferred by the ordering answer, explicitly labeling manual steps pending, regardless of the ordering answer. For validate-first, leave the branch and workspace intact until the reported human result and any finalization; for finalize-first, report the verified disposition. If a required cleanup or check fails, do not claim success; repair within scope. A missing saved goal is simply reported as absent.

## Red flags

- Squashing or cleaning up before the timing answer.
- Treating a directory name as ownership or removing a dirty/unknown worktree.
- Calling a failed cleanup successful, or handing off only a removed path.
- Reporting pending human checks as passed or treating goal completion as ticket closure/integration.
- Calling `block_goal` to wait for the operator, to ask the ordering question, or to park finished work.
- Creating validation records without a durable need, or pushing/merging/opening a PR.
