#!/usr/bin/env bats
# Contract tests for skills/cross-plugin-handoff/scripts/validate-consultant-return.sh.
#   - exit 0: one compact JSON line on stdout; warn lines on stderr in a fixed order
#   - exit 1: exactly one reject line, first failing check wins, stdout empty
#   - exit 2: exactly one error line with a named code, stdout empty
#   - extraction: a whole-input object, else the last closed ```json fence
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/cross-plugin-handoff/scripts/validate-consultant-return.sh"
CR_FIX="${FIXTURES}/skills/consultant-return"
V1_HEAD='"schema_version":"consultant-return.v1"'
ZERO_COUNTS='"severity_counts":{"critical":0,"high":0,"medium":0,"low":0}'

_validate_file() {
  run_script_env --separate-stderr "$SCRIPT" --file "$1"
}

# <json> — validates an inline return written to a scratch file.
_validate_json() {
  local wd
  wd="$(mk_tmpworkdir)"
  printf '%s\n' "$1" > "$wd/return.json"
  _validate_file "$wd/return.json"
}

# <expected-line> — exit 1, empty stdout, stderr is exactly that one line.
_assert_reject() {
  assert_failure 1
  assert_output ""
  [ "$stderr" = "$1" ] || fail "expected stderr [$1], got [$stderr]"
}

# <code> — exit 2, empty stdout, one stderr line carrying that error code.
_assert_error() {
  assert_failure 2
  assert_output ""
  [ "${#stderr_lines[@]}" -eq 1 ] || fail "expected one stderr line, got: $stderr"
  [[ "$stderr" == "error: $1: "* ]] || fail "expected error: $1, got: $stderr"
}

@test "a valid v1 return passes: stdout is the compacted object, stderr is empty" {
  _validate_file "$CR_FIX/valid-v1.json"
  assert_success
  assert_output "$(jq -c . "$CR_FIX/valid-v1.json")"
  [ "${#lines[@]}" -eq 1 ] || fail "expected one stdout line, got ${#lines[@]}"
  [ -z "$stderr" ] || fail "unexpected stderr: $stderr"
}

@test "needs_changes comes out as fail with exactly one needs_changes_normalized warning" {
  _validate_file "$CR_FIX/needs-changes.json"
  assert_success
  [ "$(printf '%s' "$output" | jq -r .verdict)" = "fail" ] || fail "verdict not fail: $output"
  [ "$stderr" = "warn: needs_changes_normalized: verdict needs_changes normalized to fail" ] \
    || fail "unexpected stderr: $stderr"
}

@test "a mismatched or null schema_version is rejected as version_mismatch" {
  _validate_file "$CR_FIX/version-v2.json"
  _assert_reject 'reject: version_mismatch: schema_version: "consultant-return.v2"'

  _validate_json "{\"schema_version\":null,\"verdict\":\"pass\",$ZERO_COUNTS,\"findings\":[]}"
  _assert_reject 'reject: version_mismatch: schema_version: null'
}

@test "a return without severity_counts is rejected as missing_severity_counts" {
  _validate_file "$CR_FIX/missing-severity-counts.json"
  _assert_reject 'reject: missing_severity_counts: severity_counts: absent'
}

@test "an absent schema_version passes with version_absent and is stamped v1" {
  _validate_file "$CR_FIX/version-absent.json"
  assert_success
  [ "$(printf '%s' "$output" | jq -r .schema_version)" = "consultant-return.v1" ] \
    || fail "not stamped: $output"
  [ "$stderr" = "warn: version_absent: schema_version absent; stamped consultant-return.v1" ] \
    || fail "unexpected stderr: $stderr"
}

