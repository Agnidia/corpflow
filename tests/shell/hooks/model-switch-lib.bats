#!/usr/bin/env bats
# Tests for hooks/model-switch-lib.sh — the sourced-only library shared by the
# PreModelSwitch gate and the PostModelSwitch observer.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

LIB="hooks/model-switch-lib.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context"
}

# Ledger with one in_progress stage and one launched, pinned dispatch row.
_ledger() {
  printf '%s' '{"version":1,"worktask_id":"wt-ms",
    "tasks":{"DV0":{"status":"in_progress"}},
    "facts":{"dispatched_agents":[
      {"stage":"DV","task_id":"DV0","subagent_type":"corpflow:developer",
       "agent_id":"agt_dv","model_requested":"opus","status":"launched"}]}}' \
    > "$WD/.context/state.json"
}

# --- corpflow_context_root ----------------------------------------------------

@test "context_root: WORKSPACE_ROOT wins when it holds a ledger" {
  _ledger
  run_script_env --cwd "$WD" --env "WORKSPACE_ROOT=$WD" --env "CLAUDE_PROJECT_DIR=/nonexistent" \
    --source "$LIB" corpflow_context_root
  assert_success
  assert_output "$WD/.context"
}

@test "context_root: CLAUDE_PROJECT_DIR is used when WORKSPACE_ROOT is unset" {
  _ledger
  run_script_env --cwd "$WD" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$WD" \
    --source "$LIB" corpflow_context_root
  assert_success
  assert_output "$WD/.context"
}

@test "context_root: a declared dir with no .context and no git above it is unresolved, not invented" {
  # No rank 3/4 hit (declared dir has no .context/), no rank 5/6 hit (no git repo
  # above cwd at all): the ladder answers empty rather than inventing
  # "$sub/.context" from a bare pwd/CLAUDE_PROJECT_DIR guess.
  local main sub
  main="$(mk_tmpworkdir)"
  mkdir -p "$main/.context"
  sub="$main/sub"
  mkdir -p "$sub"
  run_script_env --cwd "$sub" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$sub" \
    --env "GIT_CEILING_DIRECTORIES=$sub" \
    --source "$LIB" corpflow_context_root
  assert_success
  assert_output ""
}

@test "context_root: rank 6 lends the main ledger to a linked worktree only when it owns that tree" {
  local repo wt want
  repo="$(mk_git_fixture --file 'a.txt:hi' --commit 'init')"
  mkdir -p "$repo/.context"
  printf '{"tasks":{"DV0":{"status":"completed","metadata":{}}}}' > "$repo/.context/state.json"
  wt="$repo/wt"
  git -C "$repo" -c user.name=t -c user.email=t@t worktree add -q -b wt-branch "$wt" 2>/dev/null \
    || skip "git worktree unavailable"
  # resolve-root.sh resolves through `cd && pwd -P`, so compare physical paths: on
  # macOS $TMPDIR is itself a symlink and a literal comparison would fail on that alone.
  want="$(cd "$repo" && pwd -P)/.context"

  # An unrelated worktree of the repo: the main checkout's ledger is not its ledger.
  run_script_env --cwd "$wt" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR \
    --source "$LIB" corpflow_context_root
  assert_success
  assert_output ""
  run_script_env --cwd "$wt" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$wt" \
    --source "$LIB" corpflow_context_root
  assert_success
  assert_output ""

  # The session is the main checkout itself (rank 4 answers it as given, so compare physically).
  run_script_env --cwd "$wt" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$repo" \
    --source "$LIB" corpflow_context_root
  assert_success
  [ "$(cd "$output" && pwd -P)" = "$want" ]

  # The worktree is a registered stage worktree (logical path recorded, physical compared).
  jq --arg w "$wt" '.tasks.DV0.metadata.workspace_path = $w' "$repo/.context/state.json" > "$repo/st.new"
  mv "$repo/st.new" "$repo/.context/state.json"
  run_script_env --cwd "$wt" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$wt" \
    --source "$LIB" corpflow_context_root
  assert_success
  [ "$output" = "$want" ]
}

@test "context_root: rank 6 (resolve-root.sh) with no .context at the resolved root is unresolved" {
  # AD-6 rank 6 requires an existing ledger; a bare git root with no .context/
  # must not be handed back as if it were one.
  local repo wt
  repo="$(mk_git_fixture --file 'a.txt:hi' --commit 'init')"
  wt="$repo/wt"
  git -C "$repo" -c user.name=t -c user.email=t@t worktree add -q -b wt-branch "$wt" 2>/dev/null \
    || skip "git worktree unavailable"
  run_script_env --cwd "$wt" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR \
    --source "$LIB" corpflow_context_root
  assert_success
  assert_output ""
}

@test "workspace_root: rank 5 (toplevel/.context/state.json file) outranks rank 6" {
  local repo
  repo="$(mk_git_fixture --file 'a.txt:hi' --commit 'init')"
  mkdir -p "$repo/.context"
  printf '{}' > "$repo/.context/state.json"
  run_script_env --cwd "$repo" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR \
    --source "$LIB" corpflow_workspace_root
  assert_success
  local want
  want="$(cd "$repo" && pwd -P)"
  [ "$output" = "$want" ]
}

