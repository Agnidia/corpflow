---
name: worktask
description: Run one task through the staged worktask pipeline (plan, build, review, test, docs, PR) with plan and finalization gates and a resumable state ledger
argument-hint: '"<task description>" [--secure|--full] [--emergency] [--priority <High|Medium|Low>] [--platform <p>] [--ethics-review] [--with-design] [--sequential] [--no-gh-issue] [--auto=[plan,decision,finalization]] [--accept-absent=<tool[,tool]>] | --resume <STAGE_ID> [--cascade]'
version: 0.7.0
# tools: bare Agent because each stage row's metadata.agent may name a platform variant from any
# plugin (`pl0-procedure.md § Stage → agent table`, a project or user-scope CORPFLOW.md § Routing
# override included), and the Step C.0a resolver and Phase 3 re-dispatch those agents,
# `corpflow:prompt-engineer` or `corpflow:workflow-engineer`.
allowed-tools: Read, AskUserQuestion, SendMessage, ListAgents, Monitor, TaskStop, Bash(claude:*), Glob, Grep, Bash(mkdir:*), Bash(gh:*), Bash(git:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/preflight-issue-scan.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/fn-preflight.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/branch-name.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/refine-branch-target.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/publish-pl-issue.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/handoff-harness.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/effort-ladder-cli.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/model-matrix.sh --resolve *), Agent, Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/autonomy-preflight.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/seed-state.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/workspace-root-banner.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/brief-compose.sh *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/land-artifacts.sh --producer *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/land-artifacts.sh --consumer *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/land-artifacts.sh --list-landed *), Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/megatask-settle.sh *)
related:
  - skills/worktask/SKILL.md
  - commands/megatask.md
  - skills/megatask/SKILL.md
  - skills/shared/stage-codes.md
  - skills/agent-coordination/references/headless-dispatch.md
  - agents/workflow-engineer.md
---

> **Execution model** — every worktask is worktree-isolated, so the PR is the review
> surface. Three orthogonal carriers on `PL0.metadata` drive the two human checkpoints and the
> optional decision delegate; `/megatask` sets them on each per-issue PL0 (§ Per-issue run under
> `/megatask`).
>
> | Carrier | Default | Alternate | Meaning |
> |---|---|---|---|
> | `plan_gate` | `checkpoint` | `bypass` — `--auto=[plan]`, `--emergency` | Post-PL0 checkpoint: present the plan, wait for explicit `AskUserQuestion` approval before dispatching any implementation stage (AR/DV/…) |
> | `decision_gate` | `user` | `auto` — `--auto=[decision]` | Who answers `open_questions[]`: the user, or a delegate. PL0's at the plan gate (§ Step A.4); every other stage's blocking items at their own boundary (§ Step C.0a); the FN-gate batch at § Step C.3. Escalation-class questions always fall back to the user |
> | `fn_gate` | `checkpoint` | `bypass` — `--auto=[finalization]`, `--emergency` | Pre-FN checkpoint: stop before the FN `Agent()`, present a pre-FN summary, approve before any commit/push/PR |

# Worktask Command

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

| Type | Stages | Entry point |
|------|--------|-------------|
| Standard | PL→AR→TL→DV→DR→QA→DC→FN→ST | `/worktask` |
| Secure | PL→AR→TL→DV→DR→SR→QA→DC→RE→FN→ST | `/worktask --secure` |
| Emergency | IR→DV→DR→QA→RE→FN | `/worktask --emergency` |

AR and TL are optional in the standard and secure pipelines: AR is a tier default PL0 may override
either way, TL is included only when PL0 splits work across ≥2 developers. Criteria:
`skills/estimation-methodology/SKILL.md § Stage Inclusion Criteria (PL0 authority)`. Stage details:
`skills/shared/stage-codes.md`.

## Session hygiene

Start each `/worktask` or `/megatask` in a fresh session. Between tasks, `/rename` the session and
then `/clear`; the ledger, not the conversation, carries a task forward
(`skills/worktask/references/resume.md § State → Action Table`). Run `/loop` jobs in a separate
session so their output does not pile up in the orchestrator's context.

## Phase 0: Replay one stage (`--resume <STAGE_ID>`)

Entered only by `/worktask --resume <STAGE_ID> [--cascade]`. Unlike automatic reattach (first
incomplete stage, retry ceiling honoured), a replay is given one ledger id by a human and may
override that ceiling (`skills/worktask/references/resume.md § Explicit-replay row`).

Phase 0 replaces Phase 1 entirely, then re-enters the existing stage loop with no new dispatch
route or readiness rule: the replayed task becomes `pending` with its dependencies still
`completed`, so it is the first unblocked task and every other stage stays settled.

### Phase 0 — what runs

**Skip** — all of Phase 1 (Steps 2a, 3, 3a, 3c, 4, 5–6, 7–8) and every pre-loop Phase 2 step
(A.4, A.4b, A.5, Step A publish). `run_index` is frozen; no `planning-N.md`, no rename, no issue.

**Run** — Step 3b hook-install verification (idempotent; a resumed loop still needs
SubagentStop), the `fn-preflight.sh branch-divergence` check (`resume.md § Branch-rename
detection`), and the workspace-root cross-check before every `Agent()`.

### Phase 0 — procedure

1. No `.context/state.json` in the working tree → error out: "no worktask here — use
   `/worktask <task>`". Do not seed one.
2. Present the pre-replay confirmation and stop, naming: the target id with its status,
   `retry_count`, `error_escalated_to`; whether the escalation cap is being overridden; any
   already-`completed` dependents, marked *these may now be stale* (warn only — never auto-reset);
   a plan-unapproved warning when no `approval_received` row exists for `PL<run_index>`; and under
   `--cascade` the member list plus the skipped FN/RE members. There is no bypass flag.
3. Run `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-replay <ID> [--cascade]`.

### Phase 0 — procedure, steps 4–6

4. **Exit 4** means a guard refused (target live or parked, liveness indeterminate, planning
   incomplete, or a blocked cascade member); `state.json` is byte-unchanged. Print the refusal line
   verbatim and stop without entering the stage loop. Exit 1 is an unknown id, exit 2 a malformed one.
5. Append the ordinary `resume` audit row (`resume.md` step 7) — it records session re-entry, while
   the primitive's `stage_replay` row records what changed in the ledger.
6. Re-enter `§ After Step A — run the stage loop`, unchanged.

### Phase 0 — gates on a resumed run

| Gate | Behaviour |
|------|-----------|
| `plan_gate` (Step A.5) | Never re-fires. It gates the Phase-1→Phase-2 transition; a replay reopens no planning and the `approval_received` row persists. Its absence is a warning at step 2, not a stop |
| `fn_gate` | Applies unchanged: it belongs to the loop, not the entry point, so a resumed run cannot slip a commit past the finalization checkpoint |

## Phase 1: Planning (execute immediately)

> **BINDING 1 — Pre-work Prohibition**: create, edit, or modify no project files during Phase 1
> (localization, accessibility IDs, config, sources); file changes belong to DV or later. The only
> writes permitted are the Step 3 `mkdir -p .context/…`, `state-patch.sh` ledger writes, the
> Step 3a `seed-state.sh` seed, the Step 2a `.context/gh-issue.json` anchor (reuse path only), the
> Step 3a `autonomy-preflight.sh --record` call, and the `mktemp` buffers under `$TMPDIR`
> (`corpflow-preflight.*`, `corpflow-issue-scan.*`) that § Step 2a-pre and § Step 2a write.

### Context-Interruption Recovery

After an interruption (auth flows, tool failures), verify PL0 exists with status `completed`; if
not, restart from the appropriate phase. The exception: PL0 `in_progress` with stage tasks present
and a `plan_revision_dispatched` audit row with no later `approval_received` for `PL<run_index>` is
a plan revision in flight — resume it per § Plan-revision re-dispatch (`plan_revision: true`),
never the fresh-run path. Both checkpoints still apply: the plan gate at Step A.5 and the FN gate
(`skills/worktask/SKILL.md § FN Gate`).

### Steps 1–2 — Parse flags and detect embedded commands

