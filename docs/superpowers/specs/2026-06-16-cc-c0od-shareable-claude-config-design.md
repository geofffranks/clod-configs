---
tkid: cc-c0od
lifecycle: designed
title: Shareable Claude Code config repo
date: 2026-06-16
---

# Shareable Claude Code Config Repo — Design

## Goal

A public, installable repo of de-personalized Claude Code configuration —
skills, hooks, settings (env + custom prefs, **not** permissions), global
instructions, and the custom status line. Serves two audiences: syncing the
author's setup across laptops, and giving others a curated starting point.
A README points to companion tools (installed separately), not vendored.

Out of scope: `permissions` blocks, local-llm delegation (skill + MCP servers +
all references), Home Assistant domain knowledge, herdle/tk workflow skills, and
any runtime/session data.

## Repo layout

The repo mirrors `~/.claude` under a `home/` directory so install is a straight
copy plus one settings merge — no path rewriting after install.

```
claude-config/
├── README.md
├── install.sh
├── home/                       # contents copied into ~/.claude (or $CLAUDE_CONFIG_DIR)
│   ├── CLAUDE.md               # curated global instructions
│   ├── settings.recommended.json
│   ├── statusline.sh           # gitprompt path made optional
│   ├── skills/
│   │   ├── agent-session-retro/
│   │   ├── doc-writing/
│   │   └── git-workflow/       # herdle/tk references softened
│   ├── bash-guard/hook.sh
│   ├── branch-guard/hook.sh
│   ├── git-safe/hook.sh
│   ├── read-once/{hook.sh,compact.sh,read-once,read-once.ps1}
│   └── hooks/{no-remote-writes.sh,agent-state.sh}
└── docs/superpowers/specs/...  # this spec
```

`rules/` is intentionally omitted: its only source content (`herdle.md`) is
herdle-specific and herdle is not shipped. All general guidance lives in
`CLAUDE.md` instead.

## Components

### 1. install.sh — copy + backup

- Resolves target as `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`.
- Copies every file under `home/` into the target. Before overwriting any
  existing file, moves the old one to `<file>.bak-<timestamp>`.
- `home/settings.recommended.json` is **not** copied verbatim. It is merged into
  the target `settings.json` via `jq`, deep-merging the shipped keys and
  **never** touching an existing `permissions` block. If no `settings.json`
  exists, the fragment becomes the new file. If `jq` is unavailable, the script
  prints the fragment and manual merge instructions and skips the merge step
  (all other files still copy).
- Marks hooks and `statusline.sh` executable (`chmod +x`).
- Re-runnable: every overwrite is backed up first, so repeated runs are safe.

### 2. settings.recommended.json — shareable subset

**Included** (merged):

- `env`:
  - `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50`
  - `MAX_THINKING_TOKENS=5000`
  - `CLAUDE_CODE_SUBAGENT_MODEL=sonnet`
  - `ANTHROPIC_MODEL=opus`
  - `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`,
    `ANTHROPIC_DEFAULT_HAIKU_MODEL` (pinned latest model IDs)
- `statusLine` (command → `~/.claude/statusline.sh`, refreshInterval 1)
- `theme` (dark), `verbose` (true), `effortLevel` (medium)
- `availableModels`, `skillListingBudgetFraction` (0.03)
- `hooks` wiring for the **shipped** hooks only, with paths written as
  `~/.claude/...` (not absolute user paths).

**Excluded** (with rationale documented in README where relevant):

- `permissions` — per the requirement.
- local-llm MCP servers, `enabledMcpjsonServers`, cavemem `mcpServers`.
- `enabledPlugins` / `extraKnownMarketplaces` (HA-personal; superpowers/caveman
  setup is covered in the README instead).
- `defaultMode: acceptEdits` — silently weakens an edit-safety default, so it is
  documented as optional rather than auto-merged.

The pinned `ANTHROPIC_DEFAULT_*_MODEL` IDs will age. README notes they pin
"latest" models as of the repo date and may need bumping; `ANTHROPIC_MODEL=opus`
and `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` carry the portable intent.

### 3. Hooks shipped

Portable safety/utility hooks, all verified free of personal or absolute paths
internally:

- `bash-guard`, `branch-guard`, `git-safe` — bash/branch/destructive-op guards.
- `hooks/no-remote-writes.sh` — blocks `git push` / `gh` writes.
- `hooks/agent-state.sh` — writes `.agent-state` consumed by the status line.
- `read-once/` — read-dedup engine (`hook.sh`, `compact.sh`, `read-once`,
  `read-once.ps1`). Runtime session logs and `stats.jsonl` are **excluded**.

**Not auto-wired:** `rtk-rewrite.sh` (requires rtk) and the cavemem hooks
(require cavemem and a machine-specific node path). The README documents these
as opt-in additions for users who install those tools.

### 4. statusline.sh de-personalization

The only hardcoded personal value is the gitprompt path
(`/Users/gfranks/bin/gitprompt.pl`). Replace with: honor
`$CLAUDE_STATUSLINE_GITPROMPT` if set, else look for `gitprompt.pl` on `PATH`,
else fall back to plain `git` for branch + dirty status. All other paths already
use `$HOME` / `$CLAUDE_CONFIG_DIR`.

### 5. Curated CLAUDE.md

Keep only broadly-useful, genericized guidance:

- **Permission patterns** — use broadest-reasonable allow patterns (table).
- **Shell cwd discipline** — cwd persists between Bash calls; scope with
  subshells / absolute paths (personal anecdote genericized).
- **Commit messages** — apostrophes are fine; use `git commit -F <file>` for
  long/multi-line messages.
- **Memory & task routing** — durable rules → CLAUDE.md; active work → your
  tracker; never store git/PR state in memory (tk/herdle specifics removed).

Dropped: HA, local-llm, rtk, caveman-enable, herdle/tk, defer-the-plan sections.

### 6. git-workflow skill softening

Ship as-is except soften herdle/tk references: the `herdle` orientation bullet
(§1.4), the herdle auto-prune / "track work in tk" lines (§6), and mistake #5.
The guard-hook content stays — it matches the shipped hooks. `superpowers:`
defers stay (superpowers is a documented companion).

### 7. README

- What it is + `./install.sh` quickstart.
- Settings reference: table of shipped keys and what each does.
- **Companion tools** (one line + install link each), noting which shipped
  pieces lean on them: superpowers (git-workflow defers), caveman (statusline
  badge), rtk (optional hook), cavemem (optional hook), tk, herdle.
- Optional add-ons: `defaultMode: acceptEdits`, rtk/cavemem hook wiring.

## De-personalization checklist

- statusline.sh gitprompt path → env/PATH/fallback (§4).
- settings hook paths → `~/.claude/...` (§2).
- No name/email in any shipped file (identity comes from git config; the
  harness injects userEmail/currentDate, not the files).
- Exclude all `read-once/session-*.jsonl`, `read-once/stats.jsonl`,
  `read-once/.last-cleanup`, and `session-env/` runtime data.

## Testing / validation

- `install.sh` into a throwaway `CLAUDE_CONFIG_DIR` (e.g. a temp dir): verify
  files land, settings merge produces valid JSON, and a pre-existing
  `permissions` block survives untouched.
- Second run: verify backups created, no data loss.
- `jq`-absent path: verify graceful fallback message.
- statusline.sh renders with and without `gitprompt.pl` present.
- Confirm no `gfranks` / `/Users/gfranks` / `Geoff` strings remain in shipped
  files (`grep -rI`).
</content>
</invoke>
