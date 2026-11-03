# Template rules

Read when executing or checking template rules. Read linked modules only when their conditions apply.

Read these sections only when this procedure cites them.

###### Section lookup 1

[Closing Elicitation Sweep](sweep-boundaries.md#closing-elicitation-sweep)

<!-- canonical-body:start -->
## Per-Stage Frontmatter Templates

Canonical YAML templates for the `handoff:` block atop every stage artifact. Each agent's `## Handoff Protocol` pastes the matching block verbatim (with substitutions) into `.context/<artifact>-N.md` (N per [#run-index-resolution](stage-inputs.md#run-index-resolution)); agents keep the field shape below. To change a template, edit its asset in `skills/worktask/assets/templates/`, then re-run `cache-lint.sh --frontmatter-template-lint agents/*.md` to revalidate every agent's inline copy. `skills/worktask/assets/templates/template-pl.md#tpl-pl` has one more copy to mirror: the top of `skills/worktask/assets/templates/planning.md`, which PL0 copies.

### Two first-write rules the stage gate enforces

Read these before the first artifact write. `handoff-harness.sh --validate-frontmatter` fails the stage on either.

1. **Frontmatter budget.** The `handoff:` block stays at or under 200 discretionary tokens. The harness counts words × 1.33, comments included, so the limit is about 150 words. `open_questions` stubs and `tests_executed` do not count.
2. **Sweep stubs.** Each `open_questions` stub has an item under `## elicitation-sweep` with 2–4 `options[]` (`label:`), or it is an `escalate` item whose question ends in `?`. Never write a status-note stub. The empty case is in § Closing Elicitation Sweep.

A Write that breaks either rule lands. `hooks/anchor-preflight.sh` then reports it at PostToolUse: fix it with a small Edit, do not re-Write the file. Every stage agent carries a short form of both rules in its generated "Artifact anchors" block.

### Typed-return equivalent

Each stage template has a `<CODE>Handoff` JSON-Schema counterpart in
`skills/worktask/references/contracts/typed-conventions.md#handoff-schemas`, a parallel validated channel sharing one verdict vocabulary
per stage. Supersession and write-either-way rules: [Validation Protocol steps 1–2](validation.md#steps-12).
