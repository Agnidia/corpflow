#!/usr/bin/env bats
# Contract tests for skills/worktask/scripts/handoff-harness.sh.
# Contracts (from header):
#   - default run (--out DIR): generates synthetic artifacts, computes token reduction,
#     reports >=30% on all stages (AC-12), "PASS: all stages"; exit 0
#   - --validate-frontmatter <file>: valid frontmatter => "ok: ... stage=X tokens=N", exit 0
#   - --validate-frontmatter <file>: missing frontmatter => "fail: missing", exit 1
#   - --validate-state <state.json>: valid state => "ok: ... idempotent=yes", exit 0
#   - --validate-state <bad>: invalid JSON => "fail: state.json invalid JSON", exit 1
#   - --self-test => "ALL PASS", exit 0
#   - unknown arg => usage exit 2
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/worktask/scripts/handoff-harness.sh"

# The stage's required H2s, read from the allow-list so a fixture tracks the harness's H2 gate.
anchor_h2s() {  # <stage>
  bash "$PLUGIN_ROOT/skills/worktask/scripts/cache-lint.sh" --allow-list --stage "$1" \
    | awk -F'\t' '$4 == "required" { printf "\n## %s\n\nx\n", $5 }'
}

setup() {
  WD="$(mk_tmpworkdir)"
  # Use our shared DV fixture which has valid frontmatter + DV anchors.
  cp "$FIXTURES/worktask/development-0.sample.md" "$WD/development-0.md"
  cp "$FIXTURES/worktask/state.sample.json" "$WD/state.json"
  # A file with NO frontmatter (to trigger the "fail: missing" path).
  printf '# plain markdown\nno frontmatter here\n' > "$WD/plain.md"
  # Corrupt JSON for --validate-state failure test.
  printf 'not json {{' > "$WD/corrupt.json"
}

@test "happy: default run (--out DIR) reports token reduction >=30% on all stages" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --out "$WD/out"
  assert_success
  assert_output --partial "PASS: all stages"

  # Re-derive the claim from the table's own numbers rather than asserting that
  # a "%" appeared somewhere: the previous spot-check was satisfied by the
  # header row alone and could not fail while "PASS: all stages" was asserted.
  local rows=0 line stage baseline new pct want
  while IFS= read -r line; do
    case "$line" in
      *"|"*"|"*"|"*) ;;
      *) continue ;;
    esac
    stage="$(printf '%s' "$line" | awk -F'|' '{gsub(/ /,"",$1); print $1}')"
    case "$stage" in stage|*-*|'') continue ;; esac
    baseline="$(printf '%s' "$line" | awk -F'|' '{gsub(/ /,"",$2); print $2}')"
    new="$(printf '%s' "$line" | awk -F'|' '{gsub(/ /,"",$3); print $3}')"
    pct="$(printf '%s' "$line" | awk -F'|' '{gsub(/[ %]/,"",$4); print $4}')"
    rows=$((rows + 1))
    [ "$baseline" -gt 0 ]
    # AC-12: the anchored prompt must be at most 70% of the inlined baseline.
    [ $((new * 100)) -le $((baseline * 70)) ] \
      || fail "stage=$stage new=$new is more than 70% of baseline=$baseline"
    # The printed percentage must be the one those two numbers imply.
    want="$(awk -v l="$baseline" -v n="$new" 'BEGIN { printf "%.0f", (l-n)*100.0/l }')"
    [ "$pct" = "$want" ] \
      || fail "stage=$stage printed reduction ${pct}% but numbers imply ${want}%"
  done <<< "$output"
  [ "$rows" -ge 5 ] || fail "expected a row per stage, parsed $rows"

  # Independent corroboration in bytes: the generated artifacts are what the
  # baseline inlines, so the winning prompt must be far smaller than they are.
  local artifact_bytes new_bytes
  artifact_bytes="$(cat "$WD/out/.context/"*.md "$WD/out/.context/state.json" | wc -c | tr -d ' ')"
  [ "$artifact_bytes" -gt 0 ]
  new_bytes="$(wc -c < "$WD/out/.context/state.json" | tr -d ' ')"
  [ $((new_bytes * 100)) -le $((artifact_bytes * 70)) ]
}

@test "happy: --validate-frontmatter on a valid DV artifact passes (exit 0)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/development-0.md"
  assert_success
  assert_output --partial "ok:"
  assert_output --partial "stage=DV"
  assert_output --partial "tokens="
}

@test "happy: --validate-frontmatter accepts the optional acted_on_msg_id (exit 0)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$FIXTURES/worktask/ack/development-acted-m2.md"
  assert_success
  assert_output --partial "ok:"
  assert_output --partial "stage=DV"
}

@test "edge: --validate-state on a valid state.json passes (exit 0, idempotent=yes)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-state "$WD/state.json"
  assert_success
  assert_output --partial "ok:"
  assert_output --partial "idempotent=yes"
}

@test "failure: --validate-frontmatter on a no-frontmatter file fails (exit 1)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/plain.md"
  assert_failure 1
  assert_output --partial "fail:"
  assert_output --partial "missing frontmatter"
}

# Counts the extractor's leftovers in the directory `mktemp -t` actually uses.
# BSD mktemp's -t ignores TMPDIR, so the count has to be taken where the file
# really lands rather than in a redirected fixture directory — a redirected one
# stays empty whether or not the cleanup works, which is a vacuous assertion.
_fm_temp_count() {
  ls "${TMPDIR:-/tmp}"/handoff-fm-* 2>/dev/null | wc -l | tr -d ' '
}

@test "cleanup: no frontmatter temp file survives, on the pass or the fail path" {
  # Fourteen exits used to carry their own `rm -f`; one RETURN trap now does it,
  # so this checks the property rather than the arms.
  local before
  before="$(_fm_temp_count)"

  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/development-0.md"
  assert_success
  [ "$(_fm_temp_count)" = "$before" ] || fail "pass path leaked a handoff-fm temp file"

  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/plain.md"
  assert_failure 1
  [ "$(_fm_temp_count)" = "$before" ] || fail "fail path leaked a handoff-fm temp file"
}

@test "failure: --validate-state on corrupt JSON fails (exit 1)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-state "$WD/corrupt.json"
  assert_failure 1
  assert_output --partial "fail:"
  assert_output --partial "invalid JSON"
}

@test "failure: unknown argument exits 2 (usage)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --bogus
  assert_failure 2
}

# A DV artifact with one bats entry of the given count (or `[]` for an empty list) and an
# optional test_suite_compiles, and nothing else that could fail — so a failure here is
# this arm and no other.
_dv_test_evidence_artifact() {  # <path> <count|[]> [test_suite_compiles]
  local _compiles="${3:-}"
  {
    printf -- '---\n'
    printf 'handoff:\n'
    printf '  stage: DV\n'
    printf '  verdict: ok\n'
    printf '  summary: "test evidence fixture"\n'
    if [ "$2" = "[]" ]; then
      printf '  tests_executed: []\n'
    else
      printf '  tests_executed:\n'
      printf '    - { runner: bats, count: %s, summary_line: "%s tests, 0 failures" }\n' "$2" "$2"
    fi
    if [ -n "$_compiles" ]; then printf '  test_suite_compiles: %s\n' "$_compiles"; fi
    printf '  files_touched: [a.md]\n'
    printf '  next_stage_focus: "DR reviews"\n'
    printf '  open_questions: []\n'
    printf '  refs:\n'
    printf '    dev: development-0.md#files-changed\n'
    printf -- '---\n\n# Development\n\n## verification-command\n\n%s tests, 0 failures\n\n## files-changed\n\nx\n\n## tests-added\n\nx\n\n## deviations\n\nx\n\n## follow-ups\n\nx\n\n## elicitation-sweep\n\nnothing to ask\n' "$2"
  } > "$1"
}

@test "test-evidence: every count 0 with no test_suite_compiles fails (F-02)" {
  # The ambiguity the field exists to remove: a stage denied a run and a stage
  # whose suite never compiled both reported nothing, and the two were
  # indistinguishable to every reader downstream for ten hours of one run.
  local a="$WD/te-0.md"
  _dv_test_evidence_artifact "$a" 0
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$a"
  assert_failure 1
  assert_output --partial "fail: stage=DV reports no executed tests (an empty tests_executed list or every count 0) with no test_suite_compiles"
}

@test "test-evidence: an empty list with no test_suite_compiles fails; unknown clears it" {
  local a="$WD/te-empty.md"
  _dv_test_evidence_artifact "$a" "[]"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$a"
  assert_failure 1
  assert_output --partial "reports no executed tests (an empty tests_executed list or every count 0) with no test_suite_compiles"

  _dv_test_evidence_artifact "$a" "[]" unknown
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$a"
  assert_success
}

@test "test-evidence: all three legal values clear a zero count" {
  # `unknown` included, deliberately: a stage that genuinely cannot tell must be
  # able to say so rather than pick one and be wrong.
  local a="$WD/te-1.md" v
  for v in true false unknown; do
    _dv_test_evidence_artifact "$a" 0 "$v"
    run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$a"
    assert_success
  done
}

@test "test-evidence: a non-zero count needs no test_suite_compiles" {
  local a="$WD/te-2.md"
  _dv_test_evidence_artifact "$a" 12
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$a"
  assert_success
}

@test "test-evidence: a value outside the enum is refused, not accepted as truthy" {
  # `yes` reads as an answer and carries none of the three meanings.
  local a="$WD/te-3.md"
  _dv_test_evidence_artifact "$a" 0 yes
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$a"
  assert_failure
  [[ "$output" == *"expected true, false or unknown"* ]] || fail "$output"
}

@test "test-evidence: an invalid entry is reported once, not again as missing compile evidence" {
  local a="$WD/te-4.md"
  _dv_test_evidence_artifact "$a" x
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$a"
  assert_failure 1
  assert_output --partial 'tests_executed[0] runner=bats count is "x"'
  [[ "$output" != *"no test_suite_compiles"* ]] || fail "double report: $output"
}

# --- per-runner entries: each count is checked against its runner's own words ---

# mk_te <path> <stage> <entries-yaml> [body-line]...
# <entries-yaml> is the indented list under `tests_executed:`, or `[]`; every further
# argument is one body line under the verification heading, so corroborated and
# uncorroborated lines come from the same generator.
mk_te() {
  local out="$1" stage="$2" entries="$3" line
  shift 3
  {
    echo '---'
    echo 'handoff:'
    echo "  stage: $stage"
    echo '  verdict: ok'
    echo '  summary: "ad4 fixture"'
    if [ "$entries" = "[]" ]; then
      echo '  tests_executed: []'
    else
      echo '  tests_executed:'
      printf '%s\n' "$entries"
    fi
    echo '  test_suite_compiles: true'
    echo '  files_touched: [a.sh]'
    echo '  key_decisions: []'
    echo '  next_stage_focus: "next stage"'
    echo '  open_questions: []'
    echo '  refs: { dev: development.md#files-changed }'
    echo '---'
    echo
    echo '# Artifact'
    echo
    if [ "$stage" = DV ]; then echo '## verification-command'; else echo '### verification-command'; fi
    echo
    for line in "$@"; do echo "$line"; done
    echo
    anchor_h2s "$stage"; echo
    echo '## elicitation-sweep'
    echo
    echo 'nothing to ask'
  } > "$out"
}

# mk_te_legacy <path> <stage> <scalar> <legacy-top-level-line-yaml|-> <body-line|->
mk_te_legacy() {
  {
    echo '---'
    echo 'handoff:'
    echo "  stage: $2"
    echo '  verdict: ok'
    echo '  summary: "legacy fixture"'
    echo "  tests_executed: $3"
    [ "$4" = "-" ] || echo "  test_summary_line: $4  # legacy shape"
    echo '  files_touched: [a.sh]'
    echo '  key_decisions: []'
    echo '  next_stage_focus: "next stage"'
    echo '  open_questions: []'
    echo '  refs: { dev: development.md#files-changed }'
    echo '---'
    echo
    echo '# Artifact'
    echo
    [ "$5" = "-" ] || echo "$5"
    echo
    anchor_h2s "$2"; echo
    echo '## elicitation-sweep'
    echo
    echo 'nothing to ask'
  } > "$1"
}

@test "entries: a two-runner list with both lines in the body passes" {
  mk_te "$WD/te-two.md" DV '    - { runner: bats, count: 12, summary_line: "1..12" }
    - { runner: pytest, count: 3, summary_line: "3 passed in 0.4s" }' '1..12' '3 passed in 0.4s'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-two.md"
  assert_success
  [[ "$output" != *"warn: stage=DV tests_executed"* ]] || fail "a clean list warned: $output"
}

