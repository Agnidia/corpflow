# Target Mapping Rules

Every classified diff hunk maps to exactly one owning file (the "target"). The target is then **filtered** against the used-in-context set from `SKILL.md § Step 1`; out-of-context targets are discarded.

## Mapping Rules (apply first match)

Row numbers are the `rule_num` emitted by `scripts/map-and-filter.sh`, so a proposal traces back to the rule that produced it. Artifact patterns match the glob, not one filename: every numbered `<artifact>-N.md` belongs to the stage that produces it.

### Prompt & early-stage artifacts (rules 1–5)

| # | Pattern of changed file | Target | Notes |
|---|--------------------------|--------|-------|
| 1 | `agents/<name>.md`, `skills/**/SKILL.md`, `commands/<name>.md`; `hooks/**/*.sh`, `scripts/*.sh`, `skills/*/scripts/*.sh` | The file itself | Direct edit to a participating asset — self-signal. The executed shapes are exactly those Source 4 resolves, so the in-context join can match them; test-shaped names go to row 15. |
| 2 | `.context/planning-*.md` | `agents/product-manager.md` | |
| 3 | `.context/architecture-*.md` | `agents/software-architector.md` | |
| 4 | `.context/coordination-*.md` | `agents/team-lead.md` | |
| 5 | `.context/development-*.md` | `metadata.agent` of the DV task (resolve from the ledger) | Platform-aware: `corpflow:developer`, `apple-developer:ios-developer`, etc. |

### Mid-stage artifacts (rules 6–11)

| # | Pattern of changed file | Target |
|---|--------------------------|--------|
| 6 | `.context/developer-review-*.md` | `agents/technical-lead.md` |
| 7 | `.context/security-review-*.md` | `agents/security-reviewer.md` |
| 8 | `.context/testing-*.md` | `agents/qa-engineer.md` |
| 9 | `.context/documentation-*.md` | `agents/technical-writer.md` |
| 10 | `.context/release-*.md` | `agents/release-engineer.md` |
| 11 | `.context/complete-summary-*.md` | `agents/project-manager.md` |

### Late-stage artifacts, source, tests & config (rules 12–17)

| # | Pattern of changed file | Target | Notes |
|---|--------------------------|--------|-------|
| 12 | `.context/retrospective-*.md` | `agents/stakeholder.md` | Edits to own artifact — self-improvement for ST itself. |
| 13 | Source code (`src/**`, `app/**`, `lib/**`, `Sources/**`) | Resolved DV agent (same lookup as row 5) | Default to `agents/developer.md` if DV agent missing. |
| 14 | `README.md`, `docs/**`, `*.md` at repo root | `agents/technical-writer.md` | Only if DC stage ran in this worktask. |
| 15 | Tests (`tests/**`, `**/*Tests.swift`, `**/*_test.py`, `spec/**`) | `agents/qa-engineer.md` | Only if QA stage ran. |
| 16 | Config (`*.json`, `*.toml`, `*.yml`, `*.yaml`, `Makefile`, `Package.swift`) | Resolved DV agent (row 5) | Exception: `plugin.json` → `agents/workflow-engineer.md`. |
| 17 | No rule matched | Discard | Log under `## Out-of-Context Discards` in the run log. |

## In-Context Filter (mandatory)

Keep the proposal only if the mapped target path is in the used-in-context set; otherwise log it under "Out-of-Context Discards" and leave it out of `learnings.md`.

**Why:** an artifact produced by an agent that never ran here belongs to a different feedback loop. If the user tweaks `.context/security-review-N.md` left over from an earlier run during a non-secure worktask, updating `agents/security-reviewer.md` would mean learning from a stage that did not participate.

## Platform-Aware Resolution

When a stage was delegated to a cross-plugin agent (e.g. `apple-developer:ios-developer`), the target path is `plugins/<plugin>/agents/<basename>.md`, with the plugin taken from the qualified agent name. If that plugin lives outside this repo, discard the proposal and log:

```
Cross-plugin target skipped: <qualified-agent> lives in <plugin>, not editable from this worktask.
```

## Edge Cases

| Situation | Rule |
|-----------|------|
| Hunk touches multiple files | Split into per-file hunks before mapping. |
| File moved/renamed in diff | Use the NEW path for mapping. |
| Binary file edited | Discard; log with reason `binary`. |
| File in `.context/logs/` edited | Discard; logs are ephemeral, not a learning signal. |
| File in `.context/errors/` edited | Discard; error narratives are already captured. |
| File matches `skills/self-improvement/**` | Discard; self-edits to this skill go through normal code review (avoid recursion). |

## Data Sources for "Used-in-Context Set"

`SKILL.md § Step 1` defines precedence; these are the exact query shapes.

- **Ledger:** for each task with `status == "completed"`, add `metadata.agent` (normalize `corpflow:<name>` → `agents/<name>.md`) and comma-split `metadata.embedded_commands` → `commands/<name>.md` paths.
- **`.context/*.md` metadata:** parse the trailer block where present and add its entries:

  ```
  ---
  metadata:
    agent: corpflow:developer
    embedded_commands: apple-developer:fix-refactor
  ---
  ```

- **Git trailers:** where project policy uses them, scan `git log <agent_sha>..HEAD --format=%B` for `Agent:` / `Stage:` lines.
- **Audit log** (`.context/logs/audit.jsonl`) — the only source that sees non-agent
  participants. Row shapes and the path each maps to: § Audit-log row shapes below.

### Audit-log row shapes

One JSON object per line; four shapes carry participation, each mapping to one path:

| Row field | Value shape | Path |
|---|---|---|
| `actor` | `hook:<n>` or `<plugin>:hook:<n>` | `hooks/<n>.sh` |
| `metadata.tool` | `<n>.sh` | resolved by basename |
| `metadata.via` | `<n>.sh` | resolved by basename |
| `subject`, on a row with `metadata.kind == "tool"` | bare helper name, `.sh` implied | resolved by basename |

Basenames resolve against `hooks/`, `hooks/lib/`, `scripts/` and `skills/*/scripts/` under the
plugin root — a helper's directory is not derivable from its name.

### Resolving the emitted paths

All sources produce file paths: deduplicate, then drop paths that don't exist **relative to the
plugin root** (`skills/shared/plugin-root-resolution.md`) — the pipeline runs from the worktask's
repo while every candidate lives under the plugin root.

The emitted paths are the join key: a shape no mapping row above can produce as a target is
unmatchable, so the set holds it and no change ever reaches it. Row 1 covers the four directories
Source 4 resolves for that reason.

## Cross References

- `skills/worktask/references/stage-contracts.md` — stage → artifact producer mapping (rows 2–12)
- `skills/worktask/references/contracts/ledger-operations.md § Metadata Fields` — `agent`, `embedded_commands` schema
- `SKILL.md § Step 1` / `§ Step 4` — invocation of these rules in the pipeline
