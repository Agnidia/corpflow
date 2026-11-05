#!/usr/bin/env bats
# Contract tests for skills/worktask/scripts/megatask-settle.sh — the write every "→ USER"
# stop makes first under a /megatask per-issue run (skills/worktask/references/orchestration.md § USER under
# /megatask):
#   - a per-issue ledger (PL0.metadata.megatask_group) settles its own worktree's
#     workspace.json as failed / escalated_to_user, with one megatask_escalated row;
#   - it resolves the worktree through WORKSPACE_ROOT even when the shell stands in megatask's
#     root and CLAUDE_PROJECT_DIR names megatask's own ledger, which it never touches;
#   - outside /megatask, or over an already settled status, it writes nothing;
#   - a symlinked or missing workspace.json is refused (exit 1), never written through;
#   - one that is not exactly one JSON object (empty, blank, array, null, a stream) is refused
#     as malformed and left as it was;
#   - hooks/megatask-monitor.sh then frees the track and keeps the dependent blocked;
#   - the SKILL.md sites that end at USER point at the rule, and /worktask holds the grant.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/worktask/scripts/megatask-settle.sh"
MONITOR="hooks/megatask-monitor.sh"
SKILL_DOC="skills/worktask/references/orchestration.md"
WORKTASK_DOC="skills/worktask/SKILL.md"

# Megatask root with its own ledger, group milestone-9: issue 41 (in progress, the worktree
# under test) blocks issue 42. Mirrors what init-worktree.sh and build-orchestrator.sh leave.
setup() {
  ROOT="$(mk_tmpworkdir)"
  WT="$ROOT/.worktrees/milestone-9/41"
  mkdir -p "$ROOT/.context/logs" "$WT/.context/logs" "$ROOT/.worktrees/milestone-9/42"
  printf '{"version":2,"tasks":{"PL0":{"status":"completed","metadata":{}}}}\n' \
    > "$ROOT/.context/state.json"
  printf '{"version":2,"run_index":0,"tasks":{"PL0":{"status":"completed","metadata":{"megatask_group":"milestone-9"}}}}\n' \
    > "$WT/.context/state.json"
  printf '{"version":"2.0","isolation":"worktree","execution":{"status":"in_progress","pr":null}}\n' \
    > "$WT/workspace.json"
  printf '{"version":"2.0","isolation":"worktree","execution":{"status":"in_progress"}}\n' \
    > "$ROOT/.worktrees/milestone-9/42/workspace.json"
  cat > "$ROOT/.worktrees/milestone-9/orchestrator.json" <<'EOF'
{ "version":"3.1","group":"milestone-9","milestone":{"number":9,"title":"T"},
  "configuration":{"parallel_tracks":2,"isolation":"worktree"},
  "topological_order":[41,42],
  "issues":[
    {"number":41,"priority":"P0","status":"in_progress","track":1,"level":0,"blocked_by":[],"blocks":[42]},
    {"number":42,"priority":"P1","status":"blocked","track":null,"level":1,"blocked_by":[41],"blocks":[]}],
  "tracks":{"1":{"issue_number":41},"2":{"issue_number":null,"status":"available"}},
  "progress":{"total":2,"completed":0,"in_progress":1,"ready":0,"blocked":1,"failed":0} }
EOF
  cp "$ROOT/.context/state.json" "$ROOT/state.before"
}

# The subagent's shell: cwd is megatask's root, CLAUDE_PROJECT_DIR is megatask's root, and the
# run-environment prefix supplies WORKSPACE_ROOT.
settle() {
  cd "$ROOT"
  run env CLAUDE_PROJECT_DIR="$ROOT" WORKSPACE_ROOT="$WT" MILESTONE_MODE=1 \
    bash "$PLUGIN_ROOT/$SCRIPT" "$@"
}

@test "settles the worktree's workspace.json, never megatask's ledger" {
  settle --subject DV0 --detail "DV0 blocked: build tool missing"
  assert_success
  assert_line "result=settled"
  assert_line "reason=escalated_to_user"
  assert_line "workspace=$WT/workspace.json"
  run jq -r '.execution | "\(.status) \(.reason) \(.pr)"' "$WT/workspace.json"
  assert_output "failed escalated_to_user null"
  run jq -r 'select(.action == "megatask_escalated")
             | "\(.subject) \(.result) \(.metadata.megatask_group) \(.metadata.detail)"' \
    "$WT/.context/logs/audit.jsonl"
  assert_output "DV0 block milestone-9 DV0 blocked: build tool missing"
  cmp -s "$ROOT/.context/state.json" "$ROOT/state.before" || fail "megatask's ledger changed"
  [ ! -e "$ROOT/workspace.json" ]
  [ ! -e "$ROOT/.context/logs/audit.jsonl" ]
}

