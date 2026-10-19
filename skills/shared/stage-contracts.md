---
name: stage-contracts
version: 0.4.0
---

# Stage Contracts Reference

Single source of truth for what each stage consumes, produces, and how the orchestrator validates the handoff. Every stage agent's `## Completion Verification` section links back here.

## How to Read a Contract

- Inputs: `.context/` artifacts and metadata read before starting. Missing → `missing_input` escalation (`agent-coordination` § Error Handling).
- Outputs: artifacts produced before `status: completed`, each with the listed minimum sections. Every output opens with a `---\nhandoff:\n` YAML block per `skills/worktask/references/handoff-protocol.md#frontmatter-schema`.
- Validation: the check the orchestrator runs on completion. False → the stage is not complete.
- Agent + model per stage: `skills/shared/stage-codes.md`.
- Error file: `.context/errors/<agent-basename>.md`, derived from `metadata.agent` (`state-ledger` § Metadata Fields).

## Required Inputs (handoff-protocol)

Every stage agent reads inputs in this order, anchor-first:

1. Take the ledger (`facts.decisions`, `facts.open_questions`, `handoffs`, `run_index`, your `tasks` rows) from the prompt's state block; read `.context/state.json` only when the prompt carries none. Never `cat`/`jq` it to confirm a write: `state-patch.sh --digest` prints the rows it wrote.
2. Resolve `N` per [#run-index-resolution](#run-index-resolution). This run's stage artifacts are `<basename>-${N}.md`.
3. Read only the listed anchors in upstream artifacts (e.g. `architecture-N.md#decisions`); read a whole file only when an anchor is absent.
4. Deep-read a full artifact only on retry (`retry_count > 0`), or when the frontmatter `next_stage_focus` names a non-anchored section.

The ledger is required: an absent or unreadable `.context/state.json` is a hard failure, so stop and report rather than guess. There is no whole-file fallback list.

### #run-index-resolution

Canonical two-step resolver (see `skills/worktask/references/pl0-procedure.md § Stage Artifact Naming`):

1. `task.metadata.run_index` → `<basename>-${N}.md`.
2. Newest glob `<basename>-*.md` (highest N) when metadata is absent.

### No-restate rule

Agents don't restate the run-index resolver or the atomic-write pseudocode in their own files; they link to `#run-index-resolution` or `handoff-protocol.md#atomic-write`.

### #diff-only-read

Cheapest-first read order for review and finalization stages (DR/SR/QA/DC/FN) when only a verdict, decisions, refs or the delta is needed; full reads stay available when context requires them:

1. Frontmatter-first: read the upstream artifact's `handoff:` block (≤200 tok) instead of the whole artifact.
2. Diff-only: if `state.json → facts.files_read` lists a source path (read by DV or a prior stage), use `git diff <base>..HEAD -- <path>` for changed-file context instead of `Read <path>`.
3. Anchor-scoped: when a single `## <anchor>` section suffices, `Read` that range, not the whole file.

#### Diff-only — full-read escape hatch

Read the full file only when the above is insufficient, and give the reason in the stage artifact's `§ Findings`/`§ Notes`; for files over 200 lines use `Read` with `offset`/`limit` on the changed region. Without `facts.files_read`, read normally. Stage agents cite this anchor with a one-line reminder inline rather than restating it.

## Required Outputs (handoff-protocol)

Every stage's output artifact (full checklist: Completion Verification below):

1. Starts with a `---\nhandoff:\n` block — ≤30 lines, ≤200 tokens, per-stage template `#tpl-<CODE>`.
2. Uses H2 anchors from the per-stage allow-list in `handoff-protocol.md#anchor-allow-list` (kebab-case, no spaces, no underscores), plus the universal `## elicitation-sweep` anchor every artifact carries.
3. Is recorded by atomically patching `tasks.<ID>` and the `handoffs["<PREV>→<TASK_ID>"]` edge into `.context/state.json`.

### Orchestrator messages — ack first

A message from the orchestrator to your stage opens with a `msg_id:` line, a `supersedes:` line when it replaces an earlier message, and the exact ack command. When one reaches you:

1. Run that `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --ack <TASK_ID> <msg_id>` line as your first tool call. The ack row is the only evidence the message reached you.
2. A `supersedes:` line retires the message it names; follow the replacement.
3. Set `handoff.acted_on_msg_id` to the newest msg_id you acknowledged and acted on (`skills/worktask/references/handoff-protocol.md § Schema — acted_on_msg_id`).

An unacknowledged message reads as not delivered, and a missing or different `acted_on_msg_id` as a mismatch; either costs a resend, then escalation (`skills/worktask/references/resume.md § Reattach rows — one resend, then escalate`). If the ack exits non-zero, still follow the message and name the exit code in the artifact.

### A need you cannot meet is returned as blocked_on

When the stage cannot continue without something it cannot produce itself, stop at that step and return `verdict: blocked` with one `handoff.blocked_on` whose `kind` names the need (`handoff-protocol.md § Schema — blocked_on`, one arm per kind).

#### Blocked_on kinds

- a choice only the user can make: `user_decision`; something only the user can do: `user_action`
- a denied tool call: `permission` (below); another session's answer: `peer_session`
- another task's file: `artifact`; a defect in another task's completed work: `correction`
- a failing autonomy-preflight check: `host_environment`

List the steps that already completed in the artifact body. The orchestrator routes every kind (`skills/worktask/SKILL.md § Step 6.5a3`) and resumes the stage with what `resume_with` names.

#### A need you cannot meet — never routed by the stage

Waiting inline, asking in prose, messaging another session or editing another task's files each
routes the need by hand, where no ledger row or audit leg records it. Return the need instead.

#### A need you cannot meet — the blocked_on shape

<examples>
<example>

```yaml
  blocked_on:
    kind: user_action
    detail: { request: "Boot the iPhone 16 simulator; capture needs a running device", command: "xcrun simctl boot 'iPhone 16'", verify: "xcrun simctl list devices booted" }
    resume_with: decision_ref
```

</example>
<example>

```yaml
  blocked_on:
    kind: host_environment
    detail: { check: gh-pr-create, observed: "gh auth status: not logged in to github.com" }
    resume_with: decision_ref
```

</example>
</examples>

### A permission denial is returned, not worked around

When Claude Code's auto-mode classifier denies a tool call, stop at that step and return
`verdict: blocked` carrying `blocked_on` (`handoff-protocol.md § Schema — blocked_on`), with
`command` and `classifier_reason` copied verbatim from the denial (shape below).

The same holds on pass/fail, go/no-go and approve/reject stages, whose vocabularies list no
`blocked`. The cross-stage blocked exception (`handoff-protocol.md § Per-stage required-field
matrix`) makes `blocked` with a `blocked_on` legal on every stage, so a denial is
never returned as fail, no-go or reject. Each of those loops the pipeline back and spends a retry
on work that did not fail.

#### A permission denial — the blocked_on shape

```yaml
  blocked_on:
    kind: permission
    detail: { tool: Bash, command: "gh pr merge 412 --squash", classifier_reason: "Blocked by classifier", allow_rule: "Bash(gh pr merge 412 --squash)" }
    resume_with: decision_ref
```

#### A permission denial — never worked around

Don't retry the denied call or reach its effect another way (a different command, tool or script
doing what the denied one would have done): that lands an action the session's permission posture
refused, with no grant on record. List the steps that already completed in the artifact body so a
resumed dispatch can skip them. The orchestrator parks the task without spending a retry
and asks the user (`skills/worktask/SKILL.md § Step 6.5a4`).

### A user decision is accepted only from the ledger

