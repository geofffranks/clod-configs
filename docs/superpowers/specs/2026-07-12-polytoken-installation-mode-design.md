# Polytoken Installation Mode Design

**Date:** 2026-07-12
**Status:** Approved for implementation planning

## Summary

Add a first-class Polytoken installation target to `claude-config` while preserving the existing Claude Code installation behavior. The Polytoken target installs native configuration, permissions, hooks, global instructions, and the repository's canonical skills under `~/.config/polytoken` by default.

The two harnesses keep separate, explicit configuration and instruction files because their schemas and runtime semantics differ. Skills remain a single canonical tree because both harnesses use the Agent Skills directory format. Existing hook scripts remain the canonical policy and state implementations where the harnesses expose equivalent lifecycle events; a thin Polytoken adapter translates event input and decision output without duplicating hook logic.

Polytoken-native UI and job behavior replace Claude-only status-line and agent-join mechanisms. The design seeks behavioral parity, not mechanical installation of every Claude-specific artifact.

## Goals

- Preserve `./install.sh` as a backward-compatible Claude Code install.
- Add `--target claude`, `--target polytoken`, and `--target all`.
- Install Polytoken assets into `${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}`.
- Port stable, provider-neutral Claude configuration intent into native Polytoken configuration.
- Maintain one canonical skills tree for both harnesses.
- Maintain one canonical implementation for portable hook behavior.
- Preserve user configuration through per-patch merges, backups, validation, and atomic replacement.
- Test the adapter protocol, structured merges, target isolation, and idempotence.

## Non-goals

- Pin Anthropic, Opus, Sonnet, or Haiku models in Polytoken.
- Recreate Claude's executable custom status line in Polytoken.
- Add PR status, dollar cost, subscription rate-window, or custom working/idle fields to Polytoken's native status line when Polytoken has no documented module for them.
- Port Claude's `agent-join` ledger into Polytoken when Polytoken's job system, sidebar, and completion notifications already satisfy the behavioral need.
- Introduce a configuration generator, generalized hook policy framework, or duplicated harness-specific skill trees.
- Make the Polytoken installation depend on `~/.claude` or a prior Claude installation.

## Repository layout

Keep the existing `home/` tree as the Claude Code source. Add explicit Polytoken assets without reorganizing the repository around a new shared hierarchy.

```text
home/
├── CLAUDE.md
├── settings.recommended.json
├── skills/                         # canonical skills for both harnesses
├── bash-guard/
├── branch-guard/
├── git-safe/
├── read-once/
├── skill-once/
└── ...                             # other Claude assets

polytoken/
├── AGENTS.md
├── config.recommended.yaml
├── permissions.recommended.yaml
├── hooks.json
└── hooks/
    └── adapter.sh

install.sh
scripts/
├── test-install.sh
├── test-install-polytoken.sh
└── test-polytoken-hooks.sh
```

The exact test-file decomposition may change during planning, but the implementation must preserve separate coverage for existing Claude behavior, Polytoken installation, and adapter contracts.

## Installer interface

```bash
./install.sh                         # Claude; current default remains unchanged
./install.sh --target claude         # explicit Claude target
./install.sh --target polytoken      # Polytoken target only
./install.sh --target all            # run both targets independently
./install.sh --overwrite             # accept target conflicts non-interactively
```

The design does not add a model profile or `--profile` flag.

Existing Claude environment controls remain supported. The Polytoken target receives equivalent destination and test-TTY controls where required by automated tests, with `POLYTOKEN_CONFIG_DIR` as its public destination override.

`--target all` runs the two target installations independently. A failure must identify its target and must not leave either target with a partially written structured file. A successful target need not be rolled back solely because the other target failed, but the final command must report partial success clearly and exit nonzero.

## Polytoken configuration mapping

### Base configuration

`polytoken/config.recommended.yaml` contains only stable, provider-neutral preferences confirmed by Polytoken's configuration schema.

Recommended mappings include:

