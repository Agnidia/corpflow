# Decision resolution
Read when executing or checking decision resolution.

Read these sections only when this procedure cites them.
###### Section lookup 1
[Error Handling](workflow-completion.md#error-handling)
<!-- canonical-body:start -->
###### Step B.1 — the routing table

| `fail:` line names | What the stage owes |
|---|---|
| a `sw-` id | the missing stub, its `ref` anchor, or its `--facts` entry |
| `sweep ledger parity cannot be verified` | a readable ledger or spill, then re-run |
| a decision id `disagrees across transports` | one reconciled statement — see the arm below |
| `missing required field: <field>` | that field, per `stage-contracts.md#tpl-<CODE>` |
| `is a scalar` / `is a map, not a list` | `tests_executed` rewritten as one `{runner, count, summary_line}` entry per runner |
| `tests_executed[` | that entry, fixed as the line says — never folded into another |
| `with no test_suite_compiles` | the compile answer — no test authority needed |
| `N discretionary tokens > 200 budget` | a shorter `summary` / `next_stage_focus` |
| anything else | what the line says — route it here regardless |

##### Step B.1 — the `key_decisions` divergence arm

Not every failure names a `sw-` id. `check_decision_divergence` compares each `key_decisions[]`
summary against the same id's entry in the artifact body and fails with

```
fail: decision <id> disagrees across transports — frontmatter says "…" but the <artifact> body says "…"
```

which names a decision id, not a sweep id or ledger parity. It routes like any other line; what
differs is the fix the stage owes.

###### Step B.1 — routing the divergence failure

The stage reconciles the two transports to one statement; the artifact body is the author's copy.
Never settle it by deleting the body entry: that removes the reader's only expansion of the id.

The harness collects every failure it can reach in one invocation, so a single re-dispatch may carry
a sweep line and a decision line together. Pass every `fail:` line, not the first.

###### Step B.1 — shape failures short-circuit

"Every failure" is bounded by what stays parseable. A non-sequence `open_questions`, a missing
`handoff:` block and an unknown stage each stop the checks at that point, because every later check
reads the structure the failed one was validating. A re-dispatch that fixes a shape line can
therefore return failures that were present but unreachable: the check working, not a regression.
Do not promise one-shot batching when the first line is a shape line.

##### Step B.1 — the consult divergence warn (AR only)

On an AR artifact the harness also runs `check_consult_divergence`. It fires when a consult line
cites a `key_decisions` id and conflicts with that decision. The consult lines are the artifact's
`## <Platform> App Architecture` sections and each `*-architecture.md` beside it. On stderr:

```
warn: consult <source>:<lineno> restates decision <id> with different content (<reason>) — key_decisions says "…" but the consult says "…". Reconcile it in <artifact> or raise an AR sweep item
```

The warn never blocks. It does not change the exit status, and `--strict` does not promote it.

###### Step B.1 — carrying the consult warn

For each warn line, append `{"action":"consult_divergence","subject":"AR<N>","result":"warn"}`
with the line as `reason`. Carry the line verbatim into the DV and DR dispatch prompts, with the
rule that `key_decisions` prevail. A consult line that cites no id is not compared; AR's
reconcile step covers it (`agents/software-architector.md § Delegation Flow`).

### Step C — Closing-sweep collection and render (loop step 4.9)

Step C is to the FN gate what Step A.4 is to the plan gate: it resolves questions, it approves
nothing, and every path out of it falls through to the gate's own approve/reject call. Contract:
`skills/worktask/references/contracts/sweep-boundaries.md § Closing Elicitation Sweep`.

It fires at two points, selected per item by `blocks_next_stage`, never by stage:

- **C.0a** runs first at every stage boundary except PL/FN/ST/IR, resolving that stage's
  blocking `decision` items through a sub-agent so the run does not stop for them at all.
- **C.0** runs at every stage boundary, immediately after that stage's `completed` patch and
  before the next stage is dispatched, over whatever blocking items C.0a did not settle.
- **C.1–C.5** run once, immediately before the FN `Agent()` delegation, over everything else.

#### Step C.0a — resolve blocking items instead of asking (loop step 4.9, first)

Contract: `skills/worktask/references/contracts/sweep-boundaries.md § Blocking items are resolved, not asked`.

After any stage `<CODE><N>` completes, and before § Step C.0, collect the items it just wrote
that satisfy all four:

1. `<CODE>` ∉ {PL, FN, ST, IR} — the four exception stages keep their own surfacing
   (`skills/worktask/references/contracts/sweep-obligations.md § Exceptions — PL, FN, ST, IR`), so there is nothing here to unblock.
2. `blocks_next_stage` is true and `status` is not `"resolved"`.
3. `effective_class == "decision"` **after** the § Step C.2 raise-only join. Run C.2 first, on
   this set, exactly as C.1–C.5 does — an item the orchestrator raises to `escalate` must never
   reach a delegate.
4. `decision_gate == "auto"`.

Empty set ⇒ no-op, fall through to § Step C.0 unchanged.

##### Step C.0a — the resolver dispatch

1. Compute the tier. Read `tasks.<CODE><N>.metadata.effort` and `.model` — the ledger, never the
   agent's frontmatter, because a stage dispatched at an override runs at a tier its frontmatter
   never mentions. Run
   `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/effort-ladder-cli.sh for-resolver "<effort>" "<model>"`;
   it bumps one rung and clamps to the model.
   A stage row with no `metadata.effort` is a contract violation: fall through to § Step C.0 and
   audit `resolver_skipped` with `reason: "effort_unstamped"`; never guess a tier.
2. Append `auto_decision_dispatched` (`subject:"<CODE><N>"`, `metadata: { questions: <count>,
   effort_requested: <tier>, effort_clamped: <bool> }`). `effort_clamped`: step 1's
   output differs from `plus-one "<effort>"`.
3. Dispatch the emitting stage's own agent on its own model at the computed tier: one dispatch per
   boundary over the whole set (≤4 by the per-stage cap), never one per item.

##### Step C.0a — how the tier reaches the stage agent

The `Agent` tool takes an `effort` parameter, so the computed tier reaches an
in-process stage agent directly. `skills/worktask/scripts/effort-route.sh` still decides the
surface: in-process with `Agent({ effort })` by default; headless through
`skills/worktask/scripts/headless-dispatch.sh` only when the operator sets
`CORPFLOW_HEADLESS_ROUTE=on`. Both carriers outrank the agent's own `effort:` frontmatter.
The audit row's `effort_transport` names the surface:

###### Effort transport surfaces

| Surface | Carries the tier by | `effort_transport` |
|---|---|---|
| in-process (the default, and the fallback after a headless `warn`) | the `Agent` tool's `effort` parameter | `agent-param` |
| headless `claude -p --agent` (opt-in) | the `--effort <tier>` flag | `dispatch-flag` |
| in-process with no stamped tier | the agent's own frontmatter; the call passes no `effort` | `frontmatter` |
| in-process on haiku, which ignores effort | nothing — the call passes no `effort` | `none` |

###### Audit every dispatch surface

This same call happens at every stage-dispatch surface, not only here: the main loop's own
Step 6 `Agent()` dispatch, a headless-eligible DV row's fan-out dispatch, and Step C.3's batch
resolver all call `effort-route.sh` before choosing a surface, passing the full task metadata
as `--dispatch-controls`. Configured compaction or retry controls require the headless opt-in;
a refused route or fallback escalates before an in-process launch. Each call writes its own
`effort_route` audit row (`action: "effort_route"`) carrying the route line's fields plus
`effort_resolved`/`effort_resolved_reason`, `session_id`, `argv[]` and the cost/usage fields —
this section is not a special case, it is the one place the shared contract is spelled out.

###### Observe the applied tier

Only `none` records the unapplied literal: the row's `effort_resolved` is
`"requested, not applied"`, never a tier the session did not run at. Under `agent-param`, the
tier comes from the stage subagent's own `hook:audit-subagent` or `agent-stop` row
(`metadata.effort`, hook-reported). A managed `maxEffortLevel` can still cap the parameter, so
the hook row decides, not the request.
Under `dispatch-flag`, the tier is read from the child's own hook rows, which its hooks write live
into the ledger root's `audit.jsonl` (per `--ledger-root`). `headless-dispatch.sh` looks them up
itself once the child exits, matching on `metadata.dedupe_key` prefix `"<session_id>:"`. On
either surface, a row whose `metadata.effort` is `"unknown"` counts as no row, and no row leaves
`effort_resolved` `null` with `effort_resolved_reason: "no_hook_rows"`, never a value copied
from the request.

##### Step C.0a — after a headless child exits

A `warn` result (`cli_missing`, `cli_below_floor`, `exit_before_artifact`, `auth_failed` or
`agent_unresolved`) never reaches this step at all: the stage ran no headless work, so the
orchestrator dispatches it in-process via `Agent({ effort })` at the same tier and
skips the replay below entirely — there is no `SubagentStop` chain for a stage that never ran
headless. A refused value (exit 2 — a usage error or a validation refusal, e.g. a workspace path
that is not a worktree this ledger pins) is not a `warn` either: it prints no result line at all,
so it is checked for by exit code alone, before any
`result` field is read, and escalates rather than being recorded as a launch a replay would then
run against a child that never started. Everything that follows applies only to a `result:"ok"`
(or `result:"error"` handled above at the spawn) return.

###### Register and replay the child

A `headless` route does not end at the spawn: once `headless-dispatch.sh` returns, the
orchestrator calls `skills/worktask/scripts/headless-poststop.sh` to replay the installed
`plugin.json`'s `SubagentStop` hooks (state-merge, the DV gates, megatask-monitor, and the
PL/FN/ST `agent-stop` matchers) against a synthesized payload, because a `claude -p --agent`
main session never fires `SubagentStop` on itself. Pass `--ledger-root` for the orchestrator
ledger and `--workspace` for the child worktree. Before replaying any hook, the helper upserts
the child-to-task mapping with `state-patch.sh --dispatch`; registration failure exits 2 and
escalates. This keeps retries bound to the same task even after state-merge completes its row.

###### Resume a blocked child

`blocked:true` in the reply resumes the
child with `claude -p --resume <uuid>` (same argv and env, the block reason plus
`additionalContext` on stdin, `--attempt` incremented) — up to the cap of 2 resumes
(`--attempt` 1, 2, 3). The resume argv carries `--resume <uuid>` alone, never paired with
`--session-id`: the CLI refuses that combination unless `--fork-session` is also passed, and
this is a true resume of the same child, never a fork. Still blocked at `--attempt 3`
(`escalate:true`) hands the stage to § Error Handling exactly as an in-process blocked return
would, never a fourth replay. A resume that itself comes back `warn` or refused (exit 2)
escalates too — ADR-2's no-in-process-fallback rule applies to the resume round-trip exactly as
it does to the first attempt, since side effects already exist either way.

###### Step C.0a — do not reach the tier another way

Never substitute a different agent believed to run at a higher tier: that trades the domain
expertise answering the question for a guess. Pass the tier on `Agent({ effort })`,
never through prompt text: a tier asked for in prose is not applied.
