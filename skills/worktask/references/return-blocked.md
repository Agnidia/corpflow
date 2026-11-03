# Return blocked

Read when executing or checking return blocked.

Procedure routing: [return-arms](return-arms.md).

<!-- canonical-body:start -->
## Step 6.5a3 — why a typed blocked return needs its own arm

A stage that cannot continue without something it cannot produce returns `verdict: "blocked"` with
one `handoff.blocked_on` (`skills/worktask/references/contracts/blocked-needs.md § Schema — blocked_on`). Read as an
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

- `host_environment`: `route` probes a new need once and writes `probed`; repeated returns stay parked. The
  need clears only when `check` reads `pass`.
- `artifact`: `route` checks `path` against the landed set of the stage's tree, once the path ladder
  admits it. A hit clears the need with the ok `landed` row and a `resume_block`; a miss, or a path
  no landing can produce such as a `.context/` artifact, writes no `landed` row.

### Step 6.5a3 — the correction arm — invocation

A `correction` names a defect in work another task owns. Route re-opens target and parks source. Orchestrator makes one `route` call; `route` makes one `state-patch.sh --task-reopen <target> --from <source>` call carrying every mutation, then parks source and writes `opened` leg (`skills/worktask/references/script-blocked.md § blocked-on-dispatch.sh — route, the correction arm — invocation`).

### Step 6.5a3 — the correction arm — guards and mutations

Router checks: target exists, not source, is `completed`; refuses with `fail:` line and untouched ledger. Op re-checks under its lock. Retried turn caught by `opened` leg in log, so `fix_round` moves once per correction. Target becomes `pending` with `fix_round` +1, `gate_from_stage` = source stage code, `gate_blockers` = rework text. Every `completed` consumer becomes `stale`, keeping verdict, artifact, handoff. Ops: `skills/worktask/references/contracts/ledger-tasks.md § tasks — re-open and settle — guards and invocation`.

### Step 6.5a3 — what the target and its consumers do next

The target's next dispatch carries the finding through the § Step 4.6 remediation injection, which
`fix_round` alone triggers, whatever stage the target is — there is no second brief builder. It
renders as the one `gate_blockers[]` string: the finding byte-for-byte, then its `evidence_ref:` and
`source_task:` lines. Its `stale` consumers wait for the target's own completion boundary, where § Step 6.5d
settles each of them; settling at the correcting stage's resume instead would judge them against an
artifact not yet corrected.
