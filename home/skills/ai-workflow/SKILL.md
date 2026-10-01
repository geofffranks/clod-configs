---
name: ai-workflow
description: Conditional parent-role routing for designing and delivering AI agent workflows.
---
# AI-workflow routing

Use only when the work changes agent workflows, definitions, skills, hooks,
harness configuration or MCP-related agent behavior. This is coordination
routing for design/delivery parents, not a worker prerequisite.

Use `agent-workflow-architect` for useful design consultation and the design
review under the same lighter contract as `design-reviewer`: requirements,
feasibility, scope, material risks and practical acceptance, not implementation
recipes or universal automation. Design review is one initial pass plus at most
one focused delta.

Route implementation to `agent-workflow-engineer`. Follow any explicitly selected
implementation owner. Missing optional specialists permit a capable equivalent;
disclose an actual capability limit only when it prevents the work. Select and
present the implementation review panel by actual risk during design sign-off:
workflow fidelity may warrant the architect, functional configuration/install
behavior correctness, and broader authority/MCP boundaries adversarial review.
Do not make all three mandatory for every change. Delivery follows the approved
panel and its one-initial/four-followup per-lane budget; do not add lanes silently.

Use official Polytoken parser/render/effective-tool mechanisms where relevant,
existing focused installer/runtime checks, and content review/scenarios for
instructions. No prompt phrase tests, policy replicas, mandatory TDD transcripts,
evidence manifests or unrelated app suites. Keep standalone snapshot review's
identity/provenance/helper boundary separate. Source editing, installation and
runtime activation are distinct; preserve unrelated config and retire removed
installed definitions reversibly with appropriate authority.
