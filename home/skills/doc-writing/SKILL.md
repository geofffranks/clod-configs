---
name: doc-writing
effort: medium
description: Guide for writing user-facing technical documentation for software features. Use when writing new docs, updating existing docs, or auditing docs for accuracy and style. Covers the full workflow from researching a feature through writing and reviewing the output.
---

# User-Facing Documentation Writing

**Context**: This skill covers technical documentation writing across all platforms and domains. For platform-specific formatting and conventions, see the references/ directory.

**When using this skill, begin by stating:** "I'm using the doc-writing skill to write accurate, user-focused technical documentation based on implementation verification."

## Workflow

### 1. Understand the scope

Before writing, establish what is actually implemented vs. designed but not yet shipped:

- Read specs and design docs, but treat them as aspirational; implementations often differ.
- Read the implementation directly (source code, config, tests). This is the ground truth.
- Use git history to constrain your search: find relevant commits by issue tracker reference or keyword, then read the diff.
- Compare implemented behavior against the spec to identify gaps. These become "known limitations" or are simply omitted.

### 2. Understand the existing docs

- Find the most similar existing doc and match its structure, style, and terminology.
- Identify where the new doc fits in the navigation hierarchy and what cross-links are needed.
- Check whether existing docs need to be updated to reference the new content.

### 3. Plan before writing

- Determine what the user needs to know to accomplish their goal, not what is technically interesting.
- Assume the reader has general domain knowledge. Link out rather than re-explaining concepts covered elsewhere.
- Focus on differences from existing behavior. What is new or different about this feature compared to what the reader already knows?
- Keep the doc minimal. Add sections only when they carry information the user cannot get from linked docs.

### 4. Write

- Write for task completion, not comprehensiveness. Procedures > explanations.
- Verify every factual claim against the implementation before including it. When uncertain, omit or flag.
- Use one example where several would be redundant. Link to the main reference docs for exhaustive coverage.
- Review the draft before completing. Check facts, links, and style.

### 5. Review

- Re-read the implementation and compare against what you wrote. Facts drift during editing.
- Verify that all cross-links point to real anchors.
- Check for style and accuracy issues (see below).

---

## Accuracy

- Only assert what is directly confirmed by the implementation or tests. Do not infer timing, causality, or behavior unless you can point to the code.
- When behavior varies by configuration or environment, say so explicitly rather than picking one case.
- Internal implementation details (endpoint names, config property keys, internal class names) belong in the implementation, not the docs, unless they are user-facing.

---

## Style

### Prose

Write prose that keeps the reader focused on the task. Avoid stylistic patterns that distract from the technical content.

Common patterns to avoid in technical documentation:

- **Em dashes** used as a catch-all separator — use a semicolon, comma, or restructure the sentence.
- **Throat-clearing openers** like "This document describes...", "It is worth noting that...", "In order to..." — cut them and start with the substance.
- **Participial tails** that end sentences with "..., ensuring X", "..., enabling Y", "..., allowing Z" — these add words without adding information. Say what the feature does, not what it enables.
- **Inflated adjectives** like "robust", "seamless", "powerful", "comprehensive" — use concrete, specific language instead.
- **Vague claims** like "This improves performance" without quantification — either provide specifics or omit the claim.

✅ Good: "Authentication tokens expire after 24 hours."
❌ Bad: "The robust authentication system ensures secure access, allowing tokens to expire after 24 hours."

Use the active voice and second person ("you"). Prefer short, direct sentences.

### Terminology

- Use the user-facing name for any setting or configuration option, not the internal property name.
- Be consistent: pick one term for a concept and use it throughout.

### Examples

- Use realistic, human-readable example values. Avoid generic placeholders like `foo` or `test`.
- Follow existing conventions in the documentation for formatting examples (e.g., email addresses, special characters, sensitive data).

---

## Platform-Specific Guidance

For platform-specific formatting and conventions:

- **Cloud Foundry**: See [references/cloud-foundry.md](references/cloud-foundry.md) for ERB templating, document structure patterns, cross-linking conventions, and research workflow.
