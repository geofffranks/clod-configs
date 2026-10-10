# Jira-driven unattended delivery

The dispatcher is a native laptop service that selects approved LAP work in Jira
rank order and runs the existing `project-manager` or `quick-delivery` facet.
Geoff still designs and approves the work. A readable approved plan plus Ready
is the approval contract; there is no separate approval ledger, byte/hash check,
extra approval gate or per-poll model call.

The dispatcher does not design products, create worktrees, adopt someone else's
activity, terminate unrelated sessions, grant push/merge authority, or mark work
Done/Canceled. Workers use the approved workspace, Git disposition and review
panel. Process Friction, Epic and Subtask are excluded from unattended dispatch.

## Install without activating

From the source checkout on macOS:

```sh
bash scripts/install-jira-dispatcher.sh --print  # inspect only
bash scripts/install-jira-dispatcher.sh          # install inactive default
```

Installation requires `python3`, `git` and `polytoken` on PATH, plus macOS
`launchctl` and `plutil`. It copies all runtime Python files, DESIGN.md and
README.md from `jira-dispatcher/` to
`~/.local/share/polytoken/jira-dispatcher/lib/`, creates
`~/.local/share/polytoken/jira-dispatcher/config.json` only if absent, and installs
`~/Library/LaunchAgents/dev.gf.polytoken-jira-dispatcher.plist`. Existing config is
never overwritten, including its activation setting: do not reinstall an active
service expecting installation to pause it. Coordinate any running work before
reinstalling. No provider, quota, MCP, facet or session-daemon settings are changed
by this installer. Install the source facets through your existing Polytoken
configuration installation procedure separately.

**Installation is not activation. Keep the dispatcher inactive until you
explicitly activate it. Source merge, installation and operational activation
are separate actions.** Inspect the mappings, limits and live workflow paths,
then run preflight:

```sh
python3 ~/.local/share/polytoken/jira-dispatcher/lib/dispatcher.py preflight
```

After preflight succeeds and you decide to admit queued work, edit
`~/.local/share/polytoken/jira-dispatcher/config.json` and set `"active": true`.
Preflight itself never processes live tickets. An inactive default does not
permit live-ticket processing.

Remove only the service registration:

```sh
bash scripts/install-jira-dispatcher.sh --uninstall
```

Uninstall unloads/removes the LaunchAgent but retains runtime, config, state,
logs and worker sessions. Use `stop` first for a graceful supervision detach;
uninstall is not a worker cancellation command.

## Controls and service lifetime

Run these against the installed runtime:

```sh
python3 ~/.local/share/polytoken/jira-dispatcher/lib/dispatcher.py status
python3 ~/.local/share/polytoken/jira-dispatcher/lib/dispatcher.py pause
python3 ~/.local/share/polytoken/jira-dispatcher/lib/dispatcher.py resume
python3 ~/.local/share/polytoken/jira-dispatcher/lib/dispatcher.py stop
python3 ~/.local/share/polytoken/jira-dispatcher/lib/dispatcher.py preflight
python3 ~/.local/share/polytoken/jira-dispatcher/lib/dispatcher.py init-config
```

- `status`: inspect active/waiting/blocked/uncertain efforts, attempt counters and
  process information before changing ownership or retrying operations.
- `pause`/`resume`: hold/reopen admission; pause keeps supervision of existing
  efforts. Resume admission is not activation and does not answer a worker's
  pending question.
- `stop`: admit no new work, gracefully detach supervision and leave worker
  daemons alive. A later `run` reconciles retained efforts rather than launching
  duplicate workers.
- `init-config`: create an editable default configuration. It is not activation;
  retain and edit your existing config rather than replacing it.
- `run`: the long-running polling loop; `run --once` performs one cycle. Do not
  start a second loop alongside the LaunchAgent.

The LaunchAgent starts `python3 .../lib/dispatcher.py run` at load/login using
PATH with `~/.local/bin`, `/opt/homebrew/bin` and standard system paths. There is
no launchd polling interval: the runtime owns cadence. `KeepAlive=false` means
launchd does not promise automatic restart after a crash or graceful stop. To
start an installed, registered service again after checking status/ownership:

```sh
launchctl kickstart gui/$(id -u)/dev.gf.polytoken-jira-dispatcher
```

