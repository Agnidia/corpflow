#!/usr/bin/env bats
# Tests for hooks/agent-stop.sh (DV0c) — Stop-event multiplexer that writes a
# canonical `stage_completion_hook` row to .context/logs/audit.jsonl.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="hooks/agent-stop.sh"
PAYLOAD="${FIXTURES}/hooks/agent-stop.payload.json"

setup() {
  WD="$(mk_tmpworkdir)"
  # The root ladder answers only a context holding a ledger.
  mkdir -p "$WD/.context"
  printf '%s' '{"version":2,"tasks":{}}' > "$WD/.context/state.json"
}

@test "happy: appends a stage_completion_hook row with stage + dedupe keys" {
  run env CLAUDE_PROJECT_DIR="$WD" \
    bash "$PLUGIN_ROOT/$SCRIPT" --stage DV < "$PAYLOAD"
  assert_success
  [ -f "$WD/.context/logs/audit.jsonl" ]
  run jq -e '
    .action == "stage_completion_hook"
    and .subject == "corpflow:product-manager"
    and .metadata.stage == "DV"
    and .metadata.background_tasks_count == 2
    and .metadata.background_task_ids == ["bg1","bg2"]
    and .metadata.session_crons_count == 1
    and (.metadata.dedupe_key == "sess_fix:agt_pl:stage:DV")
  ' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "effort: the payload tier is recorded" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" --stage DV < "$PAYLOAD"
  assert_success
  run jq -e '.metadata.effort == "high"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "effort: a payload without effort records unknown, never \$CLAUDE_EFFORT" {
  # A haiku subagent runs with no effort: its SubagentStop payload omits .effort while the
  # env var still holds the requested tier.
  run env CLAUDE_EFFORT=high CLAUDE_PROJECT_DIR="$WD" \
    bash "$PLUGIN_ROOT/$SCRIPT" --stage DV <<< '{"agent_type":"corpflow:technical-writer","agent_id":"a9","session_id":"s9"}'
  assert_success
  run jq -e '.metadata.effort == "unknown"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "edge: missing optional fields default safely (stage=unknown, none parent)" {
  run env CLAUDE_PROJECT_DIR="$WD" \
    bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"agent_type":"corpflow:x"}'
  assert_success
  run jq -e '
    .metadata.stage == "unknown"
    and .metadata.parent_agent_id == "none"
    and .metadata.background_tasks_count == 0
    and (.metadata.dedupe_key == "nosession:noagent:stage:unknown")
  ' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "failure: malformed JSON payload does not crash (exit 0, no row written)" {
  run env CLAUDE_PROJECT_DIR="$WD" \
    bash "$PLUGIN_ROOT/$SCRIPT" --stage DV <<< 'not-json'
  # Hook swallows jq parse failure and exits 0 (must not block transition).
  assert_success
  [ ! -s "$WD/.context/logs/audit.jsonl" ]
}

@test "contract: --self-test passes (counted summary)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "self-test OK"
  assert_output --regexp 'agent-stop: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
}

@test "SR: a symlinked audit.jsonl is refused, never written through" {
  mkdir -p "$WD/.context/logs" "$WD/target-dir"
  ln -s "$WD/target-dir/escaped.txt" "$WD/.context/logs/audit.jsonl"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" --stage DV < "$PAYLOAD"
  assert_success
  [ ! -e "$WD/target-dir/escaped.txt" ]
}

@test "unresolved root exits 0 and creates no .context under cwd" {
  local outside
  outside="$(mk_tmpworkdir)"
  run_script_env --cwd "$outside" \
    --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR --unset CONTEXT_DIR \
    --env "GIT_CEILING_DIRECTORIES=$outside" --stdin-file "$PAYLOAD" \
    "$PLUGIN_ROOT/$SCRIPT" --stage DV
  assert_success
  [ ! -e "$outside/.context" ]
}

