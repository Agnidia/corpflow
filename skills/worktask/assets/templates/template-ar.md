# Template ar

Read before writing the AR stage artifact. Apply the [first-write rules](../../references/contracts/template-rules.md) and its stage template below.

<!-- canonical-body:start -->
<a id="tpl-ar"></a>
### #tpl-ar — Architecture (software-architector)

```yaml
---
handoff:
  stage: AR
  verdict: ok                  # ok / blocked / escalate
  summary: "<one-line summary ≤200 chars>"
  key_decisions:
    - { id: ad1, summary: "<decision>", anchor: "architecture-N.md#decisions" }
  next_stage_focus: "<imperative — addressed to TL when TL is in the plan, else to DV>"
  open_questions:
    - { id: sw-AR0-1, class: decision, ref: "architecture-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    plan: .context/planning-N.md#requirements
    decisions: architecture-N.md#decisions
---
```

`key_decisions` is also the source the orchestrator digests into the `metadata.architecture_ref.key_decisions` string (≤200 chars) stamped on the DV0/DR0/QA0 dispatches — keep each summary self-contained.

Prev→this label: `PL→AR`. Skip-exploration short-circuit applies — see `skills/agent-coordination/SKILL.md#orchestrator--pl0-handoff`.
