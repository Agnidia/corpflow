# Stage inputs

Read on stage entry before selecting upstream artifact sections.

<!-- canonical-body:start -->
---
name: stage-contracts
version: 0.4.0
---

# Stage Contracts Reference

Single source of truth for what each stage consumes, produces, and how the orchestrator validates the handoff. Every stage agent's `## Completion Verification` section links back here.

## How to Read a Contract

- Inputs: `.context/` artifacts and metadata read before starting. Missing → `missing_input` escalation (`agent-coordination` § Error Handling).
- Outputs: artifacts produced before `status: completed`, each with the listed minimum sections. Every output opens with a `---\nhandoff:\n` YAML block per `skills/worktask/references/contracts/frontmatter.md#frontmatter-schema`.
- Validation: the check the orchestrator runs on completion. False → the stage is not complete.
- Agent + model per stage: `skills/worktask/references/stage-codes.md`.
- Error file: `.context/errors/<agent-basename>.md`, derived from `metadata.agent` (`state-ledger` § Metadata Fields).

## Required Inputs (handoff-protocol)

Every stage agent reads inputs in this order, anchor-first:

1. Read the ledger digest and stage brief. Read `.context/state.json` only for required facts absent from that digest.
2. Resolve N from the task metadata; read upstream handoff frontmatter before the referenced sections required by this stage.
3. Resolve the required references and acceptance criteria. A missing reference keeps its dependent check blocked until repaired.
4. Inspect the relevant implementation, tests, and dependencies. Expand exploration when unresolved requirements or findings justify it.

Code and security reviews inspect the actual implementation and relevant dependencies; handoff summaries never replace source review.
Use targeted ranges for large files, and record why broader reads were necessary.

The ledger is required: an absent or unreadable `.context/state.json` is a hard failure, so stop and report rather than guess. There is no whole-file fallback list.

### #run-index-resolution

Canonical two-step resolver (see `skills/worktask/references/planning-tasks.md § Stage Artifact Naming`):

1. `task.metadata.run_index` → `<basename>-${N}.md`.
2. Newest glob `<basename>-*.md` (highest N) when metadata is absent.

### No-restate rule

Agents don't restate the run-index resolver or the atomic-write pseudocode in their own files; they link to `skills/worktask/references/contracts/stage-inputs.md#run-index-resolution` or `skills/worktask/references/contracts/ledger-writes.md#atomic-write`.

### #diff-only-read

Cheapest-first read order for review and finalization stages (DR/SR/QA/DC/FN) when only a verdict, decisions, refs or the delta is needed; full reads stay available when context requires them:

1. Frontmatter-first: read the upstream artifact's `handoff:` block (≤200 tok) instead of the whole artifact.
2. Diff-only: if `state.json → facts.files_read` lists a source path (read by DV or a prior stage), use `git diff <base>..HEAD -- <path>` for changed-file context instead of `Read <path>`.
3. Anchor-scoped: when a single `## <anchor>` section suffices, `Read` that range, not the whole file.

#### Diff-only — full-read escape hatch

Read the full file only when the above is insufficient, and give the reason in the stage artifact's `§ Findings`/`§ Notes`; for files over 200 lines use `Read` with `offset`/`limit` on the changed region. Without `facts.files_read`, read normally. Stage agents cite this anchor with a one-line reminder inline rather than restating it.