@test "severity_counts with P-keys, a missing key, or a bad value is invalid_severity_counts" {
  _validate_file "$CR_FIX/counts-p-keys.json"
  _assert_reject 'reject: invalid_severity_counts: severity_counts: keys ["P0","P1","P2","P3"]'

  local head="$V1_HEAD,\"verdict\":\"pass\",\"findings\":[]"
  _validate_json "{$head,\"severity_counts\":{\"critical\":0,\"high\":0,\"medium\":0}}"
  _assert_reject 'reject: invalid_severity_counts: severity_counts: keys ["critical","high","medium"]'

  _validate_json "{$head,\"severity_counts\":{\"Critical\":0,\"High\":0,\"Medium\":0,\"Low\":0}}"
  _assert_reject 'reject: invalid_severity_counts: severity_counts: keys ["Critical","High","Low","Medium"]'

  _validate_json "{$head,\"severity_counts\":{\"critical\":0,\"high\":1.5,\"medium\":0,\"low\":-1}}"
  _assert_reject 'reject: invalid_severity_counts: severity_counts.high: 1.5'

  _validate_json "{$head,\"severity_counts\":{\"critical\":\"0\",\"high\":0,\"medium\":0,\"low\":0}}"
  _assert_reject 'reject: invalid_severity_counts: severity_counts.critical: "0"'

  _validate_json "{$head,\"severity_counts\":[0,0,0,0]}"
  _assert_reject 'reject: invalid_severity_counts: severity_counts: not an object (array)'
}

@test "markdown: the last closed json fence is extracted, from a file or from stdin" {
  local expected
  expected="$(jq -c . "$CR_FIX/valid-v1.json")"

  _validate_file "$CR_FIX/fenced-last.md"
  assert_success
  assert_output "$expected"
  [ -z "$stderr" ] || fail "unexpected stderr: $stderr"

  run_script_env --separate-stderr --stdin-file "$CR_FIX/fenced-last.md" "$SCRIPT" -
  assert_success
  assert_output "$expected"
}

@test "tilde and unclosed fences are ignored; CRLF fences still match" {
  local wd v2
  wd="$(mk_tmpworkdir)"
  v2="{\"schema_version\":\"consultant-return.v2\",\"verdict\":\"pass\",$ZERO_COUNTS,\"findings\":[]}"
  {
    printf '```json\n%s\n```\n' "{$V1_HEAD,\"verdict\":\"pass\",$ZERO_COUNTS,\"findings\":[]}"
    printf '~~~json\n%s\n~~~\n' "$v2"
    printf '```json\n%s\n' "$v2"
  } > "$wd/return.md"
  _validate_file "$wd/return.md"
  assert_success
  [ "$(printf '%s' "$output" | jq -r .verdict)" = "pass" ] || fail "wrong fence picked: $output"

  printf '```json\r\n%s\r\n```\r\n' "{$V1_HEAD,\"verdict\":\"fail\",$ZERO_COUNTS,\"findings\":[]}" \
    > "$wd/crlf.md"
  _validate_file "$wd/crlf.md"
  assert_success
  [ "$(printf '%s' "$output" | jq -r .verdict)" = "fail" ] || fail "CRLF fence not read: $output"
}

@test "non-JSON input exits 2: unparseable for a broken fence, no_json otherwise" {
  _validate_file "$CR_FIX/not-json.md"
  _assert_error unparseable

  _validate_file "$CR_FIX/prose-no-json.md"
  _assert_error no_json

  run_script_env --separate-stderr --stdin-string "" "$SCRIPT" -
  _assert_error no_json

  local wd
  wd="$(mk_tmpworkdir)"
  printf '```json\n[1, 2]\n```\n' > "$wd/array.md"
  _validate_file "$wd/array.md"
  _assert_error no_json
}

@test "--self-test prints self-test OK and exits 0" {
  run_script "$SCRIPT" --self-test
  assert_success
  assert_output --partial "self-test OK"
  assert_output --regexp 'self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
  assert_output "self-test OK (5 passed, 0 failed)"
}

