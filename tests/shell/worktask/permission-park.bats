#!/usr/bin/env bats
# Tests for skills/worktask/scripts/permission-park.sh — classify, park, batch and resume for an
# auto-mode permission denial — plus the doc-contract cases for the prose that routes to it.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/worktask/scripts/permission-park.sh"
HOOK="hooks/permission-denied.sh"
LIB="hooks/lib/permission-denied-lib.sh"
SELFTEST="skills/worktask/scripts/permission-park-selftest.sh"
FIX="${FIXTURES}/worktask/permission-park"
MERGE_CMD="gh pr merge 412 --squash --delete-branch"
MERGE_CMD_HEAD="gh [redacted] [redacted] [redacted]"
RESET_CMD="git reset --hard origin/develop"
# Split so no static secret scanner reads a literal token in this file.
GH_TOK="ghp_""Ab12Cd34Ef56Gh78Ij90Kl12Mn"
SECRET_CMD="GITHUB_TOKEN=$GH_TOK gh api -X PUT /repos/o/r/pulls/412/merge --input /Users/alice/merge.json -f merge_method=squash"
HEAD_KEYS='["tool", "dedupe_key", "command_head", "truncated"]'
SKILL_MD="skills/worktask/references/orchestration.md"
PROTOCOL_MD="skills/worktask/references/handoff-protocol.md"
CONTRACTS_MD="skills/worktask/references/stage-contracts.md"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context/logs"
  STATE="$WD/.context/state.json"
  AUDIT="$WD/.context/logs/audit.jsonl"
  cp "$FIX/state.fn-merge-denied.json" "$STATE"
}

_pp() {
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" "$@"
}

_rows() {
  [ -f "$AUDIT" ] || { echo 0; return 0; }
  grep -c "\"action\":\"${1:-permission_denied}\"" "$AUDIT" || true
}

# _assert_logs_clean <needle>... — no file ANYWHERE under the audit log's directory may hold a
# needle. The sweep is deliberately dir-wide rather than a list of known log files: a named subset
# only ever covers the writers that existed when it was written, and that gap is what let
# state-patch's generic `--set` logger copy an unmasked denied command into state-merge.log.
_assert_logs_clean() {
  local needle hits
  for needle in "$@"; do
    hits="$(grep -rlF -- "$needle" "$(dirname "$AUDIT")" 2> /dev/null || true)"
    if [ -n "$hits" ]; then
      fail ".context/logs leaks: $needle (in $(printf '%s' "$hits" | tr '\n' ' '))"
      return 1
    fi
  done
}

_merge_detail() {
  bash "$PLUGIN_ROOT/$SCRIPT" classify --payload "$(cat "$FIX/fn-merge-denied.handoff.json")"
}

_detail_for() {
  jq -cn --arg c "$1" '{tool: "Bash", command: $c, classifier_reason: "Blocked by classifier", allow_rule: ""}'
}

_ledger_jq() {
  jq "$1" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

# _section <file> <start-line-prefix> <stop-regex> — the lines from the first line starting with
# the prefix up to, not including, the next line matching stop-regex.
_section() {
  awk -v start="$2" -v stop="$3" '
    f && $0 ~ stop { exit }
    index($0, start) == 1 { f = 1 }
    f { print }' "$(contract_source "$PLUGIN_ROOT/$1")"
}

# --- end to end ------------------------------------------------------------------

@test "AC1: FN merge denied — flag-less classify, park, one prompt, grant, resume, one audit row" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$HOOK" \
    < "$FIXTURES/hooks/permission-denied/merge-denied.payload.json"
  assert_success

  _pp classify < "$FIX/fn-merge-denied.result.txt"
  assert_success
  local detail="$output"

  _pp park --state "$STATE" --task-id FN0 --detail "$detail"
  assert_success

  _pp batch --state "$STATE"
  assert_success
  jq -e --arg c "$MERGE_CMD" '.mode == "ask" and (.payloads | length) == 1
    and (.payloads[0].questions | length) == 1
    and (.payloads[0].questions[0].question | contains($c))' <<< "$output"

  _pp resume --state "$STATE" --task-id FN0 --answer grant
  assert_success
  run jq -e '.tasks.FN0.status == "in_progress" and .tasks.FN0.metadata.blocked_on == null' "$STATE"
  assert_success
  [ "$(_rows)" = 1 ] || fail "expected exactly one permission_denied row, got $(_rows)"
}

# --- classify --------------------------------------------------------------------

@test "b2(i): classify with no flags recovers Bash and the merge command from the Tool(...) line" {
  _pp classify < "$FIX/fn-merge-denied.result.txt"
  assert_success
  jq -e --arg c "$MERGE_CMD" '.tool == "Bash" and .command == $c
    and .allow_rule == ("Bash(" + $c + ")")
    and (.classifier_reason | contains("Blocked by classifier"))' <<< "$output"
}

