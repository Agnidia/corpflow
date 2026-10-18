# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [4.1.2] — 2026-10-18

The suite runs green again (#483, #488), the cli-fallback render no longer needs a font registry,
and the marketplace id moves from `igrsoft` to `agnidia`. The repository also stops tracking
`.claude/settings.local.json`, and the adhoc self-test keeps a caller's EXIT trap.

### Changed

- **The marketplace id is now `agnidia`** (was `igrsoft`), so the install key is `corpflow@agnidia`.
  An existing install keeps the old `igrsoft` marketplace and the `corpflow@igrsoft` key. To migrate
  in Claude Code, run `/plugin marketplace remove igrsoft`, then `/plugin marketplace add Agnidia/corpflow`
  and `/plugin install corpflow@agnidia`. Then rename the `corpflow@igrsoft` key to `corpflow@agnidia`
  in every `enabledPlugins` map that names it. In Codex (steps verified on Codex CLI 0.163.0), run
  `codex plugin remove corpflow@igrsoft` and `codex plugin marketplace remove igrsoft`, then
  `codex plugin marketplace add https://github.com/Agnidia/corpflow.git` and
  `codex plugin add corpflow@agnidia`.
- **`.claude/settings.local.json` is no longer tracked.** It is per-operator Claude Code state, so
  `.gitignore` now lists it. A pull of this change deletes an unmodified tracked copy; save your copy
  first to keep its `enabledPlugins` and permissions.

### Fixed

- **The cli-fallback ImageMagick render works without a font registry.** `cli-fallback.sh` passed
  `-font Courier`, which only resolves through fontconfig, so a stock Homebrew ImageMagick 7 failed
  every render with `render_failed`. It now asks for Courier by name only when `magick -list font`
  lists it, else uses a monospace font file (Menlo, Courier, DejaVu Sans Mono), else no `-font`.
- **`adhoc-visual-evidence.sh --self-test` keeps a caller's EXIT trap.** The self-test sets its own
  EXIT, INT and TERM traps to remove its scratch directory. If the shell exits during the test, the
  caller's EXIT handler now runs after that cleanup with the real exit status. When the test ends,
  the caller's traps come back exactly.

### Tests

- `web-capture.bats` T3 and T4 hide `playwright` from PATH, so a host Playwright no longer takes
  the npx-rung capture or fetches the test URL (#483).
- The adhoc-visual-evidence self-test owns its PATH: it filters the host's `silicon`, `magick` and
  `convert` out and uses a PNG-writing stub, so a broken host tool no longer picks or fails an arm
  (#483).
- The `size-budget.bats` oversize cases hide `pngquant` through the `--hide` allowlist farm instead
  of cutting PATH down to the system bin directories, so a distro `pngquant` there no longer turns
  the "no pngquant" case into "pngquant present".
- The `handoff-harness.bats` frontmatter-budget case reads the git-tracked
  `tests/fixtures/worktask` artifacts, not the gitignored `.context/` run folder of the checkout
  (#488).

## [4.1.1] — 2026-10-09

One `CORPFLOW.md` can now configure every project. This release also records contract changes
that shipped on develop without a changelog entry; sibling-plugin `CORPFLOW.md` files that target
an earlier corpflow should resync against them.

Fixes the prompt-audit findings and comment gaps of #458, a reader-side root-resolution flaw, the
FN/ST predecessor edges of #467, the writer's share of the reader guard (#468), the planner-owned
screenshot flag (#470), and the lessons adopted from mattpocock/skills `959a8e9..4588b32`.

### Added

- **Fewer full-artifact rewrites and a bounded DC path loop.** `hooks/anchor-preflight.sh` no
  longer denies a whole-file Write. Frontmatter over budget, a digitless `summary_line`, a
  status-note sweep stub and an off-list H2 now come back at PostToolUse, one line per finding,
  with "fix it with a small Edit, do not re-Write the file". An Edit that adds an off-list H2 is
  still denied, and the stage-boundary harness still gates. Every stage agent's "Artifact anchors"
  block states the 200-token budget and the 2–4 option sweep rule. `doc-option-check.sh` gains a
  repeatable `--allow-path <path>` for paths the code creates at run time, and a stderr hint for a
  git-ignored missing path. technical-writer DC2 gets a stop rule: one failed fix, then evidence and
  `--allow-path`, never a deleted correct claim, at most 3 runs.
- **`writing-style` skill and `skills/shared/writing-style.md` canon.** Prose rules derived from
  ASD-STE100 at about 80%: single-topic sentences (procedural ≤20 words, descriptive ≤25), active
  voice, imperative steps, articles kept, one term per meaning, and tables or diagrams over prose
  for structure. technical-writer and the context-compression handoff rules cite it.
- **`## Merge danger` PR section.** The PR format (`skills/shared/git-conventions.md`) and the FN
  template and checklist (`conductor-attachments.md`) carry a reversal class (`one-way` or
  `two-way`, with its reason) and a blast radius. `## Changes` leads with the smallest visual, and
  `## Test plan` shows the failing-then-passing check or the changed output: "tests pass" alone is a
  claim. `pr-body-lint.sh` P4 warns on a missing section (exit 0 unless `--strict`).
- **Enforcement form for self-improvement proposals.** Each ST proposal is `mechanical` (a check:
  lint rule, bats test, hook, or the wiring of an unwired one) or `judgement` (prose; a standards
  rule targets the reviewer first). No new rule targets an always-loaded file, and each proposal
  cites its diff hunk. Approved `mechanical` proposals go to workflow-engineer, `judgement` ones to
  prompt-engineer.
- **Two `skill-refs.bats` predicates.** One names an unquoted top-level frontmatter value that
  contains `: `; the other names a `Skill(` call into a skill marked `disable-model-invocation: true`.

- **User-scope `CORPFLOW.md`.** corpflow reads `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CORPFLOW.md`
  as a fallback for `## Routing` and `## Models`. Precedence is per heading: the project-root file
  wins for any heading it carries, the user-scope file supplies the headings it lacks, and the
  built-in matrix covers the rest. A garbled project `## Models` still owns its heading: it is
  audited `model_override_unparsed` and never falls through to the user file; a bare project
  heading with nothing under it does not claim the heading. An explicit
  `state-patch.sh --resolve-models --corpflow <path>` still beats both.
- `model-matrix-lib.sh` gains `corpflow_md_locate`, `corpflow_md_user_path` and
  `corpflow_md_source`. `state-patch.sh --resolve-models` and `model-matrix.sh`'s bare `--resolve`
  share them, in place of two copies of the project-root path logic.
- New source value `user-override` for `state.models_source`, per-agent `state.models.*.source`
  and `state.routing_source`. The `model_override`, `model_override_unknown` and
  `model_override_unparsed` audit rows carry `metadata.source` and `metadata.path`.
- **`consultant-return.v1`** (backfill). DR and SR sibling-plugin consults return one shape,
  checked by `skills/cross-plugin-handoff/scripts/validate-consultant-return.sh`: severities are
  lowercase, a missing `version` is stamped, a mismatched one is rejected, and `needs_changes`
  maps to `fail`.
- **Reserved `## Models` heading** (backfill). `skills/shared/stage-codes.md § Agent Model
  Matrix` is the single agent-keyed model/effort source. A `CORPFLOW.md § Models` table overrides
  it row by row, fail-open, resolved once by `state-patch.sh --resolve-models` (validation check
  13) into `state.models`. A plugin-root `CORPFLOW.md` must not carry `## Models` or `## Routing`.

### Changed

- **Requires Claude Code 2.1.294** (was 2.1.284). 2.1.293 resolves `haiku` to Haiku 5.5, the
  model the cost table now prices, and `headless-dispatch.sh` floors at 2.1.294. 2.1.292 adds the
  `Agent` tool's `effort` parameter, which every in-process stage dispatch now passes. A cross-session message held at the
  recipient for approval was reported as delivered before 2.1.288; it now reads as not delivered
  and names the holding session. Background commands in unattended sessions stop at their
  `timeout` since 2.1.285, which the explicit 2 h `timeout` below depends on.
- **Stage effort is carried in-process.** Step 6 passes the stamped tier on `Agent({ effort })`
  (new `effort_transport` value `agent-param`), which outranks the agent's `effort:` frontmatter;
  `effort_resolved` comes from the subagent's hook row. `CORPFLOW_HEADLESS_ROUTE=on` sends every
  non-haiku stage headless instead; haiku stages pass no `effort` (`none`). **Breaking:**
  `effort-route.sh` drops `--agents-dir`, `--role-baseline` and the `baseline`/`baseline_source`
  fields, and `headless-dispatch.sh` drops `--baseline` and the `opted_out` fallback
  (`CORPFLOW_HEADLESS_ROUTE=off`). The headless child gets the route's tier from `--effort` alone,
  not `CLAUDE_CODE_EFFORT_LEVEL`, so a resolver bump reaches it; a `warn` fallback runs in-process
  at the same tier (`agent-param`, `effort_resolved: null`, `inproc_fallback`). A refused route
  escalates instead of dispatching without the tier, and the PL0 and self-improvement dispatches
  pass their resolved `effort` too.
- **Nested delegates get the stage tier.** A nested `Agent` call without `effort` runs at the
  target's own frontmatter tier. DV, QA, SR and RE now pass their brief's `effort:` line, which
  `brief-compose.sh` emits beside `model:`, to the agent doing the stage's primary work; consults
  keep the target's own tier.
- **Audit hooks read effort from the payload only.** `audit-tooluse`, `audit-subagent` and
  `agent-stop` drop the `$CLAUDE_EFFORT` fallback: on haiku the payload has no `effort` but the
  env var keeps the requested tier, so rows recorded a tier that never ran. They now write
  `"unknown"`, which the resolvers treat as no row.
- **`Task` → `Agent`.** Grants, hook matchers, docs and pseudo-code name only `Agent`. Hook
  payloads name the spawn tool `Agent` even when a `Task` matcher fires, so
  `test-execution-gate.sh`'s `Task)` branch never matched and wrote no `test_delegation_observed`
  row. The gate now branches on `Agent)`, and the Codex adapter emits `Agent`.
- **Prompt-audit sweep (`/prompt-audit --all`, 17 critical, 49 warnings).** Grant gaps closed:
  project-manager runs `fn-preflight.sh`, team-lead runs `jq`, developer may dispatch
  `go-developer`, tech-code-review may write its review artifact. Wrong references fixed (`ST-SI`,
  `TL3`, `release.md`, stream-blind `development-<N>.md` close-outs, lowercase self-improvement
  commit subject). `/prompt-audit` Agent rule 1 now requires `effort:` equal to the matrix tier, and
  `/create-agent` scaffolds it plus the matrix row. Branch-only blocks move behind references:
  `worktask/references/{headless-arm,return-arms,step-7a-arms,autonomy-preflight,auto-decision,
  megatask-per-issue,dr-reference}.md`, `agent-coordination/references/cross-session-messaging.md`
  and `shared/technical-consult.md`. Commands follow Options → Examples → Output Format with a
  Values column and defaults; inflated `BINDING`/`MUST` emphasis and default-behaviour sections
  are removed; designer writes `.context/designs/ux-assessment-N.md` for PM to merge.
- **CC 2.1.285→2.1.292 band integrated.** The reattach result table and `stale-check.sh` handle
  `held` (stay parked, never re-send, the operator approves at the named session). Headless-dispatch
  `Monitor(Bash(...))` calls and QA's direct-run fallback pass an explicit `timeout`, so an
  orchestrator running under `-p` no longer cuts a stage off at 30 min; a stop at the time limit is
  an infrastructure stop, not a test failure. Docs pick up fail-closed `PreToolUse` matching,
  teammate `agent_id`/`teammate_id`, worktree access fixes, the 1M default on gateways and cloud
  providers, new Bash and Read permission hardening, one-shot `-p` waiting for background commands
  and wakeups, escaped `<system-reminder>` tags in hook output, UNC-read and `allowed-tools`
  fixes, `claude plugin test` failing on a failed `expect`, and stdio MCP protocol 2026-07-28.
- **CC 2.1.293→2.1.294 band integrated: Haiku 5.5.** `haiku` now prices at Haiku 5.5 ($0.10 /
  $0.50 / $0.01 cache read, 1/20 of sonnet). A prompt over 100K tokens bills 5x that. The Sonnet
  5.5 cache-read rate is corrected to $0.10. `estimate-calc.py` follows the table. The benchmark
  `DC` pin moves to `claude-haiku-5-5`, which is a new era boundary. The README no longer says
  Haiku sees the `TaskCreate` tools: Haiku 5.5 does not. The docs add these changes:
  - instruction-style `prompt`/`agent` hooks now block (2.1.294)
  - `subagentStatusLine` `agentType`
  - rules loaded on a Bash `cat`/`head`/`tail`/`sed -n`/`grep` view
  - no `SendMessage` prompt once the tool is removed
  - narrowed child tool lists
  - `claude agents` bypass consent
  - the compaction self-action fix
- **The planner now owns `requires_screenshots`.** `detect-ui-change.sh` is advisory input: the
  planning model judges whether the diff alters rendered output, S1 (`ui_visual_check`) is a hard
  floor, a `false` over an S2 hit needs a written reason, uncertain means `true`, and the planner
  never raises a screenshot question. The user-directive override is removed from the PL procedure,
  product-manager runbook, plan template and ledger schema.
- **Detector S3 matches framework terms only.** `view`, `component`, `screen`, `layout`, `theme`,
  `styling`, `animation`, `HTML` and bare `Compose` no longer fire it. New `--ui-platforms` option
  shares the admitted platform set; bare `.kt` leaves the shared UI path vocabulary.
- **DV upward-only safety net.** New `skills/dv-screenshot-capture/scripts/escalate-flag.sh` raises
  a `false` flag to `true` (task then ledger, one `screenshot_flag_escalated` audit row) when the
  change set, including uncommitted and untracked paths, matches the UI path classes on
  apple/web/android. It never writes `false`; `agents/developer.md` runs it before capture, and
  `hooks/dv-screenshot-gate.sh` runs it (`--invoker gate`, 10 s watchdog, fail open) on every live DV
  SubagentStop whose flag reads `false`, so the net also covers DV agents that never read developer.md.
  An escalated block opens with `gate raised the planner's requires_screenshots=false: <n> UI path(s)
  matched in <ws>`.
- **Constraints blocks, all 16 agents.** Each `## Constraints (DO NOT)` bullet now takes the form
  its failure needs (`agents/prompt-engineer.md § Form to failure`): a `DO NOT` with a short
  because only where an agent knows the rule and skips it under pressure, otherwise a positive
  recipe or a conditional keyed to something observable. Bullets the model already obeys are gone,
  and unearned `MUST`/`NEVER`-style emphasis is downgraded. The heading text is unchanged.
- **Completion criteria name their evidence.** Stakeholder, QA, project-manager, architect,
  team-lead, ethics-reviewer, developer, incident-responder and release-engineer checkboxes now
  name the artifact file and anchor that proves them. incident-responder gains a
  `## Completion Verification` section and a done-when column for IR0–IR3.
- **Sibling dispatches forward `[4b]`.** The QA, SR, AR, RE and DV dispatch sections follow the
  plugin-root line with the model discipline block
  (`skills/cross-plugin-handoff/SKILL.md § Model discipline block`).
- **FN multi-stream arm moved** from `agents/project-manager.md` into
  `skills/worktask/references/fn-multi-stream.md`; the agent keeps a one-line pointer.
- **Audit commands require `effort:`.** `prompt-audit`, `optimize-agent` and `create-agent` flag
  only a `model:` frontmatter key; `effort:` is required and equals the agent's matrix row.
- `state-patch.sh` now shares the reader guard (`corpflow_inferred_ctx_ok`, #468); its exit-4 refusal no longer names the plugin root path.
- **team-lead stream rules.** A shared registry file (changelog, string catalogue, config map)
  belongs to one stream, or the streams are serialised; every new name two streams share is fixed
  in the interface contract.
- **DR re-review is scoped.** After a rework round, technical-lead checks the fixed findings and the
  rework diff only; a new P1 or P2 outside it becomes a follow-up, and only a new P0 reopens review.
- **A skipped test is not a pass.** `skills/shared/testing-strategy.md § Skipped tests`: runs report
  their skip count, a skip caused by material a worktree lacks is recorded with its cause, and
  `.worktreeinclude` is the remedy.
- **Self-improvement proposals reach the agent their form names.** `/worktask` Phase 3, the
  FN-gate Post-ST step and `/improve-yourself --apply` send `judgement` items to prompt-engineer
  and `mechanical` items to workflow-engineer, one dispatch per form, in sequence. workflow-engineer
  gains a Self-Improvement Patch Application section. An item with no valid `Enforcement:` value
  (missing, or other than `mechanical` or `judgement`) is not applied; it is counted as skipped
  and named to the user.
- **One version-bump rule for applied proposals.** `skills/self-improvement/SKILL.md § Hand-off to
  the applying agent` states it once: a target with frontmatter takes one `version:` bump, a
  script, hook or bats file takes none. The same section says that a `mechanical` proposal passes
  the Step 4 owning-file filter first and then targets a check file. `/improve-yourself`,
  `/worktask` Phase 3, the FN-gate Post-ST step and workflow-engineer point to it.
- stakeholder names both applying agents for approved proposals.
- **One plugin-paths sentence in all 16 agents.** Each `## Plugin paths` section now reads
  "Every `skills/`, `commands/` and `hooks/` path here", byte-identical across the agents.
  `skills/worktask/references/pl0-procedure.md` names the same three prefixes for its paths.
- The five scripts this release changes pass shellcheck at default severity with no output:
  `attach-visual-evidence.sh`, `adhoc-visual-evidence.sh`, `pr-body-lint.sh`,
  `pr-body-lint-selftest.sh` and `hooks/dv-screenshot-gate.sh`. Their behaviour is unchanged.

- **Per-task screenshot manifests** (backfill). Each DV task writes its own
  `.context/images/<worktask_id>/screenshots-<TASK_ID>.md`. `dv-screenshot-gate.sh --check
  <TASK_ID>` and `attach-visual-evidence.sh --validate-manifest --task-id <TASK_ID>` validate one
  task's rows against the images on disk.
- **DV fan-out writes per-row artifacts** (backfill). Each DV ledger row owns the artifact its
  `metadata.artifact` names, `development-<N>-<stream>.md` when there is more than one row, and
  completes with `state-patch.sh --task-id <ID> --artifact <path>`. A bare `development-N.md`
  remains the single-DV case.
- **Install-root dispatch line** (backfill). A plugin-root `CORPFLOW.md` names the plugin's loaded
  install root in every dispatch prompt, so the specialist resolves paths under it rather than
  searching for them.
- **AR and SR consult gate at High (≥31)** (backfill). The AR architect consult moves from ≥21 to
  the High floor, and SR consults the platform security auditor only for a sensitive surface or a
  High score, recording a skipped consult otherwise.
- Docs: `routing-matrix.md § Resolution` and its three-kind `CORPFLOW.md` table, `PROJECT-CORPFLOW.md`
  (valid at user scope; reads both `## Routing` and `## Models`, not one heading),
  `skills/cross-plugin-handoff/templates/CORPFLOW.md`, `plugin-contract.md`, validation checks 12/13 and the README describe
  the user-scope fallback.

### Fixed

- **A count-less summary line no longer proves a test count for a counting runner.**
  `handoff-harness.sh` only warned when a corroborated `summary_line` did not carry its entry's
  `count`, so `BUILD SUCCESSFUL in 4s` could stand in for "58 tests ran". It now fails the entry
  for the strict runners: `bats`, `pytest`, `jest`, `vitest`, `swift-testing`, and every `gradle*`
  or `junit*` name, matched case-insensitively. A failing pytest line, which prints no total,
  passes when its executed outcome counts sum to `count`. `bash-*` live scripts, `xcodebuild` and other
  runners keep the warn and the `count_corroboration` audit row. The new
  `skills/worktask/scripts/junit-tally.sh <results-dir>` prints one count-bearing line from a JUnit
  XML directory (`JUnit XML tally: N tests executed, F failures, E errors, S skipped`, N = tests
  minus skipped), and the fail message names it for Gradle and JUnit. `stage-contracts.md`
  (`#tpl-dv`, `#tpl-qa`), developer and qa-engineer say the same.
- **Every worktask self-test now prints how many cases it ran.** The pass lines
  (`self-test: ALL PASS`, `desc-lint self-test: ALL PASS`, `self-test OK`, …) had no digit, so
  the harness digit rule refused them as a `summary_line`. Each of the 21 `*-selftest.sh` and
  inline `--self-test` printers in `skills/worktask/scripts/` and `hooks/state-merge.sh` now
  appends `(N passed, 0 failed)`. N is a counter that goes up once per case that passed, never a
  constant. Counting self-tests print `(P passed, F failed)` on failure, and exit codes do not
  change. `state-merge.sh` repeats the count of the `state-patch.sh` run it delegates to, and
  fails if that line has no count. The old text stays as a prefix, so existing matches still hold.
- **A sweep item's `class` can no longer be lowered from `escalate`.** `state-patch.sh --facts`
  joined `class` last-writer-wins, so a stage re-run could write `decision` over an item another
  labeller raised to `escalate`. The ledger then agreed with the artifact, and the harness passed.
  Now `class` is raise-only on `decision < escalate`, and a stub with no class keeps the incumbent's.
  A refused downgrade exits 2. It prints one line per id on stdout and stderr and writes one
  `facts_items_rejected` audit row. The rest of the payload still lands. Ledgers that agree
  today keep passing. After a refusal, an artifact stub that still says `decision` fails
  `--validate-frontmatter` at the next boundary. That failure is a real defect: raise the stub to
  `escalate`. `#tpl-sr` and `#tpl-re` now make a question that offers to accept a known vulnerability,
  CVE or security finding `class: escalate`. `#tpl-st` states that ST never resolves an `escalate`
  item.
- **`apple-swift-match` checks a minimum, not equality.** It passes on any `swift` on PATH at or
  above `CORPFLOW_SWIFT_MIN` (default 6.3.0). The compare is numeric per field, and the detail
  names both versions when `xcrun swift` differs. A `swift` that cannot run fails with the probe's
  first line (home path shown as `~`). The fix line is `swiftly use --global-default --assume-yes
  xcode` or a PATH change; without `--assume-yes`, swiftly waits on a prompt. The check id is
  unchanged.
- **The Step 2a-pre snippet exits 0 on a clean pass.** It grepped for `result=`, which the script
  prints only on a skip, so a pass ended the tool call with exit 1. It now prints
  `result=<pass|skipped>` from `result_json`, keeps `reason=` and `accepted_absent=`, and exits 0.
- **PL0 gets the full task.** Step 4 calls `description` a capped label, never the planner's
  input. The new § Step 6 — the planning prompt names the minimum: the task word for word (the
  issue body under `/megatask`), the resolved flags and carriers, and the `WORKSPACE_ROOT=` banner.
  product-manager plans from that prompt. A 908-char task had reached PM cut at 240 chars.
- **`state-patch.sh` reports a description cut.** It still truncates and never refuses. After the
  write it prints `description_truncated=<id>:<length>` on stderr, on create and on meta.
- **`--task-meta --unset <key[,key...]>` removes metadata keys.** Before, `--set '{"k":null}'`
  was the only option, and `has("k")` stayed true. It runs after the merge under the same lock. An
  absent key is a no-op. A pipeline key (`stage`, `agent`, `model`, `effort`, the three gates,
  `workspace_path`, `isolation`, `base_ref`, `requires_screenshots`) exits 2 and names the key.
- Speed-over-exploration clauses removed from product-manager, technical-lead and stakeholder.
- team-lead clones PL0's resolved model/effort row instead of picking tiers; project-manager's
  stray `F3` step (the label means fallback layer 3 elsewhere) is renamed.
- workflow-engineer names the six sanctioned ledger-row writers, and its State Patch uses the
  `--task-id <ID>` / `tasks.<ID>` form.
- The handoff edge table gains `QA→RE` for a standard, secure or full run that excluded DC, and
  release-engineer's `<PREV>` rule matches it.
- `prompt-audit`'s recall-suppression citation points at `tech-code-review § Phase 1`.
- FN and ST predecessor edges (#467): `QA→FN` when DC and RE are skipped, `DC→FN` only when DC ran
  and RE did not, and `RE→ST`/`DC→ST`/`QA→ST` when FN is skipped.
- Ledger readers (`corpflow_context_dir`, `mailbox-lib`, `brief-compose`, the model-switch hooks) no longer hand a cwd nested inside the plugin checkout that checkout's live `.context`; they refuse like the #457 writer does. A linked worktree at its toplevel still resolves the main ledger (#458).
- The screenshot-gate block text names the Bash entry point
  (`skills/dv-screenshot-capture/scripts/capture.sh --task-id <id>`) instead of a skill route DV
  does not hold; the `hook-monitoring.md` example follows.
- The `writing-style` skill description fits the 250-character cap. The Core rules section of
  `skills/shared/writing-style.md` is split under two sub-headings to fit the 1000-character
  section cap; no rule changed.
- The 0600 mode tests in `tests/shell/skills/append-labels.bats` and
  `tests/shell/skills/pipeline-counts.bats` no longer fail on macOS, where `ls -l` appends `@` for
  extended attributes. The scripts were already correct.
- `tests/selection/matrix.tsv` row R17 lists `skills/shared/writing-style.md` with the other
  reviewed prose docs that have no executable contract, so test-selection M5 passes again.
- The `## Visual evidence` block goes between `## Test plan` and `## Merge danger`, the order in
  `skills/shared/git-conventions.md`. `skills/dv-screenshot-capture/SKILL.md` no longer names
  `## Notes` as the end point.
- The header comments of `attach-visual-evidence.sh` and `adhoc-visual-evidence.sh` now say that
  the Visual evidence block goes between Test plan and Merge danger.
- Doc references that did not resolve now pass the doc-option check: team-lead's path-character
  regex is anchored, technical-lead cites `skills/worktask/SKILL.md`, the settings file is named
  per project, and the git-conventions branch examples move out of code spans. No rule changed.

### Tests

- `tests/lib/test_helper.bash` points `CLAUDE_CONFIG_DIR` at an empty sandbox for every suite, so
  an operator's real `~/.claude/CORPFLOW.md` never reaches a test. The Python parity suite pins it
  the same way.

## [4.1.0] — 2026-09-28

### Added

- Portable Agent Plugins and Codex compatibility manifests, Codex-native hook registration, and
  same-named `$skill` adapters for all 28 existing slash-command workflows.
- A Codex runtime contract mapping Corpflow agent orchestration and model tiers to Codex controls:
  haiku → `gpt-6-luna`, sonnet/opus → `gpt-6-sol`, and fable → `gpt-6-astra`.
- Provider-neutral `BASE_PLUGIN_ROOT` and `BASE_PLUGIN_DATA` resolution, including safe plugin-path
  joining and support for portable, Codex, and Claude package markers.
- `skills/shared/plan-content.md`: one canonical plan-content rule ported from superpowers v6.4.2.
  A plan records decisions (files, signatures, the spec's values, test assertions), not a
  transcript of the code; it adds a step scan and a proportion check to self-review.
- `/prompt-audit` gains a planning-stage plan-content rule and a consistency check that flags
  unreferenced asset files under `skills/` for deletion.

### Changed

- PL0 (`pl0-procedure.md`, product-manager), AR (software-architector), TL (team-lead) and
  `request-plan` point at `plan-content.md` by section instead of carrying their own wording:
  each names the decisions its artifact records, and DV writes the implementation bodies.
- technical-writer: a project keeping its guidelines in `AGENTS.md` gets a `CLAUDE.md` that
  imports them with `@AGENTS.md`, since Claude Code skips `AGENTS.md` whenever a `CLAUDE.md`
  exists.
- Live benchmark: both arms also switch off the `plugin-authoring@builtin` plugin that Claude Code
  2.1.289 ships, so the WITHOUT arm again loads zero plugins.

### Compatibility

- Claude Code commands, agents, hook registration, and legacy `CLAUDE_*` boundary inputs remain
  supported. Codex-specific behavior is isolated in additive manifests, adapters, skills, and
  hook configuration.

## [4.0.32] — 2026-09-11

A control that fails silently is indistinguishable from a control that passed, and an evidence
token that asserts more than it observed is worse than no token — the theme 4.0.31 opened, applied
here to the completion loop itself, two continuity mechanisms that existed but were never wired,
and the ledger lock's ownership.

Correctness pass across agent, command and skill surfaces: seven documented defects fixed
(divergent per-stage dispatch table, unchecked parity assertion, duplicated routing glob, missing flag
documentation, stale section citations, lint regressions, and stale version line), two parity test
methods added, and five distinct stale citations across eleven occurrences repaired. Eleven follow-up items filed
out-of-scope.

### Breaking

- **`test_summary_line` is now required of DV and QA artifacts whenever `tests_executed > 0`.**
  `handoff-harness.sh --validate-frontmatter` fails an artifact reporting executed tests with no
  verbatim runner summary line to corroborate the count. No migration: an artifact that already
  carries the line is unaffected.
- **A present but non-numeric `tests_executed` now blocks** at the same gate, closing the gap
  where a claimed execution count was accepted without ever being checked.
- **`oracle.cases_digest` moves to `sha256:80652591`** (benchmark eval harness). Records either
  side of the retiering that fixed six mistiered cases and closed the era-stamp gaps refuse to
  pair; `era.prompt_contract` is unchanged. Unreleased since it landed, folded in here rather than
  shipped silently under a patch line that never mentioned it.

### Added

- **A terminal `failed` task status.** Escalation counts are tracked per full task id
  (`escalation_counts`); at the cap the task is written `failed` with `last_error.class:
  "exhausted"`. Joins `completed`/`skipped` in `SETTLED`, so the loop exits instead of spinning on
  a stage it can neither settle nor dispatch. Additive — existing ledgers load unchanged.
- **`PostCompact` and `SessionEnd` registered in `plugin.json`.** `PostCompact` drives
  `post-compact-recovery.sh`, recurrence-guarded by a new inverse manifest-parity assertion, but
  the live firing is **not yet observed** — a real compaction cannot be simulated in CI. `SessionEnd`
  drives the new `hooks/session-end-finalize.sh`: reports any task still `in_progress` at teardown
  to an audit row, never mutates status, always exits `0`.
- **The ledger lock carries an owner token** and refuses a foreign release, rather than silently
  freeing a lock another writer still holds.
- **Session hygiene and command output hygiene guidance.** `cost-optimization § 4d` covers noisy
  command output, which stays in context and is re-billed every turn; token-baselines adds
  `BASH_MAX_OUTPUT_LENGTH`, `/autocompact`, `/mcp`, `/context` and `/rewind` vs `/compact`;
  context-compression gains a copy-paste "Compact instructions" block; `/worktask` documents
  fresh-session, `/rename` + `/clear` and separate-session `/loop` habits. Docs only.

### Changed

- **A per-dispatch effort raise or lowering now reaches the session, instead of staying an
  advisory audit field.** `skills/worktask/scripts/effort-route.sh` decides, per dispatch,
  whether the stamped tier differs from the target agent's own `effort:` frontmatter tier; a
  difference routes headless through the new `skills/worktask/scripts/headless-dispatch.sh`
  (`claude -p --agent … --effort`, argv built from an allowlist, never a shell string), and
  `skills/worktask/scripts/headless-poststop.sh` replays the installed `plugin.json`
  `SubagentStop` hooks the headless child never fires itself, so a headless DV row gets the
  same gates, state merge and audit trail an in-process one would. `effort_transport` gains a
  fourth value, `env`, for an operator `CLAUDE_CODE_EFFORT_LEVEL` pin that outranks a routed
  raise (`skills/shared/stage-contracts.md § Resolver Effort Tier`,
  `commands/worktask.md § Step C.0a`). Some stages now run at a raised or lowered tier where
  they previously ran at the session default; no version-floor change (`--agent`, `--effort`
  and `--permission-prompts` already exist at 2.1.280).

- **`/cc-update` 0.3.0**: two new standing passes — a Communication Surfaces Watch (cross-session,
  cross-agent, cross-plugin entries routed to their owning docs; the four "re-check at the next
  `/cc-update`" obligations closed as confirmed/unconfirmed each run; min-CC rule stated) and a Ledger
  Field Review (every new CLI flag, frontmatter key, tool param, or `claude agents --json` key decided as
  New field / Existing field / Row key / None against `task.metadata` and the headless flag bridge).
  Both run by default on every invocation. Version Source now names the real README carriers (badge
  line + Requirements row) instead of a `claude-code min version:` token that never existed; the
  `curl`/`jq` fetch fallback and `claude agents --json` are granted in `allowed-tools`.
- **Requires Claude Code 2.1.270** (was 2.1.251). The resume loop now trusts signals older builds
  got wrong: a reattach `ok` could land in a phantom `ListAgents` twin (2.1.260), a send to an
  offline remote peer read as delivered (2.1.261), and a headless session running background agents
  reported "waiting for your input" (2.1.269). `/megatask` fan-out also relies on concurrent sessions
  no longer reverting `~/.claude.json`, which reset workspace trust (2.1.259). 2.1.270 rather than
  2.1.269, which regressed read-only git commands into permission prompts.
- **CC 2.1.252→2.1.270 band integrated.** The `SessionEnd` hook entry carries an explicit 5 s
  `timeout`; the reattach result table handles `queued` (stay parked, never re-send); PL0 raises a
  `decision` item when `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` would override every stage model pin. Docs
  cover Fable 5.1, `maxEffortLevel`, the 2.1.270 `claude agents --json` key set, permission-mode CLI
  choices, `plugin validate`/`list --json`, and a security hardening table. `claude agents run` is not
  a subcommand at 2.1.270; recorded as drift, the headless dispatch one-liner is a follow-up.

### Fixed

- The pre-compaction checkpoint hook no longer leaves an unconditional copy unguarded under
  `set -eu`; a failed checkpoint now records the failure instead of leaving no trace.
- The compaction recovery script's two output paths are rooted on the same project-directory
  variable as its sibling script, and its header no longer claims a filtered selector it does not
  run.
- **`estimation-methodology`**: a synthetic asset no longer downgrades the complexity tier it is
  scored against.
- **benchmark eval harness**: oracle discrimination restored — six mistiered cases moved from
  `implied` to `specified`, four new `implied` cases added, `failures[]` now persists into the
  record instead of being dropped at write time, and `cli_version`/`plugin_version` are stamped as
  a new era axis.
- **request-plan**: four review findings closed on the leaderboard fix plan.

- **headless-dispatch reference**: per-stage effort table now matches `stage-codes.md` canon on all rows
  (DV/DR corrected from `xhigh` to `high`, QA from `high` to `medium`, RE from `medium` to `low`); module
  citation corrected to `stage_table.py`; four missing rows (PL, AR, TL, DC) added; test-pinned advisory
  cell preserved byte-for-byte.
- **Parity test enforcement**: `test_stage_table_ssot.py` extended with two new methods (`test_efforts_match_stage_codes_md`
  and `test_headless_dispatch_table_matches_stage_codes`) to catch effort column divergence on future edits;
  existing model-family test retained unchanged.
- **Single-source-of-truth routing glob**: restated verbatim in `agents/workflow-engineer.md` replaced
  with a pointer to its canonical source in `skills/worktask/references/pl0-procedure.md`.
- **Pipeline flag documentation**: `--with-design` now appears in both `commands/worktask.md` options table
  and `skills/shared/state-ledger.md` schema, closing documentation gap where flag was live in README
  and procedure but absent from owning command's table.
- **Section-length lint regressions**: two branches-introduced sections split or trimmed under 1000-character
  cap (`commands/prompt-audit.md` and `skills/worktask/references/handoff-protocol.md`).
- **Stale cross-file section citations**: five distinct broken references repaired across nine files,
  including resume-procedure path correction, ceiling-count update, auto-delegation file/anchor fix,
  escalation-guard heading refinement, and four bare references/ path qualifications.
- **Release-tooling version line**: `MEMORY.md` version record updated to 4.0.33 with current-branch
  status corrected.

### Also in this release

Batch 7 of the request-plan calibration set was pinned and its two defects repaired
(`request-plan`, 45 cases, 18 held out, cases 271–315) between the 4.0.31 tag and this one; it
carries no user-facing behavior change and is recorded here only because it landed in the same
unreleased window.

Eleven follow-ups filed out-of-scope (F1–F11 in the architecture stage artifact): redundant-but-agreeing
mirrored tables pinned by parity tests, compound section-path citation convention, `with_design` writer
gap, per-stage table's missing-row note, and three cross-file reference style questions.

## [4.0.31] — 2026-09-09

Closes phases A–E of `ttt-run-tictactoe-multiplatform-leaderboard-2026-09-09-fixplan.md` — 21 of
the run's 26 findings. One theme runs through all of them, and it is the one 4.0.30 started: a
control that fails silently is indistinguishable from a control that passed, and an evidence token
that asserts more than it observed is worse than no token. Phase F targets a separate repository;
Phase G is filed upstream, not fixed here.

### Breaking

- **`tests_executed` is a required DV frontmatter field**, and `test_suite_compiles` is required
  alongside it whenever the count is `0`. A DV artifact without it fails
  `handoff-harness.sh --validate-frontmatter`. No migration: the field records something no reader
  could previously derive.
- **A frontmatter block with no `handoff:` key is refused by `state-patch.sh`**, which previously
  accepted a flat top-level shape through its awk fallback. An artifact with no frontmatter at all
  keeps the F3 fallback unchanged — only the malformed shape is newly refused.

### Fixed

- **F-01** — the dedupe gate no longer suppresses against a prior that executed nothing.
  `tests:0`, the new `discovered:<n>` token, `unrecorded` and any unparseable evidence now allow
  and write `test_dedupe_skipped_zero_prior`. This is the P0: a scheme with an empty test plan
  enumerated 49 cases, executed none, recorded `tests:49`, and then refused every later attempt to
  run them — so a platform reached a merge decision with zero tests executed.
- **F-01** — `test-execution-promote.sh` distinguishes discovery from execution. A count with no
  outcome vocabulary anywhere in the runner output is recorded as `discovered:<n>`, never
  `tests:<n>`. `executed` counts as outcome vocabulary; `executing` deliberately does not. The
  vocabulary is matched against the string leaves of an object response, never its serialised
  keys, so a response carrying an `error: false` field cannot pass an enumeration off as a result.
- **F-02** — every denial names the controls still in force. The dedupe denial previously named
  neither the authority holder nor the resolved test mode, which is why four stages escalated in
  one run each proposing a remedy a different arm would have refused again.
- **F-02** — DV records `tests_executed` and, at zero, `test_suite_compiles`. Compilation is
  checkable without test-execution authority, and it is the datum separating *gate-blocked* from
  *never built* — a distinction that stayed invisible for ten hours.
- **F-04** — the `facts.decisions[]` eviction spill has a reader: `state-patch.sh
  --read-decisions` returns ledger ∪ spill, ledger winning on conflict, a parse error or a
  symlinked spill being a failure rather than an empty set. Twelve decisions written for one task now all resolve; four
  were previously lost in silence, three of them cross-client parity controls.
- **F-04, F-15** — a partial `--facts` write records its casualties durably: rejected ids reach
  `audit.jsonl` as `facts_items_rejected` rather than stderr alone, and the post-write check now
  distinguishes *evicted to spill* (recoverable) from *lost* (in neither place). The old message
  asserted eviction unconditionally, and on the run that produced this finding it named four ids a
  later write had restored while four different ids were the ones actually gone.
- **F-05** — one frontmatter reader, `skills/worktask/scripts/frontmatter-lib.sh`, shared by
  `handoff-harness.sh` and `state-patch.sh`. The two previously disagreed about what a valid
  artifact looked like, so a flat-shaped artifact was unreadable to the boundary gate and still
  wrote a healthy ledger row.
- **F-06** — the second transport is now a literal command in every sweep-obligated agent.
  `qa-engineer.md`, `project-manager.md`, `stakeholder.md`, `team-lead.md` and
  `ethics-reviewer.md` carried no `--facts` invocation at all, so **every sweep item those stages
  emitted was structurally invisible to the FN gate** — the mechanism behind this run nearly
  losing its only blocker. Bare "both transports" phrasing is gone from every shipping surface.
- **F-09** — the DC contract requires cross-stream claims to be marked `consistency-checked, not
  executed`: under fan-out DC reads a tree that does not exist yet, and three of four documented
  paths were absent from the tree it was reading.
- **F-08** — security and networking claims in payload documentation must cite the stage and
  evidence that verified them, and QA treats an unverified one as a finding. A README asserting
  loopback binding shipped over a database on `*:5433` with a default credential and passed
  developer review; only a live probe caught it.
- **F-10** — `base-sanity` gains a `multi_parent_payload` degrade rung. Under fan-out
  `facts.files_modified` cannot be the union of independently-staged streams, so the rule blocked
  by construction on every fan-out — 140 PR files against 19 ledger files, cleared only with the
  sanctioned override.
- **F-11** — DV claims the ledger as its first write after the worktree pin (§ D0.0b), generalizing
  the `MANDATORY CLOSE` pattern that previously existed only in `technical-writer.md`. Three of
  four streams hit their turn ceiling with nothing staged, no artifact and the ledger still
  `in_progress`; all three carried a degradation order and ran out before reaching it.
- **F-12, F-13** — `§ Step B.1` routes **any** non-zero harness exit as a `missing_input` contract
  violation, with the named shapes demoted to an illustrative table, and states plainly that shape
  failures short-circuit so a fix may reveal further failures. The previous text enumerated three
  shapes and promised one-shot batching that shape-dependent checks cannot honour.
- **F-14** — the AR-reference warn distinguishes a malformed shape from a dangling file and names
  the expected bare form; both causes previously shared one message.
- **F-16** — a non-canonical `--artifact` name warns and names the canonical form.
  `hooks/anchor-preflight.sh` fails open on an unmatched name, so such an artifact was written,
  ledgered, harness-passed and never anchor-linted — which hid two missing required anchors.
- **F-18** — orchestrator loop step 4.7a lands AR's untracked non-`.context/` writes onto the ref
  DV forks from. AR holds no git grant, DV is inside the broken tree and FN runs last, so no stage
  could fix this; it has reproduced across three runs.
- **F-19** — `state-merge.sh` writes one `state_merge_noop` row per run when a SubagentStop carries
  neither stage nor artifact; the sentinel is keyed on `run_index`, so a later run in the same
  workspace gets its own row. Fail-open behaviour is unchanged; one run produced 335 of these and
  every sweep over `audit.jsonl` reported that boundary clean.
- **F-20** — an empty `open_questions` now requires the `## elicitation-sweep` heading. An empty
  array alone cannot distinguish "swept, nothing to ask" from "never swept", which is the rule's
  whole purpose. An absent field stays the required-field loop's single failure.
- **F-25** — the tree-fingerprint gap is documented accurately. Staged content **is** inside the
  digest, so committing is never needed to clear a denial; only untracked-file *content* is outside
  it. The finding's premise was wrong and is corrected rather than repeated.

### Not changed, after checking

- The fixplan's proposal to add `stage` and `status` to every agent's `--facts` stub was dropped:
  `state-patch.sh`'s `_sweep_defaults` already derives `stage` from the item id and defaults
  `status` to `open`, so the examples are correct as written and the addition would have been
  redundant tokens in eight agent files.
- `agents/product-manager.md` was not given a `--facts` example: PL's payload is canonical in
  `pl0-procedure.md § Union this stage's facts`, which carries the literal command. The exemption
  is pinned by a test so it cannot decay into a hole.

## [4.0.30] — 2026-09-08

Closes all thirteen findings from `corpflow-fix-plan-2026-09-07.md` across four parallel
development streams (dedupe/audit hooks, ledger-writer clamps, boundary harness, contracts/
commands/conventions/schema), plus gh#316. First authority-clean full-suite evidence of the
sequence: 1855 bats, all green, exit 0, 423 `@test` cases added over `develop` — earlier per-stream
tallies were taken mid-flight over a tree other streams were still editing and are not comparable.

Also carries a second parallel effort: closes all 26 prompt-audit findings (8 Critical, 18 Warnings) across 16 agents, 28 commands, and 23 skills (score 65/100). Two development streams addressed tool-grant coverage, normative corrections, and agent-template backfill. Full suite for this combined release: 1872 bats + 379 Python, exit 0.

### Breaking

- **`handoffs` re-keyed `<PREV_CODE>→<TASK_ID>`.** A stage split into four now writes four distinct
  edges instead of collapsing to one. No tolerant reader, no migration — readers must key on the
  new format.
- **`facts.decisions` and `facts.open_questions` clamps repartitioned per task** (8 and 4
  respectively), retiring the global rings of 8 and 12. A reader that assumed one shared ring across
  all tasks in a run will see a different item set than before. No migration.

### Fixed

- **F-18a** — `dedupe_invocation`'s default arm now folds `tool_input` into the dedupe key, not just
  the tool name, closing the credential-in-arguments exposure (security finding T6).
- **F-18b** — test-execution promotion is evidence-gated: `test-execution-promote.sh` derives one
  evidence token per run and a run whose evidence cannot be named is discarded, never promoted.
- **Phantom SubagentStop rows** — `audit-subagent.sh` suppresses and counts the ~31s-cadence
  repeats a dispatch fires, reporting them as one `subagent_stops_suppressed` row per window.
  The discriminator is a repeated `dedupe_key` within the trail: every stop the runtime delivers
  arrives with no stage and duration 0, so a predicate on those fields matched every genuine
  stop and emptied the trail — caught in review before release.
- **F-18c** — denial messages now name the evidence they were rejected against, rather than a bare
  refusal.
- **F-07a/b** — `state-patch.sh` rejects `--facts` per item; the valid remainder persists and exit 2
  fires only when something was actually rejected.
- **F-09** — the eviction spill covers resolved items, warns loudly on failure, and triggers off a
  live length comparison instead of a hard-coded bound.
- **F-21a/c** — `handoff-harness.sh` gains a reverse sweep-parity arm (a ledger id absent from the
  artifact frontmatter was previously invisible) and a decision-id divergence check.
- **F-06a/b/c** — the decisions and questions ledger writers are re-partitioned per task id, closing
  the eviction-without-spill path that let one stage's writes silently displace another's.
- **F-14** — `handoffs` re-keyed `<PREV_CODE>→<TASK_ID>` (breaking; see above).
- **F-15b** — the third-class sweep item now carries a concrete option set at the call site.
- **F-13** — `plant()`'s harness verification path fixed for the case this run's own review flagged
  (see Beyond-brief below for the residual gap).
- **F-17** — `cli-fallback.sh`'s `.txt` placeholder floor replaced by loud failure instead of a
  silent stand-in.
- **F-10** — `attach-visual-evidence.sh` gains a distinct `embed_cap` reason instead of an
  unlabelled truncation.
- **F-08** — four audit-log readers made tolerant and loud instead of silently aborting on the first
  malformed line.
- **F-04a** — `hooks/test-execution-gate.sh` gains a `scoped_test_run` arm on the Skill branch; a
  scoped `build-test` invoked as a Skill was previously classified `full_test_run` and denied
  regardless of its own `--only`/`--filter` scoping. The denial message now also names the resolved
  `test_mode`.
- **F-11a** — `state-patch.sh`'s decision/question eviction spill covers resolved items (folded into
  the same fix as F-09's trigger correction).
- **gh#316, closed.** The `facts.decisions[]` clamp now spills to `.context/decisions-<run_index>.jsonl`
  on eviction — append-only, sibling of the existing questions spill, no reader by design (matches
  the questions-spill precedent). Listed as an open follow-up in the 4.0.29 changelog; closed here.

### Prompt-audit remediation

#### Added

- **Two new predicates in `tests/shell/skills/skill-refs.bats`:** `ungranted_script_orders` (Predicate A, 7 tests) detects execution orders without matching grants, covering interpreter-prefixed paths, plugin-root variables, and bare basenames; `dangling_related_targets` (Predicate B, 5 tests) resolves `related:` entries and reports unresolvable ones. Both ship with planted-violation fixture trees and 2 repository-wide contract tests (14 named tests total, all green).
- **Agent template backfill:** `commands/create-agent.md § Body sections` gains required slots for `Example Interactions` and `Constraints (DO NOT)` sub-sections; 15 agents backfilled with `## Example Interactions` (5–8 user phrasings each); 10 agents backfilled with `### Rationalizations` and `### Red Flags — STOP` sub-sections.
- **Command structural gaps:** `## Examples` sections added to `appstore` (4 invocations), `request-plan` (4 per-class invocations), `worktask` (7 covering all unexampled options); `## Output Format` sections added to `appstore`, `megatask`, `worktask`; completion criteria rewritten on 5 commands to name their artifacts.
- **Agent differentiation:** two new `## Differentiation from Related Roles` tables resolve description collisions between `product-manager`/`stakeholder` and `team-lead`/`project-manager`.

#### Fixed

- **Grant coverage (Critical C1–C3, C13):** five worktask scripts (`branch-name.sh`, `refine-branch-target.sh`, `publish-pl-issue.sh`, `handoff-harness.sh`, `effort-ladder.sh`) added to `commands/worktask.md` `allowed-tools`; three megatask scripts added to `commands/megatask.md`; `commands/request-plan.md` matcher gains `bash ` prefix and `:*`; `agents/designer.md` gains `ToolSearch` grant with conditional step-1 delegation in `design-review.md`.
- **Audit command write grants (Critical C2):** `commands/prompt-audit.md`, `docs-audit.md`, `arch-debt.md` granted `Write, Edit` with `.context/audits/` output paths; `test-coverage.md` granted `Write`; all four gain `# tools:` comments.
- **Tool-grant comments (Critical C13, Warning W19):** nine bare `Bash`/`Task` grants annotated with `# tools:` comments; `appstore.md` narrowed to `Task(corpflow:release-engineer)`.
- **G3 invocation gate polarity (Critical C5):** `agents/prompt-engineer.md` restates G3 as "Does it **lack** standalone value…" (shared polarity with G1/G2); G4 tie-breaker re-anchored; `skills/csv-export-templates/SKILL.md` and `skills/preview-ensurer/SKILL.md` re-verified (both confirm pipeline-only via `disable-model-invocation: true`); `skills/dv-screenshot-capture/SKILL.md` scores G3 = no, gains flag.
- **Model tier correction (Critical C6):** `commands/create-agent.md` and `commands/prompt-audit.md` changed from `model: sonnet` to `model: opus`.
- **Link resolution (Critical C7):** seven `related:` entries in `skills/agent-coordination/SKILL.md` and `skills/estimation-methodology/SKILL.md` rewritten to file-relative form (../worktask/SKILL.md).
- **Accessibility version (Critical C8):** WCAG 2.1 → 2.2 across `agents/designer.md`, `commands/design-review.md`, `commands/design-accessibility.md`.
- **Section ordering (Warning W22):** example sections repositioned (W22) in `commands/milestone.md`, `ethics-review.md`; `tech-code-review.md` reordered with `## Your Job (read before you review)` preamble moved.
- **Argument-hint fixes (Warning W23):** `milestone.md` gains `|all`, `megatask.md` fixed to `<N>`.
- **Option examples (Warning W24):** 13 new examples covering 16 previously unexampled options across 5 commands.
- **Completion criteria (Warning W18):** rewritten on `designer.md`, `product-manager.md`, `design-review.md`, `design-accessibility.md`, `design-specs.md` to name artifacts.
- **Disclosure (Warnings W11–W13):** 15 agents gain `## Example Interactions`; 10 agents gain constraint sub-sections; `technical-writer.md` moves "DO NOT omit examples" from prohibition to required template slot.

### No code needed

- **F-21b/d** — the questions spill already existed since 4.0.29; the actual gap was that no command
  document read it. Fixed by documentation, not code.
- **F-15a** — the rejection message already named the enum; verified, not changed.
- **F-15c** — reopened at the user's request and reaffirmed as no-code: `defect`/`constraint`/`risk`
  are observations without an option set, so they remain follow-ups rather than sweep items.

### Beyond brief — defects this run discovered

Six defects surfaced while closing the thirteen findings, none in the original brief:

- **`run-tests.sh` has five widening paths to the full suite; only the weakest (`WIDE`) is guarded by
  `dv_in_progress`.** A scoped invocation can self-escalate past DV authority through the other four.
  **Deferred to its own worktask by user decision.** Cost: until it lands, no DV full-suite evidence
  in any run is authority-clean.
- **`state-patch.sh --stage DV --task-id DVn` without `--artifact` resolves to the stage's first
  instance**, so a fan-out stream can silently inherit a sibling's artifact and summary.
- **`plant()` proves *something* changed, not that *every* expression matched** — a compound `sed`
  passes when only one half lands.
- **`cache-lint --anchor-lint`'s DV allow-list omits sections `stage-contracts.md § DV` requires** —
  two internal specs disagreeing with each other.
- **`scan-secrets.sh` exits 133 outside its documented `{0,1,2}` contract, bypassing its own
  fail-closed arm.** QA established the trigger is cumulative (153 repo files plus one specific
  file), not the BSD-grep trap the script's own comment anticipates. No automated Pass was obtained
  for this run; SR's manual line-by-line pass over every added line compensates.
- **`.context/state.json` is 1859 tokens against a documented 500-token budget.**

### Process notes

- **This run reproduced its own findings while fixing them.** F-06 fired twice: AR0's eight
  decisions evicted all five of PL0's with no spill and exit 0, and QA confirmed eight decisions
  (`pd1`–`pd5`, `tl1`–`tl3`) are gone from the final ledger because those stages wrote before DV1's
  rescope landed. This is not a defect in the delivered code — it is the self-hosting risk
  `planning-0.md` predicted, and incidental proof the retired global ring was harmful. Those
  decisions are readable only from `planning-0.md` and `coordination-0.md`, not from the ledger.
- **Operator note**: an operator with a stale installed `.claude/hooks/state-merge.sh` should
  re-run `hook-install.sh`. That file is generated and gitignored; it was not edited by this change.
- **Post-review addition, user-directed and outside the finding set.**
  `skills/worktask/SKILL.md § Dispatch on the same turn (BINDING)` states that the orchestrator
  verifies a boundary and dispatches the next ready stage in the same turn, that a running
  background `Task` does not block it, and that only the plan gate, an `escalate`-class sweep item
  and the FN gate justify stopping mid-pipeline. It landed **after** DR, SR and QA reviewed the tree
  and after the version bump, so it did **not** go through the review the thirteen findings did. It
  is prose in an untested section — no code, test or other doc changed — so the suite evidence above
  still describes the shipped code exactly.
- **Six orchestrator rules moved from an operator's private config into the plugin**, same
  post-review status and for the same reason: a rule enforced from `~/.claude/CLAUDE.md` binds one
  operator and nobody else, which is the finding class this release closes. Delegation-only and the
  build-tooling corollary → `skills/worktask/SKILL.md § Delegation-only (BINDING)`; what counts as
  approval at the plan gate → `commands/worktask.md § What counts as approval — and what does not`;
  explicit per-stage model passing → `model-selection.md § Worktask stages: explicit, never
  inherited`; UI evidence from the running app → `stage-contracts.md § UI evidence comes from the
  running app (tpl-dv)`; spec-outranks-`git log` and the no-AI-footer rule →
  `git-conventions.md § This spec outranks git log`. Prose only, in five files, reviewed by nobody
  but the user who directed them.

## [4.0.29] — 2026-09-07

Three bodies of work, one still-unreleased version. A pull request opened against a branch the work never forked from
silently carries every commit of the intervening integration branch: a run whose own ledger
recorded 27 changed files opened a PR carrying 156 commits and 1008 files into `develop`, and every
existing finalization check passed — none compared the would-be PR diff against what the run itself
claims to have changed. Separately, thirteen remediation items from that same run's own findings
target a narrower theme underneath it: silent failure, writes that land nothing being
indistinguishable at the call site from writes that landed, and checks that pass vacuously. This
release adds the PR-diff comparison as a blocking check, surfaces fork-point evidence for
reconciliation rather than silent retargeting, corrects two documentation claims that made the gap
look covered, and closes out the remediation items — one of which was refuted on verification, three
of which shipped amended from how they were originally planned, and one of which was a fail-closed
false positive introduced by the fix itself and caught before it shipped. Dogfooding the new
base-sanity check during the remediation work itself turned up two more issues in the check, folded
in below as follow-ups rather than fixed here. Third: a plugin-wide shell-script simplification pass
consolidates plugin-root resolution, `.context/logs/audit.jsonl` appending, and `.context/state.json`
scalar reads behind three small shared libraries, extracts self-test bodies out of production scripts
into sibling harnesses, and fixes eleven defects found along the way. The honest headline is a shift
in *where* the code lives, not a bare line-count drop: production-only `.sh` line count fell by 3,448
(26,132 → 22,684), while harness/self-test files grew by 4,012 (1,949 → 5,961), for a net **+564**
lines across the corpus (28,081 → 28,645). The library extraction itself is net **+302** lines — it
reduced the number of *implementations*, not the number of lines.

### Added

- **`fn-preflight base-sanity` — a blocking wrong-base check.** It compares the would-be pull-request
  diff against the run's own `facts.files_modified` ledger record and fails when the PR is
  disproportionately larger (`pr_files > ledger_files * 3` **and** `pr_files - ledger_files > 20`);
  the second clause is a floor that keeps small runs out of the rule. The failure names both counts
  and the smallest-ahead candidate base, and states that the thresholds are wrong-base heuristics
  rather than diff-quality rules. It joins the composite `all` run in last position, so a block never
  suppresses `continuity`'s own `diverged` row. Seven degrade rungs — missing `jq`, no git,
  unresolved/unresolvable base ref, a guessed base, an unreadable ledger, an unreadable diff — each
  warn and exit 0, because a check that cannot see its inputs must not block a finalization. Six of
  the seven also write their own audit token. The `jq`-unavailable rung writes **no** audit row at
  all — the audit writer reads `worktask_id` and `run_index` through `jq` itself, so on a host
  without `jq` the row cannot be produced and the printed warning is the only evidence. Do not go
  looking in `audit.jsonl` for that one.
- **A documented, audited override.** `FN_BASE_SANITY_OVERRIDE` converts the fail arm into a warning
  carrying both counts and writes an `override` audit row with the raw value. The check is
  deliberately blocking, so the escape hatch is explicit and leaves a trace rather than being a
  `--no-verify` improvised at the moment of frustration.
- **`fork_base()` and `base_ref_source()` in `branch-lib.sh`.** `fork_base()` ranks remote branches
  by commit distance from `HEAD` and returns the nearest parent — the branch the work
  actually forked from, which is not always the branch it is configured to target. It ranks every
  remote ref, with no containment filter, which is its known ranking defect (gh#364). It returns empty
  rather than a sentinel on every failure path, so `v=$(fork_base)` cannot kill a `set -e` caller,
  and it is safe on a detached HEAD and in a repo with no remotes. `base_ref_source()` reports which
  rank of the resolution ladder produced a base, which is what lets a caller tell a confident answer
  from a fallback.
- **`fn-preflight` gains a `staging` check.** Catches unstaged-on-staged content that could
  otherwise reach a finalization silently. Built to this run's architecture-stage-amended
  predicate — the set intersection of `git diff --cached --name-only` and `git diff --name-only` —
  rather than the original plan's bare ` M` match, which would have fired on every normal FN run,
  since DC's own writes sit unstaged before FN's `git add`.
- **`hooks/test-execution-gate.sh` gains a `scoped_test_run` arm on the Skill branch.** There was
  none, so any scoped `build-test` invoked as a Skill was classified `full_test_run` and denied
  regardless of its own `--only`/`--filter` scoping. The denial message now also names the resolved
  `test_mode`, rather than leaving the caller to guess what the gate thought it saw.
- **`state-patch.sh` regains a spill path with real teeth.** The `facts.decisions[]` eviction spill
  now covers resolved items, warns loudly on failure instead of failing silently, and its trigger is
  a length comparison against the live clamp rather than a hard-coded `12` that could drift out of
  sync with the actual bound.
- **Three shared shell libraries**: `skills/shared/lib/corpflow-base.sh` (`corpflow_script_dir`,
  `corpflow_plugin_root` — mirrored byte-identically into `hooks/lib/corpflow-base.sh`, pinned by a
  parity test), `skills/shared/lib/audit-lib.sh` (`corpflow_audit_row`, the one
  `.context/logs/audit.jsonl` appender for the skills tree), and `skills/shared/lib/state-read-lib.sh`
  (`corpflow_state_str`/`corpflow_worktask_id`/`corpflow_run_index`, the read side of
  `.context/state.json`). All three fail closed under `set -e`, none uses `readonly` (bats sources a
  library twice per process; a second `readonly` assignment is `rc 1` and kills a `set -e` caller),
  and each opens with an anti-execution guard plus an include guard. Conventions and the source-block
  idiom: `skills/shared/lib/README.md`.
- **28 sibling test harnesses**, extracting self-test bodies out of 22 production scripts so a
  production script no longer carries its own test runner inline.
- **Step C.0a — a blocking `decision` item is resolved, not asked (#360).** A
  `blocks_next_stage: true` item of `effective_class == "decision"` used to stop the run for a human
  at every stage boundary; on the nine non-exception stages it is now handed to **the emitting
  stage's own agent, on its own model**, dispatched one effort tier up, and the loop continues. Same
  model by design — the stage assignment already reflects the work's difficulty, so moving it would
  change two variables to explain one outcome; one rung up is the cheapest thing that is actually
  different from the reasoning that already declined. Four conditions gate it, all required: the
  stage is not PL/FN/ST/IR (those keep their own surfacing, and PL's boundary *is* the plan gate),
  the item still blocks and is unresolved, `effective_class == "decision"` **after** the § Step C.2
  raise-only join, and `decision_gate == "auto"`. The join running first is the escalation guard: an
  item the orchestrator raises to `escalate` can never reach a delegate, so nothing here widens what
  a run may do unattended. One dispatch per boundary over the whole set, never one per item.
- **`effort-ladder.sh` — the effort ladder and the non-Opus clamp, as one executable copy.**
  `EFFORT_ENUM`, `effort_rank`, `effort_plus_one` and `effort_for_resolver`, sourced by the Step
  C.0a tier computation, by `state-patch.sh`'s enum gate, and by both bats suites — the same
  one-definition-several-consumers reason as `sweep-stub-lib.sh`, since a tier one caller accepts
  and another rejects is exactly the disagreement it exists to make impossible. The bump saturates
  at `max` rather than erroring, and is **clamped to `high` on a non-Opus model**: `xhigh` needs
  Opus 5 or Fable 5, and Sonnet silently downgrades the thinking budget rather than failing, so an
  unclamped bump would run one or two rungs below what its own audit row claims. No current stage
  hits the clamp — every non-Opus stage sits at `medium` or below — which is precisely why it is
  enforced in code rather than remembered: nothing in a run would show it if it started happening.
  The ladder is canonical in `model-selection.md § Effort Levels`; the bats suite asserts the two
  agree, and `matrix.tsv` gains R43/R44 so an edit to either side re-runs it.
- **`effort_transport` on every resolver audit row.** `metadata.effort` becomes `--effort` on the
  headless dispatch surface and is **advisory in-process** — `Task()` takes no effort argument — so
  the row says which surface it got: `dispatch-flag` or `frontmatter-only`. In-process the tier is
  recorded, not applied, and the resolver still runs. Recorded-not-applied is not a licence to reach
  the number another way: substituting a higher-frontmatter agent would trade the domain expertise
  answering the question for a field value. Rows also carry `effort_requested` alongside
  `effort_resolved`, because `xhigh`/`max` requested in a session with thinking disabled is sent as
  `high` and no clamp can catch that — the same reason `dispatched_agents[].model_resolved` exists.

### Changed

- **`fn-preflight base-sanity` resolves its base with fork-point fill enabled; every other reader's
  base resolution is unchanged.** Fork-point fill is opt-in — `resolve_base_ref` consults
  `fork_base()` only when passed `--with-fork-point`, only after ranks 1–4 have all come back empty,
  and only to replace the terminal `unresolved` result. `base-sanity` is the sole opt-in caller.
  Every other reader of the ladder — branch naming, continuity, tree preflight — sees byte-identical
  output to 4.0.28. The default is deliberately the fail-safe one: extra evidence reaches the check
  built to reconcile it, and nothing else silently changes which branch it thinks it is working from.
- **Fork-point disagreement is reconciled at the plan gate, never applied silently.** When PL0's
  configured base and the detected fork point differ, the run raises a non-blocking sweep item
  carrying both, for a human to settle. `--auto=[decision]` keeps the configured base. A resolver
  that retargeted a branch on its own authority would trade a visible wrong base for an invisible one.
- **The host-declared target branch is now a documented rank in the base-ref resolution order.** It
  always participated; it was simply absent from the written ladder, so readers of
  `handoff-protocol.md`, `pl0-procedure.md` and `workspace-modes.md` could not account for a base the
  code had actually chosen. All three now list the same ranks in the same sequence.
- **`state-patch.sh --facts` rejects per item, not per payload.** A mixed submission — some valid
  sweep resolutions alongside some malformed entries — now persists the valid remainder and exits 2,
  rather than discarding the whole payload because part of it was bad. Structural problems (a
  non-object payload, an empty object, an unknown key, a non-array value) remain whole-payload
  refusals; only item-shaped content gets per-item treatment. This was reproduced live against the
  pre-fix script during this run's own ledger writes before the fix landed.
- **`metadata.description` is capped at 240 characters on the two ledger write paths**
  (`--task-create --metadata` and `--task-meta --set`) — truncated with an ellipsis, never rejected,
  since a refused `--task-create` would break stage creation outright. The cap deliberately does
  **not** apply to the orchestrator's own dispatch-site description appends: those are transient
  and never persisted, and capping them would strip the test-scope, ban, and FN banners they carry.
- **`handoff-harness.sh` gains a reverse sweep-parity arm.** Previously the parity check only caught
  an id present in an artifact's frontmatter but missing from the ledger; an id sitting in the
  ledger with no matching artifact stub was invisible. The arm is scoped by **task**, not stage:
  a split DV (DV0/DV1) shares one `.stage` slice, so a stage-scoped version charged each stream
  with the other's stubs. An artifact carrying stubs is charged only ledger ids under its own
  `sw-<TASK_ID>-` prefixes; a stub-less artifact is charged the stage slice only when the ledger
  holds at most one task of that stage. It also gains a `files_touched` structural
  cap (`FILES_TOUCHED_MAX = 10`: first ten paths plus one `"+ N more"` marker) and a check that a
  frontmatter `key_decisions[]` entry does not diverge from its artifact-body counterpart — narrowly
  scoped to fire only when the two share no significant vocabulary or disagree on a quoted number,
  since an artifact's frontmatter summary is a paraphrase of its body by design.
- **`cli-fallback.sh` drops its `.txt` placeholder floor.** A placeholder file that satisfies an
  existence check proves nothing about whether a capture actually happened; the floor is replaced by
  loud failure, and downstream consumers (`adhoc-visual-evidence.sh`) now accept only exit 0 plus a
  non-empty file on disk as evidence of a real capture.
- **`attach-visual-evidence.sh` reports a distinct `embed_cap` reason.** A cap-truncated evidence set
  was previously reported as `reason: "ok"`, indistinguishable from an uncapped run. The body's
  cap note says "hosting is healthy" only when no row failed to host, since both can fire in one
  run and the reason already reports that as `embed_cap+<host reason>`.
- **`state-patch.sh` carries a `--facts` partial rejection out of every paired-`--stage` exit.**
  The idempotent re-completion, absent-ledger, unresolved-artifact and unparseable-stage no-op
  returns all exited 0 and hid the exit 2 the caller was told to branch on; a rework round takes
  the idempotent path by design.
- **Four audit-log readers made tolerant of malformed lines.** `stale-check.sh`,
  `post-compact-recovery.sh`, `audit-dedup.sh`, and `build-context-set.sh` now skip an unparseable
  audit row, count it, and warn on stderr, rather than aborting the whole scan on the first bad line.
- **10 of 11 audit emitters route through `audit-lib.sh`'s single appender**, replacing their own
  inline `jq -nc` construction with the shared one-writer, one-key-order, symlink-refusing path.
- **`skills/shared/plugin-root-resolution.md` now names the one resolver that exists.** It previously
  pointed at three "reference implementations" that were three *different*, disagreeing
  implementations of the same walk, and measurement during this run found only 4 of 69 scripts in the
  repository actually followed the rule the doc stated. It now names `corpflow_script_dir()` /
  `corpflow_plugin_root()` in `corpflow-base.sh` as the single implementation to source.
- **`prefix_lint` reduced from ~29 subprocess forks per log line to 4** — a 20-line log that took
  1,139 ms now takes 252 ms.
- **`publish-pl-issue.sh`'s header shrank from 161 to 58 lines**, moving plugin-root resolution and
  ledger reads onto the two new shared libraries.
- **Dead-code shellcheck classes eliminated: 7 → 0.**
- **`metadata.effort` is mandatory on a non-PL task row, and validated at the write (#360).** It
  left the optional dispatch-metadata set when Step C.0a began reading it; the two axes are
  independent, and only one moved. As a **ledger record** it is now required — the resolver bumps
  it, and a per-stage override exists nowhere else, so agent frontmatter is the wrong fallback: a DV
  sub-task dispatched at `xhigh` runs at a tier `developer.md`'s `effort: high` never mentions. As a
  **dispatch flag** it stays advisory, unchanged. `state-patch.sh` checks it against `EFFORT_ENUM`
  on `--task-create` and `--task-meta` only, so `--task-status`/`--task-block`/`--task-replay` are
  untouched; the test is `has("effort")` rather than `.effort // empty`, because the alternative
  operator reads JSON `null` and `false` as absent and a required field must not be erasable through
  its own gate. An off-ladder value would otherwise surface as a failed resolver dispatch a stage or
  more later, rather than at the write that introduced it. Absent still passes — older ledgers
  predate the field, and Step C.0a skips such a row (`resolver_skipped`, `reason:
  "effort_unstamped"`) rather than guessing a tier, costing a round-trip instead of the run.
- **`stage-codes.md` gains an `Effort` column on both tables**, primary and support, as the lookup
  the orchestrator stamps alongside `model`. Still no third copy.
- **Step C.3 drops the fable-plus-credit-fallback path.** The FN-gate batch now resolves on the same
  rule as C.0a — each item's own emitting stage's agent and model, grouped by originating stage, one
  dispatch per group — and the `facts.capabilities.fable_dispatch == "credit_blocked"` branch goes
  with it. Step A.4 is deliberately **not** folded in: PL is an exception stage whose boundary is the
  plan gate, where a user is already present under `checkpoint`.
- **A resolver's `deep_reads` is exempt from the B4 fan-in tripwire.** It deep-reads by construction
  — the ≤200-token stub cannot carry an `options[]` body — so counting it would fire the signal on
  every run that resolves anything and make a real one unreadable. The two are told apart by the
  audit row the reads belong to.

### Fixed

- **`label-align.py` weighted the held-out tranche against a population it was never drawn
  from.** Strata were re-derived as `(split, grader_verdict)` rather than taken from the draw
  `sample-for-labelling.py` actually cut (`dev/<verdict>` over the dev split, plus
  test/held-out taken whole). All 18 labelled tranche cases therefore landed in a stratum
  whose population was the entire 82-case `test` split and carried a weight near 4.6 — an
  extrapolation of a deliberately harder tail across cases it does not describe, when weighting
  assumes a random draw within the stratum. Two faults travelled with it: `--min-id` and
  `--split` narrowed the labels while `population` and `p_obs` were still built from every
  grade, so the documented "held-out TPR/TNR only" invocation returned corpus weights and the
  corpus pass rate; and `--min-id` alone never isolated the tranche, because batch 5 seeded 12
  dev cases in the same id range. `--sample` now takes the populations from the draw and
  **refuses (rc 65)** when the labels do not sit in the strata it records, `--stratum` selects a
  tranche exactly, a `defer` counts as drawn but not as sampled so one deferral no longer reads
  as a frame mismatch, and `--p-obs` supplies the observed rate when the gitignored responses
  are gone. Six regression tests. **Published numbers restated:** 0.3.0's corrected rate moves
  87% [82–92] → **86% [82–90]** and its held-out row 88% [81–88] → **89% [83–100]** on one human
  negative; 0.2.0's corrected rate is **withdrawn** outright, since its draw records dev/pass
  25 / dev/fail 17 against labels carrying 30 / 12. Every label-only quantity — TPR, TNR, the
  confusion matrices, the paired A/B, the flip and contamination analyses — is unaffected, as is
  the fully-labelled 0.0.1 baseline.
- **`build-review-page.py`'s label store was scoped by eval-set version but not by skill.**
  `localStorage` is one partition across all `file://` pages, so the moment a second eval set
  shared a version the two label stores would have merged with no symptom. The key now derives
  from the eval set's own `skill_name`, as do the page title and `<h1>`.
- **`tests/python/test_eval_capture.py` ran 49 of its 129 tests when executed directly.** An
  `if __name__ == "__main__": unittest.main()` block sat mid-file, so the 14 classes defined
  below it did not exist yet when the runner collected. `run-tests.sh` uses discovery and was
  never affected, which is why it went unnoticed. Moved to EOF.
- **`evals/README.md` described `failure-labels.jsonl` as a corpus rather than a contract.** The
  file has never been written: Step 5b is an agent step, not a hook, so the 100-row taxonomy gate
  stands at 0 of 100. Also corrected two skill ids that resolve to nothing
  (`evals-skills:error-analysis` → `evals:error-discovery`, `evals-skills:validate-evaluator` →
  `evals:validate-evaluator`) and a version paragraph still claiming the spec pair reads `0.2.0`
  — both `SKILL.md` and `eval_set_version` are `0.4.0`, while the last capture is `0.3.0`, so no
  number in the directory describes the shipping skill.
- **`fn-preflight continuity` claimed a guarantee it does not provide.** Its description implied it
  would catch a wrong base; it checks that the branch has not diverged from *its recorded* base and
  cannot discriminate whether that base was right in the first place. The description now says so and
  names `base-sanity` as the check that does discriminate.
- **Three stale "Implemented in `fn-preflight.sh`" attributions** for `resolve_base_ref`, which lives
  in `branch-lib.sh`.
- **`dv-tree-preflight.sh` no longer claims parity with the canonical ladder.** Its comment now admits
  the reduced ladder it actually implements.
- **A round-1 fail-closed false positive, caught mid-run and fixed before shipping.** The first pass
  at the per-item `--facts` fix rejected an all-empty `--facts` payload as "no valid items" and
  exited 2, aborting the paired stage patch — exactly the payload shape the closing-sweep contract
  tells every stage to emit when it has nothing new to report. The refusal now requires both nothing
  kept **and** something explicitly rejected; an empty, nothing-rejected payload is a no-op success.
- **`base-sanity` resolved its base to a stale local `develop` ref rather than its remote-tracking
  counterpart, found by dogfooding it in this run** (`0bd7df5`). refs/heads/develop sat nine commits
  behind refs/remotes/origin/develop, and `HEAD` was exactly equal to origin/develop. Against the
  stale local ref the check reported "a PR against develop would carry 55 files" and blocked; against
  origin/develop the diff is 0 files — the check built to catch a wrong base picked the wrong base
  ref itself. `resolve_git_ref` now prefers `origin/<base>` over a diverged local ref, covered by AC-4a
  in `tests/shell/worktask/fn-preflight.bats`. The ladder still knows only the `origin` remote, so a
  fork workflow whose base tracks a different remote is not yet correct (gh#353).
- **`cache-lint.sh`'s `extract_stage` failed open, not closed, on a yq failure.** It fell back to an
  `awk` extraction only when `yq` was *absent*; when `yq` was present but failed on a given input,
  the function returned whatever `yq` produced rather than falling back, and QA's own run this cycle
  produced zero anchor coverage from exactly this path. Deferred earlier in this release, then fixed
  before shipping: the fallback is now keyed on `yq`'s exit code, not its presence.

### Evals: label pipeline repair, batch-6 captures, and 0.4.0 calibration

- **`map-and-filter.sh` half-closed join dropped every hook and script edit from the label pipeline (#359).** `build-context-set.sh` Source 4 resolves audit-log basenames against four shapes: hooks/, hooks/lib/, scripts/, and skills/*/scripts/. Rule 1 only emitted `.md` prompt files as targets, making hooks and bundled scripts unmatchable by construction. Every user edit to a hook or helper script died at rule 17 DISCARD. Rule 1 widened to all four shapes, keeping test-file precedence and anti-recursion precedence intact. The fix is caller-scoped; the shared resolver is untouched. `evals/failure-labels.jsonl` received its first 7 rows (from 0 since 4.0.10); `map-and-filter.bats` expanded 9 → 13 tests (all pass).

- **Batch 6 (ids 213–270) and the first calibrated 0.4.0 rates.** The 26-case `adjacent` analysis (see `evals/findings/request-plan-0.4.0.md`) overturned the 0.3.0 reading: zero of batch 5's three labelled adjacent failures are genuine; the confound is the surface pool. Batch 6 was sized 30 buried / 18 adjacent / 10 absent to ground on the measured-genuine-negative pool (`buried`, registry-excluded surfaces) and the enumerated-registry surfaces (`adjacent`; confound repaired). No obvious or refute cases (the first yields no measurement; the second has a known false-negative floor). Corpus grew 201 → 259 (182 plan / 45 clarify / 32 refute). Two byte-identical captures recorded 259 cases each at imputed cost $207.10 and $209.65 (pair total $416.75, under $500 approved). Human labelling of a 60-case draw produced corrected 0.4.0 rates: **85% CI [81%, 91%]** (TPR 92%, **TNR 100% on 18 human negatives**, full-set); held-out **83% CI [70%, 100%]** (TPR 84%, **TNR 100% on 4 human negatives**). The held-out interval reaches 100% because n=4 — that is what four negatives look like. Corrected rates rest on capture #1 verdicts; the 17.1% run-to-run flip rate (below) means the CI covers sampling error only, not run-to-run variance. The 0.4.0 drifted-rule reconciliations (three copies of rule text, each contradicting the others) predicted a handful of affected cases against this noise band, so they were never measurable by a capture pair. **No delta is attributed to them** and the `evals.json` grading entry stands unamended.

- **The run-to-run flip rate is the headline finding.** Two byte-identical captures agree within 0.8 pp in aggregate (78.7% vs. 79.5%) while disagreeing on 44 of 258 paired-complete cases: 21 shifted pass→fail, 23 fail→pass. Flip rate: **17.1%**. This reproduces 0.3.0's 16% on a larger corpus (201 → 258 cases), elevating it from an observation to a property of this eval. Evidence committed as `evals/findings/request-plan-0.4.0-verdicts.jsonl`. With a noise floor this wide, any single capture verdict is roughly a one-in-six coin flip, and no A/B comparison can resolve an effect smaller than roughly 44 cases.

- **Coverage decision for the other 22 invocable skills.** 23 skill directories exist; 22 carry `SKILL.md` and are invocable. All 22 were ranked on whether a case output can be code-checked against an expected value (without human judgement or network requests) and whether the capture surface can produce that output — ranks 9, 15–18 are depressed by capture constraints (no fixtures, no simulator, no transcript replay), not output determinism. Top candidate: `estimation-methodology`, the only skill with an in-repo numeric oracle (`estimate-calc.py` computes expected story points from size and five factor inputs). No second eval set is committed until the failure-taxonomy gate (oracle run + ~100 label rows) has material; no build, schedule, or funding language appears in the coverage decision.

- **Two grader defects repaired, ground truth only — no spec change and no re-capture (#359).** The 60-case labelling pass measured the harness as over-strict and never lenient (18 human failures, all caught, **zero false negatives**), so both repairs subtract failures at no cost in recall. **Mode A:** nine cases carried `expected_outcome: plan` while being refutations of a false premise (78, 79, 104, 191, 216, 220, 225, 226, 252); they are relabelled in `gen-request-plan-cases.py`'s `REFUTED_PREMISE` table, never in `evals.json`, whose case array is regenerated wholesale — the corpus is now 173 plan / 45 clarify / 41 refute and the held-out tranche 17 plan / 2 refute / 4 clarify, with none of its four genuine negatives (229, 231, 241, 262) affected. Registering case 191 first required word-boundarying the generator's echo lint and its sibling in `test_skill_evals.py`: the character strip set ate the `s` of `\s`, turning `holds?` into `hold`, which a bare substring test then found inside *stakeholders*. Measured: exactly one corpus-wide error dropped, none added. **Mode B:** `classify_outcome` no longer lets a question mark below the section quorum decide the verdict — case 43 landed on both sides of it across two captures of the same response shape. The repair is **one-directional** by construction (`plan` may become `clarify`, never the reverse) and pinned by a property test over every stored response; the reverse form was measured and rejected because it read four genuine questions as plans. Across both captures 36 responses change class, **0 pass→fail**. `eval_set_version` stays 0.4.0, the two captures stay comparable, the recorded `eval_set_sha256` on the verdicts file is deliberately left pre-repair, and no corrected rate is republished — post-repair the harness disagrees with none of the 59 graded labels, so the correction collapses to the corpus observed rate and is in-sample only. The published 85% CI [81%, 91%] still reproduces.

- **`label-align.py --min-id` is refused under `--sample` rather than silently mis-weighting (#359).** A draw's populations are per stratum and whole; an id floor cuts inside one, which the drift check then reported as a moved grade set — the wrong diagnosis — and `--allow-stratum-drift` went on to weight a partial stratum by its full population. The flag now exits 64 with a message naming `--stratum` as the selector to use instead. Unchanged on the `--grades` path, where narrowing the population and `p_obs` by the same predicate is the correct behaviour and stays.

All label-derived quantities carry their denominators explicitly. The 85% and 83% rates measure the grader against humans, not a before-after comparison on the 0.4.0 rule changes.

### Known follow-ups

- Three private base-ref ladders remain divergent from the canonical one in `branch-lib.sh` —
  `dv-tree-preflight.sh` (now documented as reduced, not unified), `attachments-preseed.sh`, and
  `adhoc-visual-evidence.sh`. The adhoc one diverges further than the other two: its own
  `resolve_base_ref` falls back through the literals origin/main, origin/master, main and
  master, which is the hardcoded-literal shape the canonical ladder documents as forbidden.
  Unifying them was scoped out of this release deliberately: the resolver is on the preflight hot
  path and each additional caller changes the cost profile. They are correct for their own callers
  today; they are a consolidation debt, not a live defect.
- **`facts.files_modified` under-recorded 15 files this run** — the ledger listed 18 while 33 files
  were dirty in the working tree. That field is `base-sanity`'s other input; it did not trip the
  thresholds here (they need both `>3x` and `>20`), but it leaves the check's second input
  unreliable, and a larger gap on a smaller ledger could.
- **gh#316 remains open.** The `facts.decisions[]` clamp still evicts an entry with no spill file
  recorded — reproduced four times during this run's own ledger writes, most recently by the
  developer-review stage's own write, which evicted three of the architecture decisions its own
  confirmations rested on. A second spill path was judged out of scope here: it is a new eviction
  mechanism with no analogue to the existing "resolved-first" rule, and adding it inside the
  highest-risk edit of this run's sequence was the wrong trade.
- **The reverse sweep-parity arm may false-fail on a rework round**, accepted as a follow-up rather
  than fixed this round.
- **Two seam-dependent spill-failure WARN arms in `state-patch.sh` remain untested.** Reaching either
  requires the caller's own merge filter to fail inside the spill function while succeeding in the
  atomic apply, which no external invocation can currently arrange; adding a test-only seam to the
  ledger's single write chokepoint was judged a larger risk than the untested branches themselves.
- **The decision-id divergence extractor does not match the `- **id — title.**` bullet form** used
  by this repository's own architecture artifacts, so it is near-inert against that style today.
- **Two P3s on the new spill-append regression test**: its stderr assertion matches wording but not
  the exact unrecorded count, and it relies on `chmod 0444` denying a write, which would not hold on
  a CI image running as root.
- **Refuted, for the record: no change was made to the screenshot capture scripts.** They were
  reported as interpolating malformed JSON into `audit.jsonl`; on inspection they already build
  every audit row with `jq -nc --argjson`, so there was nothing to fix.
- **`scan-secrets.sh` exits 133 on a repo-root scan.** Pre-existing, reproduced during this run, not
  fixed here.
- **49 mid-body bare `[[ ]]` assertions are vacuous on bash 3.2** (macOS's default shell) but binding
  on bash 5.2 (CI). They pass silently on a contributor's Mac and only actually assert in CI. Left
  as-is; a fix needs either a bash-version floor bump or per-assertion conversion, both out of scope
  here. Tracked as a follow-up alongside the two above.
- **`cache-lint.sh anchor_lint` does not yet recognize `development-N-<stream>.md` fan-out
  artifacts.** `hooks/anchor-preflight.sh` already routes the stream form into the lint
  (`ARTIFACT_RE='...|development-[0-9]+(-[a-z0-9]+)*)\.md$'`), but `anchor_lint` in
  `skills/worktask/scripts/cache-lint.sh` has no anchor set for it, so every stream artifact with
  legitimate extra sections (`commits`, `verification`, `deferrals`, `defects-fixed`, `inherited
  failures`, `sr0-remediation`, etc.) now fails `--anchor-lint`. The fix needs a relaxed rule per
  `handoff-protocol.md#anchor-allow-list` — required DV anchors plus `elicitation-sweep` stay
  enforced, extra H2s are allowed — not a full exemption, since the ledger already points at
  `development-0-<stream>.md#elicitation-sweep` from `sw-DV0-1`, `sw-DV3-1`, and `sw-DV4-1`.

### Notes (shell-script simplification)

- **`development-0.md` and `development-0-defects.md` each carried the same false claim** —
  "every one of the 25 [workspace-root ladder] sites is classified" — and each is now retracted at
  its own site rather than only corrected here: five sites (`publish-pl-issue.sh:85,:93,:113`,
  `attach-visual-evidence.sh:83`, `adhoc-visual-evidence.sh:53`) were never classified. Raised by
  developer-review as P1-2's sibling finding; left uncorrected through security-review and QA and
  fixed in this documentation pass.
- **17 self-test cases dropped** during the harness extraction, each licensed by a mutation test and
  confirmed still covered by the surviving suite.
- **11 defects fixed** along the way; six other reported findings were investigated and refuted with
  evidence rather than fixed: the `state-merge.sh` "committed duplicate" file does not exist (the
  installed copy is untracked, not committed), the here-doc test-gate hazard does not reproduce, six
  apparently-unused variables are live via dynamic scope (not dead code), a standalone
  `manifest-lib`/`selftest-lib` extraction was measured and judged not worth building, and the
  reported workspace-root call-site count was itself wrong (measured as 21 files / 25 sites, not the
  originally reported 14).

## [4.0.28] — 2026-09-03

Twenty-six fixes from a six-angle code review of `develop 6e09ea8..0dd3d6d`, banded by the priority
the review assigned them, plus the closing-sweep transport-divergence fix found during OV-183.

### Fixed

- **A sweep item's two copies could disagree, and nothing looked** (OV-183). `sw-DV0-1` carried
  `blocks_next_stage: false` in its own artifact and `true` in its ledger stub;
  `--validate-frontmatter` passed, the orchestrator read the ledger, applied the raise-only join and
  held a boundary gate before DR for a QA-scoping question its author had already marked
  non-blocking. Three defects, fixed together:
  - `state-patch.sh` `_sweep_join` ORed the flag, so once `true` reached the ledger nothing could
    clear it — not even the author's own explicit `false`. Stickiness now fires only when the
    incoming stub omits the key, which is the case the comment above it always described.
  - `handoff-harness.sh check_sweep_ledger` compared ids and nothing else, so field divergence was
    invisible permanently, not just at the boundary where it fired. It now compares `class` and
    `blocks_next_stage` for every id present in both transports and refuses — it never reconciles,
    because picking a winner would be guessing which copy the author meant.
  - `stage-contracts.md § Self-labels raise, never lower` had no arm for transport divergence, so
    the orchestrator reached for the nearest rule. The lattice is now explicitly scoped to
    *labellers*; two copies with one author are a defect, not a lattice.

- **Contradictory escalation-under-bypass rules** (P1a). `skills/shared/stage-contracts.md`
  commanded opposite behaviour for the same escalation item across four surfaces depending on
  which one a reader consulted; the rules now agree everywhere.
- **Lint/doc/data mismatches** (P1b): `cache-lint.sh` rejected the two H2 headings
  `agents/software-architector.md` itself mandates, failing every architecture merge on contact;
  the eval split manifest's held-out note had gone stale against the code; `resume.md` prose
  contradicted what the implementation actually does.
- **Six live-repro behavioural bugs, each now fails closed** (P1c): an empty sweep-stub `ref`
  passed all three validation checks; `corpflow_resolve_pin` could return a pin from an already
  completed row; `stale-check.sh` exited with the "needs human decision" code (`1`) on a usage
  error instead of `2`; a contamination-detection pattern matched benign prose; `eval-capture.py
  --dry-run` printed an argv it would not actually run; `--budget` was advisory rather than a hard
  ceiling.
- **Model-switch gate trigger axis now fails open** (P2), matching the destination axis it
  previously diverged from; dead `read_stdin` code path removed.

### Changed

- **`blocks_next_stage` is now a required sweep-stub field** on both transports, enforced by the
  frontmatter shape gate and by `--facts`. Absent-vs-`false` was exactly the ambiguity that let the
  two copies disagree, so the author states the value rather than having it inferred from its own
  omission. Every per-stage template, agent payload example and schema `required[]` set carries it.
- **Consolidated duplicated logic** (P3/P4): hook-side model-switch checks now share
  `model-switch-lib.sh`; eval loaders now share `eval-engine.py`. Hot paths were cut along the way —
  capability-registry load measured 2.38s → 0.69s with byte-identical output.
- **Deduplicated documentation** (P5): the raise-only sweep lattice statement and the sweep-answers
  rationale each now appear exactly once, with pointers from every other site that used to restate
  them.

### Corrected

- `development-0.md:52` described R-7 as shipping `held_out_from: 168`; that key was deleted
  during review remediation (ledger decision `dr-6`) and the row was stale against the tree. The
  merged development artifact has been corrected to match what actually shipped: no
  `held_out_from` key.

### Known issues (tracked, not fixed here)

- `cache-lint.sh --anchor-lint` still fails on two `## remediation — …` H2 headings in
  `development-0.md` that are outside cache-lint's DV anchor set. Left as-is rather than demoting
  the headings — they are the audit trail for two review blockers.
- Test suite carries 4 pre-existing failures (2 `AC-3 twin`, 1 `PL-3` in
  `tests/shell/skills/elicitation-sweep-contracts.bats`, plus `tests/shell/worktask/section-lint.bats`
  case 6 on 6 inherited `CORPFLOW.md` template sections over the 1000-char cap), all red at `HEAD`
  and outside the scope of these 26 fixes; verified at baseline parity, not quarantined.

## [4.0.27] — 2026-08-29

Claude Code **2.1.234 → 2.1.251** integration. The band's theme is cross-agent and cross-session
communication, and the plugin surface that moves most is the resume loop: almost every entry either
makes a message's fate observable or removes a false negative from agent discovery.

### Added

- **`PreModelSwitch` / `PostModelSwitch` hooks** (`hooks/model-switch-gate.sh`,
  `hooks/model-switch-audit.sh`, shared `hooks/model-switch-lib.sh`). The gate refuses a
  mid-worktask re-tier away from a stage's pinned `metadata.model`; the observer records
  `model_switched` so cost is attributed to the model that ran. The gate **fails open by
  construction**, not by convention: a block is reachable only once the destination-model coalesce
  matches a real payload field, so a wholly wrong schema guess degrades to annotate-or-silent
  rather than wedging every session that switches models. The payload schema is unconfirmed —
  2.1.251 postdates every doc in this repo — and carries a CONFIRMED/ASSUMED split in the script
  header per the `headless-dispatch.md § Schema Versioning Watch` discipline. The **pin** is not
  guessed: it is read from `facts.dispatched_agents[].model_requested`. Three bats files (39
  assertions), both anti-vacuity guards mutation-verified against a matcher that always returns
  empty and one that collapses every model to a single family.
- **`handoff.cross_session_ask`** — an optional handoff field naming who to ask and what, legal
  alongside `verdict: "blocked"`. A subagent's `SendMessage` to another *session* delivers the
  reply into the parent conversation, so a stage that sent its own ask would wait for something
  that structurally never arrives; the stage names the ask and the orchestrator sends it
  (new orchestrator arm **Step 6.5a3**, resume branch **§ Reply routing**).
- `stale-check.sh` classifications **`reattach-undeliverable`** and **`hook-config-broken`**, with
  three new bats cases including a last-wins anti-vacuity guard.


- **Closing elicitation sweep — every stage now has to ask.** Before handing off, all thirteen
  stages emit a typed `open_questions[]` sweep: 2–4 options with exactly one marked `recommended`,
  a one-line rationale, and a `decision`/`escalate` class. A stage with nothing to ask emits an
  explicit empty array plus a "nothing to elicit" line — silence is a contract violation, because
  an omitted sweep and an empty one are otherwise indistinguishable. Contract:
  `skills/shared/stage-contracts.md § Closing Elicitation Sweep`; schema: `$defs/SweepItem` /
  `$defs/SweepStub` in `handoff-protocol.md`. Strict from this release: no warn-only mode, no
  opt-in environment variable, no per-stage exemption.
- Agents emit; the orchestrator alone asks. Non-planning sweeps accumulate in the ledger and render
  at the **existing** FN gate in batches of ≤4, grouped by originating stage, immediately before
  the approve/reject call — which fires last and unmodified. No new gate, no per-stage round-trip
  (`commands/worktask.md § Step C`; loop step 4.9 (a1)(a2)(c+)).
- Sweep stubs reach the ledger because each stage writes them: `open_questions` is now part of
  every agent's `state-patch.sh --facts` example, and
  `handoff-harness.sh --validate-frontmatter --state` fails a stage whose frontmatter
  stub never reached `facts.open_questions[]`. The orchestrator runs that invocation at **every**
  stage completion (`commands/worktask.md § Step B.1`, loop step 6.5c), not only at DV, and an
  unreadable ledger fails the parity check instead of skipping it. Without that pairing the sweep
  was schema-valid, harness-clean, and silently dropped before the FN gate for 12 of 13 stages.
- A closing-sweep stub's `ref` anchor is now verified to exist: `handoff-harness.sh` resolves each
  stub's `ref` against the artifact it names and fails on a dangling one. The stub
  carries no `options[]`, so that anchor is the only transport of what the FN gate renders — a
  dangling ref would have made the orchestrator skip the item or invent its options. The three
  sweep checks are fail-closed: a yq read error, a non-string id, or a scalar `open_questions`
  each fail by name rather than pass, and a ref spelled with the artifact's own directory
  (`.context/<artifact>-N.md#…`, the `refs:` convention) resolves to the artifact itself.
- `## elicitation-sweep` is a **mandatory** H2 anchor in every stage artifact — the full items or
  the explicit empty statement — enforced by `cache-lint.sh --anchor-lint` for all 13 stages with
  no grace for artifacts written before this release. It is a single universal-anchor constant, not
  thirteen per-stage rows.
- **A sweep item can be answered at its own stage boundary.** `blocks_next_stage: true` on an item
  routes it to a render immediately after its emitting stage completes, before the next stage is
  dispatched — because a next stage that builds on a guess is what the sweep exists to prevent.
  Everything else still batches at the FN gate. This adds no gate and changes no gate's firing
  condition; the flag is set per item, never per stage. It is orthogonal to `class`, and joins
  raise-only by OR, the same monotone idiom `decision < escalate` already uses
  (`commands/worktask.md § Step C.0`; loop step 6.6).
- `commands/worktask.md` and `commands/megatask.md` now declare `AskUserQuestion` in
  `allowed-tools`; both called it from their bodies without declaring it.
- **Stratum-weighted calibration.** A labelling budget smaller than the corpus forces an enriched
  sample, and selecting on the grader's own verdict while measuring agreement with it biases both
  rates. Each case now carries population/sampled; verified against the 0.0.1 labels, an enriched
  sample reads TPR 42% unweighted against a population truth of 63%, and 63% weighted.
- **Seeded bootstrap confidence interval**, stdlib only — no point estimate, no interval.
- **`sample-for-labelling.py`** — picks the labelling sample by design: even split across harness
  strata, held-out tranche taken whole, seeded.
- **`scan-contamination.py`** — measures what a capture still leaks after the strip, by channel.
  The scan was itself wrong in both directions before being pinned by tests: 12% on false
  positives, then 2% on missed phrasings.

### Changed

- **The resume loop checks the result of its own `SendMessage`.** Every row that said "reattach via
  `SendMessage`" assumed the send succeeded; CC 2.1.234–2.1.238 make `refused`, `dropped`,
  `oversized`, `burst_limited` and `session_list_truncated` observable. Anything but delivered
  leaves the stage parked, spends no `retry_count`, and — for a truncated session list — makes any
  "agent gone" verdict *unconfirmed rather than established*, so it can never justify a
  re-delegate. **This is what the min-CC floor bump rests on.**
- **A `maxTurns` partial return routes to the reattach arm**, not a re-delegate. Step 6.5a2's
  incomplete test gained an OR-branch on the partial marker, independent of whether a verdict was
  written, and `metadata.reason` gained a third value `max_turns_partial`. Contrasted explicitly
  with a budget halt: both skip `retry_count`, but a budget halt is re-dispatched while this is
  reattached — the agent still holds the tree it edited.
- Handoff and escalation message formats are **verdict-first**: peer messages now collapse to a
  one-line preview, so a verdict below the fold is invisible.
- `min` Claude Code **2.1.233 → 2.1.251**; README requirements row now carries both justifications.
- Documented across the remaining band surfaces: `notify_when_idle`, unconditional cross-session
  availability (never gate a handoff on provider or host OS), `ListAgents` listing teammates and
  reporting a session's own name, `claude attach` vs `--resume`, `CLAUDE_CODE_SUBAGENT_MODEL` as a
  *default* rather than an override, silent `xhigh`→`high` when thinking is disabled,
  `experimental.cacheTtl` / `promptCacheTtl` / `subagentPromptCacheTtl`, `/cost`'s prompt-cache line
  as the way to *verify* the ≈60% cross-stage target rather than assert it, worktree lock-holding
  and `.worktreeinclude`, five security-hardening rows (TOCTOU on file tools, marketplace
  path-traversal rejection, project-settings tracing limits, `--restricted`, Bash arithmetic
  auto-approve).


- **PL speaks the same sweep contract as every other stage.** `skills/shared/figma-capture.md`'s
  auth-pending and persist-failure questions are full sweep items under
  `planning-<N>.md#elicitation-sweep` with `id: sw-PL<N>-<n>`, and the plan-gate batching section
  now describes items under that anchor rather than a numbered list in `## summary`, which keeps a
  one-line-per-item preview only. One resolution idiom across the pipeline: an answered item is
  marked `status: "resolved"` with its `resolution`, **never deleted** — PL's plan-gate path used
  to delete while all twelve other stages marked. Step A.4 still also appends `(auto-decided)` to
  `facts.decisions[]`, a stated deviation from § Step C.5: AR/TL/DV read that array on stage entry,
  and ≤4 PL items cannot evict AR's newest-8 ring.
- **The sweep stub no longer carries `summary`.** `$defs/SweepStub` requires `[id, class, ref]`;
  the question text is read from the item's `ref` anchor body, whose existence the harness verifies.
  `summary` stays legal but optional; with the stub the only accepted item shape, an optional field
  needs no discriminator. The driver is the 200-token budget on the whole `handoff:` block, a
  property of the block rather than of the sweep.
- **`facts.open_questions[]` merges monotonically.** A re-emitted stub carrying `status: open` can no
  longer destroy a recorded `resolution`: `open < resolved` is joined, never overwritten, and the
  matching writer-side rule is stated in `§ Item shape`. Scoped to `open_questions` only —
  `facts.decisions` keeps last-writer-wins. Both arms are needed: the ledger clamp can evict the
  incumbent a ledger-only fix would have refused against, and the artifact rule survives eviction.
- Sweep answers are recorded in `facts.open_questions[].resolution`, never appended to
  `facts.decisions[]` — that ring keeps only the newest 8, and a 13-stage run's sweep answers were
  evicting the architectural decisions it exists to hold. `facts.open_questions[]` is itself now
  clamped to the newest 12 with `status: resolved` entries evicted first, matching the existing
  single-chokepoint clamp idiom.

- `open_questions` moved from Optional to **Required** for all thirteen stages in the per-stage
  required-field matrix, with the matching `*_REQ` lists in `handoff-harness.sh` updated in the same
  change. `facts.open_questions[]` gained the optional `status: open|resolved` that eviction rule 2
  already referenced but no schema defined.
- `skills/agent-coordination/SKILL.md § Gate prompts` said the plan gate was the *one* checkpoint
  while the same file's comparison table said two. Reconciled to two; the FN gate is where the
  sweep renders.

- **`request-plan` 0.3.0 → 0.4.0 — three drifted rule copies reconciled.** The 0.3.0 capture's 13
  graded failures were first diagnosed as a missing rule each. That was wrong: the skill states
  each of these rules more than once and the copies contradict each other, so every failure is a
  model correctly following the wrong copy. All three fixes remove a copy; none adds a fourth.
  - **`SKILL.md § 4`'s "absent from the file it was blamed on" is bounded.** It licensed a plan for
    a defect the repo does not contain, which `§ 1`'s ask branch prohibits. It now covers only a
    file that exists whose defect sits elsewhere; anything else is `§ 1`'s, and `§ 1` wins.
  - **`skills/request-plan/references/context-gathering.md` no longer states a stop condition.** It carried the
    refuted 0.2.0 rule verbatim for a whole version while `SKILL.md` rejected it in as many words;
    eight responses stopped at a plausible neighbour. The section points at `SKILL.md` instead.
  - **All three tier-trigger copies reconciled to canon.** `handoff.md` listed "security review,
    threat modelling" — topic flavour that `estimation-methodology` rules out by name — its
    `--secure` table row still framed the trigger as "work handling" a protected asset, the
    discovery reading canon replaced at 0.3.0, and `plan-template.md` said a security-sensitive
    surface *forces* the tier, contradicting canon's "a surface you discover does not raise the
    tier". The asset list is now enumerated in exactly one place under `skills/request-plan/`.
  - **Pinned by new parity contracts** in `tests/shell/skills/request-plan-contracts.bats` —
    stop-condition single-sourcing, asset-enumeration-exists-once, and a subset check whose two
    sides are both *extracted* (canon's surface-check pseudocode; `handoff.md`'s `--secure` row)
    rather than restated in the test, so a novel non-canon term fails on membership and not on a
    deny-list. Each has a paired can-actually-fail test. The absence of any of them let the drift in.
  - **`capability-registry.sh` closes stdout with a class-level trailer** naming what it does not
    enumerate. Complete-by-construction over six classes reads as complete over the repo unless the
    output says otherwise. Classes only, never a file, so no eval case becomes a lookup.

  Per the spec-change rule this applies from a 0.4.0 capture forward; 0.3.0 labels are not
  re-flipped. It will not fix all eight stop-at-a-neighbour failures and **cannot be cleanly
  measured** — cases 202 and 203 are structurally identical and split, which is variance, not a
  rule difference. Repairing verified drift stands on its own merits; no re-capture should be
  commissioned to prove it.

- **`request-plan` 0.2.0 → 0.3.0 and `estimation-methodology` 0.2.0 → 0.3.0**, resolving the two
  rule contradictions the 0.2.0 calibration measured. Both are fixed at the surface rather than by
  restating the losing rule, which is what created the contradictions in the first place.
  - **The tier surface check reads the request, not the findings.** It asked whether "the work"
    handles a secret, which escalates on discovery: three plans took `--secure` for a webhook URL,
    a CI login and a dependency scan that none of their requests named. It also left the tier
    undecidable at planning time, since two searches of one repo find different things. Now aligned
    with `derive_route()`, which can only ever see the prompt.
  - **`SKILL.md § 1`'s branches are reordered.** The fold-the-ambiguity branch was listed first and
    was broader than the no-surface branch, so it consumed the cases that branch exists for — four
    responses on `absent` grounding named the ambiguity and planned anyway, executing the first rule
    correctly. The no-surface branch now precedes it, and folding is bounded to requests whose
    surface was found.
  - **`skills/request-plan/references/handoff.md` reconciled with both.** Its flag-matches-the-body check keyed on
    anything the body argued, so a plan naming a credential path its search turned up would carry
    `--secure` — reintroducing the same escalation one layer down. It now compares the flag against
    what the body says the *request* needs. Found by the contradiction cross-read, not by a test.

  Per the spec-change rule these apply from a 0.3.0 capture forward; 0.2.0 labels are not
  re-flipped. Until that capture runs, the effect of all three is argued, not measured.

### Removed

- **Both pre-sweep `open_questions[]` item shapes are gone.** The free-text string
  (`"q1: … (AR to decide)"`) and the bare `{id, summary}` object are no longer valid in any
  transport, and the `not: { required: [class] }` disjointness guard that kept them apart from the
  stub went with them — with one shape there is nothing to discriminate. `handoff-harness.sh`
  `check_sweep_stub_shape` is now the shape gate and rejects each defect by name (not a map, id not
  `sw-<TASK_ID>-<n>`, class not `decision|escalate`, no `ref`), and `state-patch.sh --facts`
  rejects an `open_questions` item lacking a string `.class` or `.ref`. Existing artifacts carrying
  a legacy item must be migrated; there is no non-retroactive tolerance left anywhere.

### Fixed

- **`token-baselines.md` claimed a per-session spawn cap of 200 that no longer exists**, directly
  contradicting `agent-coordination/SKILL.md § No total cap; concurrency is the one that bites`.
- The audit `action` enum was missing **`stage_returned_incomplete`**, which the orchestrator has
  emitted since before this band — a pre-existing gap found while adding the new actions.
- The README hooks table claimed to mirror `plugin.json` 1:1 but omitted `test-execution-gate.sh`
  and `dv-comment-density-gate.sh`.

- **`cache-lint --anchor-lint` rejected `## summary`, which `pl0-procedure.md` requires**, and the
  conditional `## design-preview` it mandates whenever the task carries a Figma URL. `## summary` is
  now a mandatory PL anchor; `## design-preview` and PL's unmandated `## test-strategy` joined the
  allowed-but-never-required set.
- **`cache-lint --anchor-lint` rejected a review's own `## re-review` section** — the same gap that
  `## rework-<N>` had. Both are shipped conventions the DR gate reads; both are now allowed anchors.
- **The `$defs` note attributed the schema injection to a section that does not perform it.** It now
  states the obligation and says plainly that no shipped file implements it, rather than reading as
  verified. `commands/worktask.md § Step B` likewise no longer describes its harness call as
  uniformly advisory: the three sweep checks inside it hard-fail regardless of `--strict`.
- **`agents/product-manager.md` had no `## Handoff Protocol` section**, so
  `cache-lint.sh --frontmatter-template-lint` failed on it repo-wide — a pre-existing gap unrelated
  to the sweep, fixed here on an explicit user decision. It now carries the same pointer-only
  section the other thirteen stage agents use, citing `stage-contracts.md#tpl-pl`; no template copy
  was inlined.

- **The eval capture measured the installed plugin, not the tree under test.** `eval-capture.py`
  passed no `--plugin-dir`, so the CLI resolved `/corpflow:request-plan` from the marketplace
  release while `skill_version()` read this repo — a sweep could exercise one version and stamp
  another on all 156 records. Measured, not argued: with the old flags a command shipping only in
  the installed 4.0.25 was offered and one shipping only here was not. Dispatches now run in a
  detached worktree at HEAD, pinned with `--plugin-dir` and with the ambient copy disabled.
- **The answer key was inside the searched tree.** `evals.json` carries `expected_outcome`, and 7
  of 114 responses in the 0.0.1 capture reached the corpus. The capture tree strips the answer key
  — but not `evals/scripts/*.py`, which six cases ground on. A worktree rather than a copy, because
  it excludes gitignored material by construction: `.context/` held a per-trace map of every known
  failure that the prompt-leak lint could never have seen.
- **`label-align.py` could not run.** Its `--grades` default pointed at a `/tmp` path nothing
  produces, so the only calibration tool in the repo was unusable.
- **A rate-limited sweep lost 38 consecutive cases.** Capture now retries transient dispatches with
  backoff; the never-fabricate contract is unchanged.
- **`eval-grade.py --json` omitted `split`**, which both calibration tools key on.
- **Five eval cases whose premise the repo had already answered** converted to `refute`; three
  repointed where the declared ground file did not own the behaviour. `prompt_digest` untouched, so
  nothing needed re-capturing.

### Notes

- **First calibrated measurement of `request-plan` 0.2.0.** Harness 127/156 = 81%; corrected 77%,
  95% CI [65%, 85%]; dev TPR 93% / TNR 69%. TPR clears the 90% target, TNR misses the 80% floor and
  is reported rather than tuned. `missed-the-real-surface` — 15 of 22 failures in 0.0.1 — is now
  zero. Full record in `evals/findings/request-plan-0.2.0.md`.
- **The 0.0.1 baseline is retired as a comparison point.** It ran on the un-isolated surface, so its
  records cannot say which skill version produced them. Its labels stay sound; its rates do not.
- **The LLM judge is refuted a second time.** Re-validated on labels it had not seen: TNR 0%, 0 of
  10 failures caught. Verdicts committed as evidence.
- **The held-out tranche has no negatives left**, because its only three failures were among the
  five corrected cases. Held-out failure detection is still unmeasured.

### Verified, unchanged

- `.claude-plugin/marketplace.json` declares no command, agent or skill path outside the plugin
  directory, so the 2.1.251 path-traversal rejection changes nothing here.

## [4.0.26] — 2026-08-26

Command-surface reorganization. **38 → 28 commands, 26 → 23 registered skills, and no deprecation
aliases** — seven commands are gone and five are renamed, so every saved invocation of an affected
name stops resolving. Shipped as a PATCH per this plugin's own precedent (`MEMORY.md:53` records the
`company-workflow` → `corpflow` rename, breaking with no alias, shipping as one); the bump is
load-bearing either way, because the plugin cache is version-keyed and a rename without one serves
stale paths.

Two further changes ride along, both consequences of the first. **`request-plan` 0.2.0** resolves the
rule contradictions the 0.0.1 eval capture exposed, extends the capability registry to the executable
surfaces every search miss grounded on, and rebuilds the eval signal that extension spends. And the
verification pass turned up a **`megatask` defect** that had been failing `init-worktree.sh`'s own
self-test: the base branch was resolved against the caller's repository rather than the one being
initialised.

### Removed

- **Six commands with no runtime or no reader.** `business-report`, `test-report`, `pm-prioritize`
  and `pm-risk` were prompt specs with no aggregator behind them, and the last two duplicated
  judgement PL0 already makes. `/worktask-status` and `/agent-report` were working code that nothing
  in the pipeline referenced — grepping `commands/worktask.md`, `commands/megatask.md`,
  `skills/worktask/**`, every agent and every hook returns zero hits for either.
- **`/context-status`, which could not perform any part of its own contract.** Its mandated output is
  a `### Utilization` block (Current Usage, Window Size, Utilization %) and a `### Distribution`
  table of tokens by source — but a model cannot observe its own token accounting, and its grants
  were `Read, Glob` against no file in the repo that carries those figures, so every number it
  emitted was invented. Worse than `/cost-report`, which at least read a real path that happened to
  be empty. Separately `--compress` ("apply compression") and `--dry-run` ("without applying") were
  the same no-op, because there was no `Write` or `Edit` grant to apply anything with, and its own
  `## Integration` section claimed use "by `workflow-engineer` for diagnostics" while
  `agents/workflow-engineer.md` never mentioned it. Nothing is lost:
  `skills/context-compression/` stays (four agents, `hooks/precompact-checkpoint.sh`,
  `skills/worktask/SKILL.md`, `skills/worktask/references/resume.md`, and a bats suite consume it), the
  "> 50% window → summarize completed stages" trigger lives in that skill rather than the command,
  and surviving compaction is already automatic through the `PreCompact` hook with no command in the
  loop.
- **The whole cost-observability feature, not just `/cost-report`.** It aggregated
  `.context/logs/cost-*.jsonl` and **nothing in the shipped plugin has ever written those files** —
  no `cost-log.sh` exists in the repo, and none of the five registered `SubagentStop` hooks is a
  cost logger. `skills/cost-optimization/SKILL.md` said so outright while still documenting the
  hook. Getting a single row required hand-writing the capture script from a snippet and registering
  it yourself, so the command has been inert since it shipped. The `§ Per-Stage Tracking` setup
  instructions go with it: leaving them would keep advertising a hook whose only readers are being
  deleted. What stays is everything that needed no data — the model cost tiers and selection matrix,
  per-effort thinking budgets, the five reduction strategies, prompt caching, and the cost
  estimation formula that `estimation-methodology` cites as canonical.
- **skills/worktask/scripts/status-view.sh and tests/shell/worktask/status-view.bats**, in the
  same commit as the command that wrapped them. They had to move together: `coverage-proxy` C2
  reddens on a script with no `.bats` and C5 on a `.bats` orphaned from its script.
- **skills/worktask/scripts/attachments-preseed-test.sh** — superseded twice over and unreachable.
  It was a hand-rolled harness for what became `attachments-preseed.sh`, which is live, ships its
  own `--self-test`, and has a real suite. Its only references were `tests/COVERAGE.md`, its own
  bats (a test testing a test), and itself; it survived because commit `719d6e7` mechanically moved
  every references/*.sh into scripts/.
- **skills/worktask-status/** — the only skill directory a command removal deletes. Every other
  skill the removed commands touched has other consumers and stays.

### Changed

- **The `pm-` family disappears.** `pm-milestone` → `milestone`, `pm-roadmap` → `roadmap`,
  `pm-sprint` → `sprint`, `pm-requirements` → `product-requirements`. The prefix carried no
  information the bare name did not.
- **`dev-code-review` → `tech-code-review`.** The old name existed to disambiguate Claude Code's
  built-in `/code-review`; the new one does not collide, so the disambiguation note is now a pointer
  rather than a warning.
- **App Store publishing moved to the plugin that ships to that store.** The three `appstore-*`
  commands each opened with an `> **Apple-only.**` banner admitting they were misplaced in a
  platform-neutral plugin. They are now `apple-developer` 1.30.0's `gen-appstore-listing`,
  `gen-appstore-screenshots`, and `gen-appstore-iap`, with `skills/appstore-screenshots/` re-homed
  as skills/tooling/appstore-screenshots/ and its 16 layout tests migrated rather than dropped.
  `android-developer` 1.5.0 gains `gen-playstore-listing` and `gen-playstore-screenshots` — original
  authoring, not a port: Play's field budgets and asset rules differ field by field from App Store
  Connect's. Play Billing IAP is deferred.
- **New `/appstore`, a front door that writes nothing.** All three old commands held `Write`; this
  one holds `Read, Glob, Grep, Task`. It dispatches `agents/release-engineer.md`, which owns platform
  detection, alias resolution, and the sibling dispatch — routing policy has exactly one home
  (`skills/shared/routing-matrix.md`) and no test reads a command body against it. Both apple and
  android markers present, or neither, stops and reports: silently picking a store and then writing
  to a live account is the failure this design exists to prevent.
- **`release-engineer` absorbs store publishing rather than a new agent being added.** Its own
  capability table already claimed "App Store (iOS), Play Store (Android)"; that claim is now real.
  It had **no `Task` grant** and could not delegate to anything, so it gains a bare one, and the
  `haiku` / `maxTurns: 25` budget sized for a non-delegating changelog writer becomes `sonnet` /
  `maxTurns: 40`. Agent count is unchanged at 16.
- **`skills/shared/routing-matrix.md` gains a Release-engineer aliases section** — a section of its
  own, not rows inside § Functional-role aliases, whose grammar is four roles × six platforms and
  would have demanded a web/backend/systems/ai release engineer that does not exist. There is
  deliberately no bare `corpflow:release-engineer` alias: it would collide with the agent of that
  name and redden the no-collision test immediately.
- **`senior-developer-review` folds into `estimation-methodology`** as
  `skills/estimation-methodology/references/estimate-review.md`, and its step 8 stops being inert. `estimation-run.md:16` already
  listed "Senior review: platform-specific adjustments" while nothing on `/estimate`'s default path
  loaded the reference. `--detailed` now runs it inline when its existing trigger fires (complexity
  ≥ 15, or AR/ML/Vision, BLE/hardware, real-time camera, unknown third-party SDKs, background
  processing), with `--no-review` to opt out; `--review` stays for reviewing an *existing* estimate
  with `--focus`/`--update`, which the in-run step cannot do. The adjusted SP feed
  `### Budget Calculation`, so the budget is post-adjustment — `estimation-run.md`'s step order was
  corrected to match. Two sections that arrived there by accident of the skills/review/ rename
  (Dependency Upgrade Review, Review Feedback Hygiene) move to `commands/tech-code-review.md`;
  neither adjusts a story point.
- **Content the survivors cited as canonical was inlined, not dropped.** The business-case skeleton
  moved into `agents/stakeholder.md` (split as two H4s — it is ~1250 chars against a 1000-char leaf
  cap), the RICE input scales and worked example into `agents/product-manager.md`, and `pm-risk`'s
  scoring bands into `estimate-review.md § Risk Scoring`.
- **README command taxonomy restated.** The invariant claimed every non-orchestration command
  carries a domain prefix; after this change `milestone`, `roadmap`, `sprint` and
  `product-requirements` are unprefixed and are not orchestration. They form a new **Planning**
  group with `/request-plan`. The `business-`, `pm-` and `dev-` groups are empty and gone. The
  README's own count was also wrong in both directions — it claimed 36 while the tables listed 37
  and disk held 38, because `/worktask-status` was missing from the Core table; removing it settles
  the discrepancy rather than requiring a row.
- **`capability-registry.bats`** — floor raised 40 → 120 (it was set when the registry held 79
  lines and had been vacuous since), plus per-class presence assertions, a negative assertion on the
  deliberately-unlisted directories, and fixture tests for each description extractor.
- **`skills/request-plan/SKILL.md` 0.1.0 → 0.2.0**; `evals.json` `eval_set_version` 0.1.0 → 0.2.0.
  The "found the surface → plan it" test moves from § 1's ladder into § 2 beside the registry, where
  the evidence arrives; content unchanged.
- **Eval case 4 reverted from `refute` to `plan`** and its byte count corrected. The `CHANGELOG.md`
  split left the premise's *number* stale, not its *request* — it belongs with the correct-the-figure
  cases, not the shipped-work conversions. Cases 5 and 53 were re-audited against the same test and
  stay `refute`: both cite shipped behaviour, not a stale measurement.
- **New eval cases** covering the search surfaces the registry deliberately does not enumerate, plus
  the three 4.0.26 behaviours that shipped with no coverage (`/appstore` marker ambiguity,
  `/estimate --detailed`, `release-engineer` dispatch when the platform plugin is absent).
- **Three cases still naming surfaces 4.0.26 deleted.** Case 9 ("add a machine-readable summary to
  cost-report") is **retired**: the command went with the whole cost-observability feature, so the
  premise names nothing and no answer to it can be right — the same treatment 74/98/114 got, and the
  id stays open rather than renumbering. Cases 16 and 22 stay `refute`; only their *evidence* was
  stale, and both now cite what actually ships (`/estimate --export csv` and its 13-file pack;
  `hooks/audit-subagent.sh` plus `audit-dedup.sh` as the reader) instead of `/cost-report --export`
  and `/agent-report`. Corpus 157 → **156** (121 plan / 17 clarify / 18 refute).
- **The generator fails closed on a deleted command.** `validate_named_surfaces()` rejects any case
  whose prompt or `premise_refuted_by` names a `/command` absent from `commands/`. This table
  carried two dead names for three days after 4.0.26 and only a hand grep found them;
  `premise_refuted_by` is the evidence a refute case is graded against, so a dead citation lets the
  case keep passing while proving nothing.

### Added

- **The capability registry enumerates executable surfaces.** `capability-registry.sh` now also
  lists `hooks/*.sh`, `skills/*/scripts/*.{sh,py}` and `benchmark/harness/**/*.py` — 66 → 148 lines,
  ~3.2k → ~7k tokens. Every search miss in the 0.0.1 capture grounded on one of those classes, which
  behaviour search resolved two times in three while the markdown classes ran at 83–87%. Shell
  descriptions come from `@description` or the first comment block after the shebang, Python from
  the module docstring's summary paragraph; a file with no description still emits no line.
  `tests/`, `evals/`, `skills/*/references/` and `skills/shared/*.md` stay deliberately unlisted —
  the exclusion is on shared *canon*, not shared code. Two executable surfaces the first cut still
  missed are now listed: `benchmark/run-benchmark.sh` (the harness entry point) and
  `skills/shared/milestone-helpers/scripts/milestone-helpers.sh`, whose skill nests its code one
  level deeper than the flat `skills/*/scripts/` glob reached. 66 → **148** lines; the only
  executables left out are the four `hooks/lib/*-selftest.sh`, which are test scaffolding.
- **Three rules for situations nothing covered.** `SKILL.md § 2` gains the six surface classes a
  behaviour can live in (a search that has not decided which class owns it has not finished) and
  turns "do not assert absence you did not check" into a structural requirement that every negative
  claim carry its scope. `estimation-methodology` gains the rule that a quiet local tree — no
  `.context/`, no live `state.json`, a green local run — is not evidence about a failure the user is
  reporting.
- **A required surface-check verdict in the plan template.** `skills/request-plan/references/plan-template.md` now
  requires one line stating the tier verdict immediately before the trigger, the way
  `P2 — v1.1: none` requires an empty phase row to be stated. Five of the graded routing failures
  shared one shape: the check produced no visible output, so skipping it cost nothing.
  `skills/request-plan/references/handoff.md` gains the matching consistency rule — a body arguing for a security review
  and a plain `/worktask` line are two different recommendations.
- **`tests/shell/skills/request-plan-contracts.bats`** — the three mechanical parts of the
  cross-surface read: no rule surface names a command that does not resolve (the check that would
  have caught `/pm-prioritize`), the command file makes no "no exception" claim and cites § 4, and
  the template carries the surface-check line inside its Recommended-next-step block.

### Fixed

- **`skills/worktask/SKILL.md` ordered a skill that has never existed.** Its DR step emitted
  `Skill("dev-code-review")` against commands/dev-code-review.md; there is no
  skills/dev-code-review/. This is the exact defect class `tests/shell/skills/skill-refs.bats` was
  written for — its header names this very call — but the checker could not see it:
  `collect_skill_targets` globbed `agents/*.md` and `commands/*.md` only, and the call lives under
  `skills/`. It silently no-opped and the DR stage fell back to the command doc via
  `agents/technical-lead.md`. The line now names the command file, and the collector is widened to
  `skills/**/*.md`. Widening it also required reading only the **first** quoted argument of a
  `Skill(...)` call — `platform="apple"` in `dv-screenshot-capture` is an argument, not a target.
- **Nothing validated a path-scoped `Bash(...)` grant against the file it names.** A grant like
  `Bash(bash skills/foo/scripts/bar.sh:*)` does not error when its path moves — it simply stops
  matching, and the agent silently loses the capability. `skill-refs.bats` gains a predicate
  asserting every such path in a `tools:`/`allowed-tools:` line resolves to a real file.
- **`cross-plugin-refs.bats` was passing while verifying nothing.** It resolved sibling plugins at
  `$PLUGIN_ROOT/..`, which is a Conductor workspace directory locally and a bare checkout in CI —
  neither contains siblings, so the per-plugin loop found none and both contract tests were green
  against an empty set. It now takes `CORPFLOW_SIBLING_ROOT`, announces an empty sibling set on
  every run so green is never read as verified, and CI shallow-clones the six registered sibling
  repos before the suite. A clone failure warns rather than failing the job: a sibling repo's outage
  is not a defect in this one.
- **`request-plan` rule surfaces that contradicted each other.** `commands/request-plan.md` step 2
  licensed routing to a sibling command *instead of* the worktask, which `SKILL.md § 4` forbids; it
  now names no sibling at all and points at § 4 as the authority — naming one is what made the file
  go stale twice (`/pm-requirements`, then `/pm-prioritize`). Step 3 claimed the trigger rule had
  "no exception" while § 4 has had exactly one since 0.1.0; it now cites that exception rather than
  denying it. `skills/request-plan/references/handoff.md` still told XL work to emit no command, contradicting both § 4
  and step 3 — XL now names its sub-tasks and triggers the first.
- **`init-worktree.sh` resolved the base branch against the wrong repository.** Step 7 correctly
  uses `git -C "$repo_root"`, but `resolve_base_branch()` shelled out to `milestone-helpers.sh
  base-branch` in the *caller's* cwd, and that helper's develop-vs-master probe is a `git ls-remote`
  against whatever repo it is standing in. Initialising a worktree in a repo without `develop` from
  a repo that has one picked `develop`, then fetched it in the other repo and died:
  `fatal: couldn't find remote ref develop`, exit 128. It runs in `$repo_root` now (subshell, so the
  no-cwd-drift discipline holds). This is what the script's own `--self-test` had been failing on.
- **`milestone-helpers.bats` asserted a property of the developer's remote.** The base-branch
  default test called the helper with no cwd control, so it passed or failed on whether the ambient
  `origin` happened to carry `develop`. Both arms now run in a fixture with a controlled remote, and
  the develop arm — which is what tells a working probe from one hardcoded to `master` — is covered
  for the first time.
- **The escalation canon called a live failure standard work.** `skills/estimation-methodology/SKILL.md`
  said "a wedged task or a runaway batch is standard work" immediately above the test that decides
  it, so a reader who stopped at the example got the wrong answer. The example is now scoped to a
  task that has *stopped*, and a task that is both stuck and still failing escalates.

### Notes

- **No commit in this release carries `!` or a `BREAKING CHANGE:` footer**, deliberately.
  `version-bump-from-git.sh` computes `major` from either marker and shares
  `conventional-commits-lib.sh` with `changelog-from-git.sh`, so a breaking marker would put the
  release tooling in direct conflict with the chosen version number. The breakage is recorded here
  in prose instead.
- **Eight eval grounding paths were repointed and two cases retired**, because
  `tests/python/test_skill_evals.py:182` asserts every case's grounding file exists and runs in CI.
  Prompts are untouched, so no `prompt_digest` moved and no human label was invalidated. Cases 98
  and 114 grounded solely on status-view.sh and skills/worktask-status/SKILL.md; with no
  successor surface there is nothing to re-ground them on, so they join the `RETIRED` table and
  their ids stay open rather than renumbering. Case 74 retires for the same reason with
  `/context-status`: nothing else in the repo reports remaining context.

- **Three spec versions are unmeasured, and a capture cannot attribute between them.**

  `SKILL.md` 0.1.0 shipped in PR #325 with no capture. The 4.0.26 command-surface reorganization
  (PR #332, in this release) then removed seven commands, renamed five and repointed eight eval
  groundings — all inside
  the tree `eval-capture.py` reads. 0.2.0 stacks on both. Whenever a capture eventually runs it
  measures **all three at once** and cannot separate them. Recorded here while it is cheap: a later
  reader comparing a 0.2.0 number against the 0.0.1 baseline will otherwise attribute the whole delta
  to whichever change they happen to be reading about.

  Separately, extending the registry converts most of the `buried` tranche from a search into a
  lookup, so **`buried` stops measuring search quality from 0.2.0 forward**. The replacement cases
  ground only on unlisted surfaces; the note is also carried in `evals.json` `grading`.

## [4.0.25] — 2026-08-24

### Fixed

- **The plan-approval carrier `PL0.metadata.approved` had two readers and no writer.** A real human
  approval at the plan gate appended only an `approval_received` audit row, so the first DV turn's
  approval check returned `blocked` and the developer agent correctly refused to start — a prior run
  had to hand-stamp the field mid-pipeline. `commands/worktask.md` now stamps at each of the three
  arms where approval is actually established: the approval arm (`user`), the pure-bypass arm
  (`auto` — the explicitly requested bypass carrier is the approval), and the escalate-resolution arm
  (`user`, because a human really answered those items and `auto` would understate it). The
  auto-decision pre-pass at Step A.4 deliberately stamps nothing and now says so: it bypasses no gate
  and falls through to Step A.5, the sole stamping point.
- **The stamp precedes the audit row in every arm, and that order is load-bearing.** Two files, two
  writes, no atomicity primitive spanning them. Stamp-first leaves a crash window with state
  approving and no row, which the resume path answers by re-prompting a human; row-first resumes into
  the stage loop with the carrier unset, reproducing the defect being fixed.
- **Every batch lane hit the same block.** `commands/megatask.md`'s per-issue planning seed now
  stamps `approved:"auto"` alongside the gate keys it already sets.
- **Both reader sites in `agents/developer.md` and the one in `agents/product-manager.md` named the
  field bare**, which reads as the *reading* task's own metadata and would have left the fix inert.
  They now name the carrier, `PL0.metadata.approved`. The ledger schema entry gained a `description`
  naming PL0 as carrier and the orchestrator as writer.
- **New `tests/shell/worktask/approval-gate.bats`** (7 cases) extracts the writer payload, the
  reader's accepted value set and the schema enum from their own files at test time and cross-checks
  them, so drift on any one side fails the suite. Three guards make an empty or degenerate extraction
  a red test rather than a vacuous green. Reachable from all five guarded paths via L1 path
  references plus matrix rows R04, R07, R09, R10 and R15.

## [4.0.24] — 2026-08-23

### Changed

- **The `request-plan` eval corpus was reset to a `0.0.1` baseline.** The corpus had stopped being
  readable as one thing: captured responses spanned two skill versions (`eval-grade.py` refuses to
  average across them), labels were made under one rubric and partly re-flipped under later ones,
  and three findings docs each recorded a different headline for the same comparison. A staleness
  audit then found the deeper problem — the set was generated at `27e542a` and the ~20 commits that
  shipped the same evening read like a work queue against those very prompts. `SKILL.md` `version:`
  and a new top-level `eval_set_version` in `evals.json` both read `0.0.1` and move together from
  here.
- **32 of 121 cases were repaired before any re-capture**, because capturing first pays to measure
  invalid cases. 20 ask for work that has since shipped and are now `refute` cases, each carrying
  the commit that closed its premise (`REFUTED_PREMISE` in `gen-request-plan-cases.py`). 7 whose
  premise was never true are retired (`RETIRED`) — `megatask --dry-run` already existed, and
  `hook-install.sh` both backs up on overwrite and writes no settings file at all. 3 more had only
  a stale byte count and keep their request. Retired slots stay open rather than renumbering: ids
  are positional, and the rubric, the split manifest and a dozen comments key on them. 114 cases
  remain, 77 plan / 20 refute / 17 clarify.
- **Capability requests whose surface already exists stay plans.** A case becomes `refute` only
  where it asks to *build* something that already ships; asking to find or reach an existing
  surface is what `buried` grounding is for. `SKILL.md § 2` said a registry hit never licenses a
  short answer while `§ 4` said an already-shipping capability must stop without a plan — a model
  reading § 2 first failed every refute case for obeying the skill. § 2 now defers to § 4.
- **The LLM judge is retired.** Measured against human labels it scored **TNR 0%**, catching 0 of
  26 known failures, so `label-align.py` drops its column and `judge-traces.py` no longer claims to
  substitute for human labelling. The script stays for its isolation technique, and for the case
  that grounds on it.
- **`skills/request-plan/evals/failure-taxonomy.md` is retitled historical.** The labels behind its
  rates were deleted; the seven category rules it produced are still live in `SKILL.md`.

### Fixed

- **The prompt-leak lint scanned only tracked files while capture runs against the working tree**
  (`tests/python/test_skill_evals.py`), so an uncommitted findings doc holding a table of case ids
  beside their answers went undetected through a whole capture. It now scans untracked files too,
  covers `.jsonl`/`.txt`/`.yml`/`.yaml`, and reports every hit per case instead of stopping at the
  first. It remains blind to paraphrase, which is inherent to substring matching and is now
  documented rather than chased.
- **`gen-request-plan-cases.py` silently re-stratified every split when the manifest was
  unreadable**, the loudest possible breach of the never-move-a-tranche rule delivered as success.
  A missing manifest is now an error unless `--restratify` says the reshuffle is deliberate, and
  `--restratify` writes the manifest it recomputed, so the freeze cannot be undone by the next
  plain run. The 0.0.1 manifest records that its `test` tranche is **nominal, not held out**:
  every case predates the reset, so a genuinely unseen tranche needs genuinely new cases.

### Added

- **`evals/findings/request-plan-0.0.1-baseline.md` — the calibrated 0.0.1 baseline.** 114 cases
  captured at $71.73 and all 114 human-labelled. **Human 81%, harness 57%**; TPR 63% / TNR 68%,
  Rogan-Gladen corrected to 81% — the correction and the human count agree to the point, which
  says the harness's 57% is a measurement artefact. The harness false-fails 34 of the 92
  responses a human passed, concentrated in `refute` (95% human vs 30% harness) on a
  `disputes-the-premise` verb list that rejects "already **fixed**". `buried` search depth at
  67% is the dominant real defect: 15 of the 22 human failures are plans that reached a
  plausible neighbour and stopped.

- **`request-plan` 0.1.0 — the already-ships rule is narrowed (spec change).** The 0.0.1 capture
  showed `SKILL.md § 4` firing far too wide: 13 responses stopped at "this already ships" on cases
  whose request was to *find or use* a surface, and a human passed every one while the harness
  failed each on 3-6 template assertions. § 4 now stops only when the request asked to
  **build/add/fix**, the thing exists as asked, **and nothing remains**. Finding a surface you were
  asked to find is the answer to the search, not a reason to withhold the plan; a shipped headline
  with a live remainder gets a refutation of the stale part *plus* a plan for the rest. Per the
  spec-change rule in `evals/README.md`, 0.0.1 labels are not re-flipped — those responses were
  correct answers to the old contract.
- **`no-build-plan-for-work-that-exists` withdrawn** with its measurement attached: 12 firings, 12
  human passes, **0 true positives**, and it did not fire on the one refute case a human failed.
  TNR 0% is the pathology that retired the LLM judge. Replaced by `cites-evidence` (a path or a
  commit SHA — a floor all 20 refute responses clear), and its real question moved to `deferred`.
- **`disputes-the-premise` was blind to sentence-initial refutations.** `eval-engine.check` matches
  with `re.MULTILINE` and not `re.IGNORECASE`, so a lowercase pattern could not see a response
  opening "Already fixed — no plan needed" — which is exactly where a refutation belongs. Patterns
  gained `(?i)`; the verb list gained the misses the capture produced. Re-grading the same 114
  responses moves TPR 63% → 71% and the refute tranche 6/20 → 14/20, with the corrected estimate
  unchanged at 81%.

### Security

- **The capture could read its own answer key.** 7 of 114 responses reached the eval corpus
  during the run and at least 3 read the expected outcome — one quoted
  `expected_outcome: "refute"` from `evals.json` back into its answer, another named its own
  case id. `eval-capture.py` dispatches against the working tree, `evals.json` lives there, and
  the prompt-leak lint exempts it by design because a case has to live somewhere. The exemption
  that makes the lint possible is the hole, and no further lint closes it — capture has to run
  against a tree that does not contain the eval set. Filed, not fixed: changing the capture
  surface after a paid run is a deliberate change of its own. Bounds the baseline on 7 cases.

### Removed

- **All `request-plan` result artifacts**: `evals/labels/*.jsonl`, `evals/judgements/`,
  `evals/findings/*.md`, `evals/review/*.html` and the captured responses. This also closed two
  live prompt-contamination leaks, both of which lived in deleted files. Between the deletion and
  the first labelled 0.0.1 capture the harness is **uncalibrated** — TPR/TNR are unknown, so no
  grader pass rate in that window is trustworthy.

## [4.0.23] — 2026-08-22

### Added

- **`.github/workflows/test.yml` — the repository's first CI pipeline.** The repo had no
  `.github/workflows/` at all. Two jobs run in parallel: `test` runs the full deterministic suite
  via `./run-tests.sh` with `CORPFLOW_TEST_SELECT: "0"` (selection is never the required check),
  and `lint` runs the four repo lints on a single pass — `desc-lint.sh` and `section-lint.sh`
  against the repo as their real subject, `cache-lint.sh` and `pr-body-lint.sh` in `--self-test`
  mode because they consume a `prompt-log.jsonl`/PR body that nothing here emits. Checkout depth is
  pinned per job: `fetch-depth: 0` on `test` (several bats shell out to git and diff against
  origin/master) and `fetch-depth: 1` on `lint`. `permissions: contents: read`, no repository
  secret is referenced, and `concurrency` cancels superseded PR runs only — never a `master` run,
  which would leave `master` unverified.
- **`tests/shell/meta/ci-workflow.bats` — the workflow's content as an executable contract**,
  16 assertions covering the permission surface, action pinning, the four lint invocation modes,
  the load-bearing `2>&1`, the per-job `fetch-depth` split, and the `shell: bash` keys. New
  test-selection matrix row R28 (`tests/selection/matrix.tsv`) routes `.github/workflows/*` edits
  to this file; without it such an edit falls through to FULL, which is safe but hides ownership.
- **Prompt-body authoring doctrine in `agents/prompt-engineer.md`**, two sections peer to the
  existing description grammar: a four-rule body doctrine (information hierarchy on a branching
  test, completion criteria graded on clarity and demand, negation by diagnosis rather than by
  default, no-op pruning) and a four-gate conjunctive invocation classification that DV2 applies
  verbatim across the skill manifests. `commands/prompt-audit.md` gains the matching per-asset
  checks plus a `--skills` scope so the body rules reach skill manifests;
  `commands/optimize-agent.md` and `commands/arch-decision.md` carry their counterparts.
- **PL0 separates facts from decisions** (`skills/worktask/references/pl0-procedure.md`): any
  question the filesystem, git, or a tool can answer is resolved by PL0 — dispatching a subagent
  when the lookup is slow — and never reaches the approval gate; a question that depends on another
  still-open question defers to a later round instead of batching beside it. An ADR-warranted gate
  was added alongside, with fixtures under
  `skills/worktask/references/fixtures/plan-gate-questions/`.

### Changed

- **Manifest keywords reduced 120 → 15.** The array had accumulated release-note tokens
  (`opus-4-8`, `todo-tools-removed`, …) that CHANGELOG.md already carries; the remaining 15
  describe the plugin. `plugin.json` is canonical and `marketplace.json` mirrors keywords,
  `description`, and `version`, now pinned by a parity assertion in
  `tests/shell/worktask/manifest-parity.bats`.
- **Plugin `description` shortened 353 → 201 characters** in both `plugin.json` and the two
  `marketplace.json` sites, dropping the enumeration of stage roles for one sentence naming the
  pipeline, the state ledger, cross-plugin delegation, and `/megatask`.
- **`description:` frontmatter removed from 15 non-skill shared docs** under `skills/shared/` —
  they are reference documents read by path, not invocable skills, so the key had no consumer.
- **Four stale "not wired to CI" claims cleared** across three documents now that CI exists:
  `skills/context-compression/SKILL.md`, `skills/worktask/SKILL.md`, and
  `skills/worktask/references/handoff-protocol.md` (two claims). The replacements are deliberately
  narrow — CI runs `cache-lint.sh --self-test`, which gates the lint's own parser and fixtures; no
  captured prompt log is checked until an emitter exists, and anchor-lint is still not a CI check.
- **Two pipeline-only skills marked `disable-model-invocation: true`** — `skills/preview-ensurer/`
  and `skills/csv-export-templates/` — each with the gate-G3 answer recorded as a `# G3:` comment
  directly above the key: neither has standalone value outside the run that supplies its input.

### Fixed

- **Red test suites now report red, not green (#322, DR-P0).** The suite step ran
  `./run-tests.sh 2>&1 | tee run-tests.log` without a `shell:` key. GitHub Actions' default shell
  on Linux runners is `bash -e {0}` — `-o pipefail` is applied *only* when `shell: bash` is written
  out explicitly. Without it the step exited with `tee`'s status, which is 0 whatever
  `run-tests.sh` did, so a failing suite reported success to the workflow engine. Declaring
  `shell: bash` on the suite step and on the skipped-phase summary step restores `pipefail` and
  gates the job on the suite's actual result. Two assertions cover the property rather than the
  literal string, matching an anchored YAML key inside a bounded step window (this file's own
  comments say `shell: bash` in prose); both were mutation-checked — removing either key turns
  them red.
- **Colliding `G<n>` gate labels disambiguated in `agents/prompt-engineer.md`.** Its
  `### Invocation classification` section numbers its gates G1–G4 while the adjacent
  `### Description grammar` numbers its rules G1–G7, and an exemption rationale closing on
  "so G1–G5 keep their purchase" sat eight lines below the table defining G1–G4, so a reader
  resolved the nearer referent and got the wrong set. Fixed at both ends rather than by
  relabelling — the invocation gates keep G1–G4 because DV2 consumes the procedure verbatim: the
  section now states up front that its labels are local and that the grammar's G1–G7 are an
  unrelated set, and the exemption sentence names its owning section inline.
- **The ENOSPC disk guard never fired on Linux.** `disk_guard()` in
  `skills/worktask/scripts/state-patch.sh` — shipped runtime code every worktask executes — probed
  free space with `df -Pg`. `-g` is BSD-only; GNU coreutils rejects it outright (`df: invalid
  option -- 'g'`, exit 1, nothing on stdout), so `avail_gb` came back empty and the guard took its
  "df unparseable → degrade silently, never block" path. The `DISK_MIN_GB` hard halt was therefore
  unreachable on Linux at any threshold, and had been since the guard was introduced. Now `df -Pk`,
  which is POSIX on both platforms, with the conversion to GiB moved into the awk program. macOS
  behaviour is unchanged.
- **`run-tests.sh` gained a re-entrancy guard, and the Apple-only phases now gate on frameworks.**
  Re-entering the deterministic entry point for a tree already under test previously recursed
  silently until the job timed out; it now fails loudly. The guard keys on the tree rather than on
  the script and sits below the selection phase, so `--print-selection` and sandbox copies stay
  callable from inside a run. Separately, the Swift phases gated on `swift` being on `PATH`, which
  a Linux toolchain satisfies while not shipping the SwiftUI the benchmark template imports; all
  three call sites now compile the template's imports instead, and every resulting skip is named
  with its reason under `SKIPPED PHASES:` rather than passing as a quietly smaller green run.

## [4.0.22] — 2026-08-21

### Changed

- **Description-frontmatter authoring switched to a trigger-first grammar** — 42 assets (16 agents
  + 26 skill definitions) rewritten so `description:` leads with *when to invoke*, not *what the
  asset does*; `commands/*.md` stay exempt from the grammar (length cap only applies). The doctrine
  is now recorded once, normatively, in `agents/prompt-engineer.md`, with pointers from
  `commands/prompt-audit.md` and from the linter's own failure message — read it before hand-editing
  any `description:` field.
- **Rationalization tables + Red Flags lists** added as sibling H3 sections to six agents
  (`developer`, `product-manager`, `project-manager`, `qa-engineer`, `technical-lead`,
  `workflow-engineer`) — purely additive, no prior rule removed.
- **PL stage is now proactive**: it announces its sizing decision, tags plan-shaping questions with
  assumptions, and exposes a one-way mid-run re-sizing ratchet
  (`requests_stage_escalation`, an artifact-frontmatter field the orchestrator reads — never a
  ledger key) plus stage-task right-sizing. See `skills/worktask/references/pl0-procedure.md`,
  `skills/estimation-methodology/SKILL.md`, `agents/product-manager.md`, `skills/request-plan/SKILL.md`,
  `skills/worktask/SKILL.md`.
- **DV0 routing override re-keyed from directory to file kind**: DV routes to
  `corpflow:workflow-engineer` when the change touches worktask-infrastructure files that are
  *executed* (the plugin tree's `**/*.sh`, `**/*.bats`, `hooks/**`, JSON consumed by those scripts)
  rather than the old path list; markdown routes by contract, not directory. Anchored to the
  plugin/worktask tree — a product repo's shell script keeps the platform route. See
  `skills/worktask/references/pl0-procedure.md § DV0 routing override`.

### Fixed

- `skills/worktask/scripts/desc-lint.sh` was a single check (250-char cap) — extended to six checks
  (G1–G6) covering the full description grammar, and asset discovery switched from a depth-fixed
  glob to `find skills -name SKILL.md` so nested skills can no longer escape the lint. Coverage:
  `tests/shell/worktask/desc-lint.bats` grew from 10 to 26 cases.
- One skill's `description:` frontmatter was YAML-invalid before this change; it now parses.

## [4.0.21] — 2026-08-21

### Added

- **`skills/shared/routing-matrix.md` — single source of truth for alias→target routing.**
  32 virtual `corpflow:*` aliases (6 platform entry points, 24 functional roles, 2 support
  plugins) map to qualified `plugin:agent` default targets. Stage-agent inline tables become
  mandated copies validated by the new `tests/shell/skills/routing-matrix.bats`; the matrix's
  default targets are additionally resolved against sibling checkouts in
  `cross-plugin-refs.bats`.
- **Project-level routing override.** A `CORPFLOW.md` at the *user project root* may carry a
  `## Routing` table whose rows win over the matrix, alias by alias — resolved once at
  worktask init into `state.routing` (`worktask/SKILL.md § Validation check 12`), with
  `routing_override` / `routing_override_partial` audit rows. Template:
  `skills/cross-plugin-handoff/templates/PROJECT-CORPFLOW.md`; the `## Routing` heading is
  now reserved and forbidden in the plugin-side `skills/cross-plugin-handoff/templates/CORPFLOW.md`. Location decides
  which of the two same-named files applies (`plugin-contract.md § Project-level routing
  override`).
- Stage-dispatching agents (`developer`, `software-architector`, `security-reviewer`,
  `qa-engineer`) now carry a bare `Task` grant instead of ~60 literal `Task(plugin:agent)`
  grants, so any override target dispatches; the guardrail is the mandatory delegation audit
  row. Adding a plugin no longer touches agent frontmatter (`plugin-contract.md § C`
  re-ordered accordingly).

### Fixed

- `plugin-protocols.md` android rows still used pre-1.4.0 bare agent names (`code-fixer`,
  `security-auditor`, `test-generator`, `dependency-manager`) — dispatching those either
  fails or silently resolves to apple-developer's agents. Now `and-*`, matrix-validated.
- `plugin-protocols.md` apple-developer table lacked the DR row every other plugin has.
- commands/pm-milestone.md (now `commands/milestone.md`) defaulted `--platform apple` to `ios-developer` while every
  other platform (and every other file) defaults to the entry router.
- `compatible-plugins.md` still listed the retired `workflow-integration` skill column
  (replaced by the root `CORPFLOW.md` contract in 4.0.13).

## [4.0.20] — 2026-08-21

### Changed

- **Prompt surface compressed 19.7% (240,429 → 193,168 words) across all 38 commands, 16 agents,
  and 111 skill files** (#313). Behavior-preserving: one canonical copy per fact — `skills/shared/`
  and skill references are canon, commands/agents point instead of restating — tables over prose,
  one worked example per pattern, report samples reduced to section skeletons plus content rules.
  Frontmatter, tool grants, trigger descriptions, gate/AC language, schemas, script contracts, and
  every test-pinned string and cited section anchor preserved verbatim (605 citations re-resolved
  in a closing cross-file audit) — the sole frontmatter edits are the three corrected
  `argument-hint` fields listed below. Every rewritten file carrying a `version:` field takes a minor
  bump (`structure` category per `agents/prompt-engineer.md § Self-Improvement Patch Application`).
  Estimation run detail split to a new on-demand
  `skills/estimation-methodology/references/estimation-run.md`.

### Fixed

- Defects surfaced by the compression sweep: three dead `/release-notes` links (renamed command),
  a factually drifted stage→model lookup table in `stage-codes.md` (FN/IR swapped vs shipped
  frontmatter), a stale atomic-merge snippet in `stage-contracts.md` missing the mandated mkdir
  spinlock, an emergency stage list missing DR, six dangling section anchors, a stale
  `skills/README.md` index (12 missing entries), and mis-labeled rule-range headings in
  `skills/self-improvement/references/target-mapping.md`.
- Three `argument-hint` fields that had drifted from their command's documented options:
  `appstore-iap` and `appstore-screenshots` gained the `--dry-run` (and `--path <dir>`) flags they
  already accept, and `appstore-info` dropped a positional `<app name or bundle ID>` it no longer
  takes in favour of its real `--lang` / `--path` / `--readme-only` / `--dry-run` set.
- `milestone-helpers.sh` cited `megatask § Priority Sorting`, a heading this release folded into
  `§ Dependency & Blocker Resolution (DAG)`. The unqualified `<skill> §` shorthand fell outside the
  citation audit, which resolves the qualified `<path>.md §` form.
- An unescaped `||` inside a code span in `security-review-process/SKILL.md § Secure Coding
  Patterns` split the Authorization row into five cells, truncating the rule where it rendered.

## [4.0.19] — 2026-08-17

### Fixed

- **A DV brief built from the repo's own README ran the full suite and pre-empted QA's gate.** The
  orchestrator had no rule about where a stage brief's test invocation comes from, so the most
  reachable command — a full-suite `xcodebuild test` pasted out of a project `CLAUDE.md § Core
  Commands` — reached DV four times on a `test_mode: scoped` plan. `testing-strategy.md §
  Dispatch discipline` now sources the invocation from `<plan_file>` frontmatter (`test_mode`,
  `always_required_tests`) and requires the brief to state the resolved mode **and** the exact
  selector, with DV recording any identifier-grammar reconciliation in `development-N.md §
  Decisions`. The mechanical deny (`hooks/test-execution-gate.sh`) already covered this shape,
  including quoted multi-word `-destination` values; this closes the prose layer that produced the
  command in the first place.

### Changed

- **`build-only` is now *selected* for a comment/doc-only diff, not merely available.** The mode
  existed for exactly this case but was opt-in and never reached for, so doc work paid full
  simulator cost. When every planned hunk is a comment, a prose file, or a non-executable string,
  PL sets it and the marker-coverage precondition does not apply — nothing executable changed, so
  no markers are standing in for a run. One executable hunk anywhere disqualifies the diff. The
  downstream consequence is stated with it: a doc-only change landing after QA (typically DC,
  which holds no execution authority at all) does not re-trigger QA, and FN commits on QA's
  existing evidence.

- **FN unwinds build-tool churn as the last action before staging.** Build tools mutate tracked
  files nobody edited — auto-extracted localization keys, scheme and build-configuration rewrites,
  lockfile touch-ups — and those edits reached commits because no stage owned removing them.
  `project-manager.md § Pre-commit scope check` requires `git status --porcelain` to show only the
  run's intended files, reverts the rest immediately before `git add`, and forbids running
  anything that builds afterwards, since a build re-creates exactly what was just removed. FN
  holds no build path, which is what makes it the right stage to own it. Reverted paths are listed
  in `complete-summary-N.md`; one that recurs every run is a repo defect worth its own issue.

## [4.0.18] — 2026-08-17

### Fixed

- **Absolute local paths leaked into published PR and issue bodies from two directions.** The
  Pass-1 strip in `publish-pl-issue.sh` and its byte-identical copy in `pr-body-lint.sh` knew only
  the home-directory mounts (`/Users`, `/home`, `/tmp`, `/var`, `/opt`, `/etc`, `/root`), so a
  checkout under `/Volumes`, `/mnt`, `/media`, `/private`, `/srv`, or a Windows drive letter walked
  through both. The alternation now covers all of them, and `local-path-regex-parity.bats` pins the
  two copies identical. Separately, `fn-preflight.sh pr-body` skipped **all** work under batch and
  incident routing, publishing unsanitised bodies; the strip now always runs and only the
  *blocking* behaviour is dropped for those routes.

- **The comment-density gate blocked legitimate per-declaration DocC.** A 20-case enum with one
  on-budget `///` per case measured 48% and was rejected. Runs of one-line comments no longer
  count as a block; every existing fixture keeps its prior verdict.

- **Change→test selection failed closed to FULL for `hooks/lib/` self-test bodies.** `sel_alias_for`
  now resolves `<name>-selftest.sh` to its owning hook's `.bats` by chaining through the alias
  table, restoring scoped runs for hook work.

- **commands/agent-report.md was never registered in `marketplace.json`**, leaving the command
  invisible to the marketplace since it was added.

- **Six red tests, all pre-existing.** `env -u` after a `NAME=VALUE` operand is a no-op on BSD
  `env` (macOS took `-u` as the command name); the `stale-check.sh` write guard matched the word
  `SendMessage` in its own advice prose rather than any call, and now matches invocation syntax
  with a falsification test beside it; `fn-preflight` F23 asserted a message the batch exemption
  stopped emitting when it moved ahead of the sanitiser.

### Added

- **A duplicate GitHub issue is caught before `.context/` exists.** The existing anchor and
  exact-title guards are reachable only *after* the context exists, so a paraphrased request opened
  a second issue every time. `/worktask` Step 2a now scores keyword overlap against open-issue
  titles locally and offers at most three candidates. Advisory and human-confirmed only: it never
  links, comments, or writes on its own, and any failure — no `gh`, no auth, API error, timeout,
  zero hits — proceeds to a new context. Batch, incident, and non-interactive runs skip it;
  `PREFLIGHT_ISSUE_SCAN=0` disables it.

- **The test-execution gate denies a run that already happened.** Once an authorized invocation is
  allowed, the identical invocation is denied while the tree is byte-identical, scoped to
  `run_index`. The fingerprint is HEAD plus `git status --porcelain` **and** `git diff HEAD` — the
  diff is load-bearing, since porcelain reports only names and status letters. Checked on the allow
  path only, so suppression can never widen what the gate permits; every unresolvable input allows.
  `CORPFLOW_TEST_DEDUPE=off` is the hatch.

- **Unit tests for `conventional-commits-lib.sh`**, which shipped without a dedicated `.bats` —
  17 cases pinning breaking-change detection, section mapping, bump aggregation, and record
  collection at the library rather than through its two consumers.

### Changed

- **Every markdown section is back within the 1000-char cap** (38 were over, across 28 files).
  Sections were **split, not cut**: leaf semantics mean a subheading turns one over-cap section
  into two compliant ones without losing a word. The largest cluster was the nine copies of
  `State Patch — REQUIRED before return`, each split at its `--facts` obligation.

- **The gate no longer forks `sed`, and resolves the stage only for test commands.** Classification
  runs first; `sed` is gone from the classify path entirely (5 forks to 0). Measured: benign call
  13ms → 10ms, test command 36ms → 27ms. `classify_segment` is 216 lines, down from 270.

- **Hook comments compacted to `skills/code-comment-standard`**, and self-test bodies moved to
  `hooks/lib/` — four hooks shed 660 lines of test code, `test-execution-gate.sh` 1280 → 1078.
  Each dispatcher fails **closed**: a missing body reports a failure rather than "OK". Code lines
  are byte-stable in every file.

- **`request-plan` v0.3.0**, from an open-coded error analysis of 96 human-labelled traces
  (`skills/request-plan/evals/failure-taxonomy.md` — 9 categories, rates, and the case lists).
  Five rules address the format and routing categories: decide once between asking and planning,
  confirm a file owns the behaviour before planning against it, never assert absence you did not
  check, always emit all three phase rows, and end with exactly one `/worktask` line.
  `estimation-methodology` gains a surface check above the size logic, so `--secure` and
  `--emergency` are decided by what the work touches rather than by how large it is.

  The analysis then found that **half of all failures were one root cause wearing two faces**:
  16 of 32 were `buried`-grounding cases (50% failure rate, against 17–29% elsewhere) that either
  planned against the wrong file or gave up and asked — both the same search stopping before it
  reached the owning module. § 2 had licensed exactly that, telling the model to "stop gathering
  once more reading wouldn't move scope, phases, or effort" — a condition unknowable from inside
  the failure, since a search that has not found the right file cannot tell that more reading
  would change the plan. It now stops on evidence (name the owning file and what you read in it),
  searches by behaviour rather than filename, treats one hit as a hypothesis rather than a
  finding, makes `Explore` mandatory rather than preferred, and gates the "no surface" branch on
  the search having actually run.

- **The eval grader stopped excusing the failure it was built to catch.** An unexpected clarifying
  question was reported as `CLARIFY` and dropped from the denominator, hiding 9 of 32 known
  failures and computing the headline over 87 cases instead of 96; it is now scored against the
  case's `expected_outcome`. The `cites-a-repo-path` threshold dropped from 2 resolving paths to 1:
  at 2 it failed 8 plans a human passed, because a plan citing the handed file by full path and its
  neighbours by bare name resolves exactly one. Together these move the harness from TPR 83% /
  TNR 100% to **TPR 94% / TNR 100%** against the human labels.

## [4.0.17] — 2026-08-16

### Changed

- **`state-merge.sh` ships from `hooks/` like every other hook.** It was the lone occupant
  of `.claude/hooks/`, a split that bought nothing and cost a carve-out in every rule that
  quantifies over hooks. Only the **plugin-root source path** moved: the project-local
  install destination written by `hook-install.sh` is still `<project>/.claude/hooks/state-merge.sh`,
  because that is Claude Code's per-project hook directory, not a corpflow convention. The
  file is now executable, which is what `manifest-parity`'s AC-9 contract already required
  of everything under `hooks/`; the exemption that excused it from the mode bit is gone.

### Fixed

- **The relocation would have silently disabled the Layer-2 net.** `state-merge.sh` locates
  `state-patch.sh` — the only merge implementation — through `$CLAUDE_PLUGIN_ROOT` first and
  a relative arm second. That arm read `${HOOK_DIR}/../..`, which is the plugin root from
  `.claude/hooks/` but its *parent* from `hooks/`, so the shipped copy resolved a path with
  no `skills/` tree under it. A SubagentStop hook must never block a stage transition, so the
  not-found branch exits 0 — the failure mode is not a crash but a merge that quietly stops
  happening, the same silent-net class as the cwd bug fixed in 4.0.16. Both arms (dispatch
  path and `--self-test`) now go up one level. Six of the eleven `state-merge.bats` cases
  caught it; the two that stayed green were the ones passing `CLAUDE_PLUGIN_ROOT` explicitly.

- **Version parity was red before this release.** `plugin.json` read 4.0.16 while
  `marketplace.json` and `README.md` still read 4.0.15, so `manifest-parity` AC-4 failed on a
  clean checkout of 4.0.16. All four sites now agree.

- **The `state_repair` audit row recorded an absolute backup path.** 4.0.16 moved the hook onto
  a resolved `WORKSPACE_DIR`, which made `STATE_FILE` — and with it the backup path derived from
  it — absolute, so the row leaked the worktree it happened to fire in. `handoff-protocol.md` F4
  names the backup `.context/state.json.corrupt.<iso-ts>` and the sibling `artifact` field in the
  same row is workspace-relative; the row now matches both. Filesystem operations still use the
  absolute path — only what is written to the trail changed.

- **The AR-gate test pinned an index the gate deliberately does not name.** `handoff-harness.sh`
  matches any `AR[0-9]+` ("did AR run", not "did AR0 run"), so when no entry exists there is no
  index to report and the warning says `tasks.AR<N>`. The test asserted `tasks.AR0`, contradicting
  the any-instance rule it was meant to guard. The test now matches; no behaviour changed.

### Documentation

- **A green test run no longer reads as a measured skill eval.** `tests/python/test_skill_evals.py`
  described itself as grading "captured responses," and `evals/README.md` said every case "is
  graded by binary, code-checked assertions" — but no capture step exists: nothing dispatches
  the case prompts and no responses are stored. What runs offline is the assertion engine
  against hand-built fixture plans plus the eval-set lint. Both files now say so, and
  `benchmark/README.md`'s totals line no longer counts them as "skill-eval tests green".

- **Published test counts were stale and mutually contradictory.** `tests/README.md` and
  `benchmark/README.md` disagreed on the same suites (202 vs 344 harness tests, 37 vs 52
  skill-script tests). Every figure is re-derived: **924** bats across **60** files, 52 Python
  skill-script, 350 Python harness, 48 Swift — **1374** total. The hand-maintained coverage
  roster in `tests/README.md` is replaced by a pointer to `tests/shell/meta/coverage-proxy.bats`, which
  computes the target set at run time; a prose count that nothing enforces is what drifted.

- **Two sections were over the 1000-char lint cap.** `skills/agent-coordination/SKILL.md`'s plugin-hook
  writers table (1178) had the same lifecycle-field sentence duplicated across two rows and an
  inline aside on the `state_transition` hook path; both are factored into a `Plugin-hook row
  fields` subsection. `shared/state-ledger.md`'s write-operations section (1137) gained an
  `Idempotency and key creation` heading over its existing trailing paragraph. No content removed.

## [4.0.16] — 2026-08-15

### Fixed

- **`scan-secrets.sh` no longer fails open.** The regex fallback swallowed grep's exit
  status with `|| true`, making "no match" (exit 1, normal) indistinguishable from "the
  engine crashed" (exit >1). On macOS, BSD `grep` can trap on a pattern it cannot compile
  (`Trace/BPT trap: 5`, status 133); the scan then exited **0** — the documented "no
  Critical/High findings" code — so a crashed scan read as a clean bill of health to any
  reviewer following the skill's own instruction to invoke the script rather than reason
  through the patterns by hand. The status is now discriminated exactly as `gitleaks_scan`
  already did: >1 reports the failing pattern and file on stderr and returns 2 (the
  script's existing hard-error code). Clean (0) and findings-present (1) are unchanged.
  This is the same failure class an existing comment in the file describes one layer down,
  where a `2> /dev/null` once hid a dead pattern for the life of a regex.

- **`state-merge.sh` resolves the workspace instead of trusting cwd.** The hook fires on
  `SubagentStop`, and the subagent that just stopped is very often a DV stream — the one
  stage for which worktree isolation is mandatory. Its cwd is a linked worktree, where
  `.context/` does not exist, because the directory is gitignored and never carried into a
  worktree checkout. Resolving `.context/` relative to cwd therefore made the documented
  "Layer 2 safety net" structurally unable to patch the ledger for the only stage that
  always needs it, and it failed silently — a `no artifact resolved` line written into a
  shadow `.context/logs/` inside the worktree, a directory deleted along with it. Had an
  artifact resolved, the completion patch would have merged into a throwaway ledger. The
  hook now resolves `WORKSPACE_ROOT`, then `CLAUDE_PROJECT_DIR`, then the parent of
  `git rev-parse --git-common-dir` (which points at the main checkout from inside a linked
  worktree), before falling back to `pwd`. The corrupt-ledger repair path derives its temp
  file from the resolved ledger so the two cannot land on different filesystems.

- **The test-execution denial now names the supported way to build.** Stages without
  test-execution authority were told only to record `requests_test_evidence` or return
  blocked. `--no-test` — accepted by every platform plugin's `build-test` command, and
  already classified `build_only` and allowed by this gate — went unmentioned. In a
  measured run two streams were denied, neither discovered the flag, both invented
  `--build-only` (which no command accepts, so the classifier reads it as a full test run
  and denies again), and both then fell back to invoking the toolchain directly, which
  `agents/developer.md` forbids. The denial now names `--no-test` first, warns that
  `--build-only` is not a real flag, and states explicitly that falling back to the raw
  toolchain is not an option.

- **`publish-pl-issue.sh` no longer silently mislabels the complexity tier.** Tier
  extraction required the word in parentheses, so a plan writing `Score: 46 / 50 — Critical
  tier.` did not match, and a silent default labelled the issue `complexity:moderate` — the
  amber label on the run's highest-risk issue, indistinguishable in the audit trail from a
  real match. A bare-word arm (word-anchored, so it cannot fire on "critically") now runs
  when the parenthesised form is absent, and applying the default emits a stderr line.

- **`dv-tree-preflight.sh` reports split worktree parents.** When linked worktrees live
  under more than one parent directory, anything that reconstructs a worktree path by
  convention rather than from `metadata.workspace_path` must guess a prefix — and can hand
  a stage another stream's tree. In a measured four-stream run a stream assigned
  .claude/worktrees/dv3-web was given .worktrees/dv0-service at spawn on four
  consecutive dispatches, because .worktrees/ held exactly one entry for the glob to land
  on; normalising to a single parent fixed it on the next dispatch. The preflight now names
  the condition and the parents involved. Advisory, not blocking: the stream that runs it
  has already passed the assigned-tree check, and the condition harms a different one.

## [4.0.15] - 2026-08-15

Claude Code 2.1.233 removed the Todo/task-tracking tools — `TaskCreate`, `TaskGet`, `TaskUpdate`,
`TaskList`, `TodoWrite` — on Opus 4.8, Sonnet 5, Fable 5, Mythos 5 **and newer**. Every model this
plugin dispatches is on that list, and the orchestrator loop was built entirely on those four
tools, so on 2.1.233 every worktask and megatask run was broken before it started. Verified
empirically rather than inferred: the tools are absent from an Opus 5 session on 2.1.233.

`CLAUDE_CODE_ENABLE_TODO_TOOLS=1` restores them. This release deliberately does **not** depend on
that. Instead the plugin moves to a single durable ledger, with no mirror and no fallback path —
one mechanism, one code path, correct whether or not the tools exist.

Two premises worth recording, because both were checked rather than assumed:

- **`CLAUDE_CODE_ENABLE_TASKS` is not the switch.** It was set in the observed environment and does
  nothing for these tools. Confusing the two costs a debugging session.
- **`state.json` already held most of the ledger.** `stages{}` carried the same status enum,
  `retry_count`, `error_file`, `artifact`, `verdict`; `state-patch.sh` already owned locking and the
  atomic write; and 13 of 16 agents already held its Bash grant. The cutover is smaller than the
  tool removal makes it sound.

### Changed

- **BREAKING — `state.json` is `version: 2`.** `tasks{}`, keyed by numbered stage id (`PL0`, `DV0`,
  `DV1`), is now the sole stage ledger. It replaces **both** the Task System and the old `stages{}`
  map. A `version: 1` ledger is not migrated and not tolerated — readers fail loud. There were no
  in-flight ledgers on disk when this landed, so no converter ships.
- **The numbered key is the point.** `stages{}` was keyed by bare stage code and could not represent
  parallel DVN tracks, which is why `dispatched_agents[]` had to be keyed separately. `DV0` and
  `DV1` are now simply distinct keys. `hooks/test-execution-gate.sh` gains from this: two parallel
  tracks of one stage resolve to a single unambiguous stage code where bare codes forced a
  fail-open.
- **BREAKING — the four Task tools are removed from all 16 agents' `tools:` frontmatter**, and from
  commands/worktask.md, commands/megatask.md, commands/cost-report.md,
  commands/context-status.md, commands/test-report.md, commands/improve-yourself.md.
- **BREAKING — `metadata.context_files` and the F1 fallback are deleted.** `context_files` existed
  solely as the degraded path for "state.json is absent". The ledger is mandatory now, so that path
  cannot occur and a second context-delivery mechanism is exactly the kind of dual path this
  release removes. `context_refs` + `state_file` is the whole contract.
- skills/shared/task-system.md → **`skills/shared/state-ledger.md`**, with all 33 inbound
  references updated (two of them structured frontmatter deps, not prose).
- `.claude-plugin/plugin.json` — the `PostToolUse` audit matcher moves from
  `TaskUpdate|TaskCreate|Write|Edit` to `Bash|Write|Edit`. Without this the stage-transition audit
  trail silently stops, and `audit.jsonl` is load-bearing: it drives all nine resume branch tables.
  `hooks/audit-tooluse.sh` now recognises a `state-patch.sh` invocation, records `task_id` and
  `status` from it, and drops every other Bash call so widening the matcher does not turn the audit
  log into shell noise.
- `workspace.json` `worktask.task_prefix` (`"t1"`) is removed with no replacement. The `t{track}-{n}`
  id scheme it namespaced no longer exists, and no key-level namespace succeeds it: every track's
  ledger keys are the plain `<STAGE>0` ids, isolated by the track's own worktree.

### Added

- `state-patch.sh` ledger operations, replacing the retired tools: `--task-create <ID> --metadata`,
  `--task-status <ID> <status>`, `--task-block <ID> --on <ID[,ID...]>`, `--task-meta <ID> --set`.
  `--task-create` is idempotent and `--task-block` unions rather than appends, so re-running a seed
  is safe. A new `--task-id` overrides id resolution; without it the script resolves a stage code to
  the open instance of a split stage, else the highest existing, else `<CODE>0`.
- Self-test groups T14 (ledger ops, blocked_by union, idempotent create) and T15 (split-stage id
  resolution, explicit override); three bats tests covering the audit hook's ledger filtering.
- `Bash(bash skills/worktask/scripts/state-patch.sh:*)` granted to `designer`. `prompt-engineer` and
  `workflow-engineer` already held unrestricted `Bash`.

### Changed — Claude Code 2.1.221→2.1.233 integration

- **The 200-subagent per-session spawn cap is gone** (2.1.224). "Three independent ceilings" is now
  two — depth and concurrency. `/megatask`'s ~18/~22-issue batch ceiling and the advice to raise
  `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION` or split the batch are deleted; batch size is bounded by
  concurrency, disk, and rate budget alone.
- **Subagent forking is on by default** (2.1.232) — `CLAUDE_CODE_FORK_SUBAGENT=1` is no longer
  needed, and a fork inherits the parent's prompt cache, making it the cheapest available handoff
  for a stage that needs whole-orchestrator context.
- **Worktree git isolation is runtime-enforced** (2.1.222), promoting a corpflow convention to a
  guarantee. The v4.0.14 conflict-recovery precondition stays as written — it is conditioned on the
  *host* refusing destructive git, which is still the right framing.
- Documented: `/commit-push-pr` no longer auto-approving dangerous git flags (2.1.229);
  background sessions preserving work per `CLAUDE.md` (2.1.221); `/review` as a `/code-review` alias
  with `ultra` and background high-effort runs (2.1.223, 2.1.232); org-restricted family aliases
  stepping down within the family and the restricted-model warning (2.1.222, 2.1.223); `Notification`
  firing for permission prompts under Desktop/VS Code (2.1.233); PreToolUse auto-allow no longer
  widening an agent's grant list (2.1.222); immediate plugin activation, `"."` skills paths, the
  `archive` source with SHA-256 pinning, and `plugin validate` frontmatter checking (2.1.221,
  2.1.224, 2.1.233); cross-session `SendMessage`/`ListAgents` (2.1.224-2.1.232);
  `CLAUDE_CODE_WORKFLOW_PREFIX_STAGGER_MS` sibling staggering (2.1.229); and
  `CLAUDE_CODE_TOOL_MEMORY_LIMIT` (2.1.233, Linux only).
- Minimum Claude Code raised **2.1.220 → 2.1.233**, pinned to the band top per the v3.35.0/v3.37.0
  precedent.
- `MEMORY.md` trimmed from 37KB to under its own documented ~5KB cap.

## [4.0.14] - 2026-08-15

A completed 9-issue parallel `/megatask` batch, turned into tooling. Nothing here is speculative:
every item below is a collision that actually happened, was paid for once by trial, and is written
down so the next batch does not pay for it again. Two halves — codifying git mechanics already
learned (REQ-1..4), and reducing the collision *rate* by giving parallel tickets visibility into
shared seams and by making the one purely mechanical conflict class self-resolving (REQ-5, REQ-6).

Three of the six changes exist because a premise in the originating post-mortem turned out to be
false when checked against the tree, so the corrections are part of the release:

- **The deny-list premise does not hold in this repo.** The proposal assumed a `settings.json`
  denying `git merge` / `git reset --hard` / `git push --force`. This repo ships no such file. That
  refusal was a property of the *host environment* the batch ran in. A playbook that asserts a file
  the reader cannot find loses its credibility on the first line, so the playbook is written
  **condition-first** instead.
- **Git has no per-worktree exclude.** `.git/worktrees/<name>/info/exclude` is simply not consulted
  (verified on git 2.54); only the common dir's info/exclude works. So the exclusion is
  necessarily checkout-wide, and the release documents that consequence rather than hiding it.
- **The "one-line script fix" was not one line.** Three candidate mechanisms with materially
  different blast radius, one of which pollutes every future commit.

### Added

- **`## Conflict Recovery` playbook** in `skills/megatask/references/git-integration.md`. Five
  ordered steps for the case where the environment refuses destructive git: rebase locally, push
  under a **new** branch name, open a replacement PR, close the superseded one, merge the
  replacement. Step 2 is the non-obvious one and gets its own subsection — re-pushing the original
  name would need `--force`, which is exactly what is refused. A further subsection reconciles the
  local rebase with `git-conventions.md § Merge Strategy`: that rule governs how a PR is
  *integrated*, not whether a branch may be rebased before review.
- **Scratch metadata excluded at worktree creation**, not reactively. `init-worktree.sh` gains
  `exclude_scratch`, writing `/workspace.json` and `/.worktrees/` into the git **common** dir's
  info/exclude *before* `git worktree add`, behind an exact-line `grep -qxF` guard so repeated
  init cannot duplicate entries, with a provenance header naming the script that wrote them. The
  motivating failure was an unscoped stage-everything command during a conflict resolution that
  committed the batch's own scratch file to the shared branch. It never touches the tracked
  `.gitignore` and never writes a stored setting; `--dry-run` announces and writes nothing. The
  checkout-wide reach is bounded and documented: an ignore rule can never mask a **tracked** file,
  and the patterns are anchored, so a nested src/sub/workspace.json stays visible.
- **`## Conflict Resolution` rules** in `skills/megatask/SKILL.md`. Rule 1: DI-container and
  coordinator-shaped conflicts are hand-resolved by a human and **never** script-merged — a scripted
  "keep both sides" resolver mis-joined an argument list (a missing separator, because the other
  side's block opened with a comment) and duplicated a closing brace, twice, both caught only by a
  later build. Rule 2: a real build and test run before pushing any resolution. A script is
  permitted only where its class needs no interpretation *and* it refuses what it does not
  recognise — which is the bar `resolve-pbxproj-membership.sh` below is held to.
- **`## Shared-Seam Registry` convention** — a decision rule, not advice. Exactly one registry per
  batch, hosted by the sole level-0 issue, or by the milestone / orchestrator issue when there are
  several level-0 issues or none; the rule is total, so no batch shape is ambiguous. The schema
  requires a **verbatim declaration block with ordered parameter labels**, plus `consumers:` and
  `change-protocol:`. The ordering is load-bearing: the motivating failure was two parallel tickets
  inventing the same abstraction under near-identical names with a **reversed argument order**, and
  a name-only schema would not have caught it. `commands/megatask.md § Step 3` restates the
  resolution inline so the per-issue prompt is self-sufficient. **Convention, not a gate** — nothing
  validates the registry this release, by design.
- **`skills/megatask/scripts/resolve-pbxproj-membership.sh`** — sorted-union resolver for
  `PBXFileSystemSynchronizedBuildFileExceptionSet.membershipExceptions`, the one project-file
  conflict class that needs no interpretation. Dropping either side silently unregisters test
  files: green build, tests never run. All-or-nothing — any out-of-class conflict anywhere refuses
  the whole file with exit 1 and leaves it byte-identical (structural, not defensive: the parse goes
  to a temp buffer and `mv -f` runs only on accept). It refuses a conflict outside the list, a diff3
  `|||||||` base section (resurrecting a deliberate deletion is worse than refusing), a non-entry
  line inside a side, nesting, an unterminated conflict, and a list close inside a conflict. Ships
  with `--dry-run`, a 35-check `--self-test` and dual `--flag value` / `--flag=value` parsing,
  matching `build-orchestrator.sh`'s established pattern, and is registered in § Canonical Scripts.

### Changed

- **`skills/shared/git-conventions.md` records the comment-character trap.** The `#NNN`
  commit-subject convention collides with git's default comment character; in the source batch it
  destroyed the subject on **four** separate invocations, promoting the body's first paragraph to
  the subject each time. The scope is now stated precisely, because the imprecise version is what
  makes people distrust the note: `strip` cleanup deletes `#`-leading lines on **editor-driven**
  invocations only — `rebase --continue`, bare `commit`, `--amend`, conflict commits — while `-m`
  and `-F` use `whitespace` cleanup and are unaffected. The remedy is **per-invocation**
  (`git -c core.commentChar=…`, or `--cleanup=verbatim`); writing it into a stored configuration
  file is explicitly forbidden. Stated once, in the source of truth; the megatask docs reference it
  rather than restating it.

### Fixed

- **The test-execution gate was inert for every stage after PL, of every worktask.**
  `hooks/test-execution-gate.sh` resolves the acting stage from `.context/state.json` alone —
  deliberately, never from `agent_type` or an env var, so a nested delegate inherits the stage and
  the deny reaches its own leaf `Bash` call. But the orchestrator loop marked stages `in_progress`
  in the **Task System only**: the sole state.json mirror sat in the step-6.5a2 incomplete-return
  path, which fires *after* a stage returns, not at dispatch, and stage agents only ever patch
  `completed`. So from dispatch to completion nothing in the ledger named an acting stage,
  `resolve_stage()` returned empty, empty means allow — correctly, since guessing in the deny
  direction would deadlock unrelated sessions — and every deny the hook implements was unreachable
  in a live run. Nothing was unsafe: this is a fail-*open* backstop by design, and the
  dispatch-time ban banner and tool-grant narrowing are the primary controls. The backstop simply
  was not covering. `skills/worktask/SKILL.md` step 5 now mirrors the mark into state.json
  immediately beside the `TaskUpdate`, with the reason stated inline so the two writes are not
  separated again. Found by the gate firing twice against a hand-written ledger during this
  release's own run, while two real full-suite invocations at banned stages had gone through
  untouched. Both directions are pinned by tests — a non-authority stage denies, and a ledger with
  nothing `in_progress` fails open — plus an assertion that step 5 still carries the mirror, since
  that instruction *is* the fix and nothing else guards it.
- **Separated `stat -f` is a GNU/BSD trap, and it was in the new code.** `stat -f '%Lp' "$f"` is
  correct on BSD, but on GNU coreutils `-f` is `--file-system` and takes no argument, so the format
  and the path become operands: stat prints a filesystem block **to stdout** while exiting non-zero,
  the `|| stat -c%a` fallback sees only the status, and the capture becomes that block concatenated
  with the fallback value. `chmod` then fails and the script aborts before its `mv` — on Linux,
  every accepted resolution died. All four sites now use the repo's attached idiom,
  `stat -f%Lp "$f" 2>/dev/null || stat -c%a "$f" 2>/dev/null || printf '644'`, which is safe because
  GNU getopt rejects `-f%Lp` at option-parse time and writes nothing to stdout — the same form ten
  pre-existing call sites already use. Two guards make the class fail locally next time: a runtime
  `^[0-7]+$` check before the `chmod`, and a self-test probe asserting the token is single-line and
  purely numeric.
- **Resolved files keep their permission bits.** The temp buffer is created 0600; the target's mode
  is captured before the `mv` and re-applied. Tests assert a distinctive `0640` survives, not the
  644 default that would pass by accident.
- **No temp-file residue.** `$( )` subshells reset traps, so buffers allocated inside one were
  unreachable by the cleanup trap, and `TMPDIR` alone does not help (macOS `mktemp -t` ignores it).
  Buffers now use an explicit template directory under `RESOLVE_TMPDIR`/`TMPDIR`, with a
  module-level array and a single EXIT trap. Measured across a self-test run: 659 temp entries
  before, 659 after; previously +34 per run.

### Known limitations

- **Not executed on Linux.** The full suite (913 bats + 52 + 350 unittest, 0 failures) and all
  self-tests ran on macOS / BSD userland. The `stat` fix above was validated against a faithful
  GNU-getopt `stat` model with a positive control that reproduces the original break, but that
  models exactly one binary — `mktemp`, `chmod`, `awk` variants, `sed`, `grep -qxF` and git's
  `rev-parse --git-common-dir` answer are unexercised on a real GNU userland. This repo has no CI
  configuration, so nothing catches a Linux regression automatically. A Linux job is recommended
  before the plugin is relied on off-macOS.
- **The worktree exclusion is verified on git 2.54 only.** It depends on the per-worktree
  info/exclude *not* being consulted while the common-dir one is — empirically established, not a
  documented guarantee. A future git could change it; the self-test would catch it, but only when
  run.
- **`skills/worktask/scripts/state-patch.sh` still carries the separated-`stat` shape** at its lock
  mtime read, where it degrades *silently* (`|| printf ''`). Pre-existing at HEAD and deliberately
  out of scope for this release; tracked as a follow-up.

## [4.0.13] - 2026-08-13

The same rename, a second time. v4.0.0 moved `igrsoft` → `company-workflow` because the plugin id
was the last artifact carrying the vendor name; this release moves `company-workflow` → `corpflow`
because the repository has since become IGRSoft/corpflow and the plugin id was, again, the last
thing to catch up. The v4.0.0 entry below is the template this pass followed — the same three-role
split, the same runtime-literal traps, the same sibling ordering.

The word's three roles, and separating them is again the whole substance. **Plugin identity**
moves: every `company-workflow:<agent|skill>` invocation id, the `marketplace.json` plugin entry,
`plugin.json`'s `Stop` matcher and its notification title, the `Task(company-workflow:…)`
frontmatter grants, and the install key (`corpflow@igrsoft`). **Vendor identity** does not: the
author block (`IGRSoft`, `support@igrsoft.com`), the github.com/IGRSoft/… owner segment, the
`com.igrsoft.*` bundle IDs in `/appstore-iap`, and the marketplace name — still `igrsoft`, so the
cache path becomes `~/.claude/plugins/cache/igrsoft/corpflow/<version>/` with only the second
segment changed, exactly as last time.

The **third** role is new, and is what made this pass different from v4.0.0: the **repo slug**.
GitHub had already been renamed, so `README.md`'s `git clone https://github.com/igrsoft/company-workflow.git`
was a published command that no longer resolved, and the cache-discovery glob in
`skills/shared/plugin-root-resolution.md` pointed at a directory that will never exist again.

Five sites matched the literal string at runtime and would have failed silently rather than
loudly — the first four are the same four v4.0.0 called out, which is itself the argument for
writing them down:

- `hooks/dv-screenshot-gate.sh` guards on exact equality (`!= "corpflow:developer"`). Left stale,
  the DV screenshot gate would no-op on every run with no error.
- `skills/self-improvement/scripts/build-context-set.sh` maps agent refs to file paths via an awk
  field compare (`$1 == "corpflow"`).
- `.claude-plugin/plugin.json`'s `Stop` matcher must track the plugin name or the PL/FN
  approval-gate push notification stops firing.
- `skills/worktask/scripts/publish-pl-issue.sh` carries four identical copies of the plugin-prefix
  leak regex that strips internal agent ids out of published GitHub issues; they stay byte-for-byte
  in lockstep with the list in `skills/shared/compatible-plugins.md`.
- **New this time:** `skills/agent-coordination/SKILL.md` documents that `subagent_type` matching is
  case- and separator-insensitive, using the literal example `Task({ subagent_type: "Company_Workflow:Developer" })`.
  A lowercase-only pass rewrites the rest of that line and leaves the example standing — the one
  illustration on the page would have become the only stale id in the repo. The residual sweep is
  now case- and separator-insensitive (`grep -niE "company[-_ ]?workflow"`) so this class cannot
  survive again.

### Changed

- **Redundant phrasing collapsed.** `company-workflow workflow` doubled the noun; under the new
  name it would have read `corpflow workflow`. The trailing noun is dropped instead — "this agent
  is inside a company-workflow workflow" becomes "this agent is inside corpflow" — across ~78 sites
  in the six sibling plugins' agent intake blocks. The separated form
  `company-workflow 11-stage workflow system` becomes `corpflow 11-stage pipeline`, reusing the word
  the README already uses for the stage chain.

### Breaking

Recorded as breaking despite the PATCH version number, which is user-owned (the same call as at
4.0.3). Anyone reading semver alone will not be warned by the number.

- **`company-workflow:*` agent and skill ids no longer resolve.** There is no back-compat alias.
  The six sibling plugins (`apple-developer`, `system-developer`, `android-developer`,
  `frontend-developer`, `backend-developer`, `ai-engineer`) are updated in the same pass; merge
  this release first, since their docs reference `corpflow:` ids.
- **`COMPANY_WORKFLOW_*` environment variables renamed to `CORPFLOW_*` with no fallback read** —
  `TEST_GATE`, `TEST_SELECT`, `AR_REF_STRICT`, `PR_BODY_STRICT`, and
  `COMMENT_DENSITY_{MAX,WARN,MIN_LINES}`. An eighth, `COMPANY_WORKFLOW_DIR` → `CORPFLOW_DIR`, lives
  in scripts/validate.sh in four of the siblings. Update shell profiles and CI jobs.
- **Stale installs must be reinstalled.** `~/.claude/plugins/cache/` and the
  `known_marketplaces.json` / `installed_plugins.json` indexes still key on the old plugin name
  until then.
- **`audit.jsonl` is not comparable across the boundary** — the `subject` field changes prefix, so
  pre- and post-rename audit trails cannot be diffed directly.

### Not changed

Pre-4.0.13 `CHANGELOG.md` entries and `benchmark/results/**` keep their original text. A changelog
row records what shipped under the name in force at the time; rewriting it would make the history
lie. `benchmark/results/result.html` still reads "igrsoft benchmark" for the same reason and
regenerates from `report.py` on the next `make report`.

## [4.0.12] - 2026-08-12

Activating guards that were already written. A full `/worktask` run (OV-184, shipped as PR #436)
burned a whole DV cycle: the agent pinned itself to a stale worktree of a *different* clone and
could write nothing. The agent's logic was not at fault. `/worktask` never stamped
`metadata.workspace_path` — only `/megatask` did (`commands/megatask.md`) — and that single
omission silently disabled three guards that already existed and were already tested:

| Guard | Why it no-opped |
|---|---|
| orchestrator workspace-root cross-check | `_task_root="${_task_root:-$_orch_root}"` compared a value to itself |
| `dv-tree-preflight.sh` `resolve_assigned()` | returned empty → warn + exit 0, by design |
| `agents/developer.md` path-prefix check | gated on "when `task.metadata.workspace_path` is set" |

`dv-tree-preflight.sh` would have caught this exact failure — its header names the scenario
verbatim — but nothing invoked it: a prose reference with an unfilled `<workspace>` placeholder,
no hook, no orchestrator injection.

### Added

- **`metadata.workspace_path` stamped on every run.** Seeded into `state.json` at
  `commands/worktask.md` Step 3a (`git rev-parse --show-toplevel`, else `pwd`) and onto the PL0
  task at Step 4, beside `isolation`. Documented in the ledger schema
  (`handoff-protocol.md § metadata.workspace_path`) and in `task-system.md`.
- **`dv-tree-preflight.sh` invoked from the DV dispatch surface.** A new Step 4.8 assigned-tree
  banner instructs DV to run it before its first edit and treat exit 1 as blocking — following
  the precedent Step 4.8a states outright: *prose loses to the dispatch surface*.
- **Step 6.5a2 — incomplete-return arm.** An agent that yields mid-sentence with budget remaining
  has not errored, so 6.5a does not fire and control fell through to F3, which hard-codes
  `status:"completed", verdict:"ok"` over a stage that never finished. The arm keys on the
  evidence (artifact absent, or present with no `handoff.verdict`) rather than on message shape,
  marks the stage `in_progress`, emits `stage_returned_incomplete`, and resumes the agent via
  `SendMessage` instead of re-delegating. A normally-completed stage still takes the Layer-2 path.
- **`--emit pr` idempotency.** `attach-visual-evidence.sh --emit pr` caches its emission at
  `.context/logs/visual-evidence-pr-<worktask_id>-<run_index>.md` and replays it on any later run
  for the same run index; `--force` re-hosts. Running it twice previously uploaded two full asset
  sets and orphaned the first on GitHub. `fn-preflight.sh` treats the new `reused` audit result
  exactly like `ok`, so a replay cannot retire the "## Visual evidence" heading requirement.
- **`agents/developer.md` § The voluntary yield** — never end a turn to announce what you are
  about to do next; an intent sentence is not a handoff. Plus a sixth Artifact-Complete Gate box.
- **`agents/developer.md` § Manifest row shape** — DV is told the manifest is written *by the
  skill* and so never sees a column name. Adds the canonical 9-column row and the two-digit-index
  rule, and says why a malformed row is worse than a missing one.

### Changed

- **The cross-check no longer defaults to itself.** An unset `workspace_path` is now a loud stop
  with a named audit row, not a silent pass.
- **`skills/dv-screenshot-capture/references/examples/README.md` corrected to the canonical 9 columns.**
  It was a **7**-column table (no `Captured`, no `Design Ref`) that would fail
  `--validate-manifest` — and it is the file `attach-visual-evidence.sh`'s failure diagnostic
  sends a stuck DV agent to. Its AC-coverage table became a list, since the validator judges
  *every* pipe table in the file it is pointed at.
- **`workspace-modes.md`** gains the sibling-**worktree** hazard beside the existing
  sibling-*clone* hazard, with the table of why D0, D0.0, and the stated Edit/Write rule all pass
  on the wrong tree. Its claim that stale worktrees are auto-cleaned with no reuse of
  prior-session worktrees is corrected — this run disproved it.
- **`agents/developer.md` D0/D0.0** name the failure geometry: once the harness pins a worktree,
  `git rev-parse --show-toplevel` returns *that* tree, so D0 is self-consistent and cannot detect
  the problem; and a stale worktree passes D0.0 because it genuinely is isolated.
  **Isolation ≠ assignment.** D0.0a's `<workspace>` placeholder is replaced with the concrete
  resolution order.
- **`agents/product-manager.md`** no longer frames `workspace_path` as a megatask-mode detector.
- **`skills/worktask/references/resume.md`** classifies the yielded agent, which sat between its live-mid-work
  and agent-gone rows.
- **`pr-body-lint.sh` usage errors print to stderr.** `usage()` sent the help header to stdout
  while the one-line diagnostic went to stderr, so under this plugin's own `; true` / piped
  convention a caller saw help text and read it as "ran, nothing to report". An explicit
  `-h`/`--help` still writes to stdout.

## [4.0.11] - 2026-08-10

Fail-loud worktask tooling (#431 retrospective, 9 approved self-improvement proposals). The
defect class: a tool that reports success while doing nothing. `state-patch.sh`'s existing
exit-0-on-unresolved behaviour is correct for most callers (a hook probing for a stage that
never ran), but for the 13 stage agents patching their *own just-written* artifact it meant a
missed ledger patch returned success — the same silent-skip shape recurred three separate times
in this repo's own history before this worktask.

### Added

- **Fail-loud self-patch assertion (REQ-2).** `state-patch.sh` now exits **3** when the artifact
  does not resolve, `--prev` is present, and `--via` is absent — the documented signature of an
  agent patching its own predecessor edge (`handoff-protocol.md:846`). Every other combination —
  a hook, `--via`, or a never-run stage — keeps the exact exit-0 no-op byte for byte;
  `state-patch.bats:51` is unmodified. `--allow-missing-artifact` silences the assertion for a
  caller that legitimately wants no edge, but writes **nothing** — documented as such at all four
  citing sites after a review-round finding that the first pass had it write a synthesized entry.
- **Resolution-only alias basenames (REQ-1).** `DR: review`, `QA: qa`, `FN: finalization` resolve
  in a new sibling function, never inside the canonical 13-entry map, so the existing parity
  guard keeps reading exactly 13 primaries. `AR: analyzing` is deliberately not added — a prior
  artifact-naming generation used it, and re-accepting it would let a stale file answer for the
  current one.
- **`USER` as a valid `--prev` predecessor (REQ-3).** Matches the already-canonical `USER→PL` /
  `USER→IR` edges; `USER` still owns no artifact and is never a valid `--stage`.
- **`dv-tree-preflight.sh`, new D0.0a gate (REQ-7).** Asserts the resolved git root **equals**
  the assigned workspace before DV's first edit. Worktree isolation alone doesn't catch this —
  a stale worktree is perfectly isolated, which is how a correctly-specified edit once landed on
  the wrong tree.
- **Screenshot-manifest schema at the writing stage (REQ-8).** `attach-visual-evidence.sh
  --validate-manifest` is a new read-only mode; `dv-screenshot-gate.sh` ANDs its verdict into the
  pass condition and now blocks a table-free manifest sitting beside real capture files (the
  parser reports the fact, the gate applies the policy — only the gate can see the directory).
  A genuine table-free skip-rationale manifest with no captures beside it still passes.
- **Explicit issue-close check on non-default integration branches (REQ-9).**
  `fn-preflight.sh issue-close-required` compares the merge target against the repo's default
  branch and prints the exact `gh issue close <N>` command when they differ, so a non-default
  integration branch can no longer leave the tracking issue silently open. FN's procedure gained
  the acting step that runs it and executes the printed command.

### Changed

- **Tool grants for 10 of 13 stage agents, not the plan's 6 (REQ-5).** `software-architector`,
  `technical-writer`, `team-lead`, `stakeholder`, `ethics-reviewer` held no `Bash` grant at all;
  `product-manager`, `technical-lead`, `security-reviewer`, `release-engineer`, `project-manager`
  held narrow allowlists with no `bash`. All 10 gain the scoped
  `Bash(bash skills/worktask/scripts/state-patch.sh:*)` token. This grant is **empirically
  unverified** against the permission matcher under enforcement — the probe session that ran it
  enforced no denials at all — so it is not the fix by itself.
- **Mandatory documented Edit-direct fallback for all 13 agents (REQ-6), the load-bearing half.**
  `$CLAUDE_PLUGIN_ROOT` was confirmed empty in the model's Bash tool environment (exit 127 on a
  probe), so no grant string keyed on it — and the cache-install path is version-keyed, so no
  stable literal exists either way. Every agent's State Patch section now states an ordered
  ladder: run the script; on exit 3, write the artifact and re-run; if the tool cannot run at
  all, patch `.context/state.json` directly with `Edit` — both the `stages.<CODE>` entry and the
  `handoffs["<PREV>→<CODE>"]` edge — and record the occurrence under `metadata.pl_tooling_gaps`.
  The SubagentStop hook is explicitly not a substitute: it never passes `--prev`, so it repairs
  the stage entry but drops the handoff edge.

### Fixed

- `attach-visual-evidence.sh` table separator detection now accepts alignment rows (`:---`),
  removing a false schema block on a valid model-authored table.
- `fn-preflight.sh`'s unresolved-issue line no longer promises a `gh issue close` command in the
  same breath as reporting it cannot be printed.
- `state-patch.sh`'s basename resolver requires the filename stem to equal the basename exactly,
  so e.g. `qa-notes-3.md` can no longer answer for the new `qa` alias.

## [4.0.10] - 2026-08-07

Eval-audit release (#279). The benchmark's only quality signal was the arm's own
`swift test` — self-graded, and across every stored live record it never once
returned `fail`. Nothing measured whether generated output was actually correct,
user corrections to delivered work were discarded with each run's gitignored
`.context/`, and skill eval sets carried prose expectations no grader could
check. This release makes each of those signals held-out, durable, or binary.

### Added

- **Held-out oracle** (`benchmark/harness/benchmarkkit/oracle.py`, `benchmark/oracle/cases.json`).
  Both arms' prompts embed a scripted CLI contract (`_cli-contract.txt` is the
  SSOT; a lint pins both prompts to it verbatim). After measurement the harness
  release-builds each arm's `tictactoe` and scores it against 30 cases whose
  goldens are captured from `ttt-template`, never hand-written. Cases are tiered:
  `specified` (24, restates the contract — the floor `pass_fail` reads) and
  `implied` (6, derivable but unstated — the discriminating signal, reported
  beside the verdict). A mutant that sweeps `specified` while failing `implied`
  is built and asserted in `test_oracle.py`.
- **Comparability eras.** Every record now stamps `era` (harness generation,
  prompt-contract version, per-stage model pins); `bench-analyze` compares
  against the previous live record automatically and caveats each differing
  dimension — the v3.37.1 silent-repin failure mode, closed.
- **Committed failure-label dataset** (self-improvement Step 5b,
  `evals/failure-labels.jsonl`). Classified user edits persist as append-only
  JSONL labels via `append-labels.sh` (idempotent per worktask run, opt-out
  `SELF_IMPROVE_LABELS=0`, no diff bodies); `label-stats.sh` aggregates per
  target/category. Runs regardless of proposal approval.
- **Binary skill eval sets.** `skills/request-plan/evals/evals.json` replaces
  prose expectations with code-checked assertions (`contains_all`/`contains_none`/
  `regex_all`/`regex_any`); `tests/python/test_skill_evals.py` is the assertion
  engine plus a lint keeping every eval set gradeable. Interpretive criteria are
  parked in `deferred`, not graded badly.
- **Skill-reference contract** (`tests/shell/skills/skill-refs.bats`). Four
  repo-wide predicates: every ordered `Skill(` call has the `Skill` tool grant,
  every Skill target names a real skill, every `skills/<name>/…` citation
  resolves, and every agent citing plugin paths carries a `## Plugin paths`
  resolution block. Each predicate is falsified against a synthetic tree.
- **Findings docs**: `benchmark/results/AGENT-GRANT-ENFORCEMENT.md` (tool *sets* bind in
  headless dispatch; `Bash(cmd:*)` scoping and `maxTurns` did not — probe
  specified before any fix), `benchmark/results/KNOWN-BAD-RECORDS.md` (stored records
  excluded from comparisons instead of edited), `benchmark/results/VARIANCE-STUDY.md`
  (the n=3 procedure; the only step that spends money).

### Changed

- **Per-arm budgets and per-stage projections** (`benchmark/harness/benchmarklive/budget.py`).
  Paired runs split `--budget` into equal per-arm tallies (a shared purse let
  the first arm starve the second — the defect that invalidated the first
  paired A/B), projections use calibrated `STAGE_EXPECTED_TOKENS` (DV ≈ 10× a
  light stage; the flat figure admitted budgets that could not finish), and the
  running tally reserves the heavier of the projection and the heaviest
  observed stage.
- **Fail-closed verdicts.** An unmeasured or degraded arm is never green;
  where the oracle ran, it — not the arm's self-written suite — decides
  `pass_fail`. `coverage_pct` is `null` when unmeasured, never a fabricated 0.0.
- **Live retention is unbounded** (`rotation.RETENTION`): live records and
  their `benchmark/results/runs/live/` detail files are kept and tracked in git —
  deterministic records stay latest-3 and gitignored.
- **Agents**: every agent carries the `## Plugin paths` resolution block;
  `developer` and `stakeholder` gain the `Skill` grant their bodies order
  (`dv-screenshot-capture`, `self-improvement` — both silently never ran);
  `Skill` invocations use the real `Skill({skill: "company-workflow:…"})`
  syntax; `technical-lead`'s DR gate reads commands/dev-code-review.md as a
  command instead of invoking it as a nonexistent skill.

### Fixed

- Each arm's verdict reads its own degradation flag; a WITHOUT-only breach no
  longer fails a complete, oracle-conforming WITH arm (pinned by
  `PairedVerdictSymmetry`).
- Label dedup hashes `(worktask_id, run_index, path, added, removed, summary)`,
  so a correction recurring in a later worktask counts as the recurrence it is
  instead of being dropped.

## [4.0.9] - 2026-08-06

Every test run was the whole suite. Editing one agent doc, one hook, or one script ran all
55 `.bats` files, so the dev loop paid full-suite latency for a one-file change and the only
lever was to skip testing entirely. The obstacle to fixing it is that a wrong selector is
silently green — it under-runs and reports success — so the change is built to over-select
by construction: three independent layers unioned, a floor that every run includes, and
seven triggers that abandon selection and run everything. Selection is opt-in and off by
default; a bare `./run-tests.sh` is byte-identical to what it was.

### Added

- **A three-layer change→test dependency matrix.** L1 is computed live from the tree — every
  repo path a `.bats` names literally, plus the `X.sh` → `X.bats` convention resolver, which
  matters because 13 scripts have more than one consumer and convention alone returns one of
  them. L2 is `tests/selection/matrix.tsv` (24 rows), for dependencies that are a *pattern*
  rather than a path, where the glob lives inside the script the test invokes. L3 is the
  ALWAYS floor, a constant in `tests/lib/select_lib.bash`: lib/test-helper,
  meta/coverage-proxy, skills/plugin-root-refs, and worktask/manifest-parity — 47 of
  811 tests, included in every scoped run. The engine lives in `tests/lib/select_lib.bash`
  and `tests/bin/select-tests.sh`.
- **An opt-in runner surface** (`run-tests.sh`, `Makefile`). `--changed` runs the selection,
  `--base <ref>` picks the diff base, and `--print-selection` prints the plan and runs
  nothing. `make test-changed`, `make test-changed BASE=master`, and `make test-select` wrap
  the three. `COMPANY_WORKFLOW_TEST_SELECT=0` disables selection entirely. Passing
  `--changed` with `--coverage` is a hard **exit 64**, not a silent full run.
- **Fail-closed triggers F1–F7.** An unrecognised path, an unresolvable base, an empty
  changed set, a delete under tests/, hooks/, .claude/hooks/ or a skill scripts/
  directory, a change to the runner or the selector itself, and an unparseable matrix each
  yield a `FULL` verdict and run everything. `--print-selection` names the trigger id, so a
  widened run says why it widened instead of looking like a slow selection.
- **A >50% widening cap with a hand-off to QA** (`run-tests.sh`). A selection covering more
  than half the file count emits `WIDE`. If `.context/state.json` shows the DV stage in
  progress the run exits **65** and hands the suite to QA, since DV has no full-suite
  authority; for everyone else `WIDE` is informational and the run proceeds.
- **A 17-guard suite** (`tests/shell/meta/test-selection.bats`). It drives the real selection
  entry point rather than asserting on the matrix data, refuses a matrix row without a
  rationale, refuses a glob matching no tracked path, refuses a `.bats` no layer can reach,
  and plants violations to require the checker to name them — the fail-closed and cap
  behaviours are falsification tests, not assertions about output text.

### Changed

- **The test-execution gate now classifies by argument** (`hooks/test-execution-gate.sh`).
  `run-tests.sh` has a selection surface, so a bare invocation is still `full_test_run` while
  `--changed`/`--base` read as `scoped_test_run` and `--print-selection` as `build_only`.
  DV may therefore run a scoped suite it previously could not. Matching is padded-segment and
  anchored, so `cat run-tests.sh` does not classify as a test run. The widening cap is
  deliberately **not** enforced here: only the runner knows the selection size, and this hook
  stays a cheap `PreToolUse` classifier.
- **`tests/shell/meta/coverage-proxy.bats`** now drives the resolver extracted into
  `tests/lib/select_lib.bash` through shims instead of carrying its own copy, and its
  script-inventory check iterates the alias keys. The resolver's `find | head -1`
  filesystem-order dependence is fixed with `LC_ALL=C sort`, so a multi-match is stable.

### Deliberately not shipped

- **No `make coverage-changed`**, and `--changed --coverage` is a hard exit 64 rather than a
  no-op (`tests/COVERAGE.md`). kcov's denominator is the **source** set and does not shrink
  when fewer tests run, so a scoped coverage run lowers the numerator only — the bash branch
  has no percentage gate to catch it and would report a drop that looks like a regression in
  the code rather than in the measurement, while the Swift branch's ≥85% gate would fail for
  a reason unrelated to the change under test. Coverage is a full-suite QA activity.
- **No module correlation.** A `SKILL.md` edit does not pull in that skill's script tests.
  This is the release's main residual false-negative risk: a reference-doc edit whose path no
  test names literally selects only the ALWAYS floor. It is bounded by the reachability and
  non-script-coverage guards, and the fix for any gap found in practice is a targeted matrix
  row, not a blanket rule.
- **No `/test-select` slash command** — manifest parity asserts the marketplace command list
  against the commands directory, so adding one carries its own blast radius.

## [4.0.8] - 2026-08-06

`state-patch.sh` skipped its write whenever a stage was already `completed` at the same
verdict. A review-remediation loop is exactly that shape — DV completes `ok`, DR requests
changes, DV remediates and re-completes `ok` — so the second call short-circuited and left
`handoffs["PREV→CODE"]` describing the pre-remediation artifact, with no flag to correct it.
The stage record and the artifact reference stayed correct, so nothing failed loudly; the
inline summary a later stage reads just described work that had since been redone.

### Fixed

- **The idempotency guard now compares the whole patch, not just status and verdict**
  (`skills/worktask/scripts/state-patch.sh`). It additionally compares
  `stages.<CODE>.artifact` and, when `--prev` is given, the handoff edge the call would
  write. Identical inputs still exit early and leave `state.json` byte-identical; a changed
  artifact or summary now re-merges and logs `re-merge: ... artifact/handoff differ`.
  Observed twice in one worktask (`AR→DV` and `DV→DR`), once on a review agent's own patch.

### Added

- **Regression coverage for the remediation loop** — self-test `T10` (same-verdict re-merge
  refreshes the edge; a third unchanged run stays byte-identical) plus two `bats` cases in
  `tests/shell/worktask/state-patch.bats`. Verified against the pre-fix script, which leaves
  the stale edge in place.

## [4.0.7] - 2026-08-06

Branch naming's `--goal` took the raw task description, so a multi-sentence description
silently truncated mid-phrase into the branch slug — the original incident was operator
error compounded by doc wording that discouraged the cheap fix (a free preview) and hid the
free one (query modes). This release ships the branch-naming R1-R4 fix, R6's linked-worktree
rename behaviour flip, and documentation reconciliation together.

**This release changes default git behaviour on every linked-worktree machine** (Conductor
and similar host-workspace setups) — see `### Changed — R6` below before upgrading.

### Changed

- **`--goal` now takes a concise imperative title**, not the raw task description
  (`commands/worktask.md § Step 3c`, `skills/worktask/SKILL.md § Validation check 10`).
  `BRANCH_NAME_PRINT=1` is documented as a free preview — no rename, no audit row — and the
  "do not re-invoke" prohibition is narrowed to **rename mode** only, so the query modes
  (`--check`/`--print-types`/`--print-target`) stay free to use.
- **Truncation is now visible end to end**: `branch-lib.sh` gains `slug_body`/`slug_budget`/
  `slug_is_truncated` (`derive_slug` refactored onto them); `branch-name.sh` emits
  `slug_truncated=1` conditionally; Step 3c writes a `branch_slug_truncated` audit row; the
  Step A.5 plan-gate summary surfaces the derived name and the truncation warning.

### Changed — refinement window & invariant reconciliation

- **The planned branch name gets one pre-commit refinement window.** New
  `skills/worktask/scripts/refine-branch-target.sh`, invoked at new Step A.4b, refines the
  planned target once from the approved plan's own `title:` before the issue is published —
  six gates, a closed 15-token noop reason set, one `branch_target_refined` audit row, atomic
  ledger write, **no git mutation**, exit 0 always.
- **Once-only rule reconciled across 8 sites** (skills/shared/git-conventions.md,
  skills/worktask/references/handoff-protocol.md, skills/worktask/references/resume.md,
  agents/project-manager.md, agents/product-manager.md, commands/worktask.md,
  skills/worktask/SKILL.md, skills/shared/task-system.md): the **rename** happens exactly
  once, at the start of planning; the **planned name** on the ledger may additionally be
  refined at most once per run, pre-commit, ledger-only, with no git mutation.

### Changed — R6: linked worktrees now rename their own branch

**Behaviour flip, opt-out available.** `branch-name.sh` now renames the local branch inside
a linked worktree (Conductor and similar host-workspace setups) instead of deferring to
whatever name the host assigned. `is_host_workspace` still detects a worktree, but its early
`return 0` is gone: a hit now sets `IN_WORKTREE=1` and falls through to the existing
`target_exists` → `git branch -m` tail, same as any other workspace. On success `branch=`
and `target_branch=` are equal.

#### R6 — why, and the risk

The deferred behaviour assumed the host owns a meaningful, stable branch name. Falsified
live, in this very worktask — Step 3c saw `cape-town` (a placeholder), and by the
finalization gate Conductor had **silently renamed the branch mid-run** to
`which-stages-ran-tests` (derived from the chat topic), so `facts.branch` diverged from the
actual local branch with nothing detecting it. Neither name was shippable, and nothing in the
old design could tell. **Risk, stated plainly**: a host that keys its own workspace tracking
to the branch name may need to re-sync after this rename. Documented rather than discovered.

#### R6 — the opt-out and the new guard

**Opt-out**: `BRANCH_NAME_WORKTREE_RENAME=0` (literal `0` only) restores the previous
defer-to-host behaviour. Subtractive at guard-ladder position 8 — it can only restore a
behaviour a higher guard already permitted, never authorize a rename a higher guard refused.
**This is the line an upgrading user most needs to find** if their host relies on the old
behaviour. **New `already_named` guard** at ladder position 4, keyed on the `branch_renamed`
audit dedupe key rather than the branch name — a host rename makes the branch
non-conventional again, and a name-based guard would have authorized a *second* rename.

#### R6 — divergence detection and disclosure

**New `fn-preflight.sh branch-divergence`** (also runs on resume): non-blocking, exit-0-
always, excluded from `all`. Compares local HEAD against the `to` of the last
`branch_renamed / ok` audit row, classifying `expected` vs `third_party`, and surfaces only
`third_party`. **Mandatory disclosure**: a stdout line at rename time names the host re-sync
risk and the opt-out; the Step A.5 gate summary carries a matching line. Both reach a user
already running the pipeline — neither reaches a user deciding whether to *upgrade*, which is
why this CHANGELOG entry is the third disclosure surface. 12 reconciliation sites, including
Step 3c's "never revert this step's rename" rule, which was previously moot inside a worktree
and is now live there too.

### Fixed

- **Audit-scan `fromjson?` guard completed against well-formed non-object lines.** R1's AD-9
  hardening closed the *unparsable*-line half of this class but left the well-formed
  *non-object* half open (`123`, `[1,2]`, `"str"` parse cleanly, then abort on the first
  field access) — and the failure is **position-dependent**: whether the bad line sits
  before or after the row a scan is looking for.

#### Fixed — all four scans, `objects` load-bearing in each

| scan | jq form | bad line before match | bad line after match |
|---|---|---|---|
| `branch-name.sh already_named` | slurped | rc 5, fails open | rc 5, fails open |
| `fn-preflight.sh branch-divergence` | slurped | rc 5, detection suppressed | rc 5, suppressed |
| `refine-branch-target.sh` once-guard | streaming | rc 0, holds | **rc 5, fails open** |
| `refine-branch-target.sh` incumbent-truncation | streaming | rc 0, holds | rc 5, fails closed |

#### Fixed — why "after the match" is the common case, not the edge case

Audit logs are **append-only**, and the streaming pair's own rows land unusually early: the
once-guard scans for `branch_target_refined / ok`, written at Step A.4b, and the
incumbent-truncation check scans for `branch_slug_truncated`, written even earlier at Step
3c — both in Phase 1, before any stage dispatch. Every later stage's row necessarily
accumulates *after* them, so "bad line after the match" isn't merely the common case for
these two scans, it's very nearly guaranteed. Demonstrated end to end against the
un-hardened once-guard: a second refinement was authorized (`ok_rows=2`, the ledger value
overwritten); hardened, it correctly declines `already_refined` (`ok_rows=1`). All four scans
now use `fromjson? | objects`; the same gap existed in three test helpers, which is why the
new cases initially failed against already-correct production code — a fixture line must not
be able to break the assertion helper and mask the real result.

### Fixed — COVERAGE.md re-measurement

- `tests/COVERAGE.md`'s bash `@test` total was stale three times this release: first after QA
  closed three P2 coverage gaps (AC-7/23-25) in `refine-branch-target.bats` (680→683), then a
  self-contradictory `683`/`53` after R6, then a fourth-assertion undercount from a race
  between two parallel stages. Superseded by a single direct re-measurement taken after both
  stages settled: **787 `@test` across 54 `.bats` files**, `branch-name.sh` now the
  highest-density target at 90.

### Known limits (deferred, not shipped this release)

- **R5** — ticket derivation for a bare GitHub issue number (`#N`) is deliberately deferred
  pending an explicit grammar decision: mint an `issue-390-` segment, or document that repos
  minting their own issue numbers stay ticket-less. Never fabricate an alphabetic tracker key
  from a bare issue number.
- **`cache-lint.sh:92`** (`--anchor-lint`'s `extract_stage()`) pipes whole markdown files to
  `yq` under `|| true` and is non-deterministic on artifact content — confirmed by review: it
  passed against one stage artifact and failed against another for no reason but body length.
  It cannot serve as a gate for any stage until `:92` is routed through the existing
  frontmatter-scoped helper at `:485`. Not fixed here — out of this release's scope; routed
  to DV for the next touch of the script.
- **`skills/agent-coordination/scripts/audit-dedup.sh:84`** has the identical well-formed-
  non-object `fromjson?` gap this release's audit-scan fix closed elsewhere
  (`[inputs | select(length > 0) | fromjson?] as $rows` then `.value + {__idx: .key}`,
  with no `objects` filter). Pre-existing, not introduced by R4 or R6, left unfixed here —
  same one-token fix as the four scans above.

### Known limits, continued

- **`state-patch.sh` idempotency** short-circuits when a stage is already `completed`,
  silently dropping a remediation cycle's handoff summary. A remediation round in this very
  release needed a manual `stages.DV.status` reset to re-apply. Not fixed here; needs a
  design call (always re-merge summary fields vs. document the manual-reset procedure).

## [4.0.6] - 2026-08-05

The test-execution gate advertised "DV may not run the full suite" but did not enforce it for any
runner whose mandatory flags are non-selecting. A full `xcodebuild test` with `-project`, `-scheme`
and `-destination` sailed through, because the classifier saw surviving arguments and concluded the
caller had narrowed the run.

### Fixed

- **Full-suite runs carrying only non-selecting flags now deny at DV.** The classifier strips each
  runner's mandatory-but-non-selecting flags before the "did an argument survive?" test. The strip
  is **quote-aware**, which is what the reported incident actually needed:
  `-destination "platform=iOS Simulator,name=iPhone 16 Pro"`. Verdicts invert allow→deny for
  `xcodebuild test` with project/workspace/scheme/destination/sdk/arch/result-bundle/derived-data
  flags, `dotnet test <solution>`, `gradle test -p .`, `npm`/`pnpm`/`yarn test --ci`, and
  `cargo test --release`. The gradle task token is found **order-independently** (mirroring the
  xcodebuild action scan), so the flags-before-task spelling `gradle -p . test` denies identically
  rather than slipping through on the project-dir positional — and the same scan removes a
  pre-existing false deny: `gradle -p . assembleAndroidTest` (a flags-first build-only task) no
  longer reads as a test run at banned stages. Genuine selectors (`-only-testing:`, `--filter`,
  `-k`, `-t`, `-run`, a real positional) still classify scoped and are allowed, at DV and
  everywhere else.
- **`-only-testing:` selector spelling.** The explicit selector list spelled the Apple selector with
  two leading dashes; the real flag takes one, so that limb never matched a real invocation and
  scoped Apple runs classified correctly only via the positional fallback.
- **Two pre-existing false denies removed.** `-c` is not a selector for `go test` (compile-only) or
  `rspec` (`--colour`), joining the existing `bats -c` (`--count`) build-only carve-out.
- **The DV authority-matrix note documented the bug as the contract.** It claimed the deny was
  "mechanical for the bare-runner form only" and that any trailing flag classified scoped. Rewritten
  to describe what the gate now does, with its known limits stated plainly rather than buried.
- **The finalization stage was instructed to do what it is forbidden — and unable — to do.** Its
  duty list ("Run final builds and tests"), its completion checklist ("All tests passing in final
  build") and the finalization row of the shared pipeline stage table all contradicted the
  prohibition the same agent carries. FN holds no test-execution authority, no build/test Bash
  grant and no `Skill` tool, so even a build-only rewrite would have been unreachable. It now
  **verifies QA's recorded evidence** from `testing-N.md` frontmatter, mirroring the stakeholder
  stage. The `requests_test_evidence` escape path is unchanged.

### Added

- **Narrowest-run default in the developer contract**, with its cost attached: verify with the
  narrowest run that proves the change — build-only for a compile check, a selector for behaviour.
- **Fixtures on both surfaces**, 24 → 40 self-test assertions and 58 → 80 bats cases, including a
  finalization-stage deny case kept as a doc-parity lock rather than a bug catch.

### Known limits (accepted, documented)

- Whole-tree positionals (`go test ./...`, `pytest tests/`) still classify scoped. Flipping the
  positional limb's polarity has a different fail direction and is tracked separately.
- `npm|pnpm|yarn test -- -c <spec>` denies although genuinely scoped (one shared arm). Moving `-c`
  into the valueless arm would strip the flag and leave its value surviving as a positional, so any
  full run with a valueless flag before a positional would classify scoped and be allowed —
  reopening the hole this release closes. These package managers hide the underlying runner, so the
  ambiguity is irreducible. `npm test -- <spec>` is unaffected.

## [4.0.5] - 2026-08-05

Test-suite stringency hardening. The suite went from 45 files / 501 tests to **53 / 680**, every
claim in it re-derived by mutation rather than ratified, and four production defects the old tests
had characterised as "known bugs" were fixed. One of those four is a **security disclosure for
downstream consumers** and is listed first.

### Security

- **DISCLOSURE — `scan-secrets.sh` never detected credentials in database URLs. If you have run this
  plugin's security-review stage in your own repository, your past scans may have missed
  `mysql://`, `postgres://` and `mongodb://` credentials, and a clean result did not mean they were
  absent.** This is not a newly introduced regression; it is a defect that shipped from the
  beginning.

  - **What was wrong.** The built-in fallback scanner stored each rule as
    `label|severity|regex` and recovered the pattern with `${entry##*|}` — a *greedy* strip to the
    **last** `|`. Exactly one built-in pattern, `database-url`, contains an alternation, so its
    regex was truncated mid-group to `mongodb)://[^@[:space:]]{3,}@` — an ERE with an unmatched `)`.
  - **It failed on every dialect, but by two different mechanisms — and neither was noisy.** GNU
    `grep` and `ugrep` **reject** the pattern (exit 2, parse error). BSD `/usr/bin/grep`, which is
    what this script actually resolves at runtime on macOS, **accepts** it and treats the unmatched
    `)` as a *literal* character — exit 1, no diagnostic, matching only the impossible text
    "mongodb)://…". Either way nothing real was ever matched, and because the `grep` call sent
    stderr to `/dev/null`, even the GNU parse error was swallowed. The scan reported completion with
    no finding and no diagnostic on both paths.
  - **Do not assume a loud failure would have alerted you.** On the BSD path there was never
    anything to see: no error was produced at all, not merely suppressed.
  - **Which versions are affected: all of them.** `git log --reverse` on the script shows a single
    prior commit, `01c6f6f` (2026-06-29), which introduced both the file and the broken pattern.
    **No released version ever detected these credentials, on any `grep` dialect** — on GNU because
    the pattern was rejected, on BSD because it was accepted as a literal that matches nothing.
  - **Blast radius.** `scan-secrets.sh` is a shipped artifact, so every repository that has run the
    security-review stage since 2026-06-29 has run the broken pattern. The other five built-in
    patterns (AWS keys, private keys, generic tokens, and the rest) were unaffected and continued
    to fire normally; only the `database-url` class was blind. Repos configured to use `gitleaks`
    took the gitleaks path and are not affected.
  - **What to do.** Re-scan with this version. The fixed scanner reports
    `<file>:<line>:Critical:database-url` for all three schemes.
  - **Bounding the claim for *this* repository.** A retrospective scan was run here and is
    **clean**: 234 tracked files plus a 200-revision history sweep produced no real finding. Every
    hit is either a test fixture on an RFC 2606 `.invalid` host or a deliberate literal in the
    scanner's own `--self-test`. That result bounds this repository only and says nothing about
    yours.

- `scan-secrets.sh` now validates all six patterns at startup (an O(6) compile check) and no longer
  sends `grep`'s stderr to `/dev/null`, so a malformed pattern is fatal and named instead of
  silently producing an empty scan. **This is necessary but not sufficient, and would not have
  caught the original bug** — BSD `grep` accepts "mongodb)://" as a valid ERE, so the compile check
  passes it. Semantic truncation is caught only by the new per-scheme specimen tests.
- **Known limitation, unfixed and disclosed:** `scan-secrets.sh --self-test` still exercises only 2
  of the 6 built-in patterns, and `--self-test` is exactly what runs on hosts without `bats`. The
  script's self-contained check remains weaker than its external suite; that coverage was narrowed
  by **zero** in this change.
- **Known limitation, introduced here:** removing the stderr suppression means an unreadable file
  now emits `Permission denied` six times (once per pattern) and the scan still exits 0. Not fixed,
  because the only lever that makes a file unreadable is permissions, and such a test would pass
  vacuously under root.

### Fixed

- **`build-orchestrator.sh` produced false dependency cycles.** The `blocks?` regex also matched
  "Blocked by", adding a spurious reverse edge and failing the DAG build with exit 5. Now
  `\bblocks?\b`.
- **`build-context-set.sh` silently dropped agent paths on macOS.** GNU-only `\s` escapes mangled
  leading whitespace under BSD `sed`, and `set -e` then exited the pipeline. All **7** affected
  sites now use `[[:space:]]` (the original report named only 2).
- **`detect-user-changes.sh` double-counted every change.** A redundant second `git diff` ran in
  both the patch and the numstat blocks.
- **`milestone-helpers.sh` base-branch strip was case-sensitive** while its detection was not, so a
  `BASE_BRANCH:` declaration was detected and then not stripped. `sed` gains the `I` flag.
- **`state-merge.sh` could not recover a corrupt state ledger.** It now rebuilds the skeleton and
  falls through to the unchanged `state-patch.sh` delegation, backing up the corrupt file first and
  aborting without modification if the backup cannot be written.
- **The Python phase's exit status was discarded**, so a failing Python suite could not fail
  `make test`. The suite rc now propagates.
- Documentation drift: `tests/README.md` and `tests/COVERAGE.md` disagreed with each other (36/36
  vs 34/34 targets) and both disagreed with the tree. Both are regenerated from recorded commands.
  Dead references to `skills/agent-coordination/scripts/audit-dedup.sh` and to a `cost-log.sh` that was never shipped are
  corrected.

### Added

- `RUN_TESTS_REQUIRE_SWIFT=1` — opt-in gate making a skipped Swift phase a failure. The default exit
  status is unchanged; without it a Swift-less host still exits 0 and reports `SKIPPED PHASES`.
- `tests/shell/meta/coverage-proxy.bats` — a standing gate requiring every shell script to have a
  dedicated `.bats` with ≥3 real scenarios. Exemption list is empty.
- `skills/worktask/scripts/attachments-preseed.sh` — renders both Conductor attachments from their
  canonical templates, replacing six manual writer steps.

### Changed

- **`run-tests.sh`'s clean-clone guarantee now names `python3 >= 3.10`.** The guarantee was always
  conditional on it and never said so: `validate-export.sh` embeds a validator using PEP 604
  `X | None` annotations evaluated at runtime, which raise `TypeError` on 3.9. macOS ships 3.9.6 as
  `/usr/bin/python3`, so on a stock Mac the suite returns 1 until a newer `python3` is on `PATH`.
  This is a pre-existing defect in an untouched file — documented here, not fixed.

### Known issues

- `make coverage` is unreachable on macOS: the kcov branch runs away (352 MB of output in 90 s
  without completing a single target) and `benchmark/ttt-template` sits at 84.5 % against an 85 %
  gate behind it. The binding green criterion is `./run-tests.sh` rc 0.
- `state-merge.sh`'s repair writes through a `$$`-suffixed temp path that still follows a dangling
  symlink — same weakness class as the one fixed in its backup path, different code path.

## [4.0.4] - 2026-08-05

Gate-revision semantics. The spec carried one concept ("a PL invocation") where the pipeline has
two — starting a **new run** (allocate N+1, reset facts, create tasks) versus **revising the run
in flight** (reuse N, edit in place, preserve facts, update tasks). Only the first was specified,
so following the plan-gate rejection line verbatim silently forked the run. Both gates now specify
their revision path. Plus four rule fixes traced to observed failures in the 4.0.3 worktask.

### Fixed

- **Plan-gate rejection no longer forks the run (data loss).** Re-dispatching PM after a rejection
  allocated `planning-1.md` while the run was still on `planning-0.md`, which (1) wiped `facts.*`
  via the Step-4 state.json reset — erasing the `facts.decisions[]` the user had just supplied at
  that gate, (2) froze the plan under revision as "historical" and split AC baselines across two
  files, (3) `TaskCreate`d a second stage chain at `run_index: 1`, stranding the original tasks
  `pending` forever, and (4) bumped the `<worktask_id>:<run_index>:gh_issue` dedupe anchor so the
  revision read as a later run. `commands/worktask.md` now routes the rejection to
  § Plan-revision re-dispatch: `run_index`/`plan_file` frozen for the life of a run, PM
  re-dispatched with `plan_revision: true`, a four-row BINDING invariant table (edit in place /
  patch `facts.*` additively / `TaskUpdate` not `TaskCreate` / no issue re-publish),
  `metadata.revision_count` bookkeeping with one `plan_revision_dispatched` audit row, and a
  re-entry into the plan gate on return.
- **`agents/prompt-engineer.md` could not run its own embedded-command contract.** No `Skill` tool
  in the frontmatter grant, so a DV-stage dispatch carrying a mandatory
  `Skill("skill-creator:skill-creator", …)` contract had to escalate and apply the skill body
  manually as a disclosed substitute. `Skill` added.
- **AC verification commands could ship syntactically broken.** The
  `(unverified — dry-run required after theme lands)` mark excused everything, including
  invalidity — a shipped plan carried `grep -viv -e … -e …` (triple negation, a no-op reporting
  everything "clean") and three downstream stages independently re-derived the correct form. The
  mark now covers only the RESULT's representativeness, never the command's validity.

### Added

- **FN-gate rejection resume path** (`skills/worktask/SKILL.md § FN gate rejection`) — the same
  conflation at the second gate, which previously ended at "STOP (do NOT delegate FN)" with no
  defined resume. Now symmetric with the plan gate: feedback routed to the owning stage (DV fix
  round / DC re-stamp / plan amendment), `run_index` frozen, completed stages never re-run
  wholesale, `revision_count` bookkeeping, and the FN gate re-presented on completion.
- **DV-stage yield discipline for `agents/prompt-engineer.md`** — across one worktask it stopped
  mid-theme at least four times, each needing an orchestrator nudge to finish its own stage
  contract. Now points at `agents/workflow-engineer.md § Batch-Completion Discipline (DV
  execution)`, the rule that already existed but was unreachable from this agent.
- **`file:line` citations are starting sets too** (`agents/product-manager.md`) — the staleness
  rule that already covered enumerated FILE lists now covers LINE numbers cited in theme prose:
  cite as an approximate locator, require DV to re-locate the anchor by quoted text before
  editing.

## [4.0.3] - 2026-08-05

Full legacy-logic removal. Round 1 removed every rules-surface deprecation whose sunset window had
elapsed from `agents/`, `commands/`, `skills/` with zero semantics change. Round 2 (user-approved,
aggressive scope) then deleted the remaining legacy *logic* across hooks, scripts, tests, and the
benchmark harness — accepting loss of pre-4.0 `.context/` read-support. Load-bearing current
contracts (the F1–F4 fallback family, the `plan_file` path-vs-basename boundary, hook-vs-agent audit
authority, CC `--json` camelCase coalescing, visual-QA degradation invariants) are kept but reworded
away from the misleading word "legacy" — they are current behavior, not compatibility.

### BREAKING

- **Legacy `--auto-plan`/`--auto-finalization` flags removed.** Only `--auto=[plan, decision,
  finalization]` remains. These aliases are no longer recognised or documented; no rule in
  `worktask.md` governs an unrecognised top-level flag, so the effect of passing either legacy
  flag is undefined by the docs going forward.
- **`requires_ui_tests` back-compat mapping removed.** A resumed pre-4.0 `.context/planning-N.md`
  that still presents `requires_ui_tests: true` with no `test_mode` now falls to the `scoped`
  default and `ui_visual_check: false` — a legacy plan that asked for full regression plus Design
  Comparison silently gets neither, with no deprecation note surfaced.
- **Dual dedupe-key mechanism deleted.** `metadata.dedupe_key_extended` is no longer written by any
  hook and `skills/agent-coordination/scripts/audit-dedup.sh` (the base/extended mode selector) is removed. The 3-segment
  `dedupe_key` is the only documented shape; readers dedupe on it directly. `parent_agent_id` is
  still captured, for observability only.
- **Pre-run-index artifact names no longer resolve.** The artifact resolver's bare-basename rung
  (`.context/<base>.md`) is gone from `state-patch.sh` and from every documented resolver chain —
  only `<base>-<run_index>.md` and the newest-glob fallback remain.
- **Pre-#375 issue-title probe removed.** `publish-pl-issue.sh` no longer builds `TITLE_LEGACY` or
  re-probes the old slug title, so an issue published under the pre-#375 scheme is no longer found
  by the anchor-loss recovery search and a duplicate may be opened.
- **`state.json .git.base_branch` fallback removed** from the integration-branch chain; the
  surviving order is `$FN_BASE_REF` → `state.json .metadata.base_ref` → `workspace.json
  .git.base_branch` → `origin/HEAD` → unresolved.
- **Single-file visual-evidence marker shape dropped.** `attach-visual-evidence.sh` reads only the
  per-issue marker directory; `GH_MARKER_FILE` is no longer honoured.
- **Redaction supersets removed — leak risk accepted.** `publish-pl-issue.sh` no longer strips the
  `igrsoft:` plugin prefix or the pre-3.42.0 `analyzing-N.md` artifact name. A worktask resumed from
  a pre-4.0 `.context/` can therefore publish those internal identifiers into a GitHub issue body.
- **Strict benchmark token decoding.** A `tokens` block present in a benchmark record MUST carry all
  five keys (`in`, `out`, `total`, `cache_read`, `cache_creation`); a partial block now raises
  instead of decoding with silent `None`s. `benchmark/results/history.json` was migrated in place
  (key-presence-only, explicit `null`s).
- **`state.mcp_session`, `--severity` legacy aliases, and the bare-name agent shim dropped.**
  `metadata.agent` and `subagent_type` MUST be fully-qualified `plugin:agent`; `--severity` accepts
  only `P0`/`P1`/`P2`; `mcp_session` is gone from the state-ledger schema.

### Removed

- Legacy `--auto-plan`/`--auto-finalization` aliases and the `#### Legacy aliases (deprecated)`
  table (5 files + `README.md`).
- Sunset `requires_ui_tests` compat-mapping table (2 files, 6 sites).
- `igrsoft` rename residuals outside the vendor-identity allow-list (7 files).
- Stale pre-4.0 (`v3.x`) version gates: 21 of 42 matches removed in round 1; round 2 removed the
  rest, including every `v3.x+` header peg across the 8 remaining hook/skill scripts.
- Dead code: `_inline_merge` (the ~105-line inline state merger in `.claude/hooks/state-merge.sh`)
  and its call site — `state-patch.sh` is the single merge implementation.
- Files: skills/agent-coordination/scripts/audit-dedup.sh, skills/shared/legacy-fallback-f1.md (folded into
  handoff-protocol.md#f1-fallback), tests/shell/hooks/audit-dedup.bats,
  benchmark/harness/tests/test_history_backcompat.py, and 3 audit fixtures.
- `norm_dk` cross-shape key normalisation from `skills/agent-coordination/scripts/audit-dedup.sh`
  (it normalised a 4-segment key shape no writer ever emitted).
- The `fallback_legacy` value from the `artifact_path_resolved` audit enum (now
  `{ok, fallback_glob, miss}`) — unreachable once the bare-basename rung was removed.

### Changed

- Compaction pass across `agents/`, `commands/`, `skills/`: removed change-narration, deduped
  repeated canon to a single source + pointers, collapsed redundant structure. Total tracked
  markdown: 34,119 → 34,035 lines (`agents/` 4,722 → 4,694; `commands/` 9,329 → 9,292; `skills/`
  20,068 → 20,049).
- Reword sweep (rename-only, no behavior change): F1 is now "`context_files` mode" and is documented
  as required behavior rather than backward compatibility; the `handoff-harness.sh` A/B arm is
  "baseline" rather than "legacy"; `milestone-helpers` "Legacy Command" is "Non-worktree Command";
  visual-QA degradation invariants are canonical in `visual-qa.md` with `testing-strategy.md`
  pointing at them.
- `build-context-set.sh` no longer exits non-zero when a probed candidate path does not exist
  (each qualified agent ref probes agent/command/skill paths; a miss is normal).

## [4.0.2] - 2026-08-03

A live worktask in a Conductor workspace shipped PR #382 from `ov166-skin-score-all-layers`
— a branch name that fails this plugin's own `branch_is_conventional` predicate, on a repo
that merges rather than squashes, so the name is permanent history. The design was already
right (FN pushes `HEAD:refs/heads/<facts.branch>`, decoupling the PR head from the local
branch); it was fed a bad value. Scripts, tests, and docs only — no stage, agent, or gate
semantics change.

### Fixed — the derived branch target is no longer discarded on the no-op arms

`branch-name.sh` derived the conventional target inside the rename arm alone. Every other
arm — upstream tracked, target exists, jq unavailable — passed the *current* branch to
`emit_branch`, which prints `branch=` empty when the name fails the predicate. The right
answer was computed and thrown away, `facts.branch` landed empty, and FN's documented
fallback pushed the non-conventional local name as the PR head.

- **A second stdout line, `target_branch=<name>`**, emitted by every arm that can derive
  one, independent of whether the local rename happened. Derivation moved above the no-op
  arms; `derive_target` split out as a pure function. `branch=` keeps its exact semantics
  and stays the **final** stdout line — four docs and every consumer specify that parse, so
  the new line goes before it, not after. Both lines pass the same `branch_is_conventional`
  gate before emission, preserving the shell-injection hardening `emit_branch` exists for.
- **Arms that must not propose a target still emit it empty**: already-conventional
  (`branch=` is the answer), the integration branch (never a PR head under any name), and
  batch/incident routing (which owns its own naming).
- **Step 3c now stamps the target it already computed.** The post-check wrote `derived_target`
  into an audit row and discarded it; the orchestrator now stamps `facts.branch` from
  `target_branch=` whenever `branch=` is empty or fails `--check`, and the post-check reuses
  the captured value instead of re-invoking the script (which wrote a duplicate audit row).
  A non-empty `derived_target` in that warning row is now a bug report, not a shrug.

### Added — host-workspace (linked-worktree) arm

Nothing in the guard ladder could see a host workspace: Conductor leaves no `workspace.json`
in `$PWD`, so all five `fn_batch_scope` signals miss it. New arm, detected as
`git rev-parse --git-dir != --git-common-dir`: derive and emit the target, **skip** the local
`git branch -m`, audit `branch_renamed / skipped` with `reason: host_workspace_worktree`. The
host's branch↔workspace mapping stays intact *and* the PR gets a conventional head — what
`workspace-modes.md § Host mapping caveat` previously described as a manual equivalent is now
the automatic behaviour. `facts.branch` deliberately differs from the local branch name there;
that divergence is documented in `handoff-protocol.md` and `agents/project-manager.md` as the
designed outcome, so no reader "repairs" it back to a `git rev-parse`.

### Fixed — the host-session authorization was invisible at the point of decision

`workspace-modes.md § Host session authorization` ("invoking `/worktask` satisfies a host's
no-rename session rule") was referenced from exactly one file: the **FN** agent, which runs
long after the rename and never renames anything. The orchestrator at Step 3c — the only
actor that decides — had no pointer, and Step 3c's own "MUST NOT block, no STOP, no retry,
no rename" text reads as *tolerate the divergence*. An orchestrator holding Conductor's
session rule and Step 3c had everything it needed to revert a correct rename. It did. Step 3c
now carries the authorization inline as a BINDING note, in `commands/worktask.md` and
`skills/worktask/SKILL.md`.

### Tests

Twelve new cases in `tests/shell/worktask/branch-name.sh.bats` (57 total, all green): the
host-workspace arm over a real `git worktree` (local name kept, target derived, HEAD
untouched, audit reason); the acceptance trio executed through the documented Step 3c
stamping rule rather than paraphrased; both cwd cases for the detection itself — a
subdirectory of a plain repo must still rename (git answers `--git-dir` absolutely and
`--git-common-dir` relatively from there, so the comparison resolves both to physical
paths), a subdirectory inside a worktree must still detect; `target_branch=` on the
upstream-tracked, target-exists, and jq-unavailable arms; empty on the arms that must not
propose one; batch routing still winning over the host arm; a shell-hostile current branch
reaching neither emitted line; and the `BRANCH_NAME_PRINT` dry run unchanged.

## [4.0.1] - 2026-08-03

Two publication-surface bugs, both found the same way: a live worktask shipped output nobody
would have written by hand — a fix/-prefixed branch after `fix` had been removed from the
vocabulary, and a GitHub issue titled with a kebab slug. Neither was a failure; both paths
degraded silently and stayed within their non-blocking contracts while doing it. Scripts,
tests, and docs only — no stage, agent, or gate semantics change.

### Fixed — worktask branch naming (four defects on one path)

A live worktask shipped fix/catalog-image-blinking — a branch whose type prefix had been
deliberately removed from `BRANCH_TYPES`. The root cause was not the vocabulary but the step
that enforces it.

- **Step 3c was skippable.** `commands/worktask.md` told the orchestrator to run
  `branch-name.sh` but nothing verified that it did, so on a workspace already sitting on a
  plausible-looking branch an orchestrator could reasonably conclude "already named, skip" and
  stamp the pre-existing name into `facts.branch`. Step 3c is now **unconditional**, with the
  reason stated (the "already conventional" arm is a no-op, so always running it costs one
  process and is the only correct way to decide), a BINDING line that conventionality is
  decided by `branch_is_conventional()` and never by eye, an explicit pre-existing-branch
  clause, and a non-blocking post-check that emits one `branch_convention_check` warning row
  naming both the actual and the derived target when the stamped value fails the predicate.
- **The grammar gained an optional ticket segment** — `<type>/[<ticket>-]<slug>`. Repos using
  this plugin already ship bugfix/ov-156-…, which the spec (documented as the single source
  of truth) previously forced to drop its issue key. The new `derive_ticket` reads the first
  `\b[A-Z]{2,}-\d+\b` token from the goal text only, lowercased; no key found means unchanged
  behaviour. `branch_is_conventional` accepts both shapes, so no existing branch becomes
  non-conventional and gets churned. Branch ticket and PR closing keyword are complementary,
  not alternatives.
- **`derive_slug` no longer truncates mid-word.** `cut -c1-48` produced
  `…-blinking-before-r`; truncation now drops the trailing partial segment and always keeps at
  least one whole word. The ticket prefix is budgeted inside the 48-char cap, so a long issue
  key cannot starve the slug, and the key is stripped from the slug body so it appears once.
- **`derive_type` no longer misclassifies bug reports as features.** The `*"fix "*` arm
  required a trailing space, so "…investigate and fix" and "…and fix." fell through to
  `feature`. `fix` is now matched as a word (without swallowing `prefix`/`fixture`), and the
  bugfix arm gained the defect vocabulary `blink`, `flicker`, `glitch`, `broken`, `regression`,
  `incorrect`, `wrong`, `fails`, `failing`. The hotfix-before-bugfix ordering is unchanged.

Guard ladder unchanged — every arm is still a no-op or a refusal, never a failure. Commit-type
table untouched: `feature` stays branch-only. +26 bats cases across `branch-lib.bats` and
`branch-name.sh.bats`.

### Fixed — `publish-pl-issue.sh` published a garbage title and an empty Summary

Issue #375 was published as `OV-164 ov-164-catalog-image-blinking` with an empty `## Summary`.
`facts.goal` was the ONLY source for both, and it is OPTIONAL in the handoff protocol — written
only when the PM agent patches state.json, so orchestrator-inline seeding, a hand-authored
`.context/`, or a regenerated state left it unset and degraded both outputs at once, silently.

- **Title and Summary now resolve through independent chains**, first non-empty wins. Title:
  `facts.goal` → plan frontmatter `title:` → plan first H1 → first sentence of
  `## summary`/`## problem` → `worktask_id`. Summary: `facts.goal` → `## summary` →
  `## problem`. The worktask slug is deliberately not a Summary rank — an empty section is
  honest, a slug posing as prose is not.
- **New readers**, POSIX sh + awk in house style: `extract_frontmatter_field` (leading `---`
  fence only, so a thematic break mid-body is never mistaken for frontmatter),
  `extract_first_h1`, `first_sentence` (skips bullets; a terminator must be followed by
  whitespace, so `3.5s` is not a sentence end). The `head -1 | cut -c1-100 | sanitise_body`
  pipeline still applies to every rank.
- **Reaching the `worktask_id` rank is audited**, not silent: one advisory row with
  `reason: "title_fallback_worktask_id"` and `metadata.title_source`, on the
  `<dedupe_key>:title_source` suffix so it never masks the canonical outcome. Still non-blocking.
- **External-ticket extraction gained ranks** (winning title source, then plan frontmatter
  `issue:`) and its no-double-prefix guard is now case-insensitive and accepts `-` as a
  separator — the exact-case check is why `ov-164-…` was treated as unprefixed and doubled.
- **Recovery-search compatibility**: changing title generation orphans issues published under
  the old title, so `resolve_context_issue_search()` probes the current title first and the
  legacy one only on a miss. Documented as removable once that corpus is closed.

Secondary (separate commit): `commands/worktask.md` Step 3a now seeds `facts.goal` from the
task description, `skills/worktask/references/initialization-patterns.md` carries it in the
seed snippet, and `agents/product-manager.md` states that a non-empty `facts.goal` is part of
the PL state-patch contract. Nothing on the patch path actually wrote the field before. The
script fix stands on its own regardless — a missing optional field is not a reason to publish
a broken title. +5 `--self-test` blocks (13a–13e) with three new plan fixtures.

## [4.0.0] - 2026-07-31

The plugin was declared as `"name": "igrsoft"` while the repository had already become
IGRSoft/company-workflow — the plugin id was the last artifact carrying the vendor name as its
identity. This release renames the **plugin**, and only the plugin.

The word appeared in three distinct roles, and separating them is the whole substance of the
change. **Plugin identity** moves: every `igrsoft:<agent|skill>` invocation id, the
`marketplace.json` plugin entry, the `plugin.json` `Stop` hook matcher, the `Task(igrsoft:…)`
frontmatter grants, the bare-name resolution shim, and the Claude Code install cache path.
**Vendor identity** does not move: the author block (`IGRSoft`, `support@igrsoft.com`), the
github.com/IGRSoft/… URLs, the `com.igrsoft.*` bundle IDs in `/appstore-iap`, and the
marketplace name — which stays `igrsoft`, so the cache path becomes
`~/.claude/plugins/cache/igrsoft/company-workflow/<version>/` with only the second segment
changed, and the install key becomes `company-workflow@igrsoft`.

Most of the ~330 references were prose or ids, but four sites matched the literal string at
runtime and would have failed silently rather than loudly:

- `hooks/dv-screenshot-gate.sh` guards on exact equality (`!= "company-workflow:developer"`).
  Left stale, the DV screenshot gate would have no-opped on every run with no error.
- `skills/self-improvement/scripts/build-context-set.sh` maps agent refs to file paths via an
  awk field compare (`$1 == "company-workflow"`).
- `.claude-plugin/plugin.json`'s `Stop` matcher must track the plugin name or the PL/FN
  approval-gate push notification stops firing.
- `skills/worktask/scripts/publish-pl-issue.sh` carries four identical copies of the
  plugin-prefix leak regex that strips internal agent ids out of published GitHub issues; they
  are kept byte-for-byte in lockstep with the list in `skills/shared/compatible-plugins.md`.

### Breaking

- **`igrsoft:*` agent and skill ids no longer resolve.** There is no back-compat alias. The six
  sibling plugins (`apple-developer`, `system-developer`, `android-developer`,
  `frontend-developer`, `backend-developer`, `ai-engineer`) are updated in the same pass; merge
  this release first, since their docs reference `company-workflow:` ids.
- **`IGRSOFT_*` environment variables renamed to `COMPANY_WORKFLOW_*` with no fallback read** —
  `TEST_GATE`, `AR_REF_STRICT`, `PR_BODY_STRICT`, and `COMMENT_DENSITY_{MAX,WARN,MIN_LINES}`.
  Update shell profiles and CI jobs.
- **Stale installs must be reinstalled.** `~/.claude/plugins/cache/` and the
  `known_marketplaces.json` / `installed_plugins.json` indexes still key on the old plugin name
  until then.
- **`audit.jsonl` is not comparable across the boundary** — the `subject` field changes prefix,
  so pre- and post-rename audit trails cannot be diffed directly.

---

**Earlier releases are archived per major line: [CHANGELOG-3.x.md](CHANGELOG-3.x.md) (`3.0.0`–`3.43.0`), [CHANGELOG-2.x.md](CHANGELOG-2.x.md) (`2.0.0`), [CHANGELOG-1.x.md](CHANGELOG-1.x.md) (`1.0.0`).**