@test "entries: a scalar count fails without the legacy opt-in and names the scalar" {
  local stage
  for stage in DV QA; do
    mk_te_legacy "$WD/te-scalar-$stage.md" "$stage" 12 '"12 tests, 0 failures"' '12 tests, 0 failures'
    run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-scalar-$stage.md"
    assert_failure 1
    assert_output --partial "fail: stage=$stage tests_executed is a scalar (\"12\") — record one entry per runner: tests_executed: [{runner, count, summary_line}]; a legacy scalar validates only under --legacy-tests-executed"
    [[ "$output" != *"is a legacy scalar"* ]] || fail "deprecation warn without the opt-in: $output"
  done
}

@test "entries: a map fails in every mode" {
  mk_te "$WD/te-map.md" DV '    runner: bats
    count: 12
    summary_line: "1..12"' '1..12'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-map.md"
  assert_failure 1
  assert_output --partial "fail: stage=DV tests_executed is a map, not a list — record one entry per runner"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-map.md" --legacy-tests-executed
  assert_failure 1
  assert_output --partial "tests_executed is a map, not a list"
}

@test "entries: a non-map entry fails and the entries after it are still checked" {
  mk_te "$WD/te-nonmap.md" DV '    - 12
    - { count: 3, summary_line: "3 passed" }' '3 passed'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-nonmap.md"
  assert_failure 1
  assert_output --partial "fail: stage=DV tests_executed[0] is not a map — each entry is {runner, count, summary_line}"
  assert_output --partial "fail: stage=DV tests_executed[1] has no runner"
}

@test "entries: a missing or blank runner fails and names runner" {
  local r
  for r in '' 'runner: "   ", ' 'runner: 7, '; do
    mk_te "$WD/te-norunner.md" DV "    - { ${r}count: 12, summary_line: \"1..12\" }" '1..12'
    run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-norunner.md"
    assert_failure 1
    assert_output --partial "fail: stage=DV tests_executed[0] has no runner — name the runner that produced this count as a non-empty string (bats, pytest, swift, …)"
  done
}

@test "entries: runner and count faults in one entry are reported independently" {
  mk_te "$WD/te-both.md" DV '    - { count: "x" }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-both.md"
  assert_failure 1
  assert_output --partial "tests_executed[0] has no runner"
  assert_output --partial 'tests_executed[0] runner= count is "x"'
}

@test "entries: a count that is not plain digits fails" {
  local c
  for c in '"12"' '-1' '1e3' '"1841 (scoped)"'; do
    mk_te "$WD/te-count.md" DV "    - { runner: bats, count: $c, summary_line: \"1..12\" }" '1..12'
    run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-count.md"
    assert_failure 1
    assert_output --partial "tests_executed[0] runner=bats count is"
    assert_output --partial "a count is a whole number and nothing else"
  done
}

@test "entries: every bad entry gets its own failure line in one run" {
  # Collect-all: four independent faults, one per entry, and the good entry stays silent.
  mk_te "$WD/te-many.md" DV '    - { runner: bats, count: 12, summary_line: "1..12" }
    - { runner: pytest, count: "1841 (scoped)", summary_line: "1841 passed" }
    - { runner: swift, count: 4000 }
    - { runner: gradle, count: 7, summary_line: "all green" }
    - { runner: vitest, count: 9, summary_line: "9 passed" }' '1..12' '1841 passed'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-many.md"
  assert_failure 1
  assert_output --partial 'fail: stage=DV tests_executed[1] runner=pytest count is "1841 (scoped)"'
  assert_output --partial "fail: stage=DV tests_executed[2] runner=swift reports count: 4000 with no summary_line — copy the runner's own summary line in verbatim"
  assert_output --partial 'fail: stage=DV tests_executed[3] runner=gradle summary_line carries no digit: "all green"'
  assert_output --partial 'fail: stage=DV tests_executed[4] runner=vitest summary_line is uncorroborated: "9 passed" appears neither in te-many.md nor in a .context/logs/ capture it names'
  [[ "$output" != *"tests_executed[0]"* ]] || fail "the valid entry was reported: $output"
  [ "$(printf '%s\n' "$output" | grep -c '^fail: stage=DV tests_executed\[')" -eq 4 ] || fail "$output"
}

@test "entries: a blank summary line carries no digit" {
  mk_te "$WD/te-blank.md" DV '    - { runner: bats, count: 12, summary_line: "   " }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-blank.md"
  assert_failure 1
  assert_output --partial "tests_executed[0] runner=bats summary_line carries no digit"
}

@test "entries: a named log capture corroborates the line" {
  # The second legal home: a runner whose tally reaches only a terminal is captured to
  # .context/logs/ and the artifact names the capture, glob included.
  mkdir -p "$WD/logs"
  printf 'run 1\n12 tests, 0 failures\n' > "$WD/logs/dv-bats-1.log"
  mk_te "$WD/te-log.md" DV '    - { runner: bats, count: 12, summary_line: "12 tests, 0 failures" }' \
    'capture: .context/logs/dv-bats-*.log'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-log.md"
  assert_success
}

@test "entries: a bash-live count the line does not name warns once with one audit row, not a block" {
  # Warn-only for a free-form runner: a live script prints what its author chose, and
  # blocking on the token would fail a stage that satisfies the contract.
  mkdir -p "$WD/logs"
  mk_te "$WD/te-live.md" DV '    - { runner: bash-live, count: 12, summary_line: "RESULT: PASS (run 3)" }
    - { runner: pytest, count: 3, summary_line: "3 passed in 0.4s" }' 'RESULT: PASS (run 3)' '3 passed in 0.4s'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-live.md"
  assert_success
  assert_output --partial 'warn: stage=DV tests_executed[0] runner=bash-live count: 12 is not a whole-number token of summary_line "RESULT: PASS (run 3)" — the excerpt is corroborated, the count is not; a bash-* script names a .context/logs/ capture whose result line carries the count'
  [[ "$output" != *"fail:"* ]] || fail "the soft tier blocked: $output"
  assert_audit_row count_corroboration --file "$WD/logs/audit.jsonl" --subject DV \
    --count 1 --meta tests_executed=12 --meta runner=bash-live --meta 'summary_line=RESULT: PASS (run 3)'
}

@test "entries: an xcodebuild count the line does not name still warns" {
  mk_te "$WD/te-xc.md" DV '    - { runner: xcodebuild, count: 58, summary_line: "Executed 40 tests, with 0 failures (0 unexpected) in 1.2 (1.3) seconds" }' \
    'Executed 40 tests, with 0 failures (0 unexpected) in 1.2 (1.3) seconds'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-xc.md"
  assert_success
  assert_output --partial 'warn: stage=DV tests_executed[0] runner=xcodebuild count: 58 is not a whole-number token'
}

# A line QA composed from `xcrun xcresulttool get test-results summary` is printed by no runner,
# so it can sit in neither the body nor a log. The capture of that JSON is the evidence instead.
xcresult_summary() {  # <path> <totalTestCount>
  mkdir -p "$(dirname "$1")"
  printf '{"title":"App","result":"Passed","totalTestCount":%s,"passedTests":%s,"failedTests":0,"skippedTests":0,"expectedFailures":0}\n' \
    "$2" "$2" > "$1"
}

XC_ENTRY='    - { runner: xcodebuild, count: 35, summary_line: "35 tests: 35 passed, 0 failed (xcresult summary)" }'

@test "xcresult: a named summary capture whose totalTestCount equals count corroborates the line" {
  xcresult_summary "$WD/logs/qa0-xcresult-summary.json" 35
  mk_te "$WD/qa-xc.md" QA "$XC_ENTRY" 'capture: .context/logs/qa0-xcresult-summary.json'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/qa-xc.md"
  assert_success
  refute_output --partial 'summary_line is uncorroborated'
}

@test "xcresult: an unequal total, a non-summary capture or no named capture still fails" {
  xcresult_summary "$WD/logs/qa0-xcresult-summary.json" 34
  mk_te "$WD/qa-xc34.md" QA "$XC_ENTRY" 'capture: .context/logs/qa0-xcresult-summary.json'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/qa-xc34.md"
  assert_failure 1
  assert_output --partial 'runner=xcodebuild summary_line is uncorroborated'
  assert_output --partial 'xcresulttool summary whose totalTestCount is 35'

  printf '{}\n' > "$WD/logs/other.json"
  mk_te "$WD/qa-xcother.md" QA "$XC_ENTRY" 'capture: .context/logs/other.json'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/qa-xcother.md"
  assert_failure 1
  assert_output --partial 'summary_line is uncorroborated'

  # The right capture on disk proves nothing until the artifact names it.
  xcresult_summary "$WD/logs/qa0-xcresult-summary.json" 35
  mk_te "$WD/qa-xcnone.md" QA "$XC_ENTRY" 'see the bundle'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/qa-xcnone.md"
  assert_failure 1
  assert_output --partial 'summary_line is uncorroborated'
}

@test "xcresult: the summary arm is xcodebuild-only and needs the count in the line" {
  xcresult_summary "$WD/logs/qa0-xcresult-summary.json" 35
  mk_te "$WD/qa-xcpy.md" QA '    - { runner: pytest, count: 35, summary_line: "35 tests: 35 passed, 0 failed (xcresult summary)" }' \
    'capture: .context/logs/qa0-xcresult-summary.json'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/qa-xcpy.md"
  assert_failure 1
  assert_output --partial 'runner=pytest summary_line is uncorroborated'
  refute_output --partial 'xcresulttool summary whose totalTestCount'

  mk_te "$WD/qa-xcnotok.md" QA '    - { runner: xcodebuild, count: 35, summary_line: "3 suites passed (xcresult summary)" }' \
    'capture: .context/logs/qa0-xcresult-summary.json'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/qa-xcnotok.md"
  assert_failure 1
  assert_output --partial 'summary_line is uncorroborated'
}

@test "entries: a bats count the TAP plan does not name fails (strict)" {
  mkdir -p "$WD/logs"
  mk_te "$WD/te-tap.md" DV '    - { runner: bats, count: 1814, summary_line: "1..840" }' '1..840'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-tap.md"
  assert_failure 1
  assert_output --partial 'fail: stage=DV tests_executed[0] runner=bats count: 1814 is not a whole-number token of summary_line "1..840"'
  [[ ! -f "$WD/logs/audit.jsonl" ]] || ! grep -q count_corroboration "$WD/logs/audit.jsonl" \
    || fail "a strict fail wrote a warn-tier audit row"
}

@test "entries: every strict runner name fails a count-less line (strict)" {
  local r
  for r in gradle gradlew Gradle junit junit5 swift-testing vitest jest pytest bats; do
    mk_te "$WD/te-strict.md" DV "    - { runner: $r, count: 58, summary_line: \"BUILD SUCCESSFUL in 4s\" }" 'BUILD SUCCESSFUL in 4s'
    run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-strict.md"
    [[ "$status" -eq 1 ]] || fail "runner=$r exited $status: $output"
    [[ "$output" == *"fail: stage=DV tests_executed[0] runner=$r count: 58 is not a whole-number token"* ]] \
      || fail "runner=$r: $output"
  done
}

@test "entries: a failing pytest line whose outcome counts sum to count passes with no warn (strict)" {
  mkdir -p "$WD/logs"
  mk_te "$WD/te-pyfail.md" DV '    - { runner: pytest, count: 60, summary_line: "1 failed, 57 passed, 2 xfailed, 3 skipped, 4 warnings in 3.2s" }' \
    '1 failed, 57 passed, 2 xfailed, 3 skipped, 4 warnings in 3.2s'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-pyfail.md"
  assert_success
  [[ "$output" != *"is not a whole-number token"* ]] || fail "$output"
  [[ ! -f "$WD/logs/audit.jsonl" ]] || ! grep -q count_corroboration "$WD/logs/audit.jsonl" \
    || fail "a proven sum wrote a warn-tier audit row"
}

@test "entries: a pytest outcome sum that misses count, or counts skipped, still fails (strict)" {
  local line
  # 1 + 56 = 57, not 58; then 57 passed + 1 skipped = 58 only if skipped counted.
  for line in "1 failed, 56 passed in 3.2s" "57 passed, 1 skipped in 3.2s"; do
    mk_te "$WD/te-pymiss.md" DV "    - { runner: pytest, count: 58, summary_line: \"$line\" }" "$line"
    run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-pymiss.md"
    [[ "$status" -eq 1 ]] || fail "line=$line exited $status: $output"
    [[ "$output" == *"fail: stage=DV tests_executed[0] runner=pytest count: 58"* ]] || fail "line=$line: $output"
  done
}

@test "entries: a pytest teardown error on a passing case passes at either honest count (strict)" {
  local count
  # `1 passed, 1 error`: one case whose teardown failed (count 1), or two cases (count 2).
  for count in 1 2; do
    mk_te "$WD/te-pyerr.md" DV "    - { runner: pytest, count: $count, summary_line: \"1 passed, 1 error in 0.1s\" }" '1 passed, 1 error in 0.1s'
    run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-pyerr.md"
    [[ "$status" -eq 0 ]] || fail "count=$count exited $status: $output"
    [[ "$output" != *"is not a whole-number token"* ]] || fail "count=$count: $output"
  done
  # Count 1 above is also a token of the line; here neither end of [20, 22] is a token of the
  # line, so the range alone accepts them.
  for count in 20 22; do
    mk_te "$WD/te-pyerr.md" DV "    - { runner: pytest, count: $count, summary_line: \"5 failed, 15 passed, 2 errors in 0.5s\" }" '5 failed, 15 passed, 2 errors in 0.5s'
    run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-pyerr.md"
    [[ "$status" -eq 0 ]] || fail "count=$count exited $status: $output"
    [[ "$output" != *"is not a whole-number token"* ]] || fail "count=$count: $output"
  done
}

