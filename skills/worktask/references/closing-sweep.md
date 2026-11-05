# Closing sweep

Read when executing or checking closing sweep.

Procedure routing: [workflow](workflow.md).

<a id="section-lookup-1"></a>
Related: [Error Handling](workflow-completion.md#error-handling) · [Escalation guard — raise-only self-labels](plan-transition.md#escalation-guard--raise-only-self-labels)

<!-- canonical-body:start -->
##### Step C.0a — what the prompt carries

Paths, not inlined content — the § Step A.4 convention. Resolve artifact filenames through
`handoff-protocol.md #stage-artifact-map`; build no second mapping. Context tiers: `skills/worktask/references/contracts/sweep-boundaries.md § What the resolver is given`.

The delegate answers each item default-biased — deviate from the stage's own `recommended` entry
only with stated evidence — and returns one entry per item plus any it declines. It declares its
full reads through `deep_reads` (exempt from the B4 tripwire, per that section) and does not run
`state-patch.sh`: the stage is already `completed`, so the orchestrator owns every write, exactly
as at Step A.4.

##### Step C.0a — record, then fall through

4. Merge each answer through § Step C.5 — the whole stub, marked
   `(auto-decided)`. Only after `state-patch.sh` exits 0 may `SendMessage` relay it; never relay
   first (`skills/worktask/references/contracts/decision-authority.md § A user decision is accepted only from the ledger`). On a non-zero
   exit relay nothing (§ Error Handling). Append `auto_decision_resolved` (`subject:"<CODE><N>"`,
   `metadata: { decided, declined, model_resolved, effort_requested, effort_resolved,
   effort_transport, decisions: [{question, answer, rationale}] }`). `effort_requested` is the
   computed tier on every surface. `effort_resolved` is the tier the session ran at under
   `agent-param` and `dispatch-flag` (from hook rows), and `"requested, not applied"` under
   `none`.
5. Fall through to § Step C.0 with whatever remains: every `escalate` item, everything the
   delegate declined, and everything C.0a's four conditions excluded.

###### Step C.0a — reading the two effort fields

The comparison applies under `effort_transport` `agent-param` and `dispatch-flag`. There,
`effort_requested` != `effort_resolved` means the tier evaporated in transit — a managed or user
`maxEffortLevel` below the requested tier runs the session at the cap with no error
(`model-selection.md § Effort frontmatter and caps`). Recorded, not enforced: the answer
stands, it just was not reached at the tier asked for. Under
`none` the request never left the orchestrator, so `effort_resolved` reads
`"requested, not applied"` and the pair says nothing about the session.

##### Step C.0a stamps no approval carrier

As at Step A.4: resolving an item settles implementation content and approves nothing. Nothing
here writes an approval carrier, and both gates keep their firing conditions.

#### Step C.0 — blocking items, at their own boundary

After any stage `<CODE><N>` completes, read the items it just wrote whose `blocks_next_stage` is
true and whose `status` is not `"resolved"` — after § Step C.0a has had its pass, so on the nine
non-exception stages this set is what a resolver could not or must not settle. If none, Step C.0 is
a no-op and the loop proceeds unchanged. Otherwise run C.2 through C.5 on exactly those items, with
`subject:"<CODE><N>"` on every audit row, and only then dispatch the next stage, which would
otherwise build on a guess.

##### Step C.0 — no new gate, and no deadlock

This creates no new gate: it is the same render the FN gate performs, moved earlier for items
whose answers the next stage needs. Under a bypassed gate it follows § Step C.5 — the unattended
lanes, and nothing deadlocks: a lane with nobody to answer parks or records, and every other lane
has a user to stop for.

#### Boundary permission prompt — after Step C.0, not a sweep item

A task parked with `blocked_on.kind == "permission"` (`skills/worktask/references/completion-merge.md § Step 6.5a4`) has
no `class` and never enters `facts.open_questions[]`, so neither C.0a nor C.0 sees it. Once C.0 has
run and every ready stage is dispatched, `permission-park.sh batch` renders every parked need — one
AskUserQuestion call per `payloads[]` entry, so a single call for up to four needs — each offering
"grant and continue" and "run it yourself". The `! <command>` line to enter sits in the question
text inside a fenced block. A need with `truncated: true` gets no such line; its question points the
user at Claude Code's denial notice or `/permissions` recent denials. It never merges into a C.0
render. Answer handling, including the wait for the user's own run, and the step-only resume:
`skills/worktask/references/retry-routing.md § Step 7a`.

##### Boundary permission prompt — only the user answers

Granting is security posture, so no delegate answers a parked need under any `decision_gate`, and a
bypassed `plan_gate` or `fn_gate` does not silence the prompt. A `/megatask` per-issue run has no
user: `batch` asks nothing and parks the issue through § Escalation guard — unattended `/megatask`
per-issue runs (PARK), with `execution.reason: "parked_escalation"` and one `escalation_parked` row
whose `metadata.escalated[]` holds each need's redacted `{tool, command_head, truncated}`; the full
command stays in `blocked_on`. Nothing is granted. When `park.workspace_written` is false,
`park.workspace_reason` decides: on `missing` or `malformed` the orchestrator makes that guard's
write itself before it stops; any other reason is reported per
`skills/worktask/references/step-7a-arms.md § Step 7a — the megatask arm`. The orchestrator
never Writes or Edits a symlinked `workspace.json`: it refuses, audits and reports instead.

##### Boundary permission prompt — where the `!` line runs

A `!` line runs in the main session's working directory, not in the parked stage's tree. The
question therefore shows that tree as a `cwd:` data line inside its fenced info block, and the user
runs the `! <command>` line from that directory. No `cd <dir> && <command>` is ever composed: the
`!` line holds the denied command only (`skills/worktask/references/step-7a-arms.md § Step 7a — where the ! line runs`).

##### Boundary permission prompt — typed needs in the same round

A task parked on any other `blocked_on` kind (`skills/worktask/references/completion-merge.md § Step 6.5a3`) is rendered
at the same boundary by `blocked-on-dispatch.sh batch`, as a `user_action` need: a fixed lead line
with the stage's detail fenced as data, a `!` line only on a native `user_action` whose command was
not cut, and the options "done" and "stop here". A `user_decision` is the exception: it is asked
with the stage's own question and options, and the stage is resumed with the hook row's `ud-` id.
Its `payloads[]` are asked in the same round as the permission ones, only the user answers them
under any gate setting, and a `/megatask` per-issue run parks them the same way. Answers and
resume: `skills/worktask/references/step-7a-arms.md § Step 7a — the typed-need answers`.


#### Step C.1 — collect everything not already answered

At FN, the orchestrator uses the shared collection below over every unresolved item, regardless of originating stage.
C.0a/C.0 instead select the just-completed task's blocking items; A.4/A.5 select PL's unresolved `sw-PL<N>-*` items.
Completed boundary answers remain resolved and are excluded everywhere.

##### Shared question processing sequence

| Order | Orchestrator action | Failure / completion |
|---|---|---|
| Collect | Union ledger and current-run question spill by id; ledger wins. Keep unresolved items. | Missing spill is empty; unreadable or malformed spill fails. |
| Expand | Resolve each `ref` to question, options, recommendation, and rationale. | Do not invent missing content; apply the handoff failure path. |
| Classify | Run C.2's raise-only join before any delegate. | Escalate items never reach an auto-decider. |
| Answer | Apply the caller's delegate/filter, then C.4/C.5. | Persist the whole stub before relaying; write failure relays nothing. |
| Approve | Return to the caller's separate gate, if present. | Sweep answers write no approval carrier. |

<a id="step-c1--the-decisions-spill-is-a-different-reader"></a>
<a id="step-c1--how-the-two-sources-are-unioned"></a>
##### Step C.1 — the collection is ledger ∪ spill

`state-patch.sh` retains four questions per task; include `.context/open-questions-<run_index>.jsonl` to recover evictions.
Derive grouping from `sw-<TASK_ID>-<n>`; an explicit `stage` wins when present, but is optional.
The harness validates the same union.
This gate never reads the decisions spill. Decision consumers use
`state-patch.sh --read-decisions` for `facts.decisions[] ∪ .context/decisions-<run_index>.jsonl`, with the same conflict rule.
Reading the ring alone loses decisions after eight per task.

##### Step C.1 — the artifact fallback and its warning

Compare the collected count with frontmatter sweep stubs on `.context/*-N.md` artifacts; never reparse bodies to count.
On a shortfall, render the collected set and warn with the counts and missing ids; do not block or expand the set:

```
warn: FN gate collected 9 sweep items; 11 stubs exist on disk (missing: sw-DV1-2, sw-DR0-1)
```

#### Step C.2 — classify before anything answers

For every selected item, join both `class` and `blocks_next_stage` with the orchestrator's labels through
[raise-only self-labels](plan-transition.md#escalation-guard--raise-only-self-labels), strictly before C.3 or C.0a.
Classification compares labellers, never an author's artifact and ledger copies.
C.5 writes raised values to both copies; divergence fails harness parity.

#### Step C stamps no approval carrier

The shared sequence resolves content only. Return to the caller's separate approve/reject call unchanged.
