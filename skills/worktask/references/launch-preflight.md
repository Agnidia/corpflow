# Launch preflight

Read for a new run after parsing flags and before creating the ledger.

Procedure routing: [workflow](workflow.md).

<a id="section-lookup-1"></a>
Related: [Gate automation flag — `--accept-absent`](launch-options.md#gate-automation-flag----accept-absent) · [Embedded Command Detection](workflow-completion.md#embedded-command-detection)

<!-- canonical-body:start -->
## Phase 1: Planning (execute immediately)

> **BINDING 1 — Pre-work Prohibition**: create, edit, or modify no project files during Phase 1
> (localization, accessibility IDs, config, sources); file changes belong to DV or later. The only
> writes permitted are the Step 3 `mkdir -p .context/…`, `state-patch.sh` ledger writes, the
> Step 3a `seed-state.sh` seed, the Step 2a `.context/gh-issue.json` anchor (reuse path only), the
> Step 3a `autonomy-preflight.sh --record` call, and the `mktemp` buffers under `$TMPDIR`
> (`corpflow-preflight.*`, `corpflow-issue-scan.*`) that § Step 2a-pre and § Step 2a write.

### Context-Interruption Recovery

After an interruption (auth flows, tool failures), verify PL0 exists with status `completed`; if
not, restart from the appropriate phase. The exception: PL0 `in_progress` with stage tasks present
and a `plan_revision_dispatched` audit row with no later `approval_received` for `PL<run_index>` is
a plan revision in flight — resume it per § Plan-revision re-dispatch (`plan_revision: true`),
never the fresh-run path. Both checkpoints still apply: the plan gate at Step A.5 and the FN gate
(`skills/worktask/references/finalization-policy.md § FN Gate`).

### Steps 1–2 — Parse flags and detect embedded commands

1. **Parse** the task description and flags. Resolve the `--auto` array per § Gate automation flag:
   strip optional brackets, split on commas, trim whitespace, reject unknown values. Parse
   `--accept-absent=` beside it (§ Gate automation flag — `--accept-absent`): keep the value
   verbatim for Step 2a-pre, and reject an unknown tool.
2. **Detect embedded commands**: extract any `/plugin:command` or `/command` pattern into
   PL0's `metadata.embedded_commands` (comma-separated, stamped at Step 4), strip the prefix from
   the description passed to PL0, preserve the arguments. See § Embedded Command Detection.

### Per-issue run under `/megatask`

When `/megatask` launched this run (the dispatch prompt carries a `PL0.metadata` stamp with
`megatask_group`), read `skills/worktask/references/megatask-per-issue.md` before Step 2a-pre: its
Bash prefix opens every call, and its table lists the steps that change. Other runs skip it.

### Step 2a-pre — Autonomy preflight (unattended runs)

Runs only when the resolved `--auto` contains `plan` or `finalization`, before Step 2a and Step 3;
without either value, skip it. When it runs, follow `skills/worktask/references/autonomy-preflight.md`:
the snippet, the exit-code decision and the inputs.

### Step 2a — Duplicate-issue pre-flight (advisory)

Runs once the request is known and strictly before Step 3 creates `.context/`. The
`skills/gh-issue-dedup` anchor guards re-runs only, so a first run of work already filed under
different wording still opens a second issue — this step surfaces the candidates while the duplicate
is still preventable. Append `--no-gh-issue` to the invocation when that flag was supplied. When
`--auto` contains `plan`, nobody is there to answer the gate: run § Step 2a — unattended instead of
the snippet and gate below.

#### Snippet preamble (snippets that reference an ungranted plugin file)

A script granted in `allowed-tools:` is never reached through this variable: it runs as the exact
text its grant matches, such as `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/state-patch.sh`
(`skills/shared/plugin-root-resolution.md § Granted-script invocation shape`).

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"  # CC substitutes on load; if empty resolve per skills/shared/plugin-root-resolution.md
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="<plugin-root>"
```

#### Step 2a snippet — invoke the scan, non-blocking

```bash
# A missing script exits 127; `|| true` turns that into "no candidates", as for any scan failure.
scan_out=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/preflight-issue-scan.sh --goal "<task description>") || true
scan_result=$(printf '%s\n' "$scan_out" | sed -n 's/^result=//p' | tail -n 1)
```

#### Step 2a — the gate

Anything other than `result=shown` proceeds to Step 3 unchanged, with no prompt. On `result=shown`,
present each `candidate=<json>` line (number, title, url — at most three, most likely first) and
`AskUserQuestion` with exactly two outcomes:

- **Start a new worktask** — Step 3 as normal. Nothing is written yet, so declining leaves no
  orphaned state.
- **Use one of the existing issues** — Step 3, then bind this context to the chosen issue: after
  Step 3a seeds `state.json`, write the dedup anchor below.

A `/megatask` per-issue run never asks: its `--auto` holds `plan`, so § Step 2a — unattended runs
instead, and the scan skips itself there anyway (`reason=milestone_mode`).

#### Step 2a — reusing an existing issue

```bash
jq -cn --arg url "<chosen url>" --argjson num <chosen number> \
   --arg wid "$(jq -r '.worktask_id // "unknown"' .context/state.json)" \
   --arg ts "$(date -u +%FT%TZ)" \
   '{version:1, url:$url, number:$num, created_run_index:-1, created_worktask_id:$wid,
     created_at:$ts, last_commented_run_index:-1}' > .context/gh-issue.json
