# Sweep boundaries

Read when executing or checking sweep boundaries. Read linked modules only when their conditions apply.

Read these sections only when this procedure cites them.

###### Section lookup 1

[Item shape](sweep-items.md#item-shape) · [A risk-shaped observation is not a sweep item](sweep-items.md#a-risk-shaped-observation-is-not-a-sweep-item) · [Resolver Effort Tier](resolver-effort.md#resolver-effort-tier)

###### Section lookup 2

[Exceptions — PL, FN, ST, IR](sweep-obligations.md#exceptions--pl-fn-st-ir)

<!-- canonical-body:start -->
## Closing Elicitation Sweep

Canonical contract for the pipeline's end-of-stage asking logic. Every other file points here; none restates it.

### What it is and when it fires

Before it hands off, every stage runs one closing pass over its own output and asks what it decided on the user's behalf that the user would rather decide. Each surviving question becomes a typed `open_questions[]` item (§ Item shape).

Every template that shows `open_questions[]` inherits this rule and its vocabulary: an observation with nothing to answer is not a sweep item and goes to `follow-ups` (§ A risk-shaped observation is not a sweep item).

Every stage runs it. A stage with nothing to ask emits an explicit `open_questions: []` plus a one-line "nothing to elicit" statement under its `## elicitation-sweep` heading, a required H2 anchor in every artifact (`skills/worktask/references/contracts/artifact-anchors.md#anchor-allow-list`). Silence fails the contract, because an omitted sweep and an empty one otherwise look the same.

#### Agents emit; the orchestrator asks

Each stage writes its own stubs into `facts.open_questions[]` in the `state-patch.sh --facts` payload of its self-patch call. Nothing derives them from the frontmatter, so a stub that skips `--facts` never reaches a render (`skills/worktask/references/contracts/facts-merge.md#facts-union`). No stage agent holds `AskUserQuestion`; only the orchestrator renders.

#### Where an item is answered

Two destinations, selected per item by `blocks_next_stage`, never by stage:

- `blocks_next_stage: true` → answered at its own stage boundary, before the next stage is dispatched, because the next stage would otherwise build on a guess. PL's sweep is the standing instance, answered at the plan gate.
- absent or `false` → accumulates in the ledger and renders at the FN gate, grouped by originating stage, in batches of ≤4, immediately before the existing approve/reject call (`skills/worktask/references/workflow.md § Step C`; `skills/worktask/references/orchestration.md` loop step 4.9).

No new gate is created, and the FN and plan gates keep their existing firing conditions. A blocking item does add a round-trip at its own boundary, which is why the flag is set per item rather than per stage. Who takes it depends on the stage (§ Blocking items are resolved, not asked).

#### Blocking items are resolved, not asked

A `blocks_next_stage: true` item from a stage other than PL, FN, ST or IR does not stop the run for a human. It goes to a sub-agent dispatched one effort tier above the stage that raised it, which answers it from the stage's own artifacts; the orchestrator waits for that answer and dispatches the next stage. Mechanism: `skills/worktask/references/workflow.md § Step C.0a`. Tier choice, transport and clamp: § Resolver Effort Tier.

The four exception stages keep their existing surfacing (§ Exceptions — PL, FN, ST, IR): PL's items are the plan gate's business, and FN/ST/IR `decision` items are already recorded rather than prompted, so there is nothing for a resolver to unblock.

##### What the resolver is given

The stub carries `{id, class, ref, blocks_next_stage}`, and `skills/worktask/references/contracts/required-fields.md § Token budget` caps a handoff block at 200 tokens, too small for decisions. The resolver gets paths, not inlined content, and reads on demand. Filenames resolve through `handoff-protocol.md #stage-artifact-map`; use no other mapping.

| Tier | Contents |
|---|---|
| in full | the emitting stage's own artifact — it holds the `## elicitation-sweep` body with `options[]`, `recommended` and `rationale` |
| in full | `planning-N.md` — `## requirements`, `## acceptance-criteria`, `## scope` bound every answer |
| frontmatter only | every completed stage's artifact — the designed compression form |
| ledger | `facts.decisions[]`, `facts.verdicts`, and the item's already-`resolved` siblings — prior commitments the answer must not contradict |
| on demand | `files_touched` from the emitting stage's handoff, and any artifact the item names |

##### What the resolver is given — declaring the full reads

Full reads go in the existing `deep_reads` field (`handoff-protocol.md § Schema — deep_reads`) with `reason: ambiguous`. A resolver's `deep_reads` is exempt from the B4 fan-in tripwire: that signal means "a producing stage's frontmatter is under-informative", and a resolver deep-reads by construction.

##### The escalation guard is untouched

Only `effective_class == "decision"` items reach a resolver, and only after the § Step C.2 raise-only join has run, so an item the orchestrator raises to `escalate` never arrives. Escalate items stop the run as before; nothing here widens what runs unattended (`skills/worktask/references/plan-transition.md § Escalation guard (BINDING)`). Don't relabel an escalate item as a decision to make a run quieter.

#### Facts are not sweep items

A question whose answer some artifact already holds is the agent's to resolve, not the user's to answer; an expensive lookup is delegated work, not a sweep item. The rule is stated once at `skills/worktask/references/planning-decisions.md § Facts are PL0's job; decisions are the user's` and binds every stage, not only PL.
