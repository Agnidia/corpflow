#!/usr/bin/env bats
# headless-dispatch.sh — validation, argv build (--print-argv dry mode), spawn and fallback.
# No test here ever spawns a real `claude` — stub_cmd + --stub-path stands in.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/worktask/scripts/headless-dispatch.sh"

setup() {
  # LR is a real git repo (the "ledger root") and WS is a genuine linked worktree of it, so
  # the CWE-73 workspace-membership check (WORKSPACE_REAL must be LEDGER_ROOT_REAL or a path
  # `git worktree list` names for that repo) holds for every live-dispatch test below, not
  # just the two unrelated-repo fixtures that exist to fail it.
  LR="$(mk_git_fixture --file README.md:hi --commit init)"
  mkdir -p "$LR/.context/logs"
  WS="$(mk_tmpworkdir)/stream-wt"
  git -C "$LR" worktree add -q -b wt-test "$WS" > /dev/null 2>&1
}

# Neither bats' `run` nor a bare `$(...)` can hold an embedded NUL byte in a bash variable —
# both silently concatenate every token with no separator at all, verified directly. Only a
# pipe/redirect survives it, so --print-argv's exact NUL-delimited contract has to be checked
# through a temp file, never a variable. print_argv_run sets $PA_OUT_FILE (one token per
# line) and $PA_RC; argv_has greps the file.
print_argv_run() { # <script args...>
  PA_OUT_FILE="$(mk_tmpworkdir)/argv.lines"
  bash "$PLUGIN_ROOT/$SCRIPT" "$@" 2> /dev/null | tr '\0' '\n' > "$PA_OUT_FILE"
  PA_RC="${PIPESTATUS[0]}"
}
argv_has() { grep -qxF -- "$1" "$PA_OUT_FILE"; } # <exact-token>

# --- --print-argv: dry mode, no spawn, AC6 -----------------------------------

@test "print-argv emits the exact flag set, separate args, no --bg or skip flags" {
  print_argv_run --task DV0 --agent corpflow:developer --model opus --effort xhigh \
    --permission-mode manual --workspace "$WS" --print-argv
  [ "$PA_RC" -eq 0 ]
  argv_has "-p"
  argv_has "--agent"
  argv_has "corpflow:developer"
  argv_has "--effort"
  argv_has "xhigh"
  argv_has "--permission-prompts"
  argv_has "none"
  ! argv_has "--bg"
  ! argv_has "--dangerously-skip-permissions"
}

@test "print-argv on PL downgrades bypassPermissions to manual, never wider" {
  print_argv_run --task PL0 --agent corpflow:product-manager --model opus --effort high \
    --permission-mode bypassPermissions --workspace "$WS" --print-argv
  [ "$PA_RC" -eq 0 ]
  ! argv_has "bypassPermissions"
  argv_has "manual"
}

@test "print-argv on SR downgrades bypassPermissions to manual" {
  run_script "$SCRIPT" --task SR0 --agent corpflow:security-reviewer --model opus \
    --effort xhigh --permission-mode bypassPermissions --workspace "$WS" --print-argv
  assert_success
  refute_output --partial "bypassPermissions"
}

@test "print-argv on FN downgrades bypassPermissions to manual" {
  run_script "$SCRIPT" --task FN0 --agent corpflow:project-manager --model sonnet \
    --effort medium --permission-mode bypassPermissions --workspace "$WS" --print-argv
  assert_success
  refute_output --partial "bypassPermissions"
}

@test "print-argv on DV keeps bypassPermissions under a matching parent mode (not a gated stage)" {
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort xhigh \
    --permission-mode bypassPermissions --parent-mode bypassPermissions --workspace "$WS" \
    --print-argv
  assert_success
  assert_output --partial "bypassPermissions"
}

@test "plugin default maps to the CLI's manual, not passed through literally" {
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode default --workspace "$WS" --print-argv
  assert_success
  assert_output --partial "manual"
  refute_output --partial "default"
}

@test "a session id is appended as --session-id when given" {
  print_argv_run --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --workspace "$WS" --session-id abc-123 --print-argv
  [ "$PA_RC" -eq 0 ]
  argv_has "abc-123"
}

@test "--resume is appended alongside the argv, for the resume round-trip" {
  print_argv_run --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --workspace "$WS" --resume xyz-789 --print-argv
  [ "$PA_RC" -eq 0 ]
  argv_has "--resume"
  argv_has "xyz-789"
}

@test "--resume together with --session-id drops --session-id from argv (CLI refuses the pair without --fork-session)" {
  print_argv_run --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --workspace "$WS" --session-id abc-123 --resume abc-123 \
    --print-argv
  [ "$PA_RC" -eq 0 ]
  argv_has "--resume"
  argv_has "abc-123"
  ! argv_has "--session-id"
}

