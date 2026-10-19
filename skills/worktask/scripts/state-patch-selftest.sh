#!/usr/bin/env bash
# state-patch-selftest.sh — the `--self-test` harness for state-patch.sh.
#
# SOURCED, never executed: state-patch.sh loads this file only on the
# `--self-test` path, so the ledger-write path never pays for it. Sourcing
# leaves `$0` pointing at state-patch.sh, which the harness depends on: every
# case re-invokes the caller through `bash "$SELF"`, and `SELF` is rebuilt from
# `$0`. Do not rewrite that against BASH_SOURCE.
#
# Contract: defines exactly one function, `run_self_test`, which owns the exit
# for this invocation (0 on ALL PASS, 1 on the first failing case).

run_self_test() {
  _SELFTEST_PASSED=0
  # Resolve path BEFORE any cd so subprocess calls work.
  local SELF
  SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

  local td
  td=$(mktemp -d "${TMPDIR:-/tmp}/state-patch-selftest-XXXXXX")
  # shellcheck disable=SC2064   # expand $td now so the trap removes the right dir
  trap "rm -rf '${td}'" EXIT

  cd "$td"
  mkdir -p .context/logs
  # Fixtures are non-git temp dirs: without a declared root the ladder's rank 5/6 both
  # miss (no enclosing git repo, no resolver hit), and every case silently no-ops.
  export WORKSPACE_ROOT="$td"

  # ---- Fixture helpers ----
  make_state() {
    cat > .context/state.json << 'EOSTATE'
{"version":2,"worktask_id":"selftest","plan_file":".context/planning-0.md","platform":"all","run_index":0,"tasks":{"PL0":{"status":"completed","verdict":"ok"}},"facts":{"files_modified":[],"tests_added":[],"decisions":[],"open_questions":[],"verdicts":{"PL":"ok"}},"handoffs":{}}
EOSTATE
  }

  # Every non-PL/IR --task-create row needs the five dispatch-shape keys, so
  # fixtures merge them in rather than restating them at every call site.
  _r9_meta() {
    jq -cn --argjson x "${1:-null}" \
      '{effort:"high",isolation:"worktree",base_ref:"origin/develop",requires_screenshots:false,workspace_path:"/tmp/wt"} + ($x // {})'
  }

  # ---- T1: explicit --artifact path, frontmatter present ----
  make_state
  cat > .context/development-0.md << 'EOART'
---
handoff:
  stage: DV
  verdict: ok
  summary: "self-test artifact T1"
  files_touched: [a.md]
  next_stage_focus: "DR reviews"
  refs: { dev: development.md#files-changed }
---

# Development
EOART
  bash "$SELF" --stage DV --artifact .context/development-0.md \
    || {
      printf 'T1: state-patch returned non-zero\n' >&2
      exit 1
    }
  if jq -e '.tasks.DV0.status == "completed" and .tasks.DV0.verdict == "ok"' \
    .context/state.json > /dev/null; then
    printf 'T1: explicit artifact → patched: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T1: explicit artifact → patch missing: FAIL\n' >&2
    exit 1
  fi

  # ---- T2: idempotency — re-run must leave state.json byte-identical ----
  cp .context/state.json .context/state.json.snap
  bash "$SELF" --stage DV --artifact .context/development-0.md
  if diff -q .context/state.json .context/state.json.snap > /dev/null; then
    printf 'T2: idempotent re-run: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T2: idempotent re-run: FAIL (state changed)\n' >&2
    exit 1
  fi

  # ---- T3: no --artifact, resolve via run_index=0 from state.json ----
  make_state
  # development-0.md already exists from T1.
  bash "$SELF" --stage DV \
    || {
      printf 'T3: state-patch returned non-zero\n' >&2
      exit 1
    }
  if jq -e '.tasks.DV0.status == "completed" and (.tasks.DV0.artifact | endswith("development-0.md"))' \
    .context/state.json > /dev/null; then
    printf 'T3: run_index-resolved artifact: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T3: run_index-resolved artifact: FAIL\n' >&2
    exit 1
  fi

  # ---- T4: highest-N fallback when run_index absent from state.json ----
  cat > .context/state.json << 'EOSTATE'
{"version":2,"worktask_id":"selftest","plan_file":".context/planning-0.md","platform":"all","tasks":{"PL0":{"status":"completed","verdict":"ok"}},"facts":{"verdicts":{"PL":"ok"}},"handoffs":{}}
EOSTATE
  cat > .context/architecture-1.md << 'EOART'
---
handoff:
  stage: AR
  verdict: blocked
  summary: "highest-N artifact"
  refs: { plan: planning-0.md#requirements }
---
EOART
  cat > .context/architecture-0.md << 'EOART'
---
handoff:
  stage: AR
  verdict: ok
  summary: "lower-N artifact"
  refs: { plan: planning-0.md#requirements }
---
EOART
  bash "$SELF" --stage AR \
    || {
      printf 'T4: state-patch returned non-zero\n' >&2
      exit 1
    }
  if jq -e '.tasks.AR0.verdict == "blocked" and (.tasks.AR0.artifact | endswith("architecture-1.md"))' \
    .context/state.json > /dev/null; then
    printf 'T4: highest-N wins when run_index absent: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T4: highest-N resolution: FAIL\n' >&2
    jq '.tasks.AR0' .context/state.json >&2
    exit 1
  fi

  # ---- T5: absent artifact → no-op, state unchanged ----
  cat > .context/state.json << 'EOSTATE'
{"version":2,"worktask_id":"selftest","plan_file":".context/planning-0.md","platform":"all","tasks":{"PL0":{"status":"completed","verdict":"ok"}},"facts":{"verdicts":{"PL":"ok"}},"handoffs":{}}
EOSTATE
  cp .context/state.json .context/state.json.snap2
  # No QA artifact exists.
  bash "$SELF" --stage QA \
    || {
      printf 'T5: state-patch returned non-zero\n' >&2
      exit 1
    }
  if diff -q .context/state.json .context/state.json.snap2 > /dev/null; then
    printf 'T5: absent artifact → no-op: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T5: absent artifact → no-op: FAIL (state changed)\n' >&2
    exit 1
  fi

  # ---- T6: disk guard — warn threshold only (no halt) ----
  # We can't safely drop disk space in a test, so we prove the guard degrades
  # gracefully when df output is unparseable (empty avail_gb).
  make_state
  cat > .context/testing-0.md << 'EOART'
---
handoff:
  stage: QA
  verdict: go
  summary: "disk guard T6"
  refs: { dev: development-0.md#files-changed }
---
EOART
  bash "$SELF" --stage QA --artifact .context/testing-0.md --disk-check /nonexistent_mountpoint_selftest \
    || {
      printf 'T6: disk-guard degrade: non-zero exit\n' >&2
      exit 1
    }
  if jq -e '.tasks.QA0.status == "completed"' .context/state.json > /dev/null; then
    printf 'T6: disk-guard degrade on unparseable df → patch applied: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T6: disk-guard degrade: FAIL\n' >&2
    exit 1
  fi

  # ---- T8: --prev writes handoffs["PREV→TASK_ID"] from the parsed summary + ref ----
  make_state
  cat > .context/architecture-0.md << 'EOART'
---
handoff:
  stage: AR
  verdict: ok
  summary: "approach validated; DV split confirmed"
  refs: { plan: planning-0.md#requirements }
---
EOART
  bash "$SELF" --stage AR --prev PL --artifact .context/architecture-0.md \
    || {
      printf 'T8: state-patch returned non-zero\n' >&2
      exit 1
    }
  if jq -e '(.handoffs["PL→AR0"] // "") | test("approach validated") and test("ref:architecture-0.md")' \
    .context/state.json > /dev/null; then
    printf 'T8: --prev writes handoffs edge from summary+ref: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T8: --prev handoffs edge: FAIL\n' >&2
    jq '.handoffs' .context/state.json >&2
    exit 1
  fi
  # Absent --prev must NOT synthesize a handoffs edge (byte-stable default path).
  make_state
  bash "$SELF" --stage AR --artifact .context/architecture-0.md
  if jq -e '(.handoffs | length) == 0' .context/state.json > /dev/null; then
    printf 'T8: absent --prev leaves handoffs untouched: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T8: absent --prev must not add handoffs: FAIL\n' >&2
    exit 1
  fi

  # ---- T10: remediation re-merge — same verdict, new summary must refresh the handoff edge ----
  make_state
  cat > .context/development-0.md << 'EOART'
---
handoff:
  stage: DV
  verdict: ok
  summary: "first pass, pre-review"
  refs: { dev: development.md#files-changed }
---
EOART
  bash "$SELF" --stage DV --prev AR --artifact .context/development-0.md \
    || {
      printf 'T10: state-patch returned non-zero (round 1)\n' >&2
      exit 1
    }
  cat > .context/development-0.md << 'EOART'
---
handoff:
  stage: DV
  verdict: ok
  summary: "remediated after DR round 1"
  refs: { dev: development.md#files-changed }
---
EOART
  bash "$SELF" --stage DV --prev AR --artifact .context/development-0.md \
    || {
      printf 'T10: state-patch returned non-zero (round 2)\n' >&2
      exit 1
    }
  if jq -e '(.handoffs["AR→DV0"] // "") | test("remediated after DR round 1")' \
    .context/state.json > /dev/null; then
    printf 'T10: same-verdict remediation refreshes handoff edge: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T10: same-verdict remediation left a stale handoff edge: FAIL\n' >&2
    jq '.handoffs' .context/state.json >&2
    exit 1
  fi
  # A third identical run must still be a byte-identical no-op (T2 invariant preserved).
  cp .context/state.json .context/state.before
  bash "$SELF" --stage DV --prev AR --artifact .context/development-0.md
  if cmp -s .context/state.json .context/state.before; then
    printf 'T10: unchanged re-run stays idempotent: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T10: unchanged re-run must not rewrite state: FAIL\n' >&2
    exit 1
  fi

  # ---- T9: B3 bounds — decisions clamp to newest-8 PER TASK, dispatched_agents to 6 ----
  # Seed 10 PL0 decisions + 10 AR0 decisions + 8 dispatched_agents (mix launched/completed),
  # then patch any stage; atomic_apply must clamp at the single chokepoint, and the two
  # decision buckets must survive each other — a global ring keeps 8 of the 20 in total.
  jq -n '
    {version:2, worktask_id:"selftest", plan_file:".context/planning-0.md",
     platform:"all", run_index:0,
     tasks:{PL0:{status:"completed", verdict:"ok", metadata:{}}},
     facts:{
       files_modified:[], tests_added:[], open_questions:[], verdicts:{PL:"ok"},
       decisions:(
         [ range(0;10) | {id:("d"+(.|tostring)), summary:("dec "+(.|tostring)),
                          ref:"x.md#y", stage:"PL0"} ]
       + [ range(0;10) | {id:("a"+(.|tostring)), summary:("arc "+(.|tostring)),
                          ref:"x.md#y", stage:"AR0"} ]),
       dispatched_agents:(
         [ range(0;6) | {stage:"DV", task_id:("t"+(.|tostring)), subagent_type:"a", status:"completed"} ]
         + [ range(6;8) | {stage:"DV", task_id:("t"+(.|tostring)), subagent_type:"a", status:"launched"} ])
     },
     handoffs:{}}' > .context/state.json
  bash "$SELF" --stage DV --artifact .context/development-0.md \
    || {
      printf 'T9: state-patch returned non-zero\n' >&2
      exit 1
    }
  if jq -e '(.facts.decisions | length) == 16
            and ([.facts.decisions[] | select(.stage == "PL0") | .id] == ["d2","d3","d4","d5","d6","d7","d8","d9"])
            and ([.facts.decisions[] | select(.stage == "AR0") | .id] == ["a2","a3","a4","a5","a6","a7","a8","a9"])' \
    .context/state.json > /dev/null; then
    printf 'T9: facts.decisions clamped to newest-8 per task, both buckets survive: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T9: decisions bound: FAIL\n' >&2
    jq '.facts.decisions | map(.id)' .context/state.json >&2
    exit 1
  fi
  if jq -e '(.facts.dispatched_agents | length) == 6 and ([.facts.dispatched_agents[] | select(.status == "launched")] | length) == 2' \
    .context/state.json > /dev/null; then
    printf 'T9: dispatched_agents clamped to 6, launched survive: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T9: dispatched_agents bound: FAIL\n' >&2
    jq '.facts.dispatched_agents | map({task_id, status})' .context/state.json >&2
    exit 1
  fi

  # ---- T11: alias basename resolves; canonical still wins when both exist ----
  make_state
  rm -f .context/testing-*.md .context/qa-*.md
  cat > .context/qa-0.md << 'EOART'
---
handoff:
  stage: QA
  verdict: go
  summary: "alias-named artifact"
  refs: { dev: development-0.md#files-changed }
---
EOART
  bash "$SELF" --stage QA \
    || {
      printf 'T11: state-patch returned non-zero\n' >&2
      exit 1
    }
  if jq -e '.tasks.QA0.status == "completed" and (.tasks.QA0.artifact | endswith("qa-0.md"))' \
    .context/state.json > /dev/null; then
    printf 'T11: alias basename resolves: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T11: alias basename resolution: FAIL\n' >&2
    exit 1
  fi
  make_state
  cat > .context/testing-0.md << 'EOART'
---
handoff:
  stage: QA
  verdict: go
  summary: "canonical artifact"
  refs: { dev: development-0.md#files-changed }
---
EOART
  bash "$SELF" --stage QA
  if jq -e '(.tasks.QA0.artifact | endswith("testing-0.md"))' .context/state.json > /dev/null; then
    printf 'T11: canonical preferred over alias: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T11: canonical must outrank alias: FAIL\n' >&2
    exit 1
  fi
  rm -f .context/qa-0.md

  # ---- T12: self-patch (--prev, no --via) with no artifact ⇒ exit 3, state unchanged ----
  make_state
  rm -f .context/retrospective-*.md
  cp .context/state.json .context/state.json.snap3
  set +e
  st12_out=$(bash "$SELF" --stage ST --prev FN 2>&1)
  st12_rc=$?
  set -e
  if [[ "$st12_rc" -eq 3 ]] && printf '%s' "$st12_out" | grep -q 'retrospective-N.md'; then
    printf 'T12: unresolved self-patch exits 3 naming the basenames: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T12: unresolved self-patch must exit 3 (got %s): FAIL\n' "$st12_rc" >&2
    exit 1
  fi
  if diff -q .context/state.json .context/state.json.snap3 > /dev/null; then
    printf 'T12: exit 3 leaves state untouched: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T12: exit 3 must not alter state: FAIL\n' >&2
    exit 1
  fi
  # The hook path (--via) keeps the exit-0 no-op contract even with --prev present.
  set +e
  bash "$SELF" --stage ST --prev FN --via hook > /dev/null 2>&1
  st12b_rc=$?
  set -e
  if [[ "$st12b_rc" -eq 0 ]]; then
    printf 'T12: --via keeps the unresolved no-op at exit 0: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T12: --via must not fail loudly (got %s): FAIL\n' "$st12b_rc" >&2
    exit 1
  fi

  # ---- T13: --prev USER writes the origin edge ----
  make_state
  cat > .context/planning-0.md << 'EOART'
---
handoff:
  stage: PL
  verdict: ok
  summary: "origin edge from the user"
  refs: { plan: planning-0.md#requirements }
---
EOART
  bash "$SELF" --stage PL --prev USER --artifact .context/planning-0.md \
    || {
      printf 'T13: state-patch returned non-zero\n' >&2
      exit 1
    }
  if jq -e '(.handoffs["USER→PL0"] // "") | test("origin edge from the user")' \
    .context/state.json > /dev/null; then
    printf 'T13: --prev USER writes the USER→PL0 edge: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T13: --prev USER edge: FAIL\n' >&2
    jq '.handoffs' .context/state.json >&2
    exit 1
  fi

  # ---- Fixture for T15: the ledger shape the split-stage cases resolve against ----
  # The ledger-op ASSERTIONS that used to live here (create / duplicate-create /
  # bare create / block union / unblock / unblock no-op / malformed id / unknown
  # id) moved to state-patch.bats — the seven "ledger ops:" arms. Only the state
  # they left behind is kept, because T15 reads it and never seeds its own.
  make_state
  bash "$SELF" --task-create DV0 --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer"}')" \
    && bash "$SELF" --task-create DV1 --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer"}')" \
    && bash "$SELF" --task-create DR0 --metadata "$(_r9_meta '{"stage":"DR","agent":"corpflow:technical-lead"}')" \
    && bash "$SELF" --task-block DR0 --on DV0,DV1 \
    && bash "$SELF" --task-create QA0 --metadata "$(_r9_meta)" \
    && bash "$SELF" --task-unblock DR0 --off DV1 \
    && bash "$SELF" --task-status DV0 in_progress \
    || {
      printf 'T15 fixture: ledger op returned non-zero\n' >&2
      exit 1
    }
  # ---- T15: split-stage id resolution (the case bare stage codes could not express) ----
  # DV0 in_progress + DV1 pending: the running instance outranks the queued one, so a
  # bare --stage DV cannot stamp the higher-numbered track that has not started.
  t15_id=$(bash "$SELF" --resolve-task-id DV)
  if [[ "$t15_id" == "DV0" ]]; then
    printf 'T15: in_progress instance outranks pending: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T15: in_progress must win (got %s): FAIL\n' "$t15_id" >&2
    jq '.tasks' .context/state.json >&2
    exit 1
  fi

  bash "$SELF" --task-status DV0 completed > /dev/null
  t15_id=$(bash "$SELF" --resolve-task-id DV)
  if [[ "$t15_id" == "DV1" ]]; then
    printf 'T15: settled instance yields to the pending one: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T15: pending must win once DV0 settles (got %s): FAIL\n' "$t15_id" >&2
    exit 1
  fi
  cat > .context/development-0.md << 'EOSPLIT'
---
handoff:
  stage: DV
  verdict: ok
  summary: "second track"
---
EOSPLIT
  bash "$SELF" --stage DV --via step6_5 \
    || {
      printf 'T15: state-patch returned non-zero\n' >&2
      exit 1
    }
  if jq -e '.tasks.DV1.status == "completed" and .tasks.DV1.verdict == "ok"
            and (.tasks.DV0.artifact // "") == ""' .context/state.json > /dev/null; then
    printf 'T15: --stage resolves to the open split instance: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T15: split-stage resolution: FAIL\n' >&2
    jq '.tasks' .context/state.json >&2
    exit 1
  fi

  bash "$SELF" --stage DV --task-id DV0 --via step6_5 > /dev/null
  if jq -e '(.tasks.DV0.artifact // "") | endswith("development-0.md")' \
    .context/state.json > /dev/null; then
    printf 'T15: explicit --task-id overrides resolution: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T15: --task-id override: FAIL\n' >&2
    exit 1
  fi

  # ---- T15b/c/d/e: artifact-first resolution for a genuinely ambiguous split stage ----
  # T15 above only ever has ONE open instance, so it passes with or without the artifact
  # tier — which is how the mis-slotting defect stayed invisible.  These four put two
  # `in_progress` instances in the ledger, the shape a fanned-out DV run actually has.
  cat > .context/state.json << 'EOSTATE'
{"version":2,"worktask_id":"selftest","plan_file":".context/planning-0.md","platform":"all","run_index":0,"tasks":{"DV0":{"status":"in_progress","metadata":{"artifact":".context/development-0-gate.md"}},"DV1":{"status":"in_progress","metadata":{"artifact":".context/development-0-ledger.md"}}},"facts":{},"handoffs":{}}
EOSTATE
  t15b_id=$(bash "$SELF" --resolve-task-id DV --artifact .context/development-0-ledger.md)
  if [[ "$t15b_id" == "DV1" ]]; then
    printf 'T15b: --artifact picks the matching instance out of two in_progress: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T15b: artifact-first resolution (got %s, want DV1): FAIL\n' "$t15b_id" >&2
    exit 1
  fi

  # Absolute and ./-prefixed callers must land on the same key as the stored relative path.
  t15e_id=$(bash "$SELF" --resolve-task-id DV --artifact "$PWD/.context/development-0-ledger.md")
  t15e_id2=$(bash "$SELF" --resolve-task-id DV --artifact ./.context/development-0-ledger.md)
  if [[ "$t15e_id" == "DV1" && "$t15e_id2" == "DV1" ]]; then
    printf 'T15e: absolute and ./-prefixed artifacts resolve like the relative one: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T15e: path normalisation (abs=%s dot=%s, want DV1): FAIL\n' "$t15e_id" "$t15e_id2" >&2
    exit 1
  fi

  # The recorded artifact beats another instance's PLANNED one: PL0 seeds metadata from the
  # plan, and a split stage routinely writes a file the plan did not predict.
  jq '.tasks.DV0.artifact = ".context/development-1.md"
      | .tasks.DV1.metadata.artifact = ".context/development-1.md"' \
    .context/state.json > .context/state.json.t15f && mv .context/state.json.t15f .context/state.json
  t15f_id=$(bash "$SELF" --resolve-task-id DV --artifact .context/development-1.md)
  if [[ "$t15f_id" == "DV0" ]]; then
    printf 'T15f: recorded artifact outranks a stale planned one: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T15f: recorded-before-planned precedence (got %s, want DV0): FAIL\n' "$t15f_id" >&2
    exit 1
  fi

  # No discriminator: refuse, name both candidates, and leave the ledger byte-identical.
  cat > .context/state.json << 'EOSTATE'
{"version":2,"worktask_id":"selftest","plan_file":".context/planning-0.md","platform":"all","run_index":0,"tasks":{"DV0":{"status":"in_progress"},"DV1":{"status":"in_progress"}},"facts":{},"handoffs":{}}
EOSTATE
  cp .context/state.json .context/state.json.snap15c
  t15c_rc=0
  t15c_err=$(bash "$SELF" --stage DV --artifact .context/development-0.md --via step6_5 2>&1 > /dev/null) \
    || t15c_rc=$?
  if [[ "$t15c_rc" == "4" ]] \
    && printf '%s' "$t15c_err" | grep -q 'DV0,DV1' \
    && diff -q .context/state.json .context/state.json.snap15c > /dev/null; then
    printf 'T15c: ambiguous stage refuses with exit 4, both named, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T15c: ambiguity must fail closed (rc=%s err=%s): FAIL\n' "$t15c_rc" "$t15c_err" >&2
    exit 1
  fi
  rm -f .context/state.json.snap15c

  # T15d is the hooks/agent-stop.sh regression guard: one open instance, no --artifact,
  # behaviour identical to before the artifact tier existed.
  cat > .context/state.json << 'EOSTATE'
{"version":2,"worktask_id":"selftest","plan_file":".context/planning-0.md","platform":"all","run_index":0,"tasks":{"DV0":{"status":"in_progress"},"DV1":{"status":"pending"}},"facts":{},"handoffs":{}}
EOSTATE
  t15d_id=$(bash "$SELF" --resolve-task-id DV)
  t15d_rc=0
  bash "$SELF" --stage DV --via step6_5 > /dev/null 2>&1 || t15d_rc=$?
  if [[ "$t15d_id" == "DV0" && "$t15d_rc" == "0" ]] \
    && jq -e '.tasks.DV0.status == "completed" and .tasks.DV1.status == "pending"' \
      .context/state.json > /dev/null; then
    printf 'T15d: bare --stage with one open instance is unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T15d: bare --stage regression (id=%s rc=%s): FAIL\n' "$t15d_id" "$t15d_rc" >&2
    exit 1
  fi

  # ---- T18: --task-replay resets one task, and refuses while its agent is alive ----
  # Liveness is fixture-injected so the self-test needs no live agent and no claude CLI.
  make_state
  rm -f .context/logs/audit.jsonl
  printf '[]\n' > agents-gone.json
  printf '%s\n' '[{"id":"sess-dv0","sessionId":"sess-dv0deadbeef","name":"dv","state":"active"}]' \
    > agents-busy.json
  bash "$SELF" --task-create DV0 \
    --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer","retry_count":3,"error_escalated_to":"AR"}')" \
    > /dev/null
  bash "$SELF" --task-status DV0 in_progress > /dev/null
  # An in_progress task with no dispatch row classifies no-dispatch-record, which the guard
  # (correctly) refuses — absence of a record proves nothing about liveness. Seed one.
  jq '.facts.dispatched_agents = [{stage:"DV", task_id:"DV0",
        subagent_type:"corpflow:developer", agent_id:"sess-dv0", status:"launched"}]' \
    .context/state.json > .context/state.next && mv .context/state.next .context/state.json
  bash "$SELF" --task-replay DV0 --agents-json agents-gone.json 2> /dev/null \
    || {
      printf 'T18: --task-replay returned non-zero\n' >&2
      exit 1
    }
  if jq -e '.tasks.DV0.status == "pending"
            and (.tasks.DV0.metadata | has("retry_count") | not)
            and (.tasks.DV0.metadata | has("error_escalated_to") | not)
            and .tasks.PL0.status == "completed"' .context/state.json > /dev/null; then
    printf 'T18: replay resets the target and leaves PL0 alone: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T18: replay blast radius: FAIL\n' >&2
    jq '.tasks' .context/state.json >&2
    exit 1
  fi
  if jq -e 'select(.action == "stage_replay")
            | .task_id == "DV0" and .metadata.escalation_cap_override == true' \
    .context/logs/audit.jsonl > /dev/null; then
    printf 'T18: replay audits the cap override on success: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T18: stage_replay audit row missing: FAIL\n' >&2
    cat .context/logs/audit.jsonl >&2 2> /dev/null || true
    exit 1
  fi

  jq '.tasks.DV0.status = "in_progress"
      | .facts.dispatched_agents = [{stage:"DV", task_id:"DV0",
          subagent_type:"corpflow:developer", agent_id:"sess-dv0", status:"launched"}]' \
    .context/state.json > .context/state.next && mv .context/state.next .context/state.json
  cp .context/state.json .context/state.json.snap18
  st18_rc=0
  bash "$SELF" --task-replay DV0 --agents-json agents-busy.json > /dev/null 2>&1 || st18_rc=$?
  if [[ "$st18_rc" -eq 4 ]] \
    && diff -q .context/state.json .context/state.json.snap18 > /dev/null; then
    printf 'T18: live target refuses with exit 4, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T18: live-target guard (rc=%s): FAIL\n' "$st18_rc" >&2
    exit 1
  fi

  # ---- T19: a partial sweep stub via --facts is rejected before the lock ----
  # The union REPLACES the incumbent object for that id, so admitting {id} alone would
  # silently drop the class/ref the FN render resolves options[] through.
  make_state
  bash "$SELF" --facts '{"open_questions":[{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}]}' \
    > /dev/null || {
      printf 'T19: a full sweep stub was rejected\n' >&2
      exit 1
    }
  cp .context/state.json .context/state.json.snap19
  st19_rc=0
  bash "$SELF" --facts '{"open_questions":[{"id":"sw-PL0-1"}]}' > /dev/null 2>&1 || st19_rc=$?
  if [[ "$st19_rc" -eq 2 ]] \
    && diff -q .context/state.json .context/state.json.snap19 > /dev/null; then
    printf 'T19: partial sweep stub exits 2, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T19: partial-stub guard (rc=%s): FAIL\n' "$st19_rc" >&2
    exit 1
  fi
  # blocks_next_stage is required too: a stub that omits it is the demotion-by-omission the
  # union's sticky arm used to absorb, refused here instead — at the door, before any merge.
  cp .context/state.json .context/state.json.snap19b
  st19b_rc=0
  bash "$SELF" --facts '{"open_questions":[{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep"}]}' \
    > /dev/null 2>&1 || st19b_rc=$?
  if [[ "$st19b_rc" -eq 2 ]] \
    && diff -q .context/state.json .context/state.json.snap19b > /dev/null; then
    printf 'T19: a stub omitting blocks_next_stage exits 2, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T19: missing-blocks_next_stage guard (rc=%s): FAIL\n' "$st19b_rc" >&2
    exit 1
  fi
  # decisions keeps the id-only contract: the tightening is scoped to open_questions.
  bash "$SELF" --facts '{"decisions":[{"id":"d1","summary":"s","ref":"planning-0.md#stages"}]}' \
    > /dev/null || {
      printf 'T19: decisions payload was rejected: FAIL\n' >&2
      exit 1
    }

  # ---- T20: raising blocks_next_stage is honoured ----
  # The lattice's live half: an item written non-blocking can be raised to blocking later.
  # Its other half — a stub that OMITS the key cannot demote — is now enforced one layer
  # earlier by the T19 shape gate, so it can no longer be reached through --facts at all;
  # the union's sticky arm survives for legacy payloads and is covered directly against the
  # filter in tests/shell/skills/elicitation-sweep-contracts.bats.
  make_state
  bash "$SELF" --facts '{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false}]}' > /dev/null
  bash "$SELF" --facts '{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":true}]}' > /dev/null
  if jq -e '.facts.open_questions[0].blocks_next_stage == true' .context/state.json > /dev/null; then
    printf 'T20: raising blocks_next_stage is honoured: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T20: a raise to blocking was refused: FAIL\n' >&2
    exit 1
  fi

  # ---- T20b: an EXPLICIT false clears an incumbent true ----
  # The OV-183 defect: the join ORed the flag, so once `true` landed no payload could clear
  # it — not even the author's own artifact value — and the ledger permanently outvoted the
  # stub it was derived from. Absent still sticks (T19 refuses it); explicit false does not.
  make_state
  bash "$SELF" --facts '{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":true}]}' > /dev/null
  bash "$SELF" --facts '{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false}]}' > /dev/null
  if jq -e '.facts.open_questions[0].blocks_next_stage == false' .context/state.json > /dev/null; then
    printf 'T20b: an explicit false clears an incumbent true: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T20b: explicit false could not clear the flag: FAIL\n' >&2
    exit 1
  fi

  # ---- T20c: class is raise-only; a refused downgrade exits 2 with one audit row ----
  # The ledger cannot tell labellers apart, so `decision` over `escalate` is refused while
  # the stub's other fields still land.
  _oq_esc='{"open_questions":[{"id":"sw-SR0-1","class":"escalate","ref":"security-review-0.md#elicitation-sweep","blocks_next_stage":true}]}'
  _oq_dec='{"open_questions":[{"id":"sw-SR0-1","class":"decision","ref":"security-review-1.md#elicitation-sweep","blocks_next_stage":false}]}'
  make_state
  rm -f .context/logs/audit.jsonl
  bash "$SELF" --facts "$_oq_esc" > /dev/null
  st20c_rc=0
  bash "$SELF" --facts "$_oq_dec" > .context/t20c.out 2> .context/t20c.err || st20c_rc=$?
  if [[ "$st20c_rc" -eq 2 ]] \
    && jq -e '.facts.open_questions[0] | .class == "escalate" and .blocks_next_stage == false
              and .ref == "security-review-1.md#elicitation-sweep"' .context/state.json > /dev/null \
    && [[ "$(jq -c 'select(.action == "facts_items_rejected") | .metadata.rejected[] | select(.label == "sw-SR0-1")' \
           .context/logs/audit.jsonl | grep -c '^')" -eq 1 ]] \
    && grep -q 'class downgrade escalate -> decision refused' .context/t20c.out \
    && grep -q 'class downgrade escalate -> decision refused' .context/t20c.err; then
    printf 'T20c: escalate -> decision refused, other fields land, one audit row, rc=2: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T20c: class downgrade not refused/reported (rc=%s): FAIL\n' "$st20c_rc" >&2
    jq -c '.facts.open_questions' .context/state.json >&2
    cat .context/t20c.err >&2
    exit 1
  fi

  # ---- T20d: the refusal survives the --stage fall-through: merge lands, exit still 2 ----
  make_state
  bash "$SELF" --facts "$_oq_esc" > /dev/null
  st20d_rc=0
  bash "$SELF" --stage DV --artifact .context/development-0.md --facts "$_oq_dec" \
    > /dev/null 2>&1 || st20d_rc=$?
  if [[ "$st20d_rc" -eq 2 ]] \
    && [[ "$(jq -r '.tasks.DV0.status' .context/state.json)" == "completed" ]] \
    && jq -e '.facts.open_questions[0].class == "escalate"' .context/state.json > /dev/null; then
    printf 'T20d: refused downgrade with --stage still merges the stage and exits 2: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T20d: refusal lost or merge aborted on --stage (rc=%s): FAIL\n' "$st20d_rc" >&2
    exit 1
  fi

  # ---- T20e: a raise decision -> escalate is honoured, exit 0, no audit row ----
  make_state
  rm -f .context/logs/audit.jsonl
  bash "$SELF" --facts '{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false}]}' > /dev/null
  st20e_rc=0
  bash "$SELF" --facts '{"open_questions":[{"id":"sw-DV0-1","class":"escalate","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false}]}' \
    > /dev/null 2>&1 || st20e_rc=$?
  if [[ "$st20e_rc" -eq 0 ]] \
    && jq -e '.facts.open_questions[0].class == "escalate"' .context/state.json > /dev/null \
    && ! grep -q 'facts_items_rejected' .context/logs/audit.jsonl 2> /dev/null; then
    printf 'T20e: decision -> escalate raise honoured, rc=0, no rejection row: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T20e: class raise refused or reported (rc=%s): FAIL\n' "$st20e_rc" >&2
    exit 1
  fi

  # ---- T20f: three replayed downgrades leave escalate and write one row each ----
  make_state
  rm -f .context/logs/audit.jsonl
  bash "$SELF" --facts "$_oq_esc" > /dev/null
  t20f_ok=1
  for _i in 1 2 3; do
    bash "$SELF" --facts "$_oq_dec" > /dev/null 2>&1 || true
    jq -e '.facts.open_questions[0].class == "escalate"' .context/state.json > /dev/null || t20f_ok=0
  done
  if [[ "$t20f_ok" -eq 1 ]] \
    && [[ "$(grep -c '"facts_items_rejected"' .context/logs/audit.jsonl)" -eq 3 ]]; then
    printf 'T20f: 3 replayed downgrades keep escalate, 3 rejection rows: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T20f: replayed downgrade lowered the class or miscounted rows: FAIL\n' >&2
    exit 1
  fi

  # ---- T24: --facts rejects per item, persisting the valid remainder ----
  # One bad class value used to discard the whole write — decisions, changed files and
  # every valid sweep stub in the same object.
  make_state
  st24_rc=0
  bash "$SELF" --facts '{
      "decisions":[{"id":"d-good","summary":"kept"},{"summary":"no id"}],
      "files_modified":["a.sh", 42],
      "open_questions":[
        {"id":"sw-DV0-1","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false},
        {"id":"sw-DV0-2","class":"risk","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false}]
    }' > /dev/null 2> .context/t24.err || st24_rc=$?
  if [[ "$st24_rc" -eq 2 ]] \
    && jq -e '(.facts.decisions | map(.id)) == ["d-good"]
              and (.facts.files_modified) == ["a.sh"]
              and (.facts.open_questions | map(.id)) == ["sw-DV0-1"]' \
      .context/state.json > /dev/null \
    && grep -q 'sw-DV0-2' .context/t24.err; then
    printf 'T24: --facts persists the valid remainder and names each rejection (rc=2): ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T24: per-item rejection did not partition the payload (rc=%s): FAIL\n' "$st24_rc" >&2
    jq -c '.facts' .context/state.json >&2
    cat .context/t24.err >&2
    exit 1
  fi

  # ---- T24b: an unknown key is still a whole-payload refusal ----
  # Per-item rejection is about item shape; an unknown key means the caller is writing to a
  # slot that does not exist, and no part of that payload can be trusted to land where meant.
  cp .context/state.json .context/state.json.snap24b
  st24b_rc=0
  bash "$SELF" --facts '{"decisions":[{"id":"d-x"}],"nope":[]}' > /dev/null 2>&1 || st24b_rc=$?
  if [[ "$st24b_rc" -eq 2 ]] \
    && diff -q .context/state.json .context/state.json.snap24b > /dev/null; then
    printf 'T24b: an unknown key refuses the whole payload, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T24b: unknown-key guard (rc=%s): FAIL\n' "$st24b_rc" >&2
    exit 1
  fi

  # ---- T24c: a rejection diagnostic is not buried under the help text ----
  # The reproduction: the real message scrolled past behind a ~100-line usage dump.
  bash "$SELF" --facts '{"open_questions":[{"id":"sw-PL0-1"}]}' > /dev/null 2> .context/t24c.err || true
  if [[ "$(grep -c '^' .context/t24c.err)" -le 6 ]] \
    && ! grep -q 'state-patch.sh --stage' .context/t24c.err; then
    printf 'T24c: a rejection prints its diagnostic, not the usage block: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T24c: rejection diagnostic buried under usage (%s lines): FAIL\n' \
      "$(grep -c '^' .context/t24c.err)" >&2
    exit 1
  fi

  # ---- T24d: an EMPTY payload is a no-op success, not a refusal ----
  # The sweep contract tells a stage with nothing to ask to emit `open_questions: []`. Refusing
  # that aborted the stage-completion merge the same call was paired with.
  make_state
  cp .context/state.json .context/state.json.snap24d
  st24d_rc=0
  bash "$SELF" --facts '{"open_questions":[]}' > /dev/null 2>&1 || st24d_rc=$?
  if [[ "$st24d_rc" -eq 0 ]] \
    && diff -q .context/state.json .context/state.json.snap24d > /dev/null; then
    printf 'T24d: an empty --facts payload is a no-op success, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T24d: empty payload refused (rc=%s): FAIL\n' "$st24d_rc" >&2
    exit 1
  fi
  # And it must not abort the stage merge it is paired with — the shape every agent emits.
  st24e_rc=0
  bash "$SELF" --stage DV --artifact .context/development-0.md --facts '{"open_questions":[]}' \
    > /dev/null 2>&1 || st24e_rc=$?
  if [[ "$st24e_rc" -eq 0 ]] \
    && [[ "$(jq -r '.tasks.DV0.status' .context/state.json)" == "completed" ]]; then
    printf 'T24e: --stage paired with an empty --facts still patches the ledger: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T24e: empty --facts aborted the stage merge (rc=%s): FAIL\n' "$st24e_rc" >&2
    jq -c '.tasks.DV0' .context/state.json >&2
    exit 1
  fi

  # ---- T24f: a partial payload paired with --stage still exits 2 ----
  # The rejection must survive the fall-through, or a combined call hides it.
  make_state
  st24f_rc=0
  bash "$SELF" --stage DV --artifact .context/development-0.md --facts \
    '{"decisions":[{"id":"d-ok"},{"summary":"no id"}]}' > /dev/null 2>&1 || st24f_rc=$?
  if [[ "$st24f_rc" -eq 2 ]] \
    && [[ "$(jq -r '.tasks.DV0.status' .context/state.json)" == "completed" ]] \
    && jq -e '[.facts.decisions[].id] | index("d-ok")' .context/state.json > /dev/null; then
    printf 'T24f: a partial --facts beside --stage completes the merge and still exits 2: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T24f: combined partial-facts exit wrong (rc=%s): FAIL\n' "$st24f_rc" >&2
    exit 1
  fi

  # ---- T25: a --facts write that lands nothing is loud ----
  # log_msg writes only to the log file, so an absent ledger exited 0 with nothing on stderr.
  rm -rf .context
  mkdir -p .context
  st25_rc=0
  bash "$SELF" --facts '{"decisions":[{"id":"d-1"}]}' > /dev/null 2> t25.err || st25_rc=$?
  if [[ "$st25_rc" -ne 0 ]] && grep -q 'no ledger' t25.err; then
    printf 'T25: a facts write with no ledger fails loudly on stderr: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T25: absent-ledger facts write was silent (rc=%s): FAIL\n' "$st25_rc" >&2
    exit 1
  fi

  # ---- T26: metadata.description is capped on the two ledger write paths ----
  make_state
  T26_LONG=$(printf 'x%.0s' $(seq 1 400))
  bash "$SELF" --task-create DV9 --metadata "$(_r9_meta "$(jq -nc --arg d "$T26_LONG" '{stage:"DV",description:$d}')")" > /dev/null 2> t26c.err
  bash "$SELF" --task-meta DV9 --set "$(jq -nc --arg d "$T26_LONG" '{description:$d}')" > /dev/null 2> t26m.err
  if jq -e '(.tasks.DV9.metadata.description | length) == 240
            and (.tasks.DV9.metadata.description | endswith("…"))
            and .tasks.DV9.metadata.stage == "DV"' .context/state.json > /dev/null; then
    printf 'T26: an over-long description is truncated, not rejected, on create and meta: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T26: description cap did not apply: FAIL\n' >&2
    jq -c '.tasks.DV9' .context/state.json >&2
    exit 1
  fi
  # The cut is silent no more: one notice per cut on stderr, none for a value that fits.
  bash "$SELF" --task-meta DV9 --set '{"description":"short label"}' > /dev/null 2> t26s.err
  if grep -qx 'description_truncated=DV9:400' t26c.err && grep -qx 'description_truncated=DV9:400' t26m.err \
    && ! grep -q 'description_truncated' t26s.err; then
    printf 'T26: a cut prints description_truncated=<id>:<len> on stderr, a short value prints none: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T26: truncation notice missing or spurious: FAIL\n' >&2
    cat t26c.err t26m.err t26s.err >&2
    exit 1
  fi

  # ---- T26b: --task-meta --unset deletes keys, never pipeline keys ----
  make_state
  bash "$SELF" --task-create DV9 --metadata "$(_r9_meta '{"stage":"DV","note":"x","flag":true}')" > /dev/null
  bash "$SELF" --task-meta DV9 --unset note > /dev/null
  if ! jq -e '.tasks.DV9.metadata | has("note")' .context/state.json > /dev/null \
    && jq -e '.tasks.DV9.metadata.flag == true and .tasks.DV9.metadata.stage == "DV"' .context/state.json > /dev/null; then
    printf 'T26b: --unset removes an existing key and keeps the rest: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T26b: --unset did not remove the key: FAIL\n' >&2
    jq -c '.tasks.DV9.metadata' .context/state.json >&2
    exit 1
  fi
  cp .context/state.json t26b.before
  t26b_rc=0
  bash "$SELF" --task-meta DV9 --unset never_there > /dev/null 2>&1 || t26b_rc=$?
  if [[ "$t26b_rc" -eq 0 ]] && cmp -s t26b.before .context/state.json; then
    printf 'T26b: --unset of an absent key exits 0 and leaves the bytes unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T26b: absent-key --unset rc=%s or changed state: FAIL\n' "$t26b_rc" >&2
    exit 1
  fi
  t26b_rc=0
  bash "$SELF" --task-meta DV9 --unset flag,stage > /dev/null 2> t26b.err || t26b_rc=$?
  if [[ "$t26b_rc" -eq 2 ]] && grep -q 'refused --unset stage' t26b.err && cmp -s t26b.before .context/state.json; then
    printf 'T26b: --unset of a pipeline key exits 2, names it, and changes nothing: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T26b: protected-key --unset rc=%s or changed state: FAIL\n' "$t26b_rc" >&2
    cat t26b.err >&2
    exit 1
  fi
  bash "$SELF" --task-meta DV9 --set '{"owner":"qa"}' --unset flag > /dev/null
  if jq -e '.tasks.DV9.metadata.owner == "qa" and (.tasks.DV9.metadata | has("flag") | not)' .context/state.json > /dev/null; then
    printf 'T26b: --set and --unset in one call apply both: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T26b: combined --set/--unset did not apply both: FAIL\n' >&2
    jq -c '.tasks.DV9.metadata' .context/state.json >&2
    exit 1
  fi

  # ---- T27: verdict → status seam matches a literal table, across all 9 verdicts ----
  # The table is retyped here rather than calling verdict_status(): reusing the function
  # under test cannot catch a regression in its own map.
  make_state
  t27_write_art() {
    cat > ".context/t27-${1}.md" << EOART
---
handoff:
  stage: DV
  verdict: ${2}
  summary: "self-test T27 ${2}"
  files_touched: [a.md]
  next_stage_focus: "n/a"
  refs: { dev: development.md#files-changed }
---

# T27 ${2}
EOART
  }
  t27_n=0
  for t27_v in ok pass go approve blocked escalate fail reject no-go; do
    t27_n=$((t27_n + 1))
    t27_id="V${t27_n}"
    t27_write_art "$t27_id" "$t27_v"
    bash "$SELF" --stage DV --task-id "$t27_id" --artifact ".context/t27-${t27_id}.md" > /dev/null \
      || {
        printf 'T27: state-patch failed for verdict %s\n' "$t27_v" >&2
        exit 1
      }
  done
  if jq -e --argjson seam '
      {"ok":"completed","pass":"completed","go":"completed","approve":"completed",
       "blocked":"blocked","escalate":"blocked",
       "fail":"pending","reject":"pending","no-go":"pending"}' '
      ([.tasks[] | select(.verdict) | select(.status != $seam[.verdict])] | length == 0)
      and ([.tasks[] | select(.verdict == "fail" or .verdict == "reject" or .verdict == "no-go")
            | select((.metadata.gate_from_stage // "") == "")] | length == 0)
    ' .context/state.json > /dev/null; then
    printf 'T27: 9-verdict seam matches the literal table, pending rows carry gate_from_stage: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T27: seam mismatch: FAIL\n' >&2
    jq -c '.tasks' .context/state.json >&2
    exit 1
  fi

  # An unrecognized verdict string (legacy or typo) refuses whole, never guesses a status.
  t27_write_art cond conditional
  cp .context/state.json .context/state.json.snap27
  t27c_rc=0
  bash "$SELF" --stage DV --task-id Vcond --artifact .context/t27-cond.md > /dev/null 2>&1 \
    || t27c_rc=$?
  if [[ "$t27c_rc" == "3" ]] && diff -q .context/state.json .context/state.json.snap27 > /dev/null; then
    printf 'T27: an unrecognized verdict ("conditional") refuses with exit 3, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T27: unrecognized verdict must refuse (rc=%s): FAIL\n' "$t27c_rc" >&2
    exit 1
  fi
  rm -f .context/state.json.snap27

  # ---- T28: a missing verdict refuses whole, exit 3, state byte-unchanged ----
  cat > .context/t28.md << 'EOART'
---
handoff:
  stage: DV
  summary: "self-test T28 missing verdict"
  files_touched: [a.md]
  next_stage_focus: "n/a"
  refs: { dev: development.md#files-changed }
---

# T28
EOART
  cp .context/state.json .context/state.json.snap28
  t28_rc=0
  bash "$SELF" --stage DV --task-id V28 --artifact .context/t28.md > /dev/null 2>&1 || t28_rc=$?
  if [[ "$t28_rc" == "3" ]] && diff -q .context/state.json .context/state.json.snap28 > /dev/null; then
    printf 'T28: missing verdict refuses with exit 3, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T28: missing verdict must refuse (rc=%s): FAIL\n' "$t28_rc" >&2
    exit 1
  fi
  rm -f .context/state.json.snap28

  # ---- T29: derived worst-verdict key across a split stage's instances ----
  make_state
  t27_write_art dva pass
  bash "$SELF" --stage DV --task-id DV0 --artifact .context/t27-dva.md > /dev/null
  if jq -e '.facts.verdicts.DV0 == "pass" and .facts.verdicts.DV == "pass"' \
    .context/state.json > /dev/null; then
    printf 'T29: single reporting instance: DV0 and derived DV both pass: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T29: DV0-only derivation wrong: FAIL\n' >&2
    exit 1
  fi

  t27_write_art dvb fail
  bash "$SELF" --stage DV --task-id DV1 --artifact .context/t27-dvb.md > /dev/null
  if jq -e '.facts.verdicts.DV0 == "pass" and .facts.verdicts.DV1 == "fail"
            and .facts.verdicts.DV == "fail"' .context/state.json > /dev/null; then
    printf 'T29: DV1 fail outranks DV0 pass in the derived DV key: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T29: worst-of-two derivation wrong: FAIL\n' >&2
    jq -c '.facts.verdicts' .context/state.json >&2
    exit 1
  fi

  t27_write_art dvc escalate
  bash "$SELF" --stage DV --task-id DV1 --artifact .context/t27-dvc.md > /dev/null
  if jq -e '.facts.verdicts.DV1 == "escalate" and .facts.verdicts.DV == "escalate"' \
    .context/state.json > /dev/null; then
    printf 'T29: DV1 escalate outranks fail and pass in the derived DV key: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T29: escalate-outranks derivation wrong: FAIL\n' >&2
    exit 1
  fi

  bash "$SELF" --task-create DV2 --metadata "$(_r9_meta '{"stage":"DV"}')" > /dev/null
  if jq -e '.facts.verdicts.DV == "escalate" and (.tasks.DV2.verdict // "") == ""' \
    .context/state.json > /dev/null; then
    printf 'T29: a verdict-less DV2 row is ignored by the derivation: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T29: verdict-less row must not affect the derived key: FAIL\n' >&2
    exit 1
  fi

  # A fail row is a PENDING status; re-patching it at the same verdict must still be a no-op.
  t27_write_art fail2 fail
  bash "$SELF" --stage DV --task-id V29 --artifact .context/t27-fail2.md > /dev/null
  cp .context/state.json .context/state.json.snap29
  bash "$SELF" --stage DV --task-id V29 --artifact .context/t27-fail2.md > /dev/null
  if diff -q .context/state.json .context/state.json.snap29 > /dev/null; then
    printf 'T29: re-patching a fail artifact twice is idempotent on the second run: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T29: re-patching a fail artifact was not idempotent: FAIL\n' >&2
    exit 1
  fi
  rm -f .context/state.json.snap29

  # ---- T30: --claim maps pending/blocked -> in_progress + claimed_at, refuses settled rows ----
  make_state
  bash "$SELF" --task-create DV0 --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer"}')" > /dev/null
  bash "$SELF" --claim DV0 || {
    printf 'T30: --claim returned non-zero\n' >&2
    exit 1
  }
  if jq -e '.tasks.DV0.status == "in_progress"
            and (.tasks.DV0.claimed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
    .context/state.json > /dev/null; then
    printf 'T30: pending -> in_progress + claimed_at stamp: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T30: claim stamp: FAIL\n' >&2
    jq -c '.tasks.DV0' .context/state.json >&2
    exit 1
  fi
  cp .context/state.json .context/state.json.snap30
  bash "$SELF" --claim DV0 > /dev/null
  if diff -q .context/state.json .context/state.json.snap30 > /dev/null; then
    printf 'T30: re-claim is byte-identical: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T30: re-claim must not change claimed_at: FAIL\n' >&2
    exit 1
  fi
  rm -f .context/state.json.snap30
  bash "$SELF" --task-status DV0 completed > /dev/null
  cp .context/state.json .context/state.json.snap30b
  st30_rc=0
  bash "$SELF" --claim DV0 > /dev/null 2>&1 || st30_rc=$?
  if [[ "$st30_rc" -eq 4 ]] && diff -q .context/state.json .context/state.json.snap30b > /dev/null; then
    printf 'T30: claim on a settled row refuses with exit 4, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T30: claim-on-settled guard (rc=%s): FAIL\n' "$st30_rc" >&2
    exit 1
  fi
  rm -f .context/state.json.snap30b
  st30c_rc=0
  bash "$SELF" --claim ET9 > /dev/null 2>&1 || st30c_rc=$?
  if [[ "$st30c_rc" -eq 1 ]]; then
    printf 'T30: claim on an unknown id exits 1: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T30: claim unknown-id guard (rc=%s): FAIL\n' "$st30c_rc" >&2
    exit 1
  fi

  # ---- T-stale-1: `stale` is in the writer's status vocabulary; an unknown one still refuses ----
  make_state
  bash "$SELF" --task-create DV0 --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer"}')" > /dev/null
  bash "$SELF" --task-status DV0 stale > /dev/null || {
    printf 'T-stale-1: --task-status stale returned non-zero\n' >&2
    exit 1
  }
  if jq -e '.tasks.DV0.status == "stale"' .context/state.json > /dev/null; then
    printf 'T-stale-1: --task-status <ID> stale accepted: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-stale-1: stale not written: FAIL\n' >&2
    jq -c '.tasks.DV0' .context/state.json >&2
    exit 1
  fi
  # `stalled` is the deliberate near-miss: widening the vocabulary must not turn the case arm
  # into a prefix match, or any typo beginning with a known status would write a ghost value.
  cp .context/state.json .context/state.json.snapS1
  ts1_rc=0
  bash "$SELF" --task-status DV0 stalled > /dev/null 2>&1 || ts1_rc=$?
  if [[ "$ts1_rc" -eq 2 ]] && diff -q .context/state.json .context/state.json.snapS1 > /dev/null; then
    printf 'T-stale-1: an unknown status still refuses with exit 2, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-stale-1: unknown-status guard (rc=%s): FAIL\n' "$ts1_rc" >&2
    exit 1
  fi
  rm -f .context/state.json.snapS1

  # ---- T-stale-2: --claim on a stale row refuses with exit 4, state byte-identical ----
  # Same refusal class as a settled row, so a dispatcher cannot resume a parked consumer by
  # claiming it; the message is asserted because callers match the `claim refused:` prefix.
  cp .context/state.json .context/state.json.snapS2
  ts2_rc=0
  ts2_err=$(bash "$SELF" --claim DV0 2>&1 > /dev/null) || ts2_rc=$?
  if [[ "$ts2_rc" -eq 4 ]] \
    && diff -q .context/state.json .context/state.json.snapS2 > /dev/null \
    && [[ "$ts2_err" == *"claim refused: tasks.DV0 is stale"* ]]; then
    printf 'T-stale-2: claim on a stale row refuses with exit 4, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-stale-2: claim-on-stale guard (rc=%s): FAIL\n%s\n' "$ts2_rc" "$ts2_err" >&2
    exit 1
  fi
  rm -f .context/state.json.snapS2

  # ---- T-stale-3: a stale task, and a pending task blocked by it, are absent from the ready set ----
  # The exclusion is emergent, not coded: the ready filter takes `pending` with every blocker
  # `completed`, so `stale` falls out of both halves. This case is the lock on that pair — it
  # fails the moment either list is widened to admit a parked row. QA0 is the live control.
  make_state
  bash "$SELF" --task-create DV0 --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer"}')" > /dev/null
  bash "$SELF" --task-create DR0 --metadata "$(_r9_meta '{"stage":"DR","agent":"corpflow:technical-lead"}')" > /dev/null
  bash "$SELF" --task-create QA0 --metadata "$(_r9_meta '{"stage":"QA","agent":"corpflow:qa-engineer"}')" > /dev/null
  bash "$SELF" --task-block DR0 --on DV0 > /dev/null
  bash "$SELF" --task-status DV0 stale > /dev/null
  ts3_digest="$(dirname "$SELF")/ledger-digest.sh"
  if [[ -f "$ts3_digest" ]]; then
    ts3_ready=$(bash "$ts3_digest" --state .context/state.json | sed -n 's/^ready: //p')
    if [[ "$ts3_ready" == "QA0" ]]; then
      printf 'T-stale-3: stale DV0 and its blocked dependent DR0 are both out of the ready set: ok\n'
      _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
    else
      printf 'T-stale-3: ready set is "%s", expected "QA0": FAIL\n' "$ts3_ready" >&2
      exit 1
    fi
  else
    printf 'T-stale-3: ready-set filter: SKIP (ledger-digest.sh unavailable)\n'
  fi

  # ---- T-reopen-1 (plan T4): --task-reopen guards, then pending + fix_round + gate_from_stage ----
  # Named `T-reopen-*` rather than the plan's bare T4/T5: this file's own T4-T6 are taken by
  # unrelated cases, and one id answering two assertions is worse than a longer name.
  #
  # The guard half comes FIRST and each rung is checked against a byte-identical ledger,
  # because the op's whole idempotence story is "a retried route is refused, not re-applied":
  # if a guard wrote anything before refusing, a second route would double the fix_round.
  make_state
  cat > .context/development-0.md << 'EOART'
---
handoff:
  stage: DV
  verdict: ok
  summary: "self-test artifact T-reopen-1"
  files_touched: [skills/worktask/scripts/a.sh]
  next_stage_focus: "DR reviews"
  refs: { dev: development.md#files-changed }
---
EOART
  bash "$SELF" --task-create DV0 --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer"}')" > /dev/null
  bash "$SELF" --task-create DC0 --metadata "$(_r9_meta '{"stage":"DC","agent":"corpflow:technical-writer"}')" > /dev/null
  bash "$SELF" --task-create QA0 --metadata "$(_r9_meta '{"stage":"QA","agent":"corpflow:qa-engineer"}')" > /dev/null
  bash "$SELF" --stage DV --artifact .context/development-0.md > /dev/null
  bash "$SELF" --task-status DC0 completed > /dev/null
  # QA0 is left `pending` on purpose: it is the not-completed target the guard below refuses,
  # and a source only has to EXIST, so it can still raise the second correction afterwards.

  cp .context/state.json .context/state.json.snapR1
  _tr1_guard() {  # <expected-rc> <label> <args...>
    local want="$1" label="$2"
    shift 2
    local rc=0
    printf 'finding\n' | bash "$SELF" "$@" > /dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne "$want" ]]; then
      printf 'T-reopen-1: %s expected rc %s, got %s: FAIL\n' "$label" "$want" "$rc" >&2
      exit 1
    fi
    if ! diff -q .context/state.json .context/state.json.snapR1 > /dev/null; then
      printf 'T-reopen-1: %s refused but wrote to state.json: FAIL\n' "$label" >&2
      exit 1
    fi
  }
  _tr1_guard 1 "unknown target" --task-reopen DR9 --from DC0
  _tr1_guard 2 "malformed target" --task-reopen notanid --from DC0
  _tr1_guard 2 "missing --from" --task-reopen DV0
  _tr1_guard 2 "malformed --from" --task-reopen DV0 --from nope
  _tr1_guard 4 "target is source" --task-reopen DV0 --from DV0
  _tr1_guard 1 "unknown source" --task-reopen DV0 --from DC9
  _tr1_guard 4 "target not completed" --task-reopen QA0 --from DC0
  printf 'T-reopen-1: every guard refuses with the ledger byte-identical: ok\n'
  _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  rm -f .context/state.json.snapR1

  # The finding is piped, never passed as an argument: the op reads stdin under
  # `--finding-file -`, which is what keeps stage-written text out of the process table and
  # out of the state-patch log.
  printf 'the --foo option does not exist in the tree\n' \
    | bash "$SELF" --task-reopen DV0 --from DC0 --finding-file - > /dev/null || {
      printf 'T-reopen-1: --task-reopen returned non-zero\n' >&2
      exit 1
    }
  if jq -e '.tasks.DV0.status == "pending"
            and .tasks.DV0.metadata.fix_round == 1
            and .tasks.DV0.metadata.gate_from_stage == "DC"
            and .tasks.DV0.metadata.gate_blockers == ["the --foo option does not exist in the tree"]
            and .tasks.DV0.verdict == "ok"
            and (.tasks.DV0.artifact | endswith("development-0.md"))' \
    .context/state.json > /dev/null; then
    printf 'T-reopen-1: target pending, fix_round 1, gate stamped, artifact and verdict kept: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-reopen-1: re-open write: FAIL\n' >&2
    jq -c '.tasks.DV0' .context/state.json >&2
    exit 1
  fi

  # Re-running the same route is refused by the `completed` guard itself — the property that
  # makes a retried correction idempotent, so there is no second fix_round bump.
  cp .context/state.json .context/state.json.snapR1b
  tr1_rc=0
  printf 'same finding\n' | bash "$SELF" --task-reopen DV0 --from DC0 --finding-file - > /dev/null 2>&1 || tr1_rc=$?
  if [[ "$tr1_rc" -eq 4 ]] && diff -q .context/state.json .context/state.json.snapR1b > /dev/null; then
    printf 'T-reopen-1: a re-routed correction is refused, fix_round stays 1: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-reopen-1: re-route idempotence (rc=%s): FAIL\n' "$tr1_rc" >&2
    exit 1
  fi
  rm -f .context/state.json.snapR1b

  # A SECOND, distinct correction — the target completed again in between — is the only path
  # that bumps the round again, and it re-stamps the source that raised THIS one.
  bash "$SELF" --task-status DV0 completed > /dev/null
  printf 'the fix regressed case 7\n' \
    | bash "$SELF" --task-reopen DV0 --from QA0 --finding-file - > /dev/null
  if jq -e '.tasks.DV0.metadata.fix_round == 2
            and .tasks.DV0.metadata.gate_from_stage == "QA"
            and .tasks.DV0.metadata.gate_blockers == ["the fix regressed case 7"]' \
    .context/state.json > /dev/null; then
    printf 'T-reopen-1: a second correction bumps fix_round to 2 and re-stamps the source: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-reopen-1: second-round bump: FAIL\n' >&2
    jq -c '.tasks.DV0.metadata' .context/state.json >&2
    exit 1
  fi

  # An oversized or control-byte-carrying finding is refused whole (exit 2), never truncated:
  # R3 promises the finding renders byte-for-byte, and a clipped one still reads as verbatim.
  bash "$SELF" --task-status DV0 completed > /dev/null
  cp .context/state.json .context/state.json.snapR1c
  tr1b_rc=0
  head -c 2500 < /dev/zero | tr '\0' 'x' \
    | bash "$SELF" --task-reopen DV0 --from DC0 --finding-file - > /dev/null 2>&1 || tr1b_rc=$?
  tr1c_rc=0
  printf 'esc\033[2J here\n' \
    | bash "$SELF" --task-reopen DV0 --from DC0 --finding-file - > /dev/null 2>&1 || tr1c_rc=$?
  if [[ "$tr1b_rc" -eq 2 && "$tr1c_rc" -eq 2 ]] \
    && diff -q .context/state.json .context/state.json.snapR1c > /dev/null; then
    printf 'T-reopen-1: an oversized or control-byte finding exits 2, ledger byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-reopen-1: finding bounds (oversized rc=%s, control rc=%s): FAIL\n' "$tr1b_rc" "$tr1c_rc" >&2
    exit 1
  fi
  rm -f .context/state.json.snapR1c

  # ---- T-reopen-2 (plan T5): the D3 consumer set — transitive, completed-only, two exclusions ----
  # DV0 is the target. DR0 consumes it, QA0 consumes DR0 (transitive, so a direct-only walk
  # fails here), FN0 consumes QA0 (side-effect stage), DC0 is the SOURCE and also downstream,
  # ST0 is downstream but never completed, PL0 is completed but not downstream at all.
  make_state
  for tr2_id in DV0 DR0 QA0 FN0 DC0 ST0; do
    # Single-quoted around the splice, not \"-escaped: bash 3.2 misparses an escaped-quote
    # '{"a":"x","b":"y"}' word as a brace-expansion list and runs _r9_meta twice on halves.
    bash "$SELF" --task-create "$tr2_id" \
      --metadata "$(_r9_meta '{"stage":"'"${tr2_id%%[0-9]*}"'","agent":"corpflow:developer"}')" > /dev/null
  done
  bash "$SELF" --task-block DR0 --on DV0 > /dev/null
  bash "$SELF" --task-block DC0 --on DV0 > /dev/null
  bash "$SELF" --task-block QA0 --on DR0 > /dev/null
  bash "$SELF" --task-block FN0 --on QA0 > /dev/null
  bash "$SELF" --task-block ST0 --on QA0 > /dev/null
  cat > .context/developer-review-0.md << 'EOART'
---
handoff:
  stage: DR
  verdict: approve
  summary: "self-test review artifact"
  files_touched: [skills/worktask/scripts/a.sh]
  next_stage_focus: "QA verifies"
  refs: { dev: development-0.md#files-changed }
---
EOART
  bash "$SELF" --stage DR --artifact .context/developer-review-0.md > /dev/null
  bash "$SELF" --stage DV --artifact .context/development-0.md > /dev/null
  for tr2_id in QA0 FN0 DC0; do
    bash "$SELF" --task-status "$tr2_id" completed > /dev/null
  done
  printf 'the option the docs name does not exist\n' \
    | bash "$SELF" --task-reopen DV0 --from DC0 --finding-file - > /dev/null || {
      printf 'T-reopen-2: --task-reopen returned non-zero\n' >&2
      exit 1
    }
  if jq -e '.tasks.DR0.status == "stale" and .tasks.QA0.status == "stale"
            and .tasks.DC0.status == "completed"
            and .tasks.FN0.status == "completed"
            and .tasks.ST0.status == "pending"
            and .tasks.PL0.status == "completed"' .context/state.json > /dev/null; then
    printf 'T-reopen-2: transitive consumers stale; source, FN/RE, non-completed and unrelated rows untouched: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-reopen-2: consumer set: FAIL\n' >&2
    jq -c '.tasks | map_values(.status)' .context/state.json >&2
    exit 1
  fi
  # Parked, not reset: `stale` exists precisely to preserve what a replay would clear.
  if jq -e '.tasks.DR0.verdict == "approve"
            and (.tasks.DR0.artifact | endswith("developer-review-0.md"))
            and (.tasks.DR0 | has("rework_pending") | not)' .context/state.json > /dev/null; then
    printf 'T-reopen-2: a parked consumer keeps its verdict and artifact: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-reopen-2: parked consumer was reset: FAIL\n' >&2
    jq -c '.tasks.DR0' .context/state.json >&2
    exit 1
  fi

  # ---- T-settle-1 (plan T6): --task-settle-stale, cited vs uncited vs unknown ----
  # DR0 cites the file the target changed; QA0 cites something else. The change set comes from
  # the target's own artifact unless --changed (the test seam) substitutes it.
  _ts1_restale() {
    bash "$SELF" --task-status DR0 stale > /dev/null
    bash "$SELF" --task-status QA0 stale > /dev/null
  }
  bash "$SELF" --task-meta DR0 \
    --set '{"consumes":[{"from":"DV0","paths":["./skills/worktask/scripts/a.sh#files-changed"]}]}' > /dev/null
  bash "$SELF" --task-meta QA0 \
    --set '{"consumes":[{"from":"DV0","paths":["skills/worktask/scripts/b.sh:42"]}]}' > /dev/null
  _ts1_restale
  ts1_out=$(bash "$SELF" --task-settle-stale DV0) || {
    printf 'T-settle-1: --task-settle-stale returned non-zero\n' >&2
    exit 1
  }
  # The artifact lists skills/worktask/scripts/a.sh, so DR0's anchored citation matches after
  # normalisation and QA0's `:42` one does not.
  if jq -e '.settled == [{"task":"DR0","to":"pending","reason":"cited-file-changed"},
                         {"task":"QA0","to":"completed","reason":"no-cited-file-changed"}]' \
    <<< "$ts1_out" > /dev/null \
    && jq -e '.tasks.DR0.status == "pending" and .tasks.QA0.status == "completed"' \
      .context/state.json > /dev/null; then
    printf 'T-settle-1: a cited change re-verifies, an uncited one lets the result stand: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-settle-1: artifact-sourced settlement: FAIL\n%s\n' "$ts1_out" >&2
    jq -c '.tasks | map_values(.status)' .context/state.json >&2
    exit 1
  fi

  # The seam, and the .context/ exclusion that makes R5 work at all: the target rewrites its
  # own artifact on every completion, so a change set left empty BY that exclusion is a known
  # change set that touched nothing cited — not an unknown one.
  _ts1_restale
  ts1_ctx=$(bash "$SELF" --task-settle-stale DV0 --changed .context/development-0.md)
  if jq -e '[.settled[] | select(.to != "completed")] | length == 0' <<< "$ts1_ctx" > /dev/null \
    && jq -e '.tasks.DR0.status == "completed"' .context/state.json > /dev/null; then
    printf 'T-settle-1: a .context/-only change set settles every dependent completed: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-settle-1: .context/ exclusion: FAIL\n%s\n' "$ts1_ctx" >&2
    exit 1
  fi

  _ts1_restale
  ts1_seam=$(bash "$SELF" --task-settle-stale DV0 --changed "skills/worktask/scripts/b.sh,docs/x.md")
  if jq -e '.settled == [{"task":"DR0","to":"completed","reason":"no-cited-file-changed"},
                         {"task":"QA0","to":"pending","reason":"cited-file-changed"}]' \
    <<< "$ts1_seam" > /dev/null; then
    printf 'T-settle-1: --changed substitutes the change set whole: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-settle-1: --changed seam: FAIL\n%s\n' "$ts1_seam" >&2
    exit 1
  fi

  # Fail-safe direction, both halves. An unreadable change set and an empty cited set each
  # send the dependent back to pending: re-verifying costs a stage, trusting a result nothing
  # could check costs the correction.
  # The other half of D2's cited set: facts.files_read[] for that task's stage code, which is
  # how a stage that read a file without a declared consumes[] pair is still counted.
  _ts1_restale
  bash "$SELF" --task-meta QA0 --set '{"consumes":[]}' > /dev/null
  bash "$SELF" --files-read QA0 ./skills/worktask/scripts/a.sh > /dev/null
  ts1_fr=$(bash "$SELF" --task-settle-stale DV0 --changed "skills/worktask/scripts/a.sh")
  if jq -e '[.settled[] | select(.task == "QA0")]
            == [{"task":"QA0","to":"pending","reason":"cited-file-changed"}]' \
    <<< "$ts1_fr" > /dev/null; then
    printf 'T-settle-1: facts.files_read supplies the cited set when consumes[] is empty: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-settle-1: files_read cited source: FAIL\n%s\n' "$ts1_fr" >&2
    exit 1
  fi

  _ts1_restale
  ts1_safe=$(bash "$SELF" --task-settle-stale DV0 --changed "")
  if jq -e '[.settled[] | select(.to == "pending" and .reason == "change-set-unknown")] | length == 2' \
    <<< "$ts1_safe" > /dev/null \
    && jq -e '.tasks.DR0.status == "pending" and .tasks.QA0.status == "pending"' \
      .context/state.json > /dev/null; then
    printf 'T-settle-1: an empty change set fails safe to pending for every dependent: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-settle-1: fail-safe direction: FAIL\n%s\n' "$ts1_safe" >&2
    exit 1
  fi
  # ST0 declares no consumes[] and appears in no files_read row, so it cites nothing and
  # re-verifies even against a change set this call could read perfectly well.
  bash "$SELF" --task-status ST0 stale > /dev/null
  ts1_empty=$(bash "$SELF" --task-settle-stale DV0 --changed "skills/worktask/scripts/a.sh")
  if jq -e '.settled == [{"task":"ST0","to":"pending","reason":"cited-set-empty"}]' \
    <<< "$ts1_empty" > /dev/null; then
    printf 'T-settle-1: an empty cited set fails safe to pending: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-settle-1: empty cited set: FAIL\n%s\n' "$ts1_empty" >&2
    exit 1
  fi
  # An artifact that DECLARES files_touched and leaves it empty is the case the two readers
  # disagreed on: yq reports a sequence, the awk fallback cannot tell it from a missing key.
  # Both must call it `absent`, or the fail-safe direction would depend on whether the host
  # has yq installed — the settle op would complete every dependent on one host and re-verify
  # them on the other, from the same ledger and the same artifact.
  cp .context/development-0.md .context/development-0.md.bak
  cat > .context/development-0.md << 'EOART'
---
handoff:
  stage: DV
  verdict: ok
  summary: "target artifact with an empty files_touched"
  files_touched: []
  next_stage_focus: "DR re-reviews"
  refs: { dev: development-0.md#files-changed }
---
EOART
  _ts1_restale
  ts1_declared_empty=$(bash "$SELF" --task-settle-stale DV0)
  mv .context/development-0.md.bak .context/development-0.md
  if jq -e '[.settled[] | select(.to == "pending" and .reason == "change-set-unknown")] | length == 2' \
    <<< "$ts1_declared_empty" > /dev/null; then
    printf 'T-settle-1: a declared-but-empty files_touched reads absent on both readers: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-settle-1: empty files_touched: FAIL\n%s\n' "$ts1_declared_empty" >&2
    exit 1
  fi
  # Both dependents are pending again, so the next case starts from an unparked ledger.

  # A ledger with nothing parked settles nothing and says so, rather than failing.
  ts1_none=$(bash "$SELF" --task-settle-stale DV0 --changed "skills/worktask/scripts/a.sh")
  if [[ "$ts1_none" == '{"settled":[]}' ]]; then
    printf 'T-settle-1: no stale row settles to an empty list: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-settle-1: empty settle list: FAIL\n%s\n' "$ts1_none" >&2
    exit 1
  fi

  # ---- T31: --dispatch upserts facts.dispatched_agents by task_id, clamps 6-launched-newest ----
  make_state
  bash "$SELF" --task-create DV0 --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer","model":"opus"}')" > /dev/null
  bash "$SELF" --dispatch DV0 sess-dv0 launched || {
    printf 'T31: --dispatch returned non-zero\n' >&2
    exit 1
  }
  # metadata.model is PASSED EXPLICITLY here (developer -> opus, corpflow:developer's matrix
  # row) rather than relying on --task-create to fill it: sw-AR0-1 reversed the mechanically-
  # enforced auto-fill at the FN-gate sweep, so a caller that omits it now stays unset (this is
  # exactly what PL0's model-matrix.sh --resolve + hand-paste replaces). The dispatch row still
  # carries model_requested when the caller supplies the value (dv10's original assertion).
  if jq -e '.facts.dispatched_agents == [{"stage":"DV","task_id":"DV0","subagent_type":"corpflow:developer","agent_id":"sess-dv0","status":"launched","model_requested":"opus"}]' \
    .context/state.json > /dev/null; then
    printf 'T31: first dispatch appends the row: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T31: dispatch append: FAIL\n' >&2
    jq -c '.facts.dispatched_agents' .context/state.json >&2
    exit 1
  fi
  bash "$SELF" --dispatch DV0 sess-dv0 completed > /dev/null
  if jq -e '(.facts.dispatched_agents | length) == 1
            and .facts.dispatched_agents[0].status == "completed"
            and .facts.dispatched_agents[0].agent_id == "sess-dv0"' \
    .context/state.json > /dev/null; then
    printf 'T31: same agent_id updates status in place: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T31: same-agent update: FAIL\n' >&2
    exit 1
  fi
  bash "$SELF" --dispatch DV0 sess-dv0b launched > /dev/null
  if jq -e '(.facts.dispatched_agents | length) == 1
            and .facts.dispatched_agents[0].agent_id == "sess-dv0b"
            and .facts.dispatched_agents[0].status == "launched"' \
    .context/state.json > /dev/null; then
    printf 'T31: a different agent_id replaces the row at the tail: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T31: agent_id replacement: FAIL\n' >&2
    exit 1
  fi
  bash "$SELF" --dispatch DV0 /root/cf_dv0_1 launched > /dev/null
  if jq -e '(.facts.dispatched_agents | length) == 1
            and .facts.dispatched_agents[0].agent_id == "/root/cf_dv0_1"' \
    .context/state.json > /dev/null; then
    printf 'T31: a Codex canonical task name is a valid dispatch identifier: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T31: Codex canonical dispatch identifier: FAIL\n' >&2
    exit 1
  fi

  make_state
  for t31_i in 0 1 2 3 4 5 6; do
    bash "$SELF" --task-create "DV${t31_i}" --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer"}')" > /dev/null
    bash "$SELF" --dispatch "DV${t31_i}" "sess-dv${t31_i}" launched > /dev/null
  done
  if jq -e '(.facts.dispatched_agents | length) == 6
            and ([.facts.dispatched_agents[].task_id] == ["DV1","DV2","DV3","DV4","DV5","DV6"])' \
    .context/state.json > /dev/null; then
    printf 'T31: 7 distinct launched task ids clamp to the 6 newest: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T31: launched clamp: FAIL\n' >&2
    jq -c '.facts.dispatched_agents | map(.task_id)' .context/state.json >&2
    exit 1
  fi

  st31a_rc=0
  bash "$SELF" --dispatch DV0 sess-x bogus > /dev/null 2>&1 || st31a_rc=$?
  if [[ "$st31a_rc" -eq 2 ]]; then
    printf 'T31: an invalid dispatch status exits 2: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T31: bad-status guard (rc=%s): FAIL\n' "$st31a_rc" >&2
    exit 1
  fi

  bash "$SELF" --task-create QA0 --metadata "$(_r9_meta)" > /dev/null
  st31b_rc=0
  bash "$SELF" --dispatch QA0 sess-qa0 launched > /dev/null 2>&1 || st31b_rc=$?
  if [[ "$st31b_rc" -eq 2 ]]; then
    printf 'T31: a row without metadata.agent exits 2: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T31: missing-metadata.agent guard (rc=%s): FAIL\n' "$st31b_rc" >&2
    exit 1
  fi

  st31c_rc=0
  bash "$SELF" --dispatch ET9 sess-x launched > /dev/null 2>&1 || st31c_rc=$?
  if [[ "$st31c_rc" -eq 1 ]]; then
    printf 'T31: dispatch on an unknown id exits 1: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T31: dispatch unknown-id guard (rc=%s): FAIL\n' "$st31c_rc" >&2
    exit 1
  fi

  # ---- T32: --files-read upserts facts.files_read, clamps to newest 30, rejects bad paths ----
  make_state
  bash "$SELF" --task-create DR0 --metadata "$(_r9_meta '{"stage":"DR","agent":"corpflow:technical-lead"}')"
  bash "$SELF" --files-read DR0 a.sh b.sh || {
    printf 'T32: --files-read returned non-zero\n' >&2
    exit 1
  }
  bash "$SELF" --files-read DR0 b.sh c.sh > /dev/null
  if jq -e '(.facts.files_read | length) == 3
            and ([.facts.files_read[].path] == ["a.sh","b.sh","c.sh"])
            and (([.facts.files_read[].stage] | unique) == ["DR"])' \
    .context/state.json > /dev/null; then
    printf 'T32: an overlapping path collapses to one entry at the newest position, stage from id: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T32: files-read overlap/positioning: FAIL\n' >&2
    jq -c '.facts.files_read' .context/state.json >&2
    exit 1
  fi

  make_state
  bash "$SELF" --task-create DR1 --metadata "$(_r9_meta '{"stage":"DR","agent":"corpflow:technical-lead"}')" > /dev/null
  t32_paths=()
  for t32_i in $(seq 1 31); do t32_paths+=("file${t32_i}.sh"); done
  bash "$SELF" --files-read DR1 "${t32_paths[@]}" > /dev/null || {
    printf 'T32: 31-path --files-read returned non-zero\n' >&2
    exit 1
  }
  if jq -e '(.facts.files_read | length) == 30
            and (.facts.files_read[0].path == "file2.sh")
            and (.facts.files_read[-1].path == "file31.sh")' \
    .context/state.json > /dev/null; then
    printf 'T32: 31 paths in one call clamp to the last 30: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T32: files-read 30-clamp: FAIL\n' >&2
    jq -c '.facts.files_read | map(.path)' .context/state.json >&2
    exit 1
  fi

  cp .context/state.json .context/state.json.snap32
  st32_rc=0
  bash "$SELF" --files-read DR1 "$(printf 'bad\tpath.sh')" > /dev/null 2>&1 || st32_rc=$?
  if [[ "$st32_rc" -eq 2 ]] && diff -q .context/state.json .context/state.json.snap32 > /dev/null; then
    printf 'T32: a path containing a TAB exits 2, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T32: bad-path guard (rc=%s): FAIL\n' "$st32_rc" >&2
    exit 1
  fi
  rm -f .context/state.json.snap32

  # ---- T33: --facts branch is stored at facts.branch, last writer wins; non-string is fatal ----
  make_state
  bash "$SELF" --facts '{"branch":"feature/x"}' || {
    printf 'T33: branch --facts returned non-zero\n' >&2
    exit 1
  }
  if jq -e '.facts.branch == "feature/x"' .context/state.json > /dev/null; then
    printf 'T33: a branch-only payload is stored: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T33: branch storage: FAIL\n' >&2
    exit 1
  fi
  cp .context/state.json .context/state.json.snap33
  st33_rc=0
  bash "$SELF" --facts '{"branch": 5}' > /dev/null 2>&1 || st33_rc=$?
  if [[ "$st33_rc" -eq 2 ]] && diff -q .context/state.json .context/state.json.snap33 > /dev/null; then
    printf 'T33: a non-string branch is a fatal whole-payload refusal, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T33: non-string-branch guard (rc=%s): FAIL\n' "$st33_rc" >&2
    exit 1
  fi
  rm -f .context/state.json.snap33

  # ---- T34: task-create key gate — bare non-PL/IR refused, PL0/IR0 exempt on a fresh ledger ----
  make_state
  cp .context/state.json .context/state.json.snap34
  st34_rc=0
  bash "$SELF" --task-create DV0 > /dev/null 2>&1 || st34_rc=$?
  if [[ "$st34_rc" -eq 2 ]] && diff -q .context/state.json .context/state.json.snap34 > /dev/null; then
    printf 'T34: a bare non-PL/IR task-create is refused, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T34: bare task-create guard (rc=%s): FAIL\n' "$st34_rc" >&2
    exit 1
  fi
  rm -f .context/state.json.snap34

  jq -n '{version:2, worktask_id:"selftest", plan_file:".context/planning-0.md",
      platform:"all", run_index:0, tasks:{},
      facts:{files_modified:[],tests_added:[],decisions:[],open_questions:[],verdicts:{}},
      handoffs:{}}' > .context/state.json
  bash "$SELF" --task-create PL0 > /dev/null \
    && bash "$SELF" --task-create IR0 > /dev/null \
    || {
      printf 'T34: bare PL0/IR0 create on a fresh ledger returned non-zero\n' >&2
      exit 1
    }
  if jq -e '.tasks.PL0.metadata == {} and .tasks.IR0.metadata == {}' .context/state.json > /dev/null; then
    printf 'T34: bare PL0/IR0 on a fresh ledger accepted with empty metadata: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T34: bare PL0/IR0 metadata: FAIL\n' >&2
    exit 1
  fi

  # ---- T-ack: --ack appends exactly one message_ack audit row; every refusal adds none ----
  make_state
  bash "$SELF" --task-create DV0 --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer"}')" > /dev/null
  rm -f .context/logs/audit.jsonl
  cp .context/state.json .context/state.json.snapack
  _tack_rows() {
    if [[ -f .context/logs/audit.jsonl ]]; then
      jq -s '[.[] | select(.action == "message_ack")] | length' .context/logs/audit.jsonl
    else
      printf '0'
    fi
  }
  bash "$SELF" --ack DV0 DV0-m1 || {
    printf 'T-ack: --ack returned non-zero\n' >&2
    exit 1
  }
  if [[ "$(_tack_rows)" -eq 1 ]] \
    && jq -s -e '[.[] | select(.action == "message_ack")][0]
          | .task_id == "DV0" and .subject == "DV0" and .result == "ok"
            and .metadata.msg_id == "DV0-m1"' .context/logs/audit.jsonl > /dev/null \
    && diff -q .context/state.json .context/state.json.snapack > /dev/null; then
    printf 'T-ack: one message_ack row carries the msg_id, state byte-unchanged: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-ack: ack row or state: FAIL\n' >&2
    exit 1
  fi

  tack_rc=0
  bash "$SELF" --ack ET9 x > /dev/null 2>&1 || tack_rc=$?
  if [[ "$tack_rc" -eq 1 && "$(_tack_rows)" -eq 1 ]]; then
    printf 'T-ack: an unknown id exits 1 with no row: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-ack: unknown-id guard (rc=%s): FAIL\n' "$tack_rc" >&2
    exit 1
  fi

  tack_rc=0
  tack_rc3=0
  bash "$SELF" --ack DV0 > /dev/null 2>&1 || tack_rc=$?
  bash "$SELF" --ack DV0 a b > /dev/null 2>&1 || tack_rc3=$?
  if [[ "$tack_rc" -eq 2 && "$tack_rc3" -eq 2 && "$(_tack_rows)" -eq 1 ]]; then
    printf 'T-ack: one or three args exit 2 with no row: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-ack: arg-count guard (rc=%s/%s): FAIL\n' "$tack_rc" "$tack_rc3" >&2
    exit 1
  fi

  tack_rc=0
  bash "$SELF" --ack DV0 "$(printf 'DV0\tm1')" > /dev/null 2>&1 || tack_rc=$?
  if [[ "$tack_rc" -eq 2 && "$(_tack_rows)" -eq 1 ]] \
    && diff -q .context/state.json .context/state.json.snapack > /dev/null; then
    printf 'T-ack: a msg_id containing a TAB exits 2 with no row: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-ack: msg_id grammar guard (rc=%s): FAIL\n' "$tack_rc" >&2
    exit 1
  fi

  # Zero args reach the task-id guard before the argc check; either way it is exit 2.
  tack_rc=0
  bash "$SELF" --ack > /dev/null 2>&1 || tack_rc=$?
  if [[ "$tack_rc" -eq 2 && "$(_tack_rows)" -eq 1 ]]; then
    printf 'T-ack: zero args exit 2 with no row: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-ack: zero-arg guard (rc=%s): FAIL\n' "$tack_rc" >&2
    exit 1
  fi

  tack_rc=0
  bash "$SELF" --state .context/absent.json --ack DV0 DV0-m1 > /dev/null 2>&1 || tack_rc=$?
  if [[ "$tack_rc" -eq 1 && "$(_tack_rows)" -eq 1 && ! -e .context/absent.json ]]; then
    printf 'T-ack: a missing ledger exits 1 with no row: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-ack: missing-ledger guard (rc=%s): FAIL\n' "$tack_rc" >&2
    exit 1
  fi

  # corpflow_audit_row refuses a symlinked log, so the row is lost; the op must say so.
  mv .context/logs/audit.jsonl .context/audit.real.jsonl
  ln -s ../audit.real.jsonl .context/logs/audit.jsonl
  tack_rc=0
  bash "$SELF" --ack DV0 DV0-m2 > /dev/null 2>&1 || tack_rc=$?
  rm -f .context/logs/audit.jsonl
  mv .context/audit.real.jsonl .context/logs/audit.jsonl
  if [[ "$tack_rc" -eq 1 && "$(_tack_rows)" -eq 1 ]] \
    && diff -q .context/state.json .context/state.json.snapack > /dev/null; then
    printf 'T-ack: a lost audit row (symlinked log) exits 1: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-ack: lost-row guard (rc=%s): FAIL\n' "$tack_rc" >&2
    exit 1
  fi
  rm -f .context/state.json.snapack

  # ---- T35: tests_executed mirror; a replayed round is filed under rework_runs[] ----
  if command -v yq > /dev/null 2>&1; then
    make_state
    printf '[]\n' > agents-gone.json
    bash "$SELF" --task-create DV0 --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer"}')" \
      > /dev/null
    _t35_art() {  # <count> [summary-count]
      printf -- '---\nhandoff:\n  stage: DV\n  verdict: ok\n  summary: "round with %s"\n  tests_executed:\n    - { runner: bats, count: %s, summary_line: "1..%s" }\n---\n' \
        "${2:-$1}" "$1" "$1" > .context/development-0.md
    }
    _t35_art 12
    bash "$SELF" --stage DV --artifact .context/development-0.md > /dev/null 2>&1 || true
    bash "$SELF" --task-replay DV0 --agents-json agents-gone.json > /dev/null 2>&1 || true
    _t35_art 14
    bash "$SELF" --stage DV --artifact .context/development-0.md > /dev/null 2>&1 || true
    cp .context/state.json .context/state.json.snap35
    bash "$SELF" --stage DV --artifact .context/development-0.md > /dev/null 2>&1 || true
    if jq -e '.tasks.DV0.tests_executed == [{runner:"bats",count:14,summary_line:"1..14"}]
              and .tasks.DV0.rework_runs == [{round:1,tests_executed:[{runner:"bats",count:12,summary_line:"1..12"}]}]
              and (.tasks.DV0 | has("rework_pending") | not)' .context/state.json > /dev/null \
      && diff -q .context/state.json .context/state.json.snap35 > /dev/null; then
      printf 'T35: replayed round filed once under rework_runs, re-merge is a no-op: ok\n'
      _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
    else
      printf 'T35: rework_runs append: FAIL\n' >&2
      jq '.tasks.DV0' .context/state.json >&2
      exit 1
    fi
    rm -f .context/state.json.snap35
    # Same artifact, verdict and summary with only the list changed: the empty gate_from_stage
    # field must not hide the difference and turn the merge into a no-op.
    _t35_art 16 14
    bash "$SELF" --stage DV --artifact .context/development-0.md > /dev/null 2>&1 || true
    if jq -e '.tasks.DV0.tests_executed == [{runner:"bats",count:16,summary_line:"1..16"}]
              and (.tasks.DV0.rework_runs | length) == 1' .context/state.json > /dev/null; then
      printf 'T35: a changed list under the same artifact and verdict re-merges: ok\n'
      _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
    else
      printf 'T35: changed-list re-merge: FAIL\n' >&2
      jq '.tasks.DV0' .context/state.json >&2
      exit 1
    fi
  else
    printf 'T35: rework_runs append: SKIP (yq unavailable)\n'
  fi

  # ---- T-stream: a DV per-stream artifact name is canonical; a malformed slug still warns ----
  make_state
  cp .context/development-0.md .context/development-0-swift-app.md 2> /dev/null \
    || printf -- '---\nhandoff:\n  stage: DV\n  verdict: ok\n---\n' > .context/development-0-swift-app.md
  cp .context/development-0-swift-app.md .context/development-0-Swift_App.md
  tstream_out=$(bash "$SELF" --stage DV --artifact .context/development-0-swift-app.md 2>&1 || true)
  tstream_bad=$(bash "$SELF" --stage DV --artifact .context/development-0-Swift_App.md 2>&1 || true)
  rm -f .context/development-0-swift-app.md .context/development-0-Swift_App.md
  if [[ "$tstream_out" != *"is not the canonical name"* && "$tstream_bad" == *"is not the canonical name"* ]]; then
    printf 'T-stream: DV -<stream> suffix is canonical, a malformed slug warns: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-stream: DV stream-suffix canonical check: FAIL\n%s\n%s\n' "$tstream_out" "$tstream_bad" >&2
    exit 1
  fi

  # ---- T-batch: batched --task-create lands in one merge, --digest reads it back, and one
  # bad row refuses the batch byte-identically with no audit row appended ----
  make_state
  rm -f .context/logs/audit.jsonl
  tbatch_out=$(bash "$SELF" --task-create DV0 --metadata "$(_r9_meta '{"agent":"corpflow:developer"}')" \
    --task-create DR0 --metadata "$(_r9_meta)" --digest \
    --audit-row '{"action":"seed","result":"ok","subject":"plan"}' 2> /dev/null || true)
  cp .context/state.json .context/state.json.snapb
  bash "$SELF" --task-create QA0 --metadata "$(_r9_meta)" --task-create DC0 \
    --audit-row '{"action":"seed","result":"ok","subject":"plan"}' > /dev/null 2>&1 && tbatch_rc=0 || tbatch_rc=$?
  if [[ "$tbatch_out" == $'state-patch ok\nDV0 pending agent=corpflow:developer\nDR0 pending\naudit +1' ]] \
    && [[ "$tbatch_rc" -eq 2 ]] && diff -q .context/state.json .context/state.json.snapb > /dev/null \
    && [[ "$(wc -l < .context/logs/audit.jsonl | tr -d ' ')" == "1" ]]; then
    printf 'T-batch: batched create + digest + audit-row, bad row refuses whole batch: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-batch: FAIL (rc=%s)\n%s\n' "$tbatch_rc" "$tbatch_out" >&2
    exit 1
  fi
  rm -f .context/state.json.snapb

  make_state
  local tprobe_out
  tprobe_out=$(trap - ERR; LOG_FILE=.context/logs/probe.log \
    ATOMIC_APPLY_PROBE='error("forced probe failure")' \
    atomic_apply .context/state.json '.' 2>&1) || {
    printf 'T-probe: a failed observer changed the merge result: FAIL (%s)\n' "$tprobe_out" >&2
    exit 1
  }
  if [[ "$tprobe_out" == 'warn: atomic apply probe failed; merge unaffected' ]] \
    && [[ "$tprobe_out" != *class* ]]; then
    printf 'T-probe: failed observer warns once without naming a probe user: ok\n'
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    printf 'T-probe: generic warning: FAIL (%s)\n' "$tprobe_out" >&2
    exit 1
  fi

  printf 'self-test: ALL PASS (%d passed, 0 failed)\n' "$_SELFTEST_PASSED"
  exit 0
}
