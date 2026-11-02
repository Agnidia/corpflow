#!/usr/bin/env bats
# tests/shell/hooks/state-merge.bats — DV0c
# Target: hooks/state-merge.sh
# Covers: F1 absent-state.json no-op, happy merge DV→completed, corrupt-ledger repair
#         (rebuild + backup + audit row) and its fail-safe non-trigger path,
#         absent-artifact no-op, state-patch.sh resolution from a project-local install.
#
# Note: state-merge.sh resolves .context/state.json relative to CWD.
# Tests run via `bash -c "cd WD && ..."` to set the working directory correctly.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="hooks/state-merge.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context/logs"
  # The root ladder (hooks/model-switch-lib.sh) never falls back to cwd and every
  # rank demands .context/state.json; declare the fixture as the workspace root so
  # `corpflow_workspace_root` (rank 3) resolves it once a test seeds the ledger.
  export WORKSPACE_ROOT="$WD"
}

# -- helpers --

_seed_state() {
  cat > "$WD/.context/state.json" <<'EOF'
{"run_index":0,"worktask_id":"wt-fix","tasks":{"PL0":{"status":"completed","verdict":"ok"},"DV0":{"status":"in_progress"}}}
EOF
}

_seed_artifact() {
  cat > "$WD/.context/development-0.md" <<'EOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "widget done"
---

# Development

Done.
EOF
}

# ---------------------------------------------------------------------------

@test "F1: absent state.json -> exit 0, no state.json created" {
  _seed_artifact
  # Deliberately no .context/state.json
  run bash -c "cd '$WD' && CLAUDE_ARTIFACT_PATH=.context/development-0.md CLAUDE_TASK_METADATA_STAGE=DV bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success
  [ ! -f "$WD/.context/state.json" ]
}

@test "happy: merges DV->completed/verdict=ok from artifact frontmatter" {
  _seed_state
  _seed_artifact
  run bash -c "cd '$WD' && CLAUDE_ARTIFACT_PATH=.context/development-0.md CLAUDE_TASK_METADATA_STAGE=DV bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success
  local dv_status
  dv_status=$(jq -r '.tasks.DV0.status' "$WD/.context/state.json")
  local dv_verdict
  dv_verdict=$(jq -r '.tasks.DV0.verdict' "$WD/.context/state.json")
  [ "$dv_status" = "completed" ]
  [ "$dv_verdict" = "ok" ]
}

# --- corrupt-ledger repair (R4.4) ------------------------------------------
# The repair rebuilds the SKELETON only and re-enters the normal state-patch.sh
# delegation. Its one non-negotiable invariant is that the corrupt original is
# always recoverable, so each test below asserts the backup as well as the outcome.

_backup_paths() {
  # Prints one path per line; empty when no repair happened.
  find "$WD/.context" -maxdepth 1 -name 'state.json.corrupt.*' | sort
}

@test "corrupt state.json + parseable artifact -> backed up, ledger rebuilt, merge lands, state_repair row" {
  printf 'NOT JSON {{{' > "$WD/.context/state.json"
  _seed_artifact
  run bash -c "cd '$WD' && CLAUDE_ARTIFACT_PATH=.context/development-0.md CLAUDE_TASK_METADATA_STAGE=DV bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success

  # 1. The corrupt original survives, byte-for-byte, before anything else is judged.
  local backups
  backups=$(_backup_paths)
  [ "$(printf '%s\n' "$backups" | wc -l | tr -d ' ')" = "1" ]
  [ "$(cat "$backups")" = "NOT JSON {{{" ]

  # 2. The ledger parses and carries the skeleton's identity fields.
  jq -e . "$WD/.context/state.json" > /dev/null
  local run_index plan_file
  run_index=$(jq -r '.run_index' "$WD/.context/state.json")
  plan_file=$(jq -r '.plan_file' "$WD/.context/state.json")
  [ "$run_index" = "0" ]
  [ "$plan_file" = ".context/planning-0.md" ]

  # 3. The real field merge still happens in state-patch.sh — the skeleton alone
  #    would leave .tasks empty, so this is what proves the fall-through.
  #    (AR0 S6 T1 says `.verdict == "ok"`; no top-level verdict key exists in the
  #    schema — state-patch.sh writes it under the stage object. Corrected here.)
  local dv_status dv_verdict
  dv_status=$(jq -r '.tasks.DV0.status' "$WD/.context/state.json")
  dv_verdict=$(jq -r '.tasks.DV0.verdict' "$WD/.context/state.json")
  [ "$dv_status" = "completed" ]
  [ "$dv_verdict" = "ok" ]

  assert_audit_row state_repair --actor hook:state-merge --result repaired \
    --meta reason=corrupt_state_json --meta run_index=0 --meta stage=DV \
    --meta "artifact=.context/development-0.md" \
    --meta "backup=.context/$(basename "$backups")" --count 1
}

