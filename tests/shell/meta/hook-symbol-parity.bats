#!/usr/bin/env bats
# tests/shell/meta/hook-symbol-parity.bats
# Target: the shared hook library's symbol surface versus what hooks/ calls.
#
# A renamed or deleted library symbol is the failure most likely to actually
# happen, and it is silent at runtime: every consumer degrades to a fail-open
# allow rather than erroring, which is correct behaviour and therefore invisible.
# This is the check that makes the rename loud, at CI, in one place.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

LIB="${BATS_TEST_DIRNAME}/../../../hooks/model-switch-lib.sh"
# The second hook-side library. It is readonly-free by contract — it is mirrored from
# skills/shared/lib/ and consumer suites source it twice per process — so it supplies
# symbols to P1/P4 but is outside the readonly -f isolation contract P2/P3 police.
BASE_LIB="${BATS_TEST_DIRNAME}/../../../hooks/lib/corpflow-base.sh"
# The third symbol source. Hook code sources it only where it scrubs — one helper inside a
# per-call subshell, hooks/lib/command-head-lib.sh lazily on its first redaction — so like
# BASE_LIB it feeds P1/P4 and stays outside P2/P3. It matters here because both consumers
# fail open to an empty or redacted result, so a rename is otherwise silent.
PS_LIB="${BATS_TEST_DIRNAME}/../../../skills/shared/scripts/path-scrub.sh"
# The fourth symbol source. model-switch-lib lazy-sources it on ranks 5-6 for
# corpflow_inferred_ctx_ok; it is readonly-free, so it feeds P1/P4 only.
SRL_LIB="${BATS_TEST_DIRNAME}/../../../skills/shared/lib/state-read-lib.sh"
HOOKDIR="${BATS_TEST_DIRNAME}/../../../hooks"

# Every corpflow_* token any hook mentions, libraries included.
_referenced() {
  grep -rhoE 'corpflow_[a-z_]+' "$HOOKDIR" | sort -u
}

_defined_in() {
  grep -oE '^corpflow_[a-z_]+\(\)' "$1" | sed 's/()//' | sort -u
}

# Every corpflow_* any hook library defines, by definition syntax alone.
_defined() {
  { _defined_in "$LIB"; _defined_in "$BASE_LIB"; _defined_in "$PS_LIB"; _defined_in "$SRL_LIB"; } | sort -u
}

# Every corpflow_* the library freezes with readonly -f.
_frozen() {
  sed -n '/^readonly -f/,/[^\\]$/p' "$LIB" | grep -oE 'corpflow_[a-z_]+' | sort -u
}

@test "P1: every corpflow_* referenced under hooks/ is defined by the library" {
  local missing
  missing="$(comm -23 <(_referenced) <(_defined))"
  [ -z "$missing" ] || fail "referenced but defined by none of $LIB, $BASE_LIB, $PS_LIB, $SRL_LIB: $missing"
}

@test "P2: every defined symbol is readonly -f'd" {
  # readonly -f is what makes self-test isolation un-violable rather than merely
  # checkable: a body that tried to redefine a symbol is refused outright.
  local unfrozen
  unfrozen="$(comm -23 <(_defined_in "$LIB") <(_frozen))"
  [ -z "$unfrozen" ] || fail "defined but not readonly -f'd: $unfrozen"
}

@test "P3: readonly -f names nothing the library does not define" {
  local phantom
  phantom="$(comm -13 <(_defined_in "$LIB") <(_frozen))"
  [ -z "$phantom" ] || fail "readonly -f names an undefined symbol: $phantom"
}

@test "P4: ANTI-VACUITY — a planted reference to a nonexistent symbol is caught" {
  # Without this the whole file passes trivially the day the greps stop matching.
  local wd="$(mk_tmpworkdir)"
  cp -R "$HOOKDIR" "$wd/hooks"
  printf '\ncorpflow_no_such_symbol "$CTX"\n' >> "$wd/hooks/model-switch-gate.sh"
  local missing
  missing="$(comm -23 \
    <(grep -rhoE 'corpflow_[a-z_]+' "$wd/hooks" | sort -u) \
    <(_defined))"
  [ "$missing" = "corpflow_no_such_symbol" ]
}

@test "P5: every consumer sources the library under the guarded idiom" {
  # `[ -f ]` alone does not cover a TRUNCATED library: a syntax error in a sourced
  # file is fatal under set -e and `||` cannot rescue it. The $- save/restore is
  # what keeps that from turning a fail-open hook into a hard block.
  # audit-subagent runs under `set -eu`, so for it the idiom is load-bearing.
  local f
  for f in model-switch-gate model-switch-audit test-execution-gate state-merge audit-subagent; do
    grep -q 'set +e' "$HOOKDIR/$f.sh" \
      || fail "$f.sh sources the library without dropping -e first"
    grep -qE 'case "\$_[cC][fF]_[oO][pP][tT][sS]" in \*e\*\) set -e' "$HOOKDIR/$f.sh" \
      || fail "$f.sh does not restore -e from a captured \$-"
    grep -qE 'command -v corpflow_[a-z_]+' "$HOOKDIR/$f.sh" \
      || fail "$f.sh has no symbol probe after the source"
  done
}
