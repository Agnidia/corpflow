<!-- TEMPLATE. Copy to the root of an integrating plugin as CORPFLOW.md and replace every
<PLACEHOLDER>. Normative contract: corpflow skills/cross-plugin-handoff/references/plugin-contract.md.
Keep it one self-contained file; splitting it into references/ rebuilds the coupling it replaced.
Never add a `## Routing` or `## Models` heading — reserved for a *user project* root or
user-scope (~/.claude) CORPFLOW.md (override template: corpflow templates/PROJECT-CORPFLOW.md). -->

# corpflow Integration — <PLUGIN>

The only file in <PLUGIN> that knows corpflow exists — delete it and the plugin is standalone.
Nothing in `agents/`, `commands/`, `skills/`, or `hooks/` may reference corpflow.
Dispatch names <PLUGIN>'s loaded install root in every prompt: resolve paths under it, never search.

## Are we in a worktask?

`.context/state.json` exists → yes, otherwise every rule below is inert. Read it first: current
stage, `run_index`, plan file path, and `metadata.*` for the dispatched task.

## Pipeline

Default run: `PL→AR→TL→DV→DR→QA→DC→FN→ST`; `--secure` adds **SR** and **RE**. Emergency runs
`IR→DV→DR→QA→RE→FN` and skips both gates. PL0 may drop AR, TL, or DC; read `state.json`.

### Stages <PLUGIN> works in

| Stage | <PLUGIN> agent | Handoff data |
|---|---|---|
| AR (Architecture) | `<architect-agent>` | planning context + platform constraints — **consultation only**, corpflow retains the stage |
| DV (Development) | `<router-agent>`, `<specialist-agents>` | planning + architecture context |
| DR (Developer Review) | `<code-fixer-agent>` | `metadata.gate_blockers[]` + minimal-diff remediation — **consultation only**, corpflow retains the stage and writes the artifact |
| SR (Security) | `<security-auditor-agent>` | development context + <PLATFORM> security checklist — **consultation only**, corpflow retains the stage and writes the artifact |
| QA (Quality) | `<test-generator-agent>` | development context + test requirements — **consultation only**, corpflow retains the stage and writes the artifact |
| DV-support | `<support-agents>` | scoped findings returned to the parent DV agent, which owns the artifact |

#### Who owns the artifact

**DV is the only stage ownership transfers for.** Read your DV row's `agent`: a `<PLUGIN>:` id means you own
its `metadata.artifact`, patch the ledger by row id, and provide validated frontmatter. If routed via
`corpflow:developer`, it owns the artifact; return implementation plus a ≤500-token summary. Every
other stage is **consultation** — corpflow writes its artifact and ledger entry. DV-support writes
only under `.context/logs/` and never patches.

## Evidence declaration

| Field | Value |
|---|---|
| `requires_screenshots` default | `<true\|false>` |
| Build Evidence adapter | `<adapter>` |
| Error file | `.context/errors/<agent-basename>.md` |

<EVIDENCE-NOTES: what counts as Build Evidence on this platform, and what does not. For UI platforms,
state that statically produced renders do not satisfy DV exit when `metadata.ui_visual_check: true`.>

## Build and test

- Build and test **only** through `/<PLUGIN>:build-test`; never invoke the toolchain directly.
- Compile-only: `--no-test` is classified `build_only` and allowed at every stage. `--build-only` is
  not a flag; it classifies as a full test run and is denied.
- DV runs scoped tests; QA alone runs the full suite; SR/DR/RE run none. The dispatch brief gives the
  test mode and selector. DV runs touched tests plus `metadata.always_required_tests`.
- If denied and `--no-test` does not fit, record `requests_test_evidence: <what and why>` or return
  `verdict: blocked`. Never reach for the toolchain.

## Worktree isolation (DV)

You run in an isolated git worktree; `task.metadata.workspace_path` is the tree you were assigned.

- Check `git rev-parse --show-toplevel` before each write batch because a stage can move. On mismatch,
  return `verdict: blocked` with both paths; do not enter another worktree or write.
