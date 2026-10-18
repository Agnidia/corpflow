#!/usr/bin/env bats
# effort-ladder.sh — the effort tier ladder and the Step C.0a resolver's tier/model clamp.
#
# The load-bearing block is the parity check against model-selection.md: the library is the
# executable copy of a ladder whose canonical statement is prose, and only a comparison of
# the two catches a rung added on one side alone.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

LIB="skills/worktask/scripts/effort-ladder.sh"
MODEL_SELECTION="skills/shared/model-selection.md"
STATE_LEDGER="skills/shared/state-ledger.md"
STAGE_CODES="skills/shared/stage-codes.md"

# Every assertion sources the library; this keeps the boilerplate in one place.
ladder() { # <shell body>
  bash -c "set -euo pipefail; . '$PLUGIN_ROOT/$LIB'; $1"
}

# --- library authoring rules -------------------------------------------------

@test "the library defines its three constants" {
  run ladder "printf '%s|%s|%s' \"\$EFFORT_ENUM\" \"\$EFFORT_CAPPED_CEILING\" \"\$EFFORT_FULL_LADDER_RE\""
  assert_success
  assert_output 'low medium high xhigh max|high|^(opus|sonnet|fable)$'
}

@test "executing the library directly is refused" {
  run bash "$PLUGIN_ROOT/$LIB"
  assert_failure 2
  assert_output --partial "source it, do not execute it directly"
}

@test "the refusal names the CLI entry point" {
  run bash "$PLUGIN_ROOT/$LIB"
  assert_failure 2
  assert_output --partial "effort-ladder-cli.sh"
}

@test "a double source is a no-op, not a re-assignment failure" {
  run ladder ". '$PLUGIN_ROOT/$LIB'; printf ok"
  assert_success
  assert_output "ok"
}

# --- the ladder --------------------------------------------------------------

@test "effort_plus_one walks every rung" {
  run ladder 'for e in low medium high xhigh; do printf "%s " "$(effort_plus_one $e)"; done'
  assert_success
  assert_output "medium high xhigh max "
}

@test "effort_plus_one saturates at max rather than erroring" {
  run ladder 'effort_plus_one max'
  assert_success
  assert_output "max"
}

@test "effort_plus_one refuses a tier that is not on the ladder" {
  run ladder 'effort_plus_one ultra'
  assert_failure 2
  assert_output ""
}

@test "an empty effort is refused, never silently treated as low" {
  run ladder 'effort_plus_one ""'
  assert_failure 2
  assert_output ""
}

@test "the ladder survives a caller's non-default IFS" {
  # state-patch.sh runs under IFS=$'\n\t'. A bare `for t in $EFFORT_ENUM` there splits into
  # ONE word, so every tier reads as off-ladder and every stamped effort is rejected — which
  # is exactly how this shipped the first time.
  run bash -c "set -euo pipefail
    IFS=\$'\\n\\t'
    . '$PLUGIN_ROOT/$LIB'
    printf '%s %s %s' \"\$(effort_plus_one high)\" \"\$(effort_rank max)\" \
      \"\$(effort_for_resolver high haiku)\""
  assert_success
  assert_output "xhigh 4 high"
}

@test "effort_rank orders the ladder ascending" {
  run ladder 'for e in low medium high xhigh max; do printf "%s" "$(effort_rank $e)"; done'
  assert_success
  assert_output "01234"
}

# --- the tier/model clamp ----------------------------------------------------
#
# xhigh runs on Opus 5.5, Sonnet 5.5 and Fable 5.x; a pinned id outside those runs it at the
# highest level it supports, with no error. The clamp is what keeps a resolver from running two
# rungs below what its audit row claims.

@test "opus carries every bumped rung uncapped" {
  run ladder 'printf "%s %s %s" "$(effort_for_resolver high opus)" \
    "$(effort_for_resolver xhigh opus)" "$(effort_for_resolver max opus)"'
  assert_success
  assert_output "xhigh max max"
}

@test "fable carries every bumped rung uncapped" {
  run ladder 'effort_for_resolver xhigh fable'
  assert_success
  assert_output "max"
}

@test "sonnet (Sonnet 5.5) carries xhigh and max uncapped" {
  run ladder 'printf "%s %s %s" "$(effort_for_resolver high sonnet)" \
    "$(effort_for_resolver xhigh sonnet)" "$(effort_for_resolver max sonnet)"'
  assert_success
  assert_output "xhigh max max"
}

