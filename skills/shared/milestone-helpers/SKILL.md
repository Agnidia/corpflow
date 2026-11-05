---
name: milestone-helpers
description: Use when implementing milestone workspace initialization, PR detection, or worktree management. Reusable helper function patterns for milestone worktask operations.
related:
  - ../../megatask/SKILL.md
  - ../../worktask/references/workflow.md
  - ../../worktask/references/stage-codes.md
---

# Milestone Helper Functions

## Canonical Dispatcher

**`scripts/milestone-helpers.sh`** is the single executable home for all slug/branch/priority/base-branch logic. Megatask scripts invoke it rather than reimplementing these operations.

```
bash scripts/milestone-helpers.sh <subcommand> [args...]
```

All subcommands accept pre-fetched JSON via `--file` so they are network-free and testable. Run `--self-test` to verify (30 checks, no network required).

### Subcommands

| Subcommand | Invocation | Output |
|---|---|---|
| `branch-name` | `bash milestone-helpers.sh branch-name 42 "Add login flow"` | `feature/42-add-login-flow` (type derived — `bugfix/43-…` for a defect title) |
| `priority-score` | `bash milestone-helpers.sh priority-score P1 bug` | `1` |
| `base-branch` | `bash milestone-helpers.sh base-branch --file issue.json` | `develop` |
| `has-pr` | `bash milestone-helpers.sh has-pr 42 --file timeline.json` | `yes` or `no` |
| `filter-prs` | `bash milestone-helpers.sh filter-prs --file issues.json` | TSV: `<number> <status>` |
| `orchestrator-update` | `bash milestone-helpers.sh orchestrator-update --file in.json --path out.json --issue 42 status=completed` | writes updated JSON atomically |
| `workspace-init` | `bash milestone-helpers.sh workspace-init 42 "Add login flow"` | `branch=…` `worktree_path=…` `context_path=…` key=value lines |

### Slug-length canon: **50 characters**

The dispatcher implements **50** (matching `skills/megatask/SKILL.md §Branch Naming`) as the single source of truth. The issue number sits outside the cap: `<type>/{issue#}-{slug}` spends the 50 characters on the slug alone. Worktask's own budget is 48, spent on `<ticket>-<slug>` together (`skills/shared/git-conventions.md § Slug budget`) — the two differ deliberately.

### Slug truncation: whole words only

Over-budget slugs drop the trailing **partial** segment rather than cutting mid-word — `bugfix/164-fix-…-blinking-before`, never `…-blinking-before-t`. At least one whole word always survives, even a word longer than the cap, because an empty slug would emit the nameless `<type>/{issue#}-`.

Same rule as `derive_slug` in `skills/worktask/scripts/branch-lib.sh`; the two are pinned by cross-check tests in `tests/shell/skills/milestone-helpers.bats` — the same title must yield the same slug body from both entry points.

### Branch type: derived, not fixed

`branch-name` derives the type from the issue title via `derive_type`, sourced from `skills/worktask/scripts/branch-lib.sh` — the same function worktask uses, never a second copy. `feature` is the default for titles that read as new work; a title starting with "Build" derives `feat` (`"Build multiplatform leaderboard"` → `feat/7-build-multiplatform-leaderboard`); defect, refactor, docs, chore, and the rest resolve to their own prefix. If `branch-lib.sh` is unreachable the dispatcher exits 2 rather than falling back to `feature/`: a plausible-looking wrong branch name is worse than a loud stop.

#### Where each constant is canonical

> Constants are canonical in `megatask`, which owns the number-interpolation format (`<type>/{issue#}-{slug}`), the slug cap, the priority labels (P0–P3 + none), and the base-branch chain (issue body → develop → master). One exception: the branch **type** vocabulary and its derivation are canonical in `skills/shared/git-conventions.md § Branch Naming` (machine-readable copy: `BRANCH_TYPES` + `derive_type` in `branch-lib.sh`). This skill applies them via `scripts/milestone-helpers.sh`; reference those two rather than redefining here.

## Function Index (pseudocode spec — implemented in scripts/milestone-helpers.sh)

`references/implementations.md` is the **specification** for each function; the dispatcher is the executable implementation, so the happy path never requires reading it.

| Function | Dispatcher subcommand |
|----------|----------------------|
| `generateBranchName(issue)` | `branch-name` |
| `hasExistingPR(issueNumber)` | `has-pr` |
| `filterIssuesWithPRs(issues)` | `filter-prs` |
| `getPriorityScore(labels)` | `priority-score` |
| `updateOrchestratorIssue(path, number, updates)` | `orchestrator-update` |
| `resolveBaseBranch(issueBody)` | `base-branch` |
| `initializeWorkspace(milestone, issue)` | `workspace-init` (paths only; no side effects) |
| Worktree operations | Not in dispatcher (git commands — run directly per `skills/megatask/references/git-integration.md`) |

## Git Commands Reference

> **Orchestrator-side only.** The `git -C` forms below run from the parent session reaching *into* a worktree. Inside a worktree use plain `git` — the runtime blocks an isolated subagent from redirecting git at the shared checkout (`git -C`, `--git-dir`, `GIT_DIR`, `GIT_WORK_TREE`), so copying these there fails.

| Operation | Non-worktree Command | Worktree Command |
|-----------|----------------|------------------|
| Fetch base | `git fetch origin develop` | `git fetch origin develop` |
| Create branch | `git checkout -b <type>/{issue#}-{slug} origin/develop` | `git worktree add -b <type>/{issue#}-{slug} .worktrees/milestone-{N}/{issue#} origin/develop` |
| Switch to issue | `git checkout <type>/{issue#}-{slug}` | `cd .worktrees/milestone-{N}/{issue#}` (no checkout needed) |
| Stage changes | `git add -A` | `git -C .worktrees/milestone-{N}/{issue#} add -A` |

### Commit, push, PR, cleanup

| Operation | Non-worktree Command | Worktree Command |
|-----------|----------------|------------------|
| Commit | `git commit -m "#{issue} feat: {title}"` | `git -C .worktrees/milestone-{N}/{issue#} commit -m "#{issue} feat: {title}"` |
| Push branch | `git push -u origin <type>/{issue#}-{slug}` | `git -C .worktrees/milestone-{N}/{issue#} push -u origin <type>/{issue#}-{slug}` |
| Create PR | `gh pr create --base develop --body "Closes #{issue}"` | `gh pr create --base develop --body "Closes #{issue}"` |
| Cleanup | `git checkout develop` | `git worktree remove .worktrees/milestone-{N}/{issue#} && git worktree prune` |
