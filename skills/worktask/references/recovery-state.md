# Recovery state

Read on reattach after interruption; select the row matching the ledger and audit tail.

Procedure routing: [resume](resume.md).

<!-- canonical-body:start -->
# Resume After Interruption — full procedure

Read on reattach from `skills/worktask/references/finalization-publish.md § Resume After Interruption` (stub). The orchestrator loop is restartable: on reattach (PostCompact, session crash, `--resume`), diagnose state from `.context/state.json` `tasks{}` + the `.context/logs/audit.jsonl` tail before resuming.

## State → Action Table

### Initialization rows


| Ledger Shape | Audit Tail | Action |
| --- | --- | --- |
| No tasks | — | Worktask never initialized. Start over with `/worktask <task>` |
| PL0 only, `pending` | — | PL0 not started. Delegate PL0; after PL0 completes, the Step A.5 plan gate applies (stop for approval unless `plan_gate == "bypass"`) |
| PL0 only, `in_progress` | no `subagent_stopped` for PL0 | PL0 crashed mid-stage. Re-delegate PL0 (idempotent) |
| PL0 `completed`, no stage tasks | — | PL0 did not create stages. Re-run PL0 |


### Branch-rename detection (run once on re-entry)

Before acting on the ledger, run `bash skills/worktask/scripts/fn-preflight.sh branch-divergence`
once. Read-only, always exit 0, never blocks. `third_party` means something outside the pipeline
renamed the local branch while the run was interrupted — surface it before continuing; `expected`
needs no action. It compares against the `to` of the last `branch_renamed / ok` row, so an R4
refinement of `facts.branch` never registers as an external rename.

### Branch-target refinement row


| Ledger Shape | Audit Tail | Action |
| --- | --- | --- |
| PL0 `completed`, stage tasks `pending` | No `branch_target_refined` row for `PL<run_index>` | The one-shot refinement of the planned branch name has not run. Run `skills/worktask/references/workflow.md § Step A.4b` once, then continue to the plan-gate row below. The helper is self-guarding (a duplicate call is a `noop`) and mutates no git state, so running it on resume is safe. Read `facts.branch` from the ledger; do not re-run `branch-name.sh` in rename mode, because re-derivation would discard a refined value. |


### Plan-gate row


| Ledger Shape | Audit Tail | Action |
| --- | --- | --- |
| PL0 `completed`, stage tasks `pending`, no stage `in_progress` | No `approval_received` audit line for PL<run_index> | First run Step A.4b if no `branch_target_refined` row exists for `PL<run_index>` (row above) — the gate summary must carry the final name. Then branch on `PL<run_index>.metadata.plan_gate`. `"bypass"` (`--auto=[plan]` / `--emergency`, or stamped by `/megatask`): re-enter the stage loop and delegate the first unblocked stage; do not stop. `"checkpoint"` (default): parked at the post-plan checkpoint — stop and prompt for approval; proceed only once an `approval_received` line with `subject:"PL<run_index>"` is logged. |


### Plan-revision row


| Ledger Shape | Audit Tail | Action |
| --- | --- | --- |
| PL0 `in_progress`, stage tasks present | `plan_revision_dispatched` for `PL<run_index>` with no later `approval_received` | Plan revision in flight (gate rejection). Not the fresh-run path: a plain PL0 re-delegate would allocate `planning-<N+1>`, reset `facts.*`, and seed a duplicate chain. If the Step 0 pre-check shows the PM agent live, follow the live-agent rows; if it is gone, re-dispatch PM with `plan_revision: true` and the original rejection feedback. If the feedback is no longer in context, ask the user to restate it rather than dispatching without it (`skills/worktask/references/workflow.md § Plan-revision re-dispatch`). On PM's return, re-enter the plan gate at Step A.5. |


#### Plan-revision row — the branch target is not re-refined

A revision leaves the refined `facts.branch` as-is: the once-per-run-index window is already spent (`skills/worktask/references/plan-approval.md § Plan-revision invariants` row 5). Do not re-run Step A.4b here, even when the revision changed the plan title — the gate summary already showed the name.

### Auto-decision row


| Ledger Shape | Audit Tail | Action |
| --- | --- | --- |
| PL0 `completed`, stage tasks `pending`, `PL0.metadata.decision_gate == "auto"`, `facts.open_questions[]` holds a `sw-PL<N>-*` item with `status != "resolved"` | `auto_decision_dispatched` for `PL<run_index>` present but no matching `auto_decision_resolved` | Auto-decision pass interrupted mid-delegate. Re-run `skills/worktask/references/workflow.md § Step A.4`. Already-applied decisions are `facts.open_questions[]` items with `status: "resolved"` and an `(auto-decided)` `resolution`; do not re-decide those. Then continue to the plan-gate row. Unanswered `escalate` items always stop for the user, even on a `bypass` plan gate (a /megatask per-issue run parks before this row: `skills/worktask/references/workflow.md § Escalation guard — unattended /megatask per-issue runs (PARK)`). |


