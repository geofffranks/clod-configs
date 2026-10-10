# Jira dispatcher runtime (maintainer notes)

The dispatcher is a single-host Python 3.9+ service. `mcp_client.py` implements the non-LLM Streamable HTTP MCP subset (JSON and `text/event-stream` responses, heartbeat/`retry` frames, session headers); `jira.py` owns LAP lifecycle calls; `state.py` holds the durable SQLite journal and effort claims; `launch.py` starts and inspects headless Polytoken workers; `workers.py` parses the approved queued plan comment and builds the worker brief; `dispatcher.py` provides service and operator commands.

`jira.py` detects the gateway tool surface at session start. Against the real Ratatoskr gateway (whose tool surface is `tool-details`/`execute`, not raw upstream names) it calls upstream Atlassian tools via generated `execute` scripts, honors the per-session `tool-details` inspection requirement (read-only probe fallback for safe tools), and projects offloaded results (`Execution ID:` summaries) with sliced follow-up scripts to avoid re-offloading loops. Search pages stay small (default page_size 10, no `comment` field) and comments are fetched per candidate ticket. Lightweight fakes that expose upstream tools directly exercise the same lifecycle logic through the direct surface.

## Run and test

No third-party Python packages are required. Run the local-only checks from the repository root:

```sh
bash scripts/test-jira-dispatcher.sh
```

Tests use a loopback ephemeral-port fake MCP gateway, a fake daemon HTTP server, a subprocess `polytoken` shim, and temporary state. They cover the full queued lifecycle end to end (admission, In Progress transition selection, launch, supervision, Awaiting Acceptance plus delivery report), preservation and blocker handling, attempt caps, resume including a fresh-worker fallback after a failed `polytoken continue`, stop/pause controls, uncertain-spawn adoption, and preflight read-only sampling, plus restart idempotence. They do not contact Jira, the real Ratatoskr gateway, session daemons, or perform Jira writes. `python3 -m py_compile` runs as part of the harness.

To initialize configuration, run `python3 jira-dispatcher/dispatcher.py init-config`. Review the generated `config.json` and set `active` to `true` only after preflight and an operator-controlled runtime verification. Commands are `run [--once]`, `status`, `pause`, `resume`, `stop`, `preflight`, and `init-config`; `--state-dir` and `--config` support isolated environments.

## Configuration and state

Default state/config location is `~/.local/share/polytoken/jira-dispatcher/` (`state.sqlite3`, `config.json`). The database uses SQLite WAL and durable effort/journal/control rows. Config specifies the gateway URL, Jira project and custom Project field, repository mappings, allowed issue types, active concurrency limit, poll/launch timeouts, transient retry cap, `max_blocker_attempts`, `question_grace_polls`, and per-path `transition_names`. The default question grace is zero; Jira is the decision channel. Supervision runs on the launch poll interval. Repo paths and transition-name list shapes are validated when loading config.

The dispatcher only admits supported issue types in Ready with a readable `## Approved delivery plan` comment whose Delivery mode is `queued`, configured Project mapping, satisfied `Depends on:` tickets (Done), and no local ownership conflict. It owns lifecycle transitions; workers do not change Jira status. Uncertain outcomes are retained for reconciliation rather than replaying writes.

## Supervision and recovery

Each poll supervises active nonterminal efforts, re-fetching Jira state/comments and reconciling retained sessions before interpreting worker outcomes. Durable `ready_transition` and `spawn` intents are replayed only after fresh status/session checks; an already-achieved transition or uniquely correlated live session is adopted rather than repeated. Mechanical launch failures retry up to `transient_retry_cap`; exhaustion attempts a Jira Blocked transition and a marked recovery-escalation comment so the effort is visible. Uncertain writes are reconciled by status or comment markers before retry; unresolved Jira write failures remain `recovery_pending` for a later poll. Awaiting Acceptance holds its lane until a supervised Jira read observes the human-set status Done or Canceled; retirement is observe-only and never transitions Jira. A daemon exit is not delivery proof: only a newer structured worker completion report with explicit checks, review, and Git facts can trigger Awaiting Acceptance and the deduplicated delivery report. Pending questions and worker blocker reports require preservation verification before the dispatcher transitions the issue to Blocked. Ready tickets resume only after a newer Jira reply; a retained session is preferred, and blocker-attempt counts are preserved. The reply ID and resume prompt are persisted before a fresh launch. `pause` holds admission while supervision continues; `stop` detaches supervision and leaves daemons alive; `resume` clears both controls. Control flags are checked immediately before transitions, comments, worker spawn, continue, and prompt delivery; once a control is observed, the next visible operation is not begun.

`preflight` checks `polytoken models` presence and performs read-only gateway/Jira discovery and transition sampling when reachable. Per allowed issue type it verifies type metadata, and per required path it samples one ticket in each state — an outcome line is printed per check as OK/pending, and absent tickets produce pending warnings, never passes. Translation between sampling and operator setup readiness is the checklist below.

## Intentional limits

This is not runtime verification against LAP Jira or a real gateway. No distributed scheduling, approval ledger, byte/hash verification, automatic Done transition, automatic worktree creation, automatic termination of sessions, push/merge authority, or deployment is implemented. Operator activation still requires reviewing the generated configuration, workflow transition metadata, credentials/session retention, repository mappings, and recovery behavior against the real LAP environment.
