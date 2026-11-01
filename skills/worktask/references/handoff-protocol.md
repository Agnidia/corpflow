# Handoff Protocol — Inter-Stage Communication Reference

Canonical spec for worktask inter-stage communication: the `state.json` ledger, the YAML `handoff:` frontmatter contract, the typed-return schemas, the cache-friendly preamble layout, and the fallback paths.

---

## #atomic-write

Atomic state.json write: lock → read → merge → temp → fsync → rename → unlock. An
mkdir-spinlock serializes the read-merge-rename window (macOS has no `flock(1)`), so legal
sibling overlap (parallel DVN tracks, DC+QA) cannot drop a patch to last-rename-wins.
POSIX-shell pseudocode:

### Lock acquisition (step 0)

```bash
# 0. Acquire the merge lock (mkdir is atomic on POSIX). Env knobs:
#    STATE_LOCK_TIMEOUT_S (default 5), STATE_LOCK_STALE_S (default 60).
lockdir=".context/state.json.lock.d"; waited=0
until mkdir "$lockdir" 2>/dev/null; do
  # Break a leaked lock older than STATE_LOCK_STALE_S (by dir mtime).
  age=$(( $(date +%s) - $(stat -f %m "$lockdir" 2>/dev/null || stat -c %Y "$lockdir") ))
  (( age >= STATE_LOCK_STALE_S )) && { rmdir "$lockdir" 2>/dev/null; continue; }
  # Timeout ⇒ proceed UNLOCKED + WARN (never a silent no-op). break_unlocked=1.
  (( waited >= STATE_LOCK_TIMEOUT_S )) && { echo "WARN: lock timeout — unlocked" >&2; break_unlocked=1; break; }
  sleep 1; waited=$(( waited + 1 ))
done
trap 'rmdir "$lockdir" 2>/dev/null' EXIT   # release on process end/failure
```

### Merge, write, rename (steps 1–6)

```bash
# …continued: same script, after lock acquisition
cur=$(cat .context/state.json)                                   # 1. last-known-good
new=$(echo "$cur" | jq --argjson patch "$PATCH_JSON" '. * $patch')  # 2. merge in-memory (idempotent)
tmp=".context/.state.json.$$.${RANDOM}.tmp"                      # 3. temp in same dir ⇒ same FS
printf '%s' "$new" > "$tmp"
sync "$tmp" 2>/dev/null || sync || true                          # 4. fsync (best-effort)
mv -f "$tmp" .context/state.json                                 # 5. POSIX-atomic rename
rmdir "$lockdir" 2>/dev/null                                     # 6. release (also on EXIT trap)
```

`$RANDOM` in the temp name guards against PID reuse inside Task subagents.

### Failure semantics

- Crash before step 3 — state.json untouched (last-known-good preserved).
- Crash between 3 and 5 — temp file orphaned. Cleanup on next worktask start: `rm -f .context/.state.json.*.tmp`. state.json untouched.
- Crash after 5 — state.json holds the new value; idempotent, so re-running the same patch is a no-op.
- Crash while holding the lock — the EXIT trap releases it; if the trap is skipped, the next writer breaks the dir once it is older than `STATE_LOCK_STALE_S`.

### Single-writer invariant

One writer per stage key, not one writer globally. Sibling overlap is legal (two stages, or two
DVN tracks writing distinct keys, may merge concurrently); the spinlock serializes their windows so
neither patch is lost. There is no "exactly one agent `in_progress`" requirement. On lock timeout
the write proceeds unlocked with a WARN, never as a silent exit-0 no-op.

### Lock implementation

`skills/worktask/scripts/state-patch.sh` — `atomic_merge()` plus `_lock_acquire` /
`_lock_release` / `_lock_break_if_stale` — is the single merge implementation, inherited by the
SubagentStop hook via delegation; when it is absent `state-merge.sh` warns and exits 0 without
merging.

---

## #frontmatter-schema

Every stage artifact (planning-N.md, architecture-N.md, …) starts with a YAML block between `^---$` markers. Token budget ≤200. Line budget ≤30.

AR and TL are optional (`skills/estimation-methodology/SKILL.md § Stage Inclusion Criteria`), so `architecture-N.md` / `coordination-N.md` may be absent. A frontmatter field referencing an absent stage's artifact is omitted, never written as a dangling path.

JSON-Schema-style spec:

### Schema — handoff base

```yaml
$schema: https://json-schema.org/draft/2020-12/schema
title: HandoffFrontmatter
type: object
required: [handoff]
properties:
  handoff:
    type: object
    required: [stage, verdict, summary, refs]
    properties:
      stage:
        type: string
        enum: [PL, AR, TL, DV, DR, SR, QA, DC, RE, FN, ST, IR, ET]
      verdict:
        type: string
        enum: [ok, blocked, escalate, pass, fail, go, no-go, approve, reject]
      summary:
        type: string
        maxLength: 200
      task_id:
        type: string
        pattern: '^[A-Z]{2}[0-9]+$'
        description: >
          OPTIONAL. The writing task's own id; its stage prefix must equal handoff.stage. Set it
          whenever the stage has more than one task, so sweep parity charges only this task's stubs.
```

### Schema — key_decisions, files_touched, next_stage_focus

```yaml
# …continued: handoff.properties
      key_decisions:
        type: array
        maxItems: 8
        items:
          type: object
          required: [id, summary, anchor]
          properties:
            id: { type: string, pattern: '^[a-z]{1,3}[0-9]+$' }
            summary: { type: string, maxLength: 160 }
            anchor: { type: string, pattern: '^[a-z0-9.\-/]+\.md#[a-z0-9\-]+$' }
      files_touched:
        type: array
        items: { type: string }
      next_stage_focus:
        type: string
        maxLength: 240
```

### Schema — open_questions, refs, constraints

```yaml
# …continued: handoff.properties
      open_questions:
        type: array
        items: { $ref: '#/$defs/SweepStub' }   # closing elicitation sweep, the only item shape
      refs:
        type: object
        additionalProperties: { type: string }
constraints:
  total_lines: { max: 30 }
  total_tokens: { max: 200, tokenizer: cl100k_base-proxy }
```

### Schema — acted_on_msg_id

```yaml
# …continued: handoff.properties, beside open_questions
      acted_on_msg_id:
        type: string
        maxLength: 200
        pattern: '^[A-Za-z0-9_][A-Za-z0-9._:@/-]{0,199}$'
        description: >
          OPTIONAL, every stage. The newest orchestrator msg_id this stage acknowledged with
          `state-patch.sh --ack <ID> <msg_id>` and followed. Absent: no msg_id-bearing message
          reached this dispatch. Checked at the boundary by ack-check.sh, not by the harness.
```

### Schema — decisions_applied

```yaml
# …continued: handoff.properties, beside acted_on_msg_id
      decisions_applied:
        type: array
        items: { type: string, pattern: '^ud-[0-9]{8}T[0-9]{6}Z-[0-9]+$' }   # UD_ID_RE
        description: >
          OPTIONAL, every stage. Each user-decision ledger row this stage acted on, once
          `state-patch.sh --verify-decision <ud-id> --task-id <own id> --expect-answer <applied>`
          exited 0 for it. Absent: the stage applied no user decision.
```

The item grammar is the ledger's row id, `ud-<YYYYMMDDTHHMMSSZ>-<n>`, where `n` is the row's 1-based
line number (`UD_ID_RE` in `hooks/lib/user-decision-lib.sh`). The acceptance rule is
`skills/shared/stage-contracts.md § A user decision is accepted only from the ledger`.

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
|---|---|---|
| `user_decision` | question, options, [recommended], [item] | decision_ref |
| `user_action` | request, command, [verify] | decision_ref |
| `permission` | tool, command, classifier_reason, allow_rule | decision_ref |
| `peer_session` | to, question, [deadline] | reply_ref |
| `artifact` | producer_task, path | artifact_path |
| `correction` | target_task, finding, evidence_ref, severity | artifact_path |
| `host_environment` | check, observed | decision_ref |

`handoff-harness.sh --validate-frontmatter` fails an unknown kind, an unknown `resume_with` or a
missing `detail`; the router also refuses a missing key or another row's pairing. All seven route
through one table (`skills/worktask/SKILL.md § Step 6.5a3`). `skills/worktask/scripts/blocked-on-lib.sh` holds both
enums, so a new kind, key or value changes this table, that lib and the registry entry together.

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