@test "workspace_root: no declared root and no git repo above cwd is unresolved" {
  local outside
  outside="$(mk_tmpworkdir)"
  run_script_env --cwd "$outside" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR \
    --env "GIT_CEILING_DIRECTORIES=$outside" \
    --source "$LIB" corpflow_workspace_root
  assert_success
  assert_output ""
  run_script_env --cwd "$outside" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR \
    --env "GIT_CEILING_DIRECTORIES=$outside" \
    --source "$LIB" corpflow_context_root
  assert_success
  assert_output ""
}

# --- corpflow_active_stage ----------------------------------------------------

@test "active_stage: a single in_progress stage resolves to its code" {
  _ledger
  run_script_env --cwd "$WD" --source "$LIB" corpflow_active_stage "$WD/.context"
  assert_success
  assert_output "DV"
}

@test "active_stage: two distinct in_progress stages resolve to empty (never a guess)" {
  printf '%s' '{"tasks":{"DV0":{"status":"in_progress"},"QA0":{"status":"in_progress"}}}' \
    > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_active_stage "$WD/.context"
  assert_success
  assert_output ""
}

@test "active_stage: parallel tracks of ONE stage still resolve (DV0+DV1 -> DV)" {
  printf '%s' '{"tasks":{"DV0":{"status":"in_progress"},"DV1":{"status":"in_progress"}}}' \
    > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_active_stage "$WD/.context"
  assert_success
  assert_output "DV"
}

@test "active_stage: absent state.json resolves to empty" {
  run_script_env --cwd "$WD" --source "$LIB" corpflow_active_stage "$WD/.context"
  assert_success
  assert_output ""
}

# --- corpflow_resolve_pin -----------------------------------------------------

@test "resolve_pin: exact agent_id match yields the pin and task id" {
  _ledger
  run_script_env --cwd "$WD" --source "$LIB" corpflow_resolve_pin "$WD/.context" DV agt_dv
  assert_success
  assert_output "opus DV0"
}

@test "resolve_pin: degrades to the single launched row when agent_id is absent" {
  _ledger
  run_script_env --cwd "$WD" --source "$LIB" corpflow_resolve_pin "$WD/.context" DV ""
  assert_success
  assert_output "opus DV0"
}

@test "resolve_pin: two launched rows for one stage are ambiguous -> empty" {
  printf '%s' '{"tasks":{"DV0":{"status":"in_progress"}},
    "facts":{"dispatched_agents":[
      {"stage":"DV","task_id":"DV0","subagent_type":"x","model_requested":"opus","status":"launched"},
      {"stage":"DV","task_id":"DV1","subagent_type":"x","model_requested":"sonnet","status":"launched"}]}}' \
    > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_resolve_pin "$WD/.context" DV ""
  assert_success
  assert_output ""
}

@test "resolve_pin: a row carrying no model_requested carries no pin" {
  printf '%s' '{"tasks":{"DV0":{"status":"in_progress"}},
    "facts":{"dispatched_agents":[
      {"stage":"DV","task_id":"DV0","subagent_type":"x","status":"launched"}]}}' \
    > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_resolve_pin "$WD/.context" DV ""
  assert_success
  assert_output ""
}

@test "resolve_pin: a completed row is not a live pin" {
  printf '%s' '{"tasks":{"DV0":{"status":"in_progress"}},
    "facts":{"dispatched_agents":[
      {"stage":"DV","task_id":"DV0","subagent_type":"x","model_requested":"opus","status":"completed"}]}}' \
    > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_resolve_pin "$WD/.context" DV ""
  assert_success
  assert_output ""
}

@test "resolve_pin: a completed row asked by agent_id is not a live pin" {
  printf '%s' '{"tasks":{"DV0":{"status":"completed"}},
    "facts":{"dispatched_agents":[
      {"stage":"DV","task_id":"DV0","subagent_type":"x","agent_id":"agt_dv",
       "model_requested":"opus","status":"completed"}]}}' \
    > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_resolve_pin "$WD/.context" DV agt_dv
  assert_success
  assert_output ""
}

@test "resolve_pin: a failed row asked by agent_id is not a live pin" {
  printf '%s' '{"tasks":{"DV0":{"status":"in_progress"}},
    "facts":{"dispatched_agents":[
      {"stage":"DV","task_id":"DV0","subagent_type":"x","agent_id":"agt_dv",
       "model_requested":"opus","status":"failed"}]}}' \
    > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_resolve_pin "$WD/.context" DV agt_dv
  assert_success
  assert_output ""
}

@test "resolve_pin: a retry pair under one agent_id resolves the launched leg only" {
  # A retried stage leaves both legs in the ledger under the same agent id; only the
  # live one is a pin, and two matches would otherwise read as ambiguous and yield none.
  printf '%s' '{"tasks":{"DV0":{"status":"in_progress"}},
    "facts":{"dispatched_agents":[
      {"stage":"DV","task_id":"DV0","subagent_type":"x","agent_id":"agt_dv",
       "model_requested":"sonnet","status":"failed"},
      {"stage":"DV","task_id":"DV0","subagent_type":"x","agent_id":"agt_dv",
       "model_requested":"opus","status":"launched"}]}}' \
    > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_resolve_pin "$WD/.context" DV agt_dv
  assert_success
  assert_output "opus DV0"
}

