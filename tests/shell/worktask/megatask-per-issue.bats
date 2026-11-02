#!/usr/bin/env bats
# Contract tests for the /megatask per-issue run environment (commands/megatask.md § Step 3 —
# run environment in the per-issue prompt; skills/worktask/references/megatask-per-issue.md
# § Per-issue run under /megatask):
#   - both files state one Bash prefix, `cd "<wt>" && export WORKSPACE_ROOT="<wt>" MILESTONE_MODE=1 &&`;
#   - run literally from megatask's root, as a subagent's shell starts, that prefix makes
#     seed-state.sh and state-patch.sh write the worktree's ledger and leave megatask's alone,
#     and the scan, preflight and branch scripts see a per-issue run;
#   - without the export, state-patch.sh resolves megatask's ledger (why the prefix exports);
#   - Step 2a never asks, Phase 3 is skipped, and nothing calls EnterWorktree;
#   - the real SubagentStop hooks, which inherit megatask's environment and never the prefix,
#     bind to the issue from their payload and write the issue's log, never the batch's.
#
# Nothing here launches a subagent: the prefix is executed by bash exactly as the prompt
# states it, and each hook is run as Claude Code runs it — its own process, megatask's
# environment, a JSON payload on stdin.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

MEGATASK_DOC="commands/megatask.md"
WORKTASK_DOC="commands/worktask.md"
SKILL_DOC="skills/worktask/SKILL.md"
ENV_HEAD="#### Step 3 — run environment in the per-issue prompt"
PER_ISSUE_DOC="skills/worktask/references/megatask-per-issue.md"
PER_ISSUE_HEAD='## Per-issue run under `/megatask`'
SCRIPTS="skills/worktask/scripts"

section() {
  awk -v h="$2" '$0 == h {f=1; print; next} f && /^#/ {exit} f {print}' "$PLUGIN_ROOT/$1"
}

# The prefix as megatask Step 3 states it, `<wt>` still in place.
doc_prefix() {
  section "$MEGATASK_DOC" "$ENV_HEAD" \
    | sed -n 's/^- Begin every Bash call with `\(cd "<wt>" && [^`]*&&\)`\.$/\1/p' | head -1
}

setup() {
  ROOT="$(mk_tmpworkdir)"
  WT="$ROOT/.worktrees/milestone-9/41"
  mkdir -p "$ROOT/.context/logs" "$WT/.context"
  printf '{"version":2,"run_index":0,"tasks":{"PL0":{"status":"completed","metadata":{}}}}\n' \
    > "$ROOT/.context/state.json"
  cp "$ROOT/.context/state.json" "$ROOT/state.before"
  printf '{"version":"2.0","isolation":"worktree","execution":{"status":"in_progress"}}\n' \
    > "$WT/workspace.json"
  WT_PHYS="$(cd "$WT" && pwd -P)"
}

# in_run <command…> — one Bash call of the per-issue subagent: cwd and CLAUDE_PROJECT_DIR are
# megatask's root, and the documented prefix opens the call.
in_run() {
  local prefix
  prefix="$(doc_prefix)"
  prefix="${prefix//<wt>/$WT}"
  cd "$ROOT"
  run env -u WORKSPACE_ROOT -u MILESTONE_MODE -u CONTEXT_DIR CLAUDE_PROJECT_DIR="$ROOT" \
    bash -c "$prefix $*"
}

@test "prefix: megatask Step 3 and worktask's per-issue section state the same one" {
  local p
  p="$(doc_prefix)"
  [ "$p" = 'cd "<wt>" && export WORKSPACE_ROOT="<wt>" MILESTONE_MODE=1 &&' ] \
    || fail "megatask Step 3 prefix changed or missing: [$p]"
  section "$PER_ISSUE_DOC" "$PER_ISSUE_HEAD" | grep -qF "\`$p\`" \
    || fail "$PER_ISSUE_DOC § Per-issue run under /megatask does not state the same prefix"
}

