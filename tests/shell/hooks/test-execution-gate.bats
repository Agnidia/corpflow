#!/usr/bin/env bats
# Tests for hooks/test-execution-gate.sh — PreToolUse gate enforcing
# skills/shared/testing-strategy.md § Test-Execution Authority.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="hooks/test-execution-gate.sh"
PROMOTE="hooks/test-execution-promote.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context"
}

state_with() {
  # state_with <stage> [<stage2>] — writes .context/state.json with the given
  # stage(s) in_progress.
  local s1="$1" s2="${2:-}"
  if [ -n "$s2" ]; then
    printf '{"tasks":{"%s0":{"status":"in_progress"},"%s0":{"status":"in_progress"}}}' "$s1" "$s2" \
      > "$WD/.context/state.json"
  else
    printf '{"tasks":{"%s0":{"status":"in_progress"}}}' "$s1" > "$WD/.context/state.json"
  fi
}

bash_payload() {
  # bash_payload <command> -> JSON on stdout
  #
  # A malformed payload makes the hook fail OPEN: it emits nothing and writes
  # no audit row, which is byte-for-byte what a legitimate allow looks like.
  # Every "expected allow" case here asserts empty output, so a build failure
  # would pass as a green test. Guarding at the call sites is not enough —
  # most call this inline inside `<<< "$(bash_payload …)"`, where a non-zero
  # return is discarded by the redirection — so failures are recorded to a
  # file that teardown checks, which no subshell can swallow.
  local json payload
  json="$(jq -Rn --arg c "$1" '$c' 2>/dev/null)"
  payload="$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$json")"
  jq -e . >/dev/null 2>&1 <<< "$payload" \
    || printf 'bash_payload produced invalid JSON for: %s\n' "$1" >> "$WD/.payload-build-errors"
  printf '%s' "$payload"
}

teardown() {
  # Fails the test if any bash_payload call in it built an invalid payload.
  [ -s "$WD/.payload-build-errors" ] || return 0
  echo "--- payload build failures (a fixture may have passed vacuously) ---"
  cat "$WD/.payload-build-errors"
  return 1
}

@test "1: DV in progress + ./run-tests.sh via QA-only exemption does NOT apply -> DV full is denied (see 14); DV scoped allowed" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'tests/vendor/bats-core/bin/bats tests/shell/hooks/foo.bats')"
  assert_success
  [ -z "$output" ]
}

@test "2: QA + ./run-tests.sh -> allow (sole full-suite authority)" {
  state_with QA
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh')"
  assert_success
  [ -z "$output" ]
}

@test "3: DR + scoped bats -> deny + test_execution_blocked audit row" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'tests/vendor/bats-core/bin/bats tests/shell/hooks/foo.bats')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  run jq -e '.action == "test_execution_blocked" and .metadata.stage == "DR" and .metadata.command_head == "bats"' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "4: SR-dispatched delegate's own leaf Bash call inherits SR's banned authority -> deny (closes the delegation-path hole at the leaf, AR-1)" {
  state_with SR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'pytest tests/security/test_auth.py')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "5: no .context/state.json -> allow, no decision, no audit row (FO-4)" {
  rm -f "$WD/.context/state.json"
  # A ledgerless declared root falls through to git rank 5, so pin cwd and the ceiling to $WD;
  # otherwise a run from a live worktree reads and writes that worktree's ledger.
  run_script_env --cwd "$WD" --unset WORKSPACE_ROOT --unset CONTEXT_DIR \
    --env "CLAUDE_PROJECT_DIR=$WD" --env "GIT_CEILING_DIRECTORIES=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ -z "$output" ]
  [ ! -f "$WD/.context/logs/audit.jsonl" ]
}

@test "6: jq absent -> exit 0 silently, no decision (FO-9)" {
  state_with DR
  # The script probes for jq with `command -v jq`, so hiding jq is enough to
  # exercise the branch — no chroot and no skip. The old form set
  # PATH=/usr/bin:/bin and skipped whenever the host happened to have jq there,
  # which on most developer machines meant the branch never ran at all.
  run_script_env --hide jq --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" -- "$SCRIPT"
  assert_success
  [ -z "$output" ]
  [ ! -f "$WD/.context/logs/audit.jsonl" ]

  # Falsification pair: the identical payload with jq present is denied, so the
  # silent allow above is attributable to jq's absence and nothing else.
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "7: CORPFLOW_TEST_GATE=off -> allow even for a banned stage" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" CORPFLOW_TEST_GATE=off bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh')"
  assert_success
  [ -z "$output" ]
}

@test "8: DR + build-test --no-test -> allow (build-only carve-out, AC-6)" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload '/system-developer:build-test --no-test')"
  assert_success
  [ -z "$output" ]
}

@test "9: DR + build-test (no flag) -> deny" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload '/system-developer:build-test')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "10: two stages in_progress -> fail-open allow, no row (FO-7)" {
  state_with DR QA
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh')"
  assert_success
  [ -z "$output" ]
  [ ! -f "$WD/.context/logs/audit.jsonl" ]
}

@test "11: exit code is 0 on every path, including a deny" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'bats foo.bats')"
  [ "$status" -eq 0 ]
}

@test "12: audit.jsonl records command_head only, never the full command" {
  state_with SR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'bats /secret/leak/path.bats -f token-abc123')"
  assert_success
  run jq -e '.metadata.command_head == "bats" and (.metadata.command_head | test("secret|token-abc123") | not)' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
  run jq -e '(.metadata | has("command")) | not' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "13: Agent carrying the literal ban text -> allow + test_delegation_observed, NEVER a deny (AR-2 deadlock guard)" {
  state_with DR
  local payload='{"tool_name":"Agent","tool_input":{"subagent_type":"corpflow:developer","prompt":"DO NOT execute tests: bats, pytest, cargo test are forbidden outside DV/QA"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  [ -z "$output" ]
  refute_output --partial "deny"
  run jq -e '.action == "test_delegation_observed"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "14: DV + ./run-tests.sh -> deny (AR-3, mechanical half of AC-2 — DV never reaches full-suite)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  run jq -e '.metadata.stage == "DV" and .metadata.class == "full_test_run"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "14a: DV + ./run-tests.sh --changed -> allow (bare still denies, per 14)" {
  # The arm used to ignore arguments, so the one feature built for DV was denied
  # to DV. Bare stays full_test_run (test 14) — only the argument form moves.
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh --changed')"
  assert_success
  [ -z "$output" ] || fail "DV was denied its own scoped selection: $output"
}

@test "14b: --changed classifies scoped_test_run, not merely not_test" {
  # An allowed run at DV writes no audit row, so "allow" alone cannot tell a
  # correct scoped classification from the arm falling through to not_test.
  # DR denies scoped and records the class, which makes the difference visible.
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh --changed')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  run jq -e '.metadata.class == "scoped_test_run"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "14c: --base <ref> also classifies scoped, and the ref is not read as a command" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh --base master --changed')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  run jq -e '.metadata.class == "scoped_test_run"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "14e: --print-selection is build_only — allowed even where scoped is denied" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh --changed --print-selection')"
  assert_success
  [ -z "$output" ] || fail "--print-selection runs nothing and must never deny: $output"
}

@test "14d: QA + ./run-tests.sh --changed -> still allowed (QA is not narrowed)" {
  state_with QA
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh --changed')"
  assert_success
  [ -z "$output" ]
}

@test "15: non-test Bash (git status) under a banned stage -> allow, no audit row (fast-path guard)" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'git status')"
  assert_success
  [ -z "$output" ]
  [ ! -f "$WD/.context/logs/audit.jsonl" ]
}

@test "contract: --self-test passes" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "self-test OK"
}

@test "edge: unknown tool_name is out of scope -> allow, no row (FO-10 matcher drift)" {
  state_with DR
  local payload='{"tool_name":"Read","tool_input":{"file_path":"foo.txt"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  [ -z "$output" ]
  [ ! -f "$WD/.context/logs/audit.jsonl" ]
}

@test "edge: mcp__*__test_* tool under a banned stage -> deny (B9 matcher widening)" {
  state_with DR
  local payload='{"tool_name":"mcp__XcodeBuildMCP__test_sim","tool_input":{}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

# --- DR remediation regression scenarios (developer-review-1.md P1-1..P1-4) ---

@test "P1-1: Agent dispatch with NO .context/ at all -> zero filesystem side effects, no observe row" {
  rm -rf "$WD/.context"   # simulate a third-party repo with no worktask in flight
  local payload='{"tool_name":"Agent","tool_input":{"subagent_type":"corpflow:developer","prompt":"go ahead and make the change to the algorithm"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  [ -z "$output" ]
  [ ! -d "$WD/.context" ]
}

@test "P1-1: word-boundary token match — 'algorithm' does not trip the observe row (bare substring 'go' inside it)" {
  state_with DR
  local payload='{"tool_name":"Agent","tool_input":{"subagent_type":"corpflow:developer","prompt":"refine the sorting algorithm and category logic"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  [ -z "$output" ]
  [ ! -f "$WD/.context/logs/audit.jsonl" ]
}

@test "P1-2: pure build command on a multi-purpose runner ALLOWS at a banned stage (AC-6) — ./gradlew assembleDebug" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './gradlew assembleDebug')"
  assert_success
  [ -z "$output" ]
}

@test "P1-2: pure script execution on python3 ALLOWS at a banned stage (AC-6) — coverage_report.py" {
  state_with SR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'python3 tools/coverage_report.py')"
  assert_success
  [ -z "$output" ]
}

