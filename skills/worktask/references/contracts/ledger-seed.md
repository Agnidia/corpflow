# Ledger seed

Read when executing or checking ledger seed. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
### PL0 seed (initial state) {#pl0-seed}

`skills/worktask/references/workflow.md` Phase 1 Step 3a writes the initial ledger by running
`skills/worktask/scripts/seed-state.sh`, the seed's only definition (next free planning index `N`
from `.context/planning-*.md`, `0` on a fresh `.context/`; goal escaping and truncation; atomic
write). This section keeps only the resulting shape.

#### Seed shape (resulting JSON)

`plan_file` here is the path shape; task metadata carries the basename (§ plan_file shape
boundary).

```json
{
  "version": 2,
  "worktask_id": "<from task metadata>",
  "plan_file": ".context/planning-${N}.md",
  "platform": "all",
  "run_index": ${N},
  "metadata": { "workspace_path": "<absolute worktree root>" },
  "tasks": {
    "PL0": { "status": "in_progress" }
  },
  "facts": {
    "goal": "<one-sentence intent — first 240 chars of task.description or issue title>",
    "files_modified": [],
    "tests_added": [],
    "decisions": [],
    "open_questions": [],
    "verdicts": {},
    "dispatched_agents": []
  },
  "handoffs": {}
}
```

#### Additive-field seeding

The seed includes `facts.dispatched_agents: []` (additive) so the orchestrator loop
appends/replaces per-`task_id` entries in place instead of lazily creating the array. The other
additive fields (`tasks.<ID>.completed_via`/`last_error`/`worktree`, `facts.capabilities`) are
written on demand and are not seeded, because their absence is meaningful (Layer-1 self-patch, no
error, no worktree record, no observed capability hard-fail).

On a new run in an existing `.context/`, `seed-state.sh` refuses (exit 3) and leaves
`state.json` byte-unchanged; it has no overwrite path. Step 3a only reopens PL0
(`--task-status PL0 in_progress`). PL0's `skills/worktask/references/planning-sizing.md § Step 4 — state.json reset` is the
sole reset writer: `run_index = N`, `plan_file`, `tasks` reset to `{PL0: in_progress}`, `facts.*`
emptied. Historical run data lives in the on-disk `<stage>-N.md` artifacts, not in state.json.

---
