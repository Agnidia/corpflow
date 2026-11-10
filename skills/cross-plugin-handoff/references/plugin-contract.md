# The corpflow Plugin Contract

This file is the normative source for integrating a plugin with corpflow. `SKILL.md`,
`plugin-protocols.md` and the registry in `skills/shared/compatible-plugins.md` implement it or
record who satisfies it; where one of them disagrees with this file, the other file is the bug.

## The seam is one file

An integrating plugin exposes one corpflow-facing file: `CORPFLOW.md` at its repository root.
Copy `../templates/CORPFLOW.md`, fill in the plugin-specific rows, and commit it. That file is the
whole contract surface.

### Why one file

Nothing else in the plugin names corpflow — not the agents, commands, skills or hooks. Without
corpflow the plugin carries one inert, deletable file, and a contract change moves one file per
plugin. Agents need no "if `.context/state.json` exists" preamble because corpflow injects the
instruction at dispatch time (§ B); an agent carrying its own corpflow preamble is a second seam,
and the second seam is the one that rots.

## A. What the plugin must satisfy

Six items. All six before the plugin is added to `skills/shared/compatible-plugins.md`.

### 1. Command set

Expose the 15 core-parity commands under the plugin namespace (list and naming grammar in
`compatible-plugins.md § Core-parity command set`). A plugin whose domain genuinely does not fit may
ship a documented exception — `ai-engineer` is the precedent — recorded in the registry, not implicit.

### 2. Agent roster

- One **entry router agent** named after the plugin (`<plugin>:<plugin>`), routing internally to its
  own specialists. The orchestrator targets the router when the specialist is ambiguous.
- Four **functional-role agents**: architect (AR consultation), security auditor (SR), test generator
  (QA), code fixer (DR remediation).
- Functional-role agents carry a plugin-unique prefix (`sys-`, `and-`, `fe-`, `be-`, `ai-`). Bare
  names such as `test-generator` collide across plugins and break `error_file` derivation — see
  `compatible-plugins.md § Naming`.

### 3. Handoff schema

Agents taking over a stage adopt the **full** frontmatter schema from
`skills/worktask/references/contracts/frontmatter.md § frontmatter-schema` (per-stage required fields,
`state.json` patching). Artifacts land in `.context/`; error narratives in
`.context/errors/<agent-basename>.md`. Findings-bearing consultations (SR, DR) end their return with
one `consultant-return.v1` object (`skills/cross-plugin-handoff/references/consultant-return-v1.md`),
and any other version is rejected.

### 4. A root `CORPFLOW.md`

The plugin's single corpflow-facing file, from `../templates/CORPFLOW.md`, carrying the stage→agent
table, the evidence declaration, and the artifact contract from the plugin's side.

### 5. Evidence declaration

Declare the plugin's `requires_screenshots` default and its Build Evidence adapter in `CORPFLOW.md`,
and add the row to `compatible-plugins.md § Handoff defaults`. UI platforms default `true` with a
capture adapter; non-UI platforms default `false` with `cli_fallback_adapter` transcripts.

### 6. AR consultation model

The architect agent is consulted, not handed ownership: it writes
`.context/<platform>-architecture.md` and returns a summary of ≤500 tokens.
`corpflow:software-architector` retains the stage and merges the result. It consults only past its
§ Consult Gate (AR) — complexity ≥31 or an explicit trigger — so most Medium and Moderate runs never reach
the architect.

## B. What corpflow guarantees in return

The contract is bidirectional. A plugin satisfying § A can rely on all of the following, and should
file a bug against corpflow rather than working around any of them.

### Guarantees

| Guarantee | Detail |
|---|---|
| **Dispatch-time injection** | Every corpflow agent delegating to a plugin agent opens the prompt with `Your plugin root is <ROOT>. Read <ROOT>/CORPFLOW.md and follow it; …` (full line: `../SKILL.md § Dispatch Injection`). `<ROOT>` is the install this session loaded, from `../scripts/resolve-sibling-root.sh` — the plugin's agents never have to remember or search for it. |
| **`.context/` ownership** | corpflow creates and owns `.context/`. The plugin writes its stage artifact and its own `errors/<agent>.md`, nothing else. |
| **`state.json` is orchestrator-owned** | The plugin patches only via `state-patch.sh` when its path is supplied, never a hand-rolled `jq` merge. If the patch fails it proceeds anyway — the `SubagentStop` hook repairs from the artifact frontmatter. |

