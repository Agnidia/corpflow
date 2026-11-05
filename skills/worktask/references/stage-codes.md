---
name: stage-codes
---

# Stage Codes Reference

Single source of truth for worktask stage codes.

## Agent Model Matrix

Every agent's default model and effort, one row per `agents/*.md`. The stage tables map a code
to its agent; the pair lives only here. Extracted by `model-matrix-lib.sh` and resolved via
`model_resolve`, with `CORPFLOW.md § Models` as the override (project root, else user scope:
`routing-matrix.md § Resolution`). See § Model and Effort Lookup for the join.

| Agent | Model | Effort |
|-------|-------|--------|
| designer | sonnet | medium |
| developer | opus | high |
| ethics-reviewer | opus | xhigh |
| incident-responder | opus | high |
| product-manager | opus | high |
| project-manager | sonnet | medium |
| prompt-engineer | opus | xhigh |
| qa-engineer | sonnet | medium |
| release-engineer | sonnet | low |
| security-reviewer | opus | xhigh |
| software-architector | opus | high |
| stakeholder | sonnet | low |
| team-lead | sonnet | medium |
| technical-lead | opus | high |
| technical-writer | haiku | low |
| workflow-engineer | sonnet | medium |

## Primary Stages (11-Stage)

| Code | Stage | Agent |
|------|-------|-------|
| PL | Planning | product-manager |
| AR | Architecture | software-architector |
| TL | Team Lead | team-lead |
| DV | Development | developer |
| DR | Developer Review | technical-lead |
| SR | Security Review | security-reviewer |
| QA | QA Testing | qa-engineer |
| DC | Documentation | technical-writer |
| RE | Release Engineering | release-engineer |
| FN | Finalization | project-manager |
| ST | Stakeholder | stakeholder |
| IR | Incident Response | incident-responder |

### Routing and test-execution notes

- DV defaults to `developer`. For plugin worktask-infrastructure scope
  (`skills/worktask/scripts/*.sh`, the stage state-machine, `hooks/**`) PL0 routes DV to
  `workflow-engineer`: `skills/worktask/references/stage-codes.md#dv-infrastructure-routing`.
- Which agents may execute tests (as opposed to build only) is canonical in
  `skills/worktask/references/testing-strategy.md § Test-Execution Authority`.

### Side-effect-bearing stages

