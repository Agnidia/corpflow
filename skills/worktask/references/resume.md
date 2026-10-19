# Resume After Interruption — full procedure

Read on reattach from `skills/worktask/SKILL.md § Resume After Interruption` (stub). The orchestrator loop is restartable: on reattach (PostCompact, session crash, `--resume`), diagnose state from `.context/state.json` `tasks{}` + the `.context/logs/audit.jsonl` tail before resuming.

## State → Action Table

### Initialization rows

| Ledger Shape | Audit Tail | Action |
|----------------|------------|--------|
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
|----------------|------------|--------|
| PL0 `completed`, stage tasks `pending` | No `branch_target_refined` row for `PL<run_index>` | The one-shot refinement of the planned branch name has not run. Run `commands/worktask.md § Step A.4b` once, then continue to the plan-gate row below. The helper is self-guarding (a duplicate call is a `noop`) and mutates no git state, so running it on resume is safe. Read `facts.branch` from the ledger; do not re-run `branch-name.sh` in rename mode, because re-derivation would discard a refined value. |

### Plan-gate row

| Ledger Shape | Audit Tail | Action |
|----------------|------------|--------|
| PL0 `completed`, stage tasks `pending`, no stage `in_progress` | No `approval_received` audit line for PL<run_index> | First run Step A.4b if no `branch_target_refined` row exists for `PL<run_index>` (row above) — the gate summary must carry the final name. Then branch on `PL<run_index>.metadata.plan_gate`. `"bypass"` (`--auto=[plan]` / `--emergency`, or stamped by `/megatask`): re-enter the stage loop and delegate the first unblocked stage; do not stop. `"checkpoint"` (default): parked at the post-plan checkpoint — stop and prompt for approval; proceed only once an `approval_received` line with `subject:"PL<run_index>"` is logged. |

### Plan-revision row

| Ledger Shape | Audit Tail | Action |
|----------------|------------|--------|
| PL0 `in_progress`, stage tasks present | `plan_revision_dispatched` for `PL<run_index>` with no later `approval_received` | Plan revision in flight (gate rejection). Not the fresh-run path: a plain PL0 re-delegate would allocate `planning-<N+1>`, reset `facts.*`, and seed a duplicate chain. If the Step 0 pre-check shows the PM agent live, follow the live-agent rows; if it is gone, re-dispatch PM with `plan_revision: true` and the original rejection feedback. If the feedback is no longer in context, ask the user to restate it rather than dispatching without it (`commands/worktask.md § Plan-revision re-dispatch`). On PM's return, re-enter the plan gate at Step A.5. |

#### Plan-revision row — the branch target is not re-refined

A revision leaves the refined `facts.branch` as-is: the once-per-run-index window is already spent (`commands/worktask.md § Plan-revision invariants` row 5). Do not re-run Step A.4b here, even when the revision changed the plan title — the gate summary already showed the name.

### Auto-decision row

| Ledger Shape | Audit Tail | Action |
|----------------|------------|--------|
| PL0 `completed`, stage tasks `pending`, `PL0.metadata.decision_gate == "auto"`, `facts.open_questions[]` holds a `sw-PL<N>-*` item with `status != "resolved"` | `auto_decision_dispatched` for `PL<run_index>` present but no matching `auto_decision_resolved` | Auto-decision pass interrupted mid-delegate. Re-run `commands/worktask.md § Step A.4`. Already-applied decisions are `facts.open_questions[]` items with `status: "resolved"` and an `(auto-decided)` `resolution`; do not re-decide those. Then continue to the plan-gate row. Unanswered `escalate` items always stop for the user, even on a `bypass` plan gate (a /megatask per-issue run parks before this row: `commands/worktask.md § Escalation guard — unattended /megatask per-issue runs (PARK)`). |

### Mid-stage & FN-gate rows

