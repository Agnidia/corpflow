# Workspace Modes — detection & isolation rules

Read when running in megatask/worktree mode, inside a Conductor workspace clone, or on any cwd↔workspace_path mismatch (from `skills/worktask/SKILL.md § Workspace Mode` stub). In a megatask run (`/megatask N`), each ticket executes in an isolated workspace.

## Workspace Detection

```typescript
const task = state.tasks[currentTaskId];
const workspacePath = task.metadata?.workspace_path;
const isolation = task.metadata?.isolation;  // always 'worktree' for file-writing stages

// WORKTREE MODE: workspace_path IS the worktree directory — git operations and
// .context/ both live inside it. STANDARD MODE: main checkout (orchestrator and
// non-isolated stages), .context/ at the repo root.
const contextPath = isolation === 'worktree' ? `${workspacePath}/.context` : '.context';
```

## Path Resolution

| Mode | Base Path | Git Operations | Source Isolation |
|------|-----------|----------------|------------------|
| Standard | `.context/` (main checkout) | Main working directory | None (orchestrator/non-isolated stages) |
| Worktree | `.worktrees/milestone-{N}/{issue#}/.context/` | Dedicated worktree | Full (git + artifacts) |

## Conductor Workspace Topology

When CC spawns a worktask session inside a Conductor-managed workspace clone
(e.g. `/Users/<user>/conductor/workspaces/<plugin>/<workspace-id>/`), the
canonical plugin source directory (e.g. `/Users/<user>/Projects/corpflow/`)
is a sibling repo on a different branch and is not to be edited.

Rule: all `Edit`/`Write` calls target paths under `git rev-parse --show-toplevel`
of the current session, not paths under the canonical plugin source.

### Sibling-worktree hazard

That rule defends against a sibling clone, not a sibling worktree. When the harness pins the session to a stale linked worktree of a different clone, `git rev-parse --show-toplevel` answers with that worktree: the agent obeys the rule, writes every edit under the resolved root, and lands the whole stage in a tree nobody is watching — `git diff` in the real workspace shows nothing and the stage reports success.

#### Why every existing check passes on the wrong tree

D0's workspace-root self-check reads the same `--show-toplevel`, so root and prompt paths agree; D0.0's isolation check passes because a stale worktree is a linked worktree; and the rule above holds because edits target the resolved toplevel.

The missing predicate is assignment: the resolved root must equal the root the stage was
dispatched against (`task.metadata.workspace_path`). Only
`skills/worktask/scripts/dv-tree-preflight.sh` asserts it. Isolation ≠ assignment.

### Orchestrator enforcement

1. Before every `Agent()` delegation, resolve `WORKSPACE_ROOT = $(git rev-parse --show-toplevel)`.
2. Inject `WORKSPACE_ROOT=<path>` as the first line of the stage prompt banner (section [7]).
3. Rewrite any absolute path from outside `WORKSPACE_ROOT` in a stage prompt as `$WORKSPACE_ROOT/<relative>`.

Otherwise edits land in the sibling repo on the wrong branch, invisible to `git diff` in the workspace, and corrupt the source repo's working tree.

### Branch naming under a host workspace

A host that provisions the workspace also names its branch, and that name carries no ticket and no type (Conductor uses `<city>-v<n>` — `amman-v1`, `perth-v2`). Left unchanged, it gives the PR a head that says nothing about the work.

#### Host session authorization

Conductor injects a session rule: *"Do not rename the current branch unless the user explicitly tells you to do so."* Invoking `/worktask` satisfies that condition — a conventional branch and a ticket-referencing PR are part of what the pipeline was asked to deliver, so the PL-stage naming step (`skills/worktask/scripts/branch-name.sh`, once at the very start of planning — `skills/shared/git-conventions.md § Branch Naming`) is authorized work, not an unprompted change. Do not pause the pipeline to re-ask. FN reads the resulting `facts.branch` rather than re-deriving or re-renaming it (`agents/project-manager.md § Branch naming is a PL-stage concern`).

#### Scope of the authorization

It covers exactly the rename `branch-name.sh` performs — never branch deletion, force-push, or history rewrite. Caveat: the step's only discriminator is `branch_is_conventional` (does the name match `<type>/[<ticket>-]<slug>`?), so a deliberate human name that does not match — `spike-oauth-poc` — is indistinguishable from a host placeholder and will be renamed, in every checkout including linked worktrees. Mitigations: rename to a conventional form before invoking `/worktask`, or set `BRANCH_NAME_WORKTREE_RENAME=0` (restores defer-to-host inside worktrees).

#### Timing

