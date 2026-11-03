# Fallbacks

Read when executing or checking fallbacks. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
## #fallback-paths

Three documented degradation paths. The ledger itself is not one of them: `state.json` is
mandatory, and its absence is a hard failure rather than a recoverable mode.

| Path | Trigger | Behavior |
|------|---------|----------|
| F2 | state.json present, agent ignores it | No penalty. Agent reads the anchors it was given and writes its artifact. Orchestrator's hook patches state.json from frontmatter; with no frontmatter (F3) nothing is patched. |

### Paths F3–F4

| Path | Trigger | Behavior |
|------|---------|----------|
| F3 | Agent writes artifact without frontmatter | Orchestrator logs WARN `frontmatter missing in <artifact>`. No handoff is derived and nothing is written: `state-patch.sh` refuses a missing verdict with exit 3 and `state.json` unchanged. The row stays `in_progress`, and `skills/worktask/references/completion-merge.md § Step 6.5a2` resumes the stage. |
| F4 | state.json corrupt (invalid JSON or schema mismatch) | Back up to `.context/state.json.corrupt.<iso-ts>`. Rebuild the skeleton only, then recover exactly the one stage being patched by delegating to `state-patch.sh` unchanged. Audit row `state_repair` in `.context/logs/audit.jsonl`. Continue. |

#### F4 — partial recovery, by design {#f4-partial}

Three intended behaviours, not defects:

- The backup is `.context/state.json.corrupt.<iso-ts>`, so sorting by name sorts by time and the
  suffix says what happened.
- The audit trail is the `state_repair` row in `.context/logs/audit.jsonl`; there is no separate
  recovery log.
- There is no completed-stage frontmatter walk. The hook rebuilds the skeleton (including an empty
  `tasks: {}`) and recovers only the stage whose patch triggered the repair, because a full walk
  would be a second, divergent artifact parser beside `state-patch.sh`'s.

#### F4 — consequences for readers {#f4-consequences}

A repaired ledger can legitimately show fewer completed stages than `.context/` contains —
earlier stages are not replayed. Reconstruct history from the artifacts, not the ledger.

Fail-safe: if the backup cannot be written (unwritable `.context/`), the repair aborts,
`state.json` is left byte-identical, no backup and no audit row are written, and the hook still
exits 0. Corrupt-and-untouched is the designed outcome; an unchanged ledger is not evidence the
hook failed to run.

#### The ledger is mandatory {#f1-fallback}

The handoff mode is anchor-based: a stage reads `.context/state.json` plus the anchors named in
`metadata.context_refs` (≥30% input-token reduction, cache-friendly preamble).

There is no whole-file fallback list. If `state.json` cannot be read, the stage stops and reports
rather than guessing at its inputs. A read-only or unwritable `.context/` is an environment defect
to fix, not a mode to accommodate.

### F4 regeneration walk

Manual rebuild only — the hook never walks (`skills/worktask/references/contracts/fallbacks.md#f4-partial`). Runbook: `agents/workflow-engineer.md`.

1. Glob every canonical artifact basename (`skills/worktask/references/contracts/artifact-map.md#stage-artifact-map`) as `<basename>-*.md`.
2. Extract `handoff:` frontmatter from each (yq or fallback parser).
3. Sort by stage order: PL, AR, TL, DV, DR, SR, QA, DC, RE, FN, ST, IR, ET.
4. Seed state.json from PL0's frontmatter.
5. Per subsequent stage, merge `tasks.<ID>` and add `handoffs["<PREV_CODE>→<ID>"]` — one edge per
   task, so a split stage contributes one per stream.
6. Atomic-write per `skills/worktask/references/contracts/ledger-writes.md#atomic-write`.

---
