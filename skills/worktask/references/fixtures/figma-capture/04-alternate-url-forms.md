# Fixture 04 — Alternate URL forms (`/file/`, `/proto/`) fire capture

Exercises the widened URL-detection trigger. Before the fix the trigger regex matched
only `figma.com/design/…`, so a `/file/` or `/proto/` URL populated the `## design-preview`
anchor but never fired capture — no PNGs, no `figma-registry.md`, and QA's design gate was
silently skipped. The trigger now matches `figma\.com/(?:file|design|proto)/…` at both sites
(`skills/worktask/references/planning-design.md § Figma Design Capture` and `skills/shared/figma-capture.md
§ Figma URL Detection`). This fixture is the regression guard for that widening.

Primary ACs: **AC-2** (single screen → exactly one PNG), **AC-3** (persisted file is a
verified non-zero PNG). Capture behavior is identical to fixture 01 — only the URL *form*
differs, proving the path segment is no longer a gate.

## Input

Task description contains a legacy `/file/` URL:

```
https://www.figma.com/file/XYZ789/Settings?node-id=120-45
```

(One URL, no state annotation → `state: default`.) Group 1 `fileKey` = `XYZ789`;
Group 4 `nodeId` = `120-45` → API form `120:45`. The non-capturing `(?:file|design|proto)`
alternation leaves the group numbering identical to the `/design/` form.

## Node classification (`get_metadata`)

```
node 120:45  type=FRAME  name="Settings"
  children: [ TEXT, TOGGLE, TOGGLE, BUTTON ]   # zero direct FRAME children
```

→ **Leaf** (fewer than 2 direct `frame` children). One target: node `120:45` itself.

## Expected persisted files (`.context/designs/`)

Exactly **1** PNG, verified non-zero:

```
figma-settings-default-120-45.png
```

No Overview file (leaf has no container).

## Expected registry rows (`figma-registry.md`)

Exactly **1** Entries row, no `overview` row:

| ID | Screen | State | Figma Node | Screenshot |
|----|--------|-------|------------|------------|
| design-001 | settings | default | 120:45 | figma-settings-default-120-45.png |

## Expected design-preview (`<plan_file> § design-preview`)

The original URL line PLUS one persisted-file line:

- `figma-settings-default-120-45.png` — state `default` — build notes (toggles, primary button).

## Trigger-form matrix

The path segment determines only whether the trigger *fires*; once fired, capture is
identical across the three design-file forms. FigJam/Slides are rejected because
`get_metadata` is design-file-only.

| URL form | Fires capture? | Why |
|----------|----------------|-----|
| `figma.com/design/…` | yes | design file |
| `figma.com/file/…` | yes (this fixture) | design file (legacy path) |
| `figma.com/proto/…` | yes | prototype of a design file (same `fileKey`) |
| `figma.com/board/…` | **no** | FigJam board — `get_metadata` rejects it |
| `figma.com/slides/…` | **no** | Slides — `get_metadata` rejects it |

## Assertions (QA)

- [ ] A `/file/` URL fires capture (≥1 PNG persisted + 1 registry row) — same as `/design/`.
- [ ] `fileKey` = `XYZ789`, `nodeId` = `120:45`; filename matches the grammar.
- [ ] Exactly 1 registry row; **no** `overview` row.
- [ ] A `/board/` or `/slides/` URL does **not** fire capture (0 PNGs, no registry rows).
- [ ] No false "saved" claim — every recorded success corresponds to a verified PNG.