@test "the monitor then frees the track and keeps the dependent blocked" {
  settle --subject FN0 --detail "FN gate escalate item"
  assert_success
  run env WORKSPACE_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$PLUGIN_ROOT/$MONITOR" < /dev/null
  assert_success
  run jq -e '
       (.issues[] | select(.number==41) | .status=="failed" and .track==null)
    and (.issues[] | select(.number==42) | .status=="blocked" and ((.blocked_by|length)==1))
    and (.tracks["1"].issue_number==null) and (.progress.failed==1)
  ' "$ROOT/.worktrees/milestone-9/orchestrator.json"
  assert_success
}

@test "outside /megatask: skipped, nothing written" {
  jq '.tasks.PL0.metadata = {}' "$WT/.context/state.json" > "$WT/s" && mv "$WT/s" "$WT/.context/state.json"
  cp "$WT/workspace.json" "$WT/ws.before"
  settle --subject DV0 --detail "x"
  assert_success
  assert_line "result=skipped"
  assert_line "reason=not_megatask"
  cmp -s "$WT/workspace.json" "$WT/ws.before" || fail "workspace.json changed outside /megatask"
  [ ! -e "$WT/.context/logs/audit.jsonl" ]
}

@test "a settled status stands: a PARK's parked_escalation and FN's completed are kept" {
  local st
  for st in '{"status":"failed","reason":"parked_escalation"}' '{"status":"completed","pr":"https://x/pull/1"}'; do
    jq --argjson e "$st" '.execution = $e' "$WT/workspace.json" > "$WT/w" && mv "$WT/w" "$WT/workspace.json"
    cp "$WT/workspace.json" "$WT/ws.before"
    settle --subject PL0 --detail "x"
    assert_success
    assert_line "result=skipped"
    assert_line "reason=already_$(printf '%s' "$st" | jq -r .status)"
    cmp -s "$WT/workspace.json" "$WT/ws.before" || fail "settled status overwritten: $st"
  done
}

@test "SR: a symlinked workspace.json is refused, its target untouched" {
  printf 'untouched\n' > "$ROOT/target.txt"
  rm -f "$WT/workspace.json"
  ln -s "$ROOT/target.txt" "$WT/workspace.json"
  settle --subject DV0 --detail "x"
  assert_failure 1
  assert_line "result=refused"
  assert_line "reason=symlink"
  run cat "$ROOT/target.txt"
  assert_output "untouched"
}

@test "a missing workspace.json is refused, so the caller reports a held track" {
  rm -f "$WT/workspace.json"
  settle --subject DV0 --detail "x"
  assert_failure 1
  assert_line "reason=missing"
}

@test "a workspace.json that is not exactly one JSON object is refused as malformed, untouched" {
  local body
  for body in '' $' \n\t\n' '[]' '"x"' 'null' '{"a":1}{"b":2}'; do
    printf '%s' "$body" > "$WT/workspace.json"
    cp "$WT/workspace.json" "$WT/ws.before"
    settle --subject DV0 --detail "x"
    assert_failure 1
    assert_line "result=refused"
    assert_line "reason=malformed"
    refute_line "result=settled"
    cmp -s "$WT/workspace.json" "$WT/ws.before" || fail "malformed workspace.json rewritten: $body"
  done
  [ ! -e "$WT/.context/logs/audit.jsonl" ]
}

@test "usage: a bad subject or an empty detail exits 2 and writes nothing" {
  settle --subject 'DV0;x' --detail "x"
  assert_failure 2
  settle --subject DV0 --detail ""
  assert_failure 2
  run jq -r '.execution.status' "$WT/workspace.json"
  assert_output "in_progress"
}

@test "docs: every USER site under /megatask points at the rule, and /worktask holds the grant" {
  local rule grant
  rule="$(awk '$0 == "### USER under /megatask" {f=1; next} f && /^#/ {exit} f {print}' \
    "$(contract_source "$PLUGIN_ROOT/$SKILL_DOC")")"
  [ -n "$rule" ] || fail "no § USER under /megatask in $SKILL_DOC"
  printf '%s' "$rule" | grep -qF "bash \${CLAUDE_PLUGIN_ROOT}/$SCRIPT --subject" \
    || fail "§ USER under /megatask does not run $SCRIPT"
  printf '%s' "$rule" | grep -qF 'stopForUser' || fail "the rule does not cover stopForUser"
  # Mid-run escalation, the refused-landing report, and Step 7's blocked row.
  [ "$(grep -cF '§ USER under /megatask' "$(contract_source "$PLUGIN_ROOT/$SKILL_DOC")")" -ge 3 ] \
    || fail "fewer than three USER sites in $SKILL_DOC point at § USER under /megatask"
  grant="$(sed -n 's/^allowed-tools: //p' "$PLUGIN_ROOT/$WORKTASK_DOC")"
  printf '%s' "$grant" | grep -qF "Bash(bash \${CLAUDE_PLUGIN_ROOT}/$SCRIPT *)" \
    || fail "$WORKTASK_DOC does not grant $SCRIPT"
}