@test "entries: a pytest count outside [base, base + errors] still fails (strict)" {
  local count
  # base 30 (10 failed + 20 passed), errors 3: 30..33 are honest; 29 is below, 34 above.
  # Neither number is a token of the line, so only the range decides.
  for count in 29 34; do
    mk_te "$WD/te-pyerr-out.md" DV "    - { runner: pytest, count: $count, summary_line: \"10 failed, 20 passed, 3 errors in 0.1s\" }" '10 failed, 20 passed, 3 errors in 0.1s'
    run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-pyerr-out.md"
    [[ "$status" -eq 1 ]] || fail "count=$count exited $status: $output"
    [[ "$output" == *"fail: stage=DV tests_executed[0] runner=pytest count: $count"* ]] || fail "count=$count: $output"
  done
}

@test "entries: pytest errors with no other outcome prove only a count the line carries (strict)" {
  # `3 errors` may be collection errors, which are no cases: the range is off.
  mk_te "$WD/te-pycoll.md" DV '    - { runner: pytest, count: 2, summary_line: "3 errors in 0.2s" }' '3 errors in 0.2s'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-pycoll.md"
  assert_failure 1
  assert_output --partial 'fail: stage=DV tests_executed[0] runner=pytest count: 2'

  mk_te "$WD/te-pycoll3.md" DV '    - { runner: pytest, count: 3, summary_line: "3 errors in 0.2s" }' '3 errors in 0.2s'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-pycoll3.md"
  assert_success
}

@test "entries: a digit inside a decimal is not a count token (strict)" {
  mk_te "$WD/te-dec.md" DV '    - { runner: jest, count: 1, summary_line: "Done in 0.1s" }' 'Done in 0.1s'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-dec.md"
  assert_failure 1
  assert_output --partial 'fail: stage=DV tests_executed[0] runner=jest count: 1 is not a whole-number token of summary_line "Done in 0.1s"'

  mk_te "$WD/te-dec-ok.md" DV '    - { runner: jest, count: 1, summary_line: "Tests: 1 passed, 1 total in 0.1s" }' 'Tests: 1 passed, 1 total in 0.1s'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-dec-ok.md"
  assert_success
}

@test "entries: a TAP plan counts as its upper bound, never its lower bound (strict)" {
  mk_te "$WD/te-plan.md" DV '    - { runner: bats, count: 840, summary_line: "1..840" }' '1..840'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-plan.md"
  assert_success

  mk_te "$WD/te-plan1.md" DV '    - { runner: bats, count: 1, summary_line: "1..840" }' '1..840'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-plan1.md"
  assert_failure 1
  assert_output --partial 'fail: stage=DV tests_executed[0] runner=bats count: 1 is not a whole-number token of summary_line "1..840"'
}

@test "entries: a one-case TAP plan 1..1 proves count 1 (strict)" {
  mk_te "$WD/te-plan11.md" DV '    - { runner: bats, count: 1, summary_line: "1..1" }' '1..1'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-plan11.md"
  assert_success
}

@test "entries: the outcome-sum rule is pytest only; vitest with no total still fails (strict)" {
  mk_te "$WD/te-vsum.md" DV '    - { runner: vitest, count: 58, summary_line: "1 failed, 57 passed" }' '1 failed, 57 passed'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-vsum.md"
  assert_failure 1
  assert_output --partial 'fail: stage=DV tests_executed[0] runner=vitest count: 58'
}

@test "entries: a gradle BUILD SUCCESSFUL line fails and names junit-tally.sh" {
  mk_te "$WD/te-gradle.md" DV '    - { runner: gradle, count: 58, summary_line: "BUILD SUCCESSFUL in 4s" }' 'BUILD SUCCESSFUL in 4s'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-gradle.md"
  assert_failure 1
  assert_output --partial 'fail: stage=DV tests_executed[0] runner=gradle count: 58 is not a whole-number token of summary_line "BUILD SUCCESSFUL in 4s"'
  assert_output --partial 'run skills/worktask/scripts/junit-tally.sh <results-dir>'
}

@test "entries: a gradle junit-tally line in a named logs capture passes" {
  mkdir -p "$WD/logs"
  printf 'JUnit XML tally: 58 tests executed, 0 failures, 0 errors, 0 skipped\n' > "$WD/logs/dv0-junit-tally.log"
  mk_te "$WD/te-tally.md" DV '    - { runner: gradle, count: 58, summary_line: "JUnit XML tally: 58 tests executed, 0 failures, 0 errors, 0 skipped" }' \
    'Capture: .context/logs/dv0-junit-tally.log'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-tally.md"
  assert_success
  [[ "$output" != *"fail:"* ]] || fail "$output"
  [[ "$output" != *"is not a whole-number token"* ]] || fail "$output"
}

@test "entries: a replayed QA gradle BUILD SUCCESSFUL line fails" {
  mk_te "$WD/te-qa-gradle.md" QA '    - { runner: gradle, count: 58, summary_line: "BUILD SUCCESSFUL in 4s" }' 'BUILD SUCCESSFUL in 4s'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-qa-gradle.md"
  assert_failure 1
  assert_output --partial 'fail: stage=QA tests_executed[0] runner=gradle count: 58 is not a whole-number token'
  assert_output --partial 'junit-tally.sh'
}

@test "entries: a zero count needs no summary_line" {
  mk_te "$WD/te-zero.md" DV '    - { runner: bats, count: 0 }
    - { runner: pytest, count: 3, summary_line: "3 passed" }' '3 passed'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-zero.md"
  assert_success
}

@test "entries: QA carries the list too, and an empty QA list needs no compile evidence" {
  # QA is the sole holder of full-suite authority, so the arm that checks counts must
  # reach it.
  mk_te "$WD/te-qa.md" QA '    - { runner: bats, count: 840, summary_line: "1..840" }' '1..840'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-qa.md"
  assert_success

  mk_te "$WD/te-qa-absent.md" QA '    - { runner: bats, count: 840 }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-qa-absent.md"
  assert_failure 1
  assert_output --partial "stage=QA tests_executed[0] runner=bats reports count: 840 with no summary_line"

  mk_te "$WD/te-qa-empty.md" QA '[]'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-qa-empty.md"
  assert_success
}

@test "entries: a QA artifact with no tests_executed at all fails the required set" {
  {
    echo '---'
    echo 'handoff:'
    echo '  stage: QA'
    echo '  verdict: go'
    echo '  summary: "no count"'
    echo '  files_touched: [a.sh]'
    echo '  key_decisions: []'
    echo '  open_questions: []'
    echo '  refs: { qa: testing.md#results }'
    echo '---'
    echo
    echo '# QA'
  } > "$WD/ad4-qa-nofield.md"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/ad4-qa-nofield.md"
  assert_failure
  [[ "$output" == *"missing required field: tests_executed"* ]] || fail "$output"
}

@test "entries: a stray top-level summary line beside a list warns and is never evidence" {
  mk_te "$WD/te-stray.md" DV '    - { runner: bats, count: 12, summary_line: "1..12" }
  test_summary_line: "1..12"  # legacy key beside a list' '1..12'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-stray.md"
  assert_success
  assert_output --partial "warn: stage=DV carries a legacy top-level test_summary_line next to a tests_executed list — it is ignored as evidence; move it into that runner's summary_line and delete the top-level key"
  [ "$(printf '%s\n' "$output" | grep -c 'carries a legacy top-level')" -eq 1 ] || fail "$output"

  # Never evidence: the top-level line cannot stand in for an entry's missing one.
  mk_te "$WD/te-stray2.md" DV '    - { runner: bats, count: 12 }
  test_summary_line: "1..12"  # legacy key beside a list' '1..12'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-stray2.md"
  assert_failure 1
  assert_output --partial "tests_executed[0] runner=bats reports count: 12 with no summary_line"
}

# --- legacy scalar opt-in ------------------------------------------------------

@test "legacy: the flag validates a corroborated scalar with exactly one deprecation warn" {
  mk_te_legacy "$WD/te-legacy.md" DV 12 '"12 tests, 0 failures"' '12 tests, 0 failures'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-legacy.md" --legacy-tests-executed
  assert_success
  assert_output --partial "warn: stage=DV tests_executed is a legacy scalar, validated under --legacy-tests-executed — deprecated; rewrite it as tests_executed: [{runner, count, summary_line}]"
  [ "$(printf '%s\n' "$output" | grep -c '^warn:.*is a legacy scalar')" -eq 1 ] || fail "$output"
}

@test "legacy: CORPFLOW_LEGACY_TESTS_EXECUTED=1 turns the opt-in on; any other value does not" {
  mk_te_legacy "$WD/te-legacy-env.md" DV 12 '"12 tests, 0 failures"' '12 tests, 0 failures'
  run env CORPFLOW_LEGACY_TESTS_EXECUTED=1 bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-legacy-env.md"
  assert_success
  [ "$(printf '%s\n' "$output" | grep -c 'is a legacy scalar')" -eq 1 ] || fail "$output"

  run env CORPFLOW_LEGACY_TESTS_EXECUTED=true bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-legacy-env.md"
  assert_failure 1
  assert_output --partial 'tests_executed is a scalar ("12")'
}

@test "legacy: the integer rules still apply under the opt-in" {
  mk_te_legacy "$WD/te-legacy-nonnum.md" DV '"1841 (scoped)"' '"1..1841"' '1..1841'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-legacy-nonnum.md" --legacy-tests-executed
  assert_failure 1
  assert_output --partial 'stage=DV legacy tests_executed is "1841 (scoped)"'

  mk_te_legacy "$WD/te-legacy-noline.md" QA 4000 - -
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-legacy-noline.md" --legacy-tests-executed
  assert_failure 1
  assert_output --partial "stage=QA reports legacy tests_executed: 4000 with no test_summary_line"

  mk_te_legacy "$WD/te-legacy-zero.md" DV 0 - -
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-legacy-zero.md" --legacy-tests-executed
  assert_failure 1
  assert_output --partial "stage=DV reports legacy tests_executed: 0 with no test_suite_compiles"
  [ "$(printf '%s\n' "$output" | grep -c 'is a legacy scalar')" -eq 1 ] || fail "$output"
}

@test "legacy: the opt-in never relaxes a list" {
  mk_te "$WD/te-legacy-list.md" DV '    - { count: 12, summary_line: "1..12" }' '1..12'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/te-legacy-list.md" --legacy-tests-executed
  assert_failure 1
  assert_output --partial "tests_executed[0] has no runner"
  [[ "$output" != *"is a legacy scalar"* ]] || fail "a list was treated as legacy: $output"
}

@test "contract: --self-test passes (smoke, NON-counting)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "ALL PASS"
  assert_output --regexp 'ALL PASS \([1-9][0-9]* passed, 0 failed\)'
}

# --- the sweep stub's ref must be anchor-shaped, not merely present ----------

# The item under the anchor for the first id in <stub-yaml>: two options, so only what a
# test plants decides the verdict.
sweep_item_for() {  # <stub-yaml>
  local id
  id="$(printf '%s\n' "$1" | sed -n 's/.*id: *\(sw-[A-Z][A-Z][0-9]*-[0-9]*\).*/\1/p' | head -1)"
  [ -n "$id" ] || { printf 'body\n'; return 0; }
  printf -- '- id: %s\n  summary: "Which way?"\n  options:\n' "$id"
  printf -- '    - { label: "A", detail: "first" }\n    - { label: "B", detail: "second" }\n'
}

# A DV artifact whose only variable is the one sweep stub.
sweep_artifact() {  # <path> <stub-yaml>
  {
    printf -- '---\n'
    printf 'handoff:\n'
    printf '  stage: DV\n'
    printf '  tests_executed: [{ runner: bats, count: 12, summary_line: "12 tests, 0 failures" }]\n'
    printf '  verdict: ok\n'
    printf '  summary: "sweep fixture"\n'
    printf '  files_touched: [a.md]\n'
    printf '  next_stage_focus: "DR reviews"\n'
    printf '  open_questions:\n'
    printf '    - %s\n' "$2"
    printf '  refs:\n'
    printf '    dev: development.md#files-changed\n'
    printf -- '---\n\n# Development\n\n12 tests, 0 failures\n\n## files-changed\n\nx\n\n## tests-added\n\nx\n\n## deviations\n\nx\n\n## follow-ups\n\nx\n\n## elicitation-sweep\n\n'
    sweep_item_for "$2"
  } > "$1"
}