# --- refusal before any spawn, per field ------------------------------------

@test "a space in the agent id is refused" {
  run_script "$SCRIPT" --task DV0 --agent "corpflow:dev eloper" --model opus --effort high \
    --permission-mode manual --workspace "$WS" --print-argv
  assert_failure 2
  assert_output --partial "agent id"
}

@test "a semicolon in the agent id is refused" {
  run_script "$SCRIPT" --task DV0 --agent "corpflow:dev;rm -rf" --model opus --effort high \
    --permission-mode manual --workspace "$WS" --print-argv
  assert_failure 2
}

@test "an unregistered agent id is refused" {
  run_script "$SCRIPT" --task DV0 --agent "corpflow:no-such-agent" --model opus --effort high \
    --permission-mode manual --workspace "$WS" --print-argv
  assert_failure 2
  assert_output --partial "not registered"
}

@test "an effort outside the enum is refused" {
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort bogus \
    --permission-mode manual --workspace "$WS" --print-argv
  assert_failure 2
}

@test "an invalid task id is refused" {
  run_script "$SCRIPT" --task dv0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --workspace "$WS" --print-argv
  assert_failure 2
}

@test "a workspace that is not a git worktree is refused" {
  PLAIN="$(mk_tmpworkdir)"
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --workspace "$PLAIN" --print-argv
  assert_failure 2
  assert_output --partial "not a git worktree"
}

@test "an invalid permission mode is refused" {
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode yolo --workspace "$WS" --print-argv
  assert_failure 2
}

@test "a live dispatch with no --ledger-root is a usage error before any spawn" {
  echo hi > "$WS/prompt.txt"
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --workspace "$WS" --prompt "$WS/prompt.txt"
  assert_failure 2
}

@test "a removed --baseline flag is a usage error before any spawn" {
  echo hi > "$WS/prompt.txt"
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --baseline high --prompt "$WS/prompt.txt"
  assert_failure 2
}

@test "an unregistered corpflow agent id is still refused (registration checks the exact prefix)" {
  echo hi > "$WS/prompt.txt"
  run_script "$SCRIPT" --task DV0 --agent "corpflow:no-such-agent" --model opus \
    --effort high --permission-mode manual --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_failure 2
  assert_output --partial "not registered"
}

# --- spawn / fallback (each fallback reason -> one warn result, agent-param transport, tier unobserved)

@test "cli_missing: claude absent from PATH degrades to warn/agent-param" {
  echo hi > "$WS/prompt.txt"
  run_script_env --path "/usr/bin:/bin" "$SCRIPT" --task DV0 --agent corpflow:developer \
    --model opus --effort xhigh --permission-mode manual --workspace "$WS" \
    --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" --prompt "$WS/prompt.txt"
  assert_success
  assert_output --partial '"result":"warn"'
  assert_output --partial '"fallback_reason":"cli_missing"'
  assert_output --partial '"effort_transport":"agent-param"'
  assert_output --partial '"effort_resolved":null'
  assert_output --partial '"effort_resolved_reason":"inproc_fallback"'
}

@test "cli_below_floor: an old claude --version degrades to warn/agent-param" {
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "1.0.0"; exit 0; fi; exit 0'
  echo hi > "$WS/prompt.txt"
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_success
  assert_output --partial '"fallback_reason":"cli_below_floor"'
}

@test "cli_below_floor: the release just below the floor degrades too" {
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.302"; exit 0; fi; exit 0'
  echo hi > "$WS/prompt.txt"
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_success
  assert_output --partial '"fallback_reason":"cli_below_floor"'
}

@test "CORPFLOW_HEADLESS_ROUTE=off is not a fallback reason: the spawn still runs" {
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "{\"type\":\"result\",\"duration_ms\":1,\"usage\":null,\"total_cost_usd\":null}"
exit 0'
  echo hi > "$WS/prompt.txt"
  run_script_env --stub-path --env "CORPFLOW_HEADLESS_ROUTE=off" "$SCRIPT" --task DV0 \
    --agent corpflow:developer --model opus --effort xhigh --permission-mode manual \
    --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" --prompt "$WS/prompt.txt"
  assert_success
  refute_output --partial 'opted_out'
  assert_output --partial '"result":"ok"'
}

@test "without jq a warn row still emits JSON null, never the string \"null\"" {
  echo hi > "$WS/prompt.txt"
  run_script_env --hide jq --hide claude "$SCRIPT" --task DV0 --agent corpflow:developer \
    --model opus --effort xhigh --permission-mode manual --workspace "$WS" \
    --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" --prompt "$WS/prompt.txt"
  assert_success
  assert_output --partial '"effort_resolved":null'
  assert_output --partial '"effort_resolved_reason":"inproc_fallback"'
  assert_output --partial '"fallback_reason":"cli_missing"'
  refute_output --partial '"null"'
  # Only the jq branch prints session_id, so its absence proves the printf branch ran.
  refute_output --partial '"session_id"'
}

