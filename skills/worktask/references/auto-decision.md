# Auto-decision pre-pass (Step A.4)

Read from `skills/worktask/references/workflow.md § Step A.4` when `tasks.PL0.metadata.decision_gate == "auto"` and
`facts.open_questions[]` holds a `sw-PL<N>-*` item whose `status` is not `"resolved"`. Any other
run skips this file. Escalation-class questions never reach the delegate:
`skills/worktask/references/plan-transition.md § Escalation guard (BINDING)` stays in force on every run.

## Step A.4 — the delegate dispatch

1. Append an `auto_decision_dispatched` audit row (`subject:"PL<N>"`, `metadata.questions: <count>`).
2. Re-dispatch PM as a decision delegate on the Fable model:
   `Agent({ subagent_type: "corpflow:product-manager", model: "fable", prompt: <decision prompt> })`,
   the prompt carrying the open-question list verbatim (each with its recommended default) and the
   plan file path. **Model fallback**: loop step 5f exactly (`skills/worktask/references/orchestration.md § Step 5f —
   model resolution`) — if
   `facts.capabilities.fable_dispatch == "credit_blocked"`, dispatch on `"opus"` and audit
   `model_resolution_constrained`.

## Step A.4 stamps no approval carrier

This pre-pass bypasses no gate: resolving open questions answers plan content without approving
the plan, and every path out of here falls through to Step A.5, the sole stamping point. A stamp
here would approve a `checkpoint` run before any human has seen the plan.

## Auto-decision recording contract

The delegate decides every non-escalation question (default-biased — deviate from PM's recommended
default only with stated evidence), applies the amendments to the plan's existing mandatory anchors
(`## requirements` / `## acceptance-criteria` / `## scope`) in one batch pass, and returns each
decision as a typed-return `key_decisions[]` entry prefixed `(auto-decided)`, plus any `escalate`
items. It adds no new anchor (`handoff-protocol.md § #anchor-allow-list`) and does not run
`state-patch.sh`: PL0 is already `completed`, so the plan amendments are its only writes.

## Auto-decision ledger merge (orchestrator)

3. On return, the orchestrator applies [Step C.5](closing-sweep-step-c3c4--auto-answer-then-render.md#step-c5--record-and-the-unattended-lanes)
   to every whole stub, marking the answer `(auto-decided)`. Resolve in place; never delete items or append to `facts.decisions[]`.
   Downstream stages read `facts.open_questions[].resolution` on entry. A failed merge relays no answer and follows Error Handling.

### Auto-decision ledger merge — the audit row

4. Append one `auto_decision_resolved` audit row (`subject:"PL<N>"`, `metadata: { decided: <count>,
   escalated: <count>, model_resolved: <alias>, decisions: [{question, answer, rationale}] }`) — the
   per-question rationale is carried there, one line each.

## Presentation in the gate summary

On a `checkpoint` plan gate the Step A.5 summary lists every auto-decided question with its
answer marked `(auto-decided by Fable — see facts.open_questions[].resolution / audit)`, so the user
approves the decisions together with the plan. On `bypass`, the `auto_decision_resolved` audit rows
plus each item's own `resolution` are the durable record.
