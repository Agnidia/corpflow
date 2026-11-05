---
name: worktask
description: Use when running one task through the staged worktask pipeline (plan, build, review, test, docs, PR) with plan and finalization gates and a resumable state ledger
argument-hint: '"<task description>" [--secure|--full] [--emergency] [--priority <High|Medium|Low>] [--platform <p>] [--ethics-review] [--with-design] [--sequential] [--no-gh-issue] [--auto=[plan,decision,finalization]] [--accept-absent=<tool[,tool]>] | --resume <STAGE_ID> [--cascade]'
version: 0.8.0
allowed-tools: Read, AskUserQuestion, SendMessage, ListAgents, Monitor, TaskStop, Bash(claude:*), Glob, Grep, Bash(mkdir:*), Bash(gh:*), Bash(git:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/hook-install.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/preflight-issue-scan.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/fn-preflight.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/branch-name.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/refine-branch-target.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/publish-pl-issue.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/handoff-harness.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/effort-ladder-cli.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/model-matrix.sh --resolve *), Agent, Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/autonomy-preflight.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/seed-state.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/workspace-root-banner.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/brief-compose.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/land-artifacts.sh --producer *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/land-artifacts.sh --consumer *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/land-artifacts.sh --list-landed *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/megatask-settle.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/loopback-targets.sh *)
related:
  - skills/worktask/references/workflow.md
  - skills/worktask/references/orchestration.md
  - commands/megatask.md
  - skills/megatask/SKILL.md
  - skills/worktask/references/stage-codes.md
  - skills/agent-coordination/references/headless-dispatch.md
  - agents/workflow-engineer.md
---

# Worktask

Run one task through the staged pipeline with a durable ledger, isolated worktrees, and independent approval gates.
This skill is the canonical entry point and supports both explicit invocation and relevant task requests.

## Invocation

Use the installed skill name: `$worktask` in Codex, or `/corpflow:worktask` in Claude Code plugins.
Other hosts use their registered skill name; packaging and runtime capabilities must be verified separately.

When the user asks to run a worktask, load this skill before exploration or delegation.
Continue with the workflow below; loading this skill is sufficient and requires no command restart.

## Arguments

```text
worktask "<task description>" [--secure|--full] [--emergency] [--priority High|Medium|Low]
         [--platform <p>] [--ethics-review] [--with-design] [--sequential]
         [--no-gh-issue] [--auto=[plan,decision,finalization]] [--accept-absent=<tool[,tool]>]
worktask --resume <STAGE_ID> [--cascade]
```

Standard runs use the nine-stage pipeline; `--secure` or `--full` selects eleven stages.
`--emergency` selects the incident pipeline. PL0 sizing removes unnecessary stages.
Read [launch-options.md](references/launch-options.md) for the argument grammar and output contract.

## Start or resume

1. Resolve the plugin root through `skills/shared/plugin-root-resolution.md`.
2. Select the host adapter below before executing host operations.
3. Select the launch or replay procedure from [workflow.md](references/workflow.md).
4. For a new run, start with [launch-options.md](references/launch-options.md), then follow the launch procedures in order.
5. For `--resume`, follow [replay.md](references/replay.md); use [resume.md](references/resume.md) for interruption recovery.
6. After PL0, follow [plan-transition.md](references/plan-transition.md) and [plan-approval.md](references/plan-approval.md).
7. Enter through [loop-entry.md](references/loop-entry.md); select subsequent steps from [orchestration.md](references/orchestration.md).

## Host adapters

| Host | Runtime instructions |
|---|---|
| Claude Code | Use the native operations in the workflow and orchestration references. |
| Codex | Read `skills/shared/codex-runtime.md`; translate host operations while preserving the ledger and stage contracts. |
| Other skill hosts, including Qwen Code | Verify discovery, tool mapping, delegation, permissions, and hook behavior before claiming runtime support. |

If the host lacks a required capability or adapter, report that limitation before dispatching a stage.
Never synthesize agent identifiers, successful dispatches, or completed stages.

## Gates

Gate defaults and flag carriers: [launch-options.md](references/launch-options.md#execution-model).
Apply [plan-approval.md](references/plan-approval.md) after planning and [finalization-gate.md](references/finalization-gate.md) before FN.
Resolve automated decisions through [auto-decision.md](references/auto-decision.md).

## Execution invariants

All ledger writes use `scripts/state-patch.sh`. Every stage has a ledger entry and a real agent dispatch.
The orchestrator delegates implementation, reviews, builds, and tests to the owning stage agents.
Every worktask is worktree-isolated; the PR is the review surface.

## Procedures

| When | Reference |
|---|---|
| Initialization, flags, plan approval, closing sweeps, and post-run handling | [workflow.md](references/workflow.md) |
| Sizing, stage validation, dispatch, retries, and finalization | [orchestration.md](references/orchestration.md) |
| Reattach after interruption or replay | [resume.md](references/resume.md) |
| Finalization checkpoint | [fn-gate.md](references/fn-gate.md) |
| Workspace and per-issue execution | [workspace-modes.md](references/workspace-modes.md) |
| Helper CLI contracts | [scripts.md](references/scripts.md) |
