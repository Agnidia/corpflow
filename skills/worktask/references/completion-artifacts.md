# Completion artifacts

Read when executing or checking completion artifacts.

Procedure routing: [orchestration](orchestration.md).

<a id="section-lookup-1"></a>
Related: [Step 6.5](completion-merge.md#step-65) · [Step 7](retry-routing.md#step-7) · [Delegation-only](dispatch-readiness.md#delegation-only)

<!-- canonical-body:start -->
##### Step 6.5a4 — message ack check

```typescript
      // …continued: after the 6.5a3 block. Reached by a completed return, or a blocked one 6.5a3
      // did not park; 6.5a2, 6.5a3 and 7a sends are checked at the return they provoke. A fix
      // round reuses the task key, so --run-index keeps an earlier dispatch's messages out.
      const ack = spawnSync("bash", ["skills/worktask/scripts/ack-check.sh", "--task", task.id,
        "--run-index", String(full.metadata.run_index ?? 0),
        ...(fs.existsSync(incArtifact) ? ["--artifact", incArtifact] : [])], { encoding: "utf8" });
      if (ack.status !== 0) {   // 1 not delivered, 3 acted_on mismatch, 2 the check itself failed
        atomicMergeStateJson({ tasks: { [task.id]: { status: "in_progress" } } });
        resendOnceOrEscalate(state, task, subagentType, ack);
        continue;   // judged again at the next boundary; never falls through to Layer 2
      }
```

##### Step 6.5a4 — detect and park (permission denial)

```typescript
      // …continued: after the 6.5a4 ack check; PARK = scripts/permission-park.sh.
      // A completing or failing verdict never reaches classify (next section).
      const parkable = !incomplete && ["blocked","escalate"].includes(incHandoff?.verdict);
      const typed = parkable && Boolean(incHandoff?.blocked_on);
      const pd = !parkable ? null : spawnSync("bash",
        [PARK, "classify", ...(typed ? ["--payload", JSON.stringify(incHandoff)] : [])],
        { input: typed ? "" : stageReturnText });
      if (pd?.status === 0) {
        // Ledger via state-patch.sh plus one deduped, redacted permission_denied row; retry_count,
        // escalation_counts and last_error stay untouched.
        spawnSync("bash", [PARK, "park", "--task-id", task.id, "--detail", pd.stdout.trim()]);
        continue;   // siblings keep moving; § Step 7a asks
      }
```

###### Step 6.5a4 — which returns reach classify

Only a `blocked` or `escalate` verdict reaches the arm, and a handoff that carries `blocked_on`
passes it as `--payload`. A completing verdict (`ok`, `pass`, `go`, `approve`) or a failing one
(`fail`, `reject`, `no-go`) never reaches classify, even when its text quotes classifier wording:
that return settles through § Step 6.5 as usual. The returned text is the fallback, since
PermissionDenied firing inside a subagent is unverified. `--tool` and `--command` are optional on
that path, because classify recovers both from the last Tool(...) line at or before the classifier
wording, so a completed call quoted above the denied one never names the command. If it cannot
recover a tool it exits 1, and the return stays an ordinary blocked return for § Step 7.

##### Step 6.5a4 — what the orchestrator never does with a denial

- Never land the denied command yourself, nor anything with the same effect. § Delegation-only
  already forbids it, and a hand-landed command carries no grant: it is the workaround the stage
  was told not to take, moved up one level.
- Never spend a retry on it: no `retry_count` increment, no `last_error`, no `classifyError`, no
  Escalate-to edge (`agent-coordination § Retry / Escalate Matrix`, row `permission_denied`).
- Never grant. "Grant and continue" means the user grants in Claude Code's own permission UI;
  corpflow writes no allow rule or setting, and if the resumed call is denied again the stage
  simply parks again.

##### Step 6.5 — verdict → status

```typescript
// Mirror of state-patch.sh verdict_status, which stays the SSOT — status-enum-parity.bats diffs
// the two. A verdict absent here is refused by the writer (exit 3); never default one.
const VERDICT_STATUS = {
  ok: "completed", pass: "completed", go: "completed", approve: "completed",
  blocked: "blocked", escalate: "blocked",
  fail: "pending", reject: "pending", "no-go": "pending",
};
const rowMatchesHandoff = (row, h) =>
  Boolean(h?.verdict) && row?.verdict === h.verdict && row?.status === VERDICT_STATUS[h.verdict];
```

##### Step 6.5 — Layer 2 (synchronous patch)

```typescript
      if (!rowMatchesHandoff(post.tasks?.[task.id], incHandoff)) {
        const runIndex = full.metadata.run_index ?? 0;
        const artifactPath = stageArtifactPath(code, runIndex, post.tasks?.[task.id]);  // the row's artifact when it names one
        // Layer 2 (synchronous): state-patch.sh is the single implementation (hooks/state-merge.sh
        // is a thin wrapper); `--via step6_5` stamps completed_via=step6_5 vs the hook default:
        //   bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --stage <code> --task-id ${task.id} --artifact <path> --via step6_5
        // (equivalently: STATE_MERGE_VIA=step6_5 bash hooks/state-merge.sh)
        runStateMergeHook(artifactPath, code, /* via */ "step6_5");
```

##### Step 6.5 — Layer 3 (F3)

```typescript
        const post2 = JSON.parse(fs.readFileSync(".context/state.json", "utf8"));
        const handoff = parseFrontmatter(artifactPath);
        const status = VERDICT_STATUS[handoff?.verdict];
        // Layer 3 (F3): only a mapped verdict is stamped. No handoff, or a verdict the writer
        // refused, writes nothing — 6.5a2 resumes the first, Step 7 escalates the second.
        if (status && !rowMatchesHandoff(post2.tasks?.[task.id], handoff)) {
          const patch = buildPatchFromHandoff(code, handoff);
          const entry = patch.tasks[task.id];
          entry.status = status;
          entry.completed_via ??= "f3";
          if (status === "pending") entry.metadata = { ...entry.metadata, gate_from_stage: code };
          atomicMergeStateJson(patch);
        }
      }

```

##### Step 6.5b — dispatch entry completed

Re-read the ledger before replacing the dispatch array. Backfill the runtime model and attribute cost to that resolved model.

```typescript
const stateForDispatch = JSON.parse(fs.readFileSync(".context/state.json", "utf8"));
atomicMergeStateJson({
  facts: {
    dispatched_agents: markDispatchStatus(stateForDispatch, task.id, "completed", launchAck?.model_resolved),
  },
});
```

###### Step 6.5b-cap — cache the observed effort ceiling

Cache only a lower hook-reported tier, per model; unknown/missing rows never supply a ceiling.
This also covers session-wide operator effort pins. Later routes pass the cached ceiling through `--cap`.

```typescript
const observedEffort = effortResolvedFromHookRows(task.id);  // null when no hook row
if (observedEffort && route.effort_transport !== "none"
    && effortRank(observedEffort) < effortRank(route.requested)) {
  atomicMergeStateJson({ facts: { capabilities: { effort_cap: {
    [effectiveModel]: observedEffort, checked_at: new Date().toISOString() } } } });
  appendAudit({ actor: "orchestrator", action: "effort_cap_cached", subject: task.id,
    result: "ok", metadata: { model: effectiveModel, requested: route.requested, observed: observedEffort } });
}
    }
```
