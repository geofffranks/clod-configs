---
name: agent-session-retro
effort: high
description: Conduct end-of-session retrospectives to identify improvements to skills, CLAUDE.md, processes, and collaboration patterns. Use at session end to reflect on what worked well, what could be improved, and propose concrete changes to tooling or documentation.
---

# Agent Session Retrospective

Conduct structured retrospectives at session end to continuously improve agent-user collaboration.

**When using this skill, begin by stating:** "I'm using the agent-session-retro skill to conduct an end-of-session retrospective and identify improvements."

## Purpose

End-of-session retrospectives help identify:
- **Skill gaps**: Missing or incomplete skills that would have helped
- **Skill improvements**: Updates to existing skills based on learnings
- **Process improvements**: Changes to CLAUDE.md, workflows, or collaboration patterns
- **Tooling issues**: Problems with tools or their integration
- **Communication patterns**: What worked well or poorly in agent-user interaction

## When to Use

- At the end of significant work sessions
- After completing complex or novel tasks
- When user explicitly requests retrospective
- When you notice recurring inefficiencies or friction points

## Retrospective Process

### 1. Review the Session

**Critical:** Make sure to review the contents of the session in its entirety. Do NOT rely on summarized context or assumptions!

**What was accomplished?**
- Main objectives and outcomes
- Tickets/tasks completed
- Artifacts created or updated
- Problems solved

**What was the scope?**
- How long did it take?
- How many context windows?
- What skills were used?
- What tools were involved?

### 2. Identify What Worked Well

**Effective practices:**
- Clear communication patterns
- Useful skills or tools
- Good decision points
- Efficient workflows

**Examples to look for:**
- User provided clear direction at key decision points
- Existing skills provided good guidance
- Tools worked smoothly together
- Process was efficient and low-friction

### 3. Identify Inefficiencies and Friction

**Common categories:**

**Skill-related:**
- Missing skills that would have helped
- Existing skills that were too verbose or too sparse
- Skills that conflicted or overlapped
- Skills that didn't match actual usage patterns

**Process-related:**
- Unclear decision points
- Repeated explanations needed
- Work that was done and then undone
- Tickets created for already-completed work

**Tool-related:**
- Tools that conflicted (e.g., multiple tracking systems)
- Tools that were hard to use or poorly documented
- Integration issues between tools

**Communication-related:**
- Assumptions that were incorrect
- Questions that should have been asked earlier
- Feedback that came too late
- Misaligned expectations

### 4. Propose Concrete Improvements

For each issue identified, propose specific, actionable changes:

**New skills:**
```markdown
**Proposed skill**: [skill-name]
**Purpose**: [what problem it solves]
**Content**: [key sections or guidance]
**Why needed**: [what friction it addresses]
```

**Skill updates:**
```markdown
**Skill**: [existing-skill-name]
**Proposed change**: [specific addition/removal/modification]
**Rationale**: [why this improves the skill]
**Location**: [which section to update]
```

**CLAUDE.md updates:**
```markdown
**Section**: [which section to update]
**Proposed addition**:
[specific text to add]
**Rationale**: [what problem this addresses]
```

**Process changes:**
```markdown
**Process**: [which workflow or practice]
**Current state**: [how it works now]
**Proposed change**: [how it should work]
**Expected benefit**: [what improves]
```

### 5. Reflect on Collaboration Patterns

**User's working style:**
- How do they prefer to give direction?
- What level of detail do they expect?
- When do they want to be consulted vs having agent proceed?
- What kinds of questions or feedback are most helpful?

**Agent's patterns:**
- What assumptions were made?
- Where was agent proactive vs reactive?
- What could have been anticipated better?
- Where was agent too verbose or too terse?

### 6. Present Findings

**Keep output concise and scannable.** Use short bullets, avoid verbose framing. User can ask for details in follow-up.

Structure the retrospective output:

```markdown
## Session Retrospective

### What We Accomplished
[Brief summary - 1-2 sentences or short bullets]

### What Worked Well
[2-4 short bullets]

### Inefficiencies Identified
[2-4 short bullets with specific examples]

### Proposed Improvements
[Direct action items - what to change and why, in 1-2 lines each]

### Questions
[Clarifying questions if needed]
```

## Key Principles

