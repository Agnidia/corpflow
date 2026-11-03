# Stage table

Read when executing or checking stage table. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
## Contract Table

Artifact paths use `<basename>-N.md` (N per [#run-index-resolution](stage-inputs.md#run-index-resolution)). H2 sets use [artifact-anchors.md](artifact-anchors.md#anchor-allow-list). Reading the rows:

- Every Validation cell implicitly requires that the named output artifact exists on disk; only the extra conditions are listed.
- `<plan_file>` resolves via `task.metadata.plan_file`; fallback newest `.context/planning-*.md`.
- "this row's artifact" (DV) and "every DV task artifact" (downstream) both resolve from the ledger's DV rows, in ascending task-id order — `skills/worktask/references/contracts/artifact-map.md § DV fan-out — ledger tasks` (naming, seam S1) and § Iterating the DV tasks (seam S3). Never a filename composed by hand.
- † = frontmatter-first read (`Read <artifact> limit:30`); deep-read a body only on anchor-miss, a section-flagging `verdict`/`next_stage_focus`, or `retry_count > 0`.

### PL–TL

| Stage | Required Inputs | Required Outputs | Validation |
|-------|-----------------|------------------|------------|
| **PL** | User request; trigger flags | `.context/<plan_file>` (`planning-N.md`, N = next free integer ≥ 0; `skills/worktask/references/planning-sizing.md § Plan File & Run Index Naming`). Plus `.context/designs/figma-registry.md` if Figma URLs provided | Complexity Score int 0–50 + Stage Plan lists downstream task subjects + `metadata.plan_file = <plan_file>` AND `metadata.run_index = N` stamped on every downstream task |
| **AR** | `<plan_file>` | `architecture-N.md` | ≥1 decision with rationale |
| **TL** | `<plan_file>`, `architecture-N.md` (when AR ran) | `coordination-N.md` | Task breakdown maps to DV sub-tasks |

### DV–SR

| Stage | Required Inputs | Required Outputs | Validation |
|-------|-----------------|------------------|------------|
| **DV** | `<plan_file>`; `architecture-N.md` (required when AR ran; checked by `handoff-harness.sh --validate-frontmatter --state`); `coordination-N.md` (when TL ran) | this row's artifact, the runner's verbatim summary line in `## verification-command`, plus code changes | git diff non-empty + `files_touched` obeys `skills/worktask/references/contracts/files-touched.md#files-touched` + summary line quoted + per-runner `tests_executed` entries (or `test_suite_compiles` at all 0) + `.context/logs/build-*.log` shows success |
| **DR** | every DV task artifact + source diff | `developer-review-N.md` | `## verdict` ∈ {pass, fail} |
| **SR** | every DV task artifact + source diff | `security-review-N.md` | No High/Critical findings unresolved |

### QA–RE

| Stage | Required Inputs | Required Outputs | Validation |
|-------|-----------------|------------------|------------|
| **QA** | every DV task artifact, `developer-review-N.md`, `.context/designs/figma-registry.md` (if present; else glob `.context/designs/figma-*.png`) | `testing-N.md` | `.context/logs/test-*.log` shows pass + no blocking defects + if `figma-registry.md` present, `testing-N.md § Design Comparison` has one row per registry entry |
| **DC** | every DV task artifact, `architecture-N.md` (when AR ran) † | `documentation-N.md` | Docs diff present |
| **RE** | every DV task artifact, `testing-N.md`, `documentation-N.md` | `release-N.md` | Version bump proposed + changelog entry drafted |

### FN–ST

| Stage | Required Inputs | Required Outputs | Validation |
|-------|-----------------|------------------|------------|
| **FN** | Upstream `.context/*-N.md` † (log each deep read in the `deep_reads` tripwire) + `state.json` facts | `complete-summary-N.md`. Plus `.context/attachments/{PR instructions,Review request}.md` (`conductor-attachments.md`) and commit/PR. Preflight: `skills/worktask/scripts/fn-preflight.sh` | Both attachments exist + commit created OR PR opened |
| **ST** | `complete-summary-N.md` | `retrospective-N.md`. Plus optional `.context/learnings.md`, only on in-scope user changes (`skills/self-improvement/SKILL.md`) | Verdict ∈ {approve, reject} (reject carries `blockers:` and loops back to DV) + `self-improvement` invocation recorded (`learnings.md` present, or `Result: no-changes` in `.context/logs/self-improve-*.log`) |

### IR–ET

| Stage | Required Inputs | Required Outputs | Validation |
|-------|-----------------|------------------|------------|
| **IR** | User incident report | `incident-N.md` | `## root-cause`, `## fix-plan`, `## blast-radius` non-empty; H3s Required Fix, Constraints, Verification Command (under `## fix-plan`) and Blast Radius (file allow-list, under `## blast-radius`) non-empty (`skills/incident-response/SKILL.md#ir--dv-handoff-contract`) |
| **ET** | `<plan_file>` + high-risk keyword match | `ethics-review-N.md` | Decision ∈ {pass, block, conditional} |
