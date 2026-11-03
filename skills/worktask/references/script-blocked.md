# Script blocked

Read when executing or checking script blocked.

Procedure routing: [scripts](scripts.md).

<!-- canonical-body:start -->
## blocked-on-dispatch.sh and blocked-on-lib.sh

| Script | One-line invocation | Purpose |
|--------|---------------------|---------|
| `scripts/blocked-on-dispatch.sh` | `route\|batch\|resume` | Routes a typed `blocked_on` return to its arm or its `user_action` fallback, batches those needs and builds the resume (§ Step 6.5a3, § Step 7a). Self-test: `--self-test`. |
| `scripts/blocked-on-lib.sh` | sourced, never run | The one definition of the `blocked_on` enums, the arm table, the alias normalize step and `validate`. `handoff-harness.sh` and the router both source it. |

## blocked-on-dispatch.sh — CLI

```
blocked-on-dispatch.sh route  --task-id <ID> --payload <handoff json> [--state <state.json>]
blocked-on-dispatch.sh batch  [--tasks <ID,ID...>] [--boundary <ID>] [--workspace-json <path>] [--state <state.json>]
blocked-on-dispatch.sh resume --task-id <ID> --leg <leg> [--decision-ref <ud-id>] [--state <state.json>]
blocked-on-dispatch.sh --self-test
```

Exit `0` success. `1`: for `route`, an invalid need, with one `fail:` line on stderr naming the
unknown kind or `resume_with`, the missing `detail` or key, or the wrong pairing, and nothing
written; for `resume`, a task not parked on a non-permission `blocked_on`, a `--leg` that is not
its arm's closing leg, a `user_decision` with no verified ledger row to resume with, or `--leg landed`
on an artifact `path` that the path ladder refuses or that has not landed. `2`: usage error, missing
or unparseable ledger, broken install, or a ledger write refused. Requires jq; bash 3.2+.

## blocked-on-dispatch.sh — route

Normalizes and validates `--payload` through the lib, then acts on the arm the lib's table names:

- `permission`: writes nothing; § Step 6.5a4 parks it.
- `user_action`, or a kind whose owner has not landed — none today: `state-patch.sh --task-meta`
  with the stage's original `blocked_on` (under `--log /dev/null`), then `--task-status blocked`,
  then one `requested` row.
- `user_decision`: the same park, then one `asked` row with no fallback fields. It is queued for
  the next boundary's question, as `requested` is.
### blocked-on-dispatch.sh — host capability route

- `host_environment`: `autonomy-preflight.sh --auto plan --platform <metadata.preflight.platforms>`
  in check mode for a new need only, with `--harness` when `check` is `git-reset-hard`.
  Repeated ledger or audit records suppress another probe until an explicit recovery resume. Only a
  `checks[]` entry with that `id` reading `pass` clears it: `--claim`, `blocked_on` set to `null`,
  and `decision_ref` on the row. A fail, a skip or an absent id parks it as a `user_action`.

### blocked-on-dispatch.sh — route, the artifact arm

- `artifact`: parks first. When `detail.producer_task` is a task id, `detail.path` passes
  `land-artifacts.sh --check-path`, and the landed set of the task's `metadata.workspace_path` tree
  (`--list-landed --tree <workspace_path> --strict`) holds `detail.path` exactly, it claims, clears
  `blocked_on`, writes one ok `landed` row with `decision_ref` `blocked_on:<ID>:artifact:<n>`, and
  prints `resume_block` with `artifact_path` set to `detail.path`. No `workspace_path`, a failed
  read, a refused path or a non-member leaves it parked as a `user_action`: a `requested` row with `fallback_from: artifact`
  and no `owner_issue`. `BLOCKED_ON_LAND` swaps the landing script, a test seam.

### blocked-on-dispatch.sh — route, the correction arm — invocation

`correction` guards first: `detail.target_task` exists, not source, is `completed`; miss exits 1 with `fail:` line and unchanged ledger (§ Step 6.5a3 re-dispatches). Then `state-patch.sh --task-reopen <target> --from <source> --finding-file -` with rework text on stdin, source park, one `opened` row (`result: blocked`). Re-opening before parking deliberate: op can refuse under its lock; park ahead would leave source blocked with no row. Op input-bounds refusal (empty finding, byte cap, control byte) exits 1 with `fail:`, not escalation.

### blocked-on-dispatch.sh — route, the correction arm — re-route idempotency

Re-route of same still-open need detected by `opened` leg, not status guard (now reads `pending` after first route). Router re-parks source, writes no second `opened`, calls no op, so `fix_round` moves once per correction. Rework text on stdin: finding byte-for-byte, `evidence_ref:`, `source_task:` lines; lands as `gate_blockers[0]` (`skills/worktask/references/contracts/ledger-tasks.md § tasks — re-open and settle — guards and invocation`).

### blocked-on-dispatch.sh — route stdout

One JSON line: `{"task_id","kind","arm","leg","source","parked","audit_row_written"}`, plus
`fallback_from` and `owner_issue` on a fallback, and `decision_ref` and `resume_block` on a passing
re-probe or an artifact already landed. `leg` is `null` for `permission`. `source` names the key the need came from,
always `blocked_on`.

## blocked-on-dispatch.sh — batch

Selects every `blocked` task whose `metadata.blocked_on.kind` is not `permission`. Interactive:
`{"mode":"ask","needs":[{"task_id","kind","arm":"user_action","resume_leg","request","command",
"verify","truncated","cwd"}…],"payloads":[{"questions":[…≤4]}]}`, a fallback need adding
`fallback_from` and `owner_issue`. A fallback's `request` is its kind's lead line and its `command`
is `""`. Each question has the task id as `header`, the lead line, then every `detail` key as
`key: value` data and `cwd:` from the ledger's `workspace_path`, inside a fence one backtick longer
than its longest run. Options: "done" and "stop here".

### blocked-on-dispatch.sh — batch, a user decision

`user_decision` needs sharing one `(question, options, item)` become one question:

- `header` is the lowest task id, and `multiSelect` is false.
- `question` is `detail.question` verbatim and unfenced, because the hook matches its exact bytes.
- Each option is `{label: <option>, description: "Recommended" | "Offered by <header>"}`.
- Two questions with the same text never share a call, since the answers are keyed by that text.

Each need is `{task_id, kind, arm: "user_decision", resume_leg: "resumed", header}`. The megatask
park adds `{kind: "user_decision"}` to `escalated[]`.

### blocked-on-dispatch.sh — batch, the `!` line and the megatask park

A `! <command>` line, in its own fence, appears only on a native `user_action` whose `command` is
non-empty and not cut at 512 characters. Under a megatask per-issue run it asks nothing and prints
`permission-park.sh batch`'s `megatask_park` shape: the same `workspace.json` write and symlink
refusal, and one `escalation_parked` row with `metadata.kind: "user_action"` whose `escalated[]`
entries are `{kind, command_head, truncated}`.
