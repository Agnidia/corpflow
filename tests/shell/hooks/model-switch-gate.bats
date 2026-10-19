#!/usr/bin/env bats
# Tests for hooks/model-switch-gate.sh — the PreModelSwitch gate refusing a
# mid-worktask re-tier away from the model a stage was dispatched with.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="hooks/model-switch-gate.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context"
}

# Ledger: DV0 in progress, dispatched with model_requested "opus".
_ledger() {
  printf '%s' '{"version":1,"worktask_id":"wt-ms",
    "tasks":{"DV0":{"status":"in_progress"}},
    "facts":{"dispatched_agents":[
      {"stage":"DV","task_id":"DV0","subagent_type":"corpflow:developer",
       "agent_id":"agt_dv","model_requested":"opus","status":"launched"}]}}' \
    > "$WD/.context/state.json"
}

# switch_payload [key=value]... -> a PreModelSwitch payload on stdout.
# Built inline rather than fixture-filed: the assumed-field combinations this
# gate has to survive are cheaper to compose than to enumerate on disk.
switch_payload() {
  local json='{"session_id":"sess_t","agent_id":"agt_dv"}' kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    json="$(printf '%s' "$json" | jq -c --arg k "$k" --arg v "$v" '.[$k] = $v')" \
      || fail "switch_payload: jq failed building $kv"
  done
  printf '%s' "$json"
}

# Every invocation pins cwd and the project dir into the scratch tree: without
# --cwd the gate's git arm would resolve to this repo's own .context.
_run_gate() {
  run_script_env --cwd "$WD" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$1" "$SCRIPT"
}

# --- silent-pass rows ---------------------------------------------------------

@test "row 1: no worktask ledger -> silent pass, zero side effects" {
  _run_gate "$(switch_payload to_model=sonnet)"
  assert_success
  [ -z "$output" ]
  [ ! -d "$WD/.context/logs" ]
}

@test "row 1: no single in_progress stage -> silent pass" {
  printf '%s' '{"tasks":{"DV0":{"status":"completed"}}}' > "$WD/.context/state.json"
  _run_gate "$(switch_payload to_model=sonnet)"
  assert_success
  [ -z "$output" ]
}

@test "row 1: an in_progress stage with no matching dispatch row -> silent pass" {
  printf '%s' '{"tasks":{"DV0":{"status":"in_progress"}},"facts":{"dispatched_agents":[]}}' \
    > "$WD/.context/state.json"
  _run_gate "$(switch_payload to_model=sonnet)"
  assert_success
  [ -z "$output" ]
}

# --- row 2: destination unresolvable ------------------------------------------

@test "row 2: pin present but no recognizable destination field -> annotate" {
  _ledger
  _run_gate "$(switch_payload)"
  assert_success
  echo "$output" | jq -e '
    has("systemMessage") and (has("hookSpecificOutput") | not)
  '
  assert_audit_row model_switch_annotated --meta kind=destination_unresolved
}

# --- row 3: same family -------------------------------------------------------

@test "row 3: ANTI-VACUITY — alias vs resolved id is not a re-tier (silent pass)" {
  # A gate that compared raw strings would call this a mismatch and block a
  # switch that changes nothing.
  _ledger
  _run_gate "$(switch_payload to_model=claude-opus-5-5)"
  assert_success
  [ -z "$output" ]
  [ ! -f "$WD/.context/logs/audit.jsonl" ]
}

# --- row 4: fallback ----------------------------------------------------------

@test "row 4: a 404/fallback trigger annotates instead of blocking" {
  _ledger
  _run_gate "$(switch_payload to_model=sonnet reason=model_404_fallback)"
  assert_success
  echo "$output" | jq -e 'has("systemMessage")'
  assert_audit_row model_switch_annotated --meta kind=fallback --meta requested=sonnet
}

@test "row 4: the fallback annotation names model_resolved as the cost-attribution source" {
  _ledger
  _run_gate "$(switch_payload to_model=sonnet trigger=fallback)"
  echo "$output" | jq -e '.systemMessage | test("model_resolved")'
}

# --- row 5: explicit user action ----------------------------------------------

@test "row 5: an explicit user switch asks for confirmation rather than refusing" {
  _ledger
  _run_gate "$(switch_payload to_model=haiku reason=user_requested)"
  assert_success
  echo "$output" | jq -e '
    .hookSpecificOutput.permissionDecision == "ask" and .hookSpecificOutput.permissionDecision == "ask"
  '
  assert_audit_row model_switch_confirm_requested --meta kind=user
}

# --- row 6: block -------------------------------------------------------------

@test "row 6a: no trigger field at all + family change -> annotate, never deny" {
  # The trigger field names are assumed, so their absence is missing evidence.
  # Denying here would refuse every switch under a payload schema nobody has seen.
  _ledger
  _run_gate "$(switch_payload to_model=sonnet)"
  assert_success
  echo "$output" | jq -e '
    has("systemMessage") and (has("hookSpecificOutput") | not)
  '
  assert_audit_row model_switch_annotated --meta kind=trigger_unobserved --meta requested=sonnet
  assert_audit_row model_switch_blocked --absent
}

@test "row 6b: a present-but-unrecognized trigger + family change -> block, exit still 0" {
  _ledger
  _run_gate "$(switch_payload to_model=sonnet reason=quantum_flux)"
  assert_success   # the block travels in stdout JSON; a non-zero exit would wedge the session
  echo "$output" | jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and .hookSpecificOutput.permissionDecision == "deny"
  '
  assert_audit_row model_switch_blocked --result block --subject DV0 --meta pinned=opus --meta requested=sonnet
}

