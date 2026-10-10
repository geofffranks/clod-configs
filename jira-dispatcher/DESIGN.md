# Jira-driven unattended dispatch — implementation spec

Approved plan (session 0d5mf3-glide) drives this work. This file is the shared
source of truth for the dispatcher runtime, the queued-registration facet, the
installer and the operator doc. It is working design documentation retained in
the effort workspace; README.md under docs/ carries the operator-facing content.

 Geoff designs and approves. A durable native laptop service selects approved
LAP work in Jira rank order and runs existing delivery agents unattended,
escalating on Jira only when necessary. No approval ledger, no byte
verification, no extra approval gate, no distributed scheduler, no per-poll
model calls.

## Runtime mechanics (verified on this laptop)

- Ratatoskr gateway: Streamable HTTP MCP at `http://127.0.0.1:8910/mcp`
  (loopback-only per gateway source; no gateway client Authorization header;
  the polytoken client registration confirms `headers: {host: localhost:8910}`).
  Configure inside the MCP protocol, not HTTP auth.
- Mid-stream worker daemons: `polytoken --working-dir <dir> new --no-attach
  --facet <facet> --prompt <text>` spawns a daemonized session and prints
  `session_id=<id> port=<port>`; bearer token at
  `<sessions-v1>/<id>/credential.json` (`chmod 600`). All per-session daemon
  control is plain HTTP with `Authorization: Bearer <token>`:
  GET /health, GET /state, POST /prompt, POST /interrogative/{id}/respond,
  GET /events, POST /terminate. `polytoken continue <id> --no-attach` resumes
  a retained session headlessly. `polytoken reap` only kills unattached
  daemons. The OpenAPI surface is `polytoken print openapi`.
- Real session IDs only; never invent labels.
- Trusted same-user model: any process running as the same user can read daemon
  credential files (`chmod 600`) and control sessions. Writers of Jira plans and
  replies, including the operator's readable queued plans, are trusted authority
  inputs under this model; no additional gate is introduced here.

## Layout

```
jira-dispatcher/
  DESIGN.md             this file
  dispatcher.py         service + control entrypoint (run/status/pause/resume/stop/preflight/init-config)
  mcp_client.py         non-LLM Streamable HTTP MCP client (initialize/tools list/tools call)
  jira.py               LAP lifecycle ops over mcp_client (search/fetch/transition/comment/reconcile)
  launch.py             worker session launch, supervision, preserve/continue/reconcile
  state.py              SQLite durable transactional state + control flags
  config.py             config load/validate (repo mappings, limits, active switch)
  workers.py            worker brief construction (prompt text fed to the delivery facet)
  README.md             implementation/administration notes for maintainers
scripts/install-jira-dispatcher.sh
launchd/dev.gf.polytoken-jira-dispatcher.plist
scripts/test-jira-dispatcher.sh
docs/jira-dispatcher.md
```

State lives outside Git: `~/.local/share/polytoken/jira-dispatcher/`.
Runtime persistence is SQLite state (`state.sqlite3`, including effort records,
controls and the journal) and captured spawn/output data, not per-effort log
directories or pause/stop flag files. The directory also holds editable
`config.json`; see `README.md` for current capture and recovery details.
Installer copies runtime into `~/.local/share/polytoken/jira-dispatcher/lib/`
and installs a reversible LaunchAgent (`launchctl bootstrap/unload` guarded),
modeled on `scripts/install-session-watchdog.sh` conventions.

## Jira contract (non-LLM dispatcher side)

Allowed types: Story, Bug, Task, AI Workflow. Never Process Friction, Epic or
Subtask. Discover live issue-type names, status names and transition IDs via
`getJiraProjectIssueTypesMetadata` + `getTransitionsForJiraIssue`; match BOTH
transition name AND destination status; never hardcode IDs; never route one
type through another type's workflow. Missing paths are pending, never mocked.

Custom Project (observed `customfield_10043`) maps a configured value to a
canonical repo:
- `lappie` → `/Users/gfranks/workspace/track-data-collection`
- `appium-mcp` → `/Users/gfranks/workspace/appium-mcp`
Validate values and paths at preflight and read field values per ticket; a
ticket whose value or path is not configured is not eligible (leave it alone,
record why in dispatcher status output).

