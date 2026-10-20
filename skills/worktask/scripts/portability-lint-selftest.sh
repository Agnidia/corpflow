#!/usr/bin/env bash
# portability-lint-selftest.sh — the `--self-test` harness for portability-lint.sh.
#
# SOURCED, never executed: portability-lint.sh loads this file only on the `--self-test`
# path, so the production path never pays for it. Sourcing leaves the caller's already-
# defined functions (report, scan_file, ...) in scope — this file calls `lint_one`
# against fixtures written under a temp dir and does not stand alone.
#
# Contract: defines `self_test`, exiting 0 (and printing "ALL PASS") when every case
# passes, exiting 1 with a named failure otherwise.

# lint_one <content> — writes <content> to a throwaway fixture file (outside git, so
# the git-ls-files repo subject never sees it) and lints that one explicit path.
# Sets globals LINT_OUT / LINT_RC. NOT run via `$(...)`: wrapping the call itself in a
# command substitution would subshell the assignments away before the caller ever saw
# them — only the two `bash "$0"` invocations inside are subshelled, deliberately.
lint_one() {
  local content="$1" f
  f="$ST_DIR/fixture.sh"
  printf '%s\n' "$content" > "$f"
  LINT_RC=0
  LINT_OUT=$(bash "$0" -- "$f" 2>&1) || LINT_RC=$?
}

# assert_hit <label> <rule> <content> — expects <rule> in the output and exit 1.
assert_hit() {
  local label="$1" rule="$2" content="$3"
  lint_one "$content"
  case "$LINT_OUT" in
    *":$rule:"*) [ "$LINT_RC" -eq 1 ] && { _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1)); return 0; } ;;
  esac
  printf >&2 'portability-lint self-test: FAIL (%s — expected %s, rc=1; got rc=%s out=%s)\n' \
    "$label" "$rule" "$LINT_RC" "$LINT_OUT"
  exit 1
}

# assert_clean <label> <content> — expects no hit at all, exit 0.
assert_clean() {
  local label="$1" content="$2"
  lint_one "$content"
  [ "$LINT_RC" -eq 0 ] && [ -z "$LINT_OUT" ] && { _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1)); return 0; }
  printf >&2 'portability-lint self-test: FAIL (%s — expected clean; got rc=%s out=%s)\n' \
    "$label" "$LINT_RC" "$LINT_OUT"
  exit 1
}

