# Ledger field notes

Read when executing or checking ledger field notes. Read linked modules only when their conditions apply.

Read these sections only when this procedure cites them.

###### Section lookup 1

[tasks](ledger-tasks.md#tasks) · [tasks — settle, the cited set and the change set — invocation and table](ledger-tasks.md#tasks--settle-the-cited-set-and-the-change-set--invocation-and-table)

<!-- canonical-body:start -->
#### Field notes — progress

OPTIONAL. Budget-aware checkpoint for multi-batch stages (currently DV), written after each sub-batch commit so a budget-exhausted agent leaves a resumable record instead of a progress narration. The orchestrator reads `next_batch` to resume where the stage stopped (`agents/developer.md § Budget-Aware Checkpointing`; `skills/worktask/references/dispatch-readiness.md § Orchestrator Execution Loop` step 4.7). Batch ids only — never diffs, file contents, or test output.

#### Field notes — completed_via

OPTIONAL (additive). Which enforcement layer stamped this stage `completed`: `hook` = SubagentStop delegation (Layer 2, `state-merge.sh` default); `step6_5` = orchestrator synchronous Step-6.5 (`STATE_MERGE_VIA=step6_5`); `f3` = orchestrator F3 minimal-patch fallback. Absence encodes a Layer-1 agent self-patch: the hook's idempotency check exits before writing when Layer 1 already landed. Observability only; no consumer branches on it.

#### Field notes — last_error

OPTIONAL (additive). Written by the orchestrator Step-6.5 errored-return branch (errors propagate with partial work) before routing to the retry matrix. `class` reuses the taxonomy in `agent-coordination § Retry / Escalate Matrix` — no new vocabulary. Dropped once the stage reaches `status: completed` (eviction rules).

#### Field notes — worktree

OPTIONAL (additive; DV primarily). Records which worktree the stage ran in, not just `worktree: true`. Written by mapping the DV handoff frontmatter `worktree_path`/`worktree_branch` (`state-patch.sh`). Lets resume re-enter the exact worktree via `EnterWorktree(path)`, DR/QA run in the right dir, and FN carry PR context. The PR *head* comes from `facts.branch`, not here (disambiguation below). Kept through FN; dropped at archival.

#### Field notes — tests_executed, rework_runs

OPTIONAL (DV and QA rows), written only by `state-patch.sh`. The completion merge mirrors the artifact's `handoff.tests_executed` list into `tests_executed`, and drops the key when the artifact carries none. `--task-replay` sets `rework_pending: true` on a row that holds `tests_executed`; the next completion merge appends `{round: <last round + 1>, tests_executed: <the row's previous list>}` to `rework_runs`, deletes the marker, then mirrors the new list. Entries are never rewritten, so an artifact carries only its own round and no stage copies an earlier one forward. A re-merge of the same artifact without a replay appends nothing, and a blocked round resumed through `--claim` stays one round.

##### Field notes — rework_runs, where no round is filed

Without `yq` the merge cannot parse the list, so it leaves the mirror and the marker as they were. The Edit-direct fallback (`skills/worktask/references/contracts/ledger-edges.md#layer-1-fallback`) does not maintain these keys: leave `tests_executed`, `rework_runs` and `rework_pending` untouched and never write a round by hand; the next scripted completion files it.

#### Field notes — branch

OPTIONAL (additive). The worktask's planned working-branch name — the host-session branch as
`branch-name.sh` left it at the start of PL, whether it renamed it or found it already
conventional. Written at PL start, rewritten at most once at `skills/worktask/references/workflow.md § Step A.4b`
before any commit exists, and never by a stage (`skills/shared/git-conventions.md § Once-only
rule`). FN uses it as the pull-request head, reading the ledger rather than `git rev-parse` so an
external mid-run rename surfaces as a mismatch instead of retargeting the PR. Not the same field as
`tasks.DV0.worktree.branch` (disambiguation below). Kept through FN; dropped at archival.

##### Field notes — branch, divergence from the local branch name

`facts.branch` may legitimately differ from `git rev-parse --abbrev-ref HEAD` on the
`upstream_tracked` and `target_exists` arms, and inside a linked worktree under
`BRANCH_NAME_WORKTREE_RENAME=0` — there `branch-name.sh` keeps the host's local name and returns
the derived `target_branch=` for the PR head, so the host's branch↔workspace mapping survives
(`workspace-modes.md § Host mapping — updated, not preserved`). On the default worktree path
the branch is renamed and the two agree.

Divergence is observed, not merely tolerated: `fn-preflight.sh branch-divergence` classes it
`expected` or `third_party` and surfaces only `third_party` at the FN gate; its comparison base is
the `to` of the last `branch_renamed / ok` row, not this field. No reader may "repair" it by
re-deriving from the local branch — the ledger value is the planned name, and the PR head is what
it plans.

##### Field notes — branch, empty value

`branch-name.sh` prints `branch=` (empty) for a detached HEAD or not-a-git-repo — never the
literal `HEAD`, which is not a branch. FN treats an empty `facts.branch` as "no planned name
to push under": skip the `git push -u origin HEAD:refs/heads/<facts.branch>` refspec entirely and
fall back to a plain `git push -u origin HEAD`. On a detached HEAD that fallback fails loudly
("The destination you provided is not a full refname") — an acceptable failure: no wrong target,
no silent error.

##### Disambiguation — `facts.branch` vs `tasks.DV0.worktree.branch`

Two fields, disjoint definitions, neither derived from the other:

| | `facts.branch` | `tasks.DV0.worktree.branch` |
|---|---|---|
| Meaning | planned host-session branch name | observed branch of the worktree DV ran in |
| Writer | orchestrator, from `branch-name.sh` stdout, at PL start; then `refine-branch-target.sh` at Step A.4b | `state-patch.sh`, from DV handoff `worktree_branch` |
| Written when | before any commit exists | after DV completes |
| Rewritten | at most once more, pre-commit (§ Step A.4b); never by a stage | per DV re-dispatch |
| FN uses for | the PR head | worktree re-entry context only |

##### Disambiguation — topology note

They are equal in the common topology where the session's workspace is the worktree
(`agents/developer.md § Field notes — worktree fields`), and differ when DV created a fresh
`.claude/worktrees/` worktree whose branch the tool named itself. A mismatch is information,
not an error: it tells FN the commits live somewhere other than the planned branch, exactly
what `fn-preflight.sh continuity` handles. No writer copies one into the other.

#### Field notes — stream_branches

OPTIONAL (additive). Present only after the FN multi-stream arm committed each stream: the branch
each stream's commit sits on, keyed by `tasks.DV<k>.metadata.stream`. `fn-stream-merge.sh merge`
merges each value into `facts.branch` and blocks on a missing key; `fn-preflight.sh continuity`
switches to its per-stream ancestor check once the object holds ≥2 keys. It is not the PR head —
`facts.branch` stays that — and no writer copies a value from one into the other.

#### Field notes — goal

One-sentence worktask intent, populated by PL0 from the task description (or the issue title under `/megatask`). Read by stages needing the original intent without re-reading the plan file (AR sanity-checking architecture against requirements, FN composing the PR title). Single surface for this value — do not introduce a parallel one.

#### Field notes — files_read

Source files read by prior stages. Populated by DV; consumed by DR/QA, which use `git diff <base>..HEAD -- <path>` instead of `Read <path>` for any file listed. Full reads stay permitted when the diff is insufficient. Absent ⇒ normal reads.

Second reader: the stale-settlement check reads it as half of a dependent's cited set (§ tasks — settle, the cited set and the change set — invocation and table).

Scripted writer: `state-patch.sh --files-read <TASK_ID> <path>...` unions `{path, stage, lines: "all"}` — `stage` is the code of `<TASK_ID>`, a leading `./` is stripped, and the newest entry wins per path. A path that is empty, longer than 512 characters, or holds a TAB/CR/LF fails the whole call (exit 2). Past 30 entries the oldest are dropped without a spill file: this is a read hint, not a record.

#### Field notes — verdicts

`facts.verdicts.<TASK_ID>` is the verdict each task reported; `facts.verdicts.<CODE>` is derived in the same atomic write as the worst verdict among the `<CODE>N` rows that carry one (rows with no verdict yet are ignored, a tie goes to the highest `N`). Rank, worst first: `escalate` > `blocked` > `fail`|`reject`|`no-go` > `ok`|`pass`|`go`|`approve`; a legacy stored string outside the map ranks with `fail`. `blocked` outranks `fail` because it needs outside input while the loop repairs a `fail` itself. Existing `.DR`/`.QA`/`.DV` readers keep working unchanged. `--task-replay` keeps a row's verdict, so the stage key stays stale until that row is patched again.

#### Field notes — dispatched_agents

OPTIONAL (additive). Writer: the orchestrator loop only, through `state-patch.sh --dispatch <TASK_ID> <agent_id> <launched|completed|failed>`, which derives `stage` from the id and `subagent_type` (plus `model_requested` when set) from the row's `metadata.agent`/`metadata.model` — a row without `metadata.agent` is refused (exit 2). On Codex, the unchanged `agent_id` field holds the returned agent id when available, otherwise the exact canonical task name (`/root/...`). One entry per `task_id` (not per stage — parallel DVN tracks share the stage code): the same `agent_id` updates in place, a different one replaces the entry at the tail; dispatch history stays in `audit.jsonl`. Read by resume (`resume.md` step 0) to reconcile against the active host adapter. No dispatch timestamp is stored (host agent rows carry their own). Terminal entries (`status: completed|failed`) are eviction candidates.

#### Field notes — capabilities

OPTIONAL (additive). Probe cache for account-level hard-fails, so later stages do not re-hit the same error. Written by the orchestrator on first observed failure; model resolution consults it before any fable-tier dispatch. Example: `{ "fable_dispatch": "credit_blocked", "checked_at": "<ISO>" }` — Fable 5 is 1M-by-default but *dispatch* fails hard without 1M credits (model-selection.md). `effort_cap` maps a model alias to the highest effort tier the account runs, e.g. `{ "effort_cap": { "opus": "high", "checked_at": "<ISO>" } }`. Written by Step 6.5b-cap when a stage's hook-reported effort comes in below the tier it requested (an admin cap Claude Code lowers silently). Read at every route call as `effort-route.sh --cap`, so later stages dispatch at the ceiling instead of retrying above it.

### Eviction order on overflow

When state.json approaches the 500-token cap:

1. Drop `tasks.<ID>.artifact` paths for stages with `status=completed` once their `handoffs` edge string captures the essentials.
2. Drop `facts.open_questions` whose status is resolved (the newest-4-per-task clamp applies the same preference automatically at every write, inside each task's bucket).
3. Drop `facts.decisions` older than 2 stages back (keep current + previous stage decisions).
4. Drop `facts.files_read` entries whose `stage` is older than 2 stages back.

#### Eviction steps 5–8

5. Drop terminal `facts.dispatched_agents[]` entries (`status: completed|failed`) — live-agent reconciliation no longer applies; history persists in `audit.jsonl`.
6. Drop `tasks.<ID>.last_error` + `completed_via` once the stage is `completed` (error resolved; provenance was observability-only).
7. Keep `tasks.<ID>.worktree` through FN (PR context needs the branch); drop at archival.
8. Never store diffs, file contents, or test output. Fetch from git/disk on demand.
