# Worktask Initialization & Setup

## Conventions used in this document

- **`planFile`** — the plan filename PL produced for the current worktask run (`planning-N.md`, e.g. `planning-0.md`, `planning-3.md`). Computed by PL0 per `skills/worktask/references/pl0-procedure.md § Plan File & Run Index Naming`. Every downstream task carries it as `metadata.plan_file`; the same value is interpolated into `context_refs`. Stage agents resolve the plan file from `task.metadata.plan_file` first, then newest `.context/planning-*.md`.
- **handoff-protocol mode** — the metadata contract (per `skills/worktask/references/handoff-protocol.md`): tasks carry `state_file` + `context_refs` (anchor list). The ledger is mandatory; there is no whole-file fallback list.

## PL0 state.json Initialization (Phase 1)

`commands/worktask.md` Phase 1 Step 3a creates `.context/state.json` right after `mkdir -p .context/` by running `skills/worktask/scripts/seed-state.sh`, the seed's only executable definition: the re-run-aware next free planning index `N` (`0` on a fresh `.context/`), `metadata.workspace_path`, `facts.goal`, and the atomic temp+fsync+rename write. `run_index` is a required schema field (`handoff-protocol.md#state-json-schema`). The script refuses (exit 3) when `state.json` already exists; `pl0-procedure.md § Step 4 — state.json reset` owns re-runs. Resulting JSON shape: `handoff-protocol.md#pl0-seed`.

### plan_file shape boundary

Both shapes appear in this file: the state seed writes the **path** shape
(`.context/planning-N.md`); every task-seed snippet below writes the **basename** shape
(`planning-N.md`). Both are legal and every reader accepts either — rule and resolution order:
`handoff-protocol.md § plan_file shape boundary`.

### Seeded goal

`GOAL` is the task description, JSON-escaped and truncated to 240 chars
(`handoff-protocol.md § Field notes — goal`). It is seeded here because nothing in PL0's patch path
writes it, and without it `publish-pl-issue.sh` publishes a slug title with an empty Summary. PM
still refines it; the seed only guarantees it is never absent. Under `/megatask` the issue title is
the goal.

### Seeded workspace_path

`metadata.workspace_path` is the absolute root of the tree the worktask owns, seeded
unconditionally on every run — a `/megatask` per-issue run overwrites it with the per-issue
worktree path, but no run may leave it unset.

#### Readers that silently no-op without it

Three guards read it and each passes silently when it is empty, so an unstamped ledger disables
all three at once:

| Reader | Behaviour when `workspace_path` is unset |
|---|---|
| `commands/worktask.md § Workspace-root cross-check` | compares the orchestrator root against itself → always equal |
| `skills/worktask/scripts/dv-tree-preflight.sh` `resolve_assigned()` | resolves empty → warn, exit 0 (never blocks) |
| `agents/developer.md § cwd discipline` path-prefix check | gated on "when set" → never runs |

Isolation is not assignment: `workspace-modes.md § Sibling-worktree hazard`.

### Post-seed notes

`facts.dispatched_agents: []` is seeded (additive) so the orchestrator loop appends per-`task_id` entries in place. The other additive fields (`tasks.<ID>.completed_via`/`last_error`/`worktree`, `facts.capabilities`) are written on demand, never seeded — their absence is meaningful. Schema: `handoff-protocol.md#state-json-schema`.

Subsequent stage agents read `.context/state.json` first; its absence is a hard failure, not a fallback mode.

## Hook Installation

PL0 (or `commands/worktask.md` Phase 1) first verifies the `state-merge.sh` SubagentStop hook is installed. It is the Layer 2 safety net: it patches `state.json` from artifact frontmatter when a stage agent forgets to self-patch (Layer 1) or the orchestrator's Step 6.5 check is skipped.

### Install snippet

```bash
# Idempotent hook installation — run after state.json seed, before PL0 delegation.
# Source: <plugin-root>/hooks/state-merge.sh (ships with corpflow plugin).

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"  # Claude Code substitutes this token when loading this file
# Empty? Substitute <plugin-root>: the dir containing .claude-plugin/plugin.json — two levels
# above this skill's base directory (see skills/shared/plugin-root-resolution.md).
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="<plugin-root>"
hook_src="$PLUGIN_ROOT/hooks/state-merge.sh"
hook_dst=".claude/hooks/state-merge.sh"

if [[ ! -x "$hook_dst" ]]; then
  mkdir -p .claude/hooks
  cp "$hook_src" "$hook_dst"
  chmod +x "$hook_dst"
fi
```

### PL0 invariant

Before seeding the stage chain, verify:
1. `.context/state.json` exists and is valid JSON
2. `.claude/hooks/state-merge.sh` exists and is executable
3. The plugin's `plugin.json` registers the SubagentStop hook (this is declarative — no project-local action needed)

If the hook source is not found (e.g. the plugin root is unresolved), log a warning and continue — the plugin.json-registered hook still fires. The project-local copy is a fallback for environments where plugin hooks are not supported.

## Multi-Issue Initialization → `/megatask`