@test "b2(ii): hook row, then a flag-less text-path park, leaves exactly one permission_denied row" {
  _ledger_jq '.tasks.DR0.status = "completed"'
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$HOOK" \
    < "$FIXTURES/hooks/permission-denied/merge-denied.payload.json"
  assert_success
  run jq -r 'select(.action == "permission_denied") | .subject' "$AUDIT"
  assert_output "FN0"

  _pp park --state "$STATE" --task-id FN0 \
    --detail "$(bash "$PLUGIN_ROOT/$SCRIPT" classify < "$FIX/fn-merge-denied.result.txt")"
  assert_success
  jq -e '.audit_row_written == false' <<< "$output"
  [ "$(_rows)" = 1 ] || fail "expected one permission_denied row, got $(_rows)"
  [ "$(jq -r 'select(.action == "permission_denied") | .metadata.dedupe_key' "$AUDIT")" \
    = "$(jq -r '.dedupe_key' <<< "$output")" ] || fail "hook and text-path keys differ"
}

@test "b2(iii): classifier wording with no Tool(...) line is not parkable (exit 1)" {
  _pp classify --payload "$(printf 'The merge step stopped.\n  Error: Permission denied. Reason: Blocked by classifier\n')"
  [ "$status" -eq 1 ]
  assert_output ""
}

@test "AC14: the text path parks the last Tool(...) line at or before the classifier line, not an earlier completed call" {
  local detail
  _pp classify < "$FIX/fn-push-then-merge-denied.result.txt"
  assert_success
  detail="$output"
  jq -e --arg c "$MERGE_CMD" '.tool == "Bash" and .command == $c and .allow_rule == ("Bash(" + $c + ")")' <<< "$detail"
  [[ "$detail" != *"git push"* && "$detail" != *"git log"* ]] || fail "another call leaked into the need: $detail"
  _pp park --state "$STATE" --task-id FN0 --detail "$detail"
  assert_success
  _pp batch --state "$STATE"
  assert_success
  refute_output --partial "git push"
  refute_output --partial "git log"
}

@test "b2: an mcp__ tool is recovered by its bare name, hyphens included" {
  _pp classify --payload "$(printf 'mcp__plugin_github_github__merge-pull-request\n  Blocked by classifier\n')"
  assert_success
  jq -e '.tool == "mcp__plugin_github_github__merge-pull-request" and .command == ""
    and .allow_rule == "mcp__plugin_github_github__merge-pull-request"' <<< "$output"
}

@test "classify: a typed blocked_on wins over any text in the same return" {
  _pp classify --payload "$(cat "$FIX/fn-merge-denied.handoff.json")"
  assert_success
  jq -e --arg c "$MERGE_CMD" '.tool == "Bash" and .command == $c
    and .classifier_reason == "Blocked by classifier"' <<< "$output"
  _pp classify --payload '{"summary":"Blocked by classifier","blocked_on":{"kind":"user_action","detail":{}}}'
  [ "$status" -eq 1 ]
}

@test "classify: free text needs classifier wording; flags override; an ordinary rejection is not a denial" {
  _pp classify --tool Bash --command "$RESET_CMD" < "$FIX/fn-merge-denied.result.txt"
  assert_success
  jq -e --arg c "$RESET_CMD" '.command == $c and (.classifier_reason | startswith("Error:"))' <<< "$output"
  _pp classify --payload "The user doesn't want to proceed with this tool use. The tool use was rejected."
  [ "$status" -eq 1 ]
  _pp classify --payload ''
  [ "$status" -eq 1 ]
}

@test "SR: classify bounds untrusted fields and strips control characters" {
  local long
  long="$(printf 'b%.0s' $(seq 1 5000))"
  _pp classify --payload "$(jq -cn --arg c "$(printf 'echo hi\n')$long" --arg r "$long" \
    '{tool_name: "Bash", tool_input: {command: $c}, reason: $r}')"
  assert_success
  jq -e '(.command | length) <= 512 and (.classifier_reason | length) <= 512
    and (.command | test("[[:cntrl:]]") | not)' <<< "$output"
}

@test "SR: bidi overrides, isolates, zero-width and BOM characters are removed from all four fields" {
  local rlo lri zw bom payload
  rlo="$(printf '\342\200\256')" lri="$(printf '\342\201\246')" zw="$(printf '\342\200\213')" bom="$(printf '\357\273\277')"
  payload="$(jq -cn --arg t "Ba${zw}sh" --arg c "echo ${rlo}safe${lri}x" --arg r "${bom}Blocked by classifier" \
    --arg a "Bash(echo ${rlo}safe)" \
    '{blocked_on: {kind: "permission", detail: {tool: $t, command: $c, classifier_reason: $r, allow_rule: $a},
      resume_with: "decision_ref"}}')"
  _pp classify --payload "$payload"
  assert_success
  jq -e '.tool == "Bash" and .command == "echo safex"
    and .classifier_reason == "Blocked by classifier" and .allow_rule == "Bash(echo safe)"
    and ([.[] | test("\\p{Cf}")] | any | not)' <<< "$output"
}

# --- park ------------------------------------------------------------------------

