# Megatask per-issue run

Read from `skills/worktask/references/workflow.md § Per-issue run under /megatask` when `/megatask` launched this
run: the dispatch prompt carries a `PL0.metadata` stamp with `megatask_group`. A run that a user
started directly skips this file.

## Per-issue run under `/megatask`

`/megatask` Phase 2 Step 3 launches this command in a background subagent, one per issue, with
`--auto=[plan,decision,finalization]`, a `PL0.metadata` stamp carrying `megatask_group`, and a run
environment in which every Bash call opens with
`cd "<wt>" && export WORKSPACE_ROOT="<wt>" MILESTONE_MODE=1 &&`,
`<wt>` being the issue's absolute worktree path. Keep that prefix on every call, the snippets
in `skills/worktask/references/workflow.md` included. It is what makes the state scripts write `<wt>/.context/state.json` instead of
megatask's own ledger, and what the scan, preflight, publish and branch scripts read as a
per-issue run. Hooks never see that export: they bind to `<wt>` from the `WORKSPACE_ROOT=`
banner line in the acting agent's prompt, so keep `skills/worktask/references/stage-entry.md § Banner injection` on every stage brief. No
user is reachable.

### Per-issue run — what changes

| Step | Under `/megatask` |
|---|---|
| 2a-pre, 2a | Both scripts print `result=skipped reason=milestone_mode`; no `AskUserQuestion` runs |
| 3c | `branch-name.sh` self-disables; `init-worktree.sh` already named the branch |
| 4 | The stamp overlays the payload (`skills/worktask/references/launch-planning.md § Step 4 — the /megatask stamp`) |
| A | `publish-pl-issue.sh` defers with `reason=milestone_mode` |
| Any stop for the user | Settles the issue first (`skills/worktask/references/workspace-scheduling.md § USER under /megatask`) |
| Phase 3 | Skipped |
| `EnterWorktree` | Never called: the prefix already runs every call in `<wt>` |
