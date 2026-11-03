# Template qa

Read before writing the QA stage artifact. Apply the [first-write rules](../../references/contracts/template-rules.md) and its stage template below.

## Read for related fields
- For test evidence, read [test-evidence](../../references/contracts/test-evidence.md).

Apply [the QA artifact rules](../../references/contracts/artifact-rules-qa.md) before returning.

<!-- canonical-body:start -->
<a id="tpl-qa"></a>
### #tpl-qa — QA (qa-engineer)

```yaml
---
handoff:
  stage: QA
  verdict: go                  # go / no-go
  blocking_defects: []  # required on no-go; one string per defect
  summary: "<N unit tests pass, M integration checks. Coverage X%>"
  tests_executed:              # one entry per runner; cases RUN; QA holds full-suite authority
    - { runner: bats, count: 840, summary_line: "1..840" }  # line verbatim; required when count > 0
  files_touched:
    - tests/added/test-file.sh
  key_decisions:
    - { id: qa1, summary: "Coverage X%, target met", anchor: "testing-N.md#coverage" }
  open_questions:
    - { id: sw-QA0-1, class: decision, ref: "testing-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    dev:                                   # always a list, one element per DV ledger row
      - development-0-service.md#files-changed
      - development-0-web.md#files-changed
    results: testing-N.md#results
---
```

Prev→this label: `DR→QA` (or `SR→QA` when SR runs).
