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

Use the built-in `glob` and `grep` tools to find files and search content; use
`file_read` to read files. These preserve permissions and structured output and
are preferable to shell `find`, `grep`, or `cat` for discovery and reads. Use
`shell_exec` for genuine process work — builds, tests, git, and project CLIs.
