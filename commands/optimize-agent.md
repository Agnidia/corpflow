---
name: optimize-agent
description: Analyze and optimize existing agent definitions for clarity, efficiency, and consistency
version: 0.3.0
argument-hint: '<agent-file> | --all [--focus <area>] [--dry-run] [--report]'
allowed-tools: Read, Glob, Grep, Write
related:
  - agents/prompt-engineer.md
  - commands/create-agent.md
  - commands/prompt-audit.md
---

# Optimize Agent Command

Optimize existing agent definitions using prompt-engineering best practices.

## Options

| Option | Values | Effect |
|--------|--------|--------|
| `--all` | — | Every agent in `agents/` |
| `--focus <area>` | see § Focus Areas | One area only (default: all) |
| `--dry-run` | — | Recommend without editing files |
| `--report` | — | Emit the full optimization report |

## Examples

```
/optimize-agent <agent-file> [--focus <area>] [--dry-run] [--report]
/optimize-agent --all [--focus <area>] [--dry-run] [--report]

/optimize-agent agents/developer.md
/optimize-agent agents/qa-engineer.md --focus model
/optimize-agent --all --dry-run
/optimize-agent agents/workflow-engineer.md --focus efficiency --report
```

## Output Format

Sections in order below. `--dry-run` omits Changes Applied.

### Report skeleton

~~~markdown
# Agent Optimization Report — <agent>

## Frontmatter Findings
| Field | Observed | Required | Severity | Suggested edit |

## Current State
| Metric | Score | Status |
**Overall Score**: n/10

## Model Analysis
| Current | Recommended | Rationale | Cost delta | Quality impact |

## Findings by Area
## Recommendations
## Changes Applied
| Section | Change | Impact |

## Summary
| Metric | Before | After | Change |
~~~

### Report content rules

- **Current State** metrics, n/10 each: clarity, efficiency, consistency, model fit, tool config. Glyphs `✅ Good` / `⚠️ Improvable` / `🔴 Suboptimal`.
- **Findings by Area**: issue → before/after snippet → one-line rationale. Efficiency findings state tokens before → after (−N%).
- **Recommendations**: `Must Apply` / `Should Apply` / `Consider`; every frontmatter finding is Must Apply.
- **Summary**: Current State metrics plus token count, before vs after.

## Focus Areas

- **clarity**: purpose, boundaries, instructions
- **efficiency**: token count, redundancy, instruction density
- **consistency**: format, terminology, structure, conventions
- **tools**: tool access, permissions, integration
- **model**: model selection (haiku/sonnet/opus/fable)
- **frontmatter**: description length, hooks, effort, model, tools least-privilege — see § Frontmatter Audit
- **body**: information hierarchy, completion criteria, negation form, no-op pruning — see § Body doctrine
- **failure-modes**: see § Failure Mode Analysis

## Optimization Criteria

### Clarity

Unambiguous purpose; defined capability boundaries; explicit behavioral expectations; no overlap with another agent's responsibilities.

### Efficiency

Dense actionable instructions; no redundancy; one canonical example per behavior instead of repeated variants.

### Body doctrine

Runs on every agent regardless of `--focus`; findings land in Findings by Area. Normative source:
`agents/prompt-engineer.md § Prompt-body doctrine`; measurement procedure:
`commands/prompt-audit.md § Body Rules`.

| Check | Finding when | Fix line states |
|---|---|---|
| **Disclosure** | An H2 subtree over 200 lines whose body only *some* branches reach | The reference file it belongs behind, and which branch reaches it |
| **Completion criteria** | A criterion fails *clarity* (done indistinguishable from not-done) or *demand* (no artifact named to check it against) | The artifact it is checked against |
| **Negation form** | A `DO NOT` aimed at any `§ Form to failure` row but "knows the rule, skips it under pressure" | The correct form — positive recipe, REQUIRED template slot, or observable-predicate conditional |
| **No-op pruning** | An instruction the agent's matrix-resolved model already obeys by default | Deletion of the whole sentence, never a rewording |

#### Body doctrine — the model-conditioned rows

These three resolve the model from `skills/shared/stage-codes.md § Agent Model Matrix`.

| Check | Finding when | Fix line states |
|---|---|---|
| **Model-conditioned** | An instruction collides with a documented behaviour of the agent's resolved model — per-alias list in `skills/shared/model-prompting.md` | Deletion, citing the vendor page that canon file names |
| **Scope explicitness** | On a `sonnet` agent, an instruction names one item where the agent's scope covers a set | The scope — `every`, `each`, the named set — never added emphasis |
| **Emphasis inflation** | An emphasised rule with no recorded failure behind it | Downgrade to the plain imperative; the rule itself stays |

#### Body doctrine — guards

An existing `## Constraints (DO NOT)` block is reported, never rewritten in place: the finding is
advisory and `--dry-run` semantics apply to it even without the flag, because recasting constraint
blocks is its own worktask.

A model-conditioned finding is subject to the two guards in `commands/prompt-audit.md § Body rule 5
— the two guards`: a completion criterion that names an artifact is not a verification instruction.

