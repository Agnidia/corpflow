# Planning decisions

Read when executing or checking planning decisions.

Procedure routing: [pl0-procedure](pl0-procedure.md).

<!-- canonical-body:start -->
## Scope-Term Disambiguation

Before finalizing a plan draft, scan the task text for a scope noun with multiple plausible referent domains ("artifacts", "the system", "the tests"). When competing interpretations map to materially different file sets — swinging the complexity score by more than ~20% — do not silently take the broadest reading. Either (a) state the chosen interpretation in `## summary` as a vetoable assumption with a one-line justification, or (b) ask one clarifying question before drafting when the swing changes the stage set or tier.

## Plan-Gate Open-Question Batching

Every plan-gate question is a closing-sweep item like any other stage's: a full `SweepItem` under
`## elicitation-sweep` (`id: sw-PL<N>-<n>`, `class`, 2–4 `options[]` with exactly one
`recommended: true`, one-line `rationale`), with its stub in both `handoff.open_questions[]` and the
PL `--facts` payload. `## summary` keeps a one-line-per-item preview so the reader meets the
questions before the plan body; the option bodies live only under the anchor.

At most 4 items per stage — the ask tool's per-call ceiling. A surplus defers to a later round
(§ Dependency ordering) rather than a second call. Surface the batch in a single gate round-trip
and apply the user's amendments in one batch pass before marking PL0 complete, not one PL resume
per answer.

### Facts are PL0's job; decisions are the user's

A candidate question is a fact when some artifact already holds its answer — the filesystem, git
history, a manifest, a lint's exit code, `gh`, or any tool PL0 can run. Facts never reach the plan
gate: PL0 resolves them and records the value in the plan, marked verified. A candidate is a
decision only when the answer turns on what the user wants rather than on what is true.
`open_questions[]` carries decisions only. This rule binds every stage's closing sweep
(`skills/worktask/references/contracts/sweep-boundaries.md § Closing Elicitation Sweep` points back here).

Test each candidate: name the command, file, or tool that would answer it. If you can, delete the
question and run it. Worked example and its assertions:
`skills/worktask/references/fixtures/plan-gate-questions/01-facts-only-zero-questions.md`.

#### Cost is not an exemption

When the lookup is slow or wide — a repo-wide sweep, a cross-plugin check, a `gh` query over many
issues — dispatch a subagent to do it and wait for the result. Expense makes a fact delegated work,
never a gate item: a fact surfaced as a question costs a gate round-trip, and the user, lacking the
repository in context, often answers it wrong.

### Dependency ordering across gate rounds

A question whose answer depends on another still-open question is deferred to a later round, not
batched beside it — otherwise the user must answer the second under every branch of the first.

Emit only the independent questions this round. Record each deferred question in the plan text next
to the question it waits on. After the batch pass applies the answers, re-evaluate every deferred
question: the answer often resolves it outright, frequently into a fact PL0 then looks up, and only
what survives becomes a second round.

### Assumption tagging for plan-shaping questions

A question whose answer would change the plan's shape — scope boundary, stage set, or target file
set — cannot wait for the gate, because the plan is written against some answer either way. Write
the plan against the recommended default and mark every section that answer would invalidate with
an inline `assumes qN` tag, so the reader sees each answer's blast radius before answering. The
gate is unchanged. A question whose answer invalidates no section needs no tag.

### Auto-decision path (`decision_gate: "auto"`)

Under `PL0.metadata.decision_gate == "auto"` (stamped by `--auto=[decision]`), do not hold the gate
round-trip: build the same list with recommended defaults, return it in the typed handoff's
`open_questions[]`, and mark PL0 complete. The orchestrator's Step A.4 pre-pass
(`skills/worktask/references/workflow.md`) re-dispatches this agent as a decision delegate on the Fable model to
answer them.

#### Decision-delegate turn

Decide each question default-biased (deviate only with stated evidence) and apply the amendments
to the plan's existing mandatory anchors (`## requirements` / `## acceptance-criteria` /
`## scope`) in one batch pass. Never add a `## decisions` anchor to `<plan_file>`, whose anchor set
is exact (`skills/worktask/references/contracts/artifact-anchors.md#anchors--pl-to-dr`; `## decisions` belongs to AR's
`architecture-N.md`). Return every decision as a `key_decisions[]` entry prefixed
`(auto-decided)`. The orchestrator applies the
[canonical ledger merge](auto-decision.md#auto-decision-ledger-merge-orchestrator). Do not
re-run `state-patch.sh` — PL0 is already `completed`, so the plan amendments are your only writes.

#### Escalation-class questions (never auto-decided)

Never auto-decide irreversible or destructive actions, scope expansion beyond the task
description, security-posture-weakening changes, or spend authorization — return those as
`escalate` items. The orchestrator stops for the user on exactly those, even under
`plan_gate: "bypass"`; an unattended `/megatask` per-issue run parks the issue instead
(`skills/worktask/references/workflow.md § Escalation guard — unattended /megatask per-issue runs (PARK)`).
