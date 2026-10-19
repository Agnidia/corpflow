---
name: megatask
description: Orchestrate many worktasks across a GitHub milestone or an explicit issue array, ordered by a dependency/blocker DAG and priority, each issue in its own isolated worktree.
argument-hint: '<N> | --issues N,N,N [--secure] [--platform apple|android|web|systems|backend|ai|all] [--dry-run]'
version: 0.2.0
allowed-tools: Read, AskUserQuestion, ListAgents, Glob, Grep, Bash(mkdir:*), Bash(gh:*), Bash(git:*), Bash(jq:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/model-matrix.sh --resolve *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/megatask/scripts/build-orchestrator.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/megatask/scripts/init-worktree.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/megatask/scripts/resolve-pbxproj-membership.sh *), Agent(corpflow:product-manager), Agent(corpflow:workflow-engineer), Agent(corpflow:project-manager), Agent(general-purpose)
related:
  - skills/megatask/SKILL.md
  - skills/megatask/references/dependency-graph.md
  - skills/megatask/references/schemas.md
  - skills/megatask/references/git-integration.md
  - skills/shared/milestone-helpers/SKILL.md
  - commands/worktask.md
  - commands/milestone.md
  - agents/workflow-engineer.md
---

> **Execution model** — megatask is the meta-orchestrator: it owns the issue set, builds the
> dependency DAG, and launches one `/worktask` per issue in its own worktree, each as a background
> subagent (§ Step 3). It writes no code and holds no stage logic — stages belong to `/worktask`.
> Every per-issue `PL0` is stamped
> `plan_gate: "bypass"`, `decision_gate: "auto"`, `fn_gate: "bypass"`: a batch cannot stop for one
> issue's approvals or open questions (§ Step 3). Review surface is the per-issue PR; megatask's
> sole human checkpoint is the R1 batch confirmation (Phase 1). `--dry-run` stops once the DAG is
> built — no worktrees, no PRs.

# Megatask Command

Issues run in topological + priority order — never one whose blockers have not merged. Canonical
mechanics: `skills/megatask/SKILL.md`. Two constraints bound every run:

- Orchestrator and per-issue state live in `.context/state.json` `tasks{}`, written only via
  `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh`. Do not use Claude Code's
  built-in plan mode.
- On a dependency cycle, or when the ledger cannot be read or written: stop and report. Never guess
  an order, never fall back to alternative planning.

## Options

`N` or `--issues` is required; given both, `--issues` filters within milestone `N`.

