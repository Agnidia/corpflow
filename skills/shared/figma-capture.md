# Figma Design Capture

Read this when a Figma URL is in the task description or user input — the URL forces capture regardless of the design-detection keyword score. The trigger, the `{{asset:<basename>}}` placeholder grammar and the canonical anchor example live in `skills/worktask/references/pl0-procedure.md`.

## Figma URL Detection

Scan the task description for URLs matching:

```
figma\.com/(?:file|design|proto)/([a-zA-Z0-9]+)/([^?]+)(\?node-id=([0-9-]+))?
```

- Group 1 `fileKey`, Group 4 `nodeId` (`-` → `:` for API calls); `(?:file|design|proto)` is non-capturing, so all three path forms keep the same group numbers.
- Keep it in step with the two trigger regexes in `skills/worktask/references/planning-design.md § Figma Design Capture` — on drift, `/file/` and `/proto/` URLs reach `design-preview` but never fire capture (no PNGs, no registry, QA design gate skipped).
- Don't add `/board/` or `/slides/`: `get_metadata` is design-file-only and rejects FigJam/Slides.
- Branch URL (`…/branch/:branchKey/…`) → `branchKey` is the fileKey. No `node-id` → capture the top-level frame.

## State Input Contract

State comes only from explicit user input, never from scanning sibling frames. One URL, no annotation → `state: default`; otherwise one URL per state via fragment (`…?node-id=42-7#state=error`), query parameter (`…&state=error`), or inline annotation (`<url> [state: error]`).

Valid values: `default | error | empty | loading | hover | disabled | success`. Unknown values are kept as-is; QA reports unusual states in `testing.md`.

## Auth Probe

Before the Capture Workflow, if the task description contains `figma.com` (case-insensitive), call `mcp__plugin_figma_figma__get_screenshot({ fileKey, nodeId })` once on the first URL, before any plan-file write.

- **Success** → run the Capture Workflow.
- **Non-auth failure** (network, rate limit, bad node id) → use the per-URL failure path at the end of `## Capture Workflow`.

### Auth failure (soft halt)

The error string matches (case-insensitive) `authenticate`, `OAuth`, `unauthorized` or `401`:

1. Emit exactly one user-facing line: `Figma MCP not authenticated. Authorize at <OAUTH_URL_FROM_ERROR> and paste callback to continue, or reply 'skip' to proceed without screenshot.` (OAuth URL from the error payload; if absent, drop the placeholder and say `Authorize the Figma MCP server`.)
2. Write one closing-sweep item (§ Auth failure — the sweep item).
3. Skip the Capture Workflow and write the plan as if no Figma URL were present; the user decides at the gate whether to authorize and re-run.

#### Auth failure — the sweep item

Same contract as every other stage's (`skills/worktask/references/contracts/sweep-boundaries.md § Closing Elicitation Sweep`): the full `SweepItem` under `planning-<N>.md#elicitation-sweep`, and its stub in both `handoff.open_questions[]` and the PL `--facts` payload — nothing derives one from the other, so a stub written to only one never reaches the gate.