# --- wiring: plugin.json SubagentStop is the only route that fires this hook ----
# Claude Code ignores `hooks:` in plugin agent frontmatter, so the anchored matchers
# in plugin.json are what scope agent-stop.sh to the PL/FN/ST agents.

# Prints "<command>\t<args as JSON>" for every agent-stop.sh entry in a SubagentStop
# group whose matcher selects agent type $1, following the hooks-doc matcher rules:
# omitted, "" or "*" match everything; letters/digits/_/-/space/,/| only is an exact
# list; anything else is an unanchored regular expression.
_subagent_stop_agent_stop_entries() {
  jq -r --arg t "$1" '
    def selects($m):
      if ($m // "") == "" or $m == "*" then true
      elif ($m | test("^[A-Za-z0-9_ ,|-]+$")) then
        [$m | splits("[|,]") | gsub("^\\s+|\\s+$"; "")] | index([$t]) != null
      else $t | test($m) end;
    .hooks.SubagentStop[]
    | select(selects(.matcher))
    | .hooks[]
    | select(.command | endswith("/hooks/agent-stop.sh"))
    | "\(.command)\t\(.args // [] | tojson)"
  ' "$PLUGIN_ROOT/.claude-plugin/plugin.json"
}

# Fires every matched agent-stop.sh entry the way the runtime would, for agent type $1.
_fire_subagent_stop() {
  local agent="$1" cmd args
  while IFS=$'\t' read -r cmd args; do
    [ -n "$cmd" ] || continue
    cmd="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_ROOT}"
    # shellcheck disable=SC2046
    jq -n --arg t "$agent" '{agent_type:$t, agent_id:"agt_w", session_id:"sess_w"}' \
      | env CLAUDE_PROJECT_DIR="$WD" "$cmd" $(jq -r '.[]' <<< "$args") \
      || return 1
  done < <(_subagent_stop_agent_stop_entries "$agent")
}

@test "wiring: agent-stop.sh is registered only under SubagentStop, one anchored matcher per stage agent" {
  run jq -r '
    .hooks | to_entries[] | .key as $ev | .value[]
    | .matcher as $m | .hooks[]
    | select((.command // "") | endswith("/hooks/agent-stop.sh"))
    | "\($ev) \($m) \(.args | join(" "))"
  ' "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  assert_success
  assert_output "$(printf '%s\n' \
    'SubagentStop ^corpflow:product-manager$ --stage PL' \
    'SubagentStop ^corpflow:project-manager$ --stage FN' \
    'SubagentStop ^corpflow:stakeholder$ --stage ST')"
}

@test "wiring: each PL/FN/ST agent's stop writes exactly one row carrying its own stage" {
  local agent stage
  for agent in product-manager:PL project-manager:FN stakeholder:ST; do
    stage="${agent#*:}"
    agent="corpflow:${agent%%:*}"
    rm -f "$WD/.context/logs/audit.jsonl"
    _fire_subagent_stop "$agent" || fail "hook failed for $agent"
    run jq -s -c 'map({subject, stage: .metadata.stage})' "$WD/.context/logs/audit.jsonl"
    assert_success
    assert_output "[{\"subject\":\"$agent\",\"stage\":\"$stage\"}]"
  done
}

@test "wiring: other agents, near-miss names and internal agents fire nothing" {
  local agent
  # "" is the agent type Claude Code sends for its own internal agents (prompt
  # suggestions, /btw); a named matcher must not select it.
  for agent in corpflow:developer corpflow:product-manager-x xcorpflow:stakeholder \
    other-plugin:project-manager product-manager ""; do
    run _subagent_stop_agent_stop_entries "$agent"
    assert_success
    [ -z "$output" ] || fail "agent-stop.sh selected for agent type '$agent': $output"
  done
  _fire_subagent_stop corpflow:developer
  [ ! -e "$WD/.context/logs/audit.jsonl" ]
}
