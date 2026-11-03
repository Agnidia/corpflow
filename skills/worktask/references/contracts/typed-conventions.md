# Typed conventions

Read when executing or checking typed conventions. Read linked modules only when their conditions apply.

Read these sections only when this procedure cites them.

###### Section lookup 1

[Per-stage required-field matrix](required-fields.md#per-stage-required-field-matrix) · [Schema — $defs: SweepItem and SweepStub](sweep-schema.md#schema--defs-sweepitem-and-sweepstub) · [Schema — blocked_on](blocked-needs.md#schema--blocked_on)

###### Section lookup 2

[Schema — $defs: TestRunEntry](sweep-schema.md#schema--defs-testrunentry)

<!-- canonical-body:start -->
## Handoff Schemas {#handoff-schemas}

Canonical typed-return schemas — the single source of truth for the structured object a stage agent returns from its `Agent()` dispatch (`skills/worktask/references/dispatch-readiness.md § Orchestrator Execution Loop` Step 6).

Two parallel channels, neither replacing the other: the typed return is *validated*, the `handoff:` frontmatter is the *cache-friendly on-disk* form. So even on the typed path every stage still mirrors to `state.json facts` and writes its `.context/<stage>-N.md` artifact with frontmatter (durability, human readability, F4 regeneration — `skills/worktask/references/contracts/frontmatter.md#frontmatter-schema`, `skills/worktask/references/contracts/fallbacks.md#fallback-paths`).

### Schema conventions

JSON Schema draft 2020-12. Each stage's `verdict` enum MUST match that stage's row in `#frontmatter-schema § Per-stage required-field matrix` — one verdict vocabulary per stage across both channels, plus `blocked` alongside a `blocked_on` under that section's cross-stage blocked exception. The `required` set is the typed superset of that stage's frontmatter required fields (DR's `key_decisions (= findings)` becomes the typed `findings`/`blockers` arrays).

#### Conventions — the sweep field

Every stage schema requires `open_questions` — the closing elicitation sweep (`skills/worktask/references/contracts/sweep-boundaries.md § Closing Elicitation Sweep`) is mandatory for all thirteen, and an empty array is the legal form for a stage with nothing to ask. Its `$ref: '#/$defs/SweepItem'` resolves against the single `$defs` block at `#frontmatter-schema § Schema — $defs: SweepItem and SweepStub`.

##### Conventions — the optional fields

`blocked_on` is optional on every stage — one shape, defined once at `#frontmatter-schema § Schema — blocked_on` — and no stage's vocabulary limits it, under the cross-stage blocked exception; absent means the stage is not blocked on a typed need.

`acted_on_msg_id` and `decisions_applied` are optional on every stage too, on the terms their frontmatter schemas state. `ack-check.sh` enforces `acted_on_msg_id`, not the validator.

###### Conventions — the $defs pointer is an obligation

The stage schemas below are printed without it, or without `TestRunEntry` (`#frontmatter-schema § Schema — $defs: TestRunEntry`, referenced by DVHandoff and QAHandoff), so an item shape is never restated per stage. Whatever passes a stage schema to `Agent()` must inline those `$defs` blocks alongside it; no shipped file implements that step today, and nothing executes these schemas, so the `$ref` is a specification pointer rather than a live resolution.

The schema is passed as an `Agent()`/`agent()` argument, never inserted into preamble sections [1][2][4][4b], so schema dispatch leaves cache-prefix byte-identity untouched (`skills/worktask/references/contracts/prompt-layout.md#cache-prefix`).


## Select the stage schema

| Stage | Read before typed dispatch |
|---|---|
| PL | [PLHandoff](typed-pl-ar-tl.md#plhandoff) |
| AR | [ARHandoff](typed-pl-ar-tl.md#arhandoff) |
| TL | [TLHandoff](typed-pl-ar-tl.md#tlhandoff) |
| DV | [DVHandoff](typed-dv.md#dvhandoff) |
| DR | [DRHandoff](typed-dr-sr-qa.md#drhandoff) |
| SR | [SRHandoff](typed-dr-sr-qa.md#srhandoff) |
| QA | [QAHandoff](typed-dr-sr-qa.md#qahandoff) |
| DC | [DCHandoff](typed-dc-re-fn.md#dchandoff) |
| RE | [REHandoff](typed-dc-re-fn.md#rehandoff) |
| FN | [FNHandoff](typed-dc-re-fn.md#fnhandoff) |
| ST | [STHandoff](typed-st-ir-et.md#sthandoff) |
| IR | [IRHandoff](typed-st-ir-et.md#irhandoff) |
| ET | [ETHandoff](typed-st-ir-et.md#ethandoff) |

Include [sweep-schema.md](sweep-schema.md) for shared definitions; DV and QA also use its `TestRunEntry` definition.
