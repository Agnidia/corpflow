# Task Folder Examples & Asset Management

`../SKILL.md` carries the layout and naming rules; this file adds the asset-directory contract and the layouts its stage table does not imply.

## Asset Directories

Each workspace gets its own `.context/designs/`, so mockups never leak between workspaces. Pencil mockup generation (trigger, tools, verification): `skills/pencil-design-worktask/SKILL.md`.

### Producer, path, and format per artifact

Paths are relative to `.context/`. Plain-text `logs/*.log` producers and their `<kind>` names are canonical in `skills/logging-conventions/SKILL.md § Kind Taxonomy`; DV screenshots in `skills/dv-screenshot-capture`.

| Artifact | Producer | Path | Format |
|---|---|---|---|
| Pencil mockups | designer | `designs/mockup-[feature]-[screen]-[variant].pen` | .pen (JSON) |
| Figma screenshots | product-manager (PL) | `designs/figma-[screen]-[state]-[node-id].png` | PNG |
| Screenshots | user | `images/screenshot-*.png` | PNG/JPG |
| Diagrams | user | `images/diagram-*.png` | PNG/SVG |

### User-attached images

Copy them into `.context/images/` under descriptive names (`login-screen-mockup.png`, `screenshot-error-state.png`, `diagram-architecture.png`) and link them from the stage artifact that relies on them.

## Folder Structure Examples

> Every example shows run 0, so the plan file is `planning-0.md` and stage artifacts use suffix `-0`. A PL rerun increments N for that run's artifacts and preserves the earlier ones — see `skills/worktask/references/planning-sizing.md § Plan File & Run Index Naming`.

### Which artifacts appear per variant

`images/`, `errors/`, and `logs/` appear only as produced; `.md` suffixes omitted.

| Variant | `.context/` stage artifacts |
|---|---|
| Simple bug fix (9-stage, sized down) | planning-0, development-0, developer-review-0, testing-0 |
| Feature (9-stage, full) | planning-0, architecture-0, coordination-0, development-0, developer-review-0, testing-0, documentation-0, complete-summary-0, retrospective-0 |
| Security-critical (11-stage) | the full 9-stage set plus security-review-0 and release-0 |
| Emergency hotfix | incident-0, development-0, developer-review-0, testing-0, release-0, complete-summary-0 |
| Megatask per-issue | the sized stage set, inside the worktree (§ Megatask run) |

### Design assets

Figma PNGs and Pencil mockups share `designs/`; `planning-0.md` cites them under Design Requirements, DV implements against them, QA runs the comparison.

```
.context/
├── designs/
│   ├── figma-login-screen-42-1.png        # Figma: login screen (node 42:1)
│   ├── figma-login-error-42-5.png         # Figma: error state (node 42:5)
│   ├── mockup-user-profile-main.pen       # Designer: main screen
│   └── mockup-user-profile-edit-error.pen # Designer: validation errors
└── images/
    └── feature-mockup.png                 # User-attached
```

### Megatask run (worktree-isolated)

Under `/megatask` the whole project is checked out per issue, so `.context/` lives inside the worktree:

```
.worktrees/milestone-1/42/   # Git worktree root (full source copy)
├── .context/                # Worktask artifacts (planning-0.md, …, designs/)
├── workspace.json           # Workspace metadata (isolation: "worktree")
├── handoff.md               # Compressed context
├── src/, tests/, Package.swift   # Worktree copies of the project
```

### Multi-run in the same `.context/`

Artifacts from every run coexist; `state.json`, `errors/`, and `logs/` stay shared.

```
.context/
├── planning-0.md, architecture-0.md, development-0.md, testing-0.md, complete-summary-0.md
├── planning-1.md, architecture-1.md, development-1.md, testing-1.md, complete-summary-1.md
├── state.json              # Shared ledger (re-seeded per run, patches accumulate)
├── errors/developer.md     # Errors from any run
└── logs/build-*.log
```
