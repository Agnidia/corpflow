# Completion merge

Read immediately after a stage agent returns, before marking its task complete.

Procedure routing: [orchestration](orchestration.md).

<!-- canonical-body:start -->
<a id="step-65a--why-the-arm-ends-in-continue"></a>
<a id="step-65a--last_error-patch"></a>
#### Step 6.5

```typescript
    // 6.5-pre. Read handoff.requests_stage_escalation from the artifact frontmatter BEFORE any
    //          status stamp lands (Layer 2/3 below stamp the verdict-mapped status) — validate, then
    //          accept (--task-create/--task-block + metadata.added_stages) or reject naming the
    //          failed condition. Semantics: § Mid-run escalation — the orchestrator is the consumer.
    // 6.5. Patch state.json from artifact frontmatter if the agent didn't — layer #3 after the
    //      in-agent atomic write and the optional SubagentStop hook.
    //      See skills/worktask/references/contracts/fallbacks.md#fallback-paths F2/F3.
    if (fs.existsSync(".context/state.json")) {
      const post = JSON.parse(fs.readFileSync(".context/state.json", "utf8"));
      const code = full.metadata.stage;

```

##### Step 6.5a — errored return

On error, preserve partial work, classify and patch the failure, then continue to retry routing.
Never run the completion patch; retain escalation counts.

```typescript
if (launchAck?.result === "error" || launchAck?.errored) {
  const cls = classifyError(launchAck);
  const runIndex = full.metadata.run_index ?? 0;
  const stateForFailed = JSON.parse(fs.readFileSync(".context/state.json", "utf8"));
  const esc = escalationBookkeeping(stateForFailed, task, cls);
  atomicMergeStateJson({
    tasks: { [task.id]: {
      ...(esc.terminal ? { status: "failed" } : {}),
      last_error: {
        class: esc.terminal ? "exhausted" : cls,
        partial: Boolean(launchAck?.partial), at: new Date().toISOString(),
        ref: `.context/errors/${errorBasename(subagentType)}.md#retry-${runIndex}` },
      metadata: esc.metadata } },
    facts: { dispatched_agents: markDispatchStatus(stateForFailed, task.id, "failed") }
  });
  continue;
}
```

##### Step 6.5a1–a4 — the return arms, before Layer 2

Every return runs the detection code below, in order. Each arm's body, helpers and rationale
live in `references/return-arms.md`; read its section when the predicate holds.

| Read when | Section in `references/return-arms.md` |
|---|---|
| 6.5a fires: `escalationBookkeeping` | § Step 6.5a1 — the escalation target |
| `incomplete` is true | § Step 6.5a2 — why a mid-stage yield needs its own arm |
| `typedNeed` is true, or the route parks a need | § Step 6.5a3 — why a typed blocked return needs its own arm |
| `ack.status !== 0`: `resendOnceOrEscalate` | § Step 6.5a4 — why delivered is not acknowledged |
| `classify` exits 0: the stage parks | § Step 6.5a4 — why a permission denial needs its own arm |
| any message to a stage: `sendStageMessage` | § Step 6.5a4 — every stage message carries a msg_id |

##### Step 6.5a2 — incomplete return (mid-stage yield)

```typescript
      // 6.5a2. The stage yielded without finishing its handoff. Precondition — the agent is NOT
      //        live (Step 6.5's liveness rule bars this block while agent_id lives).
      const incArtifact = stageArtifactPath(code, full.metadata.run_index ?? 0, post.tasks?.[task.id]);
      const incHandoff = fs.existsSync(incArtifact) ? parseFrontmatter(incArtifact) : null;
      const selfPatched = post.tasks?.[task.id]?.status === "completed"
                          && Boolean(post.tasks[task.id].verdict);
      // Incomplete even WITH a verdict: a maxTurns stop can land after the frontmatter
      // is written. Field name unconfirmed: read defensively, recheck at /cc-update.
      const maxTurnsPartial = Boolean(launchAck?.partial);
      const incomplete = maxTurnsPartial || (!selfPatched && !incHandoff?.verdict);
      // incomplete → return-arms.md § Step 6.5a2: auto-resume ≤2 per row, then escalate
```

##### Step 6.5a3 — route every typed blocked return

```typescript
      // …continued: after the 6.5a2 block; ROUTER = scripts/blocked-on-dispatch.sh. No branch
      // picks an arm by hand: the router reads the arm table from blocked-on-lib.sh.
      const typedNeed = !incomplete && incHandoff?.verdict === "blocked"
        && Boolean(incHandoff?.blocked_on);
      const routed = !typedNeed ? null : spawnSync("bash", [ROUTER, "route", "--task-id", task.id,
        "--payload", JSON.stringify(incHandoff)], { encoding: "utf8" });
```

##### Step 6.5a3 — what the route result decides

```typescript
      // …continued. Exit 1 is a malformed need: re-dispatch with its fail: line, as § Step 6.5c.
      if (routed?.status === 1) { redispatch(task.id, { suffix: routed.stderr }); continue; }
      if (routed && routed.status !== 0) { escalate(task.id); continue; }   // 2: § Error Handling
      const out = routed ? JSON.parse(routed.stdout) : null;
      const rb = out?.resume_block;   // a host_environment re-probe that passed, or an artifact already landed
      if (rb) { deliverResume(rb, rb.instruction); continue; }
      if (out?.arm === "peer_session") { deliverAsk(out); continue; }   // return-arms.md: deliverAsk
      if (out && out.arm !== "permission") continue;   // parked; § Step 7a asks
      // A permission need, or a blocked return with no typed need, goes on to § Step 6.5a4.
```
