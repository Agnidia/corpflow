# Closing sweep step c3c4  auto answer then render

Read when executing or checking closing sweep step c3c4  auto answer then render.

Procedure routing: [workflow](workflow.md).

<a id="section-lookup-1"></a>
Related: [Escalation guard — escalate stops at every boundary](plan-transition.md#escalation-guard--escalate-stops-at-every-boundary)

<!-- canonical-body:start -->
#### Step C.3–C.4 — auto-answer, then render

3. **C.3 — Auto-answer.** Only when `decision_gate == "auto"`: resolve the
   `effective_class == "decision"` items on the § Step C.0a rule — each item's own emitting
   stage's agent and model, at `effort_for_resolver` of that stage's ledger effort — grouping the
   batch by originating stage and issuing one dispatch per group; C.3 and C.0a share one resolver
   contract. Audit `auto_decision_dispatched` →
   `auto_decision_resolved`, `subject:"FN<N>"`, carrying the same effort fields C.0a records. A
   stage row with no `metadata.effort` is skipped exactly as at C.0a (`resolver_skipped`,
   `reason: "effort_unstamped"`) and its items render at C.4.

##### Step C.4 — where the question text comes from

4. **C.4 — Render.** Present the remaining items through `AskUserQuestion`, grouped by originating
   stage, in calls of at most 4 questions (the tool's per-call ceiling). The question text comes
   from the resolved `ref` anchor body, not from the stub — the stub carries no `summary`, and
   `handoff-harness.sh check_sweep_ref_anchor` guarantees that anchor exists. Options are
   `options[]` with the `recommended: true` entry marked, shown with the `rationale`. These calls
   precede the gate's approve/reject call and never merge into it: a merged call overflows at four-plus items and entangles sweep answers with the
   gate's reject/resume path. Each question's `header` is the item's `id` (`sw-<TASK_ID>-<n>`), so
   the user-decision hook scopes the recorded answer to the emitting task
   (`hooks/references/user-decision-ledger.md § Scope ladder`).


#### Step C.5 — record, and the unattended lanes

For each answer, the orchestrator writes the whole stub through `state-patch.sh --facts`:
`id`, `class`, `ref`, `blocks_next_stage`, `status: "resolved"`, and `resolution: "<answer>"`.
Never write only `{id,status,resolution}`: the union replaces the object and rejects incomplete stubs.
Mark delegated answers `(auto-decided)`; do not append them to `facts.decisions[]` or delete the question.
The union refuses status/resolution downgrades.

Audit `sweep_resolved` with the rendering boundary as subject (`PL<N>`, `<CODE><N>`, or `FN<N>`).
If C.2 raised either axis, update both the ledger and artifact frontmatter stubs; parity rejects divergence.
Only after a successful write may the orchestrator relay an answer. A failed write relays nothing and follows Error Handling.
Return to the separate approval gate; recording never approves it.

<a id="step-c3--why-step-a4-is-not-folded-in"></a>
<a id="step-c5--the-write-back-is-a-whole-stub"></a>
##### Step C.5 — the unattended lanes

Recording never stops; only prompting does. Under `fn_gate: "bypass"` or any bypassed gate, skip C.4
for effective-`decision` items and audit `sweep_recorded` for them. Effective-`escalate` items take
the lane § Escalation guard — escalate stops at every boundary picks. A stop renders them at C.4 and
records the answers here. A `/megatask` per-issue run parks the issue exactly as § Escalation
guard — unattended `/megatask` per-issue runs (PARK) specifies. Only a lane with no reachable human
records them unanswered: one `sweep_escalation_unprompted` audit row per item, with
`metadata: {id, stage, ref}`, and the run continues. Every one of those audit subjects is
the rendering boundary, `<CODE><N>` — `FN<N>` for a batched item, the emitting stage's own id for a
blocking one. Full carrier table: `skills/worktask/references/contracts/sweep-obligations.md § Unattended fallbacks`.