| Option | Values | Effect |
|--------|--------|--------|
| `<N>` (positional) | milestone number | Execute that milestone's open issues (default: none) |
| `--issues N,N,N` | comma-separated issue numbers | Explicit issue array; may span milestones or have none (default: none) |
| `--secure` | — | Forwarded per issue, 11-stage pipeline (default: off) |
| `--platform <p>` | `apple`, `android`, `web`, `systems`, `backend`, `ai`, `all` | Forwarded per issue (default: each issue's detected platform) |
| `--dry-run` | — | Resolve, build the DAG, print the plan — no worktrees, no PRs (default: off) |

Cross-issue concurrency (`parallel_tracks`) is orchestrator-derived, never a flag (§ Track
Derivation); intra-issue async (an issue's DV0 splitting into DV0/DV1/…) belongs to its TL stage.

## Examples

```bash
/megatask <N> | --issues N,N,N [--secure] [--platform <p>] [--dry-run]

/megatask 7                       # milestone 7 by DAG + priority
/megatask 7 --secure              # …with the 11-stage secure pipeline per issue
/megatask 7 --issues 12,15        # subset within milestone 7
/megatask --issues 101,102,103    # explicit, cross-milestone set
/megatask 7 --platform apple      # force Apple routing in every issue
/megatask 7 --dry-run             # preview the DAG/order, touch no git state
```

## Output Format

`--dry-run` stops after the plan block; a live run appends progress and a batch summary:

~~~markdown
# Megatask: milestone <N> | issues <list> · <M> issues · <T> tracks

## Plan — issue | title | blockers | track | priority | worktree path
## Progress — per issue: stage reached, verdict, PR URL, worktree path, any learnings.md left
## Blocked — issues waiting, each naming the blocker issue it waits on
## Summary — merged / open / failed counts, plus follow-up issues filed
~~~

A dependency cycle or an unreadable ledger replaces everything after `## Plan` with
`## Halted — <cycle members or ledger error>`: no worktree is created and no issue is started.

## Phase 1: Resolve & Plan (execute immediately)

Phase 1 creates no worktrees and modifies no project files: only `mkdir -p .worktrees/<group>`,
the R1 audit row, reads, `gh` queries and `build-orchestrator.sh` writing `orchestrator.json` are permitted until R1
clears.

### Phase 1 · Steps 1–2 — Parse arguments & resolve the issue set

1. **Parse** the positional `N`, `--issues`, and forwarded flags. Neither present ⇒ STOP (usage error).
2. **Resolve the issue set**:
   ```bash
   gh api "/repos/{owner}/{repo}/milestones/${N}" --jq '.title'          # milestone mode: validate
   gh api "/repos/{owner}/{repo}/issues?milestone=${N}&state=open" --paginate \
     --jq '.[] | {number, title, labels: [.labels[].name], body}'
   gh issue view "${ISSUE}" --json number,title,labels,body,state        # array mode: per issue
   ```
   Drop `closed` issues and any with a linked PR (`hasExistingPR` —
   `skills/shared/milestone-helpers/SKILL.md`); record them as `skipped_has_pr`.

### Phase 1 · Step 3 — Build the DAG

3. **Build the DAG** with `build-orchestrator.sh`
   (`skills/megatask/SKILL.md § Canonical Scripts`). Feed it the kept issues on stdin as one
   JSON array of `{issue, title, labels, body}` (`issue` is gh's `number`, `labels` the names):
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/skills/megatask/scripts/build-orchestrator.sh --file - \
     --out .worktrees/<group>/orchestrator.json --group <group> \
     --milestone-num <N or 0> --milestone-title "<title>" --base-branch <base>
   ```
   It reads each body's `Depends on: #N` / `Blocks: #M` (what `/milestone` writes) and the
   `P0`–`P3` label, folds `A Blocks B` ⇔ `B Depends on A` into one edge, and reports edges leaving
   the set as `external_dependency` warnings — surfaced, never gating.

### Phase 1 · Steps 4–5 — Order & seed orchestrator.json

4. **Order** — the script sorts topologically with a priority tiebreak (P0 first; FIFO by issue
   number within a tier) and assigns levels. Exit 1 is a cycle: STOP and report the issues it names
   on stderr. Rules + levelled schedule: `skills/megatask/references/dependency-graph.md`.
5. **Seed** — the same call writes `.worktrees/<group>/orchestrator.json` (schema v3.1,
   `skills/megatask/references/schemas.md`): per-issue edges (`blocked_by`/`blocks`/`level`),
   initial `status` (`ready` when `blocked_by` is empty, else `blocked`), priorities, the order, and
   `configuration.parallel_tracks` (Phase 2). `<group>` = `milestone-{N}` or `issues-{shortid}`.

### Phase 1 · Step 6 — R1 batch confirmation gate

6. **R1 — the one human checkpoint** — present the issue set (number, title, priority,
   `blocked_by`), the levelled DAG (what starts now vs. waits), `parallel_tracks` and **total PR
   count**, the projections below, and any `external_dependency` / `skipped_has_pr` notes. Then
   `AskUserQuestion`:

   *"Megatask will execute N issues across M dependency levels, opening N PRs unattended (each
   per-issue worktask auto-approves its plan and finalization). Approve to begin, or adjust scope."*

#### R1 spawn-budget projections

All three are warn-and-continue, never a hard gate. See `skills/megatask/SKILL.md § Track Derivation`.

| Projection | Formula | Cap (default) |
|---|---|---|
| Total spawns | `issue_count × ~9–11 stages` + nested-delegation spawns | no cap (removed in CC 2.1.224) |
| Max chain depth | megatask spends one level on the per-issue orchestrator, so DV → platform-router → Tier-2 lands at **4** | `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` (3) |
| Peak concurrent | `parallel_tracks × (orchestrator + stage agent + nested children)` | `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` (20) |

Over-cap depth ⇒ name both remediations: raise the env var, or flatten Tier-2 dispatch
(`skills/megatask/SKILL.md § Depth remediations`).

#### R1 outcomes

- **Approval** → append a `batch_approved` row (below); continue to Phase 2.
- **Rejection** → append a `batch_rejected` row (below); STOP, surface feedback, create no worktrees.
- **`--dry-run`** → print the plan and STOP here regardless (no gate, no execution).

The row goes through the granted `jq` with an append redirect, because `state-patch.sh
--audit-row` needs a seeded ledger and the batch root has none:

```bash
mkdir -p .context/logs && jq -nc --arg ts "$(date -u +%FT%TZ)" --arg g "<group>" \
  '{ts:$ts, actor:"megatask", action:"batch_approved", subject:$g, result:"ok"}' \
  >> .context/logs/audit.jsonl
```

> A **free-text** R1 answer arrives neutrally worded, not framed as "continue". "Wait, explain the
> depth warning first" is a question, not approval: answer it and re-present the gate.

## Phase 2: Execute (proceeds after R1 approval)

**Track Derivation** — compute once into `configuration.parallel_tracks`; re-derive as blockers
merge and the ready-set grows. Never a flag, never a fixed default; the concurrency and depth
ceilings it respects: `skills/megatask/SKILL.md § Track Derivation`.

```
parallel_tracks = min( count(currently-ready issues), 5 )      # ready = blocked_by empty/all-merged
parallel_tracks = reduce_by_disk_capacity(parallel_tracks)     # each worktree duplicates the tree
parallel_tracks = reduce_by_concurrency_cap(parallel_tracks)   # CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS (20)
# single explicit issue ( /megatask --issues 12 )  ⇒  1
```

### Phase 2 loop · Steps 1–2 — Select ready issues & assign tracks

Execution loop, driven cooperatively with `hooks/megatask-monitor.sh`:

1. **Select** — an issue is *ready* when every `blocked_by[]` entry is `status: "completed"` (PR
   merged, or created where the project merges via PR). Take them in the Phase 1 order.
2. **Assign tracks** — fill up to `parallel_tracks` worktrees; per issue run
   `bash ${CLAUDE_PLUGIN_ROOT}/skills/megatask/scripts/init-worktree.sh --issue {issue#} --title "<title>" --group <group> --track <T> --blocked-by <N,M> --blocks <N,M> --labels <l,l>`.
   It resolves base and branch (`skills/megatask/SKILL.md § Base Branch Resolution`,
   `§ Branch Naming`), creates the worktree at `.worktrees/<group>/{issue#}` with its `.context/`,
   and stamps `workspace.json` (version 2.0). Its `worktree_path=<absolute path>` line, printed on
   a re-run too, is Step 3's `<wt>`. Then set the issue's status `in_progress` and its `track` in
   `orchestrator.json`.

### Phase 2 loop · Step 3 — Launch the per-issue worktask

3. Dispatch one background `general-purpose` subagent per ready issue; its prompt invokes the
   `corpflow:worktask` skill as `/worktask "<issue title>" --auto=[plan,decision,finalization]`
   (plus any forwarded `--secure`/`--platform`), with the run environment and standing directives
   below and this `PL0.metadata` stamp. Not a headless `claude -p`: `hooks/megatask-monitor.sh`
   runs on its `SubagentStop`, and R1's depth and concurrency math count it as one spawned level.
   `{ stage:"PL", agent:"corpflow:product-manager", model:"<model>", effort:"<effort>",
   issue_number, track, workspace_path:"<wt>", isolation:"worktree",
   plan_gate:"bypass", decision_gate:"auto", fn_gate:"bypass", approved:"auto",
   megatask_group:"<group>", milestone:<N|null> }`, `<wt>` being the absolute path Step 2 printed.

#### Step 3 — gates: the flags, then the stamp at worktask Step 4

The per-issue ledger does not exist until `/worktask` Step 3a seeds it, so megatask never writes
that PL0 itself. Order: Step 3a seeds `tasks.PL0`; Step 4 stamps the gates from the `--auto`
values (`bypass`/`auto`/`bypass`, the stamp's own values) and overlays this stamp in the same
`--task-meta PL0` call, stamp keys winning (`commands/worktask.md § Step 4 — the /megatask
stamp`). No `checkpoint`/`user` default lands on a per-issue PL0. The run is unattended and
milestone-agnostic; the batch markers below make it skip its own GitHub-issue publish, since the
parent milestone/issue is the canonical record.

#### Step 3 — run environment in the per-issue prompt

State these with `<wt>` filled in. A subagent's shell starts in megatask's root on every call and
keeps no variables, and without `WORKSPACE_ROOT` the state scripts resolve megatask's own
`.context/state.json` through `CLAUDE_PROJECT_DIR`.

- Open the prompt with the line `WORKSPACE_ROOT=<wt>`; hooks bind to the issue by it (below).
- Begin every Bash call with `cd "<wt>" && export WORKSPACE_ROOT="<wt>" MILESTONE_MODE=1 &&`.
  `MILESTONE_MODE` and `<wt>/workspace.json` are how the scan, preflight, publish and branch
  scripts recognise a per-issue run.
- Read, Edit and Write take absolute paths under `<wt>`.
- Never call `EnterWorktree`: the `cd` already runs every call in the worktree, and a path outside
  `.claude/worktrees/` asks for a confirmation nobody is there to give.
- Never wait on the user: every stop settles the issue in `workspace.json` first
  (`skills/worktask/references/megatask-per-issue.md`).

#### Step 3 — how hooks find the issue

Hooks run as their own processes with megatask's environment, so the Bash export never reaches
them, and a subagent's cwd is megatask's root. `corpflow_bind_payload` (`hooks/model-switch-lib.sh`)
binds each hook process to `<wt>` from its payload; the first valid candidate wins: the
`WORKSPACE_ROOT=` line in the acting agent's prompt, a `WORKSPACE_ROOT=<wt>` assignment in its Bash
command (read as text, never expanded), the payload's `cwd`, the hook's own cwd. Only a stamped
`.worktrees/<group>/<issue#>` under megatask's root with its own ledger binds. The cwd ranks last,
so a session inside one issue's worktree cannot pull other issues onto its ledger. Stage briefs
carry the banner (`commands/worktask.md § Banner injection`). The audit, merge, DV-gate and
`test-execution-gate` hooks then use `<wt>/.context/`, never the batch's. Each binding lives in one
hook process, so concurrent issues cannot cross.

#### Step 3 — PL0's model and effort

Resolve the pair once per batch, the way `/worktask` does (`commands/worktask.md § Step 4 — PL0's
model and effort`), never type it: `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/model-matrix.sh --resolve product-manager`
prints `<model>`, `<effort>` and the source, tab-separated; paste the first two into every
issue's stamp.

#### Step 3 — standing directives in the per-issue prompt

Include these verbatim in every per-issue dispatch prompt — a prompt is read once per run, a
reference file is not.

- Read `## Shared Seams` in the batch's registry issue before introducing any shared protocol,
  dependency-injection extension point, coordinator, or shared test assertion. The registry issue is
  the batch's foundation issue — its sole level-0 issue (the only empty `blocked_by[]`) — or, when
  the batch has several level-0 issues or none, the milestone issue / orchestrator issue (`--issues`
  mode). Name that number explicitly; there is exactly one per batch. If the seam is registered,
  conform to the declaration exactly, labels and order included; if not, add an entry rather than
  inventing a parallel abstraction (`skills/megatask/SKILL.md § Shared-Seam Registry`).

##### Step 3 — conflict directives

- Read `skills/megatask/references/git-integration.md § Conflict Recovery` before resolving a merge
  conflict. Two rules apply regardless: (1) dependency-injection and coordinator-shaped conflicts
  are hand-resolved, never script-merged; (2) run a real build and the real tests after any conflict
  resolution, before pushing.

#### Step 3 — decision_gate and issue parking

`decision_gate:"auto"` is stamped because a batch is unattended: PL0 open questions route through
the Fable decision pass (`commands/worktask.md § Step A.4`) instead of parking on a human.
Escalate-class questions are never auto-decided — they park that one issue while the batch proceeds
with the other unblocked issues.

##### Step 3 — parking mechanics

Parking rides the monitor's existing failure path, so it needs no new state: the per-issue worktask
writes `workspace.json.execution.status: "failed"` with `execution.reason: "parked_escalation"` and
an `escalation_parked` audit row (`commands/worktask.md § Escalation guard — unattended /megatask per-issue runs (PARK)`);
`hooks/megatask-monitor.sh` settles it like any failed issue — track freed, dependents stay
`blocked`. Any other stop for the user settles the same way with `execution.reason:
"escalated_to_user"` (`skills/worktask/scripts/megatask-settle.sh`). The batch summary lists each
parked or escalated issue (told apart by `execution.reason`) with its unanswered questions or its
`megatask_escalated` row, so the user can re-run it interactively, re-scope, or drop it.

### Phase 2 loop · Steps 4–6 — Monitor, completion, termination

4. **Monitor** — `hooks/megatask-monitor.sh` (SubagentStop) settles each finished issue and
   unblocks its dependents; each loop turn the orchestrator re-reads `orchestrator.json`, re-derives
   `parallel_tracks`, and assigns freed tracks (`skills/megatask/SKILL.md § Monitoring Loop`).
5. **Completion / errors** — success: PR with `Closes #{issue}`, track freed. Failure: `failed`,
   track freed, worktree preserved for debugging — a failed blocker leaves its dependents
   permanently `blocked`, so report them.
6. **Terminate** when no track is active and every issue is `completed`, `failed`, or `skipped`:
   print per-issue status + PR links, then `git worktree prune`.

## Relationship to /worktask and /milestone

`/milestone` writes issues carrying `Depends on` / `Blocks` / `P0`–`P3` → `/megatask` reads that DAG
and runs one `/worktask` per issue → `/worktask` executes one issue's milestone-agnostic pipeline
(PL→…→ST). Edge semantics and status values: `skills/megatask/SKILL.md § Dependency & Blocker
Resolution`, `§ Status Transitions`.
