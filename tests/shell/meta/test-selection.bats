#!/usr/bin/env bats
# tests/shell/meta/test-selection.bats
# Target: the change→test dependency matrix.
#
# Every guard drives the same sel_select_for_path() the real run drives, so the
# checker is itself falsifiable: M9/M10/M11 plant a violation in a synthetic tree
# and require the engine to name it. A guard with its own parser or its own rule
# evaluation would validate a grammar the engine does not implement.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"
load "${BATS_TEST_DIRNAME}/../../lib/select_lib.bash"

SELECTOR="${PLUGIN_ROOT}/tests/bin/select-tests.sh"
MATRIX="${PLUGIN_ROOT}/tests/selection/matrix.tsv"

setup() {
  sel_context_init "$PLUGIN_ROOT"
}

@test "selector self-test reports the seven executed cases" {
  run bash "$SELECTOR" --self-test
  assert_success
  assert_output --partial "select-tests.sh: self-test OK"
  assert_output --regexp 'select-tests.sh: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
  assert_output "select-tests.sh: self-test OK (7 passed, 0 failed)"
}

_targets_of() {
  sel_matrix_rows | awk -F'\t' '$2 != "NONE" && $2 != "FULL" {
    n = split($2, a, ","); for (i = 1; i <= n; i++) print "tests/shell/" a[i] ".bats"
  }' | LC_ALL=C sort -u
}

# Rule ids carrying a `# STALE-OK:` decorator on the immediately preceding line.
_stale_ok_rules() {
  awk -F'\t' '
    /^# STALE-OK:/ { pending = 1; next }
    /^#/ || /^[[:space:]]*$/ { pending = 0; next }
    { if (pending) print $3; pending = 0 }' "$MATRIX"
}

_selected_files() {
  sel_select_for_path "$1" "${2:-M}" | awk -F'\t' '$1 == "BATS" { print $2 }' | LC_ALL=C sort -u
}

# --- shape: the matrix is real ----------------------------------------------

@test "M1: the matrix parses, and the inventory it is judged against is plausible" {
  # Without this every assertion below could pass vacuously on a broken parse —
  # the failure mode coverage-proxy C1 exists to prevent.
  run sel_matrix_rows
  assert_success
  refute_output --partial "FULL	F7"
  [ "${#lines[@]}" -ge 10 ] || fail "only ${#lines[@]} matrix rows parsed; expected >= 10"

  run sel_all_bats
  assert_success
  [ "${#lines[@]}" -ge 50 ] || fail "only ${#lines[@]} .bats discovered; expected >= 50"

  run sel_always_set
  assert_success
  [ "${#lines[@]}" -ge 1 ] || fail "the ALWAYS set is empty; every scoped run would have no floor"
}

@test "M2: every glob matches at least one tracked path" {
  local files stale g t r rat f hit
  files="$(cd "$PLUGIN_ROOT" && git ls-files)"
  [ -n "$files" ] || skip "not a git checkout"
  stale="$(_stale_ok_rules)"

  while IFS=$'\t' read -r g t r rat; do
    case "$stale" in *"$r"*) continue ;; esac
    hit=0
    while IFS= read -r f; do
      sel_glob_match "$g" "$f" && { hit=1; break; }
    done <<< "$files"
    [ "$hit" -eq 1 ] || fail "$r: glob '$g' matches no tracked path (add '# STALE-OK: <reason>' above it if deliberate)"
  done <<< "$(sel_matrix_rows)"
}

@test "M3: every target names a .bats that exists, or is NONE/FULL" {
  local t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ -f "$PLUGIN_ROOT/$t" ] || fail "matrix names a target that does not exist: $t"
  done <<< "$(_targets_of)"
}

# --- reachability: nothing may fall out of the selection universe ------------

