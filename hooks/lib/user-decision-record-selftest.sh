#!/usr/bin/env bash
# @description user-decision-record-selftest.sh — the self-test for hooks/user-decision-record.sh.
#   Sources the hook with `--lib-only`, so every case calls the hook's own do_post/do_pre and the
#   lib's ud_* functions directly against a throwaway `.context`, never the stdin dispatch.
#
#   AC5: row 1 carries `prev_sha256: null` and the canonical `[question,answer]` digest; row 2's
#   `prev_sha256` is the digest of row 1's stored line bytes. Every expected digest below is a
#   literal constant computed once from the fixed inputs beside it, so a drift in the hashing
#   code cannot also move its own expectation.
#
#   Only `set -u`: the lib and hook return 1 as a normal refusal, so errexit would abort on the
#   very outcomes these cases assert.
#
# @exitcode 0 every case passed, or jq is absent (skipped)
# @exitcode 1 at least one case failed
#
# Usage: bash hooks/lib/user-decision-record-selftest.sh
# Minimum shell: bash 3.2+.
set -u

_ST_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

command -v jq > /dev/null 2>&1 || {
  printf 'user-decision-record: jq not found — self-test skipped\n'
  exit 0
}

# A runner that exported a root must never steer these cases into a real ledger.
unset CONTEXT_DIR CLAUDE_PROJECT_DIR WORKSPACE_ROOT

# shellcheck source=/dev/null  # following it would read its --lib-only `return` as unreachable code here
. "$_ST_DIR/../user-decision-record.sh" --lib-only
set +e

# sha256 of the bytes ["Ship the ledger now?","Yes, ship it"] (no trailing LF).
readonly ST_C1="9a935cce7ef6f8d91d0199f2af4d2f99d30473698c82be2f92d44e02c009d120"
# sha256 of the bytes ["Which targets must pass?","macOS, Linux"] (array answer joined with ", ").
readonly ST_C2="b25f9084b8a0513709c4c49a8c5d73a23cdfa2987aad0aceb1143a6d108cb488"
# ST_ROW1 is a stored row-1 line; ST_L1 is sha256 of exactly those bytes, without the LF.
readonly ST_ROW1='{"id":"ud-20260917T101500Z-1","ts":"2026-09-17T10:15:00Z","actor":"hook:user-decision","tool_use_id":"toolu_selftest_row1","question":"Ship the ledger now?","answer":"Yes, ship it","scope":{"worktask_id":"wt-ud-selftest","task_ids":["DV0"],"item":null},"sha256":"9a935cce7ef6f8d91d0199f2af4d2f99d30473698c82be2f92d44e02c009d120","prev_sha256":null}'
readonly ST_L1="39539b0b5aa280ece192933fec6bf738bb9f0ebb86441fb1431a77a7d51b875b"
readonly ST_Q1="Ship the ledger now?"
readonly ST_SID="sess-ud-selftest"

_st_fails=0
_st_passed=0
_st_pass() { _st_passed=$((_st_passed + 1)); printf '  ok   %s\n' "$1"; }
_st_fail() {
  printf '  FAIL %s\n' "$1"
  _st_fails=$((_st_fails + 1))
}
# _st_rc <label> <rc> — pass when <rc> is 0; call it right after the condition it judges.
_st_rc() {
  if [ "$2" -eq 0 ]; then _st_pass "$1"; else _st_fail "$1 (rc $2)"; fi
}
# _st_is <label> <got> <want> — pass on byte equality.
_st_is() {
  if [ "$2" = "$3" ]; then _st_pass "$1"; else _st_fail "$1 (got '$2')"; fi
}
# _st_append <ctx> <ledger> <payload> — ud_append_call with the hook's own audit callback.
_st_append() {
  # shellcheck disable=SC2034  # read by the sourced hook's _ud_cb
  UD_AUDIT_CTX="$1"
  ud_append_call "$2" "$1/state.json" "$3" _ud_cb
}
# _st_hook <do_post|do_pre> <payload-json> — one hook mode against a payload string.
_st_hook() {
  # shellcheck disable=SC2034  # read by the sourced hook's do_post/do_pre
  PAYLOAD="$2"
  "$1"
}

