# Finalization gate

Read when FN is ready and before any FN dispatch.

Procedure routing: [orchestration](orchestration.md).

<a id="section-lookup-1"></a>
Related: [Hand-back guard](completion-handoff.md#hand-back-guard)

<!-- canonical-body:start -->
#### Step 4.9

```typescript
    // 4.9. FN gate — PL0.metadata.fn_gate (default "checkpoint"). The gate sits BEFORE the FN
    //      Agent() delegation so nothing remote happens pre-approval. N = state.json.run_index
    //      (default 0). § FN Gate below; Read references/fn-gate.md at FN time for the procedure.
    if (full.metadata.stage === "FN") {
      const fnGate = pl0.metadata.fn_gate ?? "checkpoint";
      const N = state.run_index ?? 0;
      // (a) Run the Pre-gate Conductor-attachments writer (checkpoint path only;
      //     references/fn-gate.md § Pre-gate Conductor-attachments writer) — local writes only.
      //     The bypass path falls through to FN-agent Writer 2 inside the FN stage.
```

##### Step 4.9 — sweep collection and classification (a1)(a2)

```typescript
      // …continued: step 4.9, after (a)
      // (a1) Collect the closing elicitation sweep: read facts.open_questions[] and keep the
      //      class-bearing items whose status != "resolved". Status is the WHOLE filter —
      //      items answered at their own boundary (step 6.6) or at the plan gate are already
      //      resolved. Never filter on stage: under blocks_next_stage any stage can be
      //      answered at its own boundary. Resolve each item's `ref` anchor to its full
      //      options[] body. Stage comes from the id's pinned sw-<TASK_ID>-<n> prefix and is
      //      used for GROUPING only; an explicit `stage` field wins when present, but it is
      //      optional, so never require it.
```

##### Step 4.9 — classify, then auto-answer (a2)

```typescript
      // …continued: step 4.9, after (a1)
      // (a2) Classify, then auto-answer. The raise-only guard runs FIRST, on every item
      //      (skills/worktask/references/plan-transition.md § Escalation guard — raise-only self-labels); only then,
      //      and only when decision_gate == "auto", does the Fable delegate answer the
      //      effective-decision items. No item reaches the delegate un-reclassified.
```

##### Step 4.9 — checkpoint and bypass paths

The checkpoint STOP below is a hand-back: run § Hand-back guard (`point: checkpoint`) first.

```typescript
      if (fnGate === "checkpoint") {
        // (b) fn_gate_waiting subject:"FN<N>".
        appendAudit({ actor: "orchestrator", action: "fn_gate_waiting",
                      subject: `FN${N}`, result: "ok" });
        // (c) Present the pre-FN summary: branch, resolved base branch, commit type,
        //     changed-file count, DR/QA verdicts, PR target + Closes #<issue>.
```

##### Step 4.9 — sweep render, then the unmoved STOP (c+)(d)

```typescript
      // …continued: step 4.9 checkpoint arm, after (c)
        // (c+) Render the collected sweep, grouped by originating stage, in AskUserQuestion
        //      calls of <=4 questions each (the tool's per-call ceiling). These PRECEDE the
        //      approve/reject call below and never merge into it: merging would overflow at
        //      4+ items and entangle sweep answers with the gate's reject/resume path.
        //      Question text comes from the resolved ref anchor body, not the stub (which
        //      carries no summary). Record each answer into the item itself — status =
        //      "resolved" plus resolution = "<answer>" — and append a sweep_resolved audit
        //      row (subject: `FN<N>`). NOT facts.decisions[] — stage-contracts.md
        //      § Closing Elicitation Sweep states why that destination is refused.
```

##### Step 4.9 — the approve/reject STOP (d), unmoved

```typescript
      // …continued: step 4.9 checkpoint arm, after (c+)
        // (d) AskUserQuestion: approve → append `approval_received subject:"FN<N>"` and fall
        //     through to delegate FN. Reject → append `approval_rejected subject:"FN<N>"`,
        //     result:"rejected", and STOP (do NOT delegate FN); surface the feedback, then
        //     resume per § FN gate rejection — resume path (fix routed to its owning stage,
        //     run_index frozen, this gate re-presented on completion).
```

##### Step 4.9 — bypass path

```typescript
      // …continued: step 4.9 else-arm
      } else {  // "bypass" — --auto=[finalization] / --emergency, or per-issue by /megatask
        // (e0) Bypass records decision-class items only: audit `sweep_recorded` for them.
        //      Effective-escalate items take the lane order in workflow.md
        //      § Escalation guard — escalate stops at every boundary: /megatask per-issue
        //      PARKS and STOPs (no FN); a no-human lane (CORPFLOW_NONINTERACTIVE=1, headless)
        //      audits `sweep_escalation_unprompted` {id, stage, ref} per item; any other lane
        //      renders them as (c+) does and records the answers before (e).
        // (e) fn_gate_bypass, then delegate FN unattended (commit/push/PR).
        appendAudit({ actor: "orchestrator", action: "fn_gate_bypass",
                      subject: `FN${N}`, result: "ok", reason: "unattended" });
      }
    }
```
