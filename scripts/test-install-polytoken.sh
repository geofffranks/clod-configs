#!/usr/bin/env bash
# Scenario harness for the Polytoken install target (install.sh --target polytoken,
# backed by scripts/install-polytoken.sh). No `set -e`: assertions keep running.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_PT="$REPO/scripts/install-polytoken.sh"

LIVE_CFG="${POLYTOKEN_USER_CONFIG_DIR:-$HOME/.config/polytoken}"
if [ ! -f "$LIVE_CFG/config.yaml" ]; then
  echo "FAIL: no live polytoken config at $LIVE_CFG/config.yaml to seed a valid base" >&2
  exit 1
fi

pass=0 fail=0
ok() { echo "  ok: $1"; pass=$((pass + 1)); }
no() { echo "  FAIL: $1"; fail=$((fail + 1)); }
has() { case "$1" in *"$2"*) ok "$3" ;; *) no "$3" ;; esac; }
hasnt() { case "$1" in *"$2"*) no "$3" ;; *) ok "$3" ;; esac; }
ajq() { if jq -e "$2" "$1" >/dev/null 2>&1; then ok "$3"; else no "$3"; fi; }
ayq() { if yq -e "$2" "$1" >/dev/null 2>&1; then ok "$3"; else no "$3"; fi; }
sc() { echo; echo "=== $1 ==="; }
# valid base config dir: live config so providers/models resolve for `config validate`.
valid_base() { local d; d="$(mktemp -d)"; cp "$LIVE_CFG/config.yaml" "$d/config.yaml"; printf '%s' "$d"; }
# run_pt DIR TTY FORCE — invoke the isolated polytoken installer.
run_pt() { POLYTOKEN_CONFIG_DIR="$1" POLYTOKEN_CONFIG_TTY="$2" bash "$INSTALL_PT" "$3" 2>&1; }
pt_valid() { polytoken --config-dir "$1" config validate --user >/dev/null 2>&1; }
hasbakp() { ls "$1"/permissions.yaml.bak-* >/dev/null 2>&1; }
hasbakc() { ls "$1"/config.yaml.bak-* >/dev/null 2>&1; }
hasbakh() { ls "$1"/hooks.json.bak-* >/dev/null 2>&1; }

# --- P1: fresh target creates the expected file set, omits Claude-only artifacts ---
sc "P1 fresh target -> expected files, no Claude-only artifacts"
D="$(mktemp -d)"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
for f in config.yaml permissions.yaml hooks.json AGENTS.md hooks/adapter.sh; do
  [ -f "$D/$f" ] && ok "installed: $f" || no "installed: $f"
done
for f in compat/bash-guard/hook.sh compat/branch-guard/hook.sh compat/git-safe/hook.sh \
         compat/read-once/hook.sh compat/read-once/compact.sh compat/read-once/read-once \
         compat/skill-once/hook.sh compat/skill-once/compact.sh \
         compat/hooks/no-remote-writes.sh; do
  [ -f "$D/$f" ] && ok "installed: $f" || no "installed: $f"
