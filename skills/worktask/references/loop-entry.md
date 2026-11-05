# Loop entry

Read when executing or checking loop entry.

Procedure routing: [orchestration](orchestration.md).

<a id="section-lookup-1"></a>
Related: [FN Gate](finalization-policy.md#fn-gate) · [PL Issue Publish](completion-handoff.md#pl-issue-publish)

<!-- canonical-body:start -->
### PRECONDITION CHECK
Before entering this loop, verify:

#### Signals 1–3 (incl. 2b)

- **Signal 1 (ledger audit)**: `tasks.PL0` in `.context/state.json` has status `completed`. Missing or incomplete → stop: worktask not initialized, or planning incomplete.

**Signal 2 (plan gate)**: `PL0.metadata.plan_gate` (default `"checkpoint"`).
- `"checkpoint"` (default): require both PL0 `completed` and an `approval_received` audit line with
  `subject:"PL<run_index>"` in `.context/logs/audit.jsonl` before loop entry. Line absent → stop and
  return to `workflow.md § Step A.5` to fulfil the gate.
- `"bypass"` (`--auto=[plan]` / `--emergency`, or stamped per-issue by the `/megatask` batch orchestrator): PL0 `completed` alone suffices, no approval line — except for Signal 2b escalated items, whose `approval_received` row is still required.

##### Signal 2b (decision gate)

`PL0.metadata.decision_gate` (default `"user"`) selects WHO answers PL0's `open_questions[]` at the
plan gate; `"auto"` (stamped by `--auto=[decision]`) routes them through the Fable-model
auto-decision pre-pass (`workflow.md § Step A.4` is canon). Verify before loop entry: when
`decision_gate == "auto"` and `facts.open_questions[]` holds any `sw-PL<N>-*` item with
`status != "resolved"`, an `auto_decision_resolved` audit row with `subject:"PL<run_index>"` must
exist, and any `escalate` items need an `approval_received` resolution — absent → stop and return to
Step A.4. The carrier bypasses neither `plan_gate` nor `fn_gate`.

##### Signal 3 (FN gate)

FN dispatch is gated mid-loop on `PL0.metadata.fn_gate` (default `"checkpoint"`): stop immediately before the FN `Agent()` delegation for finalization approval unless the carrier is `"bypass"` (`--auto=[finalization]` / `--emergency`, or stamped per-issue by the `/megatask` batch orchestrator). See loop step 4.9 and § FN Gate.

#### After PL0 — steps 1–3

After PL0 completes and creates stage tasks, the orchestrator:

1. **Present PL0 results** to the user: complexity score, stages created (with agents), dependency chain, key planning decisions (at the Step A.5 plan gate; on a `checkpoint` gate execution proceeds only after approval).
2. **Re-validate before executing**: re-read `tasks{}`; verify `metadata.agent` and `metadata.model` are set on each.
3. **Publish plan to GitHub** (before stage loop). Run:

##### Step 3 — publish snippet

     ```bash
     pub_rc=0
     bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/publish-pl-issue.sh || pub_rc=$?
     ```

##### Step 3 — publish fallback (helper_not_found)

     ```bash
     # …continued: exit 127 means bash found no helper → audit one deferred github_issue_created row
     if [ "$pub_rc" -eq 127 ]; then
       LOG_DIR="${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-.}}/.context/logs"
       mkdir -p "$LOG_DIR"
       STATE_FILE="${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-.}}/.context/state.json"
       jq -cn --arg ts "$(date -u +%FT%TZ)" --arg dk "$(jq -r '.worktask_id // "unknown"' "$STATE_FILE" 2>/dev/null || echo unknown):$(jq -r '.run_index // 0' "$STATE_FILE" 2>/dev/null || echo 0):gh_issue" \
         '{ts:$ts, actor:"orchestrator", action:"github_issue_created", subject:"PL0", result:"deferred", task_id:"1", metadata:{via:"publish-pl-issue.sh", reason:"helper_not_found", dedupe_key:$dk}}' \
         >> "$LOG_DIR/audit.jsonl"; true
     fi; true
     ```

##### Step 3 — non-blocking & skip rules

     The `|| pub_rc=$?` capture and the trailing `; true` mask the helper's exit code, so a helper failure (catastrophic exit 1, deferred exit 0, network error) never becomes an orchestrator failure. Skip the step entirely when `--no-gh-issue` was supplied (PL0 stamps `task.metadata.no_gh_issue: true`; the helper also short-circuits internally). The helper self-gates the rest: megatask per-issue mode skips every `gh` call, and a second-or-later run in the same `.context/` comments instead of opening a duplicate. Semantics, sanitiser rules and the non-blocking guarantee: § PL Issue Publish.

#### Steps 1–3

```typescript
// 1. Read the ledger — tasks{} keyed by stage id (PL0, DV0, DV1…).
let state = JSON.parse(fs.readFileSync(".context/state.json", "utf8"));
if (state.version !== 2) throw new Error(`state.json version ${state.version}; expected 2`);
let tasks = Object.entries(state.tasks).map(([id, t]) => ({ id, ...t }));
```

##### HANDOFF_SCHEMA

```typescript
// Typed-return schemas — SSOT: skills/worktask/references/contracts/typed-conventions.md#handoff-schemas.
// Resolve only the current stage schema through typed-conventions.md and its stage links:
//   const HANDOFF_SCHEMA: Record<string, object> = { PL: {…PLHandoff}, AR: …, TL, DV, DR, SR,
//                                                    QA, DC, RE, FN, ST, IR, ET };
// A missing key leaves stageSchema undefined → schema param omitted → today's frontmatter path.
```

##### Steps 2–3 — completion loop & ready filter

```typescript
// 2. Loop until every task has settled. "skipped" and "failed" are terminal like "completed":
//    a task nothing will dispatch again must settle, or the loop spins with an empty ready set.
//    "stale" is deliberately absent: a parked consumer of a re-opened task is neither settled nor
//    ready, so its own dependents stay unready and the loop stays open until § Step 6.5d settles
//    it back to pending or completed (skills/worktask/references/contracts/ledger-status.md § Status Values).
const SETTLED = new Set(["completed", "skipped", "failed"]);
while (tasks.some(t => !SETTLED.has(t.status))) {
  // 3. Find unblocked pending tasks
  const ready = tasks.filter(t =>
    t.status === "pending" &&
    (t.blocked_by ?? []).every(dep => SETTLED.has(state.tasks[dep]?.status))
  );

  for (const task of ready) {
```