Single-issue setup is the only initialization this skill owns. Multi-issue batches across a GitHub
milestone or an explicit issue array are orchestrated by `/megatask` — issue fetching, PR-skip
detection, priority + dependency/blocker ordering, orchestrator.json, and per-issue worktree
creation. `/megatask` launches one `/worktask` per ready issue (gates pre-bypassed),
so the per-issue setup above still applies inside each worktree.

See:
- `../../megatask/SKILL.md` — orchestrator pattern, worktree topology, monitoring loop
- `../../megatask/references/dependency-graph.md` — DAG construction, cycle detection, levelled schedule
- `../../megatask/references/schemas.md` — orchestrator.json (v3.1) + workspace.json schemas
- `../../shared/milestone-helpers/SKILL.md` — branch naming, PR detection, worktree helpers

## Worktask Initialization

Only PL0 is created at startup. PL0 creates all subsequent stage tasks after planning.

```bash
WORKTASK_ID="dark-mode-2025"
# Resolved like every stage's pair (commands/worktask.md § Step 4 — PL0's model and effort).
IFS=$'\t' read -r MODEL EFFORT _ < <(model-matrix.sh --resolve product-manager)

# The state.json seed already created PL0 as in_progress, so this attaches its
# metadata — --task-create would early-exit as a no-op and drop the payload.
state-patch.sh --task-meta PL0 --set "$(jq -n --arg wid "$WORKTASK_ID" \
  --arg model "$MODEL" --arg effort "$EFFORT" \
  '{stage:"PL", agent:"corpflow:product-manager", model:$model, effort:$effort,
    description:"Define requirements, assess complexity, seed stage tasks",
    worktask_id:$wid, priority:"medium"}')"
```

## Pre-Stage Exploration Cache

Before creating PL0, the orchestrator creates `.context/exploration.md` when it has explored the
codebase, so stage agents do not re-read the same files.

### When to Create

- Orchestrator launched Explore agents before PL0
- User provided Figma URLs or external context
- Task involves modifying existing code (not greenfield)

When Figma URLs are provided, PL0 captures screenshots to `.context/designs/figma-*.png` and
summarizes the design context here. This applies to every worktask, including low-complexity runs
with no `.context/planning-N.md`: create `.context/designs/` and save the screenshots anyway.

### Template

```markdown
# Exploration Cache
<!-- Generated by orchestrator — read by all stage agents -->
<!-- Agents: read this INSTEAD of re-exploring the codebase -->

## File Inventory

| File | Lines | Description |
|------|-------|-------------|
| `Source/Navigation/AppCoordinator.swift` | 510 | Centralized navigation coordinator |
| `Source/Features/Settings/Views/SettingsView.swift` | 198 | Settings ZStack overlay with panel system |

## Key Interfaces

### [Section Name] (e.g., "Settings Panel Pattern")
~~~swift
// Source/Features/Settings/Views/SettingsView.swift:10-27
enum SettingsPanel {
    case grid, profile, editProfile, ...
    var animationSpeed: CGFloat { ... }
}
~~~

### [Section Name] (e.g., "Navigation Routes")
~~~swift
// Source/Navigation/Route.swift:135-157
enum FullScreenRoute: Hashable, Identifiable {
    case tryOnMakeup(lookID: String?)
    ...
}
~~~
```

#### Template (continued)

```markdown
<!-- …continued: patterns, external context, user decisions -->

## Patterns

- **Settings panel**: `@Binding var activePanel: SettingsPanel` + `SettingsPanelHeader`
- **Full-screen cover**: `FullScreenRoute` enum → `AppCoordinatorView.fullScreenContent(for:)`
- **Flag-based auto-open**: `shouldOpenDevicesOnSettings` pattern in AppCoordinator

## External Context

### Figma Design
- **Figma URL**: [original URL]
- **File Key**: [fileKey] | **Node ID**: [nodeId]
- **Screenshots captured**:
  - `.context/designs/figma-[screen]-[state]-[node-id].png` — [description]
- **Design context summary**: [colors, layout, components from get_design_context]

## User Decisions
- [Decision 1]: [choice made]
- [Decision 2]: [choice made]
```

### Size Budget

Keep exploration.md to 500-1500 tokens (roughly 50-150 lines).
Include actual code snippets only for interfaces/enums that agents need to match.
For implementation details, use `file:line` references.

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

When a task starts, the executor reads `metadata.agent` and spawns the agent. `metadata.agent` is always the fully-qualified `plugin:agent` form (e.g., `corpflow:developer`, `apple-developer:ios-developer`); bare names are not accepted. The dispatch itself (prompt built by `brief-compose.sh`, explicit `model` and `effort` from the task metadata) is specified in `skills/worktask/SKILL.md § Orchestrator Execution Loop`.

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
`artifact` differ per row (`handoff-protocol.md § DV fan-out — ledger tasks`). All DVN share
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

The splitting DV agent is the rows' creator, so it assigns every slug (`handoff-protocol.md §
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
(`handoff-protocol.md § Pinning a row's tree`). Contrast the TL split above.

```bash
state-patch.sh --task-block DV1 --on DV0
state-patch.sh --task-block DV2 --on DV1
```
