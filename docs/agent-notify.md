# Attention notifications (agent-notify)

The notify stack pings you when an agent run needs you or has died. It is
dual-channel on a native macOS host — the local **Notification Center**
(credential-free, on by default) plus the optional **Pushover** push; both fire
for the same event, and you can mute Notification Center per-app if you only
want Pushover. Everywhere the mac lane is unavailable (non-macOS, the Linux
container, or `AGENT_NOTIFY_MAC=0`) the stack is fully fail-open: hooks still
succeed, nothing is sent, nothing blocks. Pushover credentials are read from
the environment only — never from files this repo manages — and must never be
committed.

Three sensors cooperate:

- **Hooks** (both harnesses): end-of-turn, questions, and Claude `Notification`
  events, consolidated to avoid ping floods.
- **SSE event watcher** (Polytoken): daemon-level events hooks cannot see —
  plan-handoff and goal approvals, goal completion, and questions.
- **Session watchdog** (Polytoken): a host-side scan that catches a dead
  daemon — the one failure that kills the hooks themselves.

## Install

`--notify-hook-only` installs *just* the notification stack — none of the
guards, skills, statusline, instruction files, facets, or subagents:

```bash
./install.sh --notify-hook-only --target all
```

This is the primary way to get notifications. It is idempotent (a re-run
reports "unchanged" and writes no backups), and a later full install
(`./install.sh --target all`) cleanly adds the remainder through the normal
merge prompts.

- **Under Claude Code** the notify-only install is exactly:
  `hooks/agent-notify.sh` + `lib/notify-mac.sh` (the credential-free mac
  sender) + the three `agent-notify.sh` hook entries in `settings.json`.
- **Under Polytoken** it is the notify files (`hooks/agent-notify.sh`,
  `hooks/session-watchdog.sh`, `hooks/watchdog-keepalive.sh`,
  `hooks/notify-watcher-keepalive.sh`, and the `lib/notify-*.sh` set) plus the
  managed notify hook entries in `hooks.json` — seven names, or five on a
  native macOS host where the LaunchAgent owns the death scan (below).

`--containerized-polytoken` (only together with `--notify-hook-only`) tells the
installer your sessions run in containers: it skips the macOS LaunchAgent and
installs the session-start keepalive hooks instead, so the death scan and the
SSE watcher run in-container with the session.

Dependencies: the notify-only install needs **jq** and **curl** only (the
Notification Center lane needs nothing beyond macOS itself). It does **not**
need `mikefarah/yq v4` — that requirement belongs to full Polytoken installs
(YAML merges). Dependencies are gated fail-closed: a notify-only install
without `jq` aborts with a clear error instead of silently skipping the merge.

## What alerts you — under Claude Code

| Event | Alert | Notes |
|---|---|---|
| Turn ends needing input, or a `Notification` fires | one consolidated push after **~3 minutes** | your next prompt cancels the pending send; a newer event replaces the queued one |

Hook wiring (from `home/settings.recommended.json`): `agent-notify.sh claude`
runs on `UserPromptSubmit` (cancel lane) plus async `Stop` and `Notification`
entries. The delay default is `AGENT_NOTIFY_DELAY=180` seconds; all timing
coverage in tests uses explicit fractional overrides.

Every alert renders the same identity in the title —
`<repo>[/<branch>] (<session-id>)[ - <session-title>]`, falling back to
`(<session-id>)` when a session has no project identity — and every body opens
with a canonical `[source:type]` tag from a fixed, closed vocabulary:

| Tag | Sender | Meaning |
|---|---|---|
| `[hook:needs_input]` | agent-notify hook | one consolidated attention alert (all its trigger events share it) |
| `[sse:question_pending]` | SSE watcher | `ask_user_question` awaiting an answer |
| `[sse:approval_pending]` | SSE watcher | plan-handoff or goal-acceptance approval pending |
| `[sse:goal_completed]` | SSE watcher | goal driver completed |
| `[watchdog:agent_died]` | session watchdog | daemon died mid-work |
| `[watchdog:tui_crash]` | session watchdog | TUI panic |
| `[shipper:tui_abnormal_exit]` | lifecycle shipper | TUI/container SIGKILLed |

The watcher's diagnostic-log source stays `event-watcher` — body tag `sse`
corresponds to diagnostic source `event-watcher`. No transcript text beyond
the bounded preview ever leaves the machine — the same title and tagged body
reach both Notification Center and Pushover.

Under Claude Code there is no session watchdog and no SSE watcher; the death
alerts and watcher sections below are Polytoken-side (the manual nohup path is
noted where it applies).

