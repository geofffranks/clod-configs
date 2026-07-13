# Polytoken hook contract fixtures

Captured on 2026-07-12 with the exact installed version reported by `polytoken --version`:

```text
polytoken 0.5.0-unstable.6
```

## Runtime capture provenance

The capture used these literal locations from the repository root:

- isolated user config: `$PWD/.superpowers/sdd/task-1-capture/config.yaml`
- source hook array: `$PWD/.superpowers/sdd/task-1-capture/hooks.json`
- disposable project: `/tmp/polytoken-task1-project`
- active project hook config: `/tmp/polytoken-task1-project/.polytoken/hooks.json`
- handler outputs: `/tmp/polytoken-task1-pre-tool-shell.json`, `/tmp/polytoken-task1-pre-tool-file-read.json`, `/tmp/polytoken-task1-pre-tool-skill.json`, and `/tmp/polytoken-task1-post-compaction.json`

The isolated `config.yaml` was a copy of the then-valid user config. Credentials remained indirect (`${ZAI_API_KEY}` and the existing Codex device-auth profile) and are the only omitted values. The settings relevant to this capture were:

```yaml
version: 2
defaults:
  full: codex/gpt-5.6-sol
models:
  codex/gpt-5.6-sol:
    context_window: 24000
    compaction_threshold: 0.4
    max_output_tokens_per_turn: 1024
    reasoning:
      type: effort
      effort_set: gpt_5_6_sol
      can_disable: true
      levels: [low, medium, high, xhigh, max]
      default_level: high
```

The complete hook array copied to the project location was:

```json
[
  {
    "name": "capture-shell",
    "event": "pre_tool_use",
    "matcher": "shell_exec",
    "handler": {"bash": "IFS= read -r line; printf '%s\\n' \"$line\" > /tmp/polytoken-task1-pre-tool-shell.json; echo '{\"outcome\":\"allow\"}'"}
  },
  {
    "name": "capture-file-read",
    "event": "pre_tool_use",
    "matcher": "file_read",
    "handler": {"bash": "IFS= read -r line; printf '%s\\n' \"$line\" > /tmp/polytoken-task1-pre-tool-file-read.json; echo '{\"outcome\":\"allow\"}'"}
  },
  {
    "name": "capture-skill",
    "event": "pre_tool_use",
    "matcher": "skill",
    "handler": {"bash": "IFS= read -r line; printf '%s\\n' \"$line\" > /tmp/polytoken-task1-pre-tool-skill.json; echo '{\"outcome\":\"allow\"}'"}
  },
  {
    "name": "capture-post-compaction",
    "event": "post_compaction",
    "handler": {"bash": "IFS= read -r line; printf '%s\\n' \"$line\" > /tmp/polytoken-task1-post-compaction.json; echo '{\"outcome\":\"continue\"}'"}
  }
]
```

The successful pre-tool capture used these exact commands. The Perl parent sets a 45-second alarm, kills its child and exits 124 on expiry; the run completed with `capture_rc=0` before the alarm.

```sh
set -e
CAPTURE_DIR="$PWD/.superpowers/sdd/task-1-capture"
CAPROOT=/tmp/polytoken-task1-project
polytoken --config-dir "$CAPTURE_DIR" config validate --user
rm -rf "$CAPROOT"
mkdir -p "$CAPROOT/.polytoken"
cp "$CAPTURE_DIR/hooks.json" "$CAPROOT/.polytoken/hooks.json"
jq -e . "$CAPROOT/.polytoken/hooks.json" >/dev/null
rm -f /tmp/polytoken-task1-pre-tool-{shell,file-read,skill}.json
set +e
perl -e '$SIG{ALRM}=sub{kill 9,$pid if $pid; exit 124}; alarm 45; $pid=fork(); die $! unless defined $pid; if(!$pid){exec @ARGV; die $!} waitpid($pid,0); exit($? >> 8)' -- \
  polytoken --config-dir "$CAPTURE_DIR" --working-dir "$CAPROOT" exec \
  --model codex/gpt-5.6-sol --max-tool-turns 4 \
  'Use shell_exec once to run printf task1, then file_read once on /Users/gfranks/workspace/claude-config/.worktrees/polytoken-install/scripts/test-polytoken-contracts.sh, then skill once with name using-superpowers. Do not call other tools. Then answer done.' \
  >/tmp/polytoken-task1-exec.out 2>/tmp/polytoken-task1-exec.err
rc=$?
set -e
echo "capture_rc=$rc"
found=0
for f in /tmp/polytoken-task1-pre-tool-shell.json \
         /tmp/polytoken-task1-pre-tool-file-read.json \
         /tmp/polytoken-task1-pre-tool-skill.json; do
  test -e "$f" && found=$((found+1)) && echo "--- $f" && jq . "$f"
done
test "$found" -eq 3
```

The three observed JSON objects were copied without adding fields. Their `prompt_id` and `call_id` values are runtime-generated and therefore dynamic; the contract test requires nonempty strings but deliberately does not pin the captured ephemeral values. The absolute `file_read` path is preserved because it is structural capture evidence; the test accepts any machine prefix ending in `/scripts/test-polytoken-contracts.sh`.

## `post_compaction` fallback provenance

A runtime `post_compaction` event could not be captured safely. Two attempts used the same active project hook and this exact bounded invocation, first with `context_window: 12000` and `compaction_threshold: 0.2`, then with `context_window: 24000` and `compaction_threshold: 0.4`:

```sh
rm -f /tmp/polytoken-task1-post-compaction.json
perl -e '$SIG{ALRM}=sub{kill 9,$pid if $pid; exit 124}; alarm 30; $pid=fork(); die $! unless defined $pid; if(!$pid){exec @ARGV; die $!} waitpid($pid,0); exit($? >> 8)' -- \
  polytoken --config-dir "$PWD/.superpowers/sdd/task-1-capture" \
  --working-dir /tmp/polytoken-task1-project exec \
  --model codex/gpt-5.6-sol --max-tool-turns 1 \
  'Answer only done. Do not use tools.' \
  >/tmp/polytoken-task1-compact.out 2>/tmp/polytoken-task1-compact.err
```

Both attempts exited 1 with `provider error: context too large for model` before hook dispatch, so `/tmp/polytoken-task1-post-compaction.json` was never created. The task brief explicitly permits installed source/schema or daemon-log provenance when a real event cannot be triggered non-interactively. Accordingly, `post-compaction.json` uses the official installed-version hook contract at <https://docs.polytoken.dev/harness-engineering/hooks/>: every event has `event` and `matcher_subject`; non-tool matcher subjects equal the event name; no event-specific `post_compaction` stdin fields are documented. The fallback therefore contains exactly those two fields and no invented fields.

## Validation

```sh
bash scripts/test-polytoken-contracts.sh
polytoken schemas app-config --output json >/dev/null
polytoken schemas permissions-config --output json >/dev/null
```
