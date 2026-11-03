---
name: test-selection-syntax
---

# Test Selection Syntax

Inline source-level markers that DV parses to compute the `Selected Tests` list consumed by QA. Companion to `skills/worktask/references/testing-strategy.md § Test Selection Gate`.

## Markers

Three markers, written as line comments in test sources in that language's syntax (`//`, `#`,
`--`); the marker text is identical on every platform. All are optional — an untagged test counts
as `@test-tag: regression` with no dependency edges, so it runs only in `test_mode=full` or via
`metadata.always_required_tests`.

### `@test-required`

Runs in every mode (`build-only`, `scoped`, `full`). Use sparingly — smoke tests, app-launch checks, auth round-trip, and other "if this fails the build is unusable" guards.

### `@depends-on: <SymbolName>`

Re-run this test when the named symbol (top-level type, function, or extension target) appears in the changed-files diff. One symbol per marker; repeat for more. Matching is exact, case-sensitive, and spelled as in source: a diff touching `PaymentService.swift` / `.kt` / `payment_service.py` marks `PaymentService` changed; a changed free function `processRefund(...)` yields `processRefund`; a Python test covering `payment_service.process_refund` writes `@depends-on: process_refund`.

### `@test-tag: <tag>`

Categorize for filtering; repeat the marker for multiple tags. Unknown tags are preserved (permissive parser) but ignored by the dispatcher.

| Tag | Meaning | Where it runs |
|-----|---------|---------------|
| `smoke` | Critical-path verification | Always (treated as `@test-required`) |
| `regression` | Default for untagged tests | `test_mode=full` only, unless dep-matched |
| `perf` | Performance-sensitive, slow | `test_mode=full` only |
| `ui` | UI/visual interaction | `test_mode=full` AND `ui_visual_check=true` |
| `flaky` | Quarantined; not executed | Never (until untagged) |

Canonical block, here in Python:

```python
# @test-required
# @test-tag: smoke
# @depends-on: SessionStore
def test_login_roundtrip_stores_session(): ...
```

## Native tag equivalents

A framework's own tagging mechanism is a first-class equivalent to `@test-tag:` — prefer it, since
the runner can filter on it too; mixed style is allowed. `@depends-on:` has no native equivalent
anywhere (dependency declaration is not a test-runner concern) — always use the comment marker.

| Framework | Native tag | Equivalent to |
|-----------|-----------|---------------|
| Swift Testing | `.tags(.smoke)` | `@test-tag: smoke` |
| JUnit 5 | `@Tag("smoke")` | `@test-tag: smoke` |
| pytest | `@pytest.mark.smoke` | `@test-tag: smoke` |
| Go | `testing.Short()` guard | `@test-tag: perf` (inverse sense) |
| Vitest / Jest | none — use the comment marker | — |

### Swift Testing traits

Declare tags once per project (`extension Tag { @Tag static var smoke: Self }`), then apply by value: `@Test("login round-trip", .tags(.smoke, .required))`. `.tags(.required)` ≡ `// @test-required`; `.tags(.smoke)` ≡ `// @test-tag: smoke`.

## Parser algorithm (DV/D2)

DV's D2 step:

1. `changed_symbols` = top-level symbols (types, funcs, enums) extracted from every source file in `git diff --name-only <base>...HEAD`.
2. Parse markers on each test in the test source roots; select it if any holds: it carries `@test-required` or tag `smoke`; one `@depends-on` symbol is in `changed_symbols`; it *covers* a changed file (below).
3. Union in `metadata.always_required_tests` (plan-level override).
4. Write the result to `§ Selected Tests` in the DV row's artifact (`metadata.artifact`).

### "Covers" rule — exact specification

A test **covers** a changed source file when any of these match (first match wins):

1. **Filename correlation**: the changed file's basename `<Name>` maps to a test filename by the language's convention — § Test-file naming by language.
2. **Type-name correlation**: the changed file declares a top-level type or exported symbol `T`; test source declares a type, class, or `describe`/`@Suite` block matching `^${T}(Tests?|Spec)$`.
3. **Module correlation** (`scoped` only, never `build-only`): the test file sits in the changed file's module/target — Swift package or Xcode test target, Gradle source set, npm workspace package, Python package, Go package directory, or sibling directory under the repo's test root.

