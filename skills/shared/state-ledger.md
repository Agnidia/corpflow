---
name: state-ledger
version: 1.1.0
---

# State Ledger Reference

Single source of truth for worktask stage state.

## The ledger is `state.json`

`.context/state.json` `tasks{}` is the only stage ledger — authoritative for stage status,
dependencies, routing metadata, and results. It lives in the worktask folder, so it survives session
end, compaction, and resume with no configuration. Full schema:
`skills/worktask/references/handoff-protocol.md#state-json-schema`.

### Why not Claude Code's Task System

corpflow does not use Claude Code's Task System (`TaskCreate` / `TaskUpdate` / `TaskGet` /
`TaskList`), even on a model that offers it: most of the models this plugin dispatches do not, and
one ledger keeps one code path.

## Ledger Keys

`[STAGE][N]`, N 0-based and sequential per stage code: first `DV` created → `DV0`, second → `DV1`
(`PL0`, `AR0`, `DV0`, `DV1`). The human-readable label lives in `tasks.<ID>.metadata.description`.

PL is always the singleton `PL0`; other stages split into sub-tasks, so parallel DV tracks are
distinct keys. Handoff edges carry the same split: `handoffs["<PREV_CODE>→<TASK_ID>"]` — the source
is a bare stage code, the destination the ledger id of the task that wrote the edge (`PL→AR0`,
`TL→DV1`), so parallel tracks never overwrite one another's edge. Old-shape keys:
`skills/worktask/references/handoff-protocol.md § Field notes — handoffs (edge registry)`.

## Write Operations

Never edit `state.json` directly — every write goes through
`skills/worktask/scripts/state-patch.sh`, which owns the merge lock, the atomic
tmp→fsync→rename, and the disk guard.

| Operation | Command |
|-----------|---------|
| Create | `state-patch.sh --task-create <ID> --metadata '<json>'` |
| Set status | `state-patch.sh --task-status <ID> <status>` |
| Add dependency | `state-patch.sh --task-block <ID> --on <ID[,ID...]>` |
| Remove dependency | `state-patch.sh --task-unblock <ID> --off <ID[,ID...]>` |
| Merge metadata | `state-patch.sh --task-meta <ID> --set '<json>'` |
| Complete from artifact | `state-patch.sh --stage <CODE> [--task-id <ID>] [--prev <CODE>] [--via <layer>]` |
| Resolve an id (read-only) | `state-patch.sh --resolve-task-id <CODE>` |
| Re-open on a correction | `state-patch.sh --task-reopen <TARGET> --from <SOURCE> [--finding-file <path\|->]` |
| Settle the parked consumers | `state-patch.sh --task-settle-stale <TARGET>` |

### Correction pair operations

The last two are the correction pair: the first re-opens one `completed` task and parks its
consumers `stale`, the second decides each parked row at that target's next completion. Guards,
exits, the consumer set and the cited-ref rule:
`skills/worktask/references/handoff-protocol.md § tasks — re-open and settle — guards and invocation`.

### Idempotency and key creation

`--task-create` is idempotent (an existing key is left untouched), `--task-block` unions and
`--task-unblock` subtracts — re-running a seed or a teardown is safe. `--task-create` is the only
op that may introduce a key; status, block, unblock and meta refuse an id that does not exist yet,
so create the task before wiring or annotating it.

## Metadata Fields

Types, ranges, defaults and the required-field rule live in § JSON Schema below — these tables add
only purpose and normative use.

### Routing fields

| Field | Purpose |
|-------|---------|
| `stage` | Stage code, unnumbered. The schema enum is the full vocabulary, not the per-run set — AR and TL tasks exist only when PL0 included them |
| `agent` | Agent to execute this task, in fully-qualified `plugin:agent` form (`corpflow:software-architector`, `apple-developer:ios-developer`); bare names are rejected |
| `model` | Model alias (fable, opus, sonnet, haiku), always passed explicitly to `Agent()`: frontmatter inheritance falls through to `CLAUDE_CODE_SUBAGENT_MODEL` when unset |

#### Model field details

