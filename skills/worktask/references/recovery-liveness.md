# Recovery liveness

Read when executing or checking recovery liveness.

Procedure routing: [resume](resume.md).

<a id="section-lookup-1"></a>
Related: [Mid-stage &amp; FN-gate rows](recovery-state.md#mid-stage--fn-gate-rows) · [Live-agent rows — parked or gone](recovery-state.md#live-agent-rows--parked-or-gone)

<!-- canonical-body:start -->
#### Explicit replay vs automatic reattach — the three discriminators

1. **Trigger.** Reattach is entered by the orchestrator on re-entry (PostCompact, crash, session resume); replay only by a human typing `--resume <STAGE_ID>`.
2. **Target selection.** Reattach *derives* its target (first incomplete stage). Replay is *given* one named ledger id, which may be `completed`.
3. **Retry ceiling.** Every automatic row, including the re-delegates in § Live-agent rows — parked or gone and § Mid-stage &amp; FN-gate rows, honours `metadata.retry_count` (exhausted ⇒ escalate). Replay overrides it and records a `stage_replay` audit row.

The row's Ledger Shape carries a non-ledger condition (a human instruction), so a ledger scan never matches it.

#### Explicit replay — the guarded primitive

`/worktask --resume` calls `state-patch.sh --task-replay <ID> [--cascade]`, which refuses (exit 4, ledger byte-unchanged) when the target's agent is live or parked, when liveness is indeterminate, when `PL0` is not `completed`, or when any cascade member is blocked. Liveness comes from `stale-check.sh`, this runbook's detector. Full procedure and pre-replay confirmation: `skills/worktask/references/workflow.md § Phase 0`.

### Mid-stage yield


| Ledger Shape | Audit Tail | Action |
| --- | --- | --- |
| Stage returned (not live, not errored) but the artifact is absent, present with no `handoff.verdict`, or marked `partial` (`maxTurns` ceiling) even when a verdict IS present | `stage_returned_incomplete` | Reattach via `SendMessage`; never re-delegate |


The agent ended its turn with no finished handoff, which the runtime treats as an ordinary return,
so 6.5a's errored-return arm never fires. Reattach to finish the same work. Do not re-delegate (a
fresh dispatch redoes work against a tree the yielded agent already edited) and do not increment
`retry_count`: nothing failed. Detector: `skills/worktask/references/completion-merge.md § Step 6.5a2`. An audit tail of
`stage_resume_exhausted` (a 3rd incomplete return in the run) is surfaced to the operator and never reattached.

#### Mid-stage yield — the three reasons

`metadata.reason` carries `artifact_absent`, `handoff_verdict_missing`, or `max_turns_partial`.
The third is a subagent stopped at its `maxTurns` ceiling, returning output marked partial with a
hint to continue via `SendMessage`. Every corpflow agent declares a ceiling (`agents/*.md`, e.g.
`agents/team-lead.md`: 30), and this arm fires whether or not a verdict was written.

#### Mid-stage yield vs a budget halt

Both skip `retry_count`. A budget halt is re-dispatched once the budget is raised; a
`max_turns_partial` stage is reattached, because the agent still holds the tree it edited
(`skills/agent-coordination/SKILL.md#budget-halts-are-not-stage-failures`).

### Reattach rows — the SendMessage has a result too

Every "reattach via `SendMessage`" row above can fail to deliver, and each non-delivery mode is
reported. Read the result before treating any reattach as done, and log one `reattach_send_result`
row per attempt. `result: "ok"` means delivered to the addressed session itself (a backgrounded
session has no interactive twin in `ListAgents` to absorb the send); every non-delivery is
`result: "blocked"` with the mode (`refused`, `dropped`, `oversized`, `burst_limited`,
`session_list_truncated`, `queued`, `held`) in `metadata.reason`. Never log a delivered-and-awaiting send
as `deferred`, and never omit the field: `stale-check.sh` reads any present result other than `ok`
as undelivered, while a missing or null `result` counts as delivered. A delivered nudge advances
the stage; every other result leaves it exactly where it was.