## What alerts you — under Polytoken

| Event | Alert | Notes |
|---|---|---|
| End of turn awaiting you | same consolidation + cancel as Claude | suppressed while a saved-session goal is active (the goal driver continues without you) |
| `ask_user_question` pending | push with the first question's text (`agent-notify-ask`) | your answer cancels it (`agent-notify-answer`); an ambient notification (background job / subagent completion) cancels rather than adds |
| TUI or container killed (SIGKILL) | "abnormal exit" alert | at most one per 15s window with the affected-session count; normal quits, Ctrl-C/TERM/HUP exits, and TUI launch failures stay silent |
| Plan-handoff approval pending, goal-acceptance pending, goal completed | one alert each | sent by the SSE event watcher (below) — everything else on the stream stays silent |
| A turn is cancelled (any reason, including self-initiated) | immediate "turn cancelled — reason" push, one per cancelled prompt | sent by the SSE event watcher (below); no rate cap — N distinct cancels mean N pushes; cancels older than 120s stay silent (envelope staleness) |
| A command is held at the permission gate | "permission needed: <tool>" push, one per gate episode | sent by the SSE event watcher (below); body names the tool only, never the command arguments |

### Unified notification format

All notification lanes share the same session-aware title and canonical body tags; the SSE watcher's pushes receive that treatment too.

Hook wiring (from `polytoken/hooks.json`): `agent-notify` (notification),
`agent-notify-cancel` (pre_user_prompt), `agent-notify-stop` (stop),
`agent-notify-ask` and `agent-notify-answer` (pre/post_tool_use on
`ask_user_question`), plus the `session-watchdog-keepalive` and
`notify-watcher-keepalive` session-start entries. The session id comes from
`POLYTOKEN_SESSION_ID`, and repo/branch resolution follows the session log's
most recent working directory, so worktree sessions still name their repo.