1. **Parse** the task description and flags. Resolve the `--auto` array per § Gate automation flag:
   strip optional brackets, split on commas, trim whitespace, reject unknown values. Parse
   `--accept-absent=` beside it (§ Gate automation flag — `--accept-absent`): keep the value
   verbatim for Step 2a-pre, and reject an unknown tool.
2. **Detect embedded commands**: extract any `/plugin:command` or `/command` pattern into
   PL0's `metadata.embedded_commands` (comma-separated, stamped at Step 4), strip the prefix from
   the description passed to PL0, preserve the arguments. See § Embedded Command Detection.

### Per-issue run under `/megatask`

When `/megatask` launched this run (the dispatch prompt carries a `PL0.metadata` stamp with
`megatask_group`), read `skills/worktask/references/megatask-per-issue.md` before Step 2a-pre: its
Bash prefix opens every call, and its table lists the steps that change. Other runs skip it.

### Step 2a-pre — Autonomy preflight (unattended runs)

Runs only when the resolved `--auto` contains `plan` or `finalization`, before Step 2a and Step 3;
without either value, skip it. When it runs, follow `skills/worktask/references/autonomy-preflight.md`:
the snippet, the exit-code decision and the inputs.

### Step 2a — Duplicate-issue pre-flight (advisory)

Runs once the request is known and strictly before Step 3 creates `.context/`. The
`skills/gh-issue-dedup` anchor guards re-runs only, so a first run of work already filed under
different wording still opens a second issue — this step surfaces the candidates while the duplicate
is still preventable. Append `--no-gh-issue` to the invocation when that flag was supplied. When
`--auto` contains `plan`, nobody is there to answer the gate: run § Step 2a — unattended instead of
the snippet and gate below.

#### Snippet preamble (snippets that reference an ungranted plugin file)

A script granted in `allowed-tools:` is never reached through this variable: it runs as the exact
text its grant matches, such as `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh`
(`skills/shared/plugin-root-resolution.md § Granted-script invocation shape`).

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"  # CC substitutes on load; if empty resolve per skills/shared/plugin-root-resolution.md
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="<plugin-root>"
```

#### Step 2a snippet — invoke the scan, non-blocking

```bash
# A missing script exits 127; `|| true` turns that into "no candidates", as for any scan failure.
scan_out=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/preflight-issue-scan.sh --goal "<task description>") || true
scan_result=$(printf '%s\n' "$scan_out" | sed -n 's/^result=//p' | tail -n 1)
```

#### Step 2a — the gate

Anything other than `result=shown` proceeds to Step 3 unchanged, with no prompt. On `result=shown`,
present each `candidate=<json>` line (number, title, url — at most three, most likely first) and
`AskUserQuestion` with exactly two outcomes:

- **Start a new worktask** — Step 3 as normal. Nothing is written yet, so declining leaves no
  orphaned state.
- **Use one of the existing issues** — Step 3, then bind this context to the chosen issue: after
  Step 3a seeds `state.json`, write the dedup anchor below.

A `/megatask` per-issue run never asks: its `--auto` holds `plan`, so § Step 2a — unattended runs
instead, and the scan skips itself there anyway (`reason=milestone_mode`).

#### Step 2a — reusing an existing issue

```bash
jq -cn --arg url "<chosen url>" --argjson num <chosen number> \
   --arg wid "$(jq -r '.worktask_id // "unknown"' .context/state.json)" \
   --arg ts "$(date -u +%FT%TZ)" \
   '{version:1, url:$url, number:$num, created_run_index:-1, created_worktask_id:$wid,
     created_at:$ts, last_commented_run_index:-1}' > .context/gh-issue.json
```

Planning still runs, bound to the existing issue. `created_run_index: -1` is the "predates this
context" value `publish-pl-issue.sh` already uses for a recovered search hit, so Step A comments on
that issue instead of opening a second one.

#### Step 2a — unattended (`--auto` contains `plan`)

```bash
SCAN_BUF=$(mktemp "${TMPDIR:-/tmp}/corpflow-issue-scan.XXXXXX")
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/preflight-issue-scan.sh --goal "<task description>" < /dev/null > "$SCAN_BUF" || true
echo "SCAN_BUF=$SCAN_BUF"; grep -E '^(result|reason|candidates)=' "$SCAN_BUF"
```

The same scan with no prompt: stdin is `/dev/null`, there is no `AskUserQuestion`, and
`result=shown` does not stop the run. Step 3 proceeds as a new worktask; the reuse path is not
taken, and the exact-title auto-bind in `publish-pl-issue.sh` still applies. Keep the printed
`SCAN_BUF` path: the Step 3a `--record --candidates` call turns it into one
`preflight_issue_candidates` audit row, then deletes it.

##### Step 2a — unattended, what differs

- Leave `CORPFLOW_NONINTERACTIVE` unset. Set to `1`, it makes the scan skip itself, and the run
  records no candidates.
- Candidate titles and URLs arrive already path-scrubbed; when the scrub is unavailable the scan
  prints none and reports `reason=scrub_unavailable`. `--record` scrubs them again before the row
  reaches `audit.jsonl`.
- Without `plan` in `--auto`, including under `--auto=[finalization]`, the snippet and gate above
  apply unchanged.

#### Step 2a invariants

- The trailing `|| true` is required: the scan is non-blocking. No network/`gh`/auth/remote, an
  API error, a rate limit, a timeout, a malformed response, or zero hits each print
  `result=skipped`/`result=none` and Step 3 runs unchanged.
- **Advisory only**: the scan never links, comments, closes, or writes (no audit row either: the
  ledger does not exist yet, and the unattended row is Step 3a's write), and does not relax the
  exact-title auto-bind in `publish-pl-issue.sh` (`skills/gh-issue-dedup § Resolution order`).
- **Self-skips**: `CORPFLOW_NONINTERACTIVE=1`, `/megatask` (`MILESTONE_MODE=1` or a
  `workspace.json`), and `--emergency` (`INCIDENT_MODE=1`); `PREFLIGHT_ISSUE_SCAN=0` disables it
  outright. `--auto` with `plan` is not a skip: it runs unattended. A `.context/` already carrying
  a `gh-issue.json` anchor is a resume: `reason=already_anchored`, and the anchor answers.

### Steps 3–3a — Context folders and state.json seed

3. `mkdir -p .context/designs .context/images .context/errors .context/logs`
3a. Seed `.context/state.json` by running `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/seed-state.sh`, the seed's only
definition: next free planning index, `facts.goal` escaped and capped at 240 chars, the
unconditional `metadata.workspace_path` (`initialization-patterns.md § Seeded workspace_path`), and
the atomic write. It resolves `.context/` inside this worktree only, never from cwd. Resulting
shape: `handoff-protocol.md#pl0-seed`; `--help` lists flags and exit codes.

#### Step 3a snippet — seed the ledger

```bash
set -- --worktask-id "<slug>" --goal "<task description; the issue title under /megatask>"
PLATFORM="<the --platform value, verbatim; empty when not given>"
[ -n "$PLATFORM" ] && set -- "$@" --platform "$PLATFORM"
seed_rc=0
seed_out=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/seed-state.sh "$@") || seed_rc=$?
printf '%s\nseed_rc=%s\n' "$seed_out" "$seed_rc"
if [ "$seed_rc" -eq 3 ]; then
  seed_state=$(printf '%s\n' "$seed_out" | sed -n 's/^state=//p')
  bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --state "$seed_state" --task-status PL0 in_progress
fi
```

#### Step 3a — the exit code decides

- **0**: seeded; continue to § Step 3a — record the autonomy preflight, then Step 3b.
- **3**: `state.json` already exists (a new run in an existing `.context/`); byte-unchanged, and the
  script has no overwrite path. The snippet has reopened PL0 so an interruption before Step 5
  cannot read the previous run's `completed` PL0 as this run's plan (§ Context-Interruption
  Recovery). A non-zero from that call is a ledger write failure: stop and report. Otherwise
  continue as for 0;
  `pl0-procedure.md § Step 4 — state.json reset` is the re-run writer.
- **4**: no `.context/` resolves inside this worktree; nothing written. Stop and report.
- **1 or 2**: write failure or usage error; nothing written. Stop and report, since there is no
  correct degraded mode.

#### Step 3a — `metadata.workspace_path` and `facts.goal`

