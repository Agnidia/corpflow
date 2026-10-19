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

When the planned diff is entirely comments, prose files, or non-executable strings, select `build-only` (not merely allow it): nothing executable changed, so the marker-coverage precondition does not apply. Record the reason in `§ test-strategy`. Canonical rule, including "no QA re-run for a post-QA doc-only change": `skills/shared/testing-strategy.md § Comment/doc-only diffs`.

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

## Worktask Integration

Stage PL (Planning, 1/11); pipeline context: `skills/shared/worktask-stage-context.md`.

### Plan File & Run Index Naming

Each PL invocation produces a numbered plan file and stamps a shared run index on every downstream task: first plan `.context/planning-0.md`; later ones `.context/planning-N.md`, N = max existing index + 1. Both are new runs. A plan-gate revision is not a new run and allocates nothing (§ Revision of the run in flight).

#### Algorithm (run as PL0 step 1)

1. Glob `.context/planning-*.md`. Extract the integer suffix from each match.
2. If matches exist, set `N = max(existing) + 1`. Otherwise `N = 0`.
3. Write `.context/planning-${N}.md`. Do not overwrite `planning-0.md` … `planning-(N-1).md`; they stay as historical plans.

##### Write-target authority

PL0 is the authoritative writer. A `plan_file` / `run_index` in a pre-seeded `state.json` (the orchestrator's Phase-1 step 3a seed) is provisional: recompute `N` via the step-1 glob and use that. Never write to a `planning-${N}.md` that already exists — if the computed target exists, the glob was stale; recompute. The reader resolution order below (`metadata.plan_file` first) governs downstream stages reading a finalized plan, never PL0's own write target.

##### Revision of the run in flight (NOT a new index)

When the dispatch prompt carries `plan_revision: true` (a plan-gate rejection —
`commands/worktask.md § Plan-revision re-dispatch`), this turn revises the run in flight:

- Skip algorithm steps 1–3: `run_index` and `plan_file` are frozen; edit the current `.context/<plan_file>` in place.
- Skip the Step-4 reset; patch `facts.*` additively so `facts.decisions[]` (the gate answers just given) and every other fact of this run survive.
- Create no stage tasks; patch the existing chain in place when the revision changes subjects, ACs, or the stage set.

The never-overwrite rule protects finished runs' plans; a plan under active revision is not history.

#### Step 4 — state.json reset

4. Reset `state.json` (new run in an existing `.context/`; skipped on a `plan_revision` turn):
   atomically rewrite `.context/state.json` with `"run_index": N`, `"tasks": {"PL0": {"status": "in_progress"}}`, `metadata.requires_screenshots` = the planner's verdict (the channel `hooks/dv-screenshot-gate.sh` and `attach-visual-evidence.sh` read), `metadata.base_ref` = the detected integration branch (below), and empty `facts.*` (preserving `version`, `worktask_id`, `platform`). Use `handoff-protocol.md#atomic-write`.

##### Step 4 — plan_file shape

Write the path shape into `state.json.plan_file` — `".context/planning-${N}.md"`, not the bare `<plan_file>` basename used everywhere else in this document; the issue-publish helper cannot find an unprefixed plan. Rule: `handoff-protocol.md § plan_file shape boundary`.

#### Downstream propagation

When PL seeds downstream stage tasks via `state-patch.sh --task-create`, stamp every row of the tables below on each task:

| Key | Value | Purpose |
|---|---|---|
| `metadata.plan_file` | `"planning-${N}.md"` | Pins the active plan — a bare basename, unlike `state.json.plan_file` (a workspace-relative path; `handoff-protocol.md § plan_file shape boundary`). |
| `metadata.run_index` | `N` (integer) | Resolves `<basename>-${N}.md` artifacts |
| `metadata.isolation` | `"worktree"` | File-writing stages (DV; megatask per-issue AR/DR/QA) run in an isolated worktree (read by developer § D0.0, the technical-lead DR check, workspace-modes.md). |

##### Propagation fields — dispatch pair

| Key | Value | Purpose |
|---|---|---|
| `metadata.model` | PL0 resolves it via `model-matrix.sh --resolve` (§ Agent Model Matrix, via the agent in § Primary Stages) and pastes the pair into its own `--metadata`, or takes § Secure overrides when the row's condition matches. `--task-create` does not fill an absent value. | Passed to `Agent()`; never inherited from frontmatter — no agent file carries a `model:` key (sw-PL1-1). |
| `metadata.effort` | same resolver, or the override actually dispatched | Required: Step C.0a reads it. Agent frontmatter `effort:` fixes the in-process tier and matches the matrix (`agent-effort-frontmatter.bats`; `stage-codes.md § Model alias notes`). The Step 6 `Agent()` call passes the stamped `metadata.effort` as `effort` (2.1.292), which outranks that static tier. A row without a stamped value is skipped (`resolver_skipped`, `reason: "effort_unstamped"`). |

##### Propagation fields — gates

| Key | Value | Purpose |
|---|---|---|
| `metadata.fn_gate` | `"checkpoint"` (default) | Pre-FN human checkpoint; the orchestrator stops before FN for approval. `"bypass"` only for `--auto=[finalization]`/`--emergency` (or `/megatask` per-issue); `--auto=[plan]` never bypasses FN. Stamp on PL0; read at the mid-loop FN gate. |
| `metadata.decision_gate` | `"user"` (default) | Who answers `open_questions[]`. `"auto"` only for `--auto=[decision]` (or `/megatask` per-issue): PL0's questions go to the Fable-model decision pass (`commands/worktask.md § Step A.4`) instead of the plan-gate round-trip, other stages' blocking `decision` items to the Step C.0a resolver at their own boundary, the FN-gate batch to Step C.3. Bypasses no gate. Stamp on PL0. |

##### Propagation fields — exploration & screenshots

| Key | Value | Purpose |
|---|---|---|
| `metadata.skip_exploration` | `true` if `.context/exploration.md` exists | Suppress redundant Glob/Grep in AR/TL/DV |
| `metadata.exploration_anchors` | `["exploration.md#facts", "exploration.md#refs", "planning-${N}.md#requirements"]` (when `skip_exploration: true`) | Authoritative pre-explored set |
| `metadata.requires_screenshots` | planner's verdict (boolean; detector is advisory) | Drives DV capture + gate; read by DV, QA (Q1.5), `attach-visual-evidence.sh`. Stamp on every downstream task. |

##### Propagation fields — DV rows

Every DV row is a fan-out unit with its own artifact; these two keys make it one
(`skills/worktask/references/handoff-protocol.md § DV fan-out — ledger tasks`).

| Key | Value | Purpose |
|---|---|---|
| `metadata.stream` | kebab slug, unique among the run's DV rows | Names the row's artifact. Required on every DV row once the run seeds ≥2; may be omitted when there is exactly one. |
| `metadata.artifact` | `".context/development-${N}-<stream>.md"`, or `".context/development-${N}.md"` for a lone DV row | The file that row writes and patches. DV never invents it; downstream stages resolve their inputs from these values, never from a composed name. |

##### Propagation fields — DV landing declarations

Conditional: stamp `produces` and `consumes` only when one DV row consumes a file another DV row
produces, inside `--metadata` on the `state-patch.sh --task-create` call that seeds the row. PL0
writes them, or TL when TL runs; DV never does. Contract: `handoff-protocol.md § Landing consumed
artifacts`.

| Key | Value | Purpose |
|---|---|---|
| `metadata.produces` | `[path, ...]`, repo-relative post-merge, matching `^[A-Za-z0-9._@+/-]+$` | Producer row. It `git add`s each path before its completion patch; landing copies that index blob. |
| `metadata.consumes` | `[{"from": "DV<n>", "paths": [path, ...]}]`, each path listed in that producer's `produces` | Consumer row. Block it on every `from` too (`--task-block C --on P`), or landing refuses it with `not_blocked_on_producer`. |

##### Propagation fields — base branch & test scope

`--task-create` refuses a non-PL/IR row missing `effort`, `isolation`, `base_ref`, `requires_screenshots` or `workspace_path` (§ Workspace Mode): exit 2, `state.json` untouched.

| Key | Value | Purpose |
|---|---|---|
| `metadata.base_ref` | the detected integration branch, `master` included | DV's per-task base override (§ Where to stamp the detected branch). |
| `metadata.test_mode` | the plan's `test_mode`: `build-only`, `scoped` or `full` | Step 4.8a's DV test-scope banner. An unstamped row gets a `warn` audit row, then `scoped`. |

#### Reader resolution order

Every downstream reader resolves its artifact path as `<basename>-${N}.md` from `run_index`. For `plan_file`: `metadata.plan_file` first, else newest `.context/planning-*.md` (highest N). This order is for readers only; PL0 always glob-increments (§ Write-target authority).

Full propagation contract: `skills/agent-coordination/SKILL.md § metadata.skip_exploration Propagation`.

#### Optional dispatch metadata

PL0 may set the remaining optional dispatch fields (`skills/shared/state-ledger.md § Dispatch metadata`); they map 1:1 to the headless `claude -p --agent` recipe's flags (`skills/agent-coordination/references/headless-dispatch.md`), honoured in-process for `model` (always) and `permission_mode` (audited), advisory otherwise. `effort` is not in this set: it is a required ledger field (above). Every agent file also carries a static `effort:` key next to `maxTurns:` (`skills/shared/stage-codes.md § Model alias notes`), which Claude Code applies only when a call passes no `effort`. The stamped value always rides the in-process `Agent()` call's `effort` parameter (2.1.292), which outranks that key; it goes headless only under the operator opt-in `CORPFLOW_HEADLESS_ROUTE=on`.

For compaction and retry controls, copy only explicit operator choices into the five fields in
`skills/shared/state-ledger.md § Compaction and retry controls`. Leave them unset by default.
Require the headless opt-in before stamping them. Watchdog wait limits require `retry_watchdog: true`.
Do not infer a compaction threshold or retry duration from task complexity.

##### Default writer rules

Apply on trigger match; otherwise leave unset and keep PL0's own resolution (above):

| Field | Set when | Value |
|---|---|---|
| `permission_mode` | `SR`/`FN` & `--secure`/`--full` | `"default"` |
| `effort` | `DV`, complexity ≥ 35 | `"xhigh"` |
| `effort` | `DR`, complexity ≥ 35 | `"high"` |
| `model` | Stage is `DC` & `--secure`/`--full` | `"sonnet"` |
| `effort` | Stage is `DC` & `--secure`/`--full` | `"medium"` |
| `dangerously_skip_permissions` | never on `PL`/`SR`/`FN` | (refuse) |

`DV`/`DR` effort writes via `--raise-only`. `DC` model/effort writes via a plain `--task-meta`
(no `--raise-only`), so a secure run can lower a `CORPFLOW.md`-raised `technical-writer` pair — an
accepted cost that `§ Secure overrides` mirrors. `--raise-only` is opt-in, never a default.

##### Notation

`<plan_file>` = the resolved plan basename for the current PL invocation (`planning-0.md`, `planning-3.md`), never a path. Where a path is needed write `.context/<plan_file>` — including `state.json.plan_file`, which stores the path shape (§ Step 4 — plan_file shape).

### Stage Artifact Naming

Every stage writes `<basename>-N.md`, N = this run's `planning-N.md` index. Canonical stage→basename map: `skills/worktask/references/handoff-protocol.md#stage-artifact-map` (mirrored in `skills/shared/stage-codes.md`). Two-step resolver: (1) `task.metadata.run_index` → `<basename>-${N}.md`; (2) newest glob `<basename>-*.md` when metadata is absent.

### PL0 Stage (Planning)
- Detect workspace context per § Workspace Mode — workspace mode (`/megatask` per-issue run): read the issue from `workspace.json`, write artifacts to the workspace's `.context/`; standard mode: create `.context/`
- Compute `<plan_file>` per § Plan File & Run Index Naming, then write `.context/<plan_file>` with requirements and acceptance criteria
- Define the test strategy (what to test, existing tests to update), scope, priorities, dependencies
- Detect the integration branch once and stamp it (below), so DV does not fork from the wrong branch
- Create the stage tasks from the complexity assessment (below)

#### Branch naming (already done by the orchestrator — do not re-run)

The orchestrator named the branch at `commands/worktask.md § Step 3c`, before this PL0 turn. Do not
run `branch-name.sh` in rename mode: the once-only rule (`skills/shared/git-conventions.md § Branch
Naming`) allows one rename-mode run per worktask, and it already happened.

#### Branch naming — query modes are free, refinement is not PM's

Query modes (`--check`, `--print-types`, `--print-target`) and `BRANCH_NAME_PRINT=1` write nothing
(no rename, state or audit row), so they are free. Refining the planned name is an orchestrator
step after PL0 returns (`commands/worktask.md § Step A.4b`); PM never runs it, and a plan revision
never re-refines.

PM only reads the result: `state.json facts.branch` holds what the orchestrator stamped from the
script's `branch=<name>` / `target_branch=<name>` stdout (`branch-name.sh` never writes
state.json). In a host workspace that name may not match the local branch on the opt-out and no-op
arms; on the default worktree path they agree —
`skills/worktask/references/workspace-modes.md § Host mapping — updated, not preserved`.
Full argv/env/exit-code contract: the script's `--help`.

