# Revision-3 triage validation manifest

Scope: `lap-105-108-cohesive-design`, plan revision 3, snapshot SHA-256
`501275335ea8930722e76dfa8e0bf2e90b6811183c7f37ef5f1495603d72c385`.
Baseline GLOBAL `7425984dde926f349e6506d490999a61c881906c`.

## Contracts and checks

| Changed paths | Consumed contract / consumer | Focused check |
|---|---|---|
| `home/skills/jira-workflow/SKILL.md` | Prompt authority for eligible Jira actors; skill frontmatter | CLI skill validation; content review and named scenario walkthroughs |
| `polytoken/facets/process-friction-triage.md` | Facet loader frontmatter and actor prompt | CLI facet validation; effective-plan and refusal checks at authorized rollout |
| `scripts/jira-triage-fixture.py`, `scripts/test-jira-triage-fixture.py` | Offline validation support only | Python unittest runner, positive/negative calls and fault fixtures |
| `scripts/test-install-polytoken.sh` | Existing installer-test facet inventory | Shell syntax and source inventory comparison; installer execution withheld by no-install restriction |
| This manifest | Evidence classification | Manual review |

Run from the feature worktree:

```sh
polytoken validate skill home/skills/jira-workflow/SKILL.md
polytoken validate facet polytoken/facets/process-friction-triage.md
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-jira-triage-fixture.py
bash scripts/test-jira-workflow-contracts.sh
git diff --check
```

All are container-local. Existing source lint is inventory/legacy-reference
validation only. Full application/mobile/native suites are not applicable:
there is no affected application or integration code. No shared runtime or
installer changes; dcs/unrelated-repository runtime regression suites are not
applicable to this delta. Independent implementation/safety reviews belong to
the parent delivery lane, not this helper.

## Why retain the fake harness?

The approved fallback needs observable calls, attempted writes, consumed
confirmation, unchanged declines and uncertain-outcome reconciliation. Lexical
lint cannot observe these. The adapter supplies in-memory issue states and
transition objects with denial, timeout-after-mutation, index lag and partial
readback; no endpoint option, network client, shell or production connection.
Its contract tests reject uninspected/unauthorized fake calls and retain rejected
write attempts. The separate decision adapter makes scripted calls through this
boundary. It is NOT production authorization middleware and is NOT connected to
the facet runtime; it does not load prompt text or prove model adherence.

Named classes map directly to AC.1–AC.6: `TriageDedupeCases`,
`TriageCreateAuthorizationCases`, `TriageCloseAuthorizationCases`,
`LifecycleGateCases`, `OccurrenceIdentityCases`, `UnsafeFieldPendingCases`,
`PlanRoundTripCases`, `TriageNegativeMutationCase`. `FakeAdapterContract` tests
the boundary itself. Passing these establishes fixture behavior only, not live
Jira payload support, semantic matching quality, persistence or exact-once safety.
The lifecycle/occurrence helpers are explicit scenario oracles, not an automated
evaluation of the skill. No prompt-body literal tests or production TDD claim.

## Manual prompt walkthrough / required rollout evidence

- Relevant open/resolved match: evidence and actual session attribution, no
  duplicate/reopen. Distinct cause or uncertain search: ask before proposing.
- Create: particular exact proposal confirmation permits one attempt; decline,
  generic approval, changed fields or stale search permits none. Unknown outcome
  consumes consent and blocks blind retry, even with delayed indexing.
- Close: verify remedy or legitimate named disposition and intended live path;
  confirm exact key/state/destination/evidence. Stale state, missing path,
  unverified remedy or global Done shortcut stops.
- Preserve four design/PM actors' existing routine authority and lifecycle gates;
  wrong-state correction asks; Ready is not implementation approval.
- Two events in one session are distinct; repeated reports are not occurrences.
  Unsafe payload/history/concurrency leaves Count/session fields pending.
- Exact snapshot bytes and external digest plus key/scope/target/source/revision
  must survive fresh-session retrieval. Outage or stale identity blocks transfer.
- Partial installation grants nothing. Audit loaded skill and effective tools
  after coordinated authorized installation/reload. Generic ratatoskr execute
  is write-capable, not an enforceable operation sandbox.

Pending operator-authorized rollout: `InstalledPolicyExposureCheck`, effective
facet refusal with zero attempted fake writes, read-only live metadata/transition
refresh, separately authorized positive Jira snapshot write/readback and actual
fresh-PM same-ticket transfer. Do not interpret source validation as activation.
No live negative mutation, installation or Jira write is authorized by this file.
