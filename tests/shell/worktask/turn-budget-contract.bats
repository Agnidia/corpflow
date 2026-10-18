#!/usr/bin/env bats
# Contract tests for the turn-budget brief line and the bounded auto-resume (#498).
# Contracts:
#   - SKILL.md step 4.7 appends the TURN BUDGET line for every loop row and audits it
#   - return-arms.md defines turnBudget: cap from the dispatched agent's maxTurns,
#     default 50, checkpoint floor(0.8 x cap) worked in integers
#   - step 6.5a2 auto-resumes at most 2 times per row per run, counted from
#     stage_returned_incomplete audit rows keyed by task_id + run_index; a 3rd blocks
#   - qa-engineer.md: maxTurns 80, a 64-call budget, the checkpoint rule
#   - planner prescriptions name git grep -P, never a bare \b anchor
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SKILL="skills/worktask/SKILL.md"
ARMS="skills/worktask/references/return-arms.md"
QA_AGENT="agents/qa-engineer.md"

# The counting program 6.5a2 runs, held here verbatim so a fixture can execute it.
COUNT_JQ='[inputs|fromjson?|select(.action=="stage_returned_incomplete" and .metadata.task_id==$id and (.metadata.run_index//0)==$n)]|length'

@test "step 4.7: the turn-budget banner calls turnBudget and audits turn_budget_injected" {
  run awk '/^##### Step 4.7 — turn-budget banner/ {on = 1; next} on && /^#/ {exit} on {print}' \
    "$PLUGIN_ROOT/$SKILL"
  assert_success
  [ -n "$output" ] || fail "no '##### Step 4.7 — turn-budget banner' section in $SKILL"
  assert_output --partial 'turnBudget(subagentType)'
  assert_output --partial 'TURN BUDGET:'
  assert_output --partial 'action: "turn_budget_injected"'
  assert_output --partial 'floor(0.8 × cap)'
  assert_output --partial 'default 50'
}

@test "turnBudget: the line is the REQ-2 text, the default is 50, the checkpoint is cap*4/5" {
  run cat "$PLUGIN_ROOT/$ARMS"
  assert_output --partial 'const line = `TURN BUDGET: ${cap} turns. Checkpoint by turn ${checkpoint}: record progress, '
  assert_output --partial '`write the partial artifact without a handoff verdict, and return.`;'
  assert_output --partial 'const cap = read >= 1 ? read : 50;'
  assert_output --partial 'const checkpoint = Math.floor(cap * 4 / 5);'
  assert_output --partial 'The checkpoint is `floor(0.8 × cap)`'
  assert_output --partial '/^maxTurns:[ \t]*([0-9]+)[ \t]*$/m'
  assert_output --partial 'resolve-sibling-root.sh'
}

@test "turnBudget: the worked rows in the prose match shell integer arithmetic" {
  local cap want got
  for pair in 40:32 50:40 60:48 80:64; do
    cap="${pair%%:*}"
    want="${pair#*:}"
    got=$((cap * 4 / 5))
    [ "$got" -eq "$want" ] || fail "cap $cap: expected checkpoint $want, got $got"
    grep -qF "${cap}→${want}" "$PLUGIN_ROOT/$ARMS" || fail "worked row ${cap}→${want} missing from $ARMS"
  done
}

@test "6.5a2: stage_returned_incomplete carries task_id and run_index" {
  run awk '/^## Step 6.5a2 — mark & audit/ {on = 1; next} on && /^## / {exit} on {print}' \
    "$PLUGIN_ROOT/$ARMS"
  assert_success
  assert_output --partial 'action: "stage_returned_incomplete"'
  assert_output --partial 'task_id: task.id, run_index: full.metadata.run_index ?? 0'
}

@test "6.5a2: at most 2 auto-resumes, each repeating the line; a 3rd blocks and audits stage_resume_exhausted" {
  run cat "$PLUGIN_ROOT/$ARMS"
  assert_output --partial 'if (n <= 2) {'
  assert_output --partial '(auto-resume ${n} of 2)'
  assert_output --partial '${turnBudget(subagentType).line}'
  assert_output --partial '.metadata.task_id==$id and (.metadata.run_index//0)==$n)]|length'
  assert_output --partial 'state-patch.sh --task-status ${task.id} blocked'
  assert_output --partial 'action: "stage_resume_exhausted"'
  grep -qF 'auto-resume ≤2 per row, then escalate' "$PLUGIN_ROOT/$SKILL" \
    || fail "SKILL.md step 6.5a2 does not name the bound and the escalate path"
}

