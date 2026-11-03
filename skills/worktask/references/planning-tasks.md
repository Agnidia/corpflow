# Planning tasks

Read when executing or checking planning tasks.

Procedure routing: [pl0-procedure](pl0-procedure.md).

<a id="section-lookup-1"></a>
Related: [Workspace Mode](planning-artifacts.md#workspace-mode) · [Plan File & Run Index Naming](planning-sizing.md#plan-file--run-index-naming)

<!-- canonical-body:start -->
### Stage Artifact Naming

Every stage writes `<basename>-N.md`, N = this run's `planning-N.md` index. Canonical stage→basename map: `skills/worktask/references/contracts/artifact-map.md#stage-artifact-map` (mirrored in `skills/worktask/references/stage-codes.md`). Two-step resolver: (1) `task.metadata.run_index` → `<basename>-${N}.md`; (2) newest glob `<basename>-*.md` when metadata is absent.

### PL0 Stage (Planning)
- Detect workspace context per § Workspace Mode — workspace mode (`/megatask` per-issue run): read the issue from `workspace.json`, write artifacts to the workspace's `.context/`; standard mode: create `.context/`
- Compute `<plan_file>` per § Plan File & Run Index Naming, then write `.context/<plan_file>` with requirements and acceptance criteria
- Define the test strategy (what to test, existing tests to update), scope, priorities, dependencies
- Detect the integration branch once and stamp it (below), so DV does not fork from the wrong branch
- Create the stage tasks from the complexity assessment (below)

<a id="branch-naming--query-modes-are-free-refinement-is-not-pms"></a>
#### Branch naming (already done by the orchestrator — do not re-run)

PM reads `facts.branch`; the orchestrator already ran rename mode at Step 3c.
Query modes (`--check`, `--print-types`, `--print-target`, `BRANCH_NAME_PRINT=1`) write nothing and are unrestricted.
Only the orchestrator refines the planned ledger target at Step A.4b after this return; revisions never re-refine.
The local name may differ on host opt-out/no-op arms; default worktree names agree.
Full branch lifecycle: [launch-seed](launch-seed.md#step-3c--name-the-branch-once-pl-start); argv/env/exit contract: `branch-name.sh --help`.

#### Integration-branch detection

Run once, at PL0, through the shared resolver so every reader agrees on the ranks (canonical:
`skills/worktask/references/contracts/ledger-root.md § metadata.base_ref`):

| Rank | Source |
|---|---|
| 0 | `fork_base()` fork point — evidence, opt-in; reconciles by sweep item rather than overriding |
| 1 | `$FN_BASE_REF` — explicit operator/test override |
| 2a | `state.json tasks.<ID>.metadata.base_ref` — the row named in `$BASE_REF_TASK_ID` |
| 2b | `state.json .metadata.base_ref` — where a host-declared target branch enters the order |
| 3 | `workspace.json .git.base_branch` — `/megatask` per-issue record |
| 4 | `git symbolic-ref refs/remotes/origin/HEAD` — repository default branch |
| — | unresolved — reported, never guessed |

##### Calling the resolver

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
. "$PLUGIN_ROOT/skills/worktask/scripts/branch-lib.sh"
BASE=$(BASE_REF_TASK_ID=PL0 resolve_base_ref); BASE="${BASE#origin/}"
```

Source from the plugin root; project checkouts lack this relative library. `PL0` selects rank 2a before the mirror.
The megatask stamp has no `base_ref` key.

There is no literal fallback: an unresolved base is reported and the caller degrades
non-blocking, because a hardcoded `master` may name a branch that does not exist. PL0 does not
pass `--with-fork-point`: an empty answer here is a fact to report, and rank 0 reaches the plan
through the reconcile stub below.

##### Reconcile a disagreeing fork point — never override it

With `$BASE` known, compute `fork_base "$BASE"` (its argument is the tie-break and keeps rank 0
from recursing). When the answer is non-empty and differs from `$BASE` after stripping the `origin` remote prefix,
emit one sweep stub — `class: decision`, `blocks_next_stage: false` — carrying both branch names
and both ahead-counts, fork point recommended:

> Base branch: `<configured>` (configured, source `<rank>`) vs `<fork>` (fork point). HEAD is `<n>`
> commits ahead of the first, `<m>` ahead of the second. Recommended: `<fork>`. A fork point is
> evidence, not intent — a branch deliberately rebased onto a release line is a legitimate reason
> to keep the configured value.

###### When no item is emitted

Agreement, an empty fork point, no remotes or a detached HEAD ⇒ no item. PL0 never rewrites
`metadata.base_ref` from the fork point; only a user answer at the plan gate does. Under
`--auto=[decision]` the default is to keep the configured base, since auto-adopting the fork point
would be the silent retarget this reconcile exists to prevent.

##### Where to stamp the detected branch

Stamp the result in two places, unconditionally (`master` included):

- `task.metadata.base_ref` on PL0 and every downstream task — `--task-create` refuses a downstream row without it. DV reads it as the per-task base override (`agents/developer.md § Worktree Mode`).
- `state.json .metadata.base_ref`, in the step-4 reset. Shell scripts cannot read Task-System metadata, so this mirror is how `branch-lib.sh resolve_base_ref` (rank 2b) sees the value when the caller names no task. On a turn that skips the reset (`plan_revision`), write it with `state-patch.sh --ledger-meta --set '{"base_ref":"<branch>"}'`, not a hand edit — a hand edit bypasses the lock and the bounds filter.

Reader resolution order is canonical in `skills/worktask/references/contracts/ledger-root.md § metadata.base_ref`.

#### Subagent model-force preflight — detection

Run once at PL0, before the plan gate: `printenv CLAUDE_CODE_SUBAGENT_MODEL_FORCE` and `printenv CLAUDE_CODE_SUBAGENT_MODEL`. A non-empty force variable overrides every stage's `metadata.model` at spawn — each subagent runs on `CLAUDE_CODE_SUBAGENT_MODEL` or the session model (`skills/shared/model-selection.md § Forced subagent model overrides every pin`).

#### Subagent model-force preflight — sweep item

When it is set, emit one sweep stub — `class: decision`, `blocks_next_stage: false`:

> Stage model pins will not hold: `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` is set, so every stage runs on
> `<CLAUDE_CODE_SUBAGENT_MODEL, or "the session model">`, including stages this plan sizes
> `opus`/`xhigh`. Proceed on the forced model, or stop, unset the variable, restart and re-run. Recommended: unset and restart.

#### Subagent model-force preflight — gate behavior

Unset or empty ⇒ no item. Under `--auto=[decision]` the default is proceed, because a delegate cannot change the session environment. PL0 reads the variable itself; only whether to run under it reaches the gate.

#### `--no-gh-issue` opt-out

Under `--no-gh-issue`, `/worktask` Step 4 has already stamped `metadata.no_gh_issue: true` on PL0; copy it to every downstream task you create. The orchestrator's publish step (`skills/worktask/references/completion-handoff.md § PL Issue Publish`) reads it via `skills/worktask/scripts/publish-pl-issue.sh`, which exits 0 with no `gh` call, auditing `result: "deferred"`, `reason: "opted_out"`. The stage loop is unaffected.

##### Default publish path (flag absent) & megatask opt-out

Flag absent (default): leave the field unset; the helper runs the full pipeline (sanitise → `gh issue create` → state.json write → audit row). Canonical flag list: `skills/worktask/references/workflow.md`; runtime semantics: `skills/worktask/references/completion-handoff.md § PL Issue Publish`.

Per-issue `/megatask` runs opt out implicitly: the helper detects batch per-issue context via `state.json:metadata.milestone` or `workspace.json` presence and exits `0` with `reason: "milestone_mode"` before any `gh` call.

#### Anchor-content hygiene (GitHub publish safety)

`publish-pl-issue.sh` publishes the `## requirements`, `## acceptance-criteria`, `## scope` and `## complexity` anchors of `<plan_file>` (plus `## summary`) to a GitHub issue once the user approves the plan. Keep them free of:

- `.context/` paths or numbered artifact filenames (`planning-N.md` … `ethics-review-N.md`);
- absolute/relative source paths (`/Users/`, `/home/`, `/tmp/`, `~/`, `./`, `../`, …) and Conductor workspace ids (`conductor/workspaces/<id>`);
- the literal tokens `workspace_path`, `plan_file`, `run_index`, `artifact_path`;
- raw plugin-qualified identifiers (token shape `lowercase-prefix:lowercase-name`, e.g. `corpflow:developer`) — rewrite to human-readable prose ("the iOS developer", "Complexity breakdown:").

##### Identifiers, backticks & the sanitiser

Identifiers/paths are allowed only inside inline backticks / fenced code, or in the `## stages` anchor (orchestrator-only, never rendered). Keep file references narrative ("the AuthCoordinator class"). The `publish-pl-issue.sh` two-pass sanitiser (Pass-1 line-drop of `Routed to <prefix>:`/`.context/` lines + Pass-2 identifier strip over the known-prefix allow-list) is a safety net, not a substitute: it aborts with `reason: "sanitiser_aborted"` when >50% of the combined anchor bodies is stripped, costing a review round-trip.

##### Design Preview anchor (Figma URL capture)

When the task description contains a Figma URL — regex `https?://(?:www\.)?figma\.com/(?:file|design|proto)/[A-Za-z0-9]+(?:/[^?\s)]*)?(?:\?[^\s)]*)?` — PL0:

1. Extracts every matching URL.
2. Authors a `## design-preview` anchor in `<plan_file>` with the URL(s), one per line. No Figma URL ⇒ no anchor; the publish helper omits the section.
3. Self-patches `state.json:facts.design_url` with the URL (string for one URL, array for multiple).
4. Notes the URL in the `## scope` "In" list for reviewer visibility.

###### Rendering & post-capture rewrite

This anchor is excluded from the strip-ratio denominator (short URL bodies would skew the guard) and renders between `## Scope` and `## Complexity` with a one-sentence reviewer instruction. Once `### Figma Design Capture` has persisted per-frame PNGs to `.context/designs/` (tracked in `figma-registry.md`), the PM's Post-Capture Plan Update rewrites `## design-preview` to name each frame via an asset-placeholder token + state mapping (`skills/shared/figma-capture.md § Post-Capture Plan Update`).
