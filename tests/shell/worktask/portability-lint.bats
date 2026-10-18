#!/usr/bin/env bats
# Contract tests for skills/worktask/scripts/portability-lint.sh.
# Contracts (from header + architecture-0.md AD-2):
#   - explicit-file mode: a hit prints "<path>:<line>:<RULE-ID>: <message>", exit 1
#   - clean input: no output, exit 0
#   - rules P001-P009, one positive + one negative case each (see selftest for the
#     exhaustive per-rule fixtures; this file covers the CLI contract plus one
#     representative rule end to end)
#   - suppression tier 1: a comment-only line is never scanned
#   - suppression tier 2: an inline `disable=` directive, same line or line above,
#     with a mandatory reason
#   - suppression tier 3: a file-level `disable-file=` directive in the first 20 lines
#   - suppression tier 4: tests/vendor/ is a hard path exclusion
#   - P000: a disable directive with no reason, or naming only unknown rule ids
#   - --self-test => "ALL PASS", exit 0
#   - -h/--help prints usage, exit 0
#   - usage error (no args, not a git repo) exits 2
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/worktask/scripts/portability-lint.sh"

setup() {
  WD="$(mk_tmpworkdir)"
}

@test "happy: clean input exits 0 with no output" {
  printf 'f=$(mktemp "${TMPDIR:-/tmp}/foo.XXXXXX")\n' > "$WD/clean.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/clean.sh"
  assert_success
  assert_output ""
}

@test "P001: mktemp -t is flagged with file, line and rule id" {
  printf 'f=$(mktemp -t foo-XXXXXX)\n' > "$WD/hit.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/hit.sh"
  assert_failure 1
  assert_output --partial "$WD/hit.sh:1:P001:"
}

@test "P001: mktemp -d -t is flagged too (the -d -t form the plan's narrower regex missed)" {
  printf 'd=$(mktemp -d -t foo-XXXXXX)\n' > "$WD/hit.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/hit.sh"
  assert_failure 1
  assert_output --partial ":P001:"
}

@test "P002: a suffix after the XXXXXX run is flagged" {
  printf 'f=$(mktemp "$TMPDIR/foo-XXXXXX.png")\n' > "$WD/hit.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/hit.sh"
  assert_failure 1
  assert_output --partial ":P002:"
}

@test "P002 negative: an 8-X run (no backtracking false positive)" {
  printf 'f=$(mktemp "$TMPDIR/foo-XXXXXXXX")\n' > "$WD/clean.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/clean.sh"
  assert_success
}

@test "P003: sed -i with no suffix is flagged, sed -i.bak is not" {
  printf "sed -i 's/a/b/' f.txt\n" > "$WD/hit.sh"
  printf "sed -i.bak 's/a/b/' f.txt\n" > "$WD/clean.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/hit.sh"
  assert_failure 1
  assert_output --partial ":P003:"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/clean.sh"
  assert_success
}

@test "P004: a bare GNU-only hash tool is flagged; shasum alone never is" {
  printf 'x=$(md5sum "$f")\n' > "$WD/hit.sh"
  printf 'x=$(shasum "$f")\n' > "$WD/clean.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/hit.sh"
  assert_failure 1
  assert_output --partial ":P004:"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/clean.sh"
  assert_success
}

@test "P004: shasum anywhere in the file exonerates a bare md5sum in it (sibling-form check, not tautological)" {
  printf 'x=$(md5sum "$f" 2>/dev/null || shasum "$f")\n' > "$WD/clean.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/clean.sh"
  assert_success
}

@test "P004: a file with || but no sibling hash form still fires (the tautology this rule was fixed to not have)" {
  printf 'x=$(md5sum "$f") || true\n' > "$WD/hit.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/hit.sh"
  assert_failure 1
  assert_output --partial ":P004:"
}

@test "P005: declare -A is flagged, a bash 3.2-safe local is not" {
  printf 'declare -A m\n' > "$WD/hit.sh"
  printf 'local v="${1:-}"\n' > "$WD/clean.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/hit.sh"
  assert_failure 1
  assert_output --partial ":P005:"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/clean.sh"
  assert_success
}

@test "P006: an unguarded Apple-only binary is flagged; command -v guarded is not" {
  printf 'osascript -e "beep"\n' > "$WD/hit.sh"
  printf 'command -v osascript >/dev/null 2>&1 && osascript -e "beep"\n' > "$WD/clean.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/hit.sh"
  assert_failure 1
  assert_output --partial ":P006:"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/clean.sh"
  assert_success
}

@test "P007: a direct uname call is flagged; host_os() is not" {
  printf 'case "$(uname -s)" in Darwin) ;; esac\n' > "$WD/hit.sh"
  printf 'case "$(host_os)" in macos) ;; esac\n' > "$WD/clean.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/hit.sh"
  assert_failure 1
  assert_output --partial ":P007:"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/clean.sh"
  assert_success
}

@test "P007: portability-lint.sh's own uname-naming pattern/message text does not self-flag" {
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$PLUGIN_ROOT/$SCRIPT"
  refute_output --partial ":P007:"
}

@test "P008: GNU-only flags (grep -P, find -printf, sort -V, readlink -f) are each flagged" {
  printf 'grep -P "\\d+" "$f"\n' > "$WD/a.sh"
  printf 'find . -printf "%%f\\n"\n' > "$WD/b.sh"
  printf 'sort -V "$f"\n' > "$WD/c.sh"
  printf 'readlink -f "$f"\n' > "$WD/d.sh"
  for f in a b c d; do
    run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/$f.sh"
    assert_failure 1
    assert_output --partial ":P008:"
  done
}

