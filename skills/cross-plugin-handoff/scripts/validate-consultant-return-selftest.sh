#!/usr/bin/env bash
# validate-consultant-return-selftest.sh — the `--self-test` harness for
# validate-consultant-return.sh.
#
# SOURCED, never executed: the validator loads this file only on `--self-test`, so the
# production path never pays for it. It reuses the caller's WORK_DIR and EXIT trap for
# cleanup rather than installing a trap that would replace the caller's.
#
# Contract: defines `run_self_test`, which owns the exit for this invocation.

_st_fail() {
  printf >&2 'self-test FAIL: %s (%d passed, 1 failed)\n' "$1" "${_st_passed:-0}"
  exit 1
}

# <case-name> <json> — runs the real entry point on the json; sets _st_rc, _st_out, _st_err.
_st_run() {
  local name="$1" json="$2"
  printf '%s\n' "$json" > "$WORK_DIR/$name.json"
  _st_rc=0
  # `$0`, not BASH_SOURCE: this file is sourced, so `$0` is still the validator.
  bash "$0" --file "$WORK_DIR/$name.json" > "$WORK_DIR/$name.out" 2> "$WORK_DIR/$name.err" \
    || _st_rc=$?
  _st_out="$(cat "$WORK_DIR/$name.out")"
  _st_err="$(cat "$WORK_DIR/$name.err")"
}

# <case-name> <code> — asserts exit 1, empty stdout, exactly one reject line with <code>.
_st_expect_reject() {
  [ "$_st_rc" -eq 1 ] || _st_fail "$1: expected exit 1, got $_st_rc ($_st_err)"
  [ -z "$_st_out" ] || _st_fail "$1: stdout not empty on reject"
  case "$_st_err" in
    *$'\n'*) _st_fail "$1: more than one stderr line: $_st_err" ;;
    "reject: $2: "*) ;;
    *) _st_fail "$1: expected reject: $2, got: $_st_err" ;;
  esac
  _st_passed=$((_st_passed + 1))
}

run_self_test() {
  trap - ERR
  _st_passed=0
  WORK_DIR="$(mktemp -d)" || _st_fail "cannot create a temporary directory"
  local counts='"severity_counts":{"low":0,"medium":0,"high":1,"critical":0}'
  local findings='"findings":[{"summary":"Unquoted expansion","id":"F1","location":"a.sh:3","severity":"high"}]'
  local expected='{"schema_version":"consultant-return.v1","verdict":"pass","severity_counts":{"critical":0,"high":1,"medium":0,"low":0},"findings":[{"id":"F1","severity":"high","summary":"Unquoted expansion","location":"a.sh:3"}]}'

  _st_run valid "{$findings,\"verdict\":\"pass\",$counts,\"schema_version\":\"consultant-return.v1\"}"
  [ "$_st_rc" -eq 0 ] || _st_fail "valid: expected exit 0, got $_st_rc ($_st_err)"
  [ "$_st_out" = "$expected" ] || _st_fail "valid: normalized output differs: $_st_out"
  [ -z "$_st_err" ] || _st_fail "valid: unexpected stderr: $_st_err"
  _st_passed=$((_st_passed + 1))

  _st_run needs_changes "{\"schema_version\":\"consultant-return.v1\",\"verdict\":\"needs_changes\",$counts,$findings}"
  [ "$_st_rc" -eq 0 ] || _st_fail "needs_changes: expected exit 0, got $_st_rc ($_st_err)"
  case "$_st_out" in
    *'"verdict":"fail"'*) ;;
    *) _st_fail "needs_changes: verdict not normalized to fail: $_st_out" ;;
  esac
  case "$_st_err" in
    'warn: needs_changes_normalized: '*) ;;
    *) _st_fail "needs_changes: expected warn needs_changes_normalized, got: $_st_err" ;;
  esac

  _st_passed=$((_st_passed + 1))

  # info is the one optional count key; it must survive normalization in place after low.
  local info_return='{"schema_version":"consultant-return.v1","verdict":"pass","severity_counts":{"critical":0,"high":0,"medium":0,"low":0,"info":1},"findings":[{"id":"F1","severity":"info","summary":"Verbose banner"}]}'
  _st_run info_key "$info_return"
  [ "$_st_rc" -eq 0 ] || _st_fail "info_key: expected exit 0, got $_st_rc ($_st_err)"
  [ "$_st_out" = "$info_return" ] || _st_fail "info_key: normalized output differs: $_st_out"
  [ -z "$_st_err" ] || _st_fail "info_key: unexpected stderr: $_st_err"
  _st_passed=$((_st_passed + 1))

  _st_run version_v2 "{\"schema_version\":\"consultant-return.v2\",\"verdict\":\"pass\",$counts,$findings}"
  _st_expect_reject version_v2 version_mismatch

  _st_run no_counts "{\"schema_version\":\"consultant-return.v1\",\"verdict\":\"fail\",$findings}"
  _st_expect_reject no_counts missing_severity_counts

  printf 'self-test OK (%d passed, 0 failed)\n' "$_st_passed"
  exit 0
}
