# claude-config

A portable, de-personalized set of configuration for two AI coding harnesses:
[Claude Code](https://claude.com/claude-code) and
[Polytoken](https://github.com/obra/polytoken). It bundles a few skills,
safety/utility hooks, a curated global instruction file, and recommended
settings — but **no permissions** (those are always yours to grant).

A single `install.sh` installs for either or both harnesses. The two harnesses
keep separate configuration and instruction files because their schemas and
runtime semantics differ; skills and the canonical hook logic are shared.

## Install

```bash
git clone <this-repo> claude-config
cd claude-config
./install.sh
```

With no arguments, `./install.sh` is a **Claude Code** install — identical to
the original behavior, and the existing tests stay green. To target a specific
harness (or both):

```bash
./install.sh --target claude       # Claude Code config (default; same as no args)
./install.sh --target polytoken    # native Polytoken config
./install.sh --target all          # install both targets, independently
```

`--target all` runs each target as an independent step and reports each result;
it does not roll back a success if the other target fails.

### Overwrite

By default, when a recommended value differs from yours you are walked through
each difference and approve them individually (see *Merge behavior* below). To
take every recommended value without prompting:

```bash
./install.sh --target claude --overwrite
./install.sh --target polytoken --overwrite
```

`CLAUDE_CONFIG_OVERWRITE=1` does the same thing via the environment.

### Destinations

| Target | Default | Override |
|---|---|---|
| Claude Code | `~/.claude` | `CLAUDE_CONFIG_DIR` |
| Polytoken | `~/.config/polytoken` | `POLYTOKEN_CONFIG_DIR` |

Each target reads its own TTY override for interactive prompts:
`CLAUDE_CONFIG_TTY` (Claude) and `POLYTOKEN_CONFIG_TTY` (Polytoken); both
default to `/dev/tty`.

### Attention notifications (agent-notify)

Polytoken defaults do **not** install notification hooks, scripts, libraries,
watchdog credentials or runtime data. Opt in explicitly with
`./install.sh --target polytoken --notify-hook-only` (add
`--containerized-polytoken` for the SSE watcher keepalive). The watchdog keepalive
component is retired, and no `watchdog.env` is generated or sourced. Discord
bridge autostart and quota hooks remain in default installation.

For a scoped refresh of definitions, guards and hooks without configuration or
permission-policy merges, use `POLYTOKEN_CONFIG_DIR=<destination> bash
scripts/install-polytoken.sh 1 deployment`. Managed notification/Superpowers hook
registrations are retired with a hooks backup; unrelated hooks remain.

Both harnesses can push you when a run needs input or has died: the local
Notification Center (credential-free on a mac, on by default) plus the
optional Pushover. Install just the notification stack — none of the guards,
skills, statusline, or instruction files — for either or both harnesses:

```bash
./install.sh --notify-hook-only --target all
```

With containerized Polytoken sessions, add `--containerized-polytoken` (it
skips the macOS LaunchAgent and installs the keepalive hooks instead).
Pushover credentials are environment-only: `PUSHOVER_APP_TOKEN` and
`PUSHOVER_USER_KEY`. What alerts you under each harness, credentials, death
alerts, the session watchdog, the SSE event watcher, and diagnostics live in
one place: **[docs/agent-notify.md](docs/agent-notify.md)**.

### Requirements

| Dependency | Used by | Notes |
|---|---|---|
| **bash 4+** | Claude status line (`mapfile`) | macOS ships bash 3.2 — install a newer one via Homebrew. The notify/watchdog scripts are bash 3.2-safe. |
| **jq** | both targets | settings/hooks merge and JSON processing; also required by agent-notify and the session watchdog in mac-only mode (title/body enrichment). |
| **osascript + perl** | Notification Center lane | built into macOS — nothing to install; every `osascript` call is bounded by a 5s `perl` alarm. |
| **mikefarah/yq v4** | Polytarget YAML merge | the Go-based `yq`; the Python `yq` wrapper does **not** support the required `eval-all` + `*` deep-merge and is rejected. Full Polytoken installs only — the notify-only install needs jq + curl, not yq. |
| **Polytoken CLI** | Polytarget target | `polytoken config validate --user` validates structured writes in context; `polytoken validate skill` checks skills. |
| **python3** | Polytoken hook adapter | validates canonical hook paths stay under the config root. |

Missing a structured-merge dependency never triggers an unsafe text merge: the
affected step is skipped and exact manual instructions are printed.

## What each target installs

### Claude Code target

Copies everything under `home/` into `CLAUDE_CONFIG_DIR`, then merges
`home/settings.recommended.json` into your `settings.json`.

| Piece | Notes |
|---|---|
| `skills/` | Shared canonical skills (see below). |
| `bash-guard`, `branch-guard`, `git-safe` | Block risky bash, commits to protected branches, and destructive git ops. |
| `hooks/no-remote-writes.sh` | Blocks unsolicited `git push` / `gh` writes. |
| `hooks/agent-state.sh` | Writes the working/idle badge the status line shows. |
| `hooks/agent-notify.sh` + `lib/notify-mac.sh` | Attention notifications (turn-end/question pushes; Notification Center + optional Pushover) — see [docs/agent-notify.md](docs/agent-notify.md). |
| `read-once/` | De-duplicates repeated file reads to save context. |
| `skill-once/` | Checks successful loads at `PreToolUse` and records only successful `PostToolUse` deliveries; deduplication is per Claude agent, compaction resets it, and `--force` removes a prior entry before a successful reload records it again. |
| `agent-join/` | Emits an `<orchestration-status>` block when a Claude Agent subagent joins, so the main session can correlate work by id. |
| `statusline.sh` | Status line: cwd, git, agent, PR, model, context %, session cost + per-turn cost, rate limits, monthly credit spend. |
| `usage-fetch.sh` | Fetches monthly usage-credit spend from `/api/oauth/usage` into `.usage-cache.json` for the status line. Runs detached; the status line only reads the cache. |
| `settings.recommended.json` | `env` (models, thinking budget, autocompact), theme, statusline, and hook wiring. No permissions. |
| `CLAUDE.md` | Curated global instructions: permission patterns, shell-cwd discipline, commit tips, memory routing. |

### Polytoken target

Installs **provider-neutral**, native Polytoken configuration into
`POLYTOKEN_CONFIG_DIR`. The two harnesses differ in what is portable, so the
Polytoken target deliberately omits Claude-only artifacts and replaces them
with Polytoken-native equivalents.

| Piece | Source | Notes |
|---|---|---|
| `config.yaml` | `polytoken/config.recommended.yaml` | `version: 3` + the single `mcp_servers.ratatoskr` gateway entry (see below). |
| `permissions.yaml` | `polytoken/permissions.recommended.yaml` | Empty `version: 2` recommendation — your rules are always preserved. |
| `hooks.json` | `polytoken/hooks.json` | Native hooks merged by unique name, including the notification entries documented in [docs/agent-notify.md](docs/agent-notify.md). Skill-once is omitted because per-agent hook identity is unavailable. |
| `AGENTS.md` | `polytoken/AGENTS.md` | Polytoken-native global instructions (Polytoken tool names), incl. rtk guidance (`rtk grep` for content search, `rtk <framework>` for tests/build; rules only — no hook). |
| `hooks/agent-notify.sh`, `hooks/session-watchdog.sh`, `hooks/*keepalive.sh`, `lib/notify-*.sh` | `home/` | The notification stack (hooks, session watchdog, SSE event watcher) — see [docs/agent-notify.md](docs/agent-notify.md). |
| `facets/` | `polytoken/facets/` | Three lifecycle facets: `product-design`, `project-manager`, `quick-delivery`; standalone `code-review` and `process-friction-triage` remain available. |
| `subagents/` | `polytoken/subagents/` | Managed built-in and workflow-specialist roles, including `agent-workflow-architect` and `agent-workflow-engineer`. |
| `skills/` | `home/skills/` | The same canonical skills tree shared with Claude. |
| `compat/` | `home/{bash-guard,branch-guard,git-safe,grep-guard,large-read-guard,read-once}` + `home/hooks/no-remote-writes.sh` | Canonical hook scripts installed under `compat/`; a fresh install does not copy `compat/skill-once`. |

#### Design and delivery

Use `product-design` to investigate requirements, consult useful experts and write
one design covering outcome, observable requirements, solution, non-goals,
acceptance, material risks, Git choices, delivery mode and proposed review panel.
Immediately before design writing, choose the starting/effort branch, isolated
workspace, mergeback target or leave-unmerged, and standard/quick mode. The
designer may perform approved workspace setup, not repository implementation,
build/install or service launches. Delivery receives the same workspace.

Design review uses `design-reviewer`, or `agent-workflow-architect` for AI workflows:
one initial pass and at most one focused delta, with concrete blockers resolved
or escalated. It does not demand detailed implementation prescriptions or named
automation per criterion. The operator approves the complete design and review
panel, including roles/reasons/focus, before handoff.

`project-manager` owns proportionate technical planning in working task state,
implementation coordination, approved-panel review and feasible acceptance checks.
There is no second technical-plan approval unless material outcome/scope/risk
changes or infeasibility require disposition. `quick-delivery` uses a brief
approach, implements directly by default, runs relevant tests and one correctness
review by default, with no separate validation stage or manual completion gate.
Neither automatically returns to design. Generic implementation defaults to
`software-engineer`; conditional [ai-workflow](home/skills/ai-workflow/SKILL.md)
routes AI-workflow work to its specialists. Missing optional roles/skills are not
blockers. Workers load relevant procedures themselves; no mandatory architect,
persona or final-validator chain.

Each approved implementation lane gets one initial review and up to four focused
followups on unresolved findings and affected behavior. Consolidate repairs;
renaming/reslicing never resets budgets. Reviewers may run relevant tests/builds
and use web/MCP/skills, but never fix source, commit, perform destructive operations
or spawn agents. Concrete defects, requirement violations and material risks may
block; preferences are advisory. Snapshot mode retains its separate boundary.

Checks are outcome-focused: relevant existing tests, practical regression coverage,
official configuration parsers/loaders and effective-tool checks where exposure
changes. Prompt instructions receive content review/scenarios, not phrase tests
or policy replicas. No mandatory TDD transcript, clean-commit checkpoint, digest,
identity ledger, evidence manifest or new validation framework merely to finish.
Only changed inputs/affected behavior invalidate checks/reviews, not commit IDs.
Missing assets/tooling are access/procedure gaps, not redesign authority. Report
untested/manual work honestly.

Honor upfront Git disposition after successful required checks/reviews: commit,
approved local mergeback, effort-owned cleanup, then active-goal completion before
the all-done summary. Manual checks remain visible but do not block these steps.
No new finalize-before/after-human-checks question. Leave-unmerged retains the
branch; branch deletion/push is not implied. Preserve unrelated work; substantive
conflicts or unresolved blockers require escalation.

Jira remains optional without a supplied ticket. Preserve live status checks,
authority, actual session attribution and uncertain-write reconciliation via
[jira-workflow](home/skills/jira-workflow/SKILL.md). Done/Canceled still requires
confirmation. No mandatory retrospective or automatic friction tickets.

Conditional [screenshots](home/skills/screenshots/SKILL.md),
[Appium](home/skills/appium/SKILL.md) and
[native checks](home/skills/xcode-native-checks/SKILL.md) hold tool procedures,
shared-session ownership and device exclusions, not facets. Screenshot runtime
storage is `/Users/gfranks/workspace/screenshots/<branch-folder>/`; reviewers open
absolute paths, without checksums/manifests/fixture gates.

For source-only deployment, select the actual installation destination and run
`POLYTOKEN_CONFIG_DIR=<destination> bash scripts/install-polytoken.sh 0 definitions`.
It preserves config/providers/quota/MCP/hooks and prompts decline-default before
moving known retired copies to backups; force mode never retires them. Retired
copies include workflow-designer/workflow-project-manager, local escape facets,
obsolete Lappie lifecycle/bootstrap skills and inactive design-workflow.j2.
Custom definitions remain. Source edits, installed copies and runtime activation
are separate facts; inspect the chosen destination and activate separately.


#### Read-only GitHub code review

Review reports keep PR-actionable and pre-existing findings in separate severity-ranked buckets. Every finding renders **What happens if left unfixed** (`impact_if_unfixed`), **Triggering use cases / reproduction conditions** (`triggering_use_cases`), and **Affected scope** (`affected_scope`), using concrete evidence rather than vague placeholders.

The `code-review` facet reviews a pull request or uniquely named branch using
only the local authenticated `gh` CLI and read operations. It never comments,
approves, pushes, publishes, mutates the checkout, uses MCP, or executes
repository code by default. Immutable snapshots, append-only journals, and
local reports live under
`~/.local/share/polytoken/code-review/<canonical-host>/<owner>/<repo>/<scope_id>/`.

Six independent `snapshot-review-*` workers — adversarial, correctness,
completeness, maintainability, general, and abstraction — have mechanically
restricted file-read/search and allowed-skill grants, with no shell, network,
MCP or execution tools. Ordinary `review-*` workers retain relevant testing
capability and are not used by this workflow. Snapshot workers inspect the
pinned snapshot, followed by a fresh
`review-synthesis-verifier`. Findings preserve exact evidence, severity,
confidence, and provenance, with PR-actionable and pre-existing findings in
separate ranked buckets. Missing, stale, truncated, unverifiable, or failed
evidence is `blocked`, never clean. Follow-ups capture a new complete snapshot
and review unresolved findings plus changed hunks only, reporting
`still_present`, `resolved`, `unknown`, or `no_longer_applicable` rather than
silently becoming a full review.

The design/PM and triage facets pin `zai/glm-5.3-flash(high)` with fallback
`codex/gpt-5.6-luna-1m(medium)`. They use allow-all tools with small literal denies,
unrestricted skills and ratatoskr-only MCP instructions. This routing is a prompt
contract, not a sandbox for future tools or upstream operations. The gateway runs
on the Mac, including when Polytoken runs in the Linux container.

#### MCP: everything behind the ratatoskr gateway

The only MCP entry the recommendation carries is the ratatoskr gateway:

```yaml
mcp_servers:
  ratatoskr:
    transport: http
    url: http://host.docker.internal:8910/mcp
```

The gateway runs natively on the Mac as a launchd agent and fronts every MCP
server (codex-imagegen, foundry, minime_vision, appium, homeassistant). One
literal URL serves both contexts because `host.docker.internal` resolves to
loopback on the Mac (an `/etc/hosts` alias) and to the VM bridge inside the dev
containers. Deploy or refresh it with this repo's
`ratatoskr/setup-gateway.sh`; that script also wires this entry into your live
`~/.config/polytoken/config.yaml` — only after the gateway is verified
listening, so no session ever points at a dead URL. Per-project MCP
declarations are deliberately gone (DnD and ha-configs had theirs removed):
everything arrives through the gateway. Note the same ordering applies to the
installer: if you run `install.sh --target polytoken` before the gateway is
deployed, sessions will report the `ratatoskr` MCP unreachable until
`setup-gateway.sh` has run on the Mac.

#### Provider-neutral status configuration

The recommended `config.yaml` is **provider-neutral**: it carries only
`version: 3` and the `mcp_servers.ratatoskr` gateway entry. It deliberately
omits all model pins, model
defaults, and compaction/thinking settings that the Claude settings fragment
carries (`ANTHROPIC_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`,
`ANTHROPIC_DEFAULT_*_MODEL`, `MAX_THINKING_TOKENS`,
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`). Polytoken defines its own providers and
models in your user config; the recommendation installs as an overlay and never
overwrites them.

The optional `tui` block (not part of the recommendation — add it yourself if
you want it) selects a dark theme and a native status line built from
Polytoken's own modules:

```yaml
version: 3
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

This replaces Claude's executable `statusline.sh` (cwd, git, agent, PR, model,
context %, cost, rate limits). The native status line uses Polytoken's
documented modules; PR status, dollar cost, and subscription rate-window are
**not** reproduced because Polytoken has no documented module for them.

#### Native replacements for Claude-only mechanisms

Polytoken has native facilities for several things Claude implements with
custom scripts, so the Polytoken target does not install the Claude versions:

- **Status line** — Claude's `statusline.sh` → Polytoken's native `tui.status-line` modules (above).
- **Agent working/idle state** — Claude's `hooks/agent-state.sh` (writes a badge the status line reads) → Polytoken's native facet/agent state shown in its own UI.
- **Agent join / orchestration status** — Claude's `agent-join/` hook (emits an `<orchestration-status>` block so the main session can correlate Agent subagent work by id) → Polytoken's native job system, sidebar, and auto-drained completion notifications. There is no `agent-join` hook or ledger in the Polytoken target.

#### Wrapped hook families (canonical logic, shared with Claude)

The native wrapped hooks run the **same canonical policy logic** as the Claude
hooks through a thin adapter (`hooks/adapter.sh`) that translates Polytoken's
event input and decision output. They are installed as named entries merged
into your `hooks.json`:

| Name | Event | Wraps |
|---|---|---|
| `git-safe` | `pre_tool_use` (`shell_exec`) | `compat/git-safe/hook.sh` |
| `no-remote-writes` | `pre_tool_use` (`shell_exec`) | `compat/hooks/no-remote-writes.sh` |
| `read-once` | `pre_tool_use` (`file_read`) | `compat/read-once/hook.sh` |
| `read-once-reset` | `post_compaction` | `compat/read-once/compact.sh` |

`branch-guard` and `bash-guard` ship in `compat/` but are not registered by
default: the hook transport cannot distinguish a linked-worktree checkout from
the main checkout, so `branch-guard` would deny every legitimate worktree
commit, and `bash-guard` remains under evaluation for false-positive risk.
Direct-`main` commits are governed by facet and project rules; wire these
guards manually only for single-checkout setups where that tradeoff is wanted.

Polytoken deliberately does not install skill-once or its compaction reset. Its tool-hook contract does not guarantee per-agent identity, so session-scoped deduplication could deny a skill based on another agent's context. Failing open allows repeated bodies but never strands an agent. Polytoken's native `skill` tool accepts only a name, so no `--force` syntax is claimed or supported.

Fresh Polytoken installs do not copy `compat/skill-once`. Upgrades leave existing compatibility scripts untouched but remove exact legacy managed `skill-once` hook registrations; customized registrations require confirmation or `--overwrite`.

#### Canonical shared skills

`home/skills/` is one canonical tree installed into both targets. The skills
are written to be accurate in either harness where it matters — for example,
`agent-orchestration` documents both the Claude Code (Agent/SendMessage,
`agent-join`) and Polytoken (`subagent`, `job_block`/`job_result`,
auto-drained) workflows side by side, and `git-workflow` names both Claude's
`Bash` and Polytoken's `shell_exec`.

#### Negating a global hook per-project

Hooks are installed at the **global** config root. A project may negate an
installed global hook **by name** using Polytoken's native per-project hook
negation mechanism (e.g. add a same-named entry that disables it in the
project's own hook config). The global installer never edits project hook
files.

#### Large-read policy

`large-read-guard` denies unbounded reads of regular `.diff`, `.patch`, and `.log` files larger than 50 KiB (51,201 bytes), and other regular files larger than 250 KiB (256,001 bytes). Reads with a positive `max_bytes`, or a non-negative `offset` plus positive `limit`, are bounded and allowed. The hook uses filesystem metadata only, follows one symlink to its target, and fails open for missing, unreadable, dangling, directory, special-file, or stat-race cases so the authoritative Read error remains visible. It is separate from `read-once`.

#### Known limitations (Polytoken target)

- **read-once is advisory-inert under Polytoken until `READ_ONCE_MODE=deny`
  is set.** The canonical `read-once` hook defaults to `warn` mode: on a
  repeated read it allows the read *and* attaches an advisory reason
  ("…already in context, ~X tokens…"). Polytoken's `pre_tool_use` **`allow`**
  outcome has no `reason` field (only `deny` carries one), so the adapter
  emits a bare `{"outcome":"allow"}` and the advisory is discarded. Net effect:
  with the shipped default, the `read-once` hook permits every re-read and the
  de-duplication nudge never reaches the model — it provides no context savings
  under Polytoken until you opt into hard enforcement. To get real de-dup,
  set `READ_ONCE_MODE=deny` in the read-once hook's environment (e.g. in your
  shell profile or `hooks.json` handler).
- **rtk under Polytoken is rules-only.** rtk's savings only materialize when the
  model uses `rtk grep` (via `shell_exec`) rather than the built-in `grep`, and
  Polytoken cannot transparently rewrite commands the way Claude's
  `rtk-rewrite.sh` does (`pre_tool_use` allows/denies only). The built-in `grep`
  tool remains available for structured searches (multiple roots, `include`,
  `context_lines`).
- **Subagent hook probes are unavailable in this environment.** The installed
  controller rejected both implementer and review-lane probes before session
  creation because those facets were unregistered, so ordinary subagent hook
  execution could not be tested. The implementer/review-lane prompt contracts
  retain the bounded-search and ranged-read protections as the supported guard.

## Merge behavior

Both targets merge structured files **one patch at a time**. For each
difference — a new key, a changed value, or a recommended hook you don't have
yet — it prints the detail and asks `[y/N]` (Enter skips the change — keeps
your value, declines new keys). Arrays (e.g. `availableModels`) are treated as
a single unit.

- **Interactive (default):** each patch is accepted or declined individually.
- **`--overwrite` / `CLAUDE_CONFIG_OVERWRITE=1`:** accepts every recommended patch without prompting, but never deletes unrelated user entries.
- **No TTY:** applies only **additive** patches (new keys, new hooks) and keeps
  your values on any conflict, with an actionable diagnostic naming the
  conflicts.

A file is backed up to `<file>.bak-<timestamp>` only when the merged result
actually differs from what was there; an unchanged file is left alone and no
backup is created. Re-running is safe — idempotent installs report
"unchanged"/"up-to-date" and create no new backups.

Per target, the merge targets are:

- **Claude** — `settings.json` (generic keys plus per-event hook additions; your permissions block is never touched).
- **Polytoken** — `config.yaml` (provider-neutral leaf values; providers/models preserved), `hooks.json` (merged by unique `name`: add missing names, preserve unrelated hooks and their order, treat a same-name entry with a different event/matcher/handler as a conflict, never install duplicate names; fresh installs do not copy `compat/skill-once`, while upgrades remove exact legacy managed `skill-once` registrations and preserve customized ones unless confirmed or `--overwrite` is supplied), `permissions.yaml` (left untouched when it exists).

Every structured write is rendered to a temporary file, parsed and validated
(including in-context `polytoken config validate --user` for the Polytoken
target), backed up only if changed, then atomically renamed over the
destination. A validation failure removes the staging file and leaves the
original intact. `AGENTS.md` is not structurally merged: it is installed when
absent, left alone when identical, and prompted before backing up and replacing
when it differs.

### Claude settings reference

The merged `env` keys: `ANTHROPIC_MODEL=opus` and
`CLAUDE_CODE_SUBAGENT_MODEL=sonnet` set the main/subagent models;
`ANTHROPIC_DEFAULT_*_MODEL` pin specific model IDs (current as of this repo's
date — bump them as new models ship); `MAX_THINKING_TOKENS` and
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` tune thinking budget and autocompact
threshold.

## Optional add-ons

- **`defaultMode: acceptEdits`** — auto-accepts file edits. Not merged by default
  (it weakens an edit-safety prompt). Add it to `settings.json` yourself if you
  want it.
- **gitprompt** — `statusline.sh` uses [`gitprompt.pl`](https://github.com/magicmonty/bash-git-prompt)
  if it's on `PATH` or pointed to by `$CLAUDE_STATUSLINE_GITPROMPT`; otherwise it
  falls back to plain `git` for the branch + dirty flag. (Polytoken's native
  status line does not use gitprompt.)

## Companion tools (install separately)

These are referenced by or complement this config but are not bundled:

- **[superpowers](https://github.com/obra/superpowers-marketplace)** — the
  skill framework `git-workflow` defers to for branch/PR/worktree mechanics.
- **rtk** — read/grep/test output compressor. **Claude Code:** if installed,
  wire its hook — add `{ "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/.claude/hooks/rtk-rewrite.sh" } ] }`
  to `hooks.PreToolUse` (script ships with rtk); the rules live in `CLAUDE.md`.
  **Polytoken:** wired via `AGENTS.md` rules only — the model uses `rtk grep`
  (content search) and `rtk <framework>` (tests/build). There is no hook:
  Polytoken's `pre_tool_use` can only allow/deny, so it cannot rewrite a command
  the way Claude's `rtk-rewrite.sh` does.
- **cavemem** — memory MCP + hooks. If installed, add its `mcpServers` entry and
  `UserPromptSubmit`/`PostToolUse`/`Stop`/`SessionStart`/`SessionEnd` hooks per
  cavemem's docs.
- **tk** — minimal local ticket system.
- **herdle** — cross-project work dashboard built on `tk`.
- **discord-pt-stream + `discord-bridge/`** — attach-only Discord control
  surface for Polytoken sessions. The Mac host runs as a launchd agent via
  `discord-bridge/setup-bridge-host.sh` (dedicated 0600 env, KeepAlive, PATH
  incl. podman); connectors auto-start in every dev container via the
  `bridge-connector-autostart` `session_start` hook. See
  [`discord-bridge/README.md`](discord-bridge/README.md) and the
  `polytoken-container/.env.example` bridge section.