@test "the child's cwd is the worktree and WORKSPACE_ROOT is the ledger root, not the worktree" {
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
pwd > "$STUB_CWD_FILE"
printf "%s" "$WORKSPACE_ROOT" > "$STUB_ROOT_FILE"
echo "{\"type\":\"result\",\"duration_ms\":1,\"usage\":null,\"total_cost_usd\":null}"
exit 0'
  echo hi > "$WS/prompt.txt"
  STUB_CWD_FILE="$(mk_tmpworkdir)/cwd.txt"
  STUB_ROOT_FILE="$(mk_tmpworkdir)/root.txt"
  STUB_CWD_FILE="$STUB_CWD_FILE" STUB_ROOT_FILE="$STUB_ROOT_FILE" \
    run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_success
  [ "$(cat "$STUB_CWD_FILE")" = "$(cd "$WS" && pwd -P)" ]
  [ "$(cat "$STUB_ROOT_FILE")" = "$(cd "$LR" && pwd -P)" ]
}

@test "the tier reaches the child as --effort only, never through an effort env var" {
  # An ambient operator value would leak through to the stub and mask the script's own env.
  unset CLAUDE_CODE_EFFORT_LEVEL
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
printf "%s\n" "$@" > "$STUB_ARGS_FILE"
printf "%s" "${CLAUDE_CODE_EFFORT_LEVEL-unset}" > "$STUB_ENV_FILE"
echo "{\"type\":\"result\",\"duration_ms\":1,\"usage\":null,\"total_cost_usd\":null}"
exit 0'
  echo hi > "$WS/prompt.txt"
  STUB_ARGS_FILE="$(mk_tmpworkdir)/args.txt"
  STUB_ENV_FILE="$(mk_tmpworkdir)/env.txt"
  STUB_ARGS_FILE="$STUB_ARGS_FILE" STUB_ENV_FILE="$STUB_ENV_FILE" \
    run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_success
  grep -A1 -x -- '--effort' "$STUB_ARGS_FILE" | grep -qx xhigh
  [ "$(cat "$STUB_ENV_FILE")" = "unset" ]
}

@test "a successful child reports ok/dispatch-flag with duration/usage but no effort_resolved (no hook rows yet)" {
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "{\"type\":\"result\",\"duration_ms\":4200,\"usage\":{\"input_tokens\":10},\"total_cost_usd\":0.02,\"effort\":{\"level\":\"xhigh\"}}"
exit 0'
  echo hi > "$WS/prompt.txt"
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_success
  assert_output --partial '"result":"ok"'
  assert_output --partial '"effort_transport":"dispatch-flag"'
  assert_output --partial '"effort_resolved":null'
  assert_output --partial '"effort_resolved_reason":"no_hook_rows"'
  assert_output --partial '"duration_ms":4200'
}

@test "exit_before_artifact: a plain non-zero exit with no side effects degrades to warn" {
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
exit 1'
  echo hi > "$WS/prompt.txt"
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_success
  assert_output --partial '"fallback_reason":"exit_before_artifact"'
  assert_output --partial '"effort_resolved":null'
  assert_output --partial '"effort_resolved_reason":"inproc_fallback"'
}

@test "auth_failed is detected from the transcript and reported as the fallback reason" {
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "Authentication failed: please run claude login"
exit 1'
  echo hi > "$WS/prompt.txt"
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_success
  assert_output --partial '"fallback_reason":"auth_failed"'
}

@test "agent_unresolved is detected from the transcript" {
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "Unknown agent: corpflow:developer"
exit 1'
  echo hi > "$WS/prompt.txt"
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_success
  assert_output --partial '"fallback_reason":"agent_unresolved"'
}

@test "a side effect after a failed child refuses to fall back and errors instead" {
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "dirty" >> dirty.txt
exit 1'
  echo hi > "$WS/prompt.txt"
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_failure 3
  assert_output --partial '"fallback_reason":"side_effects_present"'
  assert_output --partial '"result":"error"'
  # ad4: "requested, not applied" is reserved for the "none" transport — a dead child that
  # left side effects behind never vouched for a tier either, so this stays null/no_hook_rows.
  refute_output --partial '"requested, not applied"'
  assert_output --partial '"effort_resolved":null'
  assert_output --partial '"effort_resolved_reason":"no_hook_rows"'
}