The rename runs at the very start of planning — before PL0 exists, therefore before the plan-approval gate, the pipeline's only human checkpoint — and nothing renames it back if the operator later declines the plan. `--auto=[plan]`, `--emergency` and `/megatask` remove that gate, making this the only pre-approval action any of them take; `/megatask` and `--emergency` self-disable at the first ladder position, so `--auto=[plan]` is the exposed combination and `BRANCH_NAME_WORKTREE_RENAME=0` the mitigation.

#### Rollback

The mutation is local, reversible, and network-free: `git branch -m <original-name>`
restores it manually if a declined plan needs the old name back.

#### Guard ladder — two names, one per decision

Canonical ladder and the two-name contract — `branch=<name>` is the local branch after the run (final stdout line), `target_branch=` is what the remote branch (the PR head) should carry, and blocking the rename never blocks the target: `skills/shared/git-conventions.md § Guard ladder (every arm is a no-op or a refusal, never a failure)`. Every arm exits 0. Two further no-op arms matter in batch/worktree runs: jq unavailable (batch scope unknowable — `target_branch=` derived only if `--goal` was passed) and batch routing (skipped, `target_branch=` empty).

Running at PL start retires the hazard the upstream guards catch — no push yet to orphan.

#### Host mapping — updated, not preserved

Inside a linked worktree the naming step renames the local branch, like any other checkout, so `branch=` and `target_branch=` agree. That rename updates the host's branch↔workspace mapping deliberately: a host-assigned placeholder is not worth preserving, and a host may rename again mid-run without telling the pipeline. `BRANCH_NAME_WORKTREE_RENAME=0` restores defer-to-host: local name kept, only `target_branch=` derived, auditing `branch_renamed / skipped` with `reason: host_workspace_worktree`.

#### Host mapping — detection

