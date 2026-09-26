# Jira workflow validation

Scope: `JIRA-WORKFLOW-REDESIGN-0c2rae-urban`, source base
`6d44200146ded41f3c289e0ba041db3208e3f132`. This supersedes revision-3 fixture
policy. The old decision adapter does not execute prompts; its tests are retired,
not runtime proof. No TDD is required for skill/facet Markdown.

## Validation manifest

| Changed paths / consumers | Contract | Focused checks |
|---|---|---|
| `home/skills/jira-workflow/SKILL.md`, five scoped facets, `facets/partials/*.j2`, two workflow specialists, README | Agent instructions | Manual content review and scenarios below; no literal phrase assertions or policy simulator |
| Facet/subagent frontmatter and body transclusion | Loader, effective tools/skills, transitions | Official `polytoken validate`, rendered prompt and `/tools/effective`; unconditional PM return controller check |
| `scripts/install-polytoken.sh` | Managed installation | Shell syntax, isolated installer checks, copied fragment equality and rendered installed facets |
| Existing workflow harness/source lint and fixture retirement | Validation support | Shell/Python parsing, source lint, explicit skip results; no new production behavior engine |

Container-local commands: `bash scripts/test-polytoken-workflow-facets.sh
--validate-definitions`, `--designer-authority`, `--approval-contract`; source lint
`bash scripts/test-jira-workflow-contracts.sh`; installer
`bash scripts/test-install-polytoken.sh`. Run focused modes rather than unrelated
application suites. Application builds, mobile suites and full daemon suite are
not applicable: no application contract changed. Existing unrelated daemon
failures are not evidence of a new regression.

Ratatoskr-mediated host checks inspect Jira schemas and read-only samples for
Story/Bug/AI Workflow/Process Friction. Never create lifecycle test tickets or
write production fields as a probe. Schema validity does not prove custom-field
encoding, concurrency safety, or model adherence.

## Focused manual walkthroughs

Review the rendered roles and skill, not a Python imitation of policy:

1. **Optional intake (AC.1, AC.7):** A free-form feature proceeds with saved plan,
   contextual branch from main and disposable worktree. LAP key fetches type/status
   and suggests that key as branch name. Ideas pauses planning and offers confirmed
   intake. Ready/In Progress permits planning; PM rejects Plannable implementation
   unless approval enables the routine Ready step. Explicit target wins.
2. **Lifecycle/plan (AC.2, AC.3):** Approved product plan is posted readably and
   Plannable → Ready needs no second ask. Real start moves Ready → In Progress.
   Done/Canceled needs acceptance/confirmation and live name+destination check.
   Process Friction does not acquire an invented Ready route. Normalized Markdown
   succeeds if semantically complete; missing/truncated pages remain pending.
   `file_read` wrappers are stripped, actual Markdown preserved, all pages read;
   unavailable tool-flow composition uses sequential read → gateway comment.
3. **Attribution (AC.4):** For each of Story, Bug, AI Workflow, Process Friction,
   an actual current session ID is added without replacing existing IDs. A repeat
   encounter does not duplicate it. Unsupported encoding or unsafe concurrency
   yields a nonduplicative session evidence comment and pending field status,
   while unrelated work continues. Missing identity is disclosed, never invented.
   A timeout triggers reconciliation before retry, not duplicate comments.
4. **Friction (AC.4):** Search open AND resolved semantic/root matches. A relevant
   match gets evidence/session attribution; fresh occurrence Count changes only
   with proven safe update. Retry is not recurrence. Unknown Count is not zero;
   inconclusive search does not permit creation. A new deduplicated issue includes
   stable symptom, impact, reproduction and non-authorization warning; creation
   needs no second ask, closure does.
5. **Technical autonomy/review (AC.5, AC.6):** PM changes sequencing or an unspecified
   implementation detail without architect approval. Optional advice resolves a
   technical judgment. Changed user outcome/significant risk returns to operator.
   Design review stops after one delta; delivery lanes stop after four focused
   followups, never restart on revision. Both roles retrospect and route friction.
6. **Delivery (AC.7):** All intended work committed before completion. Acceptance
   precedes merge/terminal status. Leave-as-is removes disposable worktree only
   after safe committed state, preserves branch, and reports cleanup failures.
   PM returns to designer without a material-change confirmation.

## Implementation evidence

Container-local checks passed: official definition loader 21/21; designer effective
contract 10/10; unconditional workflow PM return 7/7; PM effective contract 12/12;
all-five-facet gateway exposure 14/14; installer 254/254 including three fragment
copy comparisons; source lint and shell syntax. Retired fixture: 16 skipped, not
16 passed. Initial runtime failure identified missing explicit `switch_facet`
grants on PMs and was corrected before the successful runs. An earlier combined
runtime command timed out; successful focused reruns supersede it.

Manual self-review walked the six scenarios above against the skill and shared
bodies. Official templating documentation confirms relative subtree paths and
body-only transclusion; the loader and daemon accept these definitions. No
render-only CLI/API was found, so actual model-rendered fragment content remains
unverified. The live configuration disables fallback models; tests enable only
referenced models in isolated copies, never modify live config. Daemon cleanup
can print `Killed` after successful assertions.

Ratatoskr-mediated read-only schema checks covered fetch/search/create/comment/
edit/transition. Live samples: LAP-36 Story and LAP-100 Bug are Ideas with Accept
for Planning → Plannable; LAP-105 AI Workflow and LAP-98 Process Friction are
Done with terminal global transitions only. Historical approval paths remain
examples, not current permission. No production writes, custom-array encoding,
atomic Count update, or tool-flow composition were exercised.

These are content walkthroughs, not live model-behavior tests. Independent workflow
and safety review remain the parent's delivery responsibility. Record final commit,
actual command outputs and unresolved limitations in the delivery report.
