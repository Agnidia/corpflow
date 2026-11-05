---
name: optimize-command
description: Analyze and optimize existing command definitions for usability, consistency, and completeness
version: 0.3.0
argument-hint: '<command-file> | --all [--focus <area>] [--dry-run] [--report]'
allowed-tools: Read, Glob, Grep, Write
related:
  - agents/prompt-engineer.md
  - commands/create-agent.md
  - commands/optimize-agent.md
  - commands/prompt-audit.md
---

# Optimize Command

Optimize existing command definitions using prompt-engineering best practices.

## Options

| Option | Values | Effect |
|--------|--------|--------|
| `--all` | — | Every command in `commands/` |
| `--focus <area>` | see § Focus Areas | One area only (default: all) |
| `--dry-run` | — | Recommend without editing files |
| `--report` | — | Emit the full optimization report |

## Examples

```
/optimize-command <command-file> [--focus <area>] [--dry-run] [--report]
/optimize-command --all [--focus <area>] [--dry-run] [--report]

/optimize-command commands/create-agent.md
/optimize-command commands/estimate.md --focus options
/optimize-command --all --dry-run
/optimize-command commands/test-plan.md --focus examples --report
```

## Output Format

Report skeleton — sections in this order:

~~~markdown
# Command Optimization Report — /<name>

## Frontmatter Findings
| Field | Observed | Required | Severity | Suggested edit |

## Current State
| Metric | Score | Status |
Rows: Usage Clarity, Options, Examples, Output Format, Integration, Body. **Overall Score**: mean.

## <Area> Improvements        (one per scored area, Current → Recommended + **Changes** list)
Options / Output Format use `| Option | Status | Issue | Recommendation |`.

## Recommendations
Must Apply / Should Apply / Consider — numbered, most impactful first.

## Changes Applied
| Section | Change | Impact |

## Summary
| Metric | Before | After | Change |
~~~

### Output Format — content rules

- Score every area even when `--focus` narrows the edits; the reader needs the baseline.
- Scoring scale is n/10 with a status glyph: ✅ Good/Excellent (≥8), ⚠️ Improvable (6–7), 🔴 Insufficient (≤5).
- Quote the command's current text verbatim before the recommended replacement.
- Frontmatter findings come first and are blocking (Must Apply).
- `--dry-run` omits `## Changes Applied` and the Summary "After" column.

## Focus Areas

`--focus` values `usage`, `options`, `examples`, `output`, `integration` and `body` each narrow the pass to the matching row of § Optimization Criteria. `--focus frontmatter` runs only § Frontmatter Audit.

## Optimization Criteria

| Area (`--focus`) | Criteria |
|------|----------|
| `usage` | § Examples opens on the synopsis line, with every argument shown and optional vs required marked; no separate `## Usage` restating it |
| `options` | § Options is a table; every option documented with its type, enum values and default; purpose clear from the Effect column |
| `examples` | Minimum 3 diverse examples; cover common use cases; show option combinations; realistic values |
| `output` | Output format structured and parseable; all fields documented; status indicators consistent; actionable information |
| `integration` | `related:` frontmatter lists the related commands and agents; worktask stage use noted where the command has one |
| `body` | Passes `commands/prompt-audit.md § Body Rules`; commands carry no model, so the model-conditioned rules 5–6 do not fire |

### Frontmatter Audit

Runs on every command regardless of `--focus`.

#### Frontmatter Audit — P0 fields

| Field | Audit Rule | Severity |
|-------|------------|----------|
| `description` | ≤250 characters, measured as in `/optimize-agent`. | P0 |

#### Frontmatter Audit — P1 fields

| Field | Audit Rule | Severity |
|-------|------------|----------|
| `allowed-tools` | Explicit list with Bash subcommand scoping (`Bash(git:*)`, `Bash(gh:*)`, `Bash(swift test:*)`); bare `Bash` only when the command's purpose is general shell access. Flag `Write` declared without `Read` (likely incomplete). | P1 |
| `argument-hint` | Matches the flag surface in § Options and the § Examples synopsis: flag each `--<flag>` the hint omits. Square brackets for optional positional, angle brackets for required. | P1 |
| `description` trigger phrase | Include a recognised trigger phrase (`Use when …`, `Use after …`, `Use PROACTIVELY when …`, `Auto-loads when …`, `Reference when …`, `Apply for …`) so the model can decide whether to invoke. Exempt: `disable-model-invocation: true` (slash-only) and `paths:` frontmatter (path-triggered) — neither is invoked from its description. | P1 |

#### Frontmatter Audit — P2 consistency checks

| Field | Audit Rule | Severity |
|-------|------------|----------|
| `$ARGUMENTS` substitution | Body references `$ARGUMENTS` → `argument-hint` is non-empty. Body has no `$ARGUMENTS` but hint is set → suggest removing the hint. Unmatched `$1`/`$2` placeholders survive verbatim in bodies (not silently stripped), so positional forms are safe to audit literally. | P2 |
| Option-to-example coverage | Every `--option` in § Options appears at least once in § Examples; flag each one missing as "missing example for `--<flag>`". | P2 |
| Output-format consistency | Output samples must match the schema declared in prose — e.g. flag a command claiming "JSON output via `--format json`" whose Output Format shows only Markdown. | P2 |
| Related links | `related:` entries and paths cited in the body must resolve. Flag dead links. | P2 |