| Ledger Shape | Audit Tail | Action |
|----------------|------------|--------|
| PL0 `completed`, `approval_received` present, some stages `in_progress` | most recent `subagent_stopped` `result: error` | Mid-stage failure. Read `.context/errors/<agent>.md`, honor `retry_count` — never overrides the retry ceiling; an exhausted stage needs § Explicit-replay row |
| PL0 `completed`, all stages `completed` except FN, FN `pending`, audit tail has `fn_gate_waiting` for FN | No `approval_received` audit line for `FN<run_index>` | At the FN gate, parked. Branch on `PL<run_index>.metadata.fn_gate` (default `"checkpoint"`). `"checkpoint"`: re-present the pre-FN summary (`references/fn-gate.md`), stop, and delegate FN only once an `approval_received` line with `subject:"FN<run_index>"` is logged. `"bypass"` (`--auto=[finalization]` / `--emergency`, or stamped by `/megatask`): delegate FN. |

### Near-done & stale rows

| Ledger Shape | Audit Tail | Action |
|----------------|------------|--------|
| PL0 `completed`, all stages `completed` except FN | — | Near-done. Re-enter loop; the FN gate check (step 4.9) decides whether to stop (`checkpoint`) or proceed (`bypass`) |
| Stages `in_progress` with no `metadata.retry_count` | missing audit lines | Stale task state. Re-derive from most recent `.context/logs/` capture |

### Live-agent rows — liveness branch — alive and responsive

| Ledger Shape | Audit Tail | Action |
|----------------|------------|--------|
| Any stage `in_progress` AND `claude agents --json --all` shows live `agent_id` | — | Still alive. Branch on `{state, waitingFor}` — never blind re-delegate |
| Live `agent_id` AND `waitingFor` = `approval`/`input` | — | Parked on us. `SendMessage` reattach with awaited answer — do not re-delegate |

### Live-agent rows — liveness branch — parked, awaiting input

| Ledger Shape | Audit Tail | Action |
|----------------|------------|--------|
| Live `agent_id` AND status = "Needs input" (a sandbox, MCP-input or managed-settings prompt, or an inbound message awaiting operator approval; `claude agents` names the sender) | — | Parked on us, operator-owned. `SendMessage` only to surface prompt — never auto-answer or re-dispatch |
| Live `agent_id` AND `waitingFor` = null/empty (mid-work) | — | Agent busy. Leave it; poll/await. Do not double-dispatch or nudge. Headless/remote sessions with background agents never report "waiting for your input" |

### Live-agent rows — broken hook configuration

| Ledger Shape | Audit Tail | Action |
|----------------|------------|--------|
| Live `agent_id` matching that stage AND its `claude agents` row names a hook plus a schema error (a `PermissionRequest`/`PreToolUse` hook printed an invalid answer) | — | Operator-owned park: broken hook config, not a stage to re-dispatch. `SendMessage` cannot clear it — the same hook rejects the next tool call too. Fix the hook, then resume normally. Do not spend a `retry_count` on it |

Unlike the "Needs input" row, which parks on a prompt a human can answer, this one parks on
configuration that must be edited before the session can move at all.

### Live-agent rows — parked or gone

| Ledger Shape | Audit Tail | Action |
|----------------|------------|--------|
| `agent_id` for an `in_progress` stage shows `state: blocked` | — | Alive but parked. Reattach via `SendMessage` — do not re-delegate |
| `agent_id` absent from `claude agents --json --all` (or `state: done`) for an `in_progress` stage | — | Agent gone. Re-delegate from the first incomplete stage |
| Several `agent_id`s absent at once, all vanishing at the same timestamp, session run under `--max-budget-usd` | no per-stage failure rows | Budget halt, not stage failure. Reaching the cap denies new spawns and halts running background subagents, so healthy stages die together with no error of their own. Raise the budget, then re-dispatch, and do not increment `metadata.retry_count`: the 3 retries are reserved for genuine stage failures |

### Explicit-replay row

| Ledger Shape | Audit Tail | Action |
|----------------|------------|--------|
| A settled stage (`completed`, or `in_progress` at `retry_count == 3` with `error_escalated_to` set) and a human has asked for that one stage to run again | — | Explicit replay, not reattach. `/worktask --resume <STAGE_ID>` (add `--cascade` for transitive dependents). The only path that may override the retry ceiling; never entered automatically |

#### Explicit replay vs automatic reattach — the three discriminators

