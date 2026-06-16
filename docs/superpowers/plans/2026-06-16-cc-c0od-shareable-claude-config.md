---
tkid: cc-c0od
lifecycle: planned
title: Shareable Claude Code config repo
date: 2026-06-16
---

# Shareable Claude Config Repo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `~/workspace/claude-config`, a de-personalized, installable repo of Claude Code skills, hooks, settings, global instructions, and status line.

**Architecture:** Repo mirrors `~/.claude` under `home/`. `install.sh` copies `home/` into `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` with timestamped backups, and merges `settings.recommended.json` into the user's `settings.json` via `jq` (never touching `permissions`). Most files are copied verbatim from the author's live config; a handful are authored or genericized here.

**Tech Stack:** Bash, `jq`, JSON, Markdown.

**Source of truth for copies:** the author's live `~/.claude`. Exact source paths are given per task. The repo already contains the committed spec under `docs/superpowers/specs/`.

---

### Task 0 (Setup)

**Files:** none (git + tk state only)

- [ ] **Step 1: Mark ticket in progress**

Run: `tk start cc-c0od`

- [ ] **Step 2: Create the work branch off `main`**

```bash
cd ~/workspace/claude-config
git switch -c feat/bootstrap-config main
```
Expected: `Switched to a new branch 'feat/bootstrap-config'`
(branch-guard blocks commits to `main`, so all work happens on this branch.)

- [ ] **Step 3: Record branch + lifecycle on the ticket**

Edit `.tickets/cc-c0od.md` frontmatter: add `branch: feat/bootstrap-config` and set `lifecycle: in-development`. Commit:
```bash
git add .tickets/cc-c0od.md
git commit -m "chore: start cc-c0od on feat/bootstrap-config"
```

---

### Task 1: Repo skeleton + .gitignore

**Files:**
- Create: `home/` (directory tree)
- Create: `.gitignore`

- [ ] **Step 1: Create the directory tree**

```bash
cd ~/workspace/claude-config
mkdir -p home/skills home/hooks home/bash-guard home/branch-guard home/git-safe home/read-once
```

- [ ] **Step 2: Write `.gitignore`**

Create `.gitignore`:
```gitignore
# runtime / session data must never be committed
home/read-once/session-*.jsonl
home/read-once/stats.jsonl
home/read-once/.last-cleanup
home/**/.DS_Store
*.bak-*
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: add repo skeleton and gitignore"
```

---

### Task 2: Vendor the three skills (verbatim) + soften git-workflow

**Files:**
- Create: `home/skills/agent-session-retro/` (copy)
- Create: `home/skills/doc-writing/` (copy)
- Create: `home/skills/git-workflow/` (copy, then edit `SKILL.md`)

- [ ] **Step 1: Copy the three skill directories**

```bash
cd ~/workspace/claude-config
for s in agent-session-retro doc-writing git-workflow; do
  rm -rf "home/skills/$s"
  cp -R "$HOME/.claude/skills/$s" "home/skills/$s"
done
```

- [ ] **Step 2: Soften herdle/tk references in `home/skills/git-workflow/SKILL.md`**

Make these exact edits (the guard-hook content and `superpowers:` defers stay — they match what this repo ships):

Replace the herdle orientation bullet (currently item 4 under "## 1. Orient before you touch git"):
```
4. `herdle` (or `herdle <project>`) — open PRs, work-in-progress (branches + in-flight tickets with sync state + lifecycle), and not-yet-started tickets at a glance. Dashboard semantics live in the `herdle-tk-flow` skill.
```
with:
```
4. Check open PRs and in-flight work however you track it (e.g. `gh pr list`, your ticket system).
```

Replace the merged-branch bullet (under "## 6. Branch & repo hygiene over time"):
```
- **Delete merged local branches** (`git branch -d`). `herdle` auto-prunes `origin` on every run and hides merged-PR / upstream-gone branches, so its **work-in-progress table** shows only live branches — use it to spot stragglers.
```
with:
```
- **Delete merged local branches** (`git branch -d`); prune stale remotes (`git remote prune origin`) periodically.
```

Replace the drift bullet:
```
- **A branch with no PR** and **an in-flight ticket with no pushed branch** are both drift — `herdle` flags these; resolve them, don't let them rot.
- Track the work itself in **tk**, not in commit messages or memory.
```
with:
```
- **A branch with no PR** and **an in-flight ticket with no pushed branch** are both drift — resolve them, don't let them rot.
- Track the work itself in your ticket system, not in commit messages or memory.
```