- **`workspace_path`**: `seed-state.sh` stamps it on every run, not only under `/megatask`.
  `dv-tree-preflight.sh`, the § Workspace-root cross-check, and `agents/developer.md`'s path-prefix
  check all read it and each degrades to a silent pass when it is absent, so omitting it disables
  all three at once (`initialization-patterns.md § Seeded workspace_path`).
- **`facts.goal`**: the `--goal` value, which `seed-state.sh` escapes and caps. It is the issue
  title and `## Summary` source for `publish-pl-issue.sh`, and nothing on the PL state-patch path
  writes it. PM refines it later; the seed only guarantees it is never absent.

#### Step 3a — record the autonomy preflight

Right after the seed, and only when Step 2a-pre passed with a `result_json=` line. Otherwise record
nothing and delete any Step 2a buffer. Fill both paths from what those steps printed; leave
`SCAN_BUF` empty when Step 2a ran with its prompt or not at all.

```bash
PF_BUF="<path Step 2a-pre printed>"; SCAN_BUF="<path Step 2a printed, or empty>"
set -- --record "$PF_BUF" --context .context
[ -n "$SCAN_BUF" ] && set -- "$@" --candidates "$SCAN_BUF"
rec_rc=0
rec_out=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/autonomy-preflight.sh "$@") || rec_rc=$?
printf '%s\nrec_rc=%s\n' "$rec_out" "$rec_rc"
```

#### Step 3a — what the record writes

The call merges `metadata.preflight` into the ledger (`handoff-protocol.md § metadata.preflight`),
appends one `autonomy_preflight` audit row and, given `--candidates`, one
`preflight_issue_candidates` row (`{result, candidates:[{number,title,url,score}]}`, an empty list
allowed). It prints one `recorded=<what>` line per write and deletes both buffers on success.
`--record` takes no `--auto`, `--platform`, `--harness` or `--accept-absent` (exit 2): the buffer
already carries the result.

#### Step 3a — a failed record does not stop the run

Exit 1 means the buffer was refused (nothing written) or a write failed; the ledger merge runs
before either row, so the `recorded=` lines show what landed. Continue to Step 3b anyway: the
preflight already passed, and stopping here would be exactly the forced stop it exists to remove.
Run the continuation below in the same call, so the warn row and the buffer cleanup still happen.
With no `metadata.preflight` on the ledger, the backend `tool_missing` evidence rule, which excuses
a missing tool only when the preflight recorded it as accepted, reports that tool missing.

#### Step 3a — the failed-record continuation

```bash
# …continued: same call as the record snippet
if [ "$rec_rc" -ne 0 ]; then
  w=$(printf '%s\n' "$rec_out" | sed -n 's/^recorded=//p' | paste -sd, -)
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg rc "$rec_rc" --arg w "${w:-none}" \
    '{ts:$ts, actor:"orchestrator", action:"autonomy_preflight_record_failed", subject:"PL0",
      result:"warn", task_id:"PL0", metadata:{exit:$rc, recorded:$w}}' >> .context/logs/audit.jsonl
  rm -f -- "$PF_BUF" ${SCAN_BUF:+"$SCAN_BUF"}
fi
```

### Step 3b — Verify SubagentStop hook installed

3b. After the seed, verify `.claude/hooks/state-merge.sh` exists and is executable and that the
plugin's `plugin.json` registers the SubagentStop hook — the Layer 2 safety net that patches
state.json when agents skip self-patching (`initialization-patterns.md#hook-installation`).

   ```bash
   # $PLUGIN_ROOT per § Snippet preamble
   hook_src="$PLUGIN_ROOT/hooks/state-merge.sh"
   hook_dst=".claude/hooks/state-merge.sh"
   if [[ ! -x "$hook_dst" ]] && [[ -f "$hook_src" ]]; then
     mkdir -p .claude/hooks
     cp "$hook_src" "$hook_dst" && chmod +x "$hook_dst"
   fi
   ```

#### Step 3b regression guard

If neither the plugin-registered hook nor the project-local copy exists, warn without blocking:
`"⚠ state-merge.sh hook not installed — state.json will only be patched if agents self-merge
(Layer 1) or orchestrator Step 6.5 fires (Layer 3). Run hook-install.sh to fix."`

### Step 3c — Name the branch once (PL start)

3c. On every worktask, with no precondition (Conductor workspaces and manual `git checkout -b`
branches included): after the seed and before Step 4, run
`bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/branch-name.sh --goal "<concise imperative title>"`. This is the only
place a worktask branch is ever renamed (once-only rule, `skills/shared/git-conventions.md § Branch
Naming`); the planned ledger name may be refined once more without git mutation (§ Step A.4b).
Every outcome exits 0, so a naming problem never stops planning, and the script self-disables
under `/megatask` or `--emergency`. Its guard ladder has an "already conventional" no-op arm, so
run it on an already-named branch too: that is how the name is established as conventional.

#### Step 3c — the input is a title, not the task description

Derive the title from the request; never pass the request verbatim. A title is an imperative
phrase of ≤60 characters naming the thing changed and the change; the goal is slugified into a
48-character slug and the overflow is dropped silently (grammar and budget:
`git-conventions.md § Branch Naming`).

- good: `Replace in-house ZIP with upstream ZipArchive`
- bad: `Replace the in-house ZIP implementation in Sources/Archive/ with the upstream ZipArchive
  package, keeping the existing public API and updating the tests`

`BRANCH_NAME_PRINT=1 bash …/branch-name.sh --goal "<title>"` previews the name — renames nothing,
writes no audit row. Preview before the one rename-mode run; that is how a poor title is caught while
it is still free to change.

#### Step 3c — who decides conventionality

Never judge conventionality by eye: a name can look conventional after its type left
`BRANCH_TYPES`. The sole authority is `branch_is_conventional()` from
`skills/worktask/scripts/branch-lib.sh`, reachable as
`bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/branch-name.sh --check "<name>"`
(0 = conventional, 1 = not, 2 = internal fault).

#### Step 3c — host-session authorization

Invoking `/worktask` satisfies a host's "do not rename the current branch unless the user
explicitly tells you to" session rule (Conductor injects exactly that): never revert this step's
rename or suspend the pipeline to re-ask. That holds in worktrees too
(`skills/worktask/references/workspace-modes.md § Host session authorization`), where the local
branch is renamed as well, so `branch=` and `target_branch=` agree and the host's
branch↔workspace mapping moves with it.
`BRANCH_NAME_WORKTREE_RENAME=0` restores the defer-to-host behaviour (local name kept, only
`target_branch=` derived).

#### Step 3c — validate before stamping

Capture both stdout key=value lines: `target_branch=<name>` (the name the PR head should carry)
and the final `branch=<name>` (the local branch as it stands). Verify against
`^[A-Za-z0-9._/-]+$` before stamping, as defence in depth alongside the script's emission
validation and FN's re-validation (`agents/project-manager.md § Final FN steps`); a failing value
is stamped empty, never as-is. Stamp `state.json facts.branch` — the script never writes state.json
(`handoff-protocol.md § branch`). Both lines come back empty rather than carrying a name that fails
the predicate, so an empty stamp is the honest "no planned name" outcome (FN pushes plainly).

#### Step 3c — which of the two names gets stamped

   ```bash
   # A title (≤60 chars), never the raw task description: the 48-char slug budget
   # drops the overflow silently.
   out=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/branch-name.sh --goal "<concise imperative title>")
   local_branch=$(printf '%s\n' "$out" | sed -n 's/^branch=//p' | tail -n 1)
   target=$(printf '%s\n' "$out" | sed -n 's/^target_branch=//p' | tail -n 1)
   truncated=$(printf '%s\n' "$out" | sed -n 's/^slug_truncated=//p' | tail -n 1)

   # target_branch wins whenever the local name (a host's `<city>-v<n>`, say) is
   # unusable as a PR head.
   stamp="$local_branch"
   if [ -z "$stamp" ] || ! bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/branch-name.sh --check "$stamp"; then
     [ -n "$target" ] && stamp="$target"
   fi
   ```

#### Step 3c — post-check (non-blocking)

