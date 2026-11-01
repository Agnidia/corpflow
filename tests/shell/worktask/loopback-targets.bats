#!/usr/bin/env bats
# loopback-targets.sh — which DV rows a gate loop-back replays.
#
# The load-bearing cases are the fallbacks: a wrong narrow leaves a defect unreplayed, a
# wrong widen only costs re-runs, so every doubtful input must print the full set.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/worktask/scripts/loopback-targets.sh"
FIX="tests/fixtures/worktask/loopback-targets"
FULL=$'DV0\nDV1\nDV2\nDV3'

setup() {
  W="$(mk_tmpworkdir)"
  mkdir -p "$W/.context"
  cp "$PLUGIN_ROOT/$FIX/ctx/state.json" "$W/.context/"
  # The helper attributes blockers by artifact basename, but a tracked development-N-<stream>.md
  # would be policed as a full DV artifact, so the fixtures live under a neutral name.
  local s
  for s in alpha beta gamma delta; do
    cp "$PLUGIN_ROOT/$FIX/ctx/stream-$s.md" "$W/.context/development-0-$s.md"
  done
}

# gate_qa <blocking_defects item>... — QA0 artifact, no-go, one defect per argument.
gate_qa() {
  { printf -- '---\nhandoff:\n  stage: QA\n  verdict: no-go\n  blocking_defects:\n'
    for d in "$@"; do printf '    - "%s"\n' "$d"; done
    printf -- '---\n\n# QA\n'; } > "$W/.context/testing-0.md"
}

# gate_dr <blockers item>... — DR0 artifact, fail.
gate_dr() {
  { printf -- '---\nhandoff:\n  stage: DR\n  verdict: fail\n  blockers:\n'
    for d in "$@"; do printf '    - "%s"\n' "$d"; done
    printf -- '---\n\n# DR\n'; } > "$W/.context/developer-review-0.md"
}

run_helper() { # run_helper <gate>
  run_script_env --separate-stderr "$SCRIPT" --state "$W/.context/state.json" --gate "$1"
}

@test "AC-1: two defects citing one stream artifact narrow to that stream" {
  gate_qa "acceptance line 3 in development-0-gamma.md fails" "acceptance line 5 in .context/development-0-gamma.md fails"
  run_helper QA0
  [ "$status" -eq 0 ]
  [ "$output" = "DV2" ]
  [[ "$stderr" == *"scope=narrow"* ]]
}

@test "AC-2: DR blockers citing only paths one stream lists narrow to it" {
  gate_dr "src/beta/main.sh has an unquoted expansion" "docs/beta/notes.md is stale"
  run_helper DR0
  [ "$status" -eq 0 ]
  [ "$output" = "DV1" ]
}

@test "AC-3a: empty blockers replay the full set" {
  gate_qa
  run_helper QA0
  [ "$status" -eq 0 ]
  [ "$output" = "$FULL" ]
  [[ "$stderr" == *"scope=full"* ]]
}

@test "AC-3b: a blocker naming no stream replays the full set" {
  gate_qa "the build is red"
  run_helper QA0
  [ "$output" = "$FULL" ]
  [[ "$stderr" == *"scope=full"* ]]
}

@test "AC-3c: blockers naming two streams replay the full set" {
  gate_qa "see development-0-alpha.md" "see development-0-delta.md"
  run_helper QA0
  [ "$output" = "$FULL" ]
  [[ "$stderr" == *"scope=full"* ]]
}

@test "AC-3d: a path two streams both list replays the full set" {
  gate_qa "shared/common.sh is broken"
  run_helper QA0
  [ "$output" = "$FULL" ]
  [[ "$stderr" == *"scope=full"* ]]
}

@test "one attributable and one unattributable blocker replay the full set" {
  gate_qa "development-0-gamma.md line 2" "unrelated flake"
  run_helper QA0
  [ "$output" = "$FULL" ]
}

@test "AC-3e: a missing gate artifact replays the full set" {
  run_helper QA0
  [ "$status" -eq 0 ]
  [ "$output" = "$FULL" ]
  [[ "$stderr" == *"scope=full"* ]]
}

