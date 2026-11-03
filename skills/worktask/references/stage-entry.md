# Stage entry

Read when executing or checking stage entry.

Procedure routing: [workflow](workflow.md).

<!-- canonical-body:start -->
##### After Step A — scripts the loop runs directly

Step numbers below refer to orchestration.md.

These scripts use the entry skill's grants.

```bash
# Assigned root after any re-pin — § Step 4.8
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/workspace-root-banner.sh --task "<TASK_ID>"
# Land a producer's artifacts — § Step 4.7a
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/land-artifacts.sh --producer "<TASK_ID>"
# Re-land what a row consumes — § Step 4.8
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/land-artifacts.sh --consumer "<TASK_ID>"
# The tree's landed set — § Step 6.5a3
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/land-artifacts.sh --list-landed --tree "$_orch_root"
# Loop-back rows — § Step 7
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/loopback-targets.sh --state .context/state.json --gate "<GATE_ID>"
```

A refused landing is reported, never worked around (skills/worktask/references/completion-merge.md § Step 6.5d).

#### Workspace-root cross-check

Conductor-managed sessions spawn the orchestrator inside a workspace clone whose `pwd` differs from
the canonical plugin source repo. Before every `Agent()` call in the stage loop, verify that the
working tree matches the task's declared workspace, and inject the resolved root into the stage
prompt so the subagent targets the right directory.

##### Cross-check snippet

```bash
# Runs in the orchestrator turn, not in the subagent
_orch_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
_task_root=$(jq -r '.metadata.workspace_path // empty' .context/state.json)
# Unset is a defect, not a mode: defaulting it to $_orch_root compares a value to itself,
# so the check passes unconditionally and an unstamped ledger reads as clean — which also
# leaves dv-tree-preflight.sh and developer.md's path-prefix check inert.
if [ -z "$_task_root" ]; then
  echo "⚠ state.json has no .metadata.workspace_path — the assigned-tree guards are ALL inert. Stamp it with a --ledger-meta patch." >&2
  # Write audit row `workspace_path_unstamped` and stop; do not call Agent()
  exit 1
fi
if [ "$_orch_root" != "$_task_root" ]; then
  echo "⚠ cwd mismatch: orchestrator is at $_orch_root but task.metadata.workspace_path is $_task_root. Aborting delegation until resolved." >&2
  # Write audit row and stop; do not call Agent()
  exit 1
fi
```

##### Banner injection

The task's `WORKSPACE_ROOT=` line opens section [7] of every stage prompt (the suffix, per the
cache-prefix spec) so the subagent knows which directory to target. It arrives through the composer,
which emits `workspace-root-banner.sh`'s stdout as [7]'s first line; do not append it again. The
value is `tasks.<ID>.metadata.workspace_path` when set, else the orchestrator root — never the
ledger-level path, which names the orchestrator's tree and hides a DV stream's own:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/brief-compose.sh "<TASK_ID>" --orch-root "$_orch_root"
# stdout is the whole brief, [7] opening with the banner line; exit 1 or 2 means do not call Agent()
```

Failure mode prevented: `workspace-modes.md § Conductor Workspace Topology`.

#### Post-delegation state.json enforcement

After every `Agent()` return (the completed stage result — for a background subagent that is the
completion notification, not the launch acknowledgement), before Step 7 settles the row:
re-read `.context/state.json`; if `tasks.<ID>` does not already carry the artifact's
`handoff.verdict` and the status it maps to (`skills/worktask/references/contracts/ledger-tasks.md § tasks — verdict → status`), run
   ```bash
   CLAUDE_ARTIFACT_PATH=".context/<artifact>-N.md" \
   CLAUDE_TASK_METADATA_STAGE="<CODE>" \
   STATE_MERGE_VIA=step6_5 \
   bash .claude/hooks/state-merge.sh
   ```

##### Layer-3 stamp and F3 fallback

`STATE_MERGE_VIA=step6_5` stamps `tasks.<ID>.completed_via=step6_5` so this synchronous Layer-3 path
is distinguishable from the SubagentStop-hook Layer-2 default (`hook`). Then re-read; if the row
still does not match, apply the F3 fallback: it stamps the verdict-mapped status (plus
`metadata.gate_from_stage` when that status is `pending`) with `completed_via: "f3"`, and writes
nothing for an absent handoff or an unmapped verdict — this covers environments where the
SubagentStop hook never fired. Full three-layer logic: `skills/worktask/references/dispatch-readiness.md § Orchestrator Execution Loop` Step 6.5.

### Step B — AR-reference check at DV completion

The AR-reference arm fires only when `.context/state.json` has a `tasks.AR0` entry (AR is optional —
`skills/estimation-methodology/SKILL.md § Stage Inclusion Criteria`). The invocation itself is the
§ Step B.1 call every stage makes. It runs once per DV row, on that row's own artifact, as the row
completes; DR0 is dispatched only after every DV row has passed it:

```bash
STRICT_FLAG=""
[ "${CORPFLOW_AR_REF_STRICT:-0}" = "1" ] && STRICT_FLAG="--strict"
# The completing row names its artifact; a stream suffix cannot be composed from N.
DEV_ARTIFACT=$(jq -r --arg id "$TASK_ID" \
  '.tasks[$id] | .artifact // .metadata.artifact // empty' .context/state.json)