# --- corpflow_model_family ----------------------------------------------------
# ANTI-VACUITY PAIR: the matcher must collapse alias-vs-resolved-id onto one
# family AND still separate genuinely different tiers. A matcher that always
# returned the same value, or always empty, fails one of these two.

@test "model_family: ANTI-VACUITY — alias and resolved id collapse to one family" {
  run_script_env --cwd "$WD" --source "$LIB" corpflow_model_family "opus"
  assert_output "opus"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_model_family "claude-opus-5-5"
  assert_output "opus"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_model_family "OPUS"
  assert_output "opus"
}

@test "model_family: ANTI-VACUITY — different tiers stay different" {
  run_script_env --cwd "$WD" --source "$LIB" corpflow_model_family "claude-sonnet-5-5"
  assert_output "sonnet"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_model_family "haiku"
  assert_output "haiku"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_model_family "claude-fable-5"
  assert_output "fable"
}

@test "model_family: an unrecognized string is empty, not a family" {
  run_script_env --cwd "$WD" --source "$LIB" corpflow_model_family "gpt-9"
  assert_success
  assert_output ""
  run_script_env --cwd "$WD" --source "$LIB" corpflow_model_family ""
  assert_success
  assert_output ""
}

@test "contract: the library refuses to be executed directly" {
  run bash "$PLUGIN_ROOT/$LIB"
  [ "$status" -eq 2 ]
  assert_output --partial "source it, do not execute it directly"
}

# --- corpflow_workspace_root: every rank demands a ledger ---------------------

@test "workspace_root: a declared root holding state.json resolves" {
  _ledger
  run_script_env --cwd "$WD" --env "WORKSPACE_ROOT=$WD" --env "CLAUDE_PROJECT_DIR=/nonexistent" \
    --source "$LIB" corpflow_workspace_root
  assert_success
  assert_output "$WD"
}

@test "workspace_root: ANTI-VACUITY — a bare .context folder resolves at no rank" {
  # A folder alone is what a stray mkdir leaves behind; answering it kept hooks
  # writing into checkouts nobody seeded. Declared ranks and the git ranks all miss.
  local bare repo
  bare="$(mk_tmpworkdir)"
  mkdir -p "$bare/.context"
  run_script_env --cwd "$bare" --env "WORKSPACE_ROOT=$bare" --env "CLAUDE_PROJECT_DIR=$bare" \
    --env "GIT_CEILING_DIRECTORIES=$bare" --source "$LIB" corpflow_workspace_root
  assert_success
  assert_output ""

  repo="$(mk_git_fixture --file 'a.txt:hi' --commit 'init')"
  mkdir -p "$repo/.context"
  run_script_env --cwd "$repo" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR \
    --source "$LIB" corpflow_workspace_root
  assert_success
  assert_output ""
}

@test "workspace_root: no argument revives a write tail for an unseeded declared root" {
  local bare elsewhere m
  bare="$(mk_tmpworkdir)"
  elsewhere="$(mk_tmpworkdir)"
  for m in write read nonsense; do
    run_script_env --cwd "$elsewhere" --env "WORKSPACE_ROOT=$bare" --unset CLAUDE_PROJECT_DIR \
      --env "GIT_CEILING_DIRECTORIES=$elsewhere" --source "$LIB" corpflow_workspace_root "$m"
    assert_success
    assert_output ""
  done
}

@test "workspace_root: a linked worktree's own ledger wins over a main checkout without one" {
  local repo wt
  repo="$(mk_git_fixture --file 'a.txt:hi' --commit 'init')"
  wt="$repo/wt"
  git -C "$repo" -c user.name=t -c user.email=t@t worktree add -q -b wt-branch "$wt" 2>/dev/null \
    || skip "git worktree unavailable"
  mkdir -p "$wt/.context"
  printf '{}' > "$wt/.context/state.json"
  run_script_env --cwd "$wt" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR \
    --source "$LIB" corpflow_workspace_root
  assert_success
  [ "$output" = "$(cd "$wt" && pwd -P)" ]
}

# --- corpflow_bind_payload: per-issue binding stays inside a declared root ----

# _issue_tree <base> <group> <n> — a stamped per-issue worktree with its own ledger.
_issue_tree() {
  mkdir -p "$1/.worktrees/$2/$3/.context"
  printf '{}' > "$1/.worktrees/$2/$3/.context/state.json"
  printf '{}' > "$1/.worktrees/$2/$3/workspace.json"
}

# _bind <payload> — binds in a CLAUDE_PROJECT_DIR=$WD session, then resolves.
_bind() {
  run env -u WORKSPACE_ROOT -u _CORPFLOW_ISSUE_ROOT CLAUDE_PROJECT_DIR="$WD" bash -c \
    "cd '$WD' && . '$PLUGIN_ROOT/$LIB' && corpflow_bind_payload \"\$1\" && corpflow_workspace_root" _ "$1"
}

@test "bind_payload: a payload cwd inside a stamped issue tree outranks CLAUDE_PROJECT_DIR" {
  _ledger
  _issue_tree "$WD" g 7
  mkdir -p "$WD/.worktrees/g/7/src"
  _bind "$(jq -cn --arg c "$WD/.worktrees/g/7/src" '{cwd:$c}')"
  assert_success
  [ "$output" = "$(cd "$WD/.worktrees/g/7" && pwd -P)" ]
}

