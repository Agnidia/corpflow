#!/usr/bin/env bats
# effort-ladder-cli.sh — the allow-listable entry point to effort-ladder.sh that Step C.0a runs.
#
# Every row asserts stdout and the exit code exactly: the orchestrator compares two CLI outputs
# to detect a clamp, so a stray byte or a wrong rc becomes a false `effort_clamped` audit row.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

CLI="skills/worktask/scripts/effort-ladder-cli.sh"

# --- the AC-3a table ---------------------------------------------------------

@test "for-resolver bumps a full-ladder model one rung" {
  run bash "$PLUGIN_ROOT/$CLI" for-resolver high opus
  assert_success
  assert_output "xhigh"
}

@test "for-resolver clamps a capped model at the ceiling" {
  run bash "$PLUGIN_ROOT/$CLI" for-resolver high haiku
  assert_success
  assert_output "high"
}

@test "plus-one saturates at max" {
  run bash "$PLUGIN_ROOT/$CLI" plus-one max
  assert_success
  assert_output "max"
}

@test "rank prints the 0-based rung" {
  run bash "$PLUGIN_ROOT/$CLI" rank low
  assert_success
  assert_output "0"
}

@test "an off-ladder tier exits 2 with empty stdout" {
  run --separate-stderr bash "$PLUGIN_ROOT/$CLI" rank bogus
  assert_failure 2
  assert_output ""
  [[ "$stderr" == *"not on the ladder"* ]]
}

@test "no arguments exits 2 with usage on stderr only" {
  run --separate-stderr bash "$PLUGIN_ROOT/$CLI"
  assert_failure 2
  assert_output ""
  [[ "$stderr" == usage:* ]]
}

# --- edge rows ---------------------------------------------------------------

@test "the value carries exactly one trailing newline" {
  # The sentinel keeps the newline that $(...) would otherwise strip.
  run bash -c 'out=$(bash "$1" rank max; printf x); printf "%s" "$out"' _ "$PLUGIN_ROOT/$CLI"
  assert_success
  assert_output $'4\nx'
}

@test "an unknown subcommand and a wrong arg count both exit 2" {
  run bash "$PLUGIN_ROOT/$CLI" bump high
  assert_failure 2
  run bash "$PLUGIN_ROOT/$CLI" for-resolver high
  assert_failure 2
  run bash "$PLUGIN_ROOT/$CLI" plus-one
  assert_failure 2
}

@test "--help prints usage on stdout and exits 0" {
  run bash "$PLUGIN_ROOT/$CLI" --help
  assert_success
  assert_output --partial "for-resolver"
}

@test "a missing sibling library exits 1, not 2" {
  stub="$(mk_tmpworkdir)"
  cp "$PLUGIN_ROOT/$CLI" "$stub/"
  run bash "$stub/effort-ladder-cli.sh" rank low
  assert_failure 1
  assert_output --partial "library unreachable"
}

@test "for-resolver agrees with the library on every rung and model class" {
  for m in opus sonnet fable haiku; do
    for e in low medium high xhigh max; do
      want=$(bash -c '. "$1"; effort_for_resolver "$2" "$3"' _ \
        "$PLUGIN_ROOT/skills/worktask/scripts/effort-ladder.sh" "$e" "$m")
      run bash "$PLUGIN_ROOT/$CLI" for-resolver "$e" "$m"
      assert_success
      assert_output "$want"
    done
  done
}
