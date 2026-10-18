---
name: megatask
description: Use for /megatask, multi-issue batches, or any dependency-ordered fan-out of worktasks. Meta-orchestration of many worktasks across a GitHub milestone or explicit issue array — dependency/blocker DAG, priority ordering, isolated per-issue worktrees.
argument-hint: '<N> | --issues N,N,N [--secure] [--platform apple|android|web|systems|backend|ai|all] [--dry-run]'
version: 0.5.0
related:
  - ../../commands/megatask.md
  - references/dependency-graph.md
  - references/schemas.md
  - references/git-integration.md
  - ../shared/milestone-helpers/SKILL.md
  - ../../hooks/megatask-monitor.sh
  - ../../commands/worktask.md
  - ../shared/stage-codes.md
  - ../shared/state-ledger.md
scripts:
  - scripts/build-orchestrator.sh
  - scripts/init-worktree.sh
  - scripts/resolve-pbxproj-membership.sh
---

> **Codex host:** read `skills/shared/codex-runtime.md` before launching issue worktasks. Use Codex
> agent controls for the fan-out and `$worktask` for host-native handoffs; the DAG and ledger
> contracts below remain unchanged.

# Megatask

Executes a **batch** of single-issue worktasks: owns the issue set (a GitHub milestone or an
explicit `--issues` array), builds a **dependency/blocker DAG**, runs issues in **topological +
priority order**, each isolated in its own git worktree. One `/worktask` per issue; megatask never
runs stages itself.

> **Separation of concerns.** `/worktask` runs ONE issue's staged pipeline (PL→…→ST) and is
> milestone-agnostic. All milestone/array/DAG/track logic lives here — not in `worktask.md`.

## Canonical Scripts

Invoke these instead of reading the reference files in the happy path; the references stay the
authoritative spec. Each takes `--self-test` (no network, no side effects).

### `scripts/build-orchestrator.sh` — DAG builder

Reads pre-fetched issue JSON, extracts dependency edges, runs Kahn cycle detection, assigns levels,
computes `parallel_tracks`, emits `orchestrator.json v3.1` — the executable implementation of
`references/dependency-graph.md`. On a cycle: exit 1 naming the participating issues on stderr,
never an invented order.

#### Invocation — build-orchestrator

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/megatask/scripts/build-orchestrator.sh \
  --file issues.json \
  --out  .worktrees/milestone-1/orchestrator.json \
  --group milestone-1 --milestone-num 1 --milestone-title "Sprint 1" \
  --base-branch develop

bash ${CLAUDE_PLUGIN_ROOT}/skills/megatask/scripts/build-orchestrator.sh --self-test
```

Input schema: `[{ "issue": <int>, "title": "<str>", "labels": ["P0",...], "body": "<str>" }]`
Output: `orchestrator.json v3.1` — field contract in `references/schemas.md`.

### `scripts/init-worktree.sh` — per-issue worktree initialiser

For one issue: resolves the base branch, creates the worktree at `.worktrees/<group>/<issue#>`,
makes `.context/`, stamps `workspace.json v2.0` — the executable implementation of
`references/git-integration.md`. Branch naming and base-branch resolution are fully delegated to
`../shared/milestone-helpers/scripts/milestone-helpers.sh`; no slug or branch logic lives here.

#### Invocation — init-worktree

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/megatask/scripts/init-worktree.sh \
  --issue 42 --title "Add login flow" --group milestone-1 \
  --track 1 --blocked-by 41 --blocks 60 --labels "P1,feature" \
  [--file issue-42.json]   # pre-fetched `gh issue view … --json body,labels`