@test "prefix: seed-state.sh and state-patch.sh write the worktree's ledger, not megatask's" {
  in_run "bash '$PLUGIN_ROOT/$SCRIPTS/seed-state.sh' --worktask-id issue-41 --goal 'Add login'"
  assert_success
  assert_line "result=seeded"
  in_run "bash '$PLUGIN_ROOT/$SCRIPTS/state-patch.sh' --task-meta PL0 --set '{\"megatask_group\":\"milestone-9\",\"workspace_path\":\"$WT_PHYS\"}'"
  assert_success
  run jq -r '"\(.metadata.workspace_path) \(.tasks.PL0.metadata.megatask_group)"' "$WT/.context/state.json"
  assert_output "$WT_PHYS milestone-9"
  cmp -s "$ROOT/.context/state.json" "$ROOT/state.before" || fail "megatask's ledger changed"
}

@test "why the export: with only the cd, state-patch.sh resolves megatask's ledger" {
  printf '{"version":2,"run_index":0,"tasks":{"PL0":{"status":"in_progress","metadata":{}}}}\n' \
    > "$WT/.context/state.json"
  cd "$ROOT"
  run env -u WORKSPACE_ROOT -u CONTEXT_DIR CLAUDE_PROJECT_DIR="$ROOT" \
    bash -c "cd '$WT' && bash '$PLUGIN_ROOT/$SCRIPTS/state-patch.sh' --task-meta PL0 --set '{\"probe\":1}'"
  assert_success
  run jq -r '.tasks.PL0.metadata.probe' "$ROOT/.context/state.json"
  assert_output "1"
  run jq -r '.tasks.PL0.metadata.probe' "$WT/.context/state.json"
  assert_output "null"
}

@test "prefix: the scan, the autonomy preflight and the branch rename all see a per-issue run" {
  printf '{"version":2,"run_index":0,"tasks":{"PL0":{"status":"in_progress","metadata":{}}}}\n' \
    > "$WT/.context/state.json"
  in_run "bash '$PLUGIN_ROOT/$SCRIPTS/preflight-issue-scan.sh' --goal 'Add login'"
  assert_success
  assert_line "result=skipped"
  assert_line "reason=milestone_mode"
  in_run "bash '$PLUGIN_ROOT/$SCRIPTS/autonomy-preflight.sh' --auto plan,decision,finalization --platform none"
  assert_success
  assert_line "reason=milestone_mode"
  in_run "BRANCH_NAME_PRINT=1 bash '$PLUGIN_ROOT/$SCRIPTS/branch-name.sh' --goal 'Add login'"
  assert_success
  assert_output --partial "milestone_mode_env"
}

@test "Step 2a: a per-issue run never reaches the duplicate-issue question" {
  section "$WORKTASK_DOC" "#### Step 2a — the gate" | tr '\n' ' ' \
    | grep -qF 'A `/megatask` per-issue run never asks' \
    || fail "Step 2a's gate no longer rules out the question under /megatask"
  section "$PER_ISSUE_DOC" "### Per-issue run — what changes" \
    | grep -E '^\| 2a-pre, 2a \|' | grep -qF 'no `AskUserQuestion` runs' \
    || fail "the per-issue table no longer says Step 2a asks nothing"
}

@test "Phase 3: skipped under /megatask in the command and the skill" {
  section "$WORKTASK_DOC" "## Phase 3: Post-Worktask Self-Improvement" | tr '\n' ' ' \
    | grep -qF 'A `/megatask` per-issue run skips this phase' \
    || fail "$WORKTASK_DOC § Phase 3 does not skip under /megatask"
  section "$SKILL_DOC" "## Post-Worktask Self-Improvement" \
    | grep -qF 'except in a `/megatask` per-issue run' \
    || fail "$SKILL_DOC § Post-Worktask Self-Improvement does not skip under /megatask"
}