@test "AC2: parking leaves retry_count, escalation_counts and last_error untouched" {
  local before
  before="$(jq -c '.tasks.FN0.metadata | {retry_count, escalation_counts, last_error}' "$STATE")"
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  assert_success
  run jq -c '.tasks.FN0.metadata | {retry_count, escalation_counts, last_error}' "$STATE"
  assert_output "$before"
  run jq -e '.tasks.FN0.status == "blocked"
    and .tasks.FN0.metadata.retry_count == 1
    and .tasks.FN0.metadata.blocked_on.kind == "permission"
    and .tasks.FN0.metadata.blocked_on.resume_with == "decision_ref"
    and (.tasks.FN0.metadata.blocked_on.detail | keys) == ["allow_rule", "classifier_reason", "command", "tool"]' "$STATE"
  assert_success
  [ "$(_rows)" = 1 ] || fail "expected one row, got $(_rows)"
  run jq -e --argjson k "$HEAD_KEYS" --arg c "$MERGE_CMD_HEAD" 'select(.action == "permission_denied")
    | .actor == "orchestrator" and .subject == "FN0" and .task_id == "FN0" and .result == "block"
    and (.metadata | keys_unsorted) == $k and .metadata.command_head == $c' "$AUDIT"
  assert_success
}

@test "AC5: the fallback rows are redacted; the full secret-shaped detail stays in blocked_on and the prompt" {
  local needle
  _pp park --state "$STATE" --task-id FN0 --detail "$(jq -cn --arg c "$SECRET_CMD" \
    '{tool: "Bash", command: $c, classifier_reason: "Blocked by classifier: token literal", allow_rule: ""}')"
  assert_success
  run jq -e --argjson k "$HEAD_KEYS" 'select(.action == "permission_denied") | .metadata
    | keys_unsorted == $k and .truncated == true and .command_head == "gh [redacted] -X [redacted]"' "$AUDIT"
  assert_success
  local row_key unmasked_key masked_key
  row_key="$(jq -r 'select(.action == "permission_denied") | .metadata.dedupe_key' "$AUDIT")"
  unmasked_key="$(printf 'FN0:Bash:%s' "$SECRET_CMD" | shasum -a 256 | cut -c1-16)"
  masked_key="$(printf 'FN0:Bash:%s' "GITHUB_TOKEN=[masked] ${SECRET_CMD#GITHUB_TOKEN="$GH_TOK" }" | shasum -a 256 | cut -c1-16)"
  [ "$row_key" != "$unmasked_key" ] || fail "the row key is taken over the unmasked command"
  [ "$row_key" = "$masked_key" ] || fail "the row key is not taken over the masked command"
  run jq -e --arg c "$SECRET_CMD" '.tasks.FN0.metadata.blocked_on.detail.command == $c' "$STATE"
  assert_success
  _pp batch --state "$STATE"
  assert_success
  jq -e --arg c "$SECRET_CMD" '.payloads[0].questions[0].question | contains("! " + $c)' <<< "$output"
  _pp resume --state "$STATE" --task-id FN0 --answer manual
  assert_success
  jq -e --arg c "$SECRET_CMD" '.resume_block.command == $c' <<< "$output"
  [ "$(_rows permission_resumed)" = 1 ] || fail "expected one permission_resumed row"
  [ "$(jq -r 'select(.action == "permission_resumed") | .metadata.dedupe_key' "$AUDIT")" = "$masked_key" ] \
    || fail "the permission_resumed key is not taken over the masked command"
  for needle in "$GH_TOK" 'alice' "$SECRET_CMD" 'token literal' 'Bash(GITHUB' 'classifier_reason' \
    'allow_rule' '"command"'; do
    ! grep -qF -- "$needle" "$AUDIT" || fail "audit.jsonl leaks: $needle"
  done
  _assert_logs_clean "$GH_TOK" "$SECRET_CMD"
}

@test "B3: hook, park, megatask batch and resume write no token and no unmasked command under .context/logs" {
  local payload detail
  payload="$(jq -c --arg c "$SECRET_CMD" '.tool_input.command = $c' \
    "$FIXTURES/hooks/permission-denied/merge-denied.payload.json")"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$HOOK" <<< "$payload"
  assert_success
  _pp classify --payload "$payload"
  assert_success
  detail="$output"
  _pp park --state "$STATE" --task-id FN0 --detail "$detail"
  assert_success
  _ledger_jq '.tasks.PL0.metadata.megatask_group = "milestone-1"'
  printf '%s' '{"version":"2.0","execution":{"current_stage":null,"retry_count":0,"status":"in_progress","pr":null}}' \
    > "$WD/workspace.json"
  _pp batch --state "$STATE" --boundary FN0
  assert_success
  jq -e '.mode == "megatask_park" and .payloads == []' <<< "$output"
  _pp resume --state "$STATE" --task-id FN0 --answer manual
  assert_success
  jq -e --arg c "$SECRET_CMD" '.resume_block.command == $c' <<< "$output"

  # Every sanctioned full copy lives outside this directory: state.json's blocked_on, the stage
  # artifact's handoff.blocked_on, the resume instruction and batch's own stdout.
  _assert_logs_clean "$GH_TOK" "$SECRET_CMD"
  # --log /dev/null is scoped to the one --set that carries the command, not to the whole run:
  # the sibling --task-status write must still be logged, or the flag silenced too much.
  grep -qF -- 'ledger status: tasks.FN0 blocked' "$WD/.context/logs/state-merge.log" \
    || fail "state-merge.log lost its ledger status line; --log /dev/null is not scoped to one call"
}

@test "park: a second park of the same denial writes no second row" {
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  jq -e '.audit_row_written == true and .truncated == false' <<< "$output"
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  assert_success
  jq -e '.audit_row_written == false' <<< "$output"
  [ "$(_rows)" = 1 ] || fail "expected one row, got $(_rows)"
}

@test "dedupe: the key is the first 16 hex of sha256(task_id:tool:masked command)" {
  local expected
  expected="$(printf 'FN0:Bash:%s' "$MERGE_CMD" | shasum -a 256 | cut -c1-16)"
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  assert_success
  [ "$(jq -r '.dedupe_key' <<< "$output")" = "$expected" ] || fail "merge key is not over the (unchanged) masked command"
  expected="$(printf 'FN0:Bash:%s' 'mysql --password=[masked] -h db' | shasum -a 256 | cut -c1-16)"
  _pp park --state "$STATE" --task-id FN0 --detail "$(_detail_for 'mysql --password=hunter22 -h db')"
  assert_success
  [ "$(jq -r '.dedupe_key' <<< "$output")" = "$expected" ] || fail "password key is not over the masked command"
}

@test "B1: parks whose commands differ only in a --password= value share one key and one row" {
  local first
  _pp park --state "$STATE" --task-id FN0 --detail "$(_detail_for 'mysql --password=hunter22 -h db')"
  assert_success
  jq -e '.audit_row_written == true' <<< "$output"
  first="$(jq -r '.dedupe_key' <<< "$output")"
  _pp park --state "$STATE" --task-id FN0 --detail "$(_detail_for 'mysql --password=letmein9 -h db')"
  assert_success
  jq -e '.audit_row_written == false' <<< "$output"
  [ "$(jq -r '.dedupe_key' <<< "$output")" = "$first" ] || fail "keys differ across password values"
  [ "$(_rows)" = 1 ] || fail "expected one row, got $(_rows)"
}

@test "B1: park and resume exit 2 when a non-empty command cannot be masked, before any ledger write" {
  local shim
  shim="$(mk_tmpworkdir)"
  # Fails only the raw-input call pd_key_command makes; every other jq call on the path runs.
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -Rrs ] && exit 5; done\nexec "%s" "$@"\n' \
    "$(command -v jq)" > "$shim/jq"
  chmod +x "$shim/jq"
  run --separate-stderr env PATH="$shim:$PATH" bash "$PLUGIN_ROOT/$SCRIPT" park --state "$STATE" \
    --task-id FN0 --detail "$(_merge_detail)"
  [ "$status" -eq 2 ] || fail "park exit $status, want 2"
  jq -e '.tasks.FN0.status == "in_progress" and (.tasks.FN0.metadata.blocked_on // null) == null' "$STATE"
  [ "$(_rows)" = 0 ] || fail "park wrote a row"
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  assert_success
  run --separate-stderr env PATH="$shim:$PATH" bash "$PLUGIN_ROOT/$SCRIPT" resume --state "$STATE" \
    --task-id FN0 --answer grant
  [ "$status" -eq 2 ] || fail "resume exit $status, want 2"
  jq -e '.tasks.FN0.status == "blocked" and .tasks.FN0.metadata.blocked_on.kind == "permission"' "$STATE"
  [ "$(_rows permission_resumed)" = 0 ] || fail "resume wrote a row"
}