@test "R2: a failed child that only edits the artifact in place is still caught as a side effect (content hash, not existence)" {
  # The artifact already exists before the spawn (every rework round's shape) — an
  # existence-only check would read the edit as "no change" and let the in-process fallback
  # run over the child's partial work. Hashing content instead of checking existence catches it.
  ARTIFACT_REL=".context/development-0.md"
  ARTIFACT_ABS="$LR/$ARTIFACT_REL"
  mkdir -p "$LR/.context"
  echo "before" > "$ARTIFACT_ABS"
  cat > "$LR/.context/state.json" << EOF3
{"tasks":{"DV0":{"status":"in_progress","metadata":{"artifact":"$ARTIFACT_REL"}}}}
EOF3
  stub_cmd claude --body "if [ \"\$1\" = \"--version\" ]; then echo \"2.1.303\"; exit 0; fi
cat > /dev/null
echo after >> $ARTIFACT_ABS
exit 1"
  echo hi > "$WS/prompt.txt"
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" \
    --out "$LR/.context/logs/run.jsonl" --prompt "$WS/prompt.txt"
  assert_failure 3
  assert_output --partial '"fallback_reason":"side_effects_present"'
  assert_output --partial '"result":"error"'
}

@test "a missing shasum fails closed on the side-effect snapshot, never a silent pass" {
  echo hi > "$WS/prompt.txt"
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "{\"type\":\"result\",\"duration_ms\":1,\"usage\":null,\"total_cost_usd\":null}"
exit 0'
  # --hide farms a curated PATH (STUB_BIN + the required/optional tool allowlist) that never
  # included shasum in the first place — the real check under test.
  run_script_env --hide shasum "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort high --permission-mode manual --workspace "$WS" --ledger-root "$LR" \
    --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_failure 2
  assert_output --partial "shasum"
}

@test "effort_resolved is filled from the child's own audit-tooluse row after it exits" {
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "{\"type\":\"result\",\"duration_ms\":1,\"usage\":null,\"total_cost_usd\":null}"
exit 0'
  echo hi > "$WS/prompt.txt"
  mkdir -p "$LR/.context/logs"
  cat > "$LR/.context/logs/audit.jsonl" << 'EOF3'
{"ts":"2026-01-01T00:00:00Z","actor":"hook:audit-tooluse","action":"tool_invoked","subject":"Write","result":"ok","task_id":"DV0","metadata":{"dedupe_key":"sess-observed:toolu1","duration_ms":10,"effort":"unknown"}}
{"ts":"2026-01-01T00:00:01Z","actor":"hook:audit-tooluse","action":"tool_invoked","subject":"Edit","result":"ok","task_id":"DV0","metadata":{"dedupe_key":"sess-observed:toolu2","duration_ms":20,"effort":"xhigh"}}
EOF3
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt" --session-id sess-observed
  assert_success
  assert_output --partial '"effort_resolved":"xhigh"'
  assert_output --partial '"effort_resolved_reason":null'
}

@test "r4-1: a resume call still records session_id and runs the audit lookup when --session-id is also passed" {
  # The CLI refuses --session-id together with --resume without --fork-session, so the script
  # drops --session-id from the CLI's own ARGV on a resume (covered elsewhere) — but the
  # script's OWN internal SESSION_ID still has to come from somewhere, since it is what
  # emit_result reports and what the post-exit audit-log lookup keys on. Passing --session-id
  # alongside --resume is how the caller supplies that value on a resume round-trip.
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "{\"type\":\"result\",\"duration_ms\":1,\"usage\":null,\"total_cost_usd\":null}"
exit 0'
  echo hi > "$WS/prompt.txt"
  mkdir -p "$LR/.context/logs"
  cat > "$LR/.context/logs/audit.jsonl" << 'EOF3'
{"ts":"2026-01-01T00:00:01Z","actor":"hook:audit-tooluse","action":"tool_invoked","subject":"Edit","result":"ok","task_id":"DV0","metadata":{"dedupe_key":"sess-resumed:toolu1","duration_ms":20,"effort":"xhigh"}}
EOF3
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" \
    --out "$LR/.context/logs/run.jsonl" --prompt "$WS/prompt.txt" \
    --session-id sess-resumed --resume sess-resumed
  assert_success
  assert_output --partial '"session_id":"sess-resumed"'
  assert_output --partial '"effort_resolved":"xhigh"'
  assert_output --partial '"effort_resolved_reason":null'
}

@test "effort_resolved stays null/no_hook_rows when no audit row matches the session" {
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "{\"type\":\"result\",\"duration_ms\":1,\"usage\":null,\"total_cost_usd\":null}"
exit 0'
  echo hi > "$WS/prompt.txt"
  mkdir -p "$LR/.context/logs"
  cat > "$LR/.context/logs/audit.jsonl" << 'EOF3'
{"ts":"2026-01-01T00:00:00Z","actor":"hook:audit-tooluse","action":"tool_invoked","subject":"Write","result":"ok","task_id":"DV0","metadata":{"dedupe_key":"sess-other:toolu1","duration_ms":10,"effort":"xhigh"}}
EOF3
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt" --session-id sess-observed
  assert_success
  assert_output --partial '"effort_resolved":null'
  assert_output --partial '"effort_resolved_reason":"no_hook_rows"'
}