A stage fills it on an auto-mode classifier denial (`skills/shared/stage-contracts.md § A permission
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
(`skills/worktask/references/scripts.md § mailbox-reply.sh — CLI`). While the arm falls back, because the mailbox
is unavailable, its `reply_ref` is the `decision_ref` below instead.

#### Schema — blocked_on, the artifact arm

```yaml
# …continued: handoff.properties.blocked_on, when kind is artifact
        detail:
          type: object
          required: [producer_task, path]
          properties:
            producer_task: { type: string, pattern: '^[A-Z]{2}[0-9]+$' }
            path: { type: string, maxLength: 600 }
        resume_with: { const: artifact_path }
```

A file another task produces, which this stage must read before it can continue. Its
`artifact_path` is `detail.path`.

##### Schema — blocked_on, the artifact arm's landed leg

`route` parks the need, then reads the landed set only for a `path` the path ladder admits
(`land-artifacts.sh --check-path`); a stage file under `.context/` never lands, so it always takes
the fallback.
When `path` is in the landed set of the task's `metadata.workspace_path` tree, read with `--strict`,
the `landed` leg closes the need at once: one ok `landed` row carrying the `decision_ref`, and a
`resume_block` with `artifact_path`. Otherwise it parks as a `user_action` fallback
(`fallback_from: artifact`, no `owner_issue`, no `landed` row), and `resume --leg landed` closes it
once the path has landed. The landing that puts it there is the `contract_landed` ok row
(§ Landing — the audit row).

#### Schema — blocked_on, the correction arm — structure

```yaml
# …continued: handoff.properties.blocked_on, when kind is correction
        detail:
          type: object
          required: [target_task, finding, evidence_ref, severity]
          properties:
            target_task: { type: string, pattern: '^[A-Z]{2}[0-9]+$' }
            finding: { type: string, maxLength: 512 }
            evidence_ref: { type: string, maxLength: 600 }
            severity: { type: string, maxLength: 32 }
        resume_with: { const: artifact_path }
```

#### Schema — blocked_on, the correction arm — semantics

A defect in work another task owns. Any stage/resolver may return one; DC's option-existence gate is the worked example (`skills/shared/stage-contracts.md § The correction return (tpl-dc)`). `artifact_path` is `target_task`'s own artifact after correction: `tasks[<target>].artifact` if completion merge recorded one, else `metadata.artifact`.

##### Schema — blocked_on, the correction arm's two legs

`target_task` must be a `completed` task: a correction re-opens finished work, and the router's
`--task-reopen` guards refuse any other target with exit 4 and no ledger write (§ tasks — re-open
and settle). `route` parks the source, re-opens the target, parks that target's consumers `stale`,
and writes the `opened` leg (`result: blocked`). `resume --leg closed`, at that target's own next
completion, writes `closed` (`result: ok`) with its `decision_ref` and the corrected
`artifact_path`. Both rows carry `{kind, arm, leg}` and nothing else but that `decision_ref`: not
the target id, not the `finding`, not its `evidence_ref`
(`skills/agent-coordination/SKILL.md § Writers — blocked_on rows, the correction legs`). The finding
reaches the re-opened target through `metadata.gate_blockers` and the remediation injection, so no
second rendering path exists to review.

#### Schema — blocked_on, the host_environment arm

```yaml
# …continued: handoff.properties.blocked_on, when kind is host_environment
        detail:
          type: object
          required: [check, observed]
          properties:
            check: { type: string, maxLength: 64 }   # a metadata.preflight checks[].id
            observed: { type: string, maxLength: 512 }
        resume_with: { const: decision_ref }
```

A grant, evidence tool or toolchain that the autonomy preflight probes, failing now. `check` names
that probe (§ metadata.preflight — field notes), so a re-probe can tell fixed from still broken. A
host need no probe covers is a `user_action`.

#### Schema — blocked_on, decision_ref on the other arms

For every arm but `permission` and `user_decision`, `decision_ref` is
`blocked_on:<task_id>:<kind>:<n>`, the `metadata.decision_ref` of the closing-leg `blocked_on` audit
row. `blocked-on-dispatch.sh resume` appends and prints it; for a `host_environment` probe that
passes, or an `artifact` path already landed, `route` does. `<kind>` is the stage's own kind even
when a fallback arm closed the need, and `n` is 1 plus the earlier closing rows for that task and
kind. While an arm falls back, its `reply_ref` is that `decision_ref`, and its `artifact_path` is
resolved as the arm above says and printed beside it.

A landed `peer_session` closes on both: its `relayed` row's metadata carries `reply_ref` beside
`decision_ref`, and `resume` prints both in `resume_block`.

#### Schema — blocked_on, the other arms' full detail and audit row

The split is the permission arm's. The full detail lives in the artifact's `handoff.blocked_on`, in
the ledger's `tasks.<ID>.metadata.blocked_on`, which `resume` sets to `null`, and in the `batch`
output and boundary prompt. The committed `blocked_on` audit row carries no `request`, `command`,
`question`, `finding`, `observed` or user answer: only `{kind, arm, leg}` plus the fallback,
redacted-command and `decision_ref` fields (`skills/agent-coordination/SKILL.md § Writers —
blocked_on rows`).

#### Schema — blocked_on, reading it back

`blocked-on-lib.sh` owns the normalize step, so the harness and the router read a need alike:
`handoff-harness.sh --read-blocked-on <artifact>` prints the need plus a `source: blocked_on` line.
No other handoff key is read as a need.

### Schema — $defs: SweepItem and SweepStub

Closing elicitation sweep item, defined once for all three transports (contract:
`skills/shared/stage-contracts.md § Closing Elicitation Sweep`). The frontmatter and ledger
arrays carry `SweepStub`; the artifact body and the typed return carry the full `SweepItem`.

#### $defs — SweepItem (full item)

```yaml
# …continued: HandoffFrontmatter.$defs — also referenced by #handoff-schemas
$defs:
  SweepItem:
    type: object
    required: [id, summary, class, options, rationale]
    properties:
      id:        { type: string, pattern: '^sw-[A-Z]{2}[0-9]+-[0-9]+$' }
      summary:   { type: string, maxLength: 160 }
      rationale: { type: string, maxLength: 160 }
      stage:     { type: string }
      class:     { type: string, enum: [decision, escalate] }
      blocks_next_stage: { type: boolean }   # see $defs/SweepStub
```

##### $defs — SweepItem.options

```yaml
# …continued: $defs.SweepItem.properties
      options:
        type: array
        minItems: 2
        maxItems: 4                 # the ask tool's per-question option ceiling
        items:
          type: object
          required: [label, detail]
          properties:
            label:       { type: string, maxLength: 24 }
            detail:      { type: string, maxLength: 120 }
            recommended: { type: boolean }
        # Exactly one recommended option, as a schema fact rather than prose.
        contains:    { type: object, required: [recommended], properties: { recommended: { const: true } } }
        minContains: 1
        maxContains: 1
```

#### $defs — SweepStub (frontmatter + ledger)

```yaml
# …continued: HandoffFrontmatter.$defs
$defs:
  SweepStub:
    type: object
    # `summary` is optional: the question text is read from the `ref` anchor body,
    # which check_sweep_ref_anchor guarantees exists. `blocks_next_stage` is required
    # because absent and `false` are different claims: state it, never infer it.
    required: [id, class, ref, blocks_next_stage]
    properties:
      id:      { type: string, pattern: '^sw-[A-Z]{2}[0-9]+-[0-9]+$' }
      summary: { type: string, maxLength: 160 }   # OPTIONAL; the artifact body is canonical
      stage:   { type: string }
      class:   { type: string, enum: [decision, escalate] }
      ref:     { type: string, description: "anchor into the emitting stage's own artifact" }
```

##### $defs — SweepStub, the routing and answer fields

```yaml
# …continued: $defs.SweepStub.properties
      # Orthogonal to `class`: an escalate item may or may not block. The agent
      # self-labels and the orchestrator may raise false→true, never lower. That rule is
      # over labellers: this stub and its facts.open_questions[] twin have one author and
      # carry the same value, which handoff-harness.sh check_sweep_ledger enforces.
      blocks_next_stage: { type: boolean }
      status:            { type: string, enum: [open, resolved] }
      resolution:        { type: string, maxLength: 160 }
```

### Schema — $defs: TestRunEntry

One entry per runner invocation that printed its own summary line — the item shape of
`tests_executed` in DV and QA on both transports and on the ledger task row. A runner may repeat
(two scoped bats runs are two entries), entries are never folded into one count, and `[]` is legal.
Field rules: § DVHandoff — test-evidence field notes.

```yaml
# …continued: HandoffFrontmatter.$defs — also referenced by #handoff-schemas and #state-json-schema
$defs:
  TestRunEntry:
    type: object
    required: [runner, count]
    properties:
      runner:       { type: string, minLength: 1 }                   # free-form: bats, pytest, swift, …
      count:        { type: integer, minimum: 0 }                    # cases that RAN
      summary_line: { type: string, minLength: 1, pattern: '[0-9]' } # verbatim runner line
    if:   { required: [count], properties: { count: { minimum: 1 } } }
    then: { required: [summary_line] }
```

### Schema — subagents_spawned (B2 governance)

```yaml
# …continued: handoff.properties
      subagents_spawned:
        type: array
        maxItems: 5
        description: >
          OPTIONAL (B2). Sub-agents this stage dispatched, so DR/orchestrator see the
          fan-out without walking audit.jsonl. The cap of 5 is a policy tripwire — a
          stage needing more should re-split (TL). Nested spawns downshift a model tier
          and never run background-nested in a headless run.
        items:
          type: object
          required: [agent, task]
          properties:
            agent: { type: string, description: "resolved plugin:agent id" }
            task: { type: string, maxLength: 120 }
```

### Schema — deep_reads (B4 FN fan-in tripwire)

```yaml
# …continued: handoff.properties
      deep_reads:
        type: array
        description: >
          OPTIONAL (B4). Artifacts a fan-in stage (FN primarily) read in full beyond
          their ≤200-token frontmatter, with why. Empty/absent is healthy; a long list
          is the tripwire that a producing stage's frontmatter is under-informative.
        items:
          type: object
          required: [artifact, reason]
          properties:
            artifact: { type: string }
            reason: { type: string, enum: [anchor-miss, flagged-verdict, retry, ambiguous] }
```

#### deep_reads — the resolver exemption

A Step C.0a / C.3 resolver deep-reads by construction: it is handed the emitting stage's own
artifact and `planning-N.md` in full because the ≤200-token frontmatter cannot carry an `options[]`
body (`skills/shared/stage-contracts.md § What the resolver is given`). It declares those reads here
with `reason: "ambiguous"`, but they are excluded from the B4 tripwire, because they show a sweep
item exists, not that a frontmatter failed. Tell them apart by audit row: a resolver's reads arrive
under `auto_decision_resolved`, a fan-in stage's under its own stage id.

### Per-stage required-field matrix

Cross-stage blocked exception: any stage may return `verdict: blocked` when the return carries a
`blocked_on` (§ Schema — blocked_on), whether or not its row's vocabulary lists `blocked`. It holds
on both channels, so a typed `verdict` enum without `blocked` still accepts it alongside
`blocked_on`. A `blocked` with no `blocked_on` stays illegal on a row that lacks it, and no row's
own vocabulary changes.

#### Stages PL–DR

| Stage | Required (beyond base 4) | Optional | Verdict vocabulary |
|-------|--------------------------|----------|--------------------|
| PL | next_stage_focus, key_decisions, open_questions | files_touched | ok / blocked / escalate |
| AR | key_decisions, next_stage_focus, open_questions | files_touched, subagents_spawned | ok / blocked / escalate |
| TL | next_stage_focus, open_questions | key_decisions, files_touched | ok / blocked / escalate |
| DV | files_touched, next_stage_focus, tests_executed (TestRunEntry list), open_questions | key_decisions, subagents_spawned, test_suite_compiles (REQUIRED when tests_executed is empty or every count is 0) | ok / blocked / escalate |
| DR | key_decisions (= findings), open_questions | files_touched | pass / fail |

DR lists no `blocked`, yet still returns `verdict: blocked` with a `blocked_on` under the
cross-stage blocked exception above.

#### Stages SR–ET

| Stage | Required (beyond base 4) | Optional | Verdict vocabulary |
|-------|--------------------------|----------|--------------------|
| SR | key_decisions (= findings), open_questions | files_touched | pass / fail |
| QA | files_touched (= tests added), key_decisions (= results), tests_executed (TestRunEntry list), open_questions | — | go / no-go |
| DC | files_touched, open_questions | key_decisions | ok / blocked / escalate |
| RE | files_touched, key_decisions (= version), open_questions | — | ok / blocked |
| FN | next_stage_focus, files_touched, open_questions | key_decisions, deep_reads | ok / blocked |
| ST | key_decisions (= rationale), open_questions | blockers (on reject) | approve / reject |
| IR | key_decisions (= root cause), next_stage_focus, open_questions | files_touched | ok / escalate |
| ET | key_decisions (= ethics findings), open_questions | — | pass / fail |

##### Stages SR–ET — where the exception bites

SR, QA, ST, IR and ET list no `blocked`. Each still returns `verdict: blocked` with a `blocked_on`
under the cross-stage blocked exception (§ Per-stage required-field matrix), so a permission denial
is never returned as `fail`, `no-go` or `reject`.

### Token budget

Frontmatter is the canonical compression form: downstream stages read this block instead of the full upstream artifact whenever they only need the verdict, decisions, or refs. Over ≤200 tokens, every downstream stage pays.

A valid `tests_executed` list is excluded from that count up to 96 proxy tokens (about four entries), so recording every runner never costs budget. A `tests_executed` block that fails validation is excluded at the same 96-token cap, and the budget failure line says `(tests_executed invalid: excluded at the 96-token cap)`: the fault is reported once, and the rest of the prose is still checked against 200.

---

## Handoff Schemas {#handoff-schemas}

Canonical typed-return schemas — the single source of truth for the structured object a stage agent returns from its `Agent()` dispatch (`skills/worktask/SKILL.md § Orchestrator Execution Loop` Step 6).

Two parallel channels, neither replacing the other: the typed return is *validated*, the `handoff:` frontmatter is the *cache-friendly on-disk* form. So even on the typed path every stage still mirrors to `state.json facts` and writes its `.context/<stage>-N.md` artifact with frontmatter (durability, human readability, F4 regeneration — `#frontmatter-schema`, `#fallback-paths`).

### Schema conventions

JSON Schema draft 2020-12. Each stage's `verdict` enum MUST match that stage's row in `#frontmatter-schema § Per-stage required-field matrix` — one verdict vocabulary per stage across both channels, plus `blocked` alongside a `blocked_on` under that section's cross-stage blocked exception. The `required` set is the typed superset of that stage's frontmatter required fields (DR's `key_decisions (= findings)` becomes the typed `findings`/`blockers` arrays).

#### Conventions — the sweep field

Every stage schema requires `open_questions` — the closing elicitation sweep (`skills/shared/stage-contracts.md § Closing Elicitation Sweep`) is mandatory for all thirteen, and an empty array is the legal form for a stage with nothing to ask. Its `$ref: '#/$defs/SweepItem'` resolves against the single `$defs` block at `#frontmatter-schema § Schema — $defs: SweepItem and SweepStub`.

##### Conventions — the optional fields

`blocked_on` is optional on every stage — one shape, defined once at `#frontmatter-schema § Schema — blocked_on` — and no stage's vocabulary limits it, under the cross-stage blocked exception; absent means the stage is not blocked on a typed need.

`acted_on_msg_id` and `decisions_applied` are optional on every stage too, on the terms their frontmatter schemas state. `ack-check.sh` enforces `acted_on_msg_id`, not the validator.

###### Conventions — the $defs pointer is an obligation

The stage schemas below are printed without it, or without `TestRunEntry` (`#frontmatter-schema § Schema — $defs: TestRunEntry`, referenced by DVHandoff and QAHandoff), so an item shape is never restated per stage. Whatever passes a stage schema to `Agent()` must inline those `$defs` blocks alongside it; no shipped file implements that step today, and nothing executes these schemas, so the `$ref` is a specification pointer rather than a live resolution.

The schema is passed as an `Agent()`/`agent()` argument, never inserted into preamble sections [1][2][4][4b], so schema dispatch leaves cache-prefix byte-identity untouched (`#cache-prefix`).

### PLHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "PLHandoff",
  "type": "object",
  "required": ["verdict", "summary", "key_decisions", "next_stage_focus", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["ok", "blocked", "escalate"] },
    "summary": { "type": "string", "maxLength": 200 },
    "complexity": { "type": "integer", "minimum": 0, "maximum": 50 },
    "key_decisions": { "type": "array", "items": { "type": "string" } },
    "next_stage_focus": { "type": "string" },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### ARHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "ARHandoff",
  "type": "object",
  "required": ["verdict", "summary", "key_decisions", "next_stage_focus", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["ok", "blocked", "escalate"] },
    "summary": { "type": "string", "maxLength": 200 },
    "key_decisions": { "type": "array", "items": { "type": "string" } },
    "next_stage_focus": { "type": "string" },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### TLHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "TLHandoff",
  "type": "object",
  "required": ["verdict", "summary", "next_stage_focus", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["ok", "blocked", "escalate"] },
    "summary": { "type": "string", "maxLength": 200 },
    "next_stage_focus": { "type": "string" },
    "fanout": { "type": "array", "items": { "type": "string" } },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### DVHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "DVHandoff",
  "type": "object",
  "required": ["verdict", "files_modified", "build_status", "tests_executed",
               "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["ok", "blocked", "escalate"] },
    "files_modified": { "type": "array", "items": { "type": "string" } },
    "tests_added": { "type": "array", "items": { "type": "string" } },
    "decisions": { "type": "array", "items": { "type": "string" } },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### DVHandoff — build, test-evidence and architecture properties

```json
{
  "…continued": "DVHandoff.properties",
  "build_status": { "type": "string", "enum": ["pass", "fail", "skipped"] },
  "tests_executed": { "type": "array", "items": { "$ref": "#/$defs/TestRunEntry" } },
  "test_suite_compiles": { "enum": [true, false, "unknown"] },
  "architecture": {
    "type": "object",
    "required": ["ref", "applied"],
    "properties": {
      "ref": { "type": "string", "pattern": "^architecture-[0-9]+\\.md(#[a-z-]+)?$" },
      "applied": { "type": "boolean" }
    }
  }
}
```

#### DVHandoff — test-evidence field notes

`count` is the cases that ran under that runner, never cases it enumerated. `summary_line` is that
runner's summary line copied byte-for-byte, required whenever `count` is above 0 and checked against
the artifact body or a named `.context/logs/` capture; the count-token match inside it is warn-only,
since not every formatter repeats the number. QA's `tests_passed` / `tests_failed` stay grand totals, expected to equal the sum of `count`,
which DR spot-checks and the harness does not. Contract: `stage-contracts.md#tpl-dv § summary_line
is the checked half`.

##### DVHandoff — zero executed tests

`test_suite_compiles` is required whenever the `tests_executed` list is empty or every `count` is `0`,
and optional otherwise — the distinction between gate-blocked and never-built, answerable without
test-execution authority. It is deliberately not folded into `build_status`, which reports the app
build: a test target can fail to compile against a clean app build. Contract and rationale:
`stage-contracts.md#tpl-dv § Zero executed tests must say whether the suite compiles`. Enforced by
`handoff-harness.sh --validate-frontmatter`.

##### DVHandoff — the legacy scalar

A scalar `tests_executed` fails validation by default. Under `--legacy-tests-executed` (or
`CORPFLOW_LEGACY_TESTS_EXECUTED=1`) a legacy scalar and its legacy top-level
`test_summary_line` validate under the old integer rules with one deprecation `warn:`; the
opt-in never relaxes a list and is deprecated but still accepted. A top-level
`test_summary_line` beside a list is a legacy leftover, ignored as evidence with a `warn:`; its
line belongs in that runner's `summary_line`.

#### DVHandoff — architecture field notes

`architecture` is optional at the schema level but required whenever `state.json` has a
`tasks.AR0` entry, together with `refs.decisions`; both are omitted when AR did not run
(`stage-contracts.md#tpl-dv § Architecture reference contract`). Reference-resolution precedence,
shared by the harness, this schema and the DR rule: `refs.decisions`, then `architecture.ref`.
`handoff-harness.sh --validate-frontmatter <artifact> --state <state.json>` enforces it (warn-only
by default, blocking under `--strict`) and its inverse guard warns when an `architecture-*`
reference appears without a `tasks.AR0` entry. `applied` is DV's truthful statement that AR's
decisions were followed; deviations go in the row's artifact (`development-<N>[-<stream>].md`)
`## decisions` with rationale, and DR
fails an undeclared one.

### DRHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "DRHandoff",
  "type": "object",
  "required": ["verdict", "findings", "blockers", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["pass", "fail"] },
    "findings": { "type": "array", "items": { "type": "string" } },
    "blockers": { "type": "array", "items": { "type": "string" } },
    "p2_only": { "type": "boolean" },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### SRHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "SRHandoff",
  "type": "object",
  "required": ["verdict", "findings", "blockers", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["pass", "fail"] },
    "findings": { "type": "array", "items": { "type": "string" } },
    "blockers": { "type": "array", "items": { "type": "string" } },
    "threat_model": { "type": "string" },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### QAHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "QAHandoff",
  "type": "object",
  "required": ["verdict", "tests_executed", "tests_passed", "tests_failed", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["go", "no-go"] },
    "tests_executed": { "type": "array", "items": { "$ref": "#/$defs/TestRunEntry" } },
    "tests_passed": { "type": "integer", "minimum": 0 },
    "tests_failed": { "type": "integer", "minimum": 0 },
    "blocking_defects": { "type": "array", "items": { "type": "string" } },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  },
  "allOf": [{ "if": { "properties": { "verdict": { "const": "no-go" } } },
              "then": { "required": ["blocking_defects"],
                        "properties": { "blocking_defects": { "minItems": 1,
                          "items": { "type": "string", "minLength": 1 } } } } }]
}
```

#### QAHandoff — a no-go names its defects

A `no-go` names each defect in `blocking_defects`, one string each; `handoff-harness.sh
--validate-frontmatter` enforces it with or without `yq` (a whitespace-only entry counts as
empty). The Step 7 loop-back copies the list into the DV row's `gate_blockers`.

### DCHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "DCHandoff",
  "type": "object",
  "required": ["verdict", "files_modified", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["ok", "blocked", "escalate"] },
    "files_modified": { "type": "array", "items": { "type": "string" } },
    "cross_references": { "type": "array", "items": { "type": "string" } },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### REHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "REHandoff",
  "type": "object",
  "required": ["verdict", "version", "files_modified", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["ok", "blocked"] },
    "version": { "type": "string" },
    "files_modified": { "type": "array", "items": { "type": "string" } },
    "changelog": { "type": "array", "items": { "type": "string" } },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### FNHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "FNHandoff",
  "type": "object",
  "required": ["verdict", "summary", "next_stage_focus", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["ok", "blocked"] },
    "summary": { "type": "string", "maxLength": 200 },
    "next_stage_focus": { "type": "string" },
    "files_modified": { "type": "array", "items": { "type": "string" } },
    "pr_url": { "type": "string" },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### STHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "STHandoff",
  "type": "object",
  "required": ["verdict", "key_decisions", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["approve", "reject"] },
    "key_decisions": { "type": "array", "items": { "type": "string" } },
    "follow_ups": { "type": "array", "items": { "type": "string" } },
    "blockers": { "type": "array", "items": { "type": "string" }, "description": "reject only: one unmet criterion each; the loop-back injects them into the replayed DV prompt" },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### IRHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "IRHandoff",
  "type": "object",
  "required": ["verdict", "root_cause", "next_stage_focus", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["ok", "escalate"] },
    "root_cause": { "type": "string" },
    "next_stage_focus": { "type": "string" },
    "blast_radius": { "type": "string" },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### ETHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "ETHandoff",
  "type": "object",
  "required": ["verdict", "findings", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["pass", "fail"] },
    "findings": { "type": "array", "items": { "type": "string" } },
    "mitigations": { "type": "array", "items": { "type": "string" } },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### #schema-to-state-map

Each schema field maps onto the ledger (`#state-json-schema`) and the artifact anchor
(`#anchor-allow-list`). The map is channel-agnostic: the orchestrator applies it to a typed return
(`skills/worktask/SKILL.md § Orchestrator Execution Loop` Step 6), and populates the same targets
from the artifact's `handoff:` frontmatter when there is none (F2; an artifact without frontmatter, F3, populates nothing).

#### Map — PL, AR, TL

| Schema field | state.json target | Artifact anchor |
|--------------|-------------------|-----------------|
| `PL.verdict` | `tasks.PL0.verdict` | planning-N.md (frontmatter) |
| `PL.complexity` | `tasks.PL0.complexity` | planning-N.md `## complexity` |
| `PL.key_decisions` | `facts.decisions[]` | planning-N.md `## stages` |
| `AR.verdict` | `tasks.AR0.verdict` | architecture-N.md `## decisions` |
| `AR.key_decisions` | `facts.decisions[]` | architecture-N.md `## decisions` |
| `TL.verdict` | `tasks.TL0.verdict` | coordination-N.md `## fan-out` |
| `TL.fanout` | (DV sub-task prompts; not a ledger field) | coordination-N.md `## fan-out` |

#### Map — DV

Rows apply per DV ledger task: `<DV>` is the row's own id (`DV0`, `DV1`, …) and `<dev-artifact>`
its own artifact (§ DV fan-out — ledger tasks).

| Schema field | state.json target | Artifact anchor |
|--------------|-------------------|-----------------|
| `DV.verdict` | `tasks.<DV>.verdict` + `tasks.<DV>.status` (verdict map) + `facts.verdicts.<DV>` + derived `facts.verdicts.DV` | `<dev-artifact>` `## deviations` (summary line) |
| `DV.files_modified` | `facts.files_modified` (union) | `<dev-artifact>` `## files-changed` |
| `DV.tests_added` | `facts.tests_added` (union) | `<dev-artifact>` `## tests-added` |
| `DV.build_status` | (artifact only; status follows the verdict) | `<dev-artifact>` `## deviations` |
| `DV.tests_executed` | `tasks.<DV>.tests_executed` (current round) + `tasks.<DV>.rework_runs[]` (earlier rounds of a replayed row) | `<dev-artifact>` `## tests-added` |
| `DV.decisions` | `facts.decisions[]` | `<dev-artifact>` (inline) |

#### Map — DR, SR, QA, DC, RE

| Schema field | state.json target | Artifact anchor |
|--------------|-------------------|-----------------|
| `DR.verdict` | `tasks.DR0.verdict` + `facts.verdicts.DR0` + derived `facts.verdicts.DR` | developer-review-N.md `## verdict` |
| `DR.findings`/`blockers` | `facts.decisions[]` (= findings) | developer-review-N.md `## findings`/`## blockers` |
| `SR.*` | mirrors DR targets (`facts.verdicts.SR0`, derived `facts.verdicts.SR`) | security-review-N.md |
| `QA.verdict` | `tasks.QA0.verdict` + `facts.verdicts.QA0` + derived `facts.verdicts.QA` | testing-N.md `## verdict` |
| `QA.tests_executed` | `tasks.QA0.tests_executed` (current round) + `tasks.QA0.rework_runs[]` (earlier rounds) | testing-N.md `## results` |
| `QA.tests_passed`/`failed` | (artifact only; `facts.verdicts.*` holds verdicts, never counts) | testing-N.md `## results` |

#### Map — DC, RE

| Schema field | state.json target | Artifact anchor |
|--------------|-------------------|-----------------|
| `DC.verdict` | `tasks.DC0.verdict` | documentation-N.md `## files-changed` |
| `DC.files_modified` | `facts.files_modified` (union) | documentation-N.md `## files-changed` |
| `RE.verdict` | `tasks.RE0.verdict` | release-N.md `## version` |
| `RE.version` | `facts.decisions[]` (version) | release-N.md `## version` |

#### Map — FN, ST, IR, ET, worktree

| Schema field | state.json target | Artifact anchor |
|--------------|-------------------|-----------------|
| `FN.verdict` | `tasks.FN0.verdict` | complete-summary-N.md `## summary` |
| `FN.pr_url` | `handoffs["RE→FN0"]`/`DC→FN0`/`QA→FN0` (ref pointer); also `metadata.pr_url` (`--ledger-meta`) | complete-summary-N.md `## artifacts` |
| `ST.verdict` | `tasks.ST0.verdict` + `facts.verdicts.ST0` + derived `facts.verdicts.ST` | retrospective-N.md `## decision` |
| `IR.verdict` | `tasks.IR0.verdict` | incident-N.md `## root-cause` |
| `IR.root_cause` | `facts.decisions[]` | incident-N.md `## root-cause` |
| `ET.verdict` | `tasks.ET0.verdict` + `facts.verdicts.ET0` + derived `facts.verdicts.ET` | ethics-review-N.md `## verdict` |
| `DV.worktree_path` | `tasks.<DV>.worktree.path` | `<dev-artifact>` (frontmatter `worktree_path`) |
| `DV.worktree_branch` | `tasks.<DV>.worktree.branch` | `<dev-artifact>` (frontmatter `worktree_branch`) |

#### Additive-field writers

The v1 additive fields have orchestrator-loop / hook writers, not schema-mapped stage returns
(`facts.dispatched_agents[]`, `tasks.<ID>.last_error`, `tasks.<ID>.completed_via`,
`facts.capabilities` — `skills/worktask/SKILL.md § Orchestrator Execution Loop` steps 6/6.5).
Only `tasks.<ID>.worktree` maps from a stage artifact — the DV handoff frontmatter
`worktree_path`/`worktree_branch`, applied by `state-patch.sh` (rows above).

#### #facts-union

`facts.decisions[]`, `facts.open_questions[]`, `facts.files_modified` and `facts.tests_added` are
written by `state-patch.sh --facts '<json>'`, passed on the same self-patch call that lands the
stage's ledger row. It is the channel's only scripted writer.

##### #facts-union — who writes open_questions

`open_questions` is agent-written. A stage's closing-sweep stubs reach the ledger only if that
stage passes them in its own `--facts` payload; the two transports have no derivation between them,
so a stub written to frontmatter alone never reaches the FN gate.
`handoff-harness.sh --validate-frontmatter --state`, run at each stage completion
(`commands/worktask.md § Step B.1`), fails the stage when a sweep stub is missing from
`facts.open_questions[]`, when a stub present in both `handoff.open_questions[]` and
`facts.open_questions[]` carries a different `class` or `blocks_next_stage`, and when the ledger is
unreadable. The agent reconciles a divergence; the harness never joins it.

###### #facts-union — the merge table

The merge is a union, never `. * $patch`, because jq object-merge replaces arrays and would drop
an upstream stage's entries.

| Array | Identity | Collision | Order |
|---|---|---|---|
| `decisions` | `.id` | last writer wins | survivor moves to the tail |
| `open_questions` | `.id` | monotone join (`_union_sweep`): `status` `open < resolved`, `resolution` never dropped, `class` `decision < escalate` raise-only (an omitted class keeps the incumbent's; a refused downgrade exits 2 with a `facts_items_rejected` row) | survivor moves to the tail |
| `files_modified`, `tests_added` | the string itself | duplicate dropped | first-seen position kept |
| `stream_branches` (object) | the stream key | later value for that key wins; other keys kept | key insertion order |

##### Ordering and idempotency

Tail placement for the keyed arrays matters: the B3 clamp keeps the tail of each task's bucket, so
appending is what makes "newest survives" true after a union. Do not sort (`unique_by` does); that
hands the clamp an arbitrary survivor set.

Both shapes are idempotent: re-merging an already-merged payload leaves `state.json`
byte-identical, so a remediation loop may re-run its self-patch freely. A payload whose shape does
not match the table is rejected before the merge lock is taken. `--facts` applies ahead of the
completion merge, so facts still land when that merge short-circuits as idempotent.

#### Additive-field writers — facts.branch

Two writers, no stage agent among them: the orchestrator at `commands/worktask.md § Step 3c`, and
`refine-branch-target.sh` at § Step A.4b (at most once per run, pre-commit, ledger-only, no git
mutation). `state-patch.sh --facts '{"branch": "<name>"}'` accepts the key as a scripted channel for
either writer: a string matching `^[A-Za-z0-9._/][A-Za-z0-9._/-]{0,199}$`, last writer wins, any
other value fails the payload (exit 2).

The orchestrator's is an orchestrator-loop write: it parses the final `branch=<name>` stdout line
of `branch-name.sh` and stamps it directly — `branch-name.sh` never writes state.json (single
write chokepoint, `#atomic-write`). When that line is empty or non-conventional and
`target_branch=<name>` is not, the target is what gets stamped: the local rename can be
blocked (upstream tracked, target exists, host workspace) while the PR head is still the
pipeline's to name (§ Field notes — branch).

#### Additive-field writers — facts.stream_branches

One writer: FN on the multi-stream arm, passing the `facts=` line `fn-stream-merge.sh commit`
prints to `state-patch.sh --facts '{"stream_branches": {"<stream>": "<branch>"}}'`. Keys match the
S1 stream grammar (`^[a-z0-9]+(-[a-z0-9]+)*$`, ≤40), values the `branch` regex; any bad entry
fails the whole payload (exit 2) and `{}` is a no-op. It never touches `facts.branch`.

---

## #state-json-schema

`.context/state.json` is the worktask ledger. Created by PL0; patched by every stage on completion; read from disk by the orchestrator and by every stage agent. Preamble section [3] carries a pointer to it plus a readiness digest, never the ledger itself (`#cache-prefix`). Token budget ≤500.

JSON-Schema-style spec:

#### Ledger root

```yaml
$schema: https://json-schema.org/draft/2020-12/schema
title: WorktaskStateLedger
type: object
required: [version, worktask_id, plan_file, platform, run_index, tasks, facts, handoffs]
properties:
  version: { type: integer, const: 2 }
  worktask_id: { type: string, pattern: '^[a-z0-9\-]+$' }
  plan_file: { type: string }
  platform: { type: string, enum: [all, apple, android, web, systems, backend, ai] }  # canonical keys — skills/shared/platform-detection.md
  run_index: { type: integer, minimum: 0, default: 0 }
```

#### plan_file shape boundary

Canonical statement; other writer and reader sites point here. `state.json.plan_file` holds a
workspace-relative path (`.context/planning-N.md`); `task.metadata.plan_file` holds a bare basename
(`planning-N.md`). Both are legal. Every reader accepts either: try the value as given, then its
basename resolved against the directory holding `state.json`.

#### metadata

```yaml
# …continued: WorktaskStateLedger.properties
  metadata:
    type: object
    description: "Mirror of the dispatch fields shell helpers need — they cannot read Task-System metadata."
    properties:
      workspace_path: { type: string, description: "REQUIRED from the seed onward — see field note below" }
      base_ref: { type: string }
      requires_screenshots: { type: boolean }
      test_mode: { type: string }
      preflight: { type: object, description: "Autonomy preflight result, v1 — see metadata.preflight below" }
      ci: { type: string, enum: [enabled, disabled], description: "Absent means enabled — state-ledger.md § CI field" }
    additionalProperties: true
```

#### metadata.workspace_path

The absolute root of the tree this worktask is assigned to, seeded by
`commands/worktask.md` Step 3a on every run (`git rev-parse --show-toplevel`, else `pwd`) and
overwritten per-issue under `/megatask`. `dv-tree-preflight.sh` `resolve_assigned()` reads it as
rank 2 (after `--assigned`, before `$WORKSPACE_ROOT`).

Its absence is a defect, not a mode: every reader warns-and-proceeds on empty, so an unstamped
ledger disables the whole assigned-tree guard set at once. Rationale:
`initialization-patterns.md § Seeded workspace_path`.

#### metadata.base_ref

The integration branch, mirrored by PL0 from `task.metadata.base_ref` so shell helpers (which
cannot read Task-System metadata) can reach it. Reader resolution order, highest first:

| Rank | Source | Note |
|---|---|---|
| 0 | `fork_base()` fork point | Evidence, opt-in — see below. |
| 1 | `$FN_BASE_REF` | Explicit operator/test override. |
| 2a | `state.json tasks.<ID>.metadata.base_ref` | The row the caller names in `$BASE_REF_TASK_ID`; skipped when no task is named. |
| 2b | `state.json .metadata.base_ref` | Stamped by PL0; where a host-declared target branch enters the order — see below. |
| 3 | `workspace.json .git.base_branch` | `/megatask` per-issue record. |
| 4 | `git symbolic-ref refs/remotes/origin/HEAD` | Repository default branch. |
| — | unresolved | Reported, never guessed. |

##### Rank 0 is evidence, and opt-in

Rank 0 is consulted and reported, but it supplies the value only when ranks 1-4 are all empty and
the caller passed `--with-fork-point`. A fork point that disagrees with a value ranks 1-4 supplied
is surfaced (PL0 sweep item, `fn-preflight base-sanity` candidate line) and never applied, so a
branch deliberately rebased onto a release line is not silently retargeted.

It is opt-in because every other consumer reads an empty return as *decline, do not guess* and
gates on it (`refine-branch-target.sh`'s `base_unresolved` no-op, `branch-name.sh`, `continuity`,
`issue-close-required`). `base-sanity` opts in because it alone distinguishes an inferred base from
a configured one (its `base_guessed` degrade rung).

##### Rank 2a reads the named task row

A caller that reviews or merges one task's work names that task in `BASE_REF_TASK_ID` (for
example `stream-diff.sh` sets it to each DV row's own id). The row's `metadata.base_ref` then
answers ahead of the ledger mirror: the mirror is a copy, and a wrong copy otherwise gives every
row a wrong base. A row without a value, the string `null`, or an id absent from the ledger falls
through to rank 2b. The id reaches `jq` only as `--arg`, never inside the filter. Scope the
variable to one call; an exported value steers every later resolver call in that shell.

##### Rank 2b and the host-declared target branch

A host telling the session "the target branch for this workspace is `origin/develop`" is the
*provenance* of rank 2b, not a separate probe. It is outranked by `$FN_BASE_REF` alone, and it
outranks both the megatask record and the repository default.

##### Implementation

`skills/worktask/scripts/branch-lib.sh` — `resolve_base_ref` returns the value, `base_ref_source`
returns which rank answered (`env`, `task`, `state`, `workspace`, `origin_head`, `fork_point`,
`unresolved`; `task` is rank 2a, `state` rank 2b), both over one shared internal ladder and both accepting `--with-fork-point`. There is
no literal fallback; readers report unresolved and degrade non-blocking. The same ranks, identically
ordered, are restated in `pl0-procedure.md § Integration-branch detection`.

#### metadata.preflight

The autonomy preflight's passing result, a registered seam at `version: 1`. Its only writer is
`skills/worktask/scripts/autonomy-preflight.sh --record`, called once after the Step 3a seed of an
unattended run (`commands/worktask.md § Step 3a — record the autonomy preflight`), and `--record`
refuses any result that is not a pass. Absent on attended runs, on megatask per-issue runs, and
when the record failed. Consumer: the backend `tool_missing` evidence rule, which excuses a missing
evidence tool only when `tools_absent[]` records it `accepted: true`. Change protocol: bump
`version` on any field change.

##### metadata.preflight — schema

```yaml
# …continued: WorktaskStateLedger.properties.metadata.properties
      preflight:
        type: object
        required: [version, result, ran_at, platforms, checks, tools_absent]
        properties:
          version: { type: integer, const: 1 }
          result: { type: string, enum: [pass, fail] }   # always pass on a ledger
          ran_at: { type: string }                       # date -u +%FT%TZ, or "unknown"
          platforms: { type: array, items: { type: string } }
```

##### metadata.preflight — checks and tools_absent

```yaml
# …continued: metadata.properties.preflight.properties
          checks:
            type: array
            items:
              required: [id, kind, status, detail]
              properties:
                id: { type: string }
                kind: { type: string, enum: [permission, evidence, toolchain] }
                status: { type: string, enum: [pass, fail, skip] }
                detail: { type: string }
          tools_absent:
            type: array
            items:
              required: [tool, platform, accepted]
              properties:
                tool: { type: string, enum: [silicon, magick, convert, playwright, playwright-browser, adb-device, simulator, xcodebuildmcp] }
                platform: { type: string }
                accepted: { type: boolean }              # always true on a ledger
```

##### metadata.preflight — field notes

- `accepted: true` means the tool was named in `/worktask --accept-absent=` at launch; nothing else
  sets it. `--record` runs only after a pass and refuses an unaccepted entry, so every recorded
  `tools_absent[]` entry is `accepted: true`, and an `accepted: false` entry on a ledger is a
  contract violation.
- A tool that was present is never listed in `tools_absent[]`, accepted or not.
- A missing renderer is one entry per binary, as a `tool_missing` row names it (`silicon`,
  `magick`, `convert`); `renderer` accepts all three.
- `checks[].id`: `git-push`, `gh-pr-create`, `gh-pr-merge`, `git-reset-hard`, `renderer`, the other five tools,
  `apple-developer-dir`, `apple-sdk-settings`, `apple-showsdks`, `apple-swift-match`,
  `android-compile-sdk`, and `platform-<p>` (a platform with no checks of its own, recorded `skip`).
- With Playwright itself absent, `playwright-browser` is a `skip` check, not a second absent tool.

#### tasks

The sole stage ledger, keyed by numbered stage id (`[STAGE][N]` — `PL0`, `DV0`, `DV1`), the
same identity used in artifact names and in the destination side of a handoff edge
(`skills/shared/state-ledger.md`). An edge is `<PREV_CODE>→<TASK_ID>` (`TL→DV1`): only its source
side is a bare stage code. Hand-writing one — `#layer-1-fallback` — uses the numbered id, or a
split stage's four writers collide on one key. Full grammar: § Field notes — handoffs.

```yaml
# …continued: WorktaskStateLedger.properties.tasks
  tasks:
    type: object
    propertyNames: { pattern: '^(PL|AR|TL|DV|DR|SR|QA|DC|RE|FN|ST|IR|ET)[0-9]+$' }
    additionalProperties:
      type: object
      required: [status, metadata]
      properties:
        status: { type: string, enum: [pending, in_progress, completed, blocked, skipped, failed, stale] }
```

##### tasks — routing & dependencies

```yaml
# …continued: WorktaskStateLedger.properties.tasks.additionalProperties.properties
        blocked_by:
          type: array
          items: { type: string }
          description: "Stage ids this task waits on, e.g. ['DV0','DV1']. Ready ⇔ every entry is completed."
        metadata:
          type: object
          description: "Routing + dispatch contract — schema in skills/shared/state-ledger.md § JSON Schema."
```

##### tasks — execution results

```yaml
# …continued: WorktaskStateLedger.properties.tasks.additionalProperties.properties
        artifact: { type: string }
        complexity: { type: integer, minimum: 0, maximum: 50 }
        verdict: { type: string, description: "Sets status through the verdict map below" }
        claimed_at: { type: string, format: date-time, description: "Stamped by state-patch.sh --claim; kept on re-claim" }
        retry_count: { type: integer, minimum: 0, default: 0 }
        error_file: { type: string }
        progress:
          type: object
          description: "OPTIONAL. Budget-aware checkpoint — see field notes"
          properties:
            completed_batches: { type: array, items: { type: string } }
            next_batch: { type: string, description: "id of the next pending sub-batch, or absent when done" }
            updated_at: { type: string, format: date-time }
```

##### tasks — verdict → status

A stage patch sets `status` from the artifact's `handoff.verdict`; `state-patch.sh verdict_status` holds the only copy of the map.

| Verdict | `status` | Also written |
|---|---|---|
| `ok`, `pass`, `go`, `approve` | `completed` | `metadata.gate_from_stage` deleted |
| `blocked`, `escalate` | `blocked` | `metadata.gate_from_stage` deleted |
| `fail`, `reject`, `no-go` | `pending` | `metadata.gate_from_stage` = the patched stage's code, on the patched row |
| missing, or any other string | — | refused: exit 3, `state.json` byte-identical, on every caller path |

No verdict maps to `stale`: a stage never reports itself stale. `--task-reopen` is its only writer
and `--task-settle-stale` its only clearer (§ tasks — re-open and settle — guards and invocation).

##### tasks — loop-back, claim, create

The patch writes only its own row. Moving a failure back to DV is the orchestrator loop's job: it copies `gate_from_stage` onto the DV row it replays. `--claim <TASK_ID>` moves a `pending`/`blocked` row to `in_progress` and stamps `claimed_at`; a re-claim is a no-op, and a settled row (`completed`/`skipped`/`failed`) exits 4 — use `--task-replay`. A replay also sets `rework_pending` on a row holding `tests_executed`, so its next completion files the earlier round (§ Field notes — tests_executed, rework_runs).

`--task-create` refuses a row whose metadata lacks `effort`, `isolation`, `base_ref`, `requires_screenshots` or `workspace_path` (absent, `null` or `""`; `false` counts as present) with exit 2 and `state.json` untouched. `PL`/`IR` rows are exempt: PL0 is the stage that decides `base_ref` and `requires_screenshots`.

##### tasks — re-open and settle — guards and invocation

`--task-reopen <TARGET> --from <SOURCE> [--finding-file <path|->]` re-opens a correction-named task (`§ Schema — blocked_on, the correction arm — structure`; `skills/worktask/references/scripts.md § blocked-on-dispatch.sh — route, the correction arm — invocation`). Guards run first: target exists, is not source, is `completed`; source exists. Refusal: exit 4, `state.json` unchanged. One atomic apply then writes mutations.

##### tasks — re-open and settle — target mutation

Target: `pending`, `metadata.fix_round` = `(fix_round // 0) + 1`, `metadata.gate_from_stage` = source stage code, `metadata.gate_blockers` = stdin text (trailing whitespace stripped) or `[]`. Router composes text as `finding` byte-for-byte, blank line, `evidence_ref: <ref>`, `source_task: <id>` (because `gate_from_stage` carries stage code only). Artifact, verdict, handoff survive (like replay). `fix_round` re-arms remediation brief (`skills/worktask/SKILL.md § Step 4.6`).

##### tasks — re-open and settle — consumer mutation and idempotency

Every consumer: `stale`. Transitive set reachable downstream through `blocked_by`, filtered to `completed` status, minus source, minus `REPLAY_SIDE_EFFECT_STAGES` (`FN`, `RE`). Each keeps verdict, artifact, handoff. Finding via stdin (`--finding-file -`), excluded from state-patch log. Re-running refused by `completed` guard → retried route is idempotent.

##### tasks — settle, the cited set and the change set — invocation and table

`--task-settle-stale <TARGET>` runs after target completion and before the ready filter (`skills/worktask/SKILL.md § Step 6.5d`). It settles each `stale` task and prints `{"settled":[{"task","to","reason"}]}`:

| Case | `status` | `reason` |
|---|---|---|
| change set unreadable: no path, unreadable artifact, no parser, or absent `files_touched` | `pending` | `change-set-unknown` |
| cited set empty; dependent files_touched absent, unparsed or empty | `pending` | `cited-set-empty` |
| cited set empty; dependent's own files_touched intersects the change set | `pending` | `own-file-changed` |
| cited set empty; dependent's own files_touched is disjoint from the change set | `completed` | `no-own-file-changed` |
| cited and change sets intersect | `pending` | `cited-file-changed` |
| cited is not in change set (or `.context/` emptied it) | `completed` | `no-cited-file-changed` |

##### tasks — settle, the cited set and the change set — read vs empty distinction

Read vs empty carries fail-safe: unreadable change set is unknown (every dependent re-verifies); read then emptied by filters is known (dependent citing nothing keeps result). Collapsing them turns "no evidence" into "no change".

##### tasks — settle, the cited set and the change set — set definitions

**Cited set** of stale task `T`: `facts.files_read[] | select(.stage == <T's stage code>) | .path` unioned with `tasks[T].metadata.consumes[].paths[]`.

**Change set**: `handoff.files_touched[]` from target artifact (`tasks[TARGET].artifact` else `metadata.artifact`), filtered: `+ N more` drops as count not path; `.context/` paths drop entirely (target rewrites its artifact; counting it returns every dependent). Both normalised: strip `./` prefix, `#anchor` and `:N` suffix. `--changed <paths>` substitutes change set, state becomes `known` if ≥1 path (test seam).

`facts.files_read` keeps newest 30 entries; old stage's citations can be gone by settle time (empty-cited-set case, re-verifies).

#### tasks — tests_executed, rework_runs

```yaml
# …continued: WorktaskStateLedger.properties.tasks.additionalProperties.properties
        tests_executed:
          type: array
          items: { $ref: '#/$defs/TestRunEntry' }
          description: "OPTIONAL (DV, QA). Mirrors the current round's handoff.tests_executed — see field notes"
        rework_runs:
          type: array
          description: "OPTIONAL, append-only. One entry per earlier round of a replayed row"
          items:
            type: object
            required: [round, tests_executed]
            properties:
              round: { type: integer, minimum: 1 }
              tests_executed: { type: array, items: { $ref: '#/$defs/TestRunEntry' } }
        rework_pending: { type: boolean, description: "Transient. Set by --task-replay, consumed by the next completion merge" }
```

#### tasks — completed_via, last_error

```yaml
# …continued: WorktaskStateLedger.properties.tasks.additionalProperties.properties
        completed_via:
          type: string
          enum: [hook, step6_5, f3]
          description: "OPTIONAL — see field notes"
        last_error:
          type: object
          description: "OPTIONAL — see field notes"
          required: [class, at]
          properties:
            class: { type: string, enum: [transient, logic, missing_input, ambiguous_requirements, design_flaw, hard_constraint, exhausted] }
            partial: { type: boolean, description: "partial work was preserved on the errored return" }
            at: { type: string, format: date-time }
            ref: { type: string, description: "pointer into .context/errors/<agent>.md (e.g. #retry-1)" }
```

#### tasks — worktree

```yaml
# …continued: WorktaskStateLedger.properties.tasks.additionalProperties.properties
        worktree:
          type: object
          description: "OPTIONAL (DV primarily) — see field notes"
          properties:
            path: { type: string }
            branch: { type: string }
```

#### facts

```yaml
# …continued: WorktaskStateLedger.properties
  facts:
    type: object
    required: [files_modified, tests_added, decisions, open_questions, verdicts]
    properties:
      goal:
        type: string
        maxLength: 240
        description: "One-sentence worktask intent, populated by PL0 — see field notes"
      branch:
        type: string
        maxLength: 120
        description: "Working branch named once at PL start — see field notes"
      stream_branches:
        type: object
        propertyNames: { pattern: "^[a-z0-9]+(-[a-z0-9]+)*$", maxLength: 40 }
        additionalProperties: { type: string, pattern: "^[A-Za-z0-9._/][A-Za-z0-9._/-]{0,199}$" }
        description: "OPTIONAL (additive) — stream -> stream branch, FN multi-stream arm only; see field notes"
      files_modified: { type: array, items: { type: string } }
      tests_added: { type: array, items: { type: string } }
```

#### facts — decisions

```yaml
# …continued: WorktaskStateLedger.properties.facts.properties
      decisions:
        type: array
        maxItems: 8   # per task — there is no global ceiling
        description: "Bounded (B3): newest 8 per task survive, partitioned by the writing task's id (from `stage`, stamped at write time). Clamped at the single write chokepoint state-patch.sh atomic_merge() (AD-7), not by producers — matches eviction-order rule 3. Evicted items spill to .context/decisions-<run_index>.jsonl."
        items:
          type: object
          required: [id, summary, ref]
          properties:
            id: { type: string }
            summary: { type: string, maxLength: 160 }
            ref: { type: string }
```

#### facts — open_questions

```yaml
# …continued: WorktaskStateLedger.properties.facts.properties
      open_questions:
        type: array
        maxItems: 4   # per task — no global ceiling
        description: "Bounded (B3): newest 4 per task, keyed by the TASK_ID in the item's own `sw-<TASK_ID>-<n>` id, `status: resolved` evicted first inside each bucket. 4 equals the per-stage emission ceiling, so a conforming writer never spills. Clamped at state-patch.sh atomic_merge() (AD-7); evictions spill to open-questions-<run_index>.jsonl."
```

##### facts — open_questions, the item shape

```yaml
# …continued: facts.open_questions
        items:
          # Mirrors $defs/SweepStub — the only accepted item shape here too, so the
          # ledger and the frontmatter cannot disagree about what an entry is.
          type: object
          required: [id, class, ref, blocks_next_stage]
          properties:
            id: { type: string, pattern: '^sw-[A-Z]{2}[0-9]+-[0-9]+$' }
            summary: { type: string, maxLength: 160 }   # OPTIONAL; the body is canonical
            stage: { type: string }                     # bare CODE, for FN-gate grouping
```

##### facts — open_questions, the partition key

The clamp's partition key is derived from the item's id, not from `stage`: `stage` is the bare
code the FN gate groups by, and grouping is not partitioning. Breaking for in-flight ledgers — no
migration, no tolerant reader.

##### facts — open_questions, the ledger-only fields

```yaml
# …continued: facts.open_questions.items.properties
            class: { type: string, enum: [decision, escalate] }
            ref: { type: string }
            # q9 carrier: this item is answered at its own stage boundary, not held
            # to the FN gate. See $defs/SweepStub for the raise-only rule. This value must
            # equal the frontmatter stub's — a divergence fails check_sweep_ledger.
            blocks_next_stage: { type: boolean }
```

###### facts — open_questions, the answer fields

```yaml
# …continued: facts.open_questions.items.properties
            # Read by eviction rule 2 and by the render, so an answered item is not
            # re-prompted on a resumed run. `open < resolved` is a monotone join at
            # the union (state-patch.sh): a later write may raise, never downgrade.
            status: { type: string, enum: [open, resolved] }
            # Where a sweep answer lands; not facts.decisions[] (stage-contracts.md
            # § Closing Elicitation Sweep says why).
            resolution: { type: string, maxLength: 160 }
```

#### facts — verdicts, files_read

```yaml
# …continued: WorktaskStateLedger.properties.facts.properties
      verdicts:
        type: object
        additionalProperties: { type: string }
        description: "Keyed by task id (DV0, DV1) plus a derived stage-code key (DV) holding the worst verdict among that stage's reported tasks — see field notes"
      files_read:
        type: array
        maxItems: 30
        description: "Source files read by prior stages; DR/QA prefer git diff. Newest 30 survive, clamped in the state-patch.sh bounds filter — see field notes"
        items:
          type: object
          required: [path, stage]
          properties:
            path: { type: string }
            stage: { type: string, enum: [PL, AR, TL, DV, DR, SR, QA, DC, RE, FN, ST, IR, ET] }
            lines: { type: string, description: "'all' or '<start>-<end>'" }
```

#### facts — dispatched_agents

```yaml
# …continued: WorktaskStateLedger.properties.facts.properties
      dispatched_agents:
        type: array
        maxItems: 6
        description: "OPTIONAL (additive) — see field notes. Bounded (B3): 6 survive — the newest 6 launched first, free slots filled by the newest non-launched, survivors in original order. Clamped in the state-patch.sh bounds filter (AD-7)."
        items:
          type: object
          required: [stage, task_id, subagent_type, status]
          properties:
            stage: { type: string, description: "stage CODE (DV, DR, …)" }
            task_id: { type: string, description: "Ledger key (e.g. DV0) — the dedupe key" }
            subagent_type: { type: string, description: "resolved plugin:agent id" }
```

#### facts — dispatched_agents (continued)

```yaml
# …continued: dispatched_agents.items.properties
            agent_id: { type: string, description: "OPTIONAL launch-ack id when the runtime surfaces one (background-default dispatch); resume degrades to best-effort subagent_type match when absent; for an in-process teammate it is the agent ID, its name@team address is teammate_id (CC 2.1.290)" }
            name: { type: string, description: "OPTIONAL named-spawn handle (megatask lanes); readable default names, /rename persists across restarts" }
            model_requested: { type: string, description: "OPTIONAL — metadata.model alias at dispatch" }
            model_resolved: { type: string, description: "OPTIONAL best-effort — model that actually ran (claude agents --json / audit); omit when unknown" }
            status: { type: string, enum: [launched, completed, failed] }
```

#### facts — capabilities

```yaml
# …continued: WorktaskStateLedger.properties.facts.properties
      capabilities:
        type: object
        description: "OPTIONAL (additive); probe cache for account-level hard-fails — see field notes"
        additionalProperties: true
```

#### handoffs

```yaml
# …continued: WorktaskStateLedger.properties
  handoffs:
    type: object
    additionalProperties:
      type: string
      maxLength: 300
      pattern: '.*ref:.*'
```

#### Field notes — handoffs (edge registry)

Keys are `<PREV_CODE>→<TASK_ID>`: the source side is the predecessor's bare stage code, the
destination side is the writing task's own id (`TL→DV1`, not `TL→DV`), because a split stage has
one writer per task and a shared key would let their edges overwrite each other. There is no
migration and no tolerant reader: an old-shape key reads as absent, which forces a logged re-merge
rather than a silent mis-parse.

##### Reading the edge tables

The tables below name edges, so their rows stay stage-level and are read with one rule applied:
the destination is written as the writing task's id, so a split stage contributes one row per task.
The rows are not enumerated per task — PL0 sizes each split per run.

PL0 sizes the stage set, so several stages have more than one possible predecessor — the edge
written is the one whose when-clause holds. A stage that never ran never appears in an edge label; a
"phantom edge" for an absent stage is a ledger defect.

The tables are exhaustive across all three pipelines (standard, secure/full, emergency). The
emergency pipeline (`IR→DV→DR→QA→RE→FN`) has no PL, AR or TL stage, so DV's predecessor there is
`IR` and RE's is `QA`. RE's predecessor is also `QA` on a standard, secure or full run that
excluded DC. Any predecessor not listed is not a legal edge; add a row before writing one.

##### Edge table — standard and secure pipelines

| Edge | When | Written by |
|------|------|-----------|
| `USER→PL` | always (standard/secure) | PL |
| `PL→AR` | AR is in the plan | AR |
| `AR→TL` | TL is in the plan AND AR ran | TL |
| `PL→TL` | TL is in the plan AND AR was excluded | TL |
| `TL→DV` | TL ran | DV |
| `AR→DV` | AR ran AND TL did not | DV |
| `PL→DV` | neither AR nor TL ran | DV |
| `DV→DR` | always (DR is a floor stage) | DR |
| `DR→SR` | SR is in the plan | SR |
| `SR→QA` / `DR→QA` | SR ran / SR was excluded | QA |
| `QA→DC` | DC is in the plan | DC |
| `DC→RE` | RE is in the plan AND DC ran | RE |
| `QA→RE` | RE is in the plan AND DC was excluded | RE |
| `RE→FN` | FN is in the plan AND RE ran | FN |
| `DC→FN` | FN is in the plan AND DC ran AND RE did not | FN |
| `QA→FN` | FN is in the plan AND neither RE nor DC ran | FN |
| `FN→ST` | ST is in the plan AND FN ran | ST |
| `RE→ST` / `DC→ST` / `QA→ST` | ST in plan, FN not run: latest of RE, DC, QA that ran | ST |

##### Edge table — what "ran" means

A stage ran when its `tasks` row exists and is not `skipped`. With FN and ST both excluded, no edge
names FN: the run ends on the edge into the last stage that ran.

##### Edge table — emergency pipeline and the ethics gate

| Edge | When | Written by |
|------|------|-----------|
| `USER→IR` | always (emergency pipeline) | IR |
| `IR→DV` | emergency pipeline — no PL/AR/TL stage exists | DV |
| `QA→RE` | emergency pipeline (RE's predecessor is QA, not DC) | RE |
| `<invoker>→ET` | the ethics gate fired; `<invoker>` is whichever stage triggered it | ET |

The writer passes its predecessor to `state-patch.sh --stage <CODE> --prev <PREV>` (plus
`--task-id <TASK_ID>` in a fan-out); the script composes `<PREV>→<TASK_ID>` mechanically and knows
none of the when-clauses. `USER` is a predecessor
only: it owns no artifact and is never a valid `--stage`.

#### #layer-1-fallback

Every stage agent's State Patch section points here. Three outcomes, in order.

1. Exit 3 — `--prev` given, `--via` absent, no artifact resolved: the self-patch signature.
   The stage claims an artifact that is not on disk. Write it and re-run. If you cannot, use
   item 2 — `--allow-missing-artifact` only silences the error and patches nothing.
2. The tool cannot run at all (not granted, denied, not found). Do not skip silently.
   `Edit` `.context/state.json` directly: write both the `tasks.<ID>` completion entry and the
   `handoffs["<PREV>→<TASK_ID>"]` edge — the destination is your task id (`TL→DV1`), not the bare
   stage code — then record the failure under `metadata.pl_tooling_gaps`.
   The SubagentStop hook is not a substitute: it builds its args without `--prev`, so it
   repairs the stage entry and drops the edge.
3. `jq` or `.context/state.json` absent — skipping is correct here, and only here.

#### Field notes — progress

OPTIONAL. Budget-aware checkpoint for multi-batch stages (currently DV), written after each sub-batch commit so a budget-exhausted agent leaves a resumable record instead of a progress narration. The orchestrator reads `next_batch` to resume where the stage stopped (`agents/developer.md § Budget-Aware Checkpointing`; `skills/worktask/SKILL.md § Orchestrator Execution Loop` step 4.7). Batch ids only — never diffs, file contents, or test output.

#### Field notes — completed_via

OPTIONAL (additive). Which enforcement layer stamped this stage `completed`: `hook` = SubagentStop delegation (Layer 2, `state-merge.sh` default); `step6_5` = orchestrator synchronous Step-6.5 (`STATE_MERGE_VIA=step6_5`); `f3` = orchestrator F3 minimal-patch fallback. Absence encodes a Layer-1 agent self-patch: the hook's idempotency check exits before writing when Layer 1 already landed. Observability only; no consumer branches on it.

#### Field notes — last_error

OPTIONAL (additive). Written by the orchestrator Step-6.5 errored-return branch (errors propagate with partial work) before routing to the retry matrix. `class` reuses the taxonomy in `agent-coordination § Retry / Escalate Matrix` — no new vocabulary. Dropped once the stage reaches `status: completed` (eviction rules).

#### Field notes — worktree

OPTIONAL (additive; DV primarily). Records which worktree the stage ran in, not just `worktree: true`. Written by mapping the DV handoff frontmatter `worktree_path`/`worktree_branch` (`state-patch.sh`). Lets resume re-enter the exact worktree via `EnterWorktree(path)`, DR/QA run in the right dir, and FN carry PR context. The PR *head* comes from `facts.branch`, not here (disambiguation below). Kept through FN; dropped at archival.

#### Field notes — tests_executed, rework_runs

OPTIONAL (DV and QA rows), written only by `state-patch.sh`. The completion merge mirrors the artifact's `handoff.tests_executed` list into `tests_executed`, and drops the key when the artifact carries none. `--task-replay` sets `rework_pending: true` on a row that holds `tests_executed`; the next completion merge appends `{round: <last round + 1>, tests_executed: <the row's previous list>}` to `rework_runs`, deletes the marker, then mirrors the new list. Entries are never rewritten, so an artifact carries only its own round and no stage copies an earlier one forward. A re-merge of the same artifact without a replay appends nothing, and a blocked round resumed through `--claim` stays one round.

##### Field notes — rework_runs, where no round is filed

Without `yq` the merge cannot parse the list, so it leaves the mirror and the marker as they were. The Edit-direct fallback (`#layer-1-fallback`) does not maintain these keys: leave `tests_executed`, `rework_runs` and `rework_pending` untouched and never write a round by hand; the next scripted completion files it.

#### Field notes — branch

OPTIONAL (additive). The worktask's planned working-branch name — the host-session branch as
`branch-name.sh` left it at the start of PL, whether it renamed it or found it already
conventional. Written at PL start, rewritten at most once at `commands/worktask.md § Step A.4b`
before any commit exists, and never by a stage (`skills/shared/git-conventions.md § Once-only
rule`). FN uses it as the pull-request head, reading the ledger rather than `git rev-parse` so an
external mid-run rename surfaces as a mismatch instead of retargeting the PR. Not the same field as
`tasks.DV0.worktree.branch` (disambiguation below). Kept through FN; dropped at archival.

##### Field notes — branch, divergence from the local branch name

`facts.branch` may legitimately differ from `git rev-parse --abbrev-ref HEAD` on the
`upstream_tracked` and `target_exists` arms, and inside a linked worktree under
`BRANCH_NAME_WORKTREE_RENAME=0` — there `branch-name.sh` keeps the host's local name and returns
the derived `target_branch=` for the PR head, so the host's branch↔workspace mapping survives
(`workspace-modes.md § Host mapping — updated, not preserved`). On the default worktree path
the branch is renamed and the two agree.

Divergence is observed, not merely tolerated: `fn-preflight.sh branch-divergence` classes it
`expected` or `third_party` and surfaces only `third_party` at the FN gate; its comparison base is
the `to` of the last `branch_renamed / ok` row, not this field. No reader may "repair" it by
re-deriving from the local branch — the ledger value is the planned name, and the PR head is what
it plans.

##### Field notes — branch, empty value

`branch-name.sh` prints `branch=` (empty) for a detached HEAD or not-a-git-repo — never the
literal `HEAD`, which is not a branch. FN treats an empty `facts.branch` as "no planned name
to push under": skip the `git push -u origin HEAD:refs/heads/<facts.branch>` refspec entirely and
fall back to a plain `git push -u origin HEAD`. On a detached HEAD that fallback fails loudly
("The destination you provided is not a full refname") — an acceptable failure: no wrong target,
no silent error.

##### Disambiguation — `facts.branch` vs `tasks.DV0.worktree.branch`

Two fields, disjoint definitions, neither derived from the other:

| | `facts.branch` | `tasks.DV0.worktree.branch` |
|---|---|---|
| Meaning | planned host-session branch name | observed branch of the worktree DV ran in |
| Writer | orchestrator, from `branch-name.sh` stdout, at PL start; then `refine-branch-target.sh` at Step A.4b | `state-patch.sh`, from DV handoff `worktree_branch` |
| Written when | before any commit exists | after DV completes |
| Rewritten | at most once more, pre-commit (§ Step A.4b); never by a stage | per DV re-dispatch |
| FN uses for | the PR head | worktree re-entry context only |

##### Disambiguation — topology note

They are equal in the common topology where the session's workspace is the worktree
(`agents/developer.md § Field notes — worktree fields`), and differ when DV created a fresh
`.claude/worktrees/` worktree whose branch the tool named itself. A mismatch is information,
not an error: it tells FN the commits live somewhere other than the planned branch, exactly
what `fn-preflight.sh continuity` handles. No writer copies one into the other.

#### Field notes — stream_branches

OPTIONAL (additive). Present only after the FN multi-stream arm committed each stream: the branch
each stream's commit sits on, keyed by `tasks.DV<k>.metadata.stream`. `fn-stream-merge.sh merge`
merges each value into `facts.branch` and blocks on a missing key; `fn-preflight.sh continuity`
switches to its per-stream ancestor check once the object holds ≥2 keys. It is not the PR head —
`facts.branch` stays that — and no writer copies a value from one into the other.

#### Field notes — goal

One-sentence worktask intent, populated by PL0 from the task description (or the issue title under `/megatask`). Read by stages needing the original intent without re-reading the plan file (AR sanity-checking architecture against requirements, FN composing the PR title). Single surface for this value — do not introduce a parallel one.

#### Field notes — files_read

Source files read by prior stages. Populated by DV; consumed by DR/QA, which use `git diff <base>..HEAD -- <path>` instead of `Read <path>` for any file listed. Full reads stay permitted when the diff is insufficient. Absent ⇒ normal reads.

Second reader: the stale-settlement check reads it as half of a dependent's cited set (§ tasks — settle, the cited set and the change set — invocation and table).

Scripted writer: `state-patch.sh --files-read <TASK_ID> <path>...` unions `{path, stage, lines: "all"}` — `stage` is the code of `<TASK_ID>`, a leading `./` is stripped, and the newest entry wins per path. A path that is empty, longer than 512 characters, or holds a TAB/CR/LF fails the whole call (exit 2). Past 30 entries the oldest are dropped without a spill file: this is a read hint, not a record.

#### Field notes — verdicts

`facts.verdicts.<TASK_ID>` is the verdict each task reported; `facts.verdicts.<CODE>` is derived in the same atomic write as the worst verdict among the `<CODE>N` rows that carry one (rows with no verdict yet are ignored, a tie goes to the highest `N`). Rank, worst first: `escalate` > `blocked` > `fail`|`reject`|`no-go` > `ok`|`pass`|`go`|`approve`; a legacy stored string outside the map ranks with `fail`. `blocked` outranks `fail` because it needs outside input while the loop repairs a `fail` itself. Existing `.DR`/`.QA`/`.DV` readers keep working unchanged. `--task-replay` keeps a row's verdict, so the stage key stays stale until that row is patched again.

#### Field notes — dispatched_agents

OPTIONAL (additive). Writer: the orchestrator loop only, through `state-patch.sh --dispatch <TASK_ID> <agent_id> <launched|completed|failed>`, which derives `stage` from the id and `subagent_type` (plus `model_requested` when set) from the row's `metadata.agent`/`metadata.model` — a row without `metadata.agent` is refused (exit 2). On Codex, the unchanged `agent_id` field holds the returned agent id when available, otherwise the exact canonical task name (`/root/...`). One entry per `task_id` (not per stage — parallel DVN tracks share the stage code): the same `agent_id` updates in place, a different one replaces the entry at the tail; dispatch history stays in `audit.jsonl`. Read by resume (`resume.md` step 0) to reconcile against the active host adapter. No dispatch timestamp is stored (host agent rows carry their own). Terminal entries (`status: completed|failed`) are eviction candidates.

#### Field notes — capabilities

OPTIONAL (additive). Probe cache for account-level hard-fails, so later stages do not re-hit the same error. Written by the orchestrator on first observed failure; model resolution consults it before any fable-tier dispatch. Example: `{ "fable_dispatch": "credit_blocked", "checked_at": "<ISO>" }` — Fable 5 is 1M-by-default but *dispatch* fails hard without 1M credits (model-selection.md).

### Eviction order on overflow

When state.json approaches the 500-token cap:

1. Drop `tasks.<ID>.artifact` paths for stages with `status=completed` once their `handoffs` edge string captures the essentials.
2. Drop `facts.open_questions` whose status is resolved (the newest-4-per-task clamp applies the same preference automatically at every write, inside each task's bucket).
3. Drop `facts.decisions` older than 2 stages back (keep current + previous stage decisions).
4. Drop `facts.files_read` entries whose `stage` is older than 2 stages back.

#### Eviction steps 5–8

5. Drop terminal `facts.dispatched_agents[]` entries (`status: completed|failed`) — live-agent reconciliation no longer applies; history persists in `audit.jsonl`.
6. Drop `tasks.<ID>.last_error` + `completed_via` once the stage is `completed` (error resolved; provenance was observability-only).
7. Keep `tasks.<ID>.worktree` through FN (PR context needs the branch); drop at archival.
8. Never store diffs, file contents, or test output. Fetch from git/disk on demand.

### PL0 seed (initial state) {#pl0-seed}

`commands/worktask.md` Phase 1 Step 3a writes the initial ledger by running
`skills/worktask/scripts/seed-state.sh`, the seed's only definition (next free planning index `N`
from `.context/planning-*.md`, `0` on a fresh `.context/`; goal escaping and truncation; atomic
write). This section keeps only the resulting shape.

#### Seed shape (resulting JSON)

`plan_file` here is the path shape; task metadata carries the basename (§ plan_file shape
boundary).

```json
{
  "version": 2,
  "worktask_id": "<from task metadata>",
  "plan_file": ".context/planning-${N}.md",
  "platform": "all",
  "run_index": ${N},
  "metadata": { "workspace_path": "<absolute worktree root>" },
  "tasks": {
    "PL0": { "status": "in_progress" }
  },
  "facts": {
    "goal": "<one-sentence intent — first 240 chars of task.description or issue title>",
    "files_modified": [],
    "tests_added": [],
    "decisions": [],
    "open_questions": [],
    "verdicts": {},
    "dispatched_agents": []
  },
  "handoffs": {}
}
```

#### Additive-field seeding

The seed includes `facts.dispatched_agents: []` (additive) so the orchestrator loop
appends/replaces per-`task_id` entries in place instead of lazily creating the array. The other
additive fields (`tasks.<ID>.completed_via`/`last_error`/`worktree`, `facts.capabilities`) are
written on demand and are not seeded, because their absence is meaningful (Layer-1 self-patch, no
error, no worktree record, no observed capability hard-fail).

On a new run in an existing `.context/`, `seed-state.sh` refuses (exit 3) and leaves
`state.json` byte-unchanged; it has no overwrite path. Step 3a only reopens PL0
(`--task-status PL0 in_progress`). PL0's `pl0-procedure.md § Step 4 — state.json reset` is the
sole reset writer: `run_index = N`, `plan_file`, `tasks` reset to `{PL0: in_progress}`, `facts.*`
emptied. Historical run data lives in the on-disk `<stage>-N.md` artifacts, not in state.json.

---

## #fallback-paths

Three documented degradation paths. The ledger itself is not one of them: `state.json` is
mandatory, and its absence is a hard failure rather than a recoverable mode.

| Path | Trigger | Behavior |
|------|---------|----------|
| F2 | state.json present, agent ignores it | No penalty. Agent reads the anchors it was given and writes its artifact. Orchestrator's hook patches state.json from frontmatter; with no frontmatter (F3) nothing is patched. |

### Paths F3–F4

| Path | Trigger | Behavior |
|------|---------|----------|
| F3 | Agent writes artifact without frontmatter | Orchestrator logs WARN `frontmatter missing in <artifact>`. No handoff is derived and nothing is written: `state-patch.sh` refuses a missing verdict with exit 3 and `state.json` unchanged. The row stays `in_progress`, and `skills/worktask/SKILL.md § Step 6.5a2` resumes the stage. |
| F4 | state.json corrupt (invalid JSON or schema mismatch) | Back up to `.context/state.json.corrupt.<iso-ts>`. Rebuild the skeleton only, then recover exactly the one stage being patched by delegating to `state-patch.sh` unchanged. Audit row `state_repair` in `.context/logs/audit.jsonl`. Continue. |

#### F4 — partial recovery, by design {#f4-partial}

Three intended behaviours, not defects:

- The backup is `.context/state.json.corrupt.<iso-ts>`, so sorting by name sorts by time and the
  suffix says what happened.
- The audit trail is the `state_repair` row in `.context/logs/audit.jsonl`; there is no separate
  recovery log.
- There is no completed-stage frontmatter walk. The hook rebuilds the skeleton (including an empty
  `tasks: {}`) and recovers only the stage whose patch triggered the repair, because a full walk
  would be a second, divergent artifact parser beside `state-patch.sh`'s.

#### F4 — consequences for readers {#f4-consequences}

A repaired ledger can legitimately show fewer completed stages than `.context/` contains —
earlier stages are not replayed. Reconstruct history from the artifacts, not the ledger.

Fail-safe: if the backup cannot be written (unwritable `.context/`), the repair aborts,
`state.json` is left byte-identical, no backup and no audit row are written, and the hook still
exits 0. Corrupt-and-untouched is the designed outcome; an unchanged ledger is not evidence the
hook failed to run.

#### The ledger is mandatory {#f1-fallback}

The handoff mode is anchor-based: a stage reads `.context/state.json` plus the anchors named in
`metadata.context_refs` (≥30% input-token reduction, cache-friendly preamble).

There is no whole-file fallback list. If `state.json` cannot be read, the stage stops and reports
rather than guessing at its inputs. A read-only or unwritable `.context/` is an environment defect
to fix, not a mode to accommodate.

### F4 regeneration walk

Manual rebuild only — the hook never walks (`#f4-partial`). Runbook: `agents/workflow-engineer.md`.

1. Glob every canonical artifact basename (`#stage-artifact-map`) as `<basename>-*.md`.
2. Extract `handoff:` frontmatter from each (yq or fallback parser).
3. Sort by stage order: PL, AR, TL, DV, DR, SR, QA, DC, RE, FN, ST, IR, ET.
4. Seed state.json from PL0's frontmatter.
5. Per subsequent stage, merge `tasks.<ID>` and add `handoffs["<PREV_CODE>→<ID>"]` — one edge per
   task, so a split stage contributes one per stream.
6. Atomic-write per `#atomic-write`.

---

## #stage-artifact-map

Canonical mapping from stage code to artifact filename (used by orchestrator, hook, and F4 regeneration walk).

All stage artifacts are numbered; N is allocated by PL0 (same value as `planning-N.md`) and propagated via `task.metadata.run_index`. Readers fall back to newest-glob (`<basename>-*.md`).

| Stage code | Artifact filename | Plural? |
|------------|-------------------|---------|
| PL | `planning-N.md` (N starts at 0) | yes |
| AR | `architecture-N.md` | yes |
| TL | `coordination-N.md` | yes |
| DV | `development-N.md` (per DV ledger task: `development-N-<stream>.md`) | yes |
| DR | `developer-review-N.md` | yes |
| SR | `security-review-N.md` | yes |
| QA | `testing-N.md` | yes |
| DC | `documentation-N.md` | yes |
| RE | `release-N.md` | yes |
| FN | `complete-summary-N.md` | yes |
| ST | `retrospective-N.md` | yes |
| IR | `incident-N.md` | yes |
| ET | `ethics-review-N.md` | yes |

### DV fan-out — ledger tasks

DV fans out as ledger tasks, never as sub-agents. `DV0`, `DV1`, … are rows in `state.json`: the
orchestrator dispatches each on its own `Agent()`, each writes its own artifact, each patches its own
row. No entry agent assembles a canonical file afterwards — every DV artifact is a handoff carrier
in its own right, and downstream stages reach them by iterating the rows.

Retries are per row (`retry_count`); every row appends to the shared
`.context/errors/developer.md` under its own `## DV<k> Retry <n> — …` heading.

#### Pinning a row's tree

Every DV row carries `metadata.workspace_path` from creation (`state-patch.sh --task-create` refuses
one without it; a TL stream clones DV0's), and the row's agent enters that path and no other.

An explicit `WORKSPACE_ROOT` that resolves to the orchestrator root marks a pinned session. A
linked worktree alone does not. In that mode, shared-tree DV streams run in numeric row order.
Before dispatch, the orchestrator blocks each later independent row on the nearest earlier row,
then rechecks the row's readiness because the ready list predates the block. It keeps both rows on
the assigned session tree and does not create stream worktrees. Existing transitive ordering stays
intact, and repeat dispatch adds no dependency.

Without that session pin, a DV row with `metadata.stream` gets its own stream worktree when another
DV row holds the same `metadata.workspace_path` and neither row reaches the other through `blocked_by`.
The orchestrator creates the tree, re-stamps `metadata.workspace_path` through
`state-patch.sh --task-meta`, and then renders the banner. Already serialized streams may share
one tree. Landing of declared `consumes` runs after either path selects its final tree.

#### Artifact naming (S1)

```text
artifact  := ".context/development-" N [ "-" stream ] ".md"
N         := tasks.<ID>.metadata.run_index          # integer >= 0
stream    := ^[a-z0-9]+(-[a-z0-9]+)*$               # kebab, <= 40 chars, unique among the DV rows
source    := assigned by the row's creator: PL0, TL when TL runs, or the DV agent that splits its
             own row (it stamps that row too); a stamped stream never changes
row keys  := tasks.DV<k>.metadata.stream   = "<stream>"
             tasks.DV<k>.metadata.artifact = ".context/development-<N>-<stream>.md"  # planned
             tasks.DV<k>.artifact          # recorded at completion; beats the planned value
rule      := >= 2 DV rows -> every DV row carries stream + artifact
             exactly 1 DV row -> stream MAY be omitted, artifact development-<N>.md
location  := the ledger's .context/ (the dir holding state.json), never a stream tree's
```

##### Finding the ledger from a stream tree

A DV working in a separate stream tree finds the ledger's `.context/` through
`skills/shared/scripts/resolve-root.sh` once no declared root (`--state`, `CONTEXT_DIR`) names it:
with no flag the script prints the main worktree's `.context` directory (exit 1 outside any
repository, 3 when the main worktree is bare).

##### The bare name is a grammar output

`development-<N>.md` is what the grammar emits for a single-DV run; it is not a name other text may
spell. Downstream templates and readers take DV artifacts from `refs.dev[]` or from the ledger
(§ Iterating the DV tasks), so that name reaches them only as an already-resolved list element.

#### Completing a DV row

The completion patch names both the row id and the path, because the orchestrator's basename guess
cannot see a stream suffix:

```bash
state-patch.sh --stage DV --task-id DV<k> --prev <PREV> \
  --artifact .context/development-<N>-<stream>.md
```

#### Iterating the DV tasks

Every downstream reader resolves its DV inputs from the ledger, in ascending numeric task-id order:

```bash
jq -r '.tasks | to_entries
  | map(select(.value.metadata.stage == "DV" and (.key | test("^DV[0-9]+$"))))
  | sort_by(.key | ltrimstr("DV") | tonumber)
  | .[] | (.value.artifact // .value.metadata.artifact // empty)' .context/state.json
```

Review diff source: the diff for those rows comes from `skills/worktask/scripts/stream-diff.sh`
(same order, one labelled block per row, base from `resolve_base_ref`), never a hand-written range.

A `refs.dev[]` element (`stage-contracts.md#tpl-dr`) is that path's basename plus `#files-changed` —
replace the last line with:

```bash
  | .[] | ((.value.artifact // .value.metadata.artifact // empty) | split("/") | last) + "#files-changed"
```

#### Landing consumed artifacts

One DV row can consume a file another DV row produces, such as an interface contract, without the
producer committing it. The rows declare the pair with `produces` and `consumes`
(`skills/shared/state-ledger.md § Landing fields (DV rows)`):

```text
produces := tasks.<P>.metadata.produces = [path, ...]
consumes := tasks.<C>.metadata.consumes = [{"from": "<P>", "paths": [path, ...]}, ...]
path     := repo-relative, post-merge; alphabet [A-Za-z0-9._@+/-]
rule     := C.blocked_by holds every from, and every path is in that producer's produces
writer   := PL0, or TL when TL runs; never the DV agent
source   := P's index blob: P runs `git add -- <path>` per produced path before its completion patch
```

C treats a landed path as read-only and never edits or stages it, because P's tree ships it.

##### Landing — the two passes

`skills/worktask/scripts/land-artifacts.sh` runs from two points in `skills/worktask/SKILL.md`:

| Pass | Where | Call | Effect |
|---|---|---|---|
| Boundary | § Step 6.5d, once P is `completed`, before the next ready-filter pass | `--producer P` | Lands into every `pending` consumer's current tree; skips a `blocked` one, keeping its `landing_error`, and leaves any other status untouched with one `warn` row |
| Gate | § Step 4.8, after any re-pin, before Step 5 stamps `in_progress` | `--consumer C` | Re-lands every pair of C into its final tree; an unchanged tree is a no-op that writes nothing |

When P and C resolve to the same physical tree nothing is copied and no `landed_paths` are
recorded; a boundary pass still writes its `same_tree` ok row.

##### Landing — what one consumer's pass does

1. **Preflight.** Every path of every pair of C is checked before the first write, so C lands all or
   nothing.
2. **Source.** Exactly one stage-0 index entry in P, mode `100644` or `100755`, no filter attribute,
   no symlink on its way, and a worktree file unchanged since `git add`.
3. **Destination.** Under C's physical root, every parent a real directory, the file untracked. A
   tracked file is refused unless byte-identical (`already_present`, not recorded). An untracked one
   with a different sha is refused unless C's `landed_paths` already lists it (a producer re-run).
4. **Write.** The blob goes to a temp file beside the destination, is checked against its git
   object id, then renamed into place and re-verified by sha256.
5. **Record.** `landed_paths` and `landed_roots` (every spelling of C's tree) become sorted unions;
   `landing_error` `null`.

A refusal rolls back only files and directories this pass created.

##### Landing — refusal reasons

Each refusal writes exactly one `reason` into `landing_error` and the fail row:

| Check | Reasons |
|---|---|
| Pair | `consumer_already_dispatched` (gate only), `producer_not_completed`, `not_blocked_on_producer`, `self_consume`, `bad_declaration`, `not_produced` |
| Path shape | `bad_path`, `absolute_path`, `dotdot`, `reserved_segment`, `reserved_destination`, `control_char`, `leading_dash`, `unsafe_char` |
| Source | `symlink_source`, `gitlink`, `not_staged`, `conflicted`, `filtered_path`, `staged_then_modified` |
| Destination | `symlink_segment`, `not_dir`, `dest_escape`, `symlink_dest`, `dest_not_regular`, `dest_tracked`, `dest_exists` |
| Copy | `sha256_mismatch`, `dest_race` |
| Any git read | `git_error`, the read failed |
| Gate, exit neither 0 nor 1 | `tool_error`, written by the orchestrator |

###### Landing — reserved names

`reserved_segment` is a segment equal to `.git` or `.context`; `reserved_destination` is one equal to
`.claude`, `.github`, `.mcp.json`, `.envrc`, `.gitattributes` or `.gitmodules`. Both compare
case-insensitively.

##### Landing — exits and the audit row — exit codes

| Exit | Meaning |
|---|---|
| `0` | Landed, same tree, already present, gate no-op, nothing selected, or a consumer a boundary pass skips: `blocked` silently, any other non-`pending` status with one `warn` row |
| `1` | Consumer failed: rolled back, `landing_error {reason, path, producer}` written, row `blocked`, one fail row |
| `2` | Usage error, malformed id, bad ledger, `tree_invalid`, missing tool, failed ledger write, or signal (INT, TERM, HUP). Rolls back writes; ledger entry for completed C stays: `blocked` row fails closed, `landed_paths` entry re-copied next pass |

##### Landing — exits and the audit row — exit 1 guarantee

No other exits exist: signals/unexpected failures exit `2`, never stray `1`. Exit 1 always means `landing_error` on `blocked` row, or refused `--check-path`/unsafe `--strict` (§ Landing — strict readers).

###### Landing — the audit row

Each row is `corpflow_audit_row` with actor `orchestrator`, action `contract_landed`, subject C:

```text
ok:   {"producer":"DV0","consumer":"DV1","mode":"copied","files":[{"path":"src/api.h","sha256":"<hex>"}]}
warn: {"producer":"DV0","consumer":"DV1","reason":"consumer_not_pending","status":"completed","paths":["src/api.h"]}
fail: {"producer":"DV0","consumer":"DV1","reason":"dest_tracked","path":"src/api.h"}
```

`mode` is `copied`, `same_tree` or `already_present`. A lost audit row warns on stderr and never
changes the exit code.

###### Landing — a consumer that already ran

A producer re-run, such as a DR rework, can reach a consumer that is `in_progress`, `completed`,
`failed` or `skipped`. A boundary pass writes no file and no ledger field for that row, exits 0, and
writes the one `warn` row above, so a rework never flips a dispatched stream to `blocked`. The gate
still refuses such a row with `consumer_already_dispatched` (exit 1). `--dry-run` writes no row.

##### Landing — release and readiness

On a gate exit other than 0 or 1 the orchestrator writes `landing_error {reason: "tool_error"}`,
then `--task-status C blocked`; at the boundary that exit is reported only. Release, once the cause is fixed:

```bash
state-patch.sh --task-meta C --set '{"landing_error":null}'
state-patch.sh --task-status C pending
```

Until then C is not ready: the ready filter (`skills/worktask/SKILL.md § Readiness is mechanical`)
selects `pending` rows only, so for a `blocked` C this prints nothing:

```bash
jq -r --arg c DV1 '.tasks as $t | $t | to_entries[]
  | select(.value.status == "pending")
  | select([(.value.blocked_by // [])[] | $t[.].status] | all(. == "completed"))
  | .key | select(. == $c)' .context/state.json
```

##### Landing — strict readers

`land-artifacts.sh --list-landed --tree <tree> --strict` prints the same set as the plain call
(`skills/shared/state-ledger.md § The landed set`), but exits 1 with empty stdout when any raw
`landed_paths` entry scoped to that tree fails the path ladder: not a string, a control character,
or a lexical refusal (§ Landing — refusal reasons). The script never writes such an entry, so one
means a hand-edited ledger, and a strict reader fails closed instead of dropping it. Two readers are
strict. `fn-stream-merge.sh` reads each stream's own tree set, never a union: an unsafe entry is
`blocked reason=landed_path_unsafe`, a failed read `landed_set_unreadable`. The `blocked_on`
`artifact` arm reads the parked task's tree (§ Schema — blocked_on, the artifact arm's landed leg).
`--check-path <path>` runs the same ladder with no ledger, silent exit 0 when safe and exit 1 with
`reason=<token>` when refused; the router runs it on `detail.path`.

### Run-index resolution

The same N is shared across all stages within a worktask run. `metadata.plan_file` pins the active plan; `metadata.run_index` (integer ≥ 0) resolves `<basename>-N.md` for every other stage. Full resolver and propagation algorithm: `skills/worktask/references/pl0-procedure.md § Plan File & Run Index Naming`.

### Alias basenames (resolution-only)

`state-patch.sh` accepts a second, search-only basename for three stages — DR `review`, QA `qa`,
FN `finalization` — in a sibling function, so `#stage-artifact-map` stays the single canonical name
per stage. Aliases are accepted, never written, and a canonical match outranks an alias match at
the same run index. Resolution order: primary@run_index → primary highest-N → alias@run_index →
alias highest-N. `AR` has no alias, so a stale `analyzing` file cannot answer for the current
one. `USER` is a `--prev` value only — no
artifact, never a `--stage` or basename (edge tables: `USER→PL`, `USER→IR`).

---

## #cache-prefix

Anthropic prompt cache matches by prefix equality, not full-block equality, so the orchestrator builds the preamble in this order to maximize the byte-identical prefix shared across consecutive `Agent()` calls within one `worktask_id`.

### Preamble layout (binding)

```
<<<contract-reminder>>>
[1]  Plugin/agent contract reminder         ← stable across ALL stages
<<<worktask-header>>>
[2]  Worktask header (id, plan, exploration)← stable across ALL stages
<<<state-json>>>
[3]  Ledger pointer + readiness digest (from ledger-digest.sh) ← evolves per stage
<<<stage-contract>>>
[4]  Stage contract excerpt (this stage)    ← stable WITHIN stage type
<<<model-discipline>>>
[4b] Model discipline block                 ← stable WITHIN stage type
─────── (cache prefix boundary for sections 1+2+4+4b sharing) ───────
<<<task-description>>>
[5]  Task identifiers + ref: lines          ← dynamic per delegation
<<<retry-hints>>>
[6]  retry hints (if retry_count > 0); REMEDIATION block written by brief-compose.sh ← dynamic per delegation
<<<stage-banners>>>
[7]  Stage-specific banners (DR Skill, FN Conductor, MCP fallback) ← suffix only
```

### Section markers (binding)

Each section opens with its `<<<marker>>>` on a line of its own and runs to the next marker or
to the end of the prompt; there are no closing tags. The markers are required:

- The lint parses them. `cache-lint.sh` prefix mode extracts sections by marker, so the
  layout above is what makes an assembler's output checkable rather than guessed at.
- Section [3] needs its marker. Without `<<<state-json>>>`, [2] runs to `<<<stage-contract>>>`
  and swallows the digest, which evolves every stage — byte-identity then fails on a section that
  never changed. [3] itself is a ledger pointer plus a readiness digest, never the ledger JSON
  (§ Section [3] — ledger pointer and readiness digest).
- They separate instruction from data. [3] is a `key: value` digest and [5] is ledger-copied
  identifier and `ref:` lines, both sitting between blocks of instructions.

#### Section [3] — ledger pointer and readiness digest

Stage agents read `.context/state.json` from disk; [3] only tells them where it is and what is
ready. Grammar (exact key order, one `key: value` per line, no JSON, no timestamps):

```text
<<<state-json>>>
ledger: .context/state.json
run_index: <integer>
ready: <task ids, comma-separated, ascending key order | none>
in_progress: <ids | none>
blocked: <ids | none>
open_blocking_questions: <integer>
```

`skills/worktask/scripts/ledger-digest.sh` is the one executable copy: it prints this body without
the marker. `ready` is pending with every blocker completed, `blocked` is `status == "blocked"`,
and `open_blocking_questions` counts `facts.open_questions[]` with `blocks_next_stage == true` and
a `status` other than `resolved`.

### Section [4b] — model discipline block

Copied verbatim from `skills/shared/model-prompting.md`, selected by `task.metadata.model`. It
is inside the cache prefix for the same reason [4] is: a stage's model is fixed for the stage's
lifetime (`skills/shared/model-selection.md § Worktask stages: explicit, never inherited`), so
the block is stable within stage type even though it varies across the pipeline.

`haiku` has no block; its marker is emitted with an empty body rather than omitted, so the
section count does not vary by model.

The orchestrator copies this text and never composes it; `cache-lint.sh` catches a composed
block. Why the blocks live in one canon file rather than in the agent definitions:
`model-prompting.md § Why this lives at dispatch`.

### Section [5] — task identifiers and refs

`brief-compose.sh` writes [5]; the ledger's `task.description` is not copied into it — the agent
reads it from `.context/state.json` on disk, the file [3] points at. The section
is identifier lines copied verbatim from the ledger (`task_id`, `stage`, `agent`, `model`,
`artifact`, `subject`), then `ref:` lines only. A ref value has one of three shapes:

- `file:line` — plugin-root-relative, else under a `workspace_path`;
- `artifact#anchor` — an artifact in the resolved `.context` directory with a `## <anchor>` heading;
- a plain path to an existing file — from `metadata.context_refs` only.

A ref that does not resolve fails the compose with exit 1 and an empty stdout.

### Forbidden tokens in sections [1], [2], [4], [4b]

Anything below collapses cache-hit rate:

- Timestamps (`date`, `now`, ISO-8601 strings)
- ENV expansions that vary per call (`$HOSTNAME`, `$USER`, `$PWD` if it differs)
- Random IDs (UUIDs, `$RANDOM`, request IDs)
- Retry counters (move to section [6])
- File mtimes
- Agent-specific names beyond `worktask_id` (don't bake `software-architector` into [1] or [2]; that goes in [4])
- Conversation message IDs

### Required tokens in sections [1], [2], [4], [4b]

- `worktask_id` (string literal in [2])
- `plan_file` path (string literal in [2])
- Contract reminder text (section [1]) — drawn from `skills/worktask/references/contract-reminder.md`, copied verbatim
- Stage contract excerpt for this stage type (section [4]) — drawn from `skills/shared/stage-contracts.md`, copied verbatim
- Model discipline block for `task.metadata.model` (section [4b]) — drawn from `skills/shared/model-prompting.md`, copied verbatim

### Expected cache_read_input_tokens ratio

- Stage 1 (PL): 0% (cold cache).
- Stage 2..N, no retry: ≈ 20% (cross-stage prefix [1]+[2] cached).
- Stage 2..N, retry within same stage with the [3] digest unchanged: ≈ 80% (full preamble cached).
- [3] is six short lines, the first a pointer, so each stage prompt carries the digest in place of the ≤500-token ledger.
- Cross-stage average: ≈ 60%.

### Settings

```json
{ "env": { "ENABLE_PROMPT_CACHING_1H": "1" } }
```

Documented in `skills/cost-optimization/SKILL.md`. Without the 1h flag the default 5-min TTL applies: retries inside a stage still save, cross-stage cache is lost between long-running stages.

### Lint

`skills/worktask/scripts/cache-lint.sh` asserts byte-identity of sections [1]+[2] across consecutive stages of the same `worktask_id`, and of sections [4]+[4b] across calls sharing a `(worktask_id, stage)` pair. When a log line carries `model`, it also asserts that [4b] matches the block `model-prompting.md` carries for that alias — a stage dispatched on one model carrying another's block is a routing miss that byte-identity alone cannot see. Lines without the field skip that check, so an emitter that omits it leaves the check dormant. A line carrying `"contract_canon": true` opts in the same way for [1], which must then equal the fenced block in `contract-reminder.md`. Every line with a [3] section is checked for the `ledger: .context/state.json` first line, all six keys in order, and no embedded ledger.

`brief-compose.sh` is the assembler this spec binds; it writes no `prompt-log.jsonl`, so prefix mode stays fixture-gated.

#### Fixture-gated, not log-gated

Prefix-lint consumes a `prompt-log.jsonl` (`{worktask_id, stage, model, prompt}` per line, `model` being the resolved `task.metadata.model` alias) that nothing here emits — the live harness assembles prompts in `benchmark/harness/benchmarklive/dispatch.py` but persists only stage stdout — so it is exercised by `cache-lint.sh --self-test` fixtures. CI runs that mode on every PR (`.github/workflows/test.yml`), which gates the lint's own parser; no captured prompt is checked until an emitter exists.

---

## #anchor-allow-list

Every stage artifact carries its stage's required H2 anchors plus the universal one, and any other H2 only from the allowed and optional sets below. The tables are generated from `skills/worktask/scripts/cache-lint.sh` by `output-sections.sh --write`, which renders the same set into each stage agent's § Artifact anchors; `output-sections.sh --check` fails `make test` on drift. Enforcement runs at the write and at the stage boundary (§ Anchor Pre-Flight); no CI lint job runs anchor-lint mode.

### Anchors — required in every artifact

One anchor is universal: mandatory in all thirteen stage artifacts on top of that stage's own row below.

- `## elicitation-sweep` — the closing elicitation sweep's canonical transport (`skills/shared/stage-contracts.md § Closing Elicitation Sweep`), the target the frontmatter and ledger stubs point at by `ref`. It carries either the full items or the explicit empty statement; a stage with nothing to ask still writes the heading. Enforced by `cache-lint.sh --anchor-lint` for all 13 stages, with no grace for older artifacts.

### Anchors — allowed but never required

These anchors are allowed in every artifact and required in none, so none retroactively fails an artifact written before it existed and none is reported as unexpected:

- `## rework-<N>` — the scope-addition re-entry section the DR gate reads (`agents/technical-lead.md`).
- `## re-review` — a review stage's second pass over reworked output, recorded beside its original findings rather than overwriting them.
- `## design-preview` — PL's Figma capture block, written only when the task carries a Figma URL (`skills/shared/figma-capture.md`); absent otherwise.
- `## test-strategy` — PL's optional test-strategy section; `pl0-procedure.md` never mandates it.

### Anchors — PL to DR

<!-- output-sections:begin table=required-pl-dr -->
| Stage | Artifact | Mandatory H2 anchors |
|-------|----------|-----------------------|
| PL | planning-N.md | `## requirements`, `## acceptance-criteria`, `## scope`, `## out-of-scope`, `## risks`, `## complexity`, `## stages`, `## summary` |
| AR | architecture-N.md | `## decisions`, `## trade-offs`, `## patterns`, `## integration-points`, `## schemas`, `## open-questions`, `## risks` |
| TL | coordination-N.md | `## fan-out`, `## shared-snippets`, `## sequence`, `## risks` |
| DV | development-<N>[-<stream>].md | `## files-changed`, `## tests-added`, `## deviations`, `## follow-ups` |
| DR | developer-review-N.md | `## findings`, `## verdict`, `## blockers`, `## follow-ups` |
<!-- output-sections:end table=required-pl-dr -->

### Anchors — SR to ET

<!-- output-sections:begin table=required-sr-et -->
| Stage | Artifact | Mandatory H2 anchors |
|-------|----------|-----------------------|
| SR | security-review-N.md | `## findings`, `## verdict`, `## blockers`, `## threat-model` |
| QA | testing-N.md | `## results`, `## coverage`, `## regressions`, `## verdict` |
| DC | documentation-N.md | `## files-changed`, `## cross-references`, `## follow-ups` |
| RE | release-N.md | `## artifacts`, `## version`, `## rollback-plan` |
| FN | complete-summary-N.md | `## summary`, `## artifacts`, `## followups`, `## metrics` |
| ST | retrospective-N.md | `## decision`, `## learnings`, `## followups` |
| IR | incident-N.md | `## root-cause`, `## fix-plan`, `## blast-radius` |
| ET | ethics-review-N.md | `## findings`, `## verdict`, `## mitigations` |
<!-- output-sections:end table=required-sr-et -->

### Anchors — optional per stage

Allowed in that stage's artifact only, required in none; title-case entries are matched literally.

<!-- output-sections:begin table=optional -->
| Stage | Optional H2 anchors |
|-------|---------------------|
| AR | `## <Platform> App Architecture`, `## Test Architecture` |
| TL | `## Blockers` |
| DV | `## verification-command`, `## acceptance-commands`, `## decisions`, `## Blockers`, `## DV Completion Checklist` |
| QA | `## acceptance-commands`, `## Visual Evidence`, `## Design Comparison` |
| RE | `## Release Preparation Summary` |
| ST | `## Self-Improvement` |
| IR | `## Incident Report` |
<!-- output-sections:end table=optional -->

### Convention rules

1. H2 only. H1 is the artifact's title (exempt from anchor lint).
2. Kebab-case. No spaces, no underscores, no camelCase. The title-case optional entries above are the only exceptions.
3. Anchor IDs come from GitHub-style slugify, but the H2 title is already the kebab-case form; do not rely on slugify.
4. `key_decisions[].anchor` and `refs.*` resolve to a real `## <slug>` heading in the target file. Enforcement is narrower than the rule: the handoff harness validates cross-file resolution only for the AR→DV edge (`--validate-frontmatter <DV row artifact> --state <state.json>` checks the architecture reference's pattern and that the file exists next to the artifact). Every other `refs.*` entry is checked for key presence only, so a dangling target elsewhere is an author-owned contract violation the harness will not catch.

### Anchor Pre-Flight (PreToolUse Edit deny, PostToolUse feedback)

One managed plugin hook (`hooks/anchor-preflight.sh`, default-on) checks anchors at write before stray H2 costs rework; the harness gates the boundary. All three share `cache-lint.sh --anchor-diff`:

- **`PreToolUse` deny (Edit only)** — Path on artifact regex, basename exactly `<canonical>-<N>.md` (or DV's `development-<N>-<stream>.md`), `state.json` beside it. An Edit whose `new_string` adds an off-list H2 that `old_string` lacks gets `deny` naming it and the allowed set. A Write (Codex patches too) is never denied: an Edit fix is cheaper than a re-emit. Missing H2 never denies; hook error allows.
- **`PostToolUse` feedback** — Control-byte scan, `--anchor-lint`, one line per off-list H2 or frontmatter finding (§ Post frontmatter check).
- **Stage boundary** — `handoff-harness.sh --validate-frontmatter` fails on missing/unexpected H2 for all 13 stages; fails closed when `cache-lint.sh` cannot run.

#### Managed hook entries (plugin.json)

```jsonc
// hooks.PreToolUse, after test-execution-gate: JSON deny needs no continueOnBlock
{ "matcher": "Write|Edit",
  "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/anchor-preflight.sh", "args": ["--event", "pre"] } ] }
// hooks.PostToolUse, alongside audit-tooluse
{ "matcher": "Write|Edit",
  "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/anchor-preflight.sh", "args": ["--event", "post"], "continueOnBlock": true } ] }
```

#### Preflight behavior and cost — scan logic

`anchor-preflight.sh` scans allowlisted text writes for control bytes before artifact check. Anchor-lint runs only on canonical artifact regex (`\.context/((planning|architecture|coordination|developer-review|security-review|testing|documentation|release|complete-summary|retrospective|incident|ethics-review)-[0-9]+|development-[0-9]+(-[a-z0-9]+)*)\.md$`); other Write/Edit gets control-byte scan alone. Finding exits 2 (only PostToolUse exit routing stderr to model). Producer sees diagnostic and amends, so downstream doesn't pay.

#### Post frontmatter check

The frontmatter check, like the off-list H2 line, runs only when a ledger `state.json` sits beside the artifact. It runs `handoff-harness.sh --validate-frontmatter` on a same-basename temp copy of the file on disk and reports three classes only: `handoff:` over the 200-token budget, a digitless `summary_line`, a sweep stub without 2-4 `options[]`. It runs after a Write, a Codex patch, an unreadable payload, or an Edit whose `new_string` is empty or lands in the frontmatter or `## elicitation-sweep`; a body-only Edit is skipped. Each finding is one stderr line ending `fix it with a small Edit, do not re-Write the file.` Without `yq` the check fails open; the boundary still gates. `continueOnBlock` follows managed-hook discipline (diagnostic surfaced, unrelated write never blocked). Non-hook environments use stage-boundary harness only. Cost: O(seconds) per Write/Edit.

---

## Future work (out of scope for v1)

`version` is the migration hook (currently `2` — the `tasks{}` ledger); future schema additions ship behind it. A relaxed-profile schema for cross-plugin agents is stubbed in `skills/cross-plugin-handoff/SKILL.md`. Compressing `.context/logs/audit.jsonl` and migrating historical `.context/` artifacts are both out of scope.
