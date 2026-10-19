---
name: testing-strategy
version: 0.6.0
---

# Testing Strategy

Canonical testing reference for every platform a worktask routes to. Pyramid, AAA pattern, DV/QA
boundary, and Test Selection Gate are platform-neutral; framework and syntax specifics are gated per
platform in § Framework by platform — an Apple rule never applies off Apple, and vice versa.
Platform→plugin routing: `skills/shared/platform-detection.md`.

## Testing Pyramid

| Layer | Coverage | Scope | When |
|-------|----------|-------|------|
| Unit (70%) | Fast, isolated, deterministic | Single logic unit, mocked dependencies | Every commit |
| Integration (20%) | Component interactions | DB/API integration, service-to-service | PR and merge |
| E2E (10%) | Critical user journeys | Real browser/device | Before release |

## Framework by platform

Use the project's established framework — detect it (test layout, manifest dependencies, CI
config) before writing a test. Never add a second framework to a repo that has one; where a repo has
none, pick from the matrix and record the choice in `<plan_file> § test-strategy`.

### Framework matrix — app platforms

| Platform | Unit | Integration | UI / E2E |
|----------|------|-------------|----------|
| `apple` | Swift Testing (`@Suite`/`@Test`/`#expect`) | Swift Testing + in-memory doubles | XCTest / XCUITest |
| `android` | JUnit 5 + MockK, Turbine for flows | JUnit + Robolectric, in-memory Room | Espresso / Compose UI test, Roborazzi screenshots |
| `web` | Vitest or Jest | Testing Library + MSW | Playwright (or Cypress) |

### Framework matrix — systems, backend, ai

| Platform | Unit | Integration | UI / E2E |
|----------|------|-------------|----------|
| `systems` | GoogleTest / Catch2 (C++), Unity / CMocka (C), pytest (Python), bats (Bash) | `ctest` targets driving real I/O | No UI layer — CLI transcripts are the evidence |
| `backend` | Stack-native: Go `testing`+testify, JUnit 5, Vitest/Jest, pytest | Testcontainers for DB/broker/cache | Contract tests (Pact/OpenAPI), k6 for load |
| `ai` | pytest for pipeline and tooling code | pytest + recorded fixtures / VCR | Eval harness (promptfoo, DeepEval, in-repo runner) with scored thresholds |

### Test generation and execution