@test "haiku at high clamps to high instead of dispatching an evaporating xhigh" {
  run ladder 'effort_for_resolver high haiku'
  assert_success
  assert_output "high"
}

@test "the clamp lowers only — a haiku stage below the ceiling still gets its bump" {
  run ladder 'printf "%s %s" "$(effort_for_resolver low haiku)" \
    "$(effort_for_resolver medium haiku)"'
  assert_success
  assert_output "medium high"
}

@test "an unrecognized model alias clamps rather than assuming opus" {
  # The safe direction: a full model id or a typo must not buy an uncarryable tier.
  run ladder 'printf "%s %s" "$(effort_for_resolver high claude-opus-5-5)" \
    "$(effort_for_resolver high claude-sonnet-5-5)"'
  assert_success
  assert_output "high high"
}

@test "effort_for_resolver propagates an off-ladder tier as a failure" {
  run ladder 'effort_for_resolver ultra opus'
  assert_failure 2
}

# --- parity with the prose and frontmatter that own these values -------------

# Both stage-codes.md tables, normalized to `agent<TAB>model<TAB>effort`. They carry
# DIFFERENT column orders (Primary: Stage,Agent,Model,Effort — Support: Agent,Model,Effort,
# InvokedBy), so the header line selects the mapping. A single column-index guess reads the
# Support table's Model column as an agent name and passes vacuously.
#
# Retargeted (architecture-0.md#ad1/#ad6): § Primary Stages and § Support Agents no longer
# carry Model/Effort at all — that pair now lives in one agent-keyed § Agent Model Matrix
# table, read through model-matrix-lib.sh's own validated extractor rather than a second,
# bats-local awk. A fourth parser is a review reject (ad2); this suite is a consumer, not
# an implementation.
stage_table_rows() {
  ( . "$PLUGIN_ROOT/skills/worktask/scripts/model-matrix-lib.sh"; model_matrix_rows ) | sort -u
}

# Retargeted twice. ad6: agent files carry no model:/effort: any more, so "the agent actually
# ships" moved to what got stamped into the ledger. rework-3 (sw-AR0-1 reversed): --task-create
# auto-fill is REMOVED, so a caller must resolve first and paste — this now mirrors PL0's own
# real workflow end-to-end rather than a single seam: (1) model-matrix.sh --resolve <agent>,
# the same CLI subprocess PL0 calls (crosses the CLI/parsing boundary, not just a library call);
# (2) paste that resolved pair into --task-create's explicit --metadata, the same paste PL0
# performs, and read back what the ledger actually stored. Doing only (1) would compare the
# resolver against itself (model_resolve's rank-3 fallback IS model_matrix_rows, so a bare
# --resolve call proves nothing new the bijection test below does not already prove); step (2)
# is what still crosses a real seam post-reversal — it is the only place left that can catch a
# --task-create regression that silently rewrites an explicitly-given value, which is exactly
# the failure mode the reversal accepted responsibility for NOT catching upstream of the ledger.
ledger_stamped() { # <agent> <key>
  local resolved model effort rest state
  # Passes the real "corpflow:<name>" string (rework-4, F8): model_resolve normalizes at
  # its own boundary now, so this also re-covers the dv10 class a bare-basename call would
  # have missed — the reversal removed the auto-fill site the original bug lived in, but the
  # underlying "does the boundary strip the prefix" question is still worth asking here.
  # A bare --resolve now reads state.models/CORPFLOW.md from the root ladder; pin CONTEXT_DIR
  # to an empty dir so the parity is against the matrix, not this checkout's own ledger.
  resolved=$(CONTEXT_DIR="$(mktemp -d)" bash "$PLUGIN_ROOT/skills/worktask/scripts/model-matrix.sh" --resolve "corpflow:$1") || return 1
  model="${resolved%%$'\t'*}"
  rest="${resolved#*$'\t'}"
  effort="${rest%%$'\t'*}"
  state="$(mktemp -d)/state.json"
  printf '{"version":2,"tasks":{}}' > "$state"
  bash "$PLUGIN_ROOT/skills/worktask/scripts/state-patch.sh" --task-create DV9 --state "$state" \
    --metadata "{\"stage\":\"DV\",\"agent\":\"corpflow:$1\",\"model\":\"$model\",\"effort\":\"$effort\",
      \"plan_file\":\"planning-0.md\",\"run_index\":0,\"base_ref\":\"develop\",
      \"isolation\":\"worktree\",\"requires_screenshots\":false,\"workspace_path\":\"/tmp/x\"}" \
    > /dev/null
  jq -r ".tasks.DV9.metadata.$2" "$state"
}

