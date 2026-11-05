# Decision delegation

Read when executing or checking decision delegation.

Procedure routing: [orchestration](orchestration.md).

<a id="section-lookup-1"></a>
Related: [PRECONDITION CHECK](loop-entry.md#precondition-check)

<!-- canonical-body:start -->
## Auto-Decision Delegation (decision_gate)

Carried by `PL0.metadata.decision_gate` — `"user"` (default) or `"auto"` (`--auto=[decision]`, or
per-issue by `/megatask`). Bypasses no gate. Drives three delegations:

| Items | Delegate | Procedure |
|---|---|---|
| PL0's, at the plan gate | PM on `model: "fable"` (loop step 5f's `"opus"` capability fallback applies) | `workflow.md § Step A.4` |
| any other stage's blocking `decision` items, at that stage's own boundary | that stage's own agent and model, at `effort_for_resolver(metadata.effort, metadata.model)` | `§ Step C.0a`, loop step 6.6a |
| the non-blocking batch, at the FN gate | same rule as C.0a, grouped by originating stage | `§ Step C.3` |

PL keeps its own delegate because it is an exception stage (`stage-contracts.md § Exceptions — PL,
FN, ST, IR`) whose boundary *is* the plan gate. Precondition: § PRECONDITION CHECK Signal 2b.

### decision_gate — what none of the three may touch

Escalation-class items reach no delegate — `skills/worktask/references/plan-transition.md § Escalation guard (BINDING)` —
which keeps `--auto=[decision]` from widening what a run may do unattended.

### Delegate duties

The delegate decides each question default-biased, applies the amendments to the plan's EXISTING
mandatory anchors (`## requirements` / `## acceptance-criteria` / `## scope`) in one batch pass, and
returns each call as a typed-return `key_decisions[]` entry prefixed `(auto-decided)`. It never adds
a `## decisions` anchor to `planning-N.md` (the PL anchor set is exact —
`skills/worktask/references/contracts/artifact-anchors.md#anchor-allow-list`) and never re-runs `state-patch.sh`, since PL0 is
already `completed`; the plan amendments are its only writes.

### Orchestrator ledger merge

Follow `auto-decision.md#auto-decision-ledger-merge-orchestrator` for the plan delegate merge and audit rows.
Resolved answers stay in `facts.open_questions[]`; the decision delegate does not copy them into `facts.decisions[]`.

### Sweep items at the FN gate

The same delegate — one auto-answer authority, not a second — answers `class: decision` closing-sweep
items at loop step 4.9(a2), after the raise-only guard has reclassified them. Audit vocabulary is
reused with an FN subject: `auto_decision_dispatched` → `auto_decision_resolved`, `subject:"FN<N>"`.

### Escalation class

Escalation-class questions (irreversible/destructive, scope-expanding, security-posture-weakening,
spend-authorizing) are never auto-decided — they return as `escalate` items and force a user stop
even under `plan_gate: "bypass"`, resolved by an `approval_received subject:"PL<N>"` row. An
unattended `/megatask` per-issue run has no user, so the issue PARKS instead: settled
`execution.status: "failed"` + `execution.reason: "parked_escalation"` with an `escalation_parked`
audit row (`workflow.md § Escalation guard — unattended /megatask per-issue runs (PARK)`).
A parked permission need is escalation-class by construction — granting is security posture — so
no delegate answers it: § Step 7a asks the user, and a megatask per-issue run PARKs by this path.
A typed need § Step 6.5a3 parks as a `user_action` takes the same path, because only the user can
meet it.
