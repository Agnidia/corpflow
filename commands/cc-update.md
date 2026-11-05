---
name: cc-update
description: Update plugin agents, commands, and skills with new Claude Code features, including cross-session/cross-plugin comms surfaces and new flags that deserve state-ledger fields, then sync MEMORY.md and README.md version tracking
version: 0.3.0
argument-hint: '<version> [--notes <url|text>] [--scope agents|commands|skills|all] [--agent <name>] [--command <name>] [--dry-run] [--memory-only] [--bump-min] [--force] [--worktask-impact-only]'
allowed-tools: Read, Glob, Grep, Write, Edit, WebFetch, Bash(curl:*), Bash(jq:*), Bash(claude agents:*), Bash(claude --version)
related:
  - agents/prompt-engineer.md
  - commands/optimize-agent.md
  - commands/optimize-command.md
  - commands/prompt-audit.md
  - skills/agent-coordination/SKILL.md
  - skills/agent-coordination/references/headless-dispatch.md
  - skills/agent-coordination/references/hook-monitoring.md
  - skills/cross-plugin-handoff/SKILL.md
  - skills/worktask/references/stage-codes.md
  - skills/worktask/references/state-ledger.md
  - skills/worktask/references/handoff-protocol.md
  - skills/worktask/references/resume.md
---

# Claude Code Plugin Update Command

Read the release notes (auto-fetched or `--notes`), map the new capabilities to affected plugin
files, run the three standing passes, apply the updates, then sync MEMORY.md version tracking and
the README.md min version.

The three passes — Worktask Efficiency Analysis, Communication Surfaces Watch, Ledger Field Review —
run on every invocation, `--dry-run` included, where they preview the wins before any file is
touched. Only `--memory-only` skips them, because it bypasses file analysis by design. No flag turns
them on; `--worktask-impact-only` only narrows the output.

## Options

| Option | Values | Effect |
|--------|--------|--------|
| `<version>` | `X.Y.Z` (e.g. 2.1.77) | CC version to integrate (required, positional, no default) |
| `--notes <url\|text>` | URL or raw text | Release notes source (default: auto-fetch from GitHub releases) |
| `--scope <scope>` | `agents`, `commands`, `skills`, `all` | Files to update (default: `all`) |
| `--dry-run` | — | Preview proposed changes; write nothing (default: off) |
| `--memory-only` | — | MEMORY.md tracking only; skips file analysis (default: off) |
| `--agent <name>` | agent file basename (e.g. `developer`) | Restrict to one agent file (default: every agent in scope) |
| `--command <name>` | command file basename (e.g. `prompt-audit`) | Restrict to one command file (default: every command in scope) |

### Override options

| Option | Values | Effect |
|--------|--------|--------|
| `--bump-min` | — | Force the README.md min-version bump without breaking changes (default: off) |
| `--force` | — | Proceed when `<version>` is older than the current min (default: off) |
| `--worktask-impact-only` | — | Emit just the `## Worktask Efficiency Impact` table; no file edits (default: off) |

## Examples

```
/cc-update <version> [--notes <url|text>] [--scope agents|commands|skills|all] [--agent <name>] [--command <name>] [--dry-run] [--memory-only] [--bump-min] [--force] [--worktask-impact-only]
/cc-update 2.1.77 --notes https://github.com/anthropics/claude-code/releases/tag/v2.1.77
/cc-update 2.1.77 --dry-run                    # preview impact first
/cc-update 2.1.77 --memory-only                # after manual agent edits
/cc-update 2.1.77 --agent developer            # one file; --command prompt-audit for a command
/cc-update 2.1.77 --scope agents --notes "New Elicitation hook; agents inherit model"
/cc-update 2.1.70 --force                      # older than the recorded min version
/cc-update 2.1.260 --dry-run --notes "claude agents run gains --idle-timeout <s>"   # ledger preview
```

## Output Format

One markdown report, `# Claude Code Update Report — v<VERSION>`, sections in this order: Release
Summary, Feature Extraction, Worktask Efficiency Impact, Communication Surfaces, Ledger Field
Review, Impact Mapping, Files Modified, MEMORY.md Update, README.md Min Version Update, Summary,
Next Steps.

### Output Format — sections

