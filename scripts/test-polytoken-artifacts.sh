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
! grep -Eq 'settings\.json|PreToolUse|CLAUDE_CONFIG_DIR|rtk ' "$AGENTS" \
    || fail "AGENTS.md must not reference Claude-specific concepts"

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
# Validate every skill under home/skills/. Three of the four skills validate
# cleanly. The fourth, home/skills/git-workflow/SKILL.md, has a pre-existing
# YAML frontmatter parse error (`mapping values are not allowed in this
# context at line 2`) caused by an unquoted colon in its description. Task 4
# scope is native artifacts only and explicitly forbids editing skills; skill
# portability is owned by Task 6. So rather than fail the whole suite on that
# one known-bad file, we pin its expected failure here and require every
# *other* skill to pass.
#
# >>> TASK 6 GATE (remove this comment when resolved) <<<
# When Task 6 ports/repairs the git-workflow skill so it validates, DELETE the
# entire GIT_WORKFLOW_KNOWN_BAD expected-failure branch below and require all
# skills to pass unconditionally (revert to a plain `fail` on any failure).
# Leaving this branch in place after the skill is fixed would let a
# regression pass silently.
GIT_WORKFLOW_SKILL="home/skills/git-workflow/SKILL.md"

if ! ls home/skills/*/SKILL.md >/dev/null 2>&1; then
  fail "no skills found under home/skills/*/SKILL.md"
fi

for f in home/skills/*/SKILL.md; do
  if out=$(polytoken validate skill "$f" 2>&1); then
    rc=0
  else
    rc=$?
  fi

  if [ "$f" = "$GIT_WORKFLOW_SKILL" ]; then
    # The one skill Task 4 cannot touch: it MUST fail with the known parse
    # error. If it unexpectedly passes (e.g. Task 6 already fixed it) we fail
    # loudly so the expected-failure branch is removed.
    if [ "$rc" -eq 0 ]; then
      fail "$GIT_WORKFLOW_SKILL unexpectedly validated; Task 6 likely fixed it — remove the GIT_WORKFLOW_KNOWN_BAD expected-failure branch and require all skills green"
    fi
    # The error wraps across terminal lines with a `│` glyph between `front`
    # and `matter`, so squeeze all whitespace first and then match on the
    # contiguous `matter parse error` fragment (always present on one line).
    oneline=$(printf '%s' "$out" | tr -s ' \t\r\n' ' ')
    case "$oneline" in
      *"matter parse error"*) ;;
      *) fail "$GIT_WORKFLOW_SKILL failed, but not with the known frontmatter parse error; got: $out" ;;
    esac
  else
    # Every other skill must validate cleanly.
    if [ "$rc" -ne 0 ]; then
      fail "skill validation failed: $f"$'\n'"$out"
    fi
  fi
done

echo "  - $GIT_WORKFLOW_SKILL: expected frontmatter parse failure (Task 6 gate pending)"

echo "OK: all polytoken artifact assertions passed"
