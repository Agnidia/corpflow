# Ledger facts

Read when executing or checking ledger facts. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
#### facts

```yaml
# …continued: WorktaskStateLedger.properties
  facts:
    type: object
    required: [files_modified, tests_added, decisions, open_questions, verdicts]
    properties:
      goal:
        type: string
        maxLength: 240
        description: "One-sentence worktask intent, populated by PL0 — see field notes"
      branch:
        type: string
        maxLength: 120
        description: "Working branch named once at PL start — see field notes"
      stream_branches:
        type: object
        propertyNames: { pattern: "^[a-z0-9]+(-[a-z0-9]+)*$", maxLength: 40 }
        additionalProperties: { type: string, pattern: "^[A-Za-z0-9._/][A-Za-z0-9._/-]{0,199}$" }
        description: "OPTIONAL (additive) — stream -> stream branch, FN multi-stream arm only; see field notes"
      files_modified: { type: array, items: { type: string } }
      tests_added: { type: array, items: { type: string } }
```

#### facts — decisions

```yaml
# …continued: WorktaskStateLedger.properties.facts.properties
      decisions:
        type: array
        maxItems: 8   # per task — there is no global ceiling
        description: "Bounded (B3): newest 8 per task survive, partitioned by the writing task's id (from `stage`, stamped at write time). Clamped at the single write chokepoint state-patch.sh atomic_merge() (AD-7), not by producers — matches eviction-order rule 3. Evicted items spill to .context/decisions-<run_index>.jsonl."
        items:
          type: object
          required: [id, summary, ref]
          properties:
            id: { type: string }
            summary: { type: string, maxLength: 160 }
            ref: { type: string }
```

#### facts — open_questions

```yaml
# …continued: WorktaskStateLedger.properties.facts.properties
      open_questions:
        type: array
        maxItems: 4   # per task — no global ceiling
        description: "Bounded (B3): newest 4 per task, keyed by the TASK_ID in the item's own `sw-<TASK_ID>-<n>` id, `status: resolved` evicted first inside each bucket. 4 equals the per-stage emission ceiling, so a conforming writer never spills. Clamped at state-patch.sh atomic_merge() (AD-7); evictions spill to open-questions-<run_index>.jsonl."
```

##### facts — open_questions, the item shape

```yaml
# …continued: facts.open_questions
        items:
          # Mirrors $defs/SweepStub — the only accepted item shape here too, so the
          # ledger and the frontmatter cannot disagree about what an entry is.
          type: object
          required: [id, class, ref, blocks_next_stage]
          properties:
            id: { type: string, pattern: '^sw-[A-Z]{2}[0-9]+-[0-9]+$' }
            summary: { type: string, maxLength: 160 }   # OPTIONAL; the body is canonical
            stage: { type: string }                     # bare CODE, for FN-gate grouping
```

##### facts — open_questions, the partition key

The clamp's partition key is derived from the item's id, not from `stage`: `stage` is the bare
code the FN gate groups by, and grouping is not partitioning. Breaking for in-flight ledgers — no
migration, no tolerant reader.

##### facts — open_questions, the ledger-only fields

```yaml
# …continued: facts.open_questions.items.properties
            class: { type: string, enum: [decision, escalate] }
            ref: { type: string }
            # q9 carrier: this item is answered at its own stage boundary, not held
            # to the FN gate. See $defs/SweepStub for the raise-only rule. This value must
            # equal the frontmatter stub's — a divergence fails check_sweep_ledger.
            blocks_next_stage: { type: boolean }
```

###### facts — open_questions, the answer fields

```yaml
# …continued: facts.open_questions.items.properties
            # Read by eviction rule 2 and by the render, so an answered item is not
            # re-prompted on a resumed run. `open < resolved` is a monotone join at
            # the union (state-patch.sh): a later write may raise, never downgrade.
            status: { type: string, enum: [open, resolved] }
            # Where a sweep answer lands; not facts.decisions[] (stage-contracts.md
            # § Closing Elicitation Sweep says why).
            resolution: { type: string, maxLength: 160 }
```

#### facts — verdicts, files_read

```yaml
# …continued: WorktaskStateLedger.properties.facts.properties
      verdicts:
        type: object
        additionalProperties: { type: string }
        description: "Keyed by task id (DV0, DV1) plus a derived stage-code key (DV) holding the worst verdict among that stage's reported tasks — see field notes"
      files_read:
        type: array
        maxItems: 30
        description: "Source files read by prior stages; DR/QA prefer git diff. Newest 30 survive, clamped in the state-patch.sh bounds filter — see field notes"
        items:
          type: object
          required: [path, stage]
          properties:
            path: { type: string }
            stage: { type: string, enum: [PL, AR, TL, DV, DR, SR, QA, DC, RE, FN, ST, IR, ET] }
            lines: { type: string, description: "'all' or '<start>-<end>'" }
```

#### facts — dispatched_agents

```yaml
# …continued: WorktaskStateLedger.properties.facts.properties
      dispatched_agents:
        type: array
        maxItems: 6
        description: "OPTIONAL (additive) — see field notes. Bounded (B3): 6 survive — the newest 6 launched first, free slots filled by the newest non-launched, survivors in original order. Clamped in the state-patch.sh bounds filter (AD-7)."
        items:
          type: object
          required: [stage, task_id, subagent_type, status]
          properties:
            stage: { type: string, description: "stage CODE (DV, DR, …)" }
            task_id: { type: string, description: "Ledger key (e.g. DV0) — the dedupe key" }
            subagent_type: { type: string, description: "resolved plugin:agent id" }
```

#### facts — dispatched_agents (continued)

```yaml
# …continued: dispatched_agents.items.properties
            agent_id: { type: string, description: "OPTIONAL launch-ack id when the runtime surfaces one (background-default dispatch); resume degrades to best-effort subagent_type match when absent; for an in-process teammate it is the agent ID, its name@team address is teammate_id" }
            name: { type: string, description: "OPTIONAL named-spawn handle (megatask lanes); readable default names, /rename persists across restarts" }
            model_requested: { type: string, description: "OPTIONAL — metadata.model alias at dispatch" }
            model_resolved: { type: string, description: "OPTIONAL best-effort — model that actually ran (claude agents --json / audit); omit when unknown" }
            status: { type: string, enum: [launched, completed, failed] }
```

#### facts — capabilities

```yaml
# …continued: WorktaskStateLedger.properties.facts.properties
      capabilities:
        type: object
        description: "OPTIONAL (additive); probe cache for account-level hard-fails — see field notes"
        additionalProperties: true
```
