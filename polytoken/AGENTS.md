# Global Polytoken Instructions

## Permission Rules

When adding allow rules to `permissions.yaml`, use the broadest reasonable
pattern rather than the specific one-off command. Ask "what's the general tool
or pattern here?" and use that.

| Instead of | Use |
|---|---|
| `{ tool: shell_exec, args: { executable: git, subcommand: [status] } }` | `{ tool: shell_exec, args: { executable: git } }` |
| `{ tool: shell_exec, args: { executable: gh, subcommand: [pr, list] } }` | `{ tool: shell_exec, args: { executable: gh } }` |
| `{ tool: shell_exec, args: { executable: curl } }` | `{ tool: shell_exec, args: { executable: curl } }` |
| `{ tool: shell_exec, args: { executable: python3 } }` | `{ tool: shell_exec, args: { executable: python3 } }` |
| `{ tool: shell_exec, args: { executable: rtk, subcommand: [grep] } }` | `{ tool: shell_exec, args: { executable: rtk } }` |
| `{ tool: web_fetch, args: { url: { glob: "docs.example.com/*" } } }` | `{ tool: web_fetch, args: { url: { glob: "example.com/*" } } }` |

Never add a fully-specified one-off command as an allow rule.

```yaml
# permissions.yaml — version-2 schema
version: 2
allow:
  - tool: shell_exec
    args:
      executable: git
  - tool: shell_exec
    args:
      executable: gh
  - tool: file_read
  - tool: glob
  - tool: grep
```

## Commit messages

Apostrophes in commit messages are fine — `git commit -m "fix: it's broken"`
stores the message intact. For long or multi-line messages, prefer writing the
body to a temp file and `git commit -F /tmp/commit_msg.txt` — cleaner than a
heredoc.

## Memory & task routing — write to memory last, not first

Before persisting anything, route it. Memory is the last resort, not the default.

- **Durable rule / convention / gotcha** → the repo's `AGENTS.md`.
- **Active work** (status, design decisions, sub-tasks that outlive the session)
  → Polytoken todos and saved goals, not memory.
- **Branch existence / commit history / PR state** → never store; query `git` /
  `gh` live. Remembered status rots the moment a PR merges.
- **Full spec / plan / validation artifact** → a doc file the ticket links to.
- **Ephemeral within-session sub-tasks** → in-session todos. Promote to saved
  goals only if unfinished at session end.
- **Long-running or independent work** → dispatch to a Polytoken subagent or
  background job and track it in the jobs view rather than holding the main
  session.
- Write a **memory** only when it is none of the above: a durable user-profile
  fact or an external reference pointer not tied to a ticket.

## Search & file tools

Use the built-in `glob` tool to find files and `file_read` to read them — they
preserve permissions and structured output and are preferable to shell `find`
or `cat`. For content search, use `rtk grep` via `shell_exec` (see the RTK
section below); the built-in `grep` tool is still the right choice when you need
its structured features (multiple roots, an `include` filter, or
`context_lines`). Use `shell_exec` for genuine process work — builds, tests,
git, and project CLIs.

## RTK — search & test commands

rtk compresses command output before it reaches you; its biggest wins are
`grep` and verbose test/build output. It runs via `shell_exec`, so prefer
`rtk`-prefixed commands there — the built-in `grep`/`glob`/`file_read` tools
bypass rtk and save nothing.

- **Content search → `rtk grep <pattern> [path]`** (via `shell_exec`), not the
  built-in `grep` tool, for plain searches. The built-in `grep` is still the
  right choice when you need its structured features (multiple roots, an
  `include` filter, or `context_lines`).
- **Tests / typecheck / build / lint → `rtk <framework>`** — e.g. `rtk pytest`,
  `rtk mypy`, `rtk go test ./...`, `rtk cargo test`, `rtk jest`, `rtk vitest`,
  `rtk npm run build`, `rtk tsc`, `rtk ruff`. Don't run these bare when rtk has
  a handler.
- **venv PATH gotcha:** rtk spawns a bare `pytest`/`mypy`, so put the venv on
  `PATH` for the call: `PATH=".venv/bin:$PATH" rtk pytest tests`. Without it
  rtk errors `Failed to spawn process`.
- **Leave `find`/`read` to the built-in tools:** use `glob` for discovery and
  `file_read` for reads. `rtk find`/`rtk read` aren't worth it — the built-ins
  give structured output and preserve permissions, and `rtk read` returns a
  file pointer that forces a re-read (~2% savings).

rtk commands run through `shell_exec`, so allowing `executable: rtk` (see
Permission Rules) avoids per-call approval prompts.

# Workflow + Ticketing
Gate repo work on the skills that govern it: load `herdle-tk-flow` and create or locate the tk ticket before starting any feature or bug work, and load `git-workflow` before any branch, commit, or PR.

