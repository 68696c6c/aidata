---
name: linear-issue-writing
description: >-
  Write, review, and refine Linear issues from notes, customer requests,
  requirements, or existing tickets. Use for issue writing, backlog refinement,
  cross-repository decomposition, duplicate handling, and research spikes.
  Define outcomes and acceptance criteria, not implementation plans.
---

# Linear issue writing

## Purpose

A good Linear issue is a small, complete promise: what will be true after it's done, and what won't 
break along the way. It is both:
- A unit of value: it delivers something concrete.
- A unit of behavior: it keeps the system stable, predictable, and safe to extend.

## Core Principles

1. Outcome before activity: describe the result, not the process.
2. Human-first clarity: assume a reader will pick this up later and needs the story fast.
3. Timelessness: the issue should read the same at start and finish (no status logs).
4. Traceability: connect to milestones/PRDs/related issues.

## What a good issue looks like

A reader can quickly answer:
- What am I building?
- Why does it exist, and why now?
- How do I know it's done?
- What should I ignore or defer?
- What could break, and how do I keep it stable?

## Scope

- Create issues only for concrete tasks with defined outcomes. Move vague goals
  and feature ideas to a project doc or PRD before deriving issues.
- Translate customer requests into underlying needs, not unquestioned solutions.
- Scope execution to one git repository. Split cross-repository work into
  repository-scoped sub-issues under a shared coordination parent. Research
  Spikes may span repositories.
- Define outcomes and necessary constraints, not detailed technical designs or
  coding steps. Reserve those for implementation planning.

## Existing work and relationships

- Check existing issues before creating new ones. Update a matching backlog
  issue with new information instead of duplicating it.
- When matching work is already in progress, put additional scope in a new
  related issue. Do not duplicate work already covered.
- Record genuine dependencies in the blocking / blocked by fields, not just
  the description. If A must finish before B can proceed, A blocks B.

## Issue template

Always include an acceptance-criteria checklist. Write observable outcomes or
checkable deliverables, not implementation steps or vague claims like "works
correctly." Include the existing behavior that must remain unchanged when
relevant. Use only as many criteria as needed.

```markdown
[Optional one-sentence summary.]

## Acceptance criteria
- [ ] [Observable outcome or concrete deliverable.]

## Notes
[Optional brief context, exclusions, links, or developer suggestions.]
```

Omit unused optional sections. Keep suggestions such as libraries or existing
code references brief; link longer material rather than copying it.

## Research Spikes

- Apply the Research Spike label.
- State the unknown blocking implementation and the required deliverable:
  a spec, design, investigation report, or documented decision.
- Mark the spike as blocking at least one real implementation issue. Flag a
  missing downstream issue; do not invent one just to satisfy this rule.
- Require the deliverable to supply what those blocked issues need to proceed.
  Do not treat research activity alone as completion.

## Delivery

Return the title, description, and relevant metadata separately. Keep unresolved
questions and duplicate decisions outside the issue body. Draft unless asked to
publish.