Do not add `-k`: this is not permission to kill an existing dispatcher. Laptop
sleep suspends local supervision; it does not guarantee background progress or
notifications. On wake/restart, the intended recovery is to reconcile SQLite
state, real sessions, workspace/branch and Jira before resuming admission. Lost
acknowledgments retain the assigned slot until resolved. Restart, unblock or
fresh worker selection must not reset attempt counters.

Logs go to `~/Library/Logs/polytoken-jira-dispatcher.log`. Persistent state under
`~/.local/share/polytoken/jira-dispatcher/` includes `config.json`, `state.sqlite3`,
per-effort logs and persisted control flags; `lib/` holds the installed runtime.
Treat state and logs as private operational data; do not commit them to Git.

## Configuration and admission

The runtime-generated `config.json` under the state directory is the editable
schema source. Validation is fail-closed; a config whose mappings point at
missing paths is rejected with a non-zero exit. Configure:

- `active`: activation switch, default false. Setting it true is the operator's
  explicit activation step.
- `jira_project` (`LAP`) and `custom_project_field`
  (`customfield_10043`, the observed custom Project field). This is distinct from
  Jira's system project. Its observed API shape is `{id, self, value}`; match the
  option's value, not the object or option ID.
- `repo_mappings`: `lappie` → `repo_path`
  `/Users/gfranks/workspace/track-data-collection` and `appium-mcp` →
  `/Users/gfranks/workspace/appium-mcp`. Validate configured values and canonical
  Git-repository paths before activation. Other values and untagged tickets are
  ineligible and are left alone with a status explanation.
- `allowed_types`: Story, Bug, Task, AI Workflow. Process Friction, Epic and
  Subtask are forbidden and rejected.
- Limits: `max_global_active` (default 1), one queued effort per canonical repo,
  `transient_retry_cap` (default 3), `max_blocker_attempts` (default 3),
  `question_grace_polls` (default 0), `launch_poll_interval_seconds` (default
  300) and `launch_timeout_seconds` (default 3600). Counters persist across
  restart and unblock. Review budgets and Git choices remain those approved in
  the plan, not dispatcher defaults.
- `transition_names`: candidate transition names per lifecycle path used to
  match live metadata; `ready_to_inprogress` ships empty as pending. Names may
  vary; live destination-status matching decides, and IDs are never hardcoded.
- `gateway_url`: loopback MCP `http://127.0.0.1:8910/mcp`. This does not grant
  gateway reconfiguration, reconnect or service-restart authority.

Global CLI options: `--once` for a single run cycle, `--state-dir`, `--config`
for a non-default config path, `--facet` for the worker delivery facet (default
`quick-delivery`), and `--polytoken` for the polytoken executable. The approved
plan's delivery mode and review panel govern the worker either way.

Only Story, Bug, Task and AI Workflow in Ready with a complete approved-plan
comment marked `Delivery mode: queued` may be admitted. The plan carries `Git:`,
`Review panel:`, `Source branch:` and `Effort branch/workspace:`. Add `Depends on:`
only for actual dependency keys; each must be fetched and really Done before
admission. Ready plus the uploaded plan suffices; no extra receipt is needed.
Unknown activity in a mapped repo blocks admission rather than being adopted.
For example, the observed LAP-29 In Progress is non-queued existing activity;
it is not a worker for the dispatcher to take over.

The accepted rank query is:

```jql
project = LAP AND issuetype IN ("Story","Bug","Task","AI Workflow") ORDER BY Rank ASC
```

## Jira workflow setup checklist

Operator-owned workflow setup verification remains pending until preflight
passes against live metadata. Verify **every path for each type separately**;
a sampled Story path is not proof of Bug, Task or AI Workflow support. Transition
names may vary. Discover live metadata, match both transition name and destination
status, satisfy required fields, and never hardcode transition IDs. Global Done
or Cancel is not a shortcut for a missing path.

| Required path | Story | Bug | Task | AI Workflow | Owner/use |
|---|---|---|---|---|---|
| Plannable → Ready | [ ] | [ ] | [ ] | [ ] | Registration after approved queued plan publication |
| Plannable → In Progress | [ ] | [ ] | [ ] | [ ] | Interactive direct start; bypass Ready |
| Ready → In Progress | [ ] | [ ] | [ ] | [ ] | Dispatcher at queued launch |
| In Progress → Blocked | [ ] | [ ] | [ ] | [ ] | Dispatcher after preservation is verified |
| Blocked → Ready | [ ] | [ ] | [ ] | [ ] | Operator; named Unblock by the operator |
| In Progress → Awaiting Acceptance | [ ] | [ ] | [ ] | [ ] | Dispatcher after verified delivery receipt |
| Awaiting Acceptance → Done | [ ] | [ ] | [ ] | [ ] | Human acceptance decision only |