#### Reattach rows — the result table — delivered and refusals


| Send result | Action |
| --- | --- |
| Delivered | Proceed as the triggering row says — leave stage `in_progress` and await return |
| `refused` — recipient config or invalid managed-settings value | Stage stays parked. Escalate; do not re-delegate or increment `retry_count` |
| `dropped` — recipient inbox full or rate-limited | Stage stays parked. Back off and retry once; second drop escalates |


#### Reattach rows — the result table — size, rate, and offline


| Send result | Action |
| --- | --- |
| `oversized` — refused up front for message size | Reattach prompt is too large (authoring defect). Shorten and retry |
| `burst_limited` — refused up front for send rate | Stage stays parked. Back off briefly, retry once |
| `queued` — offline Remote Control on another machine | Stage stays parked. Do not re-send (the queued copy lands on reconnect; a second send duplicates). Do not re-delegate or increment `retry_count`. Await reconnection; escalate if stale |
| `held` — the recipient's permission-mode policy holds it for a person's approval; the notice names the session | Stage stays parked. Do not re-send (approval releases the held copy; a second send duplicates). Do not re-delegate or increment `retry_count`. Escalate to the operator to approve at the named session |


#### Reattach rows — an unconfirmed absence


| Send result | Action |
| --- | --- |
| `session_list_truncated` — the account's session list was too long to enumerate fully | Any "agent gone" verdict reached under this condition is unconfirmed. Do not re-delegate off it: retry discovery once, then escalate |


#### Reattach rows — delivered is not acknowledged

A send result says the harness accepted a message; only the stage's own `message_ack` row
(`state-patch.sh --ack <TASK_ID> <msg_id>`) says the stage read it. Every orchestrator → stage send
(a nudge, a relayed reply, an amendment, a resend) goes through `skills/worktask/references/completion-merge.md § Step 6.5a4`. It mints `<TASK_ID>-m<k>` and opens the message with `msg_id:`, plus `supersedes:` when it
replaces an earlier message, and the exact `--ack` line. Both ids go into the `metadata` of its
`reattach_send_result` row, together with the dispatch's `run_index`.

At the next boundary run `bash skills/worktask/scripts/ack-check.sh --task <ID> --run-index <N> --artifact <stage artifact>`. A message with no ack is not delivered, whatever its send result
said. The stage followed what its ack rows and `handoff.acted_on_msg_id` prove; message order
proves nothing.

#### Reattach rows — one dispatch at a time

`<N>` is the dispatch's `metadata.run_index`. A fix round re-dispatches the same task key with
`run_index` bumped, so an earlier dispatch's messages must not judge this one (a run-0 message
would otherwise demand an `acted_on_msg_id` from a run-1 artifact, or a run-0 unacked resend
escalate every later round). `--run-index` ignores send rows whose `metadata.run_index` differs,
and a row without one counts as run 0. Acks still join by msg_id, which stays unique per task key
across runs. An ack for an out-of-scope message is dropped rather than listed as `orphan-ack`.

#### Reattach rows — one resend, then escalate


| `ack-check.sh` | Action |
| --- | --- |
| exit 0, `verdict: clear` | Proceed |
| exit 1, a `msg <id> not-delivered send=ok` line | Resend the same instruction once under a new msg\_id with `supersedes: <id>`. The stage stays `in_progress` and the check runs again at the next boundary. If `<id>` itself carries `supersedes`, this is the second miss: escalate. No third send |
| exit 1, `send=` anything else | Result table already applied at send time; at the boundary: escalate, never resend (`queued` included) |
| exit 3, `acted_on … mismatch` | The same rule: one resend restating `expected=<id>` with `supersedes: <id>`, then escalate. `expected=none` has nothing to restate: escalate |
| exit 2 | The check failed: escalate, never read it as clear |
