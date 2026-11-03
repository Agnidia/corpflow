# Template ir

Read before writing the IR stage artifact. Apply the [first-write rules](../../references/contracts/template-rules.md) and its stage template below.

<!-- canonical-body:start -->
<a id="tpl-ir"></a>
### #tpl-ir — Incident Response (incident-responder)

```yaml
---
handoff:
  stage: IR
  verdict: ok                  # ok / escalate
  summary: "Root cause: <X>. Fix plan: <Y>. Blast radius: <Z>"
  key_decisions:
    - { id: ir1, summary: "Root cause identified", anchor: "incident-N.md#root-cause" }
  next_stage_focus: "DV implements fix; QA runs regression"
  open_questions:
    - { id: sw-IR0-1, class: decision, ref: "incident-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    root_cause: incident-N.md#root-cause
    fix_plan: incident-N.md#fix-plan
---
```

Prev→this label: `USER→IR`.
