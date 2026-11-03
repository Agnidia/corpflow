# Launch options

Read for a new invocation before parsing flags and selecting the launch path.

Procedure routing: [workflow](workflow.md).

<!-- canonical-body:start -->
## Execution model

> **Execution model** — every worktask is worktree-isolated, so the PR is the review
> surface. Three orthogonal carriers on `PL0.metadata` drive the two human checkpoints and the
> optional decision delegate; `/megatask` sets them on each per-issue PL0 (§ Per-issue run under
> `/megatask`).
>
> | Carrier | Default | Alternate |
> |---|---|---|
> | `plan_gate` | `checkpoint` | `bypass`: `--auto=[plan]` or `--emergency` |
> | `decision_gate` | `user` | `auto`: `--auto=[decision]` |
> | `fn_gate` | `checkpoint` | `bypass`: `--auto=[finalization]` or `--emergency` |
>
> Procedures: [plan-approval.md](plan-approval.md), [auto-decision.md](auto-decision.md), and [finalization-gate.md](finalization-gate.md).

# Worktask Workflow

`/worktask` runs one issue through the staged pipeline; it has no `--milestone` flag. A milestone
or an issue array with dependency ordering is `/megatask`. Three constraints bound every run:

- Worktask state lives in `.context/state.json` `tasks{}`, written only via `state-patch.sh`. Do
  not use Claude Code's built-in plan mode.
- Every stage has a ledger entry; never skip seeding one.
- If the ledger cannot be read or written, stop and report. Never fall back to alternative
  planning.

## Options

### Gate automation flag (`--auto`)

`--auto=[<values>]` takes any non-empty, comma-separated subset of `plan`, `decision`,
`finalization`; brackets are optional and inner whitespace is tolerated (`--auto=[plan, decision]`,
`--auto=plan,finalization`). An unknown value is a parse error: reject the invocation and report,
never drop it silently. Each value is an independent carrier on PL0. Default: no `--auto`, so
every carrier keeps its default from the table above.

#### Gate automation flag — values

| Value | Stamps | Effect beyond the carrier table above |
|-------|--------|---------------------------------------|
| `plan` | `plan_gate: "bypass"` | Auto-proceeds into the stage loop. FN gate still checkpoints unless `finalization` is also set. |
| `decision` | `decision_gate: "auto"` | Bypasses no gate by itself: under a `checkpoint` plan gate the auto-decisions are presented (marked) for approval. Also what enables the § Step C.0a resolver, so a blocking `decision` item from AR/TL/DV/DR/SR/QA/DC/RE/ET is answered a tier up instead of stopping the run. Escalation-class questions — irreversible, scope-expanding, security-posture, spend — always fall back to the user. |
| `finalization` | `fn_gate: "bypass"` | Auto commit/push/PR. Plan gate still applies unless `plan` is also set. |

#### Gate automation flag — `--accept-absent`

`--accept-absent=<tool[,tool]>` names the evidence tools an unattended run may launch without. Only
§ Step 2a-pre reads it, so it does nothing unless `--auto` contains `plan` or `finalization`, and it
is the only way a missing tool stops counting as a preflight fail. Tools: `renderer` (backend,
systems, ai, all; covers `silicon`, `magick` and `convert`, which may also be named one at a time),
`playwright` and `playwright-browser` (web), `adb-device` (android), `simulator`
and `xcodebuildmcp` (apple). An unknown tool is a parse error, as for `--auto`. Pass the list
verbatim; never default, extend or infer it, so a tool nobody named stays a fail. Default: empty.

### Scope and pipeline flags

#### Scope flags

| Option | Values | Effect |
|--------|--------|--------|
| `--priority <High\|Medium\|Low>` | One level (default: `Medium`) | Task priority |
| `--platform <apple\|android\|web\|systems\|backend\|ai\|all>` | One platform (default: what the repo markers resolve to, `skills/shared/platform-detection.md § Detection Rules (markers → platform)`) | Target platform |
| `--ethics-review` | Flag (default: off) | Add ET checkpoint after PL |
| `--with-design` | Flag (default: off) | Invoke `corpflow:designer` during PL. Sets `metadata.with_design: true` on PL0. Without it Designer is skipped even for UI work and the keyword score stays advisory. |

#### Pipeline flags

