#!/usr/bin/env bats
# Parity guard for the stage->artifact-basename mapping, which is duplicated
# across the SEVEN sources of truth listed below, with no single owner.
#
# This exists because the duplication has already drifted once: cada9e4 (v3.8.0)
# normalized four sibling artifact basenames and missed AR's, leaving `analyzing`
# stranded until 3.42.0. A half-applied rename across these six is invisible to
# every other test in the suite -- state-merge.sh's map in particular is only
# reachable when state-patch.sh is absent, so nothing exercises it organically.
#
# state-patch.sh additionally accepts resolution-only ALIAS basenames. They live in
# a sibling function so the extractor below keeps seeing exactly one canonical name
# per stage; the alias tests assert that separation rather than relaxing it.
#
# Sources:
#   1. skills/worktask/scripts/cache-lint.sh   _STAGE_TABLE (field 3)
#   2. skills/worktask/scripts/state-patch.sh  basename_for_stage()
#   3. hooks/state-merge.sh                    _basename_for_stage()
#   4. skills/worktask/references/orchestration.md                ARTIFACT_BASE (orchestrator executes it)
#   5. hooks/anchor-preflight.sh               ARTIFACT_RE alternation
#   6. handoff-protocol.md                     #stage-artifact-map table
#   7. agents/workflow-engineer.md             manual-repair brace-glob (basenames only,
#                                              so compared as a SET, not a stage->name map)
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

STAGES="PL AR TL DV DR SR QA DC RE FN ST IR ET"

# Extract a map by slicing the function body with awk, then pulling the case
# arms with sed. Deliberately avoids gawk's 3-argument match() -- the macOS awk
# this repo's suite runs under is BWK awk, which does not have it.
map_from_case() { # <abs-file> <fn-name>
  awk -v fn="$2" '
    $0 ~ "^_?" fn "\\(\\)" { infn=1; next }
    infn && /^}/ { exit }
    infn { print }
  ' "$1" \
    | sed -nE "s/^[[:space:]]*([A-Z]{2})\)[[:space:]]*(echo|printf)[[:space:]]*['\"]([a-z-]+)['\"].*/\1=\3/p"
}

expected_map() {
  cat <<'EOF'
PL=planning
AR=architecture
TL=coordination
DV=development
DR=developer-review
SR=security-review
QA=testing
DC=documentation
RE=release
FN=complete-summary
ST=retrospective
IR=incident
ET=ethics-review
EOF
}

# cache-lint.sh holds all four of its per-stage facts in one `_STAGE_TABLE` row
# set rather than in four parallel case tables, so its canonical basename is
# field 3 of the row rather than a case arm. Extracted here, not read by
# sourcing the script: sourcing it would run its argument dispatch.
map_from_stage_table() { # <abs-file>
  awk "
    /^_STAGE_TABLE='/ { sub(/^_STAGE_TABLE='/, \"\"); intbl = 1 }
    intbl {
      last = (\$0 ~ /'\$/)
      sub(/'\$/, \"\")
      if (NF >= 3) print \$1 \"=\" \$3
      if (last) exit
    }
  " "$1"
}

@test "parity: cache-lint.sh _STAGE_TABLE matches the canonical map" {
  run map_from_stage_table "$PLUGIN_ROOT/skills/worktask/scripts/cache-lint.sh"
  assert_success
  [ "$output" = "$(expected_map)" ]
}

@test "parity: state-patch.sh basename_for_stage matches the canonical map" {
  run map_from_case "$PLUGIN_ROOT/skills/worktask/scripts/state-patch.sh" basename_for_stage
  assert_success
  [ "$output" = "$(expected_map)" ]
}

@test "parity: state-patch.sh primary map holds exactly the 13 canonical stages" {
  # The alias tier must never leak into the primary map: a 14th arm here would mean
  # some stage now has two canonical names, which is the drift this file guards.
  run map_from_case "$PLUGIN_ROOT/skills/worktask/scripts/state-patch.sh" basename_for_stage
  assert_success
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "13" ]
  [ "$(printf '%s\n' "$output" | cut -d= -f1 | sort -u | tr '\n' ' ')" = "$(printf '%s\n' $STAGES | sort -u | tr '\n' ' ')" ]
}

@test "parity: state-patch.sh aliases are disjoint from every canonical basename" {
  # An alias colliding with another stage's canonical name would let --stage X resolve
  # stage Y's artifact and silently patch the wrong ledger entry.
  run map_from_case "$PLUGIN_ROOT/skills/worktask/scripts/state-patch.sh" alias_basenames_for_stage
  assert_success
  local canonical alias_name stage rc=0
  canonical="$(expected_map | cut -d= -f2 | sort)"
  while IFS='=' read -r stage alias_name; do
    [ -n "$alias_name" ] || continue
    if printf '%s\n' "$canonical" | grep -qx "$alias_name"; then
      echo "alias '$alias_name' (stage=$stage) collides with a canonical basename"
      rc=1
    fi
  done <<< "$output"
  [ "$rc" -eq 0 ]
}

@test "parity: state-merge.sh _basename_for_stage matches the canonical map" {
  # Unreachable in normal runs (only used when state-patch.sh is absent), so this
  # is the ONLY test that ever reads it.
  run map_from_case "$PLUGIN_ROOT/hooks/state-merge.sh" _basename_for_stage
  assert_success
  [ "$output" = "$(expected_map)" ]
}

@test "parity: worktask/SKILL.md ARTIFACT_BASE matches the canonical map" {
  # The orchestrator executes this TypeScript block; drift here misroutes every
  # artifact lookup.
  run bash -c '
    awk "/const ARTIFACT_BASE/,/^};/" "$1" \
      | grep -oE "[A-Z]{2}: \"[a-z-]+\"" \
      | sed -E "s/([A-Z]{2}): \"([a-z-]+)\"/\1=\2/"
  ' _ "$(contract_source "$PLUGIN_ROOT/skills/worktask/references/orchestration.md")"
  assert_success
  [ "$output" = "$(expected_map)" ]
}

@test "parity: anchor-preflight.sh ARTIFACT_RE covers every canonical basename" {
  # The regex is structured differently (development carries an optional
  # -<stream> suffix and sits outside the alternation), so assert coverage by
  # matching a real path per stage rather than comparing text.
  # Both the self-test and the regex extraction are loop-invariant: run each
  # once. Repeating them per stage cost 13 subprocess pairs and asserted the
  # same thing 13 times.
  run bash "$PLUGIN_ROOT/hooks/anchor-preflight.sh" --self-test
  assert_success

  local artifact_re
  artifact_re="$(grep -oE "ARTIFACT_RE='[^']+'" "$PLUGIN_ROOT/hooks/anchor-preflight.sh" \
    | sed "s/ARTIFACT_RE='//; s/'$//")"
  [ -n "$artifact_re" ]

  local stage base rc=0
  while IFS='=' read -r stage base; do
    printf '%s' ".context/${base}-0.md" | grep -qE "$artifact_re" \
      || { echo "ARTIFACT_RE does not accept .context/${base}-0.md (stage=$stage)"; rc=1; }
  done < <(expected_map)
  [ "$rc" -eq 0 ]
  # Falsification guard: the regex must not accept an arbitrary artifact name,
  # or the coverage loop above would pass no matter what the map contained.
  run bash -c 'printf "%s" ".context/not-an-artifact-0.md" | grep -qE "$1"' _ "$artifact_re"
  assert_failure
}

