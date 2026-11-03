# Blocked needs

Read when a stage cannot proceed because it needs permission, a user decision, a user action, or a peer reply.

## Read for related fields
- For blocked artifacts, read [blocked-artifacts](blocked-artifacts.md).

Read these sections only when this procedure cites them.

###### Section lookup 1

[Per-stage required-field matrix](required-fields.md#per-stage-required-field-matrix)

<!-- canonical-body:start -->
### Schema — blocked_on

```yaml
# …continued: handoff.properties — the megatask Shared Seams registry entry, verbatim
      blocked_on:
        kind: user_decision | user_action | permission | peer_session | artifact | correction | host_environment
        detail: {…kind-specific…}   # e.g. permission: {tool, command, classifier_reason, allow_rule}; peer_session: {to, question, deadline}
        resume_with: decision_ref | artifact_path | reply_ref
```

OPTIONAL, legal only alongside `verdict: "blocked"`, which every stage may return with it under the
cross-stage blocked exception (§ Per-stage required-field matrix): the typed reason a stage cannot
continue, in the shape the megatask Shared Seams registry declares
(`skills/megatask/SKILL.md § Registry location`). Each kind has one arm below, which fixes its
`detail` keys and the one `resume_with` it pairs with.

#### Schema — blocked_on, the seven arms at a glance

| kind | detail keys, required first, `[optional]` | resume_with |
| --- | --- | --- |
| `user_decision` | question, options, [recommended], [item] | decision_ref |
| `user_action` | request, command, [verify] | decision_ref |
| `permission` | tool, command, classifier_reason, allow_rule | decision_ref |
| `peer_session` | to, question, [deadline] | reply_ref |
| `artifact` | producer_task, path | artifact_path |
| `correction` | target_task, finding, evidence_ref, severity | artifact_path |
| `host_environment` | check, observed | decision_ref |

`handoff-harness.sh --validate-frontmatter` rejects unknown kinds or `resume_with`, and missing `detail`.
The router rejects missing keys or wrong pairings. All arms share one table
(`skills/worktask/references/completion-merge.md § Step 6.5a3`).
`skills/worktask/scripts/blocked-on-lib.sh` owns both enums; change this table, library, and registry together for new kinds, keys, or values.

#### Schema — blocked_on, the permission arm

```yaml
# …continued: handoff.properties.blocked_on, when kind is permission
        detail:
          type: object
          required: [tool, command, classifier_reason, allow_rule]
          properties:
            tool: { type: string, maxLength: 64 }
            command: { type: string, maxLength: 512 }
            classifier_reason: { type: string, maxLength: 512 }
            allow_rule: { type: string, maxLength: 600 }
        resume_with: { const: decision_ref }
```

A stage fills it on auto-mode denial (`skills/worktask/references/stage-contracts.md § A permission
denial is returned, not worked around`). `allow_rule` is informational: the rule a user could add
themselves, which corpflow never writes. The ledger copy is `tasks.<ID>.metadata.blocked_on`,
written by `permission-park.sh park` and set to `null` by `resume` — `--task-meta` merges and has
no unset, so a cleared park reads `blocked_on == null`, not an absent key.

##### Schema — blocked_on, what decision_ref points at

`resume_with: decision_ref` names the `permission_resumed` audit row that `permission-park.sh
resume` appends once the user has answered (`skills/agent-coordination/SKILL.md § Writers —
permission resumes`). Its `metadata.decision_ref` is `permission_resumed:<task_id>:<dedupe_key>:<n>`,
and `resume` returns the same value as `resume_block.decision_ref`. `n` is 1 plus the earlier
resumes with that task and key, so a call that is denied and parked again gets a distinct ref.
`truncated: true` on a `batch` need or on `resume_block` marks a command cut at 512 characters. That
text is context only: it is never offered as a `!` line, and the full command is in Claude Code's
denial notice. The stored `blocked_on` carries no `truncated` key.

##### Schema — blocked_on, where the full detail lives

The full `command`, `classifier_reason` and `allow_rule` stay out of the audit log, not out of
`.context/`. They live in the stage artifact's `handoff.blocked_on`, when the stage wrote one,
which nothing clears, so it stays after resume; in the ledger's `tasks.<ID>.metadata.blocked_on`,
which `resume` sets to `null`; in the resume message or re-dispatch suffix built from
`resume_block.instruction`; and in the `batch` output and boundary prompt shown to the user. A
project that commits `.context/` commits the artifact copy, and a ledger copy committed while the
task was parked stays in that history.

##### Schema — blocked_on, the redacted audit shape

`.context/logs/audit.jsonl` is treated as committed, so it gets the redacted shape alone: `permission_denied` and `permission_resumed` rows carry `tool`, `dedupe_key`,
`command_head` and `truncated`, and `escalation_parked` lists `{tool, command_head, truncated}` per
need (`skills/agent-coordination/SKILL.md § Writers — redacted permission rows`). There `truncated` marks a head that shows less than the whole command, not the 512-character command cut.

#### Schema — blocked_on, the user_decision arm

```yaml
# …continued: handoff.properties.blocked_on, when kind is user_decision
        detail:
          type: object
          required: [question, options]
          properties:
            question: { type: string, maxLength: 512 }
            options: { type: array, minItems: 0, maxItems: 4, items: { type: string, maxLength: 200 } }   # 0 or 2-4; exactly 1 refused
            recommended: { type: string, maxLength: 200 }   # one of options
            item: { type: string, pattern: '^sw-[A-Z]{2}[0-9]+-[0-9]+$' }   # sweep item it settles
        resume_with: { const: decision_ref }
```

A choice only the user can make, with the options the stage weighed. It is not a closing-sweep
item: a sweep item lets the stage finish, and this need stops it. The options are unique and
non-empty; empty `options` means free-text only (an expired `peer_session` ask falls back to it).

##### Schema — blocked_on, the user_decision legs and decision_ref

- `asked`: `route` parked the need for the next boundary's question.
- `answered`: the hook's `user_decision_recorded` audit row, written when the user answered.
- `resumed`: the closing leg, written by `resume` once a verified ledger row covers the task.

Its `decision_ref` is the `ud-<YYYYMMDDTHHMMSSZ>-<n>` id of that row in `.context/decisions.jsonl`,
never the `blocked_on:<task_id>:<kind>:<n>` form. `resume` writes it on the `resumed` row and returns
it as `resume_block.decision_ref`. The answer text stays in the ledger: no audit row and no
`resume_block.instruction` carries it. The stage reads it through `state-patch.sh --verify-decision`
(`hooks/references/user-decision-ledger.md`).

#### Schema — blocked_on, the user_action arm

```yaml
# …continued: handoff.properties.blocked_on, when kind is user_action
        detail:
          type: object
          required: [request, command]
          properties:
            request: { type: string, maxLength: 512 }
            command: { type: string, maxLength: 512 }   # "" when there is nothing to run
            verify: { type: string, maxLength: 512 }    # how the resumed stage confirms it
        resume_with: { const: decision_ref }
```

Something only the user can do on the host: boot a device, place a file, sign in. The user runs
`command` as a `!` line; the orchestrator never runs it. A command cut at 512 characters is context
only, as on the permission arm. The resumed stage checks `verify` before it continues.

#### Schema — blocked_on, the peer_session arm

```yaml
# …continued: handoff.properties.blocked_on, when kind is peer_session
        detail:
          type: object
          required: [to, question]
          properties:
            to: { type: string, maxLength: 200 }            # the peer session's name
            question: { type: string, maxLength: 512 }
            deadline: { type: string, format: date-time }   # ISO-8601; past it the ask expires
        resume_with: { const: reply_ref }
```

An answer only another session holds. The stage never sends the ask itself, because a subagent's
cross-session reply lands in the parent conversation (`skills/agent-coordination/SKILL.md § Replies
from a subagent land in the parent conversation`).

##### Schema — blocked_on, the peer_session deadline and ask id

`deadline` is the stage's value when it gives one, else `created_at` plus 30 minutes, and either is
clamped to `[now+60s, now+24h]`; a value that is not an ISO-8601 date-time is refused at `route`
with a `fail:` line and nothing written. Past its deadline the ask expires to a `user_decision`, so
the stage is never left waiting on a session that never answers. The ask's id lives on the ledger's
`tasks.<ID>.metadata.ask_id`, matching `^ask-[0-9]{8}t[0-9]{6}z-[0-9a-f]{12}$` — the `detail`
contract above carries no key for it, and no `options` key.

##### Schema — blocked_on, the peer_session reply_ref

`reply_ref` is `mailbox/replies/<ask_id>.json`, relative to the shared root resolver's stdout and
never absolute. It names the verified reply file that `mailbox-reply.sh` wrote — the record the
resumed stage re-reads, whose answer `resume` also relays fenced as data inside the instruction
(`skills/worktask/references/script-resume.md § mailbox-reply.sh — CLI`). While the arm falls back, because the mailbox
is unavailable, its `reply_ref` is the `decision_ref` below instead.