@test "bind_payload: an issue-shaped tree outside every declared root never binds" {
  # The banner is prompt text; pointing it at a foreign tree must not move the hook there.
  local foreign t
  _ledger
  foreign="$(mk_tmpworkdir)"
  _issue_tree "$foreign" g 7
  t="$WD/t.jsonl"
  jq -cn --arg c "WORKSPACE_ROOT=$foreign/.worktrees/g/7" '{type:"user",message:{content:$c}}' > "$t"
  mkdir -p "$WD/.worktrees"
  _bind "$(jq -cn --arg c "$foreign/.worktrees/g/7" --arg t "$t" '{cwd:$c, agent_transcript_path:$t}')"
  assert_success
  assert_output "$WD"
}

@test "bind_payload: a non-numeric issue segment or a missing workspace.json never binds" {
  _ledger
  _issue_tree "$WD" g notanissue
  _issue_tree "$WD" g 8
  rm -f "$WD/.worktrees/g/8/workspace.json"
  _bind "$(jq -cn --arg c "$WD/.worktrees/g/notanissue" '{cwd:$c}')"
  assert_output "$WD"
  _bind "$(jq -cn --arg c "$WD/.worktrees/g/8" '{cwd:$c}')"
  assert_output "$WD"
}

# _bind_in <hook cwd> <payload> — _bind with the hook process itself inside <hook cwd>.
_bind_in() {
  run env -u WORKSPACE_ROOT -u _CORPFLOW_ISSUE_ROOT CLAUDE_PROJECT_DIR="$WD" bash -c \
    "cd \"\$2\" && . '$PLUGIN_ROOT/$LIB' && corpflow_bind_payload \"\$1\" && corpflow_workspace_root" _ "$2" "$1"
}

# _banner <wt> — a transcript whose first user record carries the stage brief's banner line.
_banner() {
  jq -cn --arg c "[3] brief
WORKSPACE_ROOT=$1
Run the stage." '{type:"user",message:{role:"user",content:[{type:"text",text:$c}]}}' > "$WD/agent.jsonl"
  printf '%s' "$WD/agent.jsonl"
}

# Session cwd in worktree A (g/1), the agent's issue is worktree B (g/2).
_ab_trees() {
  _ledger
  _issue_tree "$WD" g 1
  _issue_tree "$WD" g 2
  A="$WD/.worktrees/g/1"
  B="$WD/.worktrees/g/2"
  B_PHYS="$(cd "$B" && pwd -P)"
}

@test "bind_payload: a session cwd in worktree A yields to the banner naming worktree B" {
  _ab_trees
  _bind_in "$A" "$(jq -cn --arg c "$A" --arg t "$(_banner "$B")" '{cwd:$c, agent_transcript_path:$t}')"
  assert_success
  assert_output "$B_PHYS"
}

@test "bind_payload: a tool event's transcript_path banner outranks a cwd in another issue" {
  _ab_trees
  _bind_in "$A" "$(jq -cn --arg c "$A" --arg t "$(_banner "$B")" \
    '{tool_name:"Bash", tool_input:{command:"true"}, cwd:$c, transcript_path:$t}')"
  assert_success
  assert_output "$B_PHYS"
}

@test "bind_payload: the command export names the issue when no banner is readable" {
  local cmd
  _ab_trees
  for cmd in "cd \"$B\" && export WORKSPACE_ROOT=\"$B\" MILESTONE_MODE=1 && bats x.bats" \
    "WORKSPACE_ROOT=$B bats x.bats" \
    "cd '$B' && export WORKSPACE_ROOT='$B' && bats x.bats"; do
    _bind_in "$A" "$(jq -cn --arg c "$A" --arg x "$cmd" '{tool_name:"Bash", tool_input:{command:$x}, cwd:$c}')"
    assert_success
    assert_output "$B_PHYS"
  done
}

@test "bind_payload: the banner wins when the command export names a different issue" {
  _ab_trees
  _issue_tree "$WD" g 3
  _bind_in "$A" "$(jq -cn --arg c "$A" --arg t "$(_banner "$B")" --arg x "export WORKSPACE_ROOT=\"$WD/.worktrees/g/3\" && bats x.bats" \
    '{tool_name:"Bash", tool_input:{command:$x}, cwd:$c, transcript_path:$t}')"
  assert_success
  assert_output "$B_PHYS"
}

@test "bind_payload: an invalid banner falls through to a valid command export" {
  local foreign t
  _ab_trees
  foreign="$(mk_tmpworkdir)"
  _issue_tree "$foreign" g 2
  for t in "$foreign/.worktrees/g/2" "$WD/.worktrees/g/9"; do
    _bind_in "$A" "$(jq -cn --arg c "$A" --arg t "$(_banner "$t")" --arg x "export WORKSPACE_ROOT=\"$B\" && bats x.bats" \
      '{tool_name:"Bash", tool_input:{command:$x}, cwd:$c, transcript_path:$t}')"
    assert_success
    assert_output "$B_PHYS"
  done
}