### Model Selection

Evaluate model fit against the canonical cost tiers and stage→model mapping: `skills/shared/model-selection.md`, `skills/shared/stage-codes.md`.

### Frontmatter Audit

Runs on every agent regardless of `--focus`; findings block on the Must Apply tier. Rubrics: `skills/shared/model-selection.md § Cost Tiers`, `skills/agent-coordination/references/hook-monitoring.md`.

#### Frontmatter audit — identity (P0)

| Field | Audit Rule | Severity |
|-------|------------|----------|
| `name` | Globally unique and must not contain `:` — CC rejects the file (`:` is reserved for call-site namespacing, `corpflow:developer`). CC keys agents by this field, so generic stems (`developer`, `qa-engineer`, `incident-responder`) silently overwrite across plugins: cross-check `apple-developer:`, `security-scanning:`, `debugging-toolkit:` stems, prefer `<plugin>-<role>`. | P0 (`:`) / P1 (collision) |
| `description` | ≤250 characters, measured with `awk -F'description: ' '/^description:/{print length($2)}'`; report exact count, suggest a 240-char rewrite for headroom. | P0 |

#### Frontmatter audit — model and effort (P0)

| Field | Audit Rule | Severity |
|-------|------------|----------|
| `model` | Must be absent — model selection stays a per-dispatch `Agent()` argument (`skills/shared/stage-codes.md § Model alias notes`). Flag a `model:` key in any definition frontmatter as P0; fix is deletion. | P0 |
| `effort` | Required, equal to the agent's Effort cell in `skills/shared/stage-codes.md § Agent Model Matrix` (`§ Static effort and dispatch overrides`; `agent-effort-frontmatter.bats` holds the parity). Missing or unequal is P0; fix is the matrix value. | P0 |

#### Frontmatter audit — tools (P1)

| Field | Audit Rule | Severity |
|-------|------------|----------|
| `tools` | Least-privilege explicit list, cross-checked against the agent's documented constraints. Flag: bare `Bash` (needs sub-matchers like `Bash(git:*)`); `Bash(*)`/`Read(*)`; `Write`/`Edit` on review-only agents (DR/SR/QA); single-segment `dir/**` (cwd-anchored — any-depth needs `**/dir/**`); `Write(path)`/`NotebookEdit(path)`/`Glob(path)` (startup warning — use `Edit(path)`/`Read(path)`). Scoped wildcards are fine: `WebFetch(domain:*.example.com)`, `Read(secrets-*/config.json)`. | P1 |

#### Frontmatter audit — hooks (P1)

| Field | Audit Rule | Severity |
|-------|------------|----------|
| `hooks:`, `mcpServers:`, `permissionMode:` | Must be absent: Claude Code ignores all three when it loads an agent from a plugin, so they parse and never run. An agent-scoped hook goes in `.claude-plugin/plugin.json` under `SubagentStart`/`SubagentStop` with an anchored `^corpflow:<name>$` matcher, as the PL/FN/ST `hooks/agent-stop.sh` entries do. Fix: move the hook there, or delete the field. | P1 |

#### Frontmatter audit — execution scope (P2)

| Field | Audit Rule | Severity |
|-------|------------|----------|
| `maxTurns` | Proportional to role: coordinators (DV, AR) ≥60; reviewers (DR, SR) 30–60; QA 80 (full-suite runs); one-shot haiku-tier ≤30. | P2 |
| `disallowedTools` | Suggest (never block) on review-only agents, e.g. DR with `Write, Edit, mcp__XcodeBuildMCP__test_*`. | P2 |
| `isolation: worktree` | Required on agents that mutate the working tree across split runs (DV, code-fixer). Flag if the agent has both `Edit` and git-mutating Bash matchers. | P2 |

#### Frontmatter audit — optional fields

| Field | Audit Rule | Severity |
|-------|------------|----------|
| `context: fork` | A forked skill runs in the background by default; `background: false` opts out. Flag when the caller needs its result inline rather than a completion notification. | P2 |
| booleans | Frontmatter booleans accept `yes`/`no`/`on`/`off`/`1`/`0` (case-insensitive) alongside `true`/`false`. Flag only inconsistent spellings within one file. | P3 |

### Failure Mode Analysis

With `--focus failure-modes`, classify observed failures: instruction misunderstanding (role/task confusion), output format errors, context loss (long-conversation drift), tool misuse, constraint violations, edge-case handling.

Where a class recurs, fix it in the form that class takes — `agents/prompt-engineer.md
§ Form to failure`. A wrong output shape takes a positive recipe; a missing element takes a
REQUIRED slot in the template being filled in.

Don't answer a recurring class with a generic self-check block ("Before responding, verify:
output matches format…"): `skills/shared/model-prompting.md § The verification line is narrower
than it looks` makes it a deletion on `opus`, where effort rather than prompt text sets how much the
model thinks, and half the agents resolve to `opus`. A criterion that names an artifact stays —
that is the completion-criteria row.