@test "--self-test fails closed with exit 2 when the harness is missing" {
  local wd
  wd="$(mk_tmpworkdir)"
  cp "$PLUGIN_ROOT/$SCRIPT" "$wd/validate-consultant-return.sh"
  run --separate-stderr bash "$wd/validate-consultant-return.sh" --self-test
  _assert_error unreadable
  [[ "$stderr" == *"self-test harness missing"* ]] || fail "unexpected stderr: $stderr"
}

@test "--self-test reports only reached cases after a failed assertion" {
  local wd
  wd="$(mk_tmpworkdir)"
  cp "$PLUGIN_ROOT/$SCRIPT" "$wd/validate-consultant-return.sh"
  sed "s/^  local expected=.*/  local expected='invalid'/" \
    "$PLUGIN_ROOT/skills/cross-plugin-handoff/scripts/validate-consultant-return-selftest.sh" \
    > "$wd/validate-consultant-return-selftest.sh"
  run --separate-stderr bash "$wd/validate-consultant-return.sh" --self-test
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"self-test FAIL: valid: normalized output differs"* ]]
  [[ "$stderr" == *"(0 passed, 1 failed)"* ]]
}

@test "idempotence: re-validating stdout yields the same bytes and no warnings" {
  local wd fx first
  wd="$(mk_tmpworkdir)"
  for fx in valid-v1.json needs-changes.json version-absent.json fenced-last.md; do
    _validate_file "$CR_FIX/$fx"
    assert_success
    first="$output"
    printf '%s\n' "$first" > "$wd/first.json"
    _validate_file "$wd/first.json"
    assert_success
    [ "$output" = "$first" ] || fail "$fx: second pass differs: [$output] vs [$first]"
    [ -z "$stderr" ] || fail "$fx: second pass warned: $stderr"
  done
}

@test "usage: bad invocations exit 2 with error: usage; -h and --help print usage and exit 0" {
  run_script_env --separate-stderr "$SCRIPT"
  _assert_error usage

  run_script_env --separate-stderr "$SCRIPT" --bogus
  _assert_error usage

  run_script_env --separate-stderr "$SCRIPT" --file
  _assert_error usage

  run_script_env --separate-stderr "$SCRIPT" --file a b
  _assert_error usage

  run_script_env --separate-stderr "$SCRIPT" - extra
  _assert_error usage

  run_script_env --separate-stderr "$SCRIPT" $'--bo\ngus\tx'
  _assert_error usage

  local flag
  for flag in -h --help; do
    run_script_env --separate-stderr "$SCRIPT" "$flag"
    assert_success
    assert_output --partial "Usage: validate-consultant-return.sh --file <path>"
    [ -z "$stderr" ] || fail "$flag wrote stderr: $stderr"
  done
}

@test "unreadable: a missing path or a directory exits 2 with error: unreadable" {
  local wd
  wd="$(mk_tmpworkdir)"
  _validate_file "$wd/does-not-exist.json"
  _assert_error unreadable

  _validate_file "$wd"
  _assert_error unreadable
}

@test "missing jq exits 2 with error: missing_dependency" {
  run_script_env --separate-stderr --hide jq "$SCRIPT" --file "$CR_FIX/valid-v1.json"
  _assert_error missing_dependency
}

@test "first reject wins: several defects still produce one line, in check order" {
  _validate_json '{"schema_version":"v0","verdict":"maybe","findings":"none"}'
  _assert_reject 'reject: version_mismatch: schema_version: "v0"'

  _validate_json "{$V1_HEAD,\"verdict\":\"maybe\",\"severity_counts\":{\"P0\":0},\"findings\":[{}]}"
  _assert_reject 'reject: invalid_severity_counts: severity_counts: keys ["P0"]'

  _validate_json "{$V1_HEAD,\"verdict\":\"maybe\",$ZERO_COUNTS,\"findings\":[{\"id\":\"F1\"}]}"
  _assert_reject 'reject: invalid_finding: findings[0].severity: absent'
}