@test "park: refuses a bad task id, a detail without a tool, and a missing ledger" {
  _pp park --state "$STATE" --task-id fn0 --detail "$(_merge_detail)"
  [ "$status" -eq 2 ]
  _pp park --state "$STATE" --task-id FN0 --detail '{"command":"x"}'
  [ "$status" -eq 2 ]
  _pp park --state "$WD/none.json" --task-id FN0 --detail "$(_merge_detail)"
  [ "$status" -eq 2 ]
  run jq -r '.tasks.FN0.status' "$STATE"
  assert_output "in_progress"
}

# --- batch -----------------------------------------------------------------------

@test "AC3: two tasks parked at one boundary render exactly one payload naming both" {
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  _pp park --state "$STATE" --task-id DR0 --detail "$(_detail_for "$RESET_CMD")"
  _pp batch --state "$STATE"
  assert_success
  jq -e --arg a "$MERGE_CMD" --arg b "$RESET_CMD" '
    (.payloads | length) == 1 and (.payloads[0].questions | length) == 2
    and ([.payloads[0].questions[].question] | map(select(contains($a) or contains($b))) | length) == 2
    and [.payloads[0].questions[].options[].label] == [
      "grant and continue", "run it yourself", "grant and continue", "run it yourself"]
    and ([.needs[].truncated] | all(. == false))' <<< "$output"
}

@test "SR: the command renders inside a fence longer than its longest backtick run, never in a label" {
  local cmd='echo ```` `x`'
  _pp park --state "$STATE" --task-id FN0 --detail "$(_detail_for "$cmd")"
  _pp batch --state "$STATE"
  assert_success
  jq -e --arg c "$cmd" '.payloads[0].questions[0]
    | (.question | contains("`````\ntool: Bash\ncommand: " + $c + "\n"))
      and (.question | contains("`````\n! " + $c + "\n`````"))
      and ([.options[].label, .options[].description] | map(contains($c)) | any | not)' <<< "$output"
}

