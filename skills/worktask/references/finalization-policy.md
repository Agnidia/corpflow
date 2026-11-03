# Finalization policy

Read when executing or checking finalization policy.

Procedure routing: [orchestration](orchestration.md).

<a id="section-lookup-1"></a>
Related: [PRECONDITION CHECK](loop-entry.md#precondition-check)

<!-- canonical-body:start -->
## FN Gate

The pre-finalization human checkpoint, carried by `PL0.metadata.fn_gate` (default `"checkpoint"`). It sits before the FN `Agent()` delegation, so nothing remote (commit/push/PR) happens before approval. `N = state.json.run_index` (default `0`). With the PL gate (`workflow.md § Step A.5`, § PRECONDITION CHECK Signal 2) it forms the pipeline's two human checkpoints; all file-writing work is worktree-isolated, so finalization is reviewable as a PR.

### FN gate paths

- **`checkpoint`** (default): loop step 4.9 runs the Pre-gate Conductor-attachments writer (local-only), emits `fn_gate_waiting subject:"FN<N>"`, presents the pre-FN summary (branch, resolved base branch, commit type, changed-file count, DR/QA verdicts, PR target + `Closes #<issue>`), renders the batched closing sweep — the items NOT marked `blocks_next_stage`, which were answered at their own boundary in loop step 6.6 — in calls of ≤4 questions (`skills/worktask/references/contracts/sweep-boundaries.md § Closing Elicitation Sweep`), and then calls `AskUserQuestion` for approve/reject — the sweep precedes that call and never merges into it. Approve → `approval_received subject:"FN<N>"`, then delegate FN (commit/push/PR). Reject → `approval_rejected subject:"FN<N>"` and stop without delegating FN, then resume per § FN gate rejection — resume path.

#### FN gate paths — bypass

- **`bypass`** (stamped only by `--auto=[finalization]` or `--emergency`, or per-issue by the `/megatask` batch orchestrator): loop step 4.9 runs the writer, emits a single `fn_gate_bypass subject:"FN<N>"` (`reason: "unattended"`), then delegates FN unattended; dynamic mode takes the same path on workflow return. `--auto=[plan]` never bypasses FN — it is orthogonal to the plan gate — and `--auto=[decision]` bypasses no gate at all (§ Auto-Decision Delegation).

### FN gate rejection — resume path

A rejection is a fix round inside the run in flight, symmetric with the plan gate's revision
path (`workflow.md § Plan-revision re-dispatch`) — not a new run, not a restart. Surface
the feedback verbatim, then route each item to the stage that owns it:

| Feedback is about | Route to | Shape |
|---|---|---|
| Code / tests / missing edits | DV | Fix round on the existing DV task (`retry_count++`), feedback embedded as a remediation block per loop step 4.6 |
| Docs, README, changelog wording | DC | Re-stamp on the existing DC task |
| Scope, ACs, or the plan itself | PL | Plan revision per § Plan-revision re-dispatch — the plan gate is re-presented first |

### FN gate rejection — invariants

`run_index` and `plan_file` stay frozen throughout; completed stages are never re-run wholesale —
only the owning stage's task is reopened (patched back to `in_progress`), already-green stages stay
green. Increment `metadata.revision_count` on the FN task (absent → `1`) and append one
`fn_revision_dispatched subject:"FN<N>"` row per fix round. When the routed stage completes, re-run
the pre-FN summary and re-present the gate — approval is per presentation, never inherited.

### At the FN stage

At the FN stage, read `references/fn-gate.md` for the full procedure: the Pre-gate Conductor-attachments writer (run on both paths so Conductor's *Create PR* / *Request Review* actions inherit worktask context) and the five audit lines.
