#!/usr/bin/env bats
# tests/shell/dv-screenshot/size-budget.bats
# Target: skills/dv-screenshot-capture/scripts/size-budget.sh
# Covers: small file → verdict=ok exit 0, warn-range file → verdict=warn exit 0,
#         oversize file (no pngquant) → moved to oversize/ exit 3, slug strip, root guards.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/dv-screenshot-capture/scripts/size-budget.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context/logs" "$WD/.context/images/wt-test"
  printf '%s' '{"version":2,"worktask_id":"wt-test","tasks":{"DV0":{"status":"in_progress"}}}' \
    > "$WD/.context/state.json"
  export WORKSPACE_ROOT="$WD"
}

# Oversize cases run on the allowlist farm, never on /usr/bin:/bin: a distro pngquant
# in /usr/bin would turn "no pngquant" into "pngquant present".
# ---------------------------------------------------------------------------

@test "small file (<200KB) -> verdict=ok, exit 0, size_audit line on stdout" {
  SMALL="$WD/.context/images/wt-test/dv-DV0-01-small.png"
  printf '%0.sx' {1..100} > "$SMALL"
  run bash "$PLUGIN_ROOT/$SCRIPT" --path "$SMALL" --worktask-id wt-test --project-root "$WD"
  assert_success
  assert_output --partial "verdict=ok"
}

@test "warn-range file (200KB<=x<500KB) -> verdict=warn, exit 0" {
  WARN_FILE="$WD/.context/images/wt-test/dv-02-warn.png"
  dd if=/dev/zero bs=1 count=250000 2>/dev/null > "$WARN_FILE"
  run bash "$PLUGIN_ROOT/$SCRIPT" --path "$WARN_FILE" --worktask-id wt-test --project-root "$WD"
  assert_success
  assert_output --partial "verdict=warn"
}

@test "oversize file (>=500KB, no pngquant) -> moved to oversize/, exit 3, .gitignore updated" {
  OVER_FILE="$WD/.context/images/wt-test/dv-DV0-03-big.png"
  dd if=/dev/zero bs=1 count=600000 2>/dev/null > "$OVER_FILE"
  run_script_env --cwd "$WD" --hide pngquant "$SCRIPT" \
    --path "$OVER_FILE" --worktask-id wt-test --project-root "$WD"
  [ "$status" -eq 3 ]
  assert_output --partial "verdict=oversize"
  [ ! -f "$OVER_FILE" ]
  [ -f "$WD/.context/images/wt-test/oversize/dv-DV0-03-big.png" ]
  grep -qxF '.context/images/*/oversize/' "$WD/.gitignore"
}

@test "slug inference strips both dv-NN- and dv-<TASK_ID>-NN- prefixes" {
  local f
  for f in dv-DV0-04-my-feature.png dv-05-my-feature.jpg; do
    printf 'x' > "$WD/.context/images/wt-test/$f"
    run bash "$PLUGIN_ROOT/$SCRIPT" --path "$WD/.context/images/wt-test/$f" --worktask-id wt-test --project-root "$WD"
    assert_success
  done
  run jq -rs '[.[] | select(.action == "screenshot_captured") | .subject] | unique | join(",")' \
    "$WD/.context/logs/audit.jsonl"
  assert_output "wt-test/my-feature"
}

@test "no --project-root and no repository owning .context -> oversize still moves, no .gitignore" {
  OVER_FILE="$WD/.context/images/wt-test/dv-DV0-06-big.png"
  dd if=/dev/zero bs=1 count=600000 2>/dev/null > "$OVER_FILE"
  run_script_env --cwd / --hide pngquant --env "GIT_CEILING_DIRECTORIES=$WD" "$SCRIPT" \
    --path "$OVER_FILE" --worktask-id wt-test
  [ "$status" -eq 3 ]
  [ -f "$WD/.context/images/wt-test/oversize/dv-DV0-06-big.png" ]
  [ ! -e "$WD/.gitignore" ]
  [ ! -e "/.gitignore" ] || [ "$(grep -c 'oversize' /.gitignore 2>/dev/null)" = "0" ]
}

@test "root: a ledger for another worktask, or no resolvable root, exits 1" {
  SMALL="$WD/.context/images/wt-test/dv-DV0-07-small.png"
  printf 'x' > "$SMALL"
  run bash "$PLUGIN_ROOT/$SCRIPT" --path "$SMALL" --worktask-id other
  [ "$status" -eq 1 ]
  local cwd
  cwd="$(mk_tmpworkdir)"
  run_script_env --cwd "$cwd" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR --unset CONTEXT_DIR \
    --env "GIT_CEILING_DIRECTORIES=$cwd" "$SCRIPT" --path "$SMALL" --worktask-id wt-test
  assert_failure 1
  [ ! -e "$cwd/.context" ]
}

@test "self-test smoke: --self-test exits 0 (NON-counting)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "passed"
}
