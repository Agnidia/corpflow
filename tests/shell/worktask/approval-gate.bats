#!/usr/bin/env bats
# Contract tests for the plan-approval carrier PL0.metadata.approved: the three
# stamp sites in skills/worktask/references/workflow.md, the batch seed in commands/megatask.md,
# the readers in agents/developer.md and agents/product-manager.md, and the
# schema entry in skills/worktask/references/state-ledger.md.
#
# LIMITATION, stated so green is not over-read: the approval check is behaviour
# of an agent, not of a script, so nothing here executes it. What is proven is
# the ledger-and-predicate composition — a real state-patch.sh write of the
# payload written in the doc, cross-checked against the accepted value set and
# the schema enum extracted from their own files at test time. Hardcoding any
# side would let that side drift while the suite stayed green.
#
# Every extraction is guarded (EG1/EG2/EG3 below) because the failure mode this
# file exists to avoid is a test that passes when its own extraction returns
# nothing.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

WORKTASK_DOC="skills/worktask/references/workflow.md"
AUTO_DECISION_DOC="skills/worktask/references/auto-decision.md"
MEGATASK_DOC="commands/megatask.md"
DEVELOPER_DOC="agents/developer.md"
PRODUCT_MANAGER_DOC="agents/product-manager.md"
STATE_LEDGER_DOC="skills/worktask/references/state-ledger.md"
PATCH_SCRIPT="skills/worktask/scripts/state-patch.sh"

# Arms are delimited by literal prose anchors rather than line numbers: line
# numbers rot on the next edit to the doc, the anchors ARE the prose asserted about.
ARM_A_BEGIN='^4\. \*\*On approval\*\*'      # plan gate approval arm
ARM_A_END='^5\. \*\*On rejection'
ARM_B_BEGIN='^\*\*If .plan_gate == "bypass"' # pure-bypass arm
ARM_B_END='^Exception:'
ARM_C_BEGIN='^Exception:'                    # escalate-resolution arm
ARM_C_END='^### Step A —'

# A value that must never be a member of the accepted set. A degenerate
# extraction that matched anything would admit it, which is what EG2 catches.
SENTINEL="__never_approved__"

setup() {
  WD="$(mk_tmpworkdir)"
  # state-patch.sh resolves its ledger from a declared root, never cwd.
  export WORKSPACE_ROOT="$WD"
  mk_state_fixture "$WD/.context/state.json" \
    '.version = 2' \
    '.tasks.PL0 = {"status":"in_progress","metadata":{"stage":"PL","agent":"corpflow:product-manager"}}' \
    > /dev/null
}

# --- extraction -------------------------------------------------------------

# arm_text <file> <begin-re> <end-re> — the half-open [begin, end) slice, so the
# arms stay disjoint where one arm's end anchor is the next arm's begin anchor.
arm_text() {
  local file="$(contract_source "$PLUGIN_ROOT/$1")" begin="$2" end="$3" b rel
  b="$(grep -n -m1 -E "$begin" "$file" | cut -d: -f1)" || true
  [ -n "$b" ] || return 1
  rel="$(tail -n "+$((b + 1))" "$file" | grep -n -m1 -E "$end" | cut -d: -f1)" || true
  [ -n "$rel" ] || return 1
  sed -n "${b},$((b + rel - 1))p" "$file"
}

# W — the writer payload documented inside one arm.
extract_payload() { sed -n "s/.*task-meta PL0 --set '\([^']*\)'.*/\1/p"; }

# R — the value set the reader agent doc says it accepts.
extract_reader_set() {
  sed -n 's/.*PL0\.metadata\.approved ∈ {\([^}]*\)}.*/\1/p' "$PLUGIN_ROOT/$DEVELOPER_DOC"
}

# S — the enum the ledger schema declares.
extract_schema_set() {
  awk '/"approved": \{/{f=1} f{print} f&&/\]/{exit}' "$(contract_source "$PLUGIN_ROOT/$STATE_LEDGER_DOC")" \
    | sed -n 's/.*"enum": \[\([^]]*\)\].*/\1/p'
}

# Space-delimited, sorted, quote-stripped — so set comparison is order- and
# whitespace-insensitive without either side being normalised by hand.
norm_set() { tr -d ' "' | tr ',' '\n' | grep -v '^$' | sort | tr '\n' ' '; }
# An empty needle must NOT be a member: `" $1 "` pads the haystack, so an
# unguarded empty $2 matches any set and turns a failed extraction into a pass.
set_has() {
  [ -n "${2:-}" ] || return 1
  case " $1 " in *" $2 "*) return 0 ;; esac
  return 1
}

