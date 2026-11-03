# Metadata schema

Read when executing or checking metadata schema. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
### JSON Schema

The orchestrator validates metadata before spawning the stage agent. Non-PL tasks require `stage`, `agent`, `model`, `effort`, `error_file`. The ten `json` blocks in this section are one schema, split for length; the last closes `properties`.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "allOf": [{
    "if": {"anyOf": [
      {"required": ["retry_watchdog_max_wait_ms"]},
      {"required": ["retry_watchdog_max_usage_limit_wait_ms"]}
    ]},
    "then": {"required": ["retry_watchdog"], "properties": {"retry_watchdog": {"const": true}}}
  }],
  "properties": {
    "stage": {
      "enum": ["PL", "AR", "TL", "DV", "DR", "SR", "QA", "DC", "RE", "FN", "ST", "IR", "ET"]
    },
    "agent": {
      "type": "string",
      "pattern": "^([a-z0-9-]+:)?[a-z0-9-]+$"
    },
    "model": {
      "enum": ["fable", "opus", "sonnet", "haiku"]
    },
    "effort": {
      "enum": ["low", "medium", "high", "xhigh", "max"]
    },
```

#### Schema — compaction controls

```json
    "auto_compact_window": {"type": "integer", "minimum": 100000, "maximum": 1000000},
    "retry_watchdog": {"type": "boolean"},
    "retry_watchdog_max_wait_ms": {"type": "integer", "minimum": 1, "maximum": 2147483647},
    "retry_watchdog_max_usage_limit_wait_ms": {"type": "integer", "minimum": 1, "maximum": 2147483647},
    "overloaded_retry_max_delay_ms": {"type": "integer", "minimum": 1, "maximum": 2147483647},
    "description": {
      "type": "string",
      "maxLength": 240,
      "description": "Human-readable stage label. Lives here, not top-level: state-patch.sh writes tasks.<ID> fields only through --metadata/--set."
    },
```

#### `description` is capped at 240 chars

Both writers — `--task-create --metadata` and `--task-meta --set` — truncate a longer value with an
ellipsis rather than rejecting it: a refused `--task-create` would break PL0 stage creation. Each
cut prints `description_truncated=<id>:<original length>` on stderr, so the caller knows the field
no longer holds the whole text. The field is a label: the planner's input is the full statement in
the PL0 dispatch prompt (`skills/worktask/references/workflow.md § Step 6 — the planning prompt`).

The orchestrator's dispatch-time appends (test scope, bans, the FN banner) mutate an in-memory copy
that is never written back, so they stay uncapped — capping them would strip those banners from
the prompt that needs them.

#### Schema — run & context properties

```json
    "run_index": {
      "type": "integer",
      "minimum": 0,
      "default": 0,
      "description": "Stamped by PL0; same N as planning-N.md."
    },
    "context_refs": {
      "type": "string",
      "description": "JSON-encoded array of anchor refs, e.g. '[\"architecture-N.md#decisions\",\"planning-N.md#requirements\"]'."
    },
    "state_file": {
      "type": "string",
      "default": ".context/state.json",
      "pattern": "^\\.context/[a-z0-9/_.-]+\\.json$"
    },
```

#### Schema — error & retry properties

```json
    "error_file": {
      "type": "string",
      "pattern": "^\\.context/errors/[a-z0-9-]+\\.md$"
    },
    "retry_count": {
      "type": "integer",
      "minimum": 0,
      "maximum": 3
    },
    "error_escalated_to": {
      "enum": ["PL", "AR", "TL", "DV", "DR", "SR", "QA", "DC", "RE", "FN", "ST", "IR", "ET"]
    },
    "escalation_counts": {
      "type": "object",
      "propertyNames": { "pattern": "^(PL|AR|TL|DV|DR|SR|QA|DC|RE|FN|ST|IR|ET)[0-9]+$" },
      "additionalProperties": { "type": "integer", "minimum": 0, "maximum": 3 }
    },
```

#### Schema — worktask properties

```json
    "track": {
      "type": "integer",
      "minimum": 1,
      "maximum": 5
    },
    "isolation": {
      "enum": ["worktree"],
      "description": "Always 'worktree' on file-writing tasks; no other value is valid."
    },
    "workspace_path": {
      "type": "string",
      "description": "Absolute root of the assigned tree. Stamped on every run and mirrored to state.json .metadata.workspace_path. See § workspace_path."
    },
    "priority": {
      "enum": ["high", "medium", "low"]
    },
    "approved": {
      "enum": ["user", "auto"],
      "description": "Plan-approval carrier on PL0, written by the orchestrator at the Step A.5 plan gate. Absent ⇒ stage agents block."
    },
```

#### Schema — the peer ask pointer

```json
    "ask_id": {
      "type": "string",
      "pattern": "^ask-[0-9]{8}t[0-9]{6}z-[0-9a-f]{12}$",
      "description": "The task's open mailbox ask, written by the router's peer_session arm. Scan and sweep read it off the ledger, never off the mailbox directory, so one run never relays another run's reply."
    },
```
