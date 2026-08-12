# C4 subagent hook probes

Date: 2026-07-18
Worktree: `/home/dev/workspace/.worktrees/cc-7zn9-polytoken-context-guards-c2`

## Controller entrypoint discovery

Command:

```bash
polytoken --help
polytoken exec --help
polytoken print-tools | jq -r '.tools[]? | (.name // .id // empty)' | grep -E 'subagent|job_block|file_read|grep' | head -40
```

Observed result: Polytoken exposes `exec` as the non-interactive controller entrypoint, but does not expose a standalone `subagent` or `reviewer` CLI command, and the filtered printed tool list contained no matching entries.

## Implementer probe

Command:

```bash
polytoken --config-dir "$HOME/.config/polytoken" \
  --working-dir "$PWD" exec --facet implementer --max-tool-turns 2 \
  "Probe only: attempt one ordinary file_read of README.md with offset 0 and limit 1, then report whether the ordinary hook executed. Do not modify files."
```

Observed result:

```text
Error:   × exec facet "implementer" is not registered
```

Exit status: 1. No subagent session was created, so no ordinary hook execution was observable.

## Reviewer probe

Command:

```bash
polytoken --config-dir "$HOME/.config/polytoken" \
  --working-dir "$PWD" exec --facet reviewer --max-tool-turns 2 \
  "Probe only: attempt one ordinary file_read of README.md with offset 0 and limit 1, then report whether the ordinary hook executed. Do not modify files."
```

Observed result:

```text
Error:   × exec facet "reviewer" is not registered
```

Exit status: 1. No subagent session was created, so no ordinary hook execution was observable.

## Coverage conclusion

Real implementer/reviewer subagent hook execution is unavailable through the installed controller because those facets are not registered. README documents this controller-only limitation. Prompt-level bounded-search and ranged-read protections remain in the implementer and reviewer persona contracts; this evidence does not claim ordinary hook enforcement inside subagents.