@test "AC15: the run-it-yourself suggestion carries the ledger cwd as a data line, never spliced into the ! line" {
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  _pp batch --state "$STATE"
  assert_success
  jq -e --arg c "$MERGE_CMD" '.needs[0].cwd == "/tmp/wt"
    and (.payloads[0].questions[0].question
      | contains("reason: Blocked by classifier\ncwd: /tmp/wt\n```\n")
        and contains("run it from that directory")
        and contains("```\n! " + $c + "\n```")
        and (contains("cd /tmp/wt") | not) and (contains("&&") | not))' <<< "$output"
  run jq -e '(.tasks.FN0.metadata.blocked_on.detail | keys) == ["allow_rule", "classifier_reason", "command", "tool"]' "$STATE"
  assert_success

  _ledger_jq '.tasks.FN0.metadata.workspace_path = "/tmp/a```` b"'
  _pp batch --state "$STATE"
  assert_success
  jq -e '.payloads[0].questions[0].question
    | contains("`````\ntool: Bash") and contains("\ncwd: /tmp/a```` b\n`````")' <<< "$output"

  _ledger_jq 'del(.tasks.FN0.metadata.workspace_path)'
  _pp batch --state "$STATE"
  assert_success
  jq -e --arg c "$MERGE_CMD" '.needs[0].cwd == ""
    and (.payloads[0].questions[0].question
      | (contains("cwd:") | not) and contains("To run it yourself, enter:\n\n```\n! " + $c + "\n```"))' <<< "$output"
}

@test "SR: a truncated command is flagged and never offered as a runnable ! line" {
  local long
  long="make $(printf 'x%.0s' $(seq 1 700))"
  _pp park --state "$STATE" --task-id FN0 --detail "$(_detail_for "$long")"
  assert_success
  jq -e '.truncated == true and (.blocked_on.detail.command | length) == 512' <<< "$output"
  _pp batch --state "$STATE"
  assert_success
  jq -e '.needs[0].truncated == true
    and (.payloads[0].questions[0].question | contains("\n! ") | not)
    and (.payloads[0].questions[0].question | contains("/permissions recent denials"))
    and (.payloads[0].questions[0].question | contains("truncated"))' <<< "$output"
  _pp resume --state "$STATE" --task-id FN0 --answer grant
  assert_success
  jq -e '.resume_block.truncated == true
    and (.resume_block.instruction | contains("truncated"))' <<< "$output"
}

@test "batch: more than four needs split into payloads of at most four questions" {
  local id
  for id in DV0 DV1 DV2 DV3 DV4; do
    _ledger_jq ".tasks.$id = {status: \"blocked\", metadata: {blocked_on: {kind: \"permission\",
      detail: {tool: \"Bash\", command: \"make $id\", classifier_reason: \"Blocked by classifier\", allow_rule: \"\"},
      resume_with: \"decision_ref\"}}}"
  done
  _pp batch --state "$STATE"
  assert_success
  jq -e '[.payloads[].questions | length] == [4, 1]' <<< "$output"
}

@test "batch: --tasks limits the needs; nothing parked is an empty, valid batch" {
  _pp batch --state "$STATE"
  assert_success
  jq -e '.mode == "ask" and .needs == [] and .payloads == []' <<< "$output"
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  _pp park --state "$STATE" --task-id DR0 --detail "$(_detail_for "$RESET_CMD")"
  _pp batch --state "$STATE" --tasks DR0
  assert_success
  jq -e '[.needs[].task_id] == ["DR0"]' <<< "$output"
  _pp batch --state "$STATE" --tasks 'DR0,$(id)'
  [ "$status" -eq 2 ]
}

@test "batch: a task that is not blocked is skipped even with a leftover permission blocked_on" {
  _ledger_jq '.tasks.DR0.metadata.blocked_on = {kind: "permission",
    detail: {tool: "Bash", command: "stale", classifier_reason: "Blocked by classifier", allow_rule: ""},
    resume_with: "decision_ref"}'
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  _pp batch --state "$STATE"
  assert_success
  jq -e '[.needs[].task_id] == ["FN0"]' <<< "$output"
}

@test "AC11: under a megatask per-issue run the boundary parks the issue instead of asking" {
  _ledger_jq '.tasks.PL0.metadata.megatask_group = "milestone-1"'
  printf '%s' '{"version":"2.0","execution":{"current_stage":null,"retry_count":0,"status":"in_progress","pr":null}}' \
    > "$WD/workspace.json"
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  _pp park --state "$STATE" --task-id DR0 --detail "$(_detail_for "$SECRET_CMD")"
  _pp batch --state "$STATE" --boundary FN0
  assert_success
  jq -e '.mode == "megatask_park" and .payloads == []
    and .park.execution == {status: "failed", reason: "parked_escalation"}
    and .park.workspace_written == true and .park.workspace_reason == null
    and .park.audit_row_written == true' <<< "$output"
  _pp batch --state "$STATE" --boundary FN0
  assert_success

  run jq -e '.execution.status == "failed" and .execution.reason == "parked_escalation"
    and .execution.retry_count == 0' "$WD/workspace.json"
  assert_success
  [ -z "$(find "$WD" -maxdepth 1 -name '.workspace.json.*')" ] || fail "temp file left beside workspace.json"
  [ "$(_rows escalation_parked)" = 1 ] || fail "expected one escalation_parked row, got $(_rows escalation_parked)"
  run jq -e --arg c "$MERGE_CMD_HEAD" 'select(.action == "escalation_parked")
    | .subject == "FN0"
    and .metadata.escalated[0] == {tool: "Bash", command_head: $c, truncated: true}
    and (.metadata.escalated | length) == 2
    and ([.metadata.escalated[] | keys_unsorted] | all(. == ["tool", "command_head", "truncated"]))
    and .metadata.escalated[1].command_head == "gh [redacted] -X [redacted]"' "$AUDIT"
  assert_success
  local needle
  for needle in "$GH_TOK" "$SECRET_CMD" "Bash($MERGE_CMD)" 'allow_rule' 'classifier_reason' '"command"'; do
    ! grep -qF -- "$needle" "$AUDIT" || fail "audit.jsonl leaks: $needle"
  done
  _assert_logs_clean "$GH_TOK" "$SECRET_CMD"
  run jq -e --arg c "$SECRET_CMD" '.tasks.FN0.metadata.blocked_on.kind == "permission"
    and .tasks.DR0.metadata.blocked_on.detail.command == $c' "$STATE"
  assert_success
}

