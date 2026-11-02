#!/usr/bin/env bats
# acceptance-check.sh: DV may hand off, and QA may pass, only when every DV acceptance command
# was executed with exit 0 and none fails open. The R1 fixture replays the benchmark failure — a
# byte-exact board contract that DV listed and QA never ran — and must come out no-go.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

CHECK="skills/worktask/scripts/acceptance-check.sh"

setup() {
  cd "$PLUGIN_ROOT"
  DV="$BATS_TEST_TMPDIR/development-0.md"
  QA="$BATS_TEST_TMPDIR/testing-0.md"
  cat > "$DV" <<'MD'
## verification-command

swift test

## acceptance-commands

```bash
# board rows keep one leading and one trailing space
printf 'x\n' | .build/debug/tictactoe --moves 1 | cmp - expected/board-1.txt
.build/debug/tictactoe --moves 1,2 | cmp - expected/board-2.txt
```

## decisions

none
MD
}

qa_with() {
  { printf '## summary\n\nok\n\n## acceptance-commands\n\n'; printf '%s\n' "$@"; printf '\n## notes\n\n- exit=0 ignored outside the anchor\n'; } > "$QA"
}

@test "R1 replay: QA ran no acceptance command -> no-go" {
  printf '## summary\n\nswift test: 48 passed\n' > "$QA"
  run bash "$CHECK" --qa "$QA" --dv "$DV"
  [ "$status" -eq 1 ]
  assert_line --index 0 "acceptance: 0/2 executed, 0 failed"
  assert_line --partial "missing: .build/debug/tictactoe --moves 1,2 | cmp - expected/board-2.txt"
}

@test "every command executed with exit 0 -> pass" {
  qa_with "- exit=0 printf 'x\n' | .build/debug/tictactoe --moves 1 | cmp - expected/board-1.txt" \
          "- exit=0 \`.build/debug/tictactoe --moves 1,2 | cmp - expected/board-2.txt\`"
  run bash "$CHECK" --qa "$QA" --dv "$DV"
  [ "$status" -eq 0 ]
  assert_output "acceptance: 2/2 executed, 0 failed"
}

@test "an executed command that failed -> no-go" {
  qa_with "- exit=0 printf 'x\n' | .build/debug/tictactoe --moves 1 | cmp - expected/board-1.txt" \
          "- exit=1 .build/debug/tictactoe --moves 1,2 | cmp - expected/board-2.txt"
  run bash "$CHECK" --qa "$QA" --dv "$DV"
  [ "$status" -eq 1 ]
  assert_line --partial "failed: .build/debug/tictactoe --moves 1,2"
}

@test "rows outside the QA anchor do not count" {
  qa_with "- exit=0 printf 'x\n' | .build/debug/tictactoe --moves 1 | cmp - expected/board-1.txt"
  printf -- '- exit=0 .build/debug/tictactoe --moves 1,2 | cmp - expected/board-2.txt\n' >> "$QA"
  run bash "$CHECK" --qa "$QA" --dv "$DV"
  [ "$status" -eq 1 ]
  assert_line --index 0 "acceptance: 1/2 executed, 0 failed"
}

@test "no acceptance-commands in any DV artifact -> pass with 0/0" {
  printf '## decisions\n\nnone\n' > "$DV"
  printf '## summary\n\nok\n' > "$QA"
  run bash "$CHECK" --qa "$QA" --dv "$DV"
  [ "$status" -eq 0 ]
  assert_output "acceptance: 0/0 executed, 0 failed"
}

@test "commands union across DV artifacts, duplicates counted once" {
  DV2="$BATS_TEST_TMPDIR/development-1.md"
  cp "$DV" "$DV2"
  qa_with "- exit=0 printf 'x\n' | .build/debug/tictactoe --moves 1 | cmp - expected/board-1.txt"
  run bash "$CHECK" --qa "$QA" --dv "$DV" --dv "$DV2"
  [ "$status" -eq 1 ]
  assert_line --index 0 "acceptance: 1/2 executed, 0 failed"
}

@test "usage errors exit 2: no --dv, with or without --qa, names both forms" {
  run --separate-stderr bash "$CHECK"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"acceptance-check.sh --dv <development-N.md>"* ]]
  [[ "$stderr" == *"acceptance-check.sh --qa <testing-N.md> --dv <development-N.md>"* ]]
  run bash "$CHECK" --qa "$QA"
  [ "$status" -eq 2 ]
  run bash "$CHECK" --qa /nonexistent --dv "$DV"
  [ "$status" -eq 2 ]
  run bash "$CHECK" --dv /nonexistent
  [ "$status" -eq 2 ]
}

