# Metadata artifacts

Read when executing or checking metadata artifacts. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
#### Schema — DV fan-out properties

```json
    "stream": {
      "type": "string",
      "pattern": "^[a-z0-9]+(-[a-z0-9]+)*$",
      "description": "DV rows only. See § Fan-out fields (DV rows)."
    },
    "artifact": {
      "type": "string",
      "description": "DV rows only. See § Fan-out fields (DV rows)."
    },
```

#### Schema — landing declarations

```json
    "produces": {
      "type": "array",
      "items": { "type": "string" },
      "description": "DV rows: repo-relative paths this row stages for consumers."
    },
    "consumes": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["from", "paths"],
        "additionalProperties": false,
        "properties": {
          "from": { "type": "string", "pattern": "^DV[0-9]+$" },
          "paths": { "type": "array", "minItems": 1, "items": { "type": "string" } }
        }
      }
    },
```

#### Schema — landing results

```json
    "landed_paths": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Written only by land-artifacts.sh. See § Landing results."
    },
    "landed_roots": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Written only by land-artifacts.sh, with landed_paths. See § Landing results."
    },
    "landing_error": {
      "type": ["object", "null"],
      "properties": {
        "reason": { "type": "string" },
        "path": { "type": "string" },
        "producer": { "type": "string" }
      }
    },
```

#### Schema — requires_screenshots + required-fields rule

```json
    "requires_screenshots": {
      "type": "boolean",
      "description": "Advisory: DV and QA tasks SHOULD carry this, stamped by PL0 from the plan frontmatter (writer: the planning model's judgment; detect-ui-change.sh is advisory input; DV or the DV SubagentStop gate may raise it to true via escalate-flag.sh, never lower it). Drives dv-screenshot-capture + hooks/dv-screenshot-gate.sh + attach-visual-evidence.sh. Downstream readers default it true as defense-in-depth when absent."
    }
  },
  "allOf": [
    {
      "if": {
        "properties": { "stage": { "not": { "const": "PL" } } },
        "required": ["stage"]
      },
      "then": {
        "required": ["stage", "agent", "model", "effort", "error_file"]
      }
    }
  ]
}
```

#### error_file derivation

Orchestrator populates if absent — basename = last `:`-separated segment of `agent`:
- `corpflow:developer` → `.context/errors/developer.md`; `apple-developer:ios-developer` → `.context/errors/ios-developer.md`
- Basename collision across plugins → join with `-`: `.context/errors/apple-developer-ios-developer.md`

#### Context delivery

`metadata.context_refs` is the only context-delivery mechanism; there is no whole-file fallback,
because the ledger is mandatory. On retry the stage agent also reads its own `error_file`, so it
sees what it tried before and why it failed.
