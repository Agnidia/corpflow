# Sweep obligations

Read when executing or checking sweep obligations. Read linked modules only when their conditions apply.

Read these sections only when this procedure cites them.

###### Section lookup 1

[Where an item is answered](sweep-boundaries.md#where-an-item-is-answered)

<!-- canonical-body:start -->
### Sweep obligation matrix

Every code in `stage-codes.md § Primary Stages`, unioned with the `handoff-protocol.md § Handoff
Schemas` titles, owes a sweep. No stage is exempt and there is no lower tier: a missing sweep fails
the run. The default: an item is surfaced at the FN gate when non-blocking and at this stage's own
boundary when blocking, and in an unattended lane a `decision` item is recorded, not prompted, while
an `escalate` item still stops at its boundary unless § Unattended fallbacks gives its lane nobody
to stop for. Under `fn_gate: "bypass"` nothing is deferred to the FN gate (§ Under fn_gate: "bypass").

Which side applies is decided per item by `blocks_next_stage` (§ Where an item is answered), never by
the stage code. `skills/worktask/references/workflow.md § Step C` renders the non-blocking side; § Step C.0 renders the
blocking side at each boundary.

#### Exceptions — PL, FN, ST, IR

Four stages depart from that default, and only in how an item is surfaced or what an unattended lane
does with it — never in whether the sweep is owed:

| Code | Obligation | Surfaced by (non-blocking / blocking) | Unattended fallback |
|---|---|---|---|
| PL | Required | plan gate / plan gate (PL's boundary IS the plan gate) | auto-decided at § Step A.4, else recorded — unresolved `escalate` items still force the checkpoint stop |
| FN | Required | recorded for ST / FN's own boundary, before ST | `fn_gate: "bypass"` ⇒ `[]` (below); else `decision` items recorded, not prompted; `escalate` items stop at FN's boundary unless their lane parks or records (§ Unattended fallbacks) |
| ST | Required | recorded as follow-ups / ST's own boundary | as FN, the bypass rule included |
| IR | Required | FN gate / this stage's own boundary | `--emergency` bypasses both gates: `decision` items recorded; `escalate` items still stop |

#### Why those four depart

PL, FN and ST differ because they have no *later* gate to defer to — PL's own boundary is the plan
gate, and FN and ST sit at or past the FN gate — so "surface at the FN gate" is not a destination
they can name. IR differs because `--emergency` bypasses both gates by design.

#### Under fn_gate: "bypass"

The FN gate never shows, so an item deferred to it stalls the run. FN and ST emit
`open_questions: []`. A non-blocking observation goes in the artifact body instead: FN's
`complete-summary-N.md` follow-ups, ST's `## followups`. A `decision` FN must take uses the
`recommended` option, and FN records it under its decisions with the resolution `(auto-recorded)`.
`escalate` items are unchanged (§ Unattended fallbacks).

Every other code — AR, TL, DV, DR, SR, QA, DC, RE, ET — takes the default sentence above
unmodified, and a new stage code joins them by saying nothing here.

### Auto-answer boundary

Auto-answerable: `class: decision` items whose recommendation is reversible, in-scope, posture-neutral and spend-free. Never auto-answerable: the escalation class, enumerated once at `skills/worktask/references/plan-transition.md § Escalation guard (BINDING)` and not re-listed here.

There is exactly one auto-answer authority — the existing Fable decision delegate, widened to sweep items (`skills/worktask/references/orchestration.md § Auto-Decision Delegation`), running only under `decision_gate: "auto"`.

#### Self-labels raise, never lower

`class` is the ordered lattice `decision < escalate`, and the orchestrator's effective class is `max(agent label, orchestrator label)`, computed before any auto-answer, so raising is honoured and lowering is refused by construction. The ledger enforces the join on `class` too: `state-patch.sh --facts` keeps an `escalate` item at `escalate` whatever a later stub says, so a stage cannot lower an item another labeller raised; the refusal exits 2 and writes a `facts_items_rejected` audit row. `blocks_next_stage` is the 2-element lattice `false < true` and joins the same way, by OR: the orchestrator may raise an item to blocking, never clear the agent's flag. The axes are orthogonal — an `escalate` item may or may not block. Mechanism: `skills/worktask/references/plan-transition.md § Escalation guard — raise-only self-labels`. Escalation-class behaviour under a bypassed gate or an unattended lane is per carrier, one row each in § Unattended fallbacks.

##### The join is over labellers, never transports

The lattice resolves a disagreement between two parties labelling one item. It does not apply when one agent's artifact stub and its own ledger stub disagree: that is a single author with two copies, so a divergence is a defect, not a lattice. Don't join them. The harness fails the stage (`handoff-harness.sh check_sweep_ledger`, which compares `class` and `blocks_next_stage`, not just `id`) and the agent reconciles both copies; joining would turn a bookkeeping slip into a real gate. The orchestrator is bound too: a value it raises at Step C.2 is written at C.5 to both the artifact's `handoff.open_questions[]` stub and `state.json facts.open_questions[]`, because a one-sided write creates the divergence the harness refuses.

### Not the sweep

The sweep carries decisions a person would want to make. Four cases already own a channel; use it rather than routing them through the sweep.

| Case | Use this instead | Defined at |
|---|---|---|
| runtime evidence is needed | `requests_test_evidence:` in the stage artifact | `skills/worktask/references/testing-strategy.md § Test-Execution Authority` |
| a stage PL0 skipped is needed | `requests_stage_escalation:` in the stage artifact | `skills/estimation-methodology/SKILL.md § Escalation schema` |
| a stage verdict | `handoff.verdict` + `facts.verdicts` | `skills/worktask/references/contracts/required-fields.md` § Per-stage required-field matrix |
| an ethics decision | `ethics-review-N.md` `Decision ∈ {pass, block, conditional}` | `skills/worktask/references/stage-contracts.md` § #tpl-et |

### Unattended fallbacks

Recording never stops; only prompting does. A bypass records `decision` items only. An `escalate` item stops at its boundary on every row that does not say otherwise; the rule and its lane order live at `skills/worktask/references/plan-transition.md § Escalation guard — escalate stops at every boundary`. One behaviour row per carrier, each carrier detected from its own defining field.

#### Fallbacks — gate carriers

| Carrier | Detected by | Sweep behaviour |
|---|---|---|
| plan gate bypassed | `PL0.metadata.plan_gate == "bypass"` | PL's `decision` items recorded, not prompted; unresolved `escalate` items still force the plan-gate checkpoint stop; non-PL sweeps still batch at FN |
| FN gate bypassed | `PL0.metadata.fn_gate == "bypass"` | collect and audit `sweep_recorded` for `decision` items; `escalate` items stop for a checkpoint-style render at the boundary they surface on. Subject is that boundary — `FN<N>` for a batched item, `<CODE><N>` for a blocking one |
| auto decision gate | `PL0.metadata.decision_gate == "auto"` | `decision` items answered by the delegate; `escalate` items hold their own checkpoint — the plan gate for planning-stage items, finalization otherwise |

#### Fallbacks — unattended lanes

| Carrier | Detected by | Sweep behaviour |
|---|---|---|
| `--emergency` | no PL task in `tasks` | both gates bypass: `decision` items recorded, `escalate` items still stop at their boundary |
| `/megatask` per issue | `PL0.metadata.megatask_group` | PARK on any escalate item, at whichever boundary it surfaces: `workspace.json.execution.status: "failed"`, `execution.reason: "parked_escalation"`, `escalation_parked` audit row with that boundary's `<CODE><N>` subject |
| `CORPFLOW_NONINTERACTIVE=1` | environment | no reachable human: `decision` items recorded; each `escalate` item audits `sweep_escalation_unprompted` with `metadata: {id, stage, ref}`, the run continues, and FN lists it atop the PR body (`fn-preflight.sh unresolved-decisions`) |
| headless dispatch | external runner | data-only by construction — no stage agent holds the ask tool; `escalate` items recorded as the row above |
