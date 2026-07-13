# Polytoken Installation Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a backward-compatible `--target polytoken` installation mode that installs native Polytoken configuration, permissions, hooks, instructions, and canonical shared skills while reusing the existing hook implementations through a protocol adapter.

**Architecture:** Keep `home/` as the canonical Claude source tree and add explicit native artifacts under `polytoken/`. Stateful hook scripts gain only a neutral `AGENT_CONFIG_DIR` root; `polytoken/hooks/adapter.sh` translates Polytoken events into the existing Claude-shaped hook contract and translates decisions back. `install.sh` dispatches to isolated Claude and Polytoken installers and performs file-specific, validated, atomic merges.

**Tech Stack:** Bash 4+, jq, yq v4, Python 3 standard library (test helpers only), Polytoken CLI 0.5-compatible schemas/validators, YAML/JSON configuration, shellcheck.

## Global Constraints

- `./install.sh` with no target must preserve current Claude behavior.
- Supported targets are exactly `claude`, `polytoken`, and `all`; there is no model profile or `--profile` flag.
- Polytoken installs to `${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}` and must not depend on `~/.claude`.
- Do not pin or change Polytoken model definitions or `defaults.full`, `defaults.mini`, or `defaults.nano`.
- Do not map the 50% Claude compaction setting: Polytoken 0.5 exposes compaction thresholds per model only.
- `home/skills/` remains the one canonical skills tree.
- The four guards, `read-once`, `skill-once`, and both compaction reset hooks must execute canonical scripts rather than duplicated policy logic.
- Do not register `statusline.sh`, `agent-state`, or `agent-join` for Polytoken.
- Preserve unrelated user entries in normal, no-TTY, and overwrite modes.
- Validate structured files before atomic replacement; create backups only when final content changes.
- Polytoken hook tests must use fixtures captured from the installed runtime/schema, not an inferred payload.

## File map

- Create `polytoken/config.recommended.yaml`: provider-neutral TUI configuration only.
- Create `polytoken/permissions.recommended.yaml`: minimal valid version-2 permission document.
- Create `polytoken/hooks.json`: named native hook registrations with inline adapter invocations.
- Create `polytoken/AGENTS.md`: Polytoken-native global instructions.
- Create `polytoken/hooks/adapter.sh`: protocol-only event and decision translator.
- Create `scripts/fixtures/polytoken-hooks/*.json`: verified hook payload fixtures and provenance notes.
- Create `scripts/test-polytoken-hooks.sh`: adapter and canonical-state contract tests.
- Create `scripts/test-install-polytoken.sh`: Polytoken artifact and merge scenarios.
- Create `scripts/install-polytoken.sh`: isolated Polytoken copy/merge implementation.
- Modify `install.sh`: argument parsing and target dispatch while retaining Claude behavior.
- Modify `home/read-once/hook.sh`, `home/read-once/compact.sh`, `home/skill-once/hook.sh`, `home/skill-once/compact.sh`: use `AGENT_CONFIG_DIR` for state.
- Modify `home/skills/{agent-session-retro,git-workflow,agent-orchestration}/SKILL.md`: accurate dual-harness terminology.
- Modify `README.md`: target commands, scope, dependencies, merge behavior, and omissions.

---

### Task 1: Capture and lock the Polytoken runtime contracts

**Files:**
- Create: `scripts/fixtures/polytoken-hooks/README.md`
- Create: `scripts/fixtures/polytoken-hooks/pre-tool-shell-exec.json`
- Create: `scripts/fixtures/polytoken-hooks/pre-tool-file-read.json`
- Create: `scripts/fixtures/polytoken-hooks/pre-tool-skill.json`
- Create: `scripts/fixtures/polytoken-hooks/post-compaction.json`
- Create: `scripts/test-polytoken-contracts.sh`

**Interfaces:**
- Consumes: installed `polytoken`, `polytoken schemas app-config`, `polytoken print-tools`, and a temporary config directory.
- Produces: immutable JSON fixtures with top-level `event`, `matcher_subject`, and event fields exactly as observed; validation commands reused by later tasks.

- [ ] **Step 1: Write the failing contract test**

