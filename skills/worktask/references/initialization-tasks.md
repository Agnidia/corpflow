# Initialization tasks

Read when executing or checking initialization tasks.

Procedure routing: [initialization-patterns](initialization-patterns.md).

<a id="section-lookup-1"></a>
Related: [plan_file shape boundary](initialization-ledger.md#plan_file-shape-boundary)

<!-- canonical-body:start -->
## PL Creates Subsequent Tasks

After planning completes, PL0 creates stage tasks from the complexity score. Each task is self-describing: `metadata.agent` names the executor, `metadata.model` the model alias. The ledger key IS the id — nothing to capture from the call.

### Canonical seed call

Every stage seed is this call with the values from the table below. `$PLAN_FILE` is the
**basename** shape (§ plan_file shape boundary); `$REQUIRES_SCREENSHOTS` is the plan-frontmatter
boolean the planner decided (`detect-ui-change.sh` is advisory; uncertain means `true`), propagated so the capture skill and `dv-screenshot-gate` fire.

```bash
state-patch.sh --task-create DV0 --metadata "$(jq -n \
  --arg plan "$PLAN_FILE" --arg wid "$WORKTASK_ID" --argjson shots "$REQUIRES_SCREENSHOTS" \
  --arg model "$MODEL" --arg effort "$EFFORT" \
  '{stage:"DV", agent:"corpflow:developer", model:$model, effort:$effort,
    description:"Implement dark mode theme system and color tokens",
    error_file:".context/errors/developer.md",
    context_refs:(["\($plan)#requirements","architecture-0.md#decisions","coordination-0.md#fan-out"]|tojson),
    plan_file:$plan, requires_screenshots:$shots, worktask_id:$wid, priority:"medium"}')"
```

### Per-stage values

`priority:"medium"`, `plan_file`, `worktask_id` and `error_file: ".context/errors/<agent>.md"` are
the same on every row. Drop `--argjson shots` / `requires_screenshots` on rows that do not list it.
`$MODEL`/`$EFFORT` come from `model-matrix.sh --resolve <agent>` (`stage-codes.md § Model and
Effort Lookup`).

| Task | stage / agent | `context_refs` | `requires_screenshots` |
|---|---|---|---|
| AR0 | `AR` / `corpflow:software-architector` | `exploration.md#findings`, `<plan>#requirements` | — |
| DV0 | `DV` / `corpflow:developer` | `<plan>#requirements`, `architecture-0.md#decisions`, `coordination-0.md#fan-out` | yes |
| DR0 | `DR` / `corpflow:technical-lead` | `<plan>#requirements`, `architecture-0.md#decisions`, one `#deviations` ref per DV row's `metadata.artifact` | — |
| QA0 | `QA` / `corpflow:qa-engineer` | `<plan>#acceptance-criteria`, `developer-review-0.md#verdict` | yes (QA's Q1.5 manifest ingestion / advisory-skip reads it) |

### AR0 task

AR0 is a tier default at score ≥11, not a mandate — PL0 resolves inclusion against
`skills/estimation-methodology/SKILL.md § Stage Inclusion Criteria (PL0 authority)` and records the
outcome in `skipped_stages`/`added_stages`. When AR is excluded, skip its seed entirely and chain
DV0 directly off PL0.

context_refs seeding rule: an `architecture-${N}.md` anchor appears in DV0's `context_refs` if
and only if AR0 was included. When AR is excluded, no downstream `context_refs` carries it and no
`metadata.architecture_ref` is stamped on DV0/DR0/QA0.

### Dependency chain

```bash
# DV0's predecessor is whichever of TL0/AR0/PL0 is the last stage actually seeded:
# TL0 when TL ran, AR0 when AR ran without TL, PL0 when neither did.
state-patch.sh --task-block AR0 --on PL0   # AR0 ← PL0
state-patch.sh --task-block DV0 --on AR0   # DV0 ← AR0 (AR-included branch)
state-patch.sh --task-block DR0 --on DV0   # DR0 ← DV0
state-patch.sh --task-block QA0 --on DR0   # QA0 ← DR0

state-patch.sh --task-status PL0 completed
```

## Task Execution Pattern

When a task starts, the executor reads `metadata.agent` and spawns the agent. `metadata.agent` is always the fully-qualified `plugin:agent` form (e.g., `corpflow:developer`, `apple-developer:ios-developer`); bare names are not accepted. The dispatch itself (prompt built by `brief-compose.sh`, explicit `model` and `effort` from the task metadata) is specified in `skills/worktask/references/dispatch-readiness.md § Orchestrator Execution Loop`.

## Stage Sub-Task Splitting

Two patterns for splitting DV into sub-tasks:

### TL-Initiated Split (Parallel Streams)

TL creates DVN tasks during coordination. All streams run concurrently after TL completes. DR0 waits for all.

```
                  ┌→ DV0 ─┐
PL0 → AR0 → TL0 ─┤→ DV1 ─├→ DR0 → QA0
                  └→ DV2 ─┘
```

#### Narrow scope & seed the streams

TL first narrows DV0 to the primary stream, then seeds DV1…DVN with the § Canonical seed call —
same `stage`/`agent`/`model`/`context_refs` as the DV0 row; `description`, `subject`, `stream` and
`artifact` differ per row (`skills/worktask/references/contracts/artifact-map.md § DV fan-out — ledger tasks`). All DVN share
`error_file: ".context/errors/developer.md"` with distinct section headers per sub-task
(`## DV1 Retry N`, `## DV2 Retry N`).

##### Stream seed calls

```bash
state-patch.sh --task-meta DV0 --set \
  '{"description":"Implement theme color tokens (owns: Source/Theme/Colors/)",
    "subject":"Implement theme color tokens","stream":"tokens","artifact":".context/development-0-tokens.md"}'

# DV1: "Add toggle and persistence (owns: Source/Settings/Theme/)"
# DV2: "Create dark variants for all image assets (owns: Assets/Dark/)"
state-patch.sh --task-create DV1 --metadata "$(jq -n \
  --argjson m "$(jq -c '.tasks.DV0.metadata' .context/state.json)" \
  '$m + {description:"Add toggle and persistence (owns: Source/Settings/Theme/)",
         subject:"Add theme toggle and persistence", stream:"toggle", artifact:".context/development-0-toggle.md"}')"
```

#### Dependency wiring

```bash
# All DVN blocked by TL0 (not DV0) — enables true parallelism.
state-patch.sh --task-block DV1 --on TL0
state-patch.sh --task-block DV2 --on TL0

# DR0 waits for every DV task; --task-block unions with the existing DV0 edge.
state-patch.sh --task-block DR0 --on DV1,DV2
```

### DV-Initiated Split (Sequential Sub-tasks)

DV agent splits during its own execution. Sub-tasks are children of DV0 — sequential, not parallel.

#### DV1/DV2 sub-tasks & sequencing

The splitting DV agent is the rows' creator, so it assigns every slug (`skills/worktask/references/contracts/artifact-map.md §
Artifact naming (S1)`). The split takes the run to ≥ 2 DV rows, so DV0 gets `stream` + `artifact`
first. DV1 and DV2 then clone DV0's metadata with the § Canonical seed call's shape, and the clone
drops every `coordination-*.md` ref from `context_refs` (a JSON-encoded list; no TL split here).
`description`, `subject`, `stream` and `artifact` differ per row — e.g. DV1 "Create semantic color tokens for
light/dark themes", DV2 "Add toggle and persistence for theme preference".

##### Stamp DV0, then clone it

```bash
N=$(jq -r '.tasks.DV0.metadata.run_index' .context/state.json)
state-patch.sh --task-meta DV0 --set "$(jq -cn --arg n "$N" \
  '{subject:"Build the theme core", stream:"core", artifact:".context/development-\($n)-core.md"}')"

m=$(jq -c '.tasks.DV0.metadata
  | .context_refs |= (fromjson | map(select(startswith("coordination-") | not)) | tojson)' \
  .context/state.json)
state-patch.sh --task-create DV1 --metadata "$(jq -n --argjson m "$m" \
  '$m + {description:"Create semantic color tokens for light/dark themes",
         subject:"Create semantic color tokens", stream:"tokens", artifact:".context/development-\($m.run_index)-tokens.md"}')"
state-patch.sh --task-create DV2 --metadata "$(jq -n --argjson m "$m" \
  '$m + {description:"Add toggle and persistence for theme preference",
         subject:"Add theme toggle and persistence", stream:"toggle", artifact:".context/development-\($m.run_index)-toggle.md"}')"
```

##### Chain the rows

Sequential, not parallel: a chain, so the rows share DV0's tree and are never re-pinned
(`skills/worktask/references/contracts/artifact-map.md § Pinning a row's tree`). Contrast the TL split above.

```bash
state-patch.sh --task-block DV1 --on DV0
state-patch.sh --task-block DV2 --on DV1
```