Roles:
- Dispatcher owns transitions: Ready → In Progress (at launch, after fresh
  fetch + transition metadata), In Progress → Blocked (on unresolved blocker,
  after confirming preservation), In Progress → Awaiting Acceptance (after
  verified delivery). It also posts: blocker comments, delivery-report
  comments. It never moves Ideas/Plannable/Done/Canceled.
- Registration facet (interactive, driven by product-design) owns: publishing
  the approved plan as a readable comment and Plannable → Ready. Its comment
  format is `## Approved delivery plan` first-level label plus `Git:`,
  `Delivery mode:`, `Review panel:`, `Source branch:`, `Effort branch/workspace:`,
  `Depends on:` lines. That readable text + Ready is the whole contract.
- Workers (project-manager / quick-delivery facet) own: real work, checks,
  review, Git finalization on the approved branch/worktree, completion comment.

Eligibility for unattended launch (all must hold at poll time):
1. Supported type + configured Project value + configured repo path.
2. Status == Ready.
3. Approved plan comment present (label match above, non-empty, includes Git
   and review panel choices).
4. `Depends on:` keys' actual outcomes satisfied — referenced ticket status is
   Done (verified by fetch, never an agent claim); acceptance-dependent work
   waits for the real prerequisite state.
5. Repo not owned: at most one active queued effort per canonical repo; no
   ticket of that repo in In Progress owned by someone else (live `polytoken
   sessions` project-path scan + Jira In Progress scan of mapped repos); adopt
   never, terminate never.
6. Global default max one active unattended ticket (configurable) and rank
   order selection (JQL `ORDER BY Rank` with client-side stability).

Writes reconcile before retry: after every transition/comment, re-fetch and
verify; on uncertain outcomes (timeout/gateway hiccup) verify actual state by
key + comment search before any retry. No duplicate comments. Answer delivery
uses state-serialized response content and verifies the daemon outcome before
marking it delivered; uncertain responses stay pending for reconciliation.
See `README.md` for the current response and recovery behavior.

## Worker delivery flow

Launch sequence transactionality: insert effort row + pending transition →
transition Ready → In Progress (reconcile) → spawn worker → mark running.
Persist launch intent (state row staged as `launching`) BEFORE the daemon spawn;
record the session id and captured spawn/output data when available, not a
per-effort log file. Reconcile uncertain response
against actual sessions (registry `polytoken sessions --all`) + credential
file + /health before any retry launch. Reconcile is idempotent: an existing
live session for the same ticket/effort is adopted as supervisor state and
never terminated.

The worker brief (workers.py, embedded in the first prompt) references the
ticket key with approved plan and instructs: unattended queued delivery; you
work in the approved effort workspace (worktree created only by pre-approved
plan choices — dispatcher never creates worktrees); commit partial intended
work regularly to the approved branch; never push, never merge without explicit
plan authority; use lappie/appium-mcp project procedures for device/integration
resources; resource conflicts or unsatisfied admission prerequisites → report
blocker, do not proceed; at completion post completion comment incl. actual
required checks/reviews/Git finalization and remaining manual checks; pending
question (daemon turnstile) auto-reserves/jira-blocker recording; cap on 3
problem attempts; consult proper downstream reasoning channels for blockers
and then, with advice, one bounded new approach; on never-exhausted unresolved
blocker → report blocker outcome.

Supervision: poll loop emits dispatch steps; a losing loop iteration ends
open options: completed (verified worker report + review signature present on
branch), blocker (question/blocker or retry-exhausted), uncertain (lost
acknowledgment — schedule immediate reconcile: sessions/worktree + ticket
status verify answers). Worker daemon stop/level is not delivery proof: verify
effort journey by Jira comments + the branch/worktree reality for the
dispatcher-owned transitions; never treat the model's narrative as the record.

Blocking (before transition): prefer retained stoppable worker session +
retained workspace; otherwise insist (worker brief) commits preserved partial
work; dispatcher verifies session id decode + workspace/branch presence
(never auto-commits: no fabricated commits, no secrets). Then transition and
comment: reason, exact decision needed, session id, branch/worktree/commits,
checks/review state and remaining limits, remaining work, recovery advice.
If Jira write or preservation fails → durable pending-recovery row with
retaining state. Uncertainty holds the assigned slot (never independently
reassign).

