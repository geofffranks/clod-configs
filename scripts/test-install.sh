#!/usr/bin/env bash
# Scenario harness for install.sh's settings.json merge behavior.
# No `set -e`: assertions must keep running so we see every failure.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAG="$REPO/home/settings.recommended.json"

pass=0 fail=0
ok() { echo "  ok: $1"; pass=$((pass + 1)); }
no() { echo "  FAIL: $1"; fail=$((fail + 1)); }
# ajq <file> <jq-filter> <msg> — assert the filter is truthy against the file.
ajq() { if jq -e "$2" "$1" >/dev/null 2>&1; then ok "$3"; else no "$3"; fi; }
# has <haystack> <needle> <msg> / hasnt <...> — assert substring presence/absence.
has() { case "$1" in *"$2"*) ok "$3" ;; *) no "$3" ;; esac; }
hasnt() { case "$1" in *"$2"*) no "$3" ;; *) ok "$3" ;; esac; }
hasbak() { ls "$1"/settings.json.bak-* >/dev/null 2>&1; }
seed() { local d; d="$(mktemp -d)"; printf '%s' "$2" >"$d/settings.json"; printf '%s' "$d"; }
sc() { echo; echo "=== $1 ==="; }

CONFLICT='{ "permissions": { "allow": ["Bash(echo:*)"] }, "theme": "light" }'

# --- S1: additions only (no conflicting values) -> silent merge, no warning ---
sc "S1 additions-only -> silent merge"
D="$(seed x '{ "permissions": { "allow": ["Bash(echo:*)"] }, "env": { "FOO": "bar" } }')"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" 2>&1)"
hasnt "$out" "OVERWRITE"                    "no overwrite warning"
ajq "$D/settings.json" '.env.FOO == "bar"'             "existing env key kept"
ajq "$D/settings.json" '.env.ANTHROPIC_MODEL == "opus"' "recommended env added"
ajq "$D/settings.json" '.theme == "dark"'              "new key (theme) added"
ajq "$D/settings.json" '.permissions.allow[0] == "Bash(echo:*)"' "permissions kept"
test -f "$D/statusline.sh" && ok "files copied (step 1 intact)" || no "files copied"
rm -rf "$D"

# --- S2: conflict, non-interactive (no TTY) -> conflict declined, additive applied ---
sc "S2 conflict non-interactive -> keep-mine, additive applied"
D="$(seed x "$CONFLICT")"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" 2>&1)"
has "$out" "differ"                                     "warned conflicts differ from yours"
has "$out" "theme"                                      "named the conflicting key"
ajq "$D/settings.json" '.theme == "light"'             "theme kept (conflict declined w/o TTY)"
ajq "$D/settings.json" '.env.ANTHROPIC_MODEL == "opus"' "additive env still added"
ajq "$D/settings.json" '.hooks.PreToolUse | length == 7' "additive hooks still added"
ajq "$D/settings.json" '.permissions.allow[0] == "Bash(echo:*)"' "permissions kept"
hasbak "$D" && ok "backup written (file changed)" || no "backup written"
rm -rf "$D"

# --- S3: conflict, CLAUDE_CONFIG_OVERWRITE=1 -> fragment wins ---
sc "S3 conflict + CLAUDE_CONFIG_OVERWRITE=1 -> overwrite"
D="$(seed x "$CONFLICT")"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_OVERWRITE=1 CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" 2>&1)"
ajq "$D/settings.json" '.theme == "dark"'              "theme overwritten (fragment wins)"
ajq "$D/settings.json" '.permissions.allow[0] == "Bash(echo:*)"' "permissions kept"
hasbak "$D" && ok "backup written" || no "backup written"
rm -rf "$D"

# --- S4: conflict, --overwrite arg -> fragment wins ---
sc "S4 conflict + --overwrite arg -> overwrite"
D="$(seed x "$CONFLICT")"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --overwrite 2>&1)"
ajq "$D/settings.json" '.theme == "dark"'              "theme overwritten via --overwrite"
hasbak "$D" && ok "backup written (--overwrite path)" || no "backup written (--overwrite path)"
rm -rf "$D"