@test "P1-3: leading secret env assignment never reaches command_head in the audit row" {
  state_with SR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'API_KEY=sk-test-xyz pytest tests/')"
  assert_success
  run jq -e '.metadata.command_head == "pytest" and (.metadata.command_head | test("sk-test-xyz|API_KEY") | not)' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "P1-4: 'swift test -c release' still classifies as a test run (deny at DR, not build_only)" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'swift test -c release')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "P1-4: 'swift test -c release' at DV still hits the AR-3 full-suite deny (bare -c is not a selection arg)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'swift test -c release')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "P2-13: '--list' does not over-match '--listener'" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'bats --listener foo.bats')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

# --- DR Round 2 regression scenarios (developer-review-1.md § Round 2) ---

@test "N1: 'xcodebuild test -scheme X' denies at a banned stage (prefilter previously omitted xcodebuild)" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'xcodebuild test -scheme X')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "N1 sibling: 'xcodebuild archive -scheme X' (no test subcommand) still allows" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'xcodebuild archive -scheme X')"
  assert_success
  [ -z "$output" ]
}

@test "N4: 'npm run test' (package.json-script form) denies at a banned stage" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'npm run test')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "N4 sibling: 'npm run lint' (non-test script) still allows" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'npm run lint')"
  assert_success
  [ -z "$output" ]
}

# --- SR Round 4 regression scenarios (security-review-1.md) ---

@test "SR-H1: 'swift build --build-tests' (compile-tests-without-running) ALLOWS at DV (was falsely denied)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'swift build --build-tests')"
  assert_success
  [ -z "$output" ]
}

@test "SR-H1: 'cat docs/build-test.md' ALLOWS at a banned stage (unanchored substring fixed)" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'cat docs/build-test.md')"
  assert_success
  [ -z "$output" ]
}

@test "SR-H1 non-regression: '/system-developer:build-test' (no flag) still DENIES at a banned stage" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload '/system-developer:build-test')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "SR-H1 non-regression: '/system-developer:build-test --no-test' still ALLOWS (build-only carve-out intact)" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload '/system-developer:build-test --no-test')"
  assert_success
  [ -z "$output" ]
}

@test "RK4 structural item 1: CORPFLOW_TEST_GATE=off writes ONE test_gate_disabled row, not one per call" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" CORPFLOW_TEST_GATE=off bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'bats foo.bats')"
  assert_success
  run env CLAUDE_PROJECT_DIR="$WD" CORPFLOW_TEST_GATE=off bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'pytest tests/')"
  assert_success
  run jq -e '.action == "test_gate_disabled" and .metadata.vector == "CORPFLOW_TEST_GATE"' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
  local row_count
  row_count="$(grep -c 'test_gate_disabled' "$WD/.context/logs/audit.jsonl")"
  [ "$row_count" -eq 1 ]
}

@test "SR-M1: build-only collection/compile-without-run forms allow at a banned stage" {
  state_with DR
  for cmd in 'cargo test --no-run' 'ctest -N' 'ctest --show-only' 'npx jest --listTests' 'pytest --co'; do
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
    assert_success
    [ -z "$output" ] || fail "expected allow for: $cmd (got: $output)"
  done
}

@test "SR item 3: gradle pure-build task prefixes (install/assemble/compile) allow despite containing 'test'" {
  state_with DR
  for cmd in './gradlew installDebugAndroidTest' './gradlew assembleAndroidTest' './gradlew compileDebugUnitTestKotlin'; do
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
    assert_success
    [ -z "$output" ] || fail "expected allow for: $cmd (got: $output)"
  done
}

@test "SR-M2: quoted env-value with a space no longer defeats classification (deny direction)" {
  state_with SR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'FOO="a b" pytest tests/')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "SR-M2: quoted env-value with a space no longer produces a false deny (allow direction)" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'MSG="see pytest docs" ls -la')"
  assert_success
  [ -z "$output" ]
}

@test "SR2-H1: command_head is redacted, never a secret fragment, across ;/&&/||/pipe/newline shapes" {
  state_with SR
  local cmds=(
    'PYTEST_ADDOPTS="--token ghp_LEAKME123"; pytest tests/'
    'GIT_ASKPASS="echo hunter2" && bats tests/a.bats'
    'true | pytest tests/'
  )
  for cmd in "${cmds[@]}"; do
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
    assert_success
  done
  # Newline-separated: the realistic self-inflicted shape (a multi-line Bash tool_input.command).
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$(printf 'SECRET=hunter2\npytest tests/')")"
  assert_success
  run bash -c "grep -c 'command_head\":\"redacted\"' '$WD/.context/logs/audit.jsonl'"
  local redacted_count="$output"
  [ "$redacted_count" -ge 4 ]
  run bash -c "grep -i 'hunter2\|ghp_LEAKME123' '$WD/.context/logs/audit.jsonl'"
  assert_failure
}

@test "SR2-H2: classify_segment recursion is capped — 'bash -c \"bash -c pytest\"' does not chase two levels into a deny" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'bash -c '"'"'bash -c "pytest tests/"'"'"'')"
  assert_success
  [ -z "$output" ]
}

@test "doc-honesty bypass fix: time/nohup/command/exec wrappers now classify on the real runner (deny direction)" {
  state_with DR
  for cmd in 'time pytest tests/' 'nohup pytest tests/' 'command bats foo.bats' 'exec pytest tests/'; do
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' \
      || fail "expected deny for: $cmd"
  done
}

@test "R4: timeout/gtimeout, subshell parentheses and ksh -c classify on the real runner (deny)" {
  state_with DR
  local cmd
  for cmd in 'timeout 60 bats x' 'timeout -s KILL 5m pytest' 'timeout --signal=KILL 5 pytest' \
    'timeout -k 5 60 pytest' 'gtimeout --preserve-status 60 pytest' '(pytest tests/)' \
    '(cd r && bats t)' "ksh -c 'pytest'" '(CI=1 pytest tests/)' 'timeout 600 env CI=1 pytest'; do
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null \
      || fail "expected deny for: $cmd (got: $output)"
  done
}

@test "R4: a timeout-wrapped or subshelled non-runner stays allowed" {
  state_with DR
  local cmd
  for cmd in 'timeout 5 ls' '(cd r && ls)' 'timeout' 'gtimeout -k 1 2 git status'; do
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
    assert_success
    [ -z "$output" ] || fail "expected allow for: $cmd (got: $output)"
  done
}

@test "R4: 20k leading parens before pytest still deny, well inside the hook timeout" {
  state_with DR
  local parens start elapsed
  parens="$(head -c 20000 /dev/zero | tr '\0' '(')"
  start="$(date +%s)"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "${parens}pytest tests/")"
  elapsed=$(($(date +%s) - start))
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null || fail "got: $output"
  [ "$elapsed" -le 3 ] || fail "took ${elapsed}s"
}

@test "bare &: a backgrounded segment splits in the classifier too" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'true & pytest tests/')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null || fail "got: $output"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'pytest tests/ 2>&1 | tee log')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null || fail "got: $output"
}

# portability-lint disable=P005 — prose naming the |& form under test, not bash syntax
@test "bare &: redirect forms >&, <&, &> and |& are not split and stay allowed" {
  state_with DR
  local cmd
  # portability-lint disable=P005 — literal fixture data fed to the script under test
  for cmd in 'ls 2>&1' 'ls >&2' 'ls &>/dev/null' 'ls &>>log' 'ls <&3' 'ls |& cat' 'true & ls'; do
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
    assert_success
    [ -z "$output" ] || fail "expected allow for: $cmd (got: $output)"
  done
  run bash -c ". '$PLUGIN_ROOT/$SCRIPT' --lib-only; classify_cmd 'pytest tests/ 2>&1'"
  assert_output "scoped_test_run"
}

# classify_split <command> -> classify_cmd's verdict for a literal command string.
classify_split() {
  run bash -c '. "$1" --lib-only; classify_cmd "$2"' _ "$PLUGIN_ROOT/$SCRIPT" "$1"
  assert_success
}

# portability-lint disable=P005 — prose naming the | separator under test, not bash syntax
@test "quote-aware split: a grep whose double-quoted pattern holds 'swift test' between pipes is not a test run" {
  # The live false positive (benchmark run 3 DV, call 18): the quoted pipes cut
  # the grep pattern into a segment that began with the runner.
  classify_split 'grep "swiftpm|swift test|--filter" f; swift build'
  assert_output "not_test"

  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'grep "a|swift test|b" f; swift build')"
  assert_success
  [ -z "$output" ] || fail "expected allow, got: $output"
}

@test "quote-aware split: a quoted \"swift test\" inside an echo is not a runner" {
  classify_split 'echo "swift test"'
  assert_output "not_test"
  classify_split "echo 'swift test'"
  assert_output "not_test"
  classify_split 'echo "run swift test; then pytest tests/" && ls'
  assert_output "not_test"
}

@test "quote-aware split: an unquoted runner after a separator is still classified" {
  classify_split 'echo "a;b"; swift test'
  assert_output "full_test_run"
  classify_split 'echo "x" && swift test'
  assert_output "full_test_run"
  classify_split "echo 'x|y' | swift test"
  assert_output "full_test_run"
  classify_split 'echo x | swift test'
  assert_output "full_test_run"
  classify_split 'grep "a|b" f
swift test'
  assert_output "full_test_run"

  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'grep "a|swift test|b" f; swift test')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null || fail "got: $output"
}

@test "quote-aware split: single quotes hold every separator literally" {
  classify_split "grep 'a|swift test|b' f; swift build"
  assert_output "not_test"
  classify_split "grep 'a;swift test&&b' f || swift build"
  assert_output "not_test"
  # A double quote inside single quotes opens nothing.
  classify_split "echo 'say \"hi' | swift test"
  assert_output "full_test_run"
}