- Never create or move worktrees. Writes outside your tree are never yours — report, do not make.
- Record it as `worktree: true` in the DV frontmatter. Absent or false is a hard DR fail
  (`worktree_isolation_violation`).
- Screenshots go to `screenshots-<TASK_ID>.md`; pass that task id as `--task-id` to each capture script.
  Never use `state.json facts.screenshots`: its last-writer-wins merge drops other streams.

## Artifacts

Write to `.context/` and, in DV, the assigned source paths inside your worktree. `<N>` is `run_index`.
The frontmatter is the contract; errors go to `.context/errors/<agent-basename>.md`.

| Stage | Artifact |
|---|---|
| AR | `.context/<platform>-architecture.md` (consultation output, ≤500-token return summary) |
| DV | your row's `metadata.artifact` — `.context/development-<N>-<stream>.md`, or `.context/development-<N>.md` when the run has one DV row |
| DR | `.context/developer-review-<N>.md` (written by corpflow:technical-lead) |
| SR | `.context/security-review-<N>.md` (written by corpflow:security-reviewer) |
| QA | `.context/testing-<N>.md` (written by corpflow:qa-engineer) |
| IR | `.context/incident-<N>.md` (written by corpflow:incident-responder) |

## Handoff frontmatter (BINDING)

Emit on every stage artifact, **even on failure**, so recovery can merge it. The stage boundary runs
`handoff-harness.sh --validate-frontmatter` and fails missing required fields. The budget is ≤200
tokens / ≤30 lines; decisions and questions are stubs pointing at artifact anchors.

### DV — this annotated block is the schema

```yaml
---
handoff:
  stage: DV                    # PL|AR|TL|DV|DR|SR|QA|DC|RE|FN|ST|IR|ET
  verdict: ok                  # ok / blocked / escalate
  summary: "<N files modified, M tests added>"   # ≤200 chars
  worktree: true               # false or absent → DR hard-fails the stage
  worktree_path: <abs path>    # OPTIONAL — the metadata.workspace_path you confirmed
  worktree_branch: <branch>    # OPTIONAL
  tests_executed:             # one entry per runner invocation; cases RUN, not discovered
    - { runner: bats, count: 12, summary_line: "1..12" }
  test_suite_compiles: true   # true|false|unknown; required for [] or all-zero runs
  files_touched:
    - <path>
  next_stage_focus: "<imperative: what DR/QA must focus on>"
```

Quote each nonzero `summary_line` verbatim under `## verification-command`, or name its
`.context/logs/` capture there. Strict runners (`bats`, `pytest`, `jest`, `vitest`,
`swift-testing`, `gradle*`, `junit*`) require `count` as a whole-number token in that line; a failing
`pytest` run may use its outcome-count line.
For Gradle/JUnit, quote `junit-tally.sh <results-dir>` output and name its capture. For `xcodebuild`,
derive the line from `xcresulttool` JSON and name that capture; its `totalTestCount` must equal
`count`. Explain an `unknown` `test_suite_compiles` in the body. Never sum runners into one entry.

#### DV schema, continued — sweep, refs and architecture

```yaml
# …continued: the same handoff: mapping, second half.
  open_questions:              # REQUIRED — [] when nothing to elicit, never omitted
    - { id: sw-DV0-1, class: decision, ref: "<this artifact>#elicitation-sweep", blocks_next_stage: false }
  refs:
    decisions: architecture-N.md#decisions    # ONLY when AR ran; omit otherwise
    tests: <this artifact>#tests-added
  architecture:                # ONLY when AR ran; omit the whole object otherwise
    ref: architecture-N.md#decisions
    applied: true              # your truthful statement that AR's decisions were followed
---
```

#### Pairing rule

`refs.decisions` and the `architecture` object travel together — one without the other makes DR
report `missing_input`, either without AR trips the inverse guard.

### Other stages — same block, these deltas

