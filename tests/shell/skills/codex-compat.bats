#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

RUNTIME="skills/shared/lib/codex-runtime.sh"
ADAPTER="hooks/codex-adapter.sh"
CAPTURE="tests/fixtures/hooks/codex-capture.sh"

@test "manifests: portable, Codex, Claude and marketplace versions agree" {
  run jq -er '
    input as $codex | input as $claude | input as $market
    | .version == "4.1.2"
      and $codex.version == .version
      and $claude.version == .version
      and $market.metadata.version == .version
      and $market.plugins[0].version == .version
  ' "$PLUGIN_ROOT/plugin.json" "$PLUGIN_ROOT/.codex-plugin/plugin.json" \
    "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$PLUGIN_ROOT/.claude-plugin/marketplace.json"
  assert_success
  assert_output "true"
}

@test "manifests: Codex hook config uses only supported events and official root variable" {
  run jq -er '
    (.hooks | keys | sort) == (["PostCompact","PostToolUse","PreCompact","PreToolUse","SessionEnd","SubagentStop"] | sort)
    and ([.hooks[][]?.hooks[]?.command // empty] | all(contains("${PLUGIN_ROOT}")))
    and ([.hooks[][]?.hooks[]?.command // empty] | all(contains("CLAUDE_PLUGIN_ROOT") | not))
    and .hooks.SessionEnd[0].hooks[0].timeout == 3
  ' "$PLUGIN_ROOT/hooks/codex-hooks.json"
  assert_success
  assert_output "true"
}

@test "skills: every canonical command has a same-named thin Codex adapter" {
  run ruby -ryaml -e '
    Dir["commands/*.md"].sort.each do |command|
      name = File.basename(command, ".md")
      skill = "skills/#{name}/SKILL.md"
      abort("missing #{skill}") unless File.file?(skill)
      c = YAML.safe_load(File.read(command).split("---", 3)[1], permitted_classes: [], aliases: false)
      s = YAML.safe_load(File.read(skill).split("---", 3)[1], permitted_classes: [], aliases: false)
      abort("name drift: #{name}") unless c["name"] == s["name"]
      abort("argument-hint drift: #{name}") unless c["argument-hint"] == s["argument-hint"]
      abort("trigger-first description missing: #{name}") unless s["description"].to_s.match?(/\b(Use|Apply|Invoke|Run)\b/)
      abort("canonical command link missing: #{name}") unless File.read(skill).include?("commands/#{name}.md")
    end
    puts "28 command adapters OK"
  '
  assert_success
  assert_output "28 command adapters OK"
}

@test "runtime: model aliases map to the selected Codex models" {
  local alias expected
  while read -r alias expected; do
    run bash -c ". '$PLUGIN_ROOT/$RUNTIME'; corpflow_codex_model '$alias'"
    assert_success
    assert_output "$expected"
  done <<'EOF'
haiku gpt-6-luna
sonnet gpt-6-sol
opus gpt-6-sol
fable gpt-6-astra
EOF
  run bash -c ". '$PLUGIN_ROOT/$RUNTIME'; corpflow_codex_model unknown"
  assert_failure 2
}

@test "runtime: task names are stable, lowercase and bounded" {
  run bash -c ". '$PLUGIN_ROOT/$RUNTIME'; corpflow_codex_task_name 'DV-Stream_42' 3"
  assert_success
  assert_output "cf_dv_stream_42_3"
}

@test "runtime: dispatch records the resolved model and preserves reasoning effort" {
  run bash -c ". '$PLUGIN_ROOT/$RUNTIME'; corpflow_codex_dispatch_json fable xhigh"
  assert_success
  run jq -e '.model_requested == "fable" and .model_resolved == "gpt-6-astra" and .effort == "xhigh"' <<<"$output"
  assert_success
}

@test "runtime: dispatch ordering forbids synthetic ids and empty waits" {
  run ruby -e '
    text = File.read(ARGV.fetch(0))
    spawn = text.index("Call `spawn_agent` before writing a dispatch row") or abort("missing spawn-first rule")
    record = text.index("Only after `spawn_agent` succeeds") or abort("missing returned-id rule")
    abort("dispatch row precedes spawn") unless spawn < record
    abort("missing synthetic-id ban") unless text.include?("Never synthesize an agent id")
    abort("missing empty-wait ban") unless text.include?("Only call\n`wait_agent` when at least one real spawned agent is still live")
    abort("missing agent-id preference") unless text.include?("Persist `agent_id` when present; otherwise persist the exact `task_name`")
    abort("missing identifier derivation ban") unless text.include?("Never derive one identifier from the other")
  ' "$PLUGIN_ROOT/skills/shared/codex-runtime.md"
  assert_success
}

@test "adapter: spawn_agent becomes the canonical Agent payload" {
  local wd; wd="$(mk_tmpworkdir)"
  run env BASE_PLUGIN_ROOT="$PLUGIN_ROOT" WORKSPACE_ROOT="$wd" \
    bash "$PLUGIN_ROOT/$ADAPTER" --mode tool --target "$CAPTURE" <<'JSON'
{"cwd":"/tmp","tool_name":"spawn_agent","tool_input":{"task_name":"cf_dv0_1","message":"Implement the stage"}}
JSON
  assert_success
  echo "$output" | jq -e '.tool_name == "Agent" and .tool_input.subagent_type == "cf_dv0_1" and .tool_input.prompt == "Implement the stage"'
}

@test "adapter: request_user_input answers are keyed by canonical question text" {
  local wd; wd="$(mk_tmpworkdir)"
  run env BASE_PLUGIN_ROOT="$PLUGIN_ROOT" WORKSPACE_ROOT="$wd" \
    bash "$PLUGIN_ROOT/$ADAPTER" --mode decision --target "$CAPTURE" <<'JSON'
{"tool_name":"request_user_input","tool_input":{"questions":[{"id":"strategy","header":"Strategy","question":"Which strategy?","options":[]}]},"tool_response":{"answers":{"strategy":{"answers":["Safe"]}}}}
JSON
  assert_success
  echo "$output" | jq -e '.tool_name == "AskUserQuestion" and .tool_response.answers["Which strategy?"][0] == "Safe"'
}

@test "adapter: apply_patch extracts every safe Add Update Delete path" {
  local wd capture physical_wd; wd="$(mk_tmpworkdir)"; capture="$wd/paths"; physical_wd="$(cd "$wd" && pwd -P)"
  run env BASE_PLUGIN_ROOT="$PLUGIN_ROOT" WORKSPACE_ROOT="$wd" CODEX_CAPTURE_FILE="$capture" \
    bash "$PLUGIN_ROOT/$ADAPTER" --mode patch-post --target "$CAPTURE" <<'JSON'
{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: one.txt\n+x\n*** Update File: dir/two.txt\n@@\n-old\n+new\n*** Delete File: old.txt\n*** Add File: ../escape.txt\n*** End Patch"}}
JSON
  assert_success
  run sed "s#^$physical_wd/##" "$capture"
  assert_success
  assert_output "one.txt
dir/two.txt
old.txt"
}

@test "adapter: apply_patch preflight scopes added content to each file" {
  local wd capture; wd="$(mk_tmpworkdir)"; capture="$wd/payloads"
  run env BASE_PLUGIN_ROOT="$PLUGIN_ROOT" WORKSPACE_ROOT="$wd" CODEX_CAPTURE_JSON_FILE="$capture" \
    bash "$PLUGIN_ROOT/$ADAPTER" --mode patch-pre --target "$CAPTURE" <<'JSON'
{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: one.md\n+## One\n*** Update File: two.md\n@@\n-old\n+## Two\n*** End Patch"}}
JSON
  assert_success
  run jq -se 'length == 2 and .[0].tool_input.content == "## One" and .[1].tool_input.content == "## Two"' "$capture"
  assert_success
  assert_output "true"
}

@test "contract: project does not invent CODEX_PLUGIN_ROOT" {
  run rg -n 'CODEX_PLUGIN_ROOT=' plugin.json .codex-plugin hooks skills commands README.md
  assert_failure 1
}
