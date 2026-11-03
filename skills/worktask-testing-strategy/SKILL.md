---
name: worktask-testing-strategy
description: Use when planning test strategy in the worktask PL (Planning) or AR (Architecture) stage, before implementation. Plan and architecture test templates, required tests per feature type, UI selectors, multi-substate UITests.
related:
  - agents/product-manager.md
  - agents/software-architector.md
  - agents/qa-engineer.md
  - commands/test-plan.md
  - skills/estimation-methodology/SKILL.md
---

# Worktask Testing Strategy Skill

Test planning for the PL and AR stages, so developers know what to test while coding rather than after.

- Framework matrix, AAA pattern, naming conventions, DV/QA boundary:
  `${CLAUDE_SKILL_DIR}/../shared/testing-strategy.md`. Name the concrete framework in the plan.
  Deeper per-framework guidance is the dev plugin's job, via `/<plugin>:gen-tests`.
- Per-stage test templates (PL, AR, DV): `${CLAUDE_SKILL_DIR}/references/stage-templates.md`.

## Test Strategy by Feature Type

| Feature Type | Required Tests | Integration | E2E |
|--------------|----------------|-------------|-----|
| New feature | 3+ unit tests | 1+ | Optional |
| Bug fix | Regression test | If root cause spans components | No |
| Refactor | Verify existing pass | No new | No |
| Logic update | Update affected + new edge cases | If boundaries change | No |
| API endpoint | Request/response validation | Contract tests | Optional |
| UI component | State-holder tests (view model, store, hook) | Snapshot tests | Optional |

### UI test selectors

Query by a stable identifier set in the view, not by visible label or screen position, so tests
survive copy changes and layout shifts.

| Platform | Set in the view | Query by |
|----------|-----------------|----------|
| apple | `accessibilityIdentifier` | XCUITest element queries |
| android | `Modifier.testTag(...)` | `onNodeWithTag` (Compose), `withTagValue` (Espresso) |
| web | `data-testid` (or an ARIA role + accessible name) | `getByTestId` / `getByRole` |

## Multi-substate UI screens (camera / photo / result)

Screens that cycle one view through several substates (capture → review → result, each with
default/error/empty/loading variants) hide two defects that snapshot and state-machine tests
miss: a control clipped or overflowing in one substate, and a transition control that fails to
return the prior state. Plan a hittable-control-bounds UITest for any such screen.

### Hittable-control-bounds pattern

For each substate the screen renders, assert:

1. Every primary control is present and hittable — on-screen, within window bounds, not clipped or overlapped. Query by the stable identifier (table above) and assert hittability, not mere existence: `element.isHittable` (XCUITest), `assertIsDisplayed()` + `assertHasClickAction()` (Compose), `toBeVisible()` + `toBeEnabled()` (Playwright).
2. Each substate-transition control performs its transition and its inverse returns the prior state — e.g. RETAKE from the review state returns the live-capture state.

One method may sweep every substate, or write one per substate; what matters is that every substate is covered.

## Handoff to QA Stage

| QA receives from DV | Source | QA then |
|---|---|---|
| Test scope — what was planned | `<plan_file> § test-strategy` (resolve via `task.metadata.plan_file`; fallback: newest `.context/planning-*.md`) | Runs integration + E2E as the plan defines; checks every acceptance criterion is tested |
| Test architecture — how tests are structured | `architecture-N.md`, only when AR ran (with no AR the plan's test strategy is the whole authority and DV owns the test shape) | Reviews DV's unit tests for quality and completeness |
| Implemented unit tests + the existing-tests-to-update list | Every DV artifact — `refs.dev[]`, or the ledger per `skills/worktask/references/contracts/artifact-map.md § Iterating the DV tasks` | Fills coverage gaps (edge cases, boundaries) and reports metrics in `testing.md` |

## Logic Change Handling

| Stage | Action on a logic change |
|-------|--------------------------|
| PL | List affected tests under `### Existing Tests to Update` — test file, reason, action (formula changed → update expected values; API contract changed → update mocks) |
| AR | New dependencies → define test doubles; new patterns → document the testability approach; changed boundaries → update test organization |
| DV | Update tests before or with the code change and prove no regressions |

## Integration with Estimation

Test effort sits inside each subtask estimate (`Implement login + tests | SP 5–8 | 30–48h`), not
in a separate `Write login tests` row.