# DV self-check (--dv alone): the rows are DV's own, next to the fence it lists them in.
dv_self() {  # <row line|-> — one acceptance command and, unless `-`, one row for it
  { printf '## acceptance-commands\n\n```bash\ntest -f missing.txt\n```\n\n'
    [ "$1" = "-" ] || printf '%s\n' "$1"
    printf '\n## decisions\n\n- exit=0 test -f missing.txt\n'; } > "$DV"
}

@test "self: a recorded non-zero exit -> exactly the failed block, exit 1" {
  dv_self "- exit=1 test -f missing.txt"
  run bash "$CHECK" --dv "$DV"
  [ "$status" -eq 1 ]
  [ "$output" = "$(printf 'acceptance: 1/1 executed, 1 failed\nfailed: test -f missing.txt')" ]
}

@test "self: every row exit 0 -> pass" {
  dv_self "- exit=0 test -f missing.txt"
  run bash "$CHECK" --dv "$DV"
  [ "$status" -eq 0 ]
  assert_output "acceptance: 1/1 executed, 0 failed"
}

@test "self: no row -> missing, exit 1; a row outside the anchor does not count" {
  dv_self -
  run bash "$CHECK" --dv "$DV"
  [ "$status" -eq 1 ]
  assert_line --index 0 "acceptance: 0/1 executed, 0 failed"
  assert_line "missing: test -f missing.txt"
}

@test "self: a row-shaped line inside the fence is a command, not evidence" {
  printf '## acceptance-commands\n\n```bash\n- exit=0 true\n```\n' > "$DV"
  run bash "$CHECK" --dv "$DV"
  [ "$status" -eq 1 ]
  assert_line --index 0 "acceptance: 0/1 executed, 0 failed"
}

@test "self: the DV fixture with no rows is all missing, and QA mode ignores DV rows" {
  run bash "$CHECK" --dv "$DV"
  [ "$status" -eq 1 ]
  assert_line --index 0 "acceptance: 0/2 executed, 0 failed"
  dv_self "- exit=0 test -f missing.txt"
  printf '## summary\n\nok\n' > "$QA"
  run bash "$CHECK" --qa "$QA" --dv "$DV"
  [ "$status" -eq 1 ]
  assert_line "missing: test -f missing.txt"
}

# Fail-open tail lint: a command that exits 0 whatever it found makes its own green row worthless.
fail_open_dv() {  # <command> — one command with an exit=0 row
  printf '## acceptance-commands\n\n```bash\n%s\n```\n\n- exit=0 %s\n' "$1" "$1" > "$DV"
}

@test "fail-open: a || true tail -> exactly the fail-open block, exit 1" {
  fail_open_dv "git grep -qF foo README.md || true"
  run bash "$CHECK" --dv "$DV"
  [ "$status" -eq 1 ]
  [ "$output" = "$(printf 'acceptance: 1/1 executed, 0 failed\nfail-open: git grep -qF foo README.md || true')" ]
}

@test "fail-open: || :, || echo and || printf tails are reported the same way" {
  local c
  for c in "grep -q x f || :" "grep -q x f || echo clean" "grep -q x f || printf x" \
    "grep -q x f||true # why" "a | grep -q x || true" "a && grep -q x || echo \"no\"" \
    "grep -q x f || echo x >&2" "grep -q x f || echo x 1>&2" "grep -q x f || printf x 2>&1" \
    "grep -q x f || echo x &> log" "grep -q x f || echo x >| log" "grep -q x f || true <&0"; do
    fail_open_dv "$c"
    run bash "$CHECK" --dv "$DV"
    [ "$status" -eq 1 ] || fail "not flagged: $c"
    assert_line "fail-open: $c"
  done
}

@test "fail-open: || exit 1, || false, quoted, nested or non-tail forms are not reported" {
  local c
  for c in "grep -q x f || exit 1" "grep -q x f || false" "grep -q 'a || true' f" \
    'test "$(grep -c x f || true)" = 0' "( grep -q x f || true )" "grep -q x f || true; test -s f" \
    "grep -q x f || echo x | cmp - f" "a 2>&1 | cmp - f" "grep -q x f || echo x 2>&1 | cmp - f"; do
    fail_open_dv "$c"
    run bash "$CHECK" --dv "$DV"
    [ "$status" -eq 0 ] || fail "flagged: $c -> $output"
  done
}

@test "fail-open: the lint applies in QA mode too" {
  fail_open_dv "grep -q x f || true"
  qa_with "- exit=0 grep -q x f || true"
  run bash "$CHECK" --qa "$QA" --dv "$DV"
  [ "$status" -eq 1 ]
  [ "$output" = "$(printf 'acceptance: 1/1 executed, 0 failed\nfail-open: grep -q x f || true')" ]
}
