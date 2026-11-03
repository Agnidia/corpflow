#!/usr/bin/env bats
# agent-effort-frontmatter.bats — R2: each agents/*.md `effort:` key must equal that
# agent's Effort cell in the built-in Agent Model Matrix (model-matrix.sh --rows,
# CORPFLOW.md/state.models overrides ignored — the frontmatter is a static tier, not a
# per-run resolution). Follows the state-patch suite's replay side-effect-list parity
# test: one comparator, exercised against the live tree once and against a mutated
# temp copy for every drift shape planning-1.md#requirements (R2) names.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

MATRIX_LIB="skills/worktask/scripts/model-matrix-lib.sh"
STAGE_CODES="skills/worktask/references/stage-codes.md"

# parity_report <agents_dir> [doc] -> one line per outcome on stdout:
#   "ok <agent>"              — frontmatter effort == matrix effort
#   "MISSING <agent>"          — no effort: key (or empty value) under the agent's frontmatter
#   "MISMATCH <agent> fm=<x> mx=<y>" — key present, value differs from the matrix
#   "ORPHAN_AGENT <agent>"     — an agents/*.md file with no row in the matrix
# A malformed matrix or an agents_dir where every row's file check fails (model_matrix_rows'
# own vacuity/existence guards) propagates that exit code unchanged — fail-closed, never a
# silent "0 agents, 0 drift" pass.
parity_report() {
  local dir="$1" doc="${2:-$PLUGIN_ROOT/$STAGE_CODES}"
  local mrows
  mrows=$(
    . "$PLUGIN_ROOT/$MATRIX_LIB"
    model_matrix_rows "$doc" "$dir"
  ) || return $?

  local agent model mx fm
  while IFS=$'\t' read -r agent model mx; do
    fm=$(awk '/^---[[:space:]]*$/{c++;next} c==1 && /^effort:[[:space:]]*/{
      sub(/^effort:[[:space:]]*/, ""); print; exit}' "$dir/$agent.md" 2> /dev/null)
    if [ -z "$fm" ]; then
      printf 'MISSING %s\n' "$agent"
    elif [ "$fm" != "$mx" ]; then
      printf 'MISMATCH %s fm=%s mx=%s\n' "$agent" "$fm" "$mx"
    else
      printf 'ok %s\n' "$agent"
    fi
  done <<< "$mrows"

  local f name matrix_agents
  matrix_agents=$(printf '%s\n' "$mrows" | cut -f1)
  for f in "$dir"/*.md; do
    name=$(basename "$f" .md)
    printf '%s\n' "$matrix_agents" | grep -qx "$name" || printf 'ORPHAN_AGENT %s\n' "$name"
  done
}

# mk_agents_copy -> path to a throwaway copy of the live agents/ dir, for the
# mutation cases; never touch $PLUGIN_ROOT/agents itself.
mk_agents_copy() {
  local d
  d="$(mk_tmpworkdir)/agents"
  cp -R "$PLUGIN_ROOT/agents" "$d"
  printf '%s' "$d"
}

@test "parity: the live tree reports ok for all agents, nothing else" {
  local expected_count
  expected_count=$(ls "$PLUGIN_ROOT"/agents/*.md | wc -l | tr -d ' ')
  run parity_report "$PLUGIN_ROOT/agents"
  assert_success
  [ "${#lines[@]}" -eq "$expected_count" ]
  for line in "${lines[@]}"; do
    case "$line" in
      "ok "*) ;;
      *) fail "unexpected non-ok line: $line" ;;
    esac
  done
}

@test "drift: a missing effort: key is named, not silently skipped" {
  local dir; dir="$(mk_agents_copy)"
  perl -0pi -e 's/^effort:\s*\S+\n//m' "$dir/designer.md"
  run parity_report "$dir"
  assert_success
  assert_line "MISSING designer"
  refute_line --partial "MISMATCH designer"
}

@test "drift: a value mismatch names the agent and both values" {
  local dir; dir="$(mk_agents_copy)"
  sed -i.bak 's/^effort: medium$/effort: xhigh/' "$dir/designer.md"
  run parity_report "$dir"
  assert_success
  assert_line "MISMATCH designer fm=xhigh mx=medium"
}

@test "drift: an orphan agent (no matrix row) is flagged, not treated as a pass" {
  local dir; dir="$(mk_agents_copy)"
  cat > "$dir/ghost.md" << 'EOF'
---
name: ghost
description: fixture-only agent with no matrix row.
color: white
version: 0.0.1
maxTurns: 10
effort: low
---
Fixture body.
EOF
  local expected_count
  expected_count=$(ls "$PLUGIN_ROOT"/agents/*.md | wc -l | tr -d ' ')
  run parity_report "$dir"
  assert_success
  assert_line "ORPHAN_AGENT ghost"
  # every real agent still reports ok alongside the orphan
  local ok_count=0 line
  for line in "${lines[@]}"; do
    case "$line" in "ok "*) ok_count=$((ok_count + 1)) ;; esac
  done
  [ "$ok_count" -eq "$expected_count" ]
}

@test "drift: an orphan matrix row (agent file absent) fails closed, not a silent pass" {
  local dir; dir="$(mk_agents_copy)"
  rm "$dir/designer.md"
  run parity_report "$dir"
  assert_failure 3
  assert_output --partial "unknown agent designer"
}

@test "empty parse: a matrix doc with zero rows fails closed rather than reporting zero drift" {
  local dir; dir="$(mk_agents_copy)"
  local doc="${BATS_TEST_TMPDIR}/empty-matrix.md"
  cat > "$doc" << 'EOF'
## Agent Model Matrix

| Agent | Model | Effort |
EOF
  run parity_report "$dir" "$doc"
  assert_failure 3
  assert_output --partial "zero rows"
}

@test "empty parse: an agents_dir with none of the matrix's files fails closed per-row" {
  # Every row's existence check fails before any effort comparison runs — the same
  # fail-closed guard model_matrix_rows already gives model-matrix.sh --rows itself.
  local dir; dir="$(mk_tmpworkdir)/empty-agents"
  mkdir -p "$dir"
  run parity_report "$dir"
  assert_failure 3
  assert_output --partial "unknown agent"
}