@test "row 6: ANTI-VACUITY — the block message carries the fixture's real values" {
  # A static reason string would pass a shape-only assertion while telling the
  # operator nothing about which stage is pinned to what.
  printf '%s' '{"tasks":{"QA7":{"status":"in_progress"}},
    "facts":{"dispatched_agents":[
      {"stage":"QA","task_id":"QA7","subagent_type":"corpflow:qa-engineer",
       "agent_id":"agt_dv","model_requested":"haiku","status":"launched"}]}}' \
    > "$WD/.context/state.json"
  _run_gate "$(switch_payload to_model=fable reason=quantum_flux)"
  echo "$output" | jq -e '
    (.hookSpecificOutput.permissionDecisionReason | test("QA7"))
    and (.hookSpecificOutput.permissionDecisionReason | test("haiku"))
    and (.hookSpecificOutput.permissionDecisionReason | test("fable"))
  '
  assert_audit_row model_switch_blocked --meta stage=QA --meta task_id=QA7 --meta pinned=haiku
}

# --- alternate assumed field names --------------------------------------------

@test "drift tolerance: each assumed destination spelling resolves identically" {
  # Carries an unrecognized trigger so every arm reaches row 6b: this asserts the
  # DESTINATION axis, whose deny path is retained.
  local field
  for field in to_model toModel requested_model requestedModel new_model newModel; do
    rm -f "$WD/.context/logs/audit.jsonl"
    _ledger
    _run_gate "$(switch_payload "$field=sonnet" reason=quantum_flux)"
    echo "$output" | jq -e --arg f "$field" '.hookSpecificOutput.permissionDecision == "deny"' \
      || fail "destination field '$field' did not resolve"
  done
}

# --- escape hatch -------------------------------------------------------------

@test "hatch: CORPFLOW_MODEL_SWITCH_GATE=off suppresses a block and notes itself once" {
  _ledger
  run_script_env --cwd "$WD" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$WD" \
    --env "CORPFLOW_MODEL_SWITCH_GATE=off" --stdin-string "$(switch_payload to_model=sonnet)" "$SCRIPT"
  assert_success
  [ -z "$output" ]
  assert_audit_row model_switch_gate_disabled --meta vector=CORPFLOW_MODEL_SWITCH_GATE
  # Second invocation must not re-note: the sentinel makes it once per .context/.
  run_script_env --cwd "$WD" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$WD" \
    --env "CORPFLOW_MODEL_SWITCH_GATE=off" --stdin-string "$(switch_payload to_model=sonnet)" "$SCRIPT"
  assert_audit_row model_switch_gate_disabled --count 1
}

# --- malformed payloads: the fail-open contract -------------------------------

@test "hatch: an unwritable logs/ dir still exits 0" {
  _ledger
  mkdir -p "$WD/.context/logs" && chmod 0555 "$WD/.context/logs"
  run_script_env --cwd "$WD" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$WD" \
    --env "CORPFLOW_MODEL_SWITCH_GATE=off" --stdin-string "$(switch_payload to_model=sonnet)" "$SCRIPT"
  chmod 0755 "$WD/.context/logs"
  assert_success
  [ -z "$output" ]
}

@test "malformed A: non-JSON stdin -> exit 0, no output, no audit row" {
  _ledger
  _run_gate 'not json at all {{{'
  assert_success
  [ -z "$output" ]
  assert_audit_row model_switch_blocked --absent
}

@test "malformed B: TOTAL schema drift can never reach a block" {
  # The fail-open contract, stated as a test: valid JSON, an otherwise-blocking
  # ledger, and not one field this gate guesses at. If a future edit lets this
  # reach `block`, a wrong payload guess would wedge every session that switches
  # models — which is why this assertion is `!= block`, not a shape check.
  _ledger
  _run_gate '{"session_id":"s","agent_id":"agt_dv","destinationModelIdentifier":"sonnet"}'
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision != "deny"'
  assert_audit_row model_switch_blocked --absent
}

@test "malformed C: empty stdin -> exit 0, no block" {
  _ledger
  _run_gate ''
  assert_success
  assert_audit_row model_switch_blocked --absent
}

@test "contract: --self-test passes (counted summary)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "self-test OK"
  assert_output --regexp 'model-switch-gate: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
}

@test "unresolved root exits 0, no block, no .context under cwd" {
  local cwd
  cwd="$(mk_tmpworkdir)"
  run_script_env --cwd "$cwd" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR --unset CONTEXT_DIR \
    --env "GIT_CEILING_DIRECTORIES=$cwd" \
    --stdin-string "$(switch_payload to_model=sonnet)" "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ -z "$output" ]
  [ ! -e "$cwd/.context" ]
}

@test "SR: every appender call guards subject as it guards task_id" {
  # An unguarded --subject would drop the whole evidence row under the appender's required-key
  # contract, and the invariant keeping _task_id non-empty lives in another file.
  run grep -c -- '--subject "$_task_id"' "$PLUGIN_ROOT/hooks/model-switch-gate.sh"
  assert_output "0"
}

@test "documented sources emit only supported model-switch output fields" {
  _ledger
  for source in command picker sdk; do
    _run_gate "$(switch_payload to_model=sonnet from_model=opus source=$source)"
    assert_success
    echo "$output" | jq -e '
      (keys == ["hookSpecificOutput"]) and
      (.hookSpecificOutput | keys == ["hookEventName", "permissionDecision", "permissionDecisionReason"]) and
      .hookSpecificOutput.permissionDecision == "ask" and
      (.hookSpecificOutput.permissionDecisionReason | length > 0)'
  done
  _run_gate "$(switch_payload)"
  echo "$output" | jq -e 'keys == ["systemMessage"]'
}
