#!/usr/bin/env bats
# Behavioural tests for hooks/dv-comment-density-gate.sh.
#
# Contract (verified against .claude-plugin/plugin.json): this is a SubagentStop
# hook. It NEVER signals through the exit code — it always exits 0 and travels a
# block in the stdout JSON as {"decision":"block", …,
# "hookSpecificOutput":{"hookEventName":"SubagentStop", …}}. Asserting
# `permissionDecision` here would pin a shape the hook never emits.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

HOOK="hooks/dv-comment-density-gate.sh"
WRITER='{"agent_type":"apple-developer:ios-developer","agent_id":"agt_t","session_id":"s"}'
REVIEWER='{"agent_type":"corpflow:technical-lead","agent_id":"agt_t","session_id":"s"}'

setup() {
  REPO="$(mk_git_fixture --branch main --file 'README.md:seed\n' --commit 'init')"
  mkdir -p "$REPO/.context/logs"
  # The root ladder answers only a context holding a ledger.
  printf '%s' '{"version":2,"tasks":{}}' > "$REPO/.context/state.json"
  AUDIT_LOG="$REPO/.context/logs/audit.jsonl"
}

teardown() {
  _test_helper_cleanup
}

# 30 comment lines over 18 code lines = 62%, well past the 40 ceiling and past
# the 40-line floor.
mk_bloated_swift() {
  {
    printf '/// Essay line %s narrating history the standard bans.\n' 1 2 3 4 5 6 7 8 9 10
    printf '/// Contract prose %s restating the signature.\n' 1 2 3 4 5 6 7 8 9 10
    printf '/// Provenance %s: AC-1, REQ-2, issue tag.\n' 1 2 3 4 5 6 7 8 9 10
    echo 'struct Bloated {'
    printf '    let field%s: Int\n' 1 2 3 4 5 6 7 8
    printf '    func calc%s() -> Int { field1 * %s }\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8
    echo '}'
  } > "$REPO/$1"
}

# 6 comment lines over 35 code lines = 14% (hand-computed: 6*100/41).
mk_lean_swift() {
  {
    printf '/// Terse WHY on a non-obvious literal %s.\n' 1 2 3 4 5 6
    echo 'struct Lean {'
    printf '    let field%s: Int\n' 1 2 3 4 5 6 7 8 9 10
    printf '    func calc%s() -> Int { field1 * %s }\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10
    printf '    var derived%s: Int { field1 + %s }\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10
    printf '    func extra%s() { }\n' 1 2 3
    echo '}'
  } > "$REPO/$1"
}

# ---------------------------------------------------------------------------
# T1 — the block decision travels in stdout JSON, and the exit code stays 0.
# ---------------------------------------------------------------------------
@test "T1: a bloated .swift blocks via decision JSON while still exiting 0" {
  mk_bloated_swift Bloated.swift

  run_script_env --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --stdin-string "$WRITER" "$HOOK"

  assert_success                                        # ALWAYS 0 — never the channel
  assert_equal "$(jq -r '.decision' <<< "$output")" 'block'
  assert_equal "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$output")" 'SubagentStop'
  assert_equal "$(jq 'has("permissionDecision")' <<< "$output")" 'false'
  # The offending filename must reach the agent, or the block is unactionable.
  assert_equal "$(jq -r '.reason | test("Bloated\\.swift")' <<< "$output")" 'true'
  assert_equal "$(jq -r '.reason | test("62% of 48 added")' <<< "$output")" 'true'
  assert_equal "$(jq -r '.hookSpecificOutput.additionalContext | length > 0' <<< "$output")" 'true'
}

# ---------------------------------------------------------------------------
# T2 — the audit row carries the measured worst_pct, not a placeholder.
# ---------------------------------------------------------------------------
@test "T2: blocking writes a comment_density_block row with the measured worst_pct" {
  mk_bloated_swift Bloated.swift

  run_script_env --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --stdin-string "$WRITER" "$HOOK"
  assert_success

  assert_audit_row comment_density_block --file "$AUDIT_LOG" \
    --actor 'hook:dv-comment-density-gate' \
    --subject 'apple-developer:ios-developer' \
    --result blocked \
    --meta worst_pct=62 --meta files_checked=1 --meta threshold=40 --count 1
  # stub_log/assert_audit_row must not have disturbed the decision above.
  assert_equal "$(jq -r '.decision' <<< "$output")" 'block'
}

# ---------------------------------------------------------------------------
# T3 — a lean file passes silently but is still measured.
# ---------------------------------------------------------------------------
@test "T3: a lean .swift emits no decision and a comment_density_pass row" {
  mk_lean_swift Lean.swift

  run_script_env --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --stdin-string "$WRITER" "$HOOK"

  assert_success
  assert_output ''
  # Silence alone cannot separate "measured and passed" from "never looked at",
  # so pin files_checked as well as the result.
  assert_audit_row comment_density_pass --file "$AUDIT_LOG" \
    --result ok --meta worst_pct=14 --meta files_checked=1 --count 1
  assert_audit_row comment_density_block --file "$AUDIT_LOG" --absent
}