@test "quote-aware split: a backslash-escaped separator does not split" {
  classify_split 'grep a\|swift\ test\|b f; swift build'
  assert_output "not_test"
  classify_split 'echo a\;swift test'
  assert_output "not_test"
  # An escaped quote does not open a string, so the real separator after it splits.
  classify_split 'echo \" | swift test'
  assert_output "full_test_run"
  # An escaped quote inside double quotes does not close the string.
  classify_split 'echo "a\" | swift test"'
  assert_output "not_test"
}

@test "quote-aware split: an unterminated quote falls back to the blind split and still denies" {
  classify_split 'echo "oops | swift test'
  assert_output "full_test_run"
  classify_split "echo 'oops; swift test"
  assert_output "full_test_run"
}

# The apostrophe in the body leaves a quote open for _gate_split_segments, which forces the
# blind legacy split: that is the path these cases pin.
@test "legacy split here-doc: a runner only inside the body is data, not a test run" {
  classify_split "$(printf '%s\n' "cat > log <<'EOF'" "it's a note" 'swift test' 'EOF')"
  assert_output "not_test"
  # `<<-` strips leading tabs, and a comment after the operator does not end the line early.
  classify_split "$(printf '%s\n' 'cat > log <<-EOF # notes' "it's" '	swift test' '	EOF' 'echo done')"
  assert_output "not_test"

  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$(printf '%s\n' \
    "cat > log <<'EOF'" "it's a note" 'swift test' 'EOF' 'swift build')")"
  assert_success
  [ -z "$output" ] || fail "expected allow, got: $output"
}

@test "legacy split here-doc: a runner after the terminator is still a test run" {
  classify_split "$(printf '%s\n' "cat > log <<'EOF'" "it's a note" 'EOF' 'swift test')"
  assert_output "full_test_run"
  classify_split "$(printf '%s\n' "cat > log <<'EOF' && swift test" "it's a note" 'EOF')"
  assert_output "full_test_run"
}

@test "legacy split here-doc: any doubt in the scan keeps the blind split, which denies" {
  # Unterminated body; an escaped delimiter; a continued operator line; a numeric word.
  classify_split "$(printf '%s\n' "cat > log <<'EOF'" "it's" 'swift test')"
  assert_output "full_test_run"
  classify_split "$(printf '%s\n' 'cat > log <<\EOF' "it's" 'swift test' 'EOF')"
  assert_output "full_test_run"
  classify_split "$(printf '%s\n' 'cat > log <<EOF \' "it's" 'swift test' 'EOF')"
  assert_output "full_test_run"
  classify_split "$(printf '%s\n' 'echo $((1<<2))' "it's" 'swift test' '2')"
  assert_output "full_test_run"
  # A `<<` in a comment opens nothing, so the runner line stays a command.
  classify_split "$(printf '%s\n' 'echo hi # see <<EOF' "it's" 'swift test' 'EOF')"
  assert_output "full_test_run"
}

@test "legacy split here-doc: an 8000-line body is stripped in one linear pass" {
  # Structural first: 2 segments prove the strip ran rather than aborting into one segment per
  # line. The ceiling is loose on purpose: a scan that copies the rest of the string per line
  # needs tens of seconds at this size, a linear one well under one.
  run /bin/bash -c '. "$1" --lib-only
    body=$(awk "BEGIN { for (i = 1; i <= 8000; i++) printf \"line %d data payload xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n\", i }")
    cmd=$(printf "cat > f <<\047EOF\047\nit\047s\n%s\nEOF\nswift test" "$body")
    SECONDS=0
    _gate_split_legacy "$cmd"
    printf "segs=%s last=%s secs=%s\n" "${#GATE_SEGS[@]}" "${GATE_SEGS[${#GATE_SEGS[@]}-1]}" "$SECONDS"' \
    _ "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output --regexp '^segs=2 last=swift test secs=[0-9]+$'
  [ "${output##*secs=}" -lt 15 ] || fail "legacy split took ${output##*secs=}s on 8000 lines: $output"
}

@test "quote-aware split: bash -c chases a runner after a separator inside its own string" {
  classify_split "bash -c 'echo x | swift test'"
  assert_output "full_test_run"
  classify_split "bash -c 'grep \"a|swift test\" f'"
  assert_output "not_test"
}

@test "doc-honesty bypass fix: 'bash -lc' combined short option is now chased" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "bash -lc 'pytest tests/'")"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "SR info item: a symlinked audit.jsonl is refused, never written through" {
  state_with DR
  mkdir -p "$WD/.context/logs" "$WD/target-dir"
  ln -s "$WD/target-dir/escaped.txt" "$WD/.context/logs/audit.jsonl"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'bats foo.bats')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  [ ! -e "$WD/target-dir/escaped.txt" ]
}

@test "SR2-M1: the Skill branch redacts command_head the same as the Bash branch (no secret leak via build-test flags)" {
  state_with DR
  local payload='{"tool_name":"Skill","tool_input":{"command":"/system-developer:build-test --token sk-live-9x8y --scheme App"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  run jq -e '.metadata.command_head == "redacted"' "$WD/.context/logs/audit.jsonl"
  assert_success
  run bash -c "grep -i 'sk-live-9x8y' '$WD/.context/logs/audit.jsonl'"
  assert_failure
}

# --- DR Round 3 regression scenarios (developer-review-1.md § Round 3) ---

@test "R3-1: Skill payload in its real {skill,args} shape — '--no-test' in args ALLOWS at DR (build-only carve-out)" {
  state_with DR
  local payload='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test","args":"--no-test"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  [ -z "$output" ]
}

@test "R3-1: same {skill,args} shape WITHOUT --no-test -> deny at DR" {
  state_with DR
  local payload='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test","args":"--scheme App"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "R3-1: {skill,args} with no args field at all -> deny (bare build-test is a full run)" {
  state_with DR
  local payload='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "R3-1: args-carried secret never reaches command_head (redaction survives the recombination)" {
  state_with DR
  local payload='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test","args":"--token sk-live-9x8y"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  run jq -e '.metadata.command_head == "redacted"' "$WD/.context/logs/audit.jsonl"
  assert_success
  run bash -c "grep -i 'sk-live-9x8y' '$WD/.context/logs/audit.jsonl'"
  assert_failure
}

@test "R3-4: a MISSING dedupe library degrades suppression only — the Skill arm still denies at DR" {
  # The claim the gate's header makes. If the classifier reached into the
  # suppression library, its absence would allow a full-suite Skill outright.
  state_with DR
  mkdir -p "$WD/hooks"
  cp "$PLUGIN_ROOT/$SCRIPT" "$WD/hooks/"
  cp "$PLUGIN_ROOT/hooks/model-switch-lib.sh" "$WD/hooks/"
  mkdir -p "$WD/hooks/lib" && cp "$PLUGIN_ROOT/hooks/lib/command-head-lib.sh" "$WD/hooks/lib/"
  [ ! -e "$WD/hooks/lib/dedupe-lib.sh" ]

  local payload='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$WD/hooks/test-execution-gate.sh" <<< "$payload"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  refute_output --partial "command not found"
}

@test "R3-4: a MISSING dedupe library leaves an allowed run silent (no unbound-symbol noise)" {
  state_with QA
  mkdir -p "$WD/hooks"
  cp "$PLUGIN_ROOT/$SCRIPT" "$WD/hooks/"
  cp "$PLUGIN_ROOT/hooks/model-switch-lib.sh" "$WD/hooks/"
  mkdir -p "$WD/hooks/lib" && cp "$PLUGIN_ROOT/hooks/lib/command-head-lib.sh" "$WD/hooks/lib/"

  run env CLAUDE_PROJECT_DIR="$WD" bash "$WD/hooks/test-execution-gate.sh" \
    <<< "$(bash_payload './run-tests.sh')"
  assert_success
  [ -z "$output" ]
}

@test "R3-4: a MISSING command-head library degrades the strip, announced, and quoted values still deny" {
  # Deleting one file must not become an off-switch outside the CORPFLOW_TEST_GATE hatch: a
  # leading assignment, quoted or bare, is what hides the runner from the prefilter.
  state_with SR
  mkdir -p "$WD/hooks"
  cp "$PLUGIN_ROOT/$SCRIPT" "$WD/hooks/"
  cp "$PLUGIN_ROOT/hooks/model-switch-lib.sh" "$WD/hooks/"
  [ ! -e "$WD/hooks/lib/command-head-lib.sh" ]
  local cmd
  for cmd in 'API_KEY=sk-x bats tests/shell' 'FOO="a b" bats tests/shell' "FOO='a b' pytest"; do
    run --separate-stderr env CLAUDE_PROJECT_DIR="$WD" bash "$WD/hooks/test-execution-gate.sh" \
      <<< "$(bash_payload "$cmd")"
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null \
      || fail "fallback allowed: $cmd"
    [[ "$stderr" == *"assignment strip degraded"* ]] || fail "no degradation notice for: $cmd"
    [[ "$stderr" != *"command not found"* ]] || fail "unbound strip for: $cmd"
  done
  [ -f "$WD/.context/logs/.corpflow-lib-missing" ]
}

@test "R3-4: an inherited include guard cannot suppress the library" {
  state_with SR
  local cmd
  for cmd in 'FOO="a b" bats tests/shell' "FOO='a b' pytest"; do
    run --separate-stderr env CLAUDE_PROJECT_DIR="$WD" _CORPFLOW_CMDHEAD_LIB=1 bash "$PLUGIN_ROOT/$SCRIPT" \
      <<< "$(bash_payload "$cmd")"
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null \
      || fail "inherited guard allowed: $cmd"
    [[ "$stderr" != *"degraded"* ]] || fail "the real library did not load for: $cmd"
  done
}