- schema version `2`;
- dark TUI mode, corresponding to Claude's current dark theme;
- native status-line modules for:
  - current working directory;
  - source control;
  - facet;
  - model;
  - permissions;
  - context usage.

The configuration must not change existing model definitions or `defaults.full`, `defaults.mini`, or `defaults.nano`.

Claude's `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50` may be mapped only if the installed/current Polytoken schema supports a provider-neutral global compaction threshold. If compaction thresholds are only per-model, omit this mapping rather than defining or overwriting user models.

The following Claude settings have no confirmed safe direct mapping and are omitted:

- executable `statusLine`;
- `verbose`;
- `skillListingBudgetFraction`;
- Claude/Anthropic model environment variables;
- Claude-specific model availability and effort controls.

Theme tokens may style Polytoken's native status bar and lifecycle UI, but they cannot add status-line content or change layout. Templates do not render the status line.

### Permissions

Polytoken permissions are stored in a native version-2 YAML permissions file, separate from config and hooks. The current Claude recommended settings deliberately install no permissions, so the Polytoken recommendation remains minimal and does not broadly auto-allow tools.

Safety policy remains canonical in the portable guard hooks rather than being duplicated as permission rules. Any recommended permission rules added during implementation must have a documented need not already covered by the hooks.

Existing user rules are preserved. Rules from the recommendation are added only when structurally absent. Because Polytoken resolves matching rules to the most restrictive result, the installer must not claim that adding an allow rule overrides an existing ask or deny rule.

### Native status and background behavior

Polytoken uses native status-line modules, theme styling, sidebar job state, subagent lifecycle indicators, completion flashes, and auto-drained notifications. These replace:

- `statusline.sh`;
- `hooks/agent-state.sh`;
- `agent-join/hook.sh`.

Those Claude-specific artifacts remain installed for Claude but are not registered for Polytoken.

## Global instructions

Maintain two explicit instruction files:

- `home/CLAUDE.md` for Claude Code;
- `polytoken/AGENTS.md` for Polytoken.

`AGENTS.md` is a hand-maintained semantic port, not generated from fragments. It preserves durable intent while using true Polytoken concepts:

| Claude concept | Polytoken form |
|---|---|
| `settings.json` permission patterns | version-2 `permissions` YAML |
| `Bash`, `Read`, `Glob`, `Grep` | `shell_exec`, `file_read`, `glob`, `grep` |
| Claude-specific task handling | Polytoken todos, saved goals, jobs, and subagents |
| `CLAUDE.md` as durable repo guidance | the repository's existing `AGENTS.md` or instruction file |

Commit-message and memory/task-routing guidance can be preserved where harness-neutral. Claude-specific shell-cwd and RTK statements must be included only after verifying they remain true for Polytoken. The file must not instruct Polytoken to use Claude permission syntax or edit Claude settings.

## Skills

`home/skills/` is the single canonical source and is copied recursively to both native skill directories:

```text
Claude:    ~/.claude/skills/
Polytoken: ~/.config/polytoken/skills/
```

Both harnesses use directories containing `SKILL.md` in the Agent Skills format. Polytoken-specific frontmatter such as tags or disabled model invocation is not added without a concrete requirement.

Audit the canonical skills for semantic portability:

- `doc-writing`: expected to remain harness-neutral.
- `agent-session-retro`: replace exclusive `CLAUDE.md` terminology with harness-neutral instruction-file terminology.
- `git-workflow`: describe equivalent tools and hooks without assuming only Claude names or paths.
- `agent-orchestration`: document two native workflows:
  - Claude uses its Agent tooling and `agent-join` behavior;
  - Polytoken uses `subagent`, job tools, auto-drained notifications, and sidebar state.

A skill is split only if one clear shared procedure cannot describe both harnesses. Splitting is an exception requiring justification during implementation review.

## Hook protocol differences

Claude registers hooks under event groups in `settings.json`. Its scripts currently expect fields such as `hook_event_name`, `session_id`, `tool_name`, and `tool_input`, and emit Claude-specific `hookSpecificOutput` decisions.

