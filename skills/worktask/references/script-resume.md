# Script resume

Read when executing or checking script resume.

Procedure routing: [scripts](scripts.md).

<!-- canonical-body:start -->
## blocked-on-dispatch.sh — resume — general flow

`--claim`, `blocked_on` → `null`, one closing-leg row with `decision_ref` (`skills/worktask/references/contracts/blocked-artifacts.md § Schema — blocked_on, decision_ref on the other arms`). Prints `{"resume_block":{"task_id","kind","arm","leg","decision_ref","resume_with","do_not_rerun":true,"instruction"},"cleared":true,"audit_row_written"}`, with `artifact_path` in `resume_block` when the kind resumes with one. `instruction` restates need (detail fenced) and forbids re-running completed steps.

### blocked-on-dispatch.sh — resume — artifact leg

`--leg landed` resumes `artifact` need: re-checks `path` safety and landed-set membership, exits 1 if not landed, otherwise claims, clears, writes ok `landed` row with `decision_ref`, prints same stdout. `--leg verified` (user's "done") still resumes through fallback.

### blocked-on-dispatch.sh — resume — correction leg

`--leg closed` resumes `correction` need: claim, clear, ok `closed` row with `decision_ref`, `artifact_path` = target's `artifact` or `metadata.artifact` (recorded-else-planned). Checks target status **not at all** — orchestrator calls at target's completion boundary (§ Step 6.5d). `--leg verified` (user's "done") resumes through fallback with same path. Settling `stale` dependents not part of either resume; keys on target, not parked need; runs own op at boundary.

### blocked-on-dispatch.sh — resume, a user decision

`resume` first finds the ledger row: `--decision-ref <ud-id>` names it, and without the flag it is
the newest valid row covering the task that no earlier `blocked_on` row for the task carries. A
refused or missing row exits 1 with nothing written. Otherwise the `resumed` row and
`resume_block.decision_ref` carry that `ud-` id. `instruction` names the verify command,
`state-patch.sh --verify-decision`, and carries no answer text
(`hooks/references/user-decision-ledger.md`).

### blocked-on-dispatch.sh — the lead lines

Fixed strings, with `<ID>` the only substitution:

- `user_decision`: "<ID> needs your decision. Answer with one of the options below, or your own."
- `user_action`: "<ID> needs you to do the request below, then answer done."
- `peer_session`: "<ID> needs an answer from the session below. Ask it, then answer with its reply."
- `artifact`: "<ID> waits on the file below from another task. Answer done once it exists."
- `correction`: "<ID> found the defect below in another task's work. Answer done once it is fixed."
- `host_environment`: "<ID> is blocked by the host check below, which still fails. Answer done
  once it passes."

### blocked-on-dispatch.sh — the blocked_on row

`actor: "orchestrator"`, `action: "blocked_on"`, `subject` and `task_id` both the task id. `result`
is `blocked` on a leg that leaves the task parked and `ok` on the closing leg. `metadata` is
`{kind, arm, leg}` plus `fallback_from` and `owner_issue` on a fallback, `command_head` and
`truncated` on a need with a command, and `decision_ref` on the closing leg. The redaction rule and
the head ladder: `skills/agent-coordination/SKILL.md § Writers — blocked_on rows`.

## blocked-on-lib.sh — the sourced interface

- `BLOCKED_ON_KINDS`, `BLOCKED_ON_RESUME_WITH`: both enums, in registry order.
- `blocked_on_arm <kind>`: prints the kind's row as `required|optional|resume_with|legs|closing_leg|owner_issue|landed`,
  comma-separated within a field. Exit 1 on an unknown kind.
- `blocked_on_normalize <handoff json>`: prints `{"blocked_on":{…},"source":"blocked_on"}`. Exit 1
  when `blocked_on` is absent; no other handoff key is read as a need.
- `blocked_on_validate <blocked_on json>`: kind and `resume_with` in their enums and `detail` a
  non-empty object; exit 1 with one `fail:` line. The harness stops here.
- `blocked_on_validate_arm <blocked_on json>`: adds the arm's required keys and its `resume_with`,
  and on `user_decision` the question, option, `recommended` and `item` bounds.

## mailbox.sh, mailbox-reply.sh and mailbox-lib.sh

| Script | One-line invocation | Purpose |
|--------|---------------------|---------|
| `scripts/mailbox.sh` | `show\|leg\|comment\|ingest-comments\|scan\|sweep\|wait` | The orchestrator side of the durable ask: the message transport's legs, the comment transport, reply ingestion, and the run's own scan and deadline sweep (§ Step 6.5a3, § Step 7a). |
| `scripts/mailbox-reply.sh` | `--ask-id … --answer-file …` | The only writer of `mailbox/replies/<ask_id>.json`. Self-test: `--self-test`. |
| `scripts/mailbox-lib.sh` | sourced, never run | The ask_id grammar, the mailbox root and its mode checks, the no-clobber write, the sha256 input, reply verification and the leg metadata. The router and both CLIs source it. |

### mailbox.sh — CLI

```
mailbox.sh show    --ask-id <id>
mailbox.sh leg     --task-id <ID> --ask-id <id> --leg sent|delivered --transport message
                   [--result ok|queued|refused|dropped|oversized|burst_limited]
mailbox.sh comment --task-id <ID> [--render-only]
mailbox.sh ingest-comments | scan | sweep | wait [--max-seconds N]      # all take [--state <state.json>]
```

Exit `0` ok; `1` refused — not an open ask, an invalid leg, or a bad `ask_id`; `2` usage error,
missing or unparseable ledger, or a broken install. Requires jq; bash 3.2+.

### mailbox.sh — stdout

| Subcommand | stdout (one JSON line) |
|---|---|
| `show` | the request JSON verbatim, for a same-repo peer reading `mailbox ask <ask_id>` |
| `leg` | `{"written"}` — `false` when that `(task, ask_id, leg)` was already recorded |
| `comment` | `{"posted","result"}`, result `posted\|post_failed\|opted_out\|unavailable\|scrub_failed`; `{"body"}` under `--render-only`, which posts nothing and writes no leg |
| `ingest-comments` | `{"ingested","ignored"}` |
| `scan` | `{"replied":[{task_id,ask_id}],"open":[{task_id,ask_id,deadline}]}` |
| `sweep` | `{"expired":[{task_id,ask_id,routed}]}` |
| `wait` | `{"reason":"reply\|deadline\|timeout\|none"}` |

### mailbox.sh — what scan, sweep and wait cover

`scan`, `sweep` and `wait` iterate **this run's ledger**, never the mailbox directory: the box is
shared across worktrees, and no run relays or expires another run's ask. `wait` polls every
`MAILBOX_POLL_SECONDS` (15), runs `ingest-comments` at most once a minute while a posted ask is
open, and stops at the first verified reply, at `min(deadline)+5`, or at `--max-seconds` (3600).

### mailbox-reply.sh — CLI

```
mailbox-reply.sh --ask-id <id> --answer-file <path|-> --kind peer|user --session <s> [--mailbox-dir <dir>]
mailbox-reply.sh --self-test
```

Prints `{"ask_id","reply_ref","sha256"}`. Exit `0` written; `1` refused, with one
`fail: <reason>: <detail>` line on stderr and nothing written, reason one of `invalid_ask_id`,
`bad_session`, `too_long`, `unknown_ask`, `bad_request`, `late`, `schema_invalid`, `duplicate`;
`2` usage error, mailbox unavailable, or no sha256 tool. The answer arrives only through
`--answer-file` (`-` for stdin), so untrusted text never reaches an argv (`step-7a-arms.md § Step 7a — ingestReply`).
