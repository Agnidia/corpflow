# Prompt layout

Read when composing or checking the stable prefix of a stage prompt.

<!-- canonical-body:start -->
## #cache-prefix

Anthropic prompt cache matches by prefix equality, not full-block equality, so the orchestrator builds the preamble in this order to maximize the byte-identical prefix shared across consecutive `Agent()` calls within one `worktask_id`.

### Preamble layout (binding)

```
<<<contract-reminder>>>
[1]  Plugin/agent contract reminder         ← stable across ALL stages
<<<worktask-header>>>
[2]  Worktask header (id, plan, exploration)← stable across ALL stages
<<<state-json>>>
[3]  Ledger pointer + readiness digest (from ledger-digest.sh) ← evolves per stage
<<<stage-contract>>>
[4]  Stage contract excerpt (this stage)    ← stable WITHIN stage type
<<<model-discipline>>>
[4b] Model discipline block                 ← stable WITHIN stage type
─────── (cache prefix boundary for sections 1+2+4+4b sharing) ───────
<<<task-description>>>
[5]  Task identifiers + ref: lines          ← dynamic per delegation
<<<retry-hints>>>
[6]  retry hints (if retry_count > 0); REMEDIATION block written by brief-compose.sh ← dynamic per delegation
<<<stage-banners>>>
[7]  Stage-specific banners (DR Skill, FN Conductor, MCP fallback) ← suffix only
```

### Section markers (binding)

Each section opens with its `<<<marker>>>` on a line of its own and runs to the next marker or
to the end of the prompt; there are no closing tags. The markers are required:

- The lint parses them. `cache-lint.sh` prefix mode extracts sections by marker, so the
  layout above is what makes an assembler's output checkable rather than guessed at.
- Section [3] needs its marker. Without `<<<state-json>>>`, [2] runs to `<<<stage-contract>>>`
  and swallows the digest, which evolves every stage — byte-identity then fails on a section that
  never changed. [3] itself is a ledger pointer plus a readiness digest, never the ledger JSON
  (§ Section [3] — ledger pointer and readiness digest).
- They separate instruction from data. [3] is a `key: value` digest and [5] is ledger-copied
  identifier and `ref:` lines, both sitting between blocks of instructions.

#### Section [3] — ledger pointer and readiness digest

Stage agents read `.context/state.json` from disk; [3] only tells them where it is and what is
ready. Grammar (exact key order, one `key: value` per line, no JSON, no timestamps):

```text
<<<state-json>>>
ledger: .context/state.json
run_index: <integer>
ready: <task ids, comma-separated, ascending key order | none>
in_progress: <ids | none>
blocked: <ids | none>
open_blocking_questions: <integer>
```

`skills/worktask/scripts/ledger-digest.sh` is the one executable copy: it prints this body without
the marker. `ready` is pending with every blocker completed, `blocked` is `status == "blocked"`,
and `open_blocking_questions` counts `facts.open_questions[]` with `blocks_next_stage == true` and
a `status` other than `resolved`.

### Section [4b] — model discipline block

Copied verbatim from `skills/shared/model-prompting.md`, selected by `task.metadata.model`. It
is inside the cache prefix for the same reason [4] is: a stage's model is fixed for the stage's
lifetime (`skills/worktask/references/dispatch-agent.md § Worktask stages: explicit, never inherited`), so
the block is stable within stage type even though it varies across the pipeline.

`haiku` has no block; its marker is emitted with an empty body rather than omitted, so the
section count does not vary by model.

The orchestrator copies this text and never composes it; `cache-lint.sh` catches a composed
block. Why the blocks live in one canon file rather than in the agent definitions:
`model-prompting.md § Why this lives at dispatch`.

### Section [5] — task identifiers and refs

`brief-compose.sh` writes [5]; the ledger's `task.description` is not copied into it — the agent
reads it from `.context/state.json` on disk, the file [3] points at. The section
is identifier lines copied verbatim from the ledger (`task_id`, `stage`, `agent`, `model`,
`artifact`, `subject`), then `ref:` lines only. A ref value has one of three shapes:

- `file:line` — plugin-root-relative, else under a `workspace_path`;
- `artifact#anchor` — an artifact in the resolved `.context` directory with a `## <anchor>` heading;
- a plain path to an existing file — from `metadata.context_refs` only.

Each `ref:` value appears once; the first occurrence keeps its place.
A ref that does not resolve fails the compose with exit 1 and an empty stdout.

### Forbidden tokens in sections [1], [2], [4], [4b]

Anything below collapses cache-hit rate:

- Timestamps (`date`, `now`, ISO-8601 strings)
- ENV expansions that vary per call (`$HOSTNAME`, `$USER`, `$PWD` if it differs)
- Random IDs (UUIDs, `$RANDOM`, request IDs)
- Retry counters (move to section [6])
- File mtimes
- Agent-specific names beyond `worktask_id` (don't bake `software-architector` into [1] or [2]; that goes in [4])
- Conversation message IDs

### Required tokens in sections [1], [2], [4], [4b]

- `worktask_id` (string literal in [2])
- `plan_file` path (string literal in [2])
- Contract reminder text (section [1]) — drawn from `skills/worktask/references/contract-reminder.md`, copied verbatim
- Stage contract excerpt for this stage type (section [4]) — drawn from `skills/worktask/references/stage-contracts.md`, copied verbatim
- Model discipline block for `task.metadata.model` (section [4b]) — drawn from `skills/shared/model-prompting.md`, copied verbatim

### Expected cache_read_input_tokens ratio

- Stage 1 (PL): 0% (cold cache).
- Stage 2..N, no retry: ≈ 20% (cross-stage prefix [1]+[2] cached).
- Stage 2..N, retry within same stage with the [3] digest unchanged: ≈ 80% (full preamble cached).
- [3] is six short lines, the first a pointer, so each stage prompt carries the digest in place of the ≤500-token ledger.
- Cross-stage average: ≈ 60%.

### Settings

```json
{ "env": { "ENABLE_PROMPT_CACHING_1H": "1" } }
```

Documented in `skills/cost-optimization/SKILL.md`. Without the 1h flag the default 5-min TTL applies: retries inside a stage still save, cross-stage cache is lost between long-running stages.

### Lint

`skills/worktask/scripts/cache-lint.sh` asserts byte-identity of sections [1]+[2] across consecutive stages of the same `worktask_id`, and of sections [4]+[4b] across calls sharing a `(worktask_id, stage)` pair. When a log line carries `model`, it also asserts that [4b] matches the block `model-prompting.md` carries for that alias — a stage dispatched on one model carrying another's block is a routing miss that byte-identity alone cannot see. Lines without the field skip that check, so an emitter that omits it leaves the check dormant. A line carrying `"contract_canon": true` opts in the same way for [1], which must then equal the fenced block in `contract-reminder.md`. Every line with a [3] section is checked for the `ledger: .context/state.json` first line, all six keys in order, and no embedded ledger.

`brief-compose.sh` is the assembler this spec binds; it writes no `prompt-log.jsonl`, so prefix mode stays fixture-gated.

#### Fixture-gated, not log-gated

Prefix-lint consumes a `prompt-log.jsonl` (`{worktask_id, stage, model, prompt}` per line, `model` being the resolved `task.metadata.model` alias) that nothing here emits — the live harness assembles prompts in `benchmark/harness/benchmarklive/dispatch.py` but persists only stage stdout — so it is exercised by `cache-lint.sh --self-test` fixtures. CI runs that mode on every PR (`.github/workflows/test.yml`), which gates the lint's own parser; no captured prompt is checked until an emitter exists.

---