@test "count_mismatch is a warning only: exit 0, counts kept as given" {
  _validate_file "$CR_FIX/count-mismatch.json"
  assert_success
  [ "$(printf '%s' "$output" | jq -c .severity_counts)" = '{"critical":0,"high":2,"medium":0,"low":0}' ] \
    || fail "counts altered: $output"
  [ "$stderr" = "warn: count_mismatch: severity_counts critical=0 high=2 medium=0 low=0 but findings tally critical=0 high=1 medium=0 low=0" ] \
    || fail "unexpected stderr: $stderr"
}

@test "invalid_finding names findings[<i>].<field> for each broken field" {
  _validate_file "$CR_FIX/invalid-finding.json"
  _assert_reject 'reject: invalid_finding: findings[1].severity: "Critical"'

  local head="$V1_HEAD,\"verdict\":\"fail\",$ZERO_COUNTS"
  _validate_json "{$head,\"findings\":[{\"id\":\"\",\"severity\":\"low\",\"summary\":\"s\"}]}"
  _assert_reject 'reject: invalid_finding: findings[0].id: ""'

  _validate_json "{$head,\"findings\":[{\"id\":\"F1\",\"severity\":\"low\"}]}"
  _assert_reject 'reject: invalid_finding: findings[0].summary: absent'

  _validate_json "{$head,\"findings\":[{\"id\":\"F1\",\"severity\":\"low\",\"summary\":\"s\",\"location\":12}]}"
  _assert_reject 'reject: invalid_finding: findings[0].location: 12'

  _validate_json "{$head,\"findings\":[\"F1\"]}"
  _assert_reject 'reject: invalid_finding: findings[0]: not an object (string)'
}

@test "missing_findings and invalid_verdict; an empty findings array is valid" {
  _validate_json "{$V1_HEAD,\"verdict\":\"pass\",$ZERO_COUNTS}"
  _assert_reject 'reject: missing_findings: findings: absent'

  _validate_json "{$V1_HEAD,\"verdict\":\"pass\",$ZERO_COUNTS,\"findings\":{}}"
  _assert_reject 'reject: missing_findings: findings: not an array (object)'

  _validate_json "{$V1_HEAD,$ZERO_COUNTS,\"findings\":[]}"
  _assert_reject 'reject: invalid_verdict: verdict: absent'

  _validate_json "{$V1_HEAD,\"verdict\":\"PASS\",$ZERO_COUNTS,\"findings\":[]}"
  _assert_reject 'reject: invalid_verdict: verdict: "PASS"'

  _validate_json "{$V1_HEAD,\"verdict\":\"pass\",$ZERO_COUNTS,\"findings\":[]}"
  assert_success
  [ -z "$stderr" ] || fail "unexpected stderr: $stderr"
}

@test "warnings keep their fixed order and unknown keys are dropped" {
  _validate_json '{"notes":"x","verdict":"needs_changes","severity_counts":{"critical":1,"high":0,"medium":0,"low":0},"findings":[{"id":"F1","severity":"low","summary":"s","cwe":"CWE-78"}]}'
  assert_success
  [ "${#stderr_lines[@]}" -eq 3 ] || fail "expected three warnings, got: $stderr"
  [[ "${stderr_lines[0]}" == "warn: version_absent: "* ]] || fail "line 1: ${stderr_lines[0]}"
  [[ "${stderr_lines[1]}" == "warn: needs_changes_normalized: "* ]] || fail "line 2: ${stderr_lines[1]}"
  [[ "${stderr_lines[2]}" == "warn: count_mismatch: "* ]] || fail "line 3: ${stderr_lines[2]}"
  assert_output '{"schema_version":"consultant-return.v1","verdict":"fail","severity_counts":{"critical":1,"high":0,"medium":0,"low":0},"findings":[{"id":"F1","severity":"low","summary":"s"}]}'
}