# ---------------------------------------------------------------------------
# T4 — reviewers are never blocked for the writer's bloat.
# ---------------------------------------------------------------------------
@test "T4: a reviewer agent is a no-op even with a bloated file present" {
  mk_bloated_swift Bloated.swift

  run_script_env --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --stdin-string "$REVIEWER" "$HOOK"

  assert_success
  assert_output ''
  # The agent filter returns before the log dir is even created, so no row of
  # either kind may exist.
  assert_audit_row comment_density_block --file "$AUDIT_LOG" --absent
  assert_audit_row comment_density_pass --file "$AUDIT_LOG" --absent
}

# ---------------------------------------------------------------------------
# T5 — the MIN_LINES floor: a tiny file at extreme density is not the failure
# mode the gate exists for.
# ---------------------------------------------------------------------------
@test "T5: a file under MIN_ADDED_LINES is skipped no matter how dense" {
  {
    printf '/// doc %s\n' 1 2 3
    echo 'struct Tiny { let v: Int }'
  } > "$REPO/Tiny.swift"

  run_script_env --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --stdin-string "$WRITER" "$HOOK"
  assert_success
  assert_output ''
  assert_audit_row comment_density_pass --file "$AUDIT_LOG" --absent

  # Control arm: the same 75% density above the floor DOES block, so the pass is
  # attributable to the floor and not to the extension filter.
  {
    printf '/// doc %s\n' $(seq 1 36)
    printf 'struct Big%s { let v: Int }\n' $(seq 1 12)
  } > "$REPO/Big.swift"
  run_script_env --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --stdin-string "$WRITER" "$HOOK"
  assert_equal "$(jq -r '.decision' <<< "$output")" 'block'
}

# ---------------------------------------------------------------------------
# T6 — the ceiling is configurable, and the row reports the ceiling in force.
# ---------------------------------------------------------------------------
@test "T6: CORPFLOW_COMMENT_DENSITY_MAX raises and lowers the ceiling" {
  mk_bloated_swift Bloated.swift            # 62%

  # Raised above the measurement: the same file now passes.
  run_script_env --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --env CORPFLOW_COMMENT_DENSITY_MAX=70 \
    --stdin-string "$WRITER" "$HOOK"
  assert_success
  assert_output ''
  assert_audit_row comment_density_pass --file "$AUDIT_LOG" \
    --meta worst_pct=62 --meta threshold=70 --count 1

  rm -f "$AUDIT_LOG"

  # Lowered under a lean file: 12% now blocks.
  rm -f "$REPO/Bloated.swift"
  mk_lean_swift Lean.swift
  run_script_env --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --env CORPFLOW_COMMENT_DENSITY_MAX=5 \
    --stdin-string "$WRITER" "$HOOK"
  assert_success
  assert_equal "$(jq -r '.decision' <<< "$output")" 'block'
  assert_audit_row comment_density_block --file "$AUDIT_LOG" \
    --meta threshold=5 --count 1
}

# ---------------------------------------------------------------------------
# T7 — safe degrade. jq absent must not turn a missing tool into a blocked agent.
# ---------------------------------------------------------------------------
@test "T7: jq absent fails open — stderr notice, exit 0, no decision, no row" {
  mk_bloated_swift Bloated.swift

  run_script_env --hide jq --separate-stderr \
    --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --stdin-string "$WRITER" "$HOOK"

  assert_success
  assert_output ''
  assert_equal "$stderr" 'dv-comment-density-gate: jq not found, skipping'
  [ ! -f "$AUDIT_LOG" ]
}

@test "T8: git absent fails open the same way" {
  mk_bloated_swift Bloated.swift

  run_script_env --hide git --separate-stderr \
    --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --stdin-string "$WRITER" "$HOOK"

  assert_success
  assert_output ''
  assert_equal "$stderr" 'dv-comment-density-gate: git not found, skipping'
}

# ---------------------------------------------------------------------------
# T9 — the tracked-file arm: density is measured over ADDED lines, so inherited
# bloat in a committed file must not block the agent that touched it.
# ---------------------------------------------------------------------------
@test "T9: a committed bloated file with a lean edit is judged on the added lines" {
  mk_bloated_swift Bloated.swift
  git -C "$REPO" -c user.name=t -c user.email=t@t add Bloated.swift
  GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
    git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
    commit -q -m 'inherit the bloat'

  # 44 added code lines, one comment: 2%.
  {
    echo '/// One terse WHY.'
    printf 'struct Added%s { let v: Int }\n' $(seq 1 44)
  } >> "$REPO/Bloated.swift"

  run_script_env --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --stdin-string "$WRITER" "$HOOK"

  assert_success
  assert_output ''
  assert_audit_row comment_density_pass --file "$AUDIT_LOG" --meta worst_pct=2 --count 1
}

