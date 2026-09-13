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
legacy_skill() { jq -nc --arg d '${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}' '{name:"skill-once",event:"pre_tool_use",matcher:"skill",handler:{bash:("bash \""+$d+"/hooks/adapter.sh\" skill-once/hook.sh skill")}}'; }
legacy_reset() { jq -nc --arg d '${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}' '{name:"skill-once-reset",event:"post_compaction",handler:{bash:("bash \""+$d+"/hooks/adapter.sh\" skill-once/compact.sh compact")}}'; }
seed_hooks() { jq -s '.' "$@"; }
backup_count() { find "$1" -maxdepth 1 -name 'hooks.json.bak-*' | wc -l | tr -d ' '; }
# recommended hook inventory derived from source, so counts never go stale
RECOMMENDED_HOOKS="$REPO/polytoken/hooks.json"
REC_HOOKS="$(jq 'length' "$RECOMMENDED_HOOKS")"
REC_HOOK_NAMES="$(jq -c '[.[].name]|sort' "$RECOMMENDED_HOOKS")"
# Count of "+ hook ... (new)" prompts in installer output. When nonzero in a
# same-name-conflict scenario, the single TTY input line is shared with
# alphabetically earlier/later new-hook prompts — non-deterministic per-prompt
# answers (installer patches sort by name).
new_hook_prompts() { grep -oE '\+ hook [a-z0-9-]+ \(new\) \[y/N\]:' <<<"$1" | wc -l | tr -d ' '; }
# Rendered recommended hooks for fixtures, mirroring the installer's token
# rendering (render_hooks in install-polytoken.sh) so seeded entries compare
# identical and generate no patches.
rendered_recommended() {
  jq --arg dir '${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}' \
     'walk(if type == "string" then gsub("__POLYTOKEN_CONFIG_DIR__"; $dir) else . end)' "$RECOMMENDED_HOOKS"
}
# P4 fixture: the full rendered recommended set with only git-safe divergent.
# Identical entries generate no patch, so the git-safe same-name conflict is
# the sole hook prompt and one TTY line answers exactly that decision —
# deterministically, independent of installer sort order or read consumption.
p4_seed() {
  rendered_recommended | jq -c 'map(if .name == "git-safe" then
    {name:"git-safe",event:"pre_tool_use","matcher":"shell_exec",handler:{bash:"true"}}
    else . end)' > "$1"
}

# --- P1: fresh target creates the expected file set, omits Claude-only artifacts ---
sc "P1 fresh target -> expected files, no Claude-only artifacts"
D="$(mktemp -d)"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
for f in config.yaml permissions.yaml hooks.json AGENTS.md hooks/adapter.sh; do
  [ -f "$D/$f" ] && ok "installed: $f" || no "installed: $f"
done
for f in compat/bash-guard/hook.sh compat/branch-guard/hook.sh compat/git-safe/hook.sh \
         compat/read-once/hook.sh compat/read-once/compact.sh compat/read-once/read-once \
         compat/grep-guard/hook.sh compat/large-read-guard/hook.sh compat/hooks/no-remote-writes.sh; do
  [ -f "$D/$f" ] && ok "installed: $f" || no "installed: $f"
