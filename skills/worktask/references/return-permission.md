# Return permission

Read when executing or checking return permission.

Procedure routing: [return-arms](return-arms.md).

<!-- canonical-body:start -->
## Step 6.5a4 — why delivered is not acknowledged

A `reattach_send_result` of `ok` proves the harness accepted a message, not that the stage read it:
a message waiting on the stage's next tool round misses a stage that returns first. So every
orchestrator message to a stage carries a `msg_id`. The stage runs the `--ack` line it carries as
its first tool call and names the message it followed in `handoff.acted_on_msg_id`
(`skills/worktask/references/contracts/stage-outputs.md § Orchestrator messages — ack first`). `ack-check.sh` joins the
send rows, the `message_ack` rows and that field.

The instruction a stage followed is the one its ack rows and `acted_on_msg_id` prove, not the latest
amendment; message order proves nothing. Send rows without a `msg_id` are exempt. Exit → action: `references/resume.md § Reattach rows — one resend, then
escalate`.

## Step 6.5a4 — why a permission denial needs its own arm

An auto-mode classifier denial is not a stage failure: the stage stopped where it should, and the
session's permission posture said no. Read as an ordinary blocked or errored return it spends a
retry or escalates a stage that never failed; left to the orchestrator it becomes an ad-hoc stop
and a hand-landed command that no stage, review or audit row records. This arm parks the task, § Step 7a asks the user once
per boundary, and only the denied step resumes.

### Step 6.5a4 — a resumed stage meets the ack check first

§ Step 7a resumes a live stage through `sendStageMessage`, so the resume carries a `msg_id` like
every other stage message. The stage's next return passes the ack check above before it reaches
this arm: denied again after acknowledging, it parks again here; a resume it never acknowledged
reads not delivered and takes one resend, then escalation, without reaching classify. A
re-dispatched stage gets the instruction as prompt suffix [7], which is not a message.

## Step 6.5a4 — rationalizations

| Excuse | Reality |
|---|---|
| "One merge; landing it myself beats asking" | The classifier refused it for this session. Landed by hand it is the same action with no grant, no reviewer and no stage record. |
| "Re-dispatch and let it try again" | The denial stands until the user acts, and a retry walks a stage that never failed toward `exhausted`. |
| "Ask first, dispatch the ready stages after" | The question waits on a human. Dispatch first (§ Dispatch on the same turn), then ask. |

## Step 6.5a4 — one resend, then escalate

```typescript
// Exit 1 resends only `send=ok` misses. Any other send result had its turn at send time in
// skills/worktask/references/recovery-liveness.md § Reattach rows — the result table — delivered and refusals, so the boundary escalates it; `queued` included.
function resendOnceOrEscalate(state, task, subagentType, ack) {
  if (ack.status === 2) return escalate(task.id);   // a failed check is never clear
  const misses = [...ack.stdout.matchAll(/^msg (\S+) not-delivered send=(\S+)$/gm)];
  const ids = ack.status === 1
    ? misses.filter(m => m[2] === "ok").map(m => m[1])
    : [ack.stdout.match(/^acted_on \S+ expected=(\S+) mismatch$/m)[1]];
  if (ack.status === 1 && ids.length === 0) return escalate(task.id);
```

## Step 6.5a4 — every id judged before any resend

```typescript
  // …continued. Nothing is sent until every id is judged, so no resend precedes an escalation.
  // A non-ok miss beside an ok one escalates; so does a second miss, a message that already
  // supersedes another: no third send.
  const secondMiss = id => id === "none"
    || Boolean(sendRows(task.id).find(r => r.metadata.msg_id === id)?.metadata.supersedes);
  if (ids.length < misses.length || ids.some(secondMiss)) return escalate(task.id);
  // When the original message text is not in context, escalate rather than paraphrase.
  const texts = ids.map(restate);   // the text first sent as each id; null once out of context
  if (texts.includes(null)) return escalate(task.id);
  ids.forEach((id, i) => sendStageMessage(state, task, subagentType, texts[i], id));
}
```

## Step 6.5a4 — every stage message carries a msg_id

One path for every orchestrator → stage SendMessage: 6.5a2 nudge, 7a permission, typed-need resumes, reattaches, amendments, resends. Resend/retry omitting `supersedes` leaves replaced message reading not-delivered.

### Message ID assignment code

```typescript
// k counts this task's msg_id-bearing send rows over the whole log, so a replay never reuses one.
function sendStageMessage(state, task, subagentType, body, supersedes = null) {
  const msg_id = `${task.id}-m${sendRows(task.id).length + 1}`;
  const sent = SendMessage({ to: dispatchEntry(state, task.id).agent_id ?? subagentType,
    message: [`msg_id: ${msg_id}`, ...(supersedes ? [`supersedes: ${supersedes}`] : []),
      `First tool call: bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --ack ${task.id} ${msg_id}`,
      "Set handoff.acted_on_msg_id to the newest msg_id you acted on.", "", body].join("\n") });
```

## Step 6.5a4 — the send row

```typescript
  // …continued: sendStageMessage body. One row per attempt, result never omitted
  // (skills/worktask/references/recovery-liveness.md § Reattach rows — the SendMessage has a result too). run_index is the
  // dispatch scope ack-check.sh --run-index filters on; an integer, so the check can read it.
  appendAudit({
    actor: "orchestrator", action: "reattach_send_result", subject: task.id, task_id: task.id,
    result: sent.delivered ? "ok" : "blocked",
    metadata: { msg_id, run_index: state.tasks[task.id].metadata.run_index ?? 0,
                ...(supersedes ? { supersedes } : {}),
                ...(sent.delivered ? {} : { reason: sent.reason }) },   // refused | dropped | … | queued
  });
}

// Matched on task_id, falling back to subject: the same join ack-check.sh uses.
const sendRows = id => auditRows(id, "reattach_send_result").filter(r => r.metadata?.msg_id);
```
