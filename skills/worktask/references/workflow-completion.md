# Workflow completion

Read when executing or checking workflow completion.

Procedure routing: [workflow](workflow.md).

<!-- canonical-body:start -->
## Phase 3: Post-Worktask Self-Improvement

After the loop exits (ST completed), run `orchestration.md § Post-Worktask
Self-Improvement`. A `/megatask` per-issue run skips this phase: nobody is there to check the
boxes, so the run ends at ST and any `.context/learnings.md` stays in the worktree for review.

1. If `.context/learnings.md` is absent → worktask done, terminate.
2. If present → display it and stop until the user checks the boxes they approve
   (`- [ ]` → `- [x]`).
3. On the user's approval, re-read `learnings.md` and route each checked item by its
   `Enforcement:` form: `judgement` → `corpflow:prompt-engineer`, `mechanical` →
   `corpflow:workflow-engineer`. Each applies per its `§ Self-Improvement Patch Application`.
4. Each applied proposal becomes its own commit (rollback-safe via `git revert <sha>`), with a
   `version:` bump only on a target with frontmatter. Routing and bump rule:
   `skills/self-improvement/SKILL.md § Hand-off to the applying agent`.

### Phase 3 key invariants

- Never auto-apply or auto-check: the user checks the boxes and signals approval.
- Each checked item goes to one agent only. An item with no valid `Enforcement:` value (missing,
  or other than `mechanical` or `judgement`) is not applied; count it in `skipped_count` and name
  it to the user.
- Proposals are scoped to agents/skills/commands that actually participated in this worktask's
  context (`skills/self-improvement/SKILL.md#step-4--map--filter-to-owning-target`).
- Post-ST audit entry in `.context/logs/audit.jsonl` records `applied_count` and `skipped_count`.

## Embedded Command Detection

Slash commands in the task description (e.g. `/skill-creator`,
`/apple-developer:fix-refactor src/Views/SettingsView.swift`) are embedded commands, executed
during the appropriate worktask stage.

### Detection and execution

1. Scan the description for `/<plugin:command>` / `/<command>`; match against the Skill tool's
   available skills.
2. Store them in `metadata.embedded_commands` on PL0 and the remaining text as the worktask task,
   preserving the arguments; pass the context to PL0 so the product-manager plans around it.
3. In the loop, a DV task whose PL0 has `metadata.embedded_commands` gets a prompt including
   "Execute embedded command(s) via the Skill tool: `<command>` with args: `<args>`", and the DV
   agent invokes `Skill({skill: "<command>", args: "<args>"})` as part of its implementation work.

Example: `/worktask /skill-creator deep analyze /path/to/source` → task
`"deep analyze /path/to/source"`, `metadata.embedded_commands: "skill-creator"`, DV prompt carrying
`Skill('skill-creator', args='deep analyze /path/to/source')`.

### Leading stacked skills

When the user stacks slash commands (`/worktask /skill-a do XYZ`), Claude Code loads up to 5
leading skills before the turn runs, so the embedded command's instructions may already be in
context at PL0. Extraction is unchanged and the DV-stage `Skill()` invocation is still required: it
is the execution trigger, not a context load, and re-invoking a loaded skill adds no duplicate.

### Error Handling

An embedded command that fails never falls back silently to generic DV work: the user asked for
that command, so the DV stage records the failure and escalates.

| Failure | Detection | Required Behavior |
|---------|-----------|-------------------|
| Skill name not resolvable | `Skill()` returns "skill not found" | Write `.context/errors/developer.md` entry with `Classification: missing_input`; escalate to TL (or PL if no TL0) |
| Skill execution errors mid-run | Skill tool returns non-success | `retry_count++`, append entry to `.context/errors/developer.md`; if `retry_count == 3`, set `error_escalated_to: "TL"` (or `"PL"` if no TL0) |
| Skill args malformed | Skill rejects at parse | Classification `ambiguous_requirements`; escalate to PL (requires planning revision) |
| Skill produces no artifact expected by downstream stage | stage-contract validation fails | Classification `missing_input`; escalate to the stage whose contract was violated |

#### Prohibited fallback and escalation target

On Skill failure the DV agent halts, appends the entry the table above names to
`.context/errors/developer.md` (its `retry_count` and, at the ceiling, `error_escalated_to` go on
the DV task's ledger row as for any retry), and returns without marking DV complete. Escalation
target: TL0 if it exists (retry, split the work, or revise approach), otherwise PL, which may add
TL0, revise the embedded command choice, or remove the embedding.

## Headless Dispatch (external runners)

External orchestrators (CI, cron, the user's shell) can invoke a single stage via
`claude -p --agent <plugin:agent> …` (`skills/worktask/scripts/headless-dispatch.sh`) instead of
the in-process `Agent()` path — `claude agents run` is not a subcommand. PL0 populates the
optional dispatch fields in `skills/worktask/references/state-ledger.md § Dispatch metadata`, and the runner
builds its flags from them. The runner recipe, the required `external_dispatch` audit line and
the permission-mode caveats: `skills/agent-coordination/references/headless-dispatch.md`.
