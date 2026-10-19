# Headless arm — Step 6 launch and replay

Read this file only when `effort-route.sh` returns `route: "headless"`, which needs
`CORPFLOW_HEADLESS_ROUTE=on`. The in-process route never enters it. Parent: `skills/worktask/SKILL.md
§ Step 6 — Agent() dispatch (inproc) or headless-dispatch.sh (headless)`; script contract:
`skills/agent-coordination/references/headless-dispatch.md`. An unqualified `§` names a
section of `skills/worktask/SKILL.md`.

## Headless launch

The helper owns the worktree cwd, ledger-root env, validation and side-effect checks. It reads
ledger-owned permission mode, workspace and artifact itself; do not interpolate those values
into the Bash command. `--effort` is the route's tier, so a resolver bump reaches the child. `shellQuoteAll` quotes the orchestrator-owned arguments.

### Headless launch — open the arm

```typescript
    if (route.route === "headless") {
      const attempt = 1;
      const outLog = `.context/logs/headless-${task.id}-${attempt}.jsonl`;
      const promptFile = writePromptFile(task.id, attempt, prompt);
      parentMode = orchestratorSessionMode ?? "manual";
```


### Headless launch arguments

Run detached and wait through Monitor: a foreground call would impose the Bash tool's
10-minute cap. Always set `--out` to the canonical attempt log. Pass `timeout: 7200000` too:
when the orchestrator itself runs unattended (`-p`, SDK, CI), a background command stops at
30 min by default, which would cut a long stage off mid-run.

```typescript
      const hdArgs = ["--task", task.id, "--agent", subagentType, "--model", effectiveModel,
        "--effort", route.requested, "--ledger-root", _orch_root,
        "--parent-mode", parentMode, "--prompt", promptFile, "--session-id", childSessionId,
        "--out", outLog];
      const hd = Monitor(Bash({ run_in_background: true, timeout: 7200000,
        command: `bash skills/worktask/scripts/headless-dispatch.sh ${shellQuoteAll(hdArgs)}` }));
      const hdResult = JSON.parse(hd.stdout || "{}");
```

### Refused launch and safe fallback

Exit 2 refuses bad inputs; exit 3 reports side effects; neither permits fallback. On `warn` no
headless work ran: dispatch in-process at the route's tier, audit the new surface, and omit
`.headless` so no stop hooks replay.

```typescript
      if (hd.status === 3) { escalate(task.id, "side_effects_present"); continue; }
      if (hd.status === 2) { escalate(task.id, "headless_dispatch_refused"); continue; }
      if (hdResult.result === "warn") {
        launchAck = Agent({
          subagent_type: subagentType, model: effectiveModel, effort: route.requested, prompt,
          ...(stageSchema ? { schema: stageSchema } : {}),
        });
        appendAudit({ actor: "orchestrator", action: "effort_route", subject: task.id,
          result: "ok", metadata: { ...route, route: "inproc", effort_transport: "agent-param",
            reason: "headless_warn_fallback", fallback_reason: hdResult.fallback_reason } });
```

### Launch acknowledgement

```typescript
      } else {
        launchAck = { agent_id: childSessionId, headless: true, exit: hd.status, result: hdResult };
      }
    }
```

## Step 6 — after a headless child exits: replay, resume, escalate

A `claude -p --agent` main session does not fire SubagentStop. Replay the chain with
`headless-poststop.sh`, which registers the child-to-task mapping in the orchestrator ledger
**before any hook runs**. This keeps gates bound to the task across state-merge and retries,
including concurrent DV rows. Registration failure exits 2 and escalates without replaying.
Pass the ledger root separately from the child's workspace; Step 6a's later upsert is idempotent.

A blocked reply resumes the same child with the reasons and additional context. Replay attempts
1, 2 and 3 allow at most two resumes; a blocked third attempt escalates. A refused or `warn`
resume also escalates: side effects already exist, so no in-process fallback is allowed.

```typescript
    if (launchAck?.headless) {
      let attempt = 1;
      let poststop;
      let escalated = false;
      do {
```

### Register and replay stop hooks

```typescript
        const replay = spawnSync("bash", ["skills/worktask/scripts/headless-poststop.sh",
          "--task", task.id, "--session", childSessionId,
          "--orchestrator-session", orchestratorSessionId, "--agent", subagentType,
          "--ledger-root", _orch_root,
          "--workspace", full.metadata.workspace_path, "--artifact", full.metadata.artifact,
          "--effort-level", launchAck.result?.effort_resolved ?? "",
          "--attempt", String(attempt)], { encoding: "utf8" });
        try {
          if (replay.status !== 0) throw new Error("replay failed");
          poststop = JSON.parse(replay.stdout);
          if (typeof poststop.blocked !== "boolean") throw new Error("invalid verdict");
        } catch {
          escalate(task.id, "headless_poststop_refused"); escalated = true; break;
        }
```

### Prepare the resume prompt

Re-entering headless-dispatch applies the permission cap and side-effect snapshot again.
The script needs both `--session-id` for reporting and `--resume` for the same child; it omits
`--session-id` from the CLI argv when resuming, avoiding a refused pair or a fork.

```typescript
        if (poststop.blocked && !poststop.escalate) {
          attempt += 1;
          const resumeOutLog = `.context/logs/headless-${task.id}-${attempt}.jsonl`;
          const blockPromptFile = writePromptFile(task.id, attempt,
            `${poststop.reasons.join("\n")}\n\n${poststop.additional_context ?? ""}`);
```

### Dispatch the same child again

```typescript
          const resumeArgs = ["--task", task.id, "--agent", subagentType,
            "--model", effectiveModel, "--effort", route.requested, "--ledger-root", _orch_root,
            "--parent-mode", parentMode, "--prompt", blockPromptFile,
            "--session-id", childSessionId, "--resume", childSessionId,
            "--out", resumeOutLog];
          const resumeHd = Monitor(Bash({ run_in_background: true, timeout: 7200000,
            command: `bash skills/worktask/scripts/headless-dispatch.sh ${shellQuoteAll(resumeArgs)}` }));
          const resumeResult = JSON.parse(resumeHd.stdout || "{}");
```

### Refuse unsafe resume fallback

```typescript
          if (resumeHd.status === 3) {
            escalate(task.id, "side_effects_present"); escalated = true; break;
          }
          if (resumeHd.status === 2) {
            escalate(task.id, "headless_dispatch_refused"); escalated = true; break;
          }
          if (resumeResult.result === "warn") {
            escalate(task.id, "headless_resume_warn"); escalated = true; break;
          }
          launchAck = { agent_id: childSessionId, headless: true, exit: resumeHd.status, result: resumeResult };
        }
```

### Enforce the replay cap

`break` leaves the retry loop; `continue` below advances the outer stage loop only after the
escalation. Never re-enter a still-blocked do/while after a refused resume.

```typescript
      } while (poststop.blocked && !poststop.escalate);
      if (escalated) { continue; }
      if (poststop.blocked && poststop.escalate) { escalate(task.id, "headless_poststop_block"); continue; }
    }
```

### Optional control preservation

The dispatcher reads optional compaction and retry controls from the same ledger row on fresh launch and resume.
It exits 2 instead of emitting a fallback warning when an in-process fallback would discard a configured control.
Treat this as a refused dispatch, including CLI absence, a version below 2.1.303, authentication failure, and unresolved agent identity.
A child that already changed files still exits 3 under the existing side-effect guard.