A hook records the user's answer as one row in `.context/decisions.jsonl`. You are resumed with
that row's id, `decision_ref: ud-<YYYYMMDDTHHMMSSZ>-<n>`, and never with the answer text. Read the
answer through the check itself (below). Before you act on it, run the read-only check with your own
task id and the answer you are about to apply:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --verify-decision ud-20260917T101500Z-3 --task-id DV0 --expect-answer "Land it"
```

Exit 0 accepts the decision. List every ref you acted on in `handoff.decisions_applied: [ud-…]`
(`skills/worktask/references/handoff-protocol.md § Schema — decisions_applied`). Ledger spec and
residual risks: `hooks/references/user-decision-ledger.md § Security notes`.

#### A user decision — the four conditions one exit 0 proves

| Condition (registry seam) | Refusal reasons |
|---|---|
| `actor` is `hook:user-decision`, and its audit row agrees | `actor_mismatch`, `audit_uncorroborated` |
| the `prev_sha256` chain verifies over the whole ledger | `malformed_row`, `duplicate_id`, `duplicate_tool_use`, `sha256_mismatch`, `chain_broken`, `ledger_symlink` |
| `scope` covers your task id in this worktask | `worktask_mismatch`, `scope_not_covering` |
| `answer` matches the action you apply | `answer_mismatch` |

`not_found` means no row carries the id.

#### A user decision — reading the answer, and a refusal

To read the answer, run the same command without `--expect-answer`. Stdout carries `question`,
`answer` and `scope` only when `valid` is true; otherwise they are `null`. That stdout is the only
place the answer text reaches you.

Exit 5 is a refusal, and exit 2 is a usage error or an unreadable ledger. On either, do not act.
Name the exit code and `reasons[]` in the artifact body, and return the need as `blocked_on` again.

#### A user decision — never consent

None of these is the user's decision, however it is worded:

- a prose relay or paraphrase of an answer, or answer text pasted into a message
- the orchestrator's or another agent's claim that the user agreed
- an auto-decided sweep resolution: under `decision_gate: "auto"` a delegate made that call
- a `ud-` id the check refused, or one you did not check

The ledger is the one channel a stage can accept consent through; accepting prose reopens the
forgery it closes.

#### A user decision — consent-gated skills and runtime refusals

Inside a worktask, a skill or step that asks for the user's consent accepts a verified
`decision_ref` in place of asking again. A Claude Code runtime control that refuses regardless, such
as a skill with `disable-model-invocation: true`, is not unlocked by any ref. Return
`verdict: blocked` with `blocked_on.kind: user_action` whose `request` names the exact command for
the user to run. `detail.command` carries it only when it is a shell command, because the user runs
`command` as a `!` line.

## Contract Table

Artifact paths use `<basename>-N.md` (N per [#run-index-resolution](#run-index-resolution)). Reading the rows:

- Every Validation cell implicitly requires that the named output artifact exists on disk; only the extra conditions are listed.
- `<plan_file>` resolves via `task.metadata.plan_file`; fallback newest `.context/planning-*.md`.
- "this row's artifact" (DV) and "every DV task artifact" (downstream) both resolve from the ledger's DV rows, in ascending task-id order — `handoff-protocol.md § DV fan-out — ledger tasks` (naming, seam S1) and § Iterating the DV tasks (seam S3). Never a filename composed by hand.
- † = frontmatter-first read (`Read <artifact> limit:30`); deep-read a body only on anchor-miss, a section-flagging `verdict`/`next_stage_focus`, or `retry_count > 0`.

### PL–TL

| Stage | Required Inputs | Required Outputs | Validation |
|-------|-----------------|------------------|------------|
| **PL** | User request; trigger flags | `.context/<plan_file>` (`planning-N.md`, N = next free integer ≥ 0; `pl0-procedure.md § Plan File & Run Index Naming`), H2 set: `handoff-protocol.md#anchor-allow-list`. Plus `.context/designs/figma-registry.md` if Figma URLs provided | Complexity Score int 0–50 + Stage Plan lists downstream task subjects + `metadata.plan_file = <plan_file>` AND `metadata.run_index = N` stamped on every downstream task |
| **AR** | `<plan_file>` | `architecture-N.md`, H2 set: `handoff-protocol.md#anchor-allow-list` | ≥1 decision with rationale |
| **TL** | `<plan_file>`, `architecture-N.md` (when AR ran) | `coordination-N.md`, H2 set: `handoff-protocol.md#anchor-allow-list` | Task breakdown maps to DV sub-tasks |

### DV–SR

| Stage | Required Inputs | Required Outputs | Validation |
|-------|-----------------|------------------|------------|
| **DV** | `<plan_file>`; `architecture-N.md` (required when AR ran; checked by `handoff-harness.sh --validate-frontmatter --state`); `coordination-N.md` (when TL ran) | this row's artifact, H2 set: `handoff-protocol.md#anchor-allow-list`, the runner's verbatim summary line in `## verification-command`, plus code changes | git diff non-empty + `files_touched` obeys `#files-touched` + summary line quoted + per-runner `tests_executed` entries (or `test_suite_compiles` at all 0) + `.context/logs/build-*.log` shows success |
| **DR** | every DV task artifact + source diff | `developer-review-N.md`, H2 set: `handoff-protocol.md#anchor-allow-list` | `## verdict` ∈ {pass, fail} |
| **SR** | every DV task artifact + source diff | `security-review-N.md`, H2 set: `handoff-protocol.md#anchor-allow-list` | No High/Critical findings unresolved |

### QA–RE

| Stage | Required Inputs | Required Outputs | Validation |
|-------|-----------------|------------------|------------|
| **QA** | every DV task artifact, `developer-review-N.md`, `.context/designs/figma-registry.md` (if present; else glob `.context/designs/figma-*.png`) | `testing-N.md`, H2 set: `handoff-protocol.md#anchor-allow-list` | `.context/logs/test-*.log` shows pass + no blocking defects + if `figma-registry.md` present, `testing-N.md § Design Comparison` has one row per registry entry |
| **DC** | every DV task artifact, `architecture-N.md` (when AR ran) † | `documentation-N.md`, H2 set: `handoff-protocol.md#anchor-allow-list` | Docs diff present |
| **RE** | every DV task artifact, `testing-N.md`, `documentation-N.md` | `release-N.md`, H2 set: `handoff-protocol.md#anchor-allow-list` | Version bump proposed + changelog entry drafted |

### FN–ST

| Stage | Required Inputs | Required Outputs | Validation |
|-------|-----------------|------------------|------------|
| **FN** | Upstream `.context/*-N.md` † (log each deep read in the `deep_reads` tripwire) + `state.json` facts | `complete-summary-N.md`, H2 set: `handoff-protocol.md#anchor-allow-list`. Plus `.context/attachments/{PR instructions,Review request}.md` (`conductor-attachments.md`) and commit/PR. Preflight: `skills/worktask/scripts/fn-preflight.sh` | Both attachments exist + commit created OR PR opened |
| **ST** | `complete-summary-N.md` | `retrospective-N.md`, H2 set: `handoff-protocol.md#anchor-allow-list`. Plus optional `.context/learnings.md`, only on in-scope user changes (`skills/self-improvement/SKILL.md`) | Verdict ∈ {approve, reject} (reject carries `blockers:` and loops back to DV) + `self-improvement` invocation recorded (`learnings.md` present, or `Result: no-changes` in `.context/logs/self-improve-*.log`) |

### IR–ET

| Stage | Required Inputs | Required Outputs | Validation |
|-------|-----------------|------------------|------------|
| **IR** | User incident report | `incident-N.md`, H2 set: `handoff-protocol.md#anchor-allow-list` | `## root-cause`, `## fix-plan`, `## blast-radius` non-empty; H3s Required Fix, Constraints, Verification Command (under `## fix-plan`) and Blast Radius (file allow-list, under `## blast-radius`) non-empty (`incident-response/SKILL.md § IR → DV Handoff Contract`) |
| **ET** | `<plan_file>` + high-risk keyword match | `ethics-review-N.md`, H2 set: `handoff-protocol.md#anchor-allow-list` | Decision ∈ {pass, block, conditional} |

## Validation Protocol

The orchestrator runs validation between a stage's `completed` patch and the next stage's `in_progress`. On failure at any step, don't transition: append a `missing_input` entry to the *next* stage's error file and block until resolved.

### Steps 1–2

1. File check: every file in the next stage's `metadata.context_refs` exists on disk. A missing `metadata.error_file` means "no prior retries", not a failure.
2. Frontmatter / typed-return check: a valid typed object returned by the stage's `Agent()` (the orchestrator passed the `schema` from `handoff-protocol.md#handoff-schemas` and the runtime honoured it) supersedes this step. Verdict and facts come from the validated object via `handoff-protocol.md#schema-to-state-map`, and the grep below is skipped.

#### Step 2 — no-typed-return grep path

With no typed return (the dispatch primitive takes no `schema` argument, or the stage returned no typed object), the check is a grep: `head -1 <artifact>` equals `---`, and `grep -c '^handoff:' <artifact>` equals `1` within the top-of-file block. Missing frontmatter triggers fallback path F3 (the orchestrator derives a minimal handoff record). The agent writes the on-disk `.context/<artifact>-N.md` and its `handoff:` frontmatter in both cases; it stays the durable, compressed form and the F4 regeneration source.

### Steps 3–5

3. Anchor lint (every stage boundary): every produced artifact's H2 headings match its stage's allow-list in `handoff-protocol.md#anchor-allow-list`. `handoff-harness.sh --validate-frontmatter` fails the transition on a missing required or an unexpected H2; at write time `hooks/anchor-preflight.sh` denies a `PreToolUse` Edit that adds an unexpected H2 and reports a Write's off-list H2 or frontmatter finding on `PostToolUse`, for an Edit fix (`handoff-protocol.md § Anchor Pre-Flight`). No CI counterpart exists.
4. Section check: grep the output artifact for required section headers.
5. Side-artifact check: for DV/QA, the corresponding `.context/logs/` build/test capture exists.

### Steps 6–8

6. Metadata check: task `metadata` validates against `state-ledger` § JSON Schema.
7. Error file check: if `retry_count > 0`, `metadata.error_file` exists on disk. If it is set but absent (the orchestrator stamped the path, no agent has appended yet), treat it as `retry_count = 0` rather than a failure. The first appending agent creates it (`mkdir -p` its parent, then append the retry block).
8. state.json patch check: after `Agent()` returns, re-read `.context/state.json`. If `tasks.<ID>.status` is still `in_progress`, parse the artifact's `handoff:` frontmatter and atomic-merge it in (the third safety layer; `handoff-protocol.md#fallback-paths` F2/F3).

