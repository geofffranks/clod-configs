---
name: jira-workflow
description: Canonical Jira discovery, activated scoped authority, type-aware lifecycle, transferable plans and friction bookkeeping. Load before Jira work; access alone grants no writes.
---

# Jira workflow

## Authority and activation

Jira is the issue/workflow authority for consumers of this contract. A ticket,
assignment, facet activation, tool grant or available transition is not approval
to implement. Repository implementation, commit, merge and remote-write approval
are separate from Jira authority.

The LAP-105–108 policy grants bounded routine Jira authority only after the
operator explicitly approves this policy and its coordinated deployment is
verified: canonical skill, eligible facets and active project consumers must be
installed/reloaded consistently, with effective tool/skill exposure checked.
Retain that activation evidence and policy source revision. Source edits, plan
approval for repository work and partial rollout do not activate the grant.
Until then preserve LAP-94: writes require an explicitly scoped PM or named
actor with retained per-action/field approval; transitions additionally require
explicit transition authority. Missing or conflicting evidence means no write.

After activation, eligible actors are `workflow-designer`, `product-design`,
`workflow-project-manager` and `project-manager`. Each derives active scope from
the current operator-requested or explicitly assigned work: record issue key(s),
project LAP, scope ID, purpose, permitted fields and approval provenance. A
relevant duplicate may be included only for evidence/attribution about that same
work, not unrelated changes. No project-wide authority follows from membership.

| Operation | Story | Bug | AI Workflow | Process Friction | Actor / limit after activation |
|---|---|---|---|---|---|
| Read/search | User capability | Expected/actual/repro | Agent contract | Stable friction-key, evidence/impact | Read-capable scoped roles; include resolved matches |
| Create | Capability and acceptance | Defect and reproduction | Harness/workflow scope | Obstacle, impact, non-authorization warning | All four eligible facets; dedupe and metadata first |
| Scoped edit/comment | Relevant evidence/plan | Relevant evidence/plan | Relevant evidence/plan | Evidence/occurrence/disposition | All four; preserve unrelated content and provenance |
| Add session attribution | Additive only | Additive only | Additive only | Additive only | All four; actual session identity and proven payload/concurrency safety |
| Increment recurrence Count | Not granted | Not granted by this policy | Not granted | Once per new occurrence | All four; occurrence ledger and safe update conditions below |
| Routine lifecycle | Type path below | Type path below | Type path below | Nonstandard resolution below | All four only with exact triggering evidence and live transition |
| Mismatch correction, reopen, cancel, exceptional transition | Ask | Ask | Ask | Ask | Explicit operator decision plus current scoped authority; no automatic repair |
| Delete, workflow administration, unrelated edit | Not granted | Not granted | Not granted | Not granted | Separate explicit authorization; never routine |

Delegates receive at most the caller's exact bounded authority and evidence;
there is no automatic delegation write grant. Design consultation remains
read-only unless separately explicitly authorized within the caller's scope.
Other types (Epic, Task, Subtask), other projects, links and hierarchy changes
need separate bounded authorization. Direct PM invocation is a disclosed bypass
of reviewed handoff, not proof of plan approval: confirm scope, record provenance
as unverified, and never manufacture Ready or an approved plan from invocation.

## Gateway and live discovery

Use only `ratatoskr`: list servers, list selected upstream tools, inspect each
selected schema, then execute. No direct MCP, shell/API Jira workaround or
local tracker substituted as authority. Reconnect only on auth/token expiry.
Denied access or unavailable tools leave the operation pending, not broadened.

Read project/type/status and discover all pages of required AND optional create
metadata. Resolve field IDs, allowed options and hierarchy live; distinguish
system Project from custom Project. Create metadata does not prove editability.
Inspect create/edit/comment/transition schemas and current fields before writes.
Agent Sessions is a custom array and Count numeric: neither establishes a valid
write encoding. Unknown required payload blocks creation; unsupported optional
fields are omitted with explicit pending attribution/count limitations.

Observed selected schemas: create uses `additional_fields`; edit uses `fields`;
comments accept `commentBody`, optional `commentId`, and explicit content format;
transition takes `transition: {id: ...}`. Never reuse volatile IDs. Generic
objects are not proof of custom payload support or atomicity. Do not clear
resolution or use a create-time transition to bypass a lifecycle gate.

