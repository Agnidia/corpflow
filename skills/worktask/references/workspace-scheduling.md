# Workspace scheduling

Read when executing or checking workspace scheduling.

Procedure routing: [orchestration](orchestration.md).

<!-- canonical-body:start -->
## Workspace Mode

Megatask (per-issue) tickets run in isolated workspaces. `.context/` base by mode (resolve via `task.metadata.workspace_path` + `metadata.isolation`):

| Mode | `.context/` base |
|------|------------------|
| Standard | `.context/` (main checkout — orchestrator + non-isolated stages) |
| Worktree | `.worktrees/milestone-{N}/{issue#}/.context/` |

In megatask per-issue/worktree mode, inside a Conductor workspace clone, or on any cwd↔workspace_path mismatch, read `references/workspace-modes.md` (detection snippet, Conductor sibling-repo rule, task-ID namespacing). Enforcement (workspace-root cross-check + `WORKSPACE_ROOT` banner injection) lives in `workflow.md` Phase 2. Full megatask docs: `../../megatask/SKILL.md`.

## Parallel Execution

### DC + QA Parallel (Default)

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-block DR0 --on DV0   # DR ← DV
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-block QA0 --on DR0   # QA ← DR
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-block DC0 --on DR0   # DC ← DR
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-block FN0 --on QA0,DC0   # FN ← QA AND DC
```

Use `--sequential` when DC requires test results.

### Monitor Tool Integration

Use `Monitor` to stream background-process events (builds, tests, logs) instead of polling. Persist raw stream output to `.context/logs/<kind>-<scope>-<timestamp>.log` per the `logging-conventions` skill.

### Never Parallelize

Rows apply only to stages present in the plan; a stage PL0 excluded imposes no ordering constraint.

- AR before PL (needs requirements)
- DV before TL (needs coordination)
- DR before DV (can't review unwritten code)
- QA before DR (DR must review code before QA tests)

## Error Handling

### Retry Logic

Each stage: max 3 retries, tracked in `metadata.retry_count`. Append one `## Retry N — <ts>` section per failure to `.context/errors/<agent>.md` (per-agent, append-only — `task-folder-organization` skill § Per-Agent Error Files) with problem, classification, root cause, attempted solutions. Raw stdout/stderr goes to `.context/logs/retry-<stage>-<ts>.log` per `logging-conventions`.

### Escalation Chains

The chains (11-stage, 9-stage, Emergency, Ethics) live in `skills/agent-coordination/SKILL.md §
Escalation Chains`. Stages absent from the plan drop out of the chain — escalation from DV goes to
TL if TL ran, else AR if AR ran, else PL.

### USER under /megatask

A `/megatask` per-issue run (`PL0.metadata.megatask_group`) has no user. Every path that ends at
USER first settles the issue, then stops: a chain's last link, a stop per § Error Handling,
`escalate()`, a Step 7 `blocked` row, a refused landing (§ Step 6.5d), a second mid-run
escalation, and `stopForUser`.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/megatask-settle.sh --subject <ID> --detail "<one line: why>"
```

It writes `workspace.json` `execution.status: "failed"`, `execution.reason: "escalated_to_user"`
and one `megatask_escalated` row, so `hooks/megatask-monitor.sh` frees the track and keeps the
dependents blocked. Outside `/megatask` it prints `result=skipped` and writes nothing, and it never
overwrites a settled status, so a PARK keeps its `parked_escalation`
(`references/step-7a-arms.md § Step 7a — the megatask arm`). Exit 1 (`result=refused`) leaves the track held: report the issue, the path
and the reason, and stop.