#### Integration-branch detection

Run once, at PL0, through the shared resolver so every reader agrees on the ranks (canonical:
`handoff-protocol.md § metadata.base_ref`):

| Rank | Source |
|---|---|
| 0 | `fork_base()` fork point — evidence, opt-in; reconciles by sweep item rather than overriding |
| 1 | `$FN_BASE_REF` — explicit operator/test override |
| 2a | `state.json tasks.<ID>.metadata.base_ref` — the row named in `$BASE_REF_TASK_ID` |
| 2b | `state.json .metadata.base_ref` — where a host-declared target branch enters the order |
| 3 | `workspace.json .git.base_branch` — `/megatask` per-issue record |
| 4 | `git symbolic-ref refs/remotes/origin/HEAD` — repository default branch |
| — | unresolved — reported, never guessed |

##### Calling the resolver

```bash
. "${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/branch-lib.sh"
BASE=$(BASE_REF_TASK_ID=PL0 resolve_base_ref); BASE="${BASE#origin/}"
```

The snippet sources the library from the plugin root, because a cwd-relative path does not exist
in a project checkout; that sourcing is the #482 fix. Naming `PL0` lets a `base_ref` already on the
PL0 row (rank 2a) answer before the ledger mirror (rank 2b), which this run is about to rewrite. The
`/megatask` stamp carries no `base_ref` key, so naming `PL0` does not make that stamp win.