# sweep_artifact with the body under the anchor replaced by <sweep-body>.
item_artifact() {  # <path> <stub-yaml> <sweep-body>
  sweep_artifact "$1" "$2"
  sed '/^## elicitation-sweep$/q' "$1" > "$1.tmp"
  printf '\n%s\n' "$3" >> "$1.tmp"
  mv "$1.tmp" "$1"
}

@test "sweep: an empty ref fails the shape gate" {
  sweep_artifact "$WD/dv-empty-ref.md" '{ id: sw-DV0-1, class: decision, ref: "", blocks_next_stage: false }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-empty-ref.md"
  assert_failure 1
  assert_output --partial "sw-DV0-1 carries no ref anchor"
}

@test "sweep: a ref naming no anchor fails the shape gate" {
  sweep_artifact "$WD/dv-no-anchor.md" '{ id: sw-DV0-1, class: decision, ref: "planning-0.md", blocks_next_stage: false }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-no-anchor.md"
  assert_failure 1
  assert_output --partial "sw-DV0-1 carries no ref anchor"
}

@test "sweep: an uppercase anchor fails — anchors are lowercase-kebab" {
  sweep_artifact "$WD/dv-caps.md" '{ id: sw-DV0-1, class: decision, ref: "planning-0.md#Elicitation_Sweep", blocks_next_stage: false }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-caps.md"
  assert_failure 1
  assert_output --partial "sw-DV0-1 carries no ref anchor"
}

@test "sweep: an anchor-only ref resolves to the emitting artifact and passes" {
  sweep_artifact "$WD/dv-anchor-only.md" '{ id: sw-DV0-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-anchor-only.md"
  assert_success
}

@test "sweep: the class vocabulary is the library's, not a re-spelling" {
  sweep_artifact "$WD/dv-class.md" '{ id: sw-DV0-1, class: question, ref: "#elicitation-sweep", blocks_next_stage: false }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-class.md"
  assert_failure 1
  assert_output --partial "class is not decision|escalate"
}

@test "sweep: a stub omitting blocks_next_stage fails the shape gate" {
  # The field is required, not optional-with-a-default: an absent flag is indistinguishable
  # from an explicit false, and that ambiguity is what let the two transports disagree.
  sweep_artifact "$WD/dv-noflag.md" '{ id: sw-DV0-1, class: decision, ref: "#elicitation-sweep" }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-noflag.md"
  assert_failure 1
  assert_output --partial "sw-DV0-1 carries no blocks_next_stage"
}

# --- the item under the anchor must be a question, not a status note ----------

DSTUB='{ id: sw-DV0-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
ESTUB='{ id: sw-DV0-1, class: escalate, ref: "#elicitation-sweep", blocks_next_stage: false }'

@test "sweep item: a bare status note under the anchor fails, naming the stub id" {
  item_artifact "$WD/dv-note.md" "$DSTUB" '- sw-DV0-1 — reviewed, nothing to decide'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-note.md"
  assert_failure 1
  assert_output --partial "fail: sweep stub sw-DV0-1 is a status note, not a question"
}

@test "sweep item: a decision item with two options passes" {
  item_artifact "$WD/dv-two.md" "$DSTUB" "$(sweep_item_for "$DSTUB")"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-two.md"
  assert_success
}

@test "sweep item: an escalate item standing on an explicit question passes" {
  item_artifact "$WD/dv-esc.md" "$ESTUB" '- id: sw-DV0-1
  summary: "Ship with the token still in the log?"'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-esc.md"
  assert_success
}

@test "sweep item: a question mark does not rescue a decision item with one option" {
  item_artifact "$WD/dv-decq.md" "$DSTUB" '- id: sw-DV0-1
  summary: "Ship with the token still in the log?"
  options:
    - { label: "Ship", detail: "the only option" }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-decq.md"
  assert_failure 1
  assert_output --partial "only an escalate item may stand on a bare question"
}

@test "sweep item: an id absent from the anchor section fails, and sw-DV0-12 does not stand in for sw-DV0-1" {
  item_artifact "$WD/dv-missing.md" "$DSTUB" "$(sweep_item_for 'id: sw-DV0-12')"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-missing.md"
  assert_failure 1
  assert_output --partial "fail: sweep stub sw-DV0-1 has no item under '## elicitation-sweep'"
}

@test "sweep item: options after the next ## heading do not belong to the item" {
  item_artifact "$WD/dv-cut.md" "$DSTUB" '- id: sw-DV0-1
  summary: "Which way?"

## follow-ups

  options:
    - { label: "A", detail: "first" }
    - { label: "B", detail: "second" }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-cut.md"
  assert_failure 1
  assert_output --partial "sw-DV0-1 is a status note"
}

@test "sweep item: every note is reported on its own fail line" {
  item_artifact "$WD/dv-two-notes.md" "$DSTUB
    - { id: sw-DV0-2, class: escalate, ref: \"#elicitation-sweep\", blocks_next_stage: false }" \
    '- sw-DV0-1 — done
- sw-DV0-2 — also done'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-two-notes.md"
  assert_failure 1
  [ "$(printf '%s\n' "$output" | grep -c 'is a status note, not a question')" -eq 2 ] || fail "$output"
}

@test "sweep item: a mention of another sweep id inside the item does not end its block" {
  # Only a line that starts another item ends the block; a cross-reference in the summary
  # must not strand the options below it.
  item_artifact "$WD/dv-xref.md" "$DSTUB" '- id: sw-DV0-1
  summary: "Follow-up to sw-DV0-2: which way?"
  options:
    - { label: "A", detail: "first" }
    - { label: "B", detail: "second" }
- id: sw-DV0-2
  summary: "Unrelated"'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-xref.md"
  assert_success
}

# --- stub parity: id agreement is not agreement -------------------------------
#
# The frontmatter stub and facts.open_questions[] have two writers and no derivation
# between them. Until these cases existed the only cross-check was on id, so an item whose
# ledger copy said `blocks_next_stage: true` beside an artifact saying `false` validated
# clean and the orchestrator held a boundary gate its own author had waived.

parity_state() {  # <path> <class> <blocks|omit>
  local flag="{}"
  [ "$3" = "omit" ] || flag="{\"blocks_next_stage\": $3}"
  jq -n --arg cls "$2" --argjson flag "$flag" \
    '{version: 2, worktask_id: "t", plan_file: ".context/planning-0.md", platform: "all",
      run_index: 0, tasks: {DV0: {status: "in_progress"}},
      facts: {files_modified: [], tests_added: [], decisions: [],
              open_questions: [({id: "sw-DV0-1", class: $cls, ref: "#elicitation-sweep"} + $flag)]},
      handoffs: {}}' > "$1"
}

@test "parity: a blocks_next_stage divergence fails and names both transports" {
  sweep_artifact "$WD/dv-parity-flag.md" '{ id: sw-DV0-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
  parity_state "$WD/state-parity-flag.json" decision true
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-parity-flag.md" --state "$WD/state-parity-flag.json"
  assert_failure 1
  assert_output --partial "blocks_next_stage is false in dv-parity-flag.md but true in facts.open_questions[]"
}

@test "parity: a class divergence fails too — the check is not flag-only" {
  sweep_artifact "$WD/dv-parity-class.md" '{ id: sw-DV0-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
  parity_state "$WD/state-parity-class.json" escalate false
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-parity-class.md" --state "$WD/state-parity-class.json"
  assert_failure 1
  assert_output --partial "class is decision in dv-parity-class.md but escalate in facts.open_questions[]"
}

@test "parity: agreeing transports pass — and an absent ledger flag normalises to false" {
  # Anti-vacuity for the two cases above: the check must fire on divergence and ONLY on
  # divergence, or a legacy ledger row written before the field was required reads as a defect.
  sweep_artifact "$WD/dv-parity-ok.md" '{ id: sw-DV0-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
  parity_state "$WD/state-parity-ok.json" decision omit
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-parity-ok.md" --state "$WD/state-parity-ok.json"
  assert_success
}

@test "parity: the harness refuses, it never reconciles — state.json is untouched" {
  sweep_artifact "$WD/dv-parity-ro.md" '{ id: sw-DV0-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
  parity_state "$WD/state-parity-ro.json" decision true
  cp "$WD/state-parity-ro.json" "$WD/state-parity-ro.snap"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-parity-ro.md" --state "$WD/state-parity-ro.json"
  assert_failure 1
  run diff -q "$WD/state-parity-ro.json" "$WD/state-parity-ro.snap"
  assert_success
}

@test "sweep: a ledger whose facts.open_questions is a string fails, never silently passes" {
  # jq aborts on a scalar there, and an aborted parity read is not evidence of parity:
  # the shapes that break the read are exactly the ones the gate exists to reject.
  sweep_artifact "$WD/dv-scalar-ledger.md" '{ id: sw-DV0-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
  printf '{"facts":{"open_questions":"none"}}\n' > "$WD/state-scalar.json"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-scalar-ledger.md" --state "$WD/state-scalar.json"
  assert_failure 1
  assert_output --partial "could not be read as an array of stubs"
}

# ---------------------------------------------------------------------------
# AR→DV architecture-reference gate (--state / --strict, 3.42.0).
# Ships warn-only: violations are `warn:` + exit 0 unless --strict is passed.
# The cases above this block are the AC-6 baseline pin — they must keep passing
# unmodified, since a bare --validate-frontmatter never runs this gate.
# ---------------------------------------------------------------------------

# Writes a DV artifact whose only variable is the refs block.
dv_artifact() {
  local path="$1" refs="$2"
  {
    printf -- '---\n'
    printf 'handoff:\n'
    printf '  stage: DV\n'
    printf '  tests_executed: [{ runner: bats, count: 12, summary_line: "12 tests, 0 failures" }]\n'
    printf '  verdict: ok\n'
    printf '  summary: "gate fixture"\n'
    printf '  files_touched: [a.md]\n'
    printf '  next_stage_focus: "DR reviews"\n'
    printf '  open_questions: []\n'
    printf '  refs:\n'
    printf '    %s\n' "$refs"
    printf -- '---\n\n# Development\n\n12 tests, 0 failures\n\n## files-changed\n\nx\n\n## tests-added\n\nx\n\n## deviations\n\nx\n\n## follow-ups\n\nx\n\n## elicitation-sweep\n\nnothing to ask\n'
  } > "$path"
}

# state.sample.json has PL only; the gate keys off tasks.AR0 presence.
state_with_ar() {
  jq '.tasks.AR0 = {"status":"completed","verdict":"ok"}' "$WD/state.json" > "$WD/state-ar.json"
}

@test "ar-gate: AR in state + missing ref => warn, exit 0 (default warn-only rollout)" {
  state_with_ar
  dv_artifact "$WD/dv.md" 'dev: development.md#files-changed'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv.md" --state "$WD/state-ar.json"
  assert_success
  assert_output --partial "warn: AR completed but DV refs.decisions missing"
  refute_output --partial "fail:"
}

@test "ar-gate: AR in state + missing ref + --strict => fail, exit 1" {
  state_with_ar
  dv_artifact "$WD/dv.md" 'dev: development.md#files-changed'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv.md" --state "$WD/state-ar.json" --strict
  assert_failure 1
  assert_output --partial "fail: AR completed but DV refs.decisions missing"
}

@test "ar-gate: AR in state + dangling ref => warn exit 0; --strict => fail exit 1" {
  state_with_ar
  dv_artifact "$WD/dv.md" 'decisions: architecture-9.md#decisions'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv.md" --state "$WD/state-ar.json"
  assert_success
  assert_output --partial "warn: DV architecture ref dangling"

  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv.md" --state "$WD/state-ar.json" --strict
  assert_failure 1
  assert_output --partial "fail: DV architecture ref dangling"
}

@test "ar-gate: AR in state + valid ref whose file exists => silent, exit 0 in both modes" {
  state_with_ar
  dv_artifact "$WD/dv.md" 'decisions: architecture-0.md#decisions'
  printf -- '---\nhandoff:\n  stage: AR\n---\n\n# Architecture\n\n## decisions\n' > "$WD/architecture-0.md"

  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv.md" --state "$WD/state-ar.json"
  assert_success
  refute_output --partial "AR completed but"
  refute_output --partial "architecture ref dangling"

  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv.md" --state "$WD/state-ar.json" --strict
  assert_success
  refute_output --partial "fail:"
}

@test "ar-gate: no AR in state + no ref => silent, exit 0" {
  dv_artifact "$WD/dv.md" 'dev: development.md#files-changed'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv.md" --state "$WD/state.json"
  assert_success
  refute_output --partial "AR completed but"
  refute_output --partial "but state has no tasks.AR0"
}