# --- S4b: unknown arg -> usage error, non-zero exit (no seed needed; exits at parse) ---
sc "S4b unknown arg -> error exit"
D="$(mktemp -d)"
out="$(CLAUDE_CONFIG_DIR="$D" "$REPO/install.sh" --bogus 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "non-zero exit on unknown arg (rc=$rc)" || no "non-zero exit on unknown arg (rc=$rc)"
has "$out" "usage"                                     "printed usage"
rm -rf "$D"

# --- S5: interactive, accept every patch -> all recommended applied ---
sc "S5 interactive accept-all -> overwrite"
D="$(seed x "$CONFLICT")"; TTY="$(mktemp)"; printf 'y\n%.0s' $(seq 1 40) >"$TTY"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY="$TTY" "$REPO/install.sh" 2>&1)"
ajq "$D/settings.json" '.theme == "dark"'              "theme overwritten when accepted"
ajq "$D/settings.json" '.env.ANTHROPIC_MODEL == "opus"' "env addition accepted"
rm -rf "$D" "$TTY"

# --- S6: interactive, decline every patch -> file unchanged ---
sc "S6 interactive decline-all -> keep-mine, nothing added"
D="$(seed x "$CONFLICT")"; TTY="$(mktemp)"; printf 'n\n%.0s' $(seq 1 40) >"$TTY"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY="$TTY" "$REPO/install.sh" 2>&1)"
ajq "$D/settings.json" '.theme == "light"'             "theme kept on decline"
ajq "$D/settings.json" '.env == null or (.env.ANTHROPIC_MODEL == null)' "env addition declined too"
hasbak "$D" && no "no backup when all declined" || ok "no backup when all declined"
rm -rf "$D" "$TTY"

# --- S7: interactive empty input -> defaults to decline (keep-mine) ---
sc "S7 interactive empty -> decline (default)"
D="$(seed x "$CONFLICT")"; TTY="$(mktemp)"; : >"$TTY"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY="$TTY" "$REPO/install.sh" 2>&1)"
ajq "$D/settings.json" '.theme == "light"'             "theme kept on empty input"
rm -rf "$D" "$TTY"

# --- S8: already up to date -> no backup, no write ---
sc "S8 already up to date -> no backup"
D="$(mktemp -d)"; cp "$FRAG" "$D/settings.json"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" 2>&1)"
has "$out" "up to date"                                "reported already up to date"
hasbak "$D" && no "no backup when unchanged" || ok "no backup when unchanged"
rm -rf "$D"

# --- S9: no prior settings.json -> fragment copied verbatim, no prompt ---
sc "S9 fresh install (no settings.json) -> fragment copied"
D="$(mktemp -d)"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" 2>&1)"
hasnt "$out" "OVERWRITE"                                "no overwrite warning on fresh install"
ajq "$D/settings.json" '.theme == "dark"'              "theme from fragment present"
ajq "$D/settings.json" '.hooks.PreToolUse | length == 7' "hooks from fragment present"
ajq "$D/settings.json" '.hooks.PostToolUse | map(select(.matcher == "Skill") | .hooks[].command) | index("~/.claude/skill-once/hook.sh") != null' "skill-once PostToolUse registered"
ajq "$D/settings.json" '.hooks.SubagentStop | map(.hooks[].command) | any(. == "~/.claude/agent-join/hook.sh")' "agent-join SubagentStop registered"
test -f "$D/skill-once/state.sh" && ok "fresh install copies skill-once state helper" || no "fresh install copies skill-once state helper"
grep -Fq '. "$SCRIPT_DIR/state.sh"' "$D/skill-once/hook.sh" && ok "installed hook sources sibling state helper" || no "installed hook sources sibling state helper"
grep -Fq '. "$SCRIPT_DIR/state.sh"' "$D/skill-once/compact.sh" && ok "installed compact sources sibling state helper" || no "installed compact sources sibling state helper"
ajq "$D/settings.json" '.hooks.Stop      | map(.hooks[].command) | any(. == "~/.claude/agent-join/hook.sh")' "agent-join Stop registered"
cmp -s <(jq -S . "$FRAG") <(jq -S . "$D/settings.json") && ok "settings.json == fragment" || no "settings.json == fragment"
hasbak "$D" && no "no backup on fresh install" || ok "no backup on fresh install"
rm -rf "$D"