bash ${CLAUDE_PLUGIN_ROOT}/skills/megatask/scripts/init-worktree.sh --issue 42 --title "..." --group milestone-1 --dry-run
bash ${CLAUDE_PLUGIN_ROOT}/skills/megatask/scripts/init-worktree.sh --self-test
```

#### Behavior — init-worktree

Without `--file`, base-branch resolution calls git ls-remote (thin, optional). Idempotent:
re-running on an existing worktree path is a no-op. It excludes the batch's scratch metadata
(`/workspace.json`, `/.worktrees/`) via the git common dir's `info/exclude` *before* creating the
worktree, so an unscoped `git add -A` cannot stage it (`references/git-integration.md § Creation`).

#### Runtime twin

> `hooks/megatask-monitor.sh` (SubagentStop) owns the *completion* side — reconciling
> workspace.json outcomes back into orchestrator.json; these INIT scripts own *creation* only. Both
> sides agree on the `workspace.json v2.0` / `orchestrator.json v3.1` schemas in
> `references/schemas.md`.

### `scripts/resolve-pbxproj-membership.sh` — membershipExceptions conflict resolver

Resolves a conflict in an Xcode project file's synchronized-build-file
`membershipExceptions = ( … );` list by **sorted, deduplicated union** of both sides. Keeping only
one side unregisters test files: the build stays green and those tests silently never run again.

#### Invocation — resolve-pbxproj-membership

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/megatask/scripts/resolve-pbxproj-membership.sh --file App.xcodeproj/project.pbxproj
bash ${CLAUDE_PLUGIN_ROOT}/skills/megatask/scripts/resolve-pbxproj-membership.sh --file <path> --dry-run   # prints result, writes nothing
bash ${CLAUDE_PLUGIN_ROOT}/skills/megatask/scripts/resolve-pbxproj-membership.sh --self-test
```

#### Behavior — resolve-pbxproj-membership

The one exception to § Conflict Resolution's hand-resolve rule, and only because it refuses
everything it does not recognise. Any of these refuses the whole file — exit 1 with
`refusing: <reason>`, file byte-identical (the parse writes a `mktemp` buffer and `mv -f`s only on
accept): a conflict elsewhere in the file; a comment or blank line inside a side; nested or
unterminated markers; a diff3 `|||||||` base section (an entry may have been deliberately deleted,
and a union would resurrect it); a hunk spanning the list's `);`. Exit codes: 0 union written / no
conflict / dry-run / self-test passed; 1 refusal or usage error; 2 `awk` missing. Rule 2 of
§ Conflict Resolution still applies: build and test before pushing.

## Inputs

`N` (bare integer) ⇒ milestone; `--issues 12,15,18` ⇒ explicit set (may span milestones); together,
`--issues` filters within milestone `N`. At least one is required. Full flag surface:
`../../commands/megatask.md § Options`. Cross-issue concurrency is orchestrator-derived (§ Track
Derivation); intra-issue async belongs to each issue's TL stage.

## Dependency & Blocker Resolution (DAG)

Megatask's core addition over plain priority batching: **inter-issue relationships** executed as a
directed acyclic graph rather than a flat priority list.

| Edge | Parsed from issue body | Meaning |
|------|------------------------|---------|
| `A blocked_by B` | `Depends on: #B` on issue A | A cannot start until B is `completed` |
| `A blocks B` | `Blocks: #B` on issue A | reverse of `B Depends on A` |

Both formats are what `/milestone` emits under `## Dependencies`. The two directions **normalize**
into one edge set (`A blocks B` ⇔ `B blocked_by A`); duplicates collapse. Edges leaving the resolved
issue set become `external_dependency` warnings — surfaced, never gating (out of batch scope).

### Ordering

