# Finalization publish

Read when executing or checking finalization publish.

Procedure routing: [orchestration](orchestration.md).

<a id="section-lookup-1"></a>
Related: [Hand-back guard](completion-handoff.md#hand-back-guard)

<!-- canonical-body:start -->
## Post-capture issue update (Visual evidence)

After the execution loop exits (all stage tasks completed — this runs whether or not the stage set includes FN, and after the FN push when it does, so the raw asset tier sees a reachable ref): post the DV screenshot captures to the GitHub issue as a marker-deduped comment. Non-blocking by contract, same invocation discipline as the PL publish helper (`; true`; the helper exits 0 on every operational outcome):

### Post-capture publish snippet

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"  # CC substitutes on load; if empty resolve per skills/shared/plugin-root-resolution.md
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="<plugin-root>"
HELPER="$PLUGIN_ROOT/skills/worktask/scripts/attach-visual-evidence.sh"
if [ -f "$HELPER" ]; then
  bash "$HELPER" --post issue; true
```

### Post-capture fallback audit (helper_not_found)

```bash
# …continued: helper missing → audit one deferred row
else
  LOG_DIR="${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-.}}/.context/logs"
  mkdir -p "$LOG_DIR"
  STATE_FILE="${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-.}}/.context/state.json"
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg dk "$(jq -r '.worktask_id // "unknown"' "$STATE_FILE" 2>/dev/null || echo unknown):$(jq -r '.run_index // 0' "$STATE_FILE" 2>/dev/null || echo 0):visual_evidence:issue" \
    '{ts:$ts, actor:"orchestrator", action:"visual_evidence_issue_commented", result:"deferred", metadata:{via:"attach-visual-evidence.sh", reason:"helper_not_found", dedupe_key:$dk}}' \
    >> "$LOG_DIR/audit.jsonl"; true
fi
```

### Post-capture self-gating & dedup

The helper self-gates: skips silently when `metadata.requires_screenshots == false` or no captures exist; defers when `metadata.github_issue_url` is absent (publish deferred/failed) or under megatask per-issue mode; dedupes on the HTML marker `<!-- visual-evidence:<worktask_id>:<run_index> -->` so a retry never double-posts. Each outcome is one `visual_evidence_issue_commented` audit row (`result ∈ {ok, skipped, deferred}`). The PR-body counterpart (`--emit pr`) belongs to the FN stage during PR composition — `agents/project-manager.md`, `references/conductor-attachments.md`.

## Post-merge completion comment

After the post-capture issue update above (and after FN has created/merged the PR so the closing refs are real — "when the PR closes"): post a short completion comment (PR link, summary of at most 300 characters, screenshots when captured) to every related issue the PR closes.

### Completion snippet

Run § Post-capture publish snippet and § Post-capture fallback audit (helper_not_found) verbatim with three substitutions — `--post completion` instead of `--post issue`, `action:"completion_summary_commented"` instead of `action:"visual_evidence_issue_commented"`, and the dedupe-key suffix `completion:all` instead of `visual_evidence:issue`. Same non-blocking discipline (`; true`; the helper exits 0 on every operational outcome). Inside the publish snippet's `if [ -f "$HELPER" ]` block, pass the PR FN recorded on the ledger as `<pr-ref>`; an absent or empty value passes no argument, and the helper itself drops a value that is not a PR number or a github.com PR URL naming this repository:

```bash
  PR_REF=$(jq -r '.metadata.pr_url // empty' "${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-.}}/.context/state.json" 2>/dev/null)
  bash "$HELPER" --post completion ${PR_REF:+"$PR_REF"}; true
```

### Completion PR-ref resolution

The PR resolves in this order: the `<pr-ref>` argument, then the current branch's PR, then the ledger's `metadata.pr_url` (FN writes it after `gh pr create`; the checkout is off the PR head branch after a merge into a non-default base). A valid argument is final. With no valid argument, the current-branch PR wins if it yields at least one issue, else the ledger PR, so a branch PR that closes nothing falls through. The helper passes the argument or the ledger value to `gh` only when it is a PR number or a `https://github.com/<owner>/<repo>/pull/<n>` URL naming this repository. The summary fallback reads the same PR.

### Completion issue resolution & summary sourcing

Related issues resolve from PR-body keywords (`Closes`/`Fixes`/`Resolves #N`, case-insensitive) unioned with `gh pr view --json closingIssuesReferences`, deduped to integers so no untrusted PR-body text reaches a `gh` argv. One comment per issue carries a `PR: <url>` line (only when the effective PR resolves to a github.com PR URL naming this repository; a failed lookup drops the line), then a short summary of at most 300 characters: the first paragraph under `## summary` in `.context/complete-summary-<run_index>.md`, else `state.json facts.goal`, else the PR title only (never the PR body). Each source is sanitised before the cut; a longer text keeps the last whole word that fits in 300 characters and ends in `...`. The visual-evidence block follows when `requires_screenshots == true` and captures exist (summary-only otherwise).

### Completion dedup, audit rows & timing

Per-issue HTML-marker dedup (`<!-- completion-summary:<worktask_id>:<run_index>:<issue_n> -->`) means a retry never double-posts; a partially-failed prior run re-posts only the missing issues. It defers under megatask per-issue mode (parent milestone issue is canonical) and audits `no_related_issues` when the PR closes nothing. Each issue yields one `completion_summary_commented` audit row (`result ∈ {ok, skipped, deferred}`); a single `gh` failure on one issue is audited and the loop continues (overall exit 0). FN still owns only `--emit pr` for the PR body. Timing: closing refs are populated at PR creation from the body keywords, so the resolver works at post-loop time even when the merge is a local fast-forward/push; a later real merge re-running this step is a marker no-op.

## Post-Worktask Self-Improvement

After the execution loop exits (all tasks completed, including ST), except in a `/megatask` per-issue run, which ends at ST (`workflow.md § Phase 3`). Either way, run § Hand-back guard before handing back. Then, unless the run is per-issue: if `.context/learnings.md` exists, Read `references/fn-gate.md § Post-Worktask Self-Improvement` and follow the Post-ST procedure (surface learnings → user checks boxes → route each checked item by its `Enforcement:` form to prompt-engineer or workflow-engineer → audit → terminate). Absent → worktask complete. Never apply unchecked proposals.

## Resume After Interruption

The orchestrator loop is restartable. When reattaching (PostCompact, session crash, `--resume`, or stale `in_progress` tasks found at session start), read `references/resume.md` before re-delegating anything — it maps ledger shape + audit tail → exact action, including the live-agent `claude agents --json --all` pre-check that forbids blind re-delegation of a live, busy, or parked subagent. Compaction-specific flow: `skills/context-compression/SKILL.md § PostCompact Recovery`.
