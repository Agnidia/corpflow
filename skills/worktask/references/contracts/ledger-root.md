# Ledger root

Read when initializing or validating the ledger root and workspace metadata.

## Read for related fields
- For ledger preflight, read [ledger-preflight](ledger-preflight.md).
- For ledger tasks, read [ledger-tasks](ledger-tasks.md).
- For ledger facts, read [ledger-facts](ledger-facts.md).
- For ledger edges, read [ledger-edges](ledger-edges.md).
- For ledger seed, read [ledger-seed](ledger-seed.md).

<!-- canonical-body:start -->
## #state-json-schema

`.context/state.json` is the worktask ledger. Created by PL0; patched by every stage on completion; read from disk by the orchestrator and by every stage agent. Preamble section [3] carries a pointer to it plus a readiness digest, never the ledger itself (`skills/worktask/references/contracts/prompt-layout.md#cache-prefix`). Token budget ≤500.

JSON-Schema-style spec:

#### Ledger root

```yaml
$schema: https://json-schema.org/draft/2020-12/schema
title: WorktaskStateLedger
type: object
required: [version, worktask_id, plan_file, platform, run_index, tasks, facts, handoffs]
properties:
  version: { type: integer, const: 2 }
  worktask_id: { type: string, pattern: '^[a-z0-9\-]+$' }
  plan_file: { type: string }
  platform: { type: string, enum: [all, apple, android, web, systems, backend, ai] }  # canonical keys — skills/shared/platform-detection.md
  run_index: { type: integer, minimum: 0, default: 0 }
```

#### plan_file shape boundary

Canonical statement; other writer and reader sites point here. `state.json.plan_file` holds a
workspace-relative path (`.context/planning-N.md`); `task.metadata.plan_file` holds a bare basename
(`planning-N.md`). Both are legal. Every reader accepts either: try the value as given, then its
basename resolved against the directory holding `state.json`.

#### metadata

```yaml
# …continued: WorktaskStateLedger.properties
  metadata:
    type: object
    description: "Mirror of the dispatch fields shell helpers need — they cannot read Task-System metadata."
    properties:
      workspace_path: { type: string, description: "REQUIRED from the seed onward — see field note below" }
      base_ref: { type: string }
      requires_screenshots: { type: boolean }
      test_mode: { type: string }
      preflight: { type: object, description: "Autonomy preflight result, v1 — see metadata.preflight below" }
      ci: { type: string, enum: [enabled, disabled], description: "Absent means enabled — state-ledger.md § CI field" }
    additionalProperties: true
```

#### metadata.workspace_path

The absolute root of the tree this worktask is assigned to, seeded by
`skills/worktask/references/workflow.md` Step 3a on every run (`git rev-parse --show-toplevel`, else `pwd`) and
overwritten per-issue under `/megatask`. `dv-tree-preflight.sh` `resolve_assigned()` reads it as
rank 2 (after `--assigned`, before `$WORKSPACE_ROOT`).

Its absence is a defect, not a mode: every reader warns-and-proceeds on empty, so an unstamped
ledger disables the whole assigned-tree guard set at once. Rationale:
`skills/worktask/references/initialization-ledger.md § Seeded workspace_path`.

#### metadata.base_ref

The integration branch, mirrored by PL0 from `task.metadata.base_ref` so shell helpers (which
cannot read Task-System metadata) can reach it. Reader resolution order, highest first:

| Rank | Source | Note |
|---|---|---|
| 0 | `fork_base()` fork point | Evidence, opt-in — see below. |
| 1 | `$FN_BASE_REF` | Explicit operator/test override. |
| 2a | `state.json tasks.<ID>.metadata.base_ref` | The row the caller names in `$BASE_REF_TASK_ID`; skipped when no task is named. |
| 2b | `state.json .metadata.base_ref` | Stamped by PL0; where a host-declared target branch enters the order — see below. |
| 3 | `workspace.json .git.base_branch` | `/megatask` per-issue record. |
| 4 | `git symbolic-ref refs/remotes/origin/HEAD` | Repository default branch. |
| — | unresolved | Reported, never guessed. |

##### Rank 0 is evidence, and opt-in

Rank 0 is consulted and reported, but it supplies the value only when ranks 1-4 are all empty and
the caller passed `--with-fork-point`. A fork point that disagrees with a value ranks 1-4 supplied
is surfaced (PL0 sweep item, `fn-preflight base-sanity` candidate line) and never applied, so a
branch deliberately rebased onto a release line is not silently retargeted.

It is opt-in because every other consumer reads an empty return as *decline, do not guess* and
gates on it (`refine-branch-target.sh`'s `base_unresolved` no-op, `branch-name.sh`, `continuity`,
`issue-close-required`). `base-sanity` opts in because it alone distinguishes an inferred base from
a configured one (its `base_guessed` degrade rung).

##### Rank 2a reads the named task row

A caller that reviews or merges one task's work names that task in `BASE_REF_TASK_ID` (for
example `stream-diff.sh` sets it to each DV row's own id). The row's `metadata.base_ref` then
answers ahead of the ledger mirror: the mirror is a copy, and a wrong copy otherwise gives every
row a wrong base. A row without a value, the string `null`, or an id absent from the ledger falls
through to rank 2b. The id reaches `jq` only as `--arg`, never inside the filter. Scope the
variable to one call; an exported value steers every later resolver call in that shell.

##### Rank 2b and the host-declared target branch

A host telling the session "the target branch for this workspace is `origin/develop`" is the
*provenance* of rank 2b, not a separate probe. It is outranked by `$FN_BASE_REF` alone, and it
outranks both the megatask record and the repository default.

##### Implementation

`skills/worktask/scripts/branch-lib.sh` — `resolve_base_ref` returns the value, `base_ref_source`
returns which rank answered (`env`, `task`, `state`, `workspace`, `origin_head`, `fork_point`,
`unresolved`; `task` is rank 2a, `state` rank 2b), both over one shared internal ladder and both accepting `--with-fork-point`. There is
no literal fallback; readers report unresolved and degrade non-blocking. The same ranks, identically
ordered, are restated in `skills/worktask/references/planning-tasks.md § Integration-branch detection`.
