# Stage validation

Read when executing or checking stage validation.

Procedure routing: [orchestration](orchestration.md).

<!-- canonical-body:start -->
## Pre-Stage Validation

Before executing any worktask stage, the orchestrator validates:

### Validation checks 1–5

1. **Ledger check**: `.context/state.json` is `version: 2` and holds ≥1 `tasks{}` entry whose `metadata.worktask_id` matches this worktask
2. **PL0 exists**: a task with subject starting `PL0:`
3. **Stage tasks exist**: after PL0 completes, it created subsequent stage tasks (minimum DV0, DR0, QA0 at any complexity)
3b. **Inclusion decisions are reasoned**: every `metadata.skipped_stages` / `metadata.added_stages` entry carries a non-empty, decision-shaped `reason`; a bare score restatement or a missing reason fails
4. **Stage contract check**: upstream outputs match the next stage's Required Inputs per `skills/worktask/references/stage-contracts.md` (file exists + required sections present)
5. **Metadata schema check**: next task's metadata validates against `skills/worktask/references/contracts/metadata-schema.md` § JSON Schema (non-PL tasks require `stage`, `agent`, `model`, `error_file`)

### Validation checks 6–7

6. **Model alias check**: `metadata.model ∈ {fable, opus, sonnet, haiku}` — reject unknown aliases before `Agent()` delegation. Caveat: under a managed `availableModels` allowlist (it constrains subagent model overrides too) or `enforceAvailableModels`, a *valid* alias may silently resolve to a different model at dispatch — emit a `model_resolution_constrained` audit row when a managed allowlist is in effect; don't block
6a. **Effort tier check**: `metadata.effort ∈ EFFORT_ENUM` (`scripts/effort-ladder.sh`), which `state-patch.sh` enforces at the write. Absent is not fatal — Step C.0a skips the stage (`resolver_skipped`/`effort_unstamped`), costing a round-trip rather than the run
7. **Workspace existence** (megatask per-issue/worktree mode only): `metadata.workspace_path` directory exists and `workspace.json` is readable

### Validation check 8

8. **Artifact path resolution** (non-blocking): resolve the upstream artifact for the next task's `metadata.run_index` via `stageArtifactPath()` below. Emit one `artifact_path_resolved` audit row with `result ∈ {ok, fallback_glob, miss}` and `metadata.resolved_path`. `miss` = upstream produced no artifact, handled by F3 in `skills/worktask/references/contracts/fallbacks.md#fallback-paths` — warn but proceed. Catches run_index drift (PL0 ↔ stage-task off-by-one) early.

### Validation check 9

9. **Hook installation** (first stage only): either `.claude/hooks/state-merge.sh` exists and is executable, or the plugin's `plugin.json` registers the SubagentStop hook entry. Neither → warn `"⚠ state-merge.sh hook not installed — run hook-install.sh"` without blocking — Step 6.5 provides Layer 3 coverage. See `skills/worktask/references/initialization-ledger.md#hook-installation`.

<a id="validation-check-10--pass-a-title-preview-freely"></a>
<a id="validation-check-10--post-check-and-the-host-rule"></a>
<a id="validation-check-10--stamping-and-post-check"></a>
### Validation check 10

On the first stage, after seeding and before PL0 metadata, the orchestrator executes
[Step 3c](launch-seed.md#step-3c--name-the-branch-once-pl-start) and its stamping/post-check sequence.
Run rename mode once, including on conventional branches; naming failures warn and never block planning.
Refine only after PL0 returns at Step A.4b, without git mutation; FN independently revalidates the final target.

### Validation check 11

11. **Dispatch-depth projection** (non-blocking): project the deepest dispatch chain the next stage will open against `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` (default 3) — `/megatask`'s R1 projection applied per-stage instead of once per batch. `skills/megatask/SKILL.md § Nesting-depth budget` holds the canonical level table both must agree with:

```
projected_depth = orchestrator_offset      # 1 under /megatask (it spends a level), else 0
                + 1                        # the stage agent itself
                + 1 if that agent routes through a platform router
                + 1 if the router dispatches a Tier-2 specialist
headroom = cap - projected_depth
```

Emit one `dispatch_depth_projected` audit row with `metadata: {projected_depth, cap, headroom, chain}` — `chain` naming the agents level by level, so a later `dispatch_flattened` row can be read against the forecast.

### Validation check 11 — what warns, and what stays quiet

Warn on the console only when `headroom < 0`; at `headroom >= 0` the row is written and nothing prints. The canonical DV chain — session → `developer` (1) → platform router (2) → Tier-2 specialist (3) — lands exactly on the cap, so warning at zero headroom would fire on every DV stage. A projection that does not compute `3` for that chain is wrong.

#### Never blocks; forecast, not observation

A hard gate would fail that same legal chain. When it warns, name megatask's two remediations: raise the env var, or flatten Tier-2 dispatch (`skills/megatask/SKILL.md § Depth remediations`). An unanticipated hop past the cap is caught after the fact by the refused agent's own `dispatch_flattened` row (`skills/agent-coordination/SKILL.md § Depth-refusal self-report`).

### Validation check 12 — Routing resolution

12. **Routing resolution** (first stage only, after the state.json seed): read `CORPFLOW.md § Routing` from the project root when that file has the heading, else from the user-scope `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CORPFLOW.md` (precedence is per heading: `routing-matrix.md § Resolution`), and merge its `| Alias | Target |` rows over the defaults in `skills/shared/routing-matrix.md § Matrix`. Stamp the resolved map on the ledger as `state.routing: {"<alias>": "<plugin:agent>", …}` (only aliases that differ from the default need stamping; an absent map means all-default) plus `state.routing_source: "matrix" | "project-override" | "user-override"`.

#### Check 12 — audit rows and lifecycle

Emit one `routing_override` audit row per overridden alias, `metadata: {alias, default_target, override_target}`; when an entry alias is overridden but its platform's role aliases are not, add one `routing_override_partial` row. Stages resolve through `state.routing` first (`routing-matrix.md § Resolution`), so a mid-worktask edit of either file never splits routing across stages. No `## Routing` heading in either file → all-default, no rows, no warning.

### Validation check 13 — Model resolution

13. **Model resolution** (first stage only, right after check 12): run `state-patch.sh
    --resolve-models` before PL0 is dispatched. Merges `CORPFLOW.md § Models`, fail-open per row,
    over the built-in matrix, via `model-matrix-lib.sh`; the file is picked per heading like check
    12's (project root, then user scope). Stamps `state.models` for all sixteen agents (unlike
    check 12's differences-only map) plus `state.models_source` (`matrix` | `project-override` |
    `user-override`). PL0 reads this
    map itself: `model-matrix.sh --resolve <agent>` (`product-manager.md`'s dedicated Bash grant)
    checks `state.models` first, then `CORPFLOW.md`, then the matrix, and PL0 pastes the pair into
    `--task-create`'s `--metadata`; `--task-create` does not fill it from the map. No
    `## Models` in either file → all rows `"matrix"`.

### On validation failure

- No tasks exist → not initialized. Re-run initialization (seed PL0)
- PL0 exists but no subsequent tasks → PL0 did not complete. Re-run PL0
- Tasks orphaned (no worktask_id) → log a warning, match by subject pattern
- Contract violation → don't transition. Append a `missing_input` entry to the next stage's `.context/errors/<agent>.md` and block.