| Stage | Delta | Verdict |
|---|---|---|
| AR | `key_decisions` + `open_questions` anchored in `<platform>-architecture.md`; no `files_touched` / `worktree` / `architecture` | ok / blocked / escalate |
| DR / SR | `key_decisions` = findings; no `files_touched` | pass / fail |
| QA | `files_touched` = tests added, `key_decisions` = results | go / no-go |
| IR | `key_decisions` = root cause | ok / escalate |

#### Verdict and artifact rules

`key_decisions` items are stubs: `{ id: ad1, summary: "<≤160 chars>", anchor: "<artifact>#decisions" }`.
Use `ok|blocked|escalate|pass|fail|go|no-go|approve|reject` for a recognised verdict; never use
`needs_changes`. AR writes `.context/<platform>-architecture.md` and returns ≤500 tokens for
`corpflow:software-architector`. DR, SR and QA write no artifact. DV-support returns
`{support_role, findings}` to its parent. On a block, use `verdict: blocked`, `error_escalated_to:`,
and `.context/errors/<agent-basename>.md` for the narrative.

## Closing elicitation sweep (BINDING)

Before handoff, identify decisions the user would prefer to make. Put each surviving question in
`open_questions[]`. **Every stage owes a sweep**: an empty list needs a "nothing to elicit" line
under `## elicitation-sweep`. Resolve questions existing artifacts answer; cost is no exemption.

### One item, three transports — none derived from another

| Where | Carries |
|---|---|
| artifact `## elicitation-sweep` H2 | the FULL item. Canonical. Heading present even when the array is empty. |
| `handoff.open_questions[]` | the stub `{ id, class, ref }` |
| `state-patch.sh --facts` | the stub plus `stage`, `blocks_next_stage`, `status` |

#### The item, as written in the artifact

```markdown
## elicitation-sweep

### sw-DV0-1 — <the question, ≤160 chars>
- **class**: decision            <!-- decision | escalate -->
- **blocks_next_stage**: false   <!-- true only if the next stage would build on a guess -->
- **rationale**: <one line, ≤160 chars>
- **options** (2–4, exactly one recommended):
  - `<label ≤24>` — <detail ≤120>  *(recommended)*
  - `<label ≤24>` — <detail ≤120>
```

#### Rules

- `id` is `sw-<TASK_ID>-<n>` — the ledger unions on `.id`, so an unscoped `q1` overwrites another
  stage's question. Max 4 per stage; more is handing the user your triage.
- `escalate` is never auto-answered, `decision` may be; the orchestrator raises your label, never
  lowers it. `blocks_next_stage` is REQUIRED on every stub and on BOTH stub transports —
  `handoff.open_questions[]` **and** the `state-patch.sh --facts` payload — and the two copies must
  agree — `true` costs a round trip at your own boundary, `false` batches at the final gate.
- On rework or retry, preserve `status` and `resolution`. Ledger `class` is raise-only:
  `decision < escalate` (downgrade exits 2); explicit `blocks_next_stage: false` clears prior `true`.
- An option to accept a known vulnerability, CVE, or security finding requires `class: escalate`.
- You never ask — no plugin agent holds an ask tool; the orchestrator renders every item.
- Not the sweep, each already has a channel: runtime evidence (`requests_test_evidence:`), a skipped
  stage (`requests_stage_escalation:`), your outcome (`handoff.verdict`), a defect (`blocked`).

## Patching state.json

Run `state-patch.sh --stage <CODE> --prev <PREV>` when its path is supplied in the prompt or task
metadata. Path absent → skip silently; never hand-roll a merge. Patch fails → return for hook
recovery. Exit 3 means the artifact is missing — write it and re-run.

### Facts on the same call

Pass `--facts` on the **same** call. Arrays union on identity, so send only your own entries:

```bash
state-patch.sh --stage DV --task-id <ID> --artifact <your artifact> --prev <PREV> --facts '{
  "files_modified": ["<path>"], "tests_added": ["<path>"],
  "decisions": [{"id":"dv-1","summary":"≤160 chars","ref":"development-<N>[-<stream>].md#decisions"}],
  "open_questions": [{"id":"sw-DV0-1","stage":"DV","class":"decision",
                      "ref":"development-<N>[-<stream>].md#elicitation-sweep",
                      "blocks_next_stage":false,"status":"open"}]
}'
```