# --- S10: a re-spelled number (0.0300 vs 0.03) is NOT an overwrite ---
# jq preserves number literals, so byte-comparing the two merges would falsely
# flag this; the semantic jq `==` check must treat it as no change.
sc "S10 re-spelled number -> not an overwrite"
D="$(seed x '{ "skillListingBudgetFraction": 0.0300 }')"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" 2>&1)"
hasnt "$out" "OVERWRITE"                                "no spurious overwrite for re-spelled number"
ajq "$D/settings.json" '.skillListingBudgetFraction == 0.03' "value semantically intact"
ajq "$D/settings.json" '.theme == "dark"'              "other recommended keys still added"
rm -rf "$D"

# --- S11: the conflict advisory goes to stderr, not stdout ---
sc "S11 advisory on stderr, not stdout"
D="$(seed x "$CONFLICT")"
CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" >"$D/out.txt" 2>"$D/err.txt" || true
grep -q "differ from yours" "$D/err.txt" && ok "advisory on stderr" || no "advisory on stderr"
grep -q "differ from yours" "$D/out.txt" && no "advisory kept off stdout" || ok "advisory kept off stdout"
rm -rf "$D"

# Hook arrays must be UNIONED (concat + dedup by command), never replaced — jq's
# `*` replaces arrays wholesale, which would silently drop a user's own hooks.
CUSTOMHOOK='{ "theme": "light", "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/my/custom.sh" } ] } ] } }'

# --- S12: keep-mine path preserves user hooks AND adds recommended ones ---
sc "S12 keep-mine -> user hooks preserved + recommended added"
D="$(seed x "$CUSTOMHOOK")"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" 2>&1)"
ajq "$D/settings.json" '.theme == "light"'             "theme kept (keep-mine)"
ajq "$D/settings.json" '[.hooks.PreToolUse[].hooks[].command] | index("~/my/custom.sh") != null' "user's own hook preserved"
ajq "$D/settings.json" '[.hooks.PreToolUse[].hooks[].command] | index("~/.claude/read-once/hook.sh") != null' "recommended hook added alongside"
ajq "$D/settings.json" '.hooks.PreToolUse | length == 8'  "union = 7 recommended + 1 user"
rm -rf "$D"

# --- S13: overwrite path still preserves user hooks (hooks union regardless) ---
sc "S13 overwrite -> user hooks STILL preserved"
D="$(seed x "$CUSTOMHOOK")"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --overwrite 2>&1)"
ajq "$D/settings.json" '.theme == "dark"'              "theme overwritten (scalar conflict)"
ajq "$D/settings.json" '[.hooks.PreToolUse[].hooks[].command] | index("~/my/custom.sh") != null' "user hook NOT clobbered by --overwrite"
ajq "$D/settings.json" '.hooks.PreToolUse | length == 8'  "union preserved under overwrite"
rm -rf "$D"

# --- S14: dedup by command -> an already-present recommended hook isn't duplicated ---
sc "S14 dedup -> no duplicate, no false conflict warning"
DUPHOOK='{ "hooks": { "PreToolUse": [ { "matcher": "Read", "hooks": [ { "type": "command", "command": "~/.claude/read-once/hook.sh" } ] } ] } }'
D="$(seed x "$DUPHOOK")"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" 2>&1)"
hasnt "$out" "OVERWRITE"                                "hook-only diff is not an overwrite conflict"
ajq "$D/settings.json" '[.hooks.PreToolUse[].hooks[].command] | map(select(. == "~/.claude/read-once/hook.sh")) | length == 1' "read-once hook not duplicated"
ajq "$D/settings.json" '.hooks.PreToolUse | length == 7'  "no net new entries (already had it)"
rm -rf "$D"

