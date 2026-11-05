---
name: request-plan
description: Turn a free-form request into a lightweight, context-aware plan (goal, scope, phases, rough effort, risks) and recommend the worktask trigger to execute it
argument-hint: '"<request>" [--save]'
allowed-tools: Read, Glob, Grep, Write, Agent, Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/request-plan/scripts/capability-registry.sh *)
related:
  - skills/request-plan/SKILL.md
  - skills/estimation-methodology/SKILL.md
  - skills/shared/three-stage-planning.md
  - skills/worktask/SKILL.md
  - commands/estimate.md
  - commands/product-requirements.md
---

# Request Plan Command

Produce a lightweight, grounded plan from a free-form request plus current repository context, then
hand off to the worktask system — lighter than a PRD (`/product-requirements`), broader than a
sizing estimate (`/estimate`).

Thin entry point to the `request-plan` skill, which holds the full workflow and templates.

## Options

| Option | Values | Effect |
|--------|--------|--------|
| `--save` | — | Also write the plan to `.context/request-plan-0.md`, named per `skills/task-folder-organization/SKILL.md` (default: off, inline output only) |

## Examples

```
/request-plan "<request>" [--save]
/request-plan "we keep getting duplicate push notifications, help me plan a fix"
/request-plan --save "add CSV export to the estimates feature"
/request-plan "split the 4k-line sync manager into testable units"
/request-plan --save "migrate the app from UIKit to SwiftUI"
```

- Line 1 — a bug with no known cause: context gathering reads the failing area before scoping.
- Line 3 — a refactor: no new behaviour, so Scope carries the seams and Risks the regression surface.
- Line 4 — XL work: the plan splits it into sub-tasks and triggers the first.

## Output Format

`skills/request-plan/references/plan-template.md` — `# Plan: <one-line goal>` then
Context · Goal · Scope · Phases · Effort (rough) · Risks & Dependencies ·
Recommended next step (the single `/worktask` command line).

## Workflow

1. Load the `request-plan` skill (`skills/request-plan/SKILL.md`) and follow its five steps. Done
   when the plan carries every section of `skills/request-plan/references/plan-template.md`, or,
   under the `skills/request-plan/SKILL.md#4-recommend-the-handoff` exception, cites where the asked-for thing already exists.
2. Keep it lightweight. A heavier sibling command may be named alongside the handoff, never in
   place of it — `skills/request-plan/SKILL.md#4-recommend-the-handoff` holds the list and is the authority. Done when every sibling
   command the plan names sits in its Recommended next step section next to the `/worktask` line.
3. End with a single ready-to-paste `/worktask` command line (PL0 dynamic sizing drops stages for
   small tasks), with the one exception `skills/request-plan/SKILL.md#4-recommend-the-handoff` states. XL work still gets its line, for
   the first sub-task — `skills/request-plan/references/handoff.md § Escalation beats size`.