| Section | Content |
|---------|---------|
| `## Release Summary` | `Field \| Value`: CC Version, Installed CLI (`claude --version`, or `not probed`), Previous Min Version (from README.md), Notes Source, Scope, Dry Run, Files Scanned |
| `## Feature Extraction` | `Feature \| Category \| Impact Level` — category per Feature Category Mapping; impact High/Medium/Low |
| `## Worktask Efficiency Impact` | `Feature \| Axis \| Verdict \| Improvement (mechanism)` — Behavioral rows first, then Doc-only, then N/A, one row shape throughout |
| `## Impact Mapping` | `### High/Medium/Low Impact` groups; per feature a `#### <feature> — <files>` block with **Why affected** and **Proposed changes** (`path — change` per file), detail decreasing by tier |

### Output Format — sections (comms, ledger)

| Section | Content |
|---------|---------|
| `## Communication Surfaces` | `Feature \| Surface \| Effect \| Files \| Verdict` — surface ∈ cross-session/cross-agent/cross-plugin; effect names what becomes observable or reachable; min-CC candidates marked `⚠ min-CC`. Followed by a `Re-check \| Status \| Evidence` table closing the four standing obligations (`confirmed` / `still unconfirmed`) |
| `## Ledger Field Review` | `Flag/key \| Source \| Decision \| Field \| Files` — source ∈ CLI/frontmatter/tool param/JSON row; decision per the Ledger table; `Field` is the exact `task.metadata.<name>` or `—` |

### Output Format — sections (cont.)

| Section | Content |
|---------|---------|
| `## Files Modified` | `File \| Status \| Changes`; status `✅ Updated` or `⏭ Skipped` (with the reason) |
| `## MEMORY.md Update` | Rules below, plus `Field \| Before \| After` for the integrated band and min required version |
| `## README.md Min Version Update` | `Field \| Before \| After \| Reason` for the badge line and the Requirements row |
| `## Summary` | `Metric \| Value`: features extracted, comms entries, ledger fields proposed, re-checks confirmed/unconfirmed, files updated, files unchanged, MEMORY.md updated, min version transition |
| `## Next Steps` | The steps below |

### Output Format — MEMORY.md rules

MEMORY.md here means the repo-root `MEMORY.md` (version tracking), never the auto-memory index at
`~/.claude/projects/<slug>/memory/MEMORY.md` — that directory receives only band files (Batch step
4). It is a lean rolling file (~5KB hard cap); trim before writing, since an oversized write errors
explicitly rather than truncating silently. Update only:

1. `- Plugin version: **X.Y.Z** (<one-line summary>)` — keep that exact shape; release tooling parses it.
2. The `Claude Code latest integrated band` line.
3. One new or extended `## CC Feature Band Index` row — narratives live only in the band file (Batch step 4).
4. One prepended `## Release History` line, `- YYYY-MM-DD: vX.Y.Z — Claude Code {VERSION} update ({N} files, key changes)` (≤25 words); enforce the 12-row cap by deleting the oldest.

### Output Format — Next Steps

1. Review: `git diff agents/ commands/ skills/ README.md`
2. `/prompt-audit --agents` to verify consistency
3. Outside a worktask, commit last: `#N chore: update plugin for Claude Code v<VERSION> features`
4. Under `/worktask`: skip step 3 and hand back to the orchestrator — DR reviews the diff, QA validates frontmatter.
   Never self-commit inside a worktask; FN (or the user, in compressed worktasks) owns the commit.
5. Sibling follow-ups (only when the CORPFLOW.md template changed): one line per sibling plugin
   `CORPFLOW.md`, naming the template anchor to mirror.

## Version Source

`README.md` carries the min version twice: the badge line under the title (`**Plugin X.Y.Z ·
Requires Claude Code A.B.C+**`) and the `| **Claude Code A.B.C+** | …` row of the Requirements
table; `MEMORY.md` mirrors it as `Claude Code min required`. The badge value is the "previous min".
Bump all three together when updated files depend on new or newly-required CC capabilities, or on
`--bump-min`; otherwise keep them and say so in the report.

## Batch Worktask

Multi-version updates (e.g. 2.1.77 through 2.1.86):

1. Run `--dry-run` per version; done when each version in the range has its dry-run report.
2. Apply the versions in order; done when `## Files Modified` lists every row of each report as
   updated or skipped.
3. Add or extend one MEMORY.md `## CC Feature Band Index` row (e.g. `2.1.77→2.1.86`); categorized
   narratives go only into the band file (step 4).
4. Write the band file at `~/.claude/projects/<project-slug>/memory/cc-features-<FROM>-<TO>.md`,
   reusing the prior band's categories (Model & Effort / Hooks / Tools / Plugins / Context /
   Performance / Subagents / Cross-session messaging / Agent teams / Ledger fields / Security / UX /
   Settings — applicable ones only). Unresolved re-check obligations get a `## Still unconfirmed`
   list.