### Guarantees — recovery and independence

| Guarantee | Detail |
|---|---|
| **Frontmatter is the safety net** | Unconditional `handoff:` frontmatter is what makes the three-layer recovery (agent → orchestrator fallback → hook) work. Artifact *filenames* are a backward-compat convenience; frontmatter is the contract. |
| **Standalone operation** | No runtime dependency on corpflow is ever required. With no `.context/` present the plugin behaves exactly as it does with corpflow uninstalled. |

## Project-level routing override

Other files also carry the name `CORPFLOW.md`, with semantics decided by location: at a
*sibling plugin's* root it is that plugin's stage contract (§ A.4); at the *user project's*
root, or at user scope (`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CORPFLOW.md`, every project), it is
configuration, of which corpflow reads two headings: `## Routing`, a `| Alias | Target |` table
whose rows win over the defaults in `skills/shared/routing-matrix.md`, and `## Models`,
per-agent model/effort overrides. Both are reserved: a plugin-side `CORPFLOW.md` never uses them
(guard note in `../templates/CORPFLOW.md`).

### Which file supplies each heading

Each heading is taken from the project-root file when it has it, else from the user-scope file
(`skills/shared/routing-matrix.md § Per-heading precedence`).

Template and creation instructions: `../templates/PROJECT-CORPFLOW.md` and
`routing-matrix.md § Project override`. Resolution happens once at worktask init and
persists as `state.routing` (`skills/worktask/references/orchestration.md § Validation check 12`).

An override replaces a platform's plugin wholesale and must still satisfy § A: it gets the
same dispatch injection and owes the same handoff schema.

## C. corpflow-side touchpoints when adding or swapping a plugin

Every file below changes in the same commit. Ordered so later edits can reference earlier ones.

> Scope: adding or swapping a plugin. Giving a registered plugin a new capability is smaller —
> take only the rows the change reaches (two plugins gaining a release engineer touched rows 1, 2, 13
> and 14) and say in the PR which rows you skipped and why.

### Registry and routing

| # | File | What changes |
|---|------|--------------|
| 1 | `skills/shared/routing-matrix.md` | Entry-alias row + four functional-role alias rows (the only copy of the target ids) |
| 2 | `skills/shared/compatible-plugins.md` | Registry row (entry alias), command-set row, handoff-defaults row |
| 3 | `skills/shared/platform-detection.md` | Marker rows in § Detection Rules; a per-platform specialization section; precedence notes if markers overlap an existing platform |
| 4 | `agents/developer.md` | `--platform` enum (Priority Order, Detection Logging, Routing Audit); common-rows table; UI/non-UI defaults sentence; agent `description`. No `tools:` edit — stage agents carry a bare `Agent` grant |

### Stage agents and handoff protocol

Rows 5–7 are mandated-copy edits validated by `tests/shell/skills/routing-matrix.bats` —
the test fails until each inline table matches the matrix.

| # | File | What changes |
|---|------|--------------|
| 5 | `agents/software-architector.md` | Per-platform architect table row |
| 6 | `agents/security-reviewer.md` | Platform→auditor subsection and checklist |
| 7 | `agents/qa-engineer.md` | Platform→generator list entry |
| 8 | `skills/cross-plugin-handoff/references/plugin-protocols.md` | Per-plugin stage→agent handoff table |
| 9 | `skills/worktask/scripts/publish-pl-issue-lib.sh`, `publish-pl-issue-selftest.sh` | Plugin-prefix regex (both occurrences in the lib) and the selftest's two leak-check greps — all four stay byte-identical to each other and to the list in `compatible-plugins.md` |

### Commands, scripts and release