```

Planning still runs, bound to the existing issue. `created_run_index: -1` is the "predates this
context" value `publish-pl-issue.sh` already uses for a recovered search hit, so Step A comments on
that issue instead of opening a second one.

#### Step 2a — unattended (`--auto` contains `plan`)

```bash
SCAN_BUF=$(mktemp "${TMPDIR:-/tmp}/corpflow-issue-scan.XXXXXX")
bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/preflight-issue-scan.sh --goal "<task description>" < /dev/null > "$SCAN_BUF" || true
echo "SCAN_BUF=$SCAN_BUF"; grep -E '^(result|reason|candidates)=' "$SCAN_BUF"
```

The same scan with no prompt: stdin is `/dev/null`, there is no `AskUserQuestion`, and
`result=shown` does not stop the run. Step 3 proceeds as a new worktask; the reuse path is not
taken, and the exact-title auto-bind in `publish-pl-issue.sh` still applies. Keep the printed
`SCAN_BUF` path: the Step 3a `--record --candidates` call turns it into one
`preflight_issue_candidates` audit row, then deletes it.

##### Step 2a — unattended, what differs

- Leave `CORPFLOW_NONINTERACTIVE` unset. Set to `1`, it makes the scan skip itself, and the run
  records no candidates.
- Candidate titles and URLs arrive already path-scrubbed; when the scrub is unavailable the scan
  prints none and reports `reason=scrub_unavailable`. `--record` scrubs them again before the row
  reaches `audit.jsonl`.
- Without `plan` in `--auto`, including under `--auto=[finalization]`, the snippet and gate above
  apply unchanged.

#### Step 2a invariants

- The trailing `|| true` is required: the scan is non-blocking. No network/`gh`/auth/remote, an
  API error, a rate limit, a timeout, a malformed response, or zero hits each print
  `result=skipped`/`result=none` and Step 3 runs unchanged.
- **Advisory only**: the scan never links, comments, closes, or writes (no audit row either: the
  ledger does not exist yet, and the unattended row is Step 3a's write), and does not relax the
  exact-title auto-bind in `publish-pl-issue.sh` (`skills/gh-issue-dedup § Resolution order`).
- **Self-skips**: `CORPFLOW_NONINTERACTIVE=1`, `/megatask` (`MILESTONE_MODE=1` or a
  `workspace.json`), and `--emergency` (`INCIDENT_MODE=1`); `PREFLIGHT_ISSUE_SCAN=0` disables it
  outright. `--auto` with `plan` is not a skip: it runs unattended. A `.context/` already carrying
  a `gh-issue.json` anchor is a resume: `reason=already_anchored`, and the anchor answers.

### Steps 3–3a — Context folders and state.json seed

3. `mkdir -p .context/designs .context/images .context/errors .context/logs`
3a. Seed `.context/state.json` by running `bash ${CLAUDE_PLUGIN_ROOT}/skills/worktask/scripts/seed-state.sh`, the seed's only
definition: next free planning index, `facts.goal` escaped and capped at 240 chars, the
unconditional `metadata.workspace_path` (`skills/worktask/references/initialization-ledger.md § Seeded workspace_path`), and
the atomic write. It resolves `.context/` inside this worktree only, never from cwd. Resulting
shape: `skills/worktask/references/contracts/ledger-seed.md#pl0-seed`; `--help` lists flags and exit codes.
