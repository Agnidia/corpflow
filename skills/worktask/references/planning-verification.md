# Planning verification

Read when executing or checking planning verification.

Procedure routing: [pl0-procedure](pl0-procedure.md).

<!-- canonical-body:start -->
## Version Bump Planning

When a worktask includes a version bump (release, tag, or `version:`/`CHANGELOG`/`MEMORY.md` change), run a version-ordering check before recommending a version in `<plan_file>`:

1. `max_released_version` = greater of the highest git tag (`git tag --list --sort=-v:refname | head -n1`, strip `v`) and the max `MEMORY.md` release-history entry.
2. Compare the proposed version by semver ordering.
3. If `proposed_version < max_released_version`: surface a "Version ordering regression" item in `## risks` naming both versions (`proposed 3.24.2 < released 3.25.0`) and ask the user to confirm intent before downstream stages, quoting the confirmation in the plan rationale. It is non-blocking — an out-of-order bump is acceptable but must be visible at plan time. DC repeats this check before FN commits.

## Completion Verification

### Verification Checklist Authoring

For grep-based verification steps in `<plan_file>` (e.g. AC validation commands):

- Anchor whole words with `git grep -P '\bname\b'`, or `git grep -w name` when no regex is needed, or match full filenames. Substring patterns false-positive on legitimate canonical names.
- Never put `\b` inside `git grep -E` or a BRE: BSD regex has no `\b`, so on macOS the grep matches nothing and reads as clean. `[[:<:]]`/`[[:>:]]` are BSD/macOS-only; glibc rejects them.
- Record each AC verification command in `<plan_file>` beside its criterion, with the output
  that passes. PL does not run it: DV runs the residual-greps before yielding and DV and QA
  execute the rest, per `skills/worktask/references/testing-strategy.md § Test-Execution Authority`.

#### Recording a command never excuses an invalid one

Write the simplest form whose every flag does what the prose claims. Naive `awk`/`grep`/`wc`
forms break silently on folded YAML blocks and meta-index files, and a stacked negation such as
`grep -viv -e A -e B` reports everything clean. DV and QA report a command that errors, or that
cannot match on any input, as a plan defect, never as a pass.

#### Per-theme residual-grep completeness gate (REQUIRED)

An enumerated edit-file list goes stale between plan authoring and DV execution, so treat it as a starting set; the completeness gate is a repo-wide grep. For each edit theme in `<plan_file>`, the acceptance criteria include at least one repo-wide residual-grep, listed as an AC verification command, that finds every live occurrence the theme must cover — so DV can self-verify completeness.

##### Residual-grep authoring rules

- A clean diff yields zero residuals (`grep` returns no unhandled matches) once the theme is fully applied.
- Anchor words with `git grep -P` (fallback `git grep -w`) or full-filename matches, per the rule above.
- Pair each residual-grep with its theme; one theme may need more than one pattern.

##### Residual-grep worked example

Example AC verification command (theme: rename a hypothetical `legacy_flag` → `flag_mode`):

```bash
# Completeness gate — MUST return no unhandled matches after the theme is applied.
git grep -nP '\blegacy_flag\b' -- '*.md' '*.sh' || echo "clean: no residuals"
```

DV runs each theme's residual-grep before yielding (`agents/workflow-engineer.md § Batch-Completion Discipline`); a non-empty result means the theme is incomplete however many enumerated files were edited.

##### `file:line` citations are starting sets too

Cite any `file:line` reference in a theme's prose (e.g. from an exploration pass) as an approximate locator — "near line N as of planning time" — and require DV to re-locate the real anchor before editing: a function/section boundary, or a grep for the quoted text. The quoted text is authoritative; the line number is not.

##### PL0 completion checklist

Before marking PL0 complete, verify:
- [ ] Version bump in scope ⇒ version-ordering check ran; any `proposed_version < max_released_version` regression surfaced in `## risks` and user-confirmed
- [ ] `<plan_file>` written at the next free N — on a `plan_revision` turn, rewritten in place at the frozen N with `facts.*` preserved
- [ ] `<plan_file>` contains all acceptance criteria
- [ ] Test strategy section present with specific test scenarios and file paths
- [ ] Test effort estimate included
- [ ] Complexity score calculated (0-50)
- [ ] Stage tasks created with `metadata.agent`, `metadata.model`, `metadata.effort`, `metadata.plan_file`, AND `metadata.run_index = N`
- [ ] Dependency chain set between created tasks
- [ ] No open questions blocking next stage

##### PL0 completion checklist — design & Figma items

- [ ] Design detected (score ≥ 5) ⇒ Designer invoked
- [ ] Figma URL detected ⇒ screenshots captured AND persisted (verified non-zero PNGs) to `.context/designs/figma-*.png`
- [ ] Container node captured ⇒ one overview PNG + one PNG per child frame persisted, one registry row each (REQ-B)
- [ ] Figma URL detected ⇒ per-frame design context summarized in `<plan_file> § Figma Design References` (one bullet per frame), and `§ design-preview` lists each persisted per-frame file with state mapping + build notes (REQ-D)