Create `scripts/test-polytoken-contracts.sh` with assertions that all four fixtures parse, contain the expected event/tool names, and match the documented `.input` shape:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/scripts/fixtures/polytoken-hooks"
for f in pre-tool-shell-exec pre-tool-file-read pre-tool-skill post-compaction; do
  jq -e . "$FIX/$f.json" >/dev/null
done
jq -e '.event == "pre_tool_use" and .tool_name == "shell_exec" and (.input.command | type == "string")' "$FIX/pre-tool-shell-exec.json" >/dev/null
jq -e '.event == "pre_tool_use" and .tool_name == "file_read" and (.input.path | type == "string")' "$FIX/pre-tool-file-read.json" >/dev/null
jq -e '.event == "pre_tool_use" and .tool_name == "skill" and (.input.name | type == "string")' "$FIX/pre-tool-skill.json" >/dev/null
jq -e '.event == "post_compaction"' "$FIX/post-compaction.json" >/dev/null
printf 'polytoken contract fixtures: PASS\n'
```

- [ ] **Step 2: Run the contract test to verify it fails**

Run: `bash scripts/test-polytoken-contracts.sh`

Expected: nonzero because the fixture files do not exist.

- [ ] **Step 3: Capture actual payloads with a temporary logging hook**

Create a temporary config directory containing the current valid user `config.yaml` plus a `hooks.json` whose handlers append stdin to files, then run an isolated Polytoken session and invoke `shell_exec`, `file_read`, and `skill`; trigger compaction through the TUI or an isolated test session. Use inline handlers of this form:

```json
{
  "name": "capture-shell",
  "event": "pre_tool_use",
  "matcher": "shell_exec",
  "handler": {"bash": "tee /tmp/polytoken-pre-tool-shell.json >/dev/null; echo '{\"outcome\":\"allow\"}'"}
}
```

Copy the observed objects into the four fixtures without adding fields. In `README.md`, record:

```markdown
Captured with `polytoken --version`; paste the exact output from the capture run here.
Validated on: 2026-07-12
Commands: `polytoken --config-dir "$CAPTURE_DIR" config validate --user` and the isolated capture session.
The docs confirm handler input under `.input`; these files preserve the complete observed envelopes.
```

If a real event cannot be triggered non-interactively, inspect the installed source/schema or daemon event logs and record that exact provenance instead; do not invent missing fields.

- [ ] **Step 4: Run the contract test and CLI schema checks**

Run:

```bash
bash scripts/test-polytoken-contracts.sh
polytoken schemas app-config --output json >/dev/null
polytoken schemas permissions-config --output json >/dev/null
```

Expected: `polytoken contract fixtures: PASS`; both schema commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/fixtures/polytoken-hooks scripts/test-polytoken-contracts.sh
git commit -m "test: capture Polytoken hook contracts"
```

---

### Task 2: Make canonical stateful hooks config-root portable

**Files:**
- Modify: `home/read-once/hook.sh:59-61`
- Modify: `home/read-once/compact.sh:20`
- Modify: `home/skill-once/hook.sh:61`
- Modify: `home/skill-once/compact.sh:18`
- Create: `scripts/test-hook-config-root.sh`

**Interfaces:**
- Consumes: `AGENT_CONFIG_DIR` optional environment variable.
- Produces: `CONFIG_DIR="${AGENT_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"`; all read/skill cache files live under `$CONFIG_DIR/read-once` or `$CONFIG_DIR/skill-once`.

- [ ] **Step 1: Write the failing root-isolation test**

Create `scripts/test-hook-config-root.sh` that invokes each canonical hook with a temporary `HOME`, a different `AGENT_CONFIG_DIR`, and canonical Claude-shaped payloads. Assert cache files appear only under `AGENT_CONFIG_DIR`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/config"
printf 'content\n' > "$TMP/input.txt"
read_payload=$(jq -nc --arg p "$TMP/input.txt" '{tool_name:"Read",session_id:"root-test",tool_input:{file_path:$p}}')
printf '%s' "$read_payload" | HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" bash "$ROOT/home/read-once/hook.sh" >/dev/null
skill_payload='{"tool_name":"Skill","session_id":"root-test","tool_input":{"skill":"doc-writing","args":""}}'
printf '%s' "$skill_payload" | HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" bash "$ROOT/home/skill-once/hook.sh" >/dev/null
test -d "$TMP/config/read-once"
test -d "$TMP/config/skill-once"
test ! -e "$TMP/home/.claude/read-once"
test ! -e "$TMP/home/.claude/skill-once"
printf 'hook config root: PASS\n'
```

Extend it by invoking both compact scripts with the same session and checking the corresponding session cache is removed beneath `$TMP/config`.

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/test-hook-config-root.sh`