# ---------------------------------------------------------------------------
# T10 — --self-test drives the shipped code paths, not a re-typed copy.
# ---------------------------------------------------------------------------
@test "T10: --self-test passes and is the only mode that ignores stdin" {
  run_script_env "$HOOK" --self-test
  assert_success
  assert_output --partial 'self-test OK'
  assert_output --regexp 'dv-comment-density-gate: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
}

# ---------------------------------------------------------------------------
# T11 — a pure `git mv` authors no line, so it cannot breach the ceiling.
#
# Regression: rename detection needs BOTH paths in the pathspec. A pathspec
# naming only the destination drops the deletion side before -M runs, so the
# move read as a whole-file addition and the file's inherited comments all
# counted as newly written. Observed on a real worktask, where relocating one
# 46-line 67%-comment file blocked every writer agent for the rest of the run.
# ---------------------------------------------------------------------------
@test "T11: relocating a comment-dense file is not judged as authored lines" {
  mk_bloated_swift Bloated.swift
  git -C "$REPO" -c user.name=t -c user.email=t@t add Bloated.swift
  GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
    git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
    commit -q -m 'inherit the bloat'

  mkdir -p "$REPO/Moved"
  git -C "$REPO" mv Bloated.swift Moved/Bloated.swift

  run_script_env --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --stdin-string "$WRITER" "$HOOK"

  assert_success
  assert_output ''
}

# ---------------------------------------------------------------------------
# T12 — the pairing must not blind the gate. A move that also ADDS prose is
# still judged, on the added lines alone.
#
# The pre-move body is deliberately large: it keeps similarity above git's
# rename threshold so this exercises the paired-pathspec arm. Sized smaller,
# git stops calling it a rename and the assertion passes for the wrong reason.
# ---------------------------------------------------------------------------
@test "T12: a relocated file that gains comment lines is still judged on them" {
  printf 'struct Base%s { let v: Int }\n' $(seq 1 200) > "$REPO/Big.swift"
  git -C "$REPO" -c user.name=t -c user.email=t@t add Big.swift
  GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
    git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
    commit -q -m 'inherit the big file'

  mkdir -p "$REPO/Moved"
  git -C "$REPO" mv Big.swift Moved/Big.swift
  # 45 added lines, 44 of them comment: 97%, past both the floor and the ceiling.
  {
    printf '/// Essay line %s narrating history the standard bans.\n' $(seq 1 44)
    echo 'struct Tail { let v: Int }'
  } >> "$REPO/Moved/Big.swift"

  # Guard the guard: if git stops seeing a rename here the test is vacuous.
  assert_equal "$(git -C "$REPO" diff HEAD -M --name-status --diff-filter=R | wc -l | tr -d ' ')" '1'

  run_script_env --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --stdin-string "$WRITER" "$HOOK"

  assert_success
  assert_equal "$(jq -r '.decision' <<< "$output")" 'block'
  assert_equal "$(jq -r '.reason | test("Moved/Big\\.swift")' <<< "$output")" 'true'
  # 44 of 45 added — the inherited 200 lines are correctly not counted.
  assert_equal "$(jq -r '.reason | test("97% of 45 added")' <<< "$output")" 'true'
}

@test "SR: a symlinked audit.jsonl is refused on both the block and the pass row" {
  mk_bloated_swift Bloated.swift
  mkdir -p "$REPO/target-dir"
  ln -s "$REPO/target-dir/escaped.txt" "$AUDIT_LOG"

  run_script_env --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --stdin-string "$WRITER" "$HOOK"
  assert_success
  # Refusing the row must not weaken the block the gate exists to travel.
  assert_equal "$(jq -r '.decision' <<< "$output")" 'block'
  [ ! -e "$REPO/target-dir/escaped.txt" ]

  rm -f "$REPO/Bloated.swift"
  mk_lean_swift Lean.swift
  run_script_env --env "CLAUDE_PROJECT_DIR=$REPO" --cwd "$REPO" \
    --stdin-string "$WRITER" "$HOOK"
  assert_success
  [ ! -e "$REPO/target-dir/escaped.txt" ]
}

@test "unresolved root exits 0, no block, no .context under cwd" {
  local cwd
  cwd="$(mk_tmpworkdir)"
  run_script_env --cwd "$cwd" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR --unset CONTEXT_DIR \
    --env "GIT_CEILING_DIRECTORIES=$cwd" --stdin-string "$WRITER" "$PLUGIN_ROOT/$HOOK"
  assert_success
  [ -z "$output" ]
  [ ! -e "$cwd/.context" ]
}
