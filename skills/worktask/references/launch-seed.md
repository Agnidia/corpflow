# Launch seed

Read when executing or checking launch seed.

Procedure routing: [workflow](workflow.md).

<a id="section-lookup-1"></a>
Related: [Workspace-root cross-check](stage-entry.md#workspace-root-cross-check)

<!-- canonical-body:start -->
<a id="step-3a--metadataworkspace_path-and-factsgoal"></a>
#### Step 3a snippet — seed the ledger

After creating `.context/`, the orchestrator runs:

```bash
set -- --worktask-id "<slug>" --goal "<task description; the issue title under /megatask>"
PLATFORM="<the --platform value, verbatim; empty when not given>"
[ -n "$PLATFORM" ] && set -- "$@" --platform "$PLATFORM"
seed_rc=0
seed_out=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/seed-state.sh "$@") || seed_rc=$?
printf '%s\nseed_rc=%s\n' "$seed_out" "$seed_rc"
if [ "$seed_rc" -eq 3 ]; then
  seed_state=$(printf '%s\n' "$seed_out" | sed -n 's/^state=//p')
  bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh --state "$seed_state" --task-status PL0 in_progress
fi
```

#### Step 3a — the exit code decides

| Exit | Result and next action |
|---|---|
| 0 | Seeded; record the autonomy preflight, then run Step 3b. |
| 3 | Existing ledger unchanged; the snippet reopens PL0. Stop on reopening failure; otherwise continue. PL0's new-run reset owns replacement. |
| 4 | No `.context/` inside this worktree; stop and report. Nothing written. |
| 1 or 2 | Write or usage failure; stop and report. Nothing written. |

The seed always stamps absolute `metadata.workspace_path` and escaped, capped `facts.goal`.
The former enables all three workspace guards; the latter supplies the issue title and Summary.
PM may refine the goal. Contracts: [initialization-ledger](initialization-ledger.md).

#### Step 3a — record the autonomy preflight

Only after Step 2a-pre passed with `result_json=`, record its buffer immediately after seeding.
Otherwise record nothing and delete the Step 2a buffer.
Use the printed buffer paths; leave `SCAN_BUF` empty when Step 2a prompted or did not run.

```bash
PF_BUF="<path Step 2a-pre printed>"; SCAN_BUF="<path Step 2a printed, or empty>"
set -- --record "$PF_BUF" --context .context
[ -n "$SCAN_BUF" ] && set -- "$@" --candidates "$SCAN_BUF"
rec_rc=0
rec_out=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/autonomy-preflight.sh "$@") || rec_rc=$?
printf '%s\nrec_rc=%s\n' "$rec_out" "$rec_rc"
```

#### Step 3a — what the record writes

The helper merges `metadata.preflight`, then audits `autonomy_preflight` and, with `--candidates`,
`preflight_issue_candidates` (`{result,candidates:[{number,title,url,score}]}`; empty allowed).
It prints `recorded=<what>` per write and deletes both buffers on success.
`--record` refuses `--auto`, `--platform`, `--harness`, or `--accept-absent` with exit 2.

On exit 1, `recorded=` identifies partial writes; continue to Step 3b after the continuation below.
An absent preflight record cannot excuse missing evidence tools as accepted.
Run the continuation in the same call so failure still produces the warning and cleanup.

<a id="step-3a--a-failed-record-does-not-stop-the-run"></a>
#### Step 3a — the failed-record continuation

```bash
if [ "$rec_rc" -ne 0 ]; then
  w=$(printf '%s\n' "$rec_out" | sed -n 's/^recorded=//p' | paste -sd, -)
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg rc "$rec_rc" --arg w "${w:-none}" \
    '{ts:$ts, actor:"orchestrator", action:"autonomy_preflight_record_failed", subject:"PL0",
      result:"warn", task_id:"PL0", metadata:{exit:$rc, recorded:$w}}' >> .context/logs/audit.jsonl
  rm -f -- "$PF_BUF" ${SCAN_BUF:+"$SCAN_BUF"}
fi
```

<a id="step-3b-regression-guard"></a>
### Step 3b — Verify SubagentStop hook installed

After seeding and before PL0 delegation, run the installer.
It refreshes missing or stale `.claude/hooks/state-merge.sh`, audits each replacement as
`hook_refreshed`, and verifies `plugin.json` registration. Failure warns and continues with Layers 1 and 3.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/hook-install.sh \
  || echo "⚠ state-merge.sh hook not installed — state.json will only be patched if agents self-merge (Layer 1) or orchestrator Step 6.5 fires (Layer 3). Re-run the hook installer to fix." >&2
```

<a id="step-3c--the-input-is-a-title-not-the-task-description"></a>
### Step 3c — Name the branch once (PL start)

After seeding and before Step 4, the orchestrator runs the naming snippet in
[launch-planning](launch-planning.md#step-3c--which-of-the-two-names-gets-stamped), including on manually named branches.
Only this step runs `branch-name.sh` in rename mode; all outcomes exit 0 and planning continues.
The script self-disables under `/megatask` or `--emergency`; its conventional-name arm is a no-op.

Pass a concise imperative title of ≤60 characters, never the raw request; the slug budget is 48 characters.
`branch_is_conventional()` alone decides validity through `branch-name.sh --check` (0 valid, 1 invalid, 2 fault).
Preview with `BRANCH_NAME_PRINT=1`; `--check`, `--print-types`, and `--print-target` write no state or audit rows.

<a id="step-3c--who-decides-conventionality"></a>
#### Step 3c — host-session authorization

Invoking `/worktask` authorizes the rename, including inside a linked worktree; do not revert it or re-ask.
The host's workspace mapping follows the local rename.
`BRANCH_NAME_WORKTREE_RENAME=0` preserves the local name and derives only `target_branch=`.

#### Step 3c — validate before stamping

Capture final `branch=` and `target_branch=` values; validate against `^[A-Za-z0-9._/-]+$` before stamping `facts.branch`.
Stamp invalid values empty. Prefer the non-empty target when the local name is empty or fails `--check`.
The script never writes the ledger. Empty output means no planned name; FN pushes plainly.
Run the non-blocking post-check and truncation audit in [launch-planning](launch-planning.md#step-3c--post-check-non-blocking).
Refinement occurs once after PL0 returns, at [Step A.4b](plan-transition.md#step-a4b--refine-the-branch-target-after-a4-before-a5).
