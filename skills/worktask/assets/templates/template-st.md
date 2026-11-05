# Template st

Read before writing the ST stage artifact. Apply the [first-write rules](../../references/contracts/template-rules.md) and its stage template below.

<!-- canonical-body:start -->
<a id="tpl-st"></a>
### #tpl-st — Stakeholder (stakeholder)

```yaml
---
handoff:
  stage: ST
  verdict: approve             # approve / reject
  summary: "Approved. <N follow-ups filed or 'No follow-ups'>."
  # blockers: ["<criterion>: <gap>"]   # reject only — injected into the replayed DV prompt
  key_decisions:
    - { id: st1, summary: "Approve merge", anchor: "retrospective-N.md#decision" }
  open_questions:
    - { id: sw-ST0-1, class: decision, ref: "retrospective-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    summary: .context/complete-summary-N.md
---
```

Prev→this label: `FN→ST` (or `RE→ST`/`DC→ST`/`QA→ST`, from the latest of those that ran, when FN did not run).

ST treats every `escalate` item as a recommendation only and never resolves it, in prose or in the ledger; the user answers it at its checkpoint.