`model` is an alias, not a full model id, and the model that runs can differ from it. A managed
`availableModels`/`enforceAvailableModels` allowlist can resolve a valid alias to another model
(`skills/worktask/SKILL.md § Pre-Stage Validation` step 6). `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`
overrides even the explicit alias: `skills/worktask/SKILL.md § Step 6.5b — dispatch entry completed`
backfills `dispatched_agents[].model_resolved` when the runtime reports the model that ran, and PL0
raises a plan-gate sweep item (`skills/shared/model-selection.md § Forced subagent model overrides
every pin`). Alias behaviour: `skills/shared/model-selection.md § Default Subagent Model`.

### Run & context fields

| Field | Purpose |
|-------|---------|
| `run_index` | PL0-stamped on every downstream task (same N as `planning-N.md`); resolves `<stage>-N.md` paths (`skills/worktask/references/pl0-procedure.md § Stage Artifact Naming`) |
| `context_refs` | Anchor refs the stage agent greps instead of reading whole files — § Context delivery |
| `state_file` | Path to the ledger, read by the stage agent before delegation. Mandatory — an absent `state.json` is a hard failure, not a degraded mode |

### Error & retry fields

| Field | Purpose |
|-------|---------|
| `error_file` | Auto-derived from `agent` when absent (§ error_file derivation). The stage agent reads it to see its own prior retry narrative |
| `retry_count` | Incremented on retry; resets on escalation or success |
| `fix_round` | Rounds of correction rework this task has been re-opened for. Written only by `state-patch.sh --task-reopen`; `> 0` re-arms the remediation brief for a target of any stage (`skills/worktask/SKILL.md § Step 4.6`). Distinct from `retry_count`, which counts this task's own failures |
| `error_escalated_to` | Stage code the failure escalated to when `retry_count` reached 3 |
| `escalation_counts` | Escalations attempted per edge, keyed by the full task id of the target (`{"AR0": 2}`) so a split stage's writers do not share a counter. Survives the escalation handoff that resets `retry_count`; at cap 2 the task is written `failed` with `last_error.class: "exhausted"` |

### Worktask & workspace fields

| Field | Purpose |
|-------|---------|
| `worktask_id` | Links task to worktask instance |
| `priority` | Task priority |
| `milestone_number` | GitHub milestone (megatask mode) |
| `issue_number` | GitHub issue being worked |
| `track` | Parallel track number |
| `workspace_path` | Absolute root of the tree this task is assigned to — see § workspace_path below |
| `isolation` | Always `"worktree"` on file-writing tasks (DV, and megatask per-issue AR/DR/QA); PL0 stamps it unconditionally and every reader treats it that way |
| `worktree_branch` | Branch name in the worktree. ≠ `facts.branch`, the planned host-session branch — `skills/worktask/references/handoff-protocol.md § Field notes — branch` |

#### workspace_path

Writers: `/worktask` steps 3a/4 and `/megatask`. Under `/megatask` it is the per-issue worktree,
otherwise `git rev-parse --show-toplevel` at init
(`skills/worktask/references/initialization-patterns.md § Seeded workspace_path`). Always set it:
three assigned-tree guards read it and each degrades to a silent pass when it is absent. Isolation
is not assignment — a stale worktree satisfies `isolation` and still fails these guards.

### PL0 option fields

Stamped on `tasks.PL0.metadata` by `/worktask` Step 4 (`commands/worktask.md § Step 4 — option-flag
stamping`); absent means the flag was not passed.

| Field | Writer → Reader | Purpose |
|-------|-----------------|---------|
| `with_design` | `--with-design` → PM (`pl0-procedure.md § Designer Invocation`) | `true` lets PL0 invoke `corpflow:designer`; otherwise Designer is skipped |
| `no_gh_issue` | `--no-gh-issue` → `publish-pl-issue.sh`, `mailbox.sh` | `true` suppresses GitHub issue publishing; PM copies it to every stage row |
| `embedded_commands` | Step 2 detection → DV dispatch | Comma-separated `/plugin:command` ids (`commands/worktask.md § Embedded Command Detection`) |

### Fan-out fields (DV rows)

Set on DV rows only. Canonical model, naming grammar and the single-DV case:
`skills/worktask/references/handoff-protocol.md § DV fan-out — ledger tasks`.

