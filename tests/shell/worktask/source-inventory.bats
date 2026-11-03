#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

setup() {
  WD="$(mk_tmpworkdir)"
}

@test "source inventory: reviewers can find a defect omitted from the handoff without generated noise" {
  mkdir -p "$WD/src" "$WD/.build/checkouts" "$WD/generated-capture-tools" "$WD/archives" "$WD/logs"
  printf '.build/\n' > "$WD/.gitignore"
  printf 'fixture: real evaluator source\n' > "$WD/cases.jsonl"
  printf 'summary: only the formatter changed\n' > "$WD/handoff.md"
  printf 'unsafe_dependency_call()\n' > "$WD/src/dependency.py"
  printf 'generated\n' > "$WD/.build/checkouts/noise.py"
  printf 'generated\n' > "$WD/generated-capture-tools/noise.py"
  printf 'archive\n' > "$WD/archives/old.py"
  printf 'pixels\n' > "$WD/picture.png"
  run bash "$PLUGIN_ROOT/skills/worktask/scripts/source-inventory.sh" "$WD"
  assert_success
  [[ "$output" == *"src/dependency.py"* ]]
  [[ "$output" == *"cases.jsonl"* ]]
  [[ "$output" != *"noise.py"* ]]
  [[ "$output" != *"old.py"* ]]
  [[ "$output" != *"picture.png"* ]]
  run rg 'unsafe_dependency_call' "$WD/src/dependency.py"
  assert_success
  run bash "$PLUGIN_ROOT/skills/worktask/scripts/source-inventory.sh" --include-artifacts "$WD"
  assert_success
  [[ "$output" == *"noise.py"* ]]
  [[ "$output" == *"picture.png"* ]]
  [[ "$output" == *".build/checkouts/noise.py"* ]]
}

@test "source inventory: the default root includes ordinary source files" {
  mkdir -p "$WD/src"
  printf 'contract\n' > "$WD/src/visible.py"
  cd "$WD"
  run bash "$PLUGIN_ROOT/skills/worktask/scripts/source-inventory.sh"
  assert_success
  [[ "$output" == *"src/visible.py"* ]]
}

@test "source inventory: invalid roots fail clearly without reading another directory" {
  run bash "$PLUGIN_ROOT/skills/worktask/scripts/source-inventory.sh" "$WD/missing"
  [ "$status" = 2 ]
  [[ "$output" == *"root is not a directory"* ]]
  run bash "$PLUGIN_ROOT/skills/worktask/scripts/source-inventory.sh" "$WD" unexpected
  [ "$status" = 2 ]
}

@test "source inventory: explicit ignored dependencies retain source evidence while Git metadata remains excluded" {
  mkdir -p "$WD/node_modules/dependency" "$WD/.git" "$WD/.worktrees/other"
  printf 'node_modules/\n' > "$WD/.gitignore"
  printf 'implementation contract\n' > "$WD/node_modules/dependency/source.js"
  printf 'metadata\n' > "$WD/.git/config"
  printf 'other checkout\n' > "$WD/.worktrees/other/code.py"
  run bash "$PLUGIN_ROOT/skills/worktask/scripts/source-inventory.sh" "$WD"
  assert_success
  [[ "$output" != *"dependency/source.js"* ]]
  run bash "$PLUGIN_ROOT/skills/worktask/scripts/source-inventory.sh" --include-artifacts "$WD"
  assert_success
  [[ "$output" == *"dependency/source.js"* ]]
  [[ "$output" != *".git/config"* ]]
  [[ "$output" != *"other/code.py"* ]]
}

@test "source inventory: linked-worktree Git pointer files stay excluded in both modes" {
  mkdir -p "$WD/nested" "$WD/src"
  printf 'gitdir: /external/private/git/metadata\n' > "$WD/.git"
  printf 'gitdir: /external/private/nested/metadata\n' > "$WD/nested/.git"
  printf 'source contract\n' > "$WD/src/contract.py"
  for mode in ordinary explicit; do
    if [ "$mode" = explicit ]; then
      run bash "$PLUGIN_ROOT/skills/worktask/scripts/source-inventory.sh" --include-artifacts "$WD"
    else
      run bash "$PLUGIN_ROOT/skills/worktask/scripts/source-inventory.sh" "$WD"
    fi
    assert_success
    [[ "$output" == *"src/contract.py"* ]]
    [[ "$output" != *".git"* ]]
  done
}
