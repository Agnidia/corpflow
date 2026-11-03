# Template tl

Read before writing the TL stage artifact. Apply the [first-write rules](../../references/contracts/template-rules.md) and its stage template below.

<!-- canonical-body:start -->
<a id="tpl-tl"></a>
### #tpl-tl — Team Lead (team-lead)

```yaml
---
handoff:
  stage: TL
  verdict: ok                  # ok / blocked / escalate
  summary: "<one-line coordination summary ≤200 chars>"
  next_stage_focus: "<imperative: DV batch order + parallelization>"
  open_questions:
    - { id: sw-TL0-1, class: decision, ref: "coordination-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    plan: .context/planning-N.md#requirements
    arch: .context/architecture-N.md#decisions   # only when AR ran; omit otherwise
    fan_out: coordination-N.md#fan-out
---
```

Prev→this label: `AR→TL` (or `PL→TL` when AR was excluded). Skip-exploration short-circuit applies.
