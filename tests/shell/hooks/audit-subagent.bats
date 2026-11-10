#!/usr/bin/env bats
# Tests for hooks/audit-subagent.sh (DV0c) — SubagentStop → audit.jsonl writer
# emitting a `subagent_stopped` row with dedupe_key "<session>:<agent>:stop".
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="hooks/audit-subagent.sh"
PAYLOAD="${FIXTURES}/hooks/audit-subagent.payload.json"

setup() {
  WD="$(mk_tmpworkdir)"
  # The root ladder answers only a context holding a ledger.
  mkdir -p "$WD/.context"
  printf '%s' '{"version":2,"tasks":{}}' > "$WD/.context/state.json"
}

@test "happy: writes subagent_stopped row with duration + dedupe keys" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < "$PAYLOAD"
  assert_success
  run jq -e '
    .action == "subagent_stopped"
    and .subject == "corpflow:developer"
    and .metadata.duration_ms == 12345
    and .metadata.parent_agent_id == "agt_parent"
    and (.metadata.dedupe_key == "sess_fix:agt_dv:stop")
  ' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "edge: non-numeric duration_ms coerces to 0; absent ids fall back" {
  # A first-seen key records whatever its fields say; the stage is supplied only
  # so the row also exercises the env half of the identity ladder.
  run env CLAUDE_PROJECT_DIR="$WD" CLAUDE_TASK_METADATA_STAGE=DV \
    bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"agent_type":"corpflow:y","duration_ms":"oops"}'
  assert_success
  run jq -e '
    .metadata.duration_ms == 0
    and (.metadata.dedupe_key == "nosession:noagent:stop")
    and .metadata.parent_agent_id == "none"
  ' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "effort: the payload tier is recorded" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < "$PAYLOAD"
  assert_success
  run jq -e '.metadata.effort == "high"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "effort: a payload without effort records unknown, never \$CLAUDE_EFFORT" {
  # A haiku subagent runs with no effort: its SubagentStop payload omits .effort while the
  # env var still holds the requested tier.
  run env CLAUDE_EFFORT=high CLAUDE_PROJECT_DIR="$WD" \
    bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"agent_type":"corpflow:technical-writer","agent_id":"a9","session_id":"s9"}'
  assert_success
  run jq -e '.metadata.effort == "unknown"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "happy: stage is stamped from CLAUDE_TASK_METADATA_STAGE" {
  run env CLAUDE_PROJECT_DIR="$WD" CLAUDE_TASK_METADATA_STAGE=DV \
    bash "$PLUGIN_ROOT/$SCRIPT" < "$PAYLOAD"
  assert_success
  run jq -e '.metadata.stage == "DV" and .metadata.agent_id == "agt_dv"' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "edge: empty agent_type falls back to CLAUDE_SUBAGENT_TYPE, qualifier intact" {
  # The runtime sends "" (not null) for plugin agents, so `// "unknown"` alone
  # left the row anonymous and the report could not name who ran.
  run env CLAUDE_PROJECT_DIR="$WD" CLAUDE_SUBAGENT_TYPE="apple-developer:ios-developer" \
    bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"agent_type":"","agent_id":"a1","session_id":"s1","duration_ms":7}'
  assert_success
  run jq -e '.subject == "apple-developer:ios-developer"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "edge: empty agent_type with no env fallback yields unknown, not empty" {
  # BSD env stops option parsing at the first NAME=VALUE operand, so -u must precede
  # the assignment or it is taken as the command name (status 127 on macOS).
  run env -u CLAUDE_SUBAGENT_TYPE -u CLAUDE_TASK_METADATA_STAGE CLAUDE_PROJECT_DIR="$WD" \
    bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"agent_type":"","agent_id":"a1","session_id":"s1","duration_ms":7}'
  assert_success
  run jq -e '.subject == "unknown" and .metadata.stage == "unknown"' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "failure: malformed JSON exits 0 and writes no row" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< '{broken'
  assert_success
  [ ! -s "$WD/.context/logs/audit.jsonl" ]
}

@test "contract: --self-test passes (counted summary)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "self-test OK"
  assert_output --regexp 'audit-subagent: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
}