@test "R3-4: the inline strip fallback answers exactly as the library does" {
  mkdir -p "$WD/hooks"
  cp "$PLUGIN_ROOT/$SCRIPT" "$WD/hooks/"
  cp "$PLUGIN_ROOT/hooks/model-switch-lib.sh" "$WD/hooks/"
  local inp lib fb
  for inp in 'FOO="a b" bats tests/shell' "FOO='a b' pytest" 'env A=1 B="x y" jest -t z' \
    'X=1 Y=2' 'pytest -k x' "$(printf 'A=1 go test\nB=2 pytest')" 'K="unterminated pytest'; do
    lib=$(IN="$inp" bash -c ". '$PLUGIN_ROOT/hooks/lib/command-head-lib.sh'; strip_assignments \"\$IN\"")
    fb=$(cd "$WD/hooks" && IN="$inp" bash -c '. ./test-execution-gate.sh --lib-only
      [ "$CMDHEAD_FALLBACK" = 1 ] || exit 9
      strip_assignments "$IN"')
    [ "$lib" = "$fb" ] || fail "fallback '$fb' != library '$lib' for input: $inp"
  done
}

@test "R3-2: 'make test' and 'make test-ios' deny at DR (both were dropped by the zero-fork prefilter)" {
  state_with DR
  for cmd in 'make test' 'make test-ios'; do
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' \
      || fail "expected deny for: $cmd"
  done
}

@test "R3-2: 'make test' at DV hits the full-suite deny (a named full runner, never scoped)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'make test')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  run jq -e '.metadata.class == "full_test_run" and .metadata.command_head == "make"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "R3-2 sibling: 'make build' still allows at DR (the widened prefilter did not swallow every make target)" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'make build')"
  assert_success
  [ -z "$output" ]
  [ ! -f "$WD/.context/logs/audit.jsonl" ]
}

@test "R3-3: xcodebuild's action AFTER its options is a test run -> deny at DR (was read as _subcmd='-scheme')" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'xcodebuild -scheme MyApp -destination generic/platform=iOS test')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "R3-3: trailing-action and action-first xcodebuild shapes classify IDENTICALLY" {
  state_with DR
  for cmd in 'xcodebuild test -scheme MyApp' 'xcodebuild -scheme MyApp test'; do
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
    assert_success
  done
  # Order-invariance is what this asserts; `-scheme MyApp` is non-selecting, so
  # the shared class is full_test_run. Deny at DR is unchanged either way.
  run jq -s -e 'map(.metadata.class) | unique | length == 1 and .[0] == "full_test_run"' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "R3-3: 'xcodebuild test-without-building' (executes a prebuilt bundle) -> deny at DR" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'xcodebuild -scheme MyApp test-without-building')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "R3-3: '-only-testing:' selection still classifies scoped, not full" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'xcodebuild -scheme MyApp -only-testing:MyAppTests/LoginTests test')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  run jq -e '.metadata.class == "scoped_test_run"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "R3-3 siblings: non-executing xcodebuild actions still ALLOW at DR (word-exact action match)" {
  state_with DR
  # `build-for-testing` compiles a test bundle without running it; `-scheme
  # MyTests` must not read as the `test` action on a substring match.
  for cmd in 'xcodebuild -scheme MyApp build' 'xcodebuild archive -scheme X' 'xcodebuild -scheme MyApp build-for-testing' 'xcodebuild -scheme MyTests build'; do
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
    assert_success
    [ -z "$output" ] || fail "expected allow for: $cmd (got: $output)"
  done
}

@test "SR2-L2: CORPFLOW_TEST_GATE=off with NO .context/ at all creates nothing (no test_gate_disabled pollution)" {
  rm -rf "$WD/.context"
  run env CLAUDE_PROJECT_DIR="$WD" CORPFLOW_TEST_GATE=off bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'bats foo.bats')"
  assert_success
  [ -z "$output" ]
  [ ! -d "$WD/.context" ]
}

# --- R1/R2: non-selecting runner flags no longer read as scoping ---

@test "R1-1: multi-flag 'xcodebuild test' denies at DV (every executable invocation carries flags)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'xcodebuild test -project a.xcodeproj -scheme overlay -destination generic/platform=iOS')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  run jq -e '.metadata.class == "full_test_run" and .metadata.command_head == "xcodebuild"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "R1-2: '-only-testing:' keeps a scoped xcodebuild run ALLOWED at DV (the over-deny direction)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'xcodebuild test -project a.xcodeproj -scheme s -only-testing:UnitTests/LogTests')"
  assert_success
  [ -z "$output" ]
}

@test "R1-3: QA remains the sole full-suite authority for the same multi-flag command" {
  state_with QA
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'xcodebuild test -project a.xcodeproj -scheme s -destination d')"
  assert_success
  [ -z "$output" ]
}

@test "R1-4: 'xcodebuild build' with the same flags still ALLOWS at DV (not test execution)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'xcodebuild build -project a.xcodeproj -scheme s')"
  assert_success
  [ -z "$output" ]
}

@test "R1-5: 'gradle test -p .' denies at DV (project-dir is not a selector)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'gradle test -p .')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "R1-6: 'dotnet test MySolution.sln' denies at DV (the solution positional names what to build)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'dotnet test MySolution.sln')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "R1-7: 'npm test -- --ci' denies at DV (the separator is not an argument)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'npm test -- --ci')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "R2-1: 'cargo test --release' denies at DV (a build configuration is not a selection)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'cargo test --release')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "R2-2: 'cargo test --release foo' still ALLOWS at DV (a real selector survives the strip)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'cargo test --release foo')"
  assert_success
  [ -z "$output" ]
}

@test "R1-8: a value-consuming flag missing its value must not swallow the token that follows" {
  # The surviving token must NOT be in the explicit selector list: that limb
  # matches on the whole segment BEFORE the strip runs, so an `-only-testing:`
  # case here passes with the guard deleted and proves nothing. `-MyScheme`
  # reaches the strip, and this case flips to a deny when the guard is removed.
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'xcodebuild test -project a -scheme -MyScheme')"
  assert_success
  [ -z "$output" ]
}

@test "R1-8 companion: '-only-testing:' after a valueless flag also allows (decided by the selector limb, not the guard)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'xcodebuild test -scheme -only-testing:UnitTests/LogTests')"
  assert_success
  [ -z "$output" ]
}

@test "R1-9: 'go test ./...' is UNCHANGED by the strip (whole-tree positionals stay a policy limit)" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'go test ./...')"
  assert_success
  [ -z "$output" ]
}

@test "R9: FN has no test-execution authority -> deny" {
  # Passes the day it is written: the stage limb already denies every stage but
  # DV/QA. Kept as a parity lock so a later edit to that limb cannot quietly
  # drop the row — not a bug catch, so do not delete it as a never-failing test.
  state_with FN
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'swift test')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  run jq -e '.metadata.stage == "FN"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

# --- P1-2: quoted multi-word flag values are ONE token ---

@test "R1-10: a simulator destination denies at DV in all three quoting forms" {
  # A destination containing a space is the NORMAL shape for an iOS project and
  # is what the reported incident actually passed; before the tokenizer only the
  # space-free forms denied, so the fix missed its own motivating case.
  state_with DV
  local base='xcodebuild test -project a.xcodeproj -scheme overlay -destination '
  local cmd
  for dest in 'generic/platform=iOS' '"platform=iOS Simulator,name=iPhone 16 Pro"' "'platform=iOS Simulator,name=iPhone 16 Pro'"; do
    rm -f "$WD/.context/logs/audit.jsonl"
    cmd="${base}${dest}"
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' \
      || fail "expected deny for: $cmd"
  done
}

@test "R1-11: 'dotnet test \"My Solution.sln\"' denies (a quoted solution positional is still non-selecting)" {
  state_with DV
  local cmd='dotnet test "My Solution.sln"'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "R1-12: a quoted destination PLUS a real selector still ALLOWS at DV" {
  state_with DV
  local cmd='xcodebuild test -project a -scheme overlay -destination "platform=iOS Simulator,name=iPhone 16 Pro" -only-testing:UnitTests/LogTests'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
  assert_success
  [ -z "$output" ]
}

@test "R1-13: an unterminated quote strips nothing and ALLOWS (ambiguous parse degrades to today's behaviour)" {
  state_with DV
  local cmd='xcodebuild test -project a -scheme overlay -destination "platform=iOS Simulator'
  local payload
  payload="$(bash_payload "$cmd")"
  [ -n "$payload" ]
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  [ -z "$output" ]
}

# --- P1-A: `-c` is value-taking on some runners and valueless on others ---

@test "R1-14: 'go test -c' compiles and runs nothing -> ALLOWS at DV and at a banned stage" {
  # Go's -c is valueless; the shared value-consuming strip ate the following
  # token (or ran off the end of the line) and denied a compile as a full run.
  for stage in DV DR; do
    state_with "$stage"
    for cmd in 'go test -c' 'go test -c ./pkg'; do
      run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
      assert_success
      [ -z "$output" ] || fail "expected allow at $stage for: $cmd (got: $output)"
    done
  done
}

@test "R1-15: rspec's '-c' is --colour, not a config path -> the spec file still selects" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'rspec -c spec/models/user_spec.rb')"
  assert_success
  [ -z "$output" ]
}

@test "R1-16: value-taking '-c' runners are unaffected — the value is still consumed" {
  state_with DV
  for cmd in 'swift test -c release' 'dotnet test -c Release' 'go test' 'rspec'; do
    rm -f "$WD/.context/logs/audit.jsonl"
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' \
      || fail "expected deny for: $cmd"
  done
}

@test "R1-17: gradle's task is found order-independently — flags-before-task denies the same" {
  # A first-token read saw `-p` here, mistook the project dir for a surviving
  # positional, and let the full run through as scoped.
  state_with DV
  for cmd in 'gradle -p . test' './gradlew -p app testDebugUnitTest'; do
    rm -f "$WD/.context/logs/audit.jsonl"
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$cmd")"
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' \
      || fail "expected deny for: $cmd"
  done
  # The over-deny guard: a real selector still allows in the same shape.
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'gradle -p . test --tests com.foo.Bar')"
  assert_success
  [ -z "$output" ]
}