#### Test-file naming by language

Rule 1 resolves `<Name>` through the row matching the changed file's extension; test roots are
repo-conventional (`Tests/`, `src/test/`, `tests/`, `__tests__/`, or alongside the source). Rust's
in-file `mod tests` is the one case where test and source file are the same path — a changed
`<name>.rs` with an inline `mod tests` always self-covers.

##### Naming table

| Language | Source | Test filename |
|----------|--------|---------------|
| Swift | `<Name>.swift` | `<Name>Tests.swift`, `<Name>Spec.swift` |
| Kotlin / Java | `<Name>.kt`, `<Name>.java` | `<Name>Test.kt`, `<Name>Tests.kt` |
| TypeScript / JS | `<name>.ts`, `<name>.tsx` | `<name>.test.ts(x)`, `<name>.spec.ts(x)` |
| Python | `<name>.py` | `test_<name>.py`, `<name>_test.py` |
| Go | `<name>.go` | `<name>_test.go` (same package dir) |
| Rust | `<name>.rs` | in-file `mod tests`, or `tests/<name>.rs` |
| Ruby | `<name>.rb` | `<name>_spec.rb`, `<name>_test.rb` |
| C / C++ | `<name>.c`, `<name>.cpp` | `test_<name>.c`, `<name>_test.cpp`, `<Name>Test.cpp` |
| Bash | `<name>.sh` | `<name>.bats` |

#### Covers rule × test mode

Rules 1–2 are the universal definition for `build-only`; rule 3 is additive over-inclusion in `scoped` (deliberate safety margin); `full` ignores the heuristic and runs everything. The parser logs an `info` note per diffed file with no covering test and no marker hit, so PMs can assess gaps.

### Malformed marker handling

Parsing is permissive; each case logs to `.context/logs/test-selection-warnings.md`:

- Unknown tag (`@test-tag: foo`) — preserved, ignored by the dispatcher.
- Malformed marker (`@depends-on:` with no symbol) — test included as if the marker were absent.
- Marker on the wrong scope (`@test-required` on a `@Suite`, not a `@Test`) — applies to all tests in the suite, intentionally.

## Closure rules

A matching `@depends-on: A` selects the marked test only — transitive closure is not computed; chasing A's downstream callers balloons the selected set and defeats selective execution. Fan-out tests that must always run get `@test-required` or `metadata.always_required_tests`.

Exception: under `test_mode=scoped` the parser also adds tests for any module touched by the diff (module = directory of the changed file) — deliberate over-inclusion, `scoped` being the safety mode for users who can't yet trust the marker graph.

## Examples

### Backend-only diff with good markers

Diff `Sources/Networking/RetryPolicy.swift`, with markers `RetryPolicyTests` → `@depends-on: RetryPolicy`, `NetworkClientTests` → `@depends-on: NetworkClient` only (it calls RetryPolicy, unmarked), `AuthFlowTests` → none, `AppLaunchTests` → `@test-required`.

| `test_mode` | Selected |
|---|---|
| `build-only` | `RetryPolicyTests`, `AppLaunchTests` — both unmarked suites excluded |
| `scoped` | those + every test in `NetworkingTests/` (module over-inclusion); `AuthFlowTests` still excluded (other module) |
| `full` | entire suite |

### UI feature diff

Diff `src/components/LoginForm.tsx` + a design PNG under `test_mode: build-only`, `ui_visual_check: true` → DV builds and writes the marker-derived Selected Tests; it executes nothing on a platform with a wired handler, and here (web, unwired) runs the touched module through § Auto-promotion when no handler; QA runs that list plus Design Comparison (gated on `ui_visual_check=true` AND designs present, independent of `test_mode`).

### Migration: untagged repository