These stages act outside the ledger when they complete, so re-running one can produce a second
commit, PR or tag for one unit of work. `state-patch.sh --task-replay --cascade` traverses them
but never resets them as dependents; the script mirrors this list in one constant, and a bats
parity test keeps the two in step. A directly named `--task-replay FN0` is still reset, with or
without `--cascade` (an explicit id is the user's instruction), but warns.

| Code | External side effect on completion |
|------|------------------------------------|
| FN | Commits, pushes, and opens the pull request |
| RE | Tags the release and publishes artifacts |

## Model and Effort Lookup

The orchestrator passes both `model` and `effort` when spawning a stage agent, and stamps both
onto `tasks.<ID>.metadata`. Two-hop join: § Primary/Support Stages resolve a code to its agent,
§ Agent Model Matrix resolves that agent to its pair. PL0 does the join itself via
`model-matrix.sh --resolve <agent>` and pastes the pair into `--task-create`'s `--metadata`;
`--task-create` reads neither table. The same call resolves PL0's own pair (`/worktask` Step 4)
and any stage row AR adds. § Secure overrides can then replace the pair.

`effort` is stamped because the Step C.0a resolver dispatches one rung above the item that
raised it (`skills/worktask/references/contracts/sweep-boundaries.md § Blocking items are resolved, not asked`), and only the ledger
holds the tier that actually ran.

### Secure overrides

Under `--secure` or `--full`, a row here replaces its stage's resolved model and effort
outright, so a pair a project raised through `CORPFLOW.md § Models` is lowered back to this row
if this row is lower. A stage with no row keeps its resolved pair. PL0 stamps the override
through its default-writer rows (`skills/worktask/references/pl0-procedure.md § Default writer
rules`) with a plain `--task-meta` write, no `--raise-only`. DC is here because a secure run's
DC turns option-gate findings into typed corrections, which needs more judgement than its
default tier.

| Code | Condition | Model | Effort |
|------|-----------|-------|--------|
| DC | `--secure` / `--full` | sonnet | medium |

## Support Agents (On-Demand)

| Code | Agent | Invoked By |
|------|-------|------------|
| DS | designer | PL, AR, DV, QA |
| TC | technical-lead | AR, TL, DV, QA |
| ET | ethics-reviewer | Any stage |
| PE | prompt-engineer | Agent optimization |
| WE | workflow-engineer | Worktask troubleshooting |

Support agents own no worktask stage; they are spawned on demand with the Agent tool.

### Handoff Protocol exemption

Owning no stage artifact means owning no ledger write, so `designer` and `prompt-engineer`
carry no `## Handoff Protocol` / `### State Patch` section; that absence is correct, not drift.
Three support rows are not exempt: `technical-lead` also owns DR and `workflow-engineer` takes
DV0 under the routing override above, so both carry the section; `ethics-reviewer` writes
`ethics-review-N.md` and patches state like a stage owner. Canonical rule and full exemption
list: `commands/create-agent.md § Handoff Protocol`.

### Model alias notes

The Model column uses aliases (`opus`, `sonnet`, `haiku`); a full model id would also be valid,
but aliases stay portable across providers. No agent file carries its own `model:` key — model
selection stays a per-dispatch `Agent()` argument (sw-PL1-1, `planning-1.md#elicitation-sweep`).

#### Static effort and dispatch overrides

Every agent file carries an `effort:` key next to `maxTurns:`, equal to this row's Effort cell;
the matrix stays the only place a tier is *decided*, the file is where Claude Code reads the
static one from, and a parity test holds the two together
(`tests/shell/worktask/agent-effort-frontmatter.bats`). A per-dispatch deviation from that static
tier (a default-writer stamp, a resolver bump, a `CORPFLOW.md § Models`/`state.models` override)
rides the `Agent` tool's `effort` parameter in-process (2.1.292), or routes headless when the
operator opts in — `skills/agent-coordination/references/headless-dispatch.md § Effort route and
transport`.
Alias resolution, the Fable 5 credit gate, managed-allowlist resolution and the effort
precedence chain are canonical in `skills/shared/model-selection.md § Effort frontmatter and
caps`.

## Agent Frontmatter Fields

| Field | Type | Purpose |
|-------|------|---------|
| `effort` | enum (`EFFORT_ENUM`) | Static per-agent tier Claude Code applies while this agent is active; equal to the matrix row below, enforced by `tests/shell/worktask/agent-effort-frontmatter.bats` |
| `maxTurns` | number | Limit agent turn count |
| `disallowedTools` | comma-separated | Block specific tools from the agent |
| `initialPrompt` | string | Auto-submitted first turn when the agent runs as the main session (`--agent`) |
| `experimental.cacheTtl` | `"5m"` / `"1h"` | Per-agent prompt-cache TTL, applied only when no subagent TTL setting is configured (`skills/cost-optimization/SKILL.md § Finer-grained TTL controls`) |

`tools:` and `disallowedTools:` are enforced in `--print`/SDK runs as in interactive ones.

### Agent Frontmatter Fields (continued)

Claude Code ignores these three when it loads an agent from a plugin, which every
`agents/*.md` here is, so none of them may appear there. A hook scoped to one agent is a
`.claude-plugin/plugin.json` `SubagentStart`/`SubagentStop` entry with the matcher
`^corpflow:<name>$` (the PL/FN/ST `hooks/agent-stop.sh` wiring is the example):

| Field | Type | Purpose |
|-------|------|---------|
| `permissionMode` | string | Permission mode for the agent |
| `mcpServers` | YAML map | MCP servers available to the agent |
| `hooks` | YAML map | Lifecycle hooks scoped to the agent |

### Skill, command, and output-style frontmatter

- Skills and slash commands may declare `effort` and `disallowed-tools`, scoped to that
  skill/command's invocation.
- Plugin skills are named by frontmatter `name`, not directory basename, so every `SKILL.md`
  needs an accurate `name:`. Skills also honor `context`, `agent` and `paths` (globs that limit
  when the skill activates, e.g. `- "src/**/*.swift"`).
- Output styles honor `keep-coding-instructions`, which preserves coding instructions across
  style changes.

## Worktask Pipelines

Pipeline shapes and roles: `skills/worktask/references/worktask-stage-context.md#pipelines`.

## Subject Numbering

Task subjects use `[CODE][N]:` with a 0-based index per stage code: `PL0`, `AR0`,
`DV0`/`DV1`/`DV2` when developers split, `DR0` (always present after DV), `QA0`/`QA1`. PL is a
singleton and is always `PL0`.

- N increments per seeded task for the same stage code
- The `stage` metadata field stays unnumbered (`"DV"`, not `"DV0"`)
- `metadata.agent` names the executing agent; `metadata.model` the model alias passed to the
  Agent tool (§ Model and Effort Lookup)

## Stage Artifacts

| Code | Artifact |
|------|----------|
| EX | exploration.md |
| PL | planning-N.md |
| AR | architecture-N.md |
| TL | coordination-N.md |
| DV | development-N.md |
| DR | developer-review-N.md |
| SR | security-review-N.md |
| QA | testing-N.md |
| DC | documentation-N.md |
| RE | release-N.md |
| FN | complete-summary-N.md |
| ST | retrospective-N.md |
| IR | incident-N.md |
| ET | ethics-review-N.md |

N inherits from PL0's `planning-N.md`: `skills/worktask/references/pl0-procedure.md § Plan File
& Run Index Naming`.

## DV infrastructure routing

Read when PL0 selects a DV agent for plugin infrastructure changes.

The DV0 default `corpflow:developer` routes platform app-code. Route DV to `metadata.agent: "corpflow:workflow-engineer"` (model `opus`, error_file `.context/errors/workflow-engineer.md`) when the change touches executed worktask-infrastructure in the plugin tree: `**/*.sh`, `**/*.bats`, `hooks/**`, and the JSON those scripts read. The anchor is that tree, not the extension — a product repo's shell or CI script is platform code and keeps the default route (bash → `system-developer` via `corpflow:developer`). Platform/app code stays `corpflow:developer` or its platform variant; a mixed worktask splits DV sub-tasks by scope and routes each independently.

###### Markdown routes by role, never by directory

Prompt prose under `skills/worktask/**` stays with the prompt-asset owner. The exception is an `.md` that is the normative spec of a script's or the ledger's contract — ledger keys, CLI flags, exit codes — which is infrastructure regardless of extension.

###### Worked example

A `publish-pl-issue.sh` change → DV0 `workflow-engineer`, DR0 `technical-lead`, QA0 `qa-engineer`.