@test "a platform-plugin agent (non-corpflow prefix) registered in routing-matrix.md is accepted without a local agents/ file" {
  echo hi > "$WS/prompt.txt"
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "{\"type\":\"result\",\"duration_ms\":1,\"usage\":null,\"total_cost_usd\":null}"
exit 0'
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent apple-developer:apple-developer \
    --model opus --effort xhigh --permission-mode manual --workspace "$WS" \
    --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" --prompt "$WS/prompt.txt"
  assert_success
  assert_output --partial '"result":"ok"'
}

@test "a foreign-prefix agent id absent from routing-matrix.md is refused (b9r: registry check)" {
  echo hi > "$WS/prompt.txt"
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent other-plugin:no-such-agent \
    --model opus --effort xhigh --permission-mode manual --workspace "$WS" \
    --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" --prompt "$WS/prompt.txt"
  assert_failure 2
  assert_output --partial "not registered"
}

# --- P1 CWE-269: never wider than the parent session's own mode ------------------------------

@test "a wider request than the parent mode is refused (downgraded), never passed through" {
  print_argv_run --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode bypassPermissions --parent-mode manual --workspace "$WS" --print-argv
  [ "$PA_RC" -eq 0 ]
  ! argv_has "bypassPermissions"
  argv_has "manual"
}

@test "a request narrower than the parent mode is left alone" {
  print_argv_run --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode dontAsk --parent-mode bypassPermissions --workspace "$WS" --print-argv
  [ "$PA_RC" -eq 0 ]
  argv_has "dontAsk"
}

@test "PL is pinned to manual even when both the request and the parent mode are wide open" {
  print_argv_run --task PL0 --agent corpflow:product-manager --model opus --effort high \
    --permission-mode auto --parent-mode bypassPermissions --workspace "$WS" --print-argv
  [ "$PA_RC" -eq 0 ]
  ! argv_has "auto"
  ! argv_has "bypassPermissions"
  argv_has "manual"
}

@test "SR is pinned to manual even under a wide parent mode" {
  print_argv_run --task SR0 --agent corpflow:security-reviewer --model opus --effort xhigh \
    --permission-mode acceptEdits --parent-mode auto --workspace "$WS" --print-argv
  [ "$PA_RC" -eq 0 ]
  ! argv_has "acceptEdits"
  argv_has "manual"
}

@test "FN is pinned to manual even under a wide parent mode" {
  print_argv_run --task FN0 --agent corpflow:project-manager --model sonnet --effort medium \
    --permission-mode auto --parent-mode auto --workspace "$WS" --print-argv
  [ "$PA_RC" -eq 0 ]
  ! argv_has "auto"
  argv_has "manual"
}

@test "RE is pinned to manual even under a wide parent mode (not just PL/SR/FN)" {
  print_argv_run --task RE0 --agent corpflow:release-engineer --model sonnet --effort high \
    --permission-mode bypassPermissions --parent-mode bypassPermissions --workspace "$WS" \
    --print-argv
  [ "$PA_RC" -eq 0 ]
  ! argv_has "bypassPermissions"
  argv_has "manual"
}

@test "an unknown/omitted parent mode defaults to manual, capping a wider DV request" {
  print_argv_run --task DV0 --agent corpflow:developer --model opus --effort xhigh \
    --permission-mode bypassPermissions --workspace "$WS" --print-argv
  [ "$PA_RC" -eq 0 ]
  ! argv_has "bypassPermissions"
  argv_has "manual"
}

@test "DV keeps bypassPermissions when the parent mode is itself bypassPermissions" {
  print_argv_run --task DV0 --agent corpflow:developer --model opus --effort xhigh \
    --permission-mode bypassPermissions --parent-mode bypassPermissions --workspace "$WS" \
    --print-argv
  [ "$PA_RC" -eq 0 ]
  argv_has "bypassPermissions"
}

@test "an invalid parent mode is refused before any spawn" {
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --parent-mode yolo --workspace "$WS" --print-argv
  assert_failure 2
  assert_output --partial "parent-mode"
}

# --- P2 CWE-78: the four ledger fields are self-read, never carried by the caller -------------

@test "effort/permission-mode/workspace/artifact are self-read from the ledger when omitted" {
  echo hi > "$WS/prompt.txt"
  cat > "$LR/.context/state.json" << EOF3
{"tasks":{"DV0":{"status":"in_progress","metadata":{"effort":"xhigh","permission_mode":"manual","workspace_path":"$WS","artifact":".context/development-0.md"}}}}
EOF3
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "{\"type\":\"result\",\"duration_ms\":1,\"usage\":null,\"total_cost_usd\":null}"
exit 0'
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_success
  assert_output --partial '"result":"ok"'
}