Per-framework depth lives in the platform plugin (`skills/shared/compatible-plugins.md`), which
exposes `/<plugin>:gen-tests` (write tests in the project's framework) and `/<plugin>:build-test`
(build + run). Prefer delegating execution to `/<plugin>:build-test`: it knows the repo's build
system, and its output is the Build Evidence QA reads.

## AAA Pattern

Three phases in every framework: **Arrange** the inputs and doubles, **Act** once on the unit under
test, **Assert** on the observable result. One logical act per test — a test that acts twice is two
tests. Blank lines, or `// Arrange` / `// Act` / `// Assert` comments in longer tests, keep the
phases legible. Canonical shape (Swift Testing; per-platform variants come from
`/<plugin>:gen-tests`):

```swift
@Suite("Auth Tests")                       // add @MainActor for MainActor-isolated types
struct AuthTests {
    @Test("login with valid credentials succeeds")
    func loginValid() {
        let credentials = Credentials.valid          // Arrange
        let result = authService.login(credentials)  // Act
        #expect(result == .success)                  // Assert
    }
}
```

On Apple, unit tests use Swift Testing; XCTest/XCUITest is reserved for UI tests and is the one place
`test`-prefixed method names are mandatory.

## Test naming conventions

The runner's collection rule wins — it is not a style choice. Where the runner is agnostic,
prefer a sentence naming behavior and expected outcome, not the method called.

### Naming by framework

| Framework | Convention | Example |
|-----------|------------|---------|
| Swift Testing | Descriptive func name, **no** `test_` prefix; prose title in `@Test("…")` | `loginValidCredentialsReturnsSession()` |
| XCTest / XCUITest | `test` prefix **required** by the runner | `testLoginFlow()` |
| JUnit 5 (Kotlin/Java) | Backtick sentence (Kotlin) or camelCase + `@DisplayName` | `` `login with valid credentials returns session`() `` |
| Vitest / Jest | `describe` + `it` sentences | `it('returns a session for valid credentials')` |
| pytest | `test_` prefix **required** for collection | `test_login_valid_credentials_returns_session` |
| Go | Exported `Test<Thing>` **required** | `TestLoginValidCredentials` |
| Rust | snake_case `#[test] fn` inside `mod tests` | `fn login_valid_credentials()` |
| bats | `@test "<sentence>"` | `@test "login with valid credentials"` |

## Mutation Testing

A mutation test proves a guard is non-vacuous by breaking what it guards and requiring the guard to
fail; its result carries no information unless the mutation landed. Assert the mutation was applied
before trusting the pass/fail it produced: back the target up, mutate, byte-compare (`diff -q` must
report the files differ), run the test, restore. A silently no-op mutation (a `sed` pattern that
doesn't match, a shifted line number) yields a pass indistinguishable from a weak guard.

## Portable verification greps

A canon-sweep or acceptance-criteria count is evidence only if the command means the same thing on
every host: `grep` may be GNU grep, BSD grep or `ugrep`, which differ in ways that change a count
silently instead of erroring.

- Put `--include=`/`--exclude-dir=` before the pattern, and use `-e` for any pattern containing
  `--` — past a `--` terminator ugrep reads the filter as a filename.
- Never anchor an exclusion regex on a `./` prefix; ugrep omits it, so `^\./.*` matches nothing and the
  exclusion silently does not apply.
- Report the per-file decomposition, not only the total — a filter that stopped applying looks
  identical to one that found nothing to exclude.

## Skipped tests

A skipped test is not a pass: it proves nothing about the change, yet most runners print it beside a
green summary. So every DV or QA run reports its skip count next to its pass count.

A worktree is the common cause. It lacks gitignored material the main checkout has: fixtures,
local databases, credentials. A test that skips because that material is absent reads as green while
it checked nothing. Record each such skip with its cause in the stage artifact, and treat it as
missing coverage, not a result.

The remedy is `.worktreeinclude`, which copies named gitignored paths into each new worktree
(`skills/megatask/SKILL.md § Including gitignored paths`). Never copy credentials this way unless
the test needs them and the worktree stays local.

## Strict-count runners

A strict runner has a summary line that always carries the executed count. For these runners
`handoff-harness.sh` fails a `tests_executed` entry whose `summary_line` does not carry its `count`
as a whole-number token. The canonical list:

| Runner name | Match | The line that carries the count |
|---|---|---|
| `bats` | exact | the TAP plan, `1..N` |
| `pytest` | exact | `N passed in …`; for a failing run, the outcome counts (below) |
| `jest`, `vitest` | exact | the `Tests` tally line (jest: `… N total`; vitest: `… (N)`) |
| `swift-testing` | exact | `Test run with N tests …` |
| `gradle*`, `junit*` | prefix | the `skills/worktask/scripts/junit-tally.sh <results-dir>` line |

The match ignores case. Every other runner only warns and writes one `count_corroboration` audit
row: a `bash-*` live script, `xcodebuild`, `swift`, and unknown names. `xcodebuild` stays at warn
because a mixed XCTest + Swift Testing scheme prints one tally per framework and no total.

### xcodebuild: the total comes from the result bundle

For a total, read the result bundle: capture `xcrun xcresulttool get test-results summary --path
<bundle>.xcresult` to `.context/logs/` as a `.json` file and name it in the artifact. An
`xcodebuild` entry whose line carries `count` is then corroborated when the capture's
`totalTestCount` equals `count`, even though no runner printed that line
(`skills/shared/stage-contracts.md § An xcresult summary corroborates an xcodebuild line`).

### A failing pytest run: the outcome sum

pytest prints a total only when every case passed. A failing run prints a list of outcome counts,
for example `1 failed, 57 passed in 3.2s`. So a pytest line with no `count` token still passes
when `count` lies between two sums:

- the base: the `passed`, `failed`, `xpassed` and `xfailed` counts;
- the base plus the `error`/`errors` count.

An error is either a case of its own (its setup failed) or a second report on a case already
counted (`1 passed, 1 error` when the teardown fails), so both ends are honest. A count below the
base or above the base plus errors fails. `skipped`, `deselected` and `warnings` never add: they
are not executed cases. When the base is 0 (`3 errors in 0.2s`), the range is off. Such errors
may be collection errors, which are no cases, so only a count the line carries as a token is
proven. This outcome-sum rule applies to pytest only.

### What a whole-number token is

A digit run that is not part of a decimal: the `1` in `0.1s` and the digits of `8.3.1` are not
tokens. A TAP plan `1..N` is one token worth N. Its lower bound is not a count, so `count: 1`
does not match a `1..840` plan.

## DV vs QA Boundary

DV produces the build artifact + Selected Tests list; QA executes the Selected Tests plus visual
checks if gated on, so the DV loop stays fast while QA owns regression coverage.

| DV Stage (Developer) | QA Stage (QA Engineer) |
|----------------------|------------------------|
| Unit tests per `<plan_file>` specs | Additional edge case tests |
| Mock implementations for dependencies | Coverage gap analysis |
| Happy path + known error cases | Boundary and stress tests |
| Test data builders/fixtures | Test quality review |
| Build verification + parse markers + emit Selected Tests | Run only the Selected Tests list (plus full suite if `test_mode=full`) |

## Test-Execution Authority

Canonical, single-sourced statement of who may execute tests — orthogonal to `test_mode`
(§ Test Selection Gate), which governs how much runs. Every agent file and skill points here;
none restates the matrix or the runner list below. Authority is a property of the stage, never of
the agent file: a support agent (`designer`, `ethics-reviewer`, `prompt-engineer`,
`workflow-engineer`) inherits the authority of whichever stage it is dispatched into —
`workflow-engineer` acting as DV0 for plugin-infrastructure scope holds DV's authority, not a fixed
authority of its own.

### Definitions

**Test execution** — invoking a runner that evaluates test cases: `bats`, `swift test`, `pytest`,
`python3 -m unittest`, `ctest`, `go test`, `cargo test`, `jest`, `vitest`, `playwright`, `rspec`,
`dotnet test`, `gradle test` / `./gradlew test`, `npm`/`pnpm`/`yarn test`, `xcodebuild test`,
`node --test`, `python -m pytest`, `mcp__*__test_*`; plus `./run-tests.sh`, `make test`,
`make coverage`, `make test-ios` in this
repo; plus `/<plugin>:build-test` invoked *without* `--no-test`; plus delegating any of the above
to another agent.

**Build-only verification** — compile, link, type-check, lint, static analysis, and test *collection
without execution* (`bats --count`, `pytest --collect-only`, `--dry-run`). Allowed at every one of
the 13 stages, always — `/<plugin>:build-test --no-test` is the sanctioned delegated form. Only
*reachable* where the stage holds a build path ("Reachable how" below); nominal elsewhere.

### Optional stages and authority

Rows describe a stage's authority *when that stage runs*. AR and TL are optional
(`skills/estimation-methodology/SKILL.md § Stage Inclusion Criteria`); an excluded stage grants its
authority to no one — an excluded AR does not transfer test-architecture authority to DV beyond the
design ownership rule in `agents/developer.md § Architecture Ownership`.

### Authority matrix — DV, QA, AR, DR

| Stage | Build-only | Reachable how | Scoped exec | Full exec | Note |
|---|---|---|---|---|---|
| DV | allowed | own Bash | required | forbidden | full-suite deny is mechanical (`hooks/test-execution-gate.sh`), covering the bare runner and invocations whose flags are all non-selecting; only a genuine selector classifies scoped — § DV full-suite deny |
| QA | allowed | own Bash | allowed | allowed — sole holder | |
| AR | allowed | delegation only (no Bash grant) | forbidden | forbidden | |
| DR | allowed | `/<plugin>:build-test --no-test` | forbidden | forbidden | compile-check carve-out preserved verbatim (`agents/technical-lead.md`) |

#### DV full-suite deny — coverage and known limits

Fail-open by construction: a future unstripped flag degrades to an allow, never to a false deny.

- **Denied** — a bare runner, or an invocation whose arguments are *all* non-selecting. The classifier
  strips each runner's mandatory-but-non-selecting flags first, so configuration buys no escape:
  `xcodebuild test` with `-project`/`-workspace`/`-scheme`/`-destination`/`-sdk`/`-arch`/result-bundle
  and derived-data paths, including quoted multi-word values; `dotnet test <solution|project>`;
  `gradle test -p .` (task found order-independently); `npm`/`pnpm`/`yarn test` with
  `--ci`/`--watch`/`--silent`/bare `--`; `cargo test --release`.
- **Scoped** — a genuine selector: `-only-testing:`, `--filter`, `-k`, `-t`, `-run`, or a real
  positional (`cargo test --release foo`); see `skills/shared/test-selection-syntax.md`. `-c` is a
  build-only carve-out for `bats` (`--count`), `go test` (compile-only) and `rspec` (`--colour`).

##### The Node runner

`node` is a runner only with `--test`. A bare `node <script>` is script execution and classifies
as not a test run, the same discrimination `gradle`/`gradlew` get from their task name — without it
every `node` invocation in a Node project would deny at a banned stage. `--test-reporter` and
`--test-concurrency` are configuration, not selection; `--test-name-pattern` and `--test-only` are
genuine selectors and classify scoped.

##### Known limits

- **Whole-tree positionals** — `go test ./...` and `pytest tests/` are allowed at DV though they are
  full runs. Deliberate policy limit: flipping the positional limb's polarity changes the fail
  direction.
- **Package-manager `-c` residual** — `npm test -- -c <spec>` is genuinely scoped and denies anyway
  (`pnpm`/`yarn` share the arm), because treating `-c` as valueless would let full runs classify
  scoped. Package managers hide the runner, so the ambiguity is irreducible; `npm test -- <spec>` is
  unaffected, and the human-only `CORPFLOW_TEST_GATE=off` covers the rest.

### Authority matrix — all other stages

| Stage | Build-only | Reachable how | Scoped exec | Full exec | Note |
|---|---|---|---|---|---|
| SR | allowed | narrowed Bash, read-only introspection (git/jq/cat/head/tail) | forbidden | forbidden | no `Skill` tool → `build-test --no-test` nominal, not reachable; scan capability is delegation-dependent (§ Mechanical enforcement) |
| RE | allowed | same narrowed Bash as SR | forbidden | forbidden | same `Skill`-tool gap as SR |
| IR | allowed | broad Bash (documented carve-out) | forbidden | forbidden | incident reproduction is not test execution (§ Escalation path) |
| PL, TL, DC, FN, ST | allowed | delegation only (no test-capable Bash) | forbidden | forbidden | nominal allowance |
| Support (`designer`, `ethics-reviewer`, `prompt-engineer`, `workflow-engineer`) | allowed | per agent | inherits dispatched stage | inherits dispatched stage | authority follows the stage acted for, not the agent name |

### Auto-promotion note

DV's no-handler auto-promotion never widens to `full` (`test-selection-syntax.md § Auto-promotion
when no handler`): the cap is `module-scope`, an execution-only value recorded in
the DV artifact's `§ Decisions`, never a `test_mode` value — that vocabulary stays exactly
`build-only | scoped | full`, unchanged and PL0-owned.

### Dispatch discipline — the brief carries the invocation

A stage brief's test invocation comes from `<plan_file>` frontmatter (`test_mode`,
`always_required_tests`) — never from a runner command pasted out of the repo's `CLAUDE.md` / README
"core commands" section: those are full-suite-shaped by design and carry no selector, so a DV brief
built from one makes DV pre-empt the regression gate QA exists to hold.

Every DV/QA brief therefore states the resolved mode and the exact selector it implies
(`-only-testing:…`, `--tests …`, a pytest nodeid — grammar in
`skills/shared/test-selection-syntax.md`). Where `always_required_tests` is spelled in a different
grammar than the platform's selector syntax, DV reconciles the two and records the resolved spelling
in its artifact's `§ Decisions`.

### Escalation path

A banned stage that believes runtime evidence is needed never self-serves. Ordered:

1. Non-blocking need — record `requests_test_evidence: <what and why>` in the stage's own artifact
   (`§ Findings` / `§ Notes`); QA ingests and executes it like its own additions
   (`agents/qa-engineer.md § Q1 QA Additions`).
2. Blocking need — return `verdict: blocked` with `error_escalated_to: "DV"`; the orchestrator
   re-opens DV through the existing error-handling loop (`skills/agent-coordination/SKILL.md § Error
   Handling`). No new machinery.
3. Incident reproduction is not test execution — running the app, a repro script, or hitting a
   failing endpoint is allowed for IR; its fix verification still routes through the emergency
   pipeline's own DV and QA stages.
4. Compile-only checks are unaffected — `/<plugin>:build-test --no-test` stays available to every
   stage regardless of authority.

### Mechanical enforcement

Three layers, cheapest first (`skills/worktask/SKILL.md` step 4.8b,
`hooks/test-execution-gate.sh`):

1. Tool-grant narrowing — `security-reviewer` and `release-engineer` drop bare `Bash` for scoped
   allow-lists (the `technical-lead`/`project-manager` idiom); `incident-responder`, `prompt-engineer`
   and `workflow-engineer` keep broad Bash as documented carve-outs.
2. Orchestrator step 4.8b — a NO-TEST-EXECUTION banner + `stage_test_ban_enforced` audit row in
   the composed prompt of every dispatched stage not in `{DV, QA}`.
3. The `PreToolUse` hook — `hooks/test-execution-gate.sh`, fail-open on ambiguity, resolves the
   acting stage from `.context/state.json` (never agent/payload identity) and denies test-runner
   invocations outside `{DV, QA}`, plus DV full-suite runs. Exit code is always 0; the decision
   travels in `hookSpecificOutput.permissionDecision`. Only this layer covers delegated calls and the
   orchestrator's own shell.

### Redundant-run suppression

Authority answers *who*; this answers *again?*. Once a stage holding authority has been allowed a test
invocation, the same invocation is denied while the tree is byte-identical — it can only reproduce the
result already on record. Scope is `run_index`, so a run recorded by one stage covers a later stage's
identical run within the same run. Denied callers are told to cite the prior run: its stage and
timestamp appear in the deny reason and in a `test_execution_deduped` audit row. Build-only
verification is never suppressed.

#### A prior that executed nothing suppresses nothing

Suppression only makes sense against a result that could be cited instead. A prior whose evidence
token is `tests:0`, `discovered:<n>` (the runner enumerated cases and executed none), `unrecorded`
(a marker predating the evidence grammar), or any shape this grammar does not cover records no
result, so the gate allows and writes a `test_dedupe_skipped_zero_prior` row instead of a denial —
denying would refuse the only run that could still produce evidence.

#### Keyed on the tree, never on an outcome

`PreToolUse` cannot know whether a run passed, so the key is the tree: HEAD plus
`git status --porcelain` and `git diff HEAD`, the diff being load-bearing because porcelain
reports only names and status letters. Any edit to tracked content changes the fingerprint and
re-enables the command with no flag — this is what keeps test → fix → retest working, and it is the
property to protect in any change to the fingerprint.

The one gap, documented rather than closed: an untracked file's *content* is outside
the digest. Its creation shows in porcelain, so the first write moves the fingerprint; later edits
to a file never `git add`ed do not. Staged content is inside the digest — `git diff HEAD` covers the
index — so staging is not a way to re-enable a run, and neither is committing anything less than a
real change.

#### Fail-open and the hatch

Every unresolvable input — no git, no `shasum`, no `run_index` on the ledger — skips suppression and
allows, matching the hook's fail-open contract. `CORPFLOW_TEST_DEDUPE=off` in the process environment
disables it for flake investigation; like `CORPFLOW_TEST_GATE=off` it is a human ask, not
agent-serviceable, and is noted once per `.context/` in the audit trail. The gate keeps its own
sentinels under `.context/logs/.test-runs/` and does not read `full_test_run`/`scoped_test_run`
audit rows, which `skills/agent-coordination/SKILL.md` binds as audit-only, never a gate.

### SR/RE control layering

For SR and RE specifically, the hook is not a backstop behind the grant narrowing — it is the only
control. Their platform-auditor delegates (e.g. `Agent(system-developer:sys-security-auditor)`) hold
test-capable Bash grants of their own (`ctest`, `make`, …) that narrowing SR's/RE's own grant does not
touch; the hook denies the delegate's leaf call via the same state.json stage resolution. Correct by
design — but it means a regression in stage resolution is a complete loss of enforcement for SR/RE,
not a degradation of a defense-in-depth layer.

### Escape-hatch honesty

`CORPFLOW_TEST_GATE=off` and `CLAUDE_PROJECT_DIR` (pointed at a directory with no
`.context/state.json`) are both agent-writable across sessions, not agent-proof: any stage holding
`Write`/`Edit` can write `<project>/.claude/settings.json` `env`, effective on the next session or resume.
Within a live session neither is reachable from a command string — the hook reads process env, not
payload text — which is what makes the hatch a human relief valve rather than an agent-serviceable
retry. Across sessions it is human-intent-scoped, not a hard boundary; layers 1 and 2 do not share
this property. The hook logs a `test_gate_disabled` audit row the first time either vector is seen
disabled per `.context/`, so the disable is reviewable rather than silent.

## Test Selection Gate

Tests are slow (especially UI/simulator bundles). The gate decides, per worktask run, how much of
the test pyramid runs and where, so backend, refactor, and doc-only tasks do not pay
simulator-startup cost.

### Three test modes

| Mode | DV behaviour | QA behaviour | When PL sets it |
|------|--------------|--------------|-----------------|
| `build-only` | Build; run no tests (`Executed at DV` empty), except the no-handler promotion in § Auto-promotion safety nets. Parse `@depends-on:` markers. Emit Selected Tests list for QA. | Run only Selected Tests (always-required ∪ dependency-matched). Visual comparison gated on `ui_visual_check`. | Opt-in via explicit `test_mode: build-only`, in repos that completed marker migration: refactors without behavior change, dep updates, doc-only and internal-tool changes. |

#### `scoped` and `full` modes

| Mode | DV behaviour | QA behaviour | When PL sets it |
|------|--------------|--------------|-----------------|
| `scoped` (effective default) | Build + run Selected Tests + tests in any module the diff touches. | Selected Tests + module-level tests + any QA-added edge-case tests. Visual comparison gated on `ui_visual_check`. | Bug fixes, features not spanning subsystems, diffs touching files with weak `@depends-on:` coverage (defensive). Default when `test_mode` is omitted (avoids silent coverage blackout on untagged repos). |
| `full` | Build + run Selected Tests at DV. | Full project test suite as regression gate. Visual comparison gated on `ui_visual_check`. | Release candidates (RE prep), multi-module features (auth touching networking + UI + persistence), first run after a major dependency upgrade, stakeholder-requested regression. |

#### Effective default

Omitting `metadata.test_mode` resolves to `scoped`, not `build-only` — preserving "DV runs scoped
tests, QA runs the unit+integration suite" for untagged repositories. The `build-only` speedup
requires writing `test_mode: build-only` explicitly and meaningful marker coverage (the parser
warns if `< 50%` of test files lack any marker).

#### Comment/doc-only diffs — PL *selects* `build-only`

When every hunk of the planned diff is a comment, a prose file (`docs/**`, `*.md`), or a non-executable
string, no test outcome can change: PL sets `test_mode: build-only` and says why in
`<plan_file> § test-strategy`. The one case where the marker-coverage precondition does not apply —
the mode is chosen because nothing executable changed, not because markers stand in for a run. One
executable hunk anywhere in the planned diff disqualifies it.

Downstream: a doc-only change landing after QA (typically DC, which holds no execution authority)
does not re-trigger QA. FN commits on QA's existing evidence and records the post-QA diff as doc-only
in `complete-summary-N.md`.

#### Auto-promotion safety nets

DV/QA enforce these even if PL set a tighter mode:

- Selected Tests empty AND `test_mode = build-only` → DV warns and still runs no tests; QA promotes to
  `scoped` with a logged note in `testing-N.md § Notes`.
- No wired marker-parser handler for the platform (every platform except Apple today —
  `test-selection-syntax.md § Identifier grammar by platform`) AND `test_mode ∈ {build-only, scoped}`
  → DV auto-promotes to module-scope (never `full` — § Test-Execution Authority) with a logged
  warning. Metadata keeps the PL-declared mode; the promotion is recorded in
  the DV artifact's `§ Decisions` as `auto_promoted_mode: module-scope`. If module scope cannot be
  computed, DV runs the smoke set instead and records `deferred_to_qa: full_regression` — it does not
  widen further.

### Contract

- **Flag**: `metadata.test_mode: build-only | scoped | full` in `<plan_file>` frontmatter; absent →
  `scoped` (see *Effective default*), `build-only` is opt-in.
- **Companion flags**:
  - `metadata.always_required_tests: [<test ID>...]` — explicit override, included in every Selected
    Tests list regardless of mode.
  - `metadata.ui_visual_check: <bool>` — default `false`. When `true` AND `.context/designs/` exists,
    QA performs Design Comparison. Independent of `test_mode`.
- **Writer**: PL stage (`skills/worktask/references/pl0-procedure.md § Test Strategy Definition`).

#### Readers

- DV step D2 (`agents/developer.md`) — parses markers, computes Selected Tests, runs `Executed Tests
  (DV)` only when `test_mode ∈ {scoped, full}`; under `build-only` it runs tests only through the
  no-handler promotion (§ Auto-promotion safety nets). The mode is D2's rule, not a gate:
  `hooks/test-execution-gate.sh` never reads `test_mode` and allows DV a selector-bearing run in
  every mode.
- QA step Q1 (`agents/qa-engineer.md`) — three-mode dispatcher.
- QA Design Comparison (`agents/qa-engineer.md § Design Comparison`) — gated on `ui_visual_check=true`
  (not `test_mode`).
- DR (`agents/technical-lead.md`) does not run tests, so the gate does not apply; needing runtime
  verification it records `requests_test_evidence:` for QA and never executes (authority is canonical
  in § Test-Execution Authority).

### DV Executed vs Selected (scope split)

DV's `Selected Tests` is the handoff artifact consumed by QA; `Executed Tests (DV)` is the
subset DV actually runs.

- Selected Tests = full algorithm output (smoke ∪ dependency-matched ∪ covers-changed-files ∪
  module-level ∪ `metadata.always_required_tests`). Always written to
  `§ Selected Tests` in each DV row's artifact. QA executes the union across every DV artifact
  (`refs.dev[]`).
- Executed Tests (DV) = (Selected ∩ test files Added/Modified in
  `git diff --diff-filter=AMR <base>...HEAD`) ∪ `metadata.always_required_tests`. Only this subset
  runs at DV.

#### Empty-set safety net and rationale

If Executed Tests (DV) is empty AND Selected Tests is non-empty (production changed without touching
tests), DV runs only the smoke set and records `auto_executed: smoke_set` in `§ Decisions`; QA still
executes the full Selected list. Rationale: DV verifies that the code+tests it just wrote compile and
pass, while broader regression (dep-matched, covers, module-level) belongs to QA so DV stays fast and
QA owns the gate. Canonical derivation: `agents/developer.md § D2`.

### `ui_visual_check`

Set `true` when at least one applies: new user-facing views or screens (SwiftUI/UIKit, Compose,
React/Vue/Svelte/Angular components); design artifacts in `.context/designs/` need verification;
layout/styling/animation changes require screen capture; stakeholder requests UI verification.
Independent of `test_mode` — a `build-only` plan can still set it `true` for a purely visual diff
(rare but legal).

### Selected Tests — production by DV

DV's D2 step parses test sources for the markers in `skills/shared/test-selection-syntax.md` and
produces, as an H3 under `## tests-added` in `development-N.md`:

```markdown
### Selected Tests

| Mode | build-only |
| Reason | metadata.test_mode default |

#### Always Required
- AppLaunchTests.testLaunchSucceeds — `@test-required`
- AuthSmokeTests.testLoginRoundtrip — `metadata.always_required_tests`

#### Dependency-Matched
| Test | Matched on | Source |
| ---- | ---------- | ------ |
| PaymentRefundTests.testRefundFlow | `PaymentService` (changed in `PaymentService.swift:42`) | `// @depends-on: PaymentService` at `PaymentRefundTests.swift:8` |

#### Excluded (with reason)
| Test | Reason |
| ---- | ------ |
| OrderHistoryTests.testListRender | No marker matches diff; `test_mode != full` |
```

QA reads this section verbatim; QA's edge-case additions go to an
`### Selected Tests (QA additions)` H3 under `## results` in `testing-N.md`.

### Design↔result image comparison (wired flow)

With the Design Comparison gate open (`ui_visual_check: true` AND `.context/designs/` artifacts
present), QA's primary comparison reuses DV-captured result images and runs an objective RMSE
pixel-diff pre-pass before multimodal vision, rather than always re-capturing live. The per-row
algorithm and the reporting `RMSE` column are canonical in
`skills/worktask/references/visual-qa.md`; the gate is `agents/qa-engineer.md § Design Comparison`.

#### Join key (Option A)

DV's per-task `.context/images/<worktask_id>/screenshots-<TASK_ID>.md` manifests carry an optional
trailing `Design Ref` column populated with the matching `figma-registry.md` row `ID`
(`skills/dv-screenshot-capture/SKILL.md § Registry tagging`). QA joins
`screenshots-*.md.Design Ref → figma-registry.md.ID` by ID equality; the mapped DV image is both the
RMSE `--candidate` (`skills/dv-screenshot-capture/scripts/visual-diff.sh`) and the vision input. Live
re-capture is the fallback only — used when no DV image maps.

#### Verdict reconciliation and degradation (by reference)

- RMSE is a one-way escalator: it may raise severity, never lower it (RMSE is blind to
  copy/semantic errors). Full 6-row matrix:
  `skills/worktask/references/visual-qa.md § Verdict reconciliation`.
- The reuse is strictly additive; the full invariant list (gate unchanged, absent DV images →
  live-capture, `magick` absent → vision-only non-blocking, no registry → Glob Discovery, manifest
  without a `Design Ref` column) is canonical in
  `skills/worktask/references/visual-qa.md § Degradation invariants`.

### Skip mechanics — positive selection everywhere

Every platform translates the Selected Tests list into positive include flags, never negative
excludes: an exclude list silently grows stale as tests are added, an include list fails loudly.
Per-platform flag syntax and identifier grammar are canonical in
`test-selection-syntax.md § Platform handlers` — not restated here. Drop the filter entirely for
`test_mode=full`; the full suite is the regression gate. Prefer `/<plugin>:build-test`, which applies
the correct form for the repo.

### Skip mechanics — Apple platforms

Selected Tests become positive `-only-testing:` arguments (one per owning suite, deduplicated), never
`-skip-testing:`:

```bash
# Selected Tests = [PaymentRefundTests.testRefundFlow, AppLaunchTests.testLaunchSucceeds]
# → flags collapse to the owning suite (suite-terminal); never per-function
xcodebuild test -project MyApp.xcodeproj -scheme MyApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:MyAppTests/PaymentRefundTests \
  -only-testing:MyAppTests/AppLaunchTests
```

Identifiers are suite-terminal (`<Target>/<Suite>`) per `test-selection-syntax.md § Apple
identifier grammar — suite-terminal`; a per-function segment selects nothing under Swift Testing.
Under `test_mode=full` the whole suite runs without `-only-testing:`, and UI bundles run unless
explicitly excluded (no implicit `-skip-testing:`).

### Recording the resolved selection

DV records `test_mode`, `selected_tests_count`, and `ui_visual_check` in
its artifact's `§ Decisions` (the row's `metadata.artifact`). QA records the resolved mode and any
`Selected Tests (QA additions)` in `testing-N.md § Notes`. Applies on every platform, including runs
auto-promoted to `module-scope` (§ Test-Execution Authority).

### Marker and footer grammar

Full marker grammar (`@test-required`, `@depends-on:`, `@test-tag:`), parser pseudocode, and Swift
Testing trait equivalents: `skills/shared/test-selection-syntax.md`.

Source files also carry a `Test Info` footer (`@test-file:`, `@related-tests:`, `@test-coverage:`) and
test files a `Source Info` footer (`@source-file:`, `@doc-refs:`). Sentinel words are fixed; the
comment decoration around them is language-native (`// MARK: -` on Swift, `# region` on Python, a
plain banner elsewhere). Advisory — they do not affect selection — but they let reviewers and tooling
verify coverage intent bidirectionally. Grammar, platform variants, examples:
`test-selection-syntax.md § Footer Markers`.