Omit `open_questions` here and the frontmatter stub is orphaned — the harness fails the stage with
`sweep stub <id> is in the frontmatter but not in facts.open_questions[]`.

## What you return

Return ≤500 tokens for the next stage. Drop P2/P3 detail, point at the artifact, and preserve the structure.

```markdown
## <STAGE> Summary — <PLUGIN>:<agent>
**Verdict**: <this stage's vocabulary>
**Artifact**: .context/<file>.md
**Changed**: <n> files — <the 3–5 that matter>
**Evidence**: <build/test/screenshot status>
**Blockers**: <none | what blocks and which stage resolves it>
**For next stage**: <what is not obvious from the artifact>
**Questions for the user**: <consultation stages only — sweep candidates the owning stage lifts>
```

On re-dispatch after a DR or QA rejection, `metadata.gate_blockers[]` carries the findings — the
review artifact's `## blockers`. **Fix those and nothing else**: address every entry or say in the
artifact why one is not actionable, and dispute via `error_escalated_to:` rather than by ignoring.

### Consultant return — consultant-return.v1

DR and SR consultations end the return with exactly one `json` fence, placed last, holding one
`consultant-return.v1` object (`schema_version`, `verdict`, `severity_counts`, `findings[]`) with
lowercase severities. A rejected return is re-dispatched once and never hand-fixed.

## Orchestrator agent roles

This plugin's commands name a **role**, never an id. Resolve the id, then check available agents:
**present** → dispatch it; **absent** → use the call site's `Error handling:` line.

### Which roles never route through corpflow

**Roles with a local equivalent are not dispatched through corpflow at all.** Architect, QA
engineer, and security reviewer resolve to routers that come straight back here, so app-layer work
calls this plugin's own architect, test generator, and security auditor directly. Those aliases are
corpflow's *inbound* routing, resolved at worktask init; these commands run outside any worktask.

**Split by layer, not by role.** The local architect selects this platform's patterns; service
decomposition, storage topology, and API contracts have no local equivalent and go to the
orchestrator's architect. Routing system-level design at the local architect is misrouted.

### Role to agent id

| Role named in a command | Agent id |
|---|---|
| the orchestrator's product manager | `corpflow:product-manager` |
| the orchestrator's architect | `corpflow:software-architector` |
| the orchestrator's DR reviewer | `corpflow:technical-lead` |
| the orchestrator's QA engineer | `corpflow:qa-engineer` |
| the orchestrator's technical writer | `corpflow:technical-writer` |
| the orchestrator's security reviewer | `corpflow:security-reviewer` |
| the orchestrator's ethics reviewer | `corpflow:ethics-reviewer` |
| the orchestrator's project manager | `corpflow:project-manager` |
| the orchestrator's worktask engineer | `corpflow:workflow-engineer` |
| the orchestrator's platform router | `corpflow:developer` |
| the orchestrator's meta-prompt engineer | `corpflow:prompt-engineer` |

A standard that is absent is simply unavailable — the skill's own guidance stands alone. Never
fork a standard's text into this plugin; a copy drifts silently.

## Keeping the seam single

- Never add a corpflow reference to an agent, command, skill, or hook, and never split this file
  into references. A rule an agent needs belongs here; dispatch injection delivers it.
- Hooks say "the orchestrator" generically, so they work standalone.
- Shared standards are the exception, referenced by id: `corpflow:code-comment-standard`,
  `corpflow:security-review-process`, `corpflow:claude-constitution`, `corpflow:logging-conventions`.
- <PLUGIN>'s version does not track corpflow's. Bump the target below when the contract changes.

| | |
|---|---|
| Targets corpflow | `<version>` |
| Consultant return | `consultant-return.v1` |
| Size budget | ≤300 lines |
| Contract source | `corpflow skills/cross-plugin-handoff/references/plugin-contract.md` |
