# Typed st ir et

Read when executing or checking typed st ir et. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
### STHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "STHandoff",
  "type": "object",
  "required": ["verdict", "key_decisions", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["approve", "reject"] },
    "key_decisions": { "type": "array", "items": { "type": "string" } },
    "follow_ups": { "type": "array", "items": { "type": "string" } },
    "blockers": { "type": "array", "items": { "type": "string" }, "description": "reject only: one unmet criterion each; the loop-back injects them into the replayed DV prompt" },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### IRHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "IRHandoff",
  "type": "object",
  "required": ["verdict", "root_cause", "next_stage_focus", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["ok", "escalate"] },
    "root_cause": { "type": "string" },
    "next_stage_focus": { "type": "string" },
    "blast_radius": { "type": "string" },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### ETHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "ETHandoff",
  "type": "object",
  "required": ["verdict", "findings", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["pass", "fail"] },
    "findings": { "type": "array", "items": { "type": "string" } },
    "mitigations": { "type": "array", "items": { "type": "string" } },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```