@test "P008 negative: git grep -P is exempt, a bare grep -P in the same pipeline still fires" {
  printf "git grep -P '\\\\d+' .\n" > "$WD/a.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/a.sh"
  assert_success
  assert_output ""
  printf "git grep -nP x . | grep -P 'y'\n" > "$WD/b.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/b.sh"
  assert_failure 1
  assert_output --partial "$WD/b.sh:1:P008:"
}

@test "P009: \\b in a git grep -E pattern is flagged with file, line, rule id and the -P/-w fix" {
  printf "git grep -nE '\\\\bfoo\\\\b' .\n" > "$WD/a.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/a.sh"
  assert_failure 1
  assert_output --partial "$WD/a.sh:1:P009:"
  assert_output --partial "git grep -P"
  assert_output --partial "git grep -w"
}

@test "P009: a git global option before grep and the default BRE are flagged too" {
  printf "git -C \"\$d\" grep -E '\\\\bx' .\n" > "$WD/a.sh"
  printf "git grep -n '\\\\bx' -- '*.md'\n" > "$WD/b.sh"
  for f in a b; do
    run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/$f.sh"
    assert_failure 1
    assert_output --partial ":P009:"
  done
}

@test "P009 negative: git grep -nP keeps \\b, git grep -nwE needs none" {
  printf "git grep -nP '\\\\bfoo\\\\b' .\n" > "$WD/a.sh"
  printf "git grep -nwE 'foo' .\n" > "$WD/b.sh"
  for f in a b; do
    run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/$f.sh"
    assert_success
    assert_output ""
  done
}

@test "P009 negative: plain grep -E with \\b stays out of scope (sw-PL0-1)" {
  printf "grep -qE '\\\\bfoo\\\\b' \"\$f\"\n" > "$WD/a.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/a.sh"
  assert_success
}

@test "P000: a disable directive with no reason is itself reported" {
  printf 'f=$(mktemp -t foo-XXXXXX) # portability-lint disable=P001\n' > "$WD/hit.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/hit.sh"
  assert_failure 1
  assert_output --partial ":P000:"
}

@test "P000: a disable directive naming only an unknown rule id is reported" {
  printf "f=\$(mktemp \"\${TMPDIR:-/tmp}/foo.XXXXXX\") # portability-lint disable=P999 — typo'd\n" > "$WD/hit.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/hit.sh"
  assert_failure 1
  assert_output --partial ":P000:"
}

@test "P000: a reasonless disable-file= directive is reported too (regression guard: scan_directive_reasonless once matched disable= only)" {
  {
    printf '#!/usr/bin/env bash\n'
    printf '# portability-lint disable-file=P001\n'
    printf 'f=$(mktemp "${TMPDIR:-/tmp}/foo.XXXXXX")\n'
  } > "$WD/hit.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/hit.sh"
  assert_failure 1
  assert_output --partial ":P000:"
}

@test "tier 1: a comment-only line is never scanned" {
  printf '# mktemp -t foo-XXXXXX is what NOT to write\n' > "$WD/clean.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/clean.sh"
  assert_success
}

@test "tier 1: an INDENTED code line with a trailing comment is still scanned (regression guard for the B2 glob bug)" {
  # The round-0 glob `[[:space:]]*'#'*` reads as "one whitespace char, anything, #,
  # anything" — it wrongly treated any indented line containing a `#` ANYWHERE as a
  # comment-only line, so real code before a trailing comment was skipped entirely.
  printf '    f=$(mktemp -t foo-XXXXXX) # trailing comment, not the whole line\n' > "$WD/hit.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/hit.sh"
  assert_failure 1
  assert_output --partial ":P001:"
}

@test "tier 2: an inline directive with a reason suppresses the same-line hit" {
  printf 'f=$(mktemp -t foo-XXXXXX) # portability-lint disable=P001 — legacy, migration tracked\n' > "$WD/clean.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/clean.sh"
  assert_success
}

@test "tier 2: an inline directive on the line above suppresses the hit below it" {
  {
    printf '# portability-lint disable=P001 — legacy, migration tracked\n'
    printf 'f=$(mktemp -t foo-XXXXXX)\n'
  } > "$WD/clean.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/clean.sh"
  assert_success
}

@test "tier 3: a file-level disable-file directive in the first 20 lines suppresses every matching hit" {
  {
    printf '#!/usr/bin/env bash\n'
    printf '# portability-lint disable-file=P001,P002 — fixture, exercising tier 3\n'
    printf 'f=$(mktemp -t foo-XXXXXX)\n'
    printf 'g=$(mktemp -t bar-XXXXXX)\n'
  } > "$WD/clean.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "$WD/clean.sh"
  assert_success
}

@test "tier 4: tests/vendor/ is a hard path exclusion" {
  mkdir -p "$WD/tests/vendor"
  printf 'f=$(mktemp -t foo-XXXXXX)\n' > "$WD/tests/vendor/vendored.sh"
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" -- "tests/vendor/vendored.sh"
  assert_success
}

@test "usage: -h/--help prints usage and exits 0" {
  run bash "$PLUGIN_ROOT/$SCRIPT" -h
  assert_success
  assert_output --partial "Usage"
}

@test "usage: an unknown option exits 2" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --bogus
  assert_failure 2
}

@test "contract: --self-test passes" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "ALL PASS"
  assert_output --regexp 'ALL PASS \([1-9][0-9]* passed, 0 failed\)'
}

@test "REQ-2 crit 2: the lint is green against this repository's own tracked tree" {
  cd "$PLUGIN_ROOT"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
}