_st_td="$(mktemp -d 2> /dev/null)" || {
  printf 'user-decision-record: self-test FAIL (mktemp)\n'
  exit 1
}
_st_td="$(CDPATH='' cd -- "$_st_td" && pwd -P)"
# shellcheck disable=SC2064  # expand now: the path is fixed for this run
trap "rm -rf -- '$_st_td'" EXIT

# _st_ctx <name> — a fresh <td>/<name>/.context holding the scope state; prints the ctx path.
# DV0 is parked on ST_Q1 (rung 1); sw-AR0-1 is an open sweep item (rung 2).
_st_ctx() {
  local ctx="$_st_td/$1/.context"
  mkdir -p "$ctx/logs"
  jq -n --arg q "$ST_Q1" '{
    version: 2, worktask_id: "wt-ud-selftest", run_index: 0,
    facts: {open_questions: [{id: "sw-AR0-1", summary: "Record rung-3 answers?", class: "scope"}]},
    tasks: {
      AR0: {status: "completed", metadata: {stage: "AR"}},
      DV0: {status: "blocked", metadata: {stage: "DV", blocked_on: {kind: "user_decision",
        detail: {question: $q, options: ["Yes, ship it", "Not yet"]}, resume_with: "decision_ref"}}}
    }}' > "$ctx/state.json"
  printf '%s' "$ctx"
}

# _st_payload <out> <tool_use_id> <header> <question> <answers-json> [extra-jq] — a PostToolUse
# AskUserQuestion payload whose transcript_path sits beside it as <session_id>.jsonl.
_st_payload() {
  local out="$1" tuid="$2" header="$3" q="$4" answers="$5" extra="${6:-.}" tp
  tp="${out%/*}/$ST_SID.jsonl"
  jq -n --arg t "$tuid" --arg h "$header" --arg q "$q" --argjson a "$answers" \
    --arg tp "$tp" --arg sid "$ST_SID" '{
      session_id: $sid, transcript_path: $tp, cwd: "/tmp", hook_event_name: "PostToolUse",
      tool_name: "AskUserQuestion", tool_use_id: $t,
      tool_input: {questions: [{question: $q, header: $h, multiSelect: false,
        options: [{label: "Yes, ship it"}, {label: "Not yet"}]}]},
      tool_response: {answers: $a}}' | jq -c "$extra" > "$out"
}

# _st_transcript <out> <tool_use_id> [input-extra-jq] — one assistant AskUserQuestion tool_use.
_st_transcript() {
  local out="$1" tuid="$2" extra="${3:-.}"
  jq -cn --arg t "$tuid" --arg q "$ST_Q1" '{type: "assistant", message: {role: "assistant",
    content: [{type: "tool_use", id: $t, name: "AskUserQuestion",
      input: {questions: [{question: $q, header: "DV0"}]}}]}}' \
    | jq -c ".message.content[0].input |= ($extra)" > "$out"
}

_st_last_audit() { tail -n 1 -- "$1/logs/audit.jsonl" 2> /dev/null; }

st_digests() {
  local f="$_st_td/row1.json"
  printf '%s' "$ST_ROW1" > "$f"
  _st_is "AC5: canonical digest of row 1 is the pinned literal" "$(ud_row_sha256 "$f")" "$ST_C1"
  _st_is "AC5: line digest of row 1's stored bytes is the pinned literal" "$(ud_line_sha256 "$ST_ROW1")" "$ST_L1"
  _st_is "AC5: ud_digest of the row-2 canonical bytes is the pinned literal" \
    "$(printf '%s' '["Which targets must pass?","macOS, Linux"]' | ud_digest)" "$ST_C2"
}

