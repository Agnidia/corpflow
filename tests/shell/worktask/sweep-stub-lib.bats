#!/usr/bin/env bats
# sweep-stub-lib.sh — the SweepStub predicate shared by the two enforcers of
# handoff.open_questions[]: handoff-harness.sh (frontmatter shape gate) and
# state-patch.sh --facts (ledger writer).
#
# The load-bearing block is the parity table: the library deduplicates the VALUES,
# and only a per-row verdict comparison across both enforcers deduplicates the
# SEMANTICS. One constant applied two ways still drifts.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

LIB="skills/worktask/scripts/sweep-stub-lib.sh"
HARNESS="skills/worktask/scripts/handoff-harness.sh"
PATCH="skills/worktask/scripts/state-patch.sh"
PROTOCOL="skills/worktask/references/handoff-protocol.md"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context"
  printf '%s\n' '{"version":2,"worktask_id":"wt-sweep","tasks":{},"facts":{}}' \
    > "$WD/state.json"
  # The ref-anchor check resolves a stub's ref beside the artifact, so a passing row needs
  # its target to exist; a failing row never reaches that check.
  # The item under it carries two options, so the harness's item-body check never decides a row.
  printf '# Planning\n\n## elicitation-sweep\n\n- id: sw-PL0-1\n  summary: "Which way?"\n  options:\n    - { label: "A", detail: "first" }\n    - { label: "B", detail: "second" }\n' \
    > "$WD/planning-0.md"
}

# --- library authoring rules -------------------------------------------------

@test "the library defines all three constants" {
  run bash -c ". '$PLUGIN_ROOT/$LIB'
    printf '%s|%s|%s' \"\$SWEEP_ID_RE\" \"\$SWEEP_CLASS_ENUM\" \"\$SWEEP_REF_RE\""
  assert_success
  assert_output '^sw-[A-Z]{2}[0-9]+-[0-9]+$|decision escalate|^([A-Za-z0-9._/-]+\.md)?#[a-z0-9][a-z0-9-]*$'
}

@test "executing the library directly is refused" {
  run bash "$PLUGIN_ROOT/$LIB"
  assert_failure 2
  assert_output --partial "source it, do not execute it directly"
}

@test "a double source is a no-op, not a re-assignment failure" {
  run bash -c "set -euo pipefail
    cd '$PLUGIN_ROOT'
    . '$LIB'
    . '$LIB'
    printf '%s' \"\$SWEEP_ID_RE\""
  assert_success
  assert_output '^sw-[A-Z]{2}[0-9]+-[0-9]+$'
}

@test "the library sources nothing and sets no shell options" {
  run grep -nE '^[[:space:]]*(set|shopt|trap|cd|export)[[:space:]]' "$PLUGIN_ROOT/$LIB"
  assert_failure
  run grep -nE '^[[:space:]]*(\.|source)[[:space:]]' "$PLUGIN_ROOT/$LIB"
  assert_failure
}

# --- the parity table (architecture-0.md#test-architecture) ------------------

# One stub through the frontmatter gate. Echoes "pass" or "fail".
_harness_verdict() {  # <stub-yaml>
  local art="$WD/development-0.md"
  cat > "$art" <<EOF
---
handoff:
  stage: DV
  verdict: ok
  summary: "parity fixture"
  tests_executed: [{ runner: bats, count: 12, summary_line: "12 tests, 0 failures" }]
  files_touched: 1
  next_stage_focus: "review"
  open_questions:
    - $1
  refs:
    plan: planning-0.md#requirements
---
# Development

## files-changed

x

## tests-added

12 tests, 0 failures

## deviations

none

## follow-ups

none

## elicitation-sweep

- id: sw-PL0-1
  summary: "Which way?"
  options:
    - { label: "A", detail: "first" }
    - { label: "B", detail: "second" }
EOF
  if bash "$PLUGIN_ROOT/$HARNESS" --validate-frontmatter "$art" > /dev/null 2>&1; then
    printf 'pass'
  else
    printf 'fail'
  fi
}

# The same stub through the ledger writer. Echoes "pass" or "fail".
_patch_verdict() {  # <stub-json>
  if bash "$PLUGIN_ROOT/$PATCH" --facts "{\"open_questions\":[$1]}" \
       --state "$WD/state.json" > /dev/null 2>&1; then
    printf 'pass'
  else
    printf 'fail'
  fi
}

