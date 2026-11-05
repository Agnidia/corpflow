# Autonomy preflight (Step 2a-pre)

Read from `skills/worktask/references/workflow.md § Step 2a-pre` when the resolved `--auto` contains `plan` or
`finalization`. A run without either value skips this file.

## Step 2a-pre — Autonomy preflight (unattended runs)

Runs when the resolved `--auto` contains `plan` or `finalization`, before Step 2a and Step 3, so
every human dependency an unattended run would hit surfaces in one message before anything is
seeded: the `git push`, `gh pr create` and `gh pr merge` grants, the evidence tools, and toolchain
integrity. Without either value, skip this step. A megatask per-issue run (ledger pre-seeded,
`workspace.json` present) skips it too and records nothing; the script also self-skips there with
`result=skipped` and `reason=milestone_mode`. It writes nothing under the project and never writes
a settings file: a missing grant prints the allow rule for the operator to add. It does not check
capture pre-authorization.

### Step 2a-pre snippet — check mode, output buffered

```bash
ACCEPT_ABSENT="<the --accept-absent= value, verbatim; empty when not given>"
PF_BUF=$(mktemp "${TMPDIR:-/tmp}/corpflow-preflight.XXXXXX")
set -- --auto "<resolved --auto values, comma-joined>" --platform "<platform[,platform] or none>"
[ -n "$ACCEPT_ABSENT" ] && set -- "$@" --accept-absent "$ACCEPT_ABSENT"
pf_rc=0
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/autonomy-preflight.sh "$@" > "$PF_BUF" || pf_rc=$?
echo "pf_rc=$pf_rc PF_BUF=$PF_BUF"
if [ "$pf_rc" -eq 0 ]; then
  grep -E '^(result|reason|accepted_absent)=' "$PF_BUF" || true
  sed -n 's/^result_json=//p' "$PF_BUF" | jq -r '"result=" + .result'
else awk '/^result_json=/{exit} f; /^preflight_failures=/{f=1}' "$PF_BUF"; rm -f -- "$PF_BUF"; fi
```

### Step 2a-pre — the exit code decides

- **0**: continue to Step 2a. The snippet prints `result=pass`, or `result=skipped` with its
  `reason=`. `accepted_absent=<tools>` names the missing tools the operator accepted. Keep the printed `PF_BUF` path for Step 3a, because shell variables do not survive
  between tool calls. On `result=skipped`, delete the buffer instead; Step 3a records nothing.
- **1 or 2**: stop before Step 2a and Step 3, reporting in one message every entry the snippet printed, each
  a failed grant, tool or toolchain check with its `fix:` line; for exit 2, the usage error on
  stderr (an unknown `--accept-absent` tool, say). The snippet has already deleted the buffer, no
  `.context/` exists, and nothing is recorded. The operator fixes the whole list, or relaunches
  with `--accept-absent=<tool>` for a tool the run may go without.

### Step 2a-pre — inputs

- `<platform[,platform] or none>`: `--platform` when given, else what the repo markers resolve to
  per `skills/shared/platform-detection.md § Detection Rules (markers → platform)`. A mixed repo
  passes every platform it resolves to.
- No platform resolves: pass `none`, never empty (exit 2); `none` records a `platform-none` skip.
- `--harness`, the `git reset --hard` grant check, is not passed: no step of this pipeline resets a
  tree.
- The `corpflow-preflight.` buffer prefix is required: `--record` deletes only buffers carrying it.