Replace mistake #5:
```
5. ❌ Leaving merged branches/worktrees lying around. ✅ Remove + prune as you go; let `herdle` surface drift.
```
with:
```
5. ❌ Leaving merged branches/worktrees lying around. ✅ Remove + prune as you go.
```

- [ ] **Step 3: Verify no herdle/tk strings remain in git-workflow**

Run: `grep -rIn -e herdle -e '\btk\b' home/skills/git-workflow/`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add home/skills/
git commit -m "feat: vendor agent-session-retro, doc-writing, git-workflow skills"
```

---

### Task 3: Vendor the portable hooks (exclude runtime data + tool-coupled hooks)

**Files:**
- Create: `home/bash-guard/hook.sh`, `home/branch-guard/hook.sh`, `home/git-safe/hook.sh` (copies)
- Create: `home/read-once/{hook.sh,compact.sh,read-once,read-once.ps1}` (copies, engine only)
- Create: `home/hooks/{no-remote-writes.sh,agent-state.sh}` (copies)

- [ ] **Step 1: Copy the guard hooks**

```bash
cd ~/workspace/claude-config
cp "$HOME/.claude/bash-guard/hook.sh"   home/bash-guard/hook.sh
cp "$HOME/.claude/branch-guard/hook.sh" home/branch-guard/hook.sh
cp "$HOME/.claude/git-safe/hook.sh"     home/git-safe/hook.sh
```

- [ ] **Step 2: Copy the read-once engine ONLY (no session logs)**

```bash
cp "$HOME/.claude/read-once/hook.sh"      home/read-once/hook.sh
cp "$HOME/.claude/read-once/compact.sh"   home/read-once/compact.sh
cp "$HOME/.claude/read-once/read-once"    home/read-once/read-once
cp "$HOME/.claude/read-once/read-once.ps1" home/read-once/read-once.ps1
```
Do NOT copy `session-*.jsonl`, `stats.jsonl`, or `.last-cleanup`.

- [ ] **Step 3: Copy the two standalone hooks (NOT rtk-rewrite, NOT test/sha files)**

```bash
cp "$HOME/.claude/hooks/no-remote-writes.sh" home/hooks/no-remote-writes.sh
cp "$HOME/.claude/hooks/agent-state.sh"      home/hooks/agent-state.sh
```
Excluded deliberately: `rtk-rewrite.sh` (needs rtk), `test-no-remote-writes.sh`, `.rtk-hook.sha256`.

- [ ] **Step 4: Verify no personal/absolute/tool paths leaked in**

Run:
```bash
grep -rIn -e '/Users/' -e '/opt/homebrew' -e gfranks -e '\brtk\b' -e cavemem \
  home/bash-guard home/branch-guard home/git-safe home/read-once home/hooks