# The last three direct audit.jsonl writers in the hook tree carried no symlink
# refusal; the appender in model-switch-lib.sh has always had one.
@test "SR: a symlinked audit.jsonl is refused, never written through" {
  mkdir -p "$WD/.context/logs" "$WD/target-dir"
  ln -s "$WD/target-dir/escaped.txt" "$WD/.context/logs/audit.jsonl"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < "$PAYLOAD"
  assert_success
  [ ! -e "$WD/target-dir/escaped.txt" ]
}

# --- duplicate delivery ------------------------------------------------------
# Every stop the runtime delivers carries no stage and duration 0, so the
# discriminator is a REPEATED dedupe_key; a first-seen key always records.

stop() {
  # stop <json payload> — one SubagentStop firing with no identity in the
  # environment, so the stage ladder resolves to its terminal fallback.
  run env -u CLAUDE_SUBAGENT_TYPE -u CLAUDE_TASK_METADATA_STAGE \
    CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$1"
}

rows_of() { jq -r --arg a "$1" 'select(.action == $a) | .action' "$WD/.context/logs/audit.jsonl" 2>/dev/null | wc -l | tr -d ' '; }

@test "AC-3a: a repeated dedupe_key writes no second subagent_stopped row" {
  stop '{"agent_id":"ghost","session_id":"s1","duration_ms":0}'
  assert_success
  stop '{"agent_id":"ghost","session_id":"s1","duration_ms":0}'
  assert_success
  [ "$(rows_of subagent_stopped)" = "1" ]
  # The guard keeps no state of its own: the trail is the only seen-set.
  [ -z "$(find "$WD/.context/logs" -name '.subagent-suppressed.*')" ]
}