Zero markers under `test_mode: build-only` yields an empty Selected Tests list (apart from `metadata.always_required_tests`), triggering the auto-promotion safety net (`skills/worktask/references/testing-strategy.md § Auto-promotion safety nets`): QA promotes that run to `scoped` and records the promotion plus the remedy (add `@test-required` markers or `metadata.always_required_tests`) in `testing-N.md § Notes`.

#### DV warning and DR surfacing

DV warns to `.context/logs/test-selection-warnings.md`:

> No `@test-required` or `@depends-on:` markers found in <N> test files. Selected Tests is empty. Either tag tests, set `metadata.always_required_tests`, or use `test_mode: scoped|full`.

DR (`agents/technical-lead.md`) reads that log during review and surfaces non-empty warning files in `developer-review-N.md § Findings`; silent test drops escalate to DV through DR's normal feedback channel.

## Warning log schema

`.context/logs/test-selection-warnings.md` — appended by DV, never overwritten; QA quotes every `WARN:` line into `testing-N.md § Notes`.

```markdown
# Test Selection Warnings — <ISO-8601 timestamp>

## Run <N> — <plan_file>

- INFO: 12 changed files; 8 covered by markers, 4 with no covering test or marker.
- WARN: malformed marker at `Tests/PaymentRefundTests.swift:14` — `// @depends-on:` (missing symbol). Treated as absent.
```

## Platform handlers

The marker grammar is platform-agnostic (line comments parse everywhere). What varies is the
identifier grammar each runner accepts and whether corpflow has wired a handler that emits it.
Status is per-platform and load-bearing: an unwired platform auto-promotes (§ Auto-promotion when
no handler) however well-specified its syntax is.

### Identifier grammar by platform

Apple's row is the only one a corpflow parser emits for product repos; the rest document the
syntax a future handler will need.

#### Grammar — app platforms

| Platform / runner | Selection syntax | Handler status |
|-------------------|------------------|----------------|
| Apple (Swift Testing / XCTest) | xcodebuild `-only-testing:<Target>/<Suite>`; SwiftPM `swift test --filter '<Suite>'` — suite-terminal [^apple] | Wired [^divergence] |
| Android (Gradle + JUnit) | `--tests '<package>.<ClassName>'`, optionally `.<methodName>` [^android] | Documented, not wired |
| Web (Vitest / Jest) | `<file path>` positional + `-t '<name pattern>'` | Documented, not wired |
| Web E2E (Playwright) | `<file path>` positional + `-g '<title pattern>'` | Documented, not wired |

#### Grammar — systems, backend, ai runners

| Runner | Selection syntax | Handler status |
|--------|------------------|----------------|
| Python (pytest) | nodeid `<file>::<Class>::<test>`, or `-k '<expr>'` | Documented, not wired |
| Go | `-run '^<TestFunc>$'` scoped to a package path | Documented, not wired |
| Rust | `cargo test <substring>` (matches the test path) | Documented, not wired |
| C / C++ | `ctest -R '<regex>'`; GoogleTest `--gtest_filter='<Suite>.<Test>'` | Documented, not wired |
| Bash (bats) | `<file>` positional + `-f '<name regex>'` | Wired [^bats] |

#### Bash (bats) — reference implementation

[^bats]: The corpflow repository itself is the reference implementation
— see this section.

A change→test dependency matrix resolves changed paths to `.bats` files that
`./run-tests.sh --changed` then runs: `full` maps to the bare runner, `scoped`
to `--changed`, the L3 ALWAYS floor is the `@test-required` equivalent,
`metadata.always_required_tests` maps to `--only`, and an empty computed
changed set fails closed to the full suite — the auto-promotion safety net as a
verdict. Selection is opt-in; its only permitted error is over-selection
(`tests/README.md § Test Selection`, `tests/selection/matrix.tsv`).

#### Handler status semantics

"Documented, not wired" means the syntax is correct and safe to write into a plan or report, but
no corpflow parser emits it yet — those runs auto-promote to module-scope at DV (§ Auto-promotion
when no handler; never `full` — `skills/worktask/references/testing-strategy.md § Test-Execution Authority`).

### Apple identifier grammar — suite-terminal

Apple's grammar is a hard runner constraint, not a convention, so it carries the extra rule below;
the other rows are ordinary filter syntax.

[^apple]: The identifier ends at a type, never at a function. `<SuiteName>` is an
`XCTestCase` subclass or a Swift Testing suite type, spelled as in source. Nested suites
legitimately add a segment (`Target/Outer/Inner`) — the terminal segment is still a type.
SwiftPM's `--filter` is a regular expression over `<Target>.<Suite>/<test>` identifiers, so
several suites share one flag as an alternation: `swift test --filter '<SuiteA>|<SuiteB>'`.
`hooks/test-execution-gate.sh` reads `--filter` and `-only-testing:` as selectors.

#### Why per-function forms are forbidden

Per-function forms (`/testRefundFlow`, `/testRefundFlow()`, `/testRefundFlow(amount:)`) are
forbidden: a Swift Testing `@Test` identifier includes the function's parentheses and
`@Test(arguments:)` appends a per-argument suffix, so `Target/Type/methodName` matches zero tests —
xcodebuild selects nothing and the run degrades to a full-suite fallback. A suite flag runs the
whole suite; that widening is intended and strictly cheaper than the fallback it replaces. Do not
"optimize" it back to per-function.

### Identifier grammar — platform asymmetries

[^android]: Android keeps a per-method form on purpose — JUnit's filter grammar has neither the
parenthesis nor the parameterized-suffix problem, and the same holds for pytest nodeids, `go test
-run`, and `vitest -t`. Apple's suite-terminal rule is the exception, not the model to copy.

[^divergence]: `apple-developer:swift-testing-entry` still documents the per-function form and
lives in a separate repository. Until that follow-up lands, this table is authoritative for
corpflow stages.

### Auto-promotion when no handler

An unwired platform (every row except Apple in § Identifier grammar by platform) with `test_mode ∈ {build-only, scoped}` triggers DV to auto-promote that run to module-scope (never `full` — DV holds no full-suite authority, `skills/worktask/references/testing-strategy.md § Test-Execution Authority`) and log to `.context/logs/test-selection-warnings.md`:

> No selective-test handler wired for platform `<platform>`. Auto-promoted to module-scope for this run (every test file in the touched module(s), via the platform's positional/filter syntax); selective execution will activate when a handler ships. Markers are still parsed and recorded for forward-compatibility.

#### Recording the auto-promotion

The DV artifact's `§ Decisions` records `auto_promoted_mode: module-scope` so QA and DR see the deviation — a DV-artifact execution value, never a `test_mode` value; the plan-level `test_mode` is not rewritten. If module scope cannot be computed, DV runs the smoke set and records `deferred_to_qa: full_regression` instead.

## Reader matrix

### DV and QA

| Reader | What it does with markers/Selected Tests |
|--------|------------------------------------------|
| **DV** (`agents/developer.md` D2) | Parses markers; writes Selected Tests and warnings. Builds in every mode. Executes only `Executed Tests (DV)` = `Selected ∩ test files Added/Modified` (`git diff --diff-filter=AMR`) ∪ `metadata.always_required_tests`, under `scoped`/`full` only; empty set → smoke set with `auto_executed: smoke_set` (`skills/worktask/references/testing-strategy.md § DV Executed vs Selected`). Under `build-only` it executes nothing apart from § Auto-promotion when no handler. |
| **QA** (`agents/qa-engineer.md` Q1) | Reads `§ Selected Tests` from every DV artifact (`refs.dev[]`; `skills/worktask/references/contracts/artifact-map.md § Iterating the DV tasks`), the union of full lists, not DV's Executed subsets; runs it (build-only/scoped) or the full suite (full); copies WARN lines from the warning log into `testing-N.md § Notes`. |

### DR and PL

| Reader | What it does with markers/Selected Tests |
|--------|------------------------------------------|
| **DR** (`agents/technical-lead.md`) | Reads the warning log and `§ Executed at DV`; surfaces non-empty warnings as findings in `developer-review-N.md § Findings`. Does not execute tests — `agents/technical-lead.md § Constraints` holds the forbidden-commands list. |
| **PL** (`agents/product-manager.md`) | Writes `metadata.test_mode`, `metadata.always_required_tests`, `metadata.ui_visual_check`. Does not parse markers. |

## Footer Markers

Metadata blocks appended to source and test files, cross-referencing production code and its tests bidirectionally. They are advisory — § Parser algorithm ignores them; their purpose is traceability for developers, reviewers, and QA.

### Source File Footer

Forward pointer from a production source file to its covering tests.

| Field | Required | Format | Description |
|-------|----------|--------|-------------|
| `@test-file:` | yes | Relative path from project root | Primary test file for this source |
| `@related-tests:` | no | Comma-separated relative paths | Cross-dependency test files also exercising this source |
| `@test-coverage:` | yes | Free text (single line) | What the tests verify |

```swift
// MARK: - Test Info
// @test-file: Tests/Services/PaymentServiceTests.swift
// @related-tests: Tests/Integration/PaymentFlowTests.swift, Tests/Services/NetworkClientTests.swift
// @test-coverage: Unit tests for charge(), refund(), and validateCard(). Integration tests for end-to-end payment flow.
```

### Test File Footer

Back pointer from a test file to its source and relevant documentation.

| Field | Required | Format | Description |
|-------|----------|--------|-------------|
| `@source-file:` | yes | Relative path from project root | Production source file this test exercises |
| `@doc-refs:` | no | Comma-separated URLs | Platform/framework docs or other relevant links |

```swift
// MARK: - Source Info
// @source-file: Sources/Services/PaymentService.swift
// @doc-refs: https://developer.apple.com/documentation/storekit, https://stripe.com/docs/api
```

Optional fields may be omitted; decoration is language-native (§ Platform Variants) — `# region Test Info` in Python, `// #region Source Info` in TypeScript.