self_test() {
  ST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/portability-lint-selftest.XXXXXX")
  _SELFTEST_PASSED=0
  trap 'rm -rf "$ST_DIR"' EXIT

  # --- P001: mktemp -t (BSD prefix flag) vs the AD-3 template shape -----------------
  assert_hit  "P001 positive: mktemp -t"      P001 'f=$(mktemp -t foo-XXXXXX)'
  assert_hit  "P001 positive: mktemp -d -t"   P001 'd=$(mktemp -d -t foo-XXXXXX)'
  assert_clean "P001 negative: AD-3 shape"    'f=$(mktemp "${TMPDIR:-/tmp}/foo.XXXXXX")'

  # --- P002: XXXXXX run must be the final characters --------------------------------
  assert_hit  "P002 positive: suffix after X-run" P002 'f=$(mktemp "$TMPDIR/foo-XXXXXX.png")'
  assert_clean "P002 negative: trailing X-run"     'f=$(mktemp "$TMPDIR/foo-XXXXXX")'
  assert_clean "P002 negative: 8-X run"            'f=$(mktemp "$TMPDIR/foo-XXXXXXXX")'

  # --- P003: sed -i with no suffix argument ------------------------------------------
  assert_hit  "P003 positive: bare sed -i"    P003 "sed -i 's/a/b/' file.txt"
  assert_clean "P003 negative: sed -i.bak"     "sed -i.bak 's/a/b/' file.txt"
  assert_clean "P003 negative: sed -i ''"      "sed -i '' 's/a/b/' file.txt"

  # --- P004: single-path stat/date/GNU-only hash, sibling-form exoneration ----------
  assert_hit  "P004 positive: bare stat -c"   P004 'x=$(stat -c %s "$f")'
  assert_clean "P004 negative: stat -c and -f both present" \
    'if stat -c %s "$f" 2>/dev/null; then :; else stat -f %z "$f"; fi'
  assert_hit  "P004 positive: bare date -d"   P004 'x=$(date -d "$s" +%s)'
  assert_clean "P004 negative: date -d and -r both present" \
    'x=$(date -d "$s" +%s 2>/dev/null || date -r "$s" +%s)'
  assert_hit  "P004 positive: bare md5sum"    P004 'x=$(md5sum "$f")'
  assert_clean "P004 negative: shasum present exonerates md5sum" \
    'x=$(md5sum "$f" 2>/dev/null || shasum "$f")'
  assert_clean "P004 negative: shasum alone is portable, never flagged" \
    'x=$(shasum "$f")'

  # --- P005: bash 4+ syntax against the bash 3.2 floor -------------------------------
  assert_hit  "P005 positive: declare -A"     P005 'declare -A m'
  assert_hit  "P005 positive: mapfile"        P005 'mapfile -t lines < "$f"'
  assert_hit  "P005 positive: case conversion" P005 'echo "${v^^}"'
  assert_clean "P005 negative: bash 3.2-safe"  'local v="${1:-}"; echo "$v"'

  # --- P006: unguarded Apple-only binary at command position -------------------------
  assert_hit  "P006 positive: unguarded osascript" P006 'osascript -e "beep"'
  assert_clean "P006 negative: command -v guarded" \
    'command -v osascript >/dev/null 2>&1 && osascript -e "beep"'

  # --- P007: direct uname call outside host-os-lib.sh ---------------------------------
  assert_hit  "P007 positive: uname -s"       P007 'case "$(uname -s)" in Darwin) ;; esac'
  assert_clean "P007 negative: host_os() call" 'case "$(host_os)" in macos) ;; esac'

  # --- P008: GNU-only flags -----------------------------------------------------------
  assert_hit  "P008 positive: grep -P"        P008 'grep -P "\\d+" "$f"'
  assert_hit  "P008 positive: find -printf"   P008 'find . -printf "%f\\n"'
  assert_hit  "P008 positive: sort -V"        P008 'sort -V "$f"'
  assert_hit  "P008 positive: readlink -f"    P008 'readlink -f "$f"'
  assert_clean "P008 negative: no GNU-only flag" 'sort "$f" | grep foo'
  assert_clean "P008 negative: git grep -P is exempt" "git grep -P '\\d+' ."
  assert_hit  "P008 positive: bare grep -P after git grep -P" P008 "git grep -nP x . | grep -P 'y'"

  # --- P009: \b in a git grep pattern without -P -------------------------------------
  assert_hit  "P009 positive: git grep -nE with \\b" P009 "git grep -nE '\\bfoo\\b' ."
  assert_clean "P009 negative: git grep -nP with \\b" "git grep -nP '\\bfoo\\b' ."

  # --- P000: a disable directive with no reason ---------------------------------------
  assert_hit  "P000: reasonless inline directive" P000 \
    'f=$(mktemp -t foo-XXXXXX) # portability-lint disable=P001'
  assert_hit  "P000: unknown rule id" P000 \
    'f=$(mktemp "${TMPDIR:-/tmp}/foo.XXXXXX") # portability-lint disable=P999 — typo'\''d id'

  # --- Suppression tier 1: comment-only lines are never scanned ----------------------
  assert_clean "tier1: mktemp -t inside a comment" \
    '# mktemp -t foo-XXXXXX is what NOT to write'

  # --- Suppression tier 2: inline directive, same line or line above -----------------
  assert_clean "tier2: same-line directive with reason" \
    'f=$(mktemp -t foo-XXXXXX) # portability-lint disable=P001 — legacy, migration tracked'
  {
    printf '%s\n' '# portability-lint disable=P001 — legacy, migration tracked'
    printf '%s\n' 'f=$(mktemp -t foo-XXXXXX)'
  } > "$ST_DIR/tier2-above.sh"
  out=$(bash "$0" -- "$ST_DIR/tier2-above.sh" 2>&1) || LINT_RC=$?
  LINT_RC="${LINT_RC:-0}"
  if [ "$LINT_RC" -ne 0 ] || [ -n "$out" ]; then
    printf >&2 'portability-lint self-test: FAIL (tier2: directive on the line above — rc=%s out=%s)\n' "$LINT_RC" "$out"
    exit 1
  fi
  _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  LINT_RC=0

  # --- Suppression tier 3: file-level disable-file within the first 20 lines ---------
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# portability-lint disable-file=P001,P002 — fixture, exercising tier 3'
    printf '%s\n' 'f=$(mktemp -t foo-XXXXXX)'
  } > "$ST_DIR/tier3.sh"
  out=$(bash "$0" -- "$ST_DIR/tier3.sh" 2>&1) || LINT_RC=$?
  LINT_RC="${LINT_RC:-0}"
  if [ "$LINT_RC" -ne 0 ] || [ -n "$out" ]; then
    printf >&2 'portability-lint self-test: FAIL (tier3: file-level disable-file — rc=%s out=%s)\n' "$LINT_RC" "$out"
    exit 1
  fi
  _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  LINT_RC=0

  # --- Suppression tier 4: hard path exclusions (tests/vendor/) ----------------------
  # $0 resolved to an absolute path first: a relative $0 (the common case for a
  # self-invoked selftest) would otherwise break once the subshell below `cd`s away.
  local self_abs
  self_abs="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  mkdir -p "$ST_DIR/tests/vendor"
  printf '%s\n' 'f=$(mktemp -t foo-XXXXXX)' > "$ST_DIR/tests/vendor/vendored.sh"
  out=$(cd "$ST_DIR" && bash "$self_abs" -- "tests/vendor/vendored.sh" 2>&1) || LINT_RC=$?
  LINT_RC="${LINT_RC:-0}"
  if [ "$LINT_RC" -ne 0 ] || [ -n "$out" ]; then
    printf >&2 'portability-lint self-test: FAIL (tier4: tests/vendor exclusion — rc=%s out=%s)\n' "$LINT_RC" "$out"
    exit 1
  fi
  _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))

  printf 'portability-lint: self-test ALL PASS (%d passed, 0 failed)\n' "$_SELFTEST_PASSED"
}
