# Template pl

Read before writing the PL stage artifact. Apply the [first-write rules](../../references/contracts/template-rules.md) and its stage template below.

Apply [the PL artifact rules](../../references/contracts/artifact-rules-pl.md) before returning.

<!-- canonical-body:start -->
<a id="tpl-pl"></a>
### #tpl-pl — Planning (product-manager)

```yaml
---
handoff:
  stage: PL
  verdict: ok                  # ok / blocked / escalate
  summary: "<one-line summary ≤200 chars>"
  rejection_reason: "<gate feedback, revisions only; omit on first draft>"
  key_decisions:
    - { id: pd1, summary: "<decision>", anchor: "planning-N.md#scope" }
  next_stage_focus: "<imperative: what AR must grep/design>"
  open_questions:
    - { id: sw-PL0-1, class: decision, ref: "planning-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    spec: .context/attachments/<spec-file>
    plan: .context/planning-N.md#requirements
---
```

Prev→this label: `USER→PL`.