```
Expected: no output. (If any appears, genericize before committing.)

- [ ] **Step 5: Commit**

```bash
git add home/bash-guard home/branch-guard home/git-safe home/read-once home/hooks
git commit -m "feat: vendor portable guard + read-once + agent-state hooks"
```

---

### Task 4: Vendor + genericize statusline.sh

**Files:**
- Create: `home/statusline.sh` (copy of `~/.claude/statusline.sh`, then edit the gitprompt block)

- [ ] **Step 1: Copy the status line**

```bash
cd ~/workspace/claude-config
cp "$HOME/.claude/statusline.sh" home/statusline.sh
```

- [ ] **Step 2: Replace the hardcoded gitprompt block**

In `home/statusline.sh`, find the block that begins `GP=/Users/gfranks/bin/gitprompt.pl` (the `if [ -n "$CWD" ] ... fi` that follows it, through the line `LEFT+="${DIM}|${RESET}"` and its closing `fi`). Replace that entire block with:

```bash
# gitprompt is optional: honor $CLAUDE_STATUSLINE_GITPROMPT, else look on PATH,
# else fall back to plain git for branch + dirty flag.
BRANCH=""; GSTAT=""
GP="${CLAUDE_STATUSLINE_GITPROMPT:-}"
[ -z "$GP" ] && GP="$(command -v gitprompt.pl 2>/dev/null || true)"
if [ -n "$CWD" ] && [ -d "$CWD" ] && [ -n "$GP" ] && [ -x "$GP" ] && command -v perl >/dev/null 2>&1; then
  GOUT=$(cd "$CWD" && PS0=$'%b\x01%c%u%f%F%A%B' \
        perl "$GP" c=+ u=! f=? 'F=»' 'A=↑' 'B=↓' statuscount=1 2>/dev/null)
  BRANCH=${GOUT%%$'\x01'*}
  GSTAT=${GOUT#*$'\x01'}
elif [ -n "$CWD" ] && [ -d "$CWD" ] && command -v git >/dev/null 2>&1; then
  BRANCH=$(cd "$CWD" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -n "$BRANCH" ] && [ -n "$(cd "$CWD" && git status --porcelain 2>/dev/null)" ]; then
    GSTAT="!"
  fi
fi
if [ -n "$BRANCH" ]; then
  LEFT+=" ${DIM}|${RESET}${GREEN}${BRANCH}${RESET}"
  [ -n "$WT" ] && LEFT+=" ${DIM}(${WT})${RESET}"
  if [ -z "$GSTAT" ]; then
    LEFT+=" ${GREEN}✔${RESET}"
  else
    LEFT+=" ${YELLOW}${GSTAT}${RESET}"
  fi
  LEFT+="${DIM}|${RESET}"
fi
```

- [ ] **Step 3: Verify it parses and no personal path remains**

Run:
```bash
bash -n home/statusline.sh && echo "syntax ok"
grep -n -e '/Users/' -e gfranks home/statusline.sh
```
Expected: `syntax ok`, and no grep output.

- [ ] **Step 4: Smoke-test rendering (no gitprompt installed)**

Run:
```bash
echo '{"model":{"display_name":"Opus","id":"claude-opus-4-8"},"cwd":"'"$PWD"'","workspace":{"current_dir":"'"$PWD"'"}}' \
  | COLUMNS=120 bash home/statusline.sh
```
Expected: a rendered status line showing the cwd and the current git branch (`feat/bootstrap-config`) with a dirty/clean marker — no errors.

- [ ] **Step 5: Commit**

```bash
git add home/statusline.sh
git commit -m "feat: vendor statusline with optional gitprompt + git fallback"
```

---

### Task 5: Author settings.recommended.json

**Files:**
- Create: `home/settings.recommended.json`

- [ ] **Step 1: Write the fragment**

Create `home/settings.recommended.json` (no `permissions`, no MCP/plugin/marketplace keys, no `defaultMode`):
```json
{
  "env": {
    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "50",
    "MAX_THINKING_TOKENS": "5000",
    "CLAUDE_CODE_SUBAGENT_MODEL": "sonnet",
    "ANTHROPIC_MODEL": "opus",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5-20251001"
  },
  "availableModels": ["opus", "sonnet", "haiku"],
  "theme": "dark",
  "verbose": true,
  "effortLevel": "medium",
  "skillListingBudgetFraction": 0.03,
  "statusLine": {
    "type": "command",
    "command": "bash \"$HOME/.claude/statusline.sh\"",
    "refreshInterval": 1
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Read", "hooks": [ { "type": "command", "command": "~/.claude/read-once/hook.sh" } ] },
      { "hooks": [ { "type": "command", "command": "~/.claude/git-safe/hook.sh" } ] },
      { "hooks": [ { "type": "command", "command": "~/.claude/bash-guard/hook.sh" } ] },
      { "hooks": [ { "type": "command", "command": "~/.claude/branch-guard/hook.sh" } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/.claude/hooks/no-remote-writes.sh" } ] },
      { "hooks": [ { "type": "command", "command": "~/.claude/hooks/agent-state.sh" } ] }
    ],
    "PostCompact": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "~/.claude/read-once/compact.sh" } ] }
    ]
  }
}
```

- [ ] **Step 2: Validate JSON**

Run: `jq . home/settings.recommended.json >/dev/null && echo "valid json"`
Expected: `valid json`

- [ ] **Step 3: Verify no permissions / personal data**

Run: `grep -n -e permissions -e '/Users/' -e gfranks home/settings.recommended.json`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add home/settings.recommended.json
git commit -m "feat: add recommended settings fragment (env, statusline, hooks)"
```

---

### Task 6: Author the curated CLAUDE.md

**Files:**
- Create: `home/CLAUDE.md`