1. **Cycle detection** (Kahn's algorithm). Any cycle ⇒ STOP and report the participating issues. Never guess an order.
2. **Topological sort** — issues with empty `blocked_by` form level 0; removing them exposes level 1; etc.
3. **Priority tiebreak** within a level: `P0`/`priority:critical` → `P1`/`high` → `P2`/`medium` → `P3`/`low` → unlabeled; FIFO by issue number within a tier.

An issue is **ready** only when every `blocked_by[]` entry is `completed` (PR merged, or created
when the project closes via PR): megatask **never starts an issue whose blockers are unmerged.**
Algorithm, worked example, levelled schedule: `references/dependency-graph.md`.

## Workspace Architecture

Each issue executes in its own git worktree with its own branch checked out — no `git checkout`
switching, so issues run truly in parallel. `<group>` is `milestone-{N}` or `issues-{shortid}`
(array mode).

```
.worktrees/<group>/orchestrator.json   # root orchestrator state (DAG + tracks + progress)
.worktrees/<group>/{issue#}/           # worktree root: full source copy + .git link file
    .context/                          # per-issue worktask artifacts
    workspace.json                     # workspace metadata (isolation: "worktree")
    handoff.md                         # compressed context
```

> Add `.worktrees/` to `.gitignore` so worktree contents do not appear as untracked. Subagents in
> an isolated worktree get Read/Edit access to it with no explicit `tools:` grant.

#### Sparse Checkout

For large monorepos, configure `worktree.sparsePaths` in project `settings.json` to check out only
relevant directories — less per-worktree disk, faster init:

```json
{ "worktree": { "sparsePaths": ["src/", "tests/", "Package.swift"] } }
```

#### Including gitignored paths (`.worktreeinclude`)

`.worktreeinclude` names paths to carry into a new worktree even when gitignored, including a
`**/`-leading pattern whose target lives inside a gitignored directory.

### Unattended Execution

A batch cannot stop for one issue's approvals, so every per-issue `PL0` is stamped
`plan_gate: "bypass"`, `fn_gate: "bypass"` (both default `"checkpoint"`) and `decision_gate: "auto"`
(default `"user"`) — that issue's `open_questions[]` route through the Fable decision pass
(`commands/worktask.md § Step A.4`). The single human checkpoint is megatask's own **R1 batch
confirmation**, before any worktree exists; per-issue changes are reviewable as per-issue PRs.

#### Parking an escalate-class question

Escalate-class questions are never auto-decided — they park that single issue while the batch
continues with the remaining unblocked issues. Parking needs no new state: it settles
`execution.status: "failed"` + `execution.reason: "parked_escalation"`, so the monitor frees the
track and dependents stay `blocked`. Mechanics:
`../../commands/megatask.md § Step 3 — parking mechanics`.

##### Parking — non-planning stages

The same path covers non-planning stages: an escalate-class closing-sweep item parks the issue
identically, with the audit subject set to the boundary that surfaced it — `FN<N>` for a batched
item, the emitting stage's own `<CODE><N>` for one marked `blocks_next_stage`
(`skills/shared/stage-contracts.md § Closing Elicitation Sweep`).

> When the megatask session itself runs headless (`-p`), set `MCP_CONNECTION_NONBLOCKING=true` to skip the MCP connection wait;
> with `--mcp-config`, server connections are bounded at 5s rather than blocking on the slowest.

## Track Derivation

`parallel_tracks` is computed at init and re-derived as blockers merge, into
`orchestrator.json → configuration.parallel_tracks`. Never a flag/default. Formula:
`../../commands/megatask.md § Phase 2`; the three ceilings it reduces against are below.

### Subagent spawn budget

> Each issue dispatches ~9–11 stage subagents (9-stage default, 11-stage `--secure`) plus nested delegation (DV → platform agent → Tier-2 specialist, QA → `test-generator`). No per-session total-spawn cap bounds batch size. What refuses a dispatch is concurrency (`agent-coordination § Two independent ceilings`) and, below it, disk for the worktrees and your rate budget — so size batches against peak concurrency, not a total.

### Concurrency budget

> 20 subagents may run concurrently by default (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`) — a cap distinct from spawn total and depth. Subagents are background-by-default, so live population ≈ `parallel_tracks × (1 orchestrator + 1 stage agent + its nested children)`; at `parallel_tracks = 5` with routine Tier-2 delegation that approaches the cap. Track derivation bounds itself against this ceiling; raise the env var only when disk and rate budgets also allow it.

### Nesting-depth budget

> `/megatask` spends one depth level before any stage runs: Phase 2 Step 3 dispatches each per-issue `/worktask` orchestrator as a background `general-purpose` subagent, so the chain sits one level deeper than a standalone worktask at every point.

| Level | Standalone `/worktask` | Under `/megatask` |
|-------|------------------------|-------------------|
| 0 | session | session |
| 1 | stage agent (`corpflow:developer`) | per-issue `/worktask` orchestrator |
| 2 | platform router (`apple-developer:apple-developer`) | stage agent (`corpflow:developer`) |
| 3 | Tier-2 specialist (`apple-developer:test-generator`) | platform router |
| 4 | — | Tier-2 specialist ⚠️ **past the default ceiling** |

#### Depth remediations

> Default cap **3** (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`). A batch whose DV stages route through a platform router to a Tier-2 specialist loses that last delegation — the specialist is never spawned and the platform agent does the work itself. Two remediations, chosen at the R1 gate, which reports the projected max depth:
>
> 1. **Raise the cap** (preferred — preserves routing): export `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=4` (higher for `--secure` batches that also nest under SR) before starting the batch.
> 2. **Flatten Tier-2** (no config required): DV dispatches the platform specialist directly (`apple-developer:ios-developer`) instead of the router, reclaiming one level at the cost of the router's platform-detection step.

#### One formula, two callers

> The level table above is canonical; `skills/worktask/SKILL.md § Validation check 11` applies it per-stage for standalone worktasks, differing only in `orchestrator_offset` (1 here, 0 standalone). The same chain must project **3** standalone and **4** under `/megatask` — editing one column without the other is how the two drift. An unanticipated hop, which neither projection can see, is caught afterwards by `agent-coordination § Depth-refusal self-report`.

## Status Transitions

```
pending → ready → in_progress → completed
                              → failed
        → blocked  (blocked_by not yet all completed)
        → skipped / skipped_has_pr
```

### Issue status values

| Status | Meaning |
|--------|---------|
| `pending` | resolved, not yet scheduled |
| `blocked` | `blocked_by` not all completed |
| `ready` | all blockers completed; eligible for a track |
| `in_progress` | worktree active |
| `completed` | PR created |
| `skipped` / `skipped_has_pr` | manually skipped / already has a linked PR (auto-detected) |
| `failed` | max retries exceeded, or parked on unanswered escalate-class questions (`workspace.json.execution.reason: "parked_escalation"`) |

### Starting and completing an issue

**Starting**: set `in_progress`, assign `track`, create worktree + branch, begin the per-issue
worktask (PL→…→ST) with gates pre-bypassed.

**Completing**: per-issue FN pushes the branch, opens a PR with `Closes #{issue}`, and writes
`execution.status: "completed"` + `execution.pr` into `workspace.json` (completion contract:
`references/schemas.md`). The monitor hook reads that, marks the issue `completed` in
`orchestrator.json`, **unblocks dependents**, and frees the track. A `failed` issue writes
`execution.status: "failed"` — its dependents stay `blocked`. A freed track is not reassigned
while a live child of that issue's worktask runs (§ Track hold before reassignment).

#### Track hold before reassignment

Before reassigning a freed track, run the live check of `../worktask/SKILL.md § Hand-back guard`
on that issue's `<worktree>/.context/state.json`. Every row writes `handback_guard` with
`point: track_reassign`, except `clear`:

| Outcome | Track | `result` |
|---|---|---|
| a live child | hold it this turn | `deferred` |
| clear | reassign; no row | — |
| the check cannot run here (`/megatask` grants neither `Bash(claude:*)` nor `ListAgents`, or the CLI is unavailable), or its answer is indeterminate | release it | `unverified` |

So this backstop is best-effort: it holds a track only where the lane can see liveness. The hold
is bounded by `agent-coordination § Stall Timeout`. With no other track in flight, no later turn is
guaranteed, so wait out that bound once in this turn, never in a poll loop, and check again. A child
still live then releases the track with `result: unverified`.

## Per-Track Task IDs

Every track uses the same plain `<STAGE>0` ledger keys (`PL0`, `AR0`, `DV0`, `DR0`, `QA0`). The
namespace is the worktree, not the key: each track has its own `.context/state.json` under its own
worktree, so two tracks both writing `PL0` cannot collide. Track-offset ids would break every
hardcoded `PL0`/`AR0`/`FN0` reader and the `PL is always PL0 only` rule in
`../shared/state-ledger.md`.

### Seeding a track's PL

`/worktask` Step 3a seeds the per-issue ledger with `seed-state.sh`
(`commands/worktask.md § Steps 3–3a`); it already holds `tasks.PL0`, so this row is a metadata merge.
megatask passes the stamp in the per-issue prompt, and the per-issue run's Step 4 overlays it in
its own `--task-meta PL0` call (`commands/worktask.md § Step 4 — the /megatask stamp`), from
`$WT`, the absolute `worktree_path=` that `init-worktree.sh` printed.

#### Seeding a track's PL — the stamp

```bash
# megatask bypasses both default-checkpoint gates; decision_gate=auto means open
# questions go to a Fable decision pass and an escalation parks the issue.
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-meta "PL0" --set "$(jq -n \
  --argjson issue "$ISSUE_NUMBER" --argjson track "$TRACK" \
  --arg group "$GROUP" --arg ms "$MILESTONE_OR_EMPTY" --arg wt "$WT" \
  '{stage:"PL", agent:"corpflow:product-manager",
    description:"Planning - Issue #\($issue)",
    issue_number:$issue, track:$track,
    workspace_path:$wt,
    isolation:"worktree",
    megatask_group:$group, milestone:(if $ms == "" then null else $ms end),
    fn_gate:"bypass", plan_gate:"bypass",
    decision_gate:"auto"}')"
```

## Base Branch Resolution

Per-issue fallback chain (stored in `workspace.json` as `base_branch_source`):
1. **Issue body**: parse `base_branch: <branch>`
2. **Develop fallback**: if `develop` exists on remote
3. **Master default**: fall back to `master`

## Branch Naming

`<type>/{issue#}-{slug}` — type derived from the issue title (`feature` by default, `bugfix`
for a defect, …); slug = lowercase title, spaces→hyphens, no special chars, max 50 chars,
truncated on a word boundary. Canonical definition: `../shared/milestone-helpers/SKILL.md`.

## Shared-Seam Registry

A **seam** is a code surface more than one issue in the batch touches by name: a shared protocol, a
dependency-injection extension point, a coordinator, or a shared test assertion. Parallel tickets
cannot see each other's work in progress, so two of them invent the same abstraction under
different names unless one place tells them it already exists. The dependency graph cannot catch
this class — the tickets are genuinely independent; only their seams collide.

### Registry location

**Exactly one registry per batch**, in an issue body under a `## Shared Seams` H2 — an issue body
already exists, is already fetched at dispatch, and needs no lifecycle. The host is a rule, not a
judgement call: with two hosts, each ticket reads a different registry and concludes no seam exists.

| Batch shape | Registry host |
|---|---|
| Exactly one level-0 issue (no `blocked_by`) — the **foundation issue**, the one every other issue transitively depends on | that issue's body |
| More than one level-0 issue, or none | the **milestone issue** (milestone mode) or the **orchestrator issue** (`--issues` array mode) |

**Convention, not a gate.** Nothing validates the registry this release; its force comes from the
per-issue prompt directing every issue to read it before introducing a shared abstraction
(`../../commands/megatask.md § Phase 2 loop · Step 3`).

### Registry schema

One block per seam. `declaration` carries the verbatim signature with every parameter label in
order — a name-only entry would not catch two issues agreeing on a concept but reversing an argument
order. `consumers:` plus `change-protocol:` are what make an additive change safe: adding a member
to a shared protocol silently breaks every test double conforming to it.

#### Registry entry — canonical shape

````markdown
## Shared Seams

### NotificationDestinationPresence
- kind: protocol | di-extension-point | coordinator | test-contract
- status: planned | landed
- owner: #<issue that introduces it>
- consumers: #<issue>, #<issue>
- location: <path/to/File.swift>
- declaration:
  ```swift
  protocol NotificationDestinationPresence {
      func setPresented(_ presented: Bool, for destination: Destination)
  }
  ```
- change-protocol: adding or reordering a member requires updating this entry in the same PR
  and naming every issue in `consumers:` in that PR's description.
````

## Orchestrator Pattern

### Initialization

Resolve the issue set → build the DAG (cycles stop the run) → write `orchestrator.json` v3.1 with
the DAG, order and derived tracks → R1 batch confirmation → create worktrees for the first ready
issues. Step-by-step procedure: `../../commands/megatask.md § Phase 1`.

### Monitoring Loop

**Completion-driven** via `hooks/megatask-monitor.sh` (registered on SubagentStop):

1. **On per-issue completion** — the hook marks the issue `completed` in `orchestrator.json`,
   removes it from every dependent's `blocked_by[]`, promotes now-unblocked dependents to `ready`,
   frees the track, and writes a `megatask_progress` audit row (+ optional notification).
2. **Orchestrator turn** — re-read `orchestrator.json`, re-derive `parallel_tracks`, assign freed,
   unheld tracks to ready issues (topological + priority order), launch their worktasks, each a
   background `general-purpose` subagent whose stop fires this hook
   (`../../commands/megatask.md § Phase 2 loop · Step 3`).
3. **Errors** — a `failed` issue frees its track but keeps its dependents permanently `blocked`;
   surface the blocked set so the user can intervene (retry, re-scope, or drop the edge).
4. **Stage creation** — verify each per-issue `state.json` holds ≥1 task key besides `PL0`.

#### Hook properties

Non-blocking (always exits 0) and **self-skips** when no `orchestrator.json` is present, so plain
single-issue worktasks are untouched.

## Execution Flow

The three modes differ only in issue-set resolution — milestone fetch, `gh issue view` per issue
(group `issues-{shortid}`), or milestone ∩ explicit set — then execute identically. Phase-by-phase
procedure and the resolution commands: `../../commands/megatask.md § Phase 1`, `§ Phase 2`.

Track count is orchestrator-derived (max 5) and gated by the DAG — only ready issues consume tracks,
so a deep chain (A→B→C→D→E) runs effectively serially however many tracks exist.

## Conflict Resolution

Parallel branches off one base collide on shared files. Two rules are binding for every conflict
a batch produces.

### Rule 1 — hand-resolve DI and coordinator shapes

**Dependency-injection containers and coordinator-shaped files are hand-resolved by a human; never
script-merged.** No "keep both sides" automation on these shapes — a registration list, a DI
container extension, a coordinator's argument list, a switch over destinations — because a scripted
join silently drops separators and duplicates braces, which survives review and fails only at build.

A script is allowed only where its conflict class needs no interpretation *and* the script refuses
everything it does not recognise (§ Canonical Scripts names any such tool the batch ships).

### Rule 2 — build and test before pushing

**Build and test after every conflict resolution, before pushing** — the real build and the real
test run, from the worktree. Rule 1's failure mode is invisible to everything cheaper.

### Recovery when the branch cannot be re-pushed

Rebase, push under a new name, open a replacement PR, close the superseded one:
`references/git-integration.md § Conflict Recovery`.

## Error Handling

| Error Type | Workspace Action | Orchestrator Action |
|------------|------------------|---------------------|
| Transient | Retry (3×) | Monitor |
| Fatal | Mark `failed` | Free track; keep dependents `blocked`; alert user |
| Dependency cycle | — | STOP at init; report participating issues |

**Global errors**: milestone not found, issue not in milestone/set, rate limit, dependency cycle.