st_row1_append() {
  local ctx ledger p out rc
  ctx="$(_st_ctx row1)"
  ledger="$ctx/decisions.jsonl"
  p="$ctx/p1.json"
  _st_payload "$p" toolu_selftest_row1 DV0 "$ST_Q1" '{"Ship the ledger now?":"Yes, ship it"}'
  out="$(_st_append "$ctx" "$ledger" "$p")"
  rc=$?
  _st_rc "AC5: first append succeeds, reason '$out'" "$rc"
  _st_is "AC5: first append writes exactly one line" "$(wc -l < "$ledger" 2> /dev/null | tr -d ' ')" 1
  jq -e --arg c "$ST_C1" --arg keys "$UD_ROW_KEYS" --arg re "$UD_ID_RE" '
      .prev_sha256 == null and .sha256 == $c and (keys_unsorted == ($keys | split(" ")))
      and (.id | test($re)) and (.id | endswith("-1")) and .actor == "hook:user-decision"
      and .tool_use_id == "toolu_selftest_row1"
      and .scope == {worktask_id: "wt-ud-selftest", task_ids: ["DV0"], item: null}' "$ledger" > /dev/null 2>&1
  _st_rc "AC5: row 1 has prev_sha256 null, the pinned sha256, the seam key order and a -1 id" $?
  jq -se --arg c "$ST_C1" '[.[] | select(.action == "user_decision_recorded" and .result == "ok")]
      | length == 1 and .[0].metadata.row_sha256 == $c and .[0].actor == "hook:user-decision"' \
    "$ctx/logs/audit.jsonl" > /dev/null 2>&1
  _st_rc "AC5: one user_decision_recorded audit row whose row_sha256 is the pinned digest" $?
}

st_row2_append() {
  local ctx ledger p out rc
  ctx="$(_st_ctx row2)"
  ledger="$ctx/decisions.jsonl"
  p="$ctx/p2.json"
  printf '%s\n' "$ST_ROW1" > "$ledger"
  _st_payload "$p" toolu_selftest_row2 sw-AR0-1 "Which targets must pass?" \
    '{"Which targets must pass?":["macOS","Linux"]}'
  out="$(_st_append "$ctx" "$ledger" "$p")"
  rc=$?
  _st_rc "AC5: second append succeeds, reason '$out'" "$rc"
  _st_is "AC5: row 1 bytes survive the copy+rename append" "$(head -n 1 -- "$ledger")" "$ST_ROW1"
  jq -se --arg l1 "$ST_L1" --arg c2 "$ST_C2" 'length == 2 and .[1].prev_sha256 == $l1
      and .[1].sha256 == $c2 and (.[1].id | endswith("-2")) and .[1].answer == "macOS, Linux"
      and .[1].scope == {worktask_id: "wt-ud-selftest", task_ids: ["AR0"], item: "sw-AR0-1"}' "$ledger" > /dev/null 2>&1
  _st_rc "AC5: row 2 prev_sha256 is the pinned digest of row 1's stored line bytes" $?
  _st_is "AC5: the chain walk finds no reason on either row" \
    "$(ud_chain_walk "$ledger" | jq -sc 'map(.reasons) | add')" "[]"
}

# _st_append_refusal <label> <ctx> <ledger> <payload> <reason> — rc 1, that reason, ledger unchanged.
_st_append_refusal() {
  local label="$1" ctx="$2" ledger="$3" p="$4" want="$5" before="" after="" out rc
  [ -f "$ledger" ] && before="$(shasum -a 256 < "$ledger")"
  out="$(_st_append "$ctx" "$ledger" "$p")"
  rc=$?
  [ -f "$ledger" ] && after="$(shasum -a 256 < "$ledger")"
  if [ "$rc" -eq 1 ] && [ "$out" = "$want" ] && [ "$before" = "$after" ]; then
    _st_pass "$label"
  else
    _st_fail "$label (rc $rc, reason '$out')"
  fi
}

