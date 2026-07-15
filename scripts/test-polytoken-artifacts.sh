#!/usr/bin/env bash
# scripts/test-polytoken-artifacts.sh
#
# Validates the native Polytoken artifacts under polytoken/ without installing
# them into a live config directory. Asserts the structure the installer relies
# on, then copies the artifacts into a throwaway config dir (with the canonical
# scripts under compat/) and runs `polytoken config validate --user` against it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v jq   >/dev/null 2>&1 || fail "jq is required"
command -v polytoken >/dev/null 2>&1 || fail "polytoken is required"
# The config merge relies on mikefarah/yq v4 deep-merge semantics
# (eval-all + the `*` merge operator). The Go-based Python `yq` wrapper does
# not support these flags and would silently misbehave.
command -v yq >/dev/null 2>&1 || fail "yq (mikefarah/yq v4) is required"
if ! yq --version 2>/dev/null | grep -Eq 'version v4\.'; then
  fail "yq must be mikefarah/yq v4 (got: $(yq --version 2>&1))"
fi

HOOKS="$ROOT/polytoken/hooks.json"
CFG="$ROOT/polytoken/config.recommended.yaml"
PERMS="$ROOT/polytoken/permissions.recommended.yaml"
AGENTS="$ROOT/polytoken/AGENTS.md"

# --- structural assertions (mirrors task-4-brief.md Step 1) ---

# Exactly eight hook entries, every name unique.
jq -e 'type == "array" and length == 8 and ([.[].name] | length == (unique | length))' \
    "$HOOKS" >/dev/null || fail "hooks.json must be an array of 8 uniquely-named hooks"

# Every hook fires on a supported event and invokes the installed adapter.
jq -e 'all(.[]; (.event == "pre_tool_use" or .event == "post_compaction") and (.handler.bash | contains("hooks/adapter.sh")))' \
    "$HOOKS" >/dev/null || fail "hooks must use pre_tool_use/post_compaction and the adapter"

# version: 2 headers on both recommendation files.
grep -q '^version: 2$' "$CFG"   || fail "config.recommended.yaml missing version: 2"
grep -q '^version: 2$' "$PERMS" || fail "permissions.recommended.yaml missing version: 2"

# Provider-neutral: no model names, model defaults, or Claude-specific hooks.
! grep -Eq 'opus|sonnet|haiku|defaults:|models:|agent-join|agent-state|statusline\.sh' \
    "$CFG" "$HOOKS" || fail "config/hooks.json must be provider-neutral"

# The literal install token is present (installer substitutes the real path).
grep -q '__POLYTOKEN_CONFIG_DIR__' "$HOOKS" \
    || fail "hooks.json must carry the literal __POLYTOKEN_CONFIG_DIR__ token"

# AGENTS.md exists and is Polytoken-native (Polytoken tool names, no Claude ones).
[ -f "$AGENTS" ] || fail "AGENTS.md missing"
grep -q 'shell_exec' "$AGENTS" || fail "AGENTS.md must reference Polytoken tool names"
! grep -Eq 'settings\.json|PreToolUse|CLAUDE_CONFIG_DIR' "$AGENTS" \
    || fail "AGENTS.md must not reference Claude-specific concepts"
grep -q 'rtk grep' "$AGENTS" \
    || fail "AGENTS.md must carry rtk content-search guidance"
grep -q 'executable: rtk' "$AGENTS" \
    || fail "AGENTS.md must carry the rtk permission-rules row"

# --- isolated config validation ---
#
# The recommended config is provider-neutral: it carries only `version` and the
# `tui` block, so it installs as an overlay onto a user config that already
# defines providers and models. To exercise the real install path we start from
# a copy of the live user config directory, then install the recommended
# artifacts over it (the installer writes config.yaml, permissions.yaml,
# hooks.json, and AGENTS.md, copying canonical scripts under compat/).

USER_CFG="${POLYTOKEN_USER_CONFIG_DIR:-$HOME/.config/polytoken}"
[ -f "$USER_CFG/config.yaml" ] \
  || fail "no user config.yaml at $USER_CFG to overlay onto"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Seed the isolated dir from the live user config so providers/models resolve.
cp -R "$USER_CFG/." "$TMP/"
# Install the recommended config as a deep merge onto the existing config.yaml
# (the installer preserves a user's providers/models and overlays recommended
# keys), then drop the remaining artifacts as their installed names.
if ! yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
      "$TMP/config.yaml" "$CFG" -o yaml > "$TMP/config.yaml.merged" \
      || ! mv "$TMP/config.yaml.merged" "$TMP/config.yaml"; then
  fail "config merge failed"
fi
cp "$PERMS" "$TMP/permissions.yaml"
cp "$AGENTS" "$TMP/AGENTS.md"

mkdir -p "$TMP/hooks" "$TMP/compat"
cp "$ROOT/polytoken/hooks/adapter.sh" "$TMP/hooks/adapter.sh"
chmod +x "$TMP/hooks/adapter.sh"