1. **Trigger.** Reattach is entered by the orchestrator on re-entry (PostCompact, crash, session resume); replay only by a human typing `--resume <STAGE_ID>`.
2. **Target selection.** Reattach *derives* its target (first incomplete stage). Replay is *given* one named ledger id, which may be `completed`.
3. **Retry ceiling.** Every automatic row, including the re-delegates in § Live-agent rows — parked or gone and § Mid-stage & FN-gate rows, honours `metadata.retry_count` (exhausted ⇒ escalate). Replay overrides it and records a `stage_replay` audit row.

The row's Ledger Shape carries a non-ledger condition (a human instruction), so a ledger scan never matches it.

#### Explicit replay — the guarded primitive

`/worktask --resume` calls `state-patch.sh --task-replay <ID> [--cascade]`, which refuses (exit 4, ledger byte-unchanged) when the target's agent is live or parked, when liveness is indeterminate, when `PL0` is not `completed`, or when any cascade member is blocked. Liveness comes from `stale-check.sh`, this runbook's detector. Full procedure and pre-replay confirmation: `commands/worktask.md § Phase 0`.

### Mid-stage yield

| Ledger Shape | Audit Tail | Action |
|----------------|------------|--------|
| Stage returned (not live, not errored) but the artifact is absent, present with no `handoff.verdict`, or marked `partial` (`maxTurns` ceiling) even when a verdict IS present | `stage_returned_incomplete` | Reattach via `SendMessage`; never re-delegate |

The agent ended its turn with no finished handoff, which the runtime treats as an ordinary return,
so 6.5a's errored-return arm never fires. Reattach to finish the same work. Do not re-delegate (a
fresh dispatch redoes work against a tree the yielded agent already edited) and do not increment
`retry_count`: nothing failed. Detector: `skills/worktask/SKILL.md § Step 6.5a2`. An audit tail of
`stage_resume_exhausted` (a 3rd incomplete return in the run) is surfaced to the operator and never reattached.

#### Mid-stage yield — the three reasons

`metadata.reason` carries `artifact_absent`, `handoff_verdict_missing`, or `max_turns_partial`.
The third is a subagent stopped at its `maxTurns` ceiling, returning output marked partial with a
hint to continue via `SendMessage`. Every corpflow agent declares a ceiling (`agents/*.md`, e.g.
`agents/team-lead.md`: 30), and this arm fires whether or not a verdict was written.

#### Mid-stage yield vs a budget halt

Both skip `retry_count`. A budget halt is re-dispatched once the budget is raised; a
`max_turns_partial` stage is reattached, because the agent still holds the tree it edited
(`agent-coordination/SKILL.md § Budget halts are not stage failures`).

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
|---|---|
| Delivered | Proceed as the triggering row says — leave stage `in_progress` and await return |
| `refused` — recipient config or invalid managed-settings value | Stage stays parked. Escalate; do not re-delegate or increment `retry_count` |
| `dropped` — recipient inbox full or rate-limited | Stage stays parked. Back off and retry once; second drop escalates |

#### Reattach rows — the result table — size, rate, and offline

| Send result | Action |
|---|---|
| `oversized` — refused up front for message size | Reattach prompt is too large (authoring defect). Shorten and retry |
| `burst_limited` — refused up front for send rate | Stage stays parked. Back off briefly, retry once |
| `queued` — offline Remote Control on another machine | Stage stays parked. Do not re-send (the queued copy lands on reconnect; a second send duplicates). Do not re-delegate or increment `retry_count`. Await reconnection; escalate if stale |
| `held` — the recipient's permission-mode policy holds it for a person's approval; the notice names the session | Stage stays parked. Do not re-send (approval releases the held copy; a second send duplicates). Do not re-delegate or increment `retry_count`. Escalate to the operator to approve at the named session |

#### Reattach rows — an unconfirmed absence

| Send result | Action |
|---|---|
| `session_list_truncated` — the account's session list was too long to enumerate fully | Any "agent gone" verdict reached under this condition is unconfirmed. Do not re-delegate off it: retry discovery once, then escalate |

#### Reattach rows — delivered is not acknowledged

A send result says the harness accepted a message; only the stage's own `message_ack` row
(`state-patch.sh --ack <TASK_ID> <msg_id>`) says the stage read it. Every orchestrator → stage send
(a nudge, a relayed reply, an amendment, a resend) goes through `skills/worktask/SKILL.md § Step
6.5a4`. It mints `<TASK_ID>-m<k>` and opens the message with `msg_id:`, plus `supersedes:` when it
replaces an earlier message, and the exact `--ack` line. Both ids go into the `metadata` of its
`reattach_send_result` row, together with the dispatch's `run_index`.