# shellcheck disable=SC2086
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/handoff-harness.sh --validate-frontmatter "$DEV_ARTIFACT" \
  --state .context/state.json $STRICT_FLAG $LEGACY_TE_FLAG
```

#### Step B rollout and opt-in

**Warn-only by default.** With no opt-in the harness emits `warn:` lines and exits 0. Record each as
an audit row and carry it into the DR dispatch prompt so DR checks the linkage; a warning is not a
`missing_input` block and never stops the transition.

```json
{"ts":"<ISO>","actor":"orchestrator","action":"ar_ref_check","subject":"DV<k>","result":"warn"}
```

##### Step B — what the sweep checks do to this rollout

Warn-only covers the AR-reference check alone. The same invocation also runs the three
closing-sweep checks (stub shape, `ref` anchor resolution, ledger parity), which hard-fail
regardless of `--strict` (`skills/worktask/references/contracts/sweep-boundaries.md § Closing Elicitation Sweep`). A non-zero exit here is therefore
not necessarily an AR-reference failure; a sweep failure blocks the transition per § Step B.1 — on
failure, and its `fail:` line names a `sw-` id.

**Opt-in — `CORPFLOW_AR_REF_STRICT=1`.** The orchestrator passes `--strict`; violations become
`fail:` lines with exit 1 and block the DR dispatch until DV fixes the reference. The inverse guard
(an architecture reference with no `tasks.AR0` entry) warns in both modes and never fails.

##### Step B — the legacy tests_executed opt-in

```bash
LEGACY_TE_FLAG=""
[ "${CORPFLOW_LEGACY_TESTS_EXECUTED:-0}" = "1" ] && LEGACY_TE_FLAG="--legacy-tests-executed"
```

**`CORPFLOW_LEGACY_TESTS_EXECUTED=1`** makes the orchestrator pass `--legacy-tests-executed`, so an
artifact written before per-runner entries (a legacy scalar count) validates under the old integer
rules with one deprecation `warn:`. Use it only to land in-flight legacy artifacts; it never relaxes
a list. Without it a scalar `tests_executed` fails and routes per § Step B.1 — on failure.

### Step B.1 — Sweep checks at every stage completion

The harness is not a DV-only tool. After any stage `<CODE><N>` lands its `completed` patch (loop
step 6.5) and before § Step C.0 renders its blocking items or the next stage is dispatched, run:

```bash
ART=$(jq -r --arg id "<CODE><N>" '.tasks[$id].artifact // empty' .context/state.json)
# shellcheck disable=SC2086
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/handoff-harness.sh --validate-frontmatter "$ART" --state .context/state.json \
  $LEGACY_TE_FLAG
```

`$STRICT_FLAG` from § Step B may be appended; it affects only the AR-reference arm, which fires for DV
alone. `$LEGACY_TE_FLAG` (§ Step B — the legacy tests_executed opt-in) affects only the
`tests_executed` arm of DV and QA. For DV this is the § Step B invocation — run it once, not
twice. An artifact whose `open_questions` is the empty array passes untouched; any item in it must
be a full sweep stub.

#### Step B.1 — on failure

Exit 0 → append `{"action":"sweep_check","subject":"<CODE><N>","result":"ok"}` and continue to
§ Step C.0.

**Any non-zero exit** → append the same row with `result:"fail"` and every `fail:` line as
`reason`, then treat it as a `missing_input` contract violation on `<CODE><N>`: skip Step C.0,
dispatch no next stage, and re-dispatch the stage with the `fail:` lines verbatim so it writes what
it owes. There is no advisory tier here — the unreadable-ledger case fails too.

##### Step B.1 — the routing default, and why it is a default

The default is the rule, not a fallback: a line shape absent from the routing table routes like
every row in it, so no real defect is left without a branch to take.
