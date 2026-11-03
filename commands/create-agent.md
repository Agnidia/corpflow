---
name: create-agent
description: Create new agent definitions with proper structure, model selection, and best practices
argument-hint: '<name> --purpose "<description>" [--model haiku|sonnet|opus] [--template minimal|standard|comprehensive] [--tools <preset|list>] [--stage <code>] [--output <path>]'
allowed-tools: Read, Glob, Grep, Write, Edit
related:
  - agents/prompt-engineer.md
  - commands/optimize-agent.md
  - commands/prompt-audit.md
---

# Create Agent Command

Generate a production-ready agent definition with the canonical frontmatter and the required body
sections, plus its row in `skills/worktask/references/stage-codes.md § Agent Model Matrix`, which holds the
model and effort.

## Options

| Option | Values | Effect |
|--------|--------|--------|
| `--purpose <description>` | text | Agent purpose (required, no default) |
| `--model <tier>` | `haiku`, `sonnet`, `opus` | Model cell of the new matrix row (default: § Model Auto-Selection) |
| `--template <style>` | `minimal`, `standard`, `comprehensive` | Template style (default: `standard`) |
| `--tools <preset\|list>` | § Tool Presets, or a comma-separated list | Tool access (default: `standard` preset; the `minimal` template writes no `tools:` line) |
| `--stage <code>` | PL, AR, TL, DV, DR, SR, QA, DC, RE, FN, ST, IR | Worktask stage integration (default: none, a support agent) |
| `--output <path>` | path | Output path (default: `agents/<name>.md`) |

## Examples

```
/create-agent <name> --purpose "<description>" [--model haiku|sonnet|opus] [--template minimal|standard|comprehensive] [--tools <preset|list>] [--stage <code>] [--output <path>]

/create-agent "database-admin" --purpose "Database schema design, query optimization, and migration management"
/create-agent "api-designer" --purpose "REST/GraphQL API design" --model haiku --template minimal
/create-agent "security-reviewer" --purpose "Security code review and vulnerability assessment" --model opus --tools read-only
/create-agent "test-automator" --purpose "Automated test generation" --stage QA --template comprehensive
/create-agent "release-notary" --purpose "Notarization and stapling for macOS builds" --output agents/platform/release-notary.md
```

## Output Format

~~~markdown
# Agent Created: <name>

## Generated File — `agents/<name>.md`
## Matrix Row — the `| <name> | <model> | <effort> |` row written to `stage-codes.md`, or `not written: <output path>`
## Configuration — | Setting | Value | (Name, Model, Effort, Template, Tools, Stage)
## Preview — generated frontmatter block + first 500 characters of the body
## Model Selection Rationale — **Selected** + one-line reason; **Alternatives Considered**, one line per rejected tier
## Next Steps — review the file, tighten the constraints for the stack, add domain examples, then `/optimize-agent agents/<name>.md --dry-run`
~~~

## Templates

| Section | minimal | standard (default) | comprehensive |
|---|---|---|---|
| Frontmatter | name, description, effort | + tools | + tools |
| Constraints (DO NOT) | 3 items | 3-5 items | 5-7 items |
| Purpose | basic | basic | expert purpose |
| Behavioral traits, knowledge base | — | — | ✅ |
| Worktask + state-ledger integration | — | ✅ | ✅ |
| Response approach | basic | ✅ | numbered steps |
| Related agents/commands | — | ✅ | ✅ + integration points |
| Example Interactions | 5 bullets | 5-8 bullets | 5-8 bullets |
| Anti-patterns | — | — | ✅ |
| Completion Verification | — | — | optional (see § Completion Verification) |
| Handoff Protocol + State Patch | — | stage owners only | stage owners only |

## Model Auto-Selection

Without `--model`, select from purpose keywords: procedural (format, convert, validate) → `haiku`,
balanced (implement, review, design) → `sonnet`, complex reasoning (architect, optimize, research)
→ `opus`. Effort follows the model: `haiku` → `low`, `sonnet` → `medium`, `opus` → `high`.

When the output is `agents/<name>.md`, Edit `skills/worktask/references/stage-codes.md § Agent Model Matrix` to
add `| <name> | <model> | <effort> |` in alphabetical order, and write the same effort into the
frontmatter `effort:`. Any other `--output` path gets no row, because the matrix parser rejects a
row with no `agents/<name>.md` behind it; § Output Format then records `not written` and Next Steps
names the row to add after the file moves.

Model tiers and stage→model mapping: see `skills/shared/model-selection.md` and
`skills/worktask/references/stage-codes.md` (canonical).

## Tool Presets

`--tools` takes a preset name or a comma-separated tool list:

