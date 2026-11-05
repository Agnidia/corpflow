---
name: milestone
description: Generate GitHub milestone tickets with agent assignments for implementation, test, and review
argument-hint: '"<description>" | --from-prd <path> [--milestone N] [--platform apple|android|web|systems|backend|ai|all] [--dry-run] [--secure] [--labels <extra>]'
# tools: bare Bash is deliberate — the milestone's repo tooling (gh, git, project scripts) is
# unknown until it is read; the bound is that it writes issues and milestone files, never source.
allowed-tools: Read, Glob, Grep, Write, Edit, Bash
related:
  - agents/product-manager.md
  - commands/product-requirements.md
  - commands/roadmap.md
---

# Milestone Tickets

Generate GitHub milestone tickets with agent assignments for implementation, test, and review. Ticket creation only — never implementation.

## Options

| Option | Values | Effect |
|--------|--------|--------|
| `<description>` | text | Feature description to decompose into tickets (required unless `--from-prd`) |
| `--milestone N` | milestone number | Use existing milestone N (default: create one from the feature title) |
| `--from-prd <path>` | PRD path (`/product-requirements` output) | Read the PRD as input (default: none, the `<description>`) |
| `--platform <p>` | `apple`, `android`, `web`, `systems`, `backend`, `ai`, `all` | Route the implementation agent (default: inferred from the codebase) |
| `--dry-run` | — | Preview tickets as markdown, create nothing (default: off) |
| `--secure` | — | Add `security-reviewer` to Review on every ticket (default: off) |
| `--labels <extra>` | comma-separated labels | Extra labels beyond the auto-assigned priority (default: none) |

## Examples

```bash
/milestone "<description>" | --from-prd <path> [--milestone N] [--platform apple|android|web|systems|backend|ai|all] [--dry-run] [--secure] [--labels <extra>]
/milestone "Add dark mode support" --milestone 3 --platform apple
/milestone --from-prd .context/planning-0.md --milestone 5 --dry-run   # any planning-N.md the PL produced
/milestone "Implement OAuth2 flow" --milestone 2 --secure
/milestone "User profile management"                       # auto-creates the milestone
/milestone "API rate limiting" --milestone 4 --labels "backend,performance"
```

## Output Format

### Dry-run

```markdown
# Milestone Tickets Preview: {Feature Title}

## Ticket 1: {title}
**Priority**: P0 · **Labels**: P0, feature
**Agents**: Implementation: `apple-developer:ios-developer` | Test: `apple-developer:test-generator` | Review: `corpflow:technical-lead`

### Body
[Full ticket body]

---

## Summary
| # | Title | Priority | Implementation | Test | Review | Dependencies |
|---|-------|----------|----------------|------|--------|--------------|
| 1 | Core theme system | P0 | apple-developer:ios-developer | apple-developer:test-generator | corpflow:technical-lead | — |
| 2 | Settings toggle | P1 | apple-developer:ios-developer | apple-developer:test-generator | corpflow:technical-lead | Ticket 1 |

Ready to create? Run without --dry-run.
```

### Live

Same summary table keyed by issue number (`#42`) instead of ticket index and without the Dependencies column, headed by `Milestone: #{N} "{title}"`, with dependencies listed below as `#43 → #42` and closing on `Next: /megatask {N}` to execute all tickets.

## Step 1 — Parse input

With `--from-prd`, extract the functional requirements, user stories, and acceptance criteria sections.

```bash
# Validate milestone exists (if --milestone provided)
gh api repos/:owner/:repo/milestones/{N} --jq '.title'

# Check existing issues to avoid duplicates
gh issue list --milestone "{title}" --json number,title
```

## Step 2 — Decompose into tickets

Split the input into discrete units along logical boundaries (separate concerns, features, layers); assign P0–P3 from dependency order and criticality; map inter-ticket dependencies; then pick agents. Each ticket must be actionable without reading the others.

