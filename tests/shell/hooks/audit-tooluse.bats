#!/usr/bin/env bats
# Tests for hooks/audit-tooluse.sh (DV0c) — PostToolUse → audit.jsonl writer
# emitting a `tool_invoked` row keyed "<session>:<tool_use_id>".
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="hooks/audit-tooluse.sh"
PAYLOAD="${FIXTURES}/hooks/audit-tooluse.payload.json"

setup() {
  WD="$(mk_tmpworkdir)"
  # The root ladder (hooks/model-switch-lib.sh) only honours a declared
  # CLAUDE_PROJECT_DIR/WORKSPACE_ROOT when .context/ already exists under it —
  # it never guesses cwd. Declare that fixture root up front so every test
  # below is exercising the write path, not the unresolved-root no-op. The ladder
  # answers only a context holding a ledger, so the fixture seeds one.
  mkdir -p "$WD/.context"
  printf '%s' '{"version":2,"tasks":{}}' > "$WD/.context/state.json"
}

bash_payload() {
  jq -cn --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}, tool_use_id:"tb", duration_ms:1, session_id:"s1"}'
}

@test "happy: writes tool_invoked row with tool, duration, effort, dedupe_key" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < "$PAYLOAD"
  assert_success
  run jq -e '
    .action == "tool_invoked"
    and .subject == "Write"
    and .metadata.kind == "tool"
    and .metadata.duration_ms == 42
    and .metadata.effort == "medium"
    and (.metadata.dedupe_key == "sess_fix:toolu_fix")
  ' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "edge: a payload without effort records unknown, never \$CLAUDE_EFFORT" {
  # A haiku subagent runs with no effort: its payload omits .effort while the env var still
  # holds the tier the Agent call requested. Reading the env would record a tier that never ran.
  run env CLAUDE_EFFORT=high CLAUDE_PROJECT_DIR="$WD" \
    bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"tool_name":"Write"}'
  assert_success
  run jq -e '.metadata.effort == "unknown"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "edge: --kind override and absent ids fall back to placeholders" {
  run env CLAUDE_PROJECT_DIR="$WD" \
    bash "$PLUGIN_ROOT/$SCRIPT" --kind mcp <<< '{"tool_name":"X"}'
  assert_success
  run jq -e '
    .metadata.kind == "mcp"
    and .metadata.duration_ms == 0
    and .metadata.effort == "unknown"
    and (.metadata.dedupe_key == "nosession:notoolid")
  ' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "ledger: a state-patch status call is audited with task_id and status" {
  # The stage-transition trail resume depends on: this Bash call is the ONLY signal
  # that a stage advanced.
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"tool_name":"Bash","tool_input":{"command":"bash skills/worktask/scripts/state-patch.sh --task-status DV1 in_progress"},"tool_use_id":"t1","duration_ms":10,"session_id":"s1","effort":{"level":"high"}}'
  assert_success
  run jq -e '.subject == "state-patch" and .task_id == "DV1" and .metadata.task_id == "DV1"
             and .metadata.status == "in_progress"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "ledger: an ordinary Bash call writes NO row" {
  # Widening the matcher to all of Bash must not turn the audit log into shell noise.
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_use_id":"t2","duration_ms":5,"session_id":"s1"}'
  assert_success
  [ ! -s "$WD/.context/logs/audit.jsonl" ]
}

@test "ledger: a non-status state-patch call still audits, without task fields" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"tool_name":"Bash","tool_input":{"command":"bash skills/worktask/scripts/state-patch.sh --task-create QA0 --metadata {}"},"tool_use_id":"t4","duration_ms":9,"session_id":"s1"}'
  assert_success
  run jq -e '.subject == "state-patch" and .task_id == "none" and (.metadata | has("task_id") | not)' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "row: every row carries a top-level subject and task_id, the active stage when one runs" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < "$PAYLOAD"
  assert_success
  printf '%s' '{"tasks":{"DV0":{"status":"in_progress"},"PL0":{"status":"completed"}}}' > "$WD/.context/state.json"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x"},"tool_use_id":"t3","session_id":"s1"}'
  assert_success
  run jq -rs 'map(.task_id) | join(",")' "$WD/.context/logs/audit.jsonl"
  assert_output "none,DV0"
  run jq -s -e 'all(.[]; (.subject // "") != "" and (.task_id // "") != "")' "$WD/.context/logs/audit.jsonl"
  assert_success
}

