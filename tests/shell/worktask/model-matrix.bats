#!/usr/bin/env bats
# Dedicated coverage-proxy file for model-matrix.sh (coverage-proxy.bats requires one per
# script under skills/**/scripts/). This is the thin CLI wrapper for a caller that cannot
# source bash (architecture-0.md#ad2) — model-matrix-lib.bats covers the library directly;
# this file covers the CLI surface: flag parsing, exit codes, and --resolved-json's shape.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/worktask/scripts/model-matrix.sh"

@test "--rows prints the same row count as the library, via subprocess" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --rows
  assert_success
  local agent_count
  agent_count=$(cd "$PLUGIN_ROOT/agents" && ls -1 ./*.md | wc -l | tr -d '[:space:]')
  [ "${#lines[@]}" -eq "$agent_count" ]
}

# Omitted state/CORPFLOW paths resolve from the root ladder (CONTEXT_DIR first), so every
# bare call below pins CONTEXT_DIR to an empty temp dir — the suite must not read whatever
# state.json this checkout happens to carry. CLAUDE_CONFIG_DIR is sandboxed by test_helper.
@test "--resolve <agent> prints model, effort and source, tab-separated" {
  CONTEXT_DIR="$BATS_TEST_TMPDIR" run bash "$PLUGIN_ROOT/$SCRIPT" --resolve developer
  assert_success
  assert_output $'opus\thigh\tmatrix'
}

@test "a bare --resolve reads state.models and CORPFLOW.md from the CONTEXT_DIR root ladder" {
  # The documented PL0 call passes no paths; without this default the override ranks never
  # reached the pair PL0 pastes into --task-create.
  local root="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$root/.context"
  printf '{"models":{"developer":{"model":"haiku","effort":"low","source":"project-override"}}}' \
    > "$root/.context/state.json"
  printf '## Models\n\n| Agent | Model | Effort |\n|---|---|---|\n| qa-engineer | opus | - |\n' \
    > "$root/CORPFLOW.md"
  CONTEXT_DIR="$root/.context" run bash "$PLUGIN_ROOT/$SCRIPT" --resolve corpflow:developer
  assert_success
  assert_output $'haiku\tlow\tstate'
  CONTEXT_DIR="$root/.context" run bash "$PLUGIN_ROOT/$SCRIPT" --resolve qa-engineer
  assert_success
  assert_output $'opus\tmedium\tproject-override'
}

@test "a bare --resolve falls back to the user-scope CORPFLOW.md when the project has no ## Models" {
  local root="${BATS_TEST_TMPDIR}/proj" cfg="${BATS_TEST_TMPDIR}/cfg"
  mkdir -p "$root/.context" "$cfg"
  printf '## Models\n\n| Agent | Model | Effort |\n|---|---|---|\n| qa-engineer | opus | - |\n' \
    > "$cfg/CORPFLOW.md"
  CLAUDE_CONFIG_DIR="$cfg" CONTEXT_DIR="$root/.context" \
    run bash "$PLUGIN_ROOT/$SCRIPT" --resolve qa-engineer
  assert_success
  assert_output $'opus\tmedium\tuser-override'
  # An unresolvable root still reads the user file; the project heading, once present, wins.
  CLAUDE_CONFIG_DIR="$cfg" CONTEXT_DIR="$root/.context" \
    run bash "$PLUGIN_ROOT/$SCRIPT" --resolve developer
  assert_output $'opus\thigh\tmatrix'
  printf '## Models\n\n| Agent | Model | Effort |\n|---|---|---|\n| qa-engineer | haiku | low |\n' \
    > "$root/CORPFLOW.md"
  CLAUDE_CONFIG_DIR="$cfg" CONTEXT_DIR="$root/.context" \
    run bash "$PLUGIN_ROOT/$SCRIPT" --resolve qa-engineer
  assert_output $'haiku\tlow\tproject-override'
}

@test "--resolve on an unknown agent exits 2 rather than printing an empty pair" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --resolve not-a-real-agent
  assert_failure 2
  assert_output --partial "no pair resolved"
}

@test "--resolved-json emits one entry per agent with model/effort/source keys" {
  command -v jq > /dev/null 2>&1 || skip "jq not available"
  local out="${BATS_TEST_TMPDIR}/resolved.json"
  CONTEXT_DIR="$BATS_TEST_TMPDIR" run bash -c "bash '$PLUGIN_ROOT/$SCRIPT' --resolved-json > '$out'"
  assert_success
  run jq -e '.developer.model == "opus" and .developer.source == "matrix"' "$out"
  assert_success
}

@test "--resolved-json exits 3 on a broken matrix instead of printing {} with exit 0" {
  command -v jq > /dev/null 2>&1 || skip "jq not available"
  # A shadow plugin tree whose stage-codes.md has the heading but zero rows (R3's shape).
  local tree="${BATS_TEST_TMPDIR}/tree"
  mkdir -p "$tree/skills/shared/lib" "$tree/skills/worktask/scripts" \
    "$tree/skills/worktask/references" "$tree/agents"
  cp "$PLUGIN_ROOT"/skills/worktask/scripts/{model-matrix.sh,model-matrix-lib.sh,effort-ladder.sh} \
    "$tree/skills/worktask/scripts/"
  cp "$PLUGIN_ROOT/skills/shared/lib/state-read-lib.sh" "$tree/skills/shared/lib/"
  printf '## Agent Model Matrix\n\n| Agent | Model | Effort |\n' > "$tree/skills/worktask/references/stage-codes.md"
  CONTEXT_DIR="$BATS_TEST_TMPDIR" run bash "$tree/skills/worktask/scripts/model-matrix.sh" --resolved-json
  assert_failure 3
  refute_output --partial '{}'
}

@test "no arguments, or an unknown flag, exits 2 with usage on stderr" {
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_failure 2
  assert_output --partial "usage:"
  run bash "$PLUGIN_ROOT/$SCRIPT" --bogus
  assert_failure 2
  assert_output --partial "unknown argument"
}