# EG1+EG2+EG3. Any case that consumes W, R or S calls this first: an empty or
# degenerate extraction must fail loudly here rather than pass vacuously later.
guard_extractions() {
  R_SET="$(extract_reader_set | norm_set)"
  S_SET="$(extract_schema_set | norm_set)"

  [ -n "${R_SET// /}" ] || fail \
    "EG1: reader set empty — $DEVELOPER_DOC no longer matches 'PL0.metadata.approved ∈ {…}'"
  [ -n "${S_SET// /}" ] || fail \
    "EG1: schema enum empty — $STATE_LEDGER_DOC no longer matches '\"approved\": {' … '\"enum\": [ … ]'"
  ! set_has "$R_SET" "$SENTINEL" || fail \
    "EG2: extracted reader set admits $SENTINEL — the extraction is degenerate, not the doc"
  [ "$R_SET" = "$S_SET" ] || fail \
    "EG3: reader set [$R_SET] != schema enum [$S_SET] — $DEVELOPER_DOC and $STATE_LEDGER_DOC drifted"
}

# Prints the payload, exits non-zero when the extraction came back empty. `fail`
# is deliberately NOT called here: this runs inside a command substitution, where
# `fail` aborts only the subshell and the caller would carry on with an empty
# value. Callers assert with `|| fail`, which does abort the test.
arm_payload() {
  local out
  out="$(arm_text "$WORKTASK_DOC" "$2" "$3" | extract_payload)" || true
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

eg1_arm() {
  printf 'EG1: no %s payload in the %s arm of %s — the stamp was removed or reworded' \
    "task-meta PL0 --set" "$1" "$WORKTASK_DOC"
}

# --- cases ------------------------------------------------------------------

@test "happy: the approval arm's documented invocation stamps user, and the readers accept it" {
  guard_extractions
  local payload
  payload="$(arm_payload approval "$ARM_A_BEGIN" "$ARM_A_END")" || fail "$(eg1_arm approval)"

  cd "$WD"
  run bash "$PLUGIN_ROOT/$PATCH_SCRIPT" --task-meta PL0 --set "$payload"
  assert_success

  run jq -r '.tasks.PL0.metadata.approved' .context/state.json
  assert_output "user"
  set_has "$R_SET" "user" \
    || fail "post-stamp value 'user' is not in the reader's accepted set [$R_SET]"
}

@test "happy: writer, reader and schema compose — extractions are non-empty and agree" {
  guard_extractions
  # Named as its own case so an extraction regression reports itself instead of
  # surfacing as a confusing round-trip failure.
  # Extraction and decoding are separate statements: piping into jq would make the
  # pipeline's status jq's, hiding an empty extraction behind a successful decode.
  # WHICH value each arm stamps is the decision under test, so it is asserted
  # exactly, not merely as set membership: a user->auto swap on the escalate arm
  # stays inside the extracted set while silently understating a real human
  # approval. The set itself is still extracted, never hardcoded.
  local name payload value expected
  for name in approval bypass escalate-resolution; do
    case "$name" in
      approval)
        payload="$(arm_payload "$name" "$ARM_A_BEGIN" "$ARM_A_END")"; expected=user ;;
      bypass)
        payload="$(arm_payload "$name" "$ARM_B_BEGIN" "$ARM_B_END")"; expected=auto ;;
      escalate-resolution)
        payload="$(arm_payload "$name" "$ARM_C_BEGIN" "$ARM_C_END")"; expected=user ;;
    esac
    [ -n "$payload" ] || fail "$(eg1_arm "$name")"
    value="$(printf '%s\n' "$payload" | jq -r '.approved // empty')"
    [ -n "$value" ] || fail "EG1: the $name arm's payload [$payload] carries no approved key"
    set_has "$R_SET" "$value" \
      || fail "the $name arm stamps '$value', outside the reader set [$R_SET]"
    [ "$value" = "$expected" ] \
      || fail "the $name arm stamps '$value'; '$expected' is the settled value for it"
  done
  ! set_has "$R_SET" "$SENTINEL" || fail "EG2: $SENTINEL admitted after composition"
}