@test "bind_payload: a command export with expansion syntax or a foreign path falls through to the cwd" {
  local foreign cmd sentinel="$WD/sentinel"
  _ab_trees
  foreign="$(mk_tmpworkdir)"
  _issue_tree "$foreign" g 2
  for cmd in "export WORKSPACE_ROOT=\"\$(touch $sentinel)\" && bats x.bats" \
    "WORKSPACE_ROOT=\$(touch $sentinel) bats x.bats" \
    "export WORKSPACE_ROOT=\"$B\$(touch $sentinel)\" && bats x.bats" \
    "export WORKSPACE_ROOT=\"$foreign/.worktrees/g/2\" && bats x.bats" \
    "echo WORKSPACE_ROOT=$B"; do
    _bind_in "$WD" "$(jq -cn --arg c "$A" --arg x "$cmd" '{tool_name:"Bash", tool_input:{command:$x}, cwd:$c}')"
    assert_success
    assert_output "$(cd "$A" && pwd -P)"
  done
  [ ! -e "$sentinel" ] || fail "a command export value was executed"
}

@test "bind_payload: an inherited _CORPFLOW_ISSUE_ROOT is not a global override" {
  _ledger
  _issue_tree "$WD" g 9
  run_script_env --cwd "$WD" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$WD" \
    --env "_CORPFLOW_ISSUE_ROOT=$WD/.worktrees/g/9" --source "$LIB" corpflow_workspace_root
  assert_success
  assert_output "$WD"
}

# --- corpflow_first_user_text: the one transcript read ---------------------------

@test "first_user_text: string and array content of the first user record, and empty on a miss" {
  local t="$WD/t.jsonl"
  { jq -cn '{type:"system",content:"x"}'
    jq -cn '{type:"user",message:{content:"line one\nstage: QA"}}'
    jq -cn '{type:"user",message:{content:"second"}}'; } > "$t"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_first_user_text "$t"
  assert_success
  assert_output "$(printf 'line one\nstage: QA')"

  jq -cn '{type:"user",message:{content:[{type:"text",text:"a"},{type:"image"},{type:"text",text:"b"}]}}' > "$t"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_first_user_text "$t"
  assert_output "$(printf 'a\nb')"

  run_script_env --cwd "$WD" --source "$LIB" corpflow_first_user_text "$WD/missing.jsonl"
  assert_success
  assert_output ""

  # Only the first 40 lines are read: a brief sits at the head of a transcript.
  for _ in $(seq 1 40); do jq -cn '{type:"system"}'; done > "$t"
  jq -cn '{type:"user",message:{content:"late"}}' >> "$t"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_first_user_text "$t"
  assert_success
  assert_output ""
}

# --- corpflow_switch_fields ---------------------------------------------------

@test "switch_fields: a parseable payload yields agent_id, dest, origin, trigger" {
  run_script_env --cwd "$WD" --source "$LIB" corpflow_switch_fields \
    '{"agent_id":"a1","newModel":"sonnet","current_model":"opus","source":"user_ask"}'
  assert_success
  assert_output "$(printf 'a1\tsonnet\topus\tuser_ask')"
}

@test "switch_fields: unparseable is EMPTY, all-fields-absent is three tabs" {
  # The two must stay distinguishable: callers fold their JSON-validity probe into
  # this call, and collapsing them would make a malformed payload look like a
  # payload whose schema simply drifted.
  run_script_env --cwd "$WD" --source "$LIB" corpflow_switch_fields 'not json {{{'
  assert_success
  assert_output ""

  run_script_env --cwd "$WD" --source "$LIB" corpflow_switch_fields '{"session_id":"s"}'
  assert_success
  assert_output "$(printf '\t\t\t')"
}

@test "switch_fields: a tab inside a payload value cannot invent a field" {
  # Untrusted payload data. @tsv escapes the tab rather than letting it split.
  run_script_env --cwd "$WD" --source "$LIB" corpflow_switch_fields \
    '{"agent_id":"a\tb","to_model":"sonnet"}'
  assert_success
  [ "$(printf '%s' "$output" | tr -cd '\t' | wc -c | tr -d ' ')" = "3" ]
}

@test "switch_fields: ANTI-VACUITY — it agrees with the per-field accessors" {
  # One coalesce expression, three readers. If the combined reader ever drifts
  # from corpflow_switch_dest/_origin the hooks' decisions and their audit rows
  # start describing different payloads.
  local p='{"agent_id":"a1","requestedModel":"haiku","fromModel":"opus"}'
  run_script_env --cwd "$WD" --source "$LIB" corpflow_switch_fields "$p"
  local combined="$output"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_switch_dest "$p"
  local d="$output"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_switch_origin "$p"
  local o="$output"
  [ "$combined" = "$(printf 'a1\t%s\t%s\t' "$d" "$o")" ]
}

# --- corpflow_stage_and_pin ---------------------------------------------------