| Field | Purpose |
|-------|---------|
| `stream` | Kebab slug naming this row's artifact, unique among the run's DV rows. Assigned by the row's creator (PL0, or TL when TL runs) — DV never invents one. Mandatory once a run carries ≥2 DV rows; omittable for a lone DV row |
| `artifact` | The path this row writes, `.context/development-<N>-<stream>.md` (`.context/development-<N>.md` for a lone row). Planned value only: `tasks.<ID>.artifact`, stamped by `state-patch.sh --artifact` at completion, outranks it |

### Landing fields (DV rows)

Written on DV rows and read by `skills/worktask/scripts/land-artifacts.sh`. Declarations, passes and
refusal reasons: `skills/worktask/references/handoff-protocol.md § Landing consumed artifacts`.

| Field | Purpose |
|-------|---------|
| `produces` | Producer rows: repo-relative, post-merge paths this row `git add`s for its consumers before its completion patch. Written by PL0 or TL only |
| `consumes` | Consumer rows: `[{from: "DV<n>", paths: [path]}]`, each path one the producer lists in `produces`. The row is also `blocked_by` every `from`. Written by PL0 or TL only |

#### Landing results

| Field | Purpose |
|-------|---------|
| `landed_paths` | Consumer rows: sorted unique paths landed untracked into this row's tree. Written only by `land-artifacts.sh`; absent or `[]` is normal (§ The landed set) |
| `landed_roots` | Consumer rows: every spelling of each tree those paths landed into — the banner path, `git rev-parse --show-toplevel`, the physical root. Written only by `land-artifacts.sh`, in the same write as `landed_paths` |
| `landing_error` | `{reason, path, producer}` while a refused landing holds this row `blocked`; `null` once released |

#### The landed set

The paths landed into one tree: `landed_paths` from every row whose `landed_roots` holds that
tree, so no reader has to decide which row is the consumer. Every reader computes it with this
expression, byte for byte, always passing the tree as `--arg root`:

```jq
[(.tasks // {})[] | .metadata | select(any(.landed_roots // [] | arrays | .[]; . == $root)) | .landed_paths // [] | arrays | .[] | strings | select(test("\\A[A-Za-z0-9._@+/-]+\\z"))] | unique | .[]
```

The key is the tree that received the landing, not a row's assigned `workspace_path`: a re-pin
rewrites that path, and a copy left in the old tree must stay excluded there. An entry outside the
`[A-Za-z0-9._@+/-]` alphabet is dropped, so it never becomes a match pattern; the match is
whole-string, so an entry with a trailing newline is dropped too.

##### The landed set — each reader's root

| Reader | `$root` |
|--------|---------|
| Script transports (fn-preflight base-sanity, `skills/worktask/SKILL.md` Step 4.7a) | `land-artifacts.sh --list-landed --tree "$(git rev-parse --show-toplevel)"`. `--tree` is required (exit 2 without it); the script matches the tree's physical path |
| `fn-stream-merge.sh` | `--list-landed --tree <tree> --strict`, each stream's `<tree>` from `plan`, never a union |
| `blocked-on-dispatch.sh` (`artifact` arm) | `--list-landed --tree <workspace_path> --strict`, the parked task's `metadata.workspace_path` |
| `hooks/dv-comment-density-gate.sh` | Its physical `_root`, resolved with `cd -P` and `pwd -P` |

`--strict` fails closed on an entry the path ladder refuses instead of dropping it; the FN arm and
the artifact arm use it.

##### The landed set — each agent's root

| Reader | `$root` |
|--------|---------|
| `agents/project-manager.md` (FN scope check) | Single tree: `git rev-parse --show-toplevel`. Multi-stream arm: the stream's `<tree>` from `fn-stream-merge.sh plan` |
| `agents/technical-lead.md` (DR untracked check) | The DV row's `metadata.workspace_path` as the ledger holds it, else the orchestrator's `git rev-parse --show-toplevel` |
| Any reader with no tree to hand | `--arg root ""`, which matches no row: the set is empty, never the union over every tree |

##### The landed set — subtracting it

A reader subtracts the set from untracked entries only, enumerated file-level
(`git status --porcelain --untracked-files=all` or `git ls-files --others --exclude-standard`),
since default porcelain collapses a new directory to `?? dir/`. It never subtracts from `M`, `A` or
`D` lines: a staged landed path is a consumer violation and stays visible. An empty set is normal;
only `land-artifacts.sh` writes it, and the producer's tree ships every landed file.