# --- flag values and redirects are not selectors (DV full-suite deny) ---
#
# A value-taking configuration flag's value, or a redirect, used to survive
# strip_nonselecting_flags as a "positional", so a bare full run read as scoped
# and DV was allowed the full suite. These pin each hole and the scoped shapes
# that must stay scoped.

# gate_verdict_at_dv <command> -> sets VERDICT to deny|allow for DV in progress.
gate_verdict_at_dv() {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$1")"
  assert_success
  if [ -z "$output" ]; then
    VERDICT=allow
  else
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null \
      || fail "unexpected gate output for: $1 (got: $output)"
    VERDICT=deny
  fi
}

assert_dv_denied() {
  local cmd
  for cmd in "$@"; do
    gate_verdict_at_dv "$cmd"
    [ "$VERDICT" = deny ] || fail "expected deny at DV for: $cmd"
  done
}

assert_dv_allowed() {
  local cmd
  for cmd in "$@"; do
    gate_verdict_at_dv "$cmd"
    [ "$VERDICT" = allow ] || fail "expected allow at DV for: $cmd"
  done
}

@test "flag-value hole: 'swift test --package-path <abs>' is a full run, denied at DV" {
  assert_dv_denied 'swift test --package-path /abs/pkg' 'swift test --package-path=/abs/pkg'
}

@test "flag-value hole: every value-taking swift config flag and its value is non-selecting" {
  assert_dv_denied \
    'swift test --scratch-path /s' \
    'swift test --build-path /b' \
    'swift test -c release' \
    'swift test --configuration release' \
    'swift test -j 4' \
    'swift test --jobs 4' \
    'swift test -Xswiftc -warnings-as-errors' \
    'swift test --parallel' \
    'swift test --package-path /p --scratch-path /s -c release -j 4 --parallel -Xswiftc -DX'
}

@test "redirect hole: 'swift test 2>&1' with no --filter is a full run, denied at DV" {
  assert_dv_denied 'swift test 2>&1'
}

@test "redirect hole: every redirect spelling is dropped before counting selectors" {
  # portability-lint disable=P005 — literal fixture data fed to the script under test
  assert_dv_denied 'swift test 2>/dev/null' 'swift test >out.log' 'swift test > out.log' \
    'swift test 2> err.log' 'swift test &>f' 'swift test >>f' 'swift test >> f' 'swift test >&2' \
    'swift test </dev/null' 'swift test --package-path /p 2>&1 >out.log'
}

@test "redirect hole: dropping a redirect leaves a real selector standing" {
  # Redirect stripping must not over-reach into the surviving --filter.
  assert_dv_allowed 'swift test --filter X 2>&1'
  assert_dv_allowed 'swift test 2>&1 --filter X'
}

@test "kept bare: 'swift test' and 'swift test | tee x.log' stay denied at DV" {
  assert_dv_denied 'swift test' 'swift test | tee x.log'
}

@test "kept scoped: swift --filter survives every config flag and redirect" {
  assert_dv_allowed \
    'swift test --filter X --package-path P' \
    'swift test --package-path P --filter X' \
    "swift test --filter 'A|B' 2>&1 | tee log" \
    'swift test --filter X -c release -j 4 --parallel' \
    'swift test --filter X >out.log 2>&1' \
    'swift test Foo.BarTests --package-path P'
}

@test "kept scoped: a selector-valued swift flag after -Xswiftc is not swallowed" {
  # -Xswiftc consumes exactly one value, so the positional after it still selects.
  assert_dv_allowed 'swift test -Xswiftc -warnings-as-errors Foo.BarTests'
}

@test "xcodebuild: a redirect or a KEY=VALUE build setting is not a selector" {
  assert_dv_denied \
    'xcodebuild test -scheme A 2>&1' \
    'xcodebuild test -scheme A CODE_SIGNING_ALLOWED=NO' \
    'xcodebuild test -scheme A -enableCodeCoverage YES -jobs 4'
  assert_dv_allowed \
    'xcodebuild test -scheme A -only-testing:T/C CODE_SIGNING_ALLOWED=NO 2>&1'
}

@test "pytest: config flag values and redirects are not selectors; a path or -m still is" {
  assert_dv_denied 'pytest 2>&1' 'pytest -q' 'pytest --rootdir /x -n auto' 'pytest --tb short 2>&1' \
    'python -m pytest --maxfail 1'
  assert_dv_allowed 'pytest -n 4 tests/foo.py' 'pytest -m slow' 'pytest -k foo --rootdir /x' \
    'pytest tests/foo.py 2>&1'
}

@test "npm test / jest: config flag values and redirects are not selectors; a path still is" {
  assert_dv_denied 'jest --ci 2>&1' 'jest --maxWorkers 2 --coverage' 'npm test -- --ci --maxWorkers 2' \
    'npm test 2>&1' 'vitest run'
  assert_dv_allowed 'jest src/a.test.js --ci' 'npm test -- src/a' 'vitest run src/a.test.ts' \
    'jest -t foo --maxWorkers 2'
}

@test "go test: a numeric or duration flag value is not a selector; a package pattern still is" {
  assert_dv_denied 'go test -count 1' 'go test -count=1 -timeout 30s' 'go test -v' 'go test 2>&1'
  assert_dv_allowed 'go test ./...' 'go test -count 1 ./pkg' 'go test -run TestX -count 1'
}

@test "gradle: config flags and redirects are not selectors; --tests still is" {
  assert_dv_denied \
    './gradlew test 2>&1' \
    './gradlew test --info' \
    './gradlew --console plain test' \
    './gradlew test --console plain -Dfoo=bar --no-daemon --max-workers 2'
  assert_dv_allowed './gradlew test --tests com.foo.Bar --info 2>&1'
}

@test "cargo test: manifest and job flags and redirects are not selectors; a name filter still is" {
  assert_dv_denied 'cargo test --workspace' 'cargo test --manifest-path a/Cargo.toml' \
    'cargo test --release -j 4 2>&1' 'cargo test -- --nocapture --test-threads 1'
  assert_dv_allowed 'cargo test foo' 'cargo test -p mycrate' 'cargo test foo --manifest-path a/Cargo.toml'
}

@test "classification: the holes read full_test_run and the kept-scoped shape scoped_test_run" {
  classify_split 'swift test --package-path /abs/pkg'
  assert_output "full_test_run"
  classify_split 'swift test 2>&1'
  assert_output "full_test_run"
  classify_split 'swift test --filter X --package-path P'
  assert_output "scoped_test_run"
}

# --- dispatch coupling: the gate is only live while state.json says a stage is ---

@test "D1: RE + ./run-tests.sh -> deny (RE holds no test-execution authority)" {
  state_with RE
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  run jq -e '.metadata.stage == "RE" and .metadata.class == "full_test_run"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "D2: a SETTLED ledger (stages present, none in_progress) DENIES" {
  # Reverses this test's own earlier assertion, deliberately (#295). It used to
  # require an allow here, on the reading that an empty resolve_stage always
  # means "cannot tell who is acting". It does not: a non-empty stages map with
  # zero in_progress is the ledger positively saying NOBODY is acting — the
  # worktask has finished, or the loop is between stages. Allowing there left a
  # full suite permitted forever after FN, which is how a post-merge
  # `./run-tests.sh` got through. The genuine cannot-tell shapes still fail open
  # and are covered by D2b and the no-state.json case.
  printf '{"tasks":{"PL0":{"status":"completed"},"RE0":{"status":"completed"}}}' > "$WD/.context/state.json"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh')"
  assert_success
  assert_output --partial '"permissionDecision":"deny"'
  assert_output --partial 'No stage is in progress'
}

@test "D2a: a settled ledger still ALLOWS a non-test command" {
  # Scope check: the deny must cost a finished worktask only its test runs. If
  # it reached git/gh the session would be wedged, which is the deadlock the
  # fail-open contract exists to prevent.
  printf '{"tasks":{"PL0":{"status":"completed"},"FN0":{"status":"completed"}}}' > "$WD/.context/state.json"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'git status')"
  assert_success
  [ -z "$output" ]
}

@test "D2b: an AMBIGUOUS ledger (two stages in_progress) still fails open" {
  # This is what D2 used to protect and must not be lost: with two concurrent
  # stages the gate cannot attribute the call, so denying would wedge a session
  # it cannot reason about. Ambiguity fails open; settled does not.
  printf '{"tasks":{"DV0":{"status":"in_progress"},"QA0":{"status":"in_progress"}}}' > "$WD/.context/state.json"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh')"
  assert_success
  [ -z "$output" ]
}

@test "D2c: the exact post-merge invocation from #295 is denied (cd does not evade)" {
  # cd into an unrelated directory changes nothing: the hook reads
  # ${CLAUDE_PROJECT_DIR}/.context, the session's ledger, not the cwd's. Pinned
  # verbatim because this is the command that actually got through.
  printf '{"tasks":{"PL0":{"status":"completed"},"DV0":{"status":"completed"},"QA0":{"status":"completed"},"FN0":{"status":"completed"}}}' > "$WD/.context/state.json"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "$(bash_payload 'cd /tmp/corpflow-mergecheck && ./run-tests.sh')"
  assert_success
  assert_output --partial '"permissionDecision":"deny"'
}

@test "D3: SKILL.md step 5 marks in_progress in the ledger the gate reads" {
  # The instruction IS the fix — nothing else makes the gate reachable — and the
  # orchestrator executes this block, so drift here re-inerts every case above.
  local skill="$PLUGIN_ROOT/skills/worktask/SKILL.md"
  run grep -A2 '// 5. Mark in_progress' "$skill"
  assert_success
  assert_output --partial 'state-patch.sh --task-status ${task.id} in_progress'
}