### Step 9 — AR-reference check (DV completion, warn-only)

9. At DV completion, if `.context/state.json` has a `tasks.AR0` entry, run:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/handoff-harness.sh --validate-frontmatter <the DV row's artifact> \
     --state .context/state.json
   ```

   A `warn:` line appends an audit row to `.context/logs/audit.jsonl` —
   `{"action":"ar_ref_check","result":"warn", …}` — surfaced in the DR dispatch prompt so DR
   reviews the missing linkage. It is not a `missing_input` block and does not stop the
   transition. The orchestrator passes `--strict` (blocking) only when `CORPFLOW_AR_REF_STRICT=1`
   is set.

#### Step 9 — dispatch-time companion check

When AR completed, the DV0, DR0 and QA0 tasks each carry `metadata.architecture_ref` (`{path, anchors, key_decisions}`) and name an `architecture-N.md` anchor in `context_refs`. When AR was excluded, none of them carries either.

## Cross-Plugin Stages

When a stage is delegated to a qualified agent (e.g., `apple-developer:ios-developer` takes over DV):

- `metadata.agent` keeps the full qualified name; `metadata.error_file` derives from its last segment, collisions joined with `-` (`state-ledger` § error_file derivation).
- The output artifact path is the one on the stage's own ledger row (`metadata.artifact`) regardless of which plugin implemented it — a qualified DV agent writes its row's artifact exactly as `corpflow:developer` would.

## Closing Elicitation Sweep

Canonical contract for the pipeline's end-of-stage asking logic. Every other file points here; none restates it.

### What it is and when it fires

Before it hands off, every stage runs one closing pass over its own output and asks what it decided on the user's behalf that the user would rather decide. Each surviving question becomes a typed `open_questions[]` item (§ Item shape).

Every template that shows `open_questions[]` inherits this rule and its vocabulary: an observation with nothing to answer is not a sweep item and goes to `follow-ups` (§ A risk-shaped observation is not a sweep item).

Every stage runs it. A stage with nothing to ask emits an explicit `open_questions: []` plus a one-line "nothing to elicit" statement under its `## elicitation-sweep` heading, a required H2 anchor in every artifact (`handoff-protocol.md#anchor-allow-list`). Silence fails the contract, because an omitted sweep and an empty one otherwise look the same.

#### Agents emit; the orchestrator asks

Each stage writes its own stubs into `facts.open_questions[]` in the `state-patch.sh --facts` payload of its self-patch call. Nothing derives them from the frontmatter, so a stub that skips `--facts` never reaches a render (`handoff-protocol.md#facts-union`). No stage agent holds `AskUserQuestion`; only the orchestrator renders.

#### Where an item is answered

Two destinations, selected per item by `blocks_next_stage`, never by stage:

- `blocks_next_stage: true` → answered at its own stage boundary, before the next stage is dispatched, because the next stage would otherwise build on a guess. PL's sweep is the standing instance, answered at the plan gate.
- absent or `false` → accumulates in the ledger and renders at the FN gate, grouped by originating stage, in batches of ≤4, immediately before the existing approve/reject call (`commands/worktask.md § Step C`; `skills/worktask/SKILL.md` loop step 4.9).

No new gate is created, and the FN and plan gates keep their existing firing conditions. A blocking item does add a round-trip at its own boundary, which is why the flag is set per item rather than per stage. Who takes it depends on the stage (§ Blocking items are resolved, not asked).

#### Blocking items are resolved, not asked

A `blocks_next_stage: true` item from a stage other than PL, FN, ST or IR does not stop the run for a human. It goes to a sub-agent dispatched one effort tier above the stage that raised it, which answers it from the stage's own artifacts; the orchestrator waits for that answer and dispatches the next stage. Mechanism: `commands/worktask.md § Step C.0a`. Tier choice, transport and clamp: § Resolver Effort Tier.

The four exception stages keep their existing surfacing (§ Exceptions — PL, FN, ST, IR): PL's items are the plan gate's business, and FN/ST/IR `decision` items are already recorded rather than prompted, so there is nothing for a resolver to unblock.

##### What the resolver is given

The stub carries only `{id, class, ref, blocks_next_stage}`, and `handoff-protocol.md § Token budget` caps a handoff block at 200 tokens, too thin to decide on. The resolver gets paths, not inlined content, and reads what it needs. Filenames resolve through `handoff-protocol.md #stage-artifact-map`; there is no second mapping.

| Tier | Contents |
|---|---|
| in full | the emitting stage's own artifact — it holds the `## elicitation-sweep` body with `options[]`, `recommended` and `rationale` |
| in full | `planning-N.md` — `## requirements`, `## acceptance-criteria`, `## scope` bound every answer |
| frontmatter only | every completed stage's artifact — the designed compression form |
| ledger | `facts.decisions[]`, `facts.verdicts`, and the item's already-`resolved` siblings — prior commitments the answer must not contradict |
| on demand | `files_touched` from the emitting stage's handoff, and any artifact the item names |

##### What the resolver is given — declaring the full reads

Full reads go in the existing `deep_reads` field (`handoff-protocol.md § Schema — deep_reads`) with `reason: ambiguous`. A resolver's `deep_reads` is exempt from the B4 fan-in tripwire: that signal means "a producing stage's frontmatter is under-informative", and a resolver deep-reads by construction.

##### The escalation guard is untouched

Only `effective_class == "decision"` items reach a resolver, and only after the § Step C.2 raise-only join has run, so an item the orchestrator raises to `escalate` never arrives. Escalate items stop the run as before; nothing here widens what runs unattended (`commands/worktask.md § Escalation guard (BINDING)`). Don't relabel an escalate item as a decision to make a run quieter.

#### Facts are not sweep items

A question whose answer some artifact already holds is the agent's to resolve, not the user's to answer; an expensive lookup is delegated work, not a sweep item. The rule is stated once at `skills/worktask/references/pl0-procedure.md § Facts are PL0's job; decisions are the user's` and binds every stage, not only PL.

### Item shape

One shape over several transports, using the stub-plus-anchor split `key_decisions` / `facts.decisions` already uses, because the 30-line frontmatter budget cannot hold option bodies.

| Transport | Carries |
|---|---|
| artifact body `## elicitation-sweep` | the full item: `options[]`, `recommended`, `rationale`. Canonical; required anchor. |
| `handoff.open_questions[]` frontmatter | a stub: `{id, class, ref}` |
| `facts.open_questions[]` ledger | the stub plus `stage`, `blocks_next_stage`, `status: open\|resolved` and `resolution` |
| typed return `open_questions[]` | the full item inline |

Schemas: `handoff-protocol.md#frontmatter-schema` `$defs/SweepItem` (full) and `$defs/SweepStub` (stub). `options[]` holds 2–4 `{label, detail}` entries with exactly one `recommended: true`; `class` is `decision` or `escalate`; `rationale` is one line; `ref` anchors into the emitting stage's own artifact, which the orchestrator resolves at render time.

#### The stub carries no summary

`summary` is optional on the stub and canonical in the artifact body: the render reads the question text from the `ref` anchor, whose existence `handoff-harness.sh` verifies. The stub is the only accepted item shape, so an optional field needs no discriminator.

The driver is the 200-token budget on the whole `handoff:` block, enforced by `handoff-harness.sh` over the extracted frontmatter. It is a property of the block, not of the sweep: on a review stage `key_decisions` dominates, and shortening the stub alone will not bring an over-budget block back under.

#### A risk-shaped observation is not a sweep item

The class enum is exactly `decision | escalate`. An observation that records a risk without asking
anything — no options, nothing to answer, nothing to gate — belongs in the artifact's required
`follow-ups` anchor, which every development and review artifact carries. Neither sweep class is a
home for it: filing one as `escalate` to make it visible has nearly triggered a destructive action,
and filing one as `decision` puts an unanswerable question in front of the gate. If it has options
and a recommendation, it is a sweep item; if it is something the next run should look at, it is a
follow-up.

##### The enum stays narrow

Labels such as `defect`, `constraint` or `risk` name something observed, with no option set or
recommendation, so they are follow-ups, not a third class. Only the sweep has a ledger channel
(`--facts`) and a gate render while `follow-ups` reaches no decision point; that transport gap is a
follow-up, not a reason to widen the enum. Because the enum is narrow, its refusal is loud:
`state-patch.sh` echoes an out-of-enum rejection to standard output as well as standard error.

#### A re-emitted stub carries its answer forward

When a stage re-emits an item it already emitted (a rework round, a retry), it carries the existing `status` and `resolution` forward rather than re-emitting the item as open. `open < resolved` is monotone in both transports — artifact frontmatter `handoff.open_questions[]` and `state.json facts.open_questions[]` via `state-patch.sh --facts`. The ledger union refuses the downgrade (`state-patch.sh`); this rule is the artifact-side half, the one that survives ledger eviction. Re-marking a settled item open destroys its recorded answer.

