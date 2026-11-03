# Planning sizing

Read when executing or checking planning sizing.

Procedure routing: [pl0-procedure](pl0-procedure.md).

<a id="section-lookup-1"></a>
Related: [Workspace Mode](planning-artifacts.md#workspace-mode) · [Where to stamp the detected branch](planning-tasks.md#where-to-stamp-the-detected-branch)

<!-- canonical-body:start -->
## Worktask Integration

Stage PL (Planning, 1/11); pipeline context: `skills/worktask/references/worktask-stage-context.md`.

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
`skills/worktask/references/workflow.md § Plan-revision re-dispatch`), this turn revises the run in flight:

- Skip algorithm steps 1–3: `run_index` and `plan_file` are frozen; edit the current `.context/<plan_file>` in place.
- Skip the Step-4 reset; patch `facts.*` additively so `facts.decisions[]` (the gate answers just given) and every other fact of this run survive.
- Create no stage tasks; patch the existing chain in place when the revision changes subjects, ACs, or the stage set.

The never-overwrite rule protects finished runs' plans; a plan under active revision is not history.

#### Step 4 — state.json reset

4. Reset `state.json` (new run in an existing `.context/`; skipped on a `plan_revision` turn):
   atomically rewrite `.context/state.json` with `"run_index": N`, `"tasks": {"PL0": {"status": "in_progress"}}`, `metadata.requires_screenshots` = the planner's verdict (the channel `hooks/dv-screenshot-gate.sh` and `attach-visual-evidence.sh` read), `metadata.base_ref` = the detected integration branch (below), and empty `facts.*` (preserving `version`, `worktask_id`, `platform`). Use `skills/worktask/references/contracts/ledger-writes.md#atomic-write`.

##### Step 4 — plan_file shape

Write the path shape into `state.json.plan_file` — `".context/planning-${N}.md"`, not the bare `<plan_file>` basename used everywhere else in this document; the issue-publish helper cannot find an unprefixed plan. Rule: `skills/worktask/references/contracts/ledger-root.md § plan_file shape boundary`.

#### Downstream propagation

When PL seeds downstream stage tasks via `state-patch.sh --task-create`, stamp every row of the tables below on each task:

| Key | Value | Purpose |
|---|---|---|
| `metadata.plan_file` | `"planning-${N}.md"` | Pins the active plan — a bare basename, unlike `state.json.plan_file` (a workspace-relative path; `skills/worktask/references/contracts/ledger-root.md § plan_file shape boundary`). |
| `metadata.run_index` | `N` (integer) | Resolves `<basename>-${N}.md` artifacts |
| `metadata.isolation` | `"worktree"` | File-writing stages (DV; megatask per-issue AR/DR/QA) run in an isolated worktree (read by developer § D0.0, the technical-lead DR check, workspace-modes.md). |

##### Propagation fields — dispatch pair

| Field | Source / default | Override / failure |
|---|---|---|
| `metadata.model` | `model-matrix.sh --resolve <agent>` | Apply matching Secure overrides; `--task-create` supplies no missing model. |
| `metadata.effort` | Same resolved pair | Apply Default writer rules below; C.0a skips absent effort with `resolver_skipped`, `reason: "effort_unstamped"`. |

PL0 pastes both values into `--metadata`. Dispatch passes both explicitly; the effort parameter outranks static agent frontmatter.

##### Propagation fields — gates

PL0 stamps the gates using [the launch field table](launch-planning.md#step-4--metadata-sources).
FN reads `fn_gate` at the mid-loop checkpoint; `--auto=[plan]` never bypasses FN.
`decision_gate` selects A.4 for PL, C.0a for later blocking items, and C.3 for the FN batch; it bypasses no gate.

##### Propagation fields — exploration & screenshots

| Key | Value | Purpose |
|---|---|---|
| `metadata.skip_exploration` | `true` if `.context/exploration.md` exists | Suppress redundant Glob/Grep in AR/TL/DV |
| `metadata.exploration_anchors` | `["exploration.md#facts", "exploration.md#refs", "planning-${N}.md#requirements"]` (when `skip_exploration: true`) | Authoritative pre-explored set |
| `metadata.requires_screenshots` | planner's verdict (boolean; detector is advisory) | Drives DV capture + gate; read by DV, QA (Q1.5), `attach-visual-evidence.sh`. Stamp on every downstream task. |

##### Propagation fields — DV rows

Every DV row is a fan-out unit with its own artifact; these two keys make it one
(`skills/worktask/references/contracts/artifact-map.md § DV fan-out — ledger tasks`).

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

PL0 may stamp [dispatch metadata](state-ledger.md#dispatch-metadata-optional) for the headless recipe's corresponding flags.
In-process, `model` applies and `permission_mode` is audited; other optional fields are advisory.
Required `effort` always rides the Agent parameter, above static frontmatter; headless transport requires `CORPFLOW_HEADLESS_ROUTE=on`.

For the five [compaction/retry controls](contracts/ledger-streams.md#compaction-and-retry-controls), copy only explicit operator choices.
Leave them absent by default; require headless opt-in before stamping.
Wait limits require `retry_watchdog: true`; never infer thresholds or durations from complexity.

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