@test "b10: a null permission_mode on the ledger row inherits parent-mode instead of refusing (the common row shape)" {
  # PL0 stamps permission_mode only on SR/FN under --secure/--full (state-ledger.md:212); every
  # other row, this DV row included, carries it null. No --parent-mode either, so this also
  # exercises the "omitted defaults to manual" path end to end.
  echo hi > "$WS/prompt.txt"
  cat > "$LR/.context/state.json" << EOF3
{"tasks":{"DV0":{"status":"in_progress","metadata":{"effort":"xhigh","permission_mode":null,"workspace_path":"$WS","artifact":".context/development-0.md"}}}}
EOF3
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "{\"type\":\"result\",\"duration_ms\":1,\"usage\":null,\"total_cost_usd\":null}"
exit 0'
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_success
  assert_output --partial '"result":"ok"'
}

@test "a ledger row missing a required field is refused before any spawn (self-read path)" {
  echo hi > "$WS/prompt.txt"
  cat > "$LR/.context/state.json" << EOF3
{"tasks":{"DV0":{"status":"in_progress","metadata":{"permission_mode":"manual"}}}}
EOF3
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_failure 2
  assert_output --partial "missing"
}

# --- P2 CWE-73: workspace must be a real worktree of the ledger's own repo -------------------

@test "a workspace off the ledger root's own worktree list is refused" {
  echo hi > "$WS/prompt.txt"
  OTHER_LR="$(mk_git_fixture --file README.md:hi --commit init)"
  OTHER_WS="$(mk_tmpworkdir)/other-wt"
  git -C "$OTHER_LR" worktree add -q -b wt-other "$OTHER_WS" > /dev/null 2>&1
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --workspace "$OTHER_WS" --ledger-root "$LR" \
    --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_failure 2
  assert_output --partial "not a worktree this ledger pins"
}

@test "the ledger root itself is an accepted workspace (single-worktree case)" {
  echo hi > "$LR/prompt.txt"
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "{\"type\":\"result\",\"duration_ms\":1,\"usage\":null,\"total_cost_usd\":null}"
exit 0'
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort high --permission-mode manual --workspace "$LR" --ledger-root "$LR" \
    --out "$LR/.context/logs/run.jsonl" \
    --prompt "$LR/prompt.txt"
  assert_success
  assert_output --partial '"result":"ok"'
}

@test "P2: when the ledger root is itself a linked worktree, a sibling worktree of the shared repo NOT pinned by this ledger's DV rows is refused" {
  PARENT="$(mk_git_fixture --file README.md:hi --commit init)"
  LR2="$(mk_tmpworkdir)/ledger-wt"
  git -C "$PARENT" worktree add -q -b wt-ledger "$LR2" > /dev/null 2>&1
  mkdir -p "$LR2/.context/logs"
  SIBLING="$(mk_tmpworkdir)/sibling-wt"
  git -C "$PARENT" worktree add -q -b wt-sibling "$SIBLING" > /dev/null 2>&1
  PINNED="$(mk_tmpworkdir)/pinned-wt"
  git -C "$PARENT" worktree add -q -b wt-pinned "$PINNED" > /dev/null 2>&1
  cat > "$LR2/.context/state.json" << EOF3
{"tasks":{"DV0":{"status":"in_progress","metadata":{"workspace_path":"$PINNED"}}}}
EOF3
  echo hi > "$SIBLING/prompt.txt"
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --workspace "$SIBLING" --ledger-root "$LR2" \
    --out "$LR2/.context/logs/run.jsonl" \
    --prompt "$SIBLING/prompt.txt"
  assert_failure 2
  assert_output --partial "not a worktree this ledger pins"
}

@test "P2: a worktree pinned by this ledger's own DV row is accepted even under a linked ledger root" {
  PARENT="$(mk_git_fixture --file README.md:hi --commit init)"
  LR2="$(mk_tmpworkdir)/ledger-wt"
  git -C "$PARENT" worktree add -q -b wt-ledger2 "$LR2" > /dev/null 2>&1
  mkdir -p "$LR2/.context/logs"
  PINNED="$(mk_tmpworkdir)/pinned-wt2"
  git -C "$PARENT" worktree add -q -b wt-pinned2 "$PINNED" > /dev/null 2>&1
  cat > "$LR2/.context/state.json" << EOF3
{"tasks":{"DV0":{"status":"in_progress","metadata":{"workspace_path":"$PINNED"}}}}
EOF3
  echo hi > "$PINNED/prompt.txt"
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "{\"type\":\"result\",\"duration_ms\":1,\"usage\":null,\"total_cost_usd\":null}"
exit 0'
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort high --permission-mode manual --workspace "$PINNED" --ledger-root "$LR2" \
    --out "$LR2/.context/logs/run.jsonl" \
    --prompt "$PINNED/prompt.txt"
  assert_success
  assert_output --partial '"result":"ok"'
}

