# Completion handoff

Read when executing or checking completion handoff.

Procedure routing: [orchestration](orchestration.md).

<a id="section-lookup-1"></a>
Related: [After PL0 — steps 1–3](loop-entry.md#after-pl0--steps-13) · [Step 4.9](finalization-gate.md#step-49) · [Post-Worktask Self-Improvement](finalization-publish.md#post-worktask-self-improvement)

<!-- canonical-body:start -->
#### Key rules

- Patch status at every transition (in_progress at claim, the verdict-mapped status at completion)
- Execute a stage only after its `blocked_by` dependencies have settled
- Pass `model` from task metadata to the Agent tool (`model: opus` → `model: "opus"`); don't rely on frontmatter inheritance
- Stamp `metadata.effort` on the task row: it is the ledger record the Step C.0a resolver bumps, and the only place a per-stage override (DV at `xhigh`) is recoverable. In-process it becomes the `Agent` call's `effort`, except on haiku, which gets none (transport `none`); headless dispatch turns it into `--effort`
- `metadata.agent`: always fully-qualified `plugin:agent` (`corpflow:developer`, `apple-developer:ios-developer`)
- A stage agent failing after 3 retries escalates per the error handling chain

##### Key rules — completion & tooling

- Mark a task `completed` only after delegating it and receiving its result (§ Completion signal); an errored return routes to the retry/escalate matrix, never to completion
- Drive the loop with the `state.json` ledger (read directly, written only via `state-patch.sh`) and the Agent tool
- Re-read the ledger at loop entry, after TL/DV stages (which may add tasks), and every 3rd iteration: at ≤500 tokens a re-read beats reasoning about staleness

###### Do not reintroduce the Task System

- corpflow does not use `TaskCreate`/`TaskUpdate`/`TaskGet`/`TaskList` (`skills/worktask/references/state-ledger.md`).

### PL Issue Publish

`scripts/publish-pl-issue.sh` runs between PL0 completion and stage-loop entry (§ After PL0 — steps 1–3, step 3). It never blocks the run: every operational outcome exits 0 and writes one `github_issue_created` audit row. The published body carries no local paths, `.context/` references or artifact filenames (PL0 authoring hygiene first, then a two-pass sanitiser and a >50% strip-ratio abort). Outcome vocabulary, reason enum, strict mode, title resolution, sanitiser rules, skip paths and cross-run dedup: `references/pl-issue-publish.md`.

### Platform tooling ownership

The orchestrator holds no platform build or test tooling. DV, DR, and QA each delegate to the
detected platform's `/<plugin>:build-test`, and every dev plugin owns its own toolchain: build-system
detection, MCP servers, cold-start handling, and the raw-CLI fallback when its MCP server is absent.
Plugin resolution: `skills/shared/compatible-plugins.md § Registry`.

#### No pre-warm, and what to expect

The orchestrator does not warm platform MCP servers, since that would need platform tool grants at
the orchestrator (`skills/agent-coordination/SKILL.md § MCP Tool Inheritance`). The first delegated
build may pay a cold-start retry inside the plugin or take its CLI fallback path — both reported by
the plugin, neither aborts the stage. A missing plugin falls back to the project's own build command
with a `plugin_unavailable` audit row.

### DV Batch Checkpointing

A DV agent running several non-separable batches records each finished batch in
`tasks.<ID>.progress` (`agents/developer.md § Budget-Aware Checkpointing`); loop step 4.7 reads it
on re-dispatch so the run resumes from `next_batch`.

### Hand-back guard

A run hands back at three points: the loop exit and the megatask per-issue end at ST (both in
§ Post-Worktask Self-Improvement), and a checkpoint return (the § Step 4.9 FN-gate STOP or a
partial return). It never hands back while a child of this run is live, because the parent's
stop frees the megatask track and the next turn can reassign it under the running child. The
megatask track rule (`../../megatask/SKILL.md § Starting and completing an issue`) is the second
line of defence when this guard cannot verify liveness.

#### Hand-back guard — the live check

Candidates: `facts.dispatched_agents[]` entries with `status: "launched"`, plus `tasks.*` rows
with `status: "in_progress"`. Run `claude agents --json --all`, falling back to `ListAgents`.
`--all` also lists finished sessions, so an absent row means gone, not merely finished. Join each
candidate with the rule that `scripts/stale-check.sh` and `references/resume.md § Live-agent rows`
already use: `agent_id`/`id`/`sessionId`, prefix-tolerant, with `subagent_type` as a best-effort
match when `agent_id` is absent. A row with `state: done` is not live. Liveness is defined there,
not here.

#### Hand-back guard — verdicts

Every outcome of the live check maps to exactly one row. Nothing that is unclear maps to `clear`.

| Live check | Action | `result` |
|---|---|---|
| every candidate is absent or `done` | hand back | `clear` |
| a candidate is busy (`waitingFor` empty) | wait on its completion notification, never a poll loop, bounded by `agent-coordination § Stall Timeout`; then run the guard again | `deferred` |
| a candidate is parked | § Hand-back guard — parked children | `parked` |
| the CLI ran but liveness is indeterminate: non-zero exit, unparseable output, an unrecognised shape or token | hand back | `unverified` |
| neither CLI is available | hand back | `unverified` |

#### Hand-back guard — parked children

Take the `resume.md` arm for the park kind. A reattach makes the child busy again, so run the
guard again after it: the run never hands back while a reattached child runs.

| Park kind | `resume.md` arm | Then |
|---|---|---|
| `waitingFor` is `approval` or `input` | § Live-agent rows — liveness branch — alive and responsive: `SendMessage` the ledger's answer | run the guard again |
| `state: blocked` | § Live-agent rows — parked or gone: reattach via `SendMessage` | run the guard again |
| "Needs input" (operator-owned) | § Live-agent rows — liveness branch — parked, awaiting input: surface the prompt, never auto-answer | attended: wait for the operator, then run the guard again; unattended: hand back |
| a hook schema error | § Live-agent rows — broken hook configuration | hand back; the operator fixes the hook |

#### Hand-back guard — the audit row

Write one `handback_guard` row per evaluation through a standalone `state-patch.sh --audit-row`,
**before** any wait: a session that dies while it waits still leaves the trace.

```json
{"actor":"orchestrator","action":"handback_guard","subject":"<worktask_id>",
 "result":"clear|deferred|parked|unverified",
 "metadata":{"point":"loop_exit|megatask_st|checkpoint",
             "live":["<TASK_ID>:<agent_id|subagent_type>"],
             "source":"claude agents --json|ListAgents|none"}}
```
