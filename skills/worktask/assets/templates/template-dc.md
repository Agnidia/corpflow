# Template dc

Read before writing the DC stage artifact. Apply the [first-write rules](../../references/contracts/template-rules.md) and its stage template below.

## Read for related fields
- For correction returns, read [correction-returns](../../references/contracts/correction-returns.md).

Apply [the DC artifact rules](../../references/contracts/artifact-rules-dc.md) before returning.

<!-- canonical-body:start -->
<a id="tpl-dc"></a>
### #tpl-dc — Documentation (technical-writer)

```yaml
---
handoff:
  stage: DC
  verdict: ok                  # ok / blocked / escalate
  summary: "Updated N documentation files. Cross-references added."
  files_touched:
    - docs/file1.md
  open_questions:
    - { id: sw-DC0-1, class: decision, ref: "documentation-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    dev:                                   # always a list, one element per DV ledger row
      - development-0-service.md#files-changed
      - development-0-web.md#files-changed
    docs: documentation-N.md#files-changed
---
```

Prev→this label: `QA→DC`.
