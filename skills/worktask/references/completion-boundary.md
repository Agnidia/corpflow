# Completion boundary

Read when executing or checking completion boundary.

Procedure routing: [orchestration](orchestration.md).

<!-- canonical-body:start -->
#### Structural handoff gate — before the next dispatch

Save the exact stage return under `.context/logs/return-<ID>-<timestamp>.log`.
Run one consolidated validation before dispatching a consumer:

```bash
bash "$PLUGIN_ROOT/skills/worktask/scripts/handoff-harness.sh" \
  --validate-transition "$ARTIFACT" --state "$STATE" --return-file "$RETURN_FILE"
```

Only a `pass` result permits the transition. A blocked result leaves acceptance and dependent stages pending.
Read every reported error together. Fix schema defects before attempting compression.

##### Compression repair

For artifact budget failures, permit one compression attempt by the owning stage or a trusted `--compressor <executable>`.
The executable receives one candidate path as an argument; the helper never evaluates a shell command.
Retain acceptance criteria, unresolved blockers, decisions, and evidence references during compression.
The helper preserves protected content verbatim and retains the original and failed candidate for repair.
An unchanged artifact hash cannot invoke the compressor twice, including after an interrupted attempt.
If the repaired artifact still fails, stop the transition and preserve the evidence for manual repair.
Do not repeat the original stage or trim protected fields to satisfy a budget.

##### Structural measurements

The checker labels word-based token estimates separately from measured provider usage.
The ledger's 500-token proxy threshold retains its existing warning severity and supplies an eviction hint.
Its structural guard rejects unbroken prose over 1,024 Unicode characters; valid URLs and existing file paths are exempt.

#### Step 6.6 — blocking sweep items, before the next dispatch

```typescript
    // 6.6. After the completed patch lands and BEFORE the next stage is dispatched, deal with
    //      this stage's blocking sweep items: facts.open_questions[] entries this stage wrote
    //      with blocks_next_stage == true and status != "resolved". Two passes, in order.
```

##### Step 6.6a — resolve

```typescript
    // 6.6a RESOLVE (workflow.md § Step C.0a). Skipped for PL/FN/ST/IR, and when
    //      decision_gate != "auto". Otherwise run C.2's raise-only join FIRST, then hand the
    //      surviving effective_class == "decision" items to the emitting stage's OWN agent on
    //      its OWN model, at `effort-ladder-cli.sh for-resolver <effort> <model>` (the
    //      allow-listed CLI over scripts/effort-ladder.sh). One dispatch for the whole set. No metadata.effort on the
    //      row => audit resolver_skipped/effort_unstamped and fall through; never guess a tier.
```

###### Route the resolver tier

```typescript
    //      Call scripts/effort-route.sh with the bumped tier, exactly as Step 6 does. The
    //      default is in-process with Agent({ effort: <bumped tier> }) — "agent-param"; only
    //      CORPFLOW_HEADLESS_ROUTE=on sends it headless via
    //      scripts/headless-dispatch.sh. Audit effort_transport (agent-param|dispatch-flag|
    //      none) from the route's own output. "agent-param" takes effort_resolved
    //      from the subagent's hook row (metadata.effort), else null + "no_hook_rows". Only
    //      "none" (haiku) records "requested, not applied". Never swap in a different agent.
```

##### Step 6.6b — render the remainder

```typescript
    // 6.6b RENDER (workflow.md § Step C.0) whatever 6.6a left: every escalate item,
    //      everything the resolver declined, and every item on the four exception stages. It
    //      reuses C.2-C.5 verbatim, audit subject `<CODE><N>` rather than `FN<N>`.
    //      Not a gate: the same render, moved earlier for items whose answers the next
    //      stage needs. Bypass records decision items only; escalate items stop, park, or —
    //      in a no-human lane only — are recorded (workflow.md § Escalation guard —
    //      escalate stops at every boundary), so nothing deadlocks.
```