st_append_refusals() {
  local ctx ledger p del
  ctx="$(_st_ctx refuse)"
  ledger="$ctx/decisions.jsonl"
  p="$ctx/p.json"

  _st_payload "$p" toolu_selftest_row1 DV0 "$ST_Q1" '{"Ship the ledger now?":"Yes, ship it"}'
  printf '%s\n' "$ST_ROW1" > "$ledger"
  _st_append_refusal "P5: a tool_use_id already in the ledger refuses as replay" "$ctx" "$ledger" "$p" replay

  printf '%s' "$ST_ROW1" > "$ledger"
  _st_payload "$p" toolu_selftest_torn DV0 "$ST_Q1" '{"Ship the ledger now?":"Yes, ship it"}'
  _st_append_refusal "append: a last line with no LF refuses as ledger_torn" "$ctx" "$ledger" "$p" ledger_torn

  rm -f -- "$ledger"
  _st_payload "$p" toolu_selftest_idle DV0 "$ST_Q1" '{"Ship the ledger now?":"Yes, ship it"}' \
    '.tool_response.afkTimeoutMs = 60000'
  _st_append_refusal "P3: an afkTimeoutMs response refuses as idle_auto_answer" "$ctx" "$ledger" "$p" idle_auto_answer

  _st_payload "$p" toolu_selftest_none DV0 "$ST_Q1" '{}'
  _st_append_refusal "P3: a response with no per-question answers refuses as no_answer" "$ctx" "$ledger" "$p" no_answer

  _st_payload "$p" toolu_selftest_shape DV0 "$ST_Q1" '{"Ship the ledger now?":{"label":"Yes, ship it"}}'
  _st_append_refusal "P6: a non-string, non-string-array answer refuses as answer_shape" "$ctx" "$ledger" "$p" answer_shape

  _st_payload "$p" toolu_selftest_scope QA9 "$ST_Q1" '{"Ship the ledger now?":"Yes, ship it"}'
  _st_append_refusal "P7: a header that names no parked task or sweep item refuses as no_scope" "$ctx" "$ledger" "$p" no_scope

  del="$(printf 'Ship\177it?')"
  _st_payload "$p" toolu_selftest_del DV0 "$del" "$(jq -cn --arg q "$del" '{($q): "Yes, ship it"}')"
  _st_append_refusal "AD2: a question holding U+007F refuses as unstable_encoding" "$ctx" "$ledger" "$p" unstable_encoding
}

# _st_transcript_refusal <label> <payload> <reason>
_st_transcript_refusal() {
  local out rc
  out="$(ud_transcript_check "$2")"
  rc=$?
  if [ "$rc" -eq 1 ] && [ "$out" = "$3" ]; then _st_pass "$1"; else _st_fail "$1 (rc $rc, reason '$out')"; fi
}

st_transcript_refusals() {
  local dir="$_st_td/transcript" p
  mkdir -p "$dir"
  p="$dir/p.json"
  _st_payload "$p" toolu_selftest_tx DV0 "$ST_Q1" '{"Ship the ledger now?":"Yes, ship it"}'

  _st_transcript "$dir/$ST_SID.jsonl" toolu_selftest_tx
  ud_transcript_check "$p" > /dev/null
  _st_rc "P4: a transcript holding this AskUserQuestion tool_use passes" $?

  _st_transcript "$dir/$ST_SID.jsonl" toolu_selftest_other
  _st_transcript_refusal "P4: a transcript without this tool_use_id refuses as transcript_miss" "$p" transcript_miss

  _st_transcript "$dir/$ST_SID.jsonl" toolu_selftest_tx '. + {answers: {"Ship the ledger now?": "Yes, ship it"}}'
  _st_transcript_refusal "P3: answers already in the transcript's tool_use.input refuse as pre_answered" "$p" pre_answered

  _st_transcript "$dir/real.jsonl" toolu_selftest_tx
  rm -f -- "$dir/$ST_SID.jsonl"
  ln -s "$dir/real.jsonl" "$dir/$ST_SID.jsonl"
  _st_transcript_refusal "P4: a symlinked transcript refuses as transcript_miss" "$p" transcript_miss

  jq -c --arg tp "$dir/real.jsonl" '.transcript_path = $tp' "$p" > "$dir/p-name.json"
  _st_transcript_refusal "P4: a transcript not named <session_id>.jsonl refuses as transcript_miss" \
    "$dir/p-name.json" transcript_miss
}

