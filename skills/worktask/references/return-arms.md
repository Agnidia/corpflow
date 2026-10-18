# Return arms — Step 6.5a1 to 6.5a4

Read a section here only when its predicate in `skills/worktask/SKILL.md § Step 6.5a1–a4 — the
return arms, before Layer 2` holds. The detection code every return runs stays in SKILL.md;
this file holds the arm bodies, their helpers and their rationale. An unqualified `§` names a
section of `skills/worktask/SKILL.md`.

## Step 6.5a1 — the escalation target

```typescript
// The Escalate-to column of agent-coordination § Retry / Escalate Matrix, as data. That
// table stays the SSOT — status-enum-parity.bats diffs this map against it, so the two
// cannot drift. `transient` and `logic` are absent: they retry the same agent, so there is
// no edge. `hard_constraint` is absent too — it aborts for a human rather than re-entering
// the loop, and capping an abort would be meaningless.
const ESCALATE_TO = {
  missing_input: "PREV", exhausted: "PREV",
  ambiguous_requirements: "PL", design_flaw: "AR",
};
```

## Step 6.5a1 — the per-edge escalation cap

```typescript
function escalationBookkeeping(state, task, cls) {
  const meta = { ...(state.tasks[task.id].metadata ?? {}) };
  const code = ESCALATE_TO[cls];  // one patch; routing stays the next iteration's ready filter
  if (!code) return { terminal: false, metadata: meta };   // same-agent retry, or abort
  // Full task id, never a bare code: DV0→AR0 must not share a counter with DV3→AR0.
  const target = code === "PREV"
    ? (task.blocked_by ?? []).slice(-1)[0]    // previous stage per chain
    : Object.keys(state.tasks).find(id => id.startsWith(code));
  if (!target) return { terminal: false, metadata: meta };
```

## Step 6.5a1 — the cap, and the reset that must not reach it

```typescript
// …continued: escalationBookkeeping body
  const counts = { ...(meta.escalation_counts ?? {}) };
  counts[target] = (counts[target] ?? 0) + 1;
  meta.escalation_counts = counts;            // survives the reset below
  if (counts[target] > 2) return { terminal: true, metadata: meta };  // cap 2
  meta.retry_count = 0;                       // reset at handoff — retry_count ALONE
  meta.error_escalated_to = target.replace(/[0-9]+$/, "");
  return { terminal: false, metadata: meta };
}
```

## Step 6.5a2 — why a mid-stage yield needs its own arm

An agent that yields mid-sentence with budget remaining has **not** errored, so 6.5a does not fire
and control falls through to Layer 3 and Step 7, which settle the row from a verdict written before
the stage finished — corrupting the ledger in the one direction nothing downstream re-checks — or
escalate a stage that only needed resuming. This arm keys on *evidence* (artifact absent, or
present with no `handoff.verdict`), never on the shape of the return message, so a
normally-completed stage still takes Layer 2.

## Step 6.5a2 — mark & audit

```typescript
      // …continued: step 6.5a2 body
      if (incomplete) {
        atomicMergeStateJson({ tasks: { [task.id]: { status: "in_progress" } } });
        appendAudit({
          actor: "orchestrator", action: "stage_returned_incomplete", subject: code,
          result: "blocked",
          metadata: {
            task_id: task.id, run_index: full.metadata.run_index ?? 0,  // keys the resume bound
            artifact: incArtifact,
            artifact_present: fs.existsSync(incArtifact),
            reason: maxTurnsPartial ? "max_turns_partial"
                    : fs.existsSync(incArtifact) ? "handoff_verdict_missing" : "artifact_absent",
          },
        });
```

## Step 6.5a2 — resume, never re-delegate

The agent holds the half-done work; a fresh dispatch would redo it against a tree it already
edited. Same branch as a parked agent in `references/resume.md § State → Action Table`.
Auto-resume at most 2 times per row per run; the count includes this return.

```typescript
        // …continued: step 6.5a2 body. Count from the file appendAudit writes; missing → 0.
        const n = Number(sh(`jq -nR --arg id ${task.id} --argjson n ${full.metadata.run_index ?? 0} ` +
          `'[inputs|fromjson?|select(.action=="stage_returned_incomplete" and ` +
          `.metadata.task_id==$id and (.metadata.run_index//0)==$n)]|length' ` +
          `< "\${WORKSPACE_ROOT:-\${CLAUDE_PROJECT_DIR:-.}}/.context/logs/audit.jsonl"`) || 0);
```

## Step 6.5a2 — auto-resume, at most 2

```typescript
        // …continued: step 6.5a2 body
        if (n <= 2) {   // a stage message, so it carries a msg_id (Step 6.5a4)
          sendStageMessage(state, task, subagentType,
            `Stage ${code} returned without a completed handoff (auto-resume ${n} of 2). Finish the work, write ${incArtifact} with a handoff verdict, and return. Do not restart from scratch. The budget below counts from this message.\n${turnBudget(subagentType).line}`);
          continue;   // never falls through to the completion patch
        }
