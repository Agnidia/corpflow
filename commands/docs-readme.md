---
name: docs-readme
description: Update README files based on code changes, keeping documentation in sync with implementation
argument-hint: '[--path <dir>] [--section installation|usage|api|contributing] [--from-changes] [--validate]'
allowed-tools: Read, Glob, Grep, Write, Edit, Bash(git log:*)
related:
  - agents/technical-writer.md
  - commands/docs-audit.md
  - commands/docs-release-notes.md
---

# README Update Command

Update README files based on code changes, keeping documentation in sync with implementation.

## Options

| Option | Values | Effect |
|--------|--------|--------|
| `--path <dir>` | any directory | Update the README in that directory (default: every README found) |
| `--section <name>` | `installation`, `usage`, `api`, `contributing` | Update that section only (default: every section) |
| `--from-changes` | — | Derive updates from recent git history instead of the current tree (default: off, the current tree) |
| `--validate` | — | Report accuracy issues only; write nothing (default: off) |

## Examples

```
/docs-readme [--path <dir>] [--section installation|usage|api|contributing] [--from-changes] [--validate]
/docs-readme
/docs-readme --path packages/auth
/docs-readme --section installation --from-changes
/docs-readme --validate --section api
```

## Output Format

| Section | Shape |
|---------|-------|
| `## Files Updated` | `File \| Sections Changed \| Status` — ✅ Updated or ⏭️ Skipped (nothing to change) |
| `## Changes Made` | Per file → per section: `**Before**` / `**After**` fenced snippets (or `**Added**` for new content), then a one-line `**Reason**` |
| `## Validation Results` | `Check \| Status \| Details` for Links, Code Examples, Version Numbers, Dependencies |
| `### Issues to Fix Manually` | Numbered list of what the command will not write itself, each carrying the corrected value |

Every change carries a `**Reason**` naming the code change that caused it.

## Generated README Structure

Sections in this order, each regenerated from its source rather than hand-written.

| Section | Generated from |
|---------|----------------|
| Title + one-line description | Package manifest (package.json, Package.swift, Gradle, pyproject.toml, …), repo metadata |
| Installation (command + required env setup) | Package manifest dependencies |
| Quick Start / Usage (smallest runnable snippet) | Code examples in tests |
| Features | Shipped capabilities |
| API Reference — per symbol: description, `Name \| Type \| Default \| Description` table, **Returns**, example | Public doc comments (JSDoc, DocC, KDoc, docstrings, …) |
| Configuration — `Option \| Type \| Default \| Description` | Config schema/types |
| Contributing | CONTRIBUTING.md template |
| License | LICENSE file |