@test "corrupt state.json + no artifact -> fail-safe: file byte-identical, no backup, no audit row" {
  printf 'NOT JSON {{{' > "$WD/.context/state.json"
  # Pre-image taken from disk rather than re-derived from the literal, so a
  # write that merely round-trips the same bytes still has to match exactly.
  cp "$WD/.context/state.json" "$WD/preimage"
  # Deliberately no artifact and no CLAUDE_ARTIFACT_PATH — the non-trigger path.
  run bash -c "cd '$WD' && CLAUDE_TASK_METADATA_STAGE=DV bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success

  cmp "$WD/preimage" "$WD/.context/state.json"
  [ -z "$(_backup_paths)" ]
  assert_audit_row state_repair --absent
}

@test "repair backup: named state.json.corrupt.<ts> and an earlier backup is never overwritten" {
  _seed_artifact
  local payload
  for payload in 'CORRUPT-ALPHA {{{' 'CORRUPT-BETA }}}'; do
    printf '%s' "$payload" > "$WD/.context/state.json"
    run bash -c "cd '$WD' && CLAUDE_ARTIFACT_PATH=.context/development-0.md CLAUDE_TASK_METADATA_STAGE=DV bash '$PLUGIN_ROOT/$SCRIPT'"
    assert_success
  done

  # Two repairs, two backups. Whether they land in the same second (collision
  # suffix) or not, neither payload may be lost — that is the invariant.
  local backups count f name found_alpha=0 found_beta=0
  backups=$(_backup_paths)
  count=$(printf '%s\n' "$backups" | wc -l | tr -d ' ')
  [ "$count" = "2" ]

  while read -r f; do
    name=$(basename "$f")
    [[ "$name" =~ ^state\.json\.corrupt\.[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$ ]] \
      || fail "backup name off contract: $name"
    case "$(cat "$f")" in
      'CORRUPT-ALPHA {{{') found_alpha=$((found_alpha + 1)) ;;
      'CORRUPT-BETA }}}') found_beta=$((found_beta + 1)) ;;
      *) fail "backup $name holds neither payload: $(cat "$f")" ;;
    esac
  done <<< "$backups"
  [ "$found_alpha" = "1" ]
  [ "$found_beta" = "1" ]

  assert_audit_row state_repair --result repaired --count 2
}