A linked worktree is the shape every worktree-based host provisions, detected as `git rev-parse --git-dir != --git-common-dir` — the only signal a host workspace reliably leaves (Conductor writes no `workspace.json` in `$PWD`, so none of `fn_batch_scope`'s signals fire). The rename is disclosed on stdout as it happens, naming both the re-sync consequence and the opt-out, and repeated in the Step A.5 plan-gate summary.

#### Host mapping — where the target lands

The orchestrator stamps the target into `facts.branch` (`commands/worktask.md § Step 3c — which of the two names gets stamped`) and FN's `git push -u origin HEAD:refs/heads/<facts.branch>` gives the PR a conventional head (`agents/project-manager.md § Final FN steps`).

On the default worktree path the two names agree, leaving no divergence to reconcile. Divergence is expected on the opt-out path and on the `upstream_tracked`, `target_exists` and `jq_unavailable` arms, where `fn-preflight.sh branch-divergence` observes and classes it (`expected` vs `third_party`, only the latter surfaced at the FN gate) — semantics in `handoff-protocol.md § Field notes — branch, divergence from the local branch name`.

## Task ID Namespacing

The ledger key is `<STAGE>0` in every track (`PL0`, `AR0`, `DV0`, …) — the worktree supplies the namespace, so the key never has to. Each track holds its own `.context/state.json` inside its own worktree, so identical ids across tracks address different ledgers and cannot collide.

Full workspace documentation: `../../megatask/SKILL.md § Workspace Architecture`.

## DV Worktree Mechanics

Base-ref, background, and lifecycle rules for the DV stage worktree. `agents/developer.md` keeps the D0.0 isolation gate + cwd-discipline path check inline and points here for the mechanics.

### Worktree Mode (DV)

All DV operations use the worktree path prefix — isolation is always active. `EnterWorktree`/`ExitWorktree` enter and leave worktree contexts; `EnterWorktree` takes a `path` to target a specific worktree and can switch between Claude-managed worktrees mid-session without `ExitWorktree` first. Build/test with `--package-path {workdir}`, git with `git -C {workdir}`. For large repos, `worktree.sparsePaths` reduces checkout size. See `skills/megatask/SKILL.md`.

##### The tree is pinned at dispatch

Each DV ledger row's tree is fixed before `Agent()`: the row's agent enters exactly `tasks.DV<k>.metadata.workspace_path`. The orchestrator serializes shared-tree streams when `WORKSPACE_ROOT` pins its session, or re-pins concurrent streams to separate trees otherwise (rule: `handoff-protocol.md § Pinning a row's tree`). A linked worktree alone does not signal a pinned session. Agent frontmatter `isolation`, the Agent tool's `isolation: "worktree"`, and glob conventions cannot select the assigned tree. They can hand the stage a different tree, which `dv-tree-preflight.sh --assigned` (`agents/developer.md § D0.0a`) blocks.

##### Absolute-path mode when EnterWorktree is refused

A refusal is never licence to write somewhere else. The agent works the pinned tree by absolute path instead: every path under `WORKSPACE_ROOT`, every git call as `git -C "$WORKSPACE_ROOT"`, and the pre-flight run from inside that tree with `--assigned "$WORKSPACE_ROOT"`. The tree is still isolated, so `worktree:` stays `true`. Contract: `agents/developer.md § D0.0`.

##### Do not rely on auto-cleanup

A fresh worktree per delegation is the intent, not a guarantee. Assert it with `dv-tree-preflight.sh --assigned` (D0.0a).

##### Base-ref resolution

`worktree.baseRef` sets the base of every worktree Claude Code creates (`EnterWorktree` without a `path`, `--worktree`, `isolation: worktree` subagents): `fresh`, the default, branches from `origin/<default-branch>` and drops unpushed work; `head` branches from local HEAD — inside a linked worktree, that worktree's HEAD. The plugin's own trees (megatask `init-worktree.sh`, pinned DV streams) come from `git worktree add` with an explicit base, so the setting only reaches a harness-created tree, and there the plugin needs `head` to carry the worktask's in-progress branch. A plugin cannot set it — plugin `settings.json` accepts only `agent` and `subagentStatusLine` — so the user sets `"worktree": {"baseRef": "head"}` in `.claude/settings.json` (shared) or `~/.claude/settings.json`.

##### Per-task base override

When the merge target is not the worktask default (e.g. `origin/release/v2` instead of `origin/master`), PL0 sets `task.metadata.base_ref`. DV uses it for the `git diff` ranges in test selection (D2). `EnterWorktree` takes no base argument, so a DV that must create a tree on that base runs `git worktree add -b <branch> <path> <base_ref>` and enters it with `EnterWorktree(path)`; a bare `EnterWorktree` follows `worktree.baseRef`.

##### Base-ref resolution order

PL0 also mirrors the detected branch to `state.json .metadata.base_ref` unconditionally, because shell helpers cannot read Task-System metadata. Every reader — DV, `fn-preflight.sh continuity`, `branch-name.sh` (via `branch-lib.sh resolve_base_ref`) — resolves through one order, highest first: `$FN_BASE_REF`, `state.json tasks.<ID>.metadata.base_ref` (rank 2a, the row a caller names via `BASE_REF_TASK_ID`), `state.json .metadata.base_ref` (rank 2b, the rank a host-declared target branch enters at), `workspace.json .git.base_branch`, `git symbolic-ref refs/remotes/origin/HEAD`, then unresolved. Ahead of them sits rank 0, the `fork_base()` fork point — opt-in evidence: it supplies a value only when those ranks are empty and the caller passed `--with-fork-point` (only `fn-preflight base-sanity` does); otherwise it reconciles through a PL0 sweep item instead of overriding. No hardcoded literal ends that chain; an unresolved base is reported and the caller degrades non-blocking. Canonical: `handoff-protocol.md § metadata.base_ref`.

##### Background & shared-checkout rules

Background subagents spawned via `claude agents` cannot escape their assigned worktree scope (the worktree-isolation guard covers them). Background dispatch recognises pre-existing git worktrees (Conductor `.context` workspaces, externally-managed worktree shells) instead of refusing to spawn with a duplicate-creation error, so `Edit` is not blocked where `EnterWorktree` would have collided. A background session on a *shared* checkout (no isolated worktree) is told upfront that edits are blocked until it runs `EnterWorktree` — contract at session start, not a rejected edit mid-work.

##### Out-of-tree confirmation guard

`EnterWorktree` with a `path` outside `.claude/worktrees/` triggers a confirmation prompt. Unattended DV/resume flows should keep targets under `.claude/worktrees/`, pre-authorize via `bypassPermissions`/skip-permissions mode, or rely on the cwd-based pre-existing-worktree recognition above.

##### Background session lifecycle

Background agents launched via `/bg` or `←←` preserve the active permission mode across retire/wake — a `bypassPermissions` parent does not revert to `default` after the daemon hibernates. Sub-agents in isolated worktrees get Read/Edit access to their own worktree automatically, and keep write and Bash access there when the main session enters or exits a different worktree. A worktree-isolated subagent loads the project CLAUDE.md once, not again from the worktree copy. A background session stays reopenable from `claude agents` after its worktree is removed. Stalled subagents fail with a clear error after 10 minutes — surface and retry rather than waiting. Subagents resumed via `SendMessage` restore their explicit spawn `cwd`. "Always allow" rules save at the repository root and persist across every worktree of that repo, so a rule approved in one background/worktree session is not re-prompted in a sibling worktree.
