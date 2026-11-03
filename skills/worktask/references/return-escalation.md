# Return escalation

Read when executing or checking return escalation.

Procedure routing: [return-arms](return-arms.md).

<!-- canonical-body:start -->
# Return arms — Step 6.5a1 to 6.5a4

Read a section here only when its predicate in `skills/worktask/references/completion-merge.md § Step 6.5a1–a4 — the
return arms, before Layer 2` holds. The detection code every return runs stays in SKILL.md;
this file holds the arm bodies, their helpers and their rationale. An unqualified `§` names a
section of `skills/worktask/references/orchestration.md`.

## Step 6.5a1 — the escalation target

```typescript
// The Escalate-to column of agent-coordination § Retry / Escalate Matrix, as data. That
// table stays the SSOT — status-enum-parity.bats diffs this map against it, so the two
// cannot drift. `transient` and `logic` are absent: they retry the same agent, so there is
// no edge. `hard_constraint` is absent too — it aborts for a human rather than re-entering
// the loop, and capping an abort would be meaningless.
const ESCALATE_TO = {
  missing_input: "PREV", exhausted: "PREV",
  ambiguous_requirements: "PL", design_flaw: "AR",
};
```

## Step 6.5a1 — the per-edge escalation cap

```typescript
function escalationBookkeeping(state, task, cls) {
  const meta = { ...(state.tasks[task.id].metadata ?? {}) };
  const code = ESCALATE_TO[cls];  // one patch; routing stays the next iteration's ready filter
  if (!code) return { terminal: false, metadata: meta };   // same-agent retry, or abort
  // Full task id, never a bare code: DV0→AR0 must not share a counter with DV3→AR0.
  const target = code === "PREV"
    ? (task.blocked_by ?? []).slice(-1)[0]    // previous stage per chain
    : Object.keys(state.tasks).find(id => id.startsWith(code));
  if (!target) return { terminal: false, metadata: meta };
```

## Step 6.5a1 — the cap, and the reset that must not reach it

```typescript
// …continued: escalationBookkeeping body
  const counts = { ...(meta.escalation_counts ?? {}) };
  counts[target] = (counts[target] ?? 0) + 1;
  meta.escalation_counts = counts;            // survives the reset below
  if (counts[target] > 2) return { terminal: true, metadata: meta };  // cap 2
  meta.retry_count = 0;                       // reset at handoff — retry_count ALONE
  meta.error_escalated_to = target.replace(/[0-9]+$/, "");
  return { terminal: false, metadata: meta };
}
```
