# Dispatch context

Read when executing or checking dispatch context.

Procedure routing: [orchestration](orchestration.md).

<!-- canonical-body:start -->
#### Step 4.0

```typescript
    // 4.0. Re-read the live ledger every iteration — dispatched_agents[], last_error and
    //      facts.capabilities evolve per stage. state.json is ≤500 tokens; an unreadable
    //      ledger is a hard failure, never a degraded mode.
    state = JSON.parse(fs.readFileSync(".context/state.json", "utf8"));

    // 4. Full task details come from the ledger entry itself.
    const full = state.tasks[task.id];
    const agentType = full.metadata.agent;
    const model = full.metadata.model;
    // [5] is the composer's, so the ledger text is never dispatched. full.description becomes the
    // injection buffer: text prepended before the sentinel is [6], text appended after it is [7].
    const INJECTION_SPLIT = "@@injection-split@@";  // no injection text contains it
    full.description = INJECTION_SPLIT;
```

##### Agent-type resolution

```typescript
    // bare → "corpflow:<name>"; "plugin:name" → as-is; 3-part "a:b:c" → UNSUPPORTED, throw.
    //   .context/errors/<basename>.md basename = the last `:`-segment. Depth never legitimizes
    //   a 3-part name, and CC rejects `:` in an agent file's own frontmatter `name:` — the
    //   qualified form exists only at the call site, never in the file.
    const colonCount = (agentType.match(/:/g) ?? []).length;
    if (colonCount > 1) {
      throw new Error(`Invalid agent reference '${agentType}': only bare or plugin-qualified names supported.`);
    }
    const subagentType = colonCount === 1 ? agentType : `corpflow:${agentType}`;
```

#### Step 4.5

```typescript
    // 4.5. Soft context_refs validation — warn, don't abort: low-complexity worktasks
    //      legitimately skip upstream stages, and error_file absence on the first
    //      attempt (retry_count === 0) is expected, not a warning.
    if (full.metadata.context_refs) {
      const listed = JSON.parse(full.metadata.context_refs)
        .map(r => r.split('#')[0].trim());
      const retryCount = full.metadata.retry_count ?? 0;
      const missing = listed.filter(p =>
        !fs.existsSync(p.startsWith('.context/') ? p : `.context/${p}`) &&
        !(p === full.metadata.error_file && retryCount === 0)
      );
      if (missing.length > 0) {
        full.description =
          `NOTE: Expected context files missing: ${missing.join(', ')}. ` +
          `Proceed using what is available; do not fabricate content.\n\n` +
          full.description;
      }
    }
```

#### Step 4.6-pre

```typescript
    // 4.6-pre. last_error hint — on a retry, prepend one line summarizing the prior errored
    //          return (class + partial + ref) so the re-dispatch targets the recorded failure
    //          instead of re-inferring it. Reads tasks.<ID>.last_error written by Step 6.5a.
    if ((full.metadata.retry_count ?? 0) > 0) {
      const le = state.tasks?.[task.id]?.last_error;
      if (le) {
        full.description =
          `PRIOR ERROR (class=${le.class}` +
          `${le.partial ? ", partial work preserved" : ""}` +
          `${le.ref ? `, see ${le.ref}` : ""}). Resume/repair from that point.\n\n` +
          full.description;
      }
    }

```

#### Prompt-injection steps 4.6–4.8b — shared rules

These steps mutate only `full.description`: resume blocks are prepended (dynamic section [6]),
enforcement banners appended (suffix [7]) — cache prefix [1][2][4][4b] is never touched. Each
fires one audit row; 4.6's block and row come from `brief-compose.sh`, not from this loop. A
missing row for a dispatch shows the loop was bypassed. Readers (DR, TL) surface it as an advisory
finding, not a hard fail, because a stale plugin cache serving an older loop would otherwise block
a blameless DV.

#### Step 4.6

```typescript
    // 4.6. Gate-feedback injection — rendered by brief-compose.sh, for a target of ANY stage.
    //      Two sources write the row it reads. A gate loop-back: a prior DR `verdict:fail` /
    //      QA `verdict:no-go` re-dispatches DV (run_index unchanged, retry_count up by 1) carrying the
    //      upstream remediation, one flattened line per item. Source for N = the failing upstream run_index:
    //      `.context/developer-review-N.md` (DRHandoff.blockers[]) and/or `.context/testing-N.md`
    //      (QAHandoff.blocking_defects[]). Or a typed correction: `--task-reopen` wrote the same two
    //      keys on the re-opened target and raised `fix_round`
    //      (references/return-arms.md § Step 6.5a3 — the correction arm).
    //      Hook surface: hookSpecificOutput.additionalContext —
    //      skills/agent-coordination/references/hook-monitoring.md §"Gate-feedback contract".
```

##### Step 4.6 — remediation injection & audit

Correction re-opens a task of any stage; gate loop-back reaches DV. `brief-compose.sh` is the only
writer of the remediation block: the orchestrator neither prepends it nor appends its audit row.
When the row carries a non-empty `gate_from_stage` (the raising stage's code, written by the
Step 7 loop-back or `--task-reopen`) and a non-empty `gate_blockers`, the composer writes into [6]
the line `REMEDIATION (from <code> gate — fix these specific findings before re-stop):` and one
numbered line per blocker. Control bytes become spaces and off-root paths become
`[off-root path]`. After printing, it appends one `gate_remediation_injected` row with
subject = task id. A failed write warns and keeps exit 0 (§ Prompt-injection steps 4.6–4.8b —
shared rules). Contract: the script's header.