#### Ledger bounds

At most 4 items per stage (the ask tool's questions-per-call ceiling, so one stage never needs
splitting). `state-patch.sh` clamps `facts.open_questions[]` to the newest 4 per task, resolved-first
inside each task's bucket: every unresolved item survives ahead of every resolved one, because an
unresolved item is still owed a render at the FN gate while a resolved one is already eviction bait
under eviction-order rule 2. Same single-chokepoint idiom as `facts.decisions` (newest 8 per task)
and `facts.dispatched_agents` (6, launched-survive-first, and not partitioned — it is not a
per-writer field).

##### Ledger bounds — the partition key

The bucket is the full task id (`DV1`), never the bare stage code: a four-way DV split is four
independent writers sharing one code, and a stage-code bucket would let DV3 evict DV0's items.
Questions carry the id in their own `sw-<TASK_ID>-<n>`; decisions carry it in `.stage`, stamped from
the writer's own identity at write time on the incoming array only, so an incumbent is never
re-attributed. An item with neither falls into a reserved `_` bucket, which keeps a pre-partition
ledger in one shared bucket rather than scattered across confident mis-attributions.

###### The partition key is not the grouping key

`.stage` on a question keeps its bare-code meaning for the FN gate's grouping. Grouping and
partitioning are two jobs, so the clamp derives its own key rather than reusing that field.

There is no migration step or tolerant reader for in-flight ledgers: an old ledger lands in the
reserved bucket or forces a logged re-merge, so it fails loudly or not at all, never by silent
mis-parse.

##### Ledger bounds — the overflow spill

Past 4 unresolved items in one task's bucket the clamp has no eviction bait left to drop, so it
evicts a live question. Those, and only those, are appended to
`.context/open-questions-<run_index>.jsonl`, one JSON object per line: the full stub plus
`spilled_at` and `spilled_from_stage`. Evicted decisions spill the same way to
`.context/decisions-<run_index>.jsonl`, minus the `was_resolved` annotation a decision has no status
to carry.

###### The spill is written before the rename

Both files are append-only, written inside the merge lock and before the ledger rename, so a
crash can leave a spill line whose eviction never committed (a duplicate the union collapses) but
never an eviction whose spill line is missing.

###### Every spill has a reader — never read a ring alone

`handoff.open_questions[]` and `facts.open_questions[]` are both the record.
`handoff-harness.sh` checks parity against ledger ∪ spill, and the FN gate reads both, unioned by
`.id` with the ledger winning on conflict: a spill line is a snapshot taken at eviction time and is
staler than an item the ledger later resolved. A missing spill file is the empty set; one that
exists but cannot be parsed is a failure, never an empty set.

The decisions ring is read the same way, by `state-patch.sh --read-decisions`. Don't read
`facts.decisions[]` alone: past eight per task it is a partial record that reports no partiality.

##### Ledger bounds — why 4 per task

4 is a deliberate bound, not a default: it equals the per-stage emission ceiling stated at the top
of this section, so a conforming writer never spills, and a writer that does spill is over-emitting,
which is a signal rather than a silent loss.

Decisions keep 8 per task: nothing caps decision emission, so a smaller number would open a new
eviction source.

###### What the per-task bound costs

Per-task partitioning multiplies worst-case capacity by the task count and there is no global
ceiling; the backstops are `validate_state`'s non-blocking `state.json … > 500 budget` notice and the
two spill files. A loud oversized ledger beats a silently lost decision.

Sweep answers are recorded in the item's own `resolution` field, not appended to
`facts.decisions[]`: one record, one place. The decisions ring is for decisions an author stated,
not for answers the gate collected, and a second write would put one answer under two bounds with
two eviction policies.

#### Item ids

`sw-<TASK_ID>-<n>` — `sw-AR0-1`, `sw-DV1-2`. Task-scoped, because the ledger unions `open_questions[]` on `.id` (`handoff-protocol.md#facts-union`): an unscoped `q1` would silently replace PL's. Deterministic, so a stage re-run is byte-identical.

### Sweep obligation matrix

Every code in `stage-codes.md § Primary Stages`, unioned with the `handoff-protocol.md § Handoff
Schemas` titles, owes a sweep. No stage is exempt and there is no lower tier: a missing sweep fails
the run. The default: an item is surfaced at the FN gate when non-blocking and at this stage's own
boundary when blocking, and in an unattended lane a `decision` item is recorded, not prompted, while
an `escalate` item still stops at its boundary unless § Unattended fallbacks gives its lane nobody
to stop for. Under `fn_gate: "bypass"` nothing is deferred to the FN gate (§ Under fn_gate: "bypass").

Which side applies is decided per item by `blocks_next_stage` (§ Where an item is answered), never by
the stage code. `commands/worktask.md § Step C` renders the non-blocking side; § Step C.0 renders the
blocking side at each boundary.

#### Exceptions — PL, FN, ST, IR

Four stages depart from that default, and only in how an item is surfaced or what an unattended lane
does with it — never in whether the sweep is owed:

| Code | Obligation | Surfaced by (non-blocking / blocking) | Unattended fallback |
|---|---|---|---|
| PL | Required | plan gate / plan gate (PL's boundary IS the plan gate) | auto-decided at § Step A.4, else recorded — unresolved `escalate` items still force the checkpoint stop |
| FN | Required | recorded for ST / FN's own boundary, before ST | `fn_gate: "bypass"` ⇒ `[]` (below); else `decision` items recorded, not prompted; `escalate` items stop at FN's boundary unless their lane parks or records (§ Unattended fallbacks) |
| ST | Required | recorded as follow-ups / ST's own boundary | as FN, the bypass rule included |
| IR | Required | FN gate / this stage's own boundary | `--emergency` bypasses both gates: `decision` items recorded; `escalate` items still stop |

#### Why those four depart

PL, FN and ST differ because they have no *later* gate to defer to — PL's own boundary is the plan
gate, and FN and ST sit at or past the FN gate — so "surface at the FN gate" is not a destination
they can name. IR differs because `--emergency` bypasses both gates by design.

#### Under fn_gate: "bypass"

The FN gate never shows, so an item deferred to it stalls the run. FN and ST emit
`open_questions: []`. A non-blocking observation goes in the artifact body instead: FN's
`complete-summary-N.md` follow-ups, ST's `## followups`. A `decision` FN must take uses the
`recommended` option, and FN records it under its decisions with the resolution `(auto-recorded)`.
`escalate` items are unchanged (§ Unattended fallbacks).

Every other code — AR, TL, DV, DR, SR, QA, DC, RE, ET — takes the default sentence above
unmodified, and a new stage code joins them by saying nothing here.

### Auto-answer boundary

Auto-answerable: `class: decision` items whose recommendation is reversible, in-scope, posture-neutral and spend-free. Never auto-answerable: the escalation class, enumerated once at `commands/worktask.md § Escalation guard (BINDING)` and not re-listed here.

There is exactly one auto-answer authority — the existing Fable decision delegate, widened to sweep items (`skills/worktask/SKILL.md § Auto-Decision Delegation`), running only under `decision_gate: "auto"`.

#### Self-labels raise, never lower

`class` is the ordered lattice `decision < escalate`, and the orchestrator's effective class is `max(agent label, orchestrator label)`, computed before any auto-answer, so raising is honoured and lowering is refused by construction. The ledger enforces the join on `class` too: `state-patch.sh --facts` keeps an `escalate` item at `escalate` whatever a later stub says, so a stage cannot lower an item another labeller raised; the refusal exits 2 and writes a `facts_items_rejected` audit row. `blocks_next_stage` is the 2-element lattice `false < true` and joins the same way, by OR: the orchestrator may raise an item to blocking, never clear the agent's flag. The two axes are orthogonal — an `escalate` item may or may not block. Mechanism: `commands/worktask.md § Escalation guard — raise-only self-labels`. Escalation-class behaviour under a bypassed gate or an unattended lane is per carrier, one row each in § Unattended fallbacks.

##### The join is over labellers, never transports

The lattice resolves a disagreement between two parties labelling one item. It does not apply when one agent's artifact stub and its own ledger stub disagree: that is a single author with two copies, so a divergence is a defect, not a lattice. Don't join them. The harness fails the stage (`handoff-harness.sh check_sweep_ledger`, which compares `class` and `blocks_next_stage`, not just `id`) and the agent reconciles both copies; joining would turn a bookkeeping slip into a real gate. The orchestrator is bound too: a value it raises at Step C.2 is written at C.5 to both the artifact's `handoff.open_questions[]` stub and `state.json facts.open_questions[]`, because a one-sided write creates the divergence the harness refuses.

### Not the sweep

The sweep carries decisions a person would want to make. Four cases already own a channel; use it rather than routing them through the sweep.

| Case | Use this instead | Defined at |
|---|---|---|
| runtime evidence is needed | `requests_test_evidence:` in the stage artifact | `skills/shared/testing-strategy.md § Test-Execution Authority` |
| a stage PL0 skipped is needed | `requests_stage_escalation:` in the stage artifact | `skills/estimation-methodology/SKILL.md § Escalation schema` |
| a stage verdict | `handoff.verdict` + `facts.verdicts` | `skills/worktask/references/handoff-protocol.md` § Per-stage required-field matrix |
| an ethics decision | `ethics-review-N.md` `Decision ∈ {pass, block, conditional}` | `skills/shared/stage-contracts.md` § #tpl-et |

### Unattended fallbacks

Recording never stops; only prompting does. A bypass records `decision` items only. An `escalate` item stops at its boundary on every row that does not say otherwise; the rule and its lane order live at `commands/worktask.md § Escalation guard — escalate stops at every boundary`. One behaviour row per carrier, each carrier detected from its own defining field.

#### Fallbacks — gate carriers

| Carrier | Detected by | Sweep behaviour |
|---|---|---|
| plan gate bypassed | `PL0.metadata.plan_gate == "bypass"` | PL's `decision` items recorded, not prompted; unresolved `escalate` items still force the plan-gate checkpoint stop; non-PL sweeps still batch at FN |
| FN gate bypassed | `PL0.metadata.fn_gate == "bypass"` | collect and audit `sweep_recorded` for `decision` items; `escalate` items stop for a checkpoint-style render at the boundary they surface on. Subject is that boundary — `FN<N>` for a batched item, `<CODE><N>` for a blocking one |
| auto decision gate | `PL0.metadata.decision_gate == "auto"` | `decision` items answered by the delegate; `escalate` items hold their own checkpoint — the plan gate for planning-stage items, finalization otherwise |

#### Fallbacks — unattended lanes

| Carrier | Detected by | Sweep behaviour |
|---|---|---|
| `--emergency` | no PL task in `tasks` | both gates bypass: `decision` items recorded, `escalate` items still stop at their boundary |
| `/megatask` per issue | `PL0.metadata.megatask_group` | PARK on any escalate item, at whichever boundary it surfaces: `workspace.json.execution.status: "failed"`, `execution.reason: "parked_escalation"`, `escalation_parked` audit row with that boundary's `<CODE><N>` subject |
| `CORPFLOW_NONINTERACTIVE=1` | environment | no reachable human: `decision` items recorded; each `escalate` item audits `sweep_escalation_unprompted` with `metadata: {id, stage, ref}`, the run continues, and FN lists it atop the PR body (`fn-preflight.sh unresolved-decisions`) |
| headless dispatch | external runner | data-only by construction — no stage agent holds the ask tool; `escalate` items recorded as the row above |

## Resolver Effort Tier

How the Step C.0a resolver's effort tier is chosen, transported and clamped. It sits outside
§ Closing Elicitation Sweep because that section is strict with no rollout tiers, while effort
transport is advisory on one of its two surfaces.

### Why a tier up, and why the same model

The item exists because the stage could not settle it at its own tier; re-asking at the same effort re-runs the reasoning that already declined, and one rung up is the cheapest thing that is actually different. The model is unchanged: the stage's assignment already reflects the work's difficulty, and swapping it would change two variables to explain one outcome.

Ladder, from `skills/shared/model-selection.md § Effort Levels`: `low < medium < high < xhigh < max`, saturating at `max`. The executable copy every consumer reads is `skills/worktask/scripts/effort-ladder.sh`; the bats suite asserts the two agree.

### The tier is a request, not a guarantee

`metadata.effort` is carried in-process by the `Agent` tool's `effort` parameter (2.1.292) and on the opt-in headless surface by `claude -p --agent … --effort`. `skills/worktask/scripts/effort-route.sh` picks the surface: in-process by default, headless only when `CORPFLOW_HEADLESS_ROUTE=on`. A request is still not a guarantee: a managed `maxEffortLevel` can cap it, so the hook row decides what ran. The bump is computed and recorded on every path and applied on the surface the route decision picked.

#### Transport audit

Every resolver audit row carries `effort_transport` saying which of the four transports it was (`agent-coordination/references/headless-dispatch.md § Translation table — model & effort`; `commands/worktask.md § Step C.0a`).

#### Recorded vs applied tiers

Under `none` (haiku, no `effort` passed) the `auto_decision_resolved` row records `effort_resolved: "requested, not applied"` and `effort_requested` keeps the computed tier. Under `frontmatter` (no `effort` passed: an unstamped row) `effort_resolved` comes from the hook row like `agent-param`. Under `agent-param` (in-process) and `dispatch-flag` (headless) `effort_resolved` is the tier the subagent's or child's own hook rows observed — `null` with `effort_resolved_reason: no_hook_rows` if none were (a row reading `"unknown"` observed nothing), never copied from the request. Recording the unapplied tier under `none` still gives the ledger the tier the item deserved. Don't reach that tier another way: substituting a different agent believed to run higher trades the domain expertise answering the question for a guess.

### The tier the model can actually carry

`xhigh` runs on Opus 5.5, Sonnet 5.5 and Fable 5.x (the `opus`, `sonnet` and `fable` targets); a pinned id outside those runs it at the highest level it supports at or below, with no error (`model-selection.md § xhigh routing`). A bump above `high` on a model other than the `opus`, `sonnet` and `fable` aliases is clamped to `high` and audited `effort_clamped`, never dispatched as a tier that evaporates in transit. No current stage hits the clamp (the only `haiku` stage sits at `low`), which is why it is enforced in code: nothing in a run would show it if it started happening.

A second silent path cannot be clamped and is read from the audit row instead: a managed or user `maxEffortLevel` below the requested tier runs the session at the cap with no error (`model-selection.md § Effort frontmatter and caps`). Resolvers therefore audit both `effort_requested` and `effort_resolved`, the same reason `dispatched_agents[].model_resolved` exists.

## Per-Stage Frontmatter Templates

Canonical YAML templates for the `handoff:` block atop every stage artifact. Each agent's `## Handoff Protocol` pastes the matching block verbatim (with substitutions) into `.context/<artifact>-N.md` (N per [#run-index-resolution](#run-index-resolution)); agents keep the field shape below. To change a template, edit here, then re-run `cache-lint.sh --frontmatter-template-lint agents/*.md` to revalidate every agent's inline copy. `#tpl-pl` has one more copy to mirror: the top of `skills/worktask/templates/planning.md`, which PL0 copies.

### Two first-write rules the stage gate enforces

Read these before the first artifact write. `handoff-harness.sh --validate-frontmatter` fails the stage on either.

1. **Frontmatter budget.** The `handoff:` block stays at or under 200 discretionary tokens. The harness counts words × 1.33, comments included, so the limit is about 150 words. `open_questions` stubs and `tests_executed` do not count.
2. **Sweep stubs.** Each `open_questions` stub has an item under `## elicitation-sweep` with 2–4 `options[]` (`label:`), or it is an `escalate` item whose question ends in `?`. Never write a status-note stub. The empty case is in § Closing Elicitation Sweep.

A Write that breaks either rule lands. `hooks/anchor-preflight.sh` then reports it at PostToolUse: fix it with a small Edit, do not re-Write the file. Every stage agent carries a short form of both rules in its generated "Artifact anchors" block.

### Typed-return equivalent

Each template below has a `<CODE>Handoff` JSON-Schema counterpart in
`handoff-protocol.md#handoff-schemas`, a parallel validated channel sharing one verdict vocabulary
per stage. Supersession rules and the write-either-way requirement: Validation Protocol steps 1–2
above.

### #tpl-pl — Planning (product-manager)

```yaml
---
handoff:
  stage: PL
  verdict: ok                  # ok / blocked / escalate
  summary: "<one-line summary ≤200 chars>"
  rejection_reason: "<gate feedback, revisions only; omit on first draft>"
  key_decisions:
    - { id: pd1, summary: "<decision>", anchor: "planning-N.md#scope" }
  next_stage_focus: "<imperative: what AR must grep/design>"
  open_questions:
    - { id: sw-PL0-1, class: decision, ref: "planning-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    spec: .context/attachments/<spec-file>
    plan: .context/planning-N.md#requirements
---
```

Prev→this label: `USER→PL`.

#### rejection_reason — after a plan-gate rejection

After a plan-gate rejection, the revised `planning-N.md` sets `rejection_reason:` to the user's gate feedback (verbatim or condensed) — distinct from the plan's `## summary` narrative — so downstream stages and ST retrospectives can cite it without reconstructing it from `audit.jsonl`. Omit the field on a first, un-rejected draft.

### #tpl-ar — Architecture (software-architector)

```yaml
---
handoff:
  stage: AR
  verdict: ok                  # ok / blocked / escalate
  summary: "<one-line summary ≤200 chars>"
  key_decisions:
    - { id: ad1, summary: "<decision>", anchor: "architecture-N.md#decisions" }
  next_stage_focus: "<imperative — addressed to TL when TL is in the plan, else to DV>"
  open_questions:
    - { id: sw-AR0-1, class: decision, ref: "architecture-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    plan: .context/planning-N.md#requirements
    decisions: architecture-N.md#decisions
---
```

`key_decisions` is also the source the orchestrator digests into the `metadata.architecture_ref.key_decisions` string (≤200 chars) stamped on the DV0/DR0/QA0 dispatches — keep each summary self-contained.

Prev→this label: `PL→AR`. Skip-exploration short-circuit applies — see `agent-coordination/SKILL.md § Orchestrator → PL0 Handoff`.

### #tpl-tl — Team Lead (team-lead)

```yaml
---
handoff:
  stage: TL
  verdict: ok                  # ok / blocked / escalate
  summary: "<one-line coordination summary ≤200 chars>"
  next_stage_focus: "<imperative: DV batch order + parallelization>"
  open_questions:
    - { id: sw-TL0-1, class: decision, ref: "coordination-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    plan: .context/planning-N.md#requirements
    arch: .context/architecture-N.md#decisions   # only when AR ran; omit otherwise
    fan_out: coordination-N.md#fan-out
---
```

Prev→this label: `AR→TL` (or `PL→TL` when AR was excluded). Skip-exploration short-circuit applies.

### #files-touched — the changed-file list

Every stage that emits `handoff.files_touched` emits it in one shape, because the field alone can
blow the token budget and ad-hoc truncations diverge.

#### Semantics — post-merge repo-relative

A path is written as it will read after this work merges: relative to the repository root, never to
a worktree, and never absolute. During a run the file lives under the emitting task's
`metadata.workspace_path`, so a consumer that wants to open it resolves `<workspace_path>/<path>`.
The recorded value answers "what did this run change", not "where is this file right now". No
script checks that the paths exist.

#### Cap — `FILES_TOUCHED_MAX = 10`

Emit the first ten repo-relative paths, then, when the full set
is larger, exactly one final entry of the literal form `+ <count> more`:

```yaml
  files_touched:
    - skills/worktask/scripts/state-patch.sh
    - skills/worktask/scripts/handoff-harness.sh
    - "+ 7 more"
```

Ten paths plus the marker cost 33 proxy tokens of the 200-token discretionary budget, and the list
counts inside that budget. The constant lives here and in `handoff-harness.sh`.
`handoff-harness.sh --validate-frontmatter` fails a list longer than the cap without a marker, a
marker that is not last, and more than one marker.

#### The marker obliges the body

Whenever the marker is present, the artifact's own changed-files body section carries the full set
and is marked authoritative in the same edit: the frontmatter is an excerpt, and an excerpt nobody
can complete is an ad-hoc truncation.

### #tpl-dv — Development (developer)

```yaml
---
handoff:
  stage: DV
  task_id: DV0                # your own ledger row id; required once the run has >1 DV row
  verdict: ok                  # ok / blocked / escalate
  summary: "<N files modified, M tests added>"
  tests_executed:             # one entry per runner; cases RUN, not discovered; [] is legal
    - { runner: bats, count: 12, summary_line: "1..12" }  # line verbatim; required when count > 0
  test_suite_compiles: true   # true/false/unknown; required when [] or every count is 0
  files_touched:              # cap 10, then ONE marker; #files-touched
    - path/to/file1.md
    - "+ 7 more"              # obliges the full body set
  next_stage_focus: "<imperative: what DR/QA must focus on>"
  open_questions:
    - { id: sw-DV0-1, class: decision, ref: "development-N.md#elicitation-sweep", blocks_next_stage: false }
---
```

#### Your artifact and row id come from the ledger (tpl-dv)

You write one artifact, the one your ledger row names (`tasks.<ID>.metadata.artifact`), not a
canonical file assembled from other DV rows. Naming grammar, the per-row `stream`/`artifact` keys
and the single-DV case: `handoff-protocol.md § DV fan-out — ledger tasks`. Patch that row by id and
path, since the orchestrator's basename guess cannot see a stream suffix:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --stage DV --task-id <ID> --prev <PREV> --artifact <your row's artifact path>
```

#### The refs and architecture half (tpl-dv)

```yaml
# …continued: handoff
  refs:
    decisions: architecture-N.md#decisions    # only when AR ran; omit
    coordination: coordination-N.md#fan-out   # only when TL ran; omit
    tests: development-N.md#tests-added
  architecture:                # only when AR ran; omit the object otherwise
    ref: architecture-N.md#decisions
    applied: true              # truthful; see the reference contract below
```

Prev→this label: `TL→DV` (`AR→DV` without TL, `PL→DV` when neither ran, `IR→DV` on emergency).

#### UI evidence comes from the running app (tpl-dv)

A screenshot offered as DV evidence is captured from the app built and run on its real runtime
surface this run, with each control confirmed on-screen and driven. The full rule is
`skills/dv-screenshot-capture/SKILL.md § Live-drive verification (ui_visual_check)`, with the
per-platform adapter table in its § Adapters.

The contract consequence: a `ui_visual_check` whose only evidence is a static render — `#Preview`,
`ImageRenderer`, an IDE canvas — is incomplete, not merely weaker. Canvas capture is the registered
degraded adapter on Apple and emits `screenshot_platform_fallback`; a DV artifact resting on it
without that row, or with it and no statement of why the live surface was unavailable, has not
shown the change working. Recapture from a live-driven run, because a static render differs from the
live app exactly where UI defects live: real data, real layout, real state transitions.

#### Verification Command carries the runner's verbatim summary line (tpl-dv)

`## verification-command` carries the command and the summary line the runner printed, copied
byte-for-byte into the artifact or into a `.context/logs/` capture the artifact names — not a
paraphrase, a count retyped from memory, or "all tests pass".

DV and QA hold test-execution authority and no stage between them does, so once the stage closes
nobody downstream can re-derive the number; the artifact is the only record that a count was
observed. DR treats a green suite reported without the line as an unverifiable claim.

Where a runner writes its tally only to a terminal, capture through a pty or a log and copy the line
out of the capture. Where a stage's scoped authority refuses the full-suite entrypoint, record the
refusal and quote the summary line of the scoped run that was permitted.

##### summary_line is the checked half (tpl-dv)

The same line goes in the frontmatter as the `summary_line` of that runner's `tests_executed` entry;
DV and QA carry it on every entry whose `count` is non-zero. `handoff-harness.sh
--validate-frontmatter` fails an entry whose line is absent, empty, digitless, or found neither in
the artifact body nor in a `.context/logs/` capture the artifact names, one `fail:` per bad entry in
a single run. It also fails an entry from a strict runner when the line does not carry that
entry's `count` as a whole-number token (§ Strict runners fail a count-less line).

##### An xcresult summary corroborates an xcodebuild line (tpl-dv, tpl-qa)

An `xcodebuild` line composed from `xcrun xcresulttool get test-results summary` JSON is printed
by no runner, so it has a third home: a `.context/logs/*.json` capture of that JSON, named in the
artifact body, whose `totalTestCount` equals the entry's `count`, with `count` a whole-number token
of the line. A missing capture, a file that is not that JSON, or an unequal total stays a fail. The
validator reads the capture only and never runs `xcresulttool`. Suggested name:
`.context/logs/qa0-xcresult-summary.json`.

##### Strict runners fail a count-less line (tpl-dv, tpl-qa)

The strict runners are listed once, in `skills/shared/testing-strategy.md § Strict-count runners`,
with the one exception for a failing pytest run. The list covers every name that starts with
`gradle` or `junit`, in any case. For every other runner the missing token only warns, with one
`count_corroboration` audit row. A `bash-*` live script then names a `.context/logs/` capture
whose result line carries the count. `xcodebuild` stays at warn: a mixed XCTest + Swift
Testing scheme prints one tally per framework and no total.

##### Gradle and JUnit quote the junit-tally line (tpl-dv, tpl-qa)

Gradle prints no count (`BUILD SUCCESSFUL in 4s`). For a `gradle*` or `junit*` runner, run
`skills/worktask/scripts/junit-tally.sh <results-dir>` on the JUnit XML directory (Gradle:
`build/test-results/test`). Capture its line to `.context/logs/`, name that capture in the
artifact, and quote the line as the `summary_line`:
`JUnit XML tally: 58 tests executed, 0 failures, 0 errors, 0 skipped`. The executed count is
`tests` minus `skipped`, summed over the leaf `<testsuite>` elements.

##### tests_executed carries one entry per runner (tpl-dv)

A multi-runner suite (bats + swift + pytest, say) records one entry per runner invocation, each
with its own `count` and the summary line that runner printed — never a sum across runners, and
never one runner standing in for the rest: `{runner: bats, count: 1949, summary_line: "1..1949"}`
and `{runner: pytest, count: 589, summary_line: "589 passed in 41.2s"}`. The same runner run at two
scopes is two entries. A rework round writes only its own entries: the ledger keeps earlier rounds
under `tasks.<ID>.rework_runs` (`handoff-protocol.md § Field notes — tests_executed, rework_runs`),
so no artifact copies one forward.

#### Acceptance commands are replayed, not trusted (tpl-dv, tpl-qa)

DV lists one self-checking command per exact-output rule (CLI flags, output format, byte-level
example) under `## acceptance-commands`: a fenced `bash` block, one command per line, each
comparing real output to the expected bytes with `cmp` or `diff`. QA executes every line verbatim
and records it as `- exit=<n> <command>` under its own `## acceptance-commands`;
`skills/worktask/scripts/acceptance-check.sh` then decides — a listed command that was not
executed, or exited non-zero, is `verdict: no-go`. A green unit suite does not stand in for it:
the contract is exactly what a paraphrase between agents loses.

#### Zero executed tests must say whether the suite compiles (tpl-dv)

Each `tests_executed` entry's `count` is cases that actually ran — the number in that runner's
summary line, never the number a runner enumerated before exiting. Zero is legal; being unable to
tell zero from "never built" is not.

So when the `tests_executed` list is empty or every `count` is `0`, `test_suite_compiles` is
required: `true`, `false`, or `unknown` with the reason in the body. Compilation is checkable
without test-execution authority, which is why it is asked of the stage that was denied.

##### Why not build_status (tpl-dv)

`build_status` reports the app build, and a test target can fail to compile while the app builds
clean. `handoff-harness.sh --validate-frontmatter` fails a DV artifact whose `tests_executed` list
is empty or all-zero and carries no `test_suite_compiles`.

#### Architecture reference contract (tpl-dv)

When AR ran, both `refs.decisions` and the `architecture` object are required; both are omitted
when AR was excluded. They are not alternatives: `refs.decisions` is the anchor-read pointer
downstream stages follow, `architecture.ref` is the typed carrier the `DVHandoff` schema
validates, and `architecture.applied` is the assertion DR checks. The harness accepts either
(precedence below), but DR rejects an absent `architecture` object as `missing_input`.

Gate precedence, shared by the harness, the schema and the DR rule: `refs.decisions`, then
`architecture.ref`. The chosen value must match `^architecture-[0-9]+\.md(#[a-z-]+)?$` and resolve
to a file next to the artifact — warn-only by default, blocking under `--strict`. An architecture
reference with no `tasks.AR0` entry trips the inverse guard (warn, never a failure).

##### Unreadable-state exception

An unreadable `--state` warns by default and fails (exit 1) under `--strict`.

### #tpl-dr — Developer Review (technical-lead)

```yaml
---
handoff:
  stage: DR
  verdict: pass                # pass / fail
  summary: "<N files reviewed. M findings, all addressed / K blockers remain>"
  key_decisions:
    - { id: dr1, summary: "<finding or approval>", anchor: "developer-review-N.md#findings" }
  open_questions:
    - { id: sw-DR0-1, class: decision, ref: "developer-review-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    dev:                                   # always a list, one element per DV ledger row
      - development-0-service.md#files-changed
      - development-0-web.md#files-changed
    findings: developer-review-N.md#findings
---
```

Prev→this label: `DV→DR`.

#### refs.dev is a list, one element per DV row (tpl-dr … tpl-re)

`refs.dev` is always a YAML list: a single-DV run yields a one-element list, never a scalar.
Each element is `<artifact basename>#files-changed`, one per DV ledger row, in ascending numeric
task-id order. Resolve them from the ledger rather than composing a filename — the idiom and the
naming grammar are `handoff-protocol.md § Iterating the DV tasks` (seam S3). The same field, shape
and rule apply to `#tpl-sr`, `#tpl-qa`, `#tpl-dc` and `#tpl-re`.

### #tpl-sr — Security Review (security-reviewer)

```yaml
---
handoff:
  stage: SR
  verdict: pass                # pass / fail
  summary: "<N files reviewed. M security findings>"
  key_decisions:
    - { id: sr1, summary: "<security finding>", anchor: "security-review-N.md#findings" }
  open_questions:
    - { id: sw-SR0-1, class: decision, ref: "security-review-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    dev:                                   # always a list, one element per DV ledger row
      - development-0-service.md#files-changed
      - development-0-web.md#files-changed
    findings: security-review-N.md#findings
---
```

Prev→this label: `DR→SR`.

A question whose options include accepting a known vulnerability, a CVE or a security finding is
`class: escalate`, never `decision`: accepting one is an escalation-class choice per
`commands/worktask.md § Escalation guard (BINDING)`.

### #tpl-qa — QA (qa-engineer)

```yaml
---
handoff:
  stage: QA
  verdict: go                  # go / no-go
  summary: "<N unit tests pass, M integration checks. Coverage X%>"
  tests_executed:              # one entry per runner; cases RUN; QA holds full-suite authority
    - { runner: bats, count: 840, summary_line: "1..840" }  # line verbatim; required when count > 0
  files_touched:
    - tests/added/test-file.sh
  key_decisions:
    - { id: qa1, summary: "Coverage X%, target met", anchor: "testing-N.md#coverage" }
  open_questions:
    - { id: sw-QA0-1, class: decision, ref: "testing-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    dev:                                   # always a list, one element per DV ledger row
      - development-0-service.md#files-changed
      - development-0-web.md#files-changed
    results: testing-N.md#results
---
```

Prev→this label: `DR→QA` (or `SR→QA` when SR runs).

#### QA summary lines take the tpl-dv checks (tpl-qa)

Every QA `tests_executed` entry takes the `#tpl-dv` `summary_line` checks, the strict-runner fail
included. A `gradle*` or `junit*` entry quotes the `junit-tally.sh` line
(§ Gradle and JUnit quote the junit-tally line).

#### An unverified security claim in shipped docs is a finding (tpl-qa)

A security or networking claim in payload documentation that QA did not verify is a finding,
recorded in `key_decisions` and reflected in the verdict. "The README says it binds to loopback" is
a claim about the artifact, not about the system, and such claims have passed developer review
while false; only a live probe caught them.

Ask for the claim to carry its own falsifier — for example, the `lsof` command that would disprove
a loopback-binding claim — so it cannot drift from the system and checking it costs one command.

### #tpl-dc — Documentation (technical-writer)

```yaml
---
handoff:
  stage: DC
  verdict: ok                  # ok / blocked / escalate
  summary: "Updated N documentation files. Cross-references added."
  files_touched:
    - docs/file1.md
  open_questions:
    - { id: sw-DC0-1, class: decision, ref: "documentation-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    dev:                                   # always a list, one element per DV ledger row
      - development-0-service.md#files-changed
      - development-0-web.md#files-changed
    docs: documentation-N.md#files-changed
---
```

Prev→this label: `QA→DC`.

#### Security and networking claims cite their evidence (tpl-dc)

Any security or networking claim in payload documentation names the stage and the evidence that
verified it — a probe, a config line, a test — or it does not ship. "Binds to loopback", "requires
auth", "no credentials at rest" are all claims of this class.

Prefer a claim that carries its own falsifier: documentation that ships the command proving it
cannot drift from the system silently. A claim with no cited evidence is DC asserting something no
stage established, and it will be believed.

#### Under fan-out, DC reads a tree that does not exist yet (tpl-dc)

In fan-out mode each DV row lands in its own tree, so a cross-stream claim — a path, a command,
an integration — describes an assembled tree DC cannot see, and may be right even though DC's tree
lacks it.

Mark every cross-stream claim `consistency-checked, not executed`, naming what was compared and why
execution was impossible. An unmarked claim reads as verified, so DC's verdict would carry a
confidence its evidence does not support.

#### DC runs the option-existence gate before handoff (tpl-dc)

Before handoff DC runs `doc-option-check.sh` (`skills/worktask/scripts/`) over every documentation
file it wrote or edited, with one `--tree` per assigned tree: `metadata.workspace_path`, plus each
worktree the dispatch names. The script checks two things. Every documented env var and long flag
must appear in a tracked or untracked, not-ignored file of some tree, the docs under check and
`.context/` excluded. Every link target and backticked relative path must resolve inside a tree and
exist. It prints one JSON line per finding and exits 0 clean, 1 on a finding, 2 on bad usage, 3 when
a tree or doc cannot be read.

Exit 1 is a gate failure, not a warning, and neither 2 nor 3 is a pass. `--allow` suppresses a name
the host sets, and each use names that host in `documentation-N.md`. The steady-path steps live in
`agents/technical-writer.md § Option-existence gate (DC2)`.

#### DC exempts a runtime path with --allow-path (tpl-dc)

`--allow-path <path>` suppresses a `missing` path finding at that tree-relative path or below it, for a path the code creates at run
time. The value must not be empty, `.`, absolute, or hold `..`. Each use records the creating
`file:line` or the `.gitignore` line in `documentation-N.md`. DC uses it after one failed fix
attempt, never deletes a correct claim to quiet the check, and runs the gate at most 3 times per doc
set.

#### A finding routes by who wrote the line (tpl-dc)

The first arm that matches wins:

1. DC wrote the flagged line this run: DC fixes the doc and re-runs the check. The finding is not
   returned.
2. An upstream task's handoff `files_touched` lists the doc: DC leaves the line and returns
   `verdict: blocked` with `blocked_on.kind: correction`, naming the latest such task.
3. Neither: the line predates this run, so DC fixes it as in arm 1 and names it in
   `documentation-N.md`.

`blocked_on` holds one finding, the first arm-2 finding in stdout order. `documentation-N.md` lists
every finding with its arm, so a rework round is not left to rediscover the rest one gate run at a
time.

#### The correction return (tpl-dc)

<example>

```yaml
# …continued: handoff, a DC return carrying one arm-2 finding
  verdict: blocked
  summary: "doc-option-check.sh: 1 finding in a doc DV0 owns"
  blocked_on:
    kind: correction
    detail:
      target_task: DV0
      finding: "README.md:42: env API_BIND undefined"
      evidence_ref: "README.md:42"
      severity: blocking
    resume_with: artifact_path
```

</example>

`kind`, `detail` and `resume_with` are the three keys of the `handoff.blocked_on` return contract,
and `correction` is its kind for this case. The `detail` keys are `target_task`, `finding`,
`evidence_ref`, `severity`, in that order. `finding` is the offending line verbatim, because the
rework brief quotes it. `evidence_ref` is `<file>:<line>`, and DC always sets `severity` to
`blocking`.

#### The correction return — any stage, any resolver (tpl-dc)

The example is DC's, but the arm is not: any stage or resolver that finds a defect in work another task already completed returns this same shape, and the router treats every one of them identically. FN's staged control-byte check is another origin (§ #tpl-fn).

##### Rules for correction returns

- The target is a `completed` task. A correction re-opens finished work; the ledger op refuses a target that is missing, is the returning task itself, or is in any other status. A defect in work still in flight is not a correction — it is that task's own round to finish (`skills/worktask/references/handoff-protocol.md § tasks — re-open and settle — guards and invocation`).
- Return it, never route it. The orchestrator re-opens the target, parks the tasks that consumed its output, and hands the rework brief back. A stage that edits the other task's files, or asks in prose for someone to fix them, has routed by hand and left no ledger row or audit leg.

### #tpl-re — Release Engineering (release-engineer)

```yaml
---
handoff:
  stage: RE
  verdict: ok                  # ok / blocked
  summary: "Release artifacts prepared. Version bumped to X.Y.Z"
  files_touched:
    - plugin.json
    - MEMORY.md
  key_decisions:
    - { id: re1, summary: "Version X.Y.Z", anchor: "release-N.md#version" }
  open_questions:
    - { id: sw-RE0-1, class: decision, ref: "release-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    dev:                                   # always a list, one element per DV ledger row
      - development-0-service.md#files-changed
      - development-0-web.md#files-changed
    artifacts: release-N.md#artifacts
    version: release-N.md#version
---
```

Prev→this label: `DC→RE` (or `QA→RE` when DC did not run).

A question offering to ship with a known vulnerability, CVE or open security finding is
`class: escalate` per `commands/worktask.md § Escalation guard (BINDING)`.

### #tpl-fn — Finalization (project-manager)

```yaml
---
handoff:
  stage: FN
  verdict: ok                  # ok / blocked
  summary: "All artifacts aggregated. complete-summary-N.md ready for ST approval."
  files_touched:
    - .context/complete-summary-N.md
  next_stage_focus: "ST approves merge and confirms MEMORY.md version bump"
  open_questions:
    - { id: sw-FN0-1, class: decision, ref: "complete-summary-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    summary: .context/complete-summary-N.md
    ledger: .context/state.json
---
```

Prev→this label: `RE→FN` (or `DC→FN` without RE, `QA→FN` without RE and DC).

`fn-preflight.sh staging` fails on a raw control byte in a staged text file (`control-byte-lint.sh
--staged`). When the file belongs to another task — its handoff `files_touched` lists it — that is a
correction FN returns with itself as the source and that task as the target, not a byte FN edits
out (§ The correction return — any stage, any resolver).

### #tpl-st — Stakeholder (stakeholder)

```yaml
---
handoff:
  stage: ST
  verdict: approve             # approve / reject
  summary: "Approved. <N follow-ups filed or 'No follow-ups'>."
  # blockers: ["<criterion>: <gap>"]   # reject only — injected into the replayed DV prompt
  key_decisions:
    - { id: st1, summary: "Approve merge", anchor: "retrospective-N.md#decision" }
  open_questions:
    - { id: sw-ST0-1, class: decision, ref: "retrospective-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    summary: .context/complete-summary-N.md
---
```

Prev→this label: `FN→ST` (or `RE→ST`/`DC→ST`/`QA→ST`, from the latest of those that ran, when FN did not run).

ST treats every `escalate` item as a recommendation only and never resolves it, in prose or in the ledger; the user answers it at its checkpoint.

### #tpl-ir — Incident Response (incident-responder)

```yaml
---
handoff:
  stage: IR
  verdict: ok                  # ok / escalate
  summary: "Root cause: <X>. Fix plan: <Y>. Blast radius: <Z>"
  key_decisions:
    - { id: ir1, summary: "Root cause identified", anchor: "incident-N.md#root-cause" }
  next_stage_focus: "DV implements fix; QA runs regression"
  open_questions:
    - { id: sw-IR0-1, class: decision, ref: "incident-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    root_cause: incident-N.md#root-cause
    fix_plan: incident-N.md#fix-plan
---
```

Prev→this label: `USER→IR`.

### #tpl-et — Ethics Review (ethics-reviewer)

```yaml
---
handoff:
  stage: ET
  verdict: pass                # pass / fail (block/conditional → fail with key_decisions)
  summary: "Ethics review complete. Score: <X>/100. Status: <APPROVED|CONDITIONS|BLOCKED>."
  key_decisions:
    - { id: et1, summary: "Compliance verdict", anchor: "ethics-review-N.md#findings" }
  next_stage_focus: "Invoking stage resumes after ET verdict"
  open_questions:
    - { id: sw-ET0-1, class: decision, ref: "ethics-review-N.md#elicitation-sweep", blocks_next_stage: false }
  refs:
    review: .context/ethics-review-N.md
    ledger: .context/state.json
---
```

Prev→this label: `<invoker>→ET` (whichever stage triggered the ethics gate).

## Completion Verification — before return

Single source of truth for what every stage agent verifies before `status: completed`. Each agent's `## Handoff Protocol` references this checklist rather than restating it. Repeat the numbered step outcomes verbatim in your return summary. Execute in order:

### Steps 1–3

1. Artifact frontmatter: your artifact (`.context/<artifact>-N.md`) starts with `---\nhandoff:` conforming to the per-stage template at `stage-contracts.md#tpl-<CODE>`.
2. Required fields: the frontmatter includes every required field for your stage `<CODE>` per `handoff-protocol.md#frontmatter-schema` § Per-stage required-field matrix.
3. Artifact filename: the canonical name from `handoff-protocol.md#stage-artifact-map`. Non-canonical names (e.g. `arch-0.md` for `architecture-0.md`) break the SubagentStop safety net.

### Steps 4–5

4. Patch state.json: patch `tasks.<ID>` (`status`, `artifact`, `verdict`, `retry_count`) and `handoffs["<PREV>→<TASK_ID>"]` (≤300-char summary ending with a `ref:` pointer). The source side is a bare stage code naming the stage this followed, as each template's footer above shows (e.g. `PL→AR`, `USER→IR`). The destination side is the writing task's own id, so a split stage writes one edge per task (`TL→DV0`, `TL→DV1`) instead of colliding on one key.
5. Atomic write: run `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --stage <CODE> --prev <PREV>`, which performs the canonical locked read → merge → temp → fsync → rename of `handoff-protocol.md#atomic-write`. Don't write `.context/state.json` directly. If the script cannot run at all, don't skip silently; use the Edit-direct fallback at `handoff-protocol.md#layer-1-fallback`.

### Post-return repair (F2/F3)

The orchestrator verifies `tasks.<ID>.status == "completed"` after the task returns. If still `in_progress`, the SubagentStop hook (`state-merge.sh`) repairs the ledger from the artifact's frontmatter (F2). If the artifact lacks frontmatter, the orchestrator derives a minimal handoff record from the return text (F3), but downstream cache hits collapse, so valid frontmatter is still required.

## Cross References

- `skills/worktask/references/handoff-protocol.md` — canonical state.json + frontmatter + anchor specs
- `skills/shared/stage-codes.md` — code/agent/model lookup
- `skills/shared/state-ledger.md` — metadata schema, `error_file` derivation, `context_refs`/`state_file`
- `skills/agent-coordination/SKILL.md` § Error Handling — retry/escalate matrix
- `skills/logging-conventions/SKILL.md` — raw capture paths (`.context/logs/`)
- `skills/task-folder-organization/SKILL.md` — artifact naming and retention
- `skills/self-improvement/SKILL.md` — optional `.context/learnings.md` produced at ST
