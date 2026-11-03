---
name: testing-strategy
version: 0.6.0
---

# Testing Strategy

General testing practices across platforms. Use the platform's frameworks and syntax; Apple rules apply only to Apple projects.
Platform routing: `skills/shared/platform-detection.md`.
Worktask execution policy: `skills/worktask/references/testing-strategy.md`.

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
(`skills/worktask/references/stage-contracts.md § An xcresult summary corroborates an xcodebuild line`).

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
