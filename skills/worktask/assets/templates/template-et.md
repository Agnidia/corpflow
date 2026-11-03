# Template et

Read before writing the ET stage artifact. Apply the [first-write rules](../../references/contracts/template-rules.md) and its stage template below.

<!-- canonical-body:start -->
<a id="tpl-et"></a>
### #tpl-et — Ethics Review (ethics-reviewer)

```yaml
---
handoff:
  stage: ET
  verdict: pass                # pass / fail (block/conditional → fail with key_decisions)
  summary: "Ethics review complete. Score: <X>/100. Status: <APPROVED|CONDITIONS|BLOCKED>."
  key_decisions:
    - { id: et1, summary: "Compliance verdict", anchor: "ethics-review-N.md#findings" }
  next_stage_focus: "Invoking stage resumes after ET verdict"
  open_questions:
    - { id: sw-ET0-1, class: decision, ref: "ethics-review-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    review: .context/ethics-review-N.md
    ledger: .context/state.json
---
```

Prev→this label: `<invoker>→ET` (whichever stage triggered the ethics gate).