# --- tool_input non-disclosure ----------------------------------------------
# audit.jsonl is committed and read by every downstream stage, while tool_input
# carries file contents, diffs and full shell command lines. Only the task-status
# pair, a redacted command_head and scrubbed targets may be derived from it; these
# cases go red if any other .tool_input field — or more of the command — reaches a row.
#
# CANARY is chosen so it cannot arise from any field the row legitimately emits,
# which is what stops these assertions from passing by accident.
CANARY="zqCANARYzq_tool_input_must_not_leak_7f31a9"

# grep -c exits 1 on no-match and 2 on a missing file, so a leak check alone
# would pass vacuously when nothing was written. Every case below therefore
# pins the row's presence (or absence) separately.
refute_log_contains() {
  run grep -cF "$CANARY" "$WD/.context/logs/audit.jsonl"
  assert_failure
}

@test "leak: a Write payload's file content and host path never reach the row" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/${CANARY}/.env\",\"content\":\"AWS_SECRET_ACCESS_KEY=${CANARY}\"},\"tool_use_id\":\"t10\",\"duration_ms\":7,\"session_id\":\"s1\"}"
  assert_success
  run jq -e '.subject == "Write" and .metadata.targets == ["[local-path]"]' "$WD/.context/logs/audit.jsonl"
  assert_success
  refute_log_contains
}

@test "leak: an Edit payload's old_string and new_string never reach the row" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/config.yml\",\"old_string\":\"token: old_${CANARY}\",\"new_string\":\"token: new_${CANARY}\"},\"tool_use_id\":\"t11\",\"duration_ms\":8,\"session_id\":\"s1\"}"
  assert_success
  run jq -e '.subject == "Edit" and .metadata.targets == ["[local-path]"]' "$WD/.context/logs/audit.jsonl"
  assert_success
  refute_log_contains
}

@test "leak: a filtered-out Bash command and its token never reach the row" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"curl -H 'Authorization: Bearer ${CANARY}' https://api.example.com\"},\"tool_use_id\":\"t12\",\"duration_ms\":6,\"session_id\":\"s1\"}"
  assert_success
  [ ! -s "$WD/.context/logs/audit.jsonl" ]
  refute_log_contains
}

@test "leak: a --note value never reaches the row, while the redacted head does" {
  # The positive control for the cases around it: this row MUST carry the task
  # fields, a non-empty command_head and its script target, so an assertion broad
  # enough to forbid every tool_input-derived field — or a "fix" that stopped
  # auditing Bash entirely — fails here.
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "bash skills/worktask/scripts/state-patch.sh --task-status DV1 done --note ${CANARY}")"
  assert_success
  run jq -e '.subject == "state-patch" and .metadata.task_id == "DV1" and .metadata.status == "done"
             and .metadata.command_head == "state-patch.sh --task-status DV1 [redacted]"
             and .metadata.targets == ["skills/worktask/scripts/state-patch.sh"]' "$WD/.context/logs/audit.jsonl"
  assert_success
  refute_log_contains
}

@test "leak: a secret in a leading assignment never reaches the row" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "API_TOKEN=${CANARY} bash skills/worktask/scripts/state-patch.sh --task-status DV1 done")"
  assert_success
  run jq -e '.task_id == "DV1" and (.metadata.command_head | startswith("state-patch.sh "))' "$WD/.context/logs/audit.jsonl"
  assert_success
  refute_log_contains
}

@test "leak: an Authorization header inside a filtered-in command never reaches the row" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "bash skills/worktask/scripts/state-patch.sh --task-status QA0 done --note 'Authorization: Bearer ${CANARY}'")"
  assert_success
  run jq -e '.task_id == "QA0" and (.metadata.command_head | length) <= 120' "$WD/.context/logs/audit.jsonl"
  assert_success
  refute_log_contains
  run grep -ci 'bearer' "$WD/.context/logs/audit.jsonl"
  assert_failure
}

@test "leak: an absolute file_path outside the scrub's own pattern never reaches the row" {
  local c tool fp
  for c in Write:/data/u1/secrets/prod.env Edit:/usr/local/acme/licence.key; do
    tool="${c%%:*}"
    fp="${c#*:}"
    rm -f "$WD/.context/logs/audit.jsonl"
    run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(jq -cn --arg t "$tool" --arg p "$fp" '{tool_name:$t, tool_input:{file_path:$p, old_string:"a", new_string:"b"}, tool_use_id:"ta", session_id:"s1"}')"
    assert_success
    run jq -c '.metadata.targets' "$WD/.context/logs/audit.jsonl"
    assert_output '["[local-path]"]'
    run grep -cF "$fp" "$WD/.context/logs/audit.jsonl"
    assert_failure
  done
}