@test "details are one line: control characters stripped, echoed values cut to 80 chars" {
  local long
  long="$(printf '%0200d' 0 | tr 0 v)"
  _validate_json "{\"schema_version\":\"x\\u0085\\u009f$long\",\"verdict\":\"pass\",$ZERO_COUNTS,\"findings\":[]}"
  assert_failure 1
  [ "${#stderr_lines[@]}" -eq 1 ] || fail "detail spans lines: $stderr"
  local prefix='reject: version_mismatch: schema_version: '
  [[ "$stderr" == "$prefix\"xvvv"* ]] || fail "unexpected stderr: $stderr"
  local value="${stderr#"$prefix"}"
  [ "${#value}" -eq 80 ] || fail "echoed value is ${#value} chars, expected 80"
  if printf '%s' "$stderr" | LC_ALL=C grep -q $'\xc2'; then
    fail "a C1 control character survived: $stderr"
  fi
}

@test "an info count and info findings pass unchanged, from stdin, and re-validate to the same bytes" {
  local expected
  expected="$(jq -c . "$CR_FIX/info-key.json")"
  [ "$expected" = '{"schema_version":"consultant-return.v1","verdict":"pass","severity_counts":{"critical":0,"high":0,"medium":1,"low":0,"info":2},"findings":[{"id":"F1","severity":"medium","summary":"m"},{"id":"F2","severity":"info","summary":"i"},{"id":"F3","severity":"info","summary":"j"}]}' ] \
    || fail "fixture drifted from the AC-1 input: $expected"

  run_script_env --separate-stderr --stdin-file "$CR_FIX/info-key.json" "$SCRIPT" -
  assert_success
  assert_output "$expected"
  [ -z "$stderr" ] || fail "unexpected stderr: $stderr"

  _validate_json "$output"
  assert_success
  assert_output "$expected"
  [ -z "$stderr" ] || fail "second pass warned: $stderr"
}

@test "count_mismatch compares info: an absent info count reads as 0 and is not added to the output" {
  _validate_json "{$V1_HEAD,\"verdict\":\"pass\",$ZERO_COUNTS,\"findings\":[{\"id\":\"F1\",\"severity\":\"info\",\"summary\":\"i\"}]}"
  assert_success
  assert_output "{$V1_HEAD,\"verdict\":\"pass\",$ZERO_COUNTS,\"findings\":[{\"id\":\"F1\",\"severity\":\"info\",\"summary\":\"i\"}]}"
  [ "$stderr" = "warn: count_mismatch: severity_counts critical=0 high=0 medium=0 low=0 info=0 but findings tally critical=0 high=0 medium=0 low=0 info=1" ] \
    || fail "unexpected stderr: $stderr"
}

@test "info is lowercase only and never replaces a required key; a bad info value has its own locator" {
  local head="$V1_HEAD,\"verdict\":\"pass\",\"findings\":[]"
  _validate_json "{$head,\"severity_counts\":{\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"Info\":0}}"
  _assert_reject 'reject: invalid_severity_counts: severity_counts: keys ["Info","critical","high","low","medium"]'

  _validate_json "{$head,\"severity_counts\":{\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"informational\":0}}"
  _assert_reject 'reject: invalid_severity_counts: severity_counts: keys ["critical","high","informational","low","medium"]'

  _validate_json "{$head,\"severity_counts\":{\"critical\":0,\"high\":0,\"medium\":0,\"info\":0}}"
  _assert_reject 'reject: invalid_severity_counts: severity_counts: keys ["critical","high","info","medium"]'

  _validate_json "{$head,\"severity_counts\":{\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"info\":-1}}"
  _assert_reject 'reject: invalid_severity_counts: severity_counts.info: -1'

  _validate_json "{$V1_HEAD,\"verdict\":\"pass\",$ZERO_COUNTS,\"findings\":[{\"id\":\"F1\",\"severity\":\"Info\",\"summary\":\"s\"}]}"
  _assert_reject 'reject: invalid_finding: findings[0].severity: "Info"'
}

# --- prose contract (DV1 appends below) ---
# The validator only enforces the schema while its consumers and the sibling template keep
# citing it; these pin that prose half of the seam.