@test "parity: handoff-protocol.md #stage-artifact-map matches the canonical map" {
  run bash -c '
    awk "/^## #stage-artifact-map/,/^### Run-index resolution/" "$1" \
      | grep -E "^\| [A-Z]{2} \|" \
      | sed -E "s/^\| ([A-Z]{2}) \| .?([a-z-]+)-N\.md.*/\1=\2/"
  ' _ "$(contract_source "$PLUGIN_ROOT/skills/worktask/references/handoff-protocol.md")"
  assert_success
  [ "$output" = "$(expected_map)" ]
}

@test "parity: no source of truth mentions the pre-3.42.0 'analyzing' basename" {
  # Guards the specific half-rename this test was written for.
  local f
  for f in skills/worktask/scripts/cache-lint.sh \
           skills/worktask/scripts/state-patch.sh \
           hooks/state-merge.sh \
           hooks/anchor-preflight.sh; do
    run bash -c 'grep -nE "\"analyzing\"|'"'"'analyzing'"'"'|\|analyzing\|" "$1" || true' _ "$(contract_source "$PLUGIN_ROOT/$f")"
    assert_output ""
  done
}

@test "parity: workflow-engineer.md repair glob covers exactly the canonical basenames" {
  # A seventh copy: the brace-glob in the state.json manual-repair runbook that an
  # operator is told to paste into a shell. It carries basenames without stage
  # codes, so compare it as a set -- a missing member silently skips artifacts
  # during a repair, which is precisely when the ledger is already damaged.
  # Fail loudly rather than head -1 if a SECOND glob ever appears: silently
  # checking only the first would let a divergent copy ride along unwatched,
  # which is the exact failure mode this whole file exists to prevent.
  run bash -c 'grep -coE "\.context/\{[a-z,-]+\}-\*\.md" "$1"' _ "$PLUGIN_ROOT/agents/workflow-engineer.md"
  assert_success
  [ "$output" = "1" ] || {
    echo "expected exactly 1 repair glob in workflow-engineer.md, found $output — add each to this test"
    return 1
  }

  run bash -c '
    grep -oE "\.context/\{[a-z,-]+\}-\*\.md" "$1" \
      | sed -E "s/^\.context\/\{//; s/\}-\*\.md$//" | tr "," "\n" | sort
  ' _ "$PLUGIN_ROOT/agents/workflow-engineer.md"
  assert_success
  [ "$output" = "$(expected_map | cut -d= -f2 | sort)" ]
}