done
ls "$D"/skills/*/SKILL.md >/dev/null 2>&1 && ok "skills installed" || no "skills installed"
[ -x "$D/hooks/adapter.sh" ] && ok "adapter executable" || no "adapter executable"
for x in compat/bash-guard/hook.sh compat/read-once/hook.sh compat/hooks/no-remote-writes.sh; do
  [ -x "$D/$x" ] && ok "executable: $x" || no "executable: $x"
done
for f in statusline.sh hooks/agent-state.sh agent-join agent-join/hook.sh; do
  [ ! -e "$D/$f" ] && ok "omitted: $f" || no "omitted: $f"
done
if [ -f "$D/hooks.json" ]; then
  hasnt "$(cat "$D/hooks.json")" '__POLYTOKEN_CONFIG_DIR__' "literal token rendered out of hooks.json"
else
  no "literal token rendered out of hooks.json (hooks.json missing)"
fi
grep -q "$D/hooks/adapter.sh" "$D/hooks.json" 2>/dev/null && ok "hooks reference absolute adapter path" || no "hooks reference absolute adapter path"
rm -rf "$D"

# --- P2: config no-TTY -> additive applied, tui.theme conflict preserved ---
sc "P2 config no-TTY -> additive applied, theme conflict preserved"
D="$(valid_base)"
yq -i '.tui.theme = "light"' "$D/config.yaml"
yq -i 'del(.tui.status-line)' "$D/config.yaml"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
ayq "$D/config.yaml" '.tui.theme == "light"'            "theme conflict preserved (light)"
ayq "$D/config.yaml" '.tui.status-line != null'         "status-line additive added"
pt_valid "$D" && ok "config validate passes" || no "config validate passes"
rm -rf "$D"

# --- P3: hooks merged by unique name, custom order preserved ---
sc "P3 hooks merge by name -> custom order preserved, no duplicates"
D="$(valid_base)"
printf '%s\n' '[ {"name":"my-custom","event":"pre_tool_use","matcher":"shell_exec","handler":{"bash":"true"}} ]' > "$D/hooks.json"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
[ "$(jq -r '.[0].name' "$D/hooks.json")" = "my-custom" ] && ok "custom hook order preserved (first)" || no "custom hook order preserved"
ajq "$D/hooks.json" 'length == 9'                       "8 recommended + 1 custom"
ajq "$D/hooks.json" '([.[].name]|length)==([.[].name]|unique|length)' "no duplicate hook names"
pt_valid "$D" && ok "config validate passes" || no "config validate passes"
rm -rf "$D"

# --- P4: same-name hook conflict declined then accepted (interactive) ---
sc "P4 same-name hook conflict -> decline preserves, accept replaces"
D="$(valid_base)"
printf '%s\n' '[ {"name":"bash-guard","event":"pre_tool_use","matcher":"shell_exec","handler":{"bash":"true"}} ]' > "$D/hooks.json"
TTY="$(mktemp)"; printf 'n\n' > "$TTY"
run_pt "$D" "$TTY" 0 >/dev/null
[ "$(jq -r '.[]|select(.name=="bash-guard")|.handler.bash' "$D/hooks.json")" = "true" ] \
  && ok "declined conflict kept user handler" || no "declined conflict kept user handler"
hasbakh "$D" && no "declined conflict wrote backup" || ok "declined conflict wrote no backup"
rm -rf "$D" "$TTY"

D="$(valid_base)"
printf '%s\n' '[ {"name":"bash-guard","event":"pre_tool_use","matcher":"shell_exec","handler":{"bash":"true"}} ]' > "$D/hooks.json"
TTY="$(mktemp)"; printf 'y\n' > "$TTY"
run_pt "$D" "$TTY" 0 >/dev/null
case "$(jq -r '.[]|select(.name=="bash-guard")|.handler.bash' "$D/hooks.json")" in
  *adapter.sh*) ok "accepted conflict took recommended handler" ;;
  *) no "accepted conflict took recommended handler" ;;
esac
hasbakh "$D" && ok "accepted conflict wrote backup" || no "accepted conflict wrote backup"
pt_valid "$D" && ok "config validate passes" || no "config validate passes"
rm -rf "$D" "$TTY"

# --- P5: existing valid permissions.yaml stays byte-identical (no rules to merge) ---
sc "P5 existing valid permissions.yaml -> byte-identical"
D="$(valid_base)"
printf 'version: 2\nallow:\n  - tool: shell_exec\n    args:\n      executable: git\n' > "$D/permissions.yaml"
before="$(cat "$D/permissions.yaml")"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
[ "$(cat "$D/permissions.yaml")" = "$before" ] && ok "permissions.yaml byte-identical" || no "permissions.yaml byte-identical"
hasbakp "$D" && no "permissions backup written" || ok "no permissions backup"
pt_valid "$D" && ok "config validate passes" || no "config validate passes"
rm -rf "$D"

# --- P6: no-TTY applies hook additions but preserves same-name conflict ---
sc "P6 no-TTY -> hook additions applied, conflict preserved"
D="$(valid_base)"
printf '%s\n' '[ {"name":"bash-guard","event":"pre_tool_use","matcher":"shell_exec","handler":{"bash":"true"}} ]' > "$D/hooks.json"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
[ "$(jq -r '.[]|select(.name=="bash-guard")|.handler.bash' "$D/hooks.json")" = "true" ] \
  && ok "no-TTY preserved conflict handler" || no "no-TTY preserved conflict handler"
[ "$(jq '[.[]|select(.name!="bash-guard")]|length' "$D/hooks.json")" = "7" ] \
  && ok "no-TTY applied 7 additive hooks" || no "no-TTY applied additive hooks"
pt_valid "$D" && ok "config validate passes" || no "config validate passes"
rm -rf "$D"

# --- P7: overwrite accepts conflicts without deleting unrelated entries ---
sc "P7 overwrite -> conflicts accepted, unrelated preserved"
D="$(valid_base)"
yq -i '.tui.theme = "light"' "$D/config.yaml"
printf '%s\n' '[ {"name":"unrelated-user","event":"pre_tool_use","matcher":"shell_exec","handler":{"bash":"true"}},
  {"name":"bash-guard","event":"pre_tool_use","matcher":"shell_exec","handler":{"bash":"true"}} ]' > "$D/hooks.json"
run_pt "$D" /nonexistent-xyz 1 >/dev/null
ayq "$D/config.yaml" '.tui.theme == "dark"'             "overwrite took theme"
case "$(jq -r '.[]|select(.name=="bash-guard")|.handler.bash' "$D/hooks.json")" in
  *adapter.sh*) ok "overwrite took bash-guard handler" ;;
  *) no "overwrite took bash-guard handler" ;;
esac
ajq "$D/hooks.json" '[.[]|select(.name=="unrelated-user")]|length == 1' "unrelated hook preserved under overwrite"
pt_valid "$D" && ok "config validate passes" || no "config validate passes"
rm -rf "$D"

# --- P8: repeat install is idempotent and creates no new backup ---
sc "P8 repeat install -> no new backup, no staged files"
D="$(valid_base)"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
n1="$(find "$D" -name '*.bak-*' | wc -l | tr -d ' ')"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
n2="$(find "$D" -name '*.bak-*' | wc -l | tr -d ' ')"
[ "$n2" = "$n1" ] && ok "repeat install no new backup ($n1 -> $n2)" || no "repeat install no new backup ($n1 -> $n2)"
[ "$(find "$D" -name '*.new-*' | wc -l | tr -d ' ')" = "0" ] && ok "no staged files left" || no "staged files left"
pt_valid "$D" && ok "config validate passes" || no "config validate passes"
rm -rf "$D"

# --- P9: invalid existing JSON/YAML leaves originals untouched ---
sc "P9 invalid existing JSON/YAML -> originals untouched"
D="$(valid_base)"
printf '{ not valid json' > "$D/hooks.json"
before="$(cat "$D/hooks.json")"
rc=0; run_pt "$D" /nonexistent-xyz 0 >/dev/null || rc=$?
[ "$rc" -ne 0 ] && ok "invalid hooks.json -> nonzero exit" || no "invalid hooks.json -> nonzero exit"
[ "$(cat "$D/hooks.json")" = "$before" ] && ok "invalid hooks.json unchanged" || no "invalid hooks.json unchanged"
rm -rf "$D"

D="$(valid_base)"
printf 'version: 2\nfoo: [unclosed\n' > "$D/config.yaml"
before="$(cat "$D/config.yaml")"
rc=0; run_pt "$D" /nonexistent-xyz 0 >/dev/null || rc=$?
[ "$rc" -ne 0 ] && ok "invalid config.yaml -> nonzero exit" || no "invalid config.yaml -> nonzero exit"
[ "$(cat "$D/config.yaml")" = "$before" ] && ok "invalid config.yaml unchanged" || no "invalid config.yaml unchanged"
rm -rf "$D"

# --- P10: write failure leaves originals intact ---
sc "P10 write failure -> originals intact"
D="$(valid_base)"; yq -i '.tui.theme = "light"' "$D/config.yaml"
before="$(cat "$D/config.yaml")"
chmod -w "$D"
rc=0; run_pt "$D" /nonexistent-xyz 0 >/dev/null || rc=$?
chmod +w "$D"
[ "$rc" -ne 0 ] && ok "write failure -> nonzero exit" || no "write failure -> nonzero exit"
[ "$(cat "$D/config.yaml")" = "$before" ] && ok "config.yaml intact on write failure" || no "config.yaml intact on write failure"
rm -rf "$D"

# --- P11: --target all partial failure reports both targets, exits nonzero ---
sc "P11 --target all partial failure -> both reported, nonzero"
C="$(mktemp -d)"; blocker="$(mktemp)"
out="$(CLAUDE_CONFIG_DIR="$C" POLYTOKEN_CONFIG_DIR="$blocker" POLYTOKEN_CONFIG_TTY=/nonexistent-xyz "$REPO/install.sh" --target all 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "--target all partial failure nonzero (rc=$rc)" || no "--target all partial failure nonzero (rc=$rc)"
has "$out" "claude"                                    "reported claude target"
has "$out" "polytoken"                                 "reported polytoken target"
has "$out" "polytoken: FAILED"                         "marked polytoken target failed"
rm -rf "$C" "$blocker"

# --- P12: differing managed file shows a diff before the replace prompt ---
sc "P12 differing AGENTS.md -> diff shown before replace prompt"
D="$(valid_base)"
printf '# CUSTOM-AGENTS-MARKER-7\n' > "$D/AGENTS.md"
TTY="$(mktemp)"; printf 'n\n' > "$TTY"
out="$(run_pt "$D" "$TTY" 0)"
has "$out" "CUSTOM-AGENTS-MARKER-7"  "diff shows your current content"
has "$out" "Permission Rules"        "diff shows recommended content"
[ "$(cat "$D/AGENTS.md")" = "# CUSTOM-AGENTS-MARKER-7" ] && ok "declined diff kept your AGENTS.md" || no "declined diff kept your AGENTS.md"
rm -rf "$D" "$TTY"

# --- P13: config conflict prompt shows both yours and recommended values ---
sc "P13 config conflict -> prompt shows yours and recommended values"
D="$(valid_base)"
yq -i '.tui.theme = "light"' "$D/config.yaml"
TTY="$(mktemp)"; printf 'n\n' > "$TTY"
out="$(run_pt "$D" "$TTY" 0)"
has "$out" "light"          "conflict shows your current value (light)"
has "$out" "recommended:"   "conflict shows recommended: label + value"
ayq "$D/config.yaml" '.tui.theme == "light"'   "declined conflict kept your theme (light)"
rm -rf "$D" "$TTY"

# --- P14: hook conflict prompt shows both yours and recommended handlers ---
sc "P14 hook conflict -> prompt shows yours and recommended"
D="$(valid_base)"
yq -i '.tui.theme = "dark"' "$D/config.yaml"   # match recommended: isolate the hook as the only conflict
printf '%s\n' '[ {"name":"bash-guard","event":"pre_tool_use","matcher":"shell_exec","handler":{"bash":"echo CUSTOM-HOOK-MARKER"}} ]' > "$D/hooks.json"
TTY="$(mktemp)"; printf 'n\n' > "$TTY"
out="$(run_pt "$D" "$TTY" 0)"
has "$out" "CUSTOM-HOOK-MARKER"  "conflict shows your handler value"
has "$out" "recommended:"        "conflict shows recommended: label"
[ "$(jq -r '.[]|select(.name=="bash-guard")|.handler.bash' "$D/hooks.json")" = "echo CUSTOM-HOOK-MARKER" ] && ok "declined conflict kept your handler" || no "declined conflict kept your handler"
rm -rf "$D" "$TTY"

# --- P15: existing hooks with non-recommended events (e.g. session_start) survive merge ---
sc "P15 hooks with session_start -> merge succeeds, existing hook preserved"
D="$(valid_base)"
printf '%s\n' '[ {"name":"superpowers-session-start","event":"session_start","handler":{"bash":"echo session-start"}},
  {"name":"herdle-gatekeeper","event":"pre_tool_use","matcher":"*","handler":{"bash":"echo gatekeeper"}} ]' > "$D/hooks.json"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
ajq "$D/hooks.json" '[.[]|select(.name=="superpowers-session-start" and .event=="session_start")]|length == 1' "session_start hook preserved through merge"
ajq "$D/hooks.json" '[.[]|select(.name=="herdle-gatekeeper")]|length == 1' "pre_tool_use hook preserved through merge"
ajq "$D/hooks.json" 'length == 10'                       "2 existing + 8 recommended"
ajq "$D/hooks.json" '([.[].name]|length)==([.[].name]|unique|length)' "no duplicate hook names"
pt_valid "$D" && ok "config validate passes" || no "config validate passes"
rm -rf "$D"

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
