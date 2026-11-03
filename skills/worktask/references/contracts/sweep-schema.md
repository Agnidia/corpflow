# Sweep schema

Read when composing or validating sweep items, sweep stubs, or test-run entries.

Read these sections only when this procedure cites them.

###### Section lookup 1

[DVHandoff](typed-dv.md#dvhandoff) · [DVHandoff — test-evidence field notes](typed-dv.md#dvhandoff--test-evidence-field-notes)

<!-- canonical-body:start -->
### Schema — $defs: SweepItem and SweepStub

Closing elicitation sweep item, defined once for all three transports (contract:
`skills/worktask/references/contracts/sweep-boundaries.md § Closing Elicitation Sweep`). The frontmatter and ledger
arrays carry `SweepStub`; the artifact body and the typed return carry the full `SweepItem`.

#### $defs — SweepItem (full item)

```yaml
# …continued: HandoffFrontmatter.$defs — also referenced by #handoff-schemas
$defs:
  SweepItem:
    type: object
    required: [id, summary, class, options, rationale]
    properties:
      id:        { type: string, pattern: '^sw-[A-Z]{2}[0-9]+-[0-9]+$' }
      summary:   { type: string, maxLength: 160 }
      rationale: { type: string, maxLength: 160 }
      stage:     { type: string }
      class:     { type: string, enum: [decision, escalate] }
      blocks_next_stage: { type: boolean }   # see $defs/SweepStub
```

##### $defs — SweepItem.options

```yaml
# …continued: $defs.SweepItem.properties
      options:
        type: array
        minItems: 2
        maxItems: 4                 # the ask tool's per-question option ceiling
        items:
          type: object
          required: [label, detail]
          properties:
            label:       { type: string, maxLength: 24 }
            detail:      { type: string, maxLength: 120 }
            recommended: { type: boolean }
        # Exactly one recommended option, as a schema fact rather than prose.
        contains:    { type: object, required: [recommended], properties: { recommended: { const: true } } }
        minContains: 1
        maxContains: 1
```

#### $defs — SweepStub (frontmatter + ledger)

```yaml
# …continued: HandoffFrontmatter.$defs
$defs:
  SweepStub:
    type: object
    # `summary` is optional: the question text is read from the `ref` anchor body,
    # which check_sweep_ref_anchor guarantees exists. `blocks_next_stage` is required
    # because absent and `false` are different claims: state it, never infer it.
    required: [id, class, ref, blocks_next_stage]
    properties:
      id:      { type: string, pattern: '^sw-[A-Z]{2}[0-9]+-[0-9]+$' }
      summary: { type: string, maxLength: 160 }   # OPTIONAL; the artifact body is canonical
      stage:   { type: string }
      class:   { type: string, enum: [decision, escalate] }
      ref:     { type: string, description: "anchor into the emitting stage's own artifact" }
```

##### $defs — SweepStub, the routing and answer fields

```yaml
# …continued: $defs.SweepStub.properties
      # Orthogonal to `class`: an escalate item may or may not block. The agent
      # self-labels and the orchestrator may raise false→true, never lower. That rule is
      # over labellers: this stub and its facts.open_questions[] twin have one author and
      # carry the same value, which handoff-harness.sh check_sweep_ledger enforces.
      blocks_next_stage: { type: boolean }
      status:            { type: string, enum: [open, resolved] }
      resolution:        { type: string, maxLength: 160 }
```

### Schema — $defs: TestRunEntry

One entry per runner invocation that printed its own summary line — the item shape of
`tests_executed` in DV and QA on both transports and on the ledger task row. A runner may repeat
(two scoped bats runs are two entries), entries are never folded into one count, and `[]` is legal.
Field rules: § DVHandoff — test-evidence field notes.

```yaml
# …continued: HandoffFrontmatter.$defs — also referenced by #handoff-schemas and #state-json-schema
$defs:
  TestRunEntry:
    type: object
    required: [runner, count]
    properties:
      runner:       { type: string, minLength: 1 }                   # free-form: bats, pytest, swift, …
      count:        { type: integer, minimum: 0 }                    # cases that RAN
      summary_line: { type: string, minLength: 1, pattern: '[0-9]' } # verbatim runner line
    if:   { required: [count], properties: { count: { minimum: 1 } } }
    then: { required: [summary_line] }
```

### Schema — subagents_spawned (B2 governance)

```yaml
# …continued: handoff.properties
      subagents_spawned:
        type: array
        maxItems: 5
        description: >
          OPTIONAL (B2). Sub-agents this stage dispatched, so DR/orchestrator see the
          fan-out without walking audit.jsonl. The cap of 5 is a policy tripwire — a
          stage needing more should re-split (TL). Nested spawns downshift a model tier
          and never run background-nested in a headless run.
        items:
          type: object
          required: [agent, task]
          properties:
            agent: { type: string, description: "resolved plugin:agent id" }
            task: { type: string, maxLength: 120 }
```

### Schema — deep_reads (B4 FN fan-in tripwire)

```yaml
# …continued: handoff.properties
      deep_reads:
        type: array
        description: >
          OPTIONAL (B4). Artifacts a fan-in stage (FN primarily) read in full beyond
          their ≤200-token frontmatter, with why. Empty/absent is healthy; a long list
          is the tripwire that a producing stage's frontmatter is under-informative.
        items:
          type: object
          required: [artifact, reason]
          properties:
            artifact: { type: string }
            reason: { type: string, enum: [anchor-miss, flagged-verdict, retry, ambiguous] }
```

#### deep_reads — the resolver exemption

A Step C.0a / C.3 resolver deep-reads by construction: it is handed the emitting stage's own
artifact and `planning-N.md` in full because the ≤200-token frontmatter cannot carry an `options[]`
body (`skills/worktask/references/contracts/sweep-boundaries.md § What the resolver is given`). It declares those reads here
with `reason: "ambiguous"`, but they are excluded from the B4 tripwire, because they show a sweep
item exists, not that a frontmatter failed. Tell them apart by audit row: a resolver's reads arrive
under `auto_decision_resolved`, a fan-in stage's under its own stage id.