# --- S15: a user hook on an event the fragment also defines -> union, no prompt ---
sc "S15 extra hook on shared event -> union, no overwrite prompt"
EXTRAHOOK='{ "hooks": { "Stop": [ { "matcher": "", "hooks": [ { "type": "command", "command": "~/my/stop.sh" } ] } ] } }'
D="$(seed x "$EXTRAHOOK")"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" 2>&1)"
hasnt "$out" "OVERWRITE"                                "adding to a shared event is not a conflict"
ajq "$D/settings.json" '[.hooks.Stop[].hooks[].command] | index("~/my/stop.sh") != null' "user Stop hook preserved"
# user stop.sh + recommended agent-state, agent-join, agent-notify
ajq "$D/settings.json" '.hooks.Stop | length == 4'      "recommended Stop hooks added too"
rm -rf "$D"

# --- S16: tilde vs expanded $HOME are the SAME hook -> dedup, not re-add ---
# Fragment ships "~/.claude/hooks/agent-state.sh"; Claude Code expands ~ at runtime,
# so a user file holding the expanded form must dedup against it, not duplicate.
sc "S16 expanded-\$HOME hook dedups against fragment tilde form"
TILDEHOOK="{ \"hooks\": { \"Stop\": [ { \"matcher\": \"\", \"hooks\": [ { \"type\": \"command\", \"command\": \"$HOME/.claude/hooks/agent-state.sh\" } ] } ] } }"
D="$(seed x "$TILDEHOOK")"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" 2>&1)"
ajq "$D/settings.json" '[.hooks.Stop[].hooks[].command] | map(select(test("agent-state"))) | length == 1' "agent-state not duplicated across tilde/expanded forms"
# agent-state (deduped) + agent-join + agent-notify
ajq "$D/settings.json" '.hooks.Stop | length == 3'     "agent-state deduped, agent-join added"
rm -rf "$D"

# --- S17: partial accept across two conflicts (deterministic order) ---
# Seed = the fragment with two values changed, so the ONLY patches are two
# conflicts: env.ANTHROPIC_MODEL (sorts first) then theme. Decline the first,
# accept the second.
sc "S17 partial accept -> per-conflict control"
D="$(mktemp -d)"; jq '.theme="light" | .env.ANTHROPIC_MODEL="haiku"' "$FRAG" > "$D/settings.json"
TTY="$(mktemp)"; rm "$TTY"; mkfifo "$TTY"
(printf 'n\ny\n'; sleep 10) >"$TTY" &
_s17_wp=$!
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY="$TTY" "$REPO/install.sh" 2>&1)"
kill $_s17_wp 2>/dev/null; wait $_s17_wp 2>/dev/null
ajq "$D/settings.json" '.env.ANTHROPIC_MODEL == "haiku"' "declined conflict kept yours"
ajq "$D/settings.json" '.theme == "dark"'                "accepted conflict took recommended"
has "$out" "applied 1 (1 conflict, 0 new, 0 hook), declined 1" "summary line accurate"
rm -rf "$D" "$TTY"

# --- S18: array conflict is atomic (single y/n governs whole array) ---
sc "S18 array conflict atomic"
D="$(mktemp -d)"; jq '.availableModels=["mine"]' "$FRAG" > "$D/settings.json"
TTY="$(mktemp)"; printf 'n\n' >"$TTY"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY="$TTY" "$REPO/install.sh" 2>&1)"
ajq "$D/settings.json" '.availableModels == ["mine"]' "whole array kept on decline (atomic)"
TTY2="$(mktemp)"; printf 'y\n' >"$TTY2"
D2="$(mktemp -d)"; jq '.availableModels=["mine"]' "$FRAG" > "$D2/settings.json"
CLAUDE_CONFIG_DIR="$D2" CLAUDE_CONFIG_TTY="$TTY2" "$REPO/install.sh" >/dev/null 2>&1
ajq "$D2/settings.json" '.availableModels == ["opus","sonnet","haiku"]' "whole array replaced on accept (atomic)"
rm -rf "$D" "$D2" "$TTY" "$TTY2"

