---
name: jira-workflow
description: Canonical Jira discovery, scoped authority, issue bookkeeping, transition and process-friction workflow. Load before Jira work; access grants no write authority.
---

# Jira workflow

## Authority before operations

Jira is the current issue/workflow authority for consumers of this contract.
A ticket, assignment, skill grant, tool permission, direct invocation, or available
transition is not approval to write or implement.

- Read-capable roles may inspect Jira within their assigned scope.
- Bookkeeping (create, edit, comment or link) requires an explicitly designated
  `project-manager` or `workflow-project-manager` with bounded issue/project,
  action and field scope and retained operator approval evidence. Alternatively,
  the operator may explicitly authorize a named actor for that bounded scope.
  Role membership alone is not a standing grant. Deletion is not baseline
  bookkeeping and requires separate explicit authorization.
- Transitions require separately explicit actor/transition authority and the
  required approval evidence for the exact issue and current plan revision.
  Bookkeeping permission never implies transition permission.
- Delegates receive the exact scope, actions, limits and approval evidence;
  delegation cannot broaden authority. Direct invocation without this evidence
  is read-only. Missing, stale or ambiguous evidence means stop and surface the
  proposed operation, not perform it. There is no standing friction-write carve-out.
- Repository implementation approval and Jira write approval are independent.
  This skill does not authorize repository work, remote writes or workflow administration.

## Gateway and metadata discovery

Use only `ratatoskr`: list servers, list the selected upstream's tools, inspect
each tool schema, then execute through the gateway. Never use a direct MCP
connection or shell/API fallback. Reconnect only after authentication/token expiry.
If access or a needed tool is unavailable, report the limitation and stop the
operation; do not substitute a local tracker as authority.

Read the actual issue/project and current type first. Discover project issue
types and all pages of field metadata for that type (including optional fields,
not just required fields). Distinguish field display names from IDs, system
Project from the custom Project selector, allowed values from arbitrary strings,
and create metadata from edit/transition requirements. Resolve IDs/options live;
do not copy volatile IDs from examples. Inspect create/edit/comment/link schemas
before preparing payloads. Metadata alone does not prove custom-field write
encoding or editability. Unknown required payloads block the write; omit an
unsupported optional field and report the limitation rather than inventing data.

## Issue types and intake

- Epic: related outcomes/work grouped at a higher level.
- Story: user-facing goal or capability.
- Bug: product defect, with expected/actual behavior and reproduction evidence.
- AI Workflow: proposed agent/harness workflow change and its scope/evidence.
- Process Friction: recurring or material process/tool/approval obstacle, not a
  product defect and not implementation authorization.
- Task: distinct work not better represented above; Subtask: bounded work under
  a valid parent. Their presence in metadata is not permission to create them:
  use only when the explicitly approved scope permits that type and hierarchy.

For planning intake, require the project's evidence-backed mapping to its
planning-ready state. For implementation intake, require its evidence-backed
implementation-approved state plus explicit approved scope/plan. No universal
status mapping is defined here: unknown mappings fail closed and are escalated.
Do not infer readiness from a status category, assignment, ticket prose, or an
available transition. Never transition a ticket merely to make intake pass.

## Lookup and scoped bookkeeping

Before creation, search by project, issue type, stable identity and semantic
variants of the symptom/outcome; inspect plausible matches, including resolved
issues. Use the inspected search tool appropriate to the query (JQL when using
JQL). Search failure is not evidence of no duplicate. If a match exists, surface
its key and proposed disposition; do not create another. A comment/edit/link on
that match still requires its own bounded write authority.

For authorized creation, verify required fields, type, project and duplicate
check, submit only approved fields through the inspected schema, retain the
returned key, then fetch that key directly (search indexing may lag). For edits,
read current values first and preserve unrelated content. For comments/links,
verify the target and any link direction. After any authorized write, reread
relevant fields and report observed results separately from requested changes.
Never claim success from a submitted request alone or repeat an uncertain write
without checking whether it already took effect.

## Transitions and approval

Immediately before a separately authorized transition, reread the issue and
fetch its currently available transition objects, including transition fields.
Select the intended live transition by both its name and destination status;
these need not match. Verify required fields and approval evidence. Send exactly
the ID/name/object shape required by the inspected transition tool, not a guessed
status label. If unavailable, stale, ambiguous or missing required fields, stop
and request the authorized actor's resolution. Do not bypass conditions or choose
another transition just because it is available. After execution, fetch the issue
and verify destination status; report mismatch without automatic retries.

## Process-friction baseline

Capture a stable `friction-key` derived from repository/workflow boundary and
root symptom, not a session ID, timestamp or transient error wording. Preserve
observed evidence, impact, reproduction/context and proposed disposition. Search
that key and semantic variants before proposing a Process Friction issue.
Keep pending observations in the session record when no authorized writer is
available; pass them to the scoped PM without implying permission to sync.

Lifecycle: observe and identify; check duplicates; propose new or matched issue;
triage with evidence; implement only under separately approved scope; verify the
remedy; request the authorized lifecycle transition. Existing resolved matches
need human/authorized disposition, not automatic reopen or duplicate creation.
Count is not readiness. Systematic recurrence/count/session-field mutation,
Jira-resident record automation, hooks and a triage facet are outside this baseline.

## Dated read-only evidence and limits

On 2026-09-25, gateway reads for LAP listed Epic, Story, Bug, AI Workflow,
Process Friction, Task and Subtask. All seven required Issue Type, system Project
and Summary for creation; Subtask also required Parent. Optional Agent Sessions
appeared on Task, Story, Bug, AI Workflow and Process Friction; Reporting Agent
and Count appeared on Bug and Process Friction; Design appeared on Bug,
AI Workflow and Process Friction. These observations are not permanent field rules.
Agent Sessions' custom array metadata does not establish its write payload.

LAP-94 (AI Workflow) was Plannable; available transitions included Approve Plan
→ Ready, Done → Done and Cancel → Canceled, with empty transition-field maps.
This is an example of transition/destination distinction, not an approved intake
mapping for every type. Representative reads also observed: Epic LAP-4,
Plannable, Approve Plan → Ready; Story LAP-36 and Bug LAP-100, Ideas,
Accept for Planning → Plannable; AI Workflow LAP-96, Done, only Done/Cancel;
Process Friction LAP-98, Plannable, Plan Complete → Done alongside Done/Canceled;
Subtask LAP-3, To Do, Start → In Progress. All returned transition-field maps
were empty. No Task representative was returned. These per-issue snapshots do
not enumerate all workflow states or establish approved intake mappings.
Custom-field write payloads remain unverified. No write or post-transition
readback was performed for this evidence.

The retained dcs-retribution herdle workflow is an explicit repository exception;
this migration does not change its shared runtime gatekeeper or lifecycle policy.