@test "r4-3: a tampered DV row pinning a foreign repo's work tree is refused, even though it names itself" {
  # The DV row's own metadata.workspace_path is the FOREIGN repo's worktree, not one this
  # ledger's repo owns at all — self-attested membership must not be sufficient on a linked
  # root; git-owned membership (this ledger's `git worktree list`) is required in addition.
  PARENT="$(mk_git_fixture --file README.md:hi --commit init)"
  LR2="$(mk_tmpworkdir)/ledger-wt"
  git -C "$PARENT" worktree add -q -b wt-ledger3 "$LR2" > /dev/null 2>&1
  mkdir -p "$LR2/.context/logs"
  FOREIGN_REPO="$(mk_git_fixture --file README.md:hi --commit init)"
  FOREIGN_WS="$(mk_tmpworkdir)/foreign-wt"
  git -C "$FOREIGN_REPO" worktree add -q -b wt-foreign "$FOREIGN_WS" > /dev/null 2>&1
  cat > "$LR2/.context/state.json" << EOF3
{"tasks":{"DV0":{"status":"in_progress","metadata":{"workspace_path":"$FOREIGN_WS"}}}}
EOF3
  echo hi > "$FOREIGN_WS/prompt.txt"
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --workspace "$FOREIGN_WS" --ledger-root "$LR2" \
    --out "$LR2/.context/logs/run.jsonl" \
    --prompt "$FOREIGN_WS/prompt.txt"
  assert_failure 2
  assert_output --partial "not a worktree this ledger pins"
}

@test "r4-3: a linked ledger root without jq refuses rather than widening to the repo-wide worktree list" {
  PARENT="$(mk_git_fixture --file README.md:hi --commit init)"
  LR2="$(mk_tmpworkdir)/ledger-wt"
  git -C "$PARENT" worktree add -q -b wt-ledger4 "$LR2" > /dev/null 2>&1
  mkdir -p "$LR2/.context/logs"
  SIBLING="$(mk_tmpworkdir)/sibling-wt2"
  git -C "$PARENT" worktree add -q -b wt-sibling2 "$SIBLING" > /dev/null 2>&1
  cat > "$LR2/.context/state.json" << EOF3
{"tasks":{"DV0":{"status":"in_progress","metadata":{"workspace_path":"$SIBLING"}}}}
EOF3
  echo hi > "$SIBLING/prompt.txt"
  # --hide farms a curated PATH that omits jq entirely, so the linked-root branch cannot read
  # the DV-pin set at all.
  run_script_env --hide jq "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort high --permission-mode manual --workspace "$SIBLING" --ledger-root "$LR2" \
    --out "$LR2/.context/logs/run.jsonl" \
    --prompt "$SIBLING/prompt.txt"
  assert_failure 2
  assert_output --partial "requires jq"
}

# --- P3 CWE-59/532: --out is confined to <ledger-root>/.context/logs/, never a symlink --------

@test "an --out path outside <ledger-root>/.context/logs/ is refused" {
  echo hi > "$WS/prompt.txt"
  OUTSIDE="$(mk_tmpworkdir)/elsewhere.jsonl"
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --workspace "$WS" --ledger-root "$LR" \
    --out "$OUTSIDE" --prompt "$WS/prompt.txt"
  assert_failure 2
  assert_output --partial "out log"
}

@test "a symlinked --out path is refused" {
  echo hi > "$WS/prompt.txt"
  TARGET="$(mk_tmpworkdir)/real.jsonl"
  ln -s "$TARGET" "$LR/.context/logs/link.jsonl"
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --workspace "$WS" --ledger-root "$LR" \
    --out "$LR/.context/logs/link.jsonl" \
    --prompt "$WS/prompt.txt"
  assert_failure 2
  assert_output --partial "symlink"
}

# --- P3 CWE-345: an observed effort off the tier ladder is never trusted ----------------------

@test "an observed effort not on the enum is ignored, not passed downstream" {
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat > /dev/null
echo "{\"type\":\"result\",\"duration_ms\":1,\"usage\":null,\"total_cost_usd\":null}"
exit 0'
  echo hi > "$WS/prompt.txt"
  cat > "$LR/.context/logs/audit.jsonl" << 'EOF3'
{"ts":"2026-01-01T00:00:00Z","actor":"hook:audit-tooluse","action":"tool_invoked","subject":"Write","result":"ok","task_id":"DV0","metadata":{"dedupe_key":"sess-bad:toolu1","duration_ms":10,"effort":"ludicrous"}}
EOF3
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort xhigh --permission-mode manual --workspace "$WS" --ledger-root "$LR" \
    --out "$LR/.context/logs/run.jsonl" \
    --prompt "$WS/prompt.txt" --session-id sess-bad
  assert_success
  assert_output --partial '"effort_resolved":null'
  assert_output --partial '"effort_resolved_reason":"no_hook_rows"'
}

