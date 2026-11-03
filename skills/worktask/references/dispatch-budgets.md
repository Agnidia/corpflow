# Dispatch budgets

Read when executing or checking dispatch budgets.

Procedure routing: [orchestration](orchestration.md).

<!-- canonical-body:start -->
#### Step 4.7

```typescript
    // 4.7. DV checkpoint resume, per DV row — a budget-exhausted run left a partial artifact
    //      at that row's artifact path (+ `## Blockers`) and completed sub-batches at
    //      tasks.<ID>.progress (agents/developer.md § Budget-Aware Checkpointing). Carry it
    //      forward so the re-run resumes from next_batch instead of redoing applied work.
```

##### Step 4.7 — resume injection

```typescript
    if (full.metadata.stage === "DV") {
      const dvRow = state.tasks?.[task.id];
      const dvProgress = dvRow?.progress;  // {completed_batches, next_batch, updated_at}
      if (dvProgress && (dvProgress.completed_batches?.length ?? 0) > 0) {
        const partial = stageArtifactPath("DV", full.metadata.run_index ?? 0, dvRow);
        full.description =
          `RESUME (DV checkpoint — prior run completed batches ` +
          `[${dvProgress.completed_batches.join(", ")}]; resume from ` +
          `${dvProgress.next_batch ?? "the next pending batch"}). Do NOT redo applied ` +
          `batches — read the partial ${partial} and continue forward.` +
          "\n\n" + full.description;
```

##### Step 4.7 — resume audit

```typescript
        // …continued: step 4.7 body — keyed by the row, so sibling DV rows resume independently
        appendAudit({ actor: "orchestrator", action: "dv_checkpoint_resume", subject: task.id,
                      result: "ok",
                      metadata: { completed: dvProgress.completed_batches,
                                  next_batch: dvProgress.next_batch ?? null } });
      }
    }
```

##### Step 4.7 — turn-budget banner

Every loop-dispatched row, any stage. `turnBudget` reads the dispatched agent's `maxTurns`
(default 50) and checkpoints at `floor(0.8 × cap)`: `skills/worktask/references/return-yield.md § Turn budget — the cap`.

```typescript
    // …continued: step 4.7 body. The first [7] banner: after WORKSPACE_ROOT=, before 4.8a/4.8b.
    const tb = turnBudget(subagentType);   // {cap, checkpoint, line, source}
    full.description += "\n\n" + tb.line;  // TURN BUDGET: <cap> turns. Checkpoint by turn …
    appendAudit({ actor: "orchestrator", action: "turn_budget_injected", subject: task.id,
                  result: tb.source === "default" ? "warn" : "ok",
                  metadata: { agent: subagentType, cap: tb.cap, checkpoint: tb.checkpoint,
                              source: tb.source } });
```

##### Step 4.7 — portability banner

Every loop-dispatched row, any stage, no host-OS gate: a stage agent that assumes GNU bash on Linux
loses turns to shell errors it cannot see coming. Splice it right after the TURN BUDGET line, the
same way.

```typescript
    // …continued: step 4.7 body, after the turn-budget banner.
    full.description += "\n" + "PORTABILITY: the shell can be zsh on macOS; GNU `timeout` can be " +
      "absent; unquoted $var does not word-split — quote every expansion.";
```

#### Step 4.7a

AR writes design outputs — an OpenAPI contract, a schema, a generated header — into the shared
checkout, untracked. DV then forks its worktree from `task.metadata.base_ref`, a committed ref, so
those files would be absent at the path every architecture reference cites. No stage can fix it: AR
holds no git grant, DV is inside the broken tree, FN runs last.

```typescript
    // 4.7a. AR contract landing — runs when the NEXT stage is DV and AR left untracked or
    //       unstaged non-.context/ writes in the shared checkout. Commit them onto the ref
    //       DV's worktree will fork from, so the tree DV receives contains what AR's
    //       artifact says it contains. The orchestrator does this because it is the only
    //       actor holding git that is not itself inside the tree under repair.
```

##### Step 4.7a — the stray set

```typescript
    if (full.metadata.stage === "DV" && state.tasks?.AR0?.status === "completed") {
      // .context/ is the ledger's own tree and never lands here: it is not what DV reads
      // through an architecture reference, and committing it would put run bookkeeping in
      // the payload's history. Landed files are a DV producer's to ship, not AR's: subtract
      // them from untracked entries only, listed per file, since the default porcelain
      // folds a new directory into one `?? dir/` line.
      // `land-artifacts.sh --list-landed --tree "$(git rev-parse --show-toplevel)"`; failure = empty set
      const landed = new Set(listLanded(gitToplevel()));
      const stray = gitPorcelain()           // `git status --porcelain --untracked-files=all`
        .filter(f => !f.path.startsWith(".context/"))
        .filter(f => f.worktreeDirty || (f.untracked && !landed.has(f.path)));
```

##### Step 4.7a — landing and audit

```typescript
      // …continued: step 4.7a body
      if (stray.length > 0) {
        gitCommit(stray.map(f => f.path),
                  `AR contract landing for ${task.id} (run ${state.run_index})`);
        appendAudit({ actor: "orchestrator", action: "ar_contract_landed", subject: "AR0",
                      result: "ok",
                      metadata: { files: stray.map(f => f.path), next_stage: "DV" } });
      }
    }
```

##### Step 4.7a — why the orchestrator, and not a stash

Land, don't stash: a stash leaves the files invisible to a worktree forked from the ref. Don't
widen AR's grants instead — no narrow commit grant exists. If the landing fails, return `blocked`
naming the paths: a DV dispatched into a tree missing its contract cannot succeed.