# --- S19: hook patch accepted/declined per entry ---
# Seed = fragment minus the Stop hook, so the only patch is one hook addition.
sc "S19 hook patch per-entry"
D="$(mktemp -d)"; jq 'del(.hooks.Stop)' "$FRAG" > "$D/settings.json"
TTY="$(mktemp)"; printf 'n\n' >"$TTY"
CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY="$TTY" "$REPO/install.sh" >/dev/null 2>&1
ajq "$D/settings.json" '(.hooks.Stop // []) | length == 0' "declined hook NOT added"
D2="$(mktemp -d)"; jq 'del(.hooks.Stop)' "$FRAG" > "$D2/settings.json"
TTY2="$(mktemp)"; printf 'y\n' >"$TTY2"
CLAUDE_CONFIG_DIR="$D2" CLAUDE_CONFIG_TTY="$TTY2" "$REPO/install.sh" >/dev/null 2>&1
ajq "$D2/settings.json" '[.hooks.Stop[].hooks[].command] | any(test("agent-state"))' "accepted hook added"
rm -rf "$D" "$D2" "$TTY" "$TTY2"

# --- S20: no-TTY -> additive applied, conflict declined ---
sc "S20 no-TTY additive-only"
D="$(mktemp -d)"; jq '.theme="light" | del(.hooks.Stop)' "$FRAG" > "$D/settings.json"
CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" >/dev/null 2>&1
ajq "$D/settings.json" '.theme == "light"'              "conflict declined w/o TTY"
ajq "$D/settings.json" '[.hooks.Stop[].hooks[].command] | any(test("agent-state"))' "additive hook applied w/o TTY"
rm -rf "$D"

# --- S21: all declined interactively -> file byte-identical, no backup ---
sc "S21 all-declined -> no write"
D="$(seed x "$CONFLICT")"; before="$(cat "$D/settings.json")"
TTY="$(mktemp)"; printf 'n\n%.0s' $(seq 1 40) >"$TTY"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY="$TTY" "$REPO/install.sh" 2>&1)"
[ "$(cat "$D/settings.json")" = "$before" ] && ok "file byte-identical when all declined" || no "file byte-identical when all declined"
hasbak "$D" && no "no backup when nothing applied" || ok "no backup when nothing applied"
has "$out" "unchanged — no write"                       "reported unchanged"
rm -rf "$D" "$TTY"

# --- S22: force accepts every patch (summary shows zero declined) ---
sc "S22 force accept-all summary"
D="$(seed x "$CONFLICT")"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --overwrite 2>&1)"
ajq "$D/settings.json" '.theme == "dark"'              "conflict taken under --overwrite"
has "$out" "declined 0"                                 "force declined nothing"
hasnt "$out" "differ from yours"                       "force mode omits conflict advisory"
rm -rf "$D"

# --- S23: no-argument and --target claude create identical Claude artifacts ---
sc "S23 no-arg == --target claude (identical artifacts)"
D1="$(mktemp -d)"; D2="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$D1" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" >/dev/null 2>&1
CLAUDE_CONFIG_DIR="$D2" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --target claude >/dev/null 2>&1
diff -r "$D1" "$D2" >/dev/null 2>&1 && ok "no-arg and --target claude identical" || no "no-arg and --target claude identical"
rm -rf "$D1" "$D2"

# --- S23b: --target claude is the documented default (no-arg path unchanged) ---
sc "S23b --target claude installs settings.json"
D="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --target claude >/dev/null 2>&1
[ -f "$D/settings.json" ] && ok "--target claude installed settings.json" || no "--target claude installed settings.json"
rm -rf "$D"

# --- S24: unknown target value -> exit 2 with usage ---
sc "S24 unknown target -> exit 2 + usage"
D="$(mktemp -d)"
out="$(CLAUDE_CONFIG_DIR="$D" "$REPO/install.sh" --target bogus 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "exit 2 on unknown target (rc=$rc)" || no "exit 2 on unknown target (rc=$rc)"
has "$out" "usage"                              "printed usage on unknown target"
has "$out" "target"                             "error mentions target"
rm -rf "$D"

# --- S25: missing --target value -> exit 2 with usage ---
sc "S25 missing --target value -> exit 2 + usage"
D="$(mktemp -d)"
out="$(CLAUDE_CONFIG_DIR="$D" "$REPO/install.sh" --target 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "exit 2 on missing --target value (rc=$rc)" || no "exit 2 on missing --target value (rc=$rc)"
has "$out" "usage"                              "printed usage on missing target value"
rm -rf "$D"