@test "parity: every fixture row gets the SAME verdict from both enforcers" {
  local n=0 row yaml json want hv pv
  # <expected>|<yaml stub>|<json stub>
  while IFS='|' read -r want yaml json; do
    [ -n "$want" ] || continue
    n=$((n + 1))
    hv="$(_harness_verdict "$yaml")"
    pv="$(_patch_verdict "$json")"
    [ "$hv" = "$want" ] || fail "harness verdict $hv, expected $want, for: $yaml"
    [ "$pv" = "$want" ] || fail "ledger verdict $pv, expected $want, for: $json"
  done <<'ROWS'
pass|{ id: sw-PL0-1, class: decision, ref: "planning-0.md#elicitation-sweep", blocks_next_stage: false }|{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}
fail|{ id: sw-PL0-1, class: decision, ref: "", blocks_next_stage: false }|{"id":"sw-PL0-1","class":"decision","ref":"","blocks_next_stage":false}
fail|{ id: sw-PL0-1, class: decision, ref: "planning-0.md", blocks_next_stage: false }|{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md","blocks_next_stage":false}
fail|{ id: sw-PL0-1, class: question, ref: "planning-0.md#elicitation-sweep", blocks_next_stage: false }|{"id":"sw-PL0-1","class":"question","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}
fail|{ id: sw-P0-1, class: decision, ref: "planning-0.md#elicitation-sweep", blocks_next_stage: false }|{"id":"sw-P0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}
fail|{ id: swPL0-1, class: decision, ref: "planning-0.md#elicitation-sweep", blocks_next_stage: false }|{"id":"swPL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}
pass|{ id: sw-PL0-1, class: escalate, ref: "#elicitation-sweep", blocks_next_stage: false }|{"id":"sw-PL0-1","class":"escalate","ref":"#elicitation-sweep","blocks_next_stage":false}
fail|{ id: sw-PL0-1, class: decision, ref: "planning-0.md#elicitation-sweep" }|{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep"}
ROWS
  [ "$n" -eq 8 ] || fail "non-vacuity: only $n parity rows exercised"
}

# --- the constants agree with the schema that documents them -----------------

@test "the id pattern matches every $defs/SweepStub site in handoff-protocol.md" {
  local re n
  re="$(sed -n "s/^SWEEP_ID_RE='\(.*\)'$/\1/p" "$PLUGIN_ROOT/$LIB")"
  [ -n "$re" ] || fail "non-vacuity: no id pattern extracted from the library"
  # Three SweepStub id: definitions plus the settles-item reference that must accept them.
  n="$(grep -cF "pattern: '$re'" "$(contract_source "$PLUGIN_ROOT/$PROTOCOL")")"
  [ "$n" -eq 4 ] || fail "id pattern documented at $n schema sites, expected 4"
}

@test "the class enum matches the documented SweepStub enum" {
  local enum
  enum="$(sed -n "s/^SWEEP_CLASS_ENUM='\(.*\)'$/\1/p" "$PLUGIN_ROOT/$LIB" | sed 's/ /, /g')"
  grep -qF "enum: [${enum}]" "$(contract_source "$PLUGIN_ROOT/$PROTOCOL")" \
    || fail "library class enum does not match the schema enum: [$enum]"
}

# --- lib-missing posture, per enforcer ---------------------------------------

@test "the shape gate refuses to run at all when the library is unreachable" {
  local copy="$WD/scripts"
  mkdir -p "$copy"
  cp "$PLUGIN_ROOT/$HARNESS" "$copy/handoff-harness.sh"
  run bash "$copy/handoff-harness.sh" --validate-frontmatter "$WD/development-0.md"
  assert_failure 1
  assert_output --partial "sweep-stub-lib.sh unreachable"
}

@test "the ledger writer refuses --facts, with state.json byte-identical" {
  local copy="$WD/scripts" before after
  mkdir -p "$copy"
  cp "$PLUGIN_ROOT/$PATCH" "$copy/state-patch.sh"
  before="$(cksum < "$WD/state.json")"
  run bash "$copy/state-patch.sh" --facts \
    '{"open_questions":[{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep"}]}' \
    --state "$WD/state.json"
  assert_failure 2
  assert_output --partial "sweep-stub-lib.sh unreachable"
  after="$(cksum < "$WD/state.json")"
  [ "$before" = "$after" ] || fail "state.json changed on a refused --facts"
}
