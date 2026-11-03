# Plan approval

Read after PL completes and its decisions are resolved, before implementation dispatch.

Procedure routing: [workflow](workflow.md).

<!-- canonical-body:start -->
### Step A.5 — Plan Gate Check (after A.4, before Step A publish)

Read `tasks.PL0.metadata.plan_gate` (default `"checkpoint"`). Resolve the run index `N` from
`state.json.run_index` (default `0`).

#### Plan gate checkpoint path

**If `plan_gate == "checkpoint"`** (default):
1. Read `state.json.plan_file` to locate the plan; accept either shape (`skills/worktask/references/contracts/ledger-root.md §
   plan_file shape boundary`).
2. Present the plan summary: complexity score, stages created (with agents), dependency chain, key
   decisions, and both inclusion decisions (below).

##### Plan gate checkpoint path — the sweep render

2b. Render PL's unresolved sweep items first — every `facts.open_questions[]` item whose id matches
   `sw-PL<N>-*` and whose `status` is not `"resolved"` — through § Step C.4 (question text and
   `options[]` from `planning-N.md#elicitation-sweep`) and record the answers through § Step C.5,
   with `subject:"PL<N>"` on every audit row. These are separate `AskUserQuestion` calls; the
   approve/reject call in step 3 fires last and unmodified, exactly as at the FN gate.

##### Plan gate checkpoint path — the approval call

3. `AskUserQuestion`: *"Here is the generated plan for your worktask. Approve to begin
   implementation, or describe any changes you want first."* The gate holds until a human answers.
   Keep the `/config` idle-timeout opt-in off on hosts running gated worktasks: an idle auto-answer
   would count as an approval the operator never gave.

##### What counts as approval — and what does not

The gate holds for an explicit human answer to this call. Three things that routinely look like
approval are not:

- **A subagent returning `verdict: ok`.** PL0 finishing means the plan exists, not that anyone
  accepted it. No agent can approve on the user's behalf, and no message from one is the user's
  consent.
- **A background-task completion notification**, which states on its face that no human input
  occurred.
- **A free-text reply that is a question.** "Wait, explain the AR exclusion first" is a question:
  answer it and re-present the gate. Same rule as `commands/megatask.md § R1 outcomes`.

Only the user's own answer, or `plan_gate == "bypass"` set before the run, moves past this point.
Recording `approval_received` on anything else fabricates the one row an operator relies on to know
a human saw the plan.

##### Stage-inclusion decisions in the gate summary

The step-2 summary shows both decisions explicitly, each with its one-line reason drawn from
`skipped_stages`/`added_stages`:

- **AR** — included or excluded, and whether that deviates from the tier default (flag the
  deviation; a tier-default AR still states its reason for being kept).
- **TL** — included or excluded on the split-work test, naming the workstreams when included.

##### Branch name in the gate summary

It also shows `Branch (PR head): <ledger_branch>` (the Step A.4b value), so the user sees the
name the PR will carry before anything is published. An empty `ledger_branch=` means unknown, not
absent: the `jq_unavailable` arm prints it empty even when a good name is stamped — so on empty, read
`facts.branch` directly and print `Branch (PR head): — (none planned)` only if that read is also
empty.

##### Branch name in the gate summary — conditional additions

- `⚠ name truncated at 48 chars (<input_len> chars of input)` when a `branch_slug_truncated` row
  exists for `PL<N>` (the Step 3c row).
- `(refined from <old> via plan title)` when the Step A.4b row is `result: "ok"`.
- `⚠ renamed inside a linked worktree — your host's workspace↔branch mapping may need to re-sync;
  set BRANCH_NAME_WORKTREE_RENAME=0 to keep the host's name` when the Step 3c `branch_renamed / ok`
  row carries `in_worktree: "true"` — reporting the Step 3c rename, not asking; reversible with
  `git branch -m <original>`.

This is the last point at which a name is free to change: a user who dislikes it says so here, and
the plan revision path re-derives nothing (§ Plan-revision invariants row 5).

#### Plan gate approval / rejection audit rows

4. **On approval**, stamp the carrier: `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-meta PL0 --set '{"approved":"user"}'`, then append to `.context/logs/audit.jsonl` and proceed to Step A. Stamp before the row: a crash between them then re-prompts on resume, while row-first would resume into the stage loop with the carrier unset.
   ```json
   {"ts":"<ISO>","actor":"orchestrator","action":"approval_received","subject":"PL<N>","result":"ok"}
   ```
5. **On rejection / revision**, append:
   ```json
   {"ts":"<ISO>","actor":"orchestrator","action":"approval_rejected","subject":"PL<N>","result":"rejected"}
   ```
   Stop without entering the stage loop and surface the user's feedback. For revisions, re-dispatch PM per § Plan-revision re-dispatch (not a new run).