@test "EnterWorktree: never called by the per-issue run or its DV stage" {
  section "$MEGATASK_DOC" "$ENV_HEAD" | grep -qF 'Never call `EnterWorktree`' \
    || fail "megatask's run environment no longer forbids EnterWorktree"
  section "$PER_ISSUE_DOC" "### Per-issue run — what changes" \
    | grep -E '^\| `EnterWorktree` \|' | grep -qF 'Never called' \
    || fail "the per-issue table no longer forbids EnterWorktree"
  section "$SKILL_DOC" "##### Step 4.8 — isolation banner" | tr '\n' ' ' \
    | grep -qE 'megatask_group[^:]*\? *`WORKTREE ISOLATION: WORKSPACE_ROOT is already an isolated worktree\. Never call ` *\+ *`EnterWorktree' \
    || fail "the DV isolation banner has no /megatask arm forbidding EnterWorktree"
}

# --- hooks bind to the issue from their payload ------------------------------------------------

# issue <n> — a second per-issue worktree beside the setup's #41, seeded and stamped.
issue() {
  local wt="$ROOT/.worktrees/milestone-9/$1"
  mkdir -p "$wt/.context"
  printf '{"version":2,"run_index":0,"tasks":{"PL0":{"status":"in_progress","metadata":{}}}}\n' \
    > "$wt/.context/state.json"
  printf '{"version":"2.0","isolation":"worktree","execution":{"status":"in_progress"}}\n' \
    > "$wt/workspace.json"
  printf '%s' "$wt"
}

# transcript <wt> — a stage agent's transcript whose dispatch prompt carries the brief's
# `WORKSPACE_ROOT=` banner line, as `/worktask` composes it.
transcript() {
  local t
  t="$(mk_tmpworkdir)/agent.jsonl"
  jq -cn --arg c "[7] suffix
WORKSPACE_ROOT=$1
Run the PL stage." '{type:"user",message:{role:"user",content:[{type:"text",text:$c}]}}' > "$t"
  printf '%s' "$t"
}

# hook <script> <payload> [args…] — run as Claude Code runs it: megatask's cwd and
# CLAUDE_PROJECT_DIR, no WORKSPACE_ROOT, the payload on stdin. Background-safe.
hook() {
  local script="$1" payload="$2"
  shift 2
  (cd "$ROOT" && printf '%s' "$payload" \
    | env -u WORKSPACE_ROOT -u MILESTONE_MODE -u CONTEXT_DIR -u _CORPFLOW_ISSUE_ROOT \
      CLAUDE_PROJECT_DIR="$ROOT" bash "$PLUGIN_ROOT/hooks/$script" "$@")
}

stop_payload() {  # stop_payload <agent_id> <cwd> [agent_transcript_path]
  jq -cn --arg a "$1" --arg c "$2" --arg t "${3:-}" '{hook_event_name:"SubagentStop",
    session_id:"sess_mt", agent_id:$a, agent_type:"corpflow:product-manager", cwd:$c}
    + (if $t == "" then {} else {agent_transcript_path:$t} end)'
}

@test "hooks: two concurrent issues each audit into their own log, from the payload cwd" {
  local wt42
  wt42="$(issue 42)"
  printf '{"version":2,"run_index":0,"tasks":{"PL0":{"status":"in_progress","metadata":{}}}}\n' \
    > "$WT/.context/state.json"
  hook agent-stop.sh "$(stop_payload agt_41 "$WT")" --stage PL &
  hook agent-stop.sh "$(stop_payload agt_42 "$wt42")" --stage PL &
  wait
  run jq -r '.metadata.dedupe_key' "$WT/.context/logs/audit.jsonl"
  assert_output "sess_mt:agt_41:stage:PL"
  run jq -r '.metadata.dedupe_key' "$wt42/.context/logs/audit.jsonl"
  assert_output "sess_mt:agt_42:stage:PL"
  [ ! -e "$ROOT/.context/logs/audit.jsonl" ] || fail "the batch log received an issue's row"
}