After stamping, assert the stamped value against the predicate. Reuse `$target`; never
re-invoke in rename mode (that writes a second audit row). `BRANCH_NAME_PRINT=1`, `--check`, and
`--print-target` write none:

   ```bash
   stamped=$(jq -r '.facts.branch // ""' .context/state.json)
   if [ -n "$stamped" ] && ! bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/branch-name.sh --check "$stamped"; then
     jq -cn --arg ts "$(date -u +%FT%TZ)" --arg a "$stamped" --arg d "$target" \
       '{ts:$ts, actor:"orchestrator", action:"branch_convention_check", subject:"PL0",
         result:"warn", metadata:{actual:$a, derived_target:$d}}' \
       >> .context/logs/audit.jsonl
   fi
   ```

#### Step 3c — post-check, the truncation row

`slug_truncated=1` appears only when the budget dropped content. Then append one row naming the input
length and the surviving slug — the evidence a human reads at the plan gate, and the
incumbent-quality signal § Step A.4b reads (`$title` is the `--goal` title; `slug` is the
post-`<type>/` remainder):

   ```bash
   if [ "$truncated" = "1" ]; then
     wid=$(jq -r '.worktask_id // "unknown"' .context/state.json)
     ri=$(jq -r '.run_index // 0' .context/state.json)
     jq -cn --arg ts "$(date -u +%FT%TZ)" --arg s "PL$ri" --arg t "$target" \
       --arg len "${#title}" --arg slug "${target#*/}" --arg dk "$wid:$ri:branch_slug_truncated" \
       '{ts:$ts, actor:"orchestrator", action:"branch_slug_truncated", subject:$s,
         result:"warn", task_id:"PL0",
         metadata:{input_len:$len, slug:$slug, target:$t,
                   origin_stage:"PL", dedupe_key:$dk}}' \
       >> .context/logs/audit.jsonl
   fi
   ```

#### Step 3c — post-check invariants

The post-check never blocks planning: a warning row and nothing else — no stop, no retry, no
rename (a rename here would break the once-only rule). The convention row names both the stamped
branch and the derived target, so the divergence is legible without re-deriving it. An empty
`facts.branch` is a documented outcome (detached HEAD, not a git repo), not a warning; an empty
`derived_target` means a guard arm short-circuited before derivation. A non-empty `derived_target`
there is a bug report: a conventional target existed and something stamped past it.

### Step 4 — attach PL0 metadata

4. The Step 3a seed already created `tasks.PL0`, so this step merges metadata rather than creating
the task (`--task-create` would hit the create op's idempotent early-exit and drop the payload
silently). `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-meta PL0 --set '{"stage":"PL","agent":"corpflow:product-manager","model":"<model>","effort":"<effort>","worktask_id":"<slug>","priority":"<priority>","plan_gate":"checkpoint","decision_gate":"user","fn_gate":"checkpoint","isolation":"worktree","workspace_path":"<resolved root>","description":"<task description>"}'`
— `metadata.agent` is always the fully-qualified `plugin:agent` form (`corpflow:`, `apple-developer:`, …).
`description` is a capped label, never the planner's input. `state-patch.sh` cuts a value over 240
chars to 239 plus "…" and prints `description_truncated=PL0:<length>` on stderr; Step 6 passes the
full statement.

#### Step 4 — PL0's model and effort

Resolve the pair the way every other stage row's is (`skills/shared/stage-codes.md § Model and
Effort Lookup`), never type it: `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/model-matrix.sh --resolve product-manager`
prints `<model>`, `<effort>` and the source, tab-separated; paste the first two into the payload.
It reads `state.models` first, then `CORPFLOW.md § Models` (project root, else user scope), then the matrix. No § Secure
overrides row names PL.

#### Step 4 — option-flag stamping

Merge these into the same payload. A flag that was not passed leaves its key absent, and every
reader treats an absent key as off.

| Key | Stamp only when | Read by |
|---|---|---|
| `with_design: true` | `--with-design` | PM, `pl0-procedure.md § Designer Invocation` |
| `no_gh_issue: true` | `--no-gh-issue` | `skills/worktask/SKILL.md § PL Issue Publish`, `publish-pl-issue.sh`, `mailbox.sh` |
| `embedded_commands` | Step 2 found any | the DV dispatch, `skills/worktask/SKILL.md` loop step 5a |

#### Step 4 — workspace_path stamping

`workspace_path` carries the Step 3a value and is stamped on every run beside `isolation`; PM
propagates it to every stage task. It tells a stage agent which tree it was assigned, a different
claim from the tree it resolved (`workspace-modes.md § Sibling-worktree
hazard`).

#### Step 4 — gate stamping

Gate defaults (`plan_gate: "checkpoint"`, `decision_gate: "user"`, `fn_gate: "checkpoint"`) stamp
unless a flag overrides. They are the carriers resume logic branches on (`resume.md § State → Action
Table`); `/megatask` sets them per issue through its flags and stamp (§ Step 4 — the /megatask
stamp).

| Alternate | Stamp only when | Notes |
|---|---|---|
| `plan_gate: "bypass"` | `--auto` contains `plan`, or `--emergency` | Emergency runs unattended from IR |
| `fn_gate: "bypass"` | `--auto` contains `finalization`, or `--emergency` | `--auto=[plan]` alone never stamps this (orthogonal carriers); enforced at SKILL.md loop step 4.9 |
| `decision_gate: "auto"` | `--auto` contains `decision` | `--emergency` leaves it `"user"` (no PL stage, carrier inert) |

#### Step 4 — the /megatask stamp

Under a per-issue `/megatask` run the dispatch prompt carries a `PL0.metadata` stamp
(`commands/megatask.md § Phase 2 loop · Step 3`). Overlay it on the payload above in the same
`--task-meta PL0` call, the stamp winning on every shared key. Its `workspace_path` is the absolute
worktree path, and its gates (`plan_gate: "bypass"`, `decision_gate: "auto"`, `fn_gate: "bypass"`)
match what `--auto=[plan,decision,finalization]` stamps, so no default gate lands on that PL0. The
stamp exists only in the prompt: megatask cannot write PL0 before Step 3a seeds the ledger.

#### Step 4 — decision_gate readers

`decision_gate` has two readers: the PM agent (returns questions in `open_questions[]` rather than
holding a gate round-trip — `skills/worktask/references/pl0-procedure.md § Plan-Gate Open-Question
Batching`) and Step A.4.

### Steps 5–8 — Dispatch PL, then present the plan

5. **PL0 → in_progress**: `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-status PL0 in_progress`
6. **Delegate**: `Agent({ subagent_type: "corpflow:product-manager", model: <PL0 model>, effort:
   <PL0 effort>, prompt: "<planning prompt>" })` — the pair Step 4 stamped on PL0, so a
   `CORPFLOW.md § Models` raise reaches PM (§ Step 6 — what PM computes). The prompt's minimum
   content is in § Step 6 — the planning prompt.
7. **PL0 → completed**: `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --task-status PL0 completed`
8. **Present the plan summary** (contents per § Plan gate checkpoint path), then continue to Phase 2.

#### Step 6 — the planning prompt

The prompt carries at least these 3 parts, in this order:

1. **The task description, word for word and uncapped.** Take it from the user's invocation, or
   from the issue body under `/megatask`. Never take it from `tasks.PL0.metadata.description`:
   that field is the capped label from Step 4, and a long statement loses its end there.
2. **The resolved flags and carriers.** These are the `--auto` array, the tier flags
   (`--secure`, `--full`, `--emergency`), `--priority`, `--platform`, `--accept-absent`, and the
   keys Step 4 stamped (the gates, `with_design`, `no_gh_issue`, `embedded_commands`).
3. **The workspace-root banner line.** This is `WORKSPACE_ROOT=<path>` as
   `workspace-root-banner.sh --task PL0` prints it (§ Banner injection).

#### Step 6 — what PM computes

PM computes the next free plan filename (`pl0-procedure.md § Plan File & Run Index Naming`:
glob+increment `.context/planning-0.md`, `planning-1.md`, …), writes it, assesses complexity, and
creates stage tasks with `metadata.agent` and `metadata.plan_file`. The seeded
`plan_file`/`run_index` are provisional — PM recomputes and is authoritative. Glob+increment
applies to a new run only: a plan-gate revision reuses the frozen index (§ Plan-revision
re-dispatch).

#### Step 6 — record dropped and added stages

When dynamic sizing omits any of the full 9-stage pipeline (`PL→AR→TL→DV→DR→QA→DC→FN→ST`), PM stamps
PL0's `metadata.skipped_stages` (`{stage, reason}` list) so `state.json` self-documents the drops;
a stage included beyond the tier default (AR0 at a low tier, TL0 at any tier) stamps the symmetric
`metadata.added_stages`, identical shape (`pl0-procedure.md § Dynamic Worktask Sizing (PL0 Stage)`).

## Phase 2: Execute Stages (proceeds automatically)

Phase 2 begins with the Auto-Decision Pre-Pass (Step A.4, no-op unless `decision_gate == "auto"` and
PL0 left open questions), then the Plan Gate Check (Step A.5): on `checkpoint` present the plan and
wait for approval before the stage loop; on `bypass` proceed directly.

### Step A.4 — Auto-Decision Pre-Pass (runs before Step A.5)

Read `tasks.PL0.metadata.decision_gate` (default `"user"`) and, from `facts.open_questions[]`, PL's
unresolved `sw-PL<N>-*` items — those whose `status` is not `"resolved"`
(`pl0-procedure.md § Plan-Gate Open-Question Batching`). Resolve each item's question text and
`options[]` from `planning-N.md#elicitation-sweep` exactly as § Step C.4 does; the stub carries
neither. No-op when `decision_gate == "user"` or no such item exists — fall through to
Step A.5. Otherwise, read `skills/worktask/references/auto-decision.md` and run it: the delegate
dispatch, the ledger merge, and the gate-summary presentation. § Escalation guard (BINDING) below
stays inline because every run reads it: Step C.2, Step C.0 and the FN gate apply it too.

