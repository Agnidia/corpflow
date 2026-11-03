# Template fn

Read before writing the FN stage artifact. Apply the [first-write rules](../../references/contracts/template-rules.md) and its stage template below.

<!-- canonical-body:start -->
<a id="tpl-fn"></a>
### #tpl-fn — Finalization (project-manager)

```yaml
---
handoff:
  stage: FN
  verdict: ok                  # ok / blocked
  summary: "All artifacts aggregated. complete-summary-N.md ready for ST approval."
  files_touched:
    - .context/complete-summary-N.md
  next_stage_focus: "ST approves merge and confirms MEMORY.md version bump"
  open_questions:
    - { id: sw-FN0-1, class: decision, ref: "complete-summary-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    summary: .context/complete-summary-N.md
    ledger: .context/state.json
---
```

Prev→this label: `RE→FN` (or `DC→FN` without RE, `QA→FN` without RE and DC).

`fn-preflight.sh staging` fails on a raw control byte in a staged text file (`control-byte-lint.sh
--staged`). When the file belongs to another task — its handoff `files_touched` lists it — that is a
correction FN returns with itself as the source and that task as the target, not a byte FN edits
out (§ The correction return — any stage, any resolver).