@test "M4: every matrix row fires, every .bats is reachable, and basenames are unique" {
  local reach orphans dupes files stale g t r rat rep f got ids maxid i

  # Deleting a row cannot be caught by iterating the rows that remain, so the
  # rule-id space is the independent expectation: ids are contiguous R01..Rmax,
  # and a removed row leaves a gap this names. Retire a row by setting its target
  # to NONE (+ `# STALE-OK:` if the glob also goes dead), never by deleting the
  # id — that is the idiom R23/R24 already use.
  ids="$(sel_matrix_rows | awk -F'\t' '{ print $3 }' | grep -c '^R[0-9][0-9]$' || true)"
  maxid="$(sel_matrix_rows | awk -F'\t' '$3 ~ /^R[0-9][0-9]$/ { print $3 }' | LC_ALL=C sort | tail -1)"
  [ -n "$maxid" ] || fail "the matrix declares no R.. rule ids at all; every L2 row is gone"
  for (( i = 1; i <= ${maxid#R} + 0; i++ )); do
    sel_matrix_rows | awk -F'\t' -v w="$(printf 'R%02d' "$i")" '$3 == w { found = 1 } END { exit !found }' \
      || fail "$(printf 'R%02d' "$i") is missing from the matrix — rule ids must be contiguous R01..$maxid; retire a row with target NONE instead of deleting it"
  done
  [ "$ids" -eq "${maxid#R}" ] || fail "$ids rule ids for a max of $maxid — duplicate or malformed ids"

  # Completeness half of M10: M10 proves the deleted-row mechanism on a synthetic
  # fixture, which by construction cannot notice a real row going missing. Here
  # every REAL row must fire on a real tracked path, carrying its own L2:<rule>
  # provenance — so deleting or emptying matrix.tsv turns this red and names the
  # row, its glob and its lost target.
  files="$(cd "$PLUGIN_ROOT" && git ls-files)"
  [ -n "$files" ] || skip "not a git checkout"
  stale="$(_stale_ok_rules)"
  while IFS=$'\t' read -r g t r rat; do
    [ -n "$r" ] || continue
    case "$stale" in *"$r"*) continue ;; esac
    [ "$t" = "NONE" ] && continue
    # A foundation path short-circuits to F5 before any row is consulted, so it
    # can never witness a row firing.
    rep=""
    while IFS= read -r f; do
      sel_is_foundation "$f" && continue
      sel_glob_match "$g" "$f" && { rep="$f"; break; }
    done <<< "$files"
    [ -n "$rep" ] || fail "$r: glob '$g' matches no selectable tracked path"
    if [ "$t" = "FULL" ]; then
      got="$(sel_select_for_path "$rep" M | awk -F'\t' -v r="$r" '$1 == "FULL" && $2 == r { print $2 }')"
    else
      got="$(sel_select_for_path "$rep" M | awk -F'\t' -v r="$r" '$3 == "L2" && $4 == r { print $2 }')"
    fi
    [ -n "$got" ] || fail "$r: row (glob '$g' -> $t) is not load-bearing — '$rep' matches the glob but the selection carries no L2:$r record; the row is missing or dead"
  done <<< "$(sel_matrix_rows)"

  # `sel_build_index | cut -f2` alone is "every .bats that mentions any tracked
  # path", which is near-universal and can never report an orphan. A row whose
  # referenced path IS the .bats itself is the SELF edge: it only fires when
  # someone edits the test file, which is precisely an orphan that never runs
  # when the code under test changes. Excluded, so this half can fail.
  reach="$(
    { _targets_of
      sel_always_set | cut -f2
      sel_build_index | awk -F'\t' '$1 != $2 { print $2 }'
    } | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u
  )"
  orphans="$(comm -23 <(sel_all_bats) <(printf '%s\n' "$reach"))"
  [ -z "$orphans" ] || fail "unreachable under selection (never runs scoped): $orphans"

  # sel_resolve_bats picks the LC_ALL=C-first match on a basename collision; this
  # keeps that tie-break unreachable rather than merely deterministic.
  dupes="$(sel_all_bats | sed 's#.*/##' | LC_ALL=C sort | uniq -d)"
  [ -z "$dupes" ] || fail "duplicate .bats basenames defeat convention resolution: $dupes"
}

@test "M5: every shared doc appears in exactly one precise row" {
  local d n
  for d in "$PLUGIN_ROOT"/skills/shared/*.md; do
    d="skills/shared/$(basename "$d")"
    n="$(sel_matrix_rows | awk -F'\t' -v p="$d" '
      $1 ~ /^skills\/shared\// && index("|" $1 "|", "|" p "|") { c++ } END { print c + 0 }')"
    [ "$n" -eq 1 ] || fail "$d appears in $n precise rows, want exactly 1 (NONE is a valid answer, silence is not)"
  done
}

# --- derived parity: re-derived from source, so it cannot rot ---------------

@test "M6: every agent hardcoded in a hook is selected by that agent's doc" {
  local f base hb a sel
  for f in "$PLUGIN_ROOT"/hooks/*.sh; do
    base="$(basename "$f")"
    hb="$(sel_resolve_bats "$base" "$PLUGIN_ROOT/tests/shell")"
    [ -n "$hb" ] || continue
    hb="${hb#$PLUGIN_ROOT/}"
    for a in $(grep -o 'corpflow:[a-z-]*' "$f" | sed 's/.*://' | LC_ALL=C sort -u); do
      [ -f "$PLUGIN_ROOT/agents/$a.md" ] || continue
      sel="$(_selected_files "agents/$a.md")"
      case "$sel" in
        *"$hb"*) ;;
        *) fail "$base hardcodes corpflow:$a but agents/$a.md does not select $hb" ;;
      esac
    done
  done
}

@test "M7: a multi-consumer script selects all its consumers, with L1 provenance" {
  local s want got miss w recs n
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    want="$(sel_l1_consumers "$s")"
    n="$(printf '%s\n' "$want" | grep -c . || true)"
    [ "${n:-0}" -ge 2 ] || continue
    recs="$(sel_select_for_path "$s" M)"
    got="$(printf '%s\n' "$recs" | awk -F'\t' '$1 == "BATS" { print $2 }' | LC_ALL=C sort -u)"
    miss="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got"))"
    [ -z "$miss" ] || fail "$s ($n consumers) missed: $miss"
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      printf '%s\n' "$recs" | grep -q "^BATS	$w	L1	PATHREF$" \
        || fail "$s -> $w has no L1 PATHREF edge; L1 has degraded to convention-only"
    done <<< "$want"
  done <<< "$(sel_all_scripts "$PLUGIN_ROOT")"
}

@test "M8: a non-script path a test names literally creates an edge" {
  # The dropped module-correlation rule is only safe if literal path references
  # still resolve; artifact-map-parity.bats is the test that catches the stranded
  # -analyzing bug and names both of these.
  local p sel
  for p in skills/worktask/SKILL.md agents/workflow-engineer.md; do
    sel="$(_selected_files "$p")"
    case "$sel" in
      *"tests/shell/worktask/artifact-map-parity.bats"*) ;;
      *) fail "$p does not select artifact-map-parity.bats via L1" ;;
    esac
  done
}

# --- falsification: plant a violation, require the engine to name it --------

@test "M9: an unmatched path fails closed to FULL/F3, never to nothing" {
  local wd; wd="$(mk_tmpworkdir)"
  mkdir -p "$wd/tests/shell/meta" "$wd/tests/selection" "$wd/agents"
  printf '@test "a" {\n :\n}\n' > "$wd/tests/shell/meta/a.bats"
  printf 'x\n' > "$wd/agents/designer.md"
  printf 'agents/*.md\tmeta/a\tR01\tsynthetic row with a long enough rationale\n' \
    > "$wd/tests/selection/matrix.tsv"

  sel_context_init "$wd"
  run sel_select_for_path "docs/brand-new.md" M
  assert_success
  assert_output --partial "FULL	F3"
  assert_output --partial "docs/brand-new.md"
}

@test "M10: every row is load-bearing — deleting it deselects its target" {
  local wd; wd="$(mk_tmpworkdir)"
  mkdir -p "$wd/tests/shell/meta" "$wd/tests/selection" "$wd/commands"
  printf '@test "a" {\n :\n}\n' > "$wd/tests/shell/meta/a.bats"
  printf 'x\n' > "$wd/commands/demo.md"
  printf 'commands/*.md\tmeta/a\tR02\tsynthetic row with a long enough rationale\n' \
    > "$wd/tests/selection/matrix.tsv"

  sel_context_init "$wd"
  run sel_select_for_path "commands/demo.md" M
  assert_success
  assert_output --partial "tests/shell/meta/a.bats"

  : > "$wd/tests/selection/matrix.tsv"
  run sel_select_for_path "commands/demo.md" M
  assert_success
  refute_output --partial "tests/shell/meta/a.bats"
  assert_output --partial "FULL	F3"
}

@test "M11: F4 fires under the fail-closed roots and nowhere else" {
  local wd; wd="$(mk_tmpworkdir)"
  mkdir -p "$wd/tests/shell/meta" "$wd/tests/selection" "$wd/agents" "$wd/hooks"
  printf '@test "a" {\n :\n}\n' > "$wd/tests/shell/meta/a.bats"
  printf 'x\n' > "$wd/agents/designer.md"
  printf 'agents/*.md\tmeta/a\tR01\tsynthetic row with a long enough rationale\n' \
    > "$wd/tests/selection/matrix.tsv"

  sel_context_init "$wd"

  run sel_select_for_path "tests/shell/hooks/gone.bats" D
  assert_success
  assert_output --partial "FULL	F4"

  run sel_select_for_path "hooks/gone.sh" D
  assert_success
  assert_output --partial "FULL	F4"

  # A doc delete surfaces as an A+D pair under --no-renames and both halves match
  # the same glob, so widening here would be pure cost.
  run sel_select_for_path "agents/designer.md" D
  assert_success
  refute_output --partial "FULL"
  assert_output --partial "tests/shell/meta/a.bats"
}

_mk_synthetic_repo() {
  local wd="$1" i
  mkdir -p "$wd/tests/shell/meta" "$wd/tests/selection" "$wd/agents"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    printf '@test "a" {\n :\n}\n' > "$wd/tests/shell/meta/t$i.bats"
  done
  printf 'x\n' > "$wd/agents/designer.md"
  printf 'agents/*.md\t%s\tR01\twide synthetic row with a long enough rationale\n' \
    "meta/t1,meta/t2,meta/t3,meta/t4,meta/t5,meta/t6,meta/t7" \
    > "$wd/tests/selection/matrix.tsv"
  ( cd "$wd" && git init -q . && git add -A \
      && git -c user.email=t@t -c user.name=t commit -qm base \
      && printf 'y\n' >> agents/designer.md ) >/dev/null 2>&1
}

_mk_wide_stub() {
  local p="$1"
  cat > "$p" <<'STUB'
#!/usr/bin/env bash
printf 'VERDICT\tWIDE\tCAP\tselection is 30/54 files (55%%), over the 50%% cap\n'
printf 'SELECT\ttests/shell/meta/coverage-proxy.bats\tL3:ALWAYS\n'
printf 'COUNT\t30\t54\n'
exit 0
STUB
  chmod +x "$p"
}

@test "M12: the widening cap fires for DV and stays informational for everyone else" {
  local wd; wd="$(mk_tmpworkdir)"
  _mk_synthetic_repo "$wd"

  run bash "$SELECTOR" --changed --base HEAD --root "$wd"
  assert_success
  assert_output --partial "VERDICT	WIDE	CAP"

  local stub; stub="$(mk_tmpworkdir)/wide-stub.sh"
  _mk_wide_stub "$stub"

  # Both halves drive a sandbox copy, never $PLUGIN_ROOT/run-tests.sh: a fall-through
  # in the real tree re-enters the whole suite from inside a test, unbounded and
  # silent because bats captures the child's output. CORPFLOW_TEST_SELECT is pinned
  # to 1 because both verdicts below only exist while selection is enabled, and CI
  # exports 0 for the whole suite step.
  local sandbox; sandbox="$(mk_tmpworkdir)"
  _mk_runner_sandbox "$sandbox"

  # DV in progress: refuse and hand off, without running anything.
  local ctx; ctx="$(mk_tmpworkdir)"
  mkdir -p "$ctx/.context"
  printf '{"tasks":{"DV0":{"status":"in_progress"}}}\n' > "$ctx/.context/state.json"
  CORPFLOW_TEST_SELECT=1 CLAUDE_PROJECT_DIR="$ctx" RUN_TESTS_SELECTOR="$stub" \
    run bash "$sandbox/run-tests.sh" --changed
  [ "$status" -eq 65 ] || fail "expected exit 65 under DV, got $status: $output"
  assert_output --partial "hand off to QA"
  refute_output --partial "bats file(s)"
  if grep -q '\.bats' "$sandbox/bats-args"; then
    fail "the DV refusal still started the suite: $(cat "$sandbox/bats-args")"
  fi

  # No worktask state: the same widening is informational.
  local nostate; nostate="$(mk_tmpworkdir)"
  CORPFLOW_TEST_SELECT=1 CLAUDE_PROJECT_DIR="$nostate" RUN_TESTS_SELECTOR="$stub" \
    run bash "$sandbox/run-tests.sh" --changed --print-selection
  assert_success
  assert_output --partial "VERDICT	WIDE"
}

@test "M13: the selection is a subset of the discovered suite, with fixed phase tokens" {
  local wd; wd="$(mk_tmpworkdir)"
  _mk_synthetic_repo "$wd"
  local out sel extra tok

  run bash "$SELECTOR" --changed --base HEAD --root "$wd"
  assert_success

  out="$output"
  sel_context_init "$wd"
  sel="$(printf '%s\n' "$out" | grep '^SELECT	' | cut -f2 | LC_ALL=C sort -u)"
  if [ -n "$sel" ]; then
    extra="$(comm -13 <(sel_all_bats) <(printf '%s\n' "$sel"))"
    [ -z "$extra" ] || fail "selector named files run-tests.sh would never run: $extra"
  fi

  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$tok" in
      bats|swift|python-skills|python-harness) ;;
      *) fail "phase token '$tok' is outside the fixed set" ;;
    esac
  done <<< "$(printf '%s\n' "$out" | grep '^PHASE	' | cut -f2)"
}

_ALWAYS_FLOOR="tests/shell/lib/test-helper.bats tests/shell/meta/coverage-proxy.bats tests/shell/skills/plugin-root-refs.bats tests/shell/worktask/manifest-parity.bats"

@test "M15: the ALWAYS floor reaches the emitted selection, not just sel_always_set" {
  # M1 asserts sel_always_set is non-empty, which stayed true while the floor had
  # no call site on the run path at all. This drives the real selector end to end
  # and fails if the four files are absent from the SELECT stream a run consumes.
  local wd b; wd="$(mk_tmpworkdir)"
  for b in $_ALWAYS_FLOOR; do
    mkdir -p "$wd/${b%/*}"
    printf '@test "a" {\n :\n}\n' > "$wd/$b"
  done
  # Committed and untouched: an untracked floor file would enter the changed set
  # and select itself through the SELF edge, passing this guard without the floor.
  _mk_synthetic_repo "$wd"

  run bash "$SELECTOR" --changed --base HEAD --root "$wd"
  assert_success
  for b in $_ALWAYS_FLOOR; do
    printf '%s\n' "$output" | grep -q "^SELECT	$b	" \
      || fail "the ALWAYS floor is missing from the emitted selection: $b"
  done
  assert_output --partial "L3:ALWAYS"

  # And the floor is visible in what --print-selection shows a human.
  # Outside $wd: a stub written inside the synthetic repo is an untracked file in
  # its own changed set, and lands as FULL/F3 before any selection is emitted.
  local stub; stub="$(mk_tmpworkdir)/floor-selector.sh"
  printf '#!/usr/bin/env bash\nexec bash %s --changed --base HEAD --root %s\n' \
    "$SELECTOR" "$wd" > "$stub"
  chmod +x "$stub"
  # Pinned: CI exports CORPFLOW_TEST_SELECT=0 for the whole suite step, under which
  # --print-selection reports FULL/DISABLED and never reaches a floor to show.
  CORPFLOW_TEST_SELECT=1 RUN_TESTS_SELECTOR="$stub" \
    run "$PLUGIN_ROOT/run-tests.sh" --changed --print-selection
  assert_success
  assert_output --partial "SELECT	tests/shell/meta/coverage-proxy.bats	L3:ALWAYS"
}

# A runner sandbox: the real run-tests.sh over a stub bats and a one-file suite,
# so the disable path can be observed end to end without running the whole tree from
# inside a test. The stub records its argv; a line naming a .bats means the suite
# phase actually started.
_mk_runner_sandbox() {
  local wd="$1"
  mkdir -p "$wd/tests/vendor/bats-core/bin" "$wd/tests/shell/meta"
  cp "$PLUGIN_ROOT/run-tests.sh" "$wd/run-tests.sh"
  printf '@test "a" {\n :\n}\n' > "$wd/tests/shell/meta/a.bats"
  cat > "$wd/tests/vendor/bats-core/bin/bats" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$wd/bats-args"
exit 0
STUB
  cat > "$wd/selector-stub.sh" <<STUB
#!/usr/bin/env bash
: > "$wd/selector-invoked"
printf 'VERDICT\tSCOPED\t-\t-\n'
printf 'SELECT\ttests/shell/meta/a.bats\tL3:ALWAYS\n'
exit 0
STUB
  chmod +x "$wd/tests/vendor/bats-core/bin/bats" "$wd/selector-stub.sh"
  : > "$wd/bats-args"
}

@test "M16: CORPFLOW_TEST_SELECT=0 skips selection and runs the full suite" {
  local wd; wd="$(mk_tmpworkdir)"
  _mk_runner_sandbox "$wd"

  CORPFLOW_TEST_SELECT=0 RUN_TESTS_SELECTOR="$wd/selector-stub.sh" \
    run bash "$wd/run-tests.sh" --changed
  assert_output --partial "selection disabled, running the full suite"
  [ ! -f "$wd/selector-invoked" ] || fail "the selector ran although selection is disabled"
  grep -q '\.bats' "$wd/bats-args" || fail "the disable path did not reach the suite phase"
  refute_output --partial "DESELECTED:"
}

@test "M17: --print-selection under CORPFLOW_TEST_SELECT=0 prints and runs nothing" {
  # The execution gate classifies --print-selection as build_only, which is
  # allowed at stages where a full run is denied. That grant is only sound while
  # this invocation runs nothing unconditionally — a fall-through here converts a
  # permitted build_only call into a full suite run under DV.
  local wd; wd="$(mk_tmpworkdir)"
  _mk_runner_sandbox "$wd"

  CORPFLOW_TEST_SELECT=0 RUN_TESTS_SELECTOR="$wd/selector-stub.sh" \
    run bash "$wd/run-tests.sh" --changed --print-selection
  assert_success
  assert_output --partial "VERDICT	FULL	DISABLED	CORPFLOW_TEST_SELECT=0"
  [ ! -f "$wd/selector-invoked" ] || fail "the selector ran although selection is disabled"
  if grep -q '\.bats' "$wd/bats-args"; then
    fail "--print-selection started the suite: $(cat "$wd/bats-args")"
  fi
  refute_output --partial "bats file(s)"
}

@test "M20: re-entering a tree already under test fails loudly instead of recursing" {
  # The hang this pins: CI exports CORPFLOW_TEST_SELECT=0 for the whole suite step,
  # which disables selection in any inner run-tests.sh and so skips the refusal
  # branches a caller was relying on to run nothing. Without the guard the inner
  # call runs the full suite, reaches this file again, and recurses until the job
  # times out — with no output at all, because bats captures the child's stream.
  local wd; wd="$(mk_tmpworkdir)"
  _mk_runner_sandbox "$wd"

  CORPFLOW_TEST_SELECT=0 RUN_TESTS_ACTIVE_ROOT="$wd" RUN_TESTS_SELECTOR="$wd/selector-stub.sh" \
    run bash "$wd/run-tests.sh" --changed
  assert_failure
  assert_output --partial "re-entered for a tree already under test"
  if grep -q '\.bats' "$wd/bats-args"; then
    fail "the guard let the suite phase start: $(cat "$wd/bats-args")"
  fi
}

@test "M21: the guard keys on the tree, so it spares --print-selection and other roots" {
  local wd; wd="$(mk_tmpworkdir)"
  _mk_runner_sandbox "$wd"

  # A mode that runs nothing stays callable from inside a run — that is what makes
  # a sandboxed inner invocation a workable substitute for the real tree.
  RUN_TESTS_ACTIVE_ROOT="$wd" RUN_TESTS_SELECTOR="$wd/selector-stub.sh" \
    run bash "$wd/run-tests.sh" --changed --print-selection
  assert_success
  refute_output --partial "re-entered"

  # A different root is a different tree: an outer real run must not block a sandbox.
  # Exit status is unasserted on purpose — the sandbox has no python/swift phases,
  # so a non-zero rc there says nothing about the guard. Reaching the suite phase does.
  RUN_TESTS_ACTIVE_ROOT="$PLUGIN_ROOT" RUN_TESTS_SELECTOR="$wd/selector-stub.sh" \
    run bash "$wd/run-tests.sh" --changed
  refute_output --partial "re-entered"
  grep -q '\.bats' "$wd/bats-args" || fail "a differently-rooted run was blocked from its suite phase"
}

@test "M14: the selector does not name the plugin-root environment variable" {
  # plugin-root-refs.bats asserts by exact assert_output which four .sh files may
  # contain it; a single comment here trips it with a diff two files away.
  run grep -c "CLAUDE_PLUGIN""_ROOT" "$SELECTOR"
  [ "$output" = "0" ] || fail "select-tests.sh names the plugin-root env var $output time(s)"
}

@test "M18: every hooks/lib self-test body resolves to its owning hook's .bats" {
  # The bodies moved out of the hooks in #303. An unmapped path fails the whole
  # selection closed to FULL, which silently costs a full suite on every hook
  # change — so the mapping is pinned here rather than left to convention.
  local f base resolved
  for f in "$PLUGIN_ROOT"/hooks/lib/*-selftest.sh; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    resolved="$(sel_resolve_bats "$base" "$PLUGIN_ROOT/tests/shell")"
    [ -n "$resolved" ] || fail "$base resolves to no .bats — selection will fail closed to FULL"
    [ -f "$resolved" ] || fail "$base resolves to a missing file: $resolved"
  done
}

@test "M19: the self-test alias chains through an aliased owner" {
  # dv-comment-density-gate.sh is itself aliased to comment-density-gate.bats,
  # so stripping the -selftest suffix alone would leave this one unmapped.
  run sel_alias_for dv-comment-density-gate-selftest.sh
  assert_output "comment-density-gate.bats"
  # A non-selftest script keeps its previous answer.
  run sel_alias_for state-merge.sh
  assert_output ""
}
