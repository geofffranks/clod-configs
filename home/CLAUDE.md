# Global Claude Code Instructions

## Permission Rules

When adding new allow rules to any `settings.json`, use the broadest reasonable
pattern rather than the specific one-off command. Ask "what's the general tool or
pattern here?" and use that.

| Instead of | Use |
|---|---|
| `Bash(git status)` | `Bash(git:*)` |
| `Bash(gh pr list)` | `Bash(gh:*)` |
| `Bash(curl -s http://...)` | `Bash(curl:*)` |
| `Bash(python3 -c "...")` | `Bash(python3:*)` |
| `WebFetch(domain:docs.example.com)` | `WebFetch(domain:example.com)` |

Never add a fully-specified one-off command as an allow rule.

## Shell discipline — cwd persists between Bash calls

The Bash tool's working directory persists across separate tool calls, so a bare
`cd /somewhere` leaks into every later command until you change it again. Never
bare-`cd` out of the working directory: scope directory changes with a
`(cd <dir> && …)` subshell, or use absolute paths. Reserve a persistent top-level
`cd` for when the user explicitly asks to change the working directory.

*Why:* a leaked `cd` once sent a later command to the wrong directory, where it
errored. Subshells and absolute paths keep each command self-contained and the
cwd anchored at the project root.

## Commit messages

Apostrophes in commit messages are fine — `git commit -m "fix: it's broken"`
stores the message intact. For long or multi-line messages, prefer writing the
body to a temp file and `git commit -F /tmp/commit_msg.txt` — cleaner than a
heredoc.

## Memory & task routing — write to memory last, not first

Before persisting anything, route it. Memory is the last resort, not the default.

- **Durable rule / convention / gotcha** → the repo's `CLAUDE.md`.
- **Active work** (status, design decisions, sub-tasks that outlive the session)
  → your ticket/task tracker, not memory.
- **Branch existence / commit history / PR state** → never store; query `git` /
  `gh` live. Remembered status rots the moment a PR merges.
- **Full spec / plan / validation artifact** → a doc file the ticket links to.
- **Ephemeral within-session sub-tasks** → in-session todos. Promote to the
  tracker only if unfinished at session end.
- Write a **memory** only when it is none of the above: a durable user-profile
  fact or an external reference pointer not tied to a ticket.

## RTK — search & test commands

The RTK hook only intercepts **Bash**; the built-in `Grep`/`Glob`/`Read` tools
bypass it and save nothing. RTK earns ~94% of its savings on **grep**, with
**pytest/mypy/go test** the next-biggest lever (verbose, traceback-heavy output).

- **Search contents → `Bash: rtk grep <pattern> [path]`** (not the `Grep` tool).
- **Find files → `Bash: rtk find <pattern>`** (not the `Glob` tool).
- **Python tests / typecheck → `rtk pytest …` / `rtk mypy …`**, never
  `.venv/bin/pytest` / `.venv/bin/mypy` (the `.venv/bin/` prefix bypasses RTK).
  rtk spawns a **bare** `pytest`/`mypy`, so the venv must be on `PATH` for the
  call: `PATH=".venv/bin:$PATH" rtk pytest tests`. Without it rtk errors
  `Failed to spawn process`. (`black` has no handler — run it raw.)
- **Go tests → `rtk go test ./...`** — works as-is; Go has no per-project venv,
  so there's no PATH gotcha (already ~99% savings in practice).
- **Read files → use the built-in `Read` tool freely**, especially with
  `offset`/`limit` for large or targeted reads. `rtk read` saves ~2% and on
  large files returns a persisted-file *pointer* instead of content (forcing a
  re-read), so it's not worth mandating — use it only for quick full-file reads.