@test "compaction token boundaries reach argv, invalid numbers refuse" {
  for value in 100000 1000000; do
    print_argv_run --task DV0 --agent corpflow:developer --model opus --effort high \
      --permission-mode manual --workspace "$WS" --auto-compact-window "$value" --print-argv
    [ "$PA_RC" -eq 0 ]
    argv_has --autocompact
    argv_has "$value"
  done
  for value in 99999 1000001 200k 1.5 null true; do
    run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
      --permission-mode manual --workspace "$WS" --auto-compact-window "$value" --print-argv
    assert_failure 2
  done
}

@test "watchdog waits require explicit enabled watchdog and positive bounded integers" {
  for value in 0 -1 1.5 2147483648 true; do
    run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
      --permission-mode manual --workspace "$WS" --retry-watchdog true \
      --retry-watchdog-max-wait-ms "$value" --print-argv
    assert_failure 2
  done
  run_script "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --effort high \
    --permission-mode manual --workspace "$WS" --retry-watchdog-max-wait-ms 10 --print-argv
  assert_failure 2
}

@test "ledger controls survive resume, explicit overrides and child environment isolation" {
  printf '%s' '{"tasks":{"DV0":{"metadata":{"effort":"high","retry_watchdog":true,"retry_watchdog_max_wait_ms":100,"retry_watchdog_max_usage_limit_wait_ms":200,"overloaded_retry_max_delay_ms":300,"auto_compact_window":100000}}}}' > "$LR/.context/state.json"
  CAPTURE="$(mk_tmpworkdir)/capture"
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat >/dev/null
printf "%s\n" "$CLAUDE_CODE_RETRY_WATCHDOG" "$CLAUDE_CODE_RETRY_WATCHDOG_MAX_WAIT_MS" "$CLAUDE_CODE_RETRY_WATCHDOG_MAX_USAGE_LIMIT_WAIT_MS" "$CLAUDE_CODE_OVERLOADED_RETRY_MAX_DELAY_MS" "$CLAUDE_CODE_AUTO_COMPACT_WINDOW" "$@" > "$CAPTURE"
echo "{\"type\":\"result\",\"duration_ms\":1}"'
  echo hi > "$WS/prompt.txt"
  run_script_env --stub-path --env "CAPTURE=$CAPTURE" --env "CLAUDE_CODE_AUTO_COMPACT_WINDOW=900000" \
    "$SCRIPT" --task DV0 --agent corpflow:developer --model opus --permission-mode manual \
    --workspace "$WS" --ledger-root "$LR" --out "$LR/.context/logs/run.jsonl" --prompt "$WS/prompt.txt" \
    --auto-compact-window 200000 --retry-watchdog-max-wait-ms 500 --resume abc-123
  assert_success
  [ "$(sed -n '1,5p' "$CAPTURE")" = "$(printf '1\n500\n200\n300\n200000')" ]
  grep -qx -- --resume "$CAPTURE"
  grep -qx -- abc-123 "$CAPTURE"
  grep -qx -- --autocompact "$CAPTURE"
  [ "${CLAUDE_CODE_AUTO_COMPACT_WINDOW-unset}" = unset ]
}

@test "configured controls prevent below-floor and post-launch fallback" {
  echo hi > "$WS/prompt.txt"
  stub_cmd claude --body 'echo "2.1.302"'
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort high --permission-mode manual --workspace "$WS" --ledger-root "$LR" \
    --out "$LR/.context/logs/run.jsonl" --prompt "$WS/prompt.txt" --retry-watchdog false
  assert_failure 2
  assert_output --partial 'require headless execution'
  stub_cmd claude --body 'if [ "$1" = "--version" ]; then echo "2.1.303"; exit 0; fi
cat >/dev/null
exit 1'
  run_script_env --stub-path "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
    --effort high --permission-mode manual --workspace "$WS" --ledger-root "$LR" \
    --out "$LR/.context/logs/run.jsonl" --prompt "$WS/prompt.txt" --retry-watchdog false
  assert_failure 2
  assert_output --partial 'prevent in-process fallback'
}

@test "ledger numeric strings and null controls refuse before spawn" {
  echo hi > "$WS/prompt.txt"
  for value in '"100000"' null; do
    printf '{"tasks":{"DV0":{"metadata":{"auto_compact_window":%s}}}}' "$value" > "$LR/.context/state.json"
    run_script_env --hide claude "$SCRIPT" --task DV0 --agent corpflow:developer --model opus \
      --effort high --permission-mode manual --workspace "$WS" --ledger-root "$LR" \
      --out "$LR/.context/logs/run.jsonl" --prompt "$WS/prompt.txt"
    assert_failure 2
  done
}