@test "the extractor sees the agent model matrix and nothing else, one row per agents/*.md" {
  # Non-vacuity floor (ad2 rule 4): the row set is a BIJECTION with agents/*.md, stronger than
  # a hard-coded count. Two spot checks — one row that used to live only in § Primary Stages,
  # one that used to live only in § Support Agents — guard the old duplicate-row class (both
  # tables fed one matrix) without re-parsing either table.
  run stage_table_rows
  assert_success
  assert_line "developer	opus	high"
  assert_line "workflow-engineer	sonnet	medium"
  local agent_files
  agent_files=$(cd "$PLUGIN_ROOT/agents" && ls -1 ./*.md | sed 's/^\.\///; s/\.md$//' | sort)
  local matrix_agents
  matrix_agents=$(printf '%s\n' "${lines[@]}" | cut -f1 | sort)
  [ "$matrix_agents" = "$agent_files" ]
}

@test "every effort in stage-codes.md is a rung the ladder knows" {
  # Guards the direction that actually bites: a stage table gaining a tier the resolver
  # cannot bump, which would fail at dispatch rather than here.
  . "$PLUGIN_ROOT/$LIB"
  while IFS="$(printf '\t')" read -r _agent _model effort; do
    run effort_rank "$effort"
    assert_success
  done < <(stage_table_rows)
}

@test "the matrix and the ledger agree — every agent's stamped model and effort match its matrix row" {
  # Retargeted (architecture-0.md#ad6/REQ-7), then again in rework-4 (F9): the resolve half
  # (model-matrix.sh --resolve) is the resolver checked against itself — its rank-3 fallback IS
  # model_matrix_rows, so it proves nothing the bijection test above does not already prove.
  # What this still genuinely crosses is the ledger_stamped() paste step: does --task-create
  # persist an explicitly-given value unchanged. That is a real, narrower floor than the one
  # this test used to have before sw-AR0-1 removed --task-create's own auto-fill — see
  # `## rework-4` for why the floor is lower now and that is an accepted cost, not a defect.
  # This is what the RE row lost originally: the table said haiku for seven months after the
  # agent shipped sonnet. The lookup is only authoritative if it tracks what actually runs.
  while IFS="$(printf '\t')" read -r agent model effort; do
    [ -f "$PLUGIN_ROOT/agents/$agent.md" ] || fail "no agent file for '$agent'"
    [ "$(ledger_stamped "$agent" model)" = "$model" ] \
      || fail "$agent: matrix model '$model' != ledger-stamped '$(ledger_stamped "$agent" model)'"
    [ "$(ledger_stamped "$agent" effort)" = "$effort" ] \
      || fail "$agent: matrix effort '$effort' != ledger-stamped '$(ledger_stamped "$agent" effort)'"
  done < <(stage_table_rows)
}

# --- model-matrix-lib.sh extractor regression cases (architecture-0.md#ad2) ------------------
#
# Fixture docs in BATS_TEST_TMPDIR, never the live file — these exercise the parser against the
# exact two misfires reproduced twice at planning time, not against stage-codes.md's own content.

mml() { # <shell body>
  bash -c "set -euo pipefail; . '$PLUGIN_ROOT/skills/worktask/scripts/model-matrix-lib.sh'; $1"
}

@test "R1: a second table on the same page is not captured" {
  local doc="${BATS_TEST_TMPDIR}/r1.md"
  cat > "$doc" << 'EOF'
## Agent Model Matrix

| Agent | Model | Effort |
|-------|-------|--------|
| product-manager | opus | high |
| developer | opus | high |

## Secure overrides

| Code | Condition | Model | Effort |
|------|-----------|-------|--------|
| DC | `--secure` / `--full` | sonnet | medium |

| Code | Artifact |
|------|----------|
| DC | documentation-N.md |
EOF
  run mml "model_matrix_rows '$doc'"
  assert_success
  assert_line "product-manager	opus	high"
  assert_line "developer	opus	high"
  [ "${#lines[@]}" -eq 2 ] # neither later table's rows leaked in
}

@test "R1b: a note paragraph inside the section does not end capture" {
  # ad2 rule 1's OTHER half: R1 above only exercised "scope ends at the next # line".
  # This exercises "a note paragraph inside the section must NOT end capture" —
  # prose before the header, and prose between two data rows.
  local doc="${BATS_TEST_TMPDIR}/r1b.md"
  cat > "$doc" << 'EOF'
## Agent Model Matrix

A lead-in note paragraph, immediately under the heading and before the header row.

| Agent | Model | Effort |
|-------|-------|--------|
| product-manager | opus | high |

A second note paragraph, between two data rows, still inside the section.

| developer | opus | high |

## Secure overrides

| Code | Condition | Model | Effort |
|------|-----------|-------|--------|
| DC | `--secure` / `--full` | sonnet | medium |
EOF
  run mml "model_matrix_rows '$doc'"
  assert_success
  assert_line "product-manager	opus	high"
  assert_line "developer	opus	high"
  [ "${#lines[@]}" -eq 2 ] # neither note paragraph was read as a row
}

@test "R1c: a second table inside the same section fails closed rather than leaking rows" {
  # ad2 rule 1's second half, the other shape: a second table BEFORE the closing heading
  # (not after, like R1) must not silently blend its rows into the matrix. The header
  # assertion only fires once per section, so a later 4-cell table row is read as a
  # malformed 3-cell row — fail-closed (exit 3), never a leak.
  local doc="${BATS_TEST_TMPDIR}/r1c.md"
  cat > "$doc" << 'EOF'
## Agent Model Matrix

| Agent | Model | Effort |
|-------|-------|--------|
| product-manager | opus | high |

| Code | Condition | Model | Effort |
|------|-----------|-------|--------|
| DC | `--secure` / `--full` | sonnet | medium |

## Secure overrides
EOF
  run mml "model_matrix_rows '$doc'"
  assert_failure 3
  refute_line --partial 'DC'
}

@test "R2: a literal like opus is never read as an agent name" {
  local doc="${BATS_TEST_TMPDIR}/r2.md"
  cat > "$doc" << 'EOF'
## Agent Model Matrix

| Agent | Model | Effort |
|-------|-------|--------|
| product-manager | opus | high |
| opus | sonnet | high |
EOF
  run mml "model_matrix_rows '$doc'"
  assert_failure 3
  assert_output --partial "unknown agent opus"
  refute_line --partial 'opus	sonnet	high'
}

@test "R3: zero rows under the heading is the vacuity floor, not a silent pass" {
  local doc="${BATS_TEST_TMPDIR}/r3.md"
  cat > "$doc" << 'EOF'
## Agent Model Matrix

| Agent | Model | Effort |
EOF
  run mml "model_matrix_rows '$doc'"
  assert_failure 3
  assert_output --partial "zero rows"
}

@test "EFFORT_ENUM matches the ladder model-selection.md documents" {
  # § Effort Levels states the rungs with their glyphs; the library must not add or drop one.
  run grep -qF '`low` ○, `medium` ◐, `high` ●, `xhigh` ⬣, `max` ⬛' "$PLUGIN_ROOT/$MODEL_SELECTION"
  assert_success
}

@test "the uncapped aliases are the ones model-selection.md says carry xhigh" {
  run grep -qF '`xhigh` runs on **Opus 5.5, Sonnet 5.5 and Fable 5.x** (the `opus`, `sonnet` and `fable`' "$PLUGIN_ROOT/$MODEL_SELECTION"
  assert_success
  run grep -qF 'targets), so those aliases all carry it' "$PLUGIN_ROOT/$MODEL_SELECTION"
  assert_success
}

@test "the task.metadata schema pins the same enum the ladder defines" {
  # state-ledger.md carries the tiers a third time, as a JSON enum the orchestrator validates
  # against. Three copies, so the drift has two chances to happen.
  . "$PLUGIN_ROOT/$LIB"
  # NOT `paste -sd', '`: BSD paste cycles through the delimiter LIST, so a two-char
  # delimiter alternates ',' and ' ' and the join comes out malformed on macOS.
  want=$(printf '%s' "$EFFORT_ENUM" | sed 's/[a-z][a-z]*/"&"/g; s/ /, /g')
  run grep -qF "\"enum\": [$want]" "$PLUGIN_ROOT/$STATE_LEDGER"
  assert_success
}

@test "effort is a required task.metadata field, not an optional dispatch flag" {
  run grep -qF '"required": ["stage", "agent", "model", "effort", "error_file"]' \
    "$PLUGIN_ROOT/$STATE_LEDGER"
  assert_success
  # And it must be gone from the optional set it used to live in.
  run bash -c "awk '/^### Dispatch metadata \\(optional\\)/{f=1;next} /^###/{f=0} f' \
    '$PLUGIN_ROOT/$STATE_LEDGER' | grep -c '\`effort\`'"
  assert_output "0"
}
