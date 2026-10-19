#!/usr/bin/env bash
# test-execution-gate self-test body — sourced by hooks/test-execution-gate.sh
# under --self-test only, never on the PreToolUse dispatch path.
#
# Lives here rather than inline because it is test code: the hook is a hot-path
# gate and tests/shell/hooks/test-execution-gate.bats is the real coverage.
# Sourced (not executed) so it sees run_gate and every classifier helper already
# defined by the caller; it owns the exit for this invocation.
#
# Indentation is the caller's — kept byte-identical so the extraction stays a
# pure move and the quoted heredoc payloads below are unaltered.

  _fail=0
  _st_cases=0
  command -v jq >/dev/null 2>&1 || { echo "test-execution-gate: jq not found — self-test skipped"; exit 0; }

  _tmp=$(mktemp -d)
  trap 'rm -rf "$_tmp"' EXIT

  # DR + scoped bats -> deny
  _ctx1="$_tmp/dr/.context"; mkdir -p "$_ctx1"
  printf '{"tasks":{"DR0":{"status":"in_progress"}}}' > "$_ctx1/state.json"
  _p1='{"tool_name":"Bash","tool_input":{"command":"tests/vendor/bats-core/bin/bats tests/shell/foo.bats"}}'
  _o1=$(run_gate "$_p1" "$_ctx1")
  printf '%s' "$_o1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (DR scoped deny)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # DV + full run-tests.sh -> deny (DV holds scoped authority only)
  _ctx2="$_tmp/dv/.context"; mkdir -p "$_ctx2"
  printf '{"tasks":{"DV0":{"status":"in_progress"}}}' > "$_ctx2/state.json"
  _p2='{"tool_name":"Bash","tool_input":{"command":"./run-tests.sh"}}'
  _o2=$(run_gate "$_p2" "$_ctx2")
  printf '%s' "$_o2" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (DV full deny)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # DV + run-tests.sh --changed -> allow (scoped selection is DV's own authority)
  _p2b='{"tool_name":"Bash","tool_input":{"command":"./run-tests.sh --changed"}}'
  _o2b=$(run_gate "$_p2b" "$_ctx2")
  printf '%s' "$_o2b" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && { echo "test-execution-gate: self-test FAIL (DV --changed must not deny)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # DV + run-tests.sh --print-selection -> allow (build_only: runs nothing)
  _p2c='{"tool_name":"Bash","tool_input":{"command":"./run-tests.sh --changed --print-selection"}}'
  _o2c=$(run_gate "$_p2c" "$_ctx2")
  printf '%s' "$_o2c" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    && { echo "test-execution-gate: self-test FAIL (DV --print-selection must not deny)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # QA + full run-tests.sh -> allow
  _ctx3="$_tmp/qa/.context"; mkdir -p "$_ctx3"
  printf '{"tasks":{"QA0":{"status":"in_progress"}}}' > "$_ctx3/state.json"
  _p3='{"tool_name":"Bash","tool_input":{"command":"./run-tests.sh"}}'
  _o3=$(run_gate "$_p3" "$_ctx3")
  [ -z "$_o3" ] || { echo "test-execution-gate: self-test FAIL (QA full allow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # No state.json -> allow, no row (nothing resolves, so nothing to enforce)
  _ctx4="$_tmp/none/.context"; mkdir -p "$_ctx4"
  _o4=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"bats foo.bats"}}' "$_ctx4")
  [ -z "$_o4" ] || { echo "test-execution-gate: self-test FAIL (no state.json)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  [ ! -f "$_ctx4/logs/audit.jsonl" ] || { echo "test-execution-gate: self-test FAIL (no state.json wrote a row)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # Agent carrying ban text -> allow, observe-only row, never deny
  # (a prose-matching deny here would refuse to dispatch this very policy)
  _ctx5="$_tmp/task/.context"; mkdir -p "$_ctx5"
  printf '{"tasks":{"DR0":{"status":"in_progress"}}}' > "$_ctx5/state.json"
  _p5='{"tool_name":"Agent","tool_input":{"subagent_type":"corpflow:developer","prompt":"Never run bats or pytest outside DV/QA"}}'
  _o5=$(run_gate "$_p5" "$_ctx5")
  [ -z "$_o5" ] || { echo "test-execution-gate: self-test FAIL (Agent must never deny)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  tail -n 1 "$_ctx5/logs/audit.jsonl" 2>/dev/null | jq -e '.action == "test_delegation_observed"' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (Agent observe row)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # Regression: Agent dispatch with NO .context/ at all -> zero side effects
  # (no worktask in flight means nothing should be created or logged).
  _ctx5b="$_tmp/task-no-ctx/.context"   # deliberately NOT created
  _o5b=$(run_gate '{"tool_name":"Agent","tool_input":{"subagent_type":"corpflow:developer","prompt":"go ahead and make the change"}}' "$_ctx5b")
  [ -z "$_o5b" ] || { echo "test-execution-gate: self-test FAIL (Agent no-ctx must be silent)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  [ ! -d "$_ctx5b" ] || { echo "test-execution-gate: self-test FAIL (Agent no-ctx created .context/)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # command_head only, never the full command, in a deny's audit row.
  _ctx6="$_tmp/redact/.context"; mkdir -p "$_ctx6"
  printf '{"tasks":{"SR0":{"status":"in_progress"}}}' > "$_ctx6/state.json"
  _p6='{"tool_name":"Bash","tool_input":{"command":"bats /secret/path/leak.bats -f token-abc123"}}'
  run_gate "$_p6" "$_ctx6" >/dev/null
  tail -n 1 "$_ctx6/logs/audit.jsonl" | jq -e '.metadata.command_head == "bats" and (.metadata | has("command") | not)' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (command_head redaction)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # Regression: a leading secret env assignment must not reach command_head.
  _ctx6b="$_tmp/redact-secret/.context"; mkdir -p "$_ctx6b"
  printf '{"tasks":{"SR0":{"status":"in_progress"}}}' > "$_ctx6b/state.json"
  _p6b='{"tool_name":"Bash","tool_input":{"command":"API_KEY=sk-test-xyz pytest tests/"}}'
  run_gate "$_p6b" "$_ctx6b" >/dev/null
  tail -n 1 "$_ctx6b/logs/audit.jsonl" | jq -e '.metadata.command_head == "pytest" and (.metadata.command_head | test("sk-test-xyz|API_KEY") | not)' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (secret leaked into command_head)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # CORPFLOW_TEST_GATE=off -> allow even for a banned stage
  _ctx7="$_tmp/off/.context"; mkdir -p "$_ctx7"
  printf '{"tasks":{"DR0":{"status":"in_progress"}}}' > "$_ctx7/state.json"
  _o7=$(CORPFLOW_TEST_GATE=off run_gate '{"tool_name":"Bash","tool_input":{"command":"bats foo.bats"}}' "$_ctx7")
  [ -z "$_o7" ] || { echo "test-execution-gate: self-test FAIL (escape hatch)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # DR + build-test --no-test -> allow (build-only stays permitted everywhere)
  _ctx8="$_tmp/buildonly/.context"; mkdir -p "$_ctx8"
  printf '{"tasks":{"DR0":{"status":"in_progress"}}}' > "$_ctx8/state.json"
  _o8=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"/system-developer:build-test --no-test"}}' "$_ctx8")
  [ -z "$_o8" ] || { echo "test-execution-gate: self-test FAIL (build-test --no-test)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # DR + Skill payload in its real {skill, args} shape -> --no-test allows,
  # bare denies (the flag lives in `args`, not in the skill name).
  _ctx8b="$_tmp/skill-args/.context"; mkdir -p "$_ctx8b"
  printf '{"tasks":{"DR0":{"status":"in_progress"}}}' > "$_ctx8b/state.json"
  _p8b='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test","args":"--no-test"}}'
  _o8b=$(run_gate "$_p8b" "$_ctx8b")
  [ -z "$_o8b" ] || { echo "test-execution-gate: self-test FAIL (Skill args --no-test)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  _p8c='{"tool_name":"Skill","tool_input":{"skill":"system-developer:build-test","args":"--scheme App"}}'
  _o8c=$(run_gate "$_p8c" "$_ctx8b")
  printf '%s' "$_o8c" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (Skill args full run)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # `make test` reaches the classifier at all (the zero-fork prefilter used
  # to drop it before classification, allowing it at every banned stage).
  _ctx8d="$_tmp/make-test/.context"; mkdir -p "$_ctx8d"
  printf '{"tasks":{"DR0":{"status":"in_progress"}}}' > "$_ctx8d/state.json"
  _o8d=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"make test"}}' "$_ctx8d")
  printf '%s' "$_o8d" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (make test must deny at DR)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # xcodebuild's action follows its options — the trailing-action shape must
  # classify identically to the action-first shape.
  _ctx8e="$_tmp/xcodebuild/.context"; mkdir -p "$_ctx8e"
  printf '{"tasks":{"DR0":{"status":"in_progress"}}}' > "$_ctx8e/state.json"
  _o8e=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"xcodebuild -scheme MyApp -destination generic/platform=iOS test"}}' "$_ctx8e")
  printf '%s' "$_o8e" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (xcodebuild trailing test action)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  _o8f=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"xcodebuild -scheme MyTests build-for-testing"}}' "$_ctx8e")
  [ -z "$_o8f" ] || { echo "test-execution-gate: self-test FAIL (xcodebuild build-for-testing must allow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # Regression: pure build/non-test commands on multi-purpose runners must
  # ALLOW at a banned stage — build-only stays permitted everywhere.
  _ctx9="$_tmp/gradle-build/.context"; mkdir -p "$_ctx9"
  printf '{"tasks":{"DR0":{"status":"in_progress"}}}' > "$_ctx9/state.json"
  _o9=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"./gradlew assembleDebug"}}' "$_ctx9")
  [ -z "$_o9" ] || { echo "test-execution-gate: self-test FAIL (gradlew assembleDebug must allow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  _ctx9b="$_tmp/py-coverage/.context"; mkdir -p "$_ctx9b"
  printf '{"tasks":{"SR0":{"status":"in_progress"}}}' > "$_ctx9b/state.json"
  _o9b=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"python3 tools/coverage_report.py"}}' "$_ctx9b")
  [ -z "$_o9b" ] || { echo "test-execution-gate: self-test FAIL (coverage_report.py must allow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # Regression: `-c` is a config flag for swift/pytest, not a build-only
  # signal — a real test run carrying `-c` must still classify (and deny) as
  # a test, not slip through as build-only.
  _ctx10="$_tmp/dashc-dr/.context"; mkdir -p "$_ctx10"
  printf '{"tasks":{"DR0":{"status":"in_progress"}}}' > "$_ctx10/state.json"
  _o10=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"swift test -c release"}}' "$_ctx10")
  printf '%s' "$_o10" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (swift test -c release must still deny at DR)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  _ctx10b="$_tmp/dashc-dv/.context"; mkdir -p "$_ctx10b"
  printf '{"tasks":{"DV0":{"status":"in_progress"}}}' > "$_ctx10b/state.json"
  _o10b=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"swift test -c release"}}' "$_ctx10b")
  printf '%s' "$_o10b" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (swift test -c release must deny DV-full)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # Non-selecting flags no longer read as scoping: every runner below REQUIRES
  # flags to run at all, so before the per-runner strip each of these was a
  # full suite that classified scoped and sailed past the DV deny.
  _ctx11="$_tmp/nonselecting-dv/.context"; mkdir -p "$_ctx11"
  printf '{"tasks":{"DV0":{"status":"in_progress"}}}' > "$_ctx11/state.json"
  while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    _o11=$(run_gate "$(jq -cn --arg c "$_c" '{tool_name:"Bash",tool_input:{command:$c}}')" "$_ctx11")
    printf '%s' "$_o11" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
      || { echo "test-execution-gate: self-test FAIL (DV-full deny expected: $_c)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  done <<'EOF'
xcodebuild test -project a.xcodeproj -scheme overlay -destination generic/platform=iOS
gradle test -p .
dotnet test MySolution.sln
npm test -- --ci
cargo test --release
EOF

  # The allow direction of the same change — an over-deny would block
  # legitimate scoped work mid-run, which is the worse failure.
  while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    _o12=$(run_gate "$(jq -cn --arg c "$_c" '{tool_name:"Bash",tool_input:{command:$c}}')" "$_ctx11")
    [ -z "$_o12" ] || { echo "test-execution-gate: self-test FAIL (DV allow expected: $_c)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  done <<'EOF'
xcodebuild test -project a.xcodeproj -scheme s -only-testing:UnitTests/LogTests
xcodebuild build -project a.xcodeproj -scheme s
cargo test --release foo
go test ./...
EOF

  # QA keeps sole full-suite authority — the strip changes classification, not
  # who may run a full suite.
  _ctx11b="$_tmp/nonselecting-qa/.context"; mkdir -p "$_ctx11b"
  printf '{"tasks":{"QA0":{"status":"in_progress"}}}' > "$_ctx11b/state.json"
  _o11b=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"xcodebuild test -project a.xcodeproj -scheme s -destination d"}}' "$_ctx11b")
  [ -z "$_o11b" ] || { echo "test-execution-gate: self-test FAIL (QA multi-flag xcodebuild allow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # A quoted multi-word value is ONE token. A simulator destination normally
  # contains spaces, so without this the strip missed the exact shape of the
  # incident that motivated it while the space-free forms denied.
  while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    _o11d=$(run_gate "$(jq -cn --arg c "$_c" '{tool_name:"Bash",tool_input:{command:$c}}')" "$_ctx11")
    printf '%s' "$_o11d" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
      || { echo "test-execution-gate: self-test FAIL (quoted value escaped the strip: $_c)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  done <<'EOF'
xcodebuild test -project a.xcodeproj -scheme overlay -destination "platform=iOS Simulator,name=iPhone 16 Pro"
xcodebuild test -project a.xcodeproj -scheme overlay -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
dotnet test "My Solution.sln"
EOF

  # Same quoted value, plus a real selector -> still allowed.
  # The payload is built through a variable, never inlined: an unbalanced quote
  # inside `"$( ... )"` flips the outer parser's quoting state, brace expansion
  # then splits the jq filter, and the fixture silently passes on an empty
  # payload. That is how the unterminated-quote case below was first written.
  _c='xcodebuild test -project a -scheme overlay -destination "platform=iOS Simulator,name=iPhone 16 Pro" -only-testing:UnitTests/LogTests'
  _p11e=$(jq -cn --arg c "$_c" '{tool_name:"Bash",tool_input:{command:$c}}')
  _o11e=$(run_gate "$_p11e" "$_ctx11")
  [ -z "$_o11e" ] || { echo "test-execution-gate: self-test FAIL (quoted value + selector must allow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # Unbalanced quoting strips nothing rather than half the argument list — the
  # ambiguous parse degrades to allow, never to a deny.
  _c='xcodebuild test -project a -scheme overlay -destination "platform=iOS Simulator'
  _p11f=$(jq -cn --arg c "$_c" '{tool_name:"Bash",tool_input:{command:$c}}')
  [ -n "$_p11f" ] || { echo "test-execution-gate: self-test FAIL (unterminated-quote payload did not build)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  _o11f=$(run_gate "$_p11f" "$_ctx11")
  [ -z "$_o11f" ] || { echo "test-execution-gate: self-test FAIL (unterminated quote must allow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # Fail-open guard: a value-consuming flag whose value is missing must not
  # swallow the token that follows it. The surviving token must NOT be in the
  # explicit selector list — that limb decides on $_seg before the strip ever
  # runs, so a `-only-testing:` case here passes with the guard deleted and
  # proves nothing. Verified to flip to a deny when the guard is removed.
  _o11c=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"xcodebuild test -project a -scheme -MyScheme"}}' "$_ctx11")
  [ -z "$_o11c" ] || { echo "test-execution-gate: self-test FAIL (valueless flag ate the next token)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # The guard at the unit level, independent of which limb classifies first.
  _o11g="$(strip_nonselecting_flags xcodebuild " -scheme -only-testing:UnitTests/LogTests")"
  _st_cases=$((_st_cases + 1))
  case "$_o11g" in
    *-only-testing:UnitTests/LogTests*) : ;;
    *) echo "test-execution-gate: self-test FAIL (strip ate a selector after a valueless flag)"; _fail=$((_fail + 1)) ;;
  esac

  # `-c` is value-taking on some runners and valueless on others. The
  # valueless ones must not consume the token after them: `go test -c` only
  # COMPILES, and rspec's `-c` is --colour, so both were denied as full runs.
  while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    _o14=$(run_gate "$(jq -cn --arg c "$_c" '{tool_name:"Bash",tool_input:{command:$c}}')" "$_ctx11")
    [ -z "$_o14" ] || { echo "test-execution-gate: self-test FAIL (valueless -c must not deny: $_c)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  done <<'EOF'
go test -c
go test -c ./pkg
rspec -c spec/models/user_spec.rb
EOF

  # `go test -c` is build-only, so it is allowed at a BANNED stage too, not
  # merely at DV — the promise that compiling stays permitted everywhere.
  _ctx13="$_tmp/go-compile/.context"; mkdir -p "$_ctx13"
  printf '{"tasks":{"DR0":{"status":"in_progress"}}}' > "$_ctx13/state.json"
  _o15=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"go test -c ./pkg"}}' "$_ctx13")
  [ -z "$_o15" ] || { echo "test-execution-gate: self-test FAIL (go test -c is build-only everywhere)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # The value-taking `-c` runners are unaffected: the value is still consumed,
  # so these stay full runs.
  while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    _o16=$(run_gate "$(jq -cn --arg c "$_c" '{tool_name:"Bash",tool_input:{command:$c}}')" "$_ctx11")
    printf '%s' "$_o16" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
      || { echo "test-execution-gate: self-test FAIL (value-taking -c must still deny: $_c)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  done <<'EOF'
swift test -c release
dotnet test -c Release
go test
rspec
EOF

  # A value-taking configuration flag's value and a redirect are not positional
  # selectors: each of these is still the whole suite, so DV must be denied it.
  while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    _o17=$(run_gate "$(jq -cn --arg c "$_c" '{tool_name:"Bash",tool_input:{command:$c}}')" "$_ctx11")
    printf '%s' "$_o17" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
      || { echo "test-execution-gate: self-test FAIL (flag value or redirect read as a selector: $_c)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  done <<'EOF'
swift test --package-path /abs/pkg
swift test 2>&1
go test -count 1
EOF
  _o17b=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"swift test --filter X --package-path P 2>&1"}}' "$_ctx11")
  [ -z "$_o17b" ] || { echo "test-execution-gate: self-test FAIL (a real selector plus config flags must allow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # FN has no test-execution authority. This passes the day it is written —
  # the stage limb already denies every stage but DV/QA. It is a parity lock
  # against a future edit to that limb quietly dropping the row, not a bug
  # catch, so do not delete it as a test that never fails.
  _ctx12="$_tmp/fn/.context"; mkdir -p "$_ctx12"
  printf '{"tasks":{"FN0":{"status":"in_progress"}}}' > "$_ctx12/state.json"
  _o13=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"swift test"}}' "$_ctx12")
  printf '%s' "$_o13" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (FN must have no test-execution authority)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # RE has no test-execution authority either, and unlike FN it is a stage that
  # routinely wants a full run to confirm a version bump. The pair below is the
  # coupling this gate depends on: a ledger with RE in_progress denies, and the
  # same command with nothing in_progress ALLOWS — so a dispatch loop that marks
  # stages in the Task System only leaves this gate inert, not merely quiet.
  _ctx14="$_tmp/re/.context"; mkdir -p "$_ctx14"
  printf '{"tasks":{"RE0":{"status":"in_progress"}}}' > "$_ctx14/state.json"
  _o20=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"./run-tests.sh"}}' "$_ctx14")
  printf '%s' "$_o20" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (RE must have no test-execution authority)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  # A SETTLED ledger — stages present, none in_progress — now DENIES (#295).
  # This assertion is the reverse of the one shipped alongside the RE pair, and
  # the reversal is the point: "nobody is acting" was being treated as "cannot
  # tell who is acting", so a full suite stayed permitted forever after FN. The
  # fail-open contract is unchanged and is asserted by the no-state.json case
  # above and the ambiguity case below — those are the shapes that protect an
  # unrelated session; a finished worktask is not one of them.
  printf '{"tasks":{"PL0":{"status":"completed"},"RE0":{"status":"completed"}}}' > "$_ctx14/state.json"
  _o21=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"./run-tests.sh"}}' "$_ctx14")
  printf '%s' "$_o21" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (settled ledger must deny)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # A settled ledger must still allow everything that is not a test invocation,
  # or a finished worktask could not run git, gh, or anything else.
  _o22=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"git status"}}' "$_ctx14")
  [ -z "$_o22" ] || { echo "test-execution-gate: self-test FAIL (settled must not block non-test commands)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # Ambiguity — two stages in_progress — still fails OPEN. Denying here would
  # wedge a session the gate cannot reason about.
  printf '{"tasks":{"DV0":{"status":"in_progress"},"QA0":{"status":"in_progress"}}}' > "$_ctx14/state.json"
  _o23=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"./run-tests.sh"}}' "$_ctx14")
  [ -z "$_o23" ] || { echo "test-execution-gate: self-test FAIL (ambiguous ledger must fail open)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # Gradle's task token is found order-independently: flags before the task
  # must classify the same as task-first, in both fail directions.
  while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    _o17=$(run_gate "$(jq -cn --arg c "$_c" '{tool_name:"Bash",tool_input:{command:$c}}')" "$_ctx11")
    printf '%s' "$_o17" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
      || { echo "test-execution-gate: self-test FAIL (flags-before-task gradle must deny: $_c)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  done <<'EOF'
gradle -p . test
./gradlew -p app testDebugUnitTest
EOF
  _o18=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"gradle -p . test --tests com.foo.Bar"}}' "$_ctx11")
  [ -z "$_o18" ] || { echo "test-execution-gate: self-test FAIL (flags-before-task + selector must allow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  _o19=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"gradle -p . assembleAndroidTest"}}' "$_ctx13")
  [ -z "$_o19" ] || { echo "test-execution-gate: self-test FAIL (flags-first assembleAndroidTest is build-only)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # Exit code always 0, even on a deny.
  set +e
  ( run_gate "$_p1" "$_ctx1" >/dev/null 2>&1 )
  _ec=$?
  [ "$_ec" -eq 0 ] || { echo "test-execution-gate: self-test FAIL (non-zero exit on deny path)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # Redundant-run suppression: one smoke case. The eleven behavioural cases
  # (edit re-enables, cross-stage, fail-open, the hatch) live in the bats suite;
  # this only proves the path is wired, and it needs a real repo because the
  # fingerprint is the tree.
  if command -v git >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1; then
    _ctxd="$_tmp/dedupe"; mkdir -p "$_ctxd/.context"
    ( cd "$_ctxd" \
      && git init -q \
      && git config user.email t@example.com \
      && git config user.name t \
      && git config commit.gpgsign false \
      && echo seed > src.txt && git add -A && git commit -qm init ) >/dev/null 2>&1
    printf '{"run_index":0,"tasks":{"QA0":{"status":"in_progress"}}}' > "$_ctxd/.context/state.json"
    _pd='{"tool_name":"Bash","tool_input":{"command":"./run-tests.sh"}}'
    _pdok='{"tool_name":"Bash","tool_input":{"command":"./run-tests.sh"},"tool_response":{"stdout":"7 tests, 0 failures"}}'
    _promote="$(dirname "$0")/test-execution-promote.sh"
    _od1=$( cd "$_ctxd" && run_gate "$_pd" "$_ctxd/.context" )
    # The PreToolUse marker denies nothing until the companion promotes it: a
    # deny here would mean an invocation that produced nothing had claimed the
    # tree, which is the whole defect this handshake removes.
    _od1b=$( cd "$_ctxd" && run_gate "$_pd" "$_ctxd/.context" )
    printf '%s' "$_pdok" | env -u WORKSPACE_ROOT CLAUDE_PROJECT_DIR="$_ctxd" bash "$_promote" >/dev/null 2>&1
    _od2=$( cd "$_ctxd" && run_gate "$_pd" "$_ctxd/.context" )
    [ -z "$_od1" ] \
      || { echo "test-execution-gate: self-test FAIL (first run should allow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
    [ -z "$_od1b" ] \
      || { echo "test-execution-gate: self-test FAIL (unpromoted marker must not deny)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
    printf '%s' "$_od2" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
      || { echo "test-execution-gate: self-test FAIL (promoted run should dedupe)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  fi

  # node is a runner only with --test; a bare script run is not test execution.
  _ctxn="$_tmp/node/.context"; mkdir -p "$_ctxn"
  printf '{"tasks":{"DR0":{"status":"in_progress"}}}' > "$_ctxn/state.json"
  _on1=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"node --test test/"}}' "$_ctxn")
  printf '%s' "$_on1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (node --test must deny at DR)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  _on2=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"node scripts/build.js"}}' "$_ctxn")
  [ -z "$_on2" ] || { echo "test-execution-gate: self-test FAIL (bare node must allow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # A command that only NAMES runners in its payload executes nothing.
  _op1=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"jq -cn --arg m \"ran bats; pytest tests/\" \"{note:$m}\""}}' "$_ctxn")
  [ -z "$_op1" ] || { echo "test-execution-gate: self-test FAIL (prose naming runners must allow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # Wrappers from the shared definition: timeout, a subshell and ksh -c classify on the runner.
  for _ow in 'timeout -s KILL 60 bats t' '(cd r && pytest tests/)' "ksh -c 'pytest'"; do
    _ow1=$(run_gate "$(jq -cn --arg c "$_ow" '{tool_name: "Bash", tool_input: {command: $c}}')" "$_ctxn")
    printf '%s' "$_ow1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
      || { echo "test-execution-gate: self-test FAIL (wrapped runner must deny: $_ow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  done
  _ow2=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"timeout 5 ls"}}' "$_ctxn")
  [ -z "$_ow2" ] || { echo "test-execution-gate: self-test FAIL (timeout-wrapped ls must allow)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # A settled ledger whose verification stage recorded a no-go keeps authority.
  _ctxr="$_tmp/remediate/.context"; mkdir -p "$_ctxr"
  printf '{"tasks":{"DV0":{"status":"completed","verdict":"ok"},"QA0":{"status":"completed","verdict":"no-go"}}}' > "$_ctxr/state.json"
  _or1=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"./run-tests.sh"}}' "$_ctxr")
  [ -z "$_or1" ] || { echo "test-execution-gate: self-test FAIL (open no-go must retain QA authority)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  printf '{"tasks":{"DV0":{"status":"completed","verdict":"ok"},"QA0":{"status":"completed","verdict":"go"}}}' > "$_ctxr/state.json"
  _or2=$(run_gate '{"tool_name":"Bash","tool_input":{"command":"./run-tests.sh"}}' "$_ctxr")
  printf '%s' "$_or2" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || { echo "test-execution-gate: self-test FAIL (flipped verdict must close the window)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  if [ "$_fail" -ne 0 ]; then
    echo "test-execution-gate: self-test FAIL ($(($_st_cases - _fail)) passed, $_fail failed)"
    exit 1
  fi
  echo "test-execution-gate: self-test OK ($_st_cases passed, 0 failed)"
  exit 0
