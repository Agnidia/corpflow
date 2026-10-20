#!/usr/bin/env bats
# Behavioural tests for hooks/comment-standard-context.sh.
#
# Contract (verified against .claude-plugin/plugin.json): PostToolUse, matcher
# Write|Edit, "continueOnBlock": true. It emits ONLY
# {"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":…}}
# and never a `decision` / `permissionDecision` key — this hook must never be
# able to block a tool call, so the absence of those keys is the assertion.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

HOOK="hooks/comment-standard-context.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  # Every sentinel lands here, so each test starts from a clean first-touch
  # state and traversal containment is checkable by listing one directory.
  SENTINEL_DIR="$WD/tmpdir"
  mkdir -p "$SENTINEL_DIR"
}

teardown() {
  _test_helper_cleanup
}

payload() {  # payload <transcript_path> [file_path] [session_id]
  jq -nc --arg tp "$1" --arg fp "${2:-/tmp/Foo.swift}" --arg sid "${3:-sess_fixed}" \
    '{session_id:$sid, transcript_path:$tp, tool_input:{file_path:$fp}}'
}

run_hook() {  # run_hook <payload-json>
  run_script_env --env "TMPDIR=$SENTINEL_DIR" --stdin-string "$1" "$HOOK"
}

sentinels() {
  find "$SENTINEL_DIR" -maxdepth 1 -type f -name 'corpflow-comment-standard-*' \
    | sed "s|^$SENTINEL_DIR/||" | sort
}

# ---------------------------------------------------------------------------
# T1 — first touch injects the standard, in the PostToolUse shape only.
# ---------------------------------------------------------------------------
@test "T1: first touch of a .swift injects additionalContext and no decision key" {
  run_hook "$(payload /tmp/tasks/agentA.jsonl)"

  assert_success
  assert_equal "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$output")" 'PostToolUse'
  assert_equal "$(jq 'has("decision")' <<< "$output")" 'false'
  assert_equal "$(jq 'has("permissionDecision")' <<< "$output")" 'false'
  assert_equal "$(jq -r '.hookSpecificOutput.additionalContext | test("code-comment-standard")' <<< "$output")" 'true'
  assert_equal "$(sentinels)" 'corpflow-comment-standard-agentA'
}

# ---------------------------------------------------------------------------
# T2 — the sentinel is what suppresses the second touch, and it is per AGENT.
# ---------------------------------------------------------------------------
@test "T2: the same transcript is silent on the second touch" {
  run_hook "$(payload /tmp/tasks/agentA.jsonl)"
  assert_output --partial 'PostToolUse'

  run_hook "$(payload /tmp/tasks/agentA.jsonl)"
  assert_success
  assert_output ''
}

@test "T3: a new transcript_path re-injects even on the same session_id" {
  run_hook "$(payload /tmp/tasks/agentA.jsonl /tmp/Foo.swift sess_shared)"
  assert_output --partial 'PostToolUse'

  # The regression this keys on: a session-keyed sentinel gave one worktask a
  # single reminder and left every later subagent without the standard.
  run_hook "$(payload /tmp/tasks/agentB.jsonl /tmp/Foo.swift sess_shared)"
  assert_success
  assert_equal "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$output")" 'PostToolUse'

  assert_equal "$(sentinels)" 'corpflow-comment-standard-agentA
corpflow-comment-standard-agentB'
}

# ---------------------------------------------------------------------------
# T4 — extension gate.
# ---------------------------------------------------------------------------
@test "T4: a .md edit is silent and burns no sentinel" {
  run_hook "$(payload /tmp/tasks/agentA.jsonl /tmp/notes.md)"
  assert_success
  assert_output ''
  assert_equal "$(sentinels)" ''

  # Control arm: the same agent on a .sh path DOES inject, so the silence above
  # is attributable to the extension and not to a dead code path.
  run_hook "$(payload /tmp/tasks/agentA.jsonl /tmp/deploy.sh)"
  assert_equal "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$output")" 'PostToolUse'
}

@test "T5: a missing file_path is a silent no-op" {
  run_script_env --env "TMPDIR=$SENTINEL_DIR" \
    --stdin-string '{"session_id":"s","transcript_path":"/tmp/tasks/agentA.jsonl"}' "$HOOK"
  assert_success
  assert_output ''
  assert_equal "$(sentinels)" ''
}

# ---------------------------------------------------------------------------
# T6 — injection safety. transcript_path is attacker-influenceable; the key is
# sanitised with pure parameter expansion before it reaches a path.
# ---------------------------------------------------------------------------
@test "T6: traversal in transcript_path cannot write a sentinel outside TMPDIR" {
  run_hook "$(payload "/tmp/tasks/../../../../..$WD/escaped.jsonl")"
  assert_success

  [ ! -e "$WD/escaped" ]
  [ ! -e "$WD/escaped.jsonl" ]
  assert_equal "$(sentinels)" 'corpflow-comment-standard-escaped'
}

@test "T7: separator and metacharacters are stripped out of the sentinel name" {
  # No slash at all, so ${_tp##*/} cannot do the containment on its own — the
  # charset filter has to.
  run_hook "$(payload '..%2f..%2fpwned.jsonl')"
  assert_success
  assert_equal "$(sentinels)" 'corpflow-comment-standard-2f2fpwned'

  # Every file under TMPDIR is a sentinel; nothing else was created anywhere.
  run find "$SENTINEL_DIR" -mindepth 1 -not -name 'corpflow-comment-standard-*'
  assert_output ''
}

@test "T8: a dots-only transcript falls back to a sanitised session_id" {
  run_hook "$(payload '....jsonl' /tmp/Foo.swift '../../etc/evil')"
  assert_success
  assert_equal "$(sentinels)" 'corpflow-comment-standard-etcevil'
  [ ! -e "$WD/etc" ]
}

# ---------------------------------------------------------------------------
# T9 — degrade paths never block.
# ---------------------------------------------------------------------------
@test "T9: jq absent notices on stderr and exits 0 with no stdout" {
  run_script_env --hide jq --separate-stderr --env "TMPDIR=$SENTINEL_DIR" \
    --stdin-string "$(payload /tmp/tasks/agentA.jsonl)" "$HOOK"
  assert_success
  assert_output ''
  assert_equal "$stderr" 'comment-standard-context: jq not found, skipping'
}

@test "T10: malformed stdin is reported on stderr and still exits 0" {
  run_script_env --separate-stderr --env "TMPDIR=$SENTINEL_DIR" \
    --stdin-string 'NOT JSON {{{' "$HOOK"
  assert_success
  assert_output ''
  assert_equal "$stderr" 'comment-standard-context: jq parse failed'
  assert_equal "$(sentinels)" ''
}

@test "T11: --self-test passes" {
  run_script_env "$HOOK" --self-test
  assert_success
  assert_output --partial 'self-test OK'
  assert_output --regexp 'comment-standard-context: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
}
