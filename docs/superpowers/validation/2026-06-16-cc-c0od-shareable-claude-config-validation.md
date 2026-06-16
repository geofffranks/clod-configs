---
tkid: cc-c0od
lifecycle: validated
title: Shareable Claude Code config repo — validation
date: 2026-06-16
---

# Validation — Shareable Claude Config Repo

Acceptance steps for the `claude-config` repo. The automated harness
`scripts/test-install.sh` covers the install/merge core; the remaining steps are
manual one-liners.

## Automated (scripts/test-install.sh)

Run:
```bash
bash scripts/test-install.sh
```
Expected: every `ok:` line prints, ending with `ALL PASS`. The harness installs
into a throwaway `CLAUDE_CONFIG_DIR`, seeding a pre-existing `settings.json` with
a `permissions` block, and asserts:

- [x] `statusline.sh` and hook files are copied.
- [x] Hooks land executable.
- [x] `settings.recommended.json` is NOT copied verbatim (merged instead).
- [x] The pre-existing `permissions` block survives the merge.
- [x] `env.ANTHROPIC_MODEL` is merged in.
- [x] `hooks.PreToolUse` has the fragment's 6 entries.
- [x] The prior `settings.json` is backed up to `settings.json.bak-<ts>`.

## Manual checks

- [x] **Syntax:** `bash -n install.sh` and `bash -n home/statusline.sh` both clean.
- [x] **De-personalization sweep:** `grep -rIn -e gfranks -e '/Users/gfranks' -e Geoff -e gnuconsulting home/ install.sh README.md scripts/` returns nothing.
- [x] **Statusline with gitprompt:** rendered correctly when `gitprompt.pl` is on PATH (shows branch + dirty markers).
- [x] **Statusline git fallback:** with `gitprompt.pl` off PATH and `CLAUDE_STATUSLINE_GITPROMPT` empty, the plain-`git` branch shows (verified under bash 5 with PATH=`/opt/homebrew/bin:/usr/bin:/bin`).
- [x] **jq-absent path:** with `jq` shadowed off PATH, the installer skips the merge and prints manual-merge instructions instead of failing.
- [x] **Second run safety:** re-running the installer backs up overwritten files to `*.bak-<ts>` (timestamped, no clobber).

## Known limitations (documented in README)

- The `jq` settings merge recursively merges objects (existing `env` keys kept)
  but replaces array-valued keys — an existing `hooks` block is replaced by the
  fragment's. The prior file is backed up; users re-add custom hooks from the
  backup.
- The status line requires bash 4+ (`mapfile`); macOS ships bash 3.2.
- Vendored hooks (`read-once`, `no-remote-writes`) are copied verbatim from the
  author's live config and were not modified during packaging.

## Out of scope (no PR)

Per the artifact convention, this validation does not open a PR — merging the
branch is handled by `superpowers:finishing-a-development-branch`.
