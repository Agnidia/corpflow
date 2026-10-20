#!/usr/bin/env bash
# model-switch-gate self-test body — sourced by hooks/model-switch-gate.sh under
# --self-test only, never on the hook dispatch path. Sourced, not executed, so it
# sees every helper the caller already defined; it owns the exit for this invocation.

  _tmp=$(mktemp -d)
  trap 'rm -rf "$_tmp"' EXIT
  _fail=0
  _st_cases=0

  # Ledger with one in_progress stage pinned to opus.
  _mkledger() {
    mkdir -p "$1"
    printf '%s' '{"version":1,"worktask_id":"wid-ms","tasks":{"DV0":{"status":"in_progress"}},"facts":{"dispatched_agents":[{"stage":"DV","task_id":"DV0","subagent_type":"stage-agent","agent_id":"agt_dv","model_requested":"opus","status":"launched"}]}}' > "$1/state.json"
  }

  # --- Block: pinned opus, destination sonnet, trigger present but unrecognized ---
  _bctx="$_tmp/block/.context"
  _mkledger "$_bctx"
  _bout=$(run_gate '{"session_id":"s1","agent_id":"agt_dv","to_model":"sonnet","reason":"quantum_flux"}' "$_bctx")
  printf '%s' "$_bout" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null 2>&1 \
    || { echo "model-switch-gate: self-test FAIL (block: no block decision)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  printf '%s' "$_bout" | jq -e '
    .hookSpecificOutput.hookEventName == "PreModelSwitch"
    and (.hookSpecificOutput.permissionDecisionReason | test("DV0"))
    and (.hookSpecificOutput.permissionDecisionReason | test("opus"))
    and (.hookSpecificOutput.permissionDecisionReason | test("sonnet"))
  ' > /dev/null 2>&1 \
    || { echo "model-switch-gate: self-test FAIL (block: permissionDecisionReason)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  tail -n 1 "$_bctx/logs/audit.jsonl" | jq -e '
    .action == "model_switch_blocked" and .result == "block"
    and .metadata.task_id == "DV0" and .metadata.pinned == "opus"
  ' > /dev/null 2>&1 \
    || { echo "model-switch-gate: self-test FAIL (block: audit row)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # --- No trigger field observed: the trigger axis annotates, it does not deny ---
  _uctx="$_tmp/trigger-unobserved/.context"
  _mkledger "$_uctx"
  _uout=$(run_gate '{"session_id":"s5","agent_id":"agt_dv","to_model":"sonnet"}' "$_uctx")
  printf '%s' "$_uout" | jq -e 'has("systemMessage")' > /dev/null 2>&1 \
    || { echo "model-switch-gate: self-test FAIL (trigger-unobserved: expected annotate)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  tail -n 1 "$_uctx/logs/audit.jsonl" | jq -e '
    .action == "model_switch_annotated" and .metadata.kind == "trigger_unobserved"
  ' > /dev/null 2>&1 \
    || { echo "model-switch-gate: self-test FAIL (trigger-unobserved: audit row)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # --- Same family, different spelling: alias vs resolved id is not a re-tier ---
  _sctx="$_tmp/samefamily/.context"
  _mkledger "$_sctx"
  _sout=$(run_gate '{"session_id":"s2","agent_id":"agt_dv","to_model":"claude-opus-5-5"}' "$_sctx")
  [ -z "$_sout" ] || { echo "model-switch-gate: self-test FAIL (same-family: unexpected output)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  [ ! -f "$_sctx/logs/audit.jsonl" ] || { echo "model-switch-gate: self-test FAIL (same-family: wrote a row)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # --- Total schema drift: every guessed field absent -> annotate, never block ---
  _dctx="$_tmp/drift/.context"
  _mkledger "$_dctx"
  _dout=$(run_gate '{"session_id":"s3","agent_id":"agt_dv"}' "$_dctx")
  printf '%s' "$_dout" | jq -e 'has("systemMessage")' > /dev/null 2>&1 \
    || { echo "model-switch-gate: self-test FAIL (drift: expected annotate)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # --- No worktask ledger: zero side effects ---
  _nctx="$_tmp/noworktask/.context"
  mkdir -p "$_nctx"
  _nout=$(run_gate '{"session_id":"s4","to_model":"sonnet"}' "$_nctx")
  [ -z "$_nout" ] || { echo "model-switch-gate: self-test FAIL (no-worktask: unexpected output)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  [ ! -d "$_nctx/logs" ] || { echo "model-switch-gate: self-test FAIL (no-worktask: created logs/)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  if [ "$_fail" -ne 0 ]; then
    echo "model-switch-gate: self-test FAIL ($(($_st_cases - _fail)) passed, $_fail failed)"
    exit 1
  fi
  echo "model-switch-gate: self-test OK ($_st_cases passed, 0 failed)"
  exit 0
