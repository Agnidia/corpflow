# Orchestrator & Workspace Schemas

## Orchestrator State (Required Schema)

### Orchestrator (version 3.1)

> v3.1 adds the dependency DAG. `configuration.parallel_tracks` is orchestrator-derived at init
> (`min(count(ready issues), 5)`, disk-reduced; single explicit issue ⇒ 1), never user-supplied —
> the literal below is an illustrative recorded runtime value. `group` is `milestone-{N}` or
> `issues-{shortid}` (array mode).

#### Top-level fields

```json
{
  "version": "3.1",
  "group": "milestone-1",
  "milestone": { "number": 1, "title": "Sprint 1" },
  "configuration": {
    "parallel_tracks": 2,
    "isolation": "worktree"
  },
  "base_branch": "develop",
  "created_at": "2026-06-22T10:00:00Z",
  "topological_order": [41, 42, 57, 60],
  "dependency_warnings": [
    { "issue": 42, "external_dependency": 99, "note": "#99 not in resolved set — not gating" }
  ],
```

#### `issues[]` entry

```json
  // …continued: issues[] array of the same orchestrator.json
  "issues": [
    {
      "number": 41,
      "title": "feat: Core theme system",
      "priority": "P0",
      "status": "completed",
      "track": 1,
      "level": 0,
      "blocked_by": [],
      "blocks": [42, 57],
      "external_dependencies": [],
      "current_stage": "ST",
      "branch": "feature/41-core-theme-system",
      "workspace": ".worktrees/milestone-1/41",
      "isolation": "worktree",
      "pr": "https://github.com/owner/repo/pull/120"
    }
  ],
```

Same keys in every state; a `blocked` entry differs only in values — `"status": "blocked"`,
`"track": null`, `"level": 2`, `"blocked_by": [42, 57]`, `"blocks": []`, `"current_stage": null`,
`"branch": null`, and no `pr` key until FN creates one.

#### `tracks` & `progress`

```json
  // …continued: closing keys of the same orchestrator.json
  "tracks": {
    "1": { "issue_number": 41 },
    "2": { "issue_number": null, "status": "available" }
  },
  "progress": {
    "total": 4,
    "completed": 1,
    "in_progress": 0,
    "ready": 0,
    "blocked": 3,
    "failed": 0
  }
}
```

#### DAG field contract — per-issue fields

| Field | Type | Meaning |
|-------|------|---------|
| `issues[].blocked_by` | `int[]` | Issues that must be `completed` before this one starts. Mutated at runtime: the monitor removes a number when its issue completes. |
| `issues[].blocks` | `int[]` | Reverse edges — informational (R1 summary, audits). The runtime unblock subtracts the completed issue from each dependent's `blocked_by[]`, so the monitor never reads `blocks`. |
| `issues[].level` | `int` | Topological wave (0 = no blockers). Upper bound on when it can start, not a barrier. |
| `issues[].external_dependencies` | `int[]` | Declared `Depends on` targets outside the resolved set — surfaced, not gating. |

#### DAG field contract — top-level fields

| Field | Type | Meaning |
|-------|------|---------|
| `topological_order` | `int[]` | Deterministic priority-respecting order from Kahn's algorithm. |
| `dependency_warnings` | `object[]` | External-dependency and dropped-self-edge notes for the R1 summary. |

`status ∈ {pending, blocked, ready, in_progress, completed, failed, skipped, skipped_has_pr}`.

## Workspace State

### Workspace (version 2.0)

```json
{
  "version": "2.0",
  "isolation": "worktree",
  "issue": { "number": 42, "title": "Add login flow", "labels": ["feature", "P1"] },
  "git": {
    "branch_name": "feature/42-add-login-flow",
    "base_branch": "develop",
    "base_branch_source": "develop_fallback",
    "worktree_path": "/abs/repo/.worktrees/milestone-1/42"
  },
  "worktask": { "track": 1, "complexity_score": 18 },
  "dependency": { "blocked_by": [41], "blocks": [60] },
  "execution": { "current_stage": "DV", "retry_count": 0, "status": "in_progress", "pr": null },
  "task_ids": { "PL": "PL0", "AR": "AR0", "DV": "DV0", "DR": "DR0", "QA": "QA0" }
}
```

`git.worktree_path` is the absolute physical path `init-worktree.sh` created, the value /megatask
stamps as the per-issue PL0 `workspace_path`. Nothing compares it in relative form: the monitor
finds each `workspace.json` at `.worktrees/<group>/<issue#>/` under its own root.

#### Completion contract

The per-issue worktask MUST write its terminal outcome into `workspace.json.execution`; it is what
`hooks/megatask-monitor.sh` reads.

##### `execution.status`

| Written by | Values |
|-----------|--------|
| the per-issue FN/ST stage (`agents/project-manager.md § FN Stage`), or the per-issue orchestrator when parking on escalate-class questions (`skills/worktask/references/workflow.md § Escalation guard — unattended /megatask per-issue runs (PARK)`) or stopping for the user (`skills/worktask/scripts/megatask-settle.sh`) | `in_progress` (default) → `completed` (PR created) \| `failed` (max retries, parked escalation, or escalated to the user) |

##### `execution.reason` and `execution.pr`

| Field | Written by | Values |
|-------|-----------|--------|
| `execution.reason` | the per-issue orchestrator, on parking or on a stop for the user | `"parked_escalation"` or `"escalated_to_user"` (absent otherwise) — lets the batch summary tell a parked or escalated issue from a genuine failure |
| `execution.pr` | the per-issue FN stage, on PR creation | PR URL (`null` until then); recorded onto `orchestrator.json issues[].pr` |

##### Monitor reconciliation

The sweep marks the orchestrator issue and unblocks dependents. It is idempotent: it acts only on
`in_progress` orchestrator issues whose `workspace.json` reports `status ∈ {completed, failed}`, so
re-firing on later SubagentStops is a no-op. Until FN (or the Step A.4 parking guard) writes
`status`, the issue stays `in_progress` and its dependents stay `blocked`.
