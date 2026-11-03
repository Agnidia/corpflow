# Ledger edges

Read when executing or checking ledger edges. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
#### handoffs

```yaml
# …continued: WorktaskStateLedger.properties
  handoffs:
    type: object
    additionalProperties:
      type: string
      maxLength: 300
      pattern: '.*ref:.*'
```

#### Field notes — handoffs (edge registry)

Keys are `<PREV_CODE>→<TASK_ID>`: the source side is the predecessor's bare stage code, the
destination side is the writing task's own id (`TL→DV1`, not `TL→DV`), because a split stage has
one writer per task and a shared key would let their edges overwrite each other. There is no
migration and no tolerant reader: an old-shape key reads as absent, which forces a logged re-merge
rather than a silent mis-parse.

##### Reading the edge tables

The tables below name edges, so their rows stay stage-level and are read with one rule applied:
the destination is written as the writing task's id, so a split stage contributes one row per task.
The rows are not enumerated per task — PL0 sizes each split per run.

PL0 sizes the stage set, so several stages have more than one possible predecessor — the edge
written is the one whose when-clause holds. A stage that never ran never appears in an edge label; a
"phantom edge" for an absent stage is a ledger defect.

The tables are exhaustive across all three pipelines (standard, secure/full, emergency). The
emergency pipeline (`IR→DV→DR→QA→RE→FN`) has no PL, AR or TL stage, so DV's predecessor there is
`IR` and RE's is `QA`. RE's predecessor is also `QA` on a standard, secure or full run that
excluded DC. Any predecessor not listed is not a legal edge; add a row before writing one.

##### Edge table — standard and secure pipelines

| Edge | When | Written by |
|------|------|-----------|
| `USER→PL` | always (standard/secure) | PL |
| `PL→AR` | AR is in the plan | AR |
| `AR→TL` | TL is in the plan AND AR ran | TL |
| `PL→TL` | TL is in the plan AND AR was excluded | TL |
| `TL→DV` | TL ran | DV |
| `AR→DV` | AR ran AND TL did not | DV |
| `PL→DV` | neither AR nor TL ran | DV |
| `DV→DR` | always (DR is a floor stage) | DR |
| `DR→SR` | SR is in the plan | SR |
| `SR→QA` / `DR→QA` | SR ran / SR was excluded | QA |
| `QA→DC` | DC is in the plan | DC |
| `DC→RE` | RE is in the plan AND DC ran | RE |
| `QA→RE` | RE is in the plan AND DC was excluded | RE |
| `RE→FN` | FN is in the plan AND RE ran | FN |
| `DC→FN` | FN is in the plan AND DC ran AND RE did not | FN |
| `QA→FN` | FN is in the plan AND neither RE nor DC ran | FN |
| `FN→ST` | ST is in the plan AND FN ran | ST |
| `RE→ST` / `DC→ST` / `QA→ST` | ST in plan, FN not run: latest of RE, DC, QA that ran | ST |

##### Edge table — what "ran" means

A stage ran when its `tasks` row exists and is not `skipped`. With FN and ST both excluded, no edge
names FN: the run ends on the edge into the last stage that ran.

##### Edge table — emergency pipeline and the ethics gate

| Edge | When | Written by |
|------|------|-----------|
| `USER→IR` | always (emergency pipeline) | IR |
| `IR→DV` | emergency pipeline — no PL/AR/TL stage exists | DV |
| `QA→RE` | emergency pipeline (RE's predecessor is QA, not DC) | RE |
| `<invoker>→ET` | the ethics gate fired; `<invoker>` is whichever stage triggered it | ET |

The writer passes its predecessor to `state-patch.sh --stage <CODE> --prev <PREV>` (plus
`--task-id <TASK_ID>` in a fan-out); the script composes `<PREV>→<TASK_ID>` mechanically and knows
none of the when-clauses. `USER` is a predecessor
only: it owns no artifact and is never a valid `--stage`.

#### #layer-1-fallback

Every stage agent's State Patch section points here. Three outcomes, in order.

1. Exit 3 — `--prev` given, `--via` absent, no artifact resolved: the self-patch signature.
   The stage claims an artifact that is not on disk. Write it and re-run. If you cannot, use
   item 2 — `--allow-missing-artifact` only silences the error and patches nothing.
2. The tool cannot run at all (not granted, denied, not found). Do not skip silently.
   `Edit` `.context/state.json` directly: write both the `tasks.<ID>` completion entry and the
   `handoffs["<PREV>→<TASK_ID>"]` edge — the destination is your task id (`TL→DV1`), not the bare
   stage code — then record the failure under `metadata.pl_tooling_gaps`.
   The SubagentStop hook is not a substitute: it builds its args without `--prev`, so it
   repairs the stage entry and drops the edge.
3. `jq` or `.context/state.json` absent — skipping is correct here, and only here.