# Canonical scripts live under compat/ at the same relative paths the adapter is
# given. Mirror the home/ layout: bash-guard/, branch-guard/, git-safe/,
# read-once/, skill-once/, hooks/.
cp -R "$ROOT/home/bash-guard"   "$TMP/compat/bash-guard"
cp -R "$ROOT/home/branch-guard" "$TMP/compat/branch-guard"
cp -R "$ROOT/home/git-safe"     "$TMP/compat/git-safe"
cp -R "$ROOT/home/read-once"    "$TMP/compat/read-once"
cp -R "$ROOT/home/skill-once"   "$TMP/compat/skill-once"
mkdir -p "$TMP/compat/hooks"
cp "$ROOT/home/hooks/no-remote-writes.sh" "$TMP/compat/hooks/no-remote-writes.sh"

# Substitute the literal install token with the temp dir's absolute path, as the
# installer does before validation.
jq --arg dir "$TMP" \
   'walk(if type == "string" then gsub("__POLYTOKEN_CONFIG_DIR__"; $dir) else . end)' \
   "$HOOKS" > "$TMP/hooks.json" \
   || fail "token substitution failed"

echo "==> polytoken --config-dir \"$TMP\" config validate --user"
polytoken --config-dir "$TMP" config validate --user \
    || fail "isolated config validate --user failed"

# --- skill validation ---
#
# Validate every skill under home/skills/. All four skills must validate
# cleanly: the git-workflow frontmatter parse error (an unquoted colon in its
# description) was repaired in Task 6, so there is no longer a known-bad file to
# pin. Any validation failure fails the suite.

if ! ls home/skills/*/SKILL.md >/dev/null 2>&1; then
  fail "no skills found under home/skills/*/SKILL.md"
fi

for f in home/skills/*/SKILL.md; do
  if ! out=$(polytoken validate skill "$f" 2>&1); then
    fail "skill validation failed: $f"$'\n'"$out"
  fi
  echo "  - $f: OK"
done

# --- semantic portability assertions (Task 6) ---
#
# The canonical skills live in one tree shared by both harnesses, so each
# harness-specific claim must carry its counterpart. These assertions reject
# prose that is accurate in only one harness — e.g. an orchestration rule built
# solely on Claude's Agent tool with no Polytoken branch, or a "the CLAUDE.md"
# reference that pretends AGENTS.md does not exist.

ORCH="home/skills/agent-orchestration/SKILL.md"
RETRO="home/skills/agent-session-retro/SKILL.md"
GITWF="home/skills/git-workflow/SKILL.md"

# agent-orchestration: both native orchestration workflows, side by side.
grep -q '## Claude Code'        "$ORCH" || fail "$ORCH must document the Claude Code workflow"
grep -q '## Polytoken'          "$ORCH" || fail "$ORCH must document the Polytoken workflow"
grep -q 'SendMessage'           "$ORCH" || fail "$ORCH must reference Claude Agent/SendMessage"
grep -q 'agent-join'            "$ORCH" || fail "$ORCH must reference the Claude agent-join status block"
grep -q 'subagent'              "$ORCH" || fail "$ORCH must reference the Polytoken subagent tool"
grep -Eq 'job_block|job_result' "$ORCH" || fail "$ORCH must reference Polytoken job_block/job_result"
grep -q 'auto-drained'          "$ORCH" || fail "$ORCH must reference Polytoken auto-drained notifications"

# agent-session-retro: harness-neutral instruction-file terminology.
grep -q 'CLAUDE.md'             "$RETRO" || fail "$RETRO must reference CLAUDE.md"
grep -q 'AGENTS.md'             "$RETRO" || fail "$RETRO must reference AGENTS.md"

# git-workflow: equivalent Claude/Polytoken tool names where behavior matters.
grep -q 'Bash'                  "$GITWF" || fail "$GITWF must reference the Claude Bash tool"
grep -q 'shell_exec'            "$GITWF" || fail "$GITWF must reference the Polytoken shell_exec tool"

# --- README coverage assertions (Task 7) ---
#
# README.md must document the full installation mode: the exact commands users
# run, the Polytoken destination override, the agent-join omission (Polytoken
# uses native job/sidebar behavior instead), and the provider-neutral scope of
# the recommended config. These grep -Fq checks pin the literal strings so a
# prose rewrite cannot silently drop a documented capability.

grep -Fq './install.sh --target polytoken' "$ROOT/README.md" \
  || fail "README must document './install.sh --target polytoken'"
grep -Fq './install.sh --target all' "$ROOT/README.md" \
  || fail "README must document './install.sh --target all'"
grep -Fq 'POLYTOKEN_CONFIG_DIR' "$ROOT/README.md" \
  || fail "README must document the POLYTOKEN_CONFIG_DIR override"
grep -Fq 'agent-join' "$ROOT/README.md" \
  || fail "README must document the agent-join omission/replacement"
grep -Fq 'provider-neutral' "$ROOT/README.md" \
  || fail "README must state the config is provider-neutral"

echo "OK: all polytoken artifact assertions passed"