At the next boundary run `bash skills/worktask/scripts/ack-check.sh --task <ID> --run-index <N>
--artifact <stage artifact>`. A message with no ack is not delivered, whatever its send result
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
|---|---|
| exit 0, `verdict: clear` | Proceed |
| exit 1, a `msg <id> not-delivered send=ok` line | Resend the same instruction once under a new msg_id with `supersedes: <id>`. The stage stays `in_progress` and the check runs again at the next boundary. If `<id>` itself carries `supersedes`, this is the second miss: escalate. No third send |
| exit 1, `send=` anything else | Result table already applied at send time; at the boundary: escalate, never resend (`queued` included) |
| exit 3, `acted_on … mismatch` | The same rule: one resend restating `expected=<id>` with `supersedes: <id>`, then escalate. `expected=none` has nothing to restate: escalate |
| exit 2 | The check failed: escalate, never read it as clear |

#### Reattach rows — judge every id before resending

Read every line of the output before sending anything. If one exit-1 output carries both exit-1
rows, or any listed id is a second miss, escalate and send nothing, so no resend precedes an
escalation in the same pass. A resend restates the original message text; when that text is no
longer in context (a relayed reply after compaction), escalate rather than paraphrase.

#### Reattach rows — retries carry supersedes too

A retry the result table allows (`dropped`, `burst_limited`, a shortened `oversized` send) goes out
under a new msg_id with `supersedes:` naming the one it replaces; without that, the original reads
not-delivered at every later boundary. Those retries count toward the ceiling: a superseding
message that misses again, unacked or with any result but `ok` or `queued`, escalates. A `queued`
send needs no retry, because the queued copy acks itself when it lands. `ack-check.sh` ignores send
rows without `metadata.msg_id`.

### Reply routing

| Ledger Shape | Audit Tail | Action |
|----------------|------------|--------|
| Stage `blocked` with `metadata.blocked_on` of a kind other than `permission` | A `blocked_on` row with `result: "blocked"` and no later closing-leg row for that `task_id` | Parked on a typed need (`SKILL.md § Step 6.5a3`). Do not re-delegate, and do not call `route` again: a second call writes a second opening leg. Re-enter the loop; § Step 7a's `blocked-on-dispatch.sh batch` asks the user at the next boundary — a `user_decision` need only after § Pending communication probes it |
| Stage `blocked` on `peer_session` with a `metadata.ask_id` | A `sent` or `delivered` leg carrying that `ask_id`, and no `relayed` or `expired` leg for it | The ask is durable and outlives the session; § Pending communication fixes the order it is reconciled in. Never re-route and never re-send: the request file and the `sent` leg both exist |

#### Reply routing — why the stage cannot ask for itself

A subagent's `SendMessage` to another session delivers its reply to the parent session's
conversation, so a stage that sends its own cross-session ask never receives the answer. The stage
returns `blocked_on` of kind `peer_session` naming who to ask and what; the orchestrator routes it
through the mailbox and relays the verified reply. Rule and schema: `agent-coordination/SKILL.md §
Replies from a subagent land in the parent conversation` and `handoff-protocol.md § Schema —
blocked_on, the peer_session arm`.

A stage that sent its own ask has no path to the answer. Treat it like `stage_returned_incomplete`
and reattach so the ask is redone through the orchestrator.

### Pending communication

A resumed session reconciles both durable stores before it asks the user anything.
`.context/decisions.jsonl` holds what the user already answered; the mailbox holds what a peer
already replied. The orchestrator's working summary does not survive a crash or compaction, so the
stores decide whether a parked question is still open. Order on re-entry: probe the decisions,
reconcile the mailbox, then let § Step 7a's batch ask whatever is still unanswered.

#### Pending communication — the decision probe