done
ls "$D"/skills/*/SKILL.md >/dev/null 2>&1 && ok "skills installed" || no "skills installed"
expected_subagents="$(printf '%s\n' abstraction-reviewer.md agent-workflow-architect.md agent-workflow-engineer.md completeness-reviewer.md correctness-reviewer.md general-reviewer.md implementer.md maintainability-reviewer.md mobile-app-expert.md researcher.md reviewer.md software-architect.md software-engineer.md validator.md | sort)"
actual_subagents="$(find "$D/subagents" -maxdepth 1 -type f -name '*.md' -printf '%f\n' | sort)"
[ "$actual_subagents" = "$expected_subagents" ] \
  && ok "installed exactly the 14 shipped subagents" || no "installed exactly the 14 shipped subagents"
expected_facets="$(printf '%s\n' product-design.md project-manager.md workflow-designer.md workflow-project-manager.md | sort)"
actual_facets="$(find "$D/facets" -maxdepth 1 -type f -name '*.md' -printf '%f\n' 2>/dev/null | sort)"
[ "$actual_facets" = "$expected_facets" ] \
  && ok "installed exactly the 2 shipped facets" || no "installed exactly the 2 shipped facets"
for facet in product-design project-manager workflow-designer workflow-project-manager; do
  cmp -s "$REPO/polytoken/facets/$facet.md" "$D/facets/$facet.md" 2>/dev/null \
    && ok "installed facet matches source: $facet" || no "installed facet matches source: $facet"
done
[ -x "$D/hooks/adapter.sh" ] && ok "adapter executable" || no "adapter executable"
for x in compat/bash-guard/hook.sh compat/read-once/hook.sh compat/grep-guard/hook.sh compat/large-read-guard/hook.sh compat/hooks/no-remote-writes.sh; do
  [ -x "$D/$x" ] && ok "executable: $x" || no "executable: $x"
done
cmp -s "$REPO/home/large-read-guard/hook.sh" "$D/compat/large-read-guard/hook.sh" \
  && ok "installed large-read guard matches source" || no "installed large-read guard matches source"
[ "$(sha256sum "$REPO/home/large-read-guard/hook.sh" | awk '{print $1}')" = "$(sha256sum "$D/compat/large-read-guard/hook.sh" | awk '{print $1}')" ] \
  && ok "installed large-read guard checksum matches source" || no "installed large-read guard checksum matches source"
large_payload=$(jq -nc --arg p "$D/compat/large-read-guard/hook.sh" '{tool_name:"Read",tool_input:{file_path:$p,max_bytes:1}}')
large_out=$(printf '%s' "$large_payload" | POLYTOKEN_CWD="$D" bash "$D/compat/large-read-guard/hook.sh")
[ -z "$large_out" ] && ok "installed large-read guard allows bounded read" || no "installed large-read guard behavior"
large_file="$D/compat/large-read-guard/oversized.diff"; python3 - "$large_file" <<'PY'
import sys
open(sys.argv[1], 'wb').write(b'x' * 51201)
PY
large_payload=$(jq -nc --arg p "$large_file" '{tool_name:"Read",tool_input:{file_path:$p}}')
large_out=$(printf '%s' "$large_payload" | POLYTOKEN_CWD="$D" bash "$D/compat/large-read-guard/hook.sh")
jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$large_out" >/dev/null \
  && ok "installed large-read guard denies oversized unbounded read" || no "installed large-read guard denial behavior"
for f in statusline.sh hooks/agent-state.sh agent-join agent-join/hook.sh; do
  [ ! -e "$D/$f" ] && ok "omitted: $f" || no "omitted: $f"
done
if [ -f "$D/hooks.json" ]; then
  hasnt "$(cat "$D/hooks.json")" '__POLYTOKEN_CONFIG_DIR__' "literal token rendered out of hooks.json"
else
  no "literal token rendered out of hooks.json (hooks.json missing)"
fi
portable='${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}/hooks/adapter.sh'
jq -e --arg p "$portable" '[.[] | select(.handler.bash | contains("adapter.sh"))] | length>0 and all(.[]; .handler.bash|contains($p))' "$D/hooks.json" >/dev/null \
  && ok "hooks reference portable runtime adapter path" || no "hooks reference portable runtime adapter path"
rm -rf "$D"

# --- P2: config no-TTY -> additive applied, lsp-enabled conflict preserved ---
sc "P2 config no-TTY -> additive applied, lsp-enabled conflict preserved"
D="$(valid_base)"
yq -i '.daemon.lsp.enabled = false' "$D/config.yaml"
yq -i 'del(.mcp_servers.ratatoskr)' "$D/config.yaml"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
ayq "$D/config.yaml" '.daemon.lsp.enabled == false'                   "lsp-enabled conflict preserved (false)"
ayq "$D/config.yaml" '.mcp_servers.ratatoskr.transport == "http"'     "ratatoskr url/transport additive added"
pt_valid "$D" && ok "config validate passes" || no "config validate passes"
rm -rf "$D"

# --- P3: hooks merged by unique name, custom order preserved ---
sc "P3 hooks merge by name -> custom order preserved, no duplicates"
D="$(valid_base)"
printf '%s\n' '[ {"name":"my-custom","event":"pre_tool_use","matcher":"shell_exec","handler":{"bash":"true"}} ]' > "$D/hooks.json"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
[ "$(jq -r '.[0].name' "$D/hooks.json")" = "my-custom" ] && ok "custom hook order preserved (first)" || no "custom hook order preserved"
# P3: one custom plus the full recommended set from source
ajq "$D/hooks.json" "length == $REC_HOOKS + 1" "1 custom + $REC_HOOKS recommended"
ajq "$D/hooks.json" '([.[].name]|length)==([.[].name]|unique|length)' "no duplicate hook names"
pt_valid "$D" && ok "config validate passes" || no "config validate passes"
rm -rf "$D"

# --- P4: same-name hook conflict declined then accepted (interactive) ---
# p4_seed makes the git-safe conflict the only hook prompt, so each TTY file's
# single line answers exactly that decision — even though installer patches
# sort by name and container-awareness would otherwise prompt first.
sc "P4 same-name hook conflict -> decline preserves, accept replaces"
D="$(valid_base)"
p4_seed "$D/hooks.json"
TTY="$(mktemp)"; printf 'n\n' > "$TTY"
out="$(run_pt "$D" "$TTY" 0)"
[ "$(new_hook_prompts "$out")" = 0 ] \
  && ok "no new-hook prompt shares the conflict input" || no "no new-hook prompt shares the conflict input"
has "$out" "~ hook git-safe" "conflict prompt shown for git-safe"
[ "$(jq -r '.[]|select(.name=="git-safe")|.handler.bash' "$D/hooks.json")" = "true" ] \
  && ok "declined conflict kept user handler" || no "declined conflict kept user handler"
hasbakh "$D" && no "declined conflict wrote backup" || ok "declined conflict wrote no backup"
rm -rf "$D" "$TTY"

D="$(valid_base)"
p4_seed "$D/hooks.json"
TTY="$(mktemp)"; printf 'y\n' > "$TTY"
out="$(run_pt "$D" "$TTY" 0)"
[ "$(new_hook_prompts "$out")" = 0 ] \
  && ok "no new-hook prompt consumes the single accept" || no "no new-hook prompt consumes the single accept"
has "$out" "~ hook git-safe" "conflict prompt shown for git-safe (accept)"
case "$(jq -r '.[]|select(.name=="git-safe")|.handler.bash' "$D/hooks.json")" in
  *adapter.sh*) ok "accepted conflict took recommended handler" ;;
  *) no "accepted conflict took recommended handler" ;;
esac
ajq "$D/hooks.json" "length == $REC_HOOKS" "accept replaced conflict, kept full hook inventory"
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
printf '%s\n' '[ {"name":"git-safe","event":"pre_tool_use","matcher":"shell_exec","handler":{"bash":"true"}} ]' > "$D/hooks.json"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
[ "$(jq -r '.[]|select(.name=="git-safe")|.handler.bash' "$D/hooks.json")" = "true" ] \
  && ok "no-TTY preserved conflict handler" || no "no-TTY preserved conflict handler"
# P6: git-safe conflicts, leaving the rest of the recommended set as additive
[ "$(jq '[.[]|select(.name!="git-safe")]|length' "$D/hooks.json")" = "$((REC_HOOKS - 1))" ] \
  && ok "no-TTY applied $((REC_HOOKS - 1)) additive hooks" || no "no-TTY applied additive hooks"
pt_valid "$D" && ok "config validate passes" || no "config validate passes"
rm -rf "$D"

# --- P7: overwrite accepts conflicts without deleting unrelated entries ---
sc "P7 overwrite -> conflicts accepted, unrelated preserved"
D="$(valid_base)"
yq -i '.daemon.lsp.enabled = false' "$D/config.yaml"
printf '%s\n' '[ {"name":"unrelated-user","event":"pre_tool_use","matcher":"shell_exec","handler":{"bash":"true"}},
  {"name":"git-safe","event":"pre_tool_use","matcher":"shell_exec","handler":{"bash":"true"}} ]' > "$D/hooks.json"
run_pt "$D" /nonexistent-xyz 1 >/dev/null
ayq "$D/config.yaml" '.daemon.lsp.enabled == true'     "overwrite took recommended lsp-enabled"
case "$(jq -r '.[]|select(.name=="git-safe")|.handler.bash' "$D/hooks.json")" in
  *adapter.sh*) ok "overwrite took git-safe handler" ;;
  *) no "overwrite took git-safe handler" ;;
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
D="$(valid_base)"; yq -i '.mcp_servers.ratatoskr.transport = "stdio"' "$D/config.yaml"
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
yq -i '.daemon.lsp.enabled = false' "$D/config.yaml"
TTY="$(mktemp)"; printf 'n\n' > "$TTY"
out="$(run_pt "$D" "$TTY" 0)"
has "$out" "yours:       false"  "conflict shows your current value (false)"
has "$out" "recommended: true"   "conflict shows recommended: label + value"
ayq "$D/config.yaml" '.daemon.lsp.enabled == false'   "declined conflict kept your lsp setting (false)"
rm -rf "$D" "$TTY"

# --- P14: hook conflict prompt shows both yours and recommended handlers ---
sc "P14 hook conflict -> prompt shows yours and recommended"
D="$(valid_base)"
printf '%s\n' '[ {"name":"git-safe","event":"pre_tool_use","matcher":"shell_exec","handler":{"bash":"echo CUSTOM-HOOK-MARKER"}} ]' > "$D/hooks.json"
TTY="$(mktemp)"; printf 'n\n' > "$TTY"
out="$(run_pt "$D" "$TTY" 0)"
has "$out" "CUSTOM-HOOK-MARKER"  "conflict shows your handler value"
has "$out" "recommended:"        "conflict shows recommended: label"
[ "$(jq -r '.[]|select(.name=="git-safe")|.handler.bash' "$D/hooks.json")" = "echo CUSTOM-HOOK-MARKER" ] && ok "declined conflict kept your handler" || no "declined conflict kept your handler"
rm -rf "$D" "$TTY"

# --- P15: existing hooks with non-recommended events (e.g. session_start) survive merge ---
sc "P15 hooks with session_start -> merge succeeds, existing hook preserved"
D="$(valid_base)"
printf '%s\n' '[ {"name":"superpowers-session-start","event":"session_start","handler":{"bash":"echo session-start"}},
  {"name":"herdle-gatekeeper","event":"pre_tool_use","matcher":"*","handler":{"bash":"echo gatekeeper"}} ]' > "$D/hooks.json"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
ajq "$D/hooks.json" '[.[]|select(.name=="superpowers-session-start" and .event=="session_start")]|length == 1' "session_start hook preserved through merge"
ajq "$D/hooks.json" '[.[]|select(.name=="herdle-gatekeeper")]|length == 1' "pre_tool_use hook preserved through merge"
# P15: two existing plus the full recommended set from source
ajq "$D/hooks.json" "length >= $REC_HOOKS" "existing hooks merge with recommended inventory"
ajq "$D/hooks.json" '([.[].name]|length)==([.[].name]|unique|length)' "no duplicate hook names"
pt_valid "$D" && ok "config validate passes" || no "config validate passes"
rm -rf "$D"

sc "P16 fresh install omits compatibility skill scripts"
D="$(mktemp -d)"; run_pt "$D" /nonexistent-xyz 0 >/dev/null
[ ! -e "$D/compat/skill-once/hook.sh" ] && ok "fresh hook script omitted" || no "fresh hook script omitted"
[ ! -e "$D/compat/skill-once/compact.sh" ] && ok "fresh compact script omitted" || no "fresh compact script omitted"
[ "$(jq -c '[.[].name]|sort' "$D/hooks.json")" = "$REC_HOOK_NAMES" ] \
  && ok "fresh hooks match the $REC_HOOKS recommended names from source" || no "fresh hooks match the recommended names from source"
rm -rf "$D"

sc "P17 exact legacy entries removed independently with one backup"
D="$(valid_base)"; a="$(mktemp)"; b="$(mktemp)"; legacy_skill >"$a"; legacy_reset >"$b"; seed_hooks "$a" "$b" >"$D/hooks.json"
mkdir -p "$D/compat/skill-once"; printf 'custom-hook-bytes\n' >"$D/compat/skill-once/hook.sh"; printf 'custom-compact-bytes\n' >"$D/compat/skill-once/compact.sh"
h1="$(sha256sum "$D/compat/skill-once/hook.sh" "$D/compat/skill-once/compact.sh")"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
ajq "$D/hooks.json" '([.[].name]|index("skill-once")==null) and ([.[].name]|index("skill-once-reset")==null)' "both exact legacy entries removed"
[ "$(backup_count "$D")" = 1 ] && ok "accepted removals create one backup" || no "accepted removals create one backup"
[ "$(sha256sum "$D/compat/skill-once/hook.sh" "$D/compat/skill-once/compact.sh")" = "$h1" ] && ok "legacy scripts byte-identical" || no "legacy scripts byte-identical"
rm -rf "$D" "$a" "$b"

sc "P18 absent, exact, and customized targets migrate independently"
D="$(valid_base)"; a="$(mktemp)"; legacy_skill >"$a"; seed_hooks "$a" >"$D/hooks.json"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
ajq "$D/hooks.json" '[.[].name]|index("skill-once")==null and index("skill-once-reset")==null' "one exact and one absent both end absent"
rm -rf "$D" "$a"
custom_reset='{"name":"skill-once-reset","event":"post_compaction","handler":{"bash":"echo CUSTOM-RESET"}}'
D="$(valid_base)"; a="$(mktemp)"; b="$(mktemp)"; legacy_skill >"$a"; printf '%s\n' "$custom_reset" >"$b"; seed_hooks "$a" "$b" >"$D/hooks.json"; TTY="$(mktemp)"; printf 'n\n' >"$TTY"
run_pt "$D" "$TTY" 0 >/dev/null
ajq "$D/hooks.json" '[.[].name]|index("skill-once")==null and index("skill-once-reset")!=null' "exact target removed while customized target declined"
[ "$(backup_count "$D")" = 1 ] && ok "independent accepted removal creates one backup" || no "independent accepted removal creates one backup"
rm -rf "$D" "$a" "$b" "$TTY"

sc "P19 customized removal decline, overwrite, and no-TTY warning"
custom='{"name":"skill-once","event":"pre_tool_use","matcher":"skill","handler":{"bash":"echo CUSTOM-SKILL"}}'
D="$(valid_base)"; printf '[%s]\n' "$custom" >"$D/hooks.json"; before="$(cat "$D/hooks.json")"; TTY="$(mktemp)"; printf 'n\n' >"$TTY"
out="$(run_pt "$D" "$TTY" 0)"
has "$out" 'remove customized hook skill-once? [y/N]' "interactive removal prompt exact"
has "$out" 'CUSTOM-SKILL' "prompt prints full current JSON"
[ "$(cat "$D/hooks.json")" = "$before" ] && ok "decline preserves customized hook" || no "decline preserves customized hook"
[ "$(backup_count "$D")" = 0 ] && ok "decline creates no backup" || no "decline creates no backup"
rm -rf "$D" "$TTY"
D="$(valid_base)"; printf '[%s]\n' "$custom" >"$D/hooks.json"; run_pt "$D" /nonexistent-xyz 1 >/dev/null
ajq "$D/hooks.json" '[.[].name]|index("skill-once")==null' "overwrite removes customized hook"
[ "$(backup_count "$D")" = 1 ] && ok "overwrite removal creates one backup" || no "overwrite removal creates one backup"
rm -rf "$D"
D="$(valid_base)"; printf '[%s]\n' "$custom" >"$D/hooks.json"; out="$(run_pt "$D" /nonexistent-xyz 0)"
has "$out" "customized hook skill-once still enables unsafe cross-agent skill deduplication; remove it from $D/hooks.json manually or rerun with --overwrite" "no-TTY warning exact"
ajq "$D/hooks.json" '[.[].name]|index("skill-once")!=null' "no-TTY preserves customized hook"
[ "$(backup_count "$D")" = 1 ] && ok "no-TTY backup for new hooks only" || no "no-TTY backup for new hooks only"
rm -rf "$D"

sc "P20 duplicate existing names abort before patch enumeration"
D="$(valid_base)"; printf '[%s,%s]\n' "$custom" "$custom" >"$D/hooks.json"; before="$(cat "$D/hooks.json")"
out="$(run_pt "$D" /nonexistent-xyz 0)"; rc=$?
[ "$rc" -ne 0 ] && ok "duplicate names abort" || no "duplicate names abort"
has "$out" "hooks.json contains duplicate names; existing file unchanged" "duplicate diagnostic"
[ "$(cat "$D/hooks.json")" = "$before" ] && ok "duplicate file unchanged" || no "duplicate file unchanged"
hasnt "$out" "remove customized hook" "abort precedes patch enumeration"
[ "$(backup_count "$D")" = 0 ] && ok "duplicate abort creates no backup" || no "duplicate abort creates no backup"
rm -rf "$D"

sc "P21 ratatoskr gateway entry -> fresh lands, additive merge preserves"
D="$(mktemp -d)"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
ayq "$D/config.yaml" '.mcp_servers.ratatoskr.transport == "http"' "fresh install: ratatoskr transport http"
ayq "$D/config.yaml" '.mcp_servers.ratatoskr.url == "http://host.docker.internal:8910/mcp"' "fresh install: ratatoskr url"
rm -rf "$D"
D="$(valid_base)"
yq -i '.mcp_servers = {"other-server": {"transport": "stdio", "command": "true"}}' "$D/config.yaml"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
ayq "$D/config.yaml" '.mcp_servers.ratatoskr.transport == "http"' "additive merge: ratatoskr entry added"
ayq "$D/config.yaml" '.mcp_servers["other-server"].command == "true"' "additive merge: existing mcp_servers preserved"
ayq "$D/config.yaml" '.mcp_servers | length == 2' "additive merge: exactly two servers"
pt_valid "$D" && ok "config validate passes (ratatoskr entry)" || no "config validate passes (ratatoskr entry)"
rm -rf "$D"

sc "P22 installer: no MCP wrappers, ~/.local/bin PATH still ensured"
D="$(valid_base)"
FAKEHOME="$(mktemp -d)"
P22LOG="$FAKEHOME/installer-output.log"
HOME="$FAKEHOME" POLYTOKEN_CONFIG_DIR="$D" POLYTOKEN_CONFIG_TTY=/nonexistent-xyz \
  bash "$INSTALL_PT" 0 >"$P22LOG" 2>&1
for w in foundry-mcp codex-imagegen-mcp minime-vision; do
  if [ -e "$FAKEHOME/.local/bin/$w" ]; then
    no "wrapper not installed: $w"
    echo "----- installer output (P22 failure) -----" >&2
    tail -20 "$P22LOG" >&2
    echo "-----------------------------------------" >&2
  else
    ok "wrapper not installed: $w"
  fi
done
if grep -q '.local/bin' "$FAKEHOME/.bashrc" 2>/dev/null; then
  ok "~/.local/bin PATH export appended"
else
  no "~/.local/bin PATH export appended"
  echo "----- installer output (P22 failure) -----" >&2
  tail -20 "$P22LOG" >&2
  echo "-----------------------------------------" >&2
fi
rm -rf "$D" "$FAKEHOME"

# --- P23: only top-level *.md definitions install; backups/generated/nested excluded ---
sc "P23 top-level *.md only -> backups, generated files, and subdirs excluded"
# Scratch install root: real subagent/facet sources plus planted non-definition
# artifacts that a top-level-only selection must skip.
S="$(mktemp -d)"
mkdir -p "$S/scripts"
cp "$INSTALL_PT" "$S/scripts/install-polytoken.sh"
ln -s "$REPO/home" "$S/home"
cp -R "$REPO/polytoken" "$S/polytoken"
printf 'backup junk\n' > "$S/polytoken/subagents/validator.md.bak-20260101-000000"
mkdir -p "$S/polytoken/subagents/generated"
printf 'nested junk\n' > "$S/polytoken/subagents/generated/nested.md"
printf 'swp junk\n' > "$S/polytoken/facets/workflow-designer.md.swp"
mkdir -p "$S/polytoken/facets/backups"
printf 'backup junk\n' > "$S/polytoken/facets/backups/workflow-project-manager.md.bak-20260101-000000"
D="$(mktemp -d)"
POLYTOKEN_CONFIG_DIR="$D" POLYTOKEN_CONFIG_TTY=/nonexistent-xyz bash "$S/scripts/install-polytoken.sh" 0 >/dev/null
actual_subagents="$(find "$D/subagents" -maxdepth 1 -type f -name '*.md' -printf '%f\n' | sort)"
[ "$actual_subagents" = "$expected_subagents" ] \
  && ok "top-level-only: subagent inventory still exactly 14" || no "top-level-only: subagent inventory still exactly 14"
actual_facets="$(find "$D/facets" -maxdepth 1 -type f -name '*.md' -printf '%f\n' | sort)"
[ "$actual_facets" = "$expected_facets" ] \
  && ok "top-level-only: facet inventory still exactly 2" || no "top-level-only: facet inventory still exactly 2"
[ ! -e "$D/subagents/validator.md.bak-20260101-000000" ] \
  && ok "top-level-only: subagent backup not installed" || no "top-level-only: subagent backup not installed"
[ ! -e "$D/subagents/generated" ] \
  && ok "top-level-only: subagent subdirectory not installed" || no "top-level-only: subagent subdirectory not installed"
[ ! -e "$D/facets/workflow-designer.md.swp" ] \
  && ok "top-level-only: facet swapfile not installed" || no "top-level-only: facet swapfile not installed"
[ ! -e "$D/facets/backups" ] \
  && ok "top-level-only: facet backup directory not installed" || no "top-level-only: facet backup directory not installed"
rm -rf "$D" "$S"

# --- P24: definition conflict -> decline preserves, overwrite replaces with backup ---
sc "P24 definition conflict -> decline preserves, overwrite replaces with backup"
D="$(valid_base)"
custom_subagent="$D/subagents/my-custom.md"
mkdir -p "$D/subagents" "$D/facets"
printf 'user subagent definition\n' > "$custom_subagent"
printf -- '---\nname: implementer\npolytoken:\n  model: codex/gpt-5.6-luna\n---\nUSER-CUSTOM-IMPLEMENTER-MARKER\n' > "$D/subagents/implementer.md"
cp "$REPO/polytoken/facets/workflow-designer.md" "$D/facets/workflow-designer.md"
printf '\nUSER-CUSTOM-FACET-MARKER\n' >> "$D/facets/workflow-designer.md"
before_subagent="$(cat "$D/subagents/implementer.md")"
before_facet="$(cat "$D/facets/workflow-designer.md")"
TTY="$(mktemp)"; printf 'n\n' > "$TTY"
out="$(run_pt "$D" "$TTY" 0)"
[ "$(cat "$D/subagents/implementer.md")" = "$before_subagent" ] \
  && ok "declined subagent conflict kept your bytes" || no "declined subagent conflict kept your bytes"
[ "$(cat "$D/facets/workflow-designer.md")" = "$before_facet" ] \
  && ok "declined facet conflict kept your bytes" || no "declined facet conflict kept your bytes"
[ ! -e "$custom_subagent" ] && no "unrelated destination subagent preserved" || ok "unrelated destination subagent preserved"
ls "$D"/subagents/implementer.md.bak-* >/dev/null 2>&1 \
  && no "declined subagent conflict wrote no backup" || ok "declined subagent conflict wrote no backup"
rm -rf "$D" "$TTY"

D="$(valid_base)"
custom_subagent="$D/subagents/my-custom.md"
mkdir -p "$D/subagents" "$D/facets"
printf 'user subagent definition\n' > "$custom_subagent"
printf -- '---\nname: implementer\npolytoken:\n  model: codex/gpt-5.6-luna\n---\nUSER-CUSTOM-IMPLEMENTER-MARKER\n' > "$D/subagents/implementer.md"
cp "$REPO/polytoken/facets/workflow-designer.md" "$D/facets/workflow-designer.md"
printf '\nUSER-CUSTOM-FACET-MARKER\n' >> "$D/facets/workflow-designer.md"
out="$(run_pt "$D" /nonexistent-xyz 1)"
cmp -s "$REPO/polytoken/subagents/implementer.md" "$D/subagents/implementer.md" \
  && ok "overwrite took recommended subagent bytes" || no "overwrite took recommended subagent bytes"
ls "$D"/subagents/implementer.md.bak-* >/dev/null 2>&1 \
  && ok "overwrite subagent conflict wrote backup" || no "overwrite subagent conflict wrote backup"
cmp -s "$REPO/polytoken/facets/workflow-designer.md" "$D/facets/workflow-designer.md" \
  && ok "overwrite took recommended facet bytes" || no "overwrite took recommended facet bytes"
ls "$D"/facets/workflow-designer.md.bak-* >/dev/null 2>&1 \
  && ok "overwrite facet conflict wrote backup" || no "overwrite facet conflict wrote backup"
[ "$(cat "$custom_subagent")" = "user subagent definition" ] \
  && ok "unrelated destination subagent preserved under overwrite" || no "unrelated destination subagent preserved under overwrite"
# Unrelated destination facet (not in the managed source set) also survives overwrite.
printf 'unrelated facet\n' > "$D/facets/my-own-facet.md"
run_pt "$D" /nonexistent-xyz 1 >/dev/null
[ -f "$D/facets/my-own-facet.md" ] \
  && ok "unrelated destination facet preserved under overwrite" || no "unrelated destination facet preserved under overwrite"
rm -rf "$D"

# --- P25: upgrade preserves stale renamed facet until explicit retirement ---
sc "P25 upgrade -> stale workflow-delivery preserved, then explicitly retired"
D="$(valid_base)"
mkdir -p "$D/facets"
printf '%s\n' 'old workflow-delivery definition retained during upgrade' > "$D/facets/workflow-delivery.md"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
[ -f "$D/facets/workflow-delivery.md" ] \
  && ok "upgrade preserves unmanaged workflow-delivery facet" || no "upgrade preserves unmanaged workflow-delivery facet"
[ -f "$D/facets/workflow-project-manager.md" ] \
  && ok "upgrade installs workflow-project-manager facet" || no "upgrade installs workflow-project-manager facet"
retire_backup="$(mktemp -d)/workflow-delivery.md.retired"
cp "$D/facets/workflow-delivery.md" "$retire_backup"
rm "$D/facets/workflow-delivery.md"
[ -f "$retire_backup" ] && ok "retirement backs up stale facet outside discovery directory" || no "retirement backs up stale facet outside discovery directory"
[ ! -e "$D/facets/workflow-delivery.md" ] && ok "retirement deletes exact stale facet" || no "retirement deletes exact stale facet"
[ "$(find "$D/facets" -maxdepth 1 -type f \( -name 'workflow-project-manager.md' -o -name 'workflow-delivery.md' \) -printf '%f\n' | sort)" = "workflow-project-manager.md" ] \
  && ok "retirement leaves only workflow-project-manager among delivery pair" || no "retirement leaves only workflow-project-manager among delivery pair"
rm -rf "$D" "$(dirname "$retire_backup")"

# --- P26: second-run definition idempotence -> no new backup, unchanged lines ---
sc "P25 definition idempotence -> second run no new backup, unchanged"
D="$(valid_base)"
run_pt "$D" /nonexistent-xyz 0 >/dev/null
n1="$(find "$D/subagents" "$D/facets" -name '*.bak-*' | wc -l | tr -d ' ')"
out="$(run_pt "$D" /nonexistent-xyz 0)"
n2="$(find "$D/subagents" "$D/facets" -name '*.bak-*' | wc -l | tr -d ' ')"
[ "$n2" = "$n1" ] && ok "definition repeat run no new backup ($n1 -> $n2)" || no "definition repeat run no new backup ($n1 -> $n2)"
has "$out" "unchanged: subagents/implementer.md" "second run reports subagent unchanged"
has "$out" "unchanged: facets/workflow-designer.md" "second run reports first facet unchanged"
has "$out" "unchanged: facets/workflow-project-manager.md" "second run reports workflow-project-manager unchanged"
rm -rf "$D"

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