## Type-aware lifecycle and mismatch soft gate

Operator mapping in LAP: **Plannable** means ready to plan with the operator;
**Ready** means exact operator-approved plan, ready for implementation. These
are meanings, not Jira status renames. Type-specific observations below are
snapshots, not a full workflow graph or permission to use global Done.

| Type | Planning intake / observed path | Approval / implementation / completion |
|---|---|---|
| Story | LAP-36 Ideas: Accept for Planning → Plannable | Discover approval → Ready and start → In Progress on the actual issue. Design evidence observed Story In Progress: Implementation Complete → Done; refresh before use. |
| Bug | LAP-100 Ideas: Accept for Planning → Plannable | Discover approval → Ready, start → In Progress and intended completion → Done; do not infer transition names from Story. |
| AI Workflow | LAP-105 Plannable: Approve Plan → Ready | Refresh approval transition; discover start → In Progress and intended completion → Done on the actual issue. |
| Process Friction | Earlier LAP-98 Plannable: Plan Complete → Done; fresh LAP-98 is Done with only global Done/Canceled | No proven Ready/In Progress route. Do not force the standard implementation path. Require explicit operator resolution disposition and evidence; a planning resolution is not an implemented remedy. Implementation belongs in a separately approved supported issue/path. |

On planning intake, fetch type/status: Plannable proceeds. For any mismatch,
explain observed versus expected state and consequences; ask whether to make
the appropriate live corrective transition. Declining leaves the issue unchanged
and pauses incompatible work. Accepting does not supply missing authority,
plan approval, evidence or an unavailable transition. Never silently repair.

Lifecycle checkpoints for supported implementation paths:
1. Before requesting plan approval, persist and verify the exact Jira plan record.
2. After explicit operator approval of that revision/digest, record approval and
   use current Approve Plan → Ready (or verified type-specific equivalent).
3. At actual approved implementation start, verify Ready, source identity and
   authority, then use the live intended start → In Progress. Ready alone is
   never implementation permission.
4. Failed validation or material replanning pauses delivery; preserve evidence,
   invalidate superseded approval and request renewed review/approval. Do not
   force a backward transition or claim completion.
5. After required review/validation, operator delivery signoff and confirmed
   merge into the approved target branch, synchronize evidence and use the
   intended In Progress → Done completion transition. An unmerged branch, commit,
   review success or available global Done is insufficient. If merge is not the
   approved disposition, report closure pending an explicit separate disposition.

Immediately before each transition, reread issue and available transition
objects/fields. Select by BOTH name and destination, satisfy required fields,
and send the inspected schema shape. Missing path/fields or ambiguity stops
with a visible disposition and separate operator/admin decision; never invent
states or skip through global Done. Fetch afterward and verify destination.

## Intake, deduplication and attribution

Search project/type/stable identity and semantic variants, including resolved
issues, before creation. Inspect plausible matches. A substantially relevant
match means report key/disposition and add nonduplicative evidence plus actual
current session attribution under scoped authority, rather than create another.
Uncertain similarity or distinct root cause needs human disposition. A resolved
match is not automatic reopening or duplicate creation. Inconclusive search or
indexing is pending, never evidence of no duplicate.

Read current fields before edits and preserve unrelated content. Retain the
created key and fetch directly despite search lag. Reread every write's affected
fields/comments, explicitly requesting custom fields and comments as needed;
default edit responses omit them. Submitted requests are not success evidence.
After timeout/uncertain outcome, reconcile by direct fetch before retrying.

Use the actual current harness session ID from trustworthy session context;
never invent one, use a job ID or overwrite previous sessions. Preserve reporting
actor/facet and session attribution in append-only evidence, without impersonating
the operator or changing unrelated reporter fields. Missing identity leaves
session/count bookkeeping pending and explicitly disclosed.

For Process Friction, stable `friction-key` identifies repository/workflow
boundary and root symptom, not timestamp/transient error wording. Each genuinely
new occurrence also has actual session ID and a stable date/event token. Preserve
this occurrence identity across retries; different events in one session have
different tokens. Mere viewing, retrying or repeated reporting of the same event
never increments Count. Append-only occurrence records retain evidence, actor,
identity and count-update disposition; never erase prior sessions or history.