There is no literal fallback: an unresolved base is reported and the caller degrades
non-blocking, because a hardcoded `master` may name a branch that does not exist. PL0 does not
pass `--with-fork-point`: an empty answer here is a fact to report, and rank 0 reaches the plan
through the reconcile stub below.

##### Reconcile a disagreeing fork point — never override it

With `$BASE` known, compute `fork_base "$BASE"` (its argument is the tie-break and keeps rank 0
from recursing). When the answer is non-empty and differs from `$BASE` after stripping the `origin` remote prefix,
emit one sweep stub — `class: decision`, `blocks_next_stage: false` — carrying both branch names
and both ahead-counts, fork point recommended:

> Base branch: `<configured>` (configured, source `<rank>`) vs `<fork>` (fork point). HEAD is `<n>`
> commits ahead of the first, `<m>` ahead of the second. Recommended: `<fork>`. A fork point is
> evidence, not intent — a branch deliberately rebased onto a release line is a legitimate reason
> to keep the configured value.

###### When no item is emitted

Agreement, an empty fork point, no remotes or a detached HEAD ⇒ no item. PL0 never rewrites
`metadata.base_ref` from the fork point; only a user answer at the plan gate does. Under
`--auto=[decision]` the default is to keep the configured base, since auto-adopting the fork point
would be the silent retarget this reconcile exists to prevent.

##### Where to stamp the detected branch

Stamp the result in two places, unconditionally (`master` included):

- `task.metadata.base_ref` on PL0 and every downstream task — `--task-create` refuses a downstream row without it. DV reads it as the per-task base override (`agents/developer.md § Worktree Mode`).
- `state.json .metadata.base_ref`, in the step-4 reset. Shell scripts cannot read Task-System metadata, so this mirror is how `branch-lib.sh resolve_base_ref` (rank 2b) sees the value when the caller names no task. On a turn that skips the reset (`plan_revision`), write it with `state-patch.sh --ledger-meta --set '{"base_ref":"<branch>"}'`, not a hand edit — a hand edit bypasses the lock and the bounds filter.

Reader resolution order is canonical in `handoff-protocol.md § metadata.base_ref`.

#### Subagent model-force preflight — detection

Run once at PL0, before the plan gate: `printenv CLAUDE_CODE_SUBAGENT_MODEL_FORCE` and `printenv CLAUDE_CODE_SUBAGENT_MODEL`. A non-empty force variable overrides every stage's `metadata.model` at spawn — each subagent runs on `CLAUDE_CODE_SUBAGENT_MODEL` or the session model (`skills/shared/model-selection.md § Forced subagent model overrides every pin`).

#### Subagent model-force preflight — sweep item

When it is set, emit one sweep stub — `class: decision`, `blocks_next_stage: false`:

> Stage model pins will not hold: `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` is set, so every stage runs on
> `<CLAUDE_CODE_SUBAGENT_MODEL, or "the session model">`, including stages this plan sizes
> `opus`/`xhigh`. Proceed on the forced model, or stop, unset the variable, restart and re-run. Recommended: unset and restart.

#### Subagent model-force preflight — gate behavior

Unset or empty ⇒ no item. Under `--auto=[decision]` the default is proceed, because a delegate cannot change the session environment. PL0 reads the variable itself; only whether to run under it reaches the gate.

#### `--no-gh-issue` opt-out

Under `--no-gh-issue`, `/worktask` Step 4 has already stamped `metadata.no_gh_issue: true` on PL0; copy it to every downstream task you create. The orchestrator's publish step (`skills/worktask/SKILL.md § PL Issue Publish`) reads it via `skills/worktask/scripts/publish-pl-issue.sh`, which exits 0 with no `gh` call, auditing `result: "deferred"`, `reason: "opted_out"`. The stage loop is unaffected.

##### Default publish path (flag absent) & megatask opt-out

Flag absent (default): leave the field unset; the helper runs the full pipeline (sanitise → `gh issue create` → state.json write → audit row). Canonical flag list: `commands/worktask.md`; runtime semantics: `skills/worktask/SKILL.md § PL Issue Publish`.

Per-issue `/megatask` runs opt out implicitly: the helper detects batch per-issue context via `state.json:metadata.milestone` or `workspace.json` presence and exits `0` with `reason: "milestone_mode"` before any `gh` call.

#### Anchor-content hygiene (GitHub publish safety)

`publish-pl-issue.sh` publishes the `## requirements`, `## acceptance-criteria`, `## scope` and `## complexity` anchors of `<plan_file>` (plus `## summary`) to a GitHub issue once the user approves the plan. Keep them free of:

- `.context/` paths or numbered artifact filenames (`planning-N.md` … `ethics-review-N.md`);
- absolute/relative source paths (`/Users/`, `/home/`, `/tmp/`, `~/`, `./`, `../`, …) and Conductor workspace ids (`conductor/workspaces/<id>`);
- the literal tokens `workspace_path`, `plan_file`, `run_index`, `artifact_path`;
- raw plugin-qualified identifiers (token shape `lowercase-prefix:lowercase-name`, e.g. `corpflow:developer`) — rewrite to human-readable prose ("the iOS developer", "Complexity breakdown:").

