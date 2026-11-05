#!/usr/bin/env bats
# blocked-on-lib.sh — the one definition of the blocked_on enums and arm table, sourced by both
# the boundary gate (handoff-harness.sh) and the router (blocked-on-dispatch.sh).
#
# The load-bearing block is the parity pair: the library values against the registry lines and
# the two prose tables that document them. A constant that agrees with nothing it documents is
# how the gate and the prose drift apart without a red test.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

LIB="skills/worktask/scripts/blocked-on-lib.sh"
HARNESS="skills/worktask/scripts/handoff-harness.sh"
ROUTER="skills/worktask/scripts/blocked-on-dispatch.sh"
PROTOCOL_MD="skills/worktask/references/handoff-protocol.md"
SKILL_MD="skills/worktask/references/orchestration.md"
FIX="${FIXTURES}/worktask/blocked-on"

# _lib <snippet> — runs the snippet with the library sourced under the callers' strict mode.
_lib() {
  run --separate-stderr bash -c "set -euo pipefail; . '$PLUGIN_ROOT/$LIB'; $1" < /dev/null
}

@test "blocked_on_validate: empty input is refused, not read as valid" {
  _lib 'blocked_on_validate ""'
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"fail: blocked_on is empty"* ]]
}

@test "executing the library directly is refused" {
  run bash "$PLUGIN_ROOT/$LIB"
  assert_failure 2
  assert_output --partial "source it, do not execute it directly"
}

@test "a double source is a no-op under set -euo pipefail" {
  _lib ". '$PLUGIN_ROOT/$LIB'; printf '%s' \"\$BLOCKED_ON_KINDS\""
  assert_success
  assert_output "user_decision user_action permission peer_session artifact correction host_environment"
}

@test "parity: both enums equal the registry lines in handoff-protocol.md, order included" {
  local kinds rw
  kinds="$(grep -E '^[[:space:]]+kind: user_decision \|' "$(contract_source "$PLUGIN_ROOT/$PROTOCOL_MD")" | sed 's/^[[:space:]]*kind: //; s/ | / /g')"
  rw="$(grep -E '^[[:space:]]+resume_with: decision_ref \|' "$(contract_source "$PLUGIN_ROOT/$PROTOCOL_MD")" | sed 's/^[[:space:]]*resume_with: //; s/ | / /g')"
  [ -n "$kinds" ] && [ -n "$rw" ] || fail "registry enum lines not found"
  _lib "printf '%s\n%s' \"\$BLOCKED_ON_KINDS\" \"\$BLOCKED_ON_RESUME_WITH\""
  assert_success
  assert_output "$(printf '%s\n%s' "$kinds" "$rw")"
}