### Mid-stage &amp; FN-gate rows


| Ledger Shape | Audit Tail | Action |
| --- | --- | --- |
| PL0 `completed`, `approval_received` present, some stages `in_progress` | most recent `subagent_stopped` `result: error` | Mid-stage failure. Read `.context/errors/<agent>.md`, honor `retry_count` — never overrides the retry ceiling; an exhausted stage needs § Explicit-replay row |
| PL0 `completed`, all stages `completed` except FN, FN `pending`, audit tail has `fn_gate_waiting` for FN | No `approval_received` audit line for `FN<run_index>` | At the FN gate, parked. Branch on `PL<run_index>.metadata.fn_gate` (default `"checkpoint"`). `"checkpoint"`: re-present the pre-FN summary (`references/fn-gate.md`), stop, and delegate FN only once an `approval_received` line with `subject:"FN<run_index>"` is logged. `"bypass"` (`--auto=[finalization]` / `--emergency`, or stamped by `/megatask`): delegate FN. |


### Near-done &amp; stale rows


| Ledger Shape | Audit Tail | Action |
| --- | --- | --- |
| PL0 `completed`, all stages `completed` except FN | — | Near-done. Re-enter loop; the FN gate check (step 4.9) decides whether to stop (`checkpoint`) or proceed (`bypass`) |
| Stages `in_progress` with no `metadata.retry_count` | missing audit lines | Stale task state. Re-derive from most recent `.context/logs/` capture |


### Live-agent rows — liveness branch — alive and responsive


| Ledger Shape | Audit Tail | Action |
| --- | --- | --- |
| Any stage `in_progress` AND `claude agents --json --all` shows live `agent_id` | — | Still alive. Branch on `{state, waitingFor}` — never blind re-delegate |
| Live `agent_id` AND `waitingFor` = `approval`/`input` | — | Parked on us. `SendMessage` reattach with awaited answer — do not re-delegate |


### Live-agent rows — liveness branch — parked, awaiting input


| Ledger Shape | Audit Tail | Action |
| --- | --- | --- |
| Live `agent_id` AND status = "Needs input" (a sandbox, MCP-input or managed-settings prompt, or an inbound message awaiting operator approval; `claude agents` names the sender) | — | Parked on us, operator-owned. `SendMessage` only to surface prompt — never auto-answer or re-dispatch |
| Live `agent_id` AND `waitingFor` = null/empty (mid-work) | — | Agent busy. Leave it; poll/await. Do not double-dispatch or nudge. Headless/remote sessions with background agents never report "waiting for your input" |


### Live-agent rows — broken hook configuration


| Ledger Shape | Audit Tail | Action |
| --- | --- | --- |
| Live `agent_id` matching that stage AND its `claude agents` row names a hook plus a schema error (a `PermissionRequest`/`PreToolUse` hook printed an invalid answer) | — | Operator-owned park: broken hook config, not a stage to re-dispatch. `SendMessage` cannot clear it — the same hook rejects the next tool call too. Fix the hook, then resume normally. Do not spend a `retry_count` on it |


Unlike the "Needs input" row, which parks on a prompt a human can answer, this one parks on
configuration that must be edited before the session can move at all.

### Live-agent rows — parked or gone


| Ledger Shape | Audit Tail | Action |
| --- | --- | --- |
| `agent_id` for an `in_progress` stage shows `state: blocked` | — | Alive but parked. Reattach via `SendMessage` — do not re-delegate |
| `agent_id` absent from `claude agents --json --all` (or `state: done`) for an `in_progress` stage | — | Agent gone. Re-delegate from the first incomplete stage |
| Several `agent_id`s absent at once, all vanishing at the same timestamp, session run under `--max-budget-usd` | no per-stage failure rows | Budget halt, not stage failure. Reaching the cap denies new spawns and halts running background subagents, so healthy stages die together with no error of their own. Raise the budget, then re-dispatch, and do not increment `metadata.retry_count`: the 3 retries are reserved for genuine stage failures |


### Explicit-replay row


| Ledger Shape | Audit Tail | Action |
| --- | --- | --- |
| A settled stage (`completed`, or `in_progress` at `retry_count == 3` with `error_escalated_to` set) and a human has asked for that one stage to run again | — | Explicit replay, not reattach. `/worktask --resume <STAGE_ID>` (add `--cascade` for transitive dependents). The only path that may override the retry ceiling; never entered automatically |