| Option | Values | Effect |
|--------|--------|--------|
| `--sequential` | Flag (default: off, DC runs beside QA) | DC waits for QA |
| `--secure` / `--full` | Flag (default: off, standard pipeline) | Use 11-stage worktask |
| `--emergency` | Flag (default: off) | Run the incident pipeline (IR→DV→DR→QA→RE→FN) instead of the PL-first pipeline; IR owned by `incident-responder`. |
| `--no-gh-issue` | Flag (default: off, the issue is published) | Skip the post-PL GitHub issue auto-publish. Sets `metadata.no_gh_issue: true` on PL0; `publish-pl-issue.sh` audits `deferred`/`opted_out` and the stage loop continues. |

### Replay flags

| Option | Values | Effect |
|--------|--------|--------|
| `--resume <STAGE_ID>` | A ledger id such as `DV1`, not a stage code (default: none, a new run) | Replay one already-settled stage of the worktask in this `.context/` — § Phase 0. Creates no run: no new `planning-N.md`, no issue, no branch rename. Composes with none of the flags above. |
| `--cascade` | Flag, only with `--resume` (default: off, the target alone) | Also replays dependents transitively reachable through `blocked_by`. FN/RE **dependents** are traversed through but never reset; an FN/RE named as the *target* is still reset — an explicit id is your instruction — with a `side-effect-target` warning. |

## Examples

```bash
/worktask "<task description>" [--secure|--full] [--emergency] [--priority High|Medium|Low] [--platform <p>] [--ethics-review] [--with-design] [--sequential] [--no-gh-issue] [--auto=[plan,decision,finalization]] [--accept-absent=<tool[,tool]>]
/worktask --resume <STAGE_ID> [--cascade]
/worktask "Add dark mode support"                      # standard pipeline
/worktask "Rotate the API token store" --secure        # 11-stage
/worktask "Fix flaky sync test" --priority High --platform apple
/worktask "Ship the referral banner" --ethics-review --sequential
/worktask "Bump the SDK" --no-gh-issue --auto=[plan,finalization]
/worktask "Add the export endpoint" --platform backend --auto=[plan,finalization] --accept-absent=renderer
/worktask --emergency "Production login failing"       # IR→DV→DR→QA→RE→FN
/worktask --resume DV1 --cascade                       # replay DV1 and its dependents
# Multi-issue: /megatask 1 (milestone) or /megatask --issues 12,15,18 (array)
```

## Output Format

One block per stage as it settles, then the run summary:

~~~markdown
# Worktask: <title> · <worktask_id> · <standard|secure|emergency>

## Stage — <CODE><N> · agent · model/effort · verdict (ok|blocked|escalate)
## Artifact — `.context/<stage>-N.md` plus its `handoff.summary` line, verbatim
## Ledger — the `state-patch.sh` call applied and the task ids it moved
## Gates — plan gate and FN gate: reached, bypassed, or approved (and by whom)
## Result — branch, PR URL, issue closed, follow-up issues filed
~~~

A blocked or escalated stage replaces `## Result` with `## Blocker — what stopped, at which stage,
and the decision the user owes`. The ledger stays resumable either way: `/worktask --resume <ID>`.

### Output Format — unresolved decisions open the final message

After FN, the final message opens with the stdout of
`bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/fn-preflight.sh unresolved-decisions --print` whenever it is
non-empty, verbatim and before `# Worktask:`. It is the same scrubbed block FN wrote at the top of
the PR body, so the user reads every escalate item that shipped undecided first. Empty stdout adds
nothing. On a non-zero exit, say the block could not be rendered and retype no question text: the
scrub is what keeps host paths out of it.

## Worktask Types

Pipeline shapes: `skills/worktask/references/worktask-stage-context.md#pipelines`.
Stage identifiers: `skills/worktask/references/stage-codes.md#primary-stages-11-stage`.
Stage inclusion: `skills/estimation-methodology/SKILL.md#stage-inclusion-criteria-pl0-authority`.

## Session hygiene

Start each `/worktask` or `/megatask` in a fresh session. Between tasks, `/rename` the session and
then `/clear`; the ledger, not the conversation, carries a task forward
(`skills/worktask/references/recovery-state.md § State → Action Table`). Run `/loop` jobs in a separate
session so their output does not pile up in the orchestrator's context.