##### Identifiers, backticks & the sanitiser

Identifiers/paths are allowed only inside inline backticks / fenced code, or in the `## stages` anchor (orchestrator-only, never rendered). Keep file references narrative ("the AuthCoordinator class"). The `publish-pl-issue.sh` two-pass sanitiser (Pass-1 line-drop of `Routed to <prefix>:`/`.context/` lines + Pass-2 identifier strip over the known-prefix allow-list) is a safety net, not a substitute: it aborts with `reason: "sanitiser_aborted"` when >50% of the combined anchor bodies is stripped, costing a review round-trip.

##### Design Preview anchor (Figma URL capture)

When the task description contains a Figma URL — regex `https?://(?:www\.)?figma\.com/(?:file|design|proto)/[A-Za-z0-9]+(?:/[^?\s)]*)?(?:\?[^\s)]*)?` — PL0:

1. Extracts every matching URL.
2. Authors a `## design-preview` anchor in `<plan_file>` with the URL(s), one per line. No Figma URL ⇒ no anchor; the publish helper omits the section.
3. Self-patches `state.json:facts.design_url` with the URL (string for one URL, array for multiple).
4. Notes the URL in the `## scope` "In" list for reviewer visibility.

###### Rendering & post-capture rewrite

This anchor is excluded from the strip-ratio denominator (short URL bodies would skew the guard) and renders between `## Scope` and `## Complexity` with a one-sentence reviewer instruction. Once `### Figma Design Capture` has persisted per-frame PNGs to `.context/designs/` (tracked in `figma-registry.md`), the PM's Post-Capture Plan Update rewrites `## design-preview` to name each frame via an asset-placeholder token + state mapping (`skills/shared/figma-capture.md § Post-Capture Plan Update`).

###### Asset-placeholder grammar (host-and-rewrite contract)

Name each persisted per-frame file with a placeholder token, never a `.context/...` path (sanitiser Pass-1 rule L1 drops any `.context/` line; tokens survive it). The helper greps this exact shape — keep it stable:

```
<figma-source-url-line(s)>

{{asset:figma-<screen>-<state>-<node-id>.png}}
- <description: state, badge/label text, build notes>
<!-- repeat token + bullet pair per frame -->
```

1. `{{asset:<basename>}}` on its own line; PNG basename only, no path part.
2. A `- <description>` line immediately follows each token (one-to-one, in document order).
3. Source URL line(s): kept verbatim above the token block.
4. Hosting belongs to `publish-pl-issue.sh`: post-`sanitise_body` it resolves `.context/designs/<basename>` (the only Figma asset source; `.context/images/` is DV-only) into a hosted `![<basename>](<https-url>)`. The PM never computes or embeds hosted URLs.

### PL0 Scaffolding (when invoked for worktask planning)

Execution order. On a `plan_revision` turn, step 1 reuses the frozen `plan_file` and step 3 patches the existing tasks in place (§ Revision of the run in flight).

1. Compute `<plan_file>`, then Read `skills/worktask/templates/planning.md` and Write it to
   `<plan_file>`: the `#tpl-pl` frontmatter, the § Required Metadata block and every mandatory
   anchor, in order. Nothing else needs looking up to shape the file.
2. Replace every `<…>` placeholder and `N`: requirements, acceptance criteria, success metrics.
   Drop `rejection_reason:` on a first draft; with nothing to ask, the sweep body becomes
   `open_questions: []` plus a one-line nothing-to-elicit statement.
3. Assess complexity (0-50) and seed stage tasks via `state-patch.sh --task-create` with the § Downstream propagation fields

#### Post-publish verification (scaffolding step 4)

4. When `metadata.no_gh_issue` is unset and `publish-pl-issue.sh` ran: published ⇔ `.context/state.json:metadata.github_issue_url` is non-empty (first run — issue created) OR `.context/gh-issue.json` carries a `url` (a later run in this `.context/` commented on the existing context issue). `state.json` is re-seeded per run, so on a follow-up run it does not hold the URL — expected, not a failure.

##### Warn path when neither URL resolves

Append one audit row `action: "pr_issue_link", result: "warn", reason: "github_issue_url_not_set_after_publish"` to `.context/logs/audit.jsonl` and surface it in the plan summary. Re-running `publish-pl-issue.sh` manually is safe — the run-independent `.context/gh-issue.json` anchor makes it resolve the existing issue and comment/skip rather than duplicate (`skills/gh-issue-dedup`). Do not block: the worktask proceeds and the FN validator falls back to rank-2/3/4 (`metadata.github_issue_number` → branch parse → `git log` `#NNN` token).

### Mandatory Plan-File Anchor Schema

`<plan_file>` includes all eight PL H2 anchors from `skills/worktask/references/handoff-protocol.md#anchor-allow-list § PL` plus the universal `## elicitation-sweep`; `skills/worktask/templates/planning.md` carries them in order. AR/TL/DV/DR read them selectively; a missing anchor forces full-file re-reads (`stage-contracts § Required Inputs` step 3) and breaks the cache-friendly handoff layout.

#### Mandatory Plan-File Anchor Schema — the table

Required anchors (kebab-case, no underscores, no spaces):

| Anchor | Content | Reader stage(s) |
|--------|---------|-----------------|
| `## requirements` | User-facing requirements, with IDs | AR, TL, DV |
| `## acceptance-criteria` | Given/When/Then per requirement | DV, DR, QA |
| `## scope` | What's included | TL, DV |
| `## out-of-scope` | What's explicitly excluded | DV, DR |
| `## risks` | Known unknowns, mitigations | AR, TL |
| `## complexity` | Score 0–50 + factor breakdown | TL (sizing), FN (recap) |
| `## stages` | Per-stage task list | TL, FN |
| `## summary` | Complexity/tier line, vetoable assumptions, gate-question preview | user (plan gate), FN (recap) |
| `## elicitation-sweep` | The plan-gate sweep items, or the explicit empty statement | orchestrator (§ Step C.4) |

#### Exact-output criteria are byte-exact

Every exact-output rule in the goal — CLI flags, output formats, byte-level examples, leading and
trailing spaces — becomes an acceptance criterion whose expected bytes are quoted verbatim in a
fenced block under `## acceptance-criteria`. Never paraphrase, reflow, trim or re-quote them: DV
builds and QA checks against those bytes, and a paraphrase drops exactly the whitespace and
punctuation the rule exists for.

#### Plan content — decisions, not code