@test "happy: the bypass arm's documented invocation stamps exactly auto" {
  guard_extractions
  local payload
  payload="$(arm_payload bypass "$ARM_B_BEGIN" "$ARM_B_END")" || fail "$(eg1_arm bypass)"

  cd "$WD"
  run bash "$PLUGIN_ROOT/$PATCH_SCRIPT" --task-meta PL0 --set "$payload"
  assert_success

  run jq -r '.tasks.PL0.metadata.approved' .context/state.json
  assert_output "auto"
}

@test "edge: every arm stamps before its audit row; the bypass arm has no row at all" {
  # Row-first leaves a crash window that resumes into the stage loop with the
  # carrier unset — the exact defect this contract repairs.
  # Packed as name/begin/end triples; the anchors themselves contain ':', so a
  # delimiter-split encoding would silently truncate the escalate arm's regex.
  local -a arms=(
    approval "$ARM_A_BEGIN" "$ARM_A_END"
    escalate-resolution "$ARM_C_BEGIN" "$ARM_C_END"
  )
  local i name stamp row text
  for i in 0 3; do
    name="${arms[$i]}"
    text="$(arm_text "$WORKTASK_DOC" "${arms[$((i + 1))]}" "${arms[$((i + 2))]}")"
    stamp="$(printf '%s\n' "$text" | grep -n "task-meta PL0 --set .*approved" | head -1 | cut -d: -f1)"
    row="$(printf '%s\n' "$text" | grep -n 'approval_received' | head -1 | cut -d: -f1)"
    [ -n "$stamp" ] || fail "$name arm: no stamp"
    [ -n "$row" ] || fail "$name arm: no approval_received row to order against"
    [ "$stamp" -lt "$row" ] \
      || fail "$name arm: stamp at line $stamp is not before the audit row at line $row"
  done

  # Asserted, never silently skipped: "no row to order against" is a checked fact.
  local btext
  btext="$(arm_text "$WORKTASK_DOC" "$ARM_B_BEGIN" "$ARM_B_END")"
  if printf '%s\n' "$btext" | grep -q 'approval_received'; then
    fail "bypass arm gained an approval_received row; its ordering contract changed"
  fi
  printf '%s\n' "$btext" | grep -q "task-meta PL0 --set .*approved" \
    || fail "bypass arm lost its stamp"

  # The two arms must be mutually EXCLUSIVE, not merely adjacent: an unconditional
  # auto stamp here can land before the escalation stop is honoured, and a crash in
  # that window resumes into the stage loop with escalation-class questions
  # unanswered and the approval check passing.
  printf '%s\n' "$btext" | head -1 | grep -qi 'escalat' \
    || fail "the bypass arm's entry condition no longer names the escalate precondition"

}

@test "edge: the auto-decision pre-pass stamps nothing" {
  local text
  text="$(arm_text "$WORKTASK_DOC" '^### Step A\.4 — Auto-Decision Pre-Pass' '^### Step A\.4b —')"
  [ -n "$text" ] || fail "Step A.4 range empty — the section heading in $WORKTASK_DOC moved"
  # The delegate procedure Step A.4 points at is part of the pre-pass, so it is held to the same rule.
  [ -s "$PLUGIN_ROOT/$AUTO_DECISION_DOC" ] || fail "$AUTO_DECISION_DOC is missing or empty"
  text+=$'\n'"$(cat "$PLUGIN_ROOT/$AUTO_DECISION_DOC")"
  if printf '%s\n' "$text" | grep -q "task-meta PL0 --set .*approved"; then
    fail "Step A.4 stamps an approval carrier; it bypasses no gate and must not"
  fi
  return 0
}

@test "edge: every reader names the carrier task, with no bare reference left" {
  cd "$PLUGIN_ROOT"
  run bash -c "grep -rn 'metadata\.approved' agents/ commands/ skills/ | grep -v 'PL0\.metadata\.approved'"
  # A bare reference reads as the READING task's own metadata, which leaves the
  # gate inert. Both $DEVELOPER_DOC sites and $PRODUCT_MANAGER_DOC are in this sweep.
  [ "$status" -ne 0 ] || fail "bare metadata.approved references survive:"$'\n'"$output"
}

@test "edge: the batch per-issue planning seed carries the bypass carrier" {
  cd "$PLUGIN_ROOT"
  run bash -c "grep -c 'approved:\"auto\"' $MEGATASK_DOC"
  assert_output "1"
}