#### Escalation guard (BINDING)

The delegate never auto-decides escalation-class questions: anything irreversible or
destructive (data deletion, force-push, external publication), scope-expanding beyond the task
description, security-posture-weakening, or spend-authorizing. Those return as `escalate` items. If
any exist, Step A.5 runs as a `checkpoint` gate for those items even under `plan_gate ==
"bypass"` — the user answers only the escalated questions, the batch amendment pass applies their
answers, then the bypass path resumes. Auto-decision never widens what runs unattended.

##### Escalation guard — escalate stops at every boundary

**Escalate always stops at any boundary; bypass records decision-class items only.** A stop is the
checkpoint-style render above, scoped to that boundary's escalate items: the user answers them,
§ Step C.5 records the answers, and the bypass path resumes. At the plan gate every lane keeps the
checkpoint stop (`/megatask` parks; § Plan gate bypass path — escalation exception). At a stage's own boundary
(§ Step C.0) or the FN gate, the first matching lane wins:

1. `/megatask` per-issue run (`PL0.metadata.megatask_group`): park, per § Escalation guard —
   unattended `/megatask` per-issue runs (PARK).
2. No reachable human (`CORPFLOW_NONINTERACTIVE=1`, or § Headless Dispatch): record each item and
   continue (§ Step C.5 — the unattended lanes). FN lists it atop the PR body, and the final
   message repeats it (§ Output Format).
3. Any other lane, including `--emergency`, `--auto=[finalization]` and a bypassed plan gate: stop.

##### Escalation guard — raise-only self-labels

A closing-sweep item arrives carrying its emitting stage's own `class`. At § Step C.2, strictly
before any auto-answer, join it with the orchestrator's own label on both axes — `class` and
`blocks_next_stage` — and carry the joined value forward, so no item reaches the delegate
un-reclassified. The escalation classes are the four enumerated directly above; this sub-heading
adds no second copy of them.

The join is over **labellers, never transports**: never an agent's artifact stub against its own
ledger stub. Those two copies have one author, so a disagreement is a defect —
`handoff-harness.sh check_sweep_ledger` fails the stage and the agent reconciles both.

The join itself, both axes, and why raise-only holds by construction rather than by a remembered
rule: `skills/shared/stage-contracts.md § Self-labels raise, never lower`.

##### Escalation guard — unattended `/megatask` per-issue runs (PARK)

Under a `/megatask` per-issue run (detected by `PL0.metadata.megatask_group`) there is no user to
stop for, so instead of holding the checkpoint, park the issue: write
`workspace.json.execution.status: "failed"` with `execution.reason: "parked_escalation"`, append an
`escalation_parked` audit row (`subject:"PL<N>"`, `metadata.escalated: [<questions>]`), and stop
without dispatching any stage. Parking rides the monitor's failure path
(`hooks/megatask-monitor.sh` settles only `completed`/`failed`): the track is freed, dependents stay
`blocked`, and the batch summary lists the issue with its unanswered questions for a follow-up
interactive `/worktask`. A parked permission need takes this same path; its escalated list holds
each need's redacted `{tool, command_head, truncated}`, never the command (§ Boundary permission
prompt — only the user answers).

### Step A.4b — Refine the branch target (after A.4, before A.5)

The Step 3c name predates the plan. Now that the approved plan carries its own `title:`, re-derive
the planned remote target from it — at most once per run, only while no commit exists to
disagree. This step performs no git mutation: it rewrites `facts.branch` on the ledger and
nothing else, leaving the once-only rename rule unaffected (`git-conventions.md § Once-only
rule`). Placed here so the Step A.5 summary carries the final name before anything is published.

#### Step A.4b snippet — invoke the helper, non-blocking

    # A missing helper exits 127 with empty output, which reads as "no refinement".
    ref_out=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/refine-branch-target.sh) || true
    ledger_branch=$(printf '%s\n' "$ref_out" | sed -n 's/^ledger_branch=//p' | tail -n 1)

#### Step A.4b invariants

- The trailing `|| true` is required: non-blocking, like the Step A publish helper. A
  helper failure, a missing helper (exit 127) included, does not fail the worktask.
- Self-guarding: it scans `audit.jsonl` for a prior successful `branch_target_refined` row at
  this run index, so a duplicate invocation after a resume is a `noop`, never a second refinement.
- Exactly one audit row per invocation whenever `jq` is available; the `jq_unavailable` arm alone
  writes none, announcing itself on stdout (matching `branch-lib.sh audit_fn`).
- The row is `branch_target_refined`, `ok` or `noop` with a reason from its closed set. A `noop` is
  normal: the helper declines when a commit exists, an upstream is configured, the plan carries no
  `title:`, the candidate is unusable or unchanged, or it would truncate while the incumbent has no
  recorded truncation.

#### Step A.4b — the returned value

- `ledger_branch` is the value on the ledger after this step, refined or not. Use it in the Step
  A.5 summary rather than re-reading `state.json`.
- FN's re-validation of `facts.branch` against `^[A-Za-z0-9._/-]+$` is unchanged and still runs — the
  refined value passes the identical check because FN reads the ledger.

### Step A.5 — Plan Gate Check (after A.4, before Step A publish)

Read `tasks.PL0.metadata.plan_gate` (default `"checkpoint"`). Resolve the run index `N` from
`state.json.run_index` (default `0`).

#### Plan gate checkpoint path