@test "repair backup: a dangling symlink at the backup path is never written through" {
  _seed_artifact
  printf 'NOT JSON {{{' > "$WD/.context/state.json"

  # `[[ -e ]]` is FALSE for a dangling symlink, so a candidate name occupied by one
  # reads as free; `cp` then follows it to the link's target and `cmp -s` verifies
  # through the same link, so the write lands on an attacker-chosen path silently.
  # The link is planted across a small second-window because the script picks the
  # timestamp itself — one of these is guaranteed to be the name it computes.
  local victim="$WD/pwned" i now ts
  now=$(date -u +%s)
  for i in 0 1 2 3 4; do
    ts=$(date -u -r "$((now + i))" +%Y%m%dT%H%M%SZ 2> /dev/null) \
      || ts=$(date -u -d "@$((now + i))" +%Y%m%dT%H%M%SZ)
    ln -s "$victim" "$WD/.context/state.json.corrupt.$ts"
  done

  run bash -c "cd '$WD' && CLAUDE_ARTIFACT_PATH=.context/development-0.md CLAUDE_TASK_METADATA_STAGE=DV bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success

  # 1. The invariant under test: nothing was written through the link.
  [ ! -e "$victim" ] || fail "backup was written through the dangling symlink to $victim"

  # 2. The repair still completed onto a real, non-symlink path holding the original
  #    bytes — so the fix skips the planted name rather than aborting the repair.
  local real_backups
  real_backups=$(find "$WD/.context" -maxdepth 1 -type f -name 'state.json.corrupt.*' | sort)
  [ "$(printf '%s\n' "$real_backups" | wc -l | tr -d ' ')" = "1" ]
  [ "$(cat "$real_backups")" = "NOT JSON {{{" ]

  local dv_status
  dv_status=$(jq -r '.tasks.DV0.status' "$WD/.context/state.json")
  [ "$dv_status" = "completed" ]
}

@test "neither stage nor artifact -> exit 0 with no audit row, no WARN, no sentinel (#522)" {
  _seed_state
  run bash -c "cd '$WD' && bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success
  run bash -c "cd '$WD' && bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success
  [ ! -s "$WD/.context/logs/audit.jsonl" ] || fail "a stage-less stop wrote an audit row"
  if [ -f "$WD/.context/logs/state-merge.log" ]; then
    run grep -q 'WARN' "$WD/.context/logs/state-merge.log"
    assert_failure
  fi
  run find "$WD/.context/logs" -name '.state-merge-noop-noted-*'
  assert_output ""
}

@test "stage set, no artifact -> still logs 'no artifact resolved' no-op" {
  _seed_state
  run bash -c "cd '$WD' && CLAUDE_TASK_METADATA_STAGE=DV bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success
  run grep -F 'no artifact resolved (stage=DV artifact=) — no-op' "$WD/.context/logs/state-merge.log"
  assert_success
}

@test "absent artifact -> no-op exit 0, DV stage remains in_progress" {
  _seed_state
  # No artifact on disk; CLAUDE_ARTIFACT_PATH not set → state-patch gets no --artifact
  run bash -c "cd '$WD' && CLAUDE_TASK_METADATA_STAGE=DV bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success
  local dv_status
  dv_status=$(jq -r '.tasks.DV0.status' "$WD/.context/state.json")
  [ "$dv_status" = "in_progress" ]
}

# ---------------------------------------------------------------------------
# v1 additive upgrade — --via pass-through with STATE_MERGE_VIA override (#199).
# ---------------------------------------------------------------------------

@test "via: delegation defaults completed_via=hook (Layer 2 provenance)" {
  _seed_state
  _seed_artifact
  run bash -c "cd '$WD' && CLAUDE_ARTIFACT_PATH=.context/development-0.md CLAUDE_TASK_METADATA_STAGE=DV bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success
  local via
  via=$(jq -r '.tasks.DV0.completed_via' "$WD/.context/state.json")
  [ "$via" = "hook" ]
}

@test "via: STATE_MERGE_VIA=step6_5 overrides completed_via" {
  _seed_state
  _seed_artifact
  run bash -c "cd '$WD' && STATE_MERGE_VIA=step6_5 CLAUDE_ARTIFACT_PATH=.context/development-0.md CLAUDE_TASK_METADATA_STAGE=DV bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success
  local via
  via=$(jq -r '.tasks.DV0.completed_via' "$WD/.context/state.json")
  [ "$via" = "step6_5" ]
}

# --- state-patch.sh resolution (Layer-2 safety net) -------------------------
# worktask.md Step 3b copies this hook into <project>/.claude/hooks/, where the
# relative arm resolves to a skills/ tree that does not exist. These pin the
# resolution so the net can never silently become a no-op again.

_install_project_local() {
  mkdir -p "$WD/.claude/hooks"
  cp "$PLUGIN_ROOT/$SCRIPT" "$WD/.claude/hooks/state-merge.sh"
  chmod +x "$WD/.claude/hooks/state-merge.sh"
}