### Platform Variants

Fixed is the sentinel phrase — `Test Info` / `Source Info` on a comment line, followed by
contiguous `@`-marker lines. The decoration is the language's own section idiom, not Swift's:
`MARK:` is an Xcode affordance meaning nothing outside Swift and Objective-C — do not export it;
where a language has no section idiom, a plain comment banner is correct. Region forms (`region` /
`#region`) fold in IntelliJ, VS Code, and PyCharm — close them with the matching `endregion` line
where the file already uses that convention.

#### Sentinel by language

`<Kind>` is `Test Info` in a source file, `Source Info` in a test file.

| Language | Sentinel line |
|----------|---------------|
| Swift / Objective-C | `// MARK: - <Kind>` |
| Kotlin / Java | `// region <Kind>` |
| TypeScript / JS | `// #region <Kind>` |
| Python | `# region <Kind>` |
| Ruby, Bash | `# --- <Kind> ---` |
| Go, Rust, C / C++ | `// --- <Kind> ---` |

### Position Rules

- The footer is the last block in the file, after all code and closing braces, separated from preceding code by a blank line, with no blank line inside the block.
- Paths are relative to project root (the directory holding `.git/`, or the nearest manifest — `Package.swift`, `settings.gradle(.kts)`, `package.json`, `pyproject.toml`, `go.mod`, `CMakeLists.txt`), forward slashes, no leading `./`.
- Multi-value fields (`@related-tests:`, `@doc-refs:`) delimit with comma-space; past ~120 characters, overflow into repeated marker lines (`// @related-tests: Tests/A.swift`, then `…Tests/B.swift`), which are additive.

### Marker Namespace

| Markers | Kind | Consumed by |
|---------|------|-------------|
| `@test-required`, `@depends-on:`, `@test-tag:` | Selection | Parser algorithm (D2) |
| `@test-file:`, `@related-tests:`, `@test-coverage:` | Footer (source) | Human / agent (advisory) |
| `@source-file:`, `@doc-refs:` | Footer (test) | Human / agent (advisory) |

### Parser Behavior

Footer markers carry no runtime semantics — `@related-tests:` does not select the listed tests; use `@depends-on:` in the test file for that. A missing footer is not an error; a malformed one (`@test-file:` with no path) logs a warning without affecting selection.
