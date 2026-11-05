# Retry routing

Read when a stage returns a failure, a blocked result, or an escalation.

Procedure routing: [orchestration](orchestration.md).

<!-- canonical-body:start -->
#### Step 7

```typescript
    // 7. Settle by the status Step 6.5 derived from the verdict. Stamping over it would undo
    //    the writer's map; re-read, since Layers 2/3 wrote after the step-4.0 snapshot.
    const ledger = JSON.parse(fs.readFileSync(".context/state.json", "utf8"));
    const row = ledger.tasks[task.id];
    if (row.status === "blocked") {
      // blocked | escalate needs outside input: surface per § Escalation Chains, no stamp
      // (/megatask: § USER under /megatask). A typed or permission park never reaches here:
      // 6.5a3 or 6.5a4 continued, § Step 7a asks.
    } else if (row.status === "pending" && row.metadata?.gate_from_stage) {
      loopBackToDV(ledger, task.id, row);  // fail | reject | no-go: the loop-back arm below
    } else if (row.status !== "completed") {
      // No mapped verdict landed (the writer refused it): escalate per § Error Handling.
    }
  }
```

##### Step 7a — the mailbox round, before both batches

```typescript
  // …continued: after the for-loop, inside the while. A reply relayed here never reaches the
  // boundary prompt, and an expiry routed here does, as the user_decision it became.
  const scan = JSON.parse(spawnSync("bash", [MB, "scan"]).stdout);   // writes the answered leg
  for (const r of scan.replied) {
    const rr = spawnSync("bash", [ROUTER, "resume", "--task-id", r.task_id, "--leg", "relayed"],
      { encoding: "utf8" });
    if (rr.status !== 0) { reportRefusedResume(r, "relayed", rr.stderr); continue; }
    const { resume_block: rb } = JSON.parse(rr.stdout);
    deliverResume(rb, rb.instruction);   // the answer is already fenced as data inside it
  }
  spawnSync("bash", [MB, "sweep"]);   // one expired leg, then the user_decision the batch shows
```

##### Step 7a — permission batch, at the boundary

```typescript
  // …continued: after the mailbox round, inside the while
  // 7a. Once per boundary, after every ready stage is dispatched: ≤4 parked needs per
  //     AskUserQuestion call, answered only by the user (workflow.md § Boundary
  //     permission prompt). ROUTER's batch holds every other parked need: a user_decision as
  //     its own question, any other kind as a user_action.
  const batch = JSON.parse(spawnSync("bash", [PARK, "batch"]).stdout);
  const typed = JSON.parse(spawnSync("bash", [ROUTER, "batch"]).stdout);
  for (const b of [batch, typed])   // both ran first, so a megatask park records every need
    if (b.mode === "megatask_park" && b.park) return stopParked(b.park);
```

##### Step 7a — one prompt, then each resume

```typescript
  // …continued: permission needs and typed needs are asked in the same round.
  const answers = [...batch.payloads, ...typed.payloads].flatMap(p => AskUserQuestion(p));
  for (const need of batch.needs) {
    const answer = answerFor(answers, need.task_id);
    if (answer === "manual") waitForUserRun(need);   // until the user reports having run it
    resumeDeniedStep(need, answer);
  }
  for (const need of typed.needs) resumeTypedNeed(need, answerFor(answers, need.task_id));
```

##### Step 7a — wake on the earliest deadline

```typescript
  // …continued: nothing dispatched, nothing asked, and an ask still open. Both paths only wake
  // the loop — the next boundary's scan relays, and its sweep expires whatever timed out.
  if (!ready.length && !batch.needs.length && !typed.needs.length && scan.open.length) {
    const due = Math.min(...scan.open.map(o => Date.parse(o.deadline))) + 5000;
    if (hasScheduleWakeup)   // optional tool: absent in most sessions, never a dependency
      ScheduleWakeup({ seconds: Math.max(1, Math.ceil((due - Date.now()) / 1000)) });
    else Monitor(Bash({ run_in_background: true,   // agent-coordination § Monitor Tool
      command: `bash ${MB} wait | tee -a .context/logs/mailbox-wait.log` }));
  }

  // Refresh — TL/DV may have added tasks since the last read.
  state = JSON.parse(fs.readFileSync(".context/state.json", "utf8"));
  tasks = Object.entries(state.tasks).map(([id, t]) => ({ id, ...t }));
}
```

##### Step 7a — the parked-need arms

The boundary code above calls helpers whose bodies and rules live in
`references/step-7a-arms.md`. Read the named section when its predicate holds.

| Read when | Section in `references/step-7a-arms.md` |
|---|---|
| a batch returns `mode: "megatask_park"`: `stopParked` | § Step 7a — the megatask arm |
| a permission need is answered: `resumeDeniedStep` | § Step 7a — resume only the denied step |
| a typed need is answered: `resumeTypedNeed` | § Step 7a — resume a typed need |
| a need resumes: `deliverResume` | § Step 7a — deliverResume, live or re-dispatched |
| a message or answer opens with `reply <ask_id>`: `ingestReply` | § Step 7a — an inbound reply, on any channel |

##### Step 7 — loop-back arm

```typescript
// Re-dispatching the gate row against unchanged code only burns retries, so the DV rows it
// depends on go back first; Step 4.6 then injects the gate's findings into their prompt.
function loopBackToDV(ledger, gateId, gateRow) {
  const h = parseFrontmatter(gateRow.artifact);
  const blockers = h?.blockers ?? h?.blocking_defects ?? [];  // DR/ST shape | QA shape
  const picked = spawnSync("bash", ["skills/worktask/scripts/loopback-targets.sh",
    "--state", ".context/state.json", "--gate", gateId], { encoding: "utf8" });
  let dvRows = picked.status === 0 ? picked.stdout.split("\n").filter(Boolean) : [];
```

##### Step 7 — loop-back, full-set fallback

```typescript
  // …continued: loopBackToDV body. Helper failure or empty output: the full transitive set.
  if (!dvRows.length) {
    const deps = new Set(), stack = [...(gateRow.blocked_by ?? [])];
    while (stack.length) {
      const id = stack.pop();
      if (!deps.has(id)) { deps.add(id); stack.push(...(ledger.tasks[id]?.blocked_by ?? [])); }
    }
    dvRows = [...deps].filter(id => /^DV\d+$/.test(id));
  }
```

##### Step 7 — loop-back, replay then stamp

```typescript
  // …continued: loopBackToDV body. Counts are read before any replay: --cascade clears
  // retry_count on every dependent, and one DV row can depend on another.
  const retries = Object.fromEntries(dvRows.map(dv => [dv, ledger.tasks[dv].metadata?.retry_count ?? 0]));
  for (const dv of dvRows) {
    if (spawnSync("state-patch.sh", ["--task-replay", dv, "--cascade"]).status !== 0) {
      return escalate(gateId);  // § Error Handling — a refused replay is never hand-edited
    }
  }
  for (const dv of dvRows) {  // argv, never sh(): gate_blockers is artifact text
    spawnSync("state-patch.sh", ["--task-meta", dv, "--set", JSON.stringify({
      gate_from_stage: gateRow.metadata.gate_from_stage, gate_blockers: blockers,
      retry_count: retries[dv] + 1 })]);
  }
}
```
