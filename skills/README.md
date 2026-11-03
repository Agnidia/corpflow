# Skills Index

All available skills for the corpflow worktask plugin.

**The Description column is a human index, not a mirror of each skill's `description`
frontmatter.** Those fields are routing text under a trigger-first grammar and a 250-character
cap (`agents/prompt-engineer.md § Description grammar`); these rows are prose written for someone
scanning the table. They are expected to diverge, and a divergence is not drift to be repaired.

## Skills

### Capture, coordination & context

| Skill | Description | Effort |
|-------|-------------|--------|
| [dv-screenshot-capture](dv-screenshot-capture/SKILL.md) | DV-stage screenshot evidence for QA acceptance and DR review; platform-aware adapters (apple/web/android/cli-fallback) | medium |
| [agent-coordination](agent-coordination/SKILL.md) | Multi-agent coordination, handoffs, parallel execution, and error escalation | medium |
| [claude-constitution](claude-constitution/SKILL.md) | Constitutional principles, ethics, and behavioral guidelines for AI agent behavior | medium |
| [context-compression](context-compression/SKILL.md) | Context compression between agent handoffs preserving critical information | medium |

### Cost, export & estimation

| Skill | Description | Effort |
|-------|-------------|--------|
| [cost-optimization](cost-optimization/SKILL.md) | Cost tracking and optimization strategies for AI agent worktasks | medium |
| [cross-plugin-handoff](cross-plugin-handoff/SKILL.md) | Protocol for handoffs between corpflow worktask and external plugins | medium |
| [csv-export-templates](csv-export-templates/SKILL.md) | 13-category CSV export structure for Google Sheets import | low |
| [estimation-methodology](estimation-methodology/SKILL.md) | Complexity scoring (0-50 scale) and T-shirt sizing for project estimation | low |
| [gh-issue-dedup](gh-issue-dedup/SKILL.md) | One GitHub issue per `.context/` — later runs comment on it instead of opening a duplicate | low |
| [incident-response](incident-response/SKILL.md) | Incident classification, hotfix worktask, rollback procedures, and post-mortem templates | high |

### Incident, logging & orchestration

| Skill | Description | Effort |
|-------|-------------|--------|
| [logging-conventions](logging-conventions/SKILL.md) | Route runtime log capture to `.context/logs/` with filename conventions and cleanup patterns | low |
| [megatask](megatask/SKILL.md) | Many worktasks across a GitHub milestone or issue array (`/megatask`) — blocker DAG, priority ordering, isolated per-issue worktrees, completion-driven monitor hook | high |
| [pencil-design-worktask](pencil-design-worktask/SKILL.md) | Design mockup generation worktask using Pencil MCP tools | high |
| [preview-ensurer](preview-ensurer/SKILL.md) | Detect SwiftUI View files without previews and auto-add minimal `#Preview` blocks | medium |
| [release-engineering](release-engineering/SKILL.md) | Semantic versioning, changelog generation, and deployment readiness patterns | high |

### Preview, release & review

| Skill | Description | Effort |
|-------|-------------|--------|
| [code-comment-standard](code-comment-standard/SKILL.md) | Compact source-comment standard — WHY + contract only; budgets + ban-list; wraps code-documentation.md | low |
| [request-plan](request-plan/SKILL.md) | Context-aware plan (goal, scope, phases, effort, risks) from a request; worktask-trigger handoff | medium |
| [security-review-process](security-review-process/SKILL.md) | OWASP Top 10 checklist, supply-chain triage, secure coding | medium |
| [self-improvement](self-improvement/SKILL.md) | ST retrospective: diff-based learning from user edits → `.context/learnings.md` (approval checklist) | medium |
| [task-folder-organization](task-folder-organization/SKILL.md) | `.context/` folder structure: artifact naming + path resolution | medium |

### Self-improvement, tasks & worktask

| Skill | Description | Effort |
|-------|-------------|--------|
| [worktask](worktask/SKILL.md) | Complete staged worktask system with dynamic sizing and stage management | high |
| [worktask-testing-strategy](worktask-testing-strategy/SKILL.md) | Test strategy planning guidance for PL and AR worktask stages | medium |
| [writing-style](writing-style/SKILL.md) | ASD-STE100-derived prose standard (~80%) — short active sentences, one term per meaning, tables/diagrams over prose; wraps writing-style.md | low |

## Worktask references and assets

Worktask contracts live in `worktask/references/`; stage, planning, and attachment templates live in `worktask/assets/templates/`.

### Worktask contracts

| File | Purpose |
|------|---------|
| [stage-codes.md](worktask/references/stage-codes.md) | Worktask stage codes |
| [stage-contracts.md](worktask/references/stage-contracts.md) | Per-stage Inputs→Outputs→Validation contracts |
| [state-ledger.md](worktask/references/state-ledger.md) | State ledger (tasks{}) reference |
| [worktask-stage-context.md](worktask/references/worktask-stage-context.md) | Pipeline diagrams + one-line role per stage |

## Shared Utilities

General guidance remains in `shared/`. The `milestone-helpers/` directory also provides the `corpflow:milestone-helpers` skill.

### Standards & analysis

| File | Purpose |
|------|---------|
| [milestone-helpers/](shared/milestone-helpers/) | Milestone helpers |

### General standards

| File | Purpose |
|------|---------|
| [code-documentation.md](shared/code-documentation.md) | Comment standard (name code-comment-standard) — /// and // budgets, doc-block shapes |
| [five-whys.md](shared/five-whys.md) | Five Whys root-cause analysis |
| [git-conventions.md](shared/git-conventions.md) | Conventional Commits, PR template, git safety |
| [pandoc-ingestion.md](shared/pandoc-ingestion.md) | Rich local documents and document URLs as markdown |
| [plan-content.md](shared/plan-content.md) | Plan content: decisions, not a transcript |
| [three-stage-planning.md](shared/three-stage-planning.md) | 3-stage planning model, stage budgets, gate criteria |
| [technical-consult.md](shared/technical-consult.md) | Technical-lead TC consults: technology evaluation, debt scoring, risk categories |
| [writing-style.md](shared/writing-style.md) | Prose standard (name writing-style) — ASD-STE100 core rules, relaxations, visual-over-prose |

### Testing, routing & resolution

| File | Purpose |
|------|---------|
| [testing-strategy.md](shared/testing-strategy.md) | General testing practices and framework guidance |
| [Worktask testing](worktask/references/testing-strategy.md) | Stage execution authority and test selection |
| [test-selection-syntax.md](shared/test-selection-syntax.md) | Inline test-marker grammar for selective execution |
| [compatible-plugins.md](shared/compatible-plugins.md) | Dev-plugin registry: platform → plugin/agent routing |
| [platform-detection.md](shared/platform-detection.md) | Platform detection and long-tail routing |
| [model-selection.md](shared/model-selection.md) | Model tiers (haiku/sonnet/opus), selection criteria |
| [plugin-root-resolution.md](shared/plugin-root-resolution.md) | Resolving the corpflow plugin root |
| [figma-capture.md](shared/figma-capture.md) | Figma design capture for design/dev stages |