@test "hooks: a batch-rooted cwd binds through the agent's WORKSPACE_ROOT= banner, concurrently" {
  local wt42 t41 t42
  wt42="$(issue 42)"
  printf '{"version":2,"run_index":0,"tasks":{"PL0":{"status":"in_progress","metadata":{}}}}\n' \
    > "$WT/.context/state.json"
  t41="$(transcript "$WT")"
  t42="$(transcript "$wt42")"
  hook agent-stop.sh "$(stop_payload agt_41 "$ROOT" "$t41")" --stage PL &
  hook agent-stop.sh "$(stop_payload agt_42 "$ROOT" "$t42")" --stage PL &
  hook audit-subagent.sh "$(stop_payload agt_41 "$ROOT" "$t41")" &
  hook audit-subagent.sh "$(stop_payload agt_42 "$ROOT" "$t42")" &
  wait
  run jq -rs '[.[] | select(.action == "stage_completion_hook") | .metadata.dedupe_key] | join(",")' \
    "$WT/.context/logs/audit.jsonl"
  assert_output "sess_mt:agt_41:stage:PL"
  run jq -rs '[.[] | select(.action == "stage_completion_hook") | .metadata.dedupe_key] | join(",")' \
    "$wt42/.context/logs/audit.jsonl"
  assert_output "sess_mt:agt_42:stage:PL"
  run grep -c '"hook:audit-subagent"' "$WT/.context/logs/audit.jsonl" "$wt42/.context/logs/audit.jsonl"
  assert_line --partial "41/.context/logs/audit.jsonl:1"
  assert_line --partial "42/.context/logs/audit.jsonl:1"
  [ ! -e "$ROOT/.context/logs/audit.jsonl" ] || fail "the batch log received an issue's row"
}

@test "hooks: state-merge and dv-screenshot-gate resolve the issue ledger, not the batch's" {
  local t41
  printf '{"version":2,"run_index":0,"tasks":{"PL0":{"status":"in_progress","metadata":{}}}}\n' \
    > "$WT/.context/state.json"
  t41="$(transcript "$WT")"
  CLAUDE_TASK_METADATA_STAGE=PL hook state-merge.sh "$(stop_payload agt_41 "$ROOT" "$t41")"
  run grep -rl 'no artifact resolved (stage=PL' "$WT/.context/logs"
  assert_success
  [ ! -e "$ROOT/.context/logs/state-merge.log" ] || fail "the batch received the issue's state-merge log"
  # Unparseable issue ledger, valid batch ledger: only a gate reading the issue's blocks.
  printf '{not json' > "$WT/.context/state.json"
  run hook dv-screenshot-gate.sh "$(jq -cn --arg t "$t41" --arg c "$ROOT" \
    '{agent_id:"agt_dv41", agent_type:"corpflow:developer", session_id:"sess_mt", cwd:$c, agent_transcript_path:$t}')"
  assert_output --partial "gate_unresolved"
  run jq -r 'select(.action == "screenshot_gate_block") | .metadata.block_kind' "$WT/.context/logs/audit.jsonl"
  assert_output "gate_unresolved"
  [ ! -e "$ROOT/.context/logs/audit.jsonl" ] || fail "the batch log received an issue's row"
  cmp -s "$ROOT/.context/state.json" "$ROOT/state.before" || fail "megatask's ledger changed"
}

@test "hooks: a parent with no ledger still audits the issue instead of skipping it" {
  printf '{"version":2,"run_index":0,"tasks":{"PL0":{"status":"in_progress","metadata":{}}}}\n' \
    > "$WT/.context/state.json"
  rm -rf "$ROOT/.context"
  hook agent-stop.sh "$(stop_payload agt_41 "$ROOT" "$(transcript "$WT")")" --stage PL
  run jq -r '.metadata.dedupe_key' "$WT/.context/logs/audit.jsonl"
  assert_output "sess_mt:agt_41:stage:PL"
  [ ! -e "$ROOT/.context" ] || fail "a hook created the batch's .context/"
}