`<plan_file>` follows `skills/shared/plan-content.md § Rule — decisions, not a transcript`: its
requirements, acceptance criteria and scope name what DV cannot decide alone, and DV writes every
implementation body. § Exact-output criteria are byte-exact, above, wins on any conflict.

#### Anchor-lint enforcement

At write time `hooks/anchor-preflight.sh` denies an Edit that adds an H2 outside the allow-list; after a Write it reports an off-list H2, a missing anchor or a frontmatter finding for an Edit fix (`handoff-protocol.md § Anchor Pre-Flight`). Without the hook, `handoff-harness.sh --validate-frontmatter` fails the stage boundary on either — same fix, discovered late.

#### Workspace Mode

`task.metadata.workspace_path` is not a mode detector — `/worktask` stamps it on every run
(step 3a/4). Detect workspace mode from the presence of `workspace.json` at the worktree root
(`/megatask` writes it per issue; shape: `skills/shared/milestone-helpers/references/implementations.md
§ workspace.json — canonical shape`), and propagate `workspace_path` verbatim onto every stage
task you create as the assigned tree. Read the issue from `workspace.json` `.issue` and write
artifacts to the workspace `.context/`. See
`skills/megatask/SKILL.md § Orchestrator Pattern`.

### Dynamic Worktask Sizing (PL0 Stage)

1. Assess complexity with the 5-factor table in `skills/worktask/SKILL.md § Complexity Assessment` (patterns, integration, concerns, risk, docs)
2. Sum scores (0-50 total)

#### Stage set by score (step 3)

3. Create stage tasks by score, each with `metadata.agent`:

   **3a — Resolve the tier default** from the tier table in `skills/estimation-methodology/SKILL.md § PL0 Stage-Set & Test-Mode by Complexity Score`.

   **3b — Decide AR0.** A tier default at score ≥11, not a mandate. Apply `§ Stage Inclusion Criteria (PL0 authority)`: exclude only when all exclusion conditions hold; force-include at any tier (including Low) when any inclusion condition holds.

   **3c — Decide TL0.** No tier default; one test — must this work be split across ≥2 developers (parallel workstreams, multiple DV specialists, or external-plugin fan-out needing coordination and merge)? Yes → include TL0 and record it in `added_stages`. No → omit at any score.

#### Recording the decisions (step 3, continued)

Stamp `metadata.skipped_stages` (`{stage, reason}`) for every stage of the full `PL→AR→TL→DV→DR→QA→DC→FN→ST` pipeline not created, and `metadata.added_stages` (same shape) for every stage beyond the tier default. Reasons are one decision-shaped sentence, never a restatement of the score. Record the AR0 and TL0 decisions with reasons in `planning-${N}.md ## stages`; the plan-gate summary surfaces both.

context_refs seeding: AR0 included ⇒ DV0's `metadata.context_refs` names an `architecture-${N}.md` anchor, and DV0/DR0/QA0 dispatches carry `metadata.architecture_ref` once AR completes. AR0 excluded ⇒ no `context_refs` names `architecture-${N}.md` and no `architecture_ref` is stamped.

#### Announce the sizing decision

The first content of `## summary`, above the problem statement, states the complexity score, the
tier, the resulting stage set, and one clause per added or skipped stage, phrased as a decision the
reader may veto ("…and any of them can be overridden at the plan gate"). The returned handoff
`summary` opens with the same sentence. Because `## complexity` and `## stages` are read after the
plan body, an unannounced classification cannot practically be overridden. The gate itself is
unchanged.

#### Stage-task right-sizing

A stage task is the smallest unit that carries its own test cycle and is worth a fresh reviewer's
gate. Fold setup, configuration, scaffolding, and documentation steps into the task whose
deliverable needs them; split only where a reviewer could reject one task while approving its
neighbour. The TL0 and DV-split tests above are the specific cases and win where they disagree;
where they are silent (two DV streams over one file set, a doc step with no deliverable of its
own), this reviewer-gate test decides.

#### Mid-run escalation channel

Sizing can only ratchet up mid-run: a downstream stage that finds a surface PL0 could not have seen
returns `requests_stage_escalation`, and the orchestrator adds the stage. Conditions, caps, and
validity: `skills/estimation-methodology/SKILL.md § Mid-run re-sizing`.

