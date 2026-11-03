# Replay

Read only for an explicit `--resume <STAGE_ID>` replay.

Procedure routing: [workflow](workflow.md).

<a id="section-lookup-1"></a>
Related: [After Step A — run the stage loop](plan-approval.md#after-step-a--run-the-stage-loop)

<!-- canonical-body:start -->
## Phase 0: Replay one stage (`--resume <STAGE_ID>`)

Entered only by `/worktask --resume <STAGE_ID> [--cascade]`. Unlike automatic reattach (first
incomplete stage, retry ceiling honoured), a replay is given one ledger id by a human and may
override that ceiling (`skills/worktask/references/recovery-state.md § Explicit-replay row`).

Phase 0 replaces Phase 1 entirely, then re-enters the existing stage loop with no new dispatch
route or readiness rule: the replayed task becomes `pending` with its dependencies still
`completed`, so it is the first unblocked task and every other stage stays settled.

### Phase 0 — what runs

**Skip** — all of Phase 1 (Steps 2a, 3, 3a, 3c, 4, 5–6, 7–8) and every pre-loop Phase 2 step
(A.4, A.4b, A.5, Step A publish). `run_index` is frozen; no `planning-N.md`, no rename, no issue.

**Run** — Step 3b hook-install verification (idempotent; a resumed loop still needs
SubagentStop), the `fn-preflight.sh branch-divergence` check (`resume.md § Branch-rename
detection`), and the workspace-root cross-check before every `Agent()`.

### Phase 0 — procedure

1. No `.context/state.json` in the working tree → error out: "no worktask here — use
   `/worktask <task>`". Do not seed one.
2. Present the pre-replay confirmation and stop, naming: the target id with its status,
   `retry_count`, `error_escalated_to`; whether the escalation cap is being overridden; any
   already-`completed` dependents, marked *these may now be stale* (warn only — never auto-reset);
   a plan-unapproved warning when no `approval_received` row exists for `PL<run_index>`; and under
   `--cascade` the member list plus the skipped FN/RE members. There is no bypass flag.
3. Run `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-replay <ID> [--cascade]`.

### Phase 0 — procedure, steps 4–6

4. **Exit 4** means a guard refused (target live or parked, liveness indeterminate, planning
   incomplete, or a blocked cascade member); `state.json` is byte-unchanged. Print the refusal line
   verbatim and stop without entering the stage loop. Exit 1 is an unknown id, exit 2 a malformed one.
5. Append the ordinary `resume` audit row (`resume.md` step 7) — it records session re-entry, while
   the primitive's `stage_replay` row records what changed in the ledger.
6. Re-enter `§ After Step A — run the stage loop`, unchanged.

### Phase 0 — gates on a resumed run

| Gate | Behaviour |
|------|-----------|
| `plan_gate` (Step A.5) | Never re-fires. It gates the Phase-1→Phase-2 transition; a replay reopens no planning and the `approval_received` row persists. Its absence is a warning at step 2, not a stop |
| `fn_gate` | Applies unchanged: it belongs to the loop, not the entry point, so a resumed run cannot slip a commit past the finalization checkpoint |