@test "hooks: an ordinary worktask, with no per-issue worktree, resolves exactly as before" {
  local plain t
  plain="$(mk_tmpworkdir)"
  mkdir -p "$plain/.context"
  printf '{"version":2,"run_index":0,"tasks":{}}\n' > "$plain/.context/state.json"
  t="$(transcript "$plain")"
  (cd "$plain" && stop_payload agt_plain "$plain" "$t" \
    | env -u WORKSPACE_ROOT -u CONTEXT_DIR CLAUDE_PROJECT_DIR="$plain" \
      bash "$PLUGIN_ROOT/hooks/agent-stop.sh" --stage PL)
  run jq -r '.metadata.dedupe_key' "$plain/.context/logs/audit.jsonl"
  assert_output "sess_mt:agt_plain:stage:PL"
  # A .worktrees/<group>/<n> tree that megatask never stamped is not an issue: no workspace.json.
  rm -f "$WT/workspace.json"
  printf '{"version":2,"run_index":0,"tasks":{}}\n' > "$WT/.context/state.json"
  hook agent-stop.sh "$(stop_payload agt_unstamped "$WT" "$(transcript "$WT")")" --stage PL
  run jq -r '.metadata.dedupe_key' "$ROOT/.context/logs/audit.jsonl"
  assert_output "sess_mt:agt_unstamped:stage:PL"
  [ ! -e "$WT/.context/logs/audit.jsonl" ] || fail "an unstamped tree bound as an issue"
}

@test "hooks: test-execution-gate binds from the per-issue prefix when the session cwd is another issue" {
  local wt42 prefix gate_in_41
  wt42="$(issue 42)"
  printf '{"version":2,"run_index":0,"tasks":{"QA0":{"status":"in_progress","metadata":{}}}}\n' \
    > "$wt42/.context/state.json"
  printf '{"version":2,"run_index":0,"tasks":{"PL0":{"status":"completed","metadata":{}},"QA0":{"status":"completed","metadata":{}}}}\n' \
    > "$WT/.context/state.json"
  prefix="$(doc_prefix)"
  [ -n "$prefix" ] || fail "megatask Step 3 no longer states the Bash prefix"
  # gate_in_41 <command> — PreToolUse Bash as Claude Code runs it from a session sitting in #41.
  gate_in_41() {
    jq -cn --arg c "$WT" --arg x "$1" '{hook_event_name:"PreToolUse", tool_name:"Bash",
      tool_input:{command:$x}, cwd:$c, session_id:"sess_mt"}' \
      | (cd "$WT" && env -u WORKSPACE_ROOT -u MILESTONE_MODE -u CONTEXT_DIR -u _CORPFLOW_ISSUE_ROOT \
        CLAUDE_PROJECT_DIR="$ROOT" bash "$PLUGIN_ROOT/hooks/test-execution-gate.sh")
  }
  # Anti-vacuity: unbound, this fixture is the reported denial.
  run gate_in_41 "bats x.bats"
  assert_output --partial "No stage is in progress"
  rm -rf "$WT/.context/logs" "$ROOT/.context/logs"
  run gate_in_41 "${prefix//<wt>/$wt42} bats x.bats"
  assert_success
  refute_output --partial "No stage is in progress"
  [ ! -e "$WT/.context/logs/audit.jsonl" ] || fail "the session's issue ledger received a row"
  [ ! -e "$ROOT/.context/logs/audit.jsonl" ] || fail "the batch log received a row"
}

@test "doc: megatask's run environment opens the prompt with the WORKSPACE_ROOT=<wt> banner" {
  section "$MEGATASK_DOC" "$ENV_HEAD" | grep -qF 'Open the prompt with the line `WORKSPACE_ROOT=<wt>`' \
    || fail "megatask Step 3 no longer tells the per-issue prompt to carry the hook binding banner"
  section "$MEGATASK_DOC" "#### Step 3 — how hooks find the issue" | grep -qF 'corpflow_bind_payload' \
    || fail "megatask no longer names the hook-side binding"
  section "$PER_ISSUE_DOC" "$PER_ISSUE_HEAD" | tr '\n' ' ' | grep -qF 'Hooks never see that export' \
    || fail "worktask's per-issue section no longer says hooks bind from the banner"
}
