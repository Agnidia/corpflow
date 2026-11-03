# Template sr

Read before writing the SR stage artifact. Apply the [first-write rules](../../references/contracts/template-rules.md) and its stage template below.

<!-- canonical-body:start -->
<a id="tpl-sr"></a>
### #tpl-sr — Security Review (security-reviewer)

```yaml
---
handoff:
  stage: SR
  verdict: pass                # pass / fail
  summary: "<N files reviewed. M security findings>"
  key_decisions:
    - { id: sr1, summary: "<security finding>", anchor: "security-review-N.md#findings" }
  open_questions:
    - { id: sw-SR0-1, class: decision, ref: "security-review-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    dev:                                   # always a list, one element per DV ledger row
      - development-0-service.md#files-changed
      - development-0-web.md#files-changed
    findings: security-review-N.md#findings
---
```

Prev→this label: `DR→SR`.

A question whose options include accepting a known vulnerability, a CVE or a security finding is
`class: escalate`, never `decision`: accepting one is an escalation-class choice per
`skills/worktask/references/plan-transition.md § Escalation guard (BINDING)`.