For every task parked on `blocked_on.kind: user_decision`, run
`blocked-on-dispatch.sh resume --task-id <ID> --leg resumed` before the boundary batch. Exit 0
means a valid, unconsumed, in-scope row covers the task: the stage resumes carrying its
`decision_ref` and the user is not asked. Exit 1 means none does: the probe has written nothing and
the task stays parked for the batch. Any other exit is an install or ledger fault, not an answer —
exit 2 can fire after the claim has landed, so stop and report it rather than treating it as exit 1.
Do not read the ledger by hand or ask the question from the resume path: the probe checks the
chain, the scope and the already-consumed set, and asking is the batch's job.

#### Pending communication — a row covers the parked question

The probe takes the newest unconsumed row whose scope names the task and that answers the question
the task is parked on: the row's `question` is byte-equal to `blocked_on.detail.question` and its
`scope.item` equals `detail.item` (null matches null). A sweep answer or any other row that merely
names the task is not a cover. The stage's own `--verify-decision` confirmation is still where the
answer text is read and judged.

#### Pending communication — the reply and expiry arms

Once per re-entry, over every `peer_session` ask: `mailbox.sh scan`, which writes the `answered` leg
for every verified reply; then one `blocked-on-dispatch.sh resume --task-id <ID> --leg relayed` per
`replied[]` entry — the only per-ask step; then `mailbox.sh sweep`, which expires every
ask past its deadline and routes it onward as a `user_decision`. An ask the sweep expires reaches
the same batch and is asked exactly once; it needs no decision probe of its own, because the need it
became was raised after the probe ran.

#### Pending communication — why it holds across a session boundary

A ledger row's `scope` carries the worktask and task identities, never a session identity, so a
decision recorded in one session covers the same task in the next. A row still has to pass chain
verification and audit corroboration, and a row an earlier resume consumed never resumes a second
time. Emptied `facts` (the shape a compaction leaves) change nothing, because the probe reads the
stores.

#### Pending communication — the two stores sit in different places

`decisions.jsonl` sits beside the run's own `state.json`, inside this workspace, so only a session
resuming that workspace sees it. The mailbox resolves through the project-root resolver to the main
worktree and is shared by every worktree of the project. A session resuming elsewhere therefore sees
the mailbox alone, and must not read an absent decision row as a decision never made.

## Resume Procedure

0. Liveness pre-check: `claude agents --json --all | jq '.[] | {agent_id, state, waitingFor}'`, matched against `.context/state.json.facts.dispatched_agents[]`. Branch per § Live-agent rows: parked on us → `SendMessage` the answer (a "Needs input" park: surface the prompt verbatim, never auto-answer); busy → leave it; `blocked` → reattach; `done` or absent → re-delegate from the first incomplete stage.

### Step 0 notes — observed CLI field set

   The field names above are the contract; the shipping CLI exposes fewer. A live-probed
   interactive row carries exactly `cwd`, `kind`, `name`, `pid`, `sessionId`, `startedAt` and
   `status` (e.g. `"busy"`) — no `id`, no `agent_id`, no `waitingFor`, no `parent_agent_id`. The
   background-row variant is unobserved, so `id` and `state` stay in the defensive reads. Read
   identity from `agent_id // id // sessionId` (where `id` appears it is a prefix of `sessionId`, so
   match on prefix too) and liveness from `waitingFor` when present, else `state`/`status`. Probes:
   `skills/agent-coordination/references/headless-dispatch.md § Schema Versioning Watch`. An
   unrecognised token is unknown, not absent — do not re-delegate off one.
   `skills/worktask/scripts/stale-check.sh` implements exactly this tolerance.

### Step 0 notes — own-name & teammate visibility — agent discovery changes

   `ListAgents`/`claude agents --json` lists live teammates and tells a session its own name; a pre-warmed idle worker is not listed until claimed. So a teammate does not read as gone and no phantom row matches a `subagent_type`. The degrade rules below still apply.

### Step 0 notes — own-name & teammate visibility — name matching

   The own name reuses the `name` key. Do not address your own name in a `peer_session` ask. Names are not unique — match on `sessionId`, never on `name`. A teammate row's `kind` is unconfirmed.

### Step 0 notes — reattach vs re-dispatch — cost estimation

   `SessionStart` resume hooks receive staleness and estimated re-cache cost. A long-idle session with an aged prompt cache pays the re-cache on its first turn, which can exceed a fresh dispatch for a short stage. Prefer re-dispatch only when the estimate clearly exceeds the stage cost. Reattach wins at any cache price when the agent holds edited tree state (§ Mid-stage yield).