@test "AC13: a symlinked workspace.json is refused with a reason; the link and its target are untouched" {
  _ledger_jq '.tasks.PL0.metadata.megatask_group = "milestone-1"'
  printf '%s' '{"execution":{"status":"in_progress"}}' > "$WD/real.json"
  cp "$WD/real.json" "$WD/real.before"
  ln -s "$WD/real.json" "$WD/workspace.json"
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  _pp batch --state "$STATE" --boundary FN0
  assert_success
  jq -e '.park.workspace_written == false and .park.workspace_reason == "symlink"' <<< "$output"
  [ -L "$WD/workspace.json" ] || fail "the symlink itself was replaced"
  [ "$(readlink "$WD/workspace.json")" = "$WD/real.json" ] || fail "the symlink was re-pointed"
  cmp -s "$WD/real.json" "$WD/real.before" || fail "the link target changed"
  [ -z "$(find "$WD" -maxdepth 1 -name '.workspace.json.*')" ] || fail "temp file left beside workspace.json"

  rm -f "$WD/workspace.json"
  _pp batch --state "$STATE" --boundary FN0
  assert_success
  jq -e '.park.workspace_written == false and .park.workspace_reason == "missing"' <<< "$output"
}

@test "AC11: no parked_* reason other than parked_escalation exists in megatask or the new scripts" {
  local hits
  hits="$(grep -rn 'parked_permission\|reason: *"parked_' "$PLUGIN_ROOT/skills/megatask" \
    "$PLUGIN_ROOT/commands/megatask.md" || true)"
  [ -z "$(printf '%s\n' "$hits" | grep -v 'parked_escalation' | grep -v '^$' || true)" ] \
    || fail "unexpected parked_ reason: $hits"
  run grep -ohE 'parked_[a-z_]+' "$PLUGIN_ROOT/$SCRIPT" "$PLUGIN_ROOT/$HOOK" "$PLUGIN_ROOT/$LIB"
  [ -z "$(printf '%s\n' "$output" | sort -u | grep -vx 'parked_escalation' | grep -v '^$' || true)" ] \
    || fail "new reason value introduced: $output"
}

# --- resume ----------------------------------------------------------------------

@test "AC4: grant resume names only the denied merge and forbids re-running completed steps" {
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  _pp resume --state "$STATE" --task-id FN0 --answer grant
  assert_success
  jq -e --arg c "$MERGE_CMD" '.cleared == true
    and .resume_block.task_id == "FN0" and .resume_block.command == $c
    and .resume_block.do_not_rerun == true and .resume_block.truncated == false
    and (.resume_block.instruction | contains($c))
    and (.resume_block.instruction | contains("Do not re-run any step that already completed"))' <<< "$output"
  refute_output --partial "commit"
  refute_output --partial "push"
}

@test "resume: a manual answer tells the step the user already ran the command" {
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  _pp resume --state "$STATE" --task-id FN0 --answer manual
  assert_success
  jq -e '.resume_block.answer == "manual" and (.resume_block.instruction | contains("themselves"))' <<< "$output"
}

@test "resume: one permission_resumed row records the answer, and decision_ref names it" {
  local key ref
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  key="$(jq -r '.dedupe_key' <<< "$output")"
  _pp resume --state "$STATE" --task-id FN0 --answer manual
  assert_success
  ref="$(jq -r '.resume_block.decision_ref' <<< "$output")"
  [ "$ref" = "permission_resumed:FN0:$key:1" ] || fail "unexpected decision_ref: $ref"
  jq -e '.audit_row_written == true' <<< "$output"
  [ "$(_rows permission_resumed)" = 1 ] || fail "expected one permission_resumed row, got $(_rows permission_resumed)"
  run jq -e --arg c "$MERGE_CMD_HEAD" --arg k "$key" --arg r "$ref" 'select(.action == "permission_resumed")
    | .actor == "orchestrator" and .subject == "FN0" and .result == "ok"
    and (.metadata | keys_unsorted) == ["tool", "dedupe_key", "command_head", "truncated", "answer", "decision_ref"]
    and .metadata == {tool: "Bash", dedupe_key: $k, command_head: $c, truncated: true,
      answer: "manual", decision_ref: $r}' "$AUDIT"
  assert_success

  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  _pp resume --state "$STATE" --task-id FN0 --answer grant
  assert_success
  [ "$(jq -r '.resume_block.decision_ref' <<< "$output")" = "permission_resumed:FN0:$key:2" ]
}

