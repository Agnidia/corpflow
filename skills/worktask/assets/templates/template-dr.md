# Template dr

Read before writing the DR stage artifact. Apply the [first-write rules](../../references/contracts/template-rules.md) and its stage template below.

Apply [the DR artifact rules](../../references/contracts/artifact-rules-dr.md) before returning.

<!-- canonical-body:start -->
<a id="tpl-dr"></a>
### #tpl-dr — Developer Review (technical-lead)

```yaml
---
handoff:
  stage: DR
  verdict: pass                # pass / fail
  summary: "<N files reviewed. M findings, all addressed / K blockers remain>"
  key_decisions:
    - { id: dr1, summary: "<finding or approval>", anchor: "developer-review-N.md#findings" }
  open_questions:
    - { id: sw-DR0-1, class: decision, ref: "developer-review-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    dev:                                   # always a list, one element per DV ledger row
      - development-0-service.md#files-changed
      - development-0-web.md#files-changed
    findings: developer-review-N.md#findings
---
```

Prev→this label: `DV→DR`.