@test "AC-3a: a FIRST-seen key with no stage and zero duration still records" {
  # The shape every real terminal stop arrives in. A predicate on those two
  # fields would suppress every genuine stop of every agent and empty the trail.
  stop '{"agent_type":"Explore","agent_id":"a1","session_id":"s1","duration_ms":0}'
  assert_success
  stop '{"agent_type":"corpflow:qa-engineer","agent_id":"a2","session_id":"s1","duration_ms":0}'
  assert_success
  [ "$(rows_of subagent_stopped)" = "2" ]
  run jq -se 'map(.metadata.stage == "unknown" and .metadata.duration_ms == 0) | all' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "AC-3a: the same agent_id in ANOTHER session is a different key and records" {
  stop '{"agent_id":"a1","session_id":"sA","duration_ms":0}'
  stop '{"agent_id":"a1","session_id":"sB","duration_ms":0}'
  assert_success
  [ "$(rows_of subagent_stopped)" = "2" ]
}

@test "AC-3a: the match is on the encoded key fragment, not a substring of another key" {
  # `s1:a1:stop` must not be read as already-seen because `xs1:a1:stop` is.
  stop '{"agent_id":"a1","session_id":"xs1","duration_ms":0}'
  stop '{"agent_id":"a1","session_id":"s1","duration_ms":0}'
  assert_success
  [ "$(rows_of subagent_stopped)" = "2" ]
}

@test "AC-2: a stray bare .context in a clean checkout is not a ledger — no logs, no row" {
  local repo
  repo="$(mk_git_fixture --file 'a.txt:hi' --commit 'init')"
  mkdir -p "$repo/.context"
  run_script_env --cwd "$repo" --env "WORKSPACE_ROOT=$repo" --env "CLAUDE_PROJECT_DIR=$repo" \
    --unset CONTEXT_DIR --stdin-file "$PAYLOAD" "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ -z "$(ls -A "$repo/.context")" ] || fail "the hook wrote into a bare context: $(ls -A "$repo/.context")"
}

@test "unresolved root exits 0 and creates no .context under cwd" {
  local cwd
  cwd="$(mk_tmpworkdir)"
  run_script_env --cwd "$cwd" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR --unset CONTEXT_DIR \
    --env "GIT_CEILING_DIRECTORIES=$cwd" --stdin-file "$PAYLOAD" "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ ! -e "$cwd/.context" ]
}

# --- stage ladder: payload, env, ledger dispatch row by agent_id, brief stage line ---

# _stage_ledger <rows-json> — a ledger whose facts.dispatched_agents holds <rows-json>.
_stage_ledger() {
  jq -cn --argjson rows "$1" '{version:2, tasks:{}, facts:{dispatched_agents:$rows}}' \
    > "$WD/.context/state.json"
}

# _stage_transcript <path> <stage-line> — a transcript whose first user record is a composed
# brief. A decoy `stage:` line before the task block proves the read is scoped to that block.
_stage_transcript() {
  local brief
  brief=$(printf '%s\n' '<<<contract-reminder>>>' 'stage: DR' '<<<task-description>>>' \
    'task_id: QA0' "$2" 'agent: corpflow:qa-engineer' '<<<retry-hints>>>' 'stage: FN')
  jq -cn '{type:"system",content:"init"}' > "$1"
  jq -cn --arg c "$brief" '{type:"user",message:{content:$c}}' >> "$1"
}

# _stage_run <payload-json> [env NAME=VALUE...] — runs the hook, echoes metadata.stage.
_stage_run() {
  local p="$1"
  shift
  rm -f "$WD/.context/logs/audit.jsonl"
  env -u CLAUDE_TASK_METADATA_STAGE CLAUDE_PROJECT_DIR="$WD" "$@" \
    bash "$PLUGIN_ROOT/$SCRIPT" <<< "$p" || return 1
  jq -r 'select(.action == "subagent_stopped") | .metadata.stage' "$WD/.context/logs/audit.jsonl"
}

@test "stage: the ledger dispatch row whose agent_id matches the payload names the stage, in any status" {
  local st
  for st in launched completed; do
    _stage_ledger "[{\"stage\":\"DV\",\"agent_id\":\"a_other\",\"status\":\"launched\"},
      {\"stage\":\"QA\",\"task_id\":\"QA0\",\"agent_id\":\"a_qa\",\"status\":\"$st\"}]"
    run _stage_run '{"agent_type":"","agent_id":"a_qa","session_id":"s1"}'
    assert_success
    assert_output "QA"
  done
}

@test "stage: with no matching row, the task-description stage line of the agent's brief names the stage" {
  _stage_ledger '[{"stage":"DV","agent_id":"a_other","status":"launched"}]'
  _stage_transcript "$WD/agent.jsonl" 'stage: QA'
  run _stage_run "$(jq -cn --arg t "$WD/agent.jsonl" '{agent_id:"a_qa",session_id:"s1",agent_transcript_path:$t}')"
  assert_success
  assert_output "QA"
  # transcript_path is the PARENT's transcript on SubagentStop, so it is never read.
  run _stage_run "$(jq -cn --arg t "$WD/agent.jsonl" '{agent_id:"a_qa",session_id:"s2",transcript_path:$t}')"
  assert_success
  assert_output "unknown"
  # A stage line that is not a stage code is no answer.
  _stage_transcript "$WD/bad.jsonl" 'stage: QA0'
  run _stage_run "$(jq -cn --arg t "$WD/bad.jsonl" '{agent_id:"a_qa",session_id:"s3",agent_transcript_path:$t}')"
  assert_success
  assert_output "unknown"
}

@test "stage: payload .stage and the env outrank both new rungs; nothing resolving gives unknown" {
  _stage_ledger '[{"stage":"QA","agent_id":"a_qa","status":"launched"}]'
  _stage_transcript "$WD/agent.jsonl" 'stage: AR'
  run _stage_run "$(jq -cn --arg t "$WD/agent.jsonl" '{stage:"DR",agent_id:"a_qa",session_id:"s1",agent_transcript_path:$t}')"
  assert_output "DR"
  run _stage_run "$(jq -cn --arg t "$WD/agent.jsonl" '{agent_id:"a_qa",session_id:"s2",agent_transcript_path:$t}')" \
    CLAUDE_TASK_METADATA_STAGE=DV
  assert_output "DV"
  run _stage_run '{"agent_id":"a_none","session_id":"s3"}'
  assert_success
  assert_output "unknown"
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "audit-subagent: self-test OK"
  assert_output --regexp 'audit-subagent: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
}

@test "stage: an agent_id on rows of two stages is ambiguous and falls to the brief, then to unknown" {
  _stage_ledger '[{"stage":"QA","agent_id":"a_x","status":"completed"},
    {"stage":"DR","agent_id":"a_x","status":"launched"}]'
  _stage_transcript "$WD/agent.jsonl" 'stage: AR'
  run _stage_run "$(jq -cn --arg t "$WD/agent.jsonl" '{agent_id:"a_x",session_id:"s1",agent_transcript_path:$t}')"
  assert_output "AR"
  run _stage_run '{"agent_id":"a_x","session_id":"s2"}'
  assert_output "unknown"
}