# <repo-relative file> — the section whose heading names consultant-return.v1, down to the next
# heading at the same or a higher level. Fenced lines are skipped so a `#` comment is no heading.
_consultant_section() {
  awk '
    /^ {0,3}(```|~~~)/ { fence = !fence }
    !fence && /^#+ / {
      lvl = index($0, " ") - 1
      if (on && lvl <= start) exit
      if (!on && $0 ~ /consultant-return\.v1/) { on = 1; start = lvl }
    }
    on
  ' "$PLUGIN_ROOT/$1"
}

@test "AC-3: SR and DR prose cite the schema id and the validator path" {
  local f
  for f in agents/security-reviewer.md agents/technical-lead.md; do
    grep -qE '\bconsultant-return\.v1\b' "$PLUGIN_ROOT/$f" || fail "$f does not cite consultant-return.v1"
    grep -qE 'validate-consultant-return\.sh' "$PLUGIN_ROOT/$f" || fail "$f does not cite the validator"
  done
}

@test "AC-4: the developer route lists the XcodeBuildMCP tools and six build-test skills, granting none" {
  # The MCP listing lives in the DV reference file the agent body points at, so it costs no
  # prefix tokens; the build-test names and the tools: line stay in the agent body.
  local f="$PLUGIN_ROOT/agents/developer.md" ref="$PLUGIN_ROOT/skills/worktask/references/dv-reference.md" n
  grep -q 'dv-reference.md § Sibling tooling' "$f" || fail "developer.md no longer points at the sibling tooling listing"
  n="$(grep -oE '\bmcp__XcodeBuildMCP__[a-z_]+\b' "$ref" | sort -u | wc -l | tr -d ' ')"
  [ "$n" -ge 12 ] || fail "expected at least 12 distinct XcodeBuildMCP ids, got $n"
  n="$(grep -oE '\b(apple-developer|system-developer|android-developer|frontend-developer|backend-developer|ai-engineer):build-test\b' "$f" \
    | sort -u | wc -l | tr -d ' ')"
  [ "$n" -eq 6 ] || fail "expected 6 build-test skill names, got $n"
  if grep -E '^tools:' "$f" | grep -q 'XcodeBuildMCP'; then
    fail "developer.md grants an XcodeBuildMCP tool; the listing must stay a listing"
  fi
}

@test "AC-5: the plugin-side template declares consultant-return.v1 within its 300-line budget" {
  local f="$PLUGIN_ROOT/skills/cross-plugin-handoff/templates/CORPFLOW.md" n
  grep -qE '\bconsultant-return\.v1\b' "$f" || fail "template does not declare consultant-return.v1"
  n="$(wc -l < "$f" | tr -d ' ')"
  [ "$n" -le 300 ] || fail "template is $n lines; the budget is 300"
}

@test "AC-7: the skill index and the plugin contract cite the schema" {
  local f
  for f in skills/cross-plugin-handoff/SKILL.md skills/cross-plugin-handoff/references/plugin-contract.md; do
    grep -qE '\bconsultant-return\.v1\b' "$PLUGIN_ROOT/$f" || fail "$f does not cite consultant-return.v1"
  done
}

@test "AC-8: SR and DR consultant sections merge stdout only, re-dispatch once, then block" {
  local f section
  for f in agents/security-reviewer.md agents/technical-lead.md; do
    section="$(_consultant_section "$f")"
    [ -n "$section" ] || fail "$f has no section headed with consultant-return.v1"
    printf '%s\n' "$section" | grep -qE 're-?dispatch' || fail "$f: no re-dispatch rule"
    printf '%s\n' "$section" | grep -q 'stdout only' || fail "$f: no stdout-only merge rule"
    printf '%s\n' "$section" | grep -q 'verdict: blocked' || fail "$f: no blocked verdict for a final reject"
    printf '%s\n' "$section" | grep -q 'severity_counts' || fail "$f: no rejection rule for severity_counts"
  done
}
