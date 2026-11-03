# Dispatch recording

Read when executing or checking dispatch recording.

Procedure routing: [orchestration](orchestration.md).

<!-- canonical-body:start -->
<a id="step-6a"></a>
<a id="step-6a--id-less-entry"></a>
#### Step 6a — record the launched child

The orchestrator upserts one `facts.dispatched_agents[]` row per task id.
`--dispatch` clamps the array; Step 6.5 later records completed/failed.
The child alone runs `--claim`; resume adopts id-less Claude rows by `subagent_type`.
Codex instead requires the real returned identifier ([codex-runtime](../../shared/codex-runtime.md)).

```typescript
if (fs.existsSync(".context/state.json")) {
  if (launchAck?.agent_id) {
    execFileSync("bash", ["skills/worktask/scripts/state-patch.sh", "--dispatch",
                          task.id, launchAck.agent_id, "launched"]);
  } else {
    const cur = JSON.parse(fs.readFileSync(".context/state.json", "utf8")).facts?.dispatched_agents ?? [];
    atomicMergeStateJson({ facts: { dispatched_agents: [...cur.filter(a => a.task_id !== task.id),
      { stage: full.metadata.stage, task_id: task.id, subagent_type: subagentType,
        model_requested: modelRequested, status: "launched" }] } });
  }
```

##### Step 6a — keys --dispatch does not write

Merge optional names and resolved models onto the fresh whole array: arrays replace under the atomic merge.
`--dispatch` already writes stage, task id, subagent type, agent id, status, and requested model.
Use [atomic-write](contracts/ledger-writes.md#atomic-write); a failed write follows the existing ledger error path.

```typescript
  const extra = {
    ...(full.metadata.spawn_name ? { name: full.metadata.spawn_name } : {}),
    ...(effectiveModel !== modelRequested ? { model_resolved: effectiveModel } : {}),
  };
  if (Object.keys(extra).length > 0) {
    const agents = JSON.parse(fs.readFileSync(".context/state.json", "utf8")).facts.dispatched_agents;
    atomicMergeStateJson({ facts: { dispatched_agents:
      agents.map(a => (a.task_id === task.id ? { ...a, ...extra } : a)) } });
  }
}
```
