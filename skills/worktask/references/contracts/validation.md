# Validation

Read when executing or checking validation. Read linked modules only when their conditions apply.

<!-- canonical-body:start -->
## Validation Protocol

The orchestrator runs validation between a stage's `completed` patch and the next stage's `in_progress`. On failure at any step, don't transition: append a `missing_input` entry to the *next* stage's error file and block until resolved.

### Steps 1–2

1. File check: every file in the next stage's `metadata.context_refs` exists on disk. A missing `metadata.error_file` means "no prior retries", not a failure.
2. Frontmatter / typed-return check: a valid typed object returned by the stage's `Agent()` (the orchestrator passed the `schema` from `skills/worktask/references/contracts/typed-conventions.md#handoff-schemas` and the runtime honoured it) supersedes this step. Verdict and facts come from the validated object via `skills/worktask/references/contracts/facts-merge.md#schema-to-state-map`, and the grep below is skipped.

#### Step 2 — no-typed-return grep path

With no typed return (the dispatch primitive takes no `schema` argument, or the stage returned no typed object), the check is a grep: `head -1 <artifact>` equals `---`, and `grep -c '^handoff:' <artifact>` equals `1` within the top-of-file block. Missing frontmatter triggers fallback path F3 (the orchestrator derives a minimal handoff record). The agent writes the on-disk `.context/<artifact>-N.md` and its `handoff:` frontmatter in both cases; it stays the durable, compressed form and the F4 regeneration source.

### Steps 3–5

3. Anchor lint (every stage boundary): every produced artifact's H2 headings match its stage's allow-list in `skills/worktask/references/contracts/artifact-anchors.md#anchor-allow-list`. `handoff-harness.sh --validate-frontmatter` fails the transition on a missing required or an unexpected H2; at write time `hooks/anchor-preflight.sh` denies a `PreToolUse` Edit that adds an unexpected H2 and reports a Write's off-list H2 or frontmatter finding on `PostToolUse`, for an Edit fix (`handoff-protocol.md § Anchor Pre-Flight`). No CI counterpart exists.
4. Section check: grep the output artifact for required section headers.
5. Side-artifact check: for DV/QA, the corresponding `.context/logs/` build/test capture exists.

### Steps 6–8

6. Metadata check: task `metadata` validates against `state-ledger` § JSON Schema.
7. Error file check: if `retry_count > 0`, `metadata.error_file` exists on disk. If it is set but absent (the orchestrator stamped the path, no agent has appended yet), treat it as `retry_count = 0` rather than a failure. The first appending agent creates it (`mkdir -p` its parent, then append the retry block).
8. state.json patch check: after `Agent()` returns, re-read `.context/state.json`. If `tasks.<ID>.status` is still `in_progress`, parse the artifact's `handoff:` frontmatter and atomic-merge it in (the third safety layer; `skills/worktask/references/contracts/fallbacks.md#fallback-paths` F2/F3).

### Step 9 — AR-reference check (DV completion, warn-only)

9. At DV completion, if `.context/state.json` has a `tasks.AR0` entry, run:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/handoff-harness.sh --validate-frontmatter <the DV row's artifact> \
     --state .context/state.json
   ```

   A `warn:` line appends an audit row to `.context/logs/audit.jsonl` —
   `{"action":"ar_ref_check","result":"warn", …}` — surfaced in the DR dispatch prompt so DR
   reviews the missing linkage. It is not a `missing_input` block and does not stop the
   transition. The orchestrator passes `--strict` (blocking) only when `CORPFLOW_AR_REF_STRICT=1`
   is set.

#### Step 9 — dispatch-time companion check

When AR completed, the DV0, DR0 and QA0 tasks each carry `metadata.architecture_ref` (`{path, anchors, key_decisions}`) and name an `architecture-N.md` anchor in `context_refs`. When AR was excluded, none of them carries either.

## Cross-Plugin Stages

When a stage is delegated to a qualified agent (e.g., `apple-developer:ios-developer` takes over DV):

- `metadata.agent` keeps the full qualified name; `metadata.error_file` derives from its last segment, collisions joined with `-` (`state-ledger` § error_file derivation).
- The output artifact path is the one on the stage's own ledger row (`metadata.artifact`) regardless of which plugin implemented it — a qualified DV agent writes its row's artifact exactly as `corpflow:developer` would.
