# Recovery gates

Read when executing or checking recovery gates.

Procedure routing: [resume](resume.md).

<!-- canonical-body:start -->
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
| --- | --- | --- |
| Stage `blocked` with `metadata.blocked_on` of a kind other than `permission` | A `blocked_on` row with `result: "blocked"` and no later closing-leg row for that `task_id` | Parked on a typed need (`skills/worktask/references/completion-merge.md#step-65a3--route-every-typed-blocked-return`). Do not re-delegate, and do not call `route` again: a second call writes a second opening leg. Re-enter the loop; § Step 7a's `blocked-on-dispatch.sh batch` asks the user at the next boundary — a `user_decision` need only after § Pending communication probes it |
| Stage `blocked` on `peer_session` with a `metadata.ask_id` | A `sent` or `delivered` leg carrying that `ask_id`, and no `relayed` or `expired` leg for it | The ask is durable and outlives the session; § Pending communication fixes the order it is reconciled in. Never re-route and never re-send: the request file and the `sent` leg both exist |


#### Reply routing — why the stage cannot ask for itself

A subagent's `SendMessage` to another session delivers its reply to the parent session's
conversation, so a stage that sends its own cross-session ask never receives the answer. The stage
returns `blocked_on` of kind `peer_session` naming who to ask and what; the orchestrator routes it
through the mailbox and relays the verified reply. Rule and schema: `skills/agent-coordination/SKILL.md#replies-from-a-subagent-land-in-the-parent-conversation` and `skills/worktask/references/contracts/blocked-needs.md § Schema — blocked_on, the peer_session arm`.

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
