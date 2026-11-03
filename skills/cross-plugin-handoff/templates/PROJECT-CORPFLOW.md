<!--
TEMPLATE. Copy to the root of a USER PROJECT as CORPFLOW.md to override corpflow's
default plugin routing and agent models — or to ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CORPFLOW.md
to apply the same overrides to every project. corpflow reads two headings from this file,
`## Routing` and `## Models`; everything else is yours (or delete everything else).
Precedence is per heading: a heading present in the project-root file wins over the same
heading in the user-scope file as a whole; a heading the project file lacks, or leaves bare
with nothing under it, comes from the user-scope file; neither → built-in defaults. Any
content under a project heading, even a garbled table, claims it. Not to be confused with the plugin-side
CORPFLOW.md stage contract (templates/CORPFLOW.md), which sits at a sibling plugin's root and
must NOT contain a `## Routing` or `## Models` heading.

How overrides apply: rows here win over skills/shared/routing-matrix.md § Matrix, alias
by alias, resolved ONCE at worktask init into `state.routing` — edits mid-worktask take
effect on the next worktask. Overriding an entry alias does not implicitly override that
platform's role aliases; swapping a platform's plugin normally means overriding all five
(entry + architect + security-auditor + test-generator + code-fixer). A target that is
not installed falls back per routing-matrix.md § Resolution step 5 with a
`plugin_unavailable` audit row.
-->

# corpflow Project Configuration

## Routing

Keep only the rows you override; delete the rest. Targets are fully-qualified
`plugin:agent` ids. The full alias list and every default target live in corpflow
`skills/shared/routing-matrix.md § Matrix` — deliberately not copied here, so this file
never drifts from the matrix. Aliases follow `corpflow:<plugin-role>` for entry points
(`corpflow:apple-developer`, `corpflow:ai-engineer`, …) and `corpflow:<platform>-<role>`
for functional roles (`corpflow:web-code-fixer`, `corpflow:systems-security-auditor`, …).

| Alias | Target |
|-------|--------|
| `corpflow:apple-developer` | `my-org-apple:apple-developer` |
| `corpflow:apple-code-fixer` | `my-org-apple:code-fixer` |

### Contract

An override target must satisfy the plugin contract
(`corpflow skills/cross-plugin-handoff/references/plugin-contract.md § A`): entry router,
functional-role agents, handoff frontmatter schema, and — ideally — its own root
CORPFLOW.md stage contract.

## Models

Keep only the rows you override; delete the rest. Same lifecycle as `## Routing`: rows here win
over the built-in default matrix (`corpflow skills/worktask/references/stage-codes.md § Agent Model Matrix`),
row by row, resolved ONCE at worktask init into `state.models` — edits mid-worktask take effect
on the next worktask. This heading belongs to the **project-root** or **user-scope** kind of
this file only; the plugin-root CORPFLOW.md stage contract (`templates/CORPFLOW.md`) must NOT
carry it. Audit rows carry `metadata.source` (`project-override` | `user-override`) and `path`.

| Agent | Model | Effort |
|-------|-------|--------|
| `qa-engineer` | `opus` | `-` |

An empty or `-` cell inherits that agent's built-in value for the other column alone — a row
overriding only `Effort` leaves `Model` at the default. Agent is the bare corpflow basename (no
`plugin:` prefix, backticks optional).

### Validation is fail-open, row by row

A config typo must never brick a pipeline, and never silently lower a tier:

| Condition | Behaviour | Audit action |
|-----------|-----------|---------------|
| Valid row | overrides that agent | `model_override` |
| Empty or `-` cell | that cell inherits the built-in value | `model_override` |
| Agent not in the matrix | row ignored, warning names the agent | `model_override_unknown` |
| Invalid model or effort value | row ignored, warning names the cell | `model_override_unknown` |
| Heading present, header garbled, or no rows | whole section ignored, `state.models_source` stays `"matrix"` | `model_override_unparsed` |
| An agent the matrix has no built-in row for and this section does not override either | dispatch falls back to the session model, warning names the agent | `model_unresolved` |

No `## Models` heading in either the project-root or the user-scope file → all-default, no rows,
no warning.
