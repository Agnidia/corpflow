#!/usr/bin/env bats
# Pins agents/software-architector.md § Consult Gate (AR): the platform-architect consult opens
# at the first score of the estimation table's High tier, and the open path dispatches on
# Sonnet with a capped return. Both sides are read from their defining files, never hardcoded.
# It also pins the reconcile step and checkbox that hold the merged consult to key_decisions.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

ARCH="agents/software-architector.md"
EST="skills/estimation-methodology/SKILL.md"
HANDOFF="skills/cross-plugin-handoff/SKILL.md"

# Body of one markdown section: from its heading to the next heading of any level.
section() {
  awk -v h="$2" 'index($0, h) == 1 { on = 1; next } on && /^#/ { exit } on { print }' "$1"
}

# Lower bound of the High row in the stage-set table, e.g. "31".
high_floor() {
  awk -F'|' '$3 ~ / High / { gsub(/ /, "", $2); split($2, r, "–"); print r[1]; exit }' "$1"
}

gate_floor() {
  section "$1" "#### Consult Gate (AR)" | grep -oE '≥ ?[0-9]+' | head -1 | tr -dc '0-9'
}

@test "gate floor equals the High tier floor" {
  cd "$PLUGIN_ROOT"
  want="$(high_floor "$EST")"
  got="$(gate_floor "$ARCH")"
  [ -n "$want" ] && [ "$got" = "$want" ]
}

@test "gate floor check fails on a planted Moderate floor" {
  cd "$PLUGIN_ROOT"
  planted="$BATS_TEST_TMPDIR/arch.md"
  sed 's/High+ (≥ 31/Moderate+ (≥ 21/' "$ARCH" > "$planted"
  [ "$(gate_floor "$planted")" != "$(high_floor "$EST")" ]
}

@test "the old Low-only gate heading is gone" {
  cd "$PLUGIN_ROOT"
  ! grep -q "Low-Complexity Gate" "$ARCH"
}

@test "open gate dispatches on sonnet with a capped return" {
  cd "$PLUGIN_ROOT"
  section "$ARCH" "### Delegation Flow" | grep -q 'model: "sonnet"'
  section "$ARCH" "### Delegation Flow" | grep -q '≤300 tokens'
  grep -q 'model: "sonnet"' "$HANDOFF"
  grep -q 'max 300 tokens' "$HANDOFF"
}

@test "completion checklist keys on the gate, not the tier" {
  cd "$PLUGIN_ROOT"
  section "$ARCH" "## Completion Verification" | grep -q "Consult Gate (AR)"
}

# Delegation Flow step 5: the merged consult text is checked against key_decisions and each
# conflict reconciled. Lowercase "reconcil" on purpose: the step must say it, not a heading.
reconcile_step() {
  section "$1" "### Delegation Flow" | grep -E '^5\. ' | grep -F 'key_decisions' | grep -q 'reconcil'
}

# The Completion Verification checkbox for the same rule. Three anchors, because the gate
# checkbox above it already holds "consulted" and `key_decisions` and would pass a two-anchor pin.
reconcile_checkbox() {
  section "$1" "## Completion Verification" | grep -E '^- \[ \] ' \
    | grep -E '(^|[^A-Za-z])consult([^A-Za-z]|$)' | grep -F 'key_decisions' | grep -q 'reconcil'
}

@test "Delegation Flow step 5 reconciles consult statements with key_decisions" {
  cd "$PLUGIN_ROOT"
  reconcile_step "$ARCH"
}

@test "the step-5 pin fails on a copy with the step stripped" {
  cd "$PLUGIN_ROOT"
  stripped="$BATS_TEST_TMPDIR/arch-no-step5.md"
  grep -vE '^5\. .*reconcil' "$ARCH" > "$stripped"
  run reconcile_step "$stripped"
  assert_failure
}

@test "Completion Verification carries the consult-vs-key_decisions checkbox" {
  cd "$PLUGIN_ROOT"
  reconcile_checkbox "$ARCH"
}

@test "the checkbox pin fails on a copy with the checkbox stripped" {
  cd "$PLUGIN_ROOT"
  stripped="$BATS_TEST_TMPDIR/arch-no-checkbox.md"
  grep -vE '^- \[ \] .*consult.*reconcil' "$ARCH" > "$stripped"
  run reconcile_checkbox "$stripped"
  assert_failure
}

SR="agents/security-reviewer.md"

@test "SR gate floor equals the High tier floor too" {
  cd "$PLUGIN_ROOT"
  got="$(section "$SR" "### Consult Gate (SR)" | grep -oE '≥ ?[0-9]+' | head -1 | tr -dc '0-9')"
  [ "$got" = "$(high_floor "$EST")" ]
}

@test "SR dispatch injection sits behind the gate" {
  cd "$PLUGIN_ROOT"
  section "$SR" "### Dispatch Injection (REQUIRED)" | grep -q "Only past § Consult Gate (SR)"
  section "$SR" "### Consult Gate (SR)" | grep -q "consult: skipped"
}