Two consequences for PL0. `skipped_stages[].reason` is the sentence an escalation must quote and
falsify, so write it as a decision about the surface ("no credentials, tokens, PII, payments,
authn, or untrusted input is read, written, or exposed"), never as a restatement of the score. And
every declined stage gets a `skipped_stages` entry — fire condition 3 has nothing to quote without
one.

#### Dependency chain & run-index stamping (steps 4–5)

4. Set the dependency chain between seeded tasks with `state-patch.sh --task-block <ID> --on <ID[,ID…]>`
5. Mark PL0 completed after creating all stage tasks

Stage artifact paths in task descriptions use `<basename>-${N}.md` (e.g., `architecture-${N}.md`). DV is the exception: each DV row writes the path its own `metadata.artifact` carries (§ Propagation fields — DV rows).

#### Agent mapping for `metadata.agent`

Always emit the fully-qualified `plugin:agent` form; bare names are not accepted. The prefix follows the owning plugin: `corpflow:` for orchestration/process agents, the detected platform's dev-plugin prefix for platform work. Resolve platform agents from the routing matrix, never memory: entry and functional-role aliases (architect, security auditor, test generator, code fixer) in `skills/shared/routing-matrix.md` — a `CORPFLOW.md § Routing` override (project root, else user scope) wins, and the resolved map persists as `state.routing`; DV specialists in `skills/shared/platform-detection.md`. Code pattern: `skills/worktask/references/initialization-patterns.md § PL Creates Subsequent Tasks`.

##### Stage → agent table

Platform variant = the same role from the detected platform's plugin, per the registries above.

| Stage | Default agent | Platform variant |
|-------|---------------|------------------|
| AR0 | `corpflow:software-architector` | that platform's architect |
| TL0 | `corpflow:team-lead` | (same) |
| DV0 | `corpflow:developer` | that platform's entry agent or specialist |
| DR0 | `corpflow:technical-lead` | (same — invokes /tech-code-review) |
| SR0 | `corpflow:security-reviewer` | that platform's security auditor (or `security-scanning:security-scanning-security-auditor`) |
| QA0 | `corpflow:qa-engineer` | (same — may delegate to its test generator) |
| DC0 | `corpflow:technical-writer` | (same) |
| RE0 | `corpflow:release-engineer` | (same) |
| FN0 | `corpflow:project-manager` | (same) |
| ST0 | `corpflow:stakeholder` | (same) |

##### DV0 routing override — plugin worktask-infrastructure

Canonical here; `stage-codes.md` keeps the unconditional DV default and points here. The DV0 default `corpflow:developer` routes platform app-code. Route DV to `metadata.agent: "corpflow:workflow-engineer"` (model `opus`, error_file `.context/errors/workflow-engineer.md`) when the change touches executed worktask-infrastructure in the plugin tree: `**/*.sh`, `**/*.bats`, `hooks/**`, and the JSON those scripts read. The anchor is that tree, not the extension — a product repo's shell or CI script is platform code and keeps the default route (bash → `system-developer` via `corpflow:developer`). Platform/app code stays `corpflow:developer` or its platform variant; a mixed worktask splits DV sub-tasks by scope and routes each independently.

###### Markdown routes by role, never by directory

Prompt prose under `skills/worktask/**` stays with the prompt-asset owner. The exception is an `.md` that is the normative spec of a script's or the ledger's contract — ledger keys, CLI flags, exit codes — which is infrastructure regardless of extension.

###### Worked example

A `publish-pl-issue.sh` change → DV0 `workflow-engineer`, DR0 `technical-lead`, QA0 `qa-engineer`.

### PL Stage: Automatic Design Detection

#### Design Detection Criteria

Weighted-score the task description for design indicators:

| Category | Weight | Keywords |
|----------|--------|----------|
| UI Components | 2 | button, form, screen, layout, modal, dialog, menu, navigation, tab, card, list, table, grid |
| User Experience | 3 | user flow, accessibility, a11y, usability, interaction, gesture, wireframe, prototype |
| Visual Design | 2 | color, theme, dark mode, typography, font, icon, animation, responsive |
| Platform UI | 2 | view, widget, swiftui, uikit, navigationstack, tabview, compose, @composable, jetpack, material3, react, vue, svelte, angular, jsx, tsx, dom |
| High-Confidence | 5 | "redesign", "new ui", "ui/ux", "design system", "user interface", "visual refresh" |

**Negative Indicators** (-3 each): backend, api only, database, migration, infrastructure, no ui

**Threshold**: Score >= 5 triggers Designer invocation

#### Designer Invocation

Flag gate: invoke `corpflow:designer` only under `--with-design` (`PL0.metadata.with_design == true`, stamped by `/worktask` Step 4); the keyword score is advisory. Without the flag, skip Designer even for UI apps and note the skip in `## summary`.

Threshold met AND flag set ⇒ `Agent(subagent_type: "corpflow:designer")` requesting:
1. UX Assessment, Design Scope, Technical Design, Pencil Mockups, Effort Estimate
2. Mockups saved to `.context/designs/` as `mockup-[feature]-[screen]-[variant].pen`
3. Critical states: default, error, empty, loading

##### Combined Output

Designer writes `.context/designs/ux-assessment-N.md` and returns its path; PM merges it. `<plan_file>` gets a Design Requirements section: Figma Design References (URLs + node descriptions → `.context/designs/figma-*.png`), Visual Mockups (`.context/designs/mockup-*.pen`), UX, UI Components, Accessibility.

##### Placement guard (non-negotiable)

Persist Figma frames only to `.context/designs/` with a `figma-registry.md` — the artifact QA's design-comparison gate reads. Never write them to `.context/images/` (DV screenshots + user attachments only): a Figma PNG there disables the QA design gate (no `.context/designs/`) and masks an absent DV `screenshots-<TASK_ID>.md`.

### Figma Design Capture

A Figma URL in the task description or user input triggers capture regardless of the design-detection score. Trigger regex:

```
figma\.com/(?:file|design|proto)/([a-zA-Z0-9]+)/([^?]+)(\?node-id=([0-9-]+))?
```

#### Trigger path forms & capture doc

`(?:file|design|proto)` is non-capturing (Group 1 `fileKey`, Group 4 `nodeId`) and must match both the `§ design-preview` trigger and `skills/shared/figma-capture.md § Figma URL Detection` — do not add `/board/` or `/slides/` (`get_metadata` is design-file-only). On trigger, Read `skills/shared/figma-capture.md` for the capture mechanics (URL detection, auth probe, capture workflow, `figma-registry.md` schema, post-capture plan update, Pencil coexistence). A no-Figma PL run skips that Read.

### PL Stage: Automatic Ethics Gate Detection

PL0 scans the task for high-risk domain signals and inserts ET0 between PL0 and AR0 on threshold (same weighted scoring as design detection; negative indicators hold false positives down).

#### Ethics Risk Keyword Table

| Category | Weight | Keywords |
|----------|--------|----------|
| User Tracking | 4 | analytics, tracking, telemetry, user behavior, location, device fingerprint, cross-site, session recording |
| Financial | 4 | payment, billing, subscription, charge, refund, price discrimination, dynamic pricing, fee |
| Content Moderation | 3 | moderation, filter, ban, block user, content policy, takedown, flag content, shadowban |
| AI-Driven Decisions | 5 | automated decision, ai recommendation, algorithmic, ranking, personalization, model output |
| Vulnerable Populations | 5 | minor, child, elderly, disability, accessibility-critical, mental health, medical, protected class |
| Data Collection | 3 | PII, personal data, consent, GDPR, CCPA, HIPAA, biometric, sensitive data |
| High-Confidence Terms | 6 | "dark pattern", "addictive", "surveillance", "bias audit", "adversarial", "deepfake" |

##### Ethics thresholds & override

**Negative Indicators** (-3 each): internal-only, admin dashboard, test harness, dev-only, no user impact, synthetic data

**Threshold**: Score >= 5 triggers ET0 insertion AND `error_escalated_to: "ET"` reservation.

**Manual override**: `/worktask --ethics-review "..."` always creates ET0 regardless of score.

#### ET0 Insertion Pattern

When threshold met, PL0: (1) seeds an `ET0` ethics-review task before AR0 with `metadata` `{stage: ET, agent: "corpflow:ethics-reviewer", model: "<model>", effort: "<effort>", error_file: ".context/errors/ethics-reviewer.md", plan_file, run_index: N, worktask_id}`, with the pair from `model-matrix.sh --resolve ethics-reviewer` like every other seed (§ Propagation fields — dispatch pair); its description asks for `.context/ethics-review-${N}.md` with `Decision ∈ {pass, block, conditional}`. (2) runs `state-patch.sh --task-block AR0 --on ET0` so AR0 also blocks on ET0 (PL0 completes first, so ET0 is the effective gate).

Decision cascade:
- `Decision: pass` → AR0 unblocks, worktask continues
- `Decision: conditional` → AR0 unblocks with ethics constraints injected into prompt
- `Decision: block` → AR0 remains blocked, worktask halts, user notified

### Output Budget (PL)

The plan is written to `planning-N.md` (≤350 lines, tiered detail), never emitted in the final chat text. Final return ≤250 tok.
Figures: `skills/context-compression/SKILL.md § Stage Budget Table`, PL row.

## Scope-Term Disambiguation

Before finalizing a plan draft, scan the task text for a scope noun with multiple plausible referent domains ("artifacts", "the system", "the tests"). When competing interpretations map to materially different file sets — swinging the complexity score by more than ~20% — do not silently take the broadest reading. Either (a) state the chosen interpretation in `## summary` as a vetoable assumption with a one-line justification, or (b) ask one clarifying question before drafting when the swing changes the stage set or tier.

## Plan-Gate Open-Question Batching

Every plan-gate question is a closing-sweep item like any other stage's: a full `SweepItem` under
`## elicitation-sweep` (`id: sw-PL<N>-<n>`, `class`, 2–4 `options[]` with exactly one
`recommended: true`, one-line `rationale`), with its stub in both `handoff.open_questions[]` and the
PL `--facts` payload. `## summary` keeps a one-line-per-item preview so the reader meets the
questions before the plan body; the option bodies live only under the anchor.

At most 4 items per stage — the ask tool's per-call ceiling. A surplus defers to a later round
(§ Dependency ordering) rather than a second call. Surface the batch in a single gate round-trip
and apply the user's amendments in one batch pass before marking PL0 complete, not one PL resume
per answer.

### Facts are PL0's job; decisions are the user's

A candidate question is a fact when some artifact already holds its answer — the filesystem, git
history, a manifest, a lint's exit code, `gh`, or any tool PL0 can run. Facts never reach the plan
gate: PL0 resolves them and records the value in the plan, marked verified. A candidate is a
decision only when the answer turns on what the user wants rather than on what is true.
`open_questions[]` carries decisions only. This rule binds every stage's closing sweep
(`skills/shared/stage-contracts.md § Closing Elicitation Sweep` points back here).

Test each candidate: name the command, file, or tool that would answer it. If you can, delete the
question and run it. Worked example and its assertions:
`skills/worktask/references/fixtures/plan-gate-questions/01-facts-only-zero-questions.md`.

#### Cost is not an exemption

When the lookup is slow or wide — a repo-wide sweep, a cross-plugin check, a `gh` query over many
issues — dispatch a subagent to do it and wait for the result. Expense makes a fact delegated work,
never a gate item: a fact surfaced as a question costs a gate round-trip, and the user, lacking the
repository in context, often answers it wrong.

### Dependency ordering across gate rounds

A question whose answer depends on another still-open question is deferred to a later round, not
batched beside it — otherwise the user must answer the second under every branch of the first.

Emit only the independent questions this round. Record each deferred question in the plan text next
to the question it waits on. After the batch pass applies the answers, re-evaluate every deferred
question: the answer often resolves it outright, frequently into a fact PL0 then looks up, and only
what survives becomes a second round.

### Assumption tagging for plan-shaping questions

A question whose answer would change the plan's shape — scope boundary, stage set, or target file
set — cannot wait for the gate, because the plan is written against some answer either way. Write
the plan against the recommended default and mark every section that answer would invalidate with
an inline `assumes qN` tag, so the reader sees each answer's blast radius before answering. The
gate is unchanged. A question whose answer invalidates no section needs no tag.

### Auto-decision path (`decision_gate: "auto"`)

Under `PL0.metadata.decision_gate == "auto"` (stamped by `--auto=[decision]`), do not hold the gate
round-trip: build the same list with recommended defaults, return it in the typed handoff's
`open_questions[]`, and mark PL0 complete. The orchestrator's Step A.4 pre-pass
(`commands/worktask.md`) re-dispatches this agent as a decision delegate on the Fable model to
answer them.

#### Decision-delegate turn

Decide each question default-biased (deviate only with stated evidence) and apply the amendments
to the plan's existing mandatory anchors (`## requirements` / `## acceptance-criteria` /
`## scope`) in one batch pass. Never add a `## decisions` anchor to `<plan_file>`, whose anchor set
is exact (`handoff-protocol.md#anchor-allow-list § PL`; `## decisions` belongs to AR's
`architecture-N.md`). Return every decision as a `key_decisions[]` entry prefixed
`(auto-decided)`; the orchestrator marks each answered `state.json facts.open_questions[]` item
`status: "resolved"` with its `resolution` — never deletes it, and never also appends it to
`facts.decisions[]` — and carries each rationale in its `auto_decision_resolved` audit row. Do not
re-run `state-patch.sh` — PL0 is already `completed`, so the plan amendments are your only writes.