- `id: sw-PL<N>-<n>`, `class: decision`, `ref: "planning-<N>.md#elicitation-sweep"`, `blocks_next_stage: false` (required on every stub; `false` because PL's boundary already is the plan gate).
- `summary`: `Figma MCP auth pending; proceed without screenshot capture? (URLs: <comma-separated list>)`
- `options[]`: `Proceed without screenshots` (`recommended: true`; the QA design gate is skipped for this run) / `Authorize and re-run capture`.
- `rationale`: one line on why proceeding is the default here.

## Capture Workflow

Run the Auth Probe first; on auth failure skip these steps. All PNGs land in `.context/designs/` (`skills/task-folder-organization/SKILL.md § Canonical Figma Asset Directory`), never `.context/images/` — that directory is DV-only, and a Figma PNG there disables the QA design gate.

Run `mkdir -p .context/designs` once per turn before any `curl`: `curl -o` cannot create parents, and the `skills/worktask/references/workflow.md` init mkdir may not have run.

### Steps 1–2 — Parse and classify

Per Figma URL (state defaults to `default`): parse `fileKey`, `nodeId`, `state`, then classify the node with `mcp__plugin_figma_figma__get_metadata({ fileKey, nodeId })` before capturing:

- **Leaf** — `frame`/`component`/`instance` with fewer than 2 direct `frame` children → one target, the node itself.
- **Container** — type `section`/`canvas`, or a wide `frame` with ≥ 2 direct `frame` children → descend one level only: the container as the overview, plus each direct child `frame` (id + name from metadata).
- **Ambiguous** — lone screen `frame`, or a layout group with 0–1 `frame` children → treat as leaf.

Cap: the first 12 child frames in document order; beyond that capture those 12 and append `R2 over-capture cap hit: container <nodeId> has <N> frames, captured first 12` to `.context/errors/product-manager.md`.

### Step 3 — Capture each target

For each target node (overview first, then child frames):

a. `mcp__plugin_figma_figma__get_design_context({ fileKey, nodeId })` — code hints + component info.
b. `mcp__plugin_figma_figma__get_screenshot({ fileKey, nodeId })` — returns a short-lived image URL.
c. Persist in this turn, because the URL expires before any post-approval step. `target_path` = `.context/designs/` + the grammar basename. Double-quote both arguments — the MCP-returned URL is external input:

```bash
curl -sf -o ".context/designs/<basename>" "<image_url>"
```

#### Verify and record (3d–3e)

d. Verify before recording success: `file "<target_path>"` reports a PNG and the byte size is > 0. On failure (curl non-zero, missing file, zero bytes, not a PNG) append `figma persist failed: <nodeId> → <target_path> (<reason>)` to `.context/errors/product-manager.md`, record a sweep item shaped like § Auth failure — the sweep item (same id, class, anchor, both stubs and options), and continue: persist failures never block the worktask.
e. Record `{nodeId, name, state, image_url, target_path}` into `state.json facts.figma_assets[]`; only verified rows count toward registry success, failed rows carry `failed: true`.

### Step 4 — Filename grammar

`.context/designs/figma-[screen]-[state]-[node-id].png` — the directory component is mandatory.

- `[screen]`/`[node-id]`: child frame name + child id; the Overview (container image) uses the container name + id. Names lowercase, spaces → hyphens; ids colons → dashes.
- `[state]`: per the State Input Contract, default `default`; child frames inherit the URL-level state unless annotated per-frame.
- Non-alphanumeric characters (dashes, slashes, en/em-dashes, other punctuation) collapse to one hyphen; consecutive hyphens squeeze to one.

### Steps 5–7 — Outputs and failure path

5. Repeat steps 1–4 per Figma URL.
6. Summarize per-frame design context in `<plan_file>` under **Figma Design References**: one bullet per frame (state, badge/label text, build notes — shape/geometry, control deltas) plus one overview bullet.
7. Write `.context/designs/figma-registry.md` (see Registry Generation).

A per-URL MCP failure never stops the run — continue with the remaining URLs, write the registry with the captured rows, append a failure note to `.context/errors/product-manager.md`.

## Registry Generation

Write `.context/designs/figma-registry.md` after all captures. Per-frame rule (REQ-B): a container yields N+1 rows — one Overview row (container node id, `State: overview`) plus one row per persisted child frame, keyed on its own node id, name and state; a leaf URL yields exactly one row and no Overview row. QA compares each row's persisted file individually (`agents/qa-engineer.md § Design Comparison (Visual QA)`).

### Registry template

```markdown
# Figma Design Registry

Produced by: PL stage (product-manager)
Consumed by: QA stage (qa-engineer)

## Entries

| ID | Screen | State | Device | Figma Node | Screenshot | Target File(s) | AC Ref |
|----|--------|-------|--------|------------|------------|----------------|--------|
| design-001 | skin-analysis-face-scan | overview | iPhone 15 | 255:2263 | figma-skin-analysis-face-scan-overview-255-2263.png | ScanView.swift | AC-1 |
| design-002 | scan-25 | default | iPhone 15 | 255:2264 | figma-scan-25-default-255-2264.png | ScanView.swift | AC-1, AC-2 |
```

Then `## Source URLs` (one `- design-NNN: <url> (container|child frame)` bullet per row) and `## Capture Metadata` (`Captured at:` ISO-8601, `Captured by: corpflow:product-manager (PL0)`, `Figma file version:` from `get_metadata`, else `unknown`).

### Column semantics

Column order is authoritative — QA parsers rely on it. `Screen`, `State`, and `Screenshot` follow the filename grammar (`Screenshot` = basename only; the Overview row uses the container name and literal state `overview`). `Figma Node` is the API-format id (colons). `ID` is a sequential `design-NNN`; `Device` comes from task context ("iPhone 15", "Desktop 1440", "iPad"); `Target File(s)` and `AC Ref` come from `<plan_file> § Scope` (comma-separated) and `§ Acceptance Criteria`.

Defaults when unknown: `Screen` → node-id, `State` → `default`, `Device` → `unspecified`, `Target File(s)` → `?`, `AC Ref` → blank.

Reference the registry from `<plan_file> § Figma Design References`:

> See `.context/designs/figma-registry.md` for the full node → screenshot → target mapping.

## Post-Capture Plan Update (REQ-D)

In this same PL turn, after the files are verified on disk and the registry is written, rewrite the plan's `## design-preview` anchor with the Asset-placeholder grammar from `skills/worktask/references/pl0-procedure.md`, so DV implements and QA verifies against the per-frame files.

### Anchor update steps

1. Keep the captured Figma source URL line(s) at the top of the anchor, verbatim.
2. Per persisted file (verified non-zero PNG): a `{{asset:<basename>}}` token line (basename only) immediately followed by a `- <description>` bullet — state mapping plus build notes (shape/geometry, badge/label text, control deltas versus the other states). The Overview gets its own token + bullet, marked as the container reference, not a per-state target.
3. Failed/skipped frames (`failed: true` in `state.json facts.figma_assets[]`) get a plain bullet naming their `sw-PL<N>-<n>` sweep item — no `{{asset:...}}` token, never a satisfied target.

The registry rows, not one combined screenshot, are QA's authoritative per-state targets.

### Publish-helper boundary

The PM writes only tokens and descriptions, never hosted URLs or `![...]()` image markdown. After approval and sanitisation, `publish-pl-issue.sh` resolves each token into a hosted image line (its tier chain is documented in the script header).

## Coexistence with Pencil Mockups

A Figma URL always captures and writes the registry; a design keyword score >= 5 without a Figma URL invokes Designer for Pencil mockups instead (no registry). When both fire, do both — the Figma screenshots are the authoritative design reference.
