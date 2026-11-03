#!/usr/bin/env bats
# Single-sourcing contract for depth-cap visibility.
# (PATH-KEYED filename: agent-coordination__dispatch-depth.bats — the AC-2 gate
# matches on path-derived stems, so a basename collision could never claim
# false coverage.)
#
# The depth cap silently drops a Tier-2 specialist: no hook fires, and the
# refused dispatcher completes the work itself. Two documented mechanisms make
# that visible, and each is only load-bearing if the other half exists —
# an enum value with no contract is undocumented, a contract with no enum value
# is unwritable. These tests pin both halves together:
#
#   - both actions are registered in the audit action registry AND the Writers table
#   - the self-report contract section exists and names all three required fields
#   - worktask check 11 exists, emits the projection row, and never blocks
#   - the two depth projections cross-link, so neither can be edited alone
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

COORD="$PLUGIN_ROOT/skills/agent-coordination/SKILL.md"
REGISTRY="$PLUGIN_ROOT/skills/agent-coordination/references/audit-actions.md"
WORKTASK="$(contract_source "$PLUGIN_ROOT/skills/worktask/references/orchestration.md")"
MEGATASK="$PLUGIN_ROOT/skills/megatask/SKILL.md"

# The audit `action` registry is the `actions:` lines of references/audit-actions.md.
_enum_line() { grep '^actions: ' "$REGISTRY" | tr '\n' ' '; }

# --- schema registration --------------------------------------------------
@test "schema: dispatch_flattened is a member of the audit action enum" {
  run _enum_line
  assert_success
  assert_output --partial "dispatch_flattened"
}

@test "schema: dispatch_depth_projected is a member of the audit action enum" {
  run _enum_line
  assert_success
  assert_output --partial "dispatch_depth_projected"
}

# An action defined in the enum but absent from the Writers table has no owner —
# that asymmetry is how the audit schema drifts, so both halves are pinned.
@test "schema: both actions are registered in the Writers table, not just the enum" {
  local writers
  writers="$(awk '/^### Writers$/,/^#### Writers — plugin hooks/' "$COORD")"
  echo "$writers" | grep -q 'dispatch_depth_projected' \
    || fail "Writers table does not register dispatch_depth_projected"
  echo "$writers" | grep -q 'dispatch_flattened' \
    || fail "Writers table does not register dispatch_flattened"
}

# --- the self-report contract ---------------------------------------------
@test "contract: the Depth-refusal self-report section exists" {
  run grep -c '^#### Depth-refusal self-report$' "$COORD"
  assert_success
  assert_output "1"
}

@test "contract: the row is required BEFORE the inline work, not after" {
  local section
  section="$(awk '/^#### Depth-refusal self-report$/,/^#### Background-by-default dispatch$/' "$COORD")"
  # "does the work then forgets" is the failure mode being designed around;
  # ordering is the whole contract, so it must be stated, not implied.
  echo "$section" | grep -qi 'BEFORE' \
    || fail "self-report contract does not require the row before the inline work"
}

@test "contract: all three required fields are named — specialist, depth, cap" {
  local section
  section="$(awk '/^#### Depth-refusal self-report$/,/^#### Background-by-default dispatch$/' "$COORD")"
  # A row saying only "flattening happened" cannot tell an operator which
  # specialist's judgment is missing from the output.
  echo "$section" | grep -q 'attempted_depth' || fail "contract omits attempted_depth"
  echo "$section" | grep -q 'metadata.cap'    || fail "contract omits metadata.cap"
  echo "$section" | grep -qi 'subject'        || fail "contract omits the subject (specialist) field"
}

# --- worktask pre-stage check 11 ------------------------------------------
@test "check 11: Pre-Stage Validation defines an 11th check" {
  run grep -c '^### Validation check 11$' "$WORKTASK"
  assert_success
  assert_output "1"
}

@test "check 11: emits dispatch_depth_projected and is declared non-blocking" {
  local section
  section="$(awk '/^### Validation check 11$/,/^### On validation failure$/' "$WORKTASK")"
  echo "$section" | grep -q 'dispatch_depth_projected' \
    || fail "check 11 does not emit a dispatch_depth_projected row"
  # A hard gate here would fail the canonical DV chain, which legitimately sits
  # at exactly the cap — the precedent is check 8's artifact_path_resolved.
  echo "$section" | grep -q 'non-blocking' \
    || fail "check 11 is not marked non-blocking"
  echo "$section" | grep -qi 'Never blocks' \
    || fail "check 11 does not state that it never blocks"
}

@test "check 11: checks 1-10 are still present and unrenumbered" {
  # check 11 is additive; a renumber would silently redefine every other check.
  for n in 8 9 10; do
    grep -q "^### Validation check ${n}\$" "$WORKTASK" \
      || fail "Validation check ${n} heading went missing"
  done
  grep -q '^### Validation checks 1–5$' "$WORKTASK" || fail "checks 1–5 heading went missing"
  grep -q '^### Validation checks 6–7$' "$WORKTASK" || fail "checks 6–7 heading went missing"
}

# --- the two projections must stay one formula ----------------------------
@test "cross-link: worktask check 11 points at megatask's canonical level table" {
  local section
  section="$(awk '/^### Validation check 11$/,/^### On validation failure$/' "$WORKTASK")"
  echo "$section" | grep -q 'skills/megatask/SKILL.md' \
    || fail "check 11 does not cross-link megatask's projection"
}

@test "cross-link: megatask's depth budget points back at worktask check 11" {
  grep -q 'Validation check 11' "$MEGATASK" \
    || fail "megatask does not cross-link worktask check 11"
}

@test "cross-link: both projections agree the same chain is 3 standalone and 4 under megatask" {
  # The one number that proves the two copies have not drifted. megatask's level
  # table lands Tier-2 at 4; check 11 subtracts the orchestrator offset to 3.
  grep -q 'project \*\*3\*\* standalone and \*\*4\*\* under' "$MEGATASK" \
    || fail "megatask no longer pins the standalone/batch depth pair"
}

# --- the two mechanisms are complements, not duplicates --------------------
@test "complement: check 11 defers unanticipated hops to the self-report" {
  local section
  section="$(awk '/^### Validation check 11$/,/^### On validation failure$/' "$WORKTASK")"
  echo "$section" | grep -q 'dispatch_flattened' \
    || fail "check 11 does not name the after-the-fact row that covers its blind spot"
}
