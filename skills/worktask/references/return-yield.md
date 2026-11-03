# Return yield

Read when executing or checking return yield.

Procedure routing: [return-arms](return-arms.md).

<!-- canonical-body:start -->
## Step 6.5a2 — why a mid-stage yield needs its own arm

An agent that yields mid-sentence with budget remaining has **not** errored, so 6.5a does not fire
and control falls through to Layer 3 and Step 7, which settle the row from a verdict written before
the stage finished — corrupting the ledger in the one direction nothing downstream re-checks — or
escalate a stage that only needed resuming. This arm keys on *evidence* (artifact absent, or
present with no `handoff.verdict`), never on the shape of the return message, so a
normally-completed stage still takes Layer 2.

## Step 6.5a2 — mark & audit

```typescript
      // …continued: step 6.5a2 body
      if (incomplete) {
        atomicMergeStateJson({ tasks: { [task.id]: { status: "in_progress" } } });
        appendAudit({
          actor: "orchestrator", action: "stage_returned_incomplete", subject: code,
          result: "blocked",
          metadata: {
            task_id: task.id, run_index: full.metadata.run_index ?? 0,  // keys the resume bound
            artifact: incArtifact,
            artifact_present: fs.existsSync(incArtifact),
            reason: maxTurnsPartial ? "max_turns_partial"
                    : fs.existsSync(incArtifact) ? "handoff_verdict_missing" : "artifact_absent",
          },
        });
```

## Step 6.5a2 — resume, never re-delegate

The agent holds the half-done work; a fresh dispatch would redo it against a tree it already
edited. Same branch as a parked agent in `skills/worktask/references/recovery-state.md § State → Action Table`.
Auto-resume at most 2 times per row per run; the count includes this return.

```typescript
        // …continued: step 6.5a2 body. Count from the file appendAudit writes; missing → 0.
        const n = Number(sh(`jq -nR --arg id ${task.id} --argjson n ${full.metadata.run_index ?? 0} ` +
          `'[inputs|fromjson?|select(.action=="stage_returned_incomplete" and ` +
          `.metadata.task_id==$id and (.metadata.run_index//0)==$n)]|length' ` +
          `< "\${WORKSPACE_ROOT:-\${CLAUDE_PROJECT_DIR:-.}}/.context/logs/audit.jsonl"`) || 0);
```

## Step 6.5a2 — auto-resume, at most 2

```typescript
        // …continued: step 6.5a2 body
        if (n <= 2) {   // a stage message, so it carries a msg_id (Step 6.5a4)
          sendStageMessage(state, task, subagentType,
            `Stage ${code} returned without a completed handoff (auto-resume ${n} of 2). Finish the work, write ${incArtifact} with a handoff verdict, and return. Do not restart from scratch. The budget below counts from this message.\n${turnBudget(subagentType).line}`);
          continue;   // never falls through to the completion patch
        }
```

## Step 6.5a2 — the resume bound

```typescript
        // …continued: step 6.5a2 body. A 3rd incomplete return: block, audit, no SendMessage.
        sh(`state-patch.sh --task-status ${task.id} blocked`);
        appendAudit({ actor: "orchestrator", action: "stage_resume_exhausted", subject: task.id,
                      result: "escalated",
                      metadata: { task_id: task.id, run_index: full.metadata.run_index ?? 0,
                                  incomplete_returns: n, reason: "auto_resume_cap" } });
        continue;   // surface per SKILL.md § Escalation Chains
      }
```

The bound turns an endless resume loop into one escalation. The operator then resumes by hand,
re-dispatches (Step 4.7 reads `progress`) or descopes. `retry_count` stays untouched: nothing
failed. The count keys on `task_id` + `run_index`, since `subject: code` merges parallel DV rows
and runs; an older row with no `task_id` counts 0.

## Turn budget — the cap

`turnBudget(subagentType)` serves Step 4.7 (the banner) and Step 6.5a2 (each resume). It reads
the LOADED agent definition, because the runtime enforces that copy, not the worktree's.

```typescript
function turnBudget(subagentType: string) {   // → {cap, checkpoint, line, source}
  const [plugin, name] = subagentType.split(":");
  const root = plugin === "corpflow" ? CLAUDE_PLUGIN_ROOT    // resolver exit 1 → null
    : sh(`bash ${CLAUDE_PLUGIN_ROOT}/skills/cross-plugin-handoff/scripts/resolve-sibling-root.sh ${plugin}`);
  const fm = root ? firstFrontmatterBlock(`${root}/agents/${name}.md`) : null; // first --- block
  const m = fm?.match(/^maxTurns:[ \t]*([0-9]+)[ \t]*$/m);
  const read = m ? Number(m[1]) : 0;
```

## Turn budget — the line

```typescript
  // …continued: turnBudget body
  const cap = read >= 1 ? read : 50;
  const checkpoint = Math.floor(cap * 4 / 5);
  const line = `TURN BUDGET: ${cap} turns. Checkpoint by turn ${checkpoint}: record progress, ` +
    `write the partial artifact without a handoff verdict, and return.`;
  return { cap, checkpoint, line, source: read >= 1 ? "frontmatter" : "default" };
}
```

The checkpoint is `floor(0.8 × cap)`, worked in integers to avoid float drift: 40→32, 50→40,
60→48, 80→64. An unreadable `maxTurns` (no file, resolver exit 1, no match, or 0) defaults to
50, the Tier-2 cap, and Step 4.7 audits `warn`.
