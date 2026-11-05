# Typed dv

Read when executing or checking typed dv. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
### DVHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "DVHandoff",
  "type": "object",
  "required": ["verdict", "files_modified", "build_status", "tests_executed",
               "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["ok", "blocked", "escalate"] },
    "files_modified": { "type": "array", "items": { "type": "string" } },
    "tests_added": { "type": "array", "items": { "type": "string" } },
    "decisions": { "type": "array", "items": { "type": "string" } },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### DVHandoff — build, test-evidence and architecture properties

```json
{
  "…continued": "DVHandoff.properties",
  "build_status": { "type": "string", "enum": ["pass", "fail", "skipped"] },
  "tests_executed": { "type": "array", "items": { "$ref": "#/$defs/TestRunEntry" } },
  "test_suite_compiles": { "enum": [true, false, "unknown"] },
  "architecture": {
    "type": "object",
    "required": ["ref", "applied"],
    "properties": {
      "ref": { "type": "string", "pattern": "^architecture-[0-9]+\\.md(#[a-z-]+)?$" },
      "applied": { "type": "boolean" }
    }
  }
}
```

#### DVHandoff — test-evidence field notes

`count` is the cases that ran under that runner, never cases it enumerated. `summary_line` is that
runner's summary line copied byte-for-byte, required whenever `count` is above 0 and checked against
the artifact body or a named `.context/logs/` capture; the count-token match inside it is warn-only,
since not every formatter repeats the number. QA's `tests_passed` / `tests_failed` stay grand totals, expected to equal the sum of `count`,
which DR spot-checks and the harness does not. Contract: `skills/worktask/references/contracts/test-evidence.md#summary_line-is-the-checked-half-tpl-dv`.

##### DVHandoff — zero executed tests

`test_suite_compiles` is required whenever the `tests_executed` list is empty or every `count` is `0`,
and optional otherwise — the distinction between gate-blocked and never-built, answerable without
test-execution authority. It is deliberately not folded into `build_status`, which reports the app
build: a test target can fail to compile against a clean app build. Contract and rationale:
`skills/worktask/references/contracts/test-evidence.md#zero-executed-tests-must-say-whether-the-suite-compiles-tpl-dv`. Enforced by
`handoff-harness.sh --validate-frontmatter`.

##### DVHandoff — the legacy scalar

A scalar `tests_executed` fails validation by default. Under `--legacy-tests-executed` (or
`CORPFLOW_LEGACY_TESTS_EXECUTED=1`) a legacy scalar and its legacy top-level
`test_summary_line` validate under the old integer rules with one deprecation `warn:`; the
opt-in never relaxes a list and is deprecated but still accepted. A top-level
`test_summary_line` beside a list is a legacy leftover, ignored as evidence with a `warn:`; its
line belongs in that runner's `summary_line`.

#### DVHandoff — architecture field notes

`architecture` is optional at the schema level but required whenever `state.json` has a
`tasks.AR0` entry, together with `refs.decisions`; both are omitted when AR did not run
(`skills/worktask/references/contracts/architecture-reference.md#architecture-reference-contract-tpl-dv`). Reference-resolution precedence,
shared by the harness, this schema and the DR rule: `refs.decisions`, then `architecture.ref`.
`handoff-harness.sh --validate-frontmatter <artifact> --state <state.json>` enforces it (warn-only
by default, blocking under `--strict`) and its inverse guard warns when an `architecture-*`
reference appears without a `tasks.AR0` entry. `applied` is DV's truthful statement that AR's
decisions were followed; deviations go in the row's artifact (`development-<N>[-<stream>].md`)
`## decisions` with rationale, and DR
fails an undeclared one.