@test "project-local copy: CLAUDE_PLUGIN_ROOT resolves state-patch.sh and the merge still lands" {
  _seed_state
  _seed_artifact
  _install_project_local
  run bash -c "cd '$WD' && CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' CLAUDE_ARTIFACT_PATH=.context/development-0.md CLAUDE_TASK_METADATA_STAGE=DV bash '$WD/.claude/hooks/state-merge.sh'"
  assert_success
  local dv_status
  dv_status=$(jq -r '.tasks.DV0.status' "$WD/.context/state.json")
  [ "$dv_status" = "completed" ]
}

# --- root resolution ---------------------------------------------------

@test "unresolved root -> rc 0, no .context materialized under cwd" {
  local fresh
  fresh="$(mk_tmpworkdir)"
  run env -u WORKSPACE_ROOT -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR \
    GIT_CEILING_DIRECTORIES="$fresh" \
    bash -c "cd '$fresh' && CLAUDE_TASK_METADATA_STAGE=DV bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success
  [ ! -d "$fresh/.context" ]
}

@test "registered stage worktree cwd, no declared root -> merge lands in main's ledger" {
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
  jq -cn --arg w "$wt" '{run_index: 0, worktask_id: "wt-fix", tasks: {PL0: {status: "completed", verdict: "ok"},
    DV0: {status: "in_progress", metadata: {workspace_path: $w}}}}' > "$main/.context/state.json"
  cat > "$main/.context/development-0.md" <<'EOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "widget done"
---

# Development

Done.
EOF

  run env -u WORKSPACE_ROOT -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    bash -c "cd '$wt' && CLAUDE_ARTIFACT_PATH='$main/.context/development-0.md' CLAUDE_TASK_METADATA_STAGE=DV bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success
  local dv_status
  dv_status=$(jq -r '.tasks.DV0.status' "$main/.context/state.json")
  [ "$dv_status" = "completed" ]
  [ ! -d "$wt/.context" ]
}

@test "absent state-patch.sh: exit 0 (never blocks) and the stage is left untouched" {
  _seed_state
  _seed_artifact
  _install_project_local
  # Plugin root with no skills/ tree, and no skills/ beside the project-local copy.
  run bash -c "cd '$WD' && CLAUDE_PLUGIN_ROOT='$WD/nowhere' CLAUDE_ARTIFACT_PATH=.context/development-0.md CLAUDE_TASK_METADATA_STAGE=DV bash '$WD/.claude/hooks/state-merge.sh'"
  assert_success
  local dv_status
  dv_status=$(jq -r '.tasks.DV0.status' "$WD/.context/state.json")
  [ "$dv_status" = "in_progress" ]
}

# --- verdict-refusal is swallowed (meets the "exit 0 ALWAYS" hook contract) -----

@test "SubagentStop: artifact with no verdict is swallowed — exit 0, ledger unchanged, rc logged" {
  _seed_state
  cat > "$WD/.context/development-0.md" <<'EOF'
---
handoff:
  stage: DV
  summary: "no verdict fixture"
---

# Development
EOF
  local before; before="$(shasum "$WD/.context/state.json")"
  run bash -c "cd '$WD' && CLAUDE_ARTIFACT_PATH=.context/development-0.md CLAUDE_TASK_METADATA_STAGE=DV bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success
  local after; after="$(shasum "$WD/.context/state.json")"
  [ "$before" = "$after" ]
  # state-patch.sh's own exit 3 (verdict refused) must not propagate — the hook's
  # log line is the only surviving evidence that the write was swallowed, not lost.
  run grep -c 'rc=3' "$WD/.context/logs/state-merge.log"
  assert_output "1"
}

# --- no ledger, no write -------------------------------------------------------

