# Jira dispatcher runtime (maintainer notes)

The dispatcher is a single-host Python 3.9+ service. `mcp_client.py` implements the non-LLM Streamable HTTP MCP subset; `jira.py` owns LAP lifecycle calls; `state.py` holds the durable SQLite journal and effort claims; `launch.py` starts and inspects headless Polytoken workers; `workers.py` parses the approved queued plan comment and builds the worker brief; `dispatcher.py` provides service and operator commands.

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

Each poll supervises `launching` and `running` efforts through the retained daemon API and reconciles missing sessions against live-session records. A daemon exit is not delivery proof: only a newer worker completion comment on the Jira ticket can trigger Awaiting Acceptance and the deduplicated delivery report. Pending questions and worker blocker reports require preservation verification before the dispatcher transitions the issue to Blocked. Ready tickets resume only after a newer Jira reply; a retained session is preferred, and blocker-attempt counts are preserved. If `polytoken continue` fails, the dispatcher records the failure and falls back to a fresh worker seeded with the same reply, approved plan excerpt, and preservation notes; a failed fresh launch remains `recovery_pending`. `pause` holds admission while supervision continues; `stop` detaches supervision and leaves daemons alive; `resume` clears both controls.

`preflight` checks `polytoken models` presence and performs read-only gateway/Jira discovery and transition sampling when reachable. Missing ticket samples or transition paths are reported as pending warnings.

## Intentional limits

This is not runtime verification against LAP Jira or a real gateway. No distributed scheduling, approval ledger, byte/hash verification, automatic Done transition, automatic worktree creation, automatic termination of sessions, push/merge authority, or deployment is implemented. Operator activation still requires reviewing the generated configuration, workflow transition metadata, credentials/session retention, repository mappings, and recovery behavior against the real LAP environment.
