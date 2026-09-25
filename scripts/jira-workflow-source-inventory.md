# LAP-94 source lint inventory

`bash scripts/test-jira-workflow-contracts.sh [TDC_ROOT]` runs a read-only lexical
lint, including negative/positive fixtures. Python 3 and Git are required. No
installation, generated projection, remote access or application test is performed.

## Validation manifest

- Prompt sources: canonical `home/skills/jira-workflow/SKILL.md` and the four
  product/workflow design/PM facets. Check by content review and scenarios.
- Machine-consumed frontmatter: four changed skill grants and hints. Check with
  `polytoken validate facet <path>` and `polytoken validate skill <path>`.
  No tool exposure or facet-transition graph changed. Effective installed-session
  checks remain operator-owned because install/reload is prohibited.
- Validation support: shell wrapper and Python lexical lint. Check shell syntax,
  run built-in positive/negative fixtures and scan source inventories.
- Hooks, installers and app runtime are unchanged. Hook, installer, app/mobile
  and native test suites are not applicable. TDC bootstrap belongs to its slice.

## Source ownership and classifications

`home/skills/` is the canonical shared skill tree. `scripts/install-polytoken.sh`
lines 651–656 copies every file into the destination skills tree; no installer
manifest edit is needed. The installer and installed copies are not changed.

Recursive roots include tracked and non-ignored untracked files, so new unstaged
policy sources cannot escape the scan. A temporary Git-repository fixture proves
that detection and is automatically removed after the check; project sources are
read-only. Ignored backups remain excluded.

The explicit global inventory in `jira-workflow-source-lint.py` covers tracked
`polytoken/AGENTS.md`, all `polytoken/facets/` and `polytoken/subagents/`,
`home/CLAUDE.md`, all `home/skills/`, and the container-awareness hook. The new
canonical skill is also checked before staging. These are active policy sources;
only the hook reference below is runtime context. No separate tracked rules tree
was found. GitHub pull-request review skills are unrelated and retained.

The optional TDC inventory covers tracked `AGENTS.md`, `AI-EXPERTS.md`,
`.polytoken/facet-templates/`, `.polytoken/subagent-templates/` and
`.polytoken/skills/`. Generated personas are excluded: bootstrap validates their
projection from these sources. The legacy `github-project-backlog` skill name is
an integration compatibility name, not itself an assertion of active authority.

## Reviewed exception rationale

Exceptions are exact path + exact line, never a broad substring or whole-file
waiver. The implementation self-review permits only:

1. The existing container-awareness hook's exact gatekeeper notice: runtime
   mechanism retained unchanged; dcs-retribution still depends on shared runtime.
2. The canonical skill's exact dcs-retribution exception sentence: repository-only
   preservation, not authority for other repositories.
3. One exact sentence in TDC `AI-EXPERTS.md` and
   `.polytoken/skills/github-project-backlog/SKILL.md`: `GitHub Project #1 is a frozen, read-only
   historical archive; Jira is authoritative.` This migration wording
   preserves history without granting writes. Other historical text requires
   classification and an explicit reviewed exception before it can pass.

Historical design documents outside this active inventory are archive/history,
not live authority, and are outside the base sweep. Follow-up D owns residual
reference/runtime work. No shared hook behavior is claimed verified.

## What this catches and cannot prove

The lint catches reintroduced legacy product-project names/commands and herdle
references in the bounded inventory, including split authority consumers not in
the changed-file diff. A diff-only check would miss those. Fixtures prove active
forbidden text fails and reviewed archive/runtime/dcs lines pass only at their
reviewed paths; appended active instructions fail. Missing paths and Git errors
fail closed. The scanner does not parse prose semantics, enforce authorization,
prove model adherence, catch every paraphrase or validate Jira write payloads.
New policy roots require an inventory update. TDC integration must be run with
its explicit worktree root and may fail until that separate slice is migrated.
