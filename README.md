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

One fail-open Pushover notifier serves both harnesses. With no credentials
configured it is fully inert: hooks still succeed, nothing is sent, nothing
blocks. Credentials are read from the environment only — never from files this
repo manages — and must never be committed:

```bash
export PUSHOVER_APP_TOKEN=your-application-token
export PUSHOVER_USER_KEY=your-user-key
```

#### What alerts you

| Surface | Alert | Notes |
|---|---|---|
| Claude Code: turn ends needing input, or a `Notification` fires | one consolidated push after ~60s | your next prompt cancels the pending send |
| Polytoken: end of turn awaiting you | same consolidation + cancel | suppressed while a saved-session goal is active (the goal driver continues without you) |
| Polytoken: `ask_user_question` pending | push with the first question's text | your answer cancels it; ambient/background notifications cancel rather than add |
| Polytoken: TUI or container killed (SIGKILL) | "abnormal exit" push | at most one per 15s window, with the affected-session count; normal quits, Ctrl-C/TERM/HUP exits, and TUI launch failures stay silent |
| Polytoken: plan-handoff approval pending, goal-acceptance pending, goal completed | one push each | requires the optional SSE watcher (below); everything else on the stream — cancellations, provider errors, ambient events — stays silent |

Titles carry the session title (or "Agent"); bodies carry `repo/branch:` plus
a bounded, sanitized preview. No transcript text beyond the bounded preview
ever leaves the machine.

#### Installing

```bash
./install.sh --target claude       # Claude Code hooks (UserPromptSubmit/Stop/Notification)
./install.sh --target polytoken    # native Polytoken hooks (see below)
./install.sh --target all          # both, independently
```

- **Claude Code**: `home/` is copied into `CLAUDE_CONFIG_DIR` (default
  `~/.claude`) and `settings.recommended.json` adds the three
  `agent-notify.sh claude` hooks (Stop and Notification run async). The script
  reads its session id from the event JSON and the repo/branch from the
  transcript's working directory.
- **Polytoken**: `agent-notify.sh polytoken` is installed into
  `POLYTOKEN_CONFIG_DIR` (default `~/.config/polytoken`) and `hooks.json`
  gains the `agent-notify`, `agent-notify-cancel` (pre_user_prompt),
  `agent-notify-stop` (stop), `agent-notify-ask` (pre_tool_use on
  `ask_user_question`), `agent-notify-answer` (post_tool_use), and
  `session-watchdog-keepalive` entries. Hooks load at the next session start
  or config reload. The session id comes from `POLYTOKEN_SESSION_ID`, and
  repo/branch resolution follows the session log's most recent working
  directory, so worktree sessions still name their repo.

#### Configuring credentials

- **Non-dockerized (native) Polytoken and Claude Code**: export both variables
  in the environment that launches the harness (shell profile, LaunchAgent
  environment, and so on). Hooks inherit it.
- **Dockerized Polytoken** (`polytoken-container/run.sh`): put the two exports
  in the env file run.sh injects — `POLY_ENV_FILE`, default
  `~/.config/polytoken-container.env`:

  ```bash
  echo 'export PUSHOVER_APP_TOKEN=your-application-token' >> ~/.config/polytoken-container.env
  echo 'export PUSHOVER_USER_KEY=your-user-key' >> ~/.config/polytoken-container.env
  ```

  Each container session's hooks run inside the container with that env, so
  alerts work per session with no host-side daemon.

#### Death alerts (lifecycle shipper)

- **Dockerized**: built into `polytoken-container/run.sh` — its cleanup path
  records how the container ended and sends the abnormal-exit alert when the
  container was SIGKILLed. Nothing extra to run.
- **Native**: opt-in — launch sessions with the wrapper instead of bare
  `polytoken`: `bash home/bin/polytoken-notify-wrapper.sh new` (same arguments;
  exit status and foreground behavior are preserved). Without the wrapper,
  native sessions have no death alerts.

Both lanes append a `notify-exit-record/v1` JSON line per launch — native to
`~/.local/share/polytoken/notify-exit/`, container to the host store
`~/.local/share/polytoken-dev/notify-exit/` (dir 700, file 600, size-capped).
Records whose timestamps could not be rendered faithfully carry
`"ts_fidelity":"degraded"` and never alert.

#### Optional SSE watcher (approvals + goal completion)