- [ ] **Step 1: Write the curated global instructions**

Create `home/CLAUDE.md`:
```markdown
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
```

- [ ] **Step 2: Verify no personal/tool content remains**

Run: `grep -ni -e gfranks -e gnuconsulting -e home.assistant -e local.llm -e '\brtk\b' -e herdle -e caveman home/CLAUDE.md`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add home/CLAUDE.md
git commit -m "feat: add curated global CLAUDE.md instructions"
```

---

### Task 7: Author install.sh

**Files:**
- Create: `install.sh`

- [ ] **Step 1: Write the installer**

Create `install.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/home" && pwd)"
DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TS="$(date +%Y%m%d-%H%M%S)"
FRAG="$SRC_DIR/settings.recommended.json"
SETTINGS="$DEST/settings.json"

echo "Installing Claude config into: $DEST"
mkdir -p "$DEST"

# 1. Copy every file under home/ EXCEPT the settings fragment (merged separately).
while IFS= read -r -d '' src; do
  rel="${src#"$SRC_DIR"/}"
  [ "$rel" = "settings.recommended.json" ] && continue
  dst="$DEST/$rel"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then
    mv "$dst" "$dst.bak-$TS"
    echo "  backed up: $rel -> $rel.bak-$TS"
  fi
  cp "$src" "$dst"
done < <(find "$SRC_DIR" -type f -print0)

# 2. Make scripts executable.
for f in statusline.sh bash-guard/hook.sh branch-guard/hook.sh git-safe/hook.sh \
         read-once/hook.sh read-once/compact.sh read-once/read-once \
         hooks/no-remote-writes.sh hooks/agent-state.sh; do
  [ -f "$DEST/$f" ] && chmod +x "$DEST/$f"
done

# 3. Merge the settings fragment (deep merge; fragment has no permissions, so an
#    existing permissions block is preserved).
if command -v jq >/dev/null 2>&1; then
  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak-$TS"
    tmp="$(mktemp)"
    jq -s '.[0] * .[1]' "$SETTINGS" "$FRAG" > "$tmp" && mv "$tmp" "$SETTINGS"
    echo "  merged settings.recommended.json into settings.json (existing permissions preserved)"
    echo "  previous settings.json saved to settings.json.bak-$TS"
  else
    cp "$FRAG" "$SETTINGS"
    echo "  wrote new settings.json from the recommended fragment"
  fi
else
  echo "  jq not found — skipping settings merge."
  echo "  Manually merge keys from: $FRAG"
  echo "  into: $SETTINGS  (do NOT overwrite your permissions block)"
fi

echo "Done."
```

- [ ] **Step 2: Make it executable + syntax-check**

```bash
chmod +x install.sh
bash -n install.sh && echo "syntax ok"
```
Expected: `syntax ok`

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "feat: add copy+backup installer with jq settings merge"
```

---

### Task 8: Author README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the README**

Create `README.md`:
```markdown
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
`<file>.bak-<timestamp>`. It merges `home/settings.recommended.json` into your
`settings.json` with `jq`, leaving any existing `permissions` block untouched.
If `jq` is missing it prints manual merge instructions instead. Re-running is
safe — every overwrite is backed up first.

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
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with install, settings reference, companion tools"
```

---

### Task 9: End-to-end install test into a throwaway target

**Files:**
- Create: `scripts/test-install.sh` (validation harness; kept in repo)

- [ ] **Step 1: Write the test harness**

Create `scripts/test-install.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Seed a pre-existing settings.json WITH a permissions block to prove it survives.
cat > "$TMP/settings.json" <<'JSON'
{ "permissions": { "allow": ["Bash(echo:*)"] }, "theme": "light" }
JSON

CLAUDE_CONFIG_DIR="$TMP" "$REPO/install.sh"

echo "--- assertions ---"
test -f "$TMP/statusline.sh"                       && echo "ok: statusline copied"
test -f "$TMP/bash-guard/hook.sh"                  && echo "ok: guard hook copied"
test -x "$TMP/hooks/agent-state.sh"                && echo "ok: hook executable"
test ! -f "$TMP/settings.recommended.json"         && echo "ok: fragment not copied verbatim"
jq -e '.permissions.allow[0] == "Bash(echo:*)"' "$TMP/settings.json" >/dev/null \
                                                   && echo "ok: existing permissions preserved"
jq -e '.env.ANTHROPIC_MODEL == "opus"' "$TMP/settings.json" >/dev/null \
                                                   && echo "ok: env merged"
jq -e '.hooks.PreToolUse | length == 6' "$TMP/settings.json" >/dev/null \
                                                   && echo "ok: hooks merged"
ls "$TMP"/settings.json.bak-* >/dev/null 2>&1      && echo "ok: settings backed up"
echo "ALL PASS"
```

