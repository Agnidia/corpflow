# Template dv

Read before writing the DV stage artifact. Apply the [first-write rules](../../references/contracts/template-rules.md) and its stage template below.

## Read for related fields
- For files touched, read [files-touched](../../references/contracts/files-touched.md).
- For test evidence, read [test-evidence](../../references/contracts/test-evidence.md).
- For architecture reference, read [architecture-reference](../../references/contracts/architecture-reference.md).

Apply [the DV artifact rules](../../references/contracts/artifact-rules-dv.md) before returning.

<!-- canonical-body:start -->
<a id="tpl-dv"></a>
### #tpl-dv — Development (developer)

```yaml
---
handoff:
  stage: DV
  task_id: DV0                # your own ledger row id; required once the run has >1 DV row
  verdict: ok                  # ok / blocked / escalate
  summary: "<N files modified, M tests added>"
  tests_executed:             # one entry per runner; cases RUN, not discovered; [] is legal
    - { runner: bats, count: 12, summary_line: "1..12" }  # line verbatim; required when count > 0
  test_suite_compiles: true   # true/false/unknown; required when [] or every count is 0
  files_touched:              # cap 10, then ONE marker; #files-touched
    - path/to/file1.md
    - "+ 7 more"              # obliges the full body set
  next_stage_focus: "<imperative: what DR/QA must focus on>"
  open_questions:
    - { id: sw-DV0-1, class: decision, ref: "development-N.md#elicitation-sweep", blocks_next_stage: false }
---
```

#### The refs and architecture half (tpl-dv)

```yaml
# …continued: handoff
  refs:
    decisions: architecture-N.md#decisions    # only when AR ran; omit
    coordination: coordination-N.md#fan-out   # only when TL ran; omit
    tests: development-N.md#tests-added
  architecture:                # only when AR ran; omit the object otherwise
    ref: architecture-N.md#decisions
    applied: true              # truthful; see the reference contract below
```

Prev→this label: `TL→DV` (`AR→DV` without TL, `PL→DV` when neither ran, `IR→DV` on emergency).