Polytoken registers a JSON array in `hooks.json`. Each object has a unique `name`, snake_case `event`, optional validated glob `matcher`, and `handler`. Tool matchers use Polytoken tool names. Blocking handlers emit strict event-specific outcome objects such as:

```json
{"outcome":"allow"}
```

```json
{"outcome":"deny","reason":"git push is blocked. Ask the user to push."}
```

Unknown events, matchers, handler keys, or outcome fields are load/runtime errors. Errors on `pre_tool_use`, `pre_model_turn`, `stop`, and `pre_compaction` fail closed. Adapter correctness is therefore part of the safety boundary.

## Polytoken hook adapter

### Purpose

Use a thin adapter so both installations execute the same canonical hook scripts. The adapter translates protocols only; it does not reimplement command policy, cache decisions, or orchestration logic.

```text
Polytoken event
    → normalize event/tool/input/session/config root
    → canonical existing hook
    → translate canonical decision
    → one valid Polytoken outcome
```

### Input mappings

The intended mappings are:

| Polytoken | Canonical script input |
|---|---|
| `shell_exec` on `pre_tool_use` | `Bash` with `tool_input.command` |
| `file_read` on `pre_tool_use` | `Read` with `file_path`, `offset`, and `limit` |
| `skill` on `pre_tool_use` | `Skill` with the skill identity in the shape expected by `skill-once` |
| `post_compaction` | `PostCompact` with a normalized session ID |

Use `POLYTOKEN_SESSION_ID` and other documented `POLYTOKEN_*` variables for common metadata when available. The adapter sets a neutral config root so stateful canonical hooks write under the selected Polytoken directory.

Before implementing these mappings, verify actual Polytoken stdin payloads and `handler.bash` invocation semantics against the current runtime/documentation. Tests must encode observed payloads rather than an inferred complete envelope. If Polytoken does not provide reliable input required by a stateful hook, omit that hook and document the limitation rather than fabricating unreliable values.

### Canonical script portability changes

Make only narrow changes to existing canonical scripts:

```bash
CONFIG_DIR="${AGENT_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
```

Use the neutral root for `read-once` and `skill-once` state instead of hardcoded `~/.claude` paths. Claude behavior remains unchanged through its existing fallback. The Polytoken adapter exports `AGENT_CONFIG_DIR`.

Policy and cache logic remains in the existing scripts. Polytoken outcome branches are not copied into each canonical script.

### Decision translation

- Canonical empty stdout with exit `0` becomes `{"outcome":"allow"}` for `pre_tool_use`.
- A recognized Claude allow decision becomes Polytoken `allow`.
- A recognized Claude deny decision becomes Polytoken `deny` with the same reason.
- Irrelevant event/tool input becomes explicit `allow`.
- Unexpected exit, malformed JSON, multiple output objects, or an unsupported decision becomes an explicit Polytoken `error` naming the hook.
- Canonical stderr is preserved as stderr; only the final outcome is written to stdout.
- Explicit JSON outcomes are preferred over exit-code-2 shorthand.

### Wrapped hooks

Register adapters for:

- `bash-guard`;
- `branch-guard`;
- `git-safe`;
- `no-remote-writes`;
- `read-once`;
- `skill-once`;
- `read-once` post-compaction reset;
- `skill-once` post-compaction reset.

Do not wrap `agent-state`, the executable status line, or `agent-join`.

## Merge behavior

### General policy

- Install absent managed files.
- Leave byte-identical files untouched.
- Back up and replace changed managed files only after acceptance.
- Preserve unrelated user entries in structured files in every mode.
- In no-TTY mode, apply additive changes and skip conflicts with actionable diagnostics.
- `--overwrite` accepts recommended conflicts but does not delete unrelated user entries.

### Skills and scripts

Copy recursively from repository sources. Include skill companion files. Existing differing managed files follow confirmation and backup behavior; unchanged files do not receive backups.

### Polytoken config

Merge provider-neutral recommended leaf values using the existing per-patch `[y/N]` interaction. Unknown/user keys are preserved. Arrays are atomic unless Polytoken documents a field as set-like and the implementation explicitly tests that behavior.