@test "ar-gate: inverse guard — no AR in state + architecture ref => warn, exit 0 in BOTH modes" {
  # `AR<N>` is literal in the warning: the gate matches any AR[0-9]+, so when none exists
  # there is no index to name. Pinning AR0 would contradict the any-instance rule.
  dv_artifact "$WD/dv.md" 'decisions: architecture-0.md#decisions'
  printf -- '---\nhandoff:\n  stage: AR\n---\n\n# Architecture\n' > "$WD/architecture-0.md"

  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv.md" --state "$WD/state.json"
  assert_success
  assert_output --partial "warn: DV references architecture-0.md#decisions but state has no tasks.AR<N> entry"

  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv.md" --state "$WD/state.json" --strict
  assert_success
  assert_output --partial "warn: DV references architecture-0.md#decisions but state has no tasks.AR<N> entry"
  refute_output --partial "fail:"
}

@test "ar-gate: AC-6 baseline pin — no --state means the gate never runs" {
  # Same artifact that warns under --state with AR present: silent without it.
  dv_artifact "$WD/dv.md" 'dev: development.md#files-changed'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv.md"
  assert_success
  assert_output --partial "ok:"
  refute_output --partial "AR completed but"

  # --strict alone is inert without a state file.
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv.md" --strict
  assert_success
  refute_output --partial "fail:"
}

# ---------------------------------------------------------------------------
# Sweep-ledger parity across the open_questions spill (AD-4).
# The newest-12 clamp evicts unresolved items to
# `open-questions-<run_index>.jsonl`; parity reads ledger UNION spill, so an item
# that reached the FN gate through the spill is not reported as dropped.
# ---------------------------------------------------------------------------

# A ledger carrying run_index and an explicit open_questions array.
spill_state() {  # <path> <run_index> <ids-json>
  jq -n --argjson r "$2" --argjson ids "$3" \
    '{version: 2, worktask_id: "t", plan_file: ".context/planning-0.md",
      platform: "all", run_index: $r,
      tasks: {DV0: {status: "in_progress"}},
      facts: {files_modified: [], tests_added: [], decisions: [],
              open_questions: [$ids[] | {id: ., class: "decision",
                                         ref: "#elicitation-sweep"}]},
      handoffs: {}}' > "$1"
}

@test "spill: an item present only in the spill file satisfies ledger parity" {
  sweep_artifact "$WD/dv-spill.md" '{ id: sw-DV0-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
  spill_state "$WD/state-spill.json" 4 '[]'
  printf '%s\n' '{"id":"sw-DV0-1","class":"decision","ref":"#elicitation-sweep","stage":"DV","status":"open","spilled_at":"2026-01-01T00:00:00Z","spilled_from_stage":"DV"}' \
    > "$WD/open-questions-4.jsonl"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-spill.md" --state "$WD/state-spill.json"
  assert_success
}

@test "spill: the same item with NO spill file still fails — parity is not weakened" {
  sweep_artifact "$WD/dv-nospill.md" '{ id: sw-DV0-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
  spill_state "$WD/state-nospill.json" 4 '[]'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-nospill.md" --state "$WD/state-nospill.json"
  assert_failure 1
  assert_output --partial "not in facts.open_questions[]"
}

@test "spill: a malformed spill file fails rather than reading as the empty set" {
  # Treating a corrupt overflow file as "no items" would restore the exact loss the
  # parity check exists to catch, and only in the runs that actually overflowed.
  sweep_artifact "$WD/dv-badspill.md" '{ id: sw-DV0-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
  spill_state "$WD/state-badspill.json" 4 '["sw-DV0-1"]'
  printf 'not json at all\n' > "$WD/open-questions-4.jsonl"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-badspill.md" --state "$WD/state-badspill.json"
  assert_failure 1
  assert_output --partial "not readable as JSON lines"
}

@test "spill: the path derives from the ledger's run_index, never a guess" {
  sweep_artifact "$WD/dv-idx.md" '{ id: sw-DV0-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
  spill_state "$WD/state-idx.json" 7 '[]'
  printf '%s\n' '{"id":"sw-DV0-1"}' > "$WD/open-questions-4.jsonl"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-idx.md" --state "$WD/state-idx.json"
  assert_failure 1
  mv "$WD/open-questions-4.jsonl" "$WD/open-questions-7.jsonl"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-idx.md" --state "$WD/state-idx.json"
  assert_success
}

# ---------------------------------------------------------------------------
# Frontmatter token budget (AD-2): discretionary = total - min(stub block, 64)
# - min(tests_executed block, 96), fail > 200, advisory warn > 360. Sweep stubs and
# runner entries are mandatory evidence, so excluding them stops the budget from
# penalising a stage for asking questions or for recording every runner it ran.
# ---------------------------------------------------------------------------

# A DV artifact padded to an approximate total token count, with <stubs> sweep stubs and
# <runners> list entries (default 1); `bad` emits one entry with an invalid count, `bad:N`
# emits N of them.
budget_artifact() {  # <path> <filler-words> <stubs> [runners|bad|bad:N]
  local path="$1" fill="$2" stubs="$3" runners="${4:-1}" i pad="" nbad=0
  case "$runners" in bad) nbad=1 ;; bad:*) nbad="${runners#bad:}" ;; esac
  for ((i = 0; i < fill; i++)); do pad="$pad w"; done
  {
    printf -- '---\n'
    printf 'handoff:\n'
    printf '  stage: DV\n'
    printf '  tests_executed:\n'
    if [ "$nbad" -gt 0 ]; then
      for ((i = 1; i <= nbad; i++)); do
        printf '    - { runner: bats, count: "x" }\n'
      done
    else
      for ((i = 1; i <= runners; i++)); do
        printf '    - { runner: r%s, count: 12, summary_line: "12 tests, 0 failures" }\n' "$i"
      done
    fi
    printf '  verdict: ok\n'
    printf '  summary: "budget fixture%s"\n' "$pad"
    printf '  files_touched: [a.md]\n'
    printf '  next_stage_focus: "DR reviews"\n'
    printf '  open_questions:\n'
    for ((i = 1; i <= stubs; i++)); do
      printf '    - { id: sw-DV0-%s, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }\n' "$i"
    done
    printf '  refs:\n'
    printf '    dev: development.md#files-changed\n'
    printf -- '---\n\n# Development\n\n12 tests, 0 failures\n\n## files-changed\n\nx\n\n## tests-added\n\nx\n\n## deviations\n\nx\n\n## follow-ups\n\nx\n\n## elicitation-sweep\n\n'
    for ((i = 1; i <= stubs; i++)); do
      sweep_item_for "id: sw-DV0-$i"
    done
  } > "$path"
}

@test "budget: a frontmatter over 200 discretionary tokens now FAILS, not warns" {
  budget_artifact "$WD/dv-fat.md" 200 1
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-fat.md"
  assert_failure 1
  assert_output --partial "discretionary tokens > 200 budget"
}

@test "budget: the four permitted sweep stubs cannot push a compliant artifact over" {
  # Same prose in both files; the only difference is the mandatory stub block. If the
  # stubs were counted, the second call would fail — which is the AC-8 incentive.
  budget_artifact "$WD/dv-lean.md" 120 1
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-lean.md"
  assert_success
  budget_artifact "$WD/dv-lean4.md" 120 4
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-lean4.md"
  assert_success
  # The 4-stub file is over the old flat 200 in TOTAL tokens — the case the old check
  # flagged and the new one deliberately releases.
  assert_output --partial "tokens=2"
}

@test "budget: four runner entries cannot push a compliant artifact over" {
  # Same prose, one runner versus four: folding runners into one entry must never be
  # the way to fit the budget.
  budget_artifact "$WD/dv-run1.md" 120 1 1
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-run1.md"
  assert_success
  budget_artifact "$WD/dv-run4.md" 120 1 4
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-run4.md"
  assert_success
}

@test "budget: the exclusion is capped, so extra stubs cannot buy prose room" {
  # Twelve stubs is three times the per-stage cap; the exclusion still stops at 64
  # tokens, so an artifact this size fails on its prose exactly as it would at four.
  budget_artifact "$WD/dv-gamed.md" 200 12
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-gamed.md"
  assert_failure 1
  assert_output --partial "discretionary tokens > 200 budget"
  # The excluded amount is the cap, not the measured 12-stub block.
  assert_output --partial "- 64 sweep-stub tokens -"
}

@test "budget: the tests_executed exclusion is capped at 96 tokens" {
  budget_artifact "$WD/dv-gamed-te.md" 200 1 12
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-gamed-te.md"
  assert_failure 1
  assert_output --partial "discretionary tokens > 200 budget"
  assert_output --partial "- 96 tests_executed tokens excluded)"
}

@test "budget: an invalid tests_executed list is excluded at the cap and the prose is still checked" {
  budget_artifact "$WD/dv-bad-te.md" 200 1 bad
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-bad-te.md"
  assert_failure 1
  assert_output --partial "(tests_executed invalid: excluded at the 96-token cap) stage=DV frontmatter"
  refute_output --partial "counted in full"
  refute_output --partial "- 0 tests_executed tokens excluded)"
}

@test "budget: an invalid tests_executed block cannot hide prose beyond the 96-token cap" {
  # Thirty bad entries are about 240 tokens; only 96 of them are excluded, so the excess alone
  # carries a frontmatter whose other prose is well inside 200 over the budget.
  budget_artifact "$WD/dv-bad-big.md" 40 1 bad:30
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-bad-big.md"
  assert_failure 1
  assert_output --partial "(tests_executed invalid: excluded at the 96-token cap) stage=DV frontmatter"
  assert_output --partial "- 96 tests_executed tokens excluded)"
}

@test "budget: an uncorroborated entry is one fault, not also a budget failure" {
  # Within 200 once the block is excluded at the cap, over 200 when it is counted: the old
  # full count turned the one evidence fault into two failures.
  local f="$WD/qa-uncorr.md" pad="" i
  mk_te "$f" QA '    - { runner: pytest, count: 35, summary_line: "35 passed, 2 skipped, 1 deselected, 4 warnings in 12.34s on worker gw0 with random seed 12345 and the coverage report written to htmlcov/index.html for review" }' \
    'the run is in the bundle'
  for ((i = 0; i < 115; i++)); do pad="$pad w"; done
  sed "s/summary: \"ad4 fixture\"/summary: \"ad4 fixture$pad\"/" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$f"
  assert_failure 1
  assert_output --partial 'runner=pytest summary_line is uncorroborated'
  refute_output --partial 'discretionary tokens > 200 budget'
  [ "$(printf '%s\n' "$output" | grep -c '^fail:')" -eq 1 ] || fail "expected one fail line: $output"
}

@test "budget: the 360 absolute ceiling is reported alongside the failure" {
  budget_artifact "$WD/dv-huge.md" 260 4
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv-huge.md"
  assert_failure 1
  assert_output --partial "> 360 absolute ceiling"
}

@test "budget: every stage artifact this repo ships passes the promoted gate" {
  # R8 is deliberately breaking; the claim that no in-tree artifact fails it is
  # verified here rather than asserted in prose. Only git-tracked fixtures count: the
  # checkout's run folder holds whatever the last local run left there. Names follow
  # cache-lint.sh --filename-lint: <stage>-N.md, plus DV's development-N-<stream>.md.
  # <stage> is the closed stem set of cache-lint's _STAGE_TABLE, never a generic
  # <word>, so a future non-artifact or deliberately invalid fixture named
  # <word>-N.md is not swept into a gate every artifact must pass.
  local f n=0
  local stems='planning|architecture|coordination|development|developer-review|security-review'
  stems+='|testing|documentation|release|complete-summary|retrospective|incident|ethics-review'
  local -a tracked=()
  # Listed into an array first: `run` inherits stdin and would drain a while-read loop.
  while IFS= read -r f; do tracked+=("$f"); done < <(
    git -C "$PLUGIN_ROOT" ls-files -- tests/fixtures/worktask \
      | grep -E "/(($stems)-[0-9]+|development-[0-9]+(-[a-z0-9]+)+)\.md\$")
  for f in "${tracked[@]}"; do
    run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$PLUGIN_ROOT/$f"
    [ "$status" -eq 0 ] || fail "$f fails the promoted gate: $output"
    n=$((n + 1))
  done
  [ "$n" -ge 1 ] || fail "no tracked stage-artifact fixture found under tests/fixtures/worktask"
}

# --- files_touched structural cap (R-2.1) ------------------------------------

# mk_dv <file> <files_touched-yaml-flow> [body] — a minimal valid DV artifact.
mk_dv_ft() {
  local out="$1" ft="$2"
  {
    echo '---'
    echo 'handoff:'
    echo '  stage: DV'
    echo '  tests_executed: [{ runner: bats, count: 12, summary_line: "12 tests, 0 failures" }]'
    echo '  verdict: ok'
    echo '  summary: "cap fixture"'
    echo "  files_touched: $ft"
    echo '  next_stage_focus: "DR reviews"'
    echo '  open_questions: []'
    echo '  refs: { dev: development.md#files-changed }'
    echo '---'
    echo
    echo '# Development'
    echo
    echo '12 tests, 0 failures'
    echo
    anchor_h2s DV; echo
    echo '## elicitation-sweep'
    echo
    echo 'nothing to ask'
  } > "$out"
}