- [ ] **Step 2: Run it**

```bash
chmod +x scripts/test-install.sh
bash scripts/test-install.sh
```
Expected: every `ok:` line prints, ending with `ALL PASS`.

- [ ] **Step 3: Full de-personalization sweep across shipped files**

Run:
```bash
grep -rIn -e gfranks -e '/Users/gfranks' -e Geoff -e gnuconsulting home/ install.sh README.md
```
Expected: no output. (Investigate and fix any hit before proceeding.)

- [ ] **Step 4: Commit**

```bash
git add scripts/test-install.sh
git commit -m "test: add end-to-end install harness with permissions-preservation check"
```

---

### Task 10 (Finalize)

**Files:** none (review, squash, validation doc)

- [ ] **Step 1: Two code-review passes, fixing each time**

Dispatch a subagent running `/code-review feat/bootstrap-config medium --fix`, address findings, then a second running `/code-review feat/bootstrap-config high --fix`. Defer the review process to `superpowers:requesting-code-review`. Resolve any remaining findings.

- [ ] **Step 2: Re-run the install test after fixes**

Run: `bash scripts/test-install.sh`
Expected: `ALL PASS`.

- [ ] **Step 3: Squash the branch into one commit**

```bash
cd ~/workspace/claude-config
git reset --soft main
git commit -m "feat: shareable, de-personalized Claude Code config repo (cc-c0od)"
```
(This squashes all `feat/bootstrap-config` commits into one. The spec/plan commits already on `main` are untouched.)

- [ ] **Step 4: Write the validation doc**

Create `docs/superpowers/validation/2026-06-16-cc-c0od-shareable-claude-config-validation.md` with concrete acceptance steps:
- Clone fresh, run `./install.sh` into a temp `CLAUDE_CONFIG_DIR`; confirm files land and are executable.
- Confirm a pre-existing `permissions` block survives the merge (the harness checks this).
- Confirm `env`, `statusLine`, and `hooks` keys are present in the merged `settings.json`.
- Confirm `bash -n` passes on `statusline.sh` and `install.sh`.
- Confirm the de-personalization grep returns nothing.
- Confirm the `jq`-absent path prints manual instructions (temporarily shadow `jq` on `PATH`).

- [ ] **Step 5: Run the validation harness and stamp lifecycle**

Run `bash scripts/test-install.sh`; if it passes, set `.tickets/cc-c0od.md` `lifecycle: validated` (otherwise `pending-validation`). Commit the validation doc + ticket update. Do **not** open a PR (that signals fully validated work and is handled by `superpowers:finishing-a-development-branch`).

---

## Self-Review

**Spec coverage:**
- install.sh copy+backup + jq merge preserving permissions → Tasks 7, 9.
- settings fragment (included/excluded keys) → Task 5.
- Hooks shipped + exclusions (rtk/cavemem/runtime data) → Task 3, README optional add-ons (Task 8).
- statusline gitprompt genericization → Task 4.
- Curated CLAUDE.md content → Task 6.
- git-workflow herdle/tk softening → Task 2.
- rules/ omitted → reflected by its absence (no task creates it); README "What's included" lists no rules.
- README + companion tools → Task 8.
- De-personalization checklist (statusline path, hook paths, no name/email, exclude runtime data) → Tasks 3/4 verify steps + Task 9 Step 3 sweep + Task 1 .gitignore.
- Testing/validation (temp install, second-run backups, jq-absent, statusline w/ and w/o gitprompt) → Task 9 + Task 10 validation doc.

**Placeholder scan:** No TBD/TODO; every authored file shown in full; every copy is an exact `cp` command.

**Type/path consistency:** Destination paths (`~/.claude/...`) in the settings fragment match the `home/` layout the installer copies. `PreToolUse` length 6 asserted in Task 9 matches the 6 entries authored in Task 5. Branch name `feat/bootstrap-config` consistent across Setup, statusline smoke test, and Finalize.
```