**About double question alerts:** the ask hook and the watcher do not share
dedup state, so an unanswered question can alert twice — immediately from the
watcher, and once more from the hook's ~3-minute consolidation if it is still
pending (answering cancels the hook's send). If you prefer single-alert
questions, remove the `agent-notify-ask` entry from your `hooks.json`; a
watcher-side knob is a tracked backlog opportunity, not a shipped option.

The watcher and hook lanes are likewise independent for cancellations: a
cancelled turn can produce both the watcher's immediate cancel push and, if the
hook lane's stop timer had already armed, its delayed "needs input" notice — no
cross-lane suppression, by design.

## Credentials

- **Notification Center (macOS)**: needs **no credentials**. On by default
  whenever the hooks run natively on a mac (`AGENT_NOTIFY_MAC=0` disables the
  lane). The first alert may require approving a per-app Notification Center
  permission dialog (attributed to whatever process runs `osascript`); until
  approved, macOS may silently suppress the banners.
- **Pushover (optional)**: export both variables in the environment that
  launches the harness (shell profile, LaunchAgent environment, and so on):

  ```bash
  export PUSHOVER_APP_TOKEN=your-application-token
  export PUSHOVER_USER_KEY=your-user-key
  ```

- **Dockerized Polytoken** (`polytoken-container/run.sh`): put the two exports
  in the env file run.sh injects — `POLY_ENV_FILE`, default
  `~/.config/polytoken-container.env`:

  ```bash
  echo 'export PUSHOVER_APP_TOKEN=your-application-token' >> ~/.config/polytoken-container.env
  echo 'export PUSHOVER_USER_KEY=your-user-key' >> ~/.config/polytoken-container.env
  ```

  Each container session's hooks run inside the container with that env, so
  alerts work per session with no host-side daemon.
- **Session watchdog LaunchAgent**: with no credentials in the environment,
  the installer wires `~/.config/polytoken/watchdog.env` (chmod 600) instead —
  the watchdog sources it on every scan.

## Death alerts (lifecycle shipper)

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

## Session watchdog (daemon-death and TUI-crash scan)

A host-side scan alerts when a Polytoken session's daemon dies mid-work. A
crash or replacement kills the process that would run hooks, so a host-side
watcher is the only reliable sensor. The title names the session
(`repo/branch (session-id) - title`, falling back to `(session-id)`); the body
carries the glanceable lead-in:
`[watchdog:agent_died] Agent died — <project>: <last text> (last activity Nm
ago)`. It runs as a macOS LaunchAgent
(`scripts/install-session-watchdog.sh`, invoked automatically by
`install.sh` on native macOS) scanning every 30s. Each daemon keeps a
continuously-updated liveness journal beside its log at
`~/.local/share/polytoken/logs/<started-at>-<pid>.liveness.jsonl` (the paired
`<started-at>-<pid>.log` names the session it served). A TUI panic alerts as
`[watchdog:tui_crash] TUI crashed — …` under the same claim/retry model.

On a native mac the watchdog delivers through the same dual channel as the
hooks: Notification Center first (credential-free, so it works with no
Pushover account), plus Pushover when credentials are configured. The mac lane
sends once per episode; only Pushover owns the retry counter (3 attempts), so
a failed mac send never re-arms an episode. Both the watchdog and agent-notify
require `jq` even in mac-only mode (it enriches titles/bodies) — the
LaunchAgent plist ships a `PATH` that includes `/opt/homebrew/bin` and
`/usr/local/bin`, so make sure `jq` is reachable there. **Stale installs:** an
already-installed copy of `session-watchdog.sh` / `agent-notify.sh` keeps its
old single-channel behavior until you re-run the installer.

**Per-session liveness.** A session is treated as **alive** when *any* of its
liveness journals is fresh. When a daemon is replaced, the old daemon's
leftover journal lingers beside the new one; this per-session alive check means
a live session is never re-armed or re-pinged because a stale sibling exists.
Only when *every* journal for a session is stale is a death evaluated, and it
pings at most once per episode (then tombstoned).

**Suppression knobs:** `WATCHDOG_IDLE_LIMIT` (default 600s — a daemon that died
while the session was already long idle stays silent), `WATCHDOG_MASS` (many
simultaneous deaths read as one host/container event), a boot-grace first scan,
and a 3-attempt send retry. Environment (all optional): `WATCHDOG_LOG_DIR`,
`WATCHDOG_SESSIONS_DIR`, `WATCHDOG_STATE_DIR`, `WATCHDOG_ENV_FILE`,
`WATCHDOG_LOOP_INTERVAL` (30s keepalive cadence),
`WATCHDOG_LIVENESS_STALE` (90s scan / 180s keepalive-spawned loops).

**Stale-journal cleanup.** Long-stale leftover journals for dead daemons are
purged automatically (`WATCHDOG_PURGE_OLD_DAYS`, default 7, 0 disables). A live
session's journal is never removed. Manual cleanup for a specific leftover:

```bash
rm -f ~/.local/share/polytoken/logs/2026-09-14T00-08-58Z-10.liveness.jsonl \
      ~/.local/share/polytoken/logs/2026-09-14T00-08-58Z-10.log
```

**Where the scan runs — scheduler decision table.** On stock macOS there is no
`flock`, so a keepalive hook cannot spawn a scan loop; without the LaunchAgent
there is **no death scan** on macOS.

| Setup | Death scan | Keepalive hook entries |
|---|---|---|
| Native macOS (default) | LaunchAgent, installed automatically by `install.sh` | not installed |
| Containerized sessions (`--containerized-polytoken`, or any non-macOS host) | in-container keepalive loop, ensured by the `session_start` keepalive entries | installed |
| Mixed (native Mac + container sessions) | run `--containerized-polytoken` **and** `bash scripts/install-session-watchdog.sh` manually once; both sensors coexist and the dedup state is shared, so a death pings once | installed |

**Mac-side scanning of container sessions.** Container journals are
host-visible through the `run.sh` bind mount under
`~/.local/share/polytoken-dev`. To have the Mac LaunchAgent scan them too,
point it at the container data root in `~/.config/polytoken/watchdog.env`:

```bash
WATCHDOG_LOG_DIR="$HOME/.local/share/polytoken-dev/logs"
WATCHDOG_SESSIONS_DIR="$HOME/.local/share/polytoken-dev/sessions"
```

**Silence immediately** (stop the keepalive-spawned scan loop; it resumes at
the next session start):

```bash
kill $(cat $HOME/.local/share/polytoken/.session-watchdog/loop.pid) 2>/dev/null
```

On a native macOS LaunchAgent install there is no loop or `loop.pid`; pause
the scan instead with:

```bash
launchctl unload ~/Library/LaunchAgents/dev.gf.polytoken-session-watchdog.plist  # pause
launchctl load -w   ~/Library/LaunchAgents/dev.gf.polytoken-session-watchdog.plist  # resume
```

## SSE event watcher

`lib/notify-event-watcher.sh` adds what hooks cannot see: daemon-level session
events. It discovers live session daemons (`sessions/*/startup.json`), follows
each daemon's `/events` stream with the Bearer scheme, and pushes on exactly
six mappings — questions (`question_pending`), plan-handoff approvals and
goal-acceptance approvals (`approval_pending`), goal completion
(`goal_completed`), turn cancellations (`turn_cancelled`), and permission-gate
holds (`approval_pending`). Agent-raised permission-gate holds arrive without a
sequence number; the watcher processes them cursorless with freshness checks and
permanent per-episode claims, so reconnect re-renders do not double-push. The
daemon never announces operator-facing approval popups, so those cannot push.
Everything else on the stream — provider errors, ambient events, heartbeats —
stays silent. This is not cruft: no hook fires for these daemon transitions.

**Event coverage**

| Event on the stream | Push | Once per |
|---|---|---|
| `ask_user_question` | "N questions need your answer" (+ first question) | question episode |
| plan-handoff approval (interrogative) | "approve plan handoff" | handoff episode |
| goal-acceptance approval (interrogative) | "accept goal proposal" | proposal episode |
| permission gate held by an agent (interrogative[permission], arrives without a sequence number) | "permission needed: <tool>" | gate episode |
| `goal_driver_update` completed | "goal completed: ..." | goal |
| `turn_cancelled` (any reason) | "turn cancelled — <reason>" | cancelled prompt |

Everything else on the stream stays silent (heartbeats, `hook_fired`, `session_idle`, `stream_discontinuity`, provider noise); operator-facing TUI approval popups are not announced on the stream, so they cannot push.

**Under Polytoken the watcher is ensured-running by default**: the
`notify-watcher-keepalive` session-start hook spawns one detached supervision
loop (flock-serialized, stale-pid checked, fail-soft) that re-runs the watcher
if it ever exits (`NOTIFY_WATCHER_LOOP_INTERVAL`, default 30s). Its pidfile
and loop log live under the agent-notify state root
(`$POLYTOKEN_CONFIG_DIR/.agent-notify/`). On a native macOS install the
keepalive entries are not installed (no `flock`); run the watcher manually
instead:

```bash
nohup bash "${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}/lib/notify-event-watcher.sh" >/dev/null 2>&1 &
```

Knobs (inherited by the keepalive-spawned watcher unchanged):
`NOTIFY_WATCHER_SESSIONS_DIR` (sessions root to watch — for containerized
sessions run the watcher where the daemon's loopback port is reachable and
point this at that container's sessions root), `NOTIFY_WATCHER_POLL_SECONDS`
(5), `NOTIFY_WATCHER_FRESH_SECONDS` (120), `NOTIFY_WATCHER_FUTURE_TOLERANCE`
(5), `NOTIFY_WATCHER_CLOCK_TOLERANCE` (5), `NOTIFY_WATCHER_SENDER`,
`NOTIFY_WATCHER_LOOP_LOG`. The first frame seen baselines the cursor
(pre-connect history is never notified); events older than 120s, future
timestamps, clock discontinuities, and unmapped event types are silently
ignored. One alert per episode: an atomic claim is taken before any send, so
re-fires and re-renders are no-ops.

See the double-alert note in the Polytoken section for the known question
interaction between this watcher and the ask hook.

## Diagnostics and verification

- Sender decisions (sent/rejected/no-creds): `~/.local/share/polytoken/logs/notify/notify.log`
  (bounded, rotated; `source|event|session|result|http_status`).
- SSE adapter decision log: `~/.local/share/polytoken/logs/notify-adapter/notify.log`.
- Exit records: `notify-exit/notify-exit.log` in either data root.
- Watcher keepalive loop: `$POLYTOKEN_CONFIG_DIR/.agent-notify/notify-watcher-loop.log`.
- Watchdog state: `~/.local/share/polytoken/.session-watchdog/`; logs at
  `~/Library/Logs/polytoken-session-watchdog.log` on a LaunchAgent install.
- Test suites: `bash scripts/test-agent-notify.sh`,
  `scripts/test-notify-watcher-keepalive.sh`,
  `scripts/test-notify-exit-record.sh`, `scripts/test-notify-libs.sh`,
  `scripts/test-notify-adapter.sh`, `scripts/test-notify-event-watcher.sh`,
  `scripts/test-session-watchdog.sh`, `scripts/test-watchdog-keepalive.sh` —
  all run offline with mock senders and assert no network egress.
- Raw SSE frames for watcher debugging: `bash scripts/capture-sse-experiment.sh --list`,
  then `bash scripts/capture-sse-experiment.sh <session-dir> --max-seconds 120`
  appends verbatim `data:` frames to a timestamped JSONL (no processing, no sends).
