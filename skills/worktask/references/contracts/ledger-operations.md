# Ledger operations

Read when executing or checking ledger operations. Read linked modules only when their conditions apply.

Read these sections only when this procedure cites them.

###### Section lookup 1

[JSON Schema](metadata-schema.md#json-schema) · [Context delivery](metadata-artifacts.md#context-delivery) · [error_file derivation](metadata-artifacts.md#error_file-derivation)

<!-- canonical-body:start -->
---
name: state-ledger
version: 1.1.0
---

# State Ledger Reference

Single source of truth for worktask stage state.

## The ledger is `state.json`

`.context/state.json` `tasks{}` is the only stage ledger — authoritative for stage status,
dependencies, routing metadata, and results. It lives in the worktask folder, so it survives session
end, compaction, and resume with no configuration. Full schema:
`skills/worktask/references/handoff-protocol.md#state-json-schema`.

### Why not Claude Code's Task System

corpflow does not use Claude Code's Task System (`TaskCreate` / `TaskUpdate` / `TaskGet` /
`TaskList`), even on a model that offers it: most of the models this plugin dispatches do not, and
one ledger keeps one code path.

## Ledger Keys

`[STAGE][N]`, N 0-based and sequential per stage code: first `DV` created → `DV0`, second → `DV1`
(`PL0`, `AR0`, `DV0`, `DV1`). The human-readable label lives in `tasks.<ID>.metadata.description`.

PL is always the singleton `PL0`; other stages split into sub-tasks, so parallel DV tracks are
distinct keys. Handoff edges carry the same split: `handoffs["<PREV_CODE>→<TASK_ID>"]` — the source
is a bare stage code, the destination the ledger id of the task that wrote the edge (`PL→AR0`,
`TL→DV1`), so parallel tracks never overwrite one another's edge. Old-shape keys:
`skills/worktask/references/handoff-protocol.md § Field notes — handoffs (edge registry)`.

## Write Operations

Never edit `state.json` directly — every write goes through
`skills/worktask/scripts/state-patch.sh`, which owns the merge lock, the atomic
tmp→fsync→rename, and the disk guard.

| Operation | Command |
|-----------|---------|
| Create | `state-patch.sh --task-create <ID> --metadata '<json>'` |
| Set status | `state-patch.sh --task-status <ID> <status>` |
| Add dependency | `state-patch.sh --task-block <ID> --on <ID[,ID...]>` |
| Remove dependency | `state-patch.sh --task-unblock <ID> --off <ID[,ID...]>` |
| Merge metadata | `state-patch.sh --task-meta <ID> --set '<json>'` |
| Complete from artifact | `state-patch.sh --stage <CODE> [--task-id <ID>] [--prev <CODE>] [--via <layer>]` |
| Resolve an id (read-only) | `state-patch.sh --resolve-task-id <CODE>` |
| Re-open on a correction | `state-patch.sh --task-reopen <TARGET> --from <SOURCE> [--finding-file <path\|->]` |
| Settle the parked consumers | `state-patch.sh --task-settle-stale <TARGET>` |

### Correction pair operations

The last two are the correction pair: the first re-opens one `completed` task and parks its
consumers `stale`, the second decides each parked row at that target's next completion. Guards,
exits, the consumer set and the cited-ref rule:
`skills/worktask/references/handoff-protocol.md § tasks — re-open and settle — guards and invocation`.

### Idempotency and key creation

`--task-create` is idempotent (an existing key is left untouched), `--task-block` unions and
`--task-unblock` subtracts — re-running a seed or a teardown is safe. `--task-create` is the only
op that may introduce a key; status, block, unblock and meta refuse an id that does not exist yet,
so create the task before wiring or annotating it.

## Metadata Fields

Types, ranges, defaults and the required-field rule live in § JSON Schema below — these tables add
only purpose and normative use.

### Routing fields

| Field | Purpose |
|-------|---------|
| `stage` | Stage code, unnumbered. The schema enum is the full vocabulary, not the per-run set — AR and TL tasks exist only when PL0 included them |
| `agent` | Agent to execute this task, in fully-qualified `plugin:agent` form (`corpflow:software-architector`, `apple-developer:ios-developer`); bare names are rejected |
| `model` | Model alias (fable, opus, sonnet, haiku), always passed explicitly to `Agent()`: frontmatter inheritance falls through to `CLAUDE_CODE_SUBAGENT_MODEL` when unset |

