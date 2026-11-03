# Artifact map

Read when resolving a stage artifact, its run index, or a DV stream tree.

## Read for related fields
- For artifact landing, read [artifact-landing](artifact-landing.md).

<!-- canonical-body:start -->
## #stage-artifact-map

Canonical mapping from stage code to artifact filename (used by orchestrator, hook, and F4 regeneration walk).

All stage artifacts are numbered; N is allocated by PL0 (same value as `planning-N.md`) and propagated via `task.metadata.run_index`. Readers fall back to newest-glob (`<basename>-*.md`).

| Stage code | Artifact filename | Plural? |
| --- | --- | --- |
| PL | `planning-N.md` (N starts at 0) | yes |
| AR | `architecture-N.md` | yes |
| TL | `coordination-N.md` | yes |
| DV | `development-N.md` (per DV ledger task: `development-N-<stream>.md`) | yes |
| DR | `developer-review-N.md` | yes |
| SR | `security-review-N.md` | yes |
| QA | `testing-N.md` | yes |
| DC | `documentation-N.md` | yes |
| RE | `release-N.md` | yes |
| FN | `complete-summary-N.md` | yes |
| ST | `retrospective-N.md` | yes |
| IR | `incident-N.md` | yes |
| ET | `ethics-review-N.md` | yes |

### DV fan-out — ledger tasks

DV fans out as ledger tasks, never as sub-agents. `DV0`, `DV1`, … are rows in `state.json`: the
orchestrator dispatches each on its own `Agent()`, each writes its own artifact, each patches its own
row. No entry agent assembles a canonical file afterwards — every DV artifact is a handoff carrier
in its own right, and downstream stages reach them by iterating the rows.

Retries are per row (`retry_count`); every row appends to the shared
`.context/errors/developer.md` under its own `## DV<k> Retry <n> — …` heading.

#### Pinning a row's tree

Every DV row carries `metadata.workspace_path` from creation (`state-patch.sh --task-create` refuses
one without it; a TL stream clones DV0's), and the row's agent enters that path and no other.

An explicit `WORKSPACE_ROOT` that resolves to the orchestrator root marks a pinned session. A
linked worktree alone does not. In that mode, shared-tree DV streams run in numeric row order.
Before dispatch, the orchestrator blocks each later independent row on the nearest earlier row,
then rechecks the row's readiness because the ready list predates the block. It keeps both rows on
the assigned session tree and does not create stream worktrees. Existing transitive ordering stays
intact, and repeat dispatch adds no dependency.

##### Unpinned stream worktrees

Without that session pin, a DV row with `metadata.stream` gets its own stream worktree when another
DV row holds the same `metadata.workspace_path` and neither row reaches the other through `blocked_by`.
The orchestrator creates the tree, re-stamps `metadata.workspace_path` through
`state-patch.sh --task-meta`, and then renders the banner. Already serialized streams may share
one tree. Landing of declared `consumes` runs after either path selects its final tree.

#### Artifact naming (S1)

```text
artifact  := ".context/development-" N [ "-" stream ] ".md"
N         := tasks.<ID>.metadata.run_index          # integer >= 0
stream    := ^[a-z0-9]+(-[a-z0-9]+)*$               # kebab, <= 40 chars, unique among the DV rows
source    := assigned by the row's creator: PL0, TL when TL runs, or the DV agent that splits its
             own row (it stamps that row too); a stamped stream never changes
row keys  := tasks.DV<k>.metadata.stream   = "<stream>"
             tasks.DV<k>.metadata.artifact = ".context/development-<N>-<stream>.md"  # planned
             tasks.DV<k>.artifact          # recorded at completion; beats the planned value
rule      := >= 2 DV rows -> every DV row carries stream + artifact
             exactly 1 DV row -> stream MAY be omitted, artifact development-<N>.md
location  := the ledger's .context/ (the dir holding state.json), never a stream tree's
```

##### Finding the ledger from a stream tree

A DV working in a separate stream tree finds the ledger's `.context/` through
`skills/shared/scripts/resolve-root.sh` once no declared root (`--state`, `CONTEXT_DIR`) names it:
with no flag the script prints the main worktree's `.context` directory (exit 1 outside any
repository, 3 when the main worktree is bare).

##### The bare name is a grammar output

`development-<N>.md` is what the grammar emits for a single-DV run; it is not a name other text may
spell. Downstream templates and readers take DV artifacts from `refs.dev[]` or from the ledger
(§ Iterating the DV tasks), so that name reaches them only as an already-resolved list element.

#### Completing a DV row

The completion patch names both the row id and the path, because the orchestrator's basename guess
cannot see a stream suffix:

```bash
state-patch.sh --stage DV --task-id DV<k> --prev <PREV> \
  --artifact .context/development-<N>-<stream>.md
```

#### Iterating the DV tasks

Every downstream reader resolves its DV inputs from the ledger, in ascending numeric task-id order:

```bash
jq -r '.tasks | to_entries
  | map(select(.value.metadata.stage == "DV" and (.key | test("^DV[0-9]+$"))))
  | sort_by(.key | ltrimstr("DV") | tonumber)
  | .[] | (.value.artifact // .value.metadata.artifact // empty)' .context/state.json
```

Review diff source: the diff for those rows comes from `skills/worktask/scripts/stream-diff.sh`
(same order, one labelled block per row, base from `resolve_base_ref`), never a hand-written range.

A `refs.dev[]` element (`skills/worktask/assets/templates/template-dr.md#tpl-dr`) is that path's basename plus `#files-changed` —
replace the last line with:

```bash
  | .[] | ((.value.artifact // .value.metadata.artifact // empty) | split("/") | last) + "#files-changed"
```
