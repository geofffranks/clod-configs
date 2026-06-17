# claude-config

A portable, de-personalized set of [Claude Code](https://claude.com/claude-code)
configuration: a few skills, safety/utility hooks, a custom status line, a
curated global `CLAUDE.md`, and a recommended `settings.json` fragment (env vars
and editor prefs — **not** permissions).

## Install

```bash
git clone <this-repo> claude-config
cd claude-config
./install.sh
```

`install.sh` copies everything under `home/` into `~/.claude` (override with
`CLAUDE_CONFIG_DIR`), backing up any file it would overwrite to
`<file>.bak-<timestamp>`. It then merges `home/settings.recommended.json` into
your `settings.json` with `jq` — **non-destructively**: new keys are added, but a
value you already set is changed only with your consent (see below). If `jq` is
missing it prints manual merge instructions instead. Re-running is safe — every
change is backed up first, and an unchanged file is left alone.

**Requirements:** `bash` 4+ (the status line uses `mapfile`; macOS ships bash 3.2,
so install a newer one via Homebrew) and `jq` for the settings merge.

**Merge behavior:** the merge adds the recommended keys without touching values
you already have. If applying the fragment *would* change something you set — a
scalar like `theme`, or an entire array like `hooks` (jq replaces arrays
wholesale) — the installer warns, prints a unified diff, and asks:

- **`y`** — take the recommended values (your file is backed up to
  `settings.json.bak-<timestamp>` first).
- **`N`** (default) — keep your values, but still add any genuinely new keys.

The prompt is read from the terminal (`/dev/tty`), so it still works when the
installer is piped — `curl … | bash` will ask. Only when there's no controlling
terminal (CI, cron, a non-interactive shell) can it not ask; there it takes the
safe default (keep yours, add new keys). Pass `--overwrite` or set
`CLAUDE_CONFIG_OVERWRITE=1` to take the recommended values without prompting.

## What's included

| Piece | Notes |
|---|---|
| `skills/agent-session-retro` | End-of-session retrospective workflow. |
| `skills/doc-writing` | Guide for user-facing technical docs. |
| `skills/git-workflow` | Git hygiene/branching; pairs with the guard hooks. |
| `bash-guard`, `branch-guard`, `git-safe` | Block risky bash, commits to protected branches, and destructive git ops. |
| `hooks/no-remote-writes.sh` | Blocks unsolicited `git push` / `gh` writes. |
| `hooks/agent-state.sh` | Writes the working/idle badge the status line shows. |
| `read-once/` | De-duplicates repeated file reads to save context. |
| `statusline.sh` | Status line: cwd, git, agent, PR, model, context %, cost, rate limits. |
| `settings.recommended.json` | `env` (models, thinking budget, autocompact), theme, statusline, and hook wiring. No permissions. |
| `CLAUDE.md` | Curated global instructions: permission patterns, shell-cwd discipline, commit tips, memory routing. |

### Settings reference

The merged `env` keys: `ANTHROPIC_MODEL=opus` and
`CLAUDE_CODE_SUBAGENT_MODEL=sonnet` set the main/subagent models;
`ANTHROPIC_DEFAULT_*_MODEL` pin specific model IDs (current as of this repo's
date — bump them as new models ship); `MAX_THINKING_TOKENS` and
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` tune thinking budget and autocompact threshold.

## Optional add-ons

- **`defaultMode: acceptEdits`** — auto-accepts file edits. Not merged by default
  (it weakens an edit-safety prompt). Add it to `settings.json` yourself if you
  want it.
- **gitprompt** — `statusline.sh` uses [`gitprompt.pl`](https://github.com/magicmonty/bash-git-prompt)
  if it's on `PATH` or pointed to by `$CLAUDE_STATUSLINE_GITPROMPT`; otherwise it
  falls back to plain `git` for the branch + dirty flag.

## Companion tools (install separately)

These are referenced by or complement this config but are not bundled:

- **[superpowers](https://github.com/obra/superpowers-marketplace)** — the
  skill framework `git-workflow` defers to for branch/PR/worktree mechanics.
- **[caveman](https://github.com/JuliusBrussee/caveman)** — terse-output mode;
  `statusline.sh` shows a `[CAVEMAN]` badge when it's active.
- **rtk** — read/grep/test output compressor. If installed, wire its hook:
  add `{ "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/.claude/hooks/rtk-rewrite.sh" } ] }`
  to `hooks.PreToolUse` (script ships with rtk).
- **cavemem** — memory MCP + hooks. If installed, add its `mcpServers` entry and
  `UserPromptSubmit`/`PostToolUse`/`Stop`/`SessionStart`/`SessionEnd` hooks per
  cavemem's docs.
- **tk** — minimal local ticket system.
- **herdle** — cross-project work dashboard built on `tk`.