```

## Step 6.5a2 — the resume bound

```typescript
        // …continued: step 6.5a2 body. A 3rd incomplete return: block, audit, no SendMessage.
        sh(`state-patch.sh --task-status ${task.id} blocked`);
        appendAudit({ actor: "orchestrator", action: "stage_resume_exhausted", subject: task.id,
                      result: "escalated",
                      metadata: { task_id: task.id, run_index: full.metadata.run_index ?? 0,
                                  incomplete_returns: n, reason: "auto_resume_cap" } });
        continue;   // surface per SKILL.md § Escalation Chains
      }
```

The bound turns an endless resume loop into one escalation. The operator then resumes by hand,
re-dispatches (Step 4.7 reads `progress`) or descopes. `retry_count` stays untouched: nothing
failed. The count keys on `task_id` + `run_index`, since `subject: code` merges parallel DV rows
and runs; an older row with no `task_id` counts 0.

## Turn budget — the cap

`turnBudget(subagentType)` serves Step 4.7 (the banner) and Step 6.5a2 (each resume). It reads
the LOADED agent definition, because the runtime enforces that copy, not the worktree's.

```typescript
function turnBudget(subagentType: string) {   // → {cap, checkpoint, line, source}
  const [plugin, name] = subagentType.split(":");
  const root = plugin === "corpflow" ? CLAUDE_PLUGIN_ROOT    // resolver exit 1 → null
    : sh(`bash ${CLAUDE_PLUGIN_ROOT}/skills/cross-plugin-handoff/scripts/resolve-sibling-root.sh ${plugin}`);
  const fm = root ? firstFrontmatterBlock(`${root}/agents/${name}.md`) : null; // first --- block
  const m = fm?.match(/^maxTurns:[ \t]*([0-9]+)[ \t]*$/m);
  const read = m ? Number(m[1]) : 0;
```

## Turn budget — the line

```typescript
  // …continued: turnBudget body
  const cap = read >= 1 ? read : 50;
  const checkpoint = Math.floor(cap * 4 / 5);
  const line = `TURN BUDGET: ${cap} turns. Checkpoint by turn ${checkpoint}: record progress, ` +
    `write the partial artifact without a handoff verdict, and return.`;
  return { cap, checkpoint, line, source: read >= 1 ? "frontmatter" : "default" };
}
```

The checkpoint is `floor(0.8 × cap)`, worked in integers to avoid float drift: 40→32, 50→40,
60→48, 80→64. An unreadable `maxTurns` (no file, resolver exit 1, no match, or 0) defaults to
50, the Tier-2 cap, and Step 4.7 audits `warn`.

## Step 6.5a3 — why a typed blocked return needs its own arm

A stage that cannot continue without something it cannot produce returns `verdict: "blocked"` with
one `handoff.blocked_on` (`references/handoff-protocol.md § Schema — blocked_on`). Read as an
ordinary blocked verdict, that return burns a retry on a stage that never failed, and routed by
judgement it takes a new improvised route each time. So every kind goes through one table and one
router, and each writes a fixed set of audit legs.

## Step 6.5a3 — the dispatch table — kinds and routing

Route every `blocked` return by `kind`.

### Dispatch table

| kind | Orchestrator action | Audit legs | Fallback |
|---|---|---|---|
| `user_decision` | ask `question` with `options` at § Step 7a; resume with hook row's `ud-` id | asked / answered / resumed | none |
| `user_action` | show `request` and `!` line at § Step 7a | requested / verified | none |
| `permission` | park through § Step 6.5a4 | denied / granted / resumed | none |
| `peer_session` | write request, send pointer, relay validated reply | sent / delivered / answered / relayed / expired | `user_action` (mailbox unavailable); `user_decision` (expiry) |
| `artifact` | resume once `path` in stage tree's landed set | landed | `user_action` until `path` lands |
| `correction` | re-open `target_task`, park consumers `stale` | opened / closed | none |
| `host_environment` | re-probe `check` | probed | `user_action` while failing |

### Step 6.5a3 — landing an arm

Every kind is landed (owner issues: § blocked-on-lib.sh — the arm table). A kind added later starts
pending and routes to its fallback until its owner lands; landing it changes its row here and its
landed flag in `scripts/blocked-on-lib.sh` together.

### Step 6.5a3 — deliverAsk, one transport per ask

```typescript
// MB = scripts/mailbox.sh. `route` wrote the request and parked the task; this sends the pointer.
function deliverAsk(out) {
  const led = JSON.parse(fs.readFileSync(".context/state.json", "utf8"));   // route just parked it
  const to = led.tasks[out.task_id].metadata.blocked_on.detail.to;
  const one = ListAgents().filter(a => a.name === to);   // exactly one row ⇒ the message transport
  if (one.length !== 1) return spawnSync("bash", [MB, "comment", "--task-id", out.task_id]);
  const leg = (...a) => spawnSync("bash", [MB, "leg", "--task-id", out.task_id, "--ask-id",
    out.ask_id, "--transport", "message", ...a], { encoding: "utf8" });
  if (!JSON.parse(leg("--leg", "sent").stdout).written) return;   // sent already: never re-send
  const r = SendMessage({ to, message: out.message, notify_when_idle: true });
  leg("--leg", "delivered", "--result", r.result);
}
```

### Step 6.5a3 — why the transport is chosen once

`comment` writes its own `sent` and `delivered` legs, so the two transports never both run for one
ask. `leg` dedupes on `(task, ask_id, leg)`: `written: false` means a prior turn already sent this
ask, and `SendMessage` is not idempotent — a second send asks the peer the same question twice. A
`queued` or `refused` result is recorded and left to the deadline, never retried on another channel.

## Step 6.5a3 — the fallback arm

`route` parks a need as a `user_action` when the need's own arm cannot clear it: a landed arm whose
check misses (below), a mailbox that is unavailable, or a kind still waiting on its owner — none
today. The ledger keeps the stage's original `blocked_on`, and the `requested` row adds
`fallback_from`, plus `owner_issue` only for that last case, so no fallback carries one while every
kind is landed. At § Step 7a, `batch` shows a fixed lead line for the kind with the detail keys
fenced as data. Only a native `user_action` offers a `!` line.

- `peer_session` falls back only when the mailbox is unavailable: `fallback_from`, no `owner_issue`,
  `ask_id: null`, and the user relays that peer's reply. An ask that reaches its deadline instead
  takes one `expired` leg and re-routes as a `user_decision` carrying its question and options.
- `permission` never falls back. § Step 6.5a4 parks it, and the router writes no row for it.

### Step 6.5a3 — a landed arm that checks before it parks

A miss on either check below parks the need as a `user_action` with `fallback_from` and no
`owner_issue`.

- `host_environment`: `route` re-runs the autonomy preflight in check mode and writes `probed`. The
  need clears only when `check` reads `pass`.
- `artifact`: `route` checks `path` against the landed set of the stage's tree, once the path ladder
  admits it. A hit clears the need with the ok `landed` row and a `resume_block`; a miss, or a path
  no landing can produce such as a `.context/` artifact, writes no `landed` row.

### Step 6.5a3 — the correction arm — invocation

A `correction` names a defect in work another task owns. Route re-opens target and parks source. Orchestrator makes one `route` call; `route` makes one `state-patch.sh --task-reopen <target> --from <source>` call carrying every mutation, then parks source and writes `opened` leg (`references/scripts.md § blocked-on-dispatch.sh — route, the correction arm — invocation`).

### Step 6.5a3 — the correction arm — guards and mutations

Router checks: target exists, not source, is `completed`; refuses with `fail:` line and untouched ledger. Op re-checks under its lock. Retried turn caught by `opened` leg in log, so `fix_round` moves once per correction. Target becomes `pending` with `fix_round` +1, `gate_from_stage` = source stage code, `gate_blockers` = rework text. Every `completed` consumer becomes `stale`, keeping verdict, artifact, handoff. Ops: `references/handoff-protocol.md § tasks — re-open and settle — guards and invocation`.

### Step 6.5a3 — what the target and its consumers do next

The target's next dispatch carries the finding through the § Step 4.6 remediation injection, which
`fix_round` alone triggers, whatever stage the target is — there is no second brief builder. It
renders as the one `gate_blockers[]` string: the finding byte-for-byte, then its `evidence_ref:` and
`source_task:` lines. Its `stale` consumers wait for the target's own completion boundary, where § Step 6.5d
settles each of them; settling at the correcting stage's resume instead would judge them against an
artifact not yet corrected.

## Step 6.5a4 — why delivered is not acknowledged

A `reattach_send_result` of `ok` proves the harness accepted a message, not that the stage read it:
a message waiting on the stage's next tool round misses a stage that returns first. So every
orchestrator message to a stage carries a `msg_id`. The stage runs the `--ack` line it carries as
its first tool call and names the message it followed in `handoff.acted_on_msg_id`
(`skills/shared/stage-contracts.md § Orchestrator messages — ack first`). `ack-check.sh` joins the
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
// resume.md § Reattach rows — the result table — delivered and refusals, so the boundary escalates it; `queued` included.
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
  // (references/resume.md § Reattach rows — the SendMessage has a result too). run_index is the
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