| Preset | Expands To |
|--------|-----------|
| read-only | Read, Glob, Grep |
| standard (alias: full) | Read, Glob, Grep, Write, Edit, Bash |
| orchestrator | Read, Glob, Grep, Write, Edit, Bash, Bash(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh *) |
| design | Read, Glob, Grep, Write, ToolSearch |

Cross-plugin delegation appends to any preset: `--tools full,Agent(apple-developer:ios-developer)`

## Agent Structure Guidelines

### Frontmatter (Required)

Canonical field order — every agent in `agents/` follows it:

```yaml
---
name: agent-name
description: Use PROACTIVELY for <trigger>. <Keyword sentence naming the role and domain>.
color: blue
version: 0.1.0
maxTurns: 40
effort: medium
tools: Read, Glob, Grep, Write, Edit
---
```

Optional fields keep fixed slots: `experimental.cacheTtl:` and `isolation:` between `effort:`
and `tools:`, in that order. Omit `hooks:`, `mcpServers:` and `permissionMode:`, which plugin
agents ignore; scope a hook to the agent with a `^corpflow:<name>$` `SubagentStop` matcher in
`.claude-plugin/plugin.json`. A comment explaining a narrowly-scoped grant sits immediately
above the `tools:` line it explains and moves with it.

#### Model and effort keys

`model:` is not a frontmatter field: model selection stays a per-dispatch `Agent()` argument
(`skills/worktask/references/stage-codes.md § Model alias notes`), resolved by `model-matrix-lib.sh`/`model_resolve`.
`effort:` is required and equals the new agent's Effort cell in `§ Agent Model Matrix`
(`stage-codes.md § Static effort and dispatch overrides`), so a newly-scaffolded agent needs a
matrix row, written by § Model Auto-Selection.

### Body sections

| Section | Rule |
|---|---|
| `description` | Trigger first, per `agents/prompt-engineer.md § Description grammar` (G1, G2): `Use PROACTIVELY for <trigger>. <keyword sentence>.` — e.g. "Use PROACTIVELY for query optimization or migration planning. Database specialist for schema design." |
| Purpose | Role, domain and boundaries, integration context. |
| Model fit | Write the body for the model this agent resolves to in `skills/worktask/references/stage-codes.md § Agent Model Matrix`; `skills/shared/model-prompting.md` lists what each alias needs countered, and `commands/prompt-audit.md § Body Rules (agents, commands, skills)` is the check. |
| Emphasis | Generate the plain imperative. `CRITICAL`/`MUST` is earned by a recorded failure, later. |

#### Slots that carry their own shape

Both slots are required, and so is the shape below.

| Section | Rule |
|---|---|
| Constraints (DO NOT) | First section after the frontmatter identity sentence. 3-7 bullets, each in the form its failure takes (`agents/prompt-engineer.md § Form to failure`): `DO NOT <x>` with a short because on the bullet only for "knows the rule, skips it under pressure" ("DO NOT modify production code directly" for QA agents), else a positive recipe or a `When <predicate>, <action>` conditional. |
| Example Interactions | 5-8 bullets, each a verbatim user phrasing that should route to this agent — never a description of its job. Placement: last section, or immediately before `## Worktask Integration` for a stage owner, since § Handoff Protocol stays last. |

### Completion Verification (optional)

A supplement to `skills/worktask/references/stage-contracts.md § Completion Verification`, never a restatement.
Include it only when the stage adds checks the shared contract does not cover; omit it otherwise.
Sits immediately before § Handoff Protocol.

### Handoff Protocol (stage owners only)

- Last section of the file, followed only by its `### State Patch — REQUIRED before return` subsection
- Names the `stage-contracts.md#tpl-<code>` frontmatter template and the `Prev→this` edge label; does not restate the shared contract
- State Patch subsection gives the exact `state-patch.sh --stage <CODE> --prev <PREV>` call plus a `--facts` example

#### Handoff Protocol exemptions

Do not add this section to a support agent: it asserts a ledger-write responsibility, so an agent
that owns no stage artifact must not carry it. Current exemptions, verified against
`skills/worktask/references/stage-codes.md`:

| Agent | Why exempt |
|---|---|
| `designer` | Support agent (DS). Invoked by PL/AR/DV/QA, writes no `.context/` stage artifact. |
| `prompt-engineer` | Support agent (PE). Agent-optimization work, outside the worktask ledger. |

`product-manager` is not exempt: it owns PL, so it carries the section, as a pointer into
`skills/worktask/references/pl0-procedure.md`, where its handoff and completion checklist are
canonical.

`workflow-engineer` is not exempt: it is a support agent by default, but PL0 routes DV0 to it for
worktask-infrastructure changes, so it carries a DV-scoped Handoff Protocol gated on that mode.