@test "leak: a path-shaped credential in a command never reaches targets" {
  local key='wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "bash skills/worktask/scripts/state-patch.sh --task-status DV1 done --note $key")"
  assert_success
  run jq -e '.task_id == "DV1" and (.metadata.targets | index("skills/worktask/scripts/state-patch.sh") != null)' "$WD/.context/logs/audit.jsonl"
  assert_success
  run grep -cF 'wJalrXUtnFEMI' "$WD/.context/logs/audit.jsonl"
  assert_failure
}

@test "leak: a status word is read from the first line only, and only from the closed set" {
  local pass=correct_horse_battery_staple_passphrase_lowercase
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "$(printf 'bash skills/worktask/scripts/state-patch.sh --help\necho x --task-status DV1 %s' "$pass")")"
  assert_success
  run jq -e '(.metadata | has("status") | not) and (.metadata | has("task_id") | not)' "$WD/.context/logs/audit.jsonl"
  assert_success
  run grep -cF "$pass" "$WD/.context/logs/audit.jsonl"
  assert_failure

  rm -f "$WD/.context/logs/audit.jsonl"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(bash_payload "bash skills/worktask/scripts/state-patch.sh --task-status DV1 $pass")"
  assert_success
  run jq -e '.metadata | has("status") | not' "$WD/.context/logs/audit.jsonl"
  assert_success
  run grep -cF "$pass" "$WD/.context/logs/audit.jsonl"
  assert_failure
}

@test "targets: a Write under the workspace records its repo-relative path" {
  mkdir -p "$WD/src"
  run env WORKSPACE_ROOT="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(jq -cn --arg p "$WD/src/app.sh" '{tool_name:"Write", tool_input:{file_path:$p, content:"x"}, tool_use_id:"tw", session_id:"s1"}')"
  assert_success
  run jq -c '.metadata.targets' "$WD/.context/logs/audit.jsonl"
  assert_output '["src/app.sh"]'
}

@test "targets: a file_path outside the path grammar is dropped whole, never split" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(jq -cn --arg p "$WD/my docs/a.sh" '{tool_name:"Write", tool_input:{file_path:$p}, tool_use_id:"tw", session_id:"s1"}')"
  assert_success
  run jq -c '.metadata.targets' "$WD/.context/logs/audit.jsonl"
  assert_output '[]'
}

@test "redaction: with the path scrub or the redaction library unreachable nothing raw is published" {
  local plug="$WD/plug" mode
  for mode in no-scrub no-lib; do
    rm -rf "$plug" "$WD/.context/logs"
    mkdir -p "$plug"
    cp -R "$PLUGIN_ROOT/hooks" "$plug/hooks"
    [ "$mode" = no-scrub ] || rm -f "$plug/hooks/lib/command-head-lib.sh"
    run env CLAUDE_PROJECT_DIR="$WD" bash "$plug/hooks/audit-tooluse.sh" <<< "$(bash_payload "API_TOKEN=${CANARY} bash /Users/alice/state-patch.sh --task-status DV1 done")"
    assert_success
    run jq -e '.metadata.command_head == "[redacted]" and .metadata.targets == []
               and .metadata.redaction == "scrub_unavailable" and .task_id == "DV1"' "$WD/.context/logs/audit.jsonl"
    assert_success
    refute_log_contains
    run grep -c '/Users/' "$WD/.context/logs/audit.jsonl"
    assert_failure
  done
}

@test "failure: malformed JSON exits 0 and writes no row" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< 'xxx'
  assert_success
  [ ! -s "$WD/.context/logs/audit.jsonl" ]
}

@test "contract: --self-test passes (counted summary)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "self-test OK"
  assert_output --regexp 'audit-tooluse: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
}

# Companion to the audit-subagent arm of the same name.
@test "SR: a symlinked audit.jsonl is refused, never written through" {
  mkdir -p "$WD/.context/logs" "$WD/target-dir"
  ln -s "$WD/target-dir/escaped.txt" "$WD/.context/logs/audit.jsonl"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < "$PAYLOAD"
  assert_success
  [ ! -e "$WD/target-dir/escaped.txt" ]
}

