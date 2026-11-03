#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context/logs"
  STATE="$WD/.context/state.json"
  cp "$FIXTURES/worktask/blocked-on/state.blocked-on.json" "$STATE"
  CALLS="$WD/probe-calls"
  RESULT="$WD/probe-result"
  printf 'fail' > "$RESULT"
  cat > "$WD/probe.sh" <<STUB
#!/usr/bin/env bash
printf 'probe\n' >> '$CALLS'
printf 'result_json={"checks":[{"id":"gh-pr-create","status":"%s"}]}\n' "\$(cat '$RESULT')"
STUB
  export BLOCKED_ON_PREFLIGHT="$WD/probe.sh"
  export MAILBOX_DIR="$WD/mailbox"
  PAYLOAD='{"verdict":"blocked","blocked_on":{"kind":"host_environment","detail":{"check":"gh-pr-create","observed":"Operation gh PR creation denied; evidence .context/logs/denial.log; recovery host authentication succeeds"},"resume_with":"decision_ref"}}'
}

_route() {
  run --separate-stderr bash "$PLUGIN_ROOT/skills/worktask/scripts/blocked-on-dispatch.sh" route \
    --state "$STATE" --task-id FN0 --payload "$PAYLOAD"
}

@test "capability recovery: unchanged restrictions probe once and preserve the blocker" {
  _route
  assert_success
  _route
  assert_success
  [ "$(wc -l < "$CALLS" | tr -d ' ')" = 1 ]
  jq -e '.tasks.FN0.status == "blocked" and (.tasks.FN0.metadata.blocked_on.detail.observed | contains("recovery"))' "$STATE"
  ! grep -q 'host authentication' "$WD/.context/logs/audit.jsonl"
}

@test "capability recovery: explicit recovery verifies the changed capability before resume" {
  _route
  assert_success
  run --separate-stderr bash "$PLUGIN_ROOT/skills/worktask/scripts/blocked-on-dispatch.sh" resume \
    --state "$STATE" --task-id FN0 --leg verified
  [ "$status" = 1 ]
  jq -e '.tasks.FN0.status == "blocked"' "$STATE"
  printf 'pass' > "$RESULT"
  run --separate-stderr bash "$PLUGIN_ROOT/skills/worktask/scripts/blocked-on-dispatch.sh" resume \
    --state "$STATE" --task-id FN0 --leg verified
  assert_success
  jq -e '.cleared and .resume_block.do_not_rerun' <<< "$output"
  jq -e '.tasks.FN0.status == "in_progress" and .tasks.FN0.metadata.blocked_on == null' "$STATE"
}

@test "capability recovery: a partial ledger park without audit prevents another probe" {
  jq --argjson b "$(printf '%s' "$PAYLOAD" | jq '.blocked_on')" \
    '.tasks.FN0.metadata.blocked_on = $b' "$STATE" > "$STATE.next"
  mv "$STATE.next" "$STATE"
  _route
  assert_success
  [ ! -f "$CALLS" ]
  jq -e '.tasks.FN0.status == "blocked"' "$STATE"
}

@test "capability recovery: an audit-only park prevents another probe" {
  printf '%s\n' '{"action":"blocked_on","subject":"FN0","metadata":{"kind":"host_environment","leg":"probed"}}' > "$WD/.context/logs/audit.jsonl"
  _route
  assert_success
  [ ! -f "$CALLS" ]
}


@test "capability recovery: transient and logic failures do not enter the restricted-operation route" {
  for classification in transient logic; do
    PAYLOAD="{\"verdict\":\"fail\",\"classification\":\"$classification\"}"
    _route
    [ "$status" = 1 ]
    [ ! -f "$CALLS" ]
    jq -e '.tasks.FN0.metadata.blocked_on == null' "$STATE"
  done
}