@test "stage_and_pin: ANTI-VACUITY — parity with the two functions it combines" {
  # The combined query exists to save a jq process, never to answer differently.
  _ledger
  run_script_env --cwd "$WD" --source "$LIB" corpflow_active_stage "$WD/.context"
  local stage="$output"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_resolve_pin "$WD/.context" "$stage" "agt_dv"
  local pin_pair="$output"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_stage_and_pin "$WD/.context" "agt_dv"
  assert_success
  assert_output "$(printf '%s\t%s\t%s' "$stage" "${pin_pair%% *}" "${pin_pair##* }")"
}

@test "stage_and_pin: a stage with no resolvable pin still reports the stage" {
  printf '%s' '{"tasks":{"QA0":{"status":"in_progress"}},"facts":{"dispatched_agents":[]}}' \
    > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_stage_and_pin "$WD/.context" ""
  assert_success
  assert_output "$(printf 'QA\t\t')"
}

@test "stage_and_pin: two distinct in_progress stages resolve to no stage AND no pin" {
  printf '%s' '{"tasks":{"DV0":{"status":"in_progress"},"QA0":{"status":"in_progress"}},
    "facts":{"dispatched_agents":[{"stage":"DV","task_id":"DV0","agent_id":"agt_dv",
      "model_requested":"opus","status":"launched"}]}}' > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_stage_and_pin "$WD/.context" "agt_dv"
  assert_success
  assert_output "$(printf '\t\t')"
}

@test "stage_and_pin: absent state.json is empty, not a shape" {
  run_script_env --cwd "$WD" --source "$LIB" corpflow_stage_and_pin "$WD/.context" ""
  assert_success
  assert_output ""
}

# --- corpflow_hook_audit_row -------------------------------------------------------

_row_of() { tail -n 1 "$WD/.context/logs/audit.jsonl"; }

@test "audit_row: key order is ts, actor, action, subject, result, task_id, metadata" {
  # Pinned with keys_unsorted: jq's default sort would silently reorder every row.
  run_script_env --cwd "$WD" --source "$LIB" corpflow_hook_audit_row \
    --ctx "$WD/.context" --actor hook:model-switch-gate --action model_switch_blocked \
    --result block --subject DV0 --task-id DV0 --meta '{"k":1}'
  assert_success
  [ "$(_row_of | jq -r 'keys_unsorted | join(",")')" = "ts,actor,action,subject,result,task_id,metadata" ]
}

@test "audit_row: a missing or empty subject or task_id writes nothing, once, survivably" {
  local c want args
  for c in "subject|--task-id DV0" "task_id|--subject DV0" "subject|--subject '' --task-id DV0" \
    "task_id|--subject DV0 --task-id ''"; do
    want="${c%%|*}"
    args="${c#*|}"
    rm -rf "$WD/.context/logs"
    run bash -c "set -euo pipefail; . '$PLUGIN_ROOT/$LIB'
      corpflow_hook_audit_row --ctx '$WD/.context' --actor hook:state-merge --action state_merge_noop \
        --result skipped --meta '{}' $args 2> '$WD/err'
      echo survived"
    assert_success
    assert_output survived
    [ ! -f "$WD/.context/logs/audit.jsonl" ] || fail "a row was written for: $args"
    [ "$(wc -l < "$WD/err" | tr -d ' ')" = "1" ] || fail "expected one stderr line for: $args"
    grep -q "$want" "$WD/err" || fail "stderr does not name $want for: $args"
  done
}

@test "audit_row: skipped is in the closed result set" {
  run_script_env --cwd "$WD" --source "$LIB" corpflow_hook_audit_row \
    --ctx "$WD/.context" --actor hook:state-merge --action state_merge_noop \
    --result skipped --subject none --task-id none --meta '{}'
  assert_success
  _row_of | jq -e '.result == "skipped" and .subject == "none" and .task_id == "none"'
}

@test "audit_task_id: the one in-progress key, else none, else unknown" {
  rm -f "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_audit_task_id "$WD/.context"
  assert_output none
  printf '%s' '{"tasks":{"PL0":{"status":"completed"}}}' > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_audit_task_id "$WD/.context"
  assert_output none
  printf '%s' '{"tasks":{"PL0":{"status":"completed"},"DV1":{"status":"in_progress"}}}' > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_audit_task_id "$WD/.context"
  assert_output DV1
  printf '%s' '{"tasks":{"DV0":{"status":"in_progress"},"DV1":{"status":"in_progress"}}}' > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_audit_task_id "$WD/.context"
  assert_output unknown
  printf 'NOT JSON' > "$WD/.context/state.json"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_audit_task_id "$WD/.context"
  assert_output unknown
}

@test "audit_row: a transposed action/result drops the row instead of recording a lie" {
  # The worst failure an audit log has is a valid row that lies. The closed sets
  # turn a transposition into a missing row, which is loud, not plausible.
  run_script_env --cwd "$WD" --source "$LIB" corpflow_hook_audit_row \
    --ctx "$WD/.context" --actor hook:model-switch-gate --action ok \
    --result model_switch_blocked --subject DV0 --task-id DV0 --meta '{}'
  assert_success
  [ ! -f "$WD/.context/logs/audit.jsonl" ]
}

@test "audit_row: a non-hook actor is refused" {
  run_script_env --cwd "$WD" --source "$LIB" corpflow_hook_audit_row \
    --ctx "$WD/.context" --actor "attacker" --action x --result ok --subject DV0 --task-id DV0 --meta '{}'
  assert_success
  [ ! -f "$WD/.context/logs/audit.jsonl" ]
}

