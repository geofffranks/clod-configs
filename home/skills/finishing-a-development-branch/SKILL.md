---
name: finishing-a-development-branch
description: Honor approved Git disposition, safely finalize effort-owned work and report pending manual checks.
---
# Finishing a development branch

Use when approved work includes branch/worktree finalization. Read the upfront
Git choices: effort branch/workspace, mergeback target or leave-unmerged, and
ownership. Do not ask a new finalize-before/after-human-checks question. If no
integration disposition exists, ask for it; do not invent merge authority.

Verify relevant checks and selected reviews. Reuse results whose inputs and
behavior remain unchanged; commit IDs alone do not invalidate them. Repair or
escalate known failed required checks/defects before finalization. Manual checks
may remain and do not block mergeback, effort-owned cleanup or goal completion.

Commit intended changes and inspect branch/base, history, staged/unstaged state
and registered worktrees. Never rewrite shared/external refs or overwrite
unrelated work. Do not squash merely for ceremony; if explicitly appropriate for
local-only history, preserve intended changes and verify reachability afterward.
Honor approved local mergeback; substantive conflicts or unresolved blockers
require escalation, not force. No push/PR without explicit authority.

Clean only an effort-owned disposable worktree: verify its recorded creation
path/owner, current registered branch, clean intended work and retained reachable
commit. Preserve unrelated or needed ignored/untracked files; never force-remove
an unknown/dirty workspace. Remove from outside that path, verify the exact
registration disappeared, and report cleanup failures. Leave-unmerged retains
the committed branch; branch deletion is not implied. If cleanup is outside the
assigned scope, hand off the intact workspace to its owner.

After required in-scope finalization succeeds, complete an active saved goal
before the all-done summary. No active goal means no fabricated completion call.
Do not block goals to await manual checks. Report final branch/commit/workspace
disposition, actual checks, remaining risks, and manual steps/expected results
using a viable retained branch or checkout. Pending manual work is not a pass,
and goal completion does not authorize terminal Jira status or assert human
acceptance. Jira Done/Canceled still requires its own confirmation.