Before incrementing, reconcile occurrence records and current Count. Unknown,
missing, nonnumeric Count, unsupported payload, incomplete comment history or
unproven concurrent safety leaves the update pending. Do not initialize a guessed
count, reset it or claim deduplication from a partial comment page. Agent Sessions
must be an additive union only with a proven encoding and safe update mechanism.
The inspected edit tool has no proven conditional/version update guard. A
read-modify-write plus readback is NOT atomic. Use demonstrated serialization
covering all writers or a separately verified atomic mechanism; otherwise retain
pending updates rather than overwrite attribution or inflate/lose Count. An
append-only comment is not a cross-field transaction: record uncertain or partial
outcomes and reconcile them before applying remaining writes. No exact-once or
race-free guarantee is claimed by this prompt contract.

## Jira plan record and handoff

Choose an issue-associated record after schema, size, editability and readback
checks. Prefer immutable append-only plan comments through the inspected comment
API; omit `commentId` for new records rather than editing approved snapshots.
Attachments require a separately discovered supported API. A compact description
index is optional only when existing content and migration provenance can be
preserved; do not replace the issue description wholesale.

Snapshot identity: issue key, scope ID, Git target, source revision and monotonic
plan revision. Compute the digest from exact snapshot bytes and store it OUTSIDE
the snapshot in the index/journal/approval evidence. Keep mutable decisions,
approval, jobs, review dispositions, validation and friction in a separate
append-only journal. Preserve previous revisions; material changes supersede,
not rewrite, the approved snapshot. Prove complete retrievability and exact bytes
(or reversible representation) before calling the record durable. Rendering,
size limits or incomplete comment pagination that prevent verification block
handoff; do not assume Markdown round-trips unchanged or truncate a plan.

Designer synchronizes and reads back before requesting operator plan approval;
then records approval of the exact verified identity before the Ready transition.
At handoff a fresh PM fetches the current Jira snapshot, journal and approval,
compares exact revision/digest, scope and Git target, and reconciles source
identity before work. Prior memory or an orphan local plan is insufficient.
Stale source, altered bytes, missing approval or conflicting revisions block.

Authorized owner syncs new decisions/evidence and verifies readback at handoff,
before delivery signoff, and before losing transient artifacts. Outage, denial
or unsupported record payload leaves pending reconciliation on mounted durable
storage; disclose location, identity and unsynced operations. This is NOT Jira
durability and blocks approval/handoff/closure where that record is required.
No hooks silently sync, create or transition; explicit agent checkpoints suffice.

## User-invoked friction triage — activation blocked

An evidence-only triage procedure may inspect open Process Friction issues and
relevant sources/tests/commits, cite likely implemented/partial/uncertain findings
and limitations, and rank remaining work by current reproducibility, bounded
remedy/owner, evidence, dependencies and verified recurrence Count. Missing Count
is unknown, not zero. Propose dispositions only; never implement or transition.
A later mutation requires operator confirmation and routing into the ordinary
explicitly scoped Jira workflow, not an implicit triage grant.

No `process-friction-triage` facet is activated by this source policy. Generic
gateway `execute` (and generic tool invocation) can tunnel Jira writes even when
direct write names are withheld. Prompt prohibitions are not technical read-only
isolation; shell and delegation can also broaden capability. Do not claim a
read-only sandbox. Stop facet activation until a separately approved enforceable
boundary is demonstrated or the operator explicitly accepts a prompt-constrained
alternative. Validate effective exposure and a negative mutation scenario before
activation; never issue a production write merely to test rejection.

## Evidence, rollout limits and repository exception

Design-time read-only discovery covered all create-metadata pages for Story,
Bug, AI Workflow and Process Friction (17/21/19/21 fields respectively). Agent
Sessions custom-array and Count numeric write payloads remain unproven. The fresh
implementation-session gateway reads confirmed LAP-36 and LAP-100 Ideas intake,
LAP-105 Plannable approval, and LAP-98 now Done. Earlier LAP-98 Plannable evidence
is historical, not its present state. These are not exhaustive workflow graphs;
refresh immediately before any operation. No Jira write was used to validate
this source policy. Deployment, custom payload probes and cross-session live
handoff remain separate authorized rollout checks.

The retained dcs-retribution herdle workflow is an explicit repository exception;
this contract does not alter its shared runtime gatekeeper or lifecycle policy.