@test "resume: a task not parked for a permission is refused and the ledger is unchanged" {
  local before
  before="$(cat "$STATE")"
  _pp resume --state "$STATE" --task-id FN0 --answer grant
  [ "$status" -eq 1 ]
  [ "$(cat "$STATE")" = "$before" ]
  _pp park --state "$STATE" --task-id FN0 --detail "$(_merge_detail)"
  _pp resume --state "$STATE" --task-id FN0 --answer yes
  [ "$status" -eq 2 ]
  run jq -r '.tasks.FN0.status' "$STATE"
  assert_output "blocked"
  [ "$(_rows permission_resumed)" = 0 ] || fail "a refused resume wrote a permission_resumed row"
}

# --- security gates --------------------------------------------------------------

@test "AC7: neither script writes Claude Code settings or allow rules" {
  run grep -nE 'settings(\.local)?\.json|permissions\.allow' "$PLUGIN_ROOT/$HOOK" \
    "$PLUGIN_ROOT/$LIB" "$PLUGIN_ROOT/$SCRIPT" "$PLUGIN_ROOT/$SELFTEST"
  [ "$status" -eq 1 ] || fail "settings or allow-rule reference found: $output"
}

@test "AC7: no hook or worktask script emits a retry-true decision" {
  run grep -rnE '"retry"[[:space:]]*:[[:space:]]*true' "$PLUGIN_ROOT/hooks" "$PLUGIN_ROOT/skills/worktask/scripts"
  [ "$status" -eq 1 ] || fail "retry-true found: $output"
}

# --- doc contracts (prose owned by the docs task) ---------------------------------

@test "doc-contract AC9: the audit-source table pairs PermissionDenied with permission_denied" {
  run grep -nE '^\|.*`PermissionDenied`.*`permission_denied`' "$PLUGIN_ROOT/skills/agent-coordination/SKILL.md"
  assert_success
}

@test "doc-contract AC6: the 6.5a4 park arm forbids hand-landing the denied command and spending a retry" {
  local block
  block="$(_section "$SKILL_MD" '##### Step 6.5a4 — detect and park' '^##### Step 6.5 — verdict')"
  [ -n "$block" ] || fail "Step 6.5a4 detect-and-park block not found"
  grep -qF 'permission-park.sh' <<< "$block" || fail "6.5a4 does not route to permission-park.sh"
  grep -qF 'Never land the denied command yourself' <<< "$block" || fail "6.5a4 lacks the hand-landing prohibition"
  grep -qF 'Never spend a retry on it' <<< "$block" || fail "6.5a4 lacks the no-retry prohibition"
  grep -qF 'no `retry_count` increment' <<< "$block" || fail "6.5a4 does not name retry_count"
}

@test "doc-contract b1: 6.5a4 reaches classify only on a blocked or escalate verdict" {
  local block
  block="$(_section "$SKILL_MD" '##### Step 6.5a4 — detect and park' '^##### ')"
  grep -qF '["blocked","escalate"].includes(incHandoff?.verdict)' <<< "$block" \
    || fail "6.5a4 lacks the verdict gate"
  grep -qF 'never reaches classify' <<< "$block" \
    || fail "6.5a4 does not say completing and failing verdicts never reach classify"
  grep -qF 'last Tool(...) line at or before the classifier' <<< "$block" \
    || fail "6.5a4 does not say classify takes the last tool line at or before the classifier wording"
}

@test "doc-contract b3: handoff-protocol defines the cross-stage blocked exception and cites it at both tables and both rules" {
  local f="$(contract_source "$PLUGIN_ROOT/$PROTOCOL_MD")" line
  grep -qF 'Cross-stage blocked exception:' "$f" || fail "exception sentence missing"
  _section "$PROTOCOL_MD" '#### Stages PL–DR' '^#### Stages SR–ET' | grep -qiF 'cross-stage blocked exception' \
    || fail "PL–DR table does not cite the exception"
  _section "$PROTOCOL_MD" '#### Stages SR–ET' '^### ' | grep -qiF 'cross-stage blocked exception' \
    || fail "SR–ET table does not cite the exception"
  line="$(grep -F "enum MUST match that stage's row" "$f" || true)"
  [ -n "$line" ] && grep -qiF 'cross-stage blocked exception' <<< "$line" \
    || fail "the verdict-enum rule does not cite the exception"
  line="$(grep -F '`blocked_on` is optional' "$f" || true)"
  [ -n "$line" ] && grep -qiF 'cross-stage blocked exception' <<< "$line" \
    || fail "the blocked_on convention does not cite the exception"
}

@test "doc-contract b3: stage-contracts says every vocabulary returns blocked, never fail, no-go or reject" {
  local block
  block="$(_section "$CONTRACTS_MD" '### A permission denial is returned' '^##')"
  [ -n "$block" ] || fail "stage-contracts permission section not found"
  grep -qF 'pass/fail, go/no-go and approve/reject stages' <<< "$block" \
    || fail "section does not name the pass/fail, go/no-go and approve/reject stages"
  grep -qiF 'never returned as fail, no-go or reject' <<< "$block" \
    || fail "section does not forbid returning a denial as fail, no-go or reject"
}

