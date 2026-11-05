# Correction returns

Read when executing or checking correction returns. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
#### A finding routes by who wrote the line (tpl-dc)

The first arm that matches wins:

1. DC wrote the flagged line this run: DC fixes the doc and re-runs the check. The finding is not
   returned.
2. An upstream task's handoff `files_touched` lists the doc: DC leaves the line and returns
   `verdict: blocked` with `blocked_on.kind: correction`, naming the latest such task.
3. Neither: the line predates this run, so DC fixes it as in arm 1 and names it in
   `documentation-N.md`.

`blocked_on` holds one finding, the first arm-2 finding in stdout order. `documentation-N.md` lists
every finding with its arm, so a rework round is not left to rediscover the rest one gate run at a
time.

#### The correction return (tpl-dc)

<example>

```yaml
# …continued: handoff, a DC return carrying one arm-2 finding
  verdict: blocked
  summary: "doc-option-check.sh: 1 finding in a doc DV0 owns"
  blocked_on:
    kind: correction
    detail:
      target_task: DV0
      finding: "README.md:42: env API_BIND undefined"
      evidence_ref: "README.md:42"
      severity: blocking
    resume_with: artifact_path
```

</example>

`kind`, `detail` and `resume_with` are the three keys of the `handoff.blocked_on` return contract,
and `correction` is its kind for this case. The `detail` keys are `target_task`, `finding`,
`evidence_ref`, `severity`, in that order. `finding` is the offending line verbatim, because the
rework brief quotes it. `evidence_ref` is `<file>:<line>`, and DC always sets `severity` to
`blocking`.

#### The correction return — any stage, any resolver (tpl-dc)

The example is DC's, but the arm is not: any stage or resolver that finds a defect in work another task already completed returns this same shape, and the router treats every one of them identically. FN's staged control-byte check is another origin (§ #tpl-fn).

##### Rules for correction returns

- The target is a `completed` task. A correction re-opens finished work; the ledger op refuses a target that is missing, is the returning task itself, or is in any other status. A defect in work still in flight is not a correction — it is that task's own round to finish (`skills/worktask/references/contracts/ledger-tasks.md § tasks — re-open and settle — guards and invocation`).
- Return it, never route it. The orchestrator re-opens the target, parks the tasks that consumed its output, and hands the rework brief back. A stage that edits the other task's files, or asks in prose for someone to fix them, has routed by hand and left no ledger row or audit leg.
