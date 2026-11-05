# Typed dc re fn

Read when executing or checking typed dc re fn. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
### DCHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "DCHandoff",
  "type": "object",
  "required": ["verdict", "files_modified", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["ok", "blocked", "escalate"] },
    "files_modified": { "type": "array", "items": { "type": "string" } },
    "cross_references": { "type": "array", "items": { "type": "string" } },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### REHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "REHandoff",
  "type": "object",
  "required": ["verdict", "version", "files_modified", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["ok", "blocked"] },
    "version": { "type": "string" },
    "files_modified": { "type": "array", "items": { "type": "string" } },
    "changelog": { "type": "array", "items": { "type": "string" } },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```

### FNHandoff

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "FNHandoff",
  "type": "object",
  "required": ["verdict", "summary", "next_stage_focus", "open_questions"],
  "properties": {
    "verdict": { "type": "string", "enum": ["ok", "blocked"] },
    "summary": { "type": "string", "maxLength": 200 },
    "next_stage_focus": { "type": "string" },
    "files_modified": { "type": "array", "items": { "type": "string" } },
    "pr_url": { "type": "string" },
    "open_questions": { "type": "array", "items": { "$ref": "#/$defs/SweepItem" } }
  }
}
```
