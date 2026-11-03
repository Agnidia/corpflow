# Blocked artifacts

Read when a stage needs an artifact, a correction, or a host capability.

Read these sections only when this procedure cites them.

###### Section lookup 1

[Landing — the audit row](artifact-landing.md#landing--the-audit-row) · [tasks](ledger-tasks.md#tasks) · [metadata](ledger-root.md#metadata)

###### Section lookup 2

[metadata.preflight](ledger-preflight.md#metadatapreflight) · [metadata.preflight — field notes](ledger-preflight.md#metadatapreflight--field-notes)

<!-- canonical-body:start -->
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

A defect in work another task owns. Any stage/resolver may return one; DC's option-existence gate is the worked example (`skills/worktask/references/contracts/correction-returns.md § The correction return (tpl-dc)`). `artifact_path` is `target_task`'s own artifact after correction: `tasks[<target>].artifact` if completion merge recorded one, else `metadata.artifact`.

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

##### Host capability recovery

A grant, evidence tool or toolchain that the autonomy preflight probes, failing now. `check` names
that probe (§ metadata.preflight — field notes), so a recovery probe can distinguish fixed from still broken.
A new need receives one capability probe. An existing ledger need or its recorded `probed` leg suppresses repeated probes.
This remains true when the ledger write succeeded but the audit write failed.
After the user reports the required recovery, `resume --leg verified` probes the check and resumes only on a pass.
A changed observation alone cannot grant permission or clear the blocker.
Keep the operation, evidence reference, and required recovery condition in `observed` and the stage artifact.
A host need no probe covers is a `user_action`; native acceptance stays pending trusted-host validation.

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