Expected: nonzero because current scripts write beneath `$HOME/.claude`.

- [ ] **Step 3: Implement the neutral root in all four scripts**

Replace each hardcoded cache root with:

```bash
CONFIG_DIR="${AGENT_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
CACHE_DIR="$CONFIG_DIR/read-once"       # read-once scripts
CACHE_DIR="$CONFIG_DIR/skill-once"      # skill-once scripts
```

Do not alter policy, TTL, diff, agent namespace, or output logic.

- [ ] **Step 4: Run focused and regression tests**

Run:

```bash
bash scripts/test-hook-config-root.sh
bash scripts/test-install.sh
bash scripts/test-agent-join.sh
```

Expected: `hook config root: PASS`; existing suites end with zero failures.

- [ ] **Step 5: Commit**

```bash
git add home/read-once home/skill-once scripts/test-hook-config-root.sh
git commit -m "refactor: make hook state root configurable"
```

---

### Task 3: Implement the Polytoken hook protocol adapter

**Files:**
- Create: `polytoken/hooks/adapter.sh`
- Create: `scripts/test-polytoken-hooks.sh`
- Test fixtures: `scripts/fixtures/polytoken-hooks/*.json`

**Interfaces:**
- Invocation: `adapter.sh CANONICAL_RELATIVE_PATH MAPPING`; `MAPPING` is exactly one of `shell`, `read`, `skill`, or `compact`.
- Environment: `POLYTOKEN_CONFIG_DIR` selects installed root; `POLYTOKEN_SESSION_ID` is used when stdin lacks a session id; `POLYTOKEN_CANONICAL_ROOT` overrides canonical-script lookup in repository tests.
- Output: exactly one Polytoken outcome JSON object on stdout; canonical stderr passes through stderr.

- [ ] **Step 1: Write failing allow/deny translation tests**

Create `scripts/test-polytoken-hooks.sh` with a `run_adapter` helper and assertions for:

```bash
out=$(cat "$FIX/pre-tool-shell-exec.json" | POLYTOKEN_CANONICAL_ROOT="$ROOT/home" POLYTOKEN_CONFIG_DIR="$TMP/config" \
  bash "$ADAPTER" hooks/no-remote-writes.sh shell)
jq -e '.outcome == "allow"' <<<"$out" >/dev/null

payload=$(jq '.input.command="git push"' "$FIX/pre-tool-shell-exec.json")
out=$(printf '%s' "$payload" | POLYTOKEN_CANONICAL_ROOT="$ROOT/home" POLYTOKEN_CONFIG_DIR="$TMP/config" \
  bash "$ADAPTER" hooks/no-remote-writes.sh shell)
jq -e '.outcome == "deny" and (.reason | contains("git push"))' <<<"$out" >/dev/null
```

Add cases for `bash-guard`, `branch-guard`, `git-safe`, first/duplicate `file_read`, first/duplicate `skill`, and both compact reset scripts. Assert state appears below `$TMP/config`.

- [ ] **Step 2: Add failing malformed-output and stderr-isolation tests**

Create temporary canonical scripts that emit invalid JSON, emit two JSON objects, exit nonzero, and write diagnostics to stderr. Assert the adapter emits:

```json
{"outcome":"error","message":"polytoken hook hooks/bad-output.sh: malformed canonical output"}
```

and that captured stdout contains one JSON object while diagnostics remain on stderr.

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash scripts/test-polytoken-hooks.sh`

Expected: nonzero because `polytoken/hooks/adapter.sh` does not exist.

- [ ] **Step 4: Implement input normalization**

Implement argument validation and mappings using the captured fixture field names. The canonical object must be built with jq, never string interpolation:

```bash
case "$mapping" in
  shell) canonical_tool=Bash; canonical_input=$(jq -c '{command:(.input.command // "")}') ;;
  read)  canonical_tool=Read; canonical_input=$(jq -c '{file_path:(.input.path // ""),offset:(.input.offset // null),limit:(.input.limit // null)} | with_entries(select(.value != null))') ;;
  skill) canonical_tool=Skill; canonical_input=$(jq -c '{skill:(.input.name // ""),args:""}') ;;
  compact) canonical_tool=""; canonical_input='{}' ;;
  *) emit_error "unsupported mapping: $mapping" ;;