@test "R1-18: flags-before-task build-only gradle tasks ALLOW at a banned stage (was a false deny)" {
  # `gradle -p . assembleAndroidTest` compiles a test APK and runs nothing;
  # the first-token read classified it a scoped test run and denied it at DR.
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'gradle -p . assembleAndroidTest')"
  assert_success
  [ -z "$output" ]
}

# --- redundant-run suppression ----------------------------------------------
# Dedupe keys on the tree, so these need a repo they can mutate, and a ledger
# carrying run_index (fixtures above deliberately omit it, which self-disables
# dedupe — that is what keeps every case above asserting authority alone).

git_ctx() {
  # git_ctx <stage> [run_index]
  git -C "$WD" init -q
  git -C "$WD" config user.email t@example.com
  git -C "$WD" config user.name t
  git -C "$WD" config commit.gpgsign false
  echo seed > "$WD/src.txt"
  git -C "$WD" add -A
  git -C "$WD" commit -qm init
  printf '{"run_index":%s,"tasks":{"%s0":{"status":"in_progress"}}}' "${2:-0}" "$1" \
    > "$WD/.context/state.json"
}

promote() {
  # promote <command> — the PostToolUse half of the handshake, with a payload
  # that carries a result. The gate only marks a run pending, so without this
  # nothing is ever suppressed; every case below that expects a deny must say
  # explicitly that the run produced something.
  local payload
  payload="$(jq -cn --arg c "$1" \
    '{tool_name:"Bash", tool_input:{command:$c}, tool_response:{stdout:"7 tests, 0 failures"}}')"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$payload" "$PROMOTE"
}

@test "D1: QA repeats an identical full run on an unchanged tree -> deny + audit row" {
  git_ctx QA
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ]
  promote './run-tests.sh'

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  run jq -e '.action == "test_execution_deduped" and .metadata.stage == "QA"' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "D2: an edit to the tree re-enables the same command (test -> fix -> retest)" {
  git_ctx QA
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"

  echo 'fix' >> "$WD/src.txt"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ]
}

@test "D3: a SECOND edit to the same file re-enables it (fingerprint reads content, not filenames)" {
  # Regression guard: `git status --porcelain` reports only names and status
  # letters, so two successive edits to one file are indistinguishable to it.
  # A porcelain-only fingerprint denies the retest after a real fix.
  git_ctx QA
  echo 'first' >> "$WD/src.txt"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"

  echo 'second' >> "$WD/src.txt"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ]
}

@test "D4: a run recorded by DV suppresses the identical run in QA (cross-stage, same run_index)" {
  git_ctx DV
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload 'tests/vendor/bats-core/bin/bats tests/shell/foo.bats')" \
    "$SCRIPT"
  promote 'tests/vendor/bats-core/bin/bats tests/shell/foo.bats'

  printf '{"run_index":0,"tasks":{"QA0":{"status":"in_progress"}}}' > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload 'tests/vendor/bats-core/bin/bats tests/shell/foo.bats')" \
    "$SCRIPT"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("already ran during run_index")'
}

@test "D5: a different selection is a different run -> allow" {
  git_ctx QA
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload 'tests/vendor/bats-core/bin/bats tests/shell/a.bats')" \
    "$SCRIPT"

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload 'tests/vendor/bats-core/bin/bats tests/shell/b.bats')" \
    "$SCRIPT"
  assert_success
  [ -z "$output" ]
}

@test "D6: a bumped run_index re-enables the same command" {
  git_ctx QA 0
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"

  printf '{"run_index":1,"tasks":{"QA0":{"status":"in_progress"}}}' > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ]
}

@test "D7: a ledger with no run_index self-disables dedupe -> allow (back-compat)" {
  git_ctx QA
  state_with QA   # rewrites state.json without run_index
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ]
}

@test "D8: CORPFLOW_TEST_DEDUPE=off allows the repeat and notes the hatch once" {
  git_ctx QA
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --env "CORPFLOW_TEST_DEDUPE=off" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ]
  run jq -e 'select(.action == "test_dedupe_disabled")' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "D9: a build-only run is never deduped (it executes no tests)" {
  git_ctx QA
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh --print-selection')" "$SCRIPT"

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh --print-selection')" "$SCRIPT"
  assert_success
  [ -z "$output" ]
}

@test "D10: outside a git repo the fingerprint is unresolvable -> allow (fail-open)" {
  # No git_ctx: $WD is not a repo, so tree_fingerprint returns empty.
  printf '{"run_index":0,"tasks":{"QA0":{"status":"in_progress"}}}' > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ]
}

@test "D11: a banned stage still gets the AUTHORITY deny, not the dedupe deny" {
  git_ctx DR
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("has no test-execution authority")'
}

# --- #1a: a run that produced no result claims nothing ----------------------
# The arm the previous suite could not reach at all: PreToolUse recorded on the
# allow path, so there was no state in which a run existed but had produced
# nothing.

@test "D12: an unpromoted run does NOT suppress the next identical one (PreToolUse alone claims nothing)" {
  git_ctx QA
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ]

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ]
}

@test "D13: a tool call that errored discards the marker instead of promoting it" {
  git_ctx QA
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  [ "$(find "$WD/.context/logs/.test-runs" -name '*.pending' | wc -l | tr -d ' ')" = "1" ]

  local payload
  payload="$(jq -cn '{tool_name:"Bash", tool_input:{command:"./run-tests.sh"},
                      tool_response:{error:"scheme not found"}}')"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$payload" "$PROMOTE"
  assert_success
  [ "$(find "$WD/.context/logs/.test-runs" -type f | wc -l | tr -d ' ')" = "0" ]

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ]
}

@test "D14: an orphaned pending marker can never wedge the gate (lookup ignores .pending)" {
  git_ctx QA
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"

  # No promotion ever arrives — the crash case. Ten further attempts must all
  # allow, because an inert marker is the design, not a cleanup obligation.
  local i
  for i in 1 2 3; do
    run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
      --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
    assert_success
    [ -z "$output" ]
  done
}

@test "D15: b' — a staged edit inside a LINKED WORKTREE re-enables the command (the arm rooted at the hook cwd could not see)" {
  git_ctx QA
  local wt="$WD/wt"
  git -C "$WD" worktree add -q -b feat "$wt"
  mkdir -p "$wt/.context"
  cp "$WD/.context/state.json" "$wt/.context/state.json"

  # The payload names the worktree as its cwd; the hook process stays in $WD,
  # exactly as the orchestrator checkout does for a worktree-isolated stage.
  local p1
  p1="$(jq -cn --arg d "$wt" '{tool_name:"Bash", tool_input:{command:"./run-tests.sh", cwd:$d}}')"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$wt" \
    --stdin-string "$p1" "$SCRIPT"
  assert_success
  [ -z "$output" ]

  local p2
  p2="$(jq -cn --arg d "$wt" '{tool_name:"Bash", tool_input:{command:"./run-tests.sh", cwd:$d},
                               tool_response:{stdout:"7 tests, 0 failures"}}')"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$wt" \
    --stdin-string "$p2" "$PROMOTE"

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$wt" \
    --stdin-string "$p1" "$SCRIPT"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'

  # The remedy the deny text promises, performed where the stage actually works.
  echo 'fix' >> "$wt/src.txt"
  git -C "$wt" add -A
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$wt" \
    --stdin-string "$p1" "$SCRIPT"
  assert_success
  [ -z "$output" ]
}

