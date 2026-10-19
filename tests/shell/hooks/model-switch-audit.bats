#!/usr/bin/env bats
# Tests for hooks/model-switch-audit.sh — the PostModelSwitch observer recording
# which model a pinned stage actually moved to.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="hooks/model-switch-audit.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context"
}

_ledger() {
  printf '%s' '{"version":1,"worktask_id":"wt-ms",
    "tasks":{"DV0":{"status":"in_progress"}},
    "facts":{"dispatched_agents":[
      {"stage":"DV","task_id":"DV0","subagent_type":"corpflow:developer",
       "agent_id":"agt_dv","model_requested":"opus","status":"launched"}]}}' \
    > "$WD/.context/state.json"
}

_run_audit() {
  run_script_env --cwd "$WD" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$1" "$SCRIPT"
}

@test "happy: a switch away from the pin records off_tier with both models" {
  _ledger
  _run_audit '{"session_id":"s1","agent_id":"agt_dv","from_model":"opus","to_model":"sonnet"}'
  assert_success
  assert_audit_row model_switched --subject DV0 \
    --meta pinned=opus --meta origin=opus --meta resolved=sonnet --meta off_tier=true
}

@test "happy: a switch back to the pinned model is recorded but not off_tier" {
  _ledger
  _run_audit '{"session_id":"s1","agent_id":"agt_dv","from_model":"sonnet","to_model":"opus"}'
  assert_audit_row model_switched --meta off_tier=false
}

@test "edge: no ledger -> no row and no logs directory created" {
  _run_audit '{"session_id":"s1","to_model":"sonnet"}'
  assert_success
  [ ! -d "$WD/.context/logs" ]
}

@test "edge: a switch outside any pinned stage still records, with empty pin fields" {
  printf '%s' '{"tasks":{"DV0":{"status":"completed"}}}' > "$WD/.context/state.json"
  _run_audit '{"session_id":"s1","from_model":"opus","to_model":"sonnet"}'
  assert_success
  # subject falls back to the literal "unknown": an empty --arg is truthy to jq's `//`,
  # so a `$stage // "unknown"` coalesce would write "" here.
  assert_audit_row model_switched --subject unknown --meta resolved=sonnet --meta off_tier=false
}

@test "edge: malformed payload exits 0 without wedging the switch" {
  _ledger
  _run_audit 'not json {{{'
  assert_success
}

@test "contract: --self-test passes (counted summary)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "self-test OK"
  assert_output --regexp 'model-switch-audit: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
}

@test "off_tier: alias vs resolved id is one family, not a re-tier" {
  _ledger
  _run_audit '{"session_id":"s1","agent_id":"agt_dv","from_model":"opus","to_model":"claude-opus-5-5"}'
  assert_audit_row model_switched --meta resolved=claude-opus-5-5 --meta off_tier=false
}

@test "dedupe_key: two switches in one session keep two rows after audit-dedup" {
  _ledger
  _run_audit '{"session_id":"s1","agent_id":"agt_dv","from_model":"opus","to_model":"sonnet"}'
  _run_audit '{"session_id":"s1","agent_id":"agt_dv","from_model":"sonnet","to_model":"opus"}'
  run bash "$PLUGIN_ROOT/skills/agent-coordination/scripts/audit-dedup.sh" "$WD/.context/logs/audit.jsonl"
  assert_success
  [ "$(printf '%s\n' "$output" | grep -c '"model_switched"')" -eq 2 ]
}

@test "unresolved root exits 0 and creates no .context under cwd" {
  local cwd
  cwd="$(mk_tmpworkdir)"
  run_script_env --cwd "$cwd" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR --unset CONTEXT_DIR \
    --env "GIT_CEILING_DIRECTORIES=$cwd" \
    --stdin-string '{"session_id":"s1","agent_id":"agt_dv","from_model":"opus","to_model":"sonnet"}' \
    "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ ! -e "$cwd/.context" ]
}