esac
```

Build canonical stdin with `hook_event_name`, `session_id`, `tool_name`, `tool_input`, and agent/subagent identity only when present in the observed fixture. Export:

```bash
export AGENT_CONFIG_DIR="${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}"
```

Resolve the canonical script below `${POLYTOKEN_CANONICAL_ROOT:-$AGENT_CONFIG_DIR/compat}` and reject traversal or missing/non-executable paths.

- [ ] **Step 5: Implement strict decision translation**

Capture canonical stdout/stderr separately. For `pre_tool_use`:

```bash
# empty + rc 0
jq -nc '{outcome:"allow"}'
# recognized decision
jq -c 'if .hookSpecificOutput.permissionDecision == "deny" then
  {outcome:"deny", reason:.hookSpecificOutput.permissionDecisionReason}
elif .hookSpecificOutput.permissionDecision == "allow" then
  {outcome:"allow"}
else error("unsupported decision") end'
```

For `post_compaction`, canonical empty stdout + exit 0 becomes `{"outcome":"allow"}`. Any nonzero exit, malformed/multiple JSON output, or unsupported decision emits one `error` object and exits 0 so Polytoken receives the explicit outcome.

- [ ] **Step 6: Run adapter and canonical regression tests**

Run:

```bash
bash scripts/test-polytoken-contracts.sh
bash scripts/test-polytoken-hooks.sh
bash scripts/test-hook-config-root.sh
```

Expected: all print `PASS` and exit 0.

- [ ] **Step 7: Commit**

```bash
git add polytoken/hooks/adapter.sh scripts/test-polytoken-hooks.sh
git commit -m "feat: adapt canonical hooks for Polytoken"
```

---

### Task 4: Add and validate native Polytoken artifacts

**Files:**
- Create: `polytoken/config.recommended.yaml`
- Create: `polytoken/permissions.recommended.yaml`
- Create: `polytoken/hooks.json`
- Create: `polytoken/AGENTS.md`
- Create: `scripts/test-polytoken-artifacts.sh`

**Interfaces:**
- Consumes: adapter interface from Task 3 and canonical scripts copied under `$POLYTOKEN_CONFIG_DIR/compat/`.
- Produces: valid files installed as `config.yaml`, `permissions.yaml`, `hooks.json`, and `AGENTS.md`.

- [ ] **Step 1: Write the failing artifact test**

Create `scripts/test-polytoken-artifacts.sh` to assert:

```bash
jq -e 'type == "array" and length == 8 and ([.[].name] | length == (unique | length))' "$ROOT/polytoken/hooks.json" >/dev/null
jq -e 'all(.[]; (.event == "pre_tool_use" or .event == "post_compaction") and (.handler.bash | contains("hooks/adapter.sh")))' "$ROOT/polytoken/hooks.json" >/dev/null
grep -q '^version: 2$' "$ROOT/polytoken/config.recommended.yaml"
grep -q '^version: 2$' "$ROOT/polytoken/permissions.recommended.yaml"
! grep -Eq 'opus|sonnet|haiku|defaults:|models:|agent-join|agent-state|statusline\.sh' "$ROOT/polytoken/config.recommended.yaml" "$ROOT/polytoken/hooks.json"
```

Copy artifacts into a temporary config directory with canonical scripts under `compat/`; replace `__POLYTOKEN_CONFIG_DIR__` in the copied `hooks.json` with that temporary absolute path using jq string substitution; then run `polytoken --config-dir "$TMP" config validate --user`. Validate skills with `for f in home/skills/*/SKILL.md; do polytoken validate skill "$f"; done`.

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/test-polytoken-artifacts.sh`

Expected: nonzero because native artifacts do not exist.

- [ ] **Step 3: Write provider-neutral config and permissions**

Use exact schema-backed configuration:

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

Use the authored-schema minimum; only `version` is required:

```yaml
version: 2
```

An empty recommendation intentionally adds no permission rules; the installer still preserves and validates any existing user buckets.

- [ ] **Step 4: Write the eight named hook registrations**

Each `handler.bash` invokes the installed adapter and canonical relative path. Example:

```json
{
  "name": "no-remote-writes",
  "event": "pre_tool_use",
  "matcher": "shell_exec",
  "handler": {
    "bash": "bash \"__POLYTOKEN_CONFIG_DIR__/hooks/adapter.sh\" hooks/no-remote-writes.sh shell"
  }
}
```

Use names/mappings for four guards, `read-once`, `skill-once`, `read-once-reset`, and `skill-once-reset`. Repository `hooks.json` contains the literal `__POLYTOKEN_CONFIG_DIR__` token. The installer JSON-escapes the selected absolute destination and replaces only that token before validation, making default and custom destinations deterministic.

- [ ] **Step 5: Write Polytoken-native AGENTS.md**

Port permission examples to version-2 YAML and tool names to `shell_exec`, `file_read`, `glob`, and `grep`. Preserve commit and memory-routing guidance. Omit unverified Claude cwd persistence and Claude RTK-hook claims. Refer to Polytoken todos, saved goals, subagents, and jobs.

- [ ] **Step 6: Run native validation**

Run:

```bash
bash scripts/test-polytoken-artifacts.sh
```

Expected: artifact assertions and isolated `polytoken config validate --user` pass.

- [ ] **Step 7: Commit**

```bash
git add polytoken scripts/test-polytoken-artifacts.sh
git commit -m "feat: add native Polytoken configuration"
```

---

### Task 5: Add the target-aware Polytoken installer and structured merges

**Files:**
- Create: `scripts/install-polytoken.sh`
- Create: `scripts/test-install-polytoken.sh`
- Modify: `install.sh:4-30` and target dispatch around existing Claude body
- Modify: `scripts/test-install.sh:64-70` plus explicit-target regression scenarios

**Interfaces:**
- `install.sh [--target claude|polytoken|all] [--overwrite]`.
- `scripts/install-polytoken.sh FORCE`, where `FORCE` is `0` or `1`, consumes `POLYTOKEN_CONFIG_DIR` and `POLYTOKEN_CONFIG_TTY`.
- Return 0 on target success; target `all` returns nonzero if either target fails and prints each result.

- [ ] **Step 1: Write failing CLI dispatch tests**

Extend `scripts/test-install.sh` to assert no-argument and `--target claude` create identical Claude artifacts. Assert unknown/missing target values exit 2 with usage. In `scripts/test-install-polytoken.sh`, assert a fresh target creates:

```text
config.yaml
permissions.yaml
hooks.json
AGENTS.md
skills/*
hooks/adapter.sh
compat/{bash-guard,branch-guard,git-safe,read-once,skill-once,hooks/no-remote-writes.sh}
```

and does not install `statusline.sh`, `agent-state.sh`, or `agent-join/`.

- [ ] **Step 2: Run dispatch tests to verify they fail**

Run:

```bash
bash scripts/test-install.sh
bash scripts/test-install-polytoken.sh
```

Expected: Claude suite fails only new target cases; Polytoken suite fails because target support is absent.

- [ ] **Step 3: Refactor current Claude body behind target parsing**

Parse arguments once:

```bash
target=claude
force=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) [ "$#" -ge 2 ] || usage_error; target=$2; shift 2 ;;
    --overwrite) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done
case "$target" in claude|polytoken|all) ;; *) usage_error "unknown target: $target" ;; esac
```

Move the existing Claude copy/merge body unchanged into `install_claude()` in `install.sh`. Dispatch `claude` to that function, `polytoken` to `scripts/install-polytoken.sh "$force"`, and `all` to both while retaining each return code.

- [ ] **Step 4: Implement Polytoken file copying**

In `scripts/install-polytoken.sh`, copy canonical skills and selected canonical scripts directly from the repository. Render installed `hooks.json` by replacing the literal `__POLYTOKEN_CONFIG_DIR__` token with the jq-escaped absolute `POLYTOKEN_CONFIG_DIR`. Mark adapter and canonical scripts executable.

Implement `copy_managed_file SRC DST` with absent/identical/conflict behavior. Existing differing prose/scripts prompt `[y/N]`; no-TTY preserves; force backs up and replaces.

- [ ] **Step 5: Write failing structured-merge scenarios**

Add scenarios for:

- config additive leaf plus conflicting `tui.theme`;
- hooks merged by unique `name`, preserving custom order;
- same-name hook conflict declined/accepted;
- an existing valid `permissions.yaml` remains byte-identical because the recommendation contains no rules;
- no-TTY applies additions but preserves conflicts;
- overwrite accepts conflicts without deleting unrelated entries;
- repeat install creates no backup;
- invalid existing JSON/YAML leaves originals untouched;
- injected validation/write failure leaves originals intact;
- `--target all` partial failure reports both target names and exits nonzero.

Use `polytoken --config-dir "$D" config validate --user` as the final assertion for every successful scenario.

- [ ] **Step 6: Implement schema-aware merges**

Use `jq` for `hooks.json`: index existing objects by `.name`, enumerate missing/conflicting recommended entries, and append accepted missing entries while replacing accepted same-name entries in place. Reject duplicate names before writing.

Require mikefarah `yq` v4 for Polytoken YAML merges. If `yq` is absent or not v4, print the exact requirement and return nonzero before changing structured files; do not implement indentation-based text merges.

For config, use yq to enumerate recommended leaf/atomic-array patches and preserve unknown keys. Because `permissions.recommended.yaml` contains only `version: 2`, install it as `permissions.yaml` only when absent; when a valid file already exists, validate and leave it byte-identical. Rule merging is out of scope until the repository recommends at least one rule.

- [ ] **Step 7: Implement validated atomic writes**

For each structured destination:

```bash
staged="$dst.new-$TS"
# render chosen content to $staged
# validate staged in an isolated temporary config directory
cp "$dst" "$dst.bak-$TS"   # only after validation and only when changed
mv "$staged" "$dst"
```

Trap cleanup of temporary/staged files. Error text must identify `polytoken`, destination filename, and phase.

- [ ] **Step 8: Run installer suites**

Run:

```bash
bash scripts/test-install.sh
bash scripts/test-install-polytoken.sh
```

Expected: both suites report zero failures.

- [ ] **Step 9: Commit**

```bash
git add install.sh scripts/install-polytoken.sh scripts/test-install.sh scripts/test-install-polytoken.sh
git commit -m "feat: install configuration for Polytoken"
```

---

### Task 6: Make canonical skills accurate in both harnesses

**Files:**
- Modify: `home/skills/agent-session-retro/SKILL.md`
- Modify: `home/skills/git-workflow/SKILL.md`
- Modify: `home/skills/agent-orchestration/SKILL.md`
- Test: `scripts/test-polytoken-artifacts.sh`

**Interfaces:**
- Consumes: one canonical Agent Skills tree.
- Produces: skill prose valid for Claude and Polytoken without separate copies.

- [ ] **Step 1: Add failing semantic portability assertions**

Extend `scripts/test-polytoken-artifacts.sh` to require both native orchestration workflows and reject exclusive assertions such as “multiple Agent calls” without a Polytoken branch. Require `agent-session-retro` to mention both `CLAUDE.md` and `AGENTS.md`, and `git-workflow` to name equivalent Claude/Polytoken tools where relevant.

- [ ] **Step 2: Run the artifact test to verify it fails**

Run: `bash scripts/test-polytoken-artifacts.sh`

Expected: semantic portability assertions fail on current prose.

- [ ] **Step 3: Port the three skill bodies**

In `agent-orchestration`, structure the rules as shared correlation discipline plus two explicit subsections:

```markdown
## Claude Code
Use Agent/SendMessage and trust the agent-join status block.

## Polytoken
Use `subagent`; retain its returned job id; use `job_block` while waiting and `job_result` for completed output. Trust auto-drained completion notifications and native sidebar state; do not recreate or wait on an agent-join ledger.
```

In `agent-session-retro`, refer to “the harness instruction file (`CLAUDE.md` or `AGENTS.md`)”. In `git-workflow`, distinguish Claude `Bash` from Polytoken `shell_exec` only where tool behavior matters; retain one shared git policy.

- [ ] **Step 4: Validate all skills in both suites**

Run:

```bash
for f in home/skills/*/SKILL.md; do polytoken validate skill "$f"; done
bash scripts/test-polytoken-artifacts.sh
bash scripts/test-install.sh
```

Expected: every skill validates and both suites pass.

- [ ] **Step 5: Commit**

```bash
git add home/skills scripts/test-polytoken-artifacts.sh
git commit -m "docs: make shared skills harness-aware"
```

---

### Task 7: Document and verify the complete installation mode

**Files:**
- Modify: `README.md`
- Modify: `scripts/test-polytoken-artifacts.sh` if documentation assertions are kept there

**Interfaces:**
- Consumes: completed commands, dependencies, merge behavior, and exclusions.
- Produces: user-facing installation and compatibility reference.

- [ ] **Step 1: Write failing README assertions**

Add assertions for all exact commands and key scope statements:

```bash
grep -Fq './install.sh --target polytoken' "$ROOT/README.md"
grep -Fq './install.sh --target all' "$ROOT/README.md"
grep -Fq 'POLYTOKEN_CONFIG_DIR' "$ROOT/README.md"
grep -Fq 'agent-join' "$ROOT/README.md"
grep -Fq 'provider-neutral' "$ROOT/README.md"
```

- [ ] **Step 2: Run to verify documentation coverage fails**

Run: `bash scripts/test-polytoken-artifacts.sh`

Expected: README assertions fail.

- [ ] **Step 3: Update README**

Document:

- no-argument Claude compatibility;
- all three targets and `--overwrite`;
- Claude and Polytoken destination overrides;
- exact Bash 4+, jq, mikefarah yq v4, and Polytoken CLI validation dependencies;
- provider-neutral dark/native status configuration and omitted model/compaction settings;
- canonical shared skill installation;
- wrapped hook list;
- native replacements for status line, agent state, and agent join;
- additive no-TTY behavior, per-conflict prompts, backups, and atomic validation;
- custom-project negation of global hooks by name.

- [ ] **Step 4: Run the complete verification matrix**

Run:

```bash
bash scripts/test-polytoken-contracts.sh
bash scripts/test-hook-config-root.sh
bash scripts/test-polytoken-hooks.sh
bash scripts/test-polytoken-artifacts.sh
bash scripts/test-install.sh
bash scripts/test-install-polytoken.sh
bash scripts/test-agent-join.sh
bash scripts/validate-agent-join.sh
bash -n install.sh scripts/install-polytoken.sh polytoken/hooks/adapter.sh
shellcheck install.sh scripts/install-polytoken.sh polytoken/hooks/adapter.sh \
  home/read-once/hook.sh home/read-once/compact.sh \
  home/skill-once/hook.sh home/skill-once/compact.sh