@test "parity: required, optional and resume_with match the seven-arms table in handoff-protocol.md" {
  local rows kind keys rw req opt want
  rows="$(awk '/^#### Schema — blocked_on, the seven arms at a glance/{f=1; next} f && /^####/{exit} f' "$(contract_source "$PLUGIN_ROOT/$PROTOCOL_MD")" \
    | grep -E '^\| `[a-z_]+` \|')"
  [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" = 7 ] || fail "expected 7 arm rows, got: $rows"
  while IFS='|' read -r _ kind keys rw _; do
    kind="$(printf '%s' "$kind" | tr -d ' `')"
    rw="$(printf '%s' "$rw" | tr -d ' ')"
    req="$(printf '%s' "$keys" | tr ',' '\n' | tr -d ' ' | grep -v '^\[' | paste -sd, -)"
    opt="$(printf '%s' "$keys" | tr ',' '\n' | tr -d ' ' | grep '^\[' | tr -d '[]' | paste -sd, - || true)"
    want="$req|$opt|$rw"
    _lib "blocked_on_arm $kind | cut -d'|' -f1-3"
    assert_success
    [ "$output" = "$want" ] || fail "$kind: lib says '$output', prose says '$want'"
  done <<< "$rows"
}

@test "parity: legs, closing leg, owner and landed match SKILL.md § blocked-on-lib.sh — the arm table" {
  local rows kind legs closing owner landed n=0
  rows="$(awk '/^#### blocked-on-lib.sh — the arm table/{f=1; next} f && /^#/{exit} f' "$(contract_source "$PLUGIN_ROOT/$SKILL_MD")" \
    | grep -E '^\| [a-z_]+ \|' | grep -v '^| kind |')"
  while IFS='|' read -r _ kind legs closing owner landed _; do
    kind="$(printf '%s' "$kind" | tr -d ' ')"
    n=$((n + 1))
    _lib "blocked_on_arm $kind | cut -d'|' -f4-7"
    assert_success
    [ "$output" = "$(printf '%s|%s|%s|%s' "$(printf '%s' "$legs" | tr -d ' ')" "$(printf '%s' "$closing" | tr -d ' ')" \
      "$(printf '%s' "$owner" | tr -d ' ')" "$(printf '%s' "$landed" | tr -d ' ')")" ] \
      || fail "$kind: lib row '$output' disagrees with SKILL.md"
  done <<< "$rows"
  [ "$n" = 7 ] || fail "expected 7 rows in the SKILL.md arm table, read $n"
}

@test "blocked_on_arm: an unknown kind exits 1" {
  _lib "blocked_on_arm coffee_break"
  assert_failure 1
  _lib "blocked_on_arm ''"
  assert_failure 1
}

@test "blocked_on_table_json: owner_issue is a number and landed a boolean for every kind" {
  _lib "blocked_on_table_json"
  assert_success
  jq -e '(keys | length) == 7 and all(.[]; (.owner_issue | type) == "number" and (.landed | type) == "boolean")
    and .user_action.landed and .host_environment.landed and .permission.landed and .peer_session.landed
    and .correction.landed and .correction.owner_issue == 404
    and .artifact.landed and .artifact.owner_issue == 399' <<< "$output"
}

# The flag the router's fallback and the batch renderer key on. With #404 landed no kind is
# pending, so nothing may still be routed to the user_action fallback for want of an arm — the
# arm-table row is the only place that could re-introduce one.
@test "every arm in the table is landed, so no kind names an owner issue as pending" {
  _lib "blocked_on_table_json"
  assert_success
  jq -e 'all(.[]; .landed == true)' <<< "$output"
  run grep -nE '^[a-z_]+\|.*\|no$' "$PLUGIN_ROOT/$LIB"
  [ "$status" -eq 1 ] || fail "an arm row still reads unlanded: $output"
}

@test "normalize: blocked_on passes through; cross_session_ask is not a need and exits 1" {
  _lib "blocked_on_normalize '{\"blocked_on\":{\"kind\":\"artifact\"},\"cross_session_ask\":{\"to\":\"a\",\"question\":\"b\"}}'"
  assert_success
  jq -e '. == {blocked_on: {kind: "artifact"}, source: "blocked_on"}' <<< "$output"
  _lib "blocked_on_normalize \"\$(cat '$FIX/legacy-cross-session-ask.handoff.json')\""
  assert_failure 1
  assert_output ""
  _lib "blocked_on_normalize '{\"verdict\":\"blocked\"}'"
  assert_failure 1
  _lib "blocked_on_normalize 'not json'"
  assert_failure 1
}

@test "validate: the seven valid fixtures pass both validators" {
  local kind
  for kind in user_decision user_action permission peer_session artifact correction host_environment; do
    _lib "b=\$(jq -c .blocked_on '$FIX/$kind.handoff.json'); blocked_on_validate \"\$b\" && blocked_on_validate_arm \"\$b\""
    [ "$status" -eq 0 ] || fail "$kind: exit $status: $stderr"
  done
}

@test "validate: each invalid fixture fails with exactly one named fail: line" {
  local spec name want
  for spec in 'invalid-unknown-kind|fail: blocked_on.kind "coffee_break" is not one of user_decision|user_action|permission|peer_session|artifact|correction|host_environment' \
    'invalid-unknown-resume-with|fail: blocked_on.resume_with "carrier_pigeon" is not one of decision_ref|artifact_path|reply_ref' \
    'invalid-missing-detail|fail: blocked_on.detail is missing or empty; kind user_action needs a non-empty object'; do
    name="${spec%%|*}" want="${spec#*|}"
    _lib "blocked_on_validate \"\$(jq -c .blocked_on '$FIX/$name.handoff.json')\""
    [ "$status" -eq 1 ] || fail "$name: exit $status, want 1"
    [ "$stderr" = "$want" ] || fail "$name: stderr '$stderr', want '$want'"
  done
}

@test "validate: a hostile kind is echoed as one bounded JSON-escaped line" {
  _lib "blocked_on_validate '{\"kind\":\"a\\nfail: forged\\u001b[31m$(printf 'x%.0s' $(seq 1 200))\",\"detail\":{\"a\":1},\"resume_with\":\"decision_ref\"}'"
  assert_failure 1
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ] || fail "the fail: line was split: $stderr"
  [ "${#stderr}" -lt 260 ] || fail "the echoed value is unbounded (${#stderr} chars)"
}

@test "validate_arm: a missing or null required key and a wrong pairing are named" {
  _lib "blocked_on_validate_arm '{\"kind\":\"user_action\",\"detail\":{\"request\":\"x\",\"command\":null},\"resume_with\":\"decision_ref\"}'"
  assert_failure 1
  [ "$stderr" = "fail: blocked_on.detail for kind user_action is missing required key: command" ]
  _lib "blocked_on_validate_arm '{\"kind\":\"user_action\",\"detail\":{\"request\":\"x\",\"command\":\"\"},\"resume_with\":\"decision_ref\"}'"
  assert_success
  _lib "blocked_on_validate_arm '{\"kind\":\"peer_session\",\"detail\":{\"to\":\"a\",\"question\":\"b\"},\"resume_with\":\"decision_ref\"}'"
  assert_failure 1
  [ "$stderr" = 'fail: blocked_on.resume_with for kind peer_session must be reply_ref, not "decision_ref"' ]
}

@test "both consumers source this library rather than spelling the enums" {
  run grep -nF 'blocked-on-lib.sh' "$PLUGIN_ROOT/$HARNESS" "$PLUGIN_ROOT/$ROUTER"
  assert_success
  run grep -nE 'user_decision[ |]+user_action[ |]+permission' "$PLUGIN_ROOT/$HARNESS" "$PLUGIN_ROOT/$ROUTER"
  [ "$status" -eq 1 ] || fail "a consumer spells the kind enum itself: $output"
}
