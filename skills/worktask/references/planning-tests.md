# Planning tests

Read when executing or checking planning tests.

Procedure routing: [pl0-procedure](pl0-procedure.md).

<a id="section-lookup-1"></a>
Related: [Notation](planning-sizing.md#notation) · [Downstream propagation](planning-sizing.md#downstream-propagation)

<!-- canonical-body:start -->
# PL0 Procedure — the complete planning-stage worktask integration

The whole planning procedure for `corpflow:product-manager` dispatched as the PL stage agent (PL0),
and its canonical source. The agent file carries a steady-path digest (`agents/product-manager.md
§ PL0 runbook`) and a trigger list naming the sections here to Read; this file wins any
disagreement, and a change here that alters the steady path updates that runbook in the same
change. Non-PL0 invocations (`/estimate`, `/product-requirements`, `/roadmap`, `/milestone`) never
need it.

Every `skills/`, `commands/` and `hooks/` path below is relative to the corpflow plugin root, not
the worktask repo — resolve per `agents/product-manager.md § Plugin paths`. `<plan_file>`: see § Notation.

## Test Strategy Definition

Define the test strategy in the plan file: scope (unit/integration/E2E), framework, acceptance criteria, existing tests to update, new test files, effort estimate by stage.

### Key Rules

1. DV writes unit tests as part of implementation; QA validates integration/E2E.
2. The framework is platform-derived: adopt whatever the repo's test targets already use; with no existing tests, take the detected platform's test-generator default (`skills/shared/routing-matrix.md § Functional-role aliases`). Name it in the plan. Never carry one platform's framework into another — the Swift Testing (unit) / XCTest (UI) split in `skills/shared/testing-strategy.md` is Apple-only.
3. Coverage: new features 3+ unit scenarios; bug fixes get regression tests; refactors identify all affected existing tests.
4. A test effort estimate is required — by type, hours, and stage (DV/QA).

### Required Metadata: Test Selection Gate

Every plan file (`planning-N.md`) declares four frontmatter `metadata` fields. They drive DV (step D2), QA (step Q1), the Visual Comparison subsection, and the screenshot capture gate.

```yaml
metadata:
  test_mode: scoped              # build-only | scoped | full
  always_required_tests: []      # explicit override list of test IDs
  ui_visual_check: false         # gate for QA's visual/design comparison
  requires_screenshots: false    # REQUIRED — drives DV screenshot capture + gate
```

Plans declare `test_mode` + `ui_visual_check`; the marker grammar DV parses is canonical in `skills/shared/test-selection-syntax.md`.

#### `test_mode` — selection breadth

| Mode | When to choose | Effect |
|------|----------------|--------|
| `build-only` | Repo has marker coverage (`@test-required`/`@depends-on:` widely used) AND change is refactor/dep-update/doc-only. Opt-in — do not pick if uncertain. | DV builds and runs no tests (except the no-handler module-scope promotion). QA runs Selected Tests only. |
| `scoped` (effective default if omitted) | Bug fixes, small features, anything touching a known set of modules. Default for untagged or partially-tagged repos. | DV + QA run Selected Tests + tests in any module the diff touches. |
| `full` | Release candidate, multi-module feature, post-major-dep-upgrade, stakeholder-requested full regression. | DV runs Selected Tests; QA runs the entire project test suite. |

##### Default `test_mode` by complexity score

The complexity-score → default `test_mode` table lives in `skills/estimation-methodology/SKILL.md § PL0 Stage-Set & Test-Mode by Complexity Score`. Uncertain between `scoped` and `full`? Choose `scoped` — the auto-promotion safety net (DV warns, QA promotes on an empty Selected list) catches under-selection.

##### Comment/doc-only diffs

When the planned diff is entirely comments, prose files, or non-executable strings, select `build-only` (not merely allow it): nothing executable changed, so the marker-coverage precondition does not apply. Record the reason in `§ test-strategy`. Canonical rule, including "no QA re-run for a post-QA doc-only change": `skills/worktask/references/testing-strategy.md § Comment/doc-only diffs`.

#### `always_required_tests` — explicit override

Test IDs that always run (every mode, every run). ID grammar is per-platform and canonical in `skills/shared/test-selection-syntax.md § Platform handlers`. Platforms whose selective-test handler is a stub auto-promote the run to module-scope at DV (never `full` — QA is the sole full-suite authority), so entries are recorded but unused for DV selection. Use sparingly, for cross-cutting smoke tests not annotated `@test-required` in source.

#### `ui_visual_check` — Visual QA gate

Independent of `test_mode`. Set `true` when any applies:
- New views/screens/UI components in the platform's view layer (SwiftUI/UIKit, Compose, React/Vue/Svelte/Angular, …)
- `.context/designs/` holds visual artifacts (Figma registry, mockups) needing verification
- Layout, styling, or animation changes need screen capture to validate
- Stakeholder explicitly requests UI verification

When `true` AND `.context/designs/` has artifacts, QA performs Design Comparison during Q1.

#### `requires_screenshots` — DV screenshot capture gate (REQUIRED)

Drives `dv-screenshot-capture` and its SubagentStop gate (`hooks/dv-screenshot-gate.sh`). `true` ⇒ each DV task leaves valid evidence in `.context/images/<worktask_id>/screenshots-<TASK_ID>.md` (on `backend`/`systems` the gate also passes no captures, or a `tool_missing` row), whose captures are embedded in both the PR body and the GitHub issue. `false` ⇒ DV writes a skip-rationale manifest and the gate passes.

The planning model decides this flag; the detector is advisory input. DV and the SubagentStop gate may only raise it to `true` (`skills/dv-screenshot-capture/scripts/escalate-flag.sh`), never lower it. The downstream `?? true` defaults only cover ad-hoc runs. Stamp it per the steps below.

##### Detector run (step 1)

1. Run the detector against the draft plan:
   ```bash
   skills/worktask/scripts/detect-ui-change.sh <draft-plan> --platform <platform>
   ```
   It emits `{requires_screenshots, signals, rationale}` as advisory input. Signals (any true ⇒ detector true): **S1** `ui_visual_check: true`; **S2** `.context/designs/` has `figma-registry.md`/`*.png`; **S3** `## scope`/`## requirements` matches the UI framework-term set (`SwiftUI`, `UIKit`, `Composable`, `CSS`, …; generic words like "view" or "screen" do not count); **S4** platform ∈ {apple, web, android} AND scope names UI path classes (`Views/*`, `Screens/*`, `*.storyboard`, `*.tsx`, …). Exits 0 always; any error ⇒ `true` (`fail_safe_default`).

##### Judge, stamp, propagate (steps 2–4)

2. Judge whether the planned diff alters rendered output (views, styles, layout, assets, on-screen copy). Refactor, logic, networking, tooling, tests and docs ⇒ `false`. Stamp your verdict on the plan frontmatter `metadata.requires_screenshots`.
3. Floor and rationale: S1 (`ui_visual_check: true`) ⇒ `true`, no exceptions. `false` over an S2 hit needs a written reason. Uncertain ⇒ `true`. A `false` names the touched surfaces and why none renders. Write the test-strategy line as `<true|false> — <why>; detector signals: [S…]`.
4. Never raise an `open_questions[]` item about screenshots; the decision is yours, and DV's upward-only escalation covers a wrong `false`.

Propagate the flag on all three writer surfaces (§ Downstream propagation): plan frontmatter, DV+QA task metadata, and `state.json .metadata.requires_screenshots` — the channel the gate reads, because SubagentStop stdin carries no task metadata in live runs.