### Be Specific
❌ Bad: "Communication could be better"
✅ Good: "Agent created tickets for work that was already complete. Should verify current state before creating improvement tickets."

### Focus on Actionable Changes
❌ Bad: "The session was inefficient"
✅ Good: "Add to agent-issue-tracking skill: 'Use only ONE tracking tool per session to avoid duplication and confusion.'"

### Challenge Assumptions
- What did you assume that turned out to be wrong?
- What should you have asked about earlier?
- What patterns from previous sessions didn't apply here?

### Learn from User Feedback
Pay attention to patterns in user feedback:
- Requests for justification → They want reasoning, not assertions
- Requests for permission → They want explicit consent before changes
- Questions about necessity → They value conciseness and challenging assumptions
- Corrections or pushback → They've identified a gap or misalignment

### Distinguish Systemic from One-Off Issues
- **Systemic**: Worth documenting (e.g., "reference files should be concise command references, not tutorials")
- **One-off**: Note but don't over-optimize (e.g., "user interrupted mid-task to handle urgent issue")

## Common Improvement Categories

### Skill Content
- Too verbose (violates "agents are capable")
- Too sparse (missing critical guidance)
- Wrong level of abstraction (too specific or too generic)
- Outdated (doesn't match current practices)

### Skill Organization
- Should be consolidated (overlap/duplication)
- Should be split (too many concerns)
- Should use references (variants not separated)
- Missing cross-references

### Process Documentation
- Missing guidance in CLAUDE.md
- Contradictory guidance
- Unclear decision criteria
- Missing examples or templates

### Tool Integration
- Tools conflict or duplicate
- Tools poorly documented
- Tools don't match workflow
- Missing tool guidance

### Communication Patterns
- Unclear when to ask vs proceed
- Wrong level of detail in explanations
- Missing confirmation points
- Assumptions not validated

## Anti-Patterns

### ❌ Don't: Focus only on agent improvements
Retrospectives should identify improvements for both agent and user. If user actions caused friction (unclear prompts, disruptive edits, conflicting directions), provide constructive feedback. Frame as "what would help" rather than "what went wrong."

**Examples:**
- ✅ "Would it help if you provided acceptance criteria upfront for complex tasks?"
- ✅ "Editing files while agent is working on them caused conflicts. Could we coordinate better?"
- ❌ "You kept changing your mind" (blame without constructive suggestion)

### ❌ Don't: Propose vague improvements
"Better communication" isn't actionable. "Add explicit confirmation step before major refactoring" is.

### ❌ Don't: Over-optimize for one session
Look for patterns across sessions, not one-off issues.

### ❌ Don't: Propose changes you're not confident about
If unsure, frame as questions: "Would it help if...?" or "Should we consider...?"

### ❌ Don't: Skip the retrospective when asked
Even if the session felt smooth, there are always learnings.

## Success Criteria

A good retrospective:
- Identifies 2-5 concrete improvements
- Proposes specific, actionable changes
- Distinguishes systemic from one-off issues
- Reflects on collaboration patterns
- Asks clarifying questions about user preferences
- Results in actual changes to skills, CLAUDE.md, or processes

## Integration with Other Skills

- **skill-writing**: Use when proposing new skills or skill updates
- **CLAUDE.md**: Reference when proposing process changes

## Example Output

```markdown
## Session Retrospective

### What We Accomplished
Implemented OAuth2 authentication system with 8 new endpoints, updated tests, documented API changes.

### What Worked Well
- Task decomposition with issue tracking kept work organized
- User provided clear acceptance criteria upfront
- Existing pr-review skill caught edge cases early

### Inefficiencies Identified
- Created improvement tickets for already-resolved issues (didn't verify current state first)
- Asked about error handling approach 3 times for similar endpoints (should establish pattern once)
- Requested OAuth provider details multiple times (not captured persistently)

### Proposed Improvements
- **pr-review skill**: Add "For repetitive changes, establish pattern from first instance and apply consistently"
- **agent-issue-tracking skill**: Add "Verify issue exists in current state before creating improvement tickets"
- **CLAUDE.md**: Add "Capture frequently-referenced context in persistent location to avoid repeated requests"
- **User coordination**: Would it help if agent announced which files it's working on to avoid edit conflicts?

### Questions
1. Should agent create context document at session start for frequently-referenced info?
2. Should agent be more proactive about establishing patterns vs asking each time?
```