| # | File | What changes |
|---|------|--------------|
| 10 | `commands/milestone.md` | Implementation / Test / Review agent-assignment tables; `--platform` flag docs |
| 11 | `commands/tech-code-review.md` | `--platform` enum |
| 12 | `skills/agent-coordination/SKILL.md` | Sub-Task Delegation table (platform-architect row); AR-collaboration note |
| 13 | `README.md` | Plugin mentions and worktask examples |
| 14 | `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `CHANGELOG.md`, `MEMORY.md` | MINOR version bump + release notes. New entries always land in `CHANGELOG.md`; `CHANGELOG-3.x.md` is a frozen archive and is never appended to |

A plain `skills/shared/*.md` reference needs no `marketplace.json` entry — only directory skills with
their own `SKILL.md` are listed in `skills[]`.

### Packaging and validation

- Run `claude plugin validate` before publishing: it reports `SKILL.md` files whose frontmatter fails
  to parse, which otherwise fail to load silently. Tooling reads `success` from `--json` rather than
  scraping the text output. It checks the plugin when its folder also holds a marketplace
  manifest, so validate the plugin manifest path, not only the marketplace.
- A plugin may declare `"."` as a `skills` path, meaning the plugin root itself.
- The `archive` source installs from a zip over HTTPS and accepts an optional SHA-256 pin. Pin the
  hash for any non-first-party marketplace entry.

#### Configure, install refusals and mods

- `claude plugin configure <plugin>` shows a plugin's options and the unset ones, and saves values
  read from stdin. An install is refused when its id differs from an installed plugin's only in `.`,
  `-`, `@` or letter case, and npm sources install from registry packages only.
- Claude Mods let a plugin change deeper behavior through hooks such as `tool.check`, `turn.step`
  and `agent.spawn`; `claude plugin validate` lists each gating hook with whether it has a `.catch`
  (`gatingHooks` under `--json`). corpflow ships no mods, and a user-installed mod that makes an
  organization's guard skip its check is unloaded.

#### Marketplace install, plugin tests and name limits

- `claude plugin install --marketplace <source>` adds the marketplace when needed, under the
  same policy checks as `marketplace add`, then installs from it.
- `claude plugin test` now fails on a failed `expect` inside a hook the test registered, or on a
  stub answer the engine refuses, instead of passing silently.
- Agent names are capped at 256 characters; a skill's or plugin file's longer `name` is ignored.
  An MCP tool name over 128 characters is left out, and an MCP error names it.
- Local (stdio) MCP servers negotiate protocol 2026-07-28 by default; `MCP_PROTOCOL_NEGOTIATION=legacy`
  opts out. A sibling plugin's stdio server that ignores the newer check connects the older way
  after one slow connect, remembered for 7 days.

#### Listing, loading and eval

- `claude plugin list --json` rows carry `errorDetails`/`noteDetails`, which tell a sibling that is
  installed but failed to load apart from one that is absent. The Skill tool draws the same line:
  a skill whose plugin failed to load is reported as a load failure, not as uninstalled. Under
  `-p`, the stream-json `system/init` `plugin_errors` entries carry `path`, naming the
  `--plugin-dir` that did not load.
#### Managed-only permission rules

- Under managed `allowManagedPermissionRulesOnly`, a sibling installed from a marketplace,
  claude.ai or npm loses its `allowed-tools` pre-approval; only a plugin from an official Anthropic
  source, or a source managed settings vouch for, keeps it. The sibling's tool calls then fall to
  the managed rules alone.
- `--plugin-dir` pointed at a folder of plugins loads every child folder with a manifest — one flag
  loads the siblings for local dev.
- Component paths that are symlinks, contain a backslash, or escape the plugin root are refused;
  directory names beginning with two dots are accepted by both the loader and `validate`.

## D. Replacing an existing plugin

1. Work through § C in one change, swapping the old plugin's rows, grants, and agent IDs for the
   replacement's. A half-swapped registry routes DV to one plugin and SR to another.
2. Verify nothing references the removed plugin:

   ```bash
   grep -rn "old-plugin:" --include="*.md" --include="*.sh" . | grep -v "\.claude/worktrees"
   ```

   Expected: no output.
3. Confirm the replacement's command set covers every command the old one was invoked with — including
   embedded commands in `skills/worktask/references/workflow.md` and stage templates.
4. Bump MINOR: a replacement changes behavior for every worktask on that platform, so it belongs in
   the CHANGELOG even though no corpflow command changed.

Always exclude `.claude/worktrees/` from edit sweeps — stale copies of `agents/` and `skills/` live
there and are not the source of truth.