sc "S26 skill success hook fresh + legacy upgrade"
D="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" >/dev/null 2>&1
ajq "$D/settings.json" '[.hooks.PreToolUse[].hooks[].command] | map(select(.=="~/.claude/skill-once/hook.sh")) | length==1' "fresh pre hook exactly once"
ajq "$D/settings.json" '[.hooks.PostToolUse[].hooks[].command] | map(select(.=="~/.claude/skill-once/hook.sh")) | length==1' "fresh post hook exactly once"
rm -rf "$D"
D="$(mktemp -d)"; jq 'del(.hooks.PostToolUse[] | select(.matcher=="Skill"))' "$FRAG" > "$D/settings.json"
CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" >/dev/null 2>&1
ajq "$D/settings.json" '[.hooks.PostToolUse[].hooks[].command] | map(select(.=="~/.claude/skill-once/hook.sh")) | length==1' "legacy upgrade adds post hook"
rm -rf "$D"

sc "S27 skill post hook dedup + unrelated custom preservation"
D="$(mktemp -d)"; jq --arg cmd "$HOME/.claude/skill-once/hook.sh" '(.hooks.PostToolUse[] | select(.matcher=="Skill").hooks[0].command)=$cmd | .hooks.PostToolUse += [{matcher:"Custom",hooks:[{type:"command",command:"~/my/post.sh"}]}]' "$FRAG" > "$D/settings.json"
CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" >/dev/null 2>&1
ajq "$D/settings.json" '[.hooks.PostToolUse[].hooks[].command | select(test("skill-once/hook.sh$"))] | length==1' "expanded post command not duplicated"
ajq "$D/settings.json" '[.hooks.PostToolUse[].hooks[].command] | index("~/my/post.sh") != null' "unrelated post hook preserved"
rm -rf "$D"

# --- N1: --notify-hook-only fresh install -> exactly the notify stack ---
sc "N1 notify-only fresh -> exactly the notify stack, hooks-only settings"
D="$(mktemp -d)"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --notify-hook-only 2>&1)"
[ -f "$D/hooks/agent-notify.sh" ] && [ -x "$D/hooks/agent-notify.sh" ] && ok "notify hook installed executable" || no "notify hook installed executable"
cmp -s "$REPO/home/hooks/agent-notify.sh" "$D/hooks/agent-notify.sh" && ok "notify hook matches source" || no "notify hook matches source"
cmp -s "$REPO/home/lib/notify-mac.sh" "$D/lib/notify-mac.sh" && ok "mac lane lib installed (credential-free default-on lane)" || no "mac lane lib installed"
ajq "$D/settings.json" '([.hooks | to_entries[] | .value[].hooks[].command] | map(select(test("/hooks/agent-notify\\.sh"))) | length) == 3' "exactly 3 agent-notify hook commands"
ajq "$D/settings.json" '([.hooks | keys[]] | sort) == ["Notification","Stop","UserPromptSubmit"]' "exactly the 3 notify events"
ajq "$D/settings.json" '.hooks.Stop[0].hooks[0].async == true and .hooks.Notification[0].hooks[0].async == true and (.hooks.UserPromptSubmit[0].hooks[0].async // false | not)' "async flags match the recommendation"
ajq "$D/settings.json" '[.hooks | to_entries[] | .value[].hooks[].command] | all(test("agent-state|agent-join|read-once|skill-once|no-remote-writes") | not)' "no non-notify recommended hooks (agent-state absent)"
ajq "$D/settings.json" 'keys == ["hooks"]' "settings.json is hooks-only (no env/theme/statusline keys)"
for f in statusline.sh CLAUDE.md skills agent-join bash-guard read-once hooks/agent-state.sh lib/notify-send.sh lib/notify-identity.sh; do
  [ ! -e "$D/$f" ] && ok "omitted: $f" || no "omitted: $f"
done
rm -rf "$D"

# --- N2: lib drift — every lib the installed hook sources must be installed ---
sc "N2 notify-only lib drift check"
D="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --notify-hook-only >/dev/null 2>&1
drift=0
while IFS= read -r lib; do
  [ -f "$D/lib/$lib" ] || { drift=1; echo "  missing lib: $lib" >&2; }
