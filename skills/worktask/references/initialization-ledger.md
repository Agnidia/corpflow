<a id="install-snippet"></a>
<a id="plan_file-shape-boundary"></a>
<a id="post-seed-notes"></a>
# Initialization ledger

Read when executing or checking initialization ledger.

Procedure routing: [initialization-patterns](initialization-patterns.md).

<!-- canonical-body:start -->
# Worktask Initialization & Setup

## Conventions used in this document

`planFile` is this run's plan basename (`planning-N.md`), carried as `metadata.plan_file` and in `context_refs`.
Readers prefer task metadata, then the highest numbered plan; PL0's write-target algorithm is
[planning-sizing](planning-sizing.md#plan-file--run-index-naming).
Handoff mode requires `state_file` plus anchor-based `context_refs`; the ledger has no whole-file fallback.

<a id="pl0-invariant"></a>
## PL0 state.json Initialization (Phase 1)

After `mkdir -p .context/`, the orchestrator runs `seed-state.sh` through
[launch-seed](launch-seed.md#step-3a-snippet--seed-the-ledger), the canonical command/result/failure sequence.
The helper writes the next free index (`0` initially), workspace, and goal through temp+fsync+rename.
Existing state exits 3 unchanged; PL0's [new-run reset](planning-sizing.md#step-4--statejson-reset) owns replacement.
Required JSON: [ledger-seed](contracts/ledger-seed.md#pl0-seed).
Absent or invalid state is a hard failure for downstream stages.

<a id="seeded-goal"></a>
<a id="seeded-workspace_path"></a>
### Seeded fields and path shapes

| Field | Required value / writer |
|---|---|
| `run_index` | Required integer, next free planning index |
| `state.json.plan_file` | `.context/planning-N.md` path |
| `task.metadata.plan_file` | `planning-N.md` basename; readers accept either shape |
| `facts.goal` | Escaped task description, capped at 240 chars; issue title under megatask; PM may refine |
| `metadata.workspace_path` | Absolute assigned root on every run; per-issue runs overwrite with their worktree |
| `facts.dispatched_agents` | Empty initial array; orchestrator upserts by task id |

Do not seed optional `completed_via`, `last_error`, `worktree`, or `facts.capabilities`; absence is meaningful.

### Readers that silently no-op without it

Always stamp `workspace_path`: omission disables all three guards below.
Isolation does not prove assignment ([workspace-modes](workspace-modes.md#sibling-worktree-hazard)).

| Reader | When unset |
|---|---|
| [Workspace-root cross-check](stage-entry.md#workspace-root-cross-check) | Compares the orchestrator root with itself |
| `dv-tree-preflight.sh resolve_assigned()` | Warns and exits 0 |
| [Developer path-prefix check](../../../agents/developer.md#d0--workspace-root-self-check-before-any-readeditwrite) | Does not run |

## Hook Installation

After seeding and before PL0 dispatch, the orchestrator runs the
[installer](launch-seed.md#step-3b--verify-subagentstop-hook-installed).
It verifies an executable `.claude/hooks/state-merge.sh` copy and `plugin.json` SubagentStop registration.
A missing source or installer failure warns without blocking: registered hooks or Layers 1 and 3 remain available.
PL0 verifies valid state before seeding the chain; an absent project-local copy alone does not block it.

## Multi-Issue Initialization → `/megatask`

For a milestone or issue array, use `skills/megatask/SKILL.md` for issue fetching, PR skips, priority,
DAG ordering, `orchestrator.json`, worktrees, and monitoring.
It launches one worktask per ready issue with pre-bypassed gates; this initialization runs inside each worktree.

## Worktask Initialization

Startup seeds only PL0. Apply [launch-planning](launch-planning.md#step-4--attach-pl0-metadata) to attach its resolved model and effort.
PL0 alone creates the subsequent stage tasks after planning.