@test "doc-contract AC9: blocked_on is documented on every routing and schema surface" {
  local f
  for f in skills/worktask/references/orchestration.md skills/worktask/references/workflow.md \
    skills/worktask/references/handoff-protocol.md skills/agent-coordination/SKILL.md \
    skills/agent-coordination/references/hook-monitoring.md skills/worktask/references/stage-contracts.md; do
    grep -qw 'blocked_on' "$(contract_source "$PLUGIN_ROOT/$f")" || fail "$f does not mention blocked_on"
  done
}

@test "doc-contract AC9: hook-monitoring no longer advises returning retry: true" {
  local hits
  hits="$(grep -n 'retry: true' "$PLUGIN_ROOT/skills/agent-coordination/references/hook-monitoring.md" || true)"
  [ -z "$(printf '%s\n' "$hits" | grep -v 'never' | grep -v '^$' || true)" ] \
    || fail "a retry: true line does not say corpflow never returns it: $hits"
}

@test "doc-contract AC12: the handoff schema lists the blocked_on enums verbatim and every kind's required keys" {
  local schema line req
  schema="$(_section "$PROTOCOL_MD" '### Schema — blocked_on' '^### Schema — .defs')"
  [ -n "$schema" ] || fail "Schema — blocked_on section not found"
  grep -qF 'kind: user_decision | user_action | permission | peer_session | artifact | correction | host_environment' <<< "$schema" \
    || fail "kind enum missing"
  grep -qF 'resume_with: decision_ref | artifact_path | reply_ref' <<< "$schema" || fail "resume_with enum missing"
  line="$(grep -E '^[[:space:]]*detail: \{…kind-specific…\}' <<< "$schema" || true)"
  grep -qF '# e.g. permission: {tool, command, classifier_reason, allow_rule}; peer_session: {to, question, deadline}' <<< "$line" \
    || fail "the detail line does not carry the registry's e.g. comment: $line"
  for req in '[question, options]' '[request, command]' '[tool, command, classifier_reason, allow_rule]' \
    '[to, question]' '[producer_task, path]' '[target_task, finding, evidence_ref, severity]' '[check, observed]'; do
    grep -qF "required: $req" <<< "$schema" || fail "no arm declares required: $req"
  done
}

@test "doc-contract AC13: the megatask fallback never hand-writes a symlinked workspace.json" {
  local spec file start stop block
  for spec in 'skills/worktask/references/workflow.md|##### Boundary permission prompt — only the user answers|^####' \
    "skills/worktask/references/step-7a-arms.md|## Step 7a — the megatask arm|^## "; do
    IFS='|' read -r file start stop <<< "$spec"
    block="$(_section "$file" "$start" "$stop")"
    [ -n "$block" ] || fail "$file: section '$start' not found"
    grep -qF 'never Writes or Edits a symlinked `workspace.json`' <<< "$block" \
      || fail "$file: no rule that the orchestrator never writes a symlinked workspace.json"
    grep -qF 'workspace_reason' <<< "$block" || fail "$file: workspace_reason is not named"
    ! grep -qF 'or a symlink' <<< "$block" || fail "$file: a symlink is still a reason to hand-write"
  done
}

@test "doc-contract AC5: the prose states the redacted permission row shapes" {
  local f="$PLUGIN_ROOT/skills/agent-coordination/SKILL.md" line block
  line="$(grep -E '^\|.*`PermissionDenied`.*`permission_denied`' "$f" || true)"
  grep -qF 'metadata.{tool, dedupe_key, command_head, truncated}' <<< "$line" \
    || fail "the PermissionDenied audit-source row does not state the redacted shape: $line"
  line="$(grep -E '^\|.*`permission_resumed`' "$f" || true)"
  grep -qF 'metadata.{tool, dedupe_key, command_head, truncated, answer: grant\|manual, decision_ref}' <<< "$line" \
    || fail "the permission_resumed audit-source row does not state the redacted shape: $line"
  ! grep -nE 'source: "(hook|orchestrator)"|classifier_reason, allow_rule, source' "$f" \
    || fail "agent-coordination still documents the unredacted row"
  block="$(_section skills/worktask/references/workflow.md '##### Boundary permission prompt — only the user answers' '^####')"
  grep -qF '`{tool, command_head, truncated}`' <<< "$block" \
    || fail "the megatask escalated[] shape is not the redacted one"
  ! grep -qF '{tool, command, allow_rule}' <<< "$block" || fail "the megatask escalated[] shape still names the command"
}

@test "doc-contract B1: agent-coordination says the dedupe key is taken over the masked command" {
  local f="$PLUGIN_ROOT/skills/agent-coordination/SKILL.md"
  grep -qF 'of the command after secret masking, never the unmasked text' "$f" \
    || fail "the dedupe-key sentence does not say it is derived from the masked command"
  ! grep -qF 'of the full command' "$f" || fail "agent-coordination still derives the key from the full command"
}

@test "contract: --self-test passes (smoke, NON-counting)" {
  run_script_env "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "self-test OK"
  assert_output --regexp 'self-test OK \([1-9][0-9]* passed, 0 failed\)'
}