5. Apply the bump policy below.
6. Outside a worktask, commit once, last. Inside one, stop after step 5: FN (or the user, in a
   compressed worktask) owns the commit.

### Plugin Version Bump Policy

Batch step 5. DV picks the tier, records the rationale in `.context/development-N.md`, and mirrors
it in the MEMORY.md `Plugin version` line and `.claude-plugin/plugin.json` if present.

| Tier | Trigger |
|------|---------|
| **Patch** X.Y.Z+1 | Additive, non-breaking, doc-only |
| **Minor** X.Y+1.0 | New agent/skill/command, expanded tools list, new optional ledger field or enum value, or backwards-compatible behavior change |
| **Major** X+1.0.0 | Breaking: renames, removed tools, altered stage codes, ledger field type change or new required field |

## Worktask Efficiency Analysis

Feature Extraction answers *which files* a feature touches; this pass answers *how it changes
worktask behavior*, and is the gate promoting a feature from documented to implemented. Score each
feature against the leverage axes, assign exactly one verdict, emit `## Worktask Efficiency Impact`,
and order Impact Mapping by it.

### Leverage Axes

- **Gates** — DV/DR/QA/SR feedback and hook blocks (`hookSpecificOutput.additionalContext`, screenshot gate, gate-feedback contract).
- **Handoffs** — stage→stage compression, schema returns, cache-prefix prompt layout.
- **Resume/recovery** — session discovery, reattach vs re-dispatch (`claude agents --json`, `waitingFor`, PostCompact).
- **Parallelism** — worktree isolation, megatask tracks.
- **Dispatch** — headless CLI flags, permission/model/effort metadata.
- **Comms** — delivery results, peer discovery (`ListAgents` / `claude agents` rows), reply routing, cross-plugin contract. Detailed by the Communication Surfaces Watch below.
- **Observability/Cost** — OTEL, audit rows, token baselines.

### Verdict per Feature

- **Behavioral** — changes pipeline *execution* (gate, handoff, resume loop, parallelism). Gets its
  own implementation task, ahead of doc-only edits; record the mechanism — which gate, handoff, or
  loop changes, and how.
- **Doc-only** — accuracy/reference update; no execution change.
- **N/A** — no worktask surface (e.g. a model alias).

## Communication Surfaces Watch

Comms entries quietly change whether a message arrives or a peer is visible, and the orchestrator's
reattach path and every cross-plugin delegation rest on them. Classify each entry by surface, route
it to the owning doc, emit `## Communication Surfaces`, and close the standing re-checks.

### Comms — surfaces and keywords

| Surface | Keywords | Owning files |
|---------|----------|--------------|
| **Cross-session** | SendMessage, ListAgents, notify_when_idle, crossSessionInbound, dialogExpiry, refused/dropped/oversized/burst_limited/held, session list truncated, inbox socket, Desktop routing, `claude agents`/`attach`/`logs`/`stop`/`rm`, Notification push, @-mention | `agent-coordination/references/cross-session-messaging.md § Cross-session reach & SendMessage authority`, `worktask/references/resume.md § Reattach rows` + `§ Reply routing`, `worktask/scripts/stale-check.sh` |
| **Cross-agent** | `Agent(name:)`, teammate, background subagent reply, maxTurns partial, CLAUDE_CODE_SUBAGENT_MODEL, fallback model, spawn depth, idle notification | `agent-coordination/SKILL.md`, `skills/worktask/references/completion-merge.md#step-65`, `shared/model-selection.md` |

### Comms — cross-plugin surface

| Surface | Keywords | Owning files |
|---------|----------|--------------|
| **Cross-plugin** | plugin command path rules, marketplace, `--plugin-dir`, plugin skills in background sessions, `Agent(plugin:agent)` grants, CORPFLOW.md, MCP servers shipped by a sibling plugin | `cross-plugin-handoff/SKILL.md`, `cross-plugin-handoff/references/plugin-contract.md`, `shared/compatible-plugins.md`, `shared/routing-matrix.md` |

### Comms — min-CC rule

An entry that turns a silent failure into a reported one (a delivery result, a discovery false
negative removed) is the class that justifies a min-CC bump — precedent: 2.1.238 non-delivery
reporting, which `resume.md § Reattach rows` branches on. Doc-only comms entries never bump the
floor.

### Comms — standing re-checks