@test "6.5a2: the count reads the audit log by an inline path, never an unset \$LOG_DIR" {
  run awk '/^## Step 6.5a2 — resume, never re-delegate/ {on = 1; next} on && /^## / {exit} on {print}' \
    "$PLUGIN_ROOT/$ARMS"
  assert_success
  assert_output --partial '${WORKSPACE_ROOT:-\${CLAUDE_PROJECT_DIR:-.}}/.context/logs/audit.jsonl'
  refute_output --partial '$LOG_DIR'
}

@test "6.5a2: the count is per row and per run, skips old and malformed rows" {
  local audit="$BATS_TEST_TMPDIR/audit.jsonl"
  {
    printf '%s\n' '{"action":"stage_returned_incomplete","subject":"DV","metadata":{"task_id":"DV0","run_index":0}}'
    printf '%s\n' '{"action":"stage_returned_incomplete","subject":"DV","metadata":{"task_id":"DV1","run_index":0}}'
    printf '%s\n' '{"action":"stage_returned_incomplete","subject":"DV","metadata":{"task_id":"DV0","run_index":1}}'
    printf '%s\n' '{"action":"stage_returned_incomplete","subject":"DV","metadata":{"task_id":"DV0"}}'
    printf '%s\n' '{"action":"stage_returned_incomplete","subject":"DV","metadata":{"artifact":"old-row"}}'
    printf '%s\n' '{"action":"dv_checkpoint_resume","subject":"DV0","metadata":{"task_id":"DV0","run_index":0}}'
    printf '%s\n' 'not json'
  } > "$audit"
  run jq -nR --arg id DV0 --argjson n 0 "$COUNT_JQ" < "$audit"
  assert_success
  assert_output "2"
  run jq -nR --arg id DV0 --argjson n 1 "$COUNT_JQ" < "$audit"
  assert_output "1"
  run jq -nR --arg id DV1 --argjson n 0 "$COUNT_JQ" < "$audit"
  assert_output "1"
}

@test "qa-engineer: maxTurns 80, a 64-call budget, and the checkpoint rule" {
  run cat "$PLUGIN_ROOT/$QA_AGENT"
  assert_output --partial $'\nmaxTurns: 80\n'
  assert_output --partial '### Turn-Budget Checkpoint (QA)'
  assert_output --partial '**Tool-call budget**: ≤64 tool calls per QA pass'
  assert_output --partial 'write `testing-N.md` with no `handoff.verdict`'
  refute_output --partial '35 tool calls'
}

@test "dv-reference and resume.md: checkpoint on the TURN BUDGET line; exhaustion is surfaced" {
  run cat "$PLUGIN_ROOT/skills/worktask/references/dv-reference.md"
  assert_output --partial "**At the checkpoint turn** your brief's \`TURN BUDGET\` line names"
  assert_output --partial "The delegate's brief carries its own \`TURN BUDGET\` line"
  run cat "$PLUGIN_ROOT/skills/worktask/references/resume.md"
  assert_output --partial '`stage_resume_exhausted`'
}

@test "prescriptions: planners name git grep -P with a -w fallback, never a bare \\b anchor" {
  local f
  for f in agents/product-manager.md skills/worktask/references/pl0-procedure.md; do
    grep -qF 'git grep -P' "$PLUGIN_ROOT/$f" || fail "$f does not prescribe git grep -P"
    grep -qF 'git grep -w' "$PLUGIN_ROOT/$f" || fail "$f does not name the git grep -w fallback"
    grep -F '[[:<:]]' "$PLUGIN_ROOT/$f" | grep -vqF 'BSD/macOS-only' \
      && fail "$f names [[:<:]] without marking it BSD/macOS-only"
  done
  run grep -rF -e '`\b`-anchored greps' -e 'word-boundary anchors (`\b`)' \
    "$PLUGIN_ROOT/agents" "$PLUGIN_ROOT/skills"
  assert_failure 1
}