@test "files_touched: ten paths plus one '+ N more' marker passes" {
  local ft="[a1.sh, a2.sh, a3.sh, a4.sh, a5.sh, a6.sh, a7.sh, a8.sh, a9.sh, a10.sh, \"+ 7 more\"]"
  mk_dv_ft "$WD/capped.md" "$ft"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/capped.md"
  assert_success
}

@test "files_touched: more than FILES_TOUCHED_MAX paths without a marker fails" {
  local ft="[a1.sh, a2.sh, a3.sh, a4.sh, a5.sh, a6.sh, a7.sh, a8.sh, a9.sh, a10.sh, a11.sh]"
  mk_dv_ft "$WD/uncapped.md" "$ft"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/uncapped.md"
  assert_failure
  assert_output --partial "FILES_TOUCHED_MAX=10"
}

@test "files_touched: a marker that is not last fails" {
  local ft="[\"+ 3 more\", a1.sh]"
  mk_dv_ft "$WD/misplaced.md" "$ft"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/misplaced.md"
  assert_failure
  assert_output --partial "not the last entry"
}

# --- decision divergence (R-4.1) ---------------------------------------------

# mk_qa_dec <file> <fm-summary> <body-summary>
mk_qa_dec() {
  {
    echo '---'
    echo 'handoff:'
    echo '  stage: QA'
    echo '  verdict: ok'
    echo '  tests_executed: [{ runner: bats, count: 12, summary_line: "12 tests, 0 failures" }]'
    echo '  summary: "divergence fixture"'
    echo '  files_touched: [a.sh]'
    echo '  key_decisions:'
    echo "    - { id: qa-1, summary: \"$2\" }"
    echo '  open_questions: []'
    echo '  refs: { qa: testing.md#results }'
    echo '---'
    echo
    echo '### decisions'
    echo
    echo "| id | summary |"
    echo "|----|---------|"
    echo "| qa-1 | $3 |"
    echo
    echo '12 tests, 0 failures'
    echo
    anchor_h2s QA; echo
    echo '## elicitation-sweep'
    echo
    echo 'nothing to ask'
  } > "$1"
}

@test "decisions: a body table restating the same decision passes" {
  mk_qa_dec "$WD/agree.md" \
    "Selection runs the full suite because the harness itself changed" \
    "The full suite runs: the harness changed, so a scoped selection proves nothing"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/agree.md"
  assert_success
}

@test "decisions: the same id carrying an unrelated body summary fails, naming both" {
  mk_qa_dec "$WD/diverge.md" \
    "Selection runs the full suite because the harness itself changed" \
    "Screenshots are waived for this platform"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/diverge.md"
  assert_failure
  assert_output --partial "decision qa-1 disagrees across transports"
}

@test "decisions: a restated bound with a different number fails" {
  mk_qa_dec "$WD/numbers.md" \
    "The retry budget for a failing stage is 3 attempts" \
    "The retry budget for a failing stage is 5 attempts"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/numbers.md"
  assert_failure
  assert_output --partial "disagrees across transports"
}

# --- reverse sweep parity, stage-scoped (R-1.3) ------------------------------

@test "sweep parity: a ledger stub for this stage that the artifact omits fails" {
  cd "$WD"
  jq '.facts.open_questions = [{"id":"sw-DV0-9","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false,"stage":"DV","status":"open"}]' \
    state.json > state2.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter development-0.md --state state2.json
  assert_failure
  assert_output --partial "in ledger, not in frontmatter"
}

@test "sweep parity: a resolved ledger stub the artifact omits does not fail a rework round" {
  cd "$WD"
  # The rework topology: round 1 raised sw-DV0-9 and it was answered, so the reworked
  # artifact re-emits only what is still open. Charging it with the answered id fails the
  # round, and Step B.1 reads that as missing_input and re-dispatches the whole stage.
  jq '.facts.open_questions = [{"id":"sw-DV0-9","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false,"stage":"DV","status":"resolved"}]' \
    state.json > state_resolved.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter development-0.md --state state_resolved.json
  assert_success
}