@test "AC-4: one DV row replays that row" {
  jq 'del(.tasks.DV1,.tasks.DV2,.tasks.DV3) | .tasks.DR0.blocked_by = ["DV0"]' "$W/.context/state.json" > "$W/s.json"
  mv "$W/s.json" "$W/.context/state.json"
  gate_qa "anything at all"
  run_helper QA0
  [ "$status" -eq 0 ]
  [ "$output" = "DV0" ]
}

@test "AC-4: a gate with no DV row in its closure exits 3 with empty stdout" {
  run_helper PL0
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "AC-5: a basename of a DV row outside the closure is unattributable" {
  jq '.tasks.DR0.blocked_by = ["DV0","DV1","DV3"]' "$W/.context/state.json" > "$W/s.json"
  mv "$W/s.json" "$W/.context/state.json"
  gate_qa "see development-0-gamma.md"
  run_helper QA0
  [ "$output" = $'DV0\nDV1\nDV3' ]
  [[ "$stderr" == *"scope=full"* ]]
}

@test "a longer filename does not match a stream basename as a substring" {
  gate_qa "see development-0-gamma.md.bak"
  run_helper QA0
  [[ "$stderr" == *"scope=full"* ]]
}

@test "usage errors exit 2 and an unknown gate exits 3" {
  run_script_env --separate-stderr "$SCRIPT" --state "$W/.context/state.json"
  [ "$status" -eq 2 ]
  run_helper NOPE9
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "unparseable ledger exits 3 with no stdout" {
  printf 'not json' > "$W/.context/state.json"
  run_helper QA0
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# A jq that fails on any call whose arguments contain $FAIL_JQ_ON. Every doubtful input must
# widen to the full set, so each jq call site needs its own deliberate routing.
@test "a failing jq call replays the full set, never a partial or empty one" {
  mkdir -p "$W/shim"
  local real; real="$(command -v jq)"
  { printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in *"$FAIL_JQ_ON"*) exit 5 ;; esac\n'
    printf 'exec %q "$@"\n' "$real"; } > "$W/shim/jq"
  chmod +x "$W/shim/jq"
  gate_qa "see development-0-gamma.md"
  local case_ marker reason
  for case_ in "metadata.artifact // .artifact // \"\")|gate-artifact-unreadable" \
               "--arg i|stream-artifact-unreadable" \
               "--rawfile files|stream-json-failed" \
               "--rawfile b|attribution-failed"; do
    marker="${case_%%|*}"; reason="${case_##*|}"
    FAIL_JQ_ON="$marker" PATH="$W/shim:$PATH" run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" \
      --state "$W/.context/state.json" --gate QA0
    [ "$status" -eq 0 ]
    [ "$output" = "$FULL" ]
    [[ "$stderr" == *"scope=full reason=$reason"* ]]
  done
}

# list_of must propagate a failed parse: a truncated blocker or file list could narrow to the
# wrong stream.
@test "a failing list parse replays the full set" {
  mkdir -p "$W/shim"
  local real; real="$(command -v awk)"
  { printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in *"$FAIL_AWK_ON"*) exit 5 ;; esac\n'
    printf 'exec %q "$@"\n' "$real"; } > "$W/shim/awk"
  chmod +x "$W/shim/awk"
  gate_qa "see development-0-gamma.md"
  local case_ marker reason
  for case_ in "key=blocking_defects|blockers-unreadable" \
               "key=files_modified|stream-files-unreadable"; do
    marker="${case_%%|*}"; reason="${case_##*|}"
    FAIL_AWK_ON="$marker" PATH="$W/shim:$PATH" run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" \
      --state "$W/.context/state.json" --gate QA0
    [ "$status" -eq 0 ]
    [ "$output" = "$FULL" ]
    [[ "$stderr" == *"scope=full reason=$reason"* ]]
  done
}

@test "a failing closure walk exits 3 with empty stdout" {
  mkdir -p "$W/shim"
  local real; real="$(command -v jq)"
  { printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in *"def walk"*) exit 5 ;; esac\n'
    printf 'exec %q "$@"\n' "$real"; } > "$W/shim/jq"
  chmod +x "$W/shim/jq"
  gate_qa "see development-0-gamma.md"
  PATH="$W/shim:$PATH" run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" \
    --state "$W/.context/state.json" --gate QA0
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}
