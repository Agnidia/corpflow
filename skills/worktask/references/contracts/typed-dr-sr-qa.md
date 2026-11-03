# Typed dr sr qa

Read when executing or checking typed dr sr qa. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
### DRHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "DRHandoff",
  "type": "object",
  "required": ["verdict", "findings", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["pass", "fail"] },
    "findings": { "type": "array", "items": { "type": "string" } },
    "blockers": { "type": "array", "items": { "type": "string" } },
    "p2_only": { "type": "boolean" },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  },
  "allOf": [{ "if": { "properties": { "verdict": { "const": "fail" } } },
              "then": { "required": ["blockers"],
                        "properties": { "blockers": { "minItems": 1,
                          "items": { "type": "string", "minLength": 1, "pattern": "\\S" } } } } }]
}
```

#### DRHandoff — a failure names its defects

A DR `fail` names each blocking defect in `blockers`, one nonblank string per defect.
The frontmatter validator enforces this with or without `yq`; the loop-back copies the list into DV
`metadata.gate_blockers` for the remediation brief. Passing DR artifacts may omit the list.

### SRHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "SRHandoff",
  "type": "object",
  "required": ["verdict", "findings", "blockers", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["pass", "fail"] },
    "findings": { "type": "array", "items": { "type": "string" } },
    "blockers": { "type": "array", "items": { "type": "string" } },
    "threat_model": { "type": "string" },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### QAHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "QAHandoff",
  "type": "object",
  "required": ["verdict", "tests_executed", "tests_passed", "tests_failed", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["go", "no-go"] },
    "tests_executed": { "type": "array", "items": { "$ref": "#/$defs/TestRunEntry" } },
    "tests_passed": { "type": "integer", "minimum": 0 },
    "tests_failed": { "type": "integer", "minimum": 0 },
    "blocking_defects": { "type": "array", "items": { "type": "string" } },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  },
  "allOf": [{ "if": { "properties": { "verdict": { "const": "no-go" } } },
              "then": { "required": ["blocking_defects"],
                        "properties": { "blocking_defects": { "minItems": 1,
                          "items": { "type": "string", "minLength": 1 } } } } }]
}
```

#### QAHandoff — a no-go names its defects

A `no-go` names each defect in `blocking_defects`, one string each; `handoff-harness.sh
--validate-frontmatter` enforces it with or without `yq` (a whitespace-only entry counts as
empty). The Step 7 loop-back copies the list into the DV row's `gate_blockers`.
