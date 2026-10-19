#!/usr/bin/env bats
# Tests for hooks/megatask-monitor.sh (DV0c) — SubagentStop reconciliation
# sweep over .worktrees/*/orchestrator.json. Settles completed issues, unblocks
# dependents, frees tracks, and writes a megatask_progress audit row.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="hooks/megatask-monitor.sh"

# Seed a milestone-9 group: issue 41 (in_progress, completed in workspace.json)
# blocks issue 42 (blocked).
_seed_group() {
  local root="$1"
  mkdir -p "$root/.worktrees/milestone-9/41" \
           "$root/.worktrees/milestone-9/42" "$root/.context/logs"
  cat > "$root/.worktrees/milestone-9/orchestrator.json" <<'EOF'
{ "version":"3.1","group":"milestone-9","milestone":{"number":9,"title":"T"},
  "configuration":{"parallel_tracks":2,"isolation":"worktree"},
  "topological_order":[41,42],
  "issues":[
    {"number":41,"priority":"P0","status":"in_progress","track":1,"level":0,"blocked_by":[],"blocks":[42]},
    {"number":42,"priority":"P1","status":"blocked","track":null,"level":1,"blocked_by":[41],"blocks":[]}],
  "tracks":{"1":{"issue_number":41},"2":{"issue_number":null,"status":"available"}},
  "progress":{"total":2,"completed":0,"in_progress":1,"ready":0,"blocked":1,"failed":0} }
EOF
}

setup() {
  WD="$(mk_tmpworkdir)"
}

@test "happy: completed issue settles, dependent unblocks, track frees" {
  _seed_group "$WD"
  cat > "$WD/.worktrees/milestone-9/41/workspace.json" <<'EOF'
{ "version":"2.0","isolation":"worktree","execution":{"status":"completed","pr":"https://x/pull/1"} }
EOF
  cat > "$WD/.worktrees/milestone-9/42/workspace.json" <<'EOF'
{ "version":"2.0","isolation":"worktree","execution":{"status":"in_progress"} }
EOF
  run env WORKSPACE_ROOT="$WD" CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < /dev/null
  assert_success
  local orch="$WD/.worktrees/milestone-9/orchestrator.json"
  run jq -e '
       (.issues[] | select(.number==41) | .status=="completed" and .pr=="https://x/pull/1" and .track==null)
    and (.issues[] | select(.number==42) | .status=="ready" and ((.blocked_by|length)==0))
    and (.tracks["1"].issue_number==null)
    and (.progress.completed==1 and .progress.ready==1 and .progress.blocked==0)
  ' "$orch"
  assert_success
  run grep -q megatask_progress "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "edge: a still-in_progress issue is left untouched (idempotent sweep)" {
  _seed_group "$WD"
  cat > "$WD/.worktrees/milestone-9/41/workspace.json" <<'EOF'
{ "version":"2.0","isolation":"worktree","execution":{"status":"in_progress"} }
EOF
  run env WORKSPACE_ROOT="$WD" CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < /dev/null
  assert_success
  local orch="$WD/.worktrees/milestone-9/orchestrator.json"
  run jq -e '(.issues[] | select(.number==41) | .status=="in_progress")
             and (.issues[] | select(.number==42) | .status=="blocked")' "$orch"
  assert_success
}

@test "edge: failed issue settles but does NOT unblock its dependent" {
  _seed_group "$WD"
  cat > "$WD/.worktrees/milestone-9/41/workspace.json" <<'EOF'
{ "version":"2.0","isolation":"worktree","execution":{"status":"failed"} }
EOF
  run env WORKSPACE_ROOT="$WD" CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < /dev/null
  assert_success
  local orch="$WD/.worktrees/milestone-9/orchestrator.json"
  run jq -e '(.issues[] | select(.number==41) | .status=="failed")
             and (.issues[] | select(.number==42) | .status=="blocked" and ((.blocked_by|length)==1))
             and (.progress.failed==1)' "$orch"
  assert_success
}

@test "failure: no .worktrees groups present -> self-skip, no crash" {
  mkdir -p "$WD/.context/logs"
  run env WORKSPACE_ROOT="$WD" CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < /dev/null
  assert_success
  [ ! -f "$WD/.context/logs/audit.jsonl" ]
}

@test "contract: --self-test passes (counted summary)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "self-test OK"
  assert_output --regexp 'megatask-monitor: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
}

@test "concurrency: simultaneous sweeps leave valid JSON and no lost update" {
  # Evidence gate for the R4.6 locking decision: SubagentStop can fire for
  # several agents at once, so more than one sweep can be reconciling the same
  # orchestrator.json. This test states what actually happens under that race —
  # it is the input to whether a lock is needed, not a placeholder for one.
  _seed_group "$WD"
  cat > "$WD/.worktrees/milestone-9/41/workspace.json" <<'EOF'
{ "version":"2.0","isolation":"worktree","execution":{"status":"completed","pr":"https://x/pull/1"} }
EOF
  cat > "$WD/.worktrees/milestone-9/42/workspace.json" <<'EOF'
{ "version":"2.0","isolation":"worktree","execution":{"status":"in_progress"} }
EOF

  local i
  for i in 1 2 3 4 5 6 7 8; do
    env WORKSPACE_ROOT="$WD" CLAUDE_PROJECT_DIR="$WD" \
      bash "$PLUGIN_ROOT/$SCRIPT" < /dev/null > /dev/null 2>&1 &
  done
  wait

  local orch="$WD/.worktrees/milestone-9/orchestrator.json"
  # 1. The ledger is still parseable — an interleaved partial write would not be.
  run jq -e . "$orch"
  assert_success
  # 2. The settle is applied exactly once: counts stay consistent with 2 issues,
  #    so no sweep re-applied another's transition on a stale read.
  run jq -e '
       (.issues | length) == 2
    and (.issues[] | select(.number==41) | .status=="completed" and .track==null)
    and (.issues[] | select(.number==42) | .status=="ready" and ((.blocked_by|length)==0))
    and (.tracks["1"].issue_number==null)
    and (.progress.completed==1 and .progress.ready==1
         and .progress.blocked==0 and .progress.in_progress==0)
    and ((.progress.completed + .progress.ready + .progress.blocked
          + .progress.in_progress + .progress.failed) == .progress.total)
  ' "$orch"
  assert_success
  # 3. Every audit line is a complete JSON object (no interleaved append).
  run bash -c '
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      printf "%s" "$l" | jq -e . > /dev/null || exit 1
    done < "$1"' _ "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "SR: a symlinked audit.jsonl is refused, never written through" {
  _seed_group "$WD"
  cat > "$WD/.worktrees/milestone-9/41/workspace.json" <<'JSON'
{ "version":"2.0","isolation":"worktree","execution":{"status":"completed","pr":"https://x/pull/1"} }
JSON
  cat > "$WD/.worktrees/milestone-9/42/workspace.json" <<'JSON'
{ "version":"2.0","isolation":"worktree","execution":{"status":"in_progress"} }
JSON
  mkdir -p "$WD/target-dir"
  ln -s "$WD/target-dir/escaped.txt" "$WD/.context/logs/audit.jsonl"
  run env WORKSPACE_ROOT="$WD" CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < /dev/null
  assert_success
  [ ! -e "$WD/target-dir/escaped.txt" ]
}
