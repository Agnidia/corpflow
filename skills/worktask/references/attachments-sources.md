# Attachments sources

Read when executing or checking attachments sources.

<!-- canonical-body:start -->
# Conductor Attachments — FN Templates

Templates and emission rules for the two Conductor-convention files the FN
stage writes into `.context/attachments/`. Read by `agents/project-manager.md`
(FN Stage) and validated by `skills/worktask/references/stage-contracts.md` (FN row).

## Why these files exist

Conductor injects them into a new session on a UI action: "Create PR" → `.context/attachments/PR instructions.md`, "Request Review" → `.context/attachments/Review request.md`. Without them it falls back to generic prompts with no DR/QA verdicts, commit type, resolved base branch or summary link. The FN agent also runs `gh pr create` from `PR instructions.md`, so FN and a later Conductor re-trigger follow the same instructions.

## When to write

Two idempotent writers, both rendering these templates:

| Writer | When | Data quality |
|--------|------|-------------|
| Orchestrator pre-gate | Before the FN gate's `return` (gated path only; bypass falls through to delegation) | Best-available: DR/QA verdicts from upstream artifacts, git state at gate time |
| FN agent post-approval | Before `gh pr create` (`agents/project-manager.md § FN Stage`) | Final: same sources, fresher post-commit git state |

### Writer 1 — Orchestrator pre-gate (tool-explicit)

Step 1 of the FN gate's Effect (checkpoint) list, gated path only. Procedure: `skills/worktask/references/fn-gate.md § Pre-gate Conductor-attachments writer`; gate detection: `skills/worktask/references/orchestration.md § FN Gate`. The `test -f` trip-wires in Effect steps 1 and 6 stop a skipped or partial run from reaching `return`.

### Writer 2 — FN agent post-approval

In `agents/project-manager.md § FN Stage`, immediately before `gh pr create`:

```bash
mkdir -p .context/attachments
```

Then `Write` both files from `skills/worktask/assets/templates/attachments-pr-template.md` and `skills/worktask/assets/templates/attachments-review-template.md`, overwriting from scratch (no skip, no merge): a pre-seed is expected but never assumed current.

Post-write verify, mirroring Writer 1's trip-wire:

```bash
test -f ".context/attachments/PR instructions.md" && test -f ".context/attachments/Review request.md" && echo OK
```

On `OK`, run `gh pr create` from `PR instructions.md`. Otherwise abort FN with `handoff.verdict: blocked`, write the cause to `.context/errors/project-manager.md`, and stop, because a PR without the attachments leaves later Conductor actions on generic prompts.

### Known emission-rule defects

`skills/worktask/scripts/attachments-preseed.sh` renders these blocks at run time and reproduces the defects below as written (it handles defect 1 by matching surrounding text). Fix one in this document and the script in the same commit, never in a fenced template body alone.

1. `<N>` is overloaded: uncommitted-file count in parts 1 and 3, issue number in part 7's `Closes #<N>` checklist row. Fix: rename the checklist token to `<ISSUE>`.
2. No blank line before `## 2. Push`: part 3 is the only fenced body without a trailing blank line, so it runs into part 3b.
3. Authoring comments ship: `<!-- If issue ref present: … -->` and the two `<!-- One bullet per … -->` notes sit inside the fenced bodies, so the emission rule copies them into the real attachment. Harmless, probably unintended.

## Data sources

### Git & branch state

| Field | Source |
|-------|--------|
| Current branch | `git rev-parse --abbrev-ref HEAD` |
| Branch (PR head) | `state.json § facts.branch`, the planned name from PL start. Validate first (`^[A-Za-z0-9._/-]+$`, `project-manager.md § Validating \`facts.branch\` before the push`). Push: `git push -u origin HEAD:refs/heads/<facts.branch>` (topology-independent) |
| Target / base branch | One resolution order, highest first, ending unresolved with no literal fallback; canonical in `handoff-protocol.md § metadata.base_ref`, implemented by `fn-preflight.sh` `resolve_base_ref` |
| Uncommitted change count | `git status --porcelain \| wc -l` |
| Upstream tracked? | `git rev-parse --abbrev-ref --symbolic-full-name @{u}` (non-zero exit = no upstream) |

### Plan, issue & verdict fields

| Field | Source |
|-------|--------|
| Conventional-commit type | `state.json § facts.goal` via `branch-lib.sh:derive_type` (`git-conventions.md § Branch Naming`); defaults to `feature`. Not the plan — no template emits `## Goal` |
| Plan document (other fields) | `FN0.metadata.plan_file` (basename; `handoff-protocol.md § plan_file shape boundary`), else newest `.context/planning-*.md` |
| Issue ref | `workspace.json § issue_number` (milestone mode) or `metadata.issue_ref` from PL0; else omit |
| DR verdict | First "Approval Status" line in `.context/developer-review-N.md` (N from `run_index`) |
| QA verdict | First "GO/NO-GO" line in `.context/testing-N.md` (N from `run_index`) |
| DR concerns | Lines under `## Issues Found` in `.context/developer-review-N.md` |
| QA blocking defects | Lines under `## Results` flagged blocking in `.context/testing-N.md` |
| Worktask ID | `PL0.metadata.worktask_id` |
| Timestamp | ISO 8601, UTC, second precision |

### Probe & placeholder fields

| Field | Source |
|-------|--------|
| Existing PR URL (idempotency probe) | `gh pr view --json url,state -q '"\(.state) \(.url)"' 2>/dev/null` (empty = no PR). Resolved by the consuming agent at execute time, not by the FN writer |
| `<ISSUE_LINE>` placeholder | `- Issue: #<ISSUE> — include \`Closes #<ISSUE>\` in the PR body to auto-close on merge.` if `ISSUE_REF` present, else empty string (line omitted) |
| `<UPSTREAM_LINE>` placeholder | `Upstream tracking: origin/<BRANCH>.` if `git rev-parse @{u}` succeeds, else `No upstream branch yet — use \`git push -u origin <BRANCH>\`.` |