done < <(grep -oE '\$_LIB_DIR/[A-Za-z0-9._-]+\.sh' "$D/hooks/agent-notify.sh" | sed 's/^.*_LIB_DIR\///' | sort -u)
[ "$drift" = 0 ] && ok "every sourced lib is installed" || no "every sourced lib is installed"
rm -rf "$D"

# --- N3: --notify-hook-only without jq -> clear fatal error, nothing written ---
sc "N3 notify-only without jq -> fatal, nothing written"
D="$(mktemp -d)"; NOJQ="$(mktemp -d)"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz PATH="$NOJQ" /bin/bash "$REPO/install.sh" --notify-hook-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "non-zero exit without jq (rc=$rc)" || no "non-zero exit without jq (rc=$rc)"
has "$out" "--notify-hook-only requires jq" "clear jq requirement error"
[ ! -e "$D/settings.json" ] && ok "no settings.json written" || no "no settings.json written"
hasnt "$out" "skipping settings merge" "never the silent skip path"
rm -rf "$D" "$NOJQ"

# --- N4: idempotent re-run -> unchanged, no .bak ---
sc "N4 notify-only idempotent re-run"
D="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --notify-hook-only >/dev/null 2>&1
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --notify-hook-only 2>&1)"
has "$out" "unchanged" "second run reports unchanged"
ls "$D"/*.bak-* >/dev/null 2>&1 && no "no .bak on idempotent re-run" || ok "no .bak on idempotent re-run"
rm -rf "$D"

# --- N5: notify-only over a full install -> no-op ---
sc "N5 notify-only over full install -> no-op"
D="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --overwrite >/dev/null 2>&1
before="$(cat "$D/settings.json")"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --notify-hook-only 2>&1)"
[ "$(cat "$D/settings.json")" = "$before" ] && ok "settings.json byte-identical" || no "settings.json byte-identical"
has "$out" "up to date" "reported up to date"
rm -rf "$D"

# --- N6: full install after notify-only -> adds the remainder ---
sc "N6 full install after notify-only -> adds the remainder"
D="$(mktemp -d)"
CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --notify-hook-only >/dev/null 2>&1
CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --overwrite >/dev/null 2>&1
ajq "$D/settings.json" '.theme == "dark"' "theme added by full install"
ajq "$D/settings.json" '[.hooks.PreToolUse[].hooks[].command] | any(test("agent-state"))' "non-notify hooks added"
[ -f "$D/statusline.sh" ] && ok "statusline script added" || no "statusline script added"
ajq "$D/settings.json" '([.hooks | to_entries[] | .value[].hooks[].command] | map(select(test("/hooks/agent-notify\\.sh"))) | length) == 3' "notify entries still exactly 3 (no dup)"
rm -rf "$D"

# --- N7: notify-only selector is fail-closed on a source rename ---
sc "N7 notify-only selector fail-closed on source rename"
S="$(mktemp -d)"
cp "$REPO/install.sh" "$S/install.sh"
cp -R "$REPO/home" "$S/home"
sed -i.bak 's/agent-notify\.sh/agent-notify-renamed.sh/g' "$S/home/settings.recommended.json"
D="$(mktemp -d)"
out="$(CLAUDE_CONFIG_DIR="$D" CLAUDE_CONFIG_TTY=/nonexistent-xyz bash "$S/install.sh" --notify-hook-only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "renamed source fails loudly (rc=$rc)" || no "renamed source fails loudly (rc=$rc)"
has "$out" "selector" "diagnostic names the selector failure"
[ ! -e "$D/settings.json" ] && ok "no settings.json on selector failure" || no "no settings.json on selector failure"
[ ! -e "$D/hooks" ] && [ ! -e "$D/lib" ] && ok "no partial install on selector failure (no hook or lib copies)" || no "no partial install on selector failure"
ls "$D"/*.bak-* >/dev/null 2>&1 && no "no backups on selector failure" || ok "no backups on selector failure"
rm -rf "$S" "$D"

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
