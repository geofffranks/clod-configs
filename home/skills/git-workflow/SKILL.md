---
name: git-workflow
description: Use for Git orientation, deliberate staging and commits, guard-hook guidance, and safe worktree/cwd handling.
---
# Git hygiene

Read the project's instructions and honor the approved starting branch, isolated
worktree and mergeback disposition. Lifecycle facets own those decisions; this
skill does not choose a different base or finalization model.

## Guard hooks are allies

The registered `shell_exec` guards deny commits to protected branches
(`main`/`master`/`dev`), `git push` and `gh` writes, and destructive Git operations.
A block means reconsider the operation and authority, not bypass the hook. These
are shell-command guards, not a universal sandbox for every tool or process.
Never push or publish without explicit authority.

## Orient in the intended repository

Check branch, status and remotes before changing Git state. A fork with separate
`upstream` and `origin` normally keeps its default branch a pristine upstream
mirror and targets upstream for contributions. An owned repository normally
uses origin. Project instructions and the approved effort choices govern the
actual base and destination; do not silently replace them.

## Commit deliberately

- Keep commits granular, logically coherent and independently revertible.
- Use imperative subjects (about 72 characters or fewer); explain why in the body.
- Stage named intended paths, inspect the staged diff, and never blindly add all.
- Do not commit secrets, generated output, local runtime configuration or unrelated
  work. Preserve other contributors' changes.
- For long messages use a file and `git commit -F`; apostrophes in quoted messages
  are fine. Include the harness-required co-author footer when specified.

## Cwd and worktree safety

Use explicit absolute paths and `git -C <worktree>` for Git commands. Verify the
branch and working tree before staging or committing; never rely on a remembered
cwd after tool calls or recovery. Keep one branch per worktree and use the
repository's ignored worktree location. Do not reuse unknown workspaces or discard
unrelated work. Clean up only effort-owned state under the approved disposition;
leave-unmerged retains the committed branch.