**If `plan_gate == "checkpoint"`** (default):
1. Read `state.json.plan_file` to locate the plan; accept either shape (`handoff-protocol.md §
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
  `deferred` row. Sanitiser rules: `skills/worktask/SKILL.md § PL Issue Publish`.
- One `.context/` ↔ one GitHub issue: a later run resolves the run-independent
  `.context/gh-issue.json` anchor and comments instead of duplicating (`skills/gh-issue-dedup`).
- Run it here even though SKILL.md also describes it.

#### After Step A — run the stage loop

Execute the loop from `skills/worktask/SKILL.md § Orchestrator Execution Loop`. Before the FN
`Agent()` delegation apply the FN gate check (stop on `checkpoint`, proceed on `bypass`) —
`skills/worktask/SKILL.md § FN Gate`.

##### After Step A — scripts the loop runs directly

The loop body lives in the skill, but these four run under this file's grants, so they are named
here too: a grant invoked only in the skill reads as unused to an audit.

```bash
# Assigned root for a row, after any stream re-pin — SKILL.md § Step 4.8
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/workspace-root-banner.sh --task "<TASK_ID>"
# Land a producer's artifacts — SKILL.md § Step 4.7a
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/land-artifacts.sh --producer "<TASK_ID>"
# Re-land what a row consumes — SKILL.md § Step 4.8
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/land-artifacts.sh --consumer "<TASK_ID>"
# The tree's landed set — SKILL.md § Step 6.5a3
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/land-artifacts.sh --list-landed --tree "$_orch_root"
```

A refused landing is reported, never worked around: SKILL.md § Step 6.5d.

#### Workspace-root cross-check

Conductor-managed sessions spawn the orchestrator inside a workspace clone whose `pwd` differs from
the canonical plugin source repo. Before every `Agent()` call in the stage loop, verify that the
working tree matches the task's declared workspace, and inject the resolved root into the stage
prompt so the subagent targets the right directory.

##### Cross-check snippet

```bash
# Runs in the orchestrator turn, not in the subagent
_orch_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
_task_root=$(jq -r '.metadata.workspace_path // empty' .context/state.json)
# Unset is a defect, not a mode: defaulting it to $_orch_root compares a value to itself,
# so the check passes unconditionally and an unstamped ledger reads as clean — which also
# leaves dv-tree-preflight.sh and developer.md's path-prefix check inert.
if [ -z "$_task_root" ]; then
  echo "⚠ state.json has no .metadata.workspace_path — the assigned-tree guards are ALL inert. Stamp it with a --ledger-meta patch." >&2
  # Write audit row `workspace_path_unstamped` and stop; do not call Agent()
  exit 1
fi
if [ "$_orch_root" != "$_task_root" ]; then
  echo "⚠ cwd mismatch: orchestrator is at $_orch_root but task.metadata.workspace_path is $_task_root. Aborting delegation until resolved." >&2
  # Write audit row and stop; do not call Agent()
  exit 1
fi
```

##### Banner injection

The task's `WORKSPACE_ROOT=` line opens section [7] of every stage prompt (the suffix, per the
cache-prefix spec) so the subagent knows which directory to target. It arrives through the composer,
which emits `workspace-root-banner.sh`'s stdout as [7]'s first line; do not append it again. The
value is `tasks.<ID>.metadata.workspace_path` when set, else the orchestrator root — never the
ledger-level path, which names the orchestrator's tree and hides a DV stream's own:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/brief-compose.sh "<TASK_ID>" --orch-root "$_orch_root"
# stdout is the whole brief, [7] opening with the banner line; exit 1 or 2 means do not call Agent()
```

Failure mode prevented: `workspace-modes.md § Conductor Workspace Topology`.

#### Post-delegation state.json enforcement

After every `Agent()` return (the completed stage result — for a background subagent that is the
completion notification, not the launch acknowledgement), before Step 7 settles the row:
re-read `.context/state.json`; if `tasks.<ID>` does not already carry the artifact's
`handoff.verdict` and the status it maps to (`handoff-protocol.md § tasks — verdict → status`), run
   ```bash
   CLAUDE_ARTIFACT_PATH=".context/<artifact>-N.md" \
   CLAUDE_TASK_METADATA_STAGE="<CODE>" \
   STATE_MERGE_VIA=step6_5 \
   bash .claude/hooks/state-merge.sh
   ```

##### Layer-3 stamp and F3 fallback

`STATE_MERGE_VIA=step6_5` stamps `tasks.<ID>.completed_via=step6_5` so this synchronous Layer-3 path
is distinguishable from the SubagentStop-hook Layer-2 default (`hook`). Then re-read; if the row
still does not match, apply the F3 fallback: it stamps the verdict-mapped status (plus
`metadata.gate_from_stage` when that status is `pending`) with `completed_via: "f3"`, and writes
nothing for an absent handoff or an unmapped verdict — this covers environments where the
SubagentStop hook never fired. Full three-layer logic: `skills/worktask/SKILL.md § Orchestrator Execution Loop` Step 6.5.

### Step B — AR-reference check at DV completion

The AR-reference arm fires only when `.context/state.json` has a `tasks.AR0` entry (AR is optional —
`skills/estimation-methodology/SKILL.md § Stage Inclusion Criteria`). The invocation itself is the
§ Step B.1 call every stage makes. It runs once per DV row, on that row's own artifact, as the row
completes; DR0 is dispatched only after every DV row has passed it:

```bash
STRICT_FLAG=""
[ "${CORPFLOW_AR_REF_STRICT:-0}" = "1" ] && STRICT_FLAG="--strict"
# The completing row names its artifact; a stream suffix cannot be composed from N.
DEV_ARTIFACT=$(jq -r --arg id "$TASK_ID" \
  '.tasks[$id] | .artifact // .metadata.artifact // empty' .context/state.json)
# shellcheck disable=SC2086
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/handoff-harness.sh --validate-frontmatter "$DEV_ARTIFACT" \
  --state .context/state.json $STRICT_FLAG $LEGACY_TE_FLAG
```

#### Step B rollout and opt-in

**Warn-only by default.** With no opt-in the harness emits `warn:` lines and exits 0. Record each as
an audit row and carry it into the DR dispatch prompt so DR checks the linkage; a warning is not a
`missing_input` block and never stops the transition.

```json
{"ts":"<ISO>","actor":"orchestrator","action":"ar_ref_check","subject":"DV<k>","result":"warn"}
```

##### Step B — what the sweep checks do to this rollout

Warn-only covers the AR-reference check alone. The same invocation also runs the three
closing-sweep checks (stub shape, `ref` anchor resolution, ledger parity), which hard-fail
regardless of `--strict` (`skills/shared/stage-contracts.md § Closing Elicitation Sweep`). A non-zero exit here is therefore
not necessarily an AR-reference failure; a sweep failure blocks the transition per § Step B.1 — on
failure, and its `fail:` line names a `sw-` id.

**Opt-in — `CORPFLOW_AR_REF_STRICT=1`.** The orchestrator passes `--strict`; violations become
`fail:` lines with exit 1 and block the DR dispatch until DV fixes the reference. The inverse guard
(an architecture reference with no `tasks.AR0` entry) warns in both modes and never fails.

##### Step B — the legacy tests_executed opt-in

```bash
LEGACY_TE_FLAG=""
[ "${CORPFLOW_LEGACY_TESTS_EXECUTED:-0}" = "1" ] && LEGACY_TE_FLAG="--legacy-tests-executed"
```

**`CORPFLOW_LEGACY_TESTS_EXECUTED=1`** makes the orchestrator pass `--legacy-tests-executed`, so an
artifact written before per-runner entries (a legacy scalar count) validates under the old integer
rules with one deprecation `warn:`. Use it only to land in-flight legacy artifacts; it never relaxes
a list. Without it a scalar `tests_executed` fails and routes per § Step B.1 — on failure.

### Step B.1 — Sweep checks at every stage completion

The harness is not a DV-only tool. After any stage `<CODE><N>` lands its `completed` patch (loop
step 6.5) and before § Step C.0 renders its blocking items or the next stage is dispatched, run:

```bash
ART=$(jq -r --arg id "<CODE><N>" '.tasks[$id].artifact // empty' .context/state.json)
# shellcheck disable=SC2086
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/handoff-harness.sh --validate-frontmatter "$ART" --state .context/state.json \
  $LEGACY_TE_FLAG
```

`$STRICT_FLAG` from § Step B may be appended; it affects only the AR-reference arm, which fires for DV
alone. `$LEGACY_TE_FLAG` (§ Step B — the legacy tests_executed opt-in) affects only the
`tests_executed` arm of DV and QA. For DV this is the § Step B invocation — run it once, not
twice. An artifact whose `open_questions` is the empty array passes untouched; any item in it must
be a full sweep stub.

#### Step B.1 — on failure

Exit 0 → append `{"action":"sweep_check","subject":"<CODE><N>","result":"ok"}` and continue to
§ Step C.0.

**Any non-zero exit** → append the same row with `result:"fail"` and every `fail:` line as
`reason`, then treat it as a `missing_input` contract violation on `<CODE><N>`: skip Step C.0,
dispatch no next stage, and re-dispatch the stage with the `fail:` lines verbatim so it writes what
it owes. There is no advisory tier here — the unreadable-ledger case fails too.

##### Step B.1 — the routing default, and why it is a default

The default is the rule, not a fallback: a line shape absent from the routing table routes like
every row in it, so no real defect is left without a branch to take.

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

### Step C — Closing-sweep collection and render (loop step 4.9)

Step C is to the FN gate what Step A.4 is to the plan gate: it resolves questions, it approves
nothing, and every path out of it falls through to the gate's own approve/reject call. Contract:
`skills/shared/stage-contracts.md § Closing Elicitation Sweep`.

It fires at two points, selected per item by `blocks_next_stage`, never by stage:

- **C.0a** runs first at every stage boundary except PL/FN/ST/IR, resolving that stage's
  blocking `decision` items through a sub-agent so the run does not stop for them at all.
- **C.0** runs at every stage boundary, immediately after that stage's `completed` patch and
  before the next stage is dispatched, over whatever blocking items C.0a did not settle.
- **C.1–C.5** run once, immediately before the FN `Agent()` delegation, over everything else.

#### Step C.0a — resolve blocking items instead of asking (loop step 4.9, first)

Contract: `skills/shared/stage-contracts.md § Blocking items are resolved, not asked`.

After any stage `<CODE><N>` completes, and before § Step C.0, collect the items it just wrote
that satisfy all four:

1. `<CODE>` ∉ {PL, FN, ST, IR} — the four exception stages keep their own surfacing
   (`stage-contracts.md § Exceptions — PL, FN, ST, IR`), so there is nothing here to unblock.
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

Since CC 2.1.292 the `Agent` tool takes an `effort` parameter, so the computed tier reaches an
in-process stage agent directly. `skills/worktask/scripts/effort-route.sh` still decides the
surface: in-process with `Agent({ effort })` by default; headless through
`skills/worktask/scripts/headless-dispatch.sh` only when the operator sets
`CORPFLOW_HEADLESS_ROUTE=on`. Both carriers outrank the agent's own `effort:` frontmatter
(probed at 2.1.292). The audit row's `effort_transport` names the surface:

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
expertise answering the question for a guess. Pass the tier on `Agent({ effort })` (2.1.292),
never through prompt text: a tier asked for in prose is not applied.

##### Step C.0a — what the prompt carries

Paths, not inlined content — the § Step A.4 convention. Resolve artifact filenames through
`handoff-protocol.md #stage-artifact-map`; build no second mapping. The context tiers are
enumerated once, in `stage-contracts.md § What the resolver is given`, and are not restated here.

The delegate answers each item default-biased — deviate from the stage's own `recommended` entry
only with stated evidence — and returns one entry per item plus any it declines. It declares its
full reads through `deep_reads` (exempt from the B4 tripwire, per that section) and does not run
`state-patch.sh`: the stage is already `completed`, so the orchestrator owns every write, exactly
as at Step A.4.

##### Step C.0a — record, then fall through

4. The orchestrator merges each answer through the § Step C.5 write — the whole stub, marked
   `(auto-decided)`. Only after `state-patch.sh` exits 0 may `SendMessage` relay it; never relay
   first (`stage-contracts.md § A user decision is accepted only from the ledger`). On a non-zero
   exit relay nothing (§ Error Handling). It then appends one `auto_decision_resolved` row (`subject:"<CODE><N>"`,
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

A task parked with `blocked_on.kind == "permission"` (`skills/worktask/SKILL.md § Step 6.5a4`) has
no `class` and never enters `facts.open_questions[]`, so neither C.0a nor C.0 sees it. Once C.0 has
run and every ready stage is dispatched, `permission-park.sh batch` renders every parked need — one
AskUserQuestion call per `payloads[]` entry, so a single call for up to four needs — each offering
"grant and continue" and "run it yourself". The `! <command>` line to enter sits in the question
text inside a fenced block. A need with `truncated: true` gets no such line; its question points the
user at Claude Code's denial notice or `/permissions` recent denials. It never merges into a C.0
render. Answer handling, including the wait for the user's own run, and the step-only resume:
`skills/worktask/SKILL.md § Step 7a`.

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

A task parked on any other `blocked_on` kind (`skills/worktask/SKILL.md § Step 6.5a3`) is rendered
at the same boundary by `blocked-on-dispatch.sh batch`, as a `user_action` need: a fixed lead line
with the stage's detail fenced as data, a `!` line only on a native `user_action` whose command was
not cut, and the options "done" and "stop here". A `user_decision` is the exception: it is asked
with the stage's own question and options, and the stage is resumed with the hook row's `ud-` id.
Its `payloads[]` are asked in the same round as the permission ones, only the user answers them
under any gate setting, and a `/megatask` per-issue run parks them the same way. Answers and
resume: `skills/worktask/references/step-7a-arms.md § Step 7a — the typed-need answers`.

#### Step C.1 — collect everything not already answered

1. **C.1 — Collect.** Read `facts.open_questions[]` unioned with the eviction spill (below) and
   keep the items whose `status` is not `"resolved"`. That status test is the whole filter: an item
   already answered at its own boundary (C.0) or at the plan gate is resolved, so it is excluded by
   the same rule that excludes PL's. Do **not** filter on stage — under `blocks_next_stage` any
   stage can be answered at its own boundary. Derive the stage from the item id, whose
   `sw-<TASK_ID>-<n>` shape is pinned by the schema, for grouping; an explicit `stage` field
   takes precedence when present, but it is optional and absent from every template, so nothing
   may depend on it. Resolve each item's `ref` anchor to its full `options[]`
   body in the emitting stage's artifact.

##### Step C.1 — the collection is ledger ∪ spill

The ledger is not the whole record. `state-patch.sh` clamps `facts.open_questions[]` to the newest
four per task and appends every evicted item to `.context/open-questions-<run_index>.jsonl`
(`stage-contracts.md § Ledger bounds — the overflow spill`), so an item reachable only through
the spill is one this gate would otherwise never render, silently.

###### Step C.1 — how the two sources are unioned

Union both sources by `.id`, with the ledger winning on conflict: a spill line is a snapshot
taken at eviction time and is necessarily staler than an item the ledger later resolved. A missing
spill file is the empty set. A spill that exists but cannot be parsed is a failure, never an
empty set, or this gate goes quiet in exactly the case it exists for. `handoff-harness.sh` checks parity against the same union.

###### Step C.1 — the decisions spill is a different reader

`.context/decisions-<run_index>.jsonl` is not read here: this gate renders questions. Anything
asking what this run decided uses
`bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --read-decisions`, which returns
`facts.decisions[] ∪ spill` under the same union rule; `facts.decisions[]` alone under-reports once
one task records more than eight.

##### Step C.1 — the artifact fallback and its warning

Both machine-readable transports — `handoff.open_questions[]` and `facts.open_questions[]` — can
still under-report, so count what the artifacts claim. Every `.context/*-N.md` carries a
`## elicitation-sweep` section and its frontmatter carries the stubs. When the collected count is
below the number of sweep stubs on disk, render the collected items and warn, naming the shortfall
and the missing ids:

```
warn: FN gate collected 9 sweep items; 11 stubs exist on disk (missing: sw-DV1-2, sw-DR0-1)
```

The warning does not block the gate or change what is rendered; it names a transport's loss
instead of leaving a count nobody compares. Read the stubs from artifact frontmatter, never by
re-parsing bodies.

#### Step C.2 — classify before anything answers

2. **C.2 — Classify.** Apply § Escalation guard — raise-only self-labels to every collected item.
   Strictly before C.3.

#### Step C stamps no approval carrier

As at Step A.4: answering a sweep item settles content and does not approve finalization. Nothing
here writes an approval carrier, and the gate's own `AskUserQuestion` still fires last and
unmodified.

#### Step C.3–C.4 — auto-answer, then render

3. **C.3 — Auto-answer.** Only when `decision_gate == "auto"`: resolve the
   `effective_class == "decision"` items on the § Step C.0a rule — each item's own emitting
   stage's agent and model, at `effort_for_resolver` of that stage's ledger effort — grouping the
   batch by originating stage and issuing one dispatch per group; C.3 and C.0a share one resolver
   contract. Audit `auto_decision_dispatched` →
   `auto_decision_resolved`, `subject:"FN<N>"`, carrying the same effort fields C.0a records. A
   stage row with no `metadata.effort` is skipped exactly as at C.0a (`resolver_skipped`,
   `reason: "effort_unstamped"`) and its items render at C.4.

##### Step C.3 — why Step A.4 is not folded in

A.4 answers PL's items at the plan gate. PL is an exception stage whose boundary is that gate,
and under `checkpoint` a user is already present, so it keeps its own PM-on-fable dispatch rather
than joining the resolver contract.

##### Step C.4 — where the question text comes from

4. **C.4 — Render.** Present the remaining items through `AskUserQuestion`, grouped by originating
   stage, in calls of at most 4 questions (the tool's per-call ceiling). The question text comes
   from the resolved `ref` anchor body, not from the stub — the stub carries no `summary`, and
   `handoff-harness.sh check_sweep_ref_anchor` guarantees that anchor exists. Options are
   `options[]` with the `recommended: true` entry marked, shown with the `rationale`. These calls
   precede the gate's approve/reject call and never merge into it: a merged call overflows at four-plus items and entangles sweep answers with the
   gate's reject/resume path. Each question's `header` is the item's `id` (`sw-<TASK_ID>-<n>`), so
   the user-decision hook scopes the recorded answer to the emitting task
   (`hooks/references/user-decision-ledger.md § Scope ladder`).

#### Step C.5 — record, and the unattended lanes

5. **C.5 — Record.** Write each answer back into the item itself:
   `facts.open_questions[].status = "resolved"` and `facts.open_questions[].resolution = "<answer>"`,
   plus a `sweep_resolved` audit row whose subject is the boundary that rendered it — `FN<N>` from
   C.1–C.5, `<CODE><N>` from C.0. The union refuses a later downgrade of either field, so recording
   once is enough. Answers do **not** go to `facts.decisions[]`
   (`skills/shared/stage-contracts.md § Closing Elicitation Sweep` says why).

##### Step C.5 — the write-back is a whole stub

The write goes through `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --facts`
as the complete item — `id`, `class`, `ref` and `blocks_next_stage` alongside `status` and
`resolution` — never as `{id, status, resolution}`. The union replaces the incumbent object for
that id, so a partial item would drop the very anchor C.4 resolves its question text from;
`--facts` rejects one by name.

Where C.2 raised either axis, write the raised value to both transports — the ledger stub
here, and the emitting stage's artifact frontmatter stub. The two copies have one author and
`check_sweep_ledger` refuses a divergence between them, so a ledger-only write leaves the next
`--validate-frontmatter` failing on a value this step itself created.

##### Step C.5 — the unattended lanes

Recording never stops; only prompting does. Under `fn_gate: "bypass"` or any bypassed gate, skip C.4
for effective-`decision` items and audit `sweep_recorded` for them. Effective-`escalate` items take
the lane § Escalation guard — escalate stops at every boundary picks. A stop renders them at C.4 and
records the answers here. A `/megatask` per-issue run parks the issue exactly as § Escalation
guard — unattended `/megatask` per-issue runs (PARK) specifies. Only a lane with no reachable human
records them unanswered: one `sweep_escalation_unprompted` audit row per item, with
`metadata: {id, stage, ref}`, and the run continues. Every one of those audit subjects is
the rendering boundary, `<CODE><N>` — `FN<N>` for a batched item, the emitting stage's own id for a
blocking one. Full carrier table: `skills/shared/stage-contracts.md § Unattended fallbacks`.

## Phase 3: Post-Worktask Self-Improvement

After the loop exits (ST completed), run `skills/worktask/SKILL.md § Post-Worktask
Self-Improvement`. A `/megatask` per-issue run skips this phase: nobody is there to check the
boxes, so the run ends at ST and any `.context/learnings.md` stays in the worktree for review.

1. If `.context/learnings.md` is absent → worktask done, terminate.
2. If present → display it and stop until the user checks the boxes they approve
   (`- [ ]` → `- [x]`).
3. On the user's approval, re-read `learnings.md` and route each checked item by its
   `Enforcement:` form: `judgement` → `corpflow:prompt-engineer`, `mechanical` →
   `corpflow:workflow-engineer`. Each applies per its `§ Self-Improvement Patch Application`.
4. Each applied proposal becomes its own commit (rollback-safe via `git revert <sha>`), with a
   `version:` bump only on a target with frontmatter. Routing and bump rule:
   `skills/self-improvement/SKILL.md § Hand-off to the applying agent`.

### Phase 3 key invariants

- Never auto-apply or auto-check: the user checks the boxes and signals approval.
- Each checked item goes to one agent only. An item with no valid `Enforcement:` value (missing,
  or other than `mechanical` or `judgement`) is not applied; count it in `skipped_count` and name
  it to the user.
- Proposals are scoped to agents/skills/commands that actually participated in this worktask's
  context (`skills/self-improvement/SKILL.md § Step 4`).
- Post-ST audit entry in `.context/logs/audit.jsonl` records `applied_count` and `skipped_count`.

## Embedded Command Detection

Slash commands in the task description (e.g. `/skill-creator`,
`/apple-developer:fix-refactor src/Views/SettingsView.swift`) are embedded commands, executed
during the appropriate worktask stage.

### Detection and execution

1. Scan the description for `/<plugin:command>` / `/<command>`; match against the Skill tool's
   available skills.
2. Store them in `metadata.embedded_commands` on PL0 and the remaining text as the worktask task,
   preserving the arguments; pass the context to PL0 so the product-manager plans around it.
3. In the loop, a DV task whose PL0 has `metadata.embedded_commands` gets a prompt including
   "Execute embedded command(s) via the Skill tool: `<command>` with args: `<args>`", and the DV
   agent invokes `Skill({skill: "<command>", args: "<args>"})` as part of its implementation work.

Example: `/worktask /skill-creator deep analyze /path/to/source` → task
`"deep analyze /path/to/source"`, `metadata.embedded_commands: "skill-creator"`, DV prompt carrying
`Skill('skill-creator', args='deep analyze /path/to/source')`.

### Leading stacked skills

When the user stacks slash commands (`/worktask /skill-a do XYZ`), Claude Code loads up to 5
leading skills before the turn runs, so the embedded command's instructions may already be in
context at PL0. Extraction is unchanged and the DV-stage `Skill()` invocation is still required: it
is the execution trigger, not a context load, and re-invoking a loaded skill adds no duplicate.

### Error Handling

An embedded command that fails never falls back silently to generic DV work: the user asked for
that command, so the DV stage records the failure and escalates.

| Failure | Detection | Required Behavior |
|---------|-----------|-------------------|
| Skill name not resolvable | `Skill()` returns "skill not found" | Write `.context/errors/developer.md` entry with `Classification: missing_input`; escalate to TL (or PL if no TL0) |
| Skill execution errors mid-run | Skill tool returns non-success | `retry_count++`, append entry to `.context/errors/developer.md`; if `retry_count == 3`, set `error_escalated_to: "TL"` (or `"PL"` if no TL0) |
| Skill args malformed | Skill rejects at parse | Classification `ambiguous_requirements`; escalate to PL (requires planning revision) |
| Skill produces no artifact expected by downstream stage | stage-contract validation fails | Classification `missing_input`; escalate to the stage whose contract was violated |

#### Prohibited fallback and escalation target

On Skill failure the DV agent halts, appends the entry the table above names to
`.context/errors/developer.md` (its `retry_count` and, at the ceiling, `error_escalated_to` go on
the DV task's ledger row as for any retry), and returns without marking DV complete. Escalation
target: TL0 if it exists (retry, split the work, or revise approach), otherwise PL, which may add
TL0, revise the embedded command choice, or remove the embedding.

## Headless Dispatch (external runners)

External orchestrators (CI, cron, the user's shell) can invoke a single stage via
`claude -p --agent <plugin:agent> …` (`skills/worktask/scripts/headless-dispatch.sh`) instead of
the in-process `Agent()` path — `claude agents run` is not a subcommand. PL0 populates the
optional dispatch fields in `skills/shared/state-ledger.md § Dispatch metadata`, and the runner
builds its flags from them. The runner recipe, the required `external_dispatch` audit line and
the permission-mode caveats: `skills/agent-coordination/references/headless-dispatch.md`.