### Dispatch metadata (optional)

Optional, additive fields — `permission_mode`, `add_dirs`, `mcp_config_path`,
`plugin_dir_overrides`, `dangerously_skip_permissions`, `settings_path` — each mapping 1:1 to a
`claude -p --agent` recipe flag; canonical per-field table (flag, type, in-process honouring, usage):
`skills/agent-coordination/references/headless-dispatch.md § Translation Table`. In-process the
orchestrator honours `model` (always) and `permission_mode` (audited per
`skills/agent-coordination/references/headless-dispatch.md § Permission-Mode Pinning (in-process)`);
the rest are advisory, read only by external CLI dispatchers, and the orchestrator may refuse
`dangerously_skip_permissions`.

#### Dispatch writer rules

PL0 should set `permission_mode: default` on SR/FN tasks under `--secure`/`--full` and never sets
`dangerously_skip_permissions` (CI batch only) on PL/SR/FN tasks; full rules:
`skills/worktask/references/pl0-procedure.md § Optional dispatch metadata`. `workspace_path` (always
stamped, not dispatch-optional) names the worktree a headless dispatcher `cd`s into before running
`claude -p --agent` — there is no top-level `--cwd` flag to carry it instead.

#### effort is mandatory, and the Agent call carries it

As a ledger record `effort` is required: the Step C.0a resolver
(`skills/shared/stage-contracts.md § Blocking items are resolved, not asked`) bumps it one rung, and
a per-stage override exists nowhere else. Every agent file also carries a static `effort:` key
next to `maxTurns:`, held equal to its `skills/shared/stage-codes.md § Agent Model Matrix` row by
`tests/shell/worktask/agent-effort-frontmatter.bats`; Claude Code applies that key only when a
call passes no `effort`. Since 2.1.292 the in-process `Agent()` call always passes the stamped
value as `effort` (`effort_transport: "agent-param"`), which outranks the key, so a raise, a
resolver bump or a `CORPFLOW.md § Models` override applies in-process. Only
`CORPFLOW_HEADLESS_ROUTE=on` sends it headless instead. `state-patch.sh` validates
`effort` against `EFFORT_ENUM` on `--task-create` and `--task-meta` either way.

### JSON Schema

The orchestrator should validate metadata before spawning the stage agent. Non-PL tasks require `stage`, `agent`, `model`, `effort`, `error_file`. The nine `json` blocks in this section are one schema, split for length; the last closes `properties`.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
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
the PL0 dispatch prompt (`commands/worktask.md § Step 6 — the planning prompt`).

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

## state.json Top-Level `metadata` Fields

Worktask-scoped fields at `state.json:$.metadata`, distinct from the `task.metadata` above. Canonical schema: `skills/worktask/references/handoff-protocol.md#state-json-schema`; the tables below index fields documented elsewhere in this plugin. All optional.

### Orchestrator-stamped fields

| Field | Writer → Reader | Description |
|-------|-----------------|-------------|
| `preexisting_plan` | orchestrator → PL agent | Absolute path to a user-approved plan supplied at init; PL0 adopts it verbatim and reuses its anchors |

The `/worktask` option flags are not here: they land on PL0's task metadata (§ PL0 option fields).

### Release fields

| Field | Writer → Reader | Description |
|-------|-----------------|-------------|
| `release_tag` | `state-patch.sh --ledger-meta --set '{"release_tag":"<tag>"}'` → release engineer (`changelog-from-git.sh --tag`) | The tag this release is cut under. Absent or empty ⇒ no changelog, PR or summary text names a tag |

### CI field

| Field | Writer → Reader | Description |
|-------|-----------------|-------------|
| `ci` | orchestrator, only on an explicit operator or megatask-brief instruction: `state-patch.sh --ledger-meta --set '{"ci":"disabled"}'` → FN, ST | `enabled` or `disabled`. Only the literal `"disabled"` turns CI off; absent or any other value means on, so a typo keeps CI on. Under `disabled`, FN skips `gh run watch` and writes "CI wait skipped: metadata.ci disabled" in `complete-summary-N.md`; ST marks no criterion PARTIAL for a missing CI run alone and records the flag instead. Revert with `{"ci":"enabled"}`: the merge cannot delete a key. The seed does not carry it, so a re-seeded run (new `run_index`) writes it again |

