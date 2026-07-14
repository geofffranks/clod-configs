# claude-config

A portable, de-personalized set of configuration for two AI coding harnesses:
[Claude Code](https://claude.com/claude-code) and
[Polytoken](https://github.com/obra/polytoken). It bundles a few skills,
safety/utility hooks, a curated global instruction file, and recommended
settings — but **no permissions** (those are always yours to grant).

A single `install.sh` installs for either or both harnesses. The two harnesses
keep separate configuration and instruction files because their schemas and
runtime semantics differ; skills and the canonical hook logic are shared.

## Install

```bash
git clone <this-repo> claude-config
cd claude-config
./install.sh
```

With no arguments, `./install.sh` is a **Claude Code** install — identical to
the original behavior, and the existing tests stay green. To target a specific
harness (or both):

```bash
./install.sh --target claude       # Claude Code config (default; same as no args)
./install.sh --target polytoken    # native Polytoken config
./install.sh --target all          # install both targets, independently
```

`--target all` runs each target as an independent step and reports each result;
it does not roll back a success if the other target fails.

### Overwrite

By default, when a recommended value differs from yours you are walked through
each difference and approve them individually (see *Merge behavior* below). To
take every recommended value without prompting:

```bash
./install.sh --target claude --overwrite
./install.sh --target polytoken --overwrite
```

`CLAUDE_CONFIG_OVERWRITE=1` does the same thing via the environment.

### Destinations

| Target | Default | Override |
|---|---|---|
| Claude Code | `~/.claude` | `CLAUDE_CONFIG_DIR` |
| Polytoken | `~/.config/polytoken` | `POLYTOKEN_CONFIG_DIR` |

Each target reads its own TTY override for interactive prompts:
`CLAUDE_CONFIG_TTY` (Claude) and `POLYTOKEN_CONFIG_TTY` (Polytoken); both
default to `/dev/tty`.

### Requirements

| Dependency | Used by | Notes |
|---|---|---|
| **bash 4+** | Claude status line (`mapfile`) | macOS ships bash 3.2 — install a newer one via Homebrew. |
| **jq** | both targets | settings/hooks merge and JSON processing. |
| **mikefarah/yq v4** | Polytarget YAML merge | the Go-based `yq`; the Python `yq` wrapper does **not** support the required `eval-all` + `*` deep-merge and is rejected. |
| **Polytoken CLI** | Polytarget target | `polytoken config validate --user` validates structured writes in context; `polytoken validate skill` checks skills. |
| **python3** | Polytoken hook adapter | validates canonical hook paths stay under the config root. |

Missing a structured-merge dependency never triggers an unsafe text merge: the
affected step is skipped and exact manual instructions are printed.

## What each target installs

### Claude Code target

Copies everything under `home/` into `CLAUDE_CONFIG_DIR`, then merges
`home/settings.recommended.json` into your `settings.json`.

| Piece | Notes |
|---|---|
| `skills/` | Shared canonical skills (see below). |
| `bash-guard`, `branch-guard`, `git-safe` | Block risky bash, commits to protected branches, and destructive git ops. |
| `hooks/no-remote-writes.sh` | Blocks unsolicited `git push` / `gh` writes. |
| `hooks/agent-state.sh` | Writes the working/idle badge the status line shows. |
| `read-once/` | De-duplicates repeated file reads to save context. |
| `skill-once/` | Hard-denies re-loading a skill body already loaded this session (per-agent, so subagents are never wrongly blocked); `--force` reloads. |
| `agent-join/` | Emits an `<orchestration-status>` block when a Claude Agent subagent joins, so the main session can correlate work by id. |
| `statusline.sh` | Status line: cwd, git, agent, PR, model, context %, cost, rate limits. |
| `settings.recommended.json` | `env` (models, thinking budget, autocompact), theme, statusline, and hook wiring. No permissions. |
| `CLAUDE.md` | Curated global instructions: permission patterns, shell-cwd discipline, commit tips, memory routing. |

### Polytoken target

Installs **provider-neutral**, native Polytoken configuration into
`POLYTOKEN_CONFIG_DIR`. The two harnesses differ in what is portable, so the
Polytoken target deliberately omits Claude-only artifacts and replaces them
with Polytoken-native equivalents.

| Piece | Source | Notes |
|---|---|---|
| `config.yaml` | `polytoken/config.recommended.yaml` | `version: 2` + a `tui` block only (see below). |
| `permissions.yaml` | `polytoken/permissions.recommended.yaml` | Empty `version: 2` recommendation — your rules are always preserved. |
| `hooks.json` | `polytoken/hooks.json` | Eight native hooks, all routed through `hooks/adapter.sh`. |
| `AGENTS.md` | `polytoken/AGENTS.md` | Polytoken-native global instructions (Polytoken tool names). |
| `skills/` | `home/skills/` | The same canonical skills tree shared with Claude. |
| `compat/` | `home/{bash-guard,branch-guard,git-safe,read-once,skill-once}` + `home/hooks/no-remote-writes.sh` | Canonical hook scripts installed under `compat/`, invoked via the adapter. |

#### Provider-neutral status configuration

The recommended `config.yaml` is **provider-neutral**: it carries only
`version: 2` and a `tui` block. It deliberately omits all model pins, model
defaults, and compaction/thinking settings that the Claude settings fragment
carries (`ANTHROPIC_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`,
`ANTHROPIC_DEFAULT_*_MODEL`, `MAX_THINKING_TOKENS`,
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`). Polytoken defines its own providers and
models in your user config; the recommendation installs as an overlay and never
overwrites them.

The `tui` block selects a dark theme and a native status line built from
Polytoken's own modules:

```yaml
version: 2
tui:
  theme: dark
  status-line:
    - kind: cwd
    - kind: source-control
    - kind: facet
    - kind: model
    - kind: permissions
    - kind: context-usage
```

This replaces Claude's executable `statusline.sh` (cwd, git, agent, PR, model,
context %, cost, rate limits). The native status line uses Polytoken's
documented modules; PR status, dollar cost, and subscription rate-window are
**not** reproduced because Polytoken has no documented module for them.

#### Native replacements for Claude-only mechanisms

Polytoken has native facilities for several things Claude implements with
custom scripts, so the Polytoken target does not install the Claude versions:

- **Status line** — Claude's `statusline.sh` → Polytoken's native `tui.status-line` modules (above).
- **Agent working/idle state** — Claude's `hooks/agent-state.sh` (writes a badge the status line reads) → Polytoken's native facet/agent state shown in its own UI.
- **Agent join / orchestration status** — Claude's `agent-join/` hook (emits an `<orchestration-status>` block so the main session can correlate Agent subagent work by id) → Polytoken's native job system, sidebar, and auto-drained completion notifications. There is no `agent-join` hook or ledger in the Polytoken target.

#### Wrapped hook families (canonical logic, shared with Claude)

The eight native hooks run the **same canonical policy logic** as the Claude
hooks through a thin adapter (`hooks/adapter.sh`) that translates Polytoken's
event input and decision output. They are installed as named entries merged
into your `hooks.json`:

| Name | Event | Wraps |
|---|---|---|
| `bash-guard` | `pre_tool_use` (`shell_exec`) | `compat/bash-guard/hook.sh` |
| `branch-guard` | `pre_tool_use` (`shell_exec`) | `compat/branch-guard/hook.sh` |
| `git-safe` | `pre_tool_use` (`shell_exec`) | `compat/git-safe/hook.sh` |
| `no-remote-writes` | `pre_tool_use` (`shell_exec`) | `compat/hooks/no-remote-writes.sh` |
| `read-once` | `pre_tool_use` (`file_read`) | `compat/read-once/hook.sh` |
| `skill-once` | `pre_tool_use` (`skill`) | `compat/skill-once/hook.sh` |
| `read-once-reset` | `post_compaction` | `compat/read-once/compact.sh` |
| `skill-once-reset` | `post_compaction` | `compat/skill-once/compact.sh` |

The two `post_compaction` hooks reset the read-once/skill-once caches so
de-duplication state is cleared after compaction.

#### Canonical shared skills

`home/skills/` is one canonical tree installed into both targets. The skills
are written to be accurate in either harness where it matters — for example,
`agent-orchestration` documents both the Claude Code (Agent/SendMessage,
`agent-join`) and Polytoken (`subagent`, `job_block`/`job_result`,
auto-drained) workflows side by side, and `git-workflow` names both Claude's
`Bash` and Polytoken's `shell_exec`.

#### Negating a global hook per-project

Hooks are installed at the **global** config root. A project may negate an
installed global hook **by name** using Polytoken's native per-project hook
negation mechanism (e.g. add a same-named entry that disables it in the
project's own hook config). The global installer never edits project hook
files.

#### Known limitations (Polytoken target)

- **read-once is advisory-inert under Polytoken until `READ_ONCE_MODE=deny`
  is set.** The canonical `read-once` hook defaults to `warn` mode: on a
  repeated read it allows the read *and* attaches an advisory reason
  ("…already in context, ~X tokens…"). Polytoken's `pre_tool_use` **`allow`**
  outcome has no `reason` field (only `deny` carries one), so the adapter
  emits a bare `{"outcome":"allow"}` and the advisory is discarded. Net effect:
  with the shipped default, the `read-once` hook permits every re-read and the
  de-duplication nudge never reaches the model — it provides no context savings
  under Polytoken until you opt into hard enforcement. To get real de-dup,
  set `READ_ONCE_MODE=deny` in the read-once hook's environment (e.g. in your
  shell profile or `hooks.json` handler). (`skill-once` is unaffected — it
  denies by default.)

## Merge behavior

Both targets merge structured files **one patch at a time**. For each
difference — a new key, a changed value, or a recommended hook you don't have
yet — it prints the detail and asks `[y/N]` (Enter skips the change — keeps
your value, declines new keys). Arrays (e.g. `availableModels`) are treated as
a single unit.

- **Interactive (default):** each patch is accepted or declined individually.
- **`--overwrite` / `CLAUDE_CONFIG_OVERWRITE=1`:** accepts every recommended patch without prompting, but never deletes unrelated user entries.
- **No TTY:** applies only **additive** patches (new keys, new hooks) and keeps
  your values on any conflict, with an actionable diagnostic naming the
  conflicts.

A file is backed up to `<file>.bak-<timestamp>` only when the merged result
actually differs from what was there; an unchanged file is left alone and no
backup is created. Re-running is safe — idempotent installs report
"unchanged"/"up-to-date" and create no new backups.

Per target, the merge targets are:

- **Claude** — `settings.json` (generic keys plus per-event hook additions; your permissions block is never touched).
- **Polytoken** — `config.yaml` (provider-neutral leaf values; providers/models preserved), `hooks.json` (merged by unique `name`: add missing names, preserve unrelated hooks and their order, treat a same-name entry with a different event/matcher/handler as a conflict, never install duplicate names), `permissions.yaml` (left untouched when it exists).

Every structured write is rendered to a temporary file, parsed and validated
(including in-context `polytoken config validate --user` for the Polytoken
target), backed up only if changed, then atomically renamed over the
destination. A validation failure removes the staging file and leaves the
original intact. `AGENTS.md` is not structurally merged: it is installed when
absent, left alone when identical, and prompted before backing up and replacing
when it differs.

### Claude settings reference

The merged `env` keys: `ANTHROPIC_MODEL=opus` and
`CLAUDE_CODE_SUBAGENT_MODEL=sonnet` set the main/subagent models;
`ANTHROPIC_DEFAULT_*_MODEL` pin specific model IDs (current as of this repo's
date — bump them as new models ship); `MAX_THINKING_TOKENS` and
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` tune thinking budget and autocompact
threshold.

## Optional add-ons

- **`defaultMode: acceptEdits`** — auto-accepts file edits. Not merged by default
  (it weakens an edit-safety prompt). Add it to `settings.json` yourself if you
  want it.
- **gitprompt** — `statusline.sh` uses [`gitprompt.pl`](https://github.com/magicmonty/bash-git-prompt)
  if it's on `PATH` or pointed to by `$CLAUDE_STATUSLINE_GITPROMPT`; otherwise it
  falls back to plain `git` for the branch + dirty flag. (Polytoken's native
  status line does not use gitprompt.)

## Companion tools (install separately)

These are referenced by or complement this config but are not bundled:

- **[superpowers](https://github.com/obra/superpowers-marketplace)** — the
  skill framework `git-workflow` defers to for branch/PR/worktree mechanics.
- **rtk** — read/grep/test output compressor. If installed, wire its hook:
  add `{ "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/.claude/hooks/rtk-rewrite.sh" } ] }`
  to `hooks.PreToolUse` (script ships with rtk).
- **cavemem** — memory MCP + hooks. If installed, add its `mcpServers` entry and
  `UserPromptSubmit`/`PostToolUse`/`Stop`/`SessionStart`/`SessionEnd` hooks per
  cavemem's docs.
- **tk** — minimal local ticket system.
- **herdle** — cross-project work dashboard built on `tk`.