`home/lib/notify-event-watcher.sh` is a per-host loop that discovers live
session daemons (`sessions/*/startup.json`), follows each daemon's `/events`
stream, and pushes on plan-handoff approvals, goal-acceptance approvals, goal
completion, and questions. It ships without an installer **by design** — start
it manually. Note on questions: the ask hook (above) and the watcher do not
share dedup state, so with both active an unanswered question can alert twice
— immediately from the watcher, and once more from the hook's ~60s
consolidation if it is still pending (answering cancels the hook's send). If
you prefer single-alert questions, either skip the watcher's question mapping
or uninstall the `agent-notify-ask` entry.

```bash
nohup bash /path/to/claude-config/home/lib/notify-event-watcher.sh >/dev/null 2>&1 &
```

Knobs: `NOTIFY_WATCHER_SESSIONS_DIR` (sessions root to watch — for
containerized sessions run the watcher where the daemon's loopback port is
reachable and point this at that container's sessions root),
`NOTIFY_WATCHER_POLL_SECONDS` (5), `NOTIFY_WATCHER_FRESH_SECONDS` (120).
Events older than 120s, future timestamps, clock discontinuities, and any
event outside the four mappings are silently ignored.

#### Session watchdog ("Agent Died" scan)

A host-side scan pushes "Agent Died" when a Polytoken session's daemon dies
mid-work (a crash or replacement kills the process that would run hooks, so a
host-side watcher is the only sensor). It runs as a macOS LaunchAgent
(`scripts/install-session-watchdog.sh`) scanning every 30s. Each daemon keeps a
continuously-updated liveness journal beside its log at
`~/.local/share/polytoken/logs/<started-at>-<pid>.liveness.jsonl` (the paired
`<started-at>-<pid>.log` names the session it served).

**Per-session liveness.** A session is treated as **alive** when *any* of its
liveness journals is fresh. When a daemon is replaced, the old daemon's
leftover journal lingers beside the new one; this per-session alive check means
a live session is never re-armed or re-pinged because a stale sibling exists
(this stopped a recurring "Agent Died" flood from a stale leftover journal
re-queuing a death every scan). Only when *every* journal for a session is
stale is a death evaluated, and it pings at most once per episode (then
tombstoned).

**Suppression knobs:** `WATCHDOG_IDLE_LIMIT` (a daemon that died while the
session was already long idle stays silent), `WATCHDOG_MASS` (many simultaneous
deaths read as one host/container event), a boot-grace first scan, and a
3-attempt send retry.

**Stale-journal cleanup.** Long-stale leftover journals for dead daemons are
purged automatically (`WATCHDOG_PURGE_OLD_DAYS`, default 7, 0 disables). A live
session's journal is never removed — a journal is purged only when its session
has no fresh journal. Manual cleanup for a specific leftover journal:

```bash
rm -f ~/.local/share/polytoken/logs/2026-09-14T00-08-58Z-10.liveness.jsonl \
      ~/.local/share/polytoken/logs/2026-09-14T00-08-58Z-10.log
```

**Silence immediately** (stop the scan loop; it resumes at the next
session_start keepalive):

```bash
kill $(cat $HOME/.local/share/polytoken/.session-watchdog/loop.pid) 2>/dev/null
```

That `kill` targets the keepalive-spawned loop (containers/Linux, which write
`loop.pid`). On a native macOS LaunchAgent install there is no loop or
`loop.pid`; pause the scan instead with:

```bash
launchctl unload ~/Library/LaunchAgents/dev.gf.polytoken-session-watchdog.plist  # pause
launchctl load -w   ~/Library/LaunchAgents/dev.gf.polytoken-session-watchdog.plist  # resume
```

#### Diagnostics and verification

- Sender decisions (sent/rejected/no-creds): `~/.local/share/polytoken/logs/notify/notify.log`
  (bounded, rotated; `source|event|session|result|http_status`).
- SSE adapter decision log: `~/.local/share/polytoken/logs/notify-adapter/notify.log`.
- Exit records: `notify-exit/notify-exit.log` in either data root.
- Test suites: `bash scripts/test-agent-notify.sh`,
  `scripts/test-notify-exit-record.sh`, `scripts/test-notify-libs.sh`,
  `scripts/test-notify-adapter.sh`, `scripts/test-notify-event-watcher.sh`,
  `scripts/test-session-watchdog.sh`, `scripts/test-watchdog-keepalive.sh` —
  all run offline with mock senders and assert no network egress.

### Requirements

| Dependency | Used by | Notes |
|---|---|---|
| **bash 4+** | Claude status line (`mapfile`) | macOS ships bash 3.2 — install a newer one via Homebrew. |
| **jq** | both targets | settings/hooks merge and JSON processing. |
| **mikefarah/yq v4** | Polytarget YAML merge | the Go-based `yq`; the Python `yq` wrapper does **not** support the required `eval-all` + `*` deep-merge and is rejected. |
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
| `hooks.json` | `polytoken/hooks.json` | Nine native hooks, including the metadata-only `large-read-guard`. Skill-once is omitted because per-agent hook identity is unavailable. |
| `AGENTS.md` | `polytoken/AGENTS.md` | Polytoken-native global instructions (Polytoken tool names), incl. rtk guidance (`rtk grep` for content search, `rtk <framework>` for tests/build; rules only — no hook). |
| `facets/` | `polytoken/facets/` | The `workflow-designer`, `workflow-project-manager`, `product-design`, and `project-manager` workflow facets described below. |
| `subagents/` | `polytoken/subagents/` | Managed built-in and workflow-specialist roles, including `agent-workflow-architect` and `agent-workflow-engineer`. |
| `skills/` | `home/skills/` | The same canonical skills tree shared with Claude. |
| `compat/` | `home/{bash-guard,branch-guard,git-safe,grep-guard,large-read-guard,read-once}` + `home/hooks/no-remote-writes.sh` | Canonical hook scripts installed under `compat/`; a fresh install does not copy `compat/skill-once`. |

#### Agent-workflow design and delivery

Use `workflow-designer` when you want to turn a desired AI-workflow behavior
into an implementation plan. It can inspect the project, consult the read-only
`agent-workflow-architect` and other read-only specialists, compare approaches,
and edit a saved plan. It cannot directly modify the project. Because Polytoken
does not restrict subagent names per facet, its promise to dispatch only
read-only roles is a prompt rule rather than a runtime security boundary.

Before implementation, the designer sends the saved plan to
`agent-workflow-architect` for one bounded workflow review covering plan
coherence and scope, authority, approval, delegation, MCP routing, host
boundaries, usability, operational risks, and compliance with the requested
design. Blocking findings are fixed or rebutted and the revised plan receives a
fresh architect rereview before the designer presents it to the operator and
waits for approval. After approval it hands the plan to `workflow-project-manager`; it
cannot switch facets itself. Directly invoking `workflow-project-manager` is also
supported and authorizes the requested execution, but it does not prove that a
plan was reviewed or approved. Delivery reports that provenance honestly.

`workflow-project-manager` implements the approved scope, normally through the
write-capable `agent-workflow-engineer`, with these gates:

- material changes to scope, permissions, approval, delegation, or MCP routing
  return to `workflow-designer` for renewed approval;
- multi-file, executable, high-risk, or dirty-tree work uses a feature branch
  and isolated worktree; a small clean-tree prompt/config/docs edit may stay in
  place;
- checks are selected by the actual consumed contract: Markdown instructions
  receive independent content review and scenario walkthroughs; machine-
  consumed configuration receives parser/CLI/schema and effective-runtime
  validation; executable production behavior receives risk-based executable
  checks and TDD only when required;
- executable replicas of prompt policies are not created solely to unit-test
  prose, and new validation infrastructure requires a concrete contract,
  failure, simpler-alternative, and limitation justification;
- substantive work gets an independent workflow-architecture review, with a
  second fresh review when authority, permissions, autonomous behavior,
  approval gates, delegation, destructive capability, or MCP routing changes;
- pushing and other remote writes always require separate operator action.

Reviewers are routed to one bounded question and named evidence. They identify
risks and missing evidence rather than prescribing unit tests by default.

The second workflow pair is `product-design`, which plans the product approval
lifecycle and hands off via an approved plan to `project-manager`, which
 delivers it. These four are the global facets claude-config ships.

All four facets pin `zai/glm-5.3-flash(high)` with fallback
`codex/gpt-5.6-luna-1m(medium)`. The workflow pair uses Ratatoskr-gateway-only
MCP (`mcp__ratatoskr`); the product pair uses `tag!ALL_MCP` per configured
upstream server, with `product-design` also exposing `mcp_list_resources` and
`mcp_read_resource`. The gateway itself runs on the Mac, including when
Polytoken runs in the Linux container.

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

The seven native hooks run the **same canonical policy logic** as the Claude
hooks through a thin adapter (`hooks/adapter.sh`) that translates Polytoken's
event input and decision output. They are installed as named entries merged
into your `hooks.json`:

| Name | Event | Wraps |
|---|---|---|
| `bash-guard` | `pre_tool_use` (`shell_exec`) | `compat/bash-guard/hook.sh` |
| `branch-guard` | `pre_tool_use` (`shell_exec`) | `compat/branch-guard/hook.sh` |
| `git-safe` | `pre_tool_use` (`shell_exec`) | `compat/git-safe/hook.sh` |
| `no-remote-writes` | `pre_tool_use` (`shell_exec`) | `compat/hooks/no-remote-writes.sh` |
| `read-once` | `pre_tool_use` (`file_read`) | `compat/read-once/hook.sh` |
| `read-once-reset` | `post_compaction` | `compat/read-once/compact.sh` |

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
  controller rejected both implementer and reviewer probes before session
  creation because those facets were unregistered, so ordinary subagent hook
  execution could not be tested. The implementer/reviewer prompt contracts
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