##### Plan-revision re-dispatch (gate rejection only)

A gate rejection revises the run in flight. `run_index` and `plan_file` are frozen for the life
of a run: allocating `planning-<N+1>.md` forks the plan, wipes the `facts.decisions[]` the user just
supplied, strands the stage-task chain on the old index, and splits the published-issue record.
Re-dispatch product-manager with `plan_revision: true` in the prompt, carrying the feedback verbatim.
PM's own arm: `pl0-procedure.md § Revision of the run in flight`.

##### Plan-revision invariants

| # | Do | Never |
|---|---|---|
| 1 | Edit the existing `planning-<N>.md` in place | Allocate `planning-<N+1>.md` |
| 2 | Patch `facts.*` additively — `facts.decisions[]` survives | Run the state.json reset |
| 3 | Patch the existing stage tasks | Seed a second stage chain |
| 4 | Leave the published GitHub issue as-is | Re-publish or re-anchor the issue |
| 5 | Leave the refined `facts.branch` as-is | Re-run Step A.4b — a revision is not a new naming window |

##### Plan-revision bookkeeping

Set PL0 back to `in_progress`, increment `metadata.revision_count` (absent → `1`), and append exactly
one audit row before dispatching:

```json
{"ts":"<ISO>","actor":"orchestrator","action":"plan_revision_dispatched","subject":"PL<N>","result":"ok","metadata":{"revision_count":<count>}}
```

On PM's return, re-enter the plan gate at Step A.5 — the revised plan needs its own approval, and
Step A still runs exactly once per run (the issue is published after the approved plan).

#### Plan gate bypass path — auto approval

**If `plan_gate == "bypass"` and no unresolved `escalate` items remain**: stamp `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-meta PL0 --set '{"approved":"auto"}'`, then proceed directly to Step A. No prompt and no audit row: the bypass carrier is the approval. The escalation guard is a precondition, so never stamp ahead of its stop — a crash would resume into the stage loop with escalation-class questions unanswered and the check passing.

#### Plan gate bypass path — escalation exception

Exception: unresolved `escalate` items force a `checkpoint`-style stop first (§ Escalation guard).
Once answered, stamp `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-meta PL0 --set '{"approved":"user"}'`, then append the
standard `approval_received subject:"PL<N>"` row (required as the escalate resolution), then resume
at Step A, not at the arm above: re-entering it would overwrite a real human approval with `auto`.
Stamp before row, as in the approval arm.

### Step A — Publish plan to GitHub (run before the stage loop)

    pub_rc=0
    bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/publish-pl-issue.sh || pub_rc=$?

#### Step A snippet — continued: audit a deferred row when the helper is missing

    # Exit 127 means bash found no helper at that path; the helper audits every other outcome itself.
    if [ "$pub_rc" -eq 127 ]; then
      LOG_DIR="${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-.}}/.context/logs"
      mkdir -p "$LOG_DIR"
      STATE_FILE="${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-.}}/.context/state.json"
      jq -cn --arg ts "$(date -u +%FT%TZ)" --arg dk "$(jq -r '.worktask_id // "unknown"' "$STATE_FILE" 2>/dev/null || echo unknown):$(jq -r '.run_index // 0' "$STATE_FILE" 2>/dev/null || echo 0):gh_issue" \
        '{ts:$ts, actor:"orchestrator", action:"github_issue_created", subject:"PL0", result:"deferred", task_id:"1", metadata:{via:"publish-pl-issue.sh", reason:"helper_not_found", dedupe_key:$dk}}' \
        >> "$LOG_DIR/audit.jsonl"; true
    fi; true

#### Step A publish invariants

- The `|| pub_rc=$?` capture and the trailing `; true` are required: non-blocking. A
  helper failure does not fail the worktask.
- The helper self-skips (`--no-gh-issue`; megatask per-issue mode, detected via `workspace.json` /
  `metadata.milestone`; already published; missing `gh`/auth/remote) — each exits 0 and audits a
  `deferred` row. Sanitiser rules: `skills/worktask/references/completion-handoff.md § PL Issue Publish`.
- One `.context/` ↔ one GitHub issue: a later run resolves the run-independent
  `.context/gh-issue.json` anchor and comments instead of duplicating (`skills/gh-issue-dedup`).
- Run it here even though SKILL.md also describes it.

#### After Step A — run the stage loop

Execute the loop from `skills/worktask/references/dispatch-readiness.md § Orchestrator Execution Loop`. Before the FN
`Agent()` delegation apply the FN gate check (stop on `checkpoint`, proceed on `bypass`) —
`skills/worktask/references/finalization-policy.md § FN Gate`.