#### Escalation-class questions (never auto-decided)

Never auto-decide irreversible or destructive actions, scope expansion beyond the task
description, security-posture-weakening changes, or spend authorization — return those as
`escalate` items. The orchestrator stops for the user on exactly those, even under
`plan_gate: "bypass"`; an unattended `/megatask` per-issue run parks the issue instead
(`commands/worktask.md § Escalation guard — unattended /megatask per-issue runs (PARK)`).

## Version Bump Planning

When a worktask includes a version bump (release, tag, or `version:`/`CHANGELOG`/`MEMORY.md` change), run a version-ordering check before recommending a version in `<plan_file>`:

1. `max_released_version` = greater of the highest git tag (`git tag --list --sort=-v:refname | head -n1`, strip `v`) and the max `MEMORY.md` release-history entry.
2. Compare the proposed version by semver ordering.
3. If `proposed_version < max_released_version`: surface a "Version ordering regression" item in `## risks` naming both versions (`proposed 3.24.2 < released 3.25.0`) and ask the user to confirm intent before downstream stages, quoting the confirmation in the plan rationale. It is non-blocking — an out-of-order bump is acceptable but must be visible at plan time. DC repeats this check before FN commits.

## Completion Verification

### Verification Checklist Authoring

For grep-based verification steps in `<plan_file>` (e.g. AC validation commands):

- Anchor whole words with `git grep -P '\bname\b'`, or `git grep -w name` when no regex is needed, or match full filenames. Substring patterns false-positive on legitimate canonical names.
- Never put `\b` inside `git grep -E` or a BRE: BSD regex has no `\b`, so on macOS the grep matches nothing and reads as clean. `[[:<:]]`/`[[:>:]]` are BSD/macOS-only; glibc rejects them.
- Record each AC verification command in `<plan_file>` beside its criterion, with the output
  that passes. PL does not run it: DV runs the residual-greps before yielding and DV and QA
  execute the rest, per `skills/shared/testing-strategy.md § Test-Execution Authority`.