### Issue publishing field

`metadata.github_issue_url` — issue URL written by `publish-pl-issue.sh` on the run that creates the issue; it short-circuits (`already_published`) on a resume of that same run. Readers: `publish-pl-issue.sh` (idempotency), FN PR-issue-link validator (rank-1). Pattern: `^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+(#issuecomment-[0-9]+)?$`.

`state.json` is re-seeded on every fresh `/worktask`, so this field does not survive a `run_index` increment; the run-independent anchor below carries the binding across runs, so a later run comments on the existing issue instead of duplicating it (`skills/gh-issue-dedup`).

### Run-independent issue anchor

`.context/gh-issue.json` (a sibling file, not a `state.json` field) binds one `.context/` to one GitHub issue and survives `run_index` increments. Schema and protocol: `skills/gh-issue-dedup`; folder placement: `skills/task-folder-organization/SKILL.md`. Written/read by `publish-pl-issue.sh`; read by the FN PR-issue-link validator (rank-2).

## Status Values

| Status | Meaning |
|--------|---------|
| `pending` | Not started, may be blocked |
| `in_progress` | Active work |
| `completed` | Done |
| `blocked` | Waiting on an unsatisfied `blocked_by` entry, or held by a refused landing (`metadata.landing_error`); released by clearing that field, then `--task-status <ID> pending` |
| `skipped` | Dropped by dynamic sizing during PL/AR (`state-patch.sh --task-status QA0 skipped`). The entry stays as an audit record of what was sized out; terminal, and never blocks a dependent |
| `failed` | Terminally failed: retries and per-edge escalations are both exhausted, `last_error.class` is `exhausted`, and no further dispatch will be attempted. Terminal, and settles the completion loop (`skills/worktask/SKILL.md` `SETTLED`) |
| `stale` | A `completed` task parked because the work it consumed was re-opened by a correction. Written only by `state-patch.sh --task-reopen`, left only by `--task-settle-stale` |

### Status lifecycle — stale and correction semantics

`stale` holds a `completed` task while the work it consumed is redone. Its verdict, artifact and handoff stay untouched — parked, never reset — until `--task-settle-stale` moves it to `pending` or `completed`. It is neither ready (the loop filter takes `pending`) nor settled, so tasks blocked by it stay unready and the loop stays open.

### `stale` names one thing only

A row reads `stale` only because a correction re-opened its input. Two other uses of the word are
unrelated: the liveness check in `skills/worktask/scripts/stale-check.sh`, which never writes a task
status, and `--task-replay`'s `stale_dependents` field, which only reports dependents a replay may
have invalidated.

## Hook Events for Stage Monitoring

Stage-monitoring hooks are configured in the plugin's `.claude-plugin/plugin.json` or project
`settings.json`; plugin agents ignore a frontmatter `hooks` field. Canonical event catalog (subagent lifecycle, agent-teams, elicitation, matchers, payloads,
the conditional `if` field) and configuration examples:
`skills/agent-coordination/references/hook-monitoring.md § Project-Level Configuration`.

The plugin's `SessionEnd` hook, `hooks/session-end-finalize.sh`, appends one `session_end_finalize`
audit row naming every task still `in_progress` at teardown; it never mutates task status
(`skills/agent-coordination/references/hook-monitoring.md § SessionEnd finalization`).

## Agent Teams Integration

With `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` every session has one implicit team: spawn teammates
with the Agent tool's `name` parameter (`team_name` is ignored) and message them with `SendMessage`.
A plugin-defined agent spawned by name runs with its own prompt, tools, `disallowedTools` and
effort. The Agent result's `agent_id` is the teammate's agent ID; its `name@team` address is in
`teammate_id`.
Teammates coordinate through the same `.context/state.json` ledger as every other stage and can
self-claim available work. Live teammates are visible to `ListAgents`/`claude agents --json`, so a
lead resuming mid-batch uses the stage loop's pre-check
(`skills/worktask/references/resume.md § Step 0 notes — own-name & teammate visibility — agent
discovery changes`). Megatask does not use teams. Set
`"autoMemoryDirectory": ".worktask-memory/"` in settings for worktask-specific auto-memory.
