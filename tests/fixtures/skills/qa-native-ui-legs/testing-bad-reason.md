---
handoff:
  stage: QA
  verdict: no-go
  blocking_defects:
    - "UI-3 not delegated with an empty reason"
  summary: "Negative fixture: a not_delegated native UI leg with no reason"
  tests_executed: [{ runner: bats, count: 3, summary_line: "1..3" }]
  files_touched: []
  key_decisions:
    - { id: qa1, summary: "UI-3 not delegated with an empty reason", anchor: "testing-bad-reason.md#results" }
  open_questions: []
  refs:
    dev: development-0.md#files-changed
    results: testing-bad-reason.md#results
---

# Testing — negative fixture

## results

Suite: `1..3`, 0 failures.

### Native UI Legs

| Leg | Platform | Kind | Alias | Routed to | Status | Reason | Evidence | Verdict |
|---|---|---|---|---|---|---|---|---|
| UI-1 | ios | ui-test-bundle | `corpflow:apple-ui-verifier` | `apple-developer:ios-developer` | delegated | — | test-qa-ui-UI-1-20260916-101500.log | pass |
| UI-2 | android | live-drive-capture | `corpflow:android-ui-verifier` | `android-developer:android-developer` | delegated | — | test-qa-ui-UI-2-20260916-102200.log, qa-QA0-UI-2-01-settings.png | pass |
| UI-3 | macos | live-drive-capture | `corpflow:apple-ui-verifier` | `apple-developer:macos-developer` | not_delegated | — | — | — |

## coverage

Not measured for this fixture.

## regressions

None.

## verdict

no-go: the not_delegated row carries no reason.

## elicitation-sweep

No open questions.