Close each obligation as **confirmed** (field pinned, doc updated) or **still unconfirmed** (listed
in the band file) — those two statuses only. A partial result (own-name pinned, teammate row unseen)
becomes sub-rows `1a`/`1b` rather than a "partially confirmed" status, so the band file's
`## Still unconfirmed` list stays mechanical:

1. `claude agents --json` key baseline — run `claude agents --json | jq 'first | keys'` and diff against `headless-dispatch.md § Schema Versioning Watch`; teammate row `kind` and own-name key are open. Evidence names the build observed (`claude --version`), which may differ from `<version>`.
2. Background-task notification ID key (`hook-monitoring.md`, defensive coalesce).
3. `launchAck.partial` maxTurns flag name (`skills/worktask/references/completion-merge.md#step-65`).
4. `PreModelSwitch` / `SessionStart`-resume payload field names (`hook-monitoring.md`, `hooks/model-switch-gate.sh` header CONFIRMED/ASSUMED split).

### Comms — sibling follow-ups

A change to `skills/cross-plugin-handoff/templates/CORPFLOW.md` implies the same change in every
sibling plugin's root `CORPFLOW.md` (touchpoint checklist in `plugin-contract.md`). cc-update never
edits outside this repo: list each sibling file under `## Next Steps` as a follow-up, with the
template anchor that changed.

## Ledger Field Review

Every new CLI flag, agent-frontmatter key, tool parameter, or `claude agents --json` row key is a
candidate for the workflow state: the `task.metadata` → `claude -p --agent` flag bridge
(`headless-dispatch.md § Translation Table`), the `task.metadata` schema (`skills/worktask/references/state-ledger.md`),
`facts.dispatched_agents[]` and `facts.capabilities{}` (`skills/worktask/references/contracts/ledger-root.md § state-json-schema`),
and the megatask `orchestrator.json` / `workspace.json` (`megatask/references/schemas.md`). Decide
once per candidate and emit `## Ledger Field Review`.

### Ledger — decision per new flag or key

| Decision | When | Files to touch |
|----------|------|----------------|
| **New field** | The flag changes how a stage is dispatched or resumed and PL0 can know the value up front | optional `task.metadata.<snake_case>` in `state-ledger.md` schema + purpose table; flag row in `headless-dispatch.md`; writer rule in `worktask/references/pl0-procedure.md`; `state-patch.sh` validation if enumerated |
| **Existing field** | The flag refines a field already carried (e.g. a new `effort` tier, a new `permission_mode` value) | the field's schema row, its enum in `state-patch.sh`, the flag-table row |
| **Row key** | A new/renamed key in `claude agents --json` output | key baseline + drift log in `headless-dispatch.md`; `dispatched_agents[]` reconciliation in `resume.md` and `handoff-protocol.md` |
| **None** | Operator-only or UI-only (e.g. `claude attach`, `/tasks` columns) | note in the band file |

### Ledger — rules

- New fields are optional, never required: fixtures under `tests/fixtures/worktask/` and every live
  `state.json` would fail validation. They ride behind `version` const 2
  (`handoff-protocol.md § Future work`).
- `metadata.model` never inherits agent frontmatter (`state-ledger.md`); a flag that changes
  default-model resolution (e.g. `CLAUDE_CODE_SUBAGENT_MODEL` semantics) is an **Existing field**
  note on `model`/`model_resolved`, not a new field.
- Field names are `snake_case`; the flag-table row names the exact CLI spelling; any in-process
  `Agent()` limit on a field stays documented next to its row.
- Bump: new optional field or enum value → **Minor**; type change or new required field → **Major**.

## Feature Category Mapping

Changelog entries are categorized by keyword and routed to the file types below.

### Categories — Hooks, Tools

| Category | Keywords | Affected files |
|----------|----------|----------------|
| **Hooks** | hook, PostToolUse, SubagentStart, PreToolUse, PostCompact, Elicitation, StopFailure, CwdChanged, FileChanged, TaskCreated, WorktreeCreate, PreModelSwitch, PostModelSwitch, conditional if, scheduled task, webhook, trigger delivery, task notification | agents with hook docs, agent-coordination, worktask resume reference |
| **Tools** | new tool, ExitWorktree, EnterWorktree, TaskCreate, worktree, TeamCreate/TeamDelete removed, implicit team, team_name ignored | agents with the tool in `tools:`, state-ledger |

### Categories — Model, Context, Subagents