# --- root resolution ---------------------------------------------------

@test "unresolved root -> rc 0, no .context materialized under cwd" {
  local fresh
  fresh="$(mk_tmpworkdir)"
  run env -u WORKSPACE_ROOT -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR \
    GIT_CEILING_DIRECTORIES="$fresh" \
    bash -c "cd '$fresh' && bash '$PLUGIN_ROOT/$SCRIPT'" <<< '{"tool_name":"Bash","tool_input":{"command":"bash skills/worktask/scripts/state-patch.sh --task-status DV1 in_progress"},"tool_use_id":"t20","duration_ms":10,"session_id":"s1"}'
  assert_success
  [ ! -d "$fresh/.context" ]
}

@test "registered stage worktree cwd, no declared root -> row lands in main's ledger" {
  local base main wt
  base="$(mk_tmpworkdir)"
  main="$base/main"
  wt="$base/wt"
  mkdir -p "$main"
  local G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false)
  ( cd "$main" && "${G[@]}" init -q \
    && "${G[@]}" commit -q --allow-empty -m init \
    && "${G[@]}" worktree add -q "$wt" -b t ) >/dev/null
  # Physical path: mktemp -d can hand back a symlinked path (macOS /var), while
  # the resolver always answers physically — compare physical to physical.
  main="$(cd "$main" && pwd -P)"
  mkdir -p "$main/.context"
  # The main ledger lends itself to a linked worktree only when a task registered it.
  jq -cn --arg w "$wt" '{version: 2, tasks: {DV1: {status: "pending", metadata: {workspace_path: $w}}}}' \
    > "$main/.context/state.json"

  run env -u WORKSPACE_ROOT -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash -c "cd '$wt' && bash '$PLUGIN_ROOT/$SCRIPT'" <<< '{"tool_name":"Bash","tool_input":{"command":"bash skills/worktask/scripts/state-patch.sh --task-status DV1 in_progress"},"tool_use_id":"t21","duration_ms":10,"session_id":"s1"}'
  assert_success
  run jq -e '.subject == "state-patch" and .metadata.task_id == "DV1"' \
    "$main/.context/logs/audit.jsonl"
  assert_success
  [ ! -d "$wt/.context" ]
}

# _linked_pair -> sets MAIN and WT: a main checkout plus one linked worktree, physical paths.
_linked_pair() {
  local base
  base="$(mk_tmpworkdir)"
  base="$(cd "$base" && pwd -P)"
  MAIN="$base/main"
  WT="$base/wt"
  mkdir -p "$MAIN"
  local G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false)
  ( cd "$MAIN" && "${G[@]}" init -q \
    && "${G[@]}" commit -q --allow-empty -m init \
    && "${G[@]}" worktree add -q "$WT" -b t ) >/dev/null
}

@test "AC-5: a linked worktree's own ledger receives the row when main has none" {
  _linked_pair
  mkdir -p "$WT/.context"
  printf '%s' '{"version":2,"tasks":{}}' > "$WT/.context/state.json"
  run env -u WORKSPACE_ROOT -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash -c "cd '$WT' && bash '$PLUGIN_ROOT/$SCRIPT'" <<< '{"tool_name":"Bash","tool_input":{"command":"bash skills/worktask/scripts/state-patch.sh --task-status DV1 in_progress"},"tool_use_id":"t22","duration_ms":10,"session_id":"s1"}'
  assert_success
  run jq -e '.metadata.task_id == "DV1"' "$WT/.context/logs/audit.jsonl"
  assert_success
  [ ! -e "$MAIN/.context" ]
}

@test "AC-5: a declared WORKSPACE_ROOT whose context has no state.json writes nothing anywhere" {
  _linked_pair
  mkdir -p "$WT/.context"
  run env -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR WORKSPACE_ROOT="$WT" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash -c "cd '$WT' && bash '$PLUGIN_ROOT/$SCRIPT'" <<< '{"tool_name":"Bash","tool_input":{"command":"bash skills/worktask/scripts/state-patch.sh --task-status DV1 in_progress"},"tool_use_id":"t23","duration_ms":10,"session_id":"s1"}'
  assert_success
  [ -z "$(ls -A "$WT/.context")" ] || fail "wrote into a context with no ledger: $(ls -A "$WT/.context")"
  [ ! -e "$MAIN/.context" ]
}