for f in home/skills/*/SKILL.md; do polytoken validate skill "$f"; done
```

Expected: every command exits 0; scenario suites report zero failures; shellcheck emits no findings.

- [ ] **Step 5: Run isolated install smoke tests**

Run:

```bash
C=$(mktemp -d); P=$(mktemp -d)
CLAUDE_CONFIG_DIR="$C" CLAUDE_CONFIG_TTY=/nonexistent ./install.sh --target claude
POLYTOKEN_CONFIG_DIR="$P" POLYTOKEN_CONFIG_TTY=/nonexistent ./install.sh --target polytoken
polytoken --config-dir "$P" config validate --user
POLYTOKEN_CONFIG_DIR="$P" POLYTOKEN_CONFIG_TTY=/nonexistent ./install.sh --target polytoken
rm -rf "$C" "$P"
```

Expected: both installs succeed; Polytoken validation succeeds; repeated Polytoken install reports unchanged/up-to-date and creates no new backups.

- [ ] **Step 6: Review acceptance criteria against the design**

Read `docs/superpowers/specs/2026-07-12-polytoken-installation-mode-design.md:368-381` and record each criterion as verified by one of the commands above. Do not claim completion if fixture provenance, CLI validation, or any target-isolation case is missing.

- [ ] **Step 7: Commit**

```bash
git add README.md scripts/test-polytoken-artifacts.sh
git commit -m "docs: explain Polytoken installation mode"
```
