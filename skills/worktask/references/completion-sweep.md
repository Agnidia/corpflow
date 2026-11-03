# Completion sweep

Read when executing or checking completion sweep.

Procedure routing: [orchestration](orchestration.md).

<a id="section-lookup-1"></a>
Related: [Error Handling](workspace-scheduling.md#error-handling) · [Escalation Chains](workspace-scheduling.md#escalation-chains) · [USER under /megatask](workspace-scheduling.md#user-under-megatask)

###### Section lookup 2

[Step 4.8](dispatch-workspace.md#step-48) · [Step 4.8 — land consumed artifacts](dispatch-workspace.md#step-48--land-consumed-artifacts)

<!-- canonical-body:start -->
#### Step 6.5c — sweep checks, before anything reads the sweep

```typescript
    // 6.5c. After 6.5b and BEFORE 6.6: run the handoff harness on this stage's artifact with
    //       --state (workflow.md § Step B.1). It hard-fails a class-bearing stub with
    //       no ref, a dangling ref anchor, a stub absent from facts.open_questions[] — the
    //       transport 6.6 and step 4.9(a1) read — and an unreadable ledger. Exit 0 → audit
    //       `sweep_check` ok. Non-zero with a `fail:` line → audit `sweep_check` fail and treat
    //       it as a missing_input contract violation on this stage: skip 6.6, do NOT dispatch
    //       the next stage, re-dispatch this stage with the fail line verbatim. For DV this is
    //       the same call as § Step B (the AR-reference arm rides on it); run it once.
```

##### Step 6.5d — land the producer's artifacts

```typescript
    // 6.5d. After 6.5c and BEFORE the next ready-filter pass: copy this DV row's staged
    //       `produces` into each consumer's tree (handoff-protocol.md § Landing consumed
    //       artifacts). Landing at the producer's boundary is what keeps a consumer whose
    //       landing failed out of the ready set; the ready filter itself is unchanged.
    const producer = JSON.parse(fs.readFileSync(".context/state.json", "utf8")).tasks[task.id];
    if (producer?.status === "completed" && producer.metadata?.stage === "DV" && sweepCheckPassed) {
      const land = spawnSync("bash", ["skills/worktask/scripts/land-artifacts.sh",
                                      "--producer", task.id]);
      // exit 1: consumers already blocked; any other non-zero is reported, never blocked here
      if (land.status !== 0) queueLandingBlock(land);
    }
```

##### Step 6.5d — resume a stage parked on this producer's artifact

```typescript
    // …continued, whatever the landing exited. ROUTER as in § Step 6.5a3.
    if (producer?.status === "completed" && producer.metadata?.stage === "DV" && sweepCheckPassed) {
      const tasks = JSON.parse(fs.readFileSync(".context/state.json", "utf8")).tasks;
      for (const [id, t] of Object.entries(tasks)) {
        const need = t.metadata?.blocked_on;
        if (t.status !== "blocked" || need?.kind !== "artifact"
            || need.detail?.producer_task !== task.id) continue;
        const r = spawnSync("bash", [ROUTER, "resume", "--task-id", id, "--leg", "landed"]);
        if (r.status === 0) { const rb = JSON.parse(r.stdout).resume_block; deliverResume(rb, rb.instruction); }
        else if (r.status !== 1) escalate(id);
      }
    }
```

Exit 0 delivers the resume, exit 1 leaves the stage parked for § Step 7a, and any other exit goes to
§ Error Handling.

###### Step 6.5d — a parked stage is never landed into

The boundary pass skips a `blocked` consumer, so `resume --leg landed` succeeds here only when
`path` is already in the parked stage's tree's landed set; otherwise the user answers at § Step 7a.

##### Step 6.5d — reporting a refused landing

`queueLandingBlock` reports each blocked consumer's `metadata.landing_error` (`reason`, `path`,
`producer`) to the user per § Escalation Chains → USER (§ USER under /megatask settles first),
after the other ready rows are dispatched.
Step 7 cannot surface it: it reads the returning producer's row, which stays `completed`.

On any status other than 0 or 1 (exit 2 for usage, ledger, missing tool or failed ledger write; or a
signal) the script recorded nothing about any consumer, so the report carries its stderr instead.
Nothing is blocked here; the consumer's own § Step 4.8 — land consumed artifacts gate refuses its
dispatch later.

A producer re-run (a DR rework) can reach a consumer that is no longer `pending`. The pass leaves
that row untouched and exits 0 with one `warn` `contract_landed` row whose reason is
`consumer_not_pending`, so a rework never flips a running or finished stream to `blocked`.

##### Step 6.5d — settle the consumers of a re-opened task

At re-opened target's own completion boundary (after landing pass, before next ready-filter). The correcting stage resumed earlier when corrected artifact did not exist. Any stage, not just DV.

###### Step 6.5d — settle invocation

```typescript
    const done = JSON.parse(fs.readFileSync(".context/state.json", "utf8")).tasks[task.id];
    if (done?.status === "completed" && (done.metadata?.fix_round ?? 0) > 0) {
      const st = spawnSync("bash", ["skills/worktask/scripts/state-patch.sh",
                                    "--task-settle-stale", task.id], { encoding: "utf8" });
      if (st.status !== 0) escalate(task.id);
    }
```

Script decides each `stale` dependent: back to `pending` when corrected change set intersects cited refs; back to `completed` when it doesn't; `pending` when either set unreadable/empty. Prints `{"settled":[{"task","to","reason"}]}`. Orchestrator runs it; both sets, normalisation, fail-safe direction: `skills/worktask/references/contracts/ledger-tasks.md § tasks — re-open and settle — guards and invocation`. Re-opened target never completing leaves dependents `stale`, keeping loop open.

###### Step 6.5d — resume the stage that raised the correction

```typescript
    if (done?.status === "completed" && (done.metadata?.fix_round ?? 0) > 0) {
      const parked = JSON.parse(fs.readFileSync(".context/state.json", "utf8")).tasks;
      for (const [id, t] of Object.entries(parked)) {
        const need = t.metadata?.blocked_on;
        if (t.status !== "blocked" || need?.kind !== "correction" || need.detail?.target_task !== task.id) continue;
        const r = spawnSync("bash", [ROUTER, "resume", "--task-id", id, "--leg", "closed"]);
        if (r.status === 0) { const rb = JSON.parse(r.stdout).resume_block; deliverResume(rb, rb.instruction); }
        else escalate(id);
      }
    }
```

###### Step 6.5d — notes

Corrected artifact exists only now; source resumes here not at route that parked it. Non-zero exit: row not parked or ledger write refused → § Error Handling. Unreached stays parked for § Step 7a.
