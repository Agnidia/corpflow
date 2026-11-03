# Artifact anchors

Read when writing an artifact body or validating its required and optional H2 anchors.

<!-- canonical-body:start -->
## #anchor-allow-list

Every stage artifact carries its stage's required H2 anchors plus the universal one, and any other H2 only from the allowed and optional sets below. The tables are generated from `skills/worktask/scripts/cache-lint.sh` by `output-sections.sh --write`, which renders the same set into each stage agent's § Artifact anchors; `output-sections.sh --check` fails `make test` on drift. Enforcement runs at the write and at the stage boundary (§ Anchor Pre-Flight); no CI lint job runs anchor-lint mode.

### Anchors — required in every artifact

One anchor is universal: mandatory in all thirteen stage artifacts on top of that stage's own row below.

- `## elicitation-sweep` — the closing elicitation sweep's canonical transport (`skills/worktask/references/contracts/sweep-boundaries.md § Closing Elicitation Sweep`), the target the frontmatter and ledger stubs point at by `ref`. It carries either the full items or the explicit empty statement; a stage with nothing to ask still writes the heading. Enforced by `cache-lint.sh --anchor-lint` for all 13 stages, with no grace for older artifacts.

### Anchors — allowed but never required

These anchors are allowed in every artifact and required in none, so none retroactively fails an artifact written before it existed and none is reported as unexpected:

- `## rework-<N>` — the scope-addition re-entry section the DR gate reads (`agents/technical-lead.md`).
- `## re-review` — a review stage's second pass over reworked output, recorded beside its original findings rather than overwriting them.
- `## design-preview` — PL's Figma capture block, written only when the task carries a Figma URL (`skills/shared/figma-capture.md`); absent otherwise.
- `## test-strategy` — PL's optional test-strategy section; `pl0-procedure.md` never mandates it.

### Anchors — PL to DR

<!-- output-sections:begin table=required-pl-dr -->
| Stage | Artifact | Mandatory H2 anchors |
|-------|----------|-----------------------|
| PL | planning-N.md | `## requirements`, `## acceptance-criteria`, `## scope`, `## out-of-scope`, `## risks`, `## complexity`, `## stages`, `## summary` |
| AR | architecture-N.md | `## decisions`, `## trade-offs`, `## patterns`, `## integration-points`, `## schemas`, `## open-questions`, `## risks` |
| TL | coordination-N.md | `## fan-out`, `## shared-snippets`, `## sequence`, `## risks` |
| DV | development-<N>[-<stream>].md | `## files-changed`, `## tests-added`, `## deviations`, `## follow-ups` |
| DR | developer-review-N.md | `## findings`, `## verdict`, `## blockers`, `## follow-ups` |
<!-- output-sections:end table=required-pl-dr -->

### Anchors — SR to ET

<!-- output-sections:begin table=required-sr-et -->
| Stage | Artifact | Mandatory H2 anchors |
|-------|----------|-----------------------|
| SR | security-review-N.md | `## findings`, `## verdict`, `## blockers`, `## threat-model` |
| QA | testing-N.md | `## results`, `## coverage`, `## regressions`, `## verdict` |
| DC | documentation-N.md | `## files-changed`, `## cross-references`, `## follow-ups` |
| RE | release-N.md | `## artifacts`, `## version`, `## rollback-plan` |
| FN | complete-summary-N.md | `## summary`, `## artifacts`, `## followups`, `## metrics` |
| ST | retrospective-N.md | `## decision`, `## learnings`, `## followups` |
| IR | incident-N.md | `## root-cause`, `## fix-plan`, `## blast-radius` |
| ET | ethics-review-N.md | `## findings`, `## verdict`, `## mitigations` |
<!-- output-sections:end table=required-sr-et -->

### Anchors — optional per stage

Allowed in that stage's artifact only, required in none; title-case entries are matched literally.

<!-- output-sections:begin table=optional -->
| Stage | Optional H2 anchors |
|-------|---------------------|
| AR | `## <Platform> App Architecture`, `## Test Architecture` |
| TL | `## Blockers` |
| DV | `## verification-command`, `## acceptance-commands`, `## decisions`, `## Blockers`, `## DV Completion Checklist` |
| QA | `## acceptance-commands`, `## Visual Evidence`, `## Design Comparison` |
| RE | `## Release Preparation Summary` |
| ST | `## Self-Improvement` |
| IR | `## Incident Report` |
<!-- output-sections:end table=optional -->