## Step 3 — Implementation agent

| `--platform` | Entry alias |
|---|---|
| `apple` | `corpflow:apple-developer` |
| `android` | `corpflow:android-developer` |
| `web` | `corpflow:frontend-developer` |
| `systems` | `corpflow:system-developer` |
| `backend` | `corpflow:backend-developer` |
| `ai` | `corpflow:ai-engineer` |
| `all` / omitted | `corpflow:developer` — auto-routes to specialists at runtime, so it is the safe default whenever the platform is ambiguous |

Entry aliases resolve to a qualified `plugin:agent` id per `skills/shared/routing-matrix.md`
(project `CORPFLOW.md § Routing` override wins); the platform default is the plugin's entry
router. Write the resolved qualified id into the ticket, because bare role names collide
across plugins (`skills/shared/compatible-plugins.md § Naming`).

### Content-based overrides

When a ticket names a specific target inside a platform — macOS/watchOS/tvOS/visionOS, Swift concurrency, Compose UI, React/Vue/Svelte/Angular, CSS, C/C++/Python/Bash, API contracts, schema/query work, RAG/prompt/eval, training pipelines — assign the specialist from the marker→specialist tables in `skills/shared/platform-detection.md` instead of the platform entry agent. Automated batch fixes take that platform's code-fixer alias (`skills/shared/routing-matrix.md § Functional-role aliases`).

Platform-neutral roles stay in corpflow: documentation-only → `technical-writer`; agent/command/skill → `prompt-engineer`; design system or UI design → `designer`.

### Test and review agents

Test agent: `corpflow:qa-engineer` by default; for a platform-specific ticket, that platform's test-generator alias from `skills/shared/routing-matrix.md § Functional-role aliases` (the prefixes differ per plugin), written as its resolved qualified id like the implementation agent.

| Review trigger | Agent (corpflow) |
|---|---|
| Default | `technical-lead` |
| `--secure` or security content | `security-reviewer` |
| Architecture-level change | `software-architector` |
| Ethics-sensitive content or high risk | `ethics-reviewer` |
| Agent/prompt change | `prompt-engineer` |

Security content is judged per ticket: add `security-reviewer` to any ticket whose own description mentions auth, encryption, credentials, token, API key, certificate, permission, or keychain, even without `--secure`. One matching ticket does not add the reviewer to the rest.

## Steps 4–6 — Generate, create, summarize

Apply the ticket body template per ticket. With `--dry-run`, print the preview and stop; otherwise:

```bash
# Create milestone if needed (no --milestone flag)
gh api repos/:owner/:repo/milestones --method POST \
  --field title="{feature title}" --field state="open" --jq '.number'

# Create each ticket
gh issue create \
  --title "{type}: {ticket title}" \
  --body "{ticket body}" \
  --milestone "{milestone title}" \
  --label "P{n}"
```

Finish with the summary table and the suggested next step.

## Ticket Body Template

```markdown
## Description

[Clear, actionable description of what this ticket requires]

## Requirements

- [ ] Requirement 1
- [ ] Requirement 2

## Acceptance Criteria

Given [precondition]
When [action]
Then [expected result]

## Agent Assignments

| Role | Agent |
|------|-------|
| Implementation | `{plugin:agent}` |
| Test | `{plugin:agent}` |
| Review | `{plugin:agent}` |

## Dependencies

- Depends on: #{N} (when applicable)
- Blocks: #{M} (when applicable)

## Metadata

- Priority: P{n}
- Complexity: {low|medium|high}
```

### Template — machine-read parts

`/megatask N` builds its dependency graph from these tickets: the `P0`–`P3` label sets the
priority tiebreak, and each `Depends on` / `Blocks` keyword is read to the end of its line
(`skills/megatask/scripts/build-orchestrator.sh`), so keep the two on separate lines — on one
line, every `#N` after `Depends on` becomes a dependency and the pair turns into a false cycle.
