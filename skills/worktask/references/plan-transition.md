# Plan transition

Read when executing or checking plan transition.

Procedure routing: [workflow](workflow.md).

<a id="section-lookup-1"></a>
Related: [Plan gate bypass path — escalation exception](plan-approval.md#plan-gate-bypass-path--escalation-exception) · [Step C.5 — the unattended lanes](closing-sweep-step-c3c4--auto-answer-then-render.md#step-c5--the-unattended-lanes) · [Output Format](launch-options.md#output-format)

<!-- canonical-body:start -->
## Phase 2: Execute Stages (proceeds automatically)

Phase 2 begins with the Auto-Decision Pre-Pass (Step A.4, no-op unless `decision_gate == "auto"` and
PL0 left open questions), then the Plan Gate Check (Step A.5): on `checkpoint` present the plan and
wait for approval before the stage loop; on `bypass` proceed directly.

### Step A.4 — Auto-Decision Pre-Pass (runs before Step A.5)

Read `tasks.PL0.metadata.decision_gate` (default `"user"`) and, from `facts.open_questions[]`, PL's
unresolved `sw-PL<N>-*` items — those whose `status` is not `"resolved"`
(`skills/worktask/references/planning-decisions.md § Plan-Gate Open-Question Batching`). Resolve each item's question text and
`options[]` from `planning-N.md#elicitation-sweep` exactly as § Step C.4 does; the stub carries
neither. No-op when `decision_gate == "user"` or no such item exists — fall through to
Step A.5. Otherwise, read `skills/worktask/references/auto-decision.md` and run it: the delegate
dispatch, the ledger merge, and the gate-summary presentation. § Escalation guard (BINDING) below
stays inline because every run reads it: Step C.2, Step C.0 and the FN gate apply it too.

#### Escalation guard (BINDING)

The delegate never auto-decides escalation-class questions: anything irreversible or
destructive (data deletion, force-push, external publication), scope-expanding beyond the task
description, security-posture-weakening, or spend-authorizing. Those return as `escalate` items. If
any exist, Step A.5 runs as a `checkpoint` gate for those items even under `plan_gate ==
"bypass"` — the user answers only the escalated questions, the batch amendment pass applies their
answers, then the bypass path resumes. Auto-decision never widens what runs unattended.

##### Escalation guard — escalate stops at every boundary

**Escalate always stops at any boundary; bypass records decision-class items only.** A stop is the
checkpoint-style render above, scoped to that boundary's escalate items: the user answers them,
§ Step C.5 records the answers, and the bypass path resumes. At the plan gate every lane keeps the
checkpoint stop (`/megatask` parks; § Plan gate bypass path — escalation exception). At a stage's own boundary
(§ Step C.0) or the FN gate, the first matching lane wins:

1. `/megatask` per-issue run (`PL0.metadata.megatask_group`): park, per § Escalation guard —
   unattended `/megatask` per-issue runs (PARK).
2. No reachable human (`CORPFLOW_NONINTERACTIVE=1`, or § Headless Dispatch): record each item and
   continue (§ Step C.5 — the unattended lanes). FN lists it atop the PR body, and the final
   message repeats it (§ Output Format).
3. Any other lane, including `--emergency`, `--auto=[finalization]` and a bypassed plan gate: stop.

##### Escalation guard — raise-only self-labels

A closing-sweep item arrives carrying its emitting stage's own `class`. At § Step C.2, strictly
before any auto-answer, join it with the orchestrator's own label on both axes — `class` and
`blocks_next_stage` — and carry the joined value forward, so no item reaches the delegate
un-reclassified. The escalation classes are the four enumerated directly above; this sub-heading
adds no second copy of them.

The join is over **labellers, never transports**: never an agent's artifact stub against its own
ledger stub. Those two copies have one author, so a disagreement is a defect —
`handoff-harness.sh check_sweep_ledger` fails the stage and the agent reconciles both.

The join itself, both axes, and why raise-only holds by construction rather than by a remembered
rule: `skills/worktask/references/contracts/sweep-obligations.md § Self-labels raise, never lower`.

##### Escalation guard — unattended `/megatask` per-issue runs (PARK)

Under a `/megatask` per-issue run (detected by `PL0.metadata.megatask_group`) there is no user to
stop for, so instead of holding the checkpoint, park the issue: write
`workspace.json.execution.status: "failed"` with `execution.reason: "parked_escalation"`, append an
`escalation_parked` audit row (`subject:"PL<N>"`, `metadata.escalated: [<questions>]`), and stop
without dispatching any stage. Parking rides the monitor's failure path
(`hooks/megatask-monitor.sh` settles only `completed`/`failed`): the track is freed, dependents stay
`blocked`, and the batch summary lists the issue with unanswered questions for a follow-up
interactive `/worktask`. For parked permission needs, the list holds
each need's redacted `{tool, command_head, truncated}`, never the command (§ Boundary permission
prompt — only the user answers).


### Step A.4b — Refine the branch target (after A.4, before A.5)
<a id="step-a4b--the-returned-value"></a>
<a id="step-a4b-snippet--invoke-the-helper-non-blocking"></a>

After PL0 returns, before the gate summary or publication, the orchestrator derives the remote target from the plan's `title:`.
This can rewrite `facts.branch` once per run, before commits exist; it never mutates git or repeats on plan revisions.

```bash
ref_out=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/refine-branch-target.sh) || true
ledger_branch=$(printf '%s\n' "$ref_out" | sed -n 's/^ledger_branch=//p' | tail -n 1)
```

Failure, including a missing helper (127), does not block the run; empty output means no refinement.
Use `ledger_branch` in A.5; FN still validates `^[A-Za-z0-9._/-]+$` independently.

#### Step A.4b invariants

The helper writes one `branch_target_refined` row (`ok` or `noop`, closed-set reason) per invocation when `jq` exists.
`jq_unavailable` prints its result without a row.
It scans the current run's successful row to make repeated invocations no-ops.
A commit, upstream, missing title, invalid/unchanged candidate, or new truncation against an untruncated incumbent also yields `noop`.
Initial naming remains Step 3c's only rename-mode call; this step changes the ledger alone.
