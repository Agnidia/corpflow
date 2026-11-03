# Completion

Read when executing or checking completion. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
## Completion Verification — before return

Single source of truth for what every stage agent verifies before `status: completed`. Each agent's `## Handoff Protocol` references this checklist rather than restating it. Repeat the numbered step outcomes verbatim in your return summary. Execute in order:

### Steps 1–3

1. Artifact frontmatter: your artifact (`.context/<artifact>-N.md`) starts with `---\nhandoff:` conforming to the per-stage template at `stage-contracts.md#tpl-<CODE>`.
2. Required fields: the frontmatter includes every required field for your stage `<CODE>` per `skills/worktask/references/contracts/frontmatter.md#frontmatter-schema` § Per-stage required-field matrix.
3. Artifact filename: the canonical name from `skills/worktask/references/contracts/artifact-map.md#stage-artifact-map`. Non-canonical names (e.g. `arch-0.md` for `architecture-0.md`) break the SubagentStop safety net.

### Steps 4–5

4. Patch state.json: patch `tasks.<ID>` (`status`, `artifact`, `verdict`, `retry_count`) and `handoffs["<PREV>→<TASK_ID>"]` (≤300-char summary ending with a `ref:` pointer). The source side is a bare stage code naming the stage this followed, as each template's footer above shows (e.g. `PL→AR`, `USER→IR`). The destination side is the writing task's own id, so a split stage writes one edge per task (`TL→DV0`, `TL→DV1`) instead of colliding on one key.
5. Atomic write: run `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --stage <CODE> --prev <PREV>`, which performs the canonical locked read → merge → temp → fsync → rename of `skills/worktask/references/contracts/ledger-writes.md#atomic-write`. Don't write `.context/state.json` directly. If the script cannot run at all, don't skip silently; use the Edit-direct fallback at `skills/worktask/references/contracts/ledger-edges.md#layer-1-fallback`.

### Post-return repair (F2/F3)

The orchestrator verifies `tasks.<ID>.status == "completed"` after the task returns. If still `in_progress`, the SubagentStop hook (`state-merge.sh`) repairs the ledger from the artifact's frontmatter (F2). If the artifact lacks frontmatter, the orchestrator derives a minimal handoff record from the return text (F3), but downstream cache hits collapse, so valid frontmatter is still required.

## Cross References

- `skills/worktask/references/handoff-protocol.md` — canonical state.json + frontmatter + anchor specs
- `skills/worktask/references/stage-codes.md` — code/agent/model lookup
- `skills/worktask/references/state-ledger.md` — metadata schema, `error_file` derivation, `context_refs`/`state_file`
- `skills/agent-coordination/SKILL.md` § Error Handling — retry/escalate matrix
- `skills/logging-conventions/SKILL.md` — raw capture paths (`.context/logs/`)
- `skills/task-folder-organization/SKILL.md` — artifact naming and retention
- `skills/self-improvement/SKILL.md` — optional `.context/learnings.md` produced at ST
