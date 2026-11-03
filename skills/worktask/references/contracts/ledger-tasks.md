# Ledger tasks

Read when executing or checking ledger tasks. Read linked modules only when their conditions apply.

Read these sections only when this procedure cites them.

###### Section lookup 1

[Field notes — tests_executed, rework_runs](ledger-field-notes.md#field-notes--tests_executed-rework_runs) · [Schema — blocked_on](blocked-needs.md#schema--blocked_on) · [Schema — blocked_on, the correction arm — structure](blocked-artifacts.md#schema--blocked_on-the-correction-arm--structure)

<!-- canonical-body:start -->
#### tasks

The sole stage ledger, keyed by numbered stage id (`[STAGE][N]` — `PL0`, `DV0`, `DV1`), the
same identity used in artifact names and in the destination side of a handoff edge
(`skills/worktask/references/state-ledger.md`). An edge is `<PREV_CODE>→<TASK_ID>` (`TL→DV1`): only its source
side is a bare stage code. Hand-writing one — `skills/worktask/references/contracts/ledger-edges.md#layer-1-fallback` — uses the numbered id, or a
split stage's four writers collide on one key. Full grammar: § Field notes — handoffs.

```yaml
# …continued: WorktaskStateLedger.properties.tasks
  tasks:
    type: object
    propertyNames: { pattern: '^(PL|AR|TL|DV|DR|SR|QA|DC|RE|FN|ST|IR|ET)[0-9]+$' }
    additionalProperties:
      type: object
      required: [status, metadata]
      properties:
        status: { type: string, enum: [pending, in_progress, completed, blocked, skipped, failed, stale] }
```

##### tasks — routing & dependencies

```yaml
# …continued: WorktaskStateLedger.properties.tasks.additionalProperties.properties
        blocked_by:
          type: array
          items: { type: string }
          description: "Stage ids this task waits on, e.g. ['DV0','DV1']. Ready ⇔ every entry is completed."
        metadata:
          type: object
          description: "Routing + dispatch contract — schema in skills/worktask/references/state-ledger.md § JSON Schema."
```

##### tasks — execution results

```yaml
# …continued: WorktaskStateLedger.properties.tasks.additionalProperties.properties
        artifact: { type: string }
        complexity: { type: integer, minimum: 0, maximum: 50 }
        verdict: { type: string, description: "Sets status through the verdict map below" }
        claimed_at: { type: string, format: date-time, description: "Stamped by state-patch.sh --claim; kept on re-claim" }
        retry_count: { type: integer, minimum: 0, default: 0 }
        error_file: { type: string }
        progress:
          type: object
          description: "OPTIONAL. Budget-aware checkpoint — see field notes"
          properties:
            completed_batches: { type: array, items: { type: string } }
            next_batch: { type: string, description: "id of the next pending sub-batch, or absent when done" }
            updated_at: { type: string, format: date-time }
```

##### tasks — verdict → status

A stage patch sets `status` from the artifact's `handoff.verdict`; `state-patch.sh verdict_status` holds the only copy of the map.

| Verdict | `status` | Also written |
|---|---|---|
| `ok`, `pass`, `go`, `approve` | `completed` | `metadata.gate_from_stage` deleted |
| `blocked`, `escalate` | `blocked` | `metadata.gate_from_stage` deleted |
| `fail`, `reject`, `no-go` | `pending` | `metadata.gate_from_stage` = the patched stage's code, on the patched row |
| missing, or any other string | — | refused: exit 3, `state.json` byte-identical, on every caller path |

No verdict maps to `stale`: a stage never reports itself stale. `--task-reopen` is its only writer
and `--task-settle-stale` its only clearer (§ tasks — re-open and settle — guards and invocation).

##### tasks — loop-back, claim, create

The patch writes only its own row. Moving a failure back to DV is the orchestrator loop's job: it copies `gate_from_stage` onto the DV row it replays. `--claim <TASK_ID>` moves a `pending`/`blocked` row to `in_progress` and stamps `claimed_at`; a re-claim is a no-op, and a settled row (`completed`/`skipped`/`failed`) exits 4 — use `--task-replay`. A replay also sets `rework_pending` on a row holding `tests_executed`, so its next completion files the earlier round (§ Field notes — tests_executed, rework_runs).

`--task-create` refuses a row whose metadata lacks `effort`, `isolation`, `base_ref`, `requires_screenshots` or `workspace_path` (absent, `null` or `""`; `false` counts as present) with exit 2 and `state.json` untouched. `PL`/`IR` rows are exempt: PL0 is the stage that decides `base_ref` and `requires_screenshots`.

##### tasks — re-open and settle — guards and invocation

`--task-reopen <TARGET> --from <SOURCE> [--finding-file <path|->]` re-opens a correction-named task (`§ Schema — blocked_on, the correction arm — structure`; `skills/worktask/references/script-blocked.md § blocked-on-dispatch.sh — route, the correction arm — invocation`). Guards run first: target exists, is not source, is `completed`; source exists. Refusal: exit 4, `state.json` unchanged. One atomic apply then writes mutations.

##### tasks — re-open and settle — target mutation

Target: `pending`, `metadata.fix_round` = `(fix_round // 0) + 1`, `metadata.gate_from_stage` = source stage code, `metadata.gate_blockers` = stdin text (trailing whitespace stripped) or `[]`. Router composes text as `finding` byte-for-byte, blank line, `evidence_ref: <ref>`, `source_task: <id>` (because `gate_from_stage` carries stage code only). Artifact, verdict, handoff survive (like replay). `fix_round` re-arms remediation brief (`skills/worktask/references/dispatch-context.md § Step 4.6`).

##### tasks — re-open and settle — consumer mutation and idempotency

Every consumer: `stale`. Transitive set reachable downstream through `blocked_by`, filtered to `completed` status, minus source, minus `REPLAY_SIDE_EFFECT_STAGES` (`FN`, `RE`). Each keeps verdict, artifact, handoff. Finding via stdin (`--finding-file -`), excluded from state-patch log. Re-running refused by `completed` guard → retried route is idempotent.

##### tasks — settle, the cited set and the change set — invocation and table

`--task-settle-stale <TARGET>` runs after target completion and before the ready filter (`skills/worktask/references/completion-merge.md § Step 6.5d`). It settles each `stale` task and prints `{"settled":[{"task","to","reason"}]}`:

| Case | `status` | `reason` |
|---|---|---|
| change set unreadable: no path, unreadable artifact, no parser, or absent `files_touched` | `pending` | `change-set-unknown` |
| cited set empty; dependent files_touched absent, unparsed or empty | `pending` | `cited-set-empty` |
| cited set empty; dependent's own files_touched intersects the change set | `pending` | `own-file-changed` |
| cited set empty; dependent's own files_touched is disjoint from the change set | `completed` | `no-own-file-changed` |
| cited and change sets intersect | `pending` | `cited-file-changed` |
| cited is not in change set (or `.context/` emptied it) | `completed` | `no-cited-file-changed` |

##### tasks — settle, the cited set and the change set — read vs empty distinction

Read vs empty carries fail-safe: unreadable change set is unknown (every dependent re-verifies); read then emptied by filters is known (dependent citing nothing keeps result). Collapsing them turns "no evidence" into "no change".

##### tasks — settle, the cited set and the change set — set definitions

**Cited set** of stale task `T`: `facts.files_read[] | select(.stage == <T's stage code>) | .path` unioned with `tasks[T].metadata.consumes[].paths[]`.

**Change set**: `handoff.files_touched[]` from target artifact (`tasks[TARGET].artifact` else `metadata.artifact`), filtered: `+ N more` drops as count not path; `.context/` paths drop entirely (target rewrites its artifact; counting it returns every dependent). Both normalised: strip `./` prefix, `#anchor` and `:N` suffix. `--changed <paths>` substitutes change set, state becomes `known` if ≥1 path (test seam).

`facts.files_read` keeps newest 30 entries; old stage's citations can be gone by settle time (empty-cited-set case, re-verifies).

#### tasks — tests_executed, rework_runs

```yaml
# …continued: WorktaskStateLedger.properties.tasks.additionalProperties.properties
        tests_executed:
          type: array
          items: { $ref: '#/$defs/TestRunEntry' }
          description: "OPTIONAL (DV, QA). Mirrors the current round's handoff.tests_executed — see field notes"
        rework_runs:
          type: array
          description: "OPTIONAL, append-only. One entry per earlier round of a replayed row"
          items:
            type: object
            required: [round, tests_executed]
            properties:
              round: { type: integer, minimum: 1 }
              tests_executed: { type: array, items: { $ref: '#/$defs/TestRunEntry' } }
        rework_pending: { type: boolean, description: "Transient. Set by --task-replay, consumed by the next completion merge" }
```

#### tasks — completed_via, last_error

```yaml
# …continued: WorktaskStateLedger.properties.tasks.additionalProperties.properties
        completed_via:
          type: string
          enum: [hook, step6_5, f3]
          description: "OPTIONAL — see field notes"
        last_error:
          type: object
          description: "OPTIONAL — see field notes"
          required: [class, at]
          properties:
            class: { type: string, enum: [transient, logic, missing_input, ambiguous_requirements, design_flaw, hard_constraint, exhausted] }
            partial: { type: boolean, description: "partial work was preserved on the errored return" }
            at: { type: string, format: date-time }
            ref: { type: string, description: "pointer into .context/errors/<agent>.md (e.g. #retry-1)" }
```

#### tasks — worktree

```yaml
# …continued: WorktaskStateLedger.properties.tasks.additionalProperties.properties
        worktree:
          type: object
          description: "OPTIONAL (DV primarily) — see field notes"
          properties:
            path: { type: string }
            branch: { type: string }
```
