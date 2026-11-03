# Prompt dispatch

Read when executing or checking prompt dispatch.

Procedure routing: [orchestration](orchestration.md).

<a id="section-lookup-1"></a>
Related: [Step 4.6](dispatch-context.md#step-46) · [Step 6.5](completion-merge.md#step-65)

<!-- canonical-body:start -->
### Cache-Friendly Prompt Layout & state.json (handoff-protocol)

Every delegation prompt is built in a fixed order so consecutive `Agent()` calls within one `worktask_id` share a byte-identical prefix and hit the prompt cache. Spec source: `skills/worktask/references/contracts/prompt-layout.md#cache-prefix`.

Each section opens with its own `<<<marker>>>` line and runs to the next marker — that is what `scripts/cache-lint.sh` parses. Section [1] is copied verbatim from `references/contract-reminder.md`. Section [3] is the ledger pointer plus readiness digest that `scripts/ledger-digest.sh` prints, never the ledger JSON: stage agents read `.context/state.json` from disk. Section [4b] is the per-model discipline block, copied verbatim from `skills/shared/model-prompting.md` and selected by `task.metadata.model`; `haiku` emits the marker with an empty body. `brief-compose.sh` copies these blocks verbatim; the orchestrator never writes them.

#### Composing the brief

Build every stage prompt by running `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/brief-compose.sh <TASK_ID> --orch-root <orch root>` and dispatching its stdout. The orchestrator is its only caller. The composer emits all eight markers: [1]–[5] complete, [6] empty unless the row carries `gate_from_stage` + `gate_blockers` (§ Step 4.6), and [7] opening with the task's `WORKSPACE_ROOT=` line. The Steps 4.5–5e injections write only into [6] and [7]; nothing edits [1]–[5]. Exit 1 (guard failure) or exit 2 (usage, unknown task id, unreadable ledger, missing jq or canon, failed ledger digest) leaves stdout empty: do not call `Agent()` — surface stderr and treat the row as a blocked dispatch (Step 6).

##### Cite sources in [6] and [7] by path

If text you write into [6] or [7] needs the PR section order or an allowed H2, cite the source by path instead of restating it: `skills/shared/git-conventions.md § Pull Request Format`, `skills/worktask/references/contracts/artifact-anchors.md#anchor-allow-list`. A copy drifts from its source, and the stage obeys the copy.

#### Preamble layout

```
[1] Contract reminder (references/contract-reminder.md) ← stable across ALL stages (cacheable)
[2] Worktask header (id, plan, exploration)← stable across ALL stages (cacheable)
[3] Ledger pointer + readiness digest (from ledger-digest.sh) ← evolves per stage
[4] Stage contract excerpt                 ← stable WITHIN stage type (cacheable)
[4b] Model discipline block                ← stable WITHIN stage type (cacheable)
─────── (cache prefix boundary) ───────
[5] Task identifiers + ref: lines          ← dynamic per delegation
[6] retry hints (if retry_count > 0) + REMEDIATION (brief-compose.sh) ← dynamic per delegation
[7] Stage-specific banners (DR Skill, FN Conductor, MCP fallback) ← SUFFIX, dynamic
```

[5]'s lines and ref shapes: `skills/worktask/references/contracts/prompt-layout.md § Section [5] — task identifiers and refs`.

#### Step 0 — section [3] comes from ledger-digest.sh

```typescript
// Section [3] body: the ledger pointer plus readiness digest, grammar in
// skills/worktask/references/contracts/prompt-layout.md#cache-prefix. brief-compose.sh (Step 6) makes this call for
// every delegation and is its only caller, so [3] cannot drift from the lint that checks it.
const digest = execFileSync("bash", ["skills/worktask/scripts/ledger-digest.sh",
                                     "--state", ".context/state.json"], { encoding: "utf8" });
// Exit 3 means the ledger is missing or unparseable: the composer exits 2 and nothing is
// dispatched — a hard failure, not a degraded mode.
```

#### Artifact path helper

Resolves the numbered artifact path with fallback:

```typescript
const ARTIFACT_BASE: Record<string, string> = {
  PL: "planning", AR: "architecture", TL: "coordination",
  DV: "development", DR: "developer-review", SR: "security-review",
  QA: "testing", DC: "documentation", RE: "release",
  FN: "complete-summary", ST: "retrospective", IR: "incident",
  ET: "ethics-review",
};
```

##### stageArtifactPath()

```typescript
// …continued: uses ARTIFACT_BASE above
function stageArtifactPath(code: string, runIndex: number, row?: TaskRow): string {
  // A row naming its artifact wins: a DV stream's suffix cannot be composed from `code`.
  const named = row?.artifact ?? row?.metadata?.artifact;
  if (named) return named;
  const base = ARTIFACT_BASE[code];
  const numbered = `.context/${base}-${runIndex}.md`;
  if (fs.existsSync(numbered)) return numbered;
  // Newest-glob fallback (covers out-of-band writes)
  const matches = glob.sync(`.context/${base}-*.md`).sort((a, b) => {
    const n = (f: string) => parseInt(f.match(/-([0-9]+)\.md$/)?.[1] ?? "0", 10);
    return n(a) - n(b);
  });
  if (matches.length > 0) return matches.pop()!;
  // No artifact on disk: return the canonical numbered path so the
  // caller's existence check surfaces the miss at the expected location.
  return numbered;
}
```

#### Step 6.5 — After Agent() returns, enforce state.json patch

After every `Agent()` return and before Step 7 settles the row, first read any
`requests_stage_escalation` in the artifact frontmatter (§ Mid-run escalation — the orchestrator
is the consumer), then run the three-layer check: Layer 1 (agent self-patch) → Layer 2
(`state-patch.sh --via step6_5`) → Layer 3 (F3 derivation). Code and semantics: loop § Step 6.5
below.

##### Completion signal (subagents run in the background by default)

"`Agent()` return" means the completed stage result, not the launch acknowledgement: the result arrives as a completion notification while the orchestrator keeps its turn. Run Step 6.5 (and the Step 7 settle that follows) only once that notification — or the stage's `subagent_stopped` audit row — has arrived. Don't fire Layer 3 (F3) while the stage's `agent_id` is still live in `claude agents --json`: F3 would stamp a status over a running stage. An errored return (rate limit, API cut-off) reports the error with partial work preserved: classify it per `skills/agent-coordination/SKILL.md § Retry / Escalate Matrix` (`transient`) and skip the completion patch.

###### Dispatch-tracking helpers (steps 6a/6.5 — ledger writes; [3] only points at the ledger)

```typescript
// markDispatchStatus — dispatched_agents[] with the task_id entry flipped to `status`,
// optionally backfilling model_resolved. Replace-array semantics (jq `. * $patch` overwrites
// arrays). Absent entry → array unchanged (defensive).
function markDispatchStatus(state, taskId, status, modelResolved) {
  return (state.facts?.dispatched_agents ?? []).map(a =>
    a.task_id === taskId
      ? { ...a, status, ...(modelResolved ? { model_resolved: modelResolved } : {}) }
      : a);
}
```

###### Dispatch result helper contracts

- `classifyError`: use the existing Retry / Escalate Matrix; rate-limit/API cut-off is `transient`.
- `errorBasename`: the last colon segment of `subagent_type`.
- `effortRank`: the ascending index from `effort-ladder.sh`.
- `effortResolvedFromHookRows`: the last stage `hook:audit-tooluse` row's `metadata.effort` in `.context/logs/audit.jsonl`.
  Return null for absent rows or `unknown`; never substitute the requested tier.


###### Shell quoting for headless dispatch

```typescript
// shellQuoteAll — the headless-dispatch.sh Bash-string call site's only quoting layer: every
// token is single-quoted, with an embedded single quote escaped as close-quote, literal quote,
// reopen-quote ('\''). Belt-and-suspenders over the caller's own validation (task id regex,
// session-id uuid regex, a fixed path), not the only guard against shell metacharacters.
function shellQuoteAll(args: string[]): string {
  return args.map(a => `'${String(a).replace(/'/g, `'\\''`)}'`).join(" ");
}
```

###### Banner relocation & cache-prefix hygiene

Stage-specific banners (DR Skill, FN Conductor, MCP fallback warning) are appended after `full.description` (suffix), never prepended, so prefixes [1][2][3][4] stay byte-identical across stages.

Sections [1][2][4][4b] carry no timestamps, per-call ENV expansions, random IDs, retry counters, file mtimes, or agent names beyond `worktask_id`. `scripts/cache-lint.sh` asserts that byte-stability across consecutive stages of one `worktask_id`.
