#!/usr/bin/env bash
# cache-lint-selftest.sh — the `--self-test` harness for cache-lint.sh.
#
# SOURCED, never executed: cache-lint.sh loads this file only on the `--self-test`
# path, so the production path never pays for it. Sourcing leaves the caller's
# `$0` and every function it has already defined in scope — this file reads the
# caller's helpers and is not standalone.
#
# Contract: defines `self_test`, which owns the exit for this invocation.

# ---------- Self-test ----------
self_test() {
  _SELFTEST_PASSED=0
  # Three levels up from skills/worktask/scripts/ is the plugin root. Resolved from
  # BASH_SOURCE, never $PWD: the self-test is run from arbitrary cwds (bats tempdirs,
  # CI checkouts) and a cwd-relative root silently checks the wrong agents/ or none.
  local SELF_REPO_ROOT
  SELF_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd) || SELF_REPO_ROOT="."
  local td
  td=$(mktemp -d "${TMPDIR:-/tmp}/cache-lint-XXXXXX")
  trap "rm -rf '$td'" EXIT

  # Anchor lint fixture: minimal DV artifact
  cat > "$td/development.md" <<'EOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "self-test fixture"
  refs: { plan: planning-0.md#requirements }
---

# Development

## files-changed

table goes here

## tests-added

list

## deviations

none

## follow-ups

none

## elicitation-sweep

nothing to elicit
EOF
  if "$0" --anchor-lint "$td/development.md" >/dev/null 2>&1; then
    echo "self-test: anchor-lint pass: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: anchor-lint pass: FAIL" >&2; exit 1
  fi

  # Negative anchor lint: the four DV anchors are all present, the universal one is not.
  # Keyed on the sweep heading alone so a regression in the UNIVERSAL_ANCHORS append cannot
  # hide behind a stage anchor that is also missing.
  cat > "$td/no-sweep.md" <<'EOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "no sweep heading"
  refs: { plan: planning-0.md#requirements }
---

# Development

## files-changed

x

## tests-added

x

## deviations

none

## follow-ups

none
EOF
  # Captured rather than piped: `pipefail` would otherwise read the (expected) non-zero
  # lint exit as the pipeline's verdict and fail the case it is meant to pass.
  local no_sweep_out=""
  no_sweep_out=$("$0" --anchor-lint "$td/no-sweep.md" 2>&1) || true
  if grep -q 'missing: elicitation-sweep' <<< "$no_sweep_out"; then
    echo "self-test: anchor-lint universal sweep anchor: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: anchor-lint universal sweep anchor: FAIL (missing heading accepted)" >&2; exit 1
  fi

  # Negative anchor lint: missing anchor
  cat > "$td/bad.md" <<'EOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "missing anchors"
  refs: { plan: planning-0.md#requirements }
---

## files-changed

partial
EOF
  if "$0" --anchor-lint "$td/bad.md" >/dev/null 2>&1; then
    echo "self-test: anchor-lint reject: FAIL (should have rejected missing anchors)" >&2; exit 1
  else
    echo "self-test: anchor-lint reject: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  fi

  # --allow-list and --anchor-diff: the shared core the hook and the harness read.
  local al_out="" diff_out="" diff_rc=0
  al_out=$("$0" --allow-list --stage DV 2>&1) || true
  if printf '%s\n' "$al_out" | grep -qx "DV	developer	development	optional	verification-command" \
    && printf '%s\n' "$al_out" | grep -qx "\*			any-optional	rework-<N>"; then
    echo "self-test: allow-list rows: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: allow-list rows: FAIL" >&2; exit 1
  fi
  printf '## Stage Timings\n' > "$td/baseline.md"
  diff_out=$(printf '## Stage Timings\n## decisions\n## Notes\n' \
    | "$0" --anchor-diff --for-path "/p/.context/development-3.md" --baseline "$td/baseline.md" - 2>&1) || diff_rc=$?
  if [[ "$diff_rc" -eq 1 ]] && [[ "$(printf '%s\n' "$diff_out" | grep '^unexpected')" == "unexpected	Notes" ]]; then
    echo "self-test: anchor-diff baseline + optional: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: anchor-diff baseline + optional: FAIL (rc=$diff_rc)" >&2; exit 1
  fi
  diff_rc=0
  diff_out=$(printf '## x\n' | "$0" --anchor-diff --for-path "/p/.context/development-3-stream.md" - 2>&1) || diff_rc=$?
  if [[ "$diff_rc" -eq 1 ]] && printf '%s\n' "$diff_out" | grep -qx 'missing	files-changed'; then
    echo "self-test: anchor-diff DV stream path resolves to DV: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: anchor-diff DV stream path resolves to DV: FAIL (rc=$diff_rc)" >&2; exit 1
  fi
  diff_rc=0
  printf '## x\n' | "$0" --anchor-diff --for-path "/p/.context/testing-3-ui.md" - >/dev/null 2>&1 || diff_rc=$?
  if [[ "$diff_rc" -eq 2 ]]; then
    echo "self-test: anchor-diff non-DV suffixed path unresolved: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: anchor-diff non-DV suffixed path unresolved: FAIL (rc=$diff_rc)" >&2; exit 1
  fi

  # Prefix lint fixture: two prompts, identical sections [1][2]
  local log="$td/log.jsonl"
  : > "$log"
  for stg in PL AR; do
    jq -cn --arg wid wf-self --arg stage "$stg" --arg prompt \
"<<<contract-reminder>>>
contract
<<<worktask-header>>>
worktask_id=wf-self
plan_file=planning-0.md
<<<stage-contract>>>
stage=$stg
<<<task>>>
desc" '{worktask_id:$wid, stage:$stage, prompt:$prompt}' >> "$log"
  done
  if "$0" "$log" >/dev/null 2>&1; then
    echo "self-test: prefix-lint pass: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: prefix-lint pass: FAIL" >&2; exit 1
  fi

  # Negative: drift in section [1]
  jq -cn --arg prompt \
"<<<contract-reminder>>>
DIFFERENT contract
<<<worktask-header>>>
worktask_id=wf-self
plan_file=planning-0.md
<<<stage-contract>>>
stage=TL
<<<task>>>
desc" '{worktask_id:"wf-self", stage:"TL", prompt:$prompt}' >> "$log"

  if "$0" "$log" >/dev/null 2>&1; then
    echo "self-test: prefix-lint drift detect: FAIL (should have caught drift)" >&2; exit 1
  else
    echo "self-test: prefix-lint drift detect: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  fi

  # ---------- Section [3] ledger-digest grammar ----------

  # Happy: a composed [3] following the grammar passes.
  local ledger_ok="$td/ledger-ok.jsonl"
  jq -cn --arg prompt \
"<<<contract-reminder>>>
contract
<<<worktask-header>>>
worktask_id=wf-ledger-ok
plan_file=planning-0.md
<<<state-json>>>
ledger: .context/state.json
run_index: 0
ready: none
in_progress: none
blocked: none
open_blocking_questions: 0
<<<stage-contract>>>
stage=PL
<<<task>>>
desc" '{worktask_id:"wf-ledger-ok", stage:"PL", prompt:$prompt}' > "$ledger_ok"
  if "$0" "$ledger_ok" >/dev/null 2>&1; then
    echo "self-test: prefix-lint [3] composed digest: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: prefix-lint [3] composed digest: FAIL" >&2; exit 1
  fi

  # Negative: an inlined ledger (embedded JSON) instead of the digest.
  local ledger_json="$td/ledger-json.jsonl"
  jq -cn --arg prompt \
"<<<contract-reminder>>>
contract
<<<worktask-header>>>
worktask_id=wf-ledger-json
plan_file=planning-0.md
<<<state-json>>>
{\"tasks\": {\"PL0\": {\"status\": \"completed\"}}}
<<<stage-contract>>>
stage=PL
<<<task>>>
desc" '{worktask_id:"wf-ledger-json", stage:"PL", prompt:$prompt}' > "$ledger_json"
  if "$0" "$ledger_json" >/dev/null 2>&1; then
    echo "self-test: prefix-lint [3] inlined-JSON reject: FAIL (should have caught the embedded ledger)" >&2; exit 1
  else
    echo "self-test: prefix-lint [3] inlined-JSON reject: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  fi

  # Negative: [3] present but missing the `ledger:` pointer as its first line.
  local ledger_nopointer="$td/ledger-nopointer.jsonl"
  jq -cn --arg prompt \
"<<<contract-reminder>>>
contract
<<<worktask-header>>>
worktask_id=wf-ledger-nopointer
plan_file=planning-0.md
<<<state-json>>>
run_index: 0
ready: none
in_progress: none
blocked: none
open_blocking_questions: 0
<<<stage-contract>>>
stage=PL
<<<task>>>
desc" '{worktask_id:"wf-ledger-nopointer", stage:"PL", prompt:$prompt}' > "$ledger_nopointer"
  if "$0" "$ledger_nopointer" >/dev/null 2>&1; then
    echo "self-test: prefix-lint [3] missing-pointer reject: FAIL (should have caught the missing pointer)" >&2; exit 1
  else
    echo "self-test: prefix-lint [3] missing-pointer reject: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  fi

  # ---------- Section [1] contract-canon opt-in ----------

  # Happy: [1] equals the fenced block contract-reminder.md ships, with
  # `contract_canon: true` opting the line into the check.
  local ccanon_block
  ccanon_block=$(canonical_contract_block "$SELF_REPO_ROOT") \
    || { echo "self-test: prefix-lint [1] contract-canon: FAIL (canon unreadable)" >&2; exit 1; }
  local ccanon_ok="$td/ccanon-ok.jsonl"
  jq -cn --arg prompt \
"<<<contract-reminder>>>
$ccanon_block
<<<worktask-header>>>
worktask_id=wf-ccanon-ok
plan_file=planning-0.md
<<<stage-contract>>>
stage=PL
<<<task>>>
desc" '{worktask_id:"wf-ccanon-ok", stage:"PL", contract_canon:true, prompt:$prompt}' > "$ccanon_ok"
  if "$0" "$ccanon_ok" >/dev/null 2>&1; then
    echo "self-test: prefix-lint [1] contract-canon match: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: prefix-lint [1] contract-canon match: FAIL" >&2; exit 1
  fi

  # Negative: same opt-in, [1] does not match the canon file.
  local ccanon_bad="$td/ccanon-bad.jsonl"
  jq -cn --arg prompt \
"<<<contract-reminder>>>
a hand-written reminder that does not match contract-reminder.md
<<<worktask-header>>>
worktask_id=wf-ccanon-bad
plan_file=planning-0.md
<<<stage-contract>>>
stage=PL
<<<task>>>
desc" '{worktask_id:"wf-ccanon-bad", stage:"PL", contract_canon:true, prompt:$prompt}' > "$ccanon_bad"
  if "$0" "$ccanon_bad" >/dev/null 2>&1; then
    echo "self-test: prefix-lint [1] contract-canon mismatch reject: FAIL (should have caught the mismatch)" >&2; exit 1
  else
    echo "self-test: prefix-lint [1] contract-canon mismatch reject: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  fi

  # L1 forbidden-token scanner (REQ-3/AC-4): happy path first (fresh log, no
  # forbidden tokens — must still pass byte-identity AND the new scan).
  local ftlog="$td/forbidden-token-log.jsonl"
  : > "$ftlog"
  jq -cn --arg wid wf-ft --arg stage PL --arg prompt \
"<<<contract-reminder>>>
contract
<<<worktask-header>>>
worktask_id=wf-ft
plan_file=planning-0.md
<<<stage-contract>>>
stage=PL
<<<task>>>
desc" '{worktask_id:$wid, stage:$stage, prompt:$prompt}' >> "$ftlog"
  if "$0" "$ftlog" >/dev/null 2>&1; then
    echo "self-test: forbidden-token-lint happy path: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: forbidden-token-lint happy path: FAIL" >&2; exit 1
  fi

  # Negative: ISO-8601 timestamp injected into section [2] (worktask-header)
  # — a previously-uncaught class (byte-identical across every stage of THIS
  # worktask, so the existing drift check alone would miss it; only becomes a
  # problem cross-worktask, which the intrinsic scan catches immediately).
  local ftlog_ts="$td/forbidden-token-log-ts.jsonl"
  jq -cn --arg prompt \
"<<<contract-reminder>>>
contract
<<<worktask-header>>>
worktask_id=wf-ft-ts
plan_file=planning-0.md
generated_at=2026-07-05T15:15:39Z
<<<stage-contract>>>
stage=PL
<<<task>>>
desc" '{worktask_id:"wf-ft-ts", stage:"PL", prompt:$prompt}' > "$ftlog_ts"
  if "$0" "$ftlog_ts" >/dev/null 2>&1; then
    echo "self-test: forbidden-token-lint timestamp reject: FAIL (should have caught ISO-8601 timestamp)" >&2; exit 1
  else
    echo "self-test: forbidden-token-lint timestamp reject: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  fi

  # Negative: retry counter injected into section [1] (contract-reminder) —
  # belongs in section [6] only, never [1]/[2]/[4].
  local ftlog_retry="$td/forbidden-token-log-retry.jsonl"
  jq -cn --arg prompt \
"<<<contract-reminder>>>
contract retry_count: 2
<<<worktask-header>>>
worktask_id=wf-ft-retry
plan_file=planning-0.md
<<<stage-contract>>>
stage=PL
<<<task>>>
desc" '{worktask_id:"wf-ft-retry", stage:"PL", prompt:$prompt}' > "$ftlog_retry"
  if "$0" "$ftlog_retry" >/dev/null 2>&1; then
    echo "self-test: forbidden-token-lint retry-counter reject: FAIL (should have caught retry_count)" >&2; exit 1
  else
    echo "self-test: forbidden-token-lint retry-counter reject: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  fi

  # Frontmatter template lint: positive fixture (stage agent shaped like
  # the collapsed agents).
  cat > "$td/developer.md" <<'EOF'
---
name: developer
description: dummy
---

# Developer

## Handoff Protocol

Required Inputs etc live in stage-contracts.md.

### Frontmatter for this stage (DV)

```yaml
---
handoff:
  stage: DV
  verdict: ok
  summary: "<one-line ≤200 chars>"
  files_touched:
    - path/to/file1.md
  next_stage_focus: "<imperative>"
  refs:
    decisions: architecture-N.md#decisions
---
```

## Other Section
EOF
  if "$0" --frontmatter-template-lint "$td/developer.md" >/dev/null 2>&1; then
    echo "self-test: frontmatter-template-lint pass: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: frontmatter-template-lint pass: FAIL" >&2; exit 1
  fi

  # Negative: stage mismatch
  cat > "$td/qa-engineer.md" <<'EOF'
---
name: qa-engineer
description: dummy
---

# QA

## Handoff Protocol

text

### Frontmatter for this stage (QA)

```yaml
---
handoff:
  stage: DV
  verdict: ok
  summary: "wrong stage"
  refs: { dev: development-N.md#files-changed }
---
```
EOF
  if "$0" --frontmatter-template-lint "$td/qa-engineer.md" >/dev/null 2>&1; then
    echo "self-test: frontmatter-template-lint reject mismatch: FAIL (should have rejected stage mismatch)" >&2; exit 1
  else
    echo "self-test: frontmatter-template-lint reject mismatch: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  fi

  # Negative: two yaml blocks (re-inlined boilerplate regression)
  cat > "$td/team-lead.md" <<'EOF'
---
name: team-lead
description: dummy
---

# TL

## Handoff Protocol

text

```yaml
---
handoff:
  stage: TL
  verdict: ok
  summary: "first"
  refs: { plan: planning-N.md#requirements }
---
```

```yaml
extra: block
```
EOF
  if "$0" --frontmatter-template-lint "$td/team-lead.md" >/dev/null 2>&1; then
    echo "self-test: frontmatter-template-lint reject duplicate: FAIL (should have rejected two yaml blocks)" >&2; exit 1
  else
    echo "self-test: frontmatter-template-lint reject duplicate: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  fi

  # Positive: pointer-only form (P1 dedup, Batch 5/ad4) — zero inline yaml
  # blocks, but a stage-contracts.md#tpl-<CODE> pointer is present.
  cat > "$td/release-engineer.md" <<'EOF'
---
name: release-engineer
description: dummy
---

## Handoff Protocol

Frontmatter template (paste verbatim at artifact top): `skills/worktask/assets/templates/template-re.md#tpl-re`.

### State.json Atomic Merge — REQUIRED before return

no yaml block here, just the pointer above
EOF
  if "$0" --frontmatter-template-lint "$td/release-engineer.md" >/dev/null 2>&1; then
    echo "self-test: frontmatter-template-lint pointer-only pass: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: frontmatter-template-lint pointer-only pass: FAIL" >&2; exit 1
  fi

  # Negative: zero yaml blocks AND no pointer (a botched dedup that deleted
  # the frontmatter with no replacement reference) — must be rejected.
  cat > "$td/stakeholder.md" <<'EOF'
---
name: stakeholder
description: dummy
---

## Handoff Protocol

Nothing here — no yaml block, no stage-contracts.md pointer.

### State.json Atomic Merge — REQUIRED before return

placeholder
EOF
  if "$0" --frontmatter-template-lint "$td/stakeholder.md" >/dev/null 2>&1; then
    echo "self-test: frontmatter-template-lint reject no-pointer-no-block: FAIL (should have rejected)" >&2; exit 1
  else
    echo "self-test: frontmatter-template-lint reject no-pointer-no-block: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  fi

  # Filename lint: positive — canonical names
  mkdir -p "$td/ctx"
  cat > "$td/ctx/development-0.md" <<'EOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "self-test"
  refs: { plan: planning-0.md#requirements }
---
## files-changed
EOF
  cat > "$td/ctx/testing-0.md" <<'EOF'
---
handoff:
  stage: QA
  verdict: pass
  summary: "self-test"
  refs: { dev: development-0.md#files-changed }
---
## results
EOF
  if "$0" --filename-lint "$td/ctx" >/dev/null 2>&1; then
    echo "self-test: filename-lint pass: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: filename-lint pass: FAIL" >&2; exit 1
  fi

  # Filename lint: negative — non-canonical name
  cat > "$td/ctx/arch-0.md" <<'EOF'
---
handoff:
  stage: AR
  verdict: ok
  summary: "wrong name"
  refs: { plan: planning-0.md }
---
## decisions
EOF
  if "$0" --filename-lint "$td/ctx" >/dev/null 2>&1; then
    echo "self-test: filename-lint reject non-canonical: FAIL (should have flagged arch-0.md)" >&2; exit 1
  else
    echo "self-test: filename-lint reject non-canonical: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  fi

  # Agent-section cross-check: a fixture agent mandating an UNLISTED section fails and
  # names both files; one mandating a listed section passes; a backticked `## X` with no
  # artifact filename on the line is not matched (the under-match constraint, AD-6).
  mkdir -p "$td/repo/agents"
  cat > "$td/repo/agents/developer.md" <<'EOF'
Write the summary to `development-N.md` under `## totally-unlisted-section` now.
EOF
  local sect_out=""
  sect_out=$("$0" --agent-section-lint "$td/repo" 2>&1) || true
  if grep -q "totally-unlisted-section" <<< "$sect_out" \
    && grep -q 'agents/developer.md' <<< "$sect_out" \
    && grep -q 'cache-lint.sh' <<< "$sect_out"; then
    echo "self-test: agent-section-lint reject unlisted: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: agent-section-lint reject unlisted: FAIL (unlisted section accepted)" >&2; exit 1
  fi

  cat > "$td/repo/agents/developer.md" <<'EOF'
Write the summary to `development-N.md` under `## files-changed`.
A bare mention of `## another-unlisted` with no artifact filename is not a mandate.
EOF
  if "$0" --agent-section-lint "$td/repo" >/dev/null 2>&1; then
    echo "self-test: agent-section-lint accept listed + under-match: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: agent-section-lint accept listed + under-match: FAIL" >&2; exit 1
  fi

  # The real tree must satisfy the same invariant — this is the #16 gate DV3 re-runs.
  if "$0" --agent-section-lint "$SELF_REPO_ROOT" >/dev/null 2>&1; then
    echo "self-test: agent-section-lint against this repo: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: agent-section-lint against this repo: FAIL" >&2; exit 1
  fi

  echo "self-test: ALL PASS ($_SELFTEST_PASSED passed, 0 failed)"
}
