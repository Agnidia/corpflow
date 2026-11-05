# Dispatch agent

Read when executing or checking dispatch agent.

Procedure routing: [orchestration](orchestration.md).

<!-- canonical-body:start -->
### Worktask stages: explicit, never inherited

Before each stage dispatch, the orchestrator passes the ledger's resolved `metadata.model` as an explicit short alias.
No agent carries `model:` frontmatter. An omitted argument silently inherits the parent model and can lose the sized effort tier.
The matrix is [stage-codes](stage-codes.md#agent-model-matrix); effort ceilings remain in `skills/shared/model-selection.md`.

##### Step 5f — model resolution

Before dispatch, use the cached Fable credit capability; record requested and effective models separately.

```typescript
const modelRequested = model;
let effectiveModel = model;
if (model === "fable" && state.facts?.capabilities?.fable_dispatch === "credit_blocked") {
  effectiveModel = "opus";
  appendAudit({ actor: "orchestrator", action: "model_resolution_constrained",
                subject: task.id, result: "ok",
                metadata: { requested: "fable", resolved: "opus", reason: "capabilities.fable_dispatch=credit_blocked" } });
}
```

<a id="step-6--degrade-path--cache-prefix"></a>
<a id="step-6--the-dispatch-call"></a>
#### Step 6 — typed-schema dispatch

Pass `<CODE>Handoff` as the optional `schema` argument, never in prompt sections [1][2][4][4b] or `full.description`.
A validated typed return supersedes the frontmatter scrape through [facts-merge](contracts/facts-merge.md#schema-to-state-map).
If the host rejects `schema`, omit it and use Step 6.5's scrape with F3 fallback.
The agent always writes artifact and frontmatter for durability and F4.

##### Step 6 — compose the brief

After Step 4.8 re-stamps the workspace, compose from the same row.
A non-zero exit blocks the task, audits `brief_compose_failed`, and follows escalation; never launch the agent.

```typescript
const composed = spawnSync("bash", ["skills/worktask/scripts/brief-compose.sh", task.id,
                                    "--orch-root", _orch_root], { encoding: "utf8" });
if (composed.status !== 0) {  // 1 = guard failure, 2 = usage/ledger/canon; stdout is empty
  sh(`state-patch.sh --task-status ${task.id} blocked`);
  appendAudit({ actor: "orchestrator", action: "brief_compose_failed", subject: task.id,
                result: "blocked", metadata: { exit: composed.status, stderr: composed.stderr.trim() } });
  continue;  // no Agent(): surface the stderr per § Escalation Chains
}
```

##### Step 6 — splice the injections

Preserve [1]–[5]. Match the first line-anchored marker: a blocker in [6] can end with the same text.

```typescript
const [hints, banners] = full.description.split(INJECTION_SPLIT).map(s => s.trim());
const HINTS = "<<<retry-hints>>>\n";
const cut = composed.stdout.indexOf("\n" + HINTS) + 1 + HINTS.length;
const prompt = composed.stdout.slice(0, cut) + (hints ? `${hints}\n` : "") +
               composed.stdout.slice(cut) + (banners ? `\n${banners}\n` : "");
```

##### Step 6 — session identifiers (r4-2)

Keep these bindings outside the dispatch arm for resume. The child UUID differs from the parent's runtime identity.
Each attempt passes the prompt through stdin rather than a shell argument.

```typescript
const childSessionId = crypto.randomUUID();
const orchestratorSessionId = process.env.CLAUDE_SESSION_ID ?? null;
const orchestratorSessionMode = process.env.CLAUDE_PERMISSION_MODE ?? null;
let parentMode;
function writePromptFile(taskId, attempt, contents) {
  const p = `.context/logs/prompt-${taskId}-${attempt}.txt`;
  fs.writeFileSync(p, contents);
  return p;
}
```

##### Step 6 — route before every dispatch, headless or in-process

The orchestrator routes the main loop, DV fan-out, C.0a, and C.3 through `effort-route.sh`.
Pass complete task metadata as `--dispatch-controls`, including on redispatch.
Only rows without effort AND optional controls may skip routing.
Configured controls require `CORPFLOW_HEADLESS_ROUTE=on`; refuse unsupported Codex/in-process launches.
Controlled rows missing effort must reach the router; stamp effort before retrying a refusal.

###### Step 6 — compute the route

```typescript
const hasDispatchControls = ["auto_compact_window", "retry_watchdog", "retry_watchdog_max_wait_ms",
  "retry_watchdog_max_usage_limit_wait_ms", "overloaded_retry_max_delay_ms"]
  .some(key => Object.prototype.hasOwnProperty.call(full.metadata, key));
const routed = (full.metadata.effort || hasDispatchControls) && spawnSync("bash", ["skills/worktask/scripts/effort-route.sh",
  "--agent", subagentType, "--model", effectiveModel, "--requested", full.metadata.effort ?? "",
  ...(state.facts?.capabilities?.effort_cap?.[effectiveModel]
    ? ["--cap", state.facts.capabilities.effort_cap[effectiveModel]] : []),
  "--dispatch-controls", JSON.stringify(full.metadata)],
  { encoding: "utf8" });
if (routed && routed.status !== 0) { escalate(task.id, "effort_route_refused"); continue; }
const route = routed ? JSON.parse(routed.stdout)
  : { route: "inproc", effort_transport: "frontmatter", reason: "effort_unstamped" };
```

###### Step 6 — the effort argument and the route row

A refused route escalates before launch. `agent-param` passes the stamped effort; `none` (Haiku) passes no effort.
Audit every surface; the headless spawn fills `session_id`.

```typescript
const effortArg = route.effort_transport === "agent-param" ? { effort: route.requested } : {};
appendAudit({ actor: "orchestrator", action: "effort_route", subject: task.id, result: "ok",
  metadata: { ...route, session_id: null } });  // filled once headless spawns
```

##### Step 6 — Agent() dispatch (inproc) or headless-dispatch.sh (headless)

Step 4.8 already pins the workspace. Never pass `isolation: "worktree"`, which forks an unrecorded tree.
For `route.route === "headless"`, follow [headless-arm](headless-arm.md) for launch, safe fallback, and post-exit replay.
Otherwise dispatch in-process:

```typescript
const stageSchema = HANDOFF_SCHEMA[full.metadata.stage];
let launchAck;
if (route.route === "headless") {
} else {
  launchAck = Agent({
    subagent_type: subagentType,
    model: effectiveModel,
    ...effortArg,  // agent-param: the stamped tier, honoured in-process since 2.1.292
    prompt,  // composed stdout with [6]/[7] spliced in, never full.description
    ...(stageSchema ? { schema: stageSchema } : {}),
  });
}
```