#### Model field details

`model` is an alias, not a full model id, and the model that runs can differ from it. A managed
`availableModels`/`enforceAvailableModels` allowlist can resolve a valid alias to another model
(`skills/worktask/references/orchestration.md § Pre-Stage Validation` step 6). `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`
overrides even the explicit alias: `skills/worktask/references/orchestration.md § Step 6.5b — dispatch entry completed`
backfills `dispatched_agents[].model_resolved` when the runtime reports the model that ran, and PL0
raises a plan-gate sweep item (`skills/shared/model-selection.md § Forced subagent model overrides
every pin`). Alias behaviour: `skills/shared/model-selection.md § Default Subagent Model`.

### Run & context fields

| Field | Purpose |
|-------|---------|
| `run_index` | PL0-stamped on every downstream task (same N as `planning-N.md`); resolves `<stage>-N.md` paths (`skills/worktask/references/pl0-procedure.md § Stage Artifact Naming`) |
| `context_refs` | Anchor refs the stage agent greps instead of reading whole files — § Context delivery |
| `state_file` | Path to the ledger, read by the stage agent before delegation. Mandatory — an absent `state.json` is a hard failure, not a degraded mode |

### Error & retry fields

| Field | Purpose |
|-------|---------|
| `error_file` | Auto-derived from `agent` when absent (§ error_file derivation). The stage agent reads it to see its own prior retry narrative |
| `retry_count` | Incremented on retry; resets on escalation or success |
| `fix_round` | Rounds of correction rework this task has been re-opened for. Written only by `state-patch.sh --task-reopen`; `> 0` re-arms the remediation brief for a target of any stage (`skills/worktask/references/orchestration.md § Step 4.6`). Distinct from `retry_count`, which counts this task's own failures |
| `error_escalated_to` | Stage code the failure escalated to when `retry_count` reached 3 |
| `escalation_counts` | Escalations attempted per edge, keyed by the full task id of the target (`{"AR0": 2}`) so a split stage's writers do not share a counter. Survives the escalation handoff that resets `retry_count`; at cap 2 the task is written `failed` with `last_error.class: "exhausted"` |

### Worktask & workspace fields

| Field | Purpose |
|-------|---------|
| `worktask_id` | Links task to worktask instance |
| `priority` | Task priority |
| `milestone_number` | GitHub milestone (megatask mode) |
| `issue_number` | GitHub issue being worked |
| `track` | Parallel track number |
| `workspace_path` | Absolute root of the tree this task is assigned to — see § workspace_path below |
| `isolation` | Always `"worktree"` on file-writing tasks (DV, and megatask per-issue AR/DR/QA); PL0 stamps it unconditionally and every reader treats it that way |
| `worktree_branch` | Branch name in the worktree. ≠ `facts.branch`, the planned host-session branch — `skills/worktask/references/handoff-protocol.md § Field notes — branch` |

#### workspace_path

Writers: `/worktask` steps 3a/4 and `/megatask`. Under `/megatask` it is the per-issue worktree,
otherwise `git rev-parse --show-toplevel` at init
(`skills/worktask/references/initialization-patterns.md § Seeded workspace_path`). Always set it:
three assigned-tree guards read it and each degrades to a silent pass when it is absent. Isolation
is not assignment — a stale worktree satisfies `isolation` and still fails these guards.

### PL0 option fields

Stamped on `tasks.PL0.metadata` by `/worktask` Step 4 (`skills/worktask/references/workflow.md § Step 4 — option-flag
stamping`); absent means the flag was not passed.

| Field | Writer → Reader | Purpose |
|-------|-----------------|---------|
| `with_design` | `--with-design` → PM (`pl0-procedure.md § Designer Invocation`) | `true` lets PL0 invoke `corpflow:designer`; otherwise Designer is skipped |
| `no_gh_issue` | `--no-gh-issue` → `publish-pl-issue.sh`, `mailbox.sh` | `true` suppresses GitHub issue publishing; PM copies it to every stage row |
| `embedded_commands` | Step 2 detection → DV dispatch | Comma-separated `/plugin:command` ids (`skills/worktask/references/workflow.md § Embedded Command Detection`) |