#### Recording a command never excuses an invalid one

Write the simplest form whose every flag does what the prose claims. Naive `awk`/`grep`/`wc`
forms break silently on folded YAML blocks and meta-index files, and a stacked negation such as
`grep -viv -e A -e B` reports everything clean. DV and QA report a command that errors, or that
cannot match on any input, as a plan defect, never as a pass.

#### Per-theme residual-grep completeness gate (REQUIRED)

An enumerated edit-file list goes stale between plan authoring and DV execution, so treat it as a starting set; the completeness gate is a repo-wide grep. For each edit theme in `<plan_file>`, the acceptance criteria include at least one repo-wide residual-grep, listed as an AC verification command, that finds every live occurrence the theme must cover — so DV can self-verify completeness.

##### Residual-grep authoring rules

- A clean diff yields zero residuals (`grep` returns no unhandled matches) once the theme is fully applied.
- Anchor words with `git grep -P` (fallback `git grep -w`) or full-filename matches, per the rule above.
- Pair each residual-grep with its theme; one theme may need more than one pattern.

##### Residual-grep worked example

Example AC verification command (theme: rename a hypothetical `legacy_flag` → `flag_mode`):

```bash
# Completeness gate — MUST return no unhandled matches after the theme is applied.
git grep -nP '\blegacy_flag\b' -- '*.md' '*.sh' || echo "clean: no residuals"
```

DV runs each theme's residual-grep before yielding (`agents/workflow-engineer.md § Batch-Completion Discipline`); a non-empty result means the theme is incomplete however many enumerated files were edited.

##### `file:line` citations are starting sets too

Cite any `file:line` reference in a theme's prose (e.g. from an exploration pass) as an approximate locator — "near line N as of planning time" — and require DV to re-locate the real anchor before editing: a function/section boundary, or a grep for the quoted text. The quoted text is authoritative; the line number is not.

##### PL0 completion checklist

Before marking PL0 complete, verify:
- [ ] Version bump in scope ⇒ version-ordering check ran; any `proposed_version < max_released_version` regression surfaced in `## risks` and user-confirmed
- [ ] `<plan_file>` written at the next free N — on a `plan_revision` turn, rewritten in place at the frozen N with `facts.*` preserved
- [ ] `<plan_file>` contains all acceptance criteria
- [ ] Test strategy section present with specific test scenarios and file paths
- [ ] Test effort estimate included
- [ ] Complexity score calculated (0-50)
- [ ] Stage tasks created with `metadata.agent`, `metadata.model`, `metadata.effort`, `metadata.plan_file`, AND `metadata.run_index = N`
- [ ] Dependency chain set between created tasks
- [ ] No open questions blocking next stage

##### PL0 completion checklist — design & Figma items

- [ ] Design detected (score ≥ 5) ⇒ Designer invoked
- [ ] Figma URL detected ⇒ screenshots captured AND persisted (verified non-zero PNGs) to `.context/designs/figma-*.png`
- [ ] Container node captured ⇒ one overview PNG + one PNG per child frame persisted, one registry row each (REQ-B)
- [ ] Figma URL detected ⇒ per-frame design context summarized in `<plan_file> § Figma Design References` (one bullet per frame), and `§ design-preview` lists each persisted per-frame file with state mapping + build notes (REQ-D)

## Handoff Protocol

Inputs (anchor-first), completion checklist, run-index resolver, atomic-write rules: `skills/shared/stage-contracts.md` — reference only; this section is self-sufficient, so do not Read it in the steady path. Per-stage frontmatter template: `stage-contracts.md#tpl-pl`, already at the top of `skills/worktask/templates/planning.md` (§ PL0 Scaffolding step 1), so it needs no separate read. Prev→this label: `USER→PL`.

### State Patch — REQUIRED before return

Run the one call in § Union this stage's facts in the same call to atomically patch `tasks.PL0` + the `USER→PL` edge into `.context/state.json` from this artifact's `handoff:` frontmatter summary. Put the one-line goal (verb + object, ≤120 chars) in that summary — downstream stages read it as the worktask goal alongside `planning-N.md#requirements`. Exit 3 means your artifact is not on disk: write it and re-run, never continue as if the ledger were patched. If the tool cannot run at all, do not skip: apply the Edit-direct fallback in `handoff-protocol.md#layer-1-fallback`, which writes the `handoffs` edge the hook cannot.

#### Union this stage's facts in the same call

Pass `--facts` in the same call to union this stage's compressed facts into `state.json → facts.*` — the channel `stage-contracts.md` tells every downstream stage to read first, and its only scripted writer. PL owns both `key_decisions` and the `open_questions[]` a `--auto=[decision]` delegate later resolves:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --stage PL --prev USER --facts '{
  "decisions": [{"id":"pl-1","summary":"≤160 chars","ref":"planning-0.md#stages"}],
  "open_questions": [{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}]}'
```

Union by `.id` (last writer wins, newest at the tail): never clobbers an upstream stage's entries, and a re-run is byte-identical. Omitting it loses the facts silently. Canonical rule: `handoff-protocol.md#facts-union`.

#### One call, no jq edits to `state.json`

The command is the grant prefix byte for byte, so it matches `agents/product-manager.md`'s
`tools:` grant (`skills/shared/plugin-root-resolution.md § Invocation`); every other
`state-patch.sh --…` step in this file (`--task-create`, `--task-block`, `--ledger-meta`) takes
the same prefix. It writes `tasks.PL0`, the edge and the `facts` arrays. The ledger has no
`stages{}` map to fill (`handoff-protocol.md § Ledger root`), and a refused call is fixed by its
flags, never by rewriting the file:

- exit 4, ledger dir "inside the plugin root": cwd is not the project; add
  `--state <project>/.context/state.json`.
- no `state.json` at all: the one case where skipping is correct (`#layer-1-fallback` item 3).
  Never hand-write or re-version a ledger.

Stage-task seeding uses the same `state-patch.sh` grant and shares this fallback ladder; there is
no separate task tool to fall back to.

#### State Patch — `facts.goal` is part of the contract

`facts.goal` is non-empty in `.context/state.json` when PL returns. The orchestrator seeds it from the task description at Step 3a; refine it to the one-line goal above, or add it if the seed lacks it, with one `Edit` of that value: `--facts` has no `goal` key, so it is the one ledger value PL writes by hand. `publish-pl-issue.sh` reads it as the first rank of both the issue title and the `## Summary` chain; without it the issue gets a kebab-slug title and an empty Summary. Also write a `title:` line into the plan's frontmatter — the chain's next rank.