| Category | Keywords | Affected files |
|----------|----------|----------------|
| **Model** | model alias, Opus/Sonnet/Haiku version, effort level, availableModels, /fast allowlist, model-deprecation | stage-codes, agents with full model IDs, model-selection |
| **Context** | compaction, context window, sparsePaths, worktree, circuit breaker, --fallback-model | context-compression, agent-coordination |
| **Subagents** | subagent, background agent, teammate, partial result, resume removed, implicit team, Agent(name:) spawn, pre-launch spawn classification, fg/bg nesting depth | agent-coordination, developer + project-manager agents, state-ledger |

### Categories — MCP, Cost, Frontmatter

| Category | Keywords | Affected files |
|----------|----------|----------------|
| **MCP** | MCP, elicitation, server deduplication, deferred tools, description cap, server-level disallowedTools, auth-stub tools | agent-coordination (sibling-plugin MCP servers → Comms) |
| **Cost** | token, cache, prompt cache, cost reduction, cacheTtl | cost-optimization |
| **Frontmatter** | effort, maxTurns, disallowedTools, initialPrompt, paths YAML, description cap, Tool(param:value) permission syntax, model: deprecation, experimental.cacheTtl | stage-codes, prompt-engineer agent, model-selection (dispatch-relevant keys → Ledger) |

### Categories — Comms, Ledger, Commands, Security

| Category | Keywords | Affected files |
|----------|----------|----------------|
| **Comms** | the keywords in § Communication Surfaces Watch | the owning files named there |
| **Ledger** | new `claude agents run` flag, new frontmatter key, new `Agent()` param, `claude agents --json` key, `--json-schema`, `--permission-mode` value | the files in § Ledger Field Review |
| **Commands** | slash command, /clear, /reload-plugins, Tool(param:value) permission syntax | worktask + relevant command files, agent-coordination |
| **Security** | auto mode, destructive git block, commit --amend guard, IaC destroy block, trigger delivery can't auto-approve, auth-stub tools headless, --restricted, TOCTOU, path traversal | git-conventions, resume reference, security-review-process `references/claude-code-hardening.md` |

## Integration

Used by the `prompt-engineer` agent after CC releases, manually when a release adds features worth
leveraging, and as a prerequisite for `/prompt-audit`. Standalone maintenance command with stage
code **PE**, outside the 9/11-stage worktask; cadence is within a week of each CC release —
`--dry-run` first, then apply.

## Worktask Routing

Embedded in a worktask (e.g. `/worktask /cc-update X.Y.Z`), the implementation stage routes to
`corpflow:prompt-engineer`, not the default `corpflow:developer` — cc-update is metadata and prompt
engineering, not platform code. PL0 sets `metadata.agent: "corpflow:prompt-engineer"` on the
implementation task even when the framework labels that slot DV, overriding the DV → developer
mapping for any worktask whose `metadata.embedded_commands` includes `cc-update`.

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| WebFetch unavailable or fails | In order: (a) `curl -fsSL https://api.github.com/repos/anthropics/claude-code/releases/tags/v<VERSION>`, parsing `body` with `jq`; (b) inline `--notes <url\|text>`; (c) ask the user. Never silently proceed without notes. |
| No notes for the version | Report "No notes found"; exit without changes |
| Version older than current min | Warn and skip unless `--force` |
| `--scope` yields zero changes | Report clean scan; skip the MEMORY.md update |
| Repo `MEMORY.md` missing/malformed | Recreate the lean skeleton (Version Tracking + CC Feature Band Index + Release History). Never applies to the auto-memory index — a missing `Plugin version` line there is expected, not malformed |

### Edge Cases — Comms and ledger passes

| Scenario | Behavior |
|----------|----------|
| `claude agents --json` unavailable (no CLI, no live sessions, permission denied) | Leave obligation 1 `still unconfirmed` with the reason; never guess key names from the notes text. |
| A comms entry only fixes availability (provider, OS, container) | Doc-only: update the "availability is unconditional" statement; no min-CC bump. |
| Installed CLI is newer than `<version>` (common when notes are replayed or hypothetical) | Record both in Release Summary. A key or flag the notes claim but the live build does not show is reported as `claimed by notes, not observed at <installed>` and stays `still unconfirmed` — a newer build lacking it is the sharper finding, so say that rather than calling the probe inconclusive. |

### Edge Cases — Team-Tool Removal

| Scenario | Behavior |
|----------|----------|
| Team tool removed by a band (e.g. TeamCreate/TeamDelete → implicit team) | Rewrite team/coordination docs to the new model (`Agent(name: …)` spawn, `team_name` ignored). Bump **Minor**, not Major, when the removed tools were never in any agent's `tools:` frontmatter — reference-doc corrections only, no breaking change. |