@test "audit_row: malformed metadata degrades the METADATA, never the row" {
  # Losing metadata beats losing a result:"block" row.
  run_script_env --cwd "$WD" --source "$LIB" corpflow_hook_audit_row \
    --ctx "$WD/.context" --actor hook:model-switch-gate --action model_switch_blocked \
    --result block --meta 'not json' --subject DV0 --task-id DV0
  assert_success
  _row_of | jq -e '.result == "block" and .metadata._meta_invalid == true'
}

@test "audit_row: a value-less flag does not shift the parse or abort the caller" {
  # `shift 2` past $# returns non-zero and would kill a set -e consumer from
  # inside the appender.
  run_script_env --cwd "$WD" --source "$LIB" corpflow_hook_audit_row \
    --ctx "$WD/.context" --actor hook:model-switch-gate --action a --result ok --meta
  assert_success
}

@test "audit_row: it refuses to append through a symlink" {
  mkdir -p "$WD/.context/logs" "$WD/elsewhere"
  : > "$WD/elsewhere/target"
  ln -s "$WD/elsewhere/target" "$WD/.context/logs/audit.jsonl"
  run_script_env --cwd "$WD" --source "$LIB" corpflow_hook_audit_row \
    --ctx "$WD/.context" --actor hook:model-switch-gate --action a --result ok \
    --subject DV0 --task-id DV0 --meta '{}'
  assert_success
  [ ! -s "$WD/elsewhere/target" ]
}

# --- library authoring rules --------------------------------------------------

@test "authoring: every symbol returns 0 under all three consumer option sets" {
  # The consumers run under set -eu, set -u/set -f, and set -euo pipefail. A
  # library that returns non-zero — or that word-splits on a glob under -f —
  # aborts the caller from inside the code meant to keep it fail-open.
  local opts fn
  local fns="corpflow_workspace_root corpflow_context_root corpflow_active_stage
    corpflow_resolve_pin corpflow_stage_and_pin corpflow_model_family
    corpflow_switch_dest corpflow_switch_origin corpflow_switch_fields corpflow_audit_task_id
    corpflow_hook_audit_row corpflow_bind_payload corpflow_first_user_text"
  for opts in 'set -eu' 'set -u; set -f' 'set -euo pipefail'; do
    for fn in $fns; do
      run bash -c "cd '$WD'; $opts; . '$PLUGIN_ROOT/$LIB'; $fn" 
      assert_success
    done
  done
}

@test "authoring: sourcing twice is a no-op, not a readonly redefinition failure" {
  run bash -c "set -euo pipefail; . '$PLUGIN_ROOT/$LIB'; . '$PLUGIN_ROOT/$LIB'; corpflow_model_family opus"
  assert_success
  assert_output "opus"
}

@test "authoring: a self-test body cannot redefine a library symbol" {
  # readonly -f makes the isolation un-violable rather than merely checkable.
  run bash -c "set -u; . '$PLUGIN_ROOT/$LIB'; corpflow_active_stage() { printf 'HIJACKED'; } 2>/dev/null; corpflow_active_stage /nowhere"
  refute_output --partial "HIJACKED"
}

@test "authoring: the library survives its dependencies being hidden" {
  local fn
  for fn in corpflow_active_stage corpflow_stage_and_pin corpflow_switch_fields corpflow_audit_task_id \
    corpflow_hook_audit_row; do
    run_script_env --cwd "$WD" --hide jq --hide git --hide date \
      --source "$LIB" "$fn" "$WD/.context" ""
    assert_success
  done
}

# --- AD-2 degradation: three mutations x four consumers -----------------------
# One fixture, twelve cases. The TRUNCATE mutation is the one that matters: a
# syntax error in a sourced file is fatal under `set -e` and `||` does NOT rescue
# it, so a half-written library would turn the fail-open PreModelSwitch gate into
# an exit-2 hard block on every model switch in every session. `[ -f ]` alone
# never sees it.

# _degraded_hooks <delete|stub|truncate> -> echoes a hooks/ copy with the shared
# library mutated that way.
_degraded_hooks() {
  local mode="$1" hd lib line
  hd="$(mk_tmpworkdir)/hooks"
  cp -R "$PLUGIN_ROOT/hooks" "$hd"
  lib="$hd/model-switch-lib.sh"
  case "$mode" in
    delete) rm -f "$lib" ;;
    stub)
      # Symbols exist and return nothing. The probe passes; every answer is empty.
      { printf '%s\n' '#!/usr/bin/env bash'
        local fn
        for fn in corpflow_workspace_root corpflow_context_root corpflow_active_stage \
                  corpflow_resolve_pin corpflow_stage_and_pin corpflow_model_family \
                  corpflow_switch_dest corpflow_switch_origin corpflow_switch_fields \
                  corpflow_hook_audit_row; do
          printf '%s() { printf ""; return 0; }\n' "$fn"
        done
      } > "$lib" ;;
    truncate)
      line="$(grep -n '^corpflow_hook_audit_row() {' "$lib" | cut -d: -f1)"
      if [ -z "$line" ]; then
        printf >&2 '_degraded_hooks: no corpflow_hook_audit_row to truncate at\n'
        return 1
      fi
      awk -v n="$((line + 6))" 'NR <= n' "$lib" > "$lib.cut" && mv "$lib.cut" "$lib"
      if bash -n "$lib" 2>/dev/null; then
        printf >&2 '_degraded_hooks: truncation is not a syntax error\n'
        return 1
      fi
      ;;
  esac
  printf '%s' "$hd"
}