@test "D16: an edit in the MAIN tree does not re-enable a run fingerprinted in the worktree" {
  # The converse of D15, and the reason b' is a fix rather than a widening: the
  # two trees are genuinely different keys, not one key resolved loosely.
  git_ctx QA
  local wt="$WD/wt"
  git -C "$WD" worktree add -q -b feat "$wt"
  mkdir -p "$wt/.context"
  cp "$WD/.context/state.json" "$wt/.context/state.json"

  local p1 p2
  p1="$(jq -cn --arg d "$wt" '{tool_name:"Bash", tool_input:{command:"./run-tests.sh", cwd:$d}}')"
  p2="$(jq -cn --arg d "$wt" '{tool_name:"Bash", tool_input:{command:"./run-tests.sh", cwd:$d},
                               tool_response:{stdout:"7 tests, 0 failures"}}')"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$wt" --stdin-string "$p1" "$SCRIPT"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$wt" --stdin-string "$p2" "$PROMOTE"

  echo 'unrelated' >> "$WD/src.txt"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$wt" --stdin-string "$p1" "$SCRIPT"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "D17: the denial NAMES the cited run's evidence (F-18c)" {
  # A denial that cannot say what the run it protects produced is the symptom
  # that cost an hour of diagnosis: the message pointed at a run whose sentinel
  # held no counts, no verdict and no output.
  git_ctx QA
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  promote './run-tests.sh'

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("evidence: tests:7")'
  # And the audit row carries it as its own field, so the trail is greppable
  # without parsing the denial prose.
  run jq -e '.metadata.prior_evidence == "tests:7"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "D18: a STALE two-field sentinel splits to unrecorded, and unrecorded no longer suppresses" {
  # Markers written before the evidence token joined the grammar exist in the
  # wild. The explicit three-field split degrades them loudly; the `%% */#* `
  # pair the old denial used would have quoted the timestamp as a result.
  #
  # It no longer DENIES: the denial prose has always told the caller to treat
  # `unrecorded` as no evidence at all, so suppressing against it refused the one
  # run that could still produce some. The split is still what is under test —
  # asserted now on the audit row, which is where an allowed run records it.
  git_ctx QA
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  promote './run-tests.sh'

  local sentinel
  sentinel="$(find "$WD/.context/logs/.test-runs" -type f ! -name '*.pending' | head -1)"
  printf 'QA 2026-09-07T17:30:49Z\n' > "$sentinel"

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ] || fail "a zero-evidence prior must not deny: $output"
  run jq -e 'select(.action == "test_dedupe_skipped_zero_prior")
             | .metadata.prior_evidence == "unrecorded"' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "D18a: a tests:0 prior does not suppress the next run (F-01)" {
  # The P0 in one line: a scheme with an empty test plan enumerated 49 cases,
  # executed none, and its sentinel then refused every later attempt to run them.
  git_ctx QA
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  promote './run-tests.sh'

  local sentinel
  sentinel="$(find "$WD/.context/logs/.test-runs" -type f ! -name '*.pending' | head -1)"
  printf 'QA 2026-09-07T17:30:49Z tests:0\n' > "$sentinel"

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ] || fail "tests:0 is not a result to reproduce: $output"
  run jq -e 'select(.action == "test_dedupe_skipped_zero_prior")
             | .metadata.prior_evidence == "tests:0"' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "D18b: a discovered: prior does not suppress, but a real count still does" {
  git_ctx QA
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  promote './run-tests.sh'

  local sentinel
  sentinel="$(find "$WD/.context/logs/.test-runs" -type f ! -name '*.pending' | head -1)"

  printf 'QA 2026-09-07T17:30:49Z discovered:49\n' > "$sentinel"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ] || fail "an enumeration is not an execution: $output"

  # The control: the same tree, the same invocation, one executed test — denies.
  printf 'QA 2026-09-07T17:30:49Z tests:1\n' > "$sentinel"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "D18c: an output: prior does not suppress — bytes are not an execution (2b)" {
  # `output:` is minted for ANY non-empty response with no parseable count, so
  # `error: no such module Foo` earns one, and the gate then denied every retry
  # citing a run that compiled nothing and executed nothing. A byte count says a
  # tool SPOKE; suppression must cite a result the denied run could only reproduce.
  git_ctx QA
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  promote './run-tests.sh'

  local sentinel
  sentinel="$(find "$WD/.context/logs/.test-runs" -type f ! -name '*.pending' | head -1)"
  printf 'QA 2026-09-07T17:30:49Z output:38B\n' > "$sentinel"

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  [ -z "$output" ] || fail "a compiler error is not a test result: $output"
  run jq -e 'select(.action == "test_dedupe_skipped_zero_prior")
             | .metadata.prior_evidence == "output:38B"' \
    "$WD/.context/logs/audit.jsonl"
  assert_success

  # The control: `errtext:` stays evidence. A PostToolUseFailure payload is a red
  # suite that printed its failures, which IS a run — dropping it with `output:`
  # would have discarded every failing suite from the record.
  printf 'QA 2026-09-07T17:30:49Z errtext:38B\n' > "$sentinel"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "A3-1: a dedupe denial names the authority holder and the test mode (F-02)" {
  # Four stages escalated in one run naming a remedy that would have been refused
  # again by the arm nobody told them about. The gate knows all three of its own
  # arms at deny time; before this it volunteered one.
  git_ctx QA
  printf '{"run_index":0,"metadata":{"test_mode":"full"},"tasks":{"QA0":{"status":"in_progress"}}}' \
    > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  promote './run-tests.sh'

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  local reason
  reason="$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"already ran during run_index"* ]] || fail "not the dedupe arm: $reason"
  [[ "$reason" == *"test-execution authority (held by stage 'QA')"* ]] \
    || fail "authority holder unnamed: $reason"
  [[ "$reason" == *"resolved test mode 'full'"* ]] || fail "test mode unnamed: $reason"
  # One line, like every other denial the caller reads.
  [ "$(printf '%s' "$reason" | wc -l | tr -d ' ')" = "0" ] || fail "reason is multi-line"
}

@test "A3-2: a dedupe denial with NO stage in_progress still names both controls" {
  # The exact shape the run hit: authority survives a settled ledger through an
  # unresolved no-go, so dedupe can fire with nothing in_progress.
  git_ctx QA
  printf '{"run_index":0,"metadata":{"test_mode":"scoped"},"tasks":{"QA0":{"status":"completed","verdict":"no-go"}}}' \
    > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  promote './run-tests.sh'

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$SCRIPT"
  assert_success
  local reason
  reason="$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"test-execution authority (held by stage 'QA')"* ]] \
    || fail "authority holder unnamed: $reason"
  [[ "$reason" == *"resolved test mode 'scoped'"* ]] || fail "test mode unnamed: $reason"
}

@test "A3-3: an authority denial names suppression, and never repeats the mode" {
  state_with DR
  local payload='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  local reason
  reason="$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"redundant-run suppression (on)"* ]] || fail "suppression unnamed: $reason"
  # The authority clause already quotes the mode inline; the trailing list must
  # not say it a second time.
  [ "$(printf '%s' "$reason" | grep -o "resolved test mode" | wc -l | tr -d ' ')" = "1" ] \
    || fail "test mode named twice: $reason"
}

@test "D19: two MCP test calls differing only in SELECTION do not collide (F-18a end to end)" {
  # The P0 in its original shape: every mcp__*test* call fell through to the bare
  # tool name, so the first run's sentinel denied every later call of that tool
  # whatever it was asked to run — one platform left DV with 0 executed tests.
  git_ctx QA
  local a b post_a
  a="$(jq -cn '{tool_name:"mcp__XcodeBuildMCP__test_sim",
                tool_input:{scheme:"App", testTarget:"AppTests/LoginTests"}}')"
  b="$(jq -cn '{tool_name:"mcp__XcodeBuildMCP__test_sim",
                tool_input:{scheme:"App", testTarget:"AppTests/SignupTests"}}')"
  post_a="$(jq -cn '{tool_name:"mcp__XcodeBuildMCP__test_sim",
                     tool_input:{scheme:"App", testTarget:"AppTests/LoginTests"},
                     tool_response:{stdout:"Executed 12 tests, with 0 failures"}}')"

  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" --stdin-string "$a" "$SCRIPT"
  assert_success
  [ -z "$output" ]
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" --stdin-string "$post_a" "$PROMOTE"

  # The OTHER selection is a different run and must be allowed.
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" --stdin-string "$b" "$SCRIPT"
  assert_success
  [ -z "$output" ]

  # The SAME selection against the same tree is the duplicate, and it is denied
  # naming what the first one produced.
  run_script_env --cwd "$WD" --env "CLAUDE_PROJECT_DIR=$WD" --stdin-string "$a" "$SCRIPT"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("evidence: tests:12")'
}

# --- #8: the Node standard-library runner -----------------------------------

@test "N-node-1: 'node --test' denies at a banned stage (the suite that ran ungated at every stage)" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'node --test')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "N-node-2: bare 'node script.js' still ALLOWS at a banned stage (script execution is not test execution)" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'node scripts/seed.js')"
  assert_success
  [ -z "$output" ]
}

@test "N-node-3: 'node --test' at DV hits the full-suite deny; a name pattern keeps it scoped" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload 'node --test')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'

  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "$(bash_payload 'node --test --test-name-pattern=parses')"
  assert_success
  [ -z "$output" ]
}

@test "N-node-4: a reporter flag is configuration, not selection — 'node --test --test-reporter=spec' still denies at DV" {
  state_with DV
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "$(bash_payload 'node --test --test-reporter=spec')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

# --- #12: the prefilter classifies structure, not text ----------------------

@test "P-pre-1: a jq call whose ARGUMENT names runners executes nothing -> allow at a banned stage" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "$(bash_payload 'jq -cn --arg m "ran bats; pytest tests/; go test ./..." "{note:\$m}" >> log.json')"
  assert_success
  [ -z "$output" ]
}

@test "P-pre-2: a here-doc body naming runners is data, not commands -> allow at a banned stage" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$(printf '%s\n' \
    "cat > notes.md <<'EOF'" \
    'pytest tests/unit' \
    'bats tests/shell' \
    'EOF')")"
  assert_success
  [ -z "$output" ]
}

@test "P-pre-3: the narrowing keeps every real deny — a runner after a non-runner segment still denies" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "$(bash_payload 'cd sub && FOO=1 npx jest src/a.test.js')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "P-pre-4: text after the here-doc terminator is code again (the skip has an end)" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$(printf '%s\n' \
    "cat > notes.md <<'EOF'" \
    'nothing to see' \
    'EOF' \
    'pytest tests/unit')")"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "P-pre-5: the prefilter skips BOTH words of 'uv run', so the runner behind it still denies" {
  # A first-token-only skip heads on `run` — not gateable — and the fast path
  # allows a real runner at a banned stage.
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "$(bash_payload 'uv run pytest tests/')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "P-pre-6: 'uv run python -m pytest' reaches the python -m collapse behind the launcher" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "$(bash_payload 'uv run python -m pytest tests/')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "P-pre-7: 'uv run <script>' is script execution, not a runner -> allow at a banned stage" {
  state_with DR
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "$(bash_payload 'uv run scripts/seed.py')"
  assert_success
  [ -z "$output" ]
}

# --- #7: authority during post-completion remediation ------------------------

@test "V-rem-1: a settled ledger whose QA carries an unresolved no-go keeps full-suite authority" {
  printf '{"tasks":{"DV0":{"status":"completed","verdict":"ok"},
                    "QA0":{"status":"completed","verdict":"no-go"}}}' > "$WD/.context/state.json"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh')"
  assert_success
  [ -z "$output" ]
}

@test "V-rem-2: the window closes the moment the verdict flips" {
  printf '{"tasks":{"DV0":{"status":"completed","verdict":"ok"},
                    "QA0":{"status":"completed","verdict":"go"}}}' > "$WD/.context/state.json"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("No stage is in progress")'
}

