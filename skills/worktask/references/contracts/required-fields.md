# Required fields

Read when checking a stage verdict or its required frontmatter fields.

Read these sections only when this procedure cites them.

###### Section lookup 1

[Schema — blocked_on](blocked-needs.md#schema--blocked_on)

<!-- canonical-body:start -->
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

A valid `tests_executed` list is excluded from that count up to 24 proxy tokens per entry, for at most eight entries (192 tokens), so recording every runner never costs budget. A `tests_executed` block that fails validation is excluded at a flat 96-token cap, and the budget failure line says `(tests_executed invalid: excluded at the 96-token cap)`: the fault is reported once, and the rest of the prose is still checked against 200.

---
