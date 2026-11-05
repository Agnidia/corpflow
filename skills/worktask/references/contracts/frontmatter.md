# Frontmatter

Read before authoring or validating an artifact header. Resolve optional fields through the schema links below.

## Read for related fields
- For blocked needs, read [blocked-needs](blocked-needs.md).
- For blocked artifacts, read [blocked-artifacts](blocked-artifacts.md).
- For sweep schema, read [sweep-schema](sweep-schema.md).
- For required fields, read [required-fields](required-fields.md).

<!-- canonical-body:start -->
## #frontmatter-schema

Every stage artifact (planning-N.md, architecture-N.md, …) starts with a YAML block between `^---$` markers. Token budget ≤200. Line budget ≤30.

AR and TL are optional (`skills/estimation-methodology/SKILL.md § Stage Inclusion Criteria`), so `architecture-N.md` / `coordination-N.md` may be absent. A frontmatter field referencing an absent stage's artifact is omitted, never written as a dangling path.

JSON-Schema-style spec:

### Schema — handoff base

```yaml
$schema: https://json-schema.org/draft/2020-12/schema
title: HandoffFrontmatter
type: object
required: [handoff]
properties:
  handoff:
    type: object
    required: [stage, verdict, summary, refs]
    properties:
      stage:
        type: string
        enum: [PL, AR, TL, DV, DR, SR, QA, DC, RE, FN, ST, IR, ET]
      verdict:
        type: string
        enum: [ok, blocked, escalate, pass, fail, go, no-go, approve, reject]
      summary:
        type: string
        maxLength: 200
      task_id:
        type: string
        pattern: '^[A-Z]{2}[0-9]+$'
        description: >
          OPTIONAL. The writing task's own id; its stage prefix must equal handoff.stage. Set it
          whenever the stage has more than one task, so sweep parity charges only this task's stubs.
```

### Schema — key_decisions, files_touched, next_stage_focus

```yaml
# …continued: handoff.properties
      key_decisions:
        type: array
        maxItems: 8
        items:
          type: object
          required: [id, summary, anchor]
          properties:
            id: { type: string, pattern: '^[a-z]{1,3}[0-9]+$' }
            summary: { type: string, maxLength: 160 }
            anchor: { type: string, pattern: '^[a-z0-9.\-/]+\.md#[a-z0-9\-]+$' }
      files_touched:
        type: array
        items: { type: string }
      next_stage_focus:
        type: string
        maxLength: 240
```

### Schema — open_questions, refs, constraints

```yaml
# …continued: handoff.properties
      open_questions:
        type: array
        items: { $ref: '#/$defs/SweepStub' }   # closing elicitation sweep, the only item shape
      refs:
        type: object
        additionalProperties: { type: string }
constraints:
  total_lines: { max: 30 }
  total_tokens: { max: 200, estimate: whitespace-words-times-1.33 }
```

The token estimate is a size proxy, not exact Codex or Claude tokenization.
The validator preserves capped sweep-stub and test-evidence exclusions from the discretionary budget.

### Schema — acted_on_msg_id

```yaml
# …continued: handoff.properties, beside open_questions
      acted_on_msg_id:
        type: string
        maxLength: 200
        pattern: '^[A-Za-z0-9_][A-Za-z0-9._:@/-]{0,199}$'
        description: >
          OPTIONAL, every stage. The newest orchestrator msg_id this stage acknowledged with
          `state-patch.sh --ack <ID> <msg_id>` and followed. Absent: no msg_id-bearing message
          reached this dispatch. Checked at the boundary by ack-check.sh, not by the harness.
```

### Schema — decisions_applied

```yaml
# …continued: handoff.properties, beside acted_on_msg_id
      decisions_applied:
        type: array
        items: { type: string, pattern: '^ud-[0-9]{8}T[0-9]{6}Z-[0-9]+$' }   # UD_ID_RE
        description: >
          OPTIONAL, every stage. Each user-decision ledger row this stage acted on, once
          `state-patch.sh --verify-decision <ud-id> --task-id <own id> --expect-answer <applied>`
          exited 0 for it. Absent: the stage applied no user decision.
```

The item grammar is the ledger's row id, `ud-<YYYYMMDDTHHMMSSZ>-<n>`, where `n` is the row's 1-based
line number (`UD_ID_RE` in `hooks/lib/user-decision-lib.sh`). The acceptance rule is
`skills/worktask/references/contracts/decision-authority.md § A user decision is accepted only from the ledger`.
