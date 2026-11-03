# Sweep items

Read when executing or checking sweep items. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
### Item shape

One shape across transports uses the stub-plus-anchor split `key_decisions` / `facts.decisions` already uses, because the 30-line frontmatter budget cannot hold option bodies.

| Transport | Carries |
|---|---|
| artifact body `## elicitation-sweep` | the full item: `options[]`, `recommended`, `rationale`. Canonical; required anchor. |
| `handoff.open_questions[]` frontmatter | a stub: `{id, class, ref}` |
| `facts.open_questions[]` ledger | the stub plus `stage`, `blocks_next_stage`, `status: open\|resolved` and `resolution` |
| typed return `open_questions[]` | the full item inline |

Schemas: `skills/worktask/references/contracts/frontmatter.md#frontmatter-schema` `$defs/SweepItem` (full) and `$defs/SweepStub` (stub). `options[]` holds 2–4 `{label, detail}` entries with exactly one `recommended: true`; `class` is `decision` or `escalate`; `rationale` is one line; `ref` anchors into the emitting stage's own artifact, which the orchestrator resolves at render time.

#### The stub carries no summary

`summary` is optional on the stub and canonical in the artifact body: the render reads the question text from the `ref` anchor, whose existence `handoff-harness.sh` verifies. The stub is the only accepted item shape, so an optional field needs no discriminator.

The driver is the 200-token budget on the whole `handoff:` block, enforced by `handoff-harness.sh` over the extracted frontmatter. It is a property of the block, not of the sweep: on a review stage `key_decisions` dominates, and shortening the stub alone will not bring an over-budget block back under.

#### A risk-shaped observation is not a sweep item

The class enum is exactly `decision | escalate`. An observation that records a risk without asking
anything — no options, nothing to answer, nothing to gate — belongs in the artifact's required
`follow-ups` anchor, which every development and review artifact carries. Neither sweep class is a
home for it: filing one as `escalate` to make it visible has nearly triggered a destructive action,
and filing one as `decision` puts an unanswerable question in front of the gate. If it has options
and a recommendation, it is a sweep item; if it is something the next run should look at, it is a
follow-up.

##### The enum stays narrow

Labels such as `defect`, `constraint` or `risk` name something observed, with no option set or
recommendation, so they are follow-ups, not a third class. Only the sweep has a ledger channel
(`--facts`) and a gate render while `follow-ups` reaches no decision point; that transport gap is a
follow-up, not a reason to widen the enum. Because the enum is narrow, its refusal is loud:
`state-patch.sh` echoes an out-of-enum rejection to standard output as well as standard error.

#### A re-emitted stub carries its answer forward

When a stage re-emits an item it already emitted (a rework round, a retry), it carries the existing `status` and `resolution` forward rather than re-emitting the item as open. `open < resolved` is monotone in both transports — artifact frontmatter `handoff.open_questions[]` and `state.json facts.open_questions[]` via `state-patch.sh --facts`. The ledger union refuses the downgrade (`state-patch.sh`); this rule is the artifact-side half, the one that survives ledger eviction. Re-marking a settled item open destroys its recorded answer.

#### Ledger bounds

At most 4 items per stage (the ask tool's questions-per-call ceiling, so one stage never needs
splitting). `state-patch.sh` clamps `facts.open_questions[]` to the newest 4 per task, resolved-first
inside each task's bucket: every unresolved item survives ahead of every resolved one, because an
unresolved item is still owed a render at the FN gate while a resolved one is already eviction bait
under eviction-order rule 2. Same single-chokepoint idiom as `facts.decisions` (newest 8 per task)
and `facts.dispatched_agents` (6, launched-survive-first, and not partitioned — it is not a
per-writer field).

##### Ledger bounds — the partition key

The bucket is the full task id (`DV1`), never the bare stage code: a four-way DV split is four
independent writers sharing one code, and a stage-code bucket would let DV3 evict DV0's items.
Questions carry the id in their own `sw-<TASK_ID>-<n>`; decisions carry it in `.stage`, stamped from
the writer's own identity at write time on the incoming array only, so an incumbent is never
re-attributed. An item with neither falls into a reserved `_` bucket, which keeps a pre-partition
ledger in one shared bucket rather than scattered across confident mis-attributions.

###### The partition key is not the grouping key

`.stage` on a question keeps its bare-code meaning for the FN gate's grouping. Grouping and
partitioning are two jobs, so the clamp derives its own key rather than reusing that field.

There is no migration step or tolerant reader for in-flight ledgers: an old ledger lands in the
reserved bucket or forces a logged re-merge, so it fails loudly or not at all, never by silent
mis-parse.

##### Ledger bounds — the overflow spill

Past 4 unresolved items in one task's bucket the clamp has no eviction bait left to drop, so it
evicts a live question. Those, and only those, are appended to
`.context/open-questions-<run_index>.jsonl`, one JSON object per line: the full stub plus
`spilled_at` and `spilled_from_stage`. Evicted decisions spill the same way to
`.context/decisions-<run_index>.jsonl`, minus the `was_resolved` annotation a decision has no status
to carry.

###### The spill is written before the rename

Both files are append-only, written inside the merge lock and before the ledger rename, so a
crash can leave a spill line whose eviction never committed (a duplicate the union collapses) but
never an eviction whose spill line is missing.

###### Every spill has a reader — never read a ring alone

`handoff.open_questions[]` and `facts.open_questions[]` are both the record.
`handoff-harness.sh` checks parity against ledger ∪ spill, and the FN gate reads both, unioned by
`.id` with the ledger winning on conflict: a spill line is a snapshot taken at eviction time and is
staler than an item the ledger later resolved. A missing spill file is the empty set; one that
exists but cannot be parsed is a failure, never an empty set.

The decisions ring is read the same way, by `state-patch.sh --read-decisions`. Don't read
`facts.decisions[]` alone: past eight per task it is a partial record that reports no partiality.

##### Ledger bounds — why 4 per task

4 is a deliberate bound, not a default: it equals the per-stage emission ceiling stated at the top
of this section, so a conforming writer never spills, and a writer that does spill is over-emitting,
which is a signal rather than a silent loss.

Decisions keep 8 per task: nothing caps decision emission, so a smaller number would open a new
eviction source.

###### What the per-task bound costs

Per-task partitioning multiplies worst-case capacity by the task count and there is no global
ceiling; the backstops are `validate_state`'s non-blocking `state.json … > 500 budget` notice and the
two spill files. A loud oversized ledger beats a silently lost decision.

Sweep answers are recorded in the item's own `resolution` field, not appended to
`facts.decisions[]`: one record, one place. The decisions ring is for decisions an author stated,
not for answers the gate collected, and a second write would put one answer under two bounds with
two eviction policies.

#### Item ids

`sw-<TASK_ID>-<n>` — `sw-AR0-1`, `sw-DV1-2`. Task-scoped, because the ledger unions `open_questions[]` on `.id` (`skills/worktask/references/contracts/facts-merge.md#facts-union`): an unscoped `q1` would silently replace PL's. Deterministic, so a stage re-run is byte-identical.