### Convention rules

1. H2 only. H1 is the artifact's title (exempt from anchor lint).
2. Kebab-case. No spaces, no underscores, no camelCase. The title-case optional entries above are the only exceptions.
3. Anchor IDs come from GitHub-style slugify, but the H2 title is already the kebab-case form; do not rely on slugify.
4. `key_decisions[].anchor` and `refs.*` resolve to a real `## <slug>` heading in the target file. Enforcement is narrower than the rule: the handoff harness validates cross-file resolution only for the AR→DV edge (`--validate-frontmatter <DV row artifact> --state <state.json>` checks the architecture reference's pattern and that the file exists next to the artifact). Every other `refs.*` entry is checked for key presence only, so a dangling target elsewhere is an author-owned contract violation the harness will not catch.

### Anchor Pre-Flight (PreToolUse Edit deny, PostToolUse feedback)

One managed plugin hook (`hooks/anchor-preflight.sh`, default-on) checks anchors at write before stray H2 costs rework; the harness gates the boundary. All three share `cache-lint.sh --anchor-diff`:

- **`PreToolUse` deny (Edit only)** — Path on artifact regex, basename exactly `<canonical>-<N>.md` (or DV's `development-<N>-<stream>.md`), `state.json` beside it. An Edit whose `new_string` adds an off-list H2 that `old_string` lacks gets `deny` naming it and the allowed set. A Write (Codex patches too) is never denied: an Edit fix is cheaper than a re-emit. Missing H2 never denies; hook error allows.
- **`PostToolUse` feedback** — Control-byte scan, `--anchor-lint`, one line per off-list H2 or frontmatter finding (§ Post frontmatter check).
- **Stage boundary** — `handoff-harness.sh --validate-frontmatter` fails on missing/unexpected H2 for all 13 stages; fails closed when `cache-lint.sh` cannot run.

#### Managed hook entries (plugin.json)

```jsonc
// hooks.PreToolUse, after test-execution-gate: JSON deny needs no continueOnBlock
{ "matcher": "Write|Edit",
  "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/anchor-preflight.sh", "args": ["--event", "pre"] } ] }
// hooks.PostToolUse, alongside audit-tooluse
{ "matcher": "Write|Edit",
  "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/anchor-preflight.sh", "args": ["--event", "post"], "continueOnBlock": true } ] }
```

#### Preflight behavior and cost — scan logic

`anchor-preflight.sh` scans allowlisted text writes for control bytes before artifact check. Anchor-lint runs only on canonical artifact regex (`\.context/((planning|architecture|coordination|developer-review|security-review|testing|documentation|release|complete-summary|retrospective|incident|ethics-review)-[0-9]+|development-[0-9]+(-[a-z0-9]+)*)\.md$`); other Write/Edit gets control-byte scan alone. Finding exits 2 (only PostToolUse exit routing stderr to model). Producer sees diagnostic and amends, so downstream doesn't pay.

#### Post frontmatter check

The frontmatter check, like the off-list H2 line, runs only when a ledger `state.json` sits beside the artifact. It runs `handoff-harness.sh --validate-frontmatter` on a same-basename temp copy of the file on disk and reports three classes only: `handoff:` over the 200-token budget, a digitless `summary_line`, a sweep stub without 2-4 `options[]`. It runs after a Write, a Codex patch, an unreadable payload, or an Edit whose `new_string` is empty or lands in the frontmatter or `## elicitation-sweep`; a body-only Edit is skipped. Each finding is one stderr line ending `fix it with a small Edit, do not re-Write the file.` Without `yq` the check fails open; the boundary still gates. `continueOnBlock` follows managed-hook discipline (diagnostic surfaced, unrelated write never blocked). Non-hook environments use stage-boundary harness only. Cost: O(seconds) per Write/Edit.

---

## Future work (out of scope for v1)

`version` is the migration hook (currently `2` — the `tasks{}` ledger); future schema additions ship behind it. A relaxed-profile schema for cross-plugin agents is stubbed in `skills/cross-plugin-handoff/SKILL.md`. Compressing `.context/logs/audit.jsonl` and migrating historical `.context/` artifacts are both out of scope.
