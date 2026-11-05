---
name: task-folder-organization
description: Use when creating, naming, or resolving worktask artifact paths. The `.context/` folder layout — run-indexed stage artifacts, design and image assets, per-agent error files, runtime logs.
version: 0.3.0
---

# Task Folder Organization

Every project keeps one `.context/` folder at the project root for all worktask artifacts, so the audit trail from plan to deploy sits in one place. Under `/megatask` it lives inside each worktree (`.worktrees/<group>/<issue#>/.context/`), not in the main repo root.

## Layout

Flat — every `.md` sits directly in `.context/`; `designs/`, `images/`, `errors/`, and `logs/` are the only subdirectories.

```
.context/
├── <basename>-N.md   # stage artifacts, run-numbered (§ Stage Artifacts)
├── state.json        # worktask ledger; shared across runs, re-seeded each PL run
├── gh-issue.json     # run-independent .context ↔ GitHub issue anchor
├── designs/          # canonical Figma assets: figma-*.png + figma-registry.md + Pencil .pen mockups
├── images/           # user-attached screenshots + DV implementation screenshots (not Figma)
├── errors/           # per-agent escalation narratives
└── logs/             # runtime capture logs (build/test/monitor/sim/incident/hotfix)
```

Per-variant layouts, asset naming, and worked examples: `references/examples.md`.

### Run-Index Naming

Stage artifacts are `<basename>-N.md`, N = `task.metadata.run_index` — an integer PL0 stamps on every downstream task, starting at 0. A PL0 rerun (scope change, re-plan) increments N, and `planning-1.md`, `architecture-1.md`, … land beside run 0's files, which are preserved.

`state.json`, `gh-issue.json`, `designs/`, `images/`, `errors/`, and `logs/` are shared across all runs, never duplicated per run. `state.json` is re-seeded (metadata wiped) each PL run, so the durable `.context ↔ issue` binding lives in `gh-issue.json` — that is what lets a follow-up run comment on the existing issue instead of opening a duplicate (`skills/gh-issue-dedup`).

### Stage Artifacts

Canonical stage→basename map: `skills/worktask/references/contracts/artifact-map.md#stage-artifact-map`; stage→agent: `skills/worktask/references/stage-codes.md`. Path-resolution mirror:

| Artifact | Stage | Owner | Variant |
|---|---|---|---|
| planning-N.md | PL | product-manager | standard |
| architecture-N.md | AR | software-architector | standard |
| coordination-N.md | TL | team-lead | standard |
| development-<N>[-<stream>].md | DV | developer | all |
| developer-review-N.md | DR | technical-lead | all |
| security-review-N.md | SR | security-reviewer | `--secure` |
| testing-N.md | QA | qa-engineer | all |
| documentation-N.md | DC | technical-writer | standard |
| release-N.md | RE | release-engineer | `--secure`, emergency |
| complete-summary-N.md | FN | project-manager | all |
| retrospective-N.md | ST | stakeholder | standard |
| incident-N.md | IR | incident-responder | emergency |
| ethics-review-N.md | ET | ethics-reviewer | on demand |

#### Variant column

Standard = 9-stage `PL→AR→TL→DV→DR→QA→DC→FN→ST` (dynamic sizing may omit stages); `--secure` = 11-stage, adding SR and RE; emergency = `IR→DV→DR→QA→RE→FN`.

DV fans out as ledger tasks — one artifact per `DV<k>` row, `development-N-<stream>.md`: `skills/worktask/references/contracts/artifact-map.md § DV fan-out — ledger tasks`.

#### Artifact content

Each artifact opens with a header (task id, date, author agent), then purpose, stage content with the why behind each decision, next steps, and references to related documents.

### Canonical Figma Asset Directory

`.context/designs/` is the one directory for Figma assets — per-frame screenshots (`figma-*.png`), the registry (`figma-registry.md`) — and Pencil `.pen` mockups.

- **Writer**: `product-manager` (PL) persists PNGs in-turn via `Bash(curl:*)` and writes `figma-registry.md` — `skills/worktask/references/planning-design.md § Figma Design Capture`.
- **Reader**: `qa-engineer` (QA) reads `figma-registry.md` and compares it against each persisted frame — `agents/qa-engineer.md § Design Comparison (Visual QA)`.
- Figma assets never go in `.context/images/`: that directory holds user-attached screenshots/diagrams and DV implementation screenshots (per-task `screenshots-<TASK_ID>.md` manifests, `skills/dv-screenshot-capture`).

#### Figma Filename Grammar

`figma-[screen]-[state]-[node-id].png` — per-frame children use the child name/id, the container overview uses the container's. See `skills/shared/figma-capture.md § Capture Workflow`.

### Per-Agent Error Files (`errors/`)

One escalation narrative per agent, created on failure, so parallel stages (QA+DC, TL-split DV streams, megatask tracks) cannot clobber each other.

- Path `.context/errors/<agent-basename>.md`; basename = last `:`-separated segment of `metadata.agent` (`developer`, `qa-engineer`, `ios-developer` for `apple-developer:ios-developer`). On cross-plugin collision, join with `-`: `apple-developer-ios-developer.md`.
- Append-only: one `## Retry N — <ts>` section per failure, each followed by a machine-readable metadata line (classification, task_id, retry_count).
- One agent across several tasks (TL split `DV0`/`DV1`/`DV2`) → a single `developer.md` with per-task sections (`## DV0 Retry 1`, `## DV1 Retry 1`, …).
- `.context/error.md` is retired; never write it.

### Runtime Logs (`logs/`)

Raw runtime capture — background `Bash` stdout, `Monitor` streams, simulator captures, incident tails — distinct from the narrative `errors/`. Split table, filename grammar (`<kind>-<scope>-<timestamp>.log`), and cleanup policy: `skills/logging-conventions/SKILL.md § The Split`.

## Starting a new task

Archive or clear a stale `.context/` before starting an unrelated task; a rerun of the same task keeps it (§ Run-Index Naming).