@test "V-rem-3: a no-go carried by DV grants DV's authority, not QA's (the full-suite deny survives)" {
  printf '{"tasks":{"DV0":{"status":"completed","verdict":"no-go"}}}' > "$WD/.context/state.json"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Stage .DV. has no test-execution authority")'

  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "$(bash_payload 'tests/vendor/bats-core/bin/bats tests/shell/foo.bats')"
  assert_success
  [ -z "$output" ]
}

@test "V-rem-4: two stages carrying a no-go is ambiguous -> the settled deny stands" {
  printf '{"tasks":{"DV0":{"status":"completed","verdict":"no-go"},
                    "QA0":{"status":"completed","verdict":"no-go"}}}' > "$WD/.context/state.json"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload './run-tests.sh')"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("No stage is in progress")'
}

# --- R-3.1: the Skill branch's missing scoped arm ----------------------------

@test "R3-1s: a DV build-test Skill carrying a selection flag classifies scoped and is ALLOWED" {
  state_with DV
  local payload='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test","args":"--only tests/shell/worktask"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  [ -z "$output" ]
}

@test "R3-1s: --filter and -only-testing: are selections too" {
  state_with DV
  for args in "--filter StatePatchTests" "-only-testing:AppTests/LoginTests"; do
    local payload
    payload="$(jq -cn --arg a "$args" '{tool_name:"Skill",tool_input:{skill:"apple-developer:build-test",args:$a}}')"
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
    assert_success
    [ -z "$output" ] || fail "scoped selection '$args' was denied"
  done
}

@test "R3-1s: a bare DV build-test Skill is still a full run and still denied" {
  state_with DV
  local payload='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "R3-1s: the denial names BOTH the stage authority and the resolved test mode" {
  printf '{"metadata":{"test_mode":"full"},"tasks":{"DV0":{"status":"in_progress"}}}' \
    > "$WD/.context/state.json"
  local payload='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  local reason
  reason="$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"has no test-execution authority"* ]]
  [[ "$reason" == *"resolved test mode is 'full'"* ]]
}

@test "DH1: the remediation half of a denial comes from references/test-execution-denials.md" {
  state_with DR
  local payload='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  local reason
  reason="$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  # A phrase that exists only in the document, so this fails if the section stops loading.
  [[ "$reason" == *"--build-only is not a real flag"* ]] || fail "remediation section absent: $reason"
  # Joined into one line: a wrapped paragraph must not reach the caller as multiple lines.
  [ "$(printf '%s' "$reason" | wc -l | tr -d ' ')" = "0" ] || fail "reason is multi-line"
}

@test "DH2: an unreadable denial document degrades to the condition clause, never to an allow" {
  cp -R "$PLUGIN_ROOT/hooks" "$WD/hooks"
  rm -rf "$WD/hooks/references"
  state_with DR
  local payload='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$WD/hooks/test-execution-gate.sh" <<< "$payload"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  local reason
  reason="$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"has no test-execution authority"* ]] || fail "condition clause lost: $reason"
  [[ "$reason" != *"--build-only is not a real flag"* ]] || fail "help text loaded from nowhere"
}

@test "R3-1s: an absent test_mode is reported as unset, never guessed as full" {
  state_with DR
  local payload='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test"}}'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$payload"
  assert_success
  echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q "unset (resolves to scoped)"
}

# _gate_lib <gate-script> <snippet> [args...] — <snippet> with the gate sourced --lib-only.
_gate_lib() {
  local gate="$1" snippet="$2"
  shift 2
  run --separate-stderr bash -c ". '$gate' --lib-only; $snippet" _ "$@"
}

# The check both contract cases run: every wrapper phrase in the ONE shared
# definition, put in front of a runner, must give the fast-path scanner a
# gateable head AND classify as a test run; prints the phrases checked.
# shellcheck disable=SC2016  # expanded by the inner shell
_WRAPPER_CHECK='
  bad="" n=0
  _chk() {
    local c="$1 pytest tests/" g=0 t
    n=$((n + 1))
    gate_head_tokens "$c"
    for t in $HEAD_TOKENS; do gate_head_is_gateable "$t" && g=1; done
    [ "$g" -eq 1 ] || bad="$bad scanner:[$1]"
    case "$(classify_cmd "$c")" in *test_run) ;; *) bad="$bad classifier:[$1]" ;; esac
  }
  for l in $GATE_LAUNCHERS; do _chk "${l//_/ }"; _chk "${l//_/ } VAR=1"; done
  for w in $GATE_TIMEOUT_WRAPPERS; do
    _chk "$w 5"; _chk "$w -s KILL -k 5 60"; _chk "$w 5 VAR=1"; _chk "$w 600 env VAR=1"
  done
  _chk "(VAR=1"
  for sh in $GATE_SHELLS; do
    c="$sh -c '"'"'pytest tests/'"'"'"
    n=$((n + 1))
    gate_head_tokens "$c"; g=0
    for t in $HEAD_TOKENS; do gate_head_is_gateable "$t" && g=1; done
    [ "$g" -eq 1 ] || bad="$bad scanner:[$sh -c]"
    case "$(classify_cmd "$c")" in *test_run) ;; *) bad="$bad classifier:[$sh -c]" ;; esac
  done
  printf "%s|%s" "$n" "$bad"'

@test "contract: the scanner and the classifier see through every wrapper in the one shared definition" {
  # A wrapper the classifier strips but the scanner does not makes the fast path
  # head on the wrapper, find nothing gateable, and ALLOW what the classifier
  # would deny — so both consumers are exercised against every listed phrase.
  _gate_lib "$PLUGIN_ROOT/$SCRIPT" "$_WRAPPER_CHECK"
  assert_success
  [ "${output%%|*}" -ge 8 ] || fail "non-vacuity: only ${output%%|*} wrapper phrases checked"
  [ -z "${output#*|}" ] || fail "not seen through:${output#*|}"
  # No second, hand-kept copy of the lists survives anywhere in the gate.
  run grep -nE -e 'for _launcher in ' -e 'env[|]npx[|]uvx[|]bunx' -e 'bash[|]sh[|]zsh[|]dash[)]' \
    -e 'bash sh zsh dash ' "$PLUGIN_ROOT/$SCRIPT"
  assert_failure 1
}

@test "contract: a wrapper added to GATE_LAUNCHERS alone reaches both the scanner and the classifier" {
  sed 's/^GATE_LAUNCHERS="\(.*\)"$/GATE_LAUNCHERS="\1 zzwrap zzpair_go"/' "$PLUGIN_ROOT/$SCRIPT" > "$WD/gate-copy.sh"
  grep -q '^GATE_LAUNCHERS=".* zzwrap zzpair_go"$' "$WD/gate-copy.sh" || fail "GATE_LAUNCHERS line not found"
  # shellcheck disable=SC2016  # expanded by the inner shell
  _gate_lib "$WD/gate-copy.sh" '
    for c in "zzwrap pytest tests/" "zzpair go pytest tests/"; do
      gate_head_tokens "$c"; printf "%s=%s|" "$c" "$HEAD_TOKENS"
      printf "%s\n" "$(classify_cmd "$c")"
    done'
  assert_success
  assert_line "zzwrap pytest tests/= pytest|scoped_test_run"
  assert_line "zzpair go pytest tests/= pytest|scoped_test_run"
}

@test "unresolved root exits 0, no block, no .context under cwd" {
  local cwd
  cwd="$(mk_tmpworkdir)"
  run_script_env --cwd "$cwd" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR --unset CONTEXT_DIR \
    --env "GIT_CEILING_DIRECTORIES=$cwd" \
    --stdin-string "$(bash_payload './run-tests.sh')" "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ -z "$output" ]
  [ ! -e "$cwd/.context" ]
}

# --- root resolution: where and when --------------------------------------------

@test "R6: a non-test Bash call resolves no context root in the gate or the promote hook; a test run does" {
  git_ctx DV
  local stub="$WD/stubbin" real
  real="$(command -v git)"
  mkdir -p "$stub"
  printf '#!/bin/sh\necho "$*" >> "%s/git.calls"\nexec "%s" "$@"\n' "$WD" "$real" > "$stub/git"
  chmod +x "$stub/git"

  local hook
  for hook in "$SCRIPT" "$PROMOTE"; do
    run_script_env --cwd "$WD" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR --env "PATH=$stub:$PATH" \
      --stdin-string "$(bash_payload 'ls -la')" "$hook"
    assert_success
    [ ! -s "$WD/git.calls" ] || fail "$hook resolved a root for ls: $(cat "$WD/git.calls")"
  done

  run_script_env --cwd "$WD" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR --env "PATH=$stub:$PATH" \
    --stdin-string "$(bash_payload 'bats tests/x.bats')" "$SCRIPT"
  assert_success
  grep -q 'rev-parse' "$WD/git.calls" || fail "a test run never resolved the root"
}

@test "R2: an unregistered linked worktree with no ledger of its own does not inherit the main checkout's settled ledger" {
  git_ctx QA
  printf '{"run_index":0,"tasks":{"DV0":{"status":"completed"},"QA0":{"status":"completed"}}}' > "$WD/.context/state.json"
  local wt="$WD/wt"
  git -C "$WD" worktree add -q -b feat "$wt"

  run_script_env --cwd "$wt" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$wt" \
    --stdin-string "$(bash_payload 'bats tests/x.bats')" "$SCRIPT"
  assert_success
  assert_output ""

  # Registered as a stage worktree, it is governed by the main ledger again (settled: deny).
  jq --arg w "$wt" '.tasks.DV0.metadata.workspace_path = $w' "$WD/.context/state.json" > "$WD/st.new"
  mv "$WD/st.new" "$WD/.context/state.json"
  run_script_env --cwd "$wt" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$wt" \
    --stdin-string "$(bash_payload 'bats tests/x.bats')" "$SCRIPT"
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null \
    || fail "registered worktree was not governed: $output"
}