### Step 0 notes — reattach vs re-dispatch — what reattach preserves

   Resumed subagents keep tool list, system-prompt prefix, `SubagentStart` hook context, preloaded skills (cache prefix survives), and nested background results in parent transcript. A `--bg` session receiving a message before idle timeout is not retired mid-turn.

### Step 0 notes — proactive detection

   To ask "is anything wedged?" without resuming, run `skills/worktask/scripts/stale-check.sh` — it
   reconciles the same inputs and prints the verdict from these tables. Read-only; it recovers
   nothing.

### Step 0 notes — why the pre-check

   One pre-check prevents blind respawn of a working subagent, redundant nudging of a busy one, and blind re-dispatch of an invisible blocked one. When `claude agents` is unavailable, skip the pre-check and re-delegate from the first incomplete stage. See `skills/agent-coordination/references/headless-dispatch.md § Live Session Discovery`.

### Step 0 notes — dispatched_agents matching

   The orchestrator loop writes one `dispatched_agents[]` entry per `task_id` (`{stage, task_id, subagent_type, agent_id?, name?, model_requested?, model_resolved?, status}`). Degrade rules for imperfect rows:
   - `agent_id` present → match the `claude agents --json --all` row by id; branch per the table above.
   - `agent_id` absent (no launch-ack) → match by `subagent_type` among the non-interactive rows (skip `waitingFor = approval/input` rows). Exactly one candidate ⇒ adopt it; ambiguous or none ⇒ skip the pre-check and re-delegate from the first incomplete stage.
   - entry `status: completed|failed` → the stage already resolved; do not reattach, advance to the next incomplete stage. Terminal entries may be evicted after compaction; absence means "no live agent".

#### Worktree re-entry

   - `tasks.<ID>.worktree.path` recorded → `EnterWorktree(path)` before resuming that stage, so DR/QA/DV-retry run in the right directory rather than the shared checkout. The recorded `worktree.branch` gives the branch without shelling `git rev-parse`.

### Step 0 notes — state-signal reliability

   Trust the `state` signal. With nested spawning (3 levels by default), match only top-level agents from `facts.dispatched_agents[]`; rows whose `parent_agent_id` points at another live row are the stage agent's own children — never reattach or re-delegate those directly.

   A resumed background agent restores its own prompt and tool restrictions, so a live row matched to a stage is still that stage's agent: prefer reattach.

### Step 0 notes — authority caveat

   A `SendMessage` reattach may nudge a parked agent (supply an awaited answer, re-prompt) but cannot authorize anything: a relayed message carries no operator permission authority (the receiver refuses relayed permission requests; auto mode blocks them). Permission escalations and the PL approval gate stay operator-owned.

### Step 0 notes — trigger delivery & reattach

   Scheduled-task and webhook deliveries are task notifications: in auto mode they cannot approve a pending action or set a session title, so they do not satisfy a `waitingFor = approval` park. Treat one like a relayed message: keep the stage parked and resolve the approval through the operator-owned path.

   Messages sent while a subagent is finishing its turn are not dropped, and `ctrl+b` does not restart the session, so a mid-turn reattach keeps the awaited answer.

### Step 0 notes — scheduled tasks & agents-view replies

   Scheduled tasks and `/loop` wakeups come back after a compaction or resume, and a foreground-set task fires after a `/background` hand-off; a recurring one no longer runs an extra time on resume, respawn or fork. A background session waiting on a scheduled wakeup is kept through updates and low memory. Saved tasks created after `/resume`, `/branch` or `/clear` now fire, and a background session's `/loop` survives a process restart (2.1.292). Plan mode is restored on resume.

   A reply sent from `claude agents` arrives as a queued message and is retried for up to 12 s while a crashed session restarts. A slash command or answer it could not deliver is no longer saved and replayed on the next restart. A reply to a session parked on a permission prompt never approves the pending command.

### Step 0 notes — background-agent guarantees

   The resume loop may rely on these at the plugin's min CC:

#### Push & honest completion

   - **Push signals**: finish/needs-input fires the `Notification` hook (`agent_completed` / `agent_needs_input`) — prefer it as the wake-up; the `claude agents --json` pre-check stays the authoritative reconciliation.
   - **Honest completion**: an errored subagent surfaces as an error with partial work preserved, never an empty success — trust `subagent_stopped` `result: error` rows. This is not a hard invariant, so keep the `references/fn-gate.md` cross-check ("BG notification ≠ approval").

#### Stopped & work preservation

   - **Stopped means stopped**: an operator-killed agent never auto-respawns or re-runs a stale prompt; a daemon-restart-killed worker auto-resumes when the agents view next opens. Re-delegate only when the pre-check shows the agent truly absent.
   - **Work preservation**: waking a background job never deletes its transcript or re-runs the prompt; returning to `claude agents` carries running work over; long-running commands survive session restarts. A running background session holds its worktree's lock, so cleanup leaves it alone. Stale-worktree cleanup is not a resume chore.

#### Interrupted calls & transcript fidelity

   - **Interrupted calls**: a session that ended mid-tool-call resumes with that call marked outcome unknown and no hidden "Continue" message, so check its effect before repeating it. MCP calls in a resumed session wait up to 10s for a reconnecting server. `CLAUDE_CODE_RESUME_INTERRUPTED_TURN` does not re-run a turn that ended at `--max-turns`.
   - **Transcript fidelity**: `--resume` keeps the turns after a batch of parallel tool calls, the context a compaction restored, and the last messages before a quit. A session backgrounded while idle resumes its conversation instead of reopening empty. After a compaction Claude no longer takes its own last actions from before it as done after it, which made it retract or redo finished work, and a message typed while Claude works survives `←` backgrounding; if it cannot move, the session stays in the foreground and says so (2.1.293).

#### Reattach, cross-spawn & inspection

   - **Reattach fidelity**: `SendMessage` asks the caller to retarget when a re-spawned agent reuses a previous name; a `SendMessage`-resumed agent does not stick as `failed`/`completed`; a per-stage model override survives resume and follow-up messages (`skills/shared/model-selection.md § Per-Invocation Override`); `/rename` persists across restarts.
   - **Cross-spawn targeting**: `TaskStop` finds agents spawned by another agent and lists them by id/description on error, so resume can target a cross-spawned stage agent. Read a background task's output from its output file with `Read`.
   - **Inspection**: completed agents stay in `/tasks` until cleanup and attaching shows the transcript immediately, so a just-finished stage is still inspectable. Reopening a stopped session resumes it or reports why it cannot — a refusal means re-delegate, not retry blindly.

### Steps 1–7 — replay & audit

1. `tail -n 50 .context/logs/audit.jsonl | jq .` — last 50 audit lines
2. `.context/state.json` `tasks{}` — current ledger state
3. Cross-reference with `skills/shared/stage-contracts.md` — identify first incomplete stage
4. Re-read that stage's `.context/*.md` artifact (if partial)
5. If `metadata.retry_count > 0`, read `.context/errors/<agent>.md` for retry history
6. Continue from the execution loop's `while (tasks.some(...))` — no need to replay completed stages; reconcile the parked tasks against the decision ledger and the mailbox (§ Pending communication) before the resumed loop reaches its first boundary
7. Write a `resume` audit entry: `{actor: "orchestrator", action: "resume", subject: "<worktask_id>", result: "ok"}`

See `skills/context-compression/SKILL.md § PostCompact Recovery` for the compaction-specific flow.

## Claude Code 2.1.303 resume compatibility

Use the stored agent ID across restart and compaction. Name lookup after restart is fixed in 2.1.299,
but names assigned before the last compaction still require the ID. Do not dispatch a replacement on name lookup failure alone.
Repeated resumes retain SendMessage reachability from 2.1.295. Completion messages can describe an agent waiting
on its own background work, receiving a late message, or stopping at a usage limit (2.1.299).
A waiting notice is not a completed stage. Duplicate result/message delivery is also fixed in 2.1.299;
continue to reconcile by task and agent ID before applying completion once.
Stopping the agents service can stop live sessions after about one minute. Recheck discovery before redispatching.
Resumed headless dispatches carry the same optional compaction and retry controls; do not substitute an in-process run.