Resume: Blocked → Ready (operator) plus relevant reply comment newer than the
blocker comment and referencing the effort roadmap; prefer original session
resume `polytoken continue <session_id> --no-attach` then POST /prompt with
the reply text and plan resumption; else fresh session seeded with retained
state summary (branch/topology, remaining work). No speculation about an
unanswered turnstile: unanswered turnstile ≠ resume.

A Blocked interactive effort returned to Ready must NOT be enqueued for
unattended execution: dispatcher recognizes route markers (registration comment
contains `Delivery mode: queued` required to ever enqueue) and never enqueues
interactive-delivery plans.

## Retry / attempt counters

Per effort in SQLite: current_stage, launch attempts (transient failures
retry ≤ config (default 3)), blocker_attempt count (worker problem-solving
attempts, surfaced in resume brief), completed checks and reported outcomes,
pending Jira side effects, last reconcile/recovery notes. Counters survive
restart and unblock; never reset by renaming/reslicing; worker change
(resume vs fresh) does not reset. Exhaustion → block with status; escalating
observer counts; never loops on simple Ready moves without relevant reply.

## Controls and preflight

- `dispatcher.py run [--once]` main loop; refuses live-ticket processing while
  config `active: false` (installer default); `preflight` validates it
  without processing.
- `status` — active/waiting/blocked/uncertain efforts, counters, process info.
- `pause`/`resume` — hold admission but keep supervision (SQLite control rows).
- `stop` — graceful; no new admission; marks supervision detached for running
  efforts, leaves daemons alive; `run` picks them up again idempotently.
- `init-config` writes default config.json with editable mappings/limits.
- Preflight checks: python3/polytoken/git present; ratatoskr loopback
  reachable (MCP initialize); Jira/Atlassian resource discovery; configured repo
  paths exist as Git repos; state dir writable; `polytoken models`
  (non-exhaustive). Live transitions are sampled from available tickets;
  missing samples or paths remain pending outcomes, not proof of per-type
  workflow coverage. Verify every required path for Story, Bug, Task and
  AI Workflow separately, plus configured Project values and effective
  permissions, before activation. See `README.md` for current sampling behavior.
- Installer: `--print` renders plist; `--uninstall` unload+remove; checks
  dependencies fail-closed. Operate responsibly at the end.

## Facet / guidance updates (agent-workflow-engineer)

- New facet `polytoken/facets/queued-registration.md`: after native design
  acceptance, publish the approved plan comment exactly per contract above,
  move Plannable → Ready for queued route OR (interactive route) move
  Plannable → In Progress at actual implementation start and hand off
  immediately to project-manager/quick-delivery without queue enrollment.
  No implementation of any kind. Validate with `polytoken validate facet`.
- Update `polytoken/facets/product-design.md` routing: before native approval
  handoff, choose queued (register + Ready) or interactive (direct In Progress
  actual start) explicitly. Jira handoff targets queued-registration, carrying
  the eventual delivery facet, source branch and approved workspace choices;
  never fall through a Ready route into delivery. Without Jira, retain the
  direct native delivery handoff.
- Update `partials/workflow-common.j2` lifecycle line: include Awaiting
  Acceptance receipt (results + remaining manual checks, never Done).
- Preserve existing useful lifecycle text; do not rewrite the file.

## Testing

`scripts/test-jira-dispatcher.sh`: local-only tests (no Jira writes, no network
except 127.0.0.1): shell syntax, python -m compileall/py-syntax, unit fixtures
over a fake gateway + fake registry as before, state transactions/admission
matrix (type/project/status/plan/dependency/ownership), launch reconcile /
double-launch protection, comment marked dedupe, transition metadata retry,
config-invalid behavior, installer copy checks via `--print`. Focused checks
only — no mandatory manifest, no applicaion suites run.

## Out of scope

Byte/hash verification, separate approval registry, upstream receipt machinery,
distributed scheduler, automatic Done, deployment, physics device experiments,
Jira automation (outside initial scope), Discord channel (never).