st_do_post_refusals() {
  local ctx out
  ctx="$(_st_ctx post)"
  export WORKSPACE_ROOT="${ctx%/.context}"

  out="$(_st_hook do_post "$(jq -cn \
    '{hook_event_name: "PostToolUse", tool_name: "Bash", tool_use_id: "toolu_selftest_ev"}')")"
  _st_is "P2: a tool other than AskUserQuestion prints nothing" "$out" ""
  _st_last_audit "$ctx" | jq -e '.action == "user_decision_refused" and .result == "skipped"
    and .subject == "AskUserQuestion" and .metadata == {reason: "bad_event"}' > /dev/null 2>&1
  _st_rc "P2: its refusal row is bad_event and carries no tool_use_id" $?

  _st_hook do_post "$(jq -cn \
    '{hook_event_name: "PostToolUse", tool_name: "AskUserQuestion", tool_use_id: "toolu bad;id"}')" > /dev/null
  _st_last_audit "$ctx" | jq -e '.metadata == {reason: "bad_event"}' > /dev/null 2>&1
  _st_rc "P2: a tool_use_id outside the id grammar refuses as bad_event" $?

  _st_payload "$ctx/p.json" toolu_selftest_post DV0 "$ST_Q1" '{"Ship the ledger now?":"Yes, ship it"}'
  _st_transcript "$ctx/$ST_SID.jsonl" toolu_selftest_elsewhere
  _st_hook do_post "$(cat "$ctx/p.json")" > /dev/null
  _st_last_audit "$ctx" | jq -e '.metadata == {reason: "transcript_miss", tool_use_id: "toolu_selftest_post"}' \
    > /dev/null 2>&1
  _st_rc "P4: do_post refuses transcript_miss with the tool_use_id once P2 passed" $?
  if grep -qF -e "$ST_Q1" -e "Yes, ship it" -- "$ctx/logs/audit.jsonl"; then
    _st_fail "audit: no refusal row carries the question or answer text"
  else
    _st_pass "audit: no refusal row carries the question or answer text"
  fi
  if [ -e "$ctx/decisions.jsonl" ]; then
    _st_fail "P2-P4: no refusal created the ledger"
  else
    _st_pass "P2-P4: no refusal created the ledger"
  fi
  unset WORKSPACE_ROOT
}

# _st_norm <label> <n> <text> <want-answers-json|untouched> — ud_normalize_answers over an MCP
# text payload asking Q1..Qn; "untouched" means the file must keep its bytes (P3 refuses it).
_st_norm() {
  local f="$_st_td/norm.json" before after got
  jq -cn --argjson n "$2" --arg t "$3" '{tool_input: {questions: [range(0; $n) | {question: "Q\(. + 1)"}]},
    tool_response: [{type: "text", text: $t}]}' > "$f"
  before="$(shasum -a 256 < "$f")"
  ud_normalize_answers "$f" > /dev/null 2>&1
  after="$(shasum -a 256 < "$f")"
  if [ "$4" = untouched ]; then
    _st_is "$1" "$after" "$before"
  else
    got="$(jq -c '.tool_response.answers? // null' "$f" 2> /dev/null)"
    _st_is "$1" "$got" "$4"
  fi
}

st_normalize() {
  local nl='
'
  _st_norm "P3: a multi-line block joins its continuation with LF" 2 \
    "User responses:${nl}1. line a${nl}line b${nl}2. c" '{"Q1":"line a\nline b","Q2":"c"}'
  _st_norm "P3: a number above N is continuation text" 2 \
    "User responses:${nl}1. a${nl}7. step${nl}2. b" '{"Q1":"a\n7. step","Q2":"b"}'
  _st_norm "P3: a repeated block start is refused" 2 "User responses:${nl}1. a${nl}2. x${nl}2. b" untouched
  _st_norm "P3: a missing block start is refused" 2 "User responses:${nl}1. a${nl}3. b" untouched
  _st_norm "P3: a missing header is refused" 2 "1. a${nl}2. b" untouched
  _st_norm "P3: too few blocks are refused" 2 "User responses:${nl}1. a" untouched
  _st_norm "P3: an empty answer is refused" 2 "User responses:${nl}1. ${nl}2. b" untouched
}

st_guard() {
  local ctx out
  ctx="$(_st_ctx guard)"
  export WORKSPACE_ROOT="${ctx%/.context}"
  out="$(_st_hook do_pre "$(jq -cn --arg f "$ctx/decisions.jsonl" \
    '{hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: $f, content: "{}\n"}}')")"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null 2>&1
  _st_rc "AD8: a Write to the ledger is denied" $?
  out="$(_st_hook do_pre "$(jq -cn '{hook_event_name: "PreToolUse", tool_name: "Bash",
    tool_input: {command: "cat .context/decisions.jsonl"}}')")"
  _st_is "AD8: a read-only Bash command on the ledger is allowed" "$out" ""
  unset WORKSPACE_ROOT
}

st_digests
st_row1_append
st_row2_append
st_append_refusals
st_transcript_refusals
st_do_post_refusals
st_normalize
st_guard

if [ "$_st_fails" -eq 0 ]; then
  printf 'user-decision-record: self-test OK (%d passed, %d failed)\n' "$_st_passed" "$_st_fails"
  exit 0
fi
printf 'user-decision-record: self-test FAILED (%d passed, %d failed)\n' "$_st_passed" "$_st_fails"
exit 1