@test "sweep parity: an open ledger stub is still charged when a resolved sibling exists" {
  cd "$WD"
  # Non-vacuity twin: the status filter must not disable the arm wholesale.
  jq '.facts.open_questions = [
        {"id":"sw-DV0-8","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false,"stage":"DV","status":"resolved"},
        {"id":"sw-DV0-9","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false,"stage":"DV","status":"open"}]' \
    state.json > state_mixed.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter development-0.md --state state_mixed.json
  assert_failure
  assert_output --partial "sw-DV0-9"
  refute_output --partial "sw-DV0-8"
}

@test "sweep parity: a ledger stub belonging to another stage is not charged to this one" {
  cd "$WD"
  jq '.facts.open_questions = [{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false,"stage":"PL","status":"open"}]' \
    state.json > state3.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter development-0.md --state state3.json
  assert_success
}

@test "files_touched: two '+ N more' markers fail — the overflow must be declared once" {
  local ft="[a1.sh, \"+ 3 more\", \"+ 4 more\"]"
  mk_dv_ft "$WD/twomarkers.md" "$ft"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/twomarkers.md"
  assert_failure
  assert_output --partial "markers"
}

@test "sweep parity: a split stage charges each stream only its own task's stubs" {
  cd "$WD"
  # DV0 and DV1 both live in the ledger; the DV1 artifact re-emits sw-DV1-1 and must not be
  # charged DV0's sw-DV0-9, which shares the `.stage == "DV"` slice.
  jq '.tasks.DV0 = {status:"completed"} | .tasks.DV1 = {status:"in_progress"}
      | .facts.open_questions = [
          {"id":"sw-DV0-9","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false,"stage":"DV","status":"open"},
          {"id":"sw-DV1-1","class":"decision","ref":"#elicitation-sweep","blocks_next_stage":false,"stage":"DV","status":"open"}]' \
    state.json > state4.json
  sweep_artifact "$WD/dv1.md" '{ id: sw-DV1-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv1.md" --state state4.json
  assert_success
}

@test "sweep parity: a stub-less artifact of a split stage is not guessed onto either stream" {
  cd "$WD"
  jq '.tasks.DV0 = {status:"completed"} | .tasks.DV1 = {status:"in_progress"}
      | .facts.open_questions = [{"id":"sw-DV0-9","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false,"stage":"DV","status":"open"}]' \
    state.json > state5.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter development-0.md --state state5.json
  assert_success
}

# mk_qa_dec_bullet <file> <fm-summary> <body-bullet-line> — the two bullet body forms the
# extractor must reach; the table fixture above covered neither.
mk_qa_dec_bullet() {
  {
    echo '---'
    echo 'handoff:'
    echo '  stage: QA'
    echo '  verdict: ok'
    echo '  tests_executed: [{ runner: bats, count: 12, summary_line: "12 tests, 0 failures" }]'
    echo '  summary: "divergence fixture"'
    echo '  files_touched: [a.sh]'
    echo '  key_decisions:'
    echo "    - { id: qa-1, summary: \"$2\" }"
    echo '  open_questions: []'
    echo '  refs: { qa: testing.md#results }'
    echo '---'
    echo
    echo '### decisions'
    echo
    echo "$3"
    echo
    echo '12 tests, 0 failures'
    echo
    anchor_h2s QA; echo
    echo '## elicitation-sweep'
    echo
    echo 'nothing to ask'
  } > "$1"
}

@test "decisions: the bullet body form is extracted, not silently skipped" {
  # Anti-vacuity for the two bullet passes below: if the extractor found nothing, a
  # contradiction this total would still pass.
  mk_qa_dec_bullet "$WD/bullet-diverge.md" \
    "Selection runs the full suite because the harness itself changed" \
    '- **qa-1** — Screenshots are waived for this platform'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/bullet-diverge.md"
  assert_failure
  assert_output --partial "decision qa-1 disagrees across transports"
}

@test "decisions: the '- **id — title.**' bullet form is reached too" {
  # The form this repo's own architecture artifacts use; the extractor was inert against it.
  mk_qa_dec_bullet "$WD/bullet-inline-diverge.md" \
    "Selection runs the full suite because the harness itself changed" \
    '- **qa-1 — Screenshots are waived for this platform.**'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/bullet-inline-diverge.md"
  assert_failure
  assert_output --partial "decision qa-1 disagrees across transports"
}

@test "decisions: an agreeing '- **id — title.**' bullet passes" {
  mk_qa_dec_bullet "$WD/bullet-inline-agree.md" \
    "Selection runs the full suite because the harness itself changed" \
    '- **qa-1 — The full suite runs: the harness changed, so a scoped selection proves nothing.**'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/bullet-inline-agree.md"
  assert_success
}

@test "decisions: an em-dash inside the summary is not eaten by the trim" {
  # The inline-bullet trim anchors to the id, so a second separator belongs to the summary.
  mk_qa_dec_bullet "$WD/bullet-emdash.md" \
    "Selection runs the full suite because the harness itself changed" \
    '- **qa-1 — Selection — the full one — runs because the harness changed.**'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/bullet-emdash.md"
  assert_success
}

@test "decisions: a body citing a sibling artifact does not manufacture a digit (F-07a)" {
  # planning-0.md used to contribute a bare 0, so the frontmatter's 3 matched nothing and
  # the boundary blocked on an artifact that agrees with itself.
  mk_qa_dec "$WD/filename-digit.md" \
    "The retry budget for a failing stage is 3 attempts" \
    "The retry budget for a failing stage is three attempts, per planning-0.md"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/filename-digit.md"
  assert_success
}

@test "decisions: every filename extension in the allow-list is stripped" {
  local ext
  for ext in md yml yaml json jsonl sh bats txt log; do
    mk_qa_dec "$WD/fn-$ext.md" \
      "The retry budget for a failing stage is 3 attempts" \
      "The retry budget for a failing stage is three attempts, per state-0.$ext"
    run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/fn-$ext.md"
    assert_success || fail "extension $ext still contributed a digit"
  done
}

@test "decisions: a digit inside a hyphenated name is not a quoted count (F-07b)" {
  # `newest-8` names a ring; it is not the "restated bound or count" the arm looks for.
  mk_qa_dec "$WD/hyphen-digit.md" \
    "The newest-8 decisions ring is rescoped per task" \
    "The newest-4 questions ring is rescoped per task as well"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/hyphen-digit.md"
  assert_success
}

@test "decisions: a genuine numeric divergence still fails after both harvest fixes" {
  # The sensitivity floor for AC-6: standalone counts on both sides, none common.
  mk_qa_dec "$WD/still-fails.md" \
    "The retry budget for a failing stage is 3 attempts, see planning-0.md" \
    "The retry budget for a failing stage is 5 attempts, see planning-0.md"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/still-fails.md"
  assert_failure
  assert_output --partial "decision qa-1 disagrees across transports"
}

@test "decisions: stripping filenames cannot false-fail arm 1" {
  # A summary made entirely of filenames empties one side, and arm 1 declines rather than
  # firing on a vocabulary set it just erased.
  mk_qa_dec "$WD/all-filenames.md" \
    "planning-0.md architecture-0.md" \
    "Selection runs the full suite because the harness itself changed"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/all-filenames.md"
  assert_success
}

# --- collect-all frontmatter reporting (REQ-13) ------------------------------

@test "collect-all: two violated check groups report two lines and one non-zero exit" {
  # AC-7. Before this, an author fixed the cap failure and was immediately handed the stub
  # failure on the re-run — one boundary round per defect.
  local ft="[a1.sh, a2.sh, a3.sh, a4.sh, a5.sh, a6.sh, a7.sh, a8.sh, a9.sh, a10.sh, a11.sh]"
  {
    echo '---'
    echo 'handoff:'
    echo '  stage: DV'
    echo '  tests_executed: [{ runner: bats, count: 12, summary_line: "12 tests, 0 failures" }]'
    echo '  verdict: ok'
    echo '  summary: "collect-all fixture"'
    echo "  files_touched: $ft"
    echo '  next_stage_focus: "DR reviews"'
    echo '  open_questions:'
    echo '    - "q1: not a stub"'
    echo '  refs: { dev: development.md#files-changed }'
    echo '---'
    echo
    echo '# Development'
    echo
    echo '12 tests, 0 failures'
  } > "$WD/two-faults.md"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/two-faults.md"
  assert_failure 1
  assert_output --partial "FILES_TOUCHED_MAX=10"
  assert_output --partial "is not a sweep stub"
  # Each failure keeps its own greppable line; they are not aggregated.
  local lines
  lines="$(printf '%s\n' "$output" | grep -c '^fail: ')"
  [ "$lines" -ge 2 ] || fail "expected >=2 distinct fail: lines, got $lines"
}

@test "collect-all: the required-field loop reports every missing field, not the first" {
  {
    echo '---'
    echo 'handoff:'
    echo '  stage: DV'
    echo '  tests_executed: [{ runner: bats, count: 12, summary_line: "12 tests, 0 failures" }]'
    echo '  verdict: ok'
    echo '  summary: "missing fields fixture"'
    echo '---'
    echo
    echo '# Development'
    echo
    echo '12 tests, 0 failures'
  } > "$WD/missing-fields.md"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/missing-fields.md"
  assert_failure 1
  assert_output --partial "missing required field: refs"
  assert_output --partial "missing required field: files_touched"
  assert_output --partial "missing required field: next_stage_focus"
}

@test "collect-all: the prologue still fails fast — an unknown stage reports only itself" {
  {
    echo '---'
    echo 'handoff:'
    echo '  stage: ZZ'
    echo '  verdict: ok'
    echo '---'
    echo
    echo '# Nothing'
  } > "$WD/unknown-stage.md"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/unknown-stage.md"
  assert_failure 1
  assert_output --partial "fail: unknown stage ZZ"
  refute_output --partial "missing required field"
}

@test "collect-all: a broken stub counts in full against the budget and says so" {
  # Not a skip: the exclusion is only sound once the stub shape passes, and skipping the
  # budget arm would let a broken stub hide an over-budget block for a round.
  local pad
  pad="$(head -c 900 < /dev/zero | tr '\0' 'x' | sed 's/x/word /g')"
  {
    echo '---'
    echo 'handoff:'
    echo '  stage: DV'
    echo '  tests_executed: [{ runner: bats, count: 12, summary_line: "12 tests, 0 failures" }]'
    echo '  verdict: ok'
    echo "  summary: \"budget fixture $pad\""
    echo '  files_touched: [a.md]'
    echo '  next_stage_focus: "DR reviews"'
    echo '  open_questions:'
    echo '    - "q1: not a stub"'
    echo '  refs: { dev: development.md#files-changed }'
    echo '---'
    echo
    echo '# Development'
    echo
    echo '12 tests, 0 failures'
  } > "$WD/broken-stub-budget.md"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/broken-stub-budget.md"
  assert_failure 1
  assert_output --partial "is not a sweep stub"
  assert_output --partial "(stub-shape invalid: sweep stubs counted in full)"
  assert_output --partial "- 0 sweep-stub tokens -"
}

@test "collect-all: a clean artifact still reports one ok: line and exit 0" {
  # Anti-vacuity: an aggregate return that never resets would fail everything.
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/development-0.md"
  assert_success
  assert_output --partial "ok: "
}

# --- raw control bytes are a gate failure ------------------------------------
# Bytes are printf-generated; the NUL rides inside an inline-code list of escape spellings,
# the exact shape a typed escape was decoded into.

@test "control bytes: a raw NUL fails naming the path and byte offset" {
  local off
  off=$(( $(wc -c < "$WD/development-0.md") + 19 ))
  { cat "$WD/development-0.md"; printf 'spellings `\\0` raw \000 end\n'; } > "$WD/nul.md"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/nul.md"
  assert_failure 1
  assert_output --partial "fail: control byte 0x00 at byte offset $off in $WD/nul.md"
}

@test "control bytes: the same text spelling the escape literally passes" {
  { cat "$WD/development-0.md"; printf '%s\n' 'spellings `\0` raw \0 end'; } > "$WD/literal.md"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/literal.md"
  assert_success
}

@test "control bytes: --strict fails the same way" {
  { cat "$WD/development-0.md"; printf 'esc \033 here\n'; } > "$WD/esc.md"
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/esc.md" --strict
  assert_failure 1
  assert_output --partial "fail: control byte 0x1B at byte offset"
}

@test "control bytes: the gate refuses to run when the library is unreachable" {
  local copy="$WD/scripts"
  mkdir -p "$copy"
  cp "$PLUGIN_ROOT/$SCRIPT" "$PLUGIN_ROOT/skills/worktask/scripts/sweep-stub-lib.sh" \
    "$PLUGIN_ROOT/skills/worktask/scripts/frontmatter-lib.sh" "$copy/"
  run bash "$copy/handoff-harness.sh" --validate-frontmatter "$WD/development-0.md"
  assert_failure 1
  assert_output --partial "control-byte-lib.sh unreachable"
}

# --- split-stage parity scoped by handoff.task_id -----------------------------

# split_artifact <path> <task_id|-> [stub-yaml] — a DV artifact; no stub means `open_questions: []`.
# A stub's anchor carries a two-option item naming its id, so the harness's item-body check
# never decides a verdict here and each case isolates task_id parity.
split_artifact() {
  local stub_id=""
  if [ -n "${3:-}" ]; then
    stub_id="${3#*id: }"
    stub_id="${stub_id%%,*}"
  fi
  {
    printf -- '---\nhandoff:\n  stage: DV\n'
    [ "$2" = "-" ] || printf '  task_id: %s\n' "$2"
    printf '  tests_executed: [{ runner: bats, count: 12, summary_line: "12 tests, 0 failures" }]\n'
    printf '  verdict: ok\n  summary: "split fixture"\n  files_touched: [a.md]\n'
    printf '  next_stage_focus: "DR reviews"\n'
    if [ -n "${3:-}" ]; then
      printf '  open_questions:\n    - %s\n' "$3"
    else
      printf '  open_questions: []\n'
    fi
    printf '  refs:\n    dev: development.md#files-changed\n'
    printf -- '---\n\n# Development\n\n12 tests, 0 failures\n\n## files-changed\n\nx\n\n## tests-added\n\nx\n\n## deviations\n\nx\n\n## follow-ups\n\nx\n\n## elicitation-sweep\n\n'
    if [ -n "$stub_id" ]; then
      printf -- '- id: %s\n  summary: "Which way?"\n  options:\n' "$stub_id"
      printf -- '    - { label: "A", detail: "first" }\n    - { label: "B", detail: "second" }\n'
    else
      printf 'body\n'
    fi
  } > "$1"
}

# split_state <out> <open-id>... — DV0 and DV1 share the DV slice; each id is an open DV item.
split_state() {
  local out="$1"
  shift
  # The file precedes --args: every operand after it is a positional string, not an input.
  jq '.tasks.DV0 = {status:"in_progress"} | .tasks.DV1 = {status:"in_progress"}
      | .facts.open_questions = [$ARGS.positional[] | {id: ., class: "decision",
          ref: "#elicitation-sweep", blocks_next_stage: false, stage: "DV", status: "open"}]' \
    state.json --args "$@" > "$out"
  jq -e '.tasks.DV1' "$out" > /dev/null || fail "split_state wrote no ledger"
}

@test "task_id parity: DV0 is not charged DV1's open item" {
  cd "$WD"
  split_state split.json sw-DV1-1
  split_artifact "$WD/dv0.md" DV0
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv0.md" --state split.json
  assert_success
  refute_output --partial "warn:"
}

@test "task_id parity: a stub-less DV1 is charged only its own open item" {
  cd "$WD"
  split_state split.json sw-DV0-1 sw-DV1-1
  split_artifact "$WD/dv1.md" DV1
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv1.md" --state split.json
  assert_failure 1
  assert_output --partial "sweep stub sw-DV1-1 is in ledger, not in frontmatter"
  refute_output --partial "sw-DV0-1"
}

@test "task_id parity: DV1 re-emitting its item passes beside DV0's open item" {
  cd "$WD"
  split_state split.json sw-DV0-1 sw-DV1-1
  split_artifact "$WD/dv1.md" DV1 '{ id: sw-DV1-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv1.md" --state split.json
  assert_success
}

@test "task_id parity: the mirror passes DV1 and charges DV0" {
  cd "$WD"
  split_state split.json sw-DV0-1
  split_artifact "$WD/dv1.md" DV1
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv1.md" --state split.json
  assert_success
  split_artifact "$WD/dv0.md" DV0
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv0.md" --state split.json
  assert_failure 1
  assert_output --partial "sweep stub sw-DV0-1 is in ledger, not in frontmatter"
}

@test "task_id parity: a sibling's id over this stream's stubs fails instead of escaping" {
  cd "$WD"
  split_state split.json sw-DV1-1 sw-DV1-2
  split_artifact "$WD/dv1.md" DV0 '{ id: sw-DV1-1, class: decision, ref: "#elicitation-sweep", blocks_next_stage: false }'
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv1.md" --state split.json
  assert_failure 1
  assert_output --partial "fail: sweep stub sw-DV1-1 does not belong to handoff.task_id DV0"
}

@test "task_id: another stage's id or a lowercase id fails the shape check" {
  split_artifact "$WD/dr0.md" DR0
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dr0.md"
  assert_failure 1
  assert_output --partial "fail: handoff.task_id 'DR0' is not a task id of stage DV"
  split_artifact "$WD/lower.md" dv0
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/lower.md"
  assert_failure 1
  assert_output --partial "fail: handoff.task_id 'dv0' is not a task id of stage DV"
}

@test "task_id: an id missing from tasks{} fails" {
  cd "$WD"
  split_state split.json sw-DV1-1
  split_artifact "$WD/dv7.md" DV7
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/dv7.md" --state split.json
  assert_failure 1
  assert_output --partial "fail: handoff.task_id DV7 is not in tasks{}"
}

@test "task_id: absent on a split stage warns and keeps today's rule" {
  cd "$WD"
  split_state split.json sw-DV0-9
  split_artifact "$WD/nostub.md" -
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/nostub.md" --state split.json
  assert_success
  assert_output --partial "warn: nostub.md omits handoff.task_id while stage DV has 2 tasks"
}

@test "task_id: absent on a single-task stage does not warn" {
  cd "$WD"
  jq '.tasks.DV0 = {status:"in_progress"} | .facts.open_questions = []' state.json > single.json
  split_artifact "$WD/single.md" -
  run bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$WD/single.md" --state single.json
  assert_success
  refute_output --partial "warn:"
}

# --- blocked_on: the typed need, gated identically with and without yq ---------------
# The enums are skills/worktask/scripts/blocked-on-lib.sh's; the cases below are the bats twin of
# self_test_blocked_on in skills/worktask/scripts/handoff-harness-selftest.sh.

BO_FIX="${FIXTURES}/worktask/blocked-on"

# _dv_blocked_artifact <path> <lines under handoff:> — a passing DV artifact plus one need.
_dv_blocked_artifact() {
  {
    printf -- '---\nhandoff:\n  stage: DV\n  verdict: blocked\n'
    printf '  summary: "blocked_on fixture"\n'
    printf '  tests_executed: [{ runner: bats, count: 3, summary_line: "3 tests, 0 failures" }]\n'
    printf '  files_touched: [a.md]\n'
    printf '  next_stage_focus: "DR reviews"\n  open_questions: []\n'
    printf '%s\n' "$2"
    printf '  refs:\n    dev: development-0.md#files-changed\n'
    printf -- '---\n\n# Development\n\n## verification-command\n\n3 tests, 0 failures\n\n## files-changed\n\nx\n\n## tests-added\n\nx\n\n## deviations\n\nx\n\n## follow-ups\n\nx\n\n## elicitation-sweep\n\nnothing to ask\n'
  } > "$1"
}

# _bo_from_fixture <name> — the fixture's blocked_on (or, for the legacy fixture, its
# cross_session_ask) as one JSON flow line, which YAML reads as-is.
_bo_from_fixture() {
  if jq -e 'has("blocked_on")' "$BO_FIX/$1.handoff.json" > /dev/null; then
    printf '  blocked_on: %s' "$(jq -c '.blocked_on' "$BO_FIX/$1.handoff.json")"
  else
    printf '  cross_session_ask: %s' "$(jq -c '.cross_session_ask' "$BO_FIX/$1.handoff.json")"
  fi
}

@test "blocked_on: each of the seven kinds passes the gate, with and without yq" {
  local kind
  for kind in user_decision user_action permission peer_session artifact correction host_environment; do
    _dv_blocked_artifact "$WD/bo-$kind.md" "$(_bo_from_fixture "$kind")"
    run_script_env --separate-stderr "$SCRIPT" --validate-frontmatter "$WD/bo-$kind.md"
    [ "$status" -eq 0 ] || fail "$kind (host reader): exit $status: $stderr"
    run_script_env --separate-stderr --hide yq "$SCRIPT" --validate-frontmatter "$WD/bo-$kind.md"
    [ "$status" -eq 0 ] || fail "$kind (no yq): exit $status: $stderr"
  done
}

@test "blocked_on: unknown kind, unknown resume_with and missing detail fail by name, with and without yq" {
  local spec name want hide
  for spec in 'invalid-unknown-kind|fail: blocked_on.kind "coffee_break" is not one of' \
    'invalid-unknown-resume-with|fail: blocked_on.resume_with "carrier_pigeon" is not one of' \
    'invalid-missing-detail|fail: blocked_on.detail is missing or empty'; do
    name="${spec%%|*}" want="${spec#*|}"
    _dv_blocked_artifact "$WD/$name.md" "$(_bo_from_fixture "$name")"
    for hide in no yes; do
      if [ "$hide" = yes ]; then
        run_script_env --separate-stderr --hide yq "$SCRIPT" --validate-frontmatter "$WD/$name.md"
      else
        run_script_env --separate-stderr "$SCRIPT" --validate-frontmatter "$WD/$name.md"
      fi
      [ "$status" -eq 1 ] || fail "$name (hide yq: $hide): exit $status, want 1"
      [[ "$stderr" == *"$want"* ]] || fail "$name (hide yq: $hide): no '$want' in: $stderr"
    done
  done
}

@test "blocked_on: an empty detail object fails like a missing one" {
  _dv_blocked_artifact "$WD/empty.md" '  blocked_on:
    kind: user_action
    detail: {}
    resume_with: decision_ref'
  run_script_env --separate-stderr --hide yq "$SCRIPT" --validate-frontmatter "$WD/empty.md"
  assert_failure 1
  [[ "$stderr" == *"fail: blocked_on.detail is missing or empty"* ]]
  run_script_env --separate-stderr "$SCRIPT" --validate-frontmatter "$WD/empty.md"
  assert_failure 1
}

@test "--read-blocked-on: cross_session_ask is not a need — the gate ignores it and the reader finds none" {
  _dv_blocked_artifact "$WD/old-name.md" "$(_bo_from_fixture legacy-cross-session-ask)"
  run_script_env --separate-stderr --hide yq "$SCRIPT" --validate-frontmatter "$WD/old-name.md"
  assert_success
  run_script_env --separate-stderr "$SCRIPT" --validate-frontmatter "$WD/old-name.md"
  assert_success
  run_script_env --separate-stderr --hide yq "$SCRIPT" --read-blocked-on "$WD/old-name.md"
  assert_failure 1
  [[ "$stderr" == *"no blocked_on in"* ]]
  run_script_env --separate-stderr "$SCRIPT" --read-blocked-on "$WD/old-name.md"
  assert_failure 1
  [[ "$stderr" == *"no blocked_on in"* ]]
}

@test "--read-blocked-on: blocked_on is read beside an unrelated key, and none present exits 1" {
  _dv_blocked_artifact "$WD/both.md" "$(_bo_from_fixture artifact)
$(_bo_from_fixture legacy-cross-session-ask)"
  run_script_env --separate-stderr --hide yq "$SCRIPT" --read-blocked-on "$WD/both.md"
  assert_success
  jq -e '.kind == "artifact"' <<< "${lines[0]}"
  [ "${lines[1]}" = "source: blocked_on" ]
  _dv_test_evidence_artifact "$WD/none.md" 3
  run_script_env --separate-stderr --hide yq "$SCRIPT" --read-blocked-on "$WD/none.md"
  assert_failure 1
  [[ "$stderr" == *"no blocked_on in"* ]]
}

@test "--read-blocked-on: the no-yq reader parses block style, flow style and a block sequence alike" {
  local want
  want='{"kind":"user_decision","detail":{"question":"Ship: behind a flag?","options":["flag","no-flag"],"recommended":"flag"},"resume_with":"decision_ref"}'
  _dv_blocked_artifact "$WD/block.md" '  blocked_on:
    kind: user_decision   # the stage cannot choose
    detail:
      question: "Ship: behind a flag?"
      options:
        - flag
        - '"'no-flag'"'
      recommended: flag
    resume_with: decision_ref'
  _dv_blocked_artifact "$WD/flow.md" '  blocked_on: { kind: user_decision, detail: { question: "Ship: behind a flag?", options: [flag, no-flag], recommended: flag }, resume_with: decision_ref }'
  local f
  for f in block flow; do
    run_script_env --separate-stderr --hide yq "$SCRIPT" --read-blocked-on "$WD/$f.md"
    assert_success
    [ "$(jq -cS . <<< "${lines[0]}")" = "$(jq -cS . <<< "$want")" ] || fail "$f (no yq): ${lines[0]}"
    run_script_env --separate-stderr "$SCRIPT" --read-blocked-on "$WD/$f.md"
    assert_success
    [ "$(jq -cS . <<< "${lines[0]}")" = "$(jq -cS . <<< "$want")" ] || fail "$f (host reader): ${lines[0]}"
  done
}

@test "--read-blocked-on: an indentless sequence and multi-line mapping items read the same with and without yq" {
  local want
  want='{"kind":"user_decision","detail":{"question":"Which base?","options":[{"label":"develop","description":"the default"},{"label":"master"}],"recommended":"develop"},"resume_with":"decision_ref"}'
  _dv_blocked_artifact "$WD/indentless.md" '  blocked_on:
    kind: user_decision
    detail:
      question: "Which base?"
      options:
      - label: develop
        description: the default
      - label: master
      recommended: develop
    resume_with: decision_ref'
  run_script_env --separate-stderr --hide yq "$SCRIPT" --read-blocked-on "$WD/indentless.md"
  assert_success
  [ "$(jq -cS . <<< "${lines[0]}")" = "$(jq -cS . <<< "$want")" ] || fail "no yq: ${lines[0]}"
  run_script_env --separate-stderr "$SCRIPT" --read-blocked-on "$WD/indentless.md"
  assert_success
  [ "$(jq -cS . <<< "${lines[0]}")" = "$(jq -cS . <<< "$want")" ] || fail "host reader: ${lines[0]}"
  run_script_env --separate-stderr --hide yq "$SCRIPT" --validate-frontmatter "$WD/indentless.md"
  assert_success
}

@test "blocked_on: the self-test source carries one case per kind and each refusal, each asserting its exit code" {
  local st="$PLUGIN_ROOT/skills/worktask/scripts/handoff-harness-selftest.sh" kind
  for kind in user_decision user_action permission peer_session artifact correction host_environment; do
    grep -qE "^$kind\|" "$st" || fail "no self-test case row for $kind"
  done
  grep -qF '_bo_case "valid/$kind" 0' "$st" || fail "the valid cases do not assert exit 0"
  grep -qF '_bo_case "unknown-kind" 1' "$st" || fail "no unknown-kind case asserting exit 1"
  grep -qF '_bo_case "unknown-resume_with" 1' "$st" || fail "no unknown resume_with case asserting exit 1"
  grep -qF '_bo_case "missing-detail" 1' "$st" || fail "no missing-detail case asserting exit 1"
  grep -qF 'old-name/reads-as-absent' "$st" || fail "no case reading cross_session_ask as absent"
  grep -qF 'skills/worktask/scripts/blocked-on-lib.sh' "$BATS_TEST_FILENAME"
}

# --- H2 anchor enforcement for all 13 stages ---------------------------------

ANCHORS="$FIXTURES/worktask/anchors"

@test "anchors: an ST artifact with 5 extra H2s and no followups fails, one line per defect" {
  run bash "$PLUGIN_ROOT/skills/worktask/scripts/handoff-harness.sh" --validate-frontmatter "$ANCHORS/retrospective-0.drift.md"
  assert_failure 1
  assert_output --partial "fail: anchor-lint stage=ST missing required H2 '## followups' in retrospective-0.drift.md"
  [ "$(grep -c "unexpected H2 '## " <<< "$output")" -eq 5 ] || fail "want 5 unexpected lines: $output"
  assert_output --partial "nest it as H3 (handoff-protocol.md#anchor-allow-list)"
}

@test "anchors: every stage's conforming fixture passes; dropping any one required H2 fails" {
  local rows stage base heading n=0
  rows="$(bash "$PLUGIN_ROOT/skills/worktask/scripts/cache-lint.sh" --allow-list)"
  for stage in PL AR TL DV DR SR QA DC RE FN ST IR ET; do
    base="$(awk -F'\t' -v s="$stage" '$1 == s { print $3; exit }' <<< "$rows")"
    run bash "$PLUGIN_ROOT/skills/worktask/scripts/handoff-harness.sh" --validate-frontmatter "$ANCHORS/$base-0.md"
    assert_success
    while IFS= read -r heading; do
      grep -vx "## $heading" "$ANCHORS/$base-0.md" > "$WD/$base-0.md"
      run bash "$PLUGIN_ROOT/skills/worktask/scripts/handoff-harness.sh" --validate-frontmatter "$WD/$base-0.md"
      assert_failure 1
      [[ "$output" == *"missing required H2 '## $heading'"* ]] || fail "$stage/$heading: $output"
      n=$((n + 1))
    done < <(awk -F'\t' -v s="$stage" '$1 == s && ($4 == "required" || $4 == "universal") { print $5 }' <<< "$rows")
  done
  [ "$n" -ge 52 ] || fail "non-vacuity: only $n removals exercised"
}

@test "anchors: DV and QA optional H2s pass; a DV Stage Timings H2 fails by name" {
  local H="$PLUGIN_ROOT/skills/worktask/scripts/handoff-harness.sh"
  run bash "$H" --validate-frontmatter "$ANCHORS/development-0.optional.md"
  assert_success
  run bash "$H" --validate-frontmatter "$ANCHORS/testing-0.optional.md"
  assert_success
  { cat "$ANCHORS/development-0.optional.md"; printf '\n## Stage Timings\n\nx\n'; } > "$WD/development-0.md"
  run bash "$H" --validate-frontmatter "$WD/development-0.md"
  assert_failure 1
  assert_output --partial "unexpected H2 '## Stage Timings' in development-0.md"
}

@test "anchors: enforcement does not depend on yq" {
  local bin="$WD/bin" t
  mkdir -p "$bin"
  for t in bash awk sed grep cat cmp mktemp rm tr wc head tail basename dirname od; do
    ln -s "$(command -v "$t")" "$bin/$t"
  done
  run env PATH="$bin" bash "$PLUGIN_ROOT/skills/worktask/scripts/handoff-harness.sh" \
    --validate-frontmatter "$ANCHORS/retrospective-0.drift.md"
  assert_failure 1
  assert_output --partial "missing required H2 '## followups'"
}

@test "anchors: an unreachable cache-lint.sh fails the gate closed" {
  local copy="$WD/scripts" f
  mkdir -p "$copy"
  # Every startup-sourced lib except cache-lint.sh must be present, or the fail-closed
  # startup block (not the anchor gate) fires first with a different library's message.
  for f in handoff-harness.sh sweep-stub-lib.sh frontmatter-lib.sh control-byte-lib.sh blocked-on-lib.sh; do
    cp "$PLUGIN_ROOT/skills/worktask/scripts/$f" "$copy/$f"
  done
  run bash "$copy/handoff-harness.sh" --validate-frontmatter "$ANCHORS/retrospective-0.md"
  assert_failure 1
  assert_output --partial "fail: anchor gate cannot run on retrospective-0.md"
}

# The ledger refuses the downgrade, so an artifact still saying `decision` diverges from it
# and the unchanged harness must fail the boundary.
@test "sweep class: a refused --facts downgrade leaves the decision artifact failing the harness" {
  local d="$WD/sr" rc=0 sp="$PLUGIN_ROOT/skills/worktask/scripts/state-patch.sh"
  local want="fail: sweep stub sw-SR0-1 disagrees across transports — class is decision in security-review-0.md but escalate in facts.open_questions[]. Reconcile both to the intended value (the artifact is the author's copy); do not leave them divergent"
  mkdir -p "$d/logs"
  printf '{"version":2,"run_index":0,"tasks":{},"facts":{"open_questions":[]}}\n' > "$d/state.json"
  bash "$sp" --state "$d/state.json" --facts '{"open_questions":[{"id":"sw-SR0-1","class":"escalate","ref":"security-review-0.md#elicitation-sweep","blocks_next_stage":false}]}' > /dev/null
  run bash "$sp" --state "$d/state.json" --facts '{"open_questions":[{"id":"sw-SR0-1","class":"decision","ref":"security-review-0.md#elicitation-sweep","blocks_next_stage":false}]}'
  assert_failure 2
  assert_output --partial "class downgrade escalate -> decision refused"
  {
    printf -- '---\nhandoff:\n  stage: SR\n  verdict: pass\n  summary: "fixture"\n'
    printf '  key_decisions:\n    - { id: sr1, summary: "x", anchor: "security-review-0.md#findings" }\n'
    printf '  open_questions:\n'
    printf '    - { id: sw-SR0-1, class: decision, ref: "security-review-0.md#elicitation-sweep", blocks_next_stage: false }\n'
    printf '  refs:\n    findings: security-review-0.md#findings\n---\n\n# Security Review\n'
    anchor_h2s SR
    printf '\n## elicitation-sweep\n\n- id: sw-SR0-1\n  summary: "Accept the finding?"\n  options:\n'
    printf -- '    - { label: "A", detail: "first" }\n    - { label: "B", detail: "second" }\n'
  } > "$d/security-review-0.md"
  bash "$PLUGIN_ROOT/$SCRIPT" --validate-frontmatter "$d/security-review-0.md" --state "$d/state.json" \
    > "$d/out" 2> "$d/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "the harness passed a decision stub beside a ledger escalate"
  grep -qF -- "$want" "$d/err" || fail "exact divergence line absent from stderr: $(cat "$d/err")"
}
