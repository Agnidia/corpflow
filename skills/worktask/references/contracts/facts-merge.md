# Facts merge

Read when merging a typed return or compressed facts into the ledger.

Read these sections only when this procedure cites them.

###### Section lookup 1

[DV fan-out — ledger tasks](artifact-map.md#dv-fan-out--ledger-tasks) · [Field notes — branch](ledger-field-notes.md#field-notes--branch)

<!-- canonical-body:start -->
### #schema-to-state-map

Each schema field maps onto the ledger (`skills/worktask/references/contracts/ledger-root.md#state-json-schema`) and the artifact anchor
(`skills/worktask/references/contracts/artifact-anchors.md#anchor-allow-list`). The map is channel-agnostic: the orchestrator applies it to a typed return
(`skills/worktask/references/dispatch-readiness.md § Orchestrator Execution Loop` Step 6), and populates the same targets
from the artifact's `handoff:` frontmatter when there is none (F2; an artifact without frontmatter, F3, populates nothing).

#### Map — PL, AR, TL

| Schema field | state.json target | Artifact anchor |
|--------------|-------------------|-----------------|
| `PL.verdict` | `tasks.PL0.verdict` | planning-N.md (frontmatter) |
| `PL.complexity` | `tasks.PL0.complexity` | planning-N.md `## complexity` |
| `PL.key_decisions` | `facts.decisions[]` | planning-N.md `## stages` |
| `AR.verdict` | `tasks.AR0.verdict` | architecture-N.md `## decisions` |
| `AR.key_decisions` | `facts.decisions[]` | architecture-N.md `## decisions` |
| `TL.verdict` | `tasks.TL0.verdict` | coordination-N.md `## fan-out` |
| `TL.fanout` | (DV sub-task prompts; not a ledger field) | coordination-N.md `## fan-out` |

#### Map — DV

Rows apply per DV ledger task: `<DV>` is the row's own id (`DV0`, `DV1`, …) and `<dev-artifact>`
its own artifact (§ DV fan-out — ledger tasks).

| Schema field | state.json target | Artifact anchor |
|--------------|-------------------|-----------------|
| `DV.verdict` | `tasks.<DV>.verdict` + `tasks.<DV>.status` (verdict map) + `facts.verdicts.<DV>` + derived `facts.verdicts.DV` | `<dev-artifact>` `## deviations` (summary line) |
| `DV.files_modified` | `facts.files_modified` (union) | `<dev-artifact>` `## files-changed` |
| `DV.tests_added` | `facts.tests_added` (union) | `<dev-artifact>` `## tests-added` |
| `DV.build_status` | (artifact only; status follows the verdict) | `<dev-artifact>` `## deviations` |
| `DV.tests_executed` | `tasks.<DV>.tests_executed` (current round) + `tasks.<DV>.rework_runs[]` (earlier rounds of a replayed row) | `<dev-artifact>` `## tests-added` |
| `DV.decisions` | `facts.decisions[]` | `<dev-artifact>` (inline) |

#### Map — DR, SR, QA, DC, RE

| Schema field | state.json target | Artifact anchor |
|--------------|-------------------|-----------------|
| `DR.verdict` | `tasks.DR0.verdict` + `facts.verdicts.DR0` + derived `facts.verdicts.DR` | developer-review-N.md `## verdict` |
| `DR.findings`/`blockers` | `facts.decisions[]` (= findings) | developer-review-N.md `## findings`/`## blockers` |
| `SR.*` | mirrors DR targets (`facts.verdicts.SR0`, derived `facts.verdicts.SR`) | security-review-N.md |
| `QA.verdict` | `tasks.QA0.verdict` + `facts.verdicts.QA0` + derived `facts.verdicts.QA` | testing-N.md `## verdict` |
| `QA.tests_executed` | `tasks.QA0.tests_executed` (current round) + `tasks.QA0.rework_runs[]` (earlier rounds) | testing-N.md `## results` |
| `QA.tests_passed`/`failed` | (artifact only; `facts.verdicts.*` holds verdicts, never counts) | testing-N.md `## results` |

#### Map — DC, RE

| Schema field | state.json target | Artifact anchor |
|--------------|-------------------|-----------------|
| `DC.verdict` | `tasks.DC0.verdict` | documentation-N.md `## files-changed` |
| `DC.files_modified` | `facts.files_modified` (union) | documentation-N.md `## files-changed` |
| `RE.verdict` | `tasks.RE0.verdict` | release-N.md `## version` |
| `RE.version` | `facts.decisions[]` (version) | release-N.md `## version` |

#### Map — FN, ST, IR, ET, worktree

| Schema field | state.json target | Artifact anchor |
|--------------|-------------------|-----------------|
| `FN.verdict` | `tasks.FN0.verdict` | complete-summary-N.md `## summary` |
| `FN.pr_url` | `handoffs["RE→FN0"]`/`DC→FN0`/`QA→FN0` (ref pointer); also `metadata.pr_url` (`--ledger-meta`) | complete-summary-N.md `## artifacts` |
| `ST.verdict` | `tasks.ST0.verdict` + `facts.verdicts.ST0` + derived `facts.verdicts.ST` | retrospective-N.md `## decision` |
| `IR.verdict` | `tasks.IR0.verdict` | incident-N.md `## root-cause` |
| `IR.root_cause` | `facts.decisions[]` | incident-N.md `## root-cause` |
| `ET.verdict` | `tasks.ET0.verdict` + `facts.verdicts.ET0` + derived `facts.verdicts.ET` | ethics-review-N.md `## verdict` |
| `DV.worktree_path` | `tasks.<DV>.worktree.path` | `<dev-artifact>` (frontmatter `worktree_path`) |
| `DV.worktree_branch` | `tasks.<DV>.worktree.branch` | `<dev-artifact>` (frontmatter `worktree_branch`) |

#### Additive-field writers

The v1 additive fields have orchestrator-loop / hook writers, not schema-mapped stage returns
(`facts.dispatched_agents[]`, `tasks.<ID>.last_error`, `tasks.<ID>.completed_via`,
`facts.capabilities` — `skills/worktask/references/dispatch-readiness.md § Orchestrator Execution Loop` steps 6/6.5).
Only `tasks.<ID>.worktree` maps from a stage artifact — the DV handoff frontmatter
`worktree_path`/`worktree_branch`, applied by `state-patch.sh` (rows above).

#### #facts-union

`facts.decisions[]`, `facts.open_questions[]`, `facts.files_modified` and `facts.tests_added` are
written by `state-patch.sh --facts '<json>'`, passed on the same self-patch call that lands the
stage's ledger row. It is the channel's only scripted writer.

##### #facts-union — who writes open_questions

`open_questions` is agent-written. A stage's closing-sweep stubs reach the ledger only if that
stage passes them in its own `--facts` payload; the two transports have no derivation between them,
so a stub written to frontmatter alone never reaches the FN gate.
`handoff-harness.sh --validate-frontmatter --state`, run at each stage completion
(`skills/worktask/references/workflow.md § Step B.1`), fails the stage when a sweep stub is missing from
`facts.open_questions[]`, when a stub present in both `handoff.open_questions[]` and
`facts.open_questions[]` carries a different `class` or `blocks_next_stage`, and when the ledger is
unreadable. The agent reconciles a divergence; the harness never joins it.

###### #facts-union — the merge table

The merge is a union, never `. * $patch`, because jq object-merge replaces arrays and would drop
an upstream stage's entries.

| Array | Identity | Collision | Order |
|---|---|---|---|
| `decisions` | `.id` | last writer wins | survivor moves to the tail |
| `open_questions` | `.id` | monotone join (`_union_sweep`): `status` `open < resolved`, `resolution` never dropped, `class` `decision < escalate` raise-only (an omitted class keeps the incumbent's; a refused downgrade exits 2 with a `facts_items_rejected` row) | survivor moves to the tail |
| `files_modified`, `tests_added` | the string itself | duplicate dropped | first-seen position kept |
| `stream_branches` (object) | the stream key | later value for that key wins; other keys kept | key insertion order |

##### Ordering and idempotency

Tail placement for the keyed arrays matters: the B3 clamp keeps the tail of each task's bucket, so
appending is what makes "newest survives" true after a union. Do not sort (`unique_by` does); that
hands the clamp an arbitrary survivor set.

Both shapes are idempotent: re-merging an already-merged payload leaves `state.json`
byte-identical, so a remediation loop may re-run its self-patch freely. A payload whose shape does
not match the table is rejected before the merge lock is taken. `--facts` applies ahead of the
completion merge, so facts still land when that merge short-circuits as idempotent.

#### Additive-field writers — facts.branch

Two writers, neither a stage agent: orchestrator at `skills/worktask/references/workflow.md § Step 3c`, and
`refine-branch-target.sh` at § Step A.4b (once per run, pre-commit, ledger-only, no git
mutation). `state-patch.sh --facts '{"branch": "<name>"}'` accepts the key as a scripted channel for
either writer: a string matching `^[A-Za-z0-9._/][A-Za-z0-9._/-]{0,199}$`, last writer wins, any
other value fails the payload (exit 2).

The orchestrator parses the final `branch=<name>` stdout line
of `branch-name.sh` and stamps it directly — `branch-name.sh` never writes state.json (single
write chokepoint, `skills/worktask/references/contracts/ledger-writes.md#atomic-write`). When that line is empty or non-conventional and
`target_branch=<name>` is not, the target is what gets stamped: the local rename can be
blocked (upstream tracked, target exists, host workspace) while the PR head is still the
pipeline's to name (§ Field notes — branch).

#### Additive-field writers — facts.stream_branches

One writer: FN on the multi-stream arm, passing the `facts=` line `fn-stream-merge.sh commit`
prints to `state-patch.sh --facts '{"stream_branches": {"<stream>": "<branch>"}}'`. Keys match the
S1 stream grammar (`^[a-z0-9]+(-[a-z0-9]+)*$`, ≤40), values the `branch` regex; any bad entry
fails the whole payload (exit 2) and `{}` is a no-op. It never touches `facts.branch`.

---