### Hooks

Merge `hooks.json` by required `name`:

- add missing recommended names;
- preserve unrelated user hooks and their relative ordering;
- treat a same-name entry with different event, matcher, or handler as a conflict;
- never install duplicate hook names.

A project may negate a global hook by name using Polytoken's native negation mechanism; the global installer does not edit project hook files.

### Permissions

Preserve every existing rule. Add a recommended rule only when structurally absent from its bucket. Do not remove, reorder, or weaken existing rules.

### AGENTS.md

Do not attempt a structural prose merge. Install when absent, leave identical content unchanged, and prompt before backing up and replacing different content. No-TTY mode preserves an existing differing file and prints manual instructions.

## Atomicity and error handling

Every structured update is rendered to a temporary file and parsed/validated before destination changes. Stage the validated file in the destination directory, back up the existing file only when final content differs, and atomically rename the staged file over the destination. Signal or validation failure removes staging files and leaves the original intact.

Errors name target, file, and phase, for example:

```text
polytoken: hooks.json validation failed; existing file unchanged
```

Missing `jq` or a required YAML processor must not trigger unsafe text-based merges. Use a documented Polytoken CLI facility where available; otherwise skip the affected structured merge and print exact manual instructions. Dependencies must be listed in `--help` and README.

## Validation and testing

### Static artifacts

- Parse all JSON and YAML.
- Ensure Polytoken hook names are unique.
- Ensure every handler references an installed file.
- Ensure every canonical skill directory contains `SKILL.md` with compatible required frontmatter.
- Run `bash -n` and `shellcheck` on shell scripts.
- Use Polytoken CLI validators where available.

### Adapter contracts

Use captured representative Polytoken payloads for:

- `shell_exec`;
- `file_read`;
- `skill`;
- `post_compaction`.

Cover:

- allow and deny translation;
- malformed canonical output;
- unexpected canonical exit;
- irrelevant tool/event input;
- exactly one valid Polytoken outcome on stdout;
- stderr isolation;
- state written under the selected Polytoken root and not `~/.claude`.

### Installer scenarios

Cover:

- fresh Claude installation;
- fresh Polytoken installation;
- `--target all`;
- repeated idempotent installs;
- custom destinations;
- no-TTY additive merges;
- interactive conflict accept/decline;
- `--overwrite`;
- preservation of custom config keys, hooks, permission rules, and skills;
- backup creation only when content changes;
- injected parse/write failures leaving originals intact;
- clear partial-success reporting for `--target all`.

Smoke-test Polytoken startup or config reload against an isolated temporary config directory when the CLI supports doing so. At minimum, validate `hooks.json` against Polytoken's strict documented schema rather than merely parsing it as generic JSON.

## Documentation

Update README to cover:

- supported targets and default behavior;
- destination overrides;
- provider-neutral Polytoken configuration scope;
- canonical shared skills;
- wrapped hook families;
- native replacements for status line, agent state, and agent join;
- merge, no-TTY, backup, and overwrite behavior;
- required dependencies;
- known compatibility limitations.

## Acceptance criteria

Implementation is complete when:

1. No-argument Claude installation and its existing tests remain compatible.
2. `--target polytoken` installs valid native config, permissions, hooks, `AGENTS.md`, canonical scripts, and canonical skills beneath the selected Polytoken config root.
3. The four safety guards execute the same canonical policy logic in both harnesses.
4. `read-once`, `skill-once`, and both compaction reset scripts execute canonical logic through verified Polytoken adapters.
5. Polytoken uses native toolbar and subagent/job behavior instead of Claude-only status and `agent-join` scripts.
6. Repeated installation is idempotent and creates no unnecessary backups.
7. User-owned structured entries survive normal, no-TTY, and overwrite modes.
8. Structured writes are validated and atomic.
9. README accurately describes installation, scope, and omissions.
10. Adapter tests use verified runtime payloads and all static, adapter, installer, and smoke validations pass.