@test "AC-2: one subagent cycle through every registered hook leaves a clean checkout clean" {
  local repo h hit
  repo="$(mk_git_fixture --file 'a.txt:hi' --commit 'init')"
  repo="$(cd "$repo" && pwd -P)"
  local tool='{"tool_name":"Bash","tool_input":{"command":"bash skills/worktask/scripts/state-patch.sh --task-status DV0 in_progress"},"tool_use_id":"t1","duration_ms":5,"session_id":"s1"}'
  local stop='{"hook_event_name":"SubagentStop","agent_type":"corpflow:developer","agent_id":"agt1","session_id":"s1","duration_ms":5}'
  local sw='{"session_id":"s1","agent_id":"agt1","from_model":"opus","to_model":"sonnet"}'

  # <script> <payload> [args...] — both declared roots point at the unseeded checkout,
  # and the off-hatches are set because they are the arms that write sentinels.
  _fire() {
    local s="$1" p="$2"
    shift 2
    run env -u CONTEXT_DIR WORKSPACE_ROOT="$repo" CLAUDE_PROJECT_DIR="$repo" \
      CLAUDE_TASK_METADATA_STAGE=DV CORPFLOW_TEST_GATE=off CORPFLOW_MODEL_SWITCH_GATE=off \
      bash -c 'cd "$1" && shift && bash "$@"' _ "$repo" "$PLUGIN_ROOT/$s" "$@" <<< "$p"
    [ "$status" -eq 0 ] || fail "$s exited $status: $output"
  }

  for h in test-execution-gate audit-tooluse test-execution-promote anchor-preflight comment-standard-context; do
    _fire "hooks/$h.sh" "$tool"
  done
  _fire hooks/model-switch-gate.sh "$sw"
  _fire hooks/model-switch-audit.sh "$sw"
  for h in audit-subagent dv-screenshot-gate dv-comment-density-gate state-merge megatask-monitor; do
    _fire "hooks/$h.sh" "$stop"
  done
  _fire hooks/agent-stop.sh "$stop" --stage DV
  _fire hooks/precompact-checkpoint.sh '{}'
  _fire skills/context-compression/scripts/post-compact-recovery.sh '{}'
  _fire hooks/session-end-finalize.sh '{"hook_event_name":"SessionEnd","reason":"clear"}'

  hit="$(find "$repo" -name .context -print | head -n 1)"
  [ -z "$hit" ] || fail "a hook created $hit"
}

@test "no ledger: a bare .context/ with no state.json is not a merge target — no log, no ledger" {
  _seed_artifact
  run bash -c "cd '$WD' && CLAUDE_ARTIFACT_PATH=.context/development-0.md CLAUDE_TASK_METADATA_STAGE=DV GIT_CEILING_DIRECTORIES='$WD' bash '$PLUGIN_ROOT/$SCRIPT'"
  assert_success
  [ ! -e "$WD/.context/logs/state-merge.log" ]
  [ ! -e "$WD/.context/state.json" ]
}

# A stub delegate keeps these cases fast; state-patch.bats runs the real suite.
_stub_patch() { # <shell body for the stub state-patch.sh>
  mkdir -p "$WD/root/skills/worktask/scripts"
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$WD/root/skills/worktask/scripts/state-patch.sh"
}

@test "--self-test: the wrapper line repeats the delegate's executed-case count" {
  _stub_patch "printf 'T1: ok\nT2: ok\nself-test: ALL PASS (2 passed, 0 failed)\n'"
  run env CLAUDE_PLUGIN_ROOT="$WD/root" bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "T2: ok"
  assert_output --partial "self-test (via state-patch.sh): ALL PASS (2 passed, 0 failed)"
}

@test "--self-test: a digitless delegate pass line fails the wrapper" {
  _stub_patch "printf 'self-test: ALL PASS\n'"
  run env CLAUDE_PLUGIN_ROOT="$WD/root" bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_failure 1
  assert_output --partial "passed without a case count"
  refute_output --partial "self-test (via state-patch.sh): ALL PASS"
}

@test "--self-test: a failing delegate keeps exit 1 and its output" {
  _stub_patch "printf 'T1: FAIL\n'; exit 1"
  run env CLAUDE_PLUGIN_ROOT="$WD/root" bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_failure 1
  assert_output --partial "T1: FAIL"
  assert_output --partial "state-patch.sh --self-test FAILED"
}