Configure board columns so **Blocked** and **Awaiting Acceptance** are visible
and mapped to those statuses. Confirm that workflow configuration, screens,
required fields and permissions allow the intended users/service account to
perform each path. Missing paths remain pending; do not create test transitions
or use another issue type's workflow as a substitute.

### Read-only observations supplied during this effort

Site: `lappie.atlassian.net`; accessible-resource discovery returned cloudId
`84f22174-cb05-43a3-ab5e-1b00ffb36223`. These are observations, not a replacement
for current accessible-resource and workflow discovery.

- Story LAP-129 in Plannable exposed `Approve Plan` → Ready and
  `Approve + Start Interactive Implementation` → In Progress. The direct
  interactive path already exists. It also exposed global Done and
  `Cancel` → Canceled; neither grants terminal authority.
- Story LAP-29 in In Progress exposed `Block` → Blocked,
  `Implementation Complete` → Awaiting Acceptance, and
  `Implementation Failed Needs Re-Planning` → Plannable, plus global Done/Cancel.
- There were no tickets in Ready, Blocked or Awaiting Acceptance. Ready →
  In Progress and Blocked → Ready (`Unblock`) are operator-confirmed but not
  runtime-inspected; verify them through preflight when tickets reach those
  states. Awaiting Acceptance → Done also remains uninspected. Workflow setup
  for all four supported types is not yet established by these samples.
- The rank query was accepted. Across the four allowed types, the supplied
  status counts were Ideas 24, Plannable 10, In Progress 3, Done 32, Canceled 2.
- Observed custom Project values were lappie (11), claude-config (1),
  discord-pt-stream (2), ios-app-dev-mcp (1), and 56 untagged. Do not add mappings
  merely because these values exist. appium-mcp's intended mapping still needs
  live value/path verification.

## Registration, blockers and acceptance

After native design acceptance, choose one route explicitly:

- **Queued:** `queued-registration` publishes the complete readable plan under
  `## Approved delivery plan` with `Delivery mode: queued`, verifies publication,
  then moves Plannable → Ready. The dispatcher owns subsequent admission.
- **Interactive:** publish with `Delivery mode: interactive`, move directly
  Plannable → In Progress at actual work start, then hand off to the selected
  delivery facet without queue enrollment. For an already-Ready ticket,
  coordinate dispatcher ownership and claim/move it out of Ready before work;
  never race an existing or uncertain queued claim.

After a queued blocker, read the comment's decision request and preserved session,
workspace/branch, checks and remaining work. Supply a relevant reply newer than
the blocker comment and referring to that effort, then use Blocked → Ready
(Unblock). A Ready move alone does not answer a question. Resume should prefer
the retained session; a fresh session must carry preserved state and counters.
Interactive plans returned to Ready must remain excluded from unattended admission.

Awaiting Acceptance is the delivery receipt: results, actual checks/review/Git
finalization and remaining manual checks are posted. It is **not Done**. Confirm
those checks and make the human acceptance decision before Awaiting Acceptance →
Done. Done/Canceled and exceptional lifecycle moves remain human decisions.

## Limits and verification

Local tests do not prove live workflow configuration, auth, effective permissions,
model availability, device admission or successful unattended delivery. Preflight
must check loopback MCP initialization, Jira/Atlassian resources, type-specific
live transitions, configured Git repos/values, writable state/effective permissions
and a non-exhaustive `polytoken models` check before activation. Missing metadata,
auth or ownership stays pending, not fabricated success.

Review the [implementation design](../jira-dispatcher/DESIGN.md) and
[maintainer notes](../jira-dispatcher/README.md) for the runtime contract. From the
checkout, the focused local checks are:

```sh
bash scripts/test-jira-dispatcher-facets-install.sh
bash scripts/test-jira-dispatcher.sh
```

These checks do not install into your real home or write to Jira. Operator-owned
live workflow verification, explicit activation and real-run acceptance remain
separate work.
