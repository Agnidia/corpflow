#!/usr/bin/env bash
# dv-comment-density-gate self-test body — sourced by hooks/dv-comment-density-gate.sh under --self-test only,
# never on the hook dispatch path. Sourced, not executed, so it sees every
# helper the caller already defined; it owns the exit for this invocation.
# Indentation is the caller's — kept byte-identical so this stays a pure move.

  _tmp=$(mktemp -d)
  trap 'rm -rf "$_tmp"' EXIT
  git -C "$_tmp" init -q 2>/dev/null || { echo "dv-comment-density-gate: self-test SKIP (git init failed)"; exit 0; }
  # Real repos always have a HEAD; give the fixture one so the `git diff HEAD`
  # arm is exercised rather than silently falling through to ls-files.
  git -C "$_tmp" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null || true
  mkdir -p "$_tmp/.context/logs"

  # Both fixtures are new (untracked) files, so their whole body counts as
  # added, and both clear MIN_ADDED_LINES.
  # Bloated: 30 comment lines vs 18 code = 62%.
  {
    printf '/// Essay line %s narrating history the standard bans.\n' 1 2 3 4 5 6 7 8 9 10
    printf '/// Contract prose %s restating the signature.\n' 1 2 3 4 5 6 7 8 9 10
    printf '/// Provenance %s: AC-1, REQ-2, issue tag.\n' 1 2 3 4 5 6 7 8 9 10
    echo 'struct Bloated {'
    printf '    let field%s: Int\n' 1 2 3 4 5 6 7 8
    printf '    func calc%s() -> Int { field1 * %s }\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8
    echo '}'
  } >"$_tmp/Bloated.swift"

  # Lean: 6 comment lines vs 44 code = 12%.
  {
    printf '/// Terse WHY on a non-obvious literal %s.\n' 1 2 3 4 5 6
    echo 'struct Lean {'
    printf '    let field%s: Int\n' 1 2 3 4 5 6 7 8 9 10
    printf '    func calc%s() -> Int { field1 * %s }\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10
    printf '    var derived%s: Int { field1 + %s }\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10
    printf '    func extra%s() { }\n' 1 2 3
    echo '}'
  } >"$_tmp/Lean.swift"

  _fail=0
  _st_cases=0

  # 1. Bloated present -> must block, with remediation text.
  _out=$(run_gate "$(read_stdin)" "$_tmp/.context" "$_tmp")
  printf '%s' "$_out" | jq -e '
    .decision == "block"
    and (.hookSpecificOutput.additionalContext | length > 0)
  ' >/dev/null 2>&1 || { echo "dv-comment-density-gate: self-test FAIL (bloated file did not block)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # 2. Lean only -> must pass silently.
  rm -f "$_tmp/Bloated.swift"
  _out=$(run_gate "$(read_stdin)" "$_tmp/.context" "$_tmp")
  [ -z "$_out" ] || { echo "dv-comment-density-gate: self-test FAIL (lean file blocked)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # 3. Reviewer agent with the bloated file back -> must stay silent (a reviewer
  #    is never blocked for the writer's bloat).
  printf '/// essay %s\n' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 >"$_tmp/Bloated.swift"
  printf 'struct B%s { let v: Int }\n' 1 2 3 4 5 >>"$_tmp/Bloated.swift"
  _out=$(run_gate '{"agent_type":"corpflow:technical-lead"}' "$_tmp/.context" "$_tmp")
  [ -z "$_out" ] || { echo "dv-comment-density-gate: self-test FAIL (reviewer agent was blocked)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # 4. Small edit under the floor -> must stay silent even at high density.
  printf '/// doc %s\n' 1 2 3 >"$_tmp/Tiny.swift"
  echo 'struct Tiny { let v: Int }' >>"$_tmp/Tiny.swift"
  _out=$(run_gate "$(read_stdin)" "$_tmp/.context" "$_tmp")
  [ -z "$_out" ] || { echo "dv-comment-density-gate: self-test FAIL (small edit blocked)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  rm -f "$_tmp/Bloated.swift" "$_tmp/Tiny.swift"

  # 5. Hash-comment language: a bloated .py must block. Under the C-family-only
  #    regex this file scored 0% and passed, which is the defect these two cases
  #    pin down.
  {
    printf '# Essay line %s narrating history the standard bans.\n' 1 2 3 4 5 6 7 8 9 10
    printf '# Contract prose %s restating the signature.\n' 1 2 3 4 5 6 7 8 9 10
    printf '# Provenance %s: AC-1, REQ-2, issue tag.\n' 1 2 3 4 5 6 7 8 9 10
    echo 'class Bloated:'
    printf '    field%s = 0\n' 1 2 3 4 5 6 7 8
    printf '    def calc%s(self): return self.field1 * %s\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8
  } >"$_tmp/bloated.py"
  _out=$(run_gate "$(read_stdin)" "$_tmp/.context" "$_tmp")
  printf '%s' "$_out" | jq -e '
    .decision == "block" and (.reason | test("bloated\\.py"))
  ' >/dev/null 2>&1 || { echo "dv-comment-density-gate: self-test FAIL (bloated .py did not block)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # 6. Lean .py -> must pass. Guards the other direction: Python code lines must
  #    not be miscounted as comments.
  rm -f "$_tmp/bloated.py"
  {
    printf '# Terse WHY on a non-obvious literal %s.\n' 1 2 3 4 5 6
    echo 'class Lean:'
    printf '    field%s = 0\n' 1 2 3 4 5 6 7 8 9 10
    printf '    def calc%s(self): return self.field1 * %s\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10
    printf '    def derived%s(self): return self.field1 + %s\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10
    printf '    def extra%s(self): pass\n' 1 2 3
  } >"$_tmp/lean.py"
  _out=$(run_gate "$(read_stdin)" "$_tmp/.context" "$_tmp")
  [ -z "$_out" ] || { echo "dv-comment-density-gate: self-test FAIL (lean .py blocked)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # 7. Shell: a bloated .sh must block. Shell fell to the C-family regex, so it
  #    scored 0% no matter how much of it was comment.
  {
    echo '#!/usr/bin/env bash'
    printf '# Essay line %s narrating history the standard bans.\n' 1 2 3 4 5 6 7 8 9 10
    printf '# Contract prose %s restating the signature.\n' 1 2 3 4 5 6 7 8 9 10
    printf '# Provenance %s: ticket id, review answer, issue tag.\n' 1 2 3 4 5 6 7 8 9 10
    echo 'set -euo pipefail'
    printf 'field%s=0\n' 1 2 3 4 5 6 7 8
    printf 'calc%s() { echo %s; }\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8
  } >"$_tmp/bloated.sh"
  _out=$(run_gate "$(read_stdin)" "$_tmp/.context" "$_tmp")
  printf '%s' "$_out" | jq -e '
    .decision == "block" and (.reason | test("bloated\\.sh"))
  ' >/dev/null 2>&1 || { echo "dv-comment-density-gate: self-test FAIL (bloated .sh did not block)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # 8. Lean .sh -> must pass. It carries a real shebang and a conventional header
  #    because shell's mandatory preamble is counted as comment: a fixture
  #    without one would overstate how much headroom a real script has.
  rm -f "$_tmp/bloated.sh"
  run_gate "$(read_stdin)" "$_tmp/.context" "$_tmp" >/dev/null
  _checked_before=$(tail -n 1 "$_tmp/.context/logs/audit.jsonl" | jq -r '.metadata.files_checked')
  {
    echo '#!/usr/bin/env bash'
    echo '# prune-artifacts — drop build artifacts past the retention window.'
    echo '#'
    echo '# Requires: find, date. Exits non-zero when the artifact root is absent.'
    echo '# Safe to re-run; deletion is idempotent.'
    echo 'set -euo pipefail'
    printf 'field%s=0\n' 1 2 3 4 5 6 7 8 9 10
    printf 'calc%s() { echo %s; }\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10
    echo '# Two retries: the artifact store 502s on a cold cache.'
    printf 'derived%s() { echo "derived %s"; }\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10
    printf 'extra%s() { :; }\n' 1 2 3 4 5 6 7 8
  } >"$_tmp/lean.sh"
  _out=$(run_gate "$(read_stdin)" "$_tmp/.context" "$_tmp")
  [ -z "$_out" ] || { echo "dv-comment-density-gate: self-test FAIL (lean .sh blocked)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  # Silence alone cannot separate a measured pass from a file the extension
  # filter never looked at, so pin the count the audit row reports.
  _checked_after=$(tail -n 1 "$_tmp/.context/logs/audit.jsonl" | jq -r '.metadata.files_checked')
  [ "$_checked_after" -eq $((_checked_before + 1)) ] ||
    { echo "dv-comment-density-gate: self-test FAIL (lean .sh was never measured)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # 9. Vendored third-party shell must never block: on a dependency refresh the
  #    added lines are code the agent did not write.
  rm -f "$_tmp/lean.sh"
  _vendor_body=$(
    printf '# vendor essay %s\n' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20
    printf 'v%s=0\n' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25
  )
  # Control arm: the identical body outside vendor/ must block, so the pass below
  # is attributable to the path filter and not to the size floor.
  printf '%s\n' "$_vendor_body" >"$_tmp/dep.sh"
  _out=$(run_gate "$(read_stdin)" "$_tmp/.context" "$_tmp")
  printf '%s' "$_out" | jq -e '
    .decision == "block" and (.reason | test("dep\\.sh"))
  ' >/dev/null 2>&1 || { echo "dv-comment-density-gate: self-test FAIL (vendor control fixture did not block)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  rm -f "$_tmp/dep.sh"
  mkdir -p "$_tmp/vendor"
  printf '%s\n' "$_vendor_body" >"$_tmp/vendor/dep.sh"
  _out=$(run_gate "$(read_stdin)" "$_tmp/.context" "$_tmp")
  [ -z "$_out" ] || { echo "dv-comment-density-gate: self-test FAIL (vendored .sh blocked)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # 10. One budget-compliant /// per one-line case: 48% aggregate, every comment
  #     run one line long. The aggregate ratio alone blocked this.
  # Clear every earlier fixture, so files_checked below is attributable.
  rm -rf "$_tmp/vendor" "$_tmp/lean.py" "$_tmp/Lean.swift"
  {
    echo '/// Every state a request can occupy.'
    echo 'enum RequestState {'
    for _i in $(seq 1 20); do
      echo "    /// Case ${_i}: parked awaiting stage ${_i}."
      echo "    case state${_i}"
    done
    echo '}'
  } >"$_tmp/RequestState.swift"
  _out=$(run_gate "$(read_stdin)" "$_tmp/.context" "$_tmp")
  [ -z "$_out" ] ||
    { echo "dv-comment-density-gate: self-test FAIL (per-declaration one-liners blocked)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))
  # Silence must be a measured pass, not a file the filters skipped.
  tail -n 1 "$_tmp/.context/logs/audit.jsonl" | jq -e '
    .action == "comment_density_pass" and .metadata.files_checked == 1
    and .metadata.worst_pct > 40 and .metadata.worst_essay_pct == 0
  ' >/dev/null 2>&1 ||
    { echo "dv-comment-density-gate: self-test FAIL (per-declaration case was never measured)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  # 11. The loophole the block-length signal opens: prose kept inside the 3-line
  #     budget but repeated for every declaration. The secondary aggregate
  #     ceiling is the only thing that still catches it.
  rm -f "$_tmp/RequestState.swift"
  {
    echo 'enum Spread {'
    for _i in $(seq 1 15); do
      echo "    /// Case ${_i} narrates the history the standard bans."
      echo "    /// It restates the signature across a second line."
      echo "    /// AC-${_i}, REQ-${_i}: provenance kept inside the budget."
      echo "    case state${_i}"
    done
    echo '}'
  } >"$_tmp/Spread.swift"
  _out=$(run_gate "$(read_stdin)" "$_tmp/.context" "$_tmp")
  printf '%s' "$_out" | jq -e '
    .decision == "block" and (.reason | test("Spread\\.swift"))
  ' >/dev/null 2>&1 ||
    { echo "dv-comment-density-gate: self-test FAIL (essay-per-declaration did not block)"; _fail=$((_fail + 1)); }
  _st_cases=$((_st_cases + 1))

  [ "$_fail" -eq 0 ] || exit 1
  echo "dv-comment-density-gate: self-test OK ($_st_cases passed, 0 failed)"
  exit 0
