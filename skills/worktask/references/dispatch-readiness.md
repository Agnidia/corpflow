# Dispatch readiness

Read when executing or checking dispatch readiness.

Procedure routing: [orchestration](orchestration.md).

<a id="section-lookup-1"></a>
Related: [FN Gate](finalization-policy.md#fn-gate) · [Platform tooling ownership](completion-handoff.md#platform-tooling-ownership)

<!-- canonical-body:start -->
## Orchestrator Execution Loop

This loop dispatches each ready stage once — in-process via `Agent()`, or headless when
`effort-route.sh` returns `route: "headless"` (§ Step 6 — route before every dispatch) — from the
PL0 precondition (below)
through the FN gate (§ FN Gate), advancing stages as their `blockedBy` dependencies resolve.

Figma asset persistence is not an orchestrator step: the product-manager captures and persists
screenshots to `.context/designs/` inside the PL turn via its `Bash(curl:*)` grant, because
`get_screenshot` returns a short-lived URL. Don't add a post-PL0 download step — it collides with
the Phase-1 Bash prohibition in `workflow.md` and races the expiring URL
(`skills/shared/figma-capture.md § Capture Workflow`).

### Before this loop — autonomy preflight (Phase 1)

An unattended launch (`--auto` containing `plan` or `finalization`) runs
`scripts/autonomy-preflight.sh` before Step 3 creates `.context/`, with its output buffered under
`$TMPDIR`. Any failed permission grant, evidence tool or toolchain check stops the run there, in a
single message, before anything is seeded; a pass is recorded after the Step 3a seed as
`metadata.preflight` (`skills/worktask/references/contracts/ledger-preflight.md § metadata.preflight`). Megatask per-issue
runs skip it. Canon, including `--accept-absent` and the non-interactive Step 2a scan:
`skills/worktask/references/autonomy-preflight.md § Step 2a-pre` and `skills/worktask/references/launch-seed.md § Step 3a — record the autonomy preflight`.

### Delegation-only

The orchestrator never writes code, tests or docs during a worktask, and never runs build commands
or marks a task completed without delegating. Every change is made by the stage agent that owns it,
through `Agent()` — including one-line fixes, because an orchestrator edit lands in no stage's
`files_touched`, is reviewed by no DR or SR, and appears in no artifact. Reading is unrestricted.
When a stage returns work that is nearly right, re-dispatch it with the correction instead of
patching it here. The orchestrator's job is the loop: read tasks, resolve agents, delegate, track
status.

#### Delegation-only — the build-tooling corollary

The orchestrator holds no build or test tooling; DV/DR/QA delegate to the detected platform's
`/<plugin>:build-test` (§ Platform tooling ownership). Don't re-add a platform's MCP grants
(`mcp__XcodeBuildMCP__*` and the like) to a stage agent to work around this; the plugin that owns the
toolchain owns its lifecycle.

### Dispatch on the same turn

Verify a boundary and dispatch the next ready stage in the same turn; report after dispatching, not
instead of it. A running background `Agent` does not block the orchestrator, so "an agent is working"
is no reason to stop, and ending a turn with "next: DC → RE → FN" while those stages are
dispatchable leaves the pipeline idle until a human asks. Exactly four things justify stopping
mid-pipeline: the plan gate (`workflow.md § Step A.5`), an `escalate`-class sweep item, the
prompt for a parked permission denial or typed need (§ Step 7a, asked only after every ready stage
is dispatched), and the FN gate (§ FN Gate).

#### Readiness is mechanical, not a judgement call

> Between stages, ask the ledger:
>
> ```bash
> jq -r '.tasks as $t | $t | to_entries[]
>   | select(.value.status == "pending")
>   | select([(.value.blocked_by // [])[] | $t[.].status] | all(. == "completed"))
>   | .key' .context/state.json
> ```
>
> A `stale` row answers neither filter: it is not `pending`, so it is never returned, and it is not
> `completed`, so a row blocked by it is not returned either. It leaves that query only when
> § Step 6.5d settles it (`skills/worktask/references/contracts/ledger-status.md § Status Values`).
>
> A name returned with nothing live means there is work to do — dispatch it, including right after a
> big green result, which is a handoff, not a completion.