_run_consumer() {
  local hd="$1" who="$2"
  case "$who" in
    model-switch-gate|model-switch-audit)
      run env -u WORKSPACE_ROOT "CLAUDE_PROJECT_DIR=$WD" \
        bash "$hd/$who.sh" <<< '{"session_id":"s","agent_id":"agt_dv","to_model":"sonnet"}' ;;
    test-execution-gate)
      run env -u WORKSPACE_ROOT "CLAUDE_PROJECT_DIR=$WD" \
        bash "$hd/$who.sh" <<< '{"tool_name":"Bash","tool_input":{"command":"bats tests/x.bats"}}' ;;
    state-merge)
      run env -u WORKSPACE_ROOT "CLAUDE_PROJECT_DIR=$WD" "CLAUDE_TASK_METADATA_STAGE=DV" \
        bash "$hd/$who.sh" < /dev/null ;;
  esac
}

@test "degradation: all four consumers exit 0 under delete, stub and truncate" {
  _ledger
  local mode who hd
  for mode in delete stub truncate; do
    hd="$(_degraded_hooks "$mode")"
    for who in model-switch-gate model-switch-audit test-execution-gate state-merge; do
      _run_consumer "$hd" "$who"
      [ "$status" -eq 0 ] || fail "$who exited $status under '$mode' (must be 0, never 2)"
    done
  done
}

@test "degradation: the truncated library never reaches the gate's exit 2" {
  # Stated as its own case because exit 2 is not merely a failure here: per
  # hook-monitoring.md an exit-2 PreToolUse/PreModelSwitch block HOLDS even when
  # its JSON fails schema validation, so this would wedge every session.
  _ledger
  local hd
  hd="$(_degraded_hooks truncate)"
  _run_consumer "$hd" model-switch-gate
  [ "$status" -eq 0 ]
  refute_output --partial '"decision"'
}

@test "degradation: signalling is library-free — stderr plus a sentinel, no audit row" {
  # The appender is IN the library, so a degraded path that tried to write an
  # audit row would be asking the missing code to report its own absence.
  _ledger
  local hd
  hd="$(_degraded_hooks delete)"
  run env -u WORKSPACE_ROOT "CLAUDE_PROJECT_DIR=$WD" \
    bash "$hd/model-switch-gate.sh" <<< '{"session_id":"s","to_model":"sonnet"}'
  assert_success
  [ -f "$WD/.context/logs/.corpflow-lib-missing" ]
  [ ! -f "$WD/.context/logs/audit.jsonl" ]
}

@test "degradation: a session with no ledger stays silent and creates nothing" {
  local bare hd
  bare="$(mk_tmpworkdir)"
  hd="$(_degraded_hooks delete)"
  run env -u WORKSPACE_ROOT "CLAUDE_PROJECT_DIR=$bare" \
    bash "$hd/model-switch-gate.sh" <<< '{"session_id":"s","to_model":"sonnet"}'
  assert_success
  [ ! -d "$bare/.context" ]
}

@test "degradation: the test-execution gate announces itself in-band on the first allow" {
  # It is the only consumer with a channel back to the model, and a silently
  # disarmed authority gate is worse than a noisy one.
  _ledger
  local hd
  hd="$(_degraded_hooks delete)"
  # --separate-stderr: the library-free diagnostic goes to stderr, and the in-band
  # notice is the only thing on stdout.
  run --separate-stderr env -u WORKSPACE_ROOT "CLAUDE_PROJECT_DIR=$WD" \
    bash "$hd/test-execution-gate.sh" <<< '{"tool_name":"Bash","tool_input":{"command":"bats tests/x.bats"}}'
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("degraded")'
}

@test "degradation: the in-band notice survives another hook writing the shared sentinel" {
  # The shared sentinel is written by every degraded hook, so keying the notice on
  # it made the announcement a race: whichever hook ran first silenced the only
  # consumer that can tell the model its authority gate is off.
  _ledger
  local hd
  hd="$(_degraded_hooks delete)"
  mkdir -p "$WD/.context/logs"
  : > "$WD/.context/logs/.corpflow-lib-missing"
  run --separate-stderr env -u WORKSPACE_ROOT "CLAUDE_PROJECT_DIR=$WD" \
    bash "$hd/test-execution-gate.sh" <<< '{"tool_name":"Bash","tool_input":{"command":"bats tests/x.bats"}}'
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("degraded")'
}

@test "degradation: ANTI-VACUITY — both self-tests FAIL against a stubbed library" {
  # S4. A self-test that still prints OK against a gutted library is vacuous by
  # definition, and would certify the exact regression it exists to catch.
  local hd who
  hd="$(_degraded_hooks stub)"
  for who in model-switch-gate model-switch-audit; do
    run bash "$hd/$who.sh" --self-test
    [ "$status" -ne 0 ] || fail "$who --self-test passed against a stubbed library"
  done
}
