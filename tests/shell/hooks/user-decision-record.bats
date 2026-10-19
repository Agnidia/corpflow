#!/usr/bin/env bats
# Tests for hooks/user-decision-record.sh — PostToolUse AskUserQuestion appends one hash-chained
# ledger row per answered, scoped question; PreToolUse Write|Edit|Bash denies a ledger write.
#
# The ledger name is materialised only inside each test's temp dir: no fixture file carries it
# (AD8), and the fixture payloads hold __TRANSCRIPT__/__CTX__ placeholders filled in per test.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="hooks/user-decision-record.sh"
SELFTEST="hooks/lib/user-decision-record-selftest.sh"
UD_FIX="${FIXTURES}/worktask/user-decision"
Q1="Ship the ledger now?"
A1="Yes, ship it"
# sha256 of the bytes ["Ship the ledger now?","Yes, ship it"].
C1="9a935cce7ef6f8d91d0199f2af4d2f99d30473698c82be2f92d44e02c009d120"
# sha256 of the bytes ["Should rung-3 answers be recorded?","Record with empty task_ids, Write nothing"].
CS="01850ed18109a41570375239783bf43789564c6e5117adc6eb2842c4f8b766dc"

setup() {
  # Physical path: the Write/Edit arm compares a pwd -P target against the context root.
  WD="$(CDPATH='' cd -- "$(mk_tmpworkdir)" && pwd -P)"
  CTX="$WD/.context"
  mkdir -p "$CTX/logs" "$WD/transcripts"
  cp "$UD_FIX/state.rung1.json" "$CTX/state.json"
  LEDGER="$CTX/decisions.jsonl"
  AUDIT="$CTX/logs/audit.jsonl"
  TRANSCRIPT="$WD/transcripts/sess-ud-fixture.jsonl"
  cp "$UD_FIX/transcript.valid.jsonl" "$TRANSCRIPT"
  PAYLOAD_FILE="$WD/payload.json"
}

# _hook [root] — the hook as the harness runs it, stdin from $PAYLOAD_FILE, rooted at [root].
# Runs from $WD under a git ceiling: once state.json is removed, the root ladder's git ranks must
# find nothing rather than the checkout running this suite and its real audit log.
_hook() {
  # shellcheck disable=SC2016  # $1/$2 are the inner shell's positional args, expanded there
  run --separate-stderr env -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR WORKSPACE_ROOT="${1:-$WD}" \
    GIT_CEILING_DIRECTORIES="${WD%/*}" \
    bash -c 'cd -- "$1" && exec bash "$2"' _ "$WD" "$PLUGIN_ROOT/$SCRIPT" < "$PAYLOAD_FILE"
}

# _post <fixture> [jq-filter] — stage a PostToolUse payload pointing at $TRANSCRIPT.
_post() {
  jq -c --arg tp "$TRANSCRIPT" ".transcript_path = \$tp | ${2:-.}" "$UD_FIX/$1" > "$PAYLOAD_FILE"
}

# _pre <fixture> [jq-filter] — stage a PreToolUse payload with __CTX__ resolved to $CTX.
_pre() {
  jq -c --arg ctx "$CTX" "(.tool_input.file_path? |= (if . == null then . else sub(\"__CTX__\"; \$ctx) end)) | ${2:-.}" \
    "$UD_FIX/$1" > "$PAYLOAD_FILE"
}

# _bash_cmd <command> — stage a PreToolUse Bash payload carrying <command>.
_bash_cmd() {
  jq -c --arg c "$1" '.tool_input.command = $c' "$UD_FIX/pre.bash-ledger-read.payload.json" > "$PAYLOAD_FILE"
}

_ledger_rows() {
  [ -f "$LEDGER" ] || {
    echo 0
    return 0
  }
  wc -l < "$LEDGER" | tr -d ' '
}

_count_action() {
  [ -f "$AUDIT" ] || {
    echo 0
    return 0
  }
  grep -c "\"action\":\"$1\"" "$AUDIT" || true
}

# _assert_refused <reason> [tool_use_id] — no ledger, silent success, one refusal row naming it.
_assert_refused() {
  assert_success
  assert_output ""
  [ ! -e "$LEDGER" ] || fail "a refusal wrote the ledger: $(cat "$LEDGER")"
  [ "$(_count_action user_decision_refused)" = 1 ] || fail "expected one refusal row, got $(_count_action user_decision_refused)"
  if [ -n "${2:-}" ]; then
    jq -e --arg r "$1" --arg t "$2" 'select(.action == "user_decision_refused")
      | .actor == "hook:user-decision" and .result == "skipped" and .subject == "AskUserQuestion"
      and .metadata == {reason: $r, tool_use_id: $t}' "$AUDIT" || fail "refusal row: $(cat "$AUDIT")"
  else
    jq -e --arg r "$1" 'select(.action == "user_decision_refused")
      | .actor == "hook:user-decision" and .result == "skipped" and .metadata == {reason: $r}' "$AUDIT" \
      || fail "refusal row: $(cat "$AUDIT")"
  fi
}

_assert_denied() {
  assert_success
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
    and .hookSpecificOutput.permissionDecision == "deny"' > /dev/null || fail "expected deny, got: $output"
}

_assert_allowed() {
  assert_success
  assert_output ""
  [ "$(_count_action user_decision_ledger_write_denied)" = 0 ] || fail "an allowed call wrote a deny row"
}

# --- AC1: the hook half ----------------------------------------------------------------------

@test "AC1: one answered AskUserQuestion on a parked task appends exactly one row whose scope covers that task" {
  _post post.valid.payload.json
  _hook
  assert_success
  assert_output ""
  [ "$(_ledger_rows)" = 1 ] || fail "expected one row, got $(_ledger_rows)"
  run jq -e --arg q "$Q1" --arg a "$A1" --arg c "$C1" '
    (keys_unsorted == ["id", "ts", "actor", "tool_use_id", "question", "answer", "scope", "sha256", "prev_sha256"])
    and (.id | test("^ud-[0-9]{8}T[0-9]{6}Z-1$"))
    and .actor == "hook:user-decision" and .tool_use_id == "toolu_01UdFixture0001"
    and .question == $q and .answer == $a
    and .scope == {worktask_id: "wt-ud-fixture", task_ids: ["DV0"], item: null}
    and .sha256 == $c and .prev_sha256 == null' "$LEDGER"
  assert_success
  [ -z "$(tail -c 1 "$LEDGER")" ] || fail "the row is not LF-terminated"
  run ls -l "$LEDGER"
  assert_output --regexp '^-rw-------'
}

@test "AC1: the recorded audit row names the row id, tool_use_id and row digest, and nothing is degraded" {
  _post post.valid.payload.json
  _hook
  assert_success
  local id
  id="$(jq -r .id "$LEDGER")"
  [ "$(_count_action user_decision_recorded)" = 1 ] || fail "expected one recorded row: $(cat "$AUDIT")"
  run jq -e --arg id "$id" --arg c "$C1" 'select(.action == "user_decision_recorded")
    | .actor == "hook:user-decision" and .result == "ok" and .subject == $id
    and (.metadata | keys_unsorted) == ["decision_id", "tool_use_id", "row_sha256", "item"]
    and .metadata == {decision_id: $id, tool_use_id: "toolu_01UdFixture0001", row_sha256: $c, item: null}' "$AUDIT"
  assert_success
  ! grep -qF '"result":"degraded"' "$AUDIT" || fail "a confirmed row was reported degraded"
}

@test "AC1: rung 1 covers every task parked on the same question, options and item, sorted" {
  jq '.tasks.DV1 = .tasks.DV0
    | .tasks.DC0 = (.tasks.DV0 | .metadata.blocked_on.detail.options = ["Yes, ship it"])' \
    "$UD_FIX/state.rung1.json" > "$CTX/state.json"
  _post post.valid.payload.json
  _hook
  assert_success
  run jq -ce '.scope.task_ids' "$LEDGER"
  assert_output '["DV0","DV1"]'
}

@test "AC1: a need parked with no options pairs under the asker's synthetic labels, and covers its whole group" {
  # blocked-on-dispatch.sh `batch` renders a free-text need under two labels it never stores, to
  # clear AskUserQuestion's 2-option floor. Matching the stored [] against them would scope the
  # answer to nothing and leave the need unresumable.
  jq '.tasks.DV0.metadata.blocked_on.detail = {question: "Ship the ledger now?", options: []}
    | .tasks.DV1 = .tasks.DV0' "$UD_FIX/state.rung1.json" > "$CTX/state.json"
  _post post.valid.payload.json '(.tool_input.questions[0].options, .tool_response.questions[0].options)
    = [{label: "the stage decides", description: "No preset choices here."},
       {label: "raise this need again", description: "Raise the need again rather than settle it."}]
    | .tool_response.answers = {"Ship the ledger now?": "Ship it once the audit lands"}'
  _hook
  assert_success
  assert_output ""
  [ "$(_ledger_rows)" = 1 ] || fail "expected one row, got $(_ledger_rows)"
  run jq -e --arg q "$Q1" '.question == $q and .answer == "Ship it once the audit lands"
    and .scope == {worktask_id: "wt-ud-fixture", task_ids: ["DV0", "DV1"], item: null}' "$LEDGER"
  assert_success
  # Payload-only: the synthetic labels are not an answer and never reach the ledger or the log.
  ! grep -qF "the stage decides" "$LEDGER" || fail "a synthetic label reached the ledger"
  ! grep -qF "the stage decides" "$AUDIT" || fail "a synthetic label reached the audit log"
}

@test "AC1: a need parked with real options still refuses a question asked under different ones" {
  # ANTI-VACUITY: the empty-list tolerance above must not widen to any option mismatch.
  jq '.tasks.DV0.metadata.blocked_on.detail.options = ["Yes, ship it", "Much later"]
    | del(.tasks.DV0.metadata.blocked_on.detail.recommended)' \
    "$UD_FIX/state.rung1.json" > "$CTX/state.json"
  _post post.valid.payload.json
  _hook
  assert_success
  run jq -ce '.scope.task_ids' "$LEDGER"
  assert_output '[]'
}

@test "AC1: rung 2 scopes a sweep header to its one task and item, and joins an array answer with ', '" {
  cp "$UD_FIX/state.rung2.json" "$CTX/state.json"
  _post post.sweep.payload.json
  _hook
  assert_success
  [ "$(_ledger_rows)" = 1 ] || fail "expected one row, got $(_ledger_rows)"
  run jq -e --arg c "$CS" '.answer == "Record with empty task_ids, Write nothing"
    and .scope == {worktask_id: "wt-ud-fixture", task_ids: ["AR0"], item: "sw-AR0-1"}
    and .sha256 == $c and .prev_sha256 == null' "$LEDGER"
  assert_success
  run jq -e 'select(.action == "user_decision_recorded") | .metadata.item == "sw-AR0-1"' "$AUDIT"
  assert_success
}

@test "AC1: a second call chains onto the first — ordinal 2 and prev_sha256 = sha256 of row 1's line bytes" {
  jq '.facts.open_questions = [{id: "sw-AR0-1", summary: "Record rung-3 answers?", class: "scope"}]' \
    "$UD_FIX/state.rung1.json" > "$CTX/state.json"
  _post post.valid.payload.json
  _hook
  assert_success
  _post post.sweep.payload.json
  _hook
  assert_success
  [ "$(_ledger_rows)" = 2 ] || fail "expected two rows, got $(_ledger_rows)"
  local line1_sha
  line1_sha="$(head -n 1 "$LEDGER" | tr -d '\n' | shasum -a 256 | cut -d' ' -f1)"
  run jq -se --arg p "$line1_sha" '(.[1].id | endswith("-2")) and .[1].prev_sha256 == $p' "$LEDGER"
  assert_success
}

@test "AC1: a fork subagent's call (agent_id present) is still the user's answer and records" {
  _post post.valid.payload.json '.agent_id = "agent-fork-1"'
  _hook
  assert_success
  [ "$(_ledger_rows)" = 1 ] || fail "expected one row, got $(_ledger_rows)"
}

# --- AC2: provenance refusals ----------------------------------------------------------------

@test "AC2: a tool other than AskUserQuestion writes no row; bad_event carries no tool_use_id" {
  _post post.valid.payload.json '.tool_name = "AskUserQuestionX"'
  _hook
  _assert_refused bad_event
}

@test "R5: a PostToolUse payload naming no ask tool exits at the prefilter — no row, no audit" {
  _post post.bad-event.payload.json
  _hook
  assert_success
  assert_output ""
  [ ! -e "$LEDGER" ] || fail "a non-ask payload wrote the ledger"
  [ ! -e "$AUDIT" ] || fail "a non-ask payload wrote an audit row: $(cat "$AUDIT")"
}

# --- MCP-proxied ask tool (Conductor) --------------------------------------------------------

MCP_TOOL="mcp__conductor__AskUserQuestion"

# _mcp_post <response-text> — the valid payload as an MCP proxy delivers it: its tool name and a
# text content array in place of the answers object; the transcript's call carries the same name.
_mcp_post() {
  jq -c --arg tp "$TRANSCRIPT" --arg tn "$MCP_TOOL" --arg t "$1" \
    '.transcript_path = $tp | .tool_name = $tn | .tool_response = [{type: "text", text: $t}]' \
    "$UD_FIX/post.valid.payload.json" > "$PAYLOAD_FILE"
  sed "s/\"name\":\"AskUserQuestion\"/\"name\":\"$MCP_TOOL\"/" "$UD_FIX/transcript.valid.jsonl" > "$TRANSCRIPT"
}

@test "R1: an mcp__<server>__AskUserQuestion text answer records one row with the numbered answer" {
  _mcp_post "User responses:
1. $A1"
  _hook
  assert_success
  assert_output ""
  [ "$(_ledger_rows)" = 1 ] || fail "expected one row, got $(_ledger_rows); audit: $(cat "$AUDIT" 2> /dev/null)"
  run jq -e --arg q "$Q1" --arg a "$A1" --arg c "$C1" '.question == $q and .answer == $a and .sha256 == $c
    and .scope.task_ids == ["DV0"]' "$LEDGER"
  assert_success
}

@test "R1: a lookalike tool name refuses as bad_event; unnumbered or miscounted text refuses as no_answer" {
  _post post.valid.payload.json '.tool_name = "mcp__x__AskUserQuestionEvil"'
  _hook
  _assert_refused bad_event

  local text
  for text in "User responses:
$A1" "User responses:
1. $A1
1. again" "1. $A1" "User responses:
2. $A1"; do
    rm -f "$AUDIT" "$LEDGER"
    _mcp_post "$text"
    _hook
    _assert_refused no_answer toolu_01UdFixture0001
  done
}

@test "R1: an MCP answer whose transcript call carries another tool name refuses as transcript_miss" {
  _mcp_post "User responses:
1. $A1"
  cp "$UD_FIX/transcript.valid.jsonl" "$TRANSCRIPT"
  _hook
  _assert_refused transcript_miss toolu_01UdFixture0001
}

@test "R1 (QA): an object-shaped content wrapper ({content:[...]}) normalizes the same as a bare array" {
  jq -c --arg tp "$TRANSCRIPT" --arg tn "$MCP_TOOL" --arg t "User responses:
1. $A1" \
    '.transcript_path = $tp | .tool_name = $tn | .tool_response = {content: [{type: "text", text: $t}]}' \
    "$UD_FIX/post.valid.payload.json" > "$PAYLOAD_FILE"
  sed "s/\"name\":\"AskUserQuestion\"/\"name\":\"$MCP_TOOL\"/" "$UD_FIX/transcript.valid.jsonl" > "$TRANSCRIPT"
  _hook
  assert_success
  assert_output ""
  [ "$(_ledger_rows)" = 1 ] || fail "expected one row, got $(_ledger_rows); audit: $(cat "$AUDIT" 2> /dev/null)"
  run jq -e --arg q "$Q1" --arg a "$A1" --arg c "$C1" '.question == $q and .answer == $a and .sha256 == $c
    and .scope.task_ids == ["DV0"]' "$LEDGER"
  assert_success
}

# --- R3: multi-line MCP answers ---------------------------------------------------------------

Q2="Which targets must pass?"

# _mcp_post2 <response-text> — an MCP payload asking Q1 (parked DV0) and Q2 (open sweep item
# sw-AR0-1), with the transcript's recorded call carrying both questions under the same tool name.
_mcp_post2() {
  jq '.facts.open_questions = [{id: "sw-AR0-1", summary: "Which targets?", class: "scope"}]' \
    "$CTX/state.json" > "$CTX/state.json.new" && mv "$CTX/state.json.new" "$CTX/state.json"
  jq -c --arg tp "$TRANSCRIPT" --arg tn "$MCP_TOOL" --arg t "$1" --arg q2 "$Q2" '
    .transcript_path = $tp | .tool_name = $tn | .tool_response = [{type: "text", text: $t}]
    | .tool_input.questions += [.tool_input.questions[0] | .question = $q2 | .header = "sw-AR0-1"]' \
    "$UD_FIX/post.valid.payload.json" > "$PAYLOAD_FILE"
  jq -c --arg tn "$MCP_TOOL" --slurpfile p "$PAYLOAD_FILE" '
    if .type == "assistant" then .message.content |= map(if .type == "tool_use"
      then .name = $tn | .input.questions = $p[0].tool_input.questions else . end) else . end' \
    "$UD_FIX/transcript.valid.jsonl" > "$TRANSCRIPT"
}

@test "R3: a multi-line answer block records verbatim, joined with LF, one row per question" {
  _mcp_post2 "User responses:
1. line a
line b
2. c"
  _hook
  assert_success
  assert_output ""
  [ "$(_ledger_rows)" = 2 ] || fail "expected two rows, got $(_ledger_rows); audit: $(cat "$AUDIT" 2> /dev/null)"
  run jq -se --arg q1 "$Q1" --arg q2 "$Q2" '
    (map({(.question): .answer}) | add) == {($q1): "line a\nline b", ($q2): "c"}' "$LEDGER"
  assert_success
}

@test "R3: a number above N is continuation text, not a block start" {
  _mcp_post2 "User responses:
1. a
7. step
2. b"
  _hook
  assert_success
  [ "$(_ledger_rows)" = 2 ] || fail "expected two rows, got $(_ledger_rows); audit: $(cat "$AUDIT" 2> /dev/null)"
  run jq -se --arg q1 "$Q1" '[.[] | select(.question == $q1) | .answer] == ["a\n7. step"]' "$LEDGER"
  assert_success
}

@test "R3: ambiguous or incomplete numbered text refuses as no_answer and writes no row" {
  local text
  for text in "User responses:
1. a
2. x
2. b" "User responses:
1. a
3. b" "1. a
2. b" "User responses:
1. a" "User responses:
1. 
2. b" "User responses:
2. b
1. a" "User responses:
preamble
1. a
2. b" "User responses:
1.  
2. b"; do
    rm -f "$AUDIT" "$LEDGER"
    _mcp_post2 "$text"
    _hook
    _assert_refused no_answer toolu_01UdFixture0001
  done
}

# --- R6: one ask-tool pattern ------------------------------------------------------------------

# _post_lib_only <shell-snippet> — do_post from the hook sourced --lib-only, after <snippet> runs,
# against $PAYLOAD_FILE; lets a case replace the lib's pattern the hook must read.
_post_lib_only() {
  # shellcheck disable=SC2016  # expanded by the inner shell
  run --separate-stderr env -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR WORKSPACE_ROOT="$WD" \
    GIT_CEILING_DIRECTORIES="${WD%/*}" \
    bash -c 'cd -- "$1" && . "$2" --lib-only && eval "$4" && PAYLOAD=$(cat "$3") && do_post' \
    _ "$WD" "$PLUGIN_ROOT/$SCRIPT" "$PAYLOAD_FILE" "$1"
}

@test "R6: the ask-tool pattern is defined only in the lib" {
  run grep -cE '^[[:space:]]*_?UD_ASK_TOOL_RE=' "$PLUGIN_ROOT/$SCRIPT"
  assert_output "0"
  run grep -cE '^UD_ASK_TOOL_RE=' "$PLUGIN_ROOT/hooks/lib/user-decision-lib.sh"
  assert_output "1"
}

@test "R6: the plugin.json PostToolUse matcher that routes to this hook equals UD_ASK_TOOL_RE" {
  local lib manifest
  lib="$(grep -E '^UD_ASK_TOOL_RE=' "$PLUGIN_ROOT/hooks/lib/user-decision-lib.sh" | cut -d= -f2- | tr -d "'")"
  manifest="$(jq -r '[.hooks.PostToolUse[] | select(any(.hooks[]; .command | endswith("/hooks/user-decision-record.sh")))
    | .matcher] | if length == 1 then .[0] else "count=\(length)" end' "$PLUGIN_ROOT/.claude-plugin/plugin.json")"
  [ -n "$lib" ] && [ "$manifest" = "$lib" ] || fail "manifest=$manifest lib=$lib"
}

@test "R6: do_post matches the tool name against the lib's UD_ASK_TOOL_RE" {
  _mcp_post "User responses:
1. $A1"
  _post_lib_only 'UD_ASK_TOOL_RE="^AskUserQuestion\$"'
  _assert_refused bad_event
}

@test "R6: an empty or unset UD_ASK_TOOL_RE never matches — refused as no_digest_tool before the match" {
  local snip
  for snip in 'UD_ASK_TOOL_RE=""' 'unset UD_ASK_TOOL_RE'; do
    rm -f "$AUDIT" "$LEDGER"
    _post post.valid.payload.json '.tool_name = "Bash"'
    _post_lib_only "$snip"
    _assert_refused no_digest_tool
  done
}

@test "AC2: a tool_use_id outside ^[A-Za-z0-9_-]{1,128}\$ refuses as bad_event" {
  local bad
  for bad in 'toolu bad' 'toolu;rm' '' "$(printf '%0129d' 0 | tr 0 x)"; do
    rm -f "$AUDIT"
    _post post.valid.payload.json ".tool_use_id = \"$bad\""
    _hook
    _assert_refused bad_event
  done
}

@test "AC2: a tool_use_id absent from the transcript writes no row (transcript_miss)" {
  cp "$UD_FIX/transcript.missing-id.jsonl" "$TRANSCRIPT"
  _post post.valid.payload.json
  _hook
  _assert_refused transcript_miss toolu_01UdFixture0001
}

@test "AC2: a transcript not named <session_id>.jsonl, or a symlinked one, refuses as transcript_miss" {
  _post post.valid.payload.json '.session_id = "sess-other"'
  _hook
  _assert_refused transcript_miss toolu_01UdFixture0001

  rm -f "$AUDIT"
  mv "$TRANSCRIPT" "$WD/real.jsonl"
  ln -s "$WD/real.jsonl" "$TRANSCRIPT"
  _post post.valid.payload.json
  _hook
  _assert_refused transcript_miss toolu_01UdFixture0001
}

@test "AC2: answers already in the transcript's own tool_use.input refuse as pre_answered" {
  cp "$UD_FIX/transcript.pre-answered.jsonl" "$TRANSCRIPT"
  _post post.valid.payload.json
  _hook
  _assert_refused pre_answered toolu_01UdFixture0001
}

@test "AC2: tool_input.answers alone is no pre-answer signal — the permission UI fills it for real answers" {
  _post post.valid.payload.json ".tool_input.answers = {\"$Q1\": \"$A1\"}"
  _hook
  assert_success
  [ "$(_ledger_rows)" = 1 ] || fail "expected one row, got $(_ledger_rows)"
}

@test "AC2: an idle auto-answer (tool_response.afkTimeoutMs) refuses as idle_auto_answer" {
  _post post.idle.payload.json
  _hook
  _assert_refused idle_auto_answer toolu_01UdFixture0001
}

@test "AC2: a response with no per-question answers refuses as no_answer" {
  _post post.valid.payload.json '.tool_response.answers = {}'
  _hook
  _assert_refused no_answer toolu_01UdFixture0001
}

@test "AC2: an answer that is neither a string nor an array of strings refuses as answer_shape" {
  _post post.answer-shape.payload.json
  _hook
  _assert_refused answer_shape toolu_01UdFixture0001
}

@test "AC2: a header naming no parked task or sweep item (rung 3) writes nothing and refuses as no_scope" {
  _post post.valid.payload.json '.tool_input.questions[0].header = "Approve"'
  _hook
  _assert_refused no_scope toolu_01UdFixture0001
}

@test "AC2: a replayed tool_use_id writes no second row (replay)" {
  _post post.valid.payload.json
  _hook
  assert_success
  local before
  before="$(shasum -a 256 < "$LEDGER")"
  _hook
  assert_success
  assert_output ""
  [ "$(shasum -a 256 < "$LEDGER")" = "$before" ] || fail "the replay changed the ledger"
  run jq -e 'select(.action == "user_decision_refused") | .metadata == {reason: "replay", tool_use_id: "toolu_01UdFixture0001"}' "$AUDIT"
  assert_success
}

@test "AC2: a ledger whose last line lacks its LF is left byte-identical (ledger_torn)" {
  printf '%s' '{"id":"ud-20260917T101500Z-1"}' > "$LEDGER"
  _post post.valid.payload.json
  _hook
  assert_success
  assert_output ""
  [ "$(cat "$LEDGER")" = '{"id":"ud-20260917T101500Z-1"}' ] || fail "a torn ledger was appended to"
  run jq -e 'select(.action == "user_decision_refused") | .metadata.reason == "ledger_torn"' "$AUDIT"
  assert_success
}

@test "AC2: a symlinked ledger is never written through (ledger_symlink)" {
  printf 'untouched\n' > "$WD/elsewhere.txt"
  ln -s "$WD/elsewhere.txt" "$LEDGER"
  _post post.valid.payload.json
  _hook
  assert_success
  assert_output ""
  [ "$(cat "$WD/elsewhere.txt")" = "untouched" ] || fail "the symlink target was written"
  [ -L "$LEDGER" ] || fail "the symlink was replaced by a ledger"
  run jq -e 'select(.action == "user_decision_refused") | .metadata.reason == "ledger_symlink"' "$AUDIT"
  assert_success
}

@test "AC2: no state.json means no context — silent, no ledger, no audit row" {
  rm -f "$CTX/state.json"
  _post post.valid.payload.json
  _hook
  assert_success
  assert_output ""
  [ ! -e "$LEDGER" ] || fail "a ledger was written without state.json"
  [ "$(_count_action user_decision_refused)" = 0 ] || fail "a refusal row was written without state.json"
}

# --- AC6: the write guard --------------------------------------------------------------------

@test "AC6: a Write to the ledger is denied with one block row carrying only tool, dedupe_key, command_head, truncated" {
  _pre pre.write-ledger.payload.json
  _hook
  _assert_denied
  [ ! -e "$LEDGER" ] || fail "the guard itself created the ledger"
  [ "$(_count_action user_decision_ledger_write_denied)" = 1 ] || fail "expected one deny row"
  run jq -e 'select(.action == "user_decision_ledger_write_denied")
    | .actor == "hook:user-decision" and .result == "block" and .subject == "Write"
    and (.metadata | keys_unsorted | . - ["redaction"]) == ["tool", "dedupe_key", "command_head", "truncated"]
    and .metadata.tool == "Write"' "$AUDIT"
  assert_success
}

@test "AC6: an Edit to the ledger, and a Write under its lock dir, are denied" {
  _pre pre.edit-ledger.payload.json
  _hook
  _assert_denied

  mkdir -p "$LEDGER.lock"
  _pre pre.write-ledger.payload.json ".tool_input.file_path = \"$LEDGER.lock/owner\""
  _hook
  _assert_denied
}

@test "AC6: a Write through a dot-dot path that resolves to the ledger is denied" {
  mkdir -p "$CTX/logs/sub"
  _pre pre.write-ledger.payload.json ".tool_input.file_path = \"$CTX/logs/sub/../../decisions.jsonl\""
  _hook
  _assert_denied
}

@test "AC6: a Write to the ledger is denied when the workspace root is reached through a symlink" {
  ln -s "$WD" "$WD/rootlink"
  _pre pre.write-ledger.payload.json
  _hook "$WD/rootlink"
  _assert_denied
}

@test "AC6: every Bash write shape naming the ledger is denied" {
  local cmd
  _pre pre.bash-ledger-write.payload.json
  _hook
  _assert_denied
  # shellcheck disable=SC2016  # the $( ) shape is the literal command text under test
  for cmd in \
    'echo x > .context/decisions.jsonl' \
    'cat /tmp/forged >> .context/decisions.jsonl' \
    'printf x | tee -a .context/decisions.jsonl' \
    "sed -i '' 's/Not yet/Yes/' .context/decisions.jsonl" \
    'mv /tmp/forged .context/decisions.jsonl' \
    'cp /tmp/forged .context/decisions.jsonl' \
    'truncate -s 0 .context/decisions.jsonl' \
    'dd if=/tmp/forged of=.context/decisions.jsonl' \
    'jq -c . /tmp/forged > .context/decisions.jsonl' \
    'cat $(echo .context/decisions.jsonl)' \
    'eval "cat .context/decisions.jsonl"' \
    'ls /tmp | xargs cat .context/decisions.jsonl' \
    'A=1 perl -pi -e s/a/b/ .context/decisions.jsonl'; do
    _bash_cmd "$cmd"
    _hook
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null \
      || fail "expected deny for: $cmd (got: $output)"
  done
}

@test "AC6: read-only Bash commands on the ledger pass" {
  local cmd
  _pre pre.bash-ledger-read.payload.json
  _hook
  _assert_allowed
  for cmd in \
    'cat .context/decisions.jsonl' \
    'grep -c DV0 .context/decisions.jsonl' \
    'tail -n 1 .context/decisions.jsonl 2>/dev/null' \
    'cat .context/decisions.jsonl | wc -l' \
    'shasum -a 256 .context/decisions.jsonl && ls -l .context/decisions.jsonl'; do
    _bash_cmd "$cmd"
    _hook
    _assert_allowed
  done
}

@test "AC6: executing the hook script is denied; bash -n, shellcheck and editing its source pass" {
  local cmd
  for cmd in \
    'bash hooks/user-decision-record.sh < /tmp/p.json' \
    './hooks/user-decision-record.sh' \
    'source hooks/user-decision-record.sh --lib-only' \
    '. hooks/user-decision-record.sh --lib-only' \
    'exec hooks/user-decision-record.sh'; do
    _bash_cmd "$cmd"
    _hook
    assert_success
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null \
      || fail "expected deny for: $cmd (got: $output)"
  done
  # _assert_allowed counts deny rows in the whole log; clear the ones the deny loop above wrote.
  for cmd in 'bash -n hooks/user-decision-record.sh' 'shellcheck hooks/user-decision-record.sh'; do
    rm -f "$AUDIT"
    _bash_cmd "$cmd"
    _hook
    _assert_allowed
  done
  rm -f "$AUDIT"
  _pre pre.write-ledger.payload.json ".tool_input.file_path = \"$WD/hooks/user-decision-record.sh\""
  _hook
  _assert_allowed
}

@test "AC6: the fast path and a tree with no state.json both allow a ledger write untouched" {
  _bash_cmd 'git status --short'
  _hook
  _assert_allowed
  rm -f "$CTX/state.json"
  _pre pre.write-ledger.payload.json
  _hook
  assert_success
  assert_output ""
}

# --- R2: fail closed without jq or a library ---------------------------------------------------

# _nojq_path — a PATH directory holding the tools the hook forks, but no jq.
_nojq_path() {
  local d="$WD/nojq" t
  mkdir -p "$d"
  for t in bash cat dirname env mktemp awk tr rm git grep sed; do
    ln -sf "$(command -v "$t")" "$d/$t"
  done
  printf '%s' "$d"
}

# _hook_nojq [script] — _hook with jq absent from PATH.
_hook_nojq() {
  local p b
  p="$(_nojq_path)"
  b="$(command -v bash)"
  # shellcheck disable=SC2016  # $1/$2 are the inner shell's positional args, expanded there
  run --separate-stderr env -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR WORKSPACE_ROOT="$WD" \
    GIT_CEILING_DIRECTORIES="${WD%/*}" PATH="$p" \
    "$b" -c 'cd -- "$1" && exec bash "$2"' _ "$WD" "${1:-$PLUGIN_ROOT/$SCRIPT}" < "$PAYLOAD_FILE"
}

# _hook_copy — a copy of the hooks tree the case may break; prints the copied hook's path.
_hook_copy() {
  cp -R "$PLUGIN_ROOT/hooks" "$WD/hooks-copy"
  printf '%s' "$WD/hooks-copy/user-decision-record.sh"
}

# _each_guarded_pre <runner> — every PreToolUse shape the fast path guards, each asserted denied.
_each_guarded_pre() {
  _bash_cmd 'jq -c .id .context/decisions.jsonl'
  "$@"
  _assert_denied
  _pre pre.write-ledger.payload.json
  "$@"
  _assert_denied
  _bash_cmd 'bash -n hooks/user-decision-record.sh'
  "$@"
  _assert_denied
}

@test "R2: without jq every guarded PreToolUse shape is denied, exit 0" {
  _each_guarded_pre _hook_nojq
  [ ! -e "$LEDGER" ] || fail "the guard created the ledger"
}

@test "R2: without jq a spaced \"hook_event_name\" : \"PreToolUse\" is still denied" {
  _pre pre.write-ledger.payload.json
  sed 's/"hook_event_name":"PreToolUse"/"hook_event_name" : "PreToolUse"/' "$PAYLOAD_FILE" > "$PAYLOAD_FILE.s"
  mv "$PAYLOAD_FILE.s" "$PAYLOAD_FILE"
  grep -qF '"hook_event_name" : "PreToolUse"' "$PAYLOAD_FILE" || fail "fixture not spaced"
  _hook_nojq
  _assert_denied
}

@test "R2: without jq a PostToolUse copy inside the command string cannot pass as the event" {
  _bash_cmd 'cat .context/decisions.jsonl # "hook_event_name":"PostToolUse"'
  _hook_nojq
  _assert_denied
  jq -c '.hook_event_name = "PreToolUse" | {tool_input, hook_event_name, x: {hook_event_name: "PostToolUse"}}' \
    "$PAYLOAD_FILE" > "$PAYLOAD_FILE.s"
  mv "$PAYLOAD_FILE.s" "$PAYLOAD_FILE"
  _hook_nojq
  _assert_denied
}

@test "R2: without jq a PostToolUse AskUserQuestion payload prints nothing and writes nothing" {
  _post post.valid.payload.json
  _hook_nojq
  assert_success
  assert_output ""
  [ ! -e "$LEDGER" ] || fail "a jq-less run wrote the ledger"
}

@test "R2: without jq a tree with no state.json still allows a ledger write" {
  rm -f "$CTX/state.json"
  _pre pre.write-ledger.payload.json
  _hook_nojq
  assert_success
  assert_output ""
}

@test "R2 (M1): a 64 KB escape-dense jq-less Write to the ledger denies well inside the hook timeout" {
  local content start elapsed
  content="$(head -c 60000 /dev/zero | tr '\0' 'a' | sed 's/aaaa/a\\"\\/g')"
  _pre pre.write-ledger.payload.json
  jq -c --arg c "$content" '.tool_input.content = $c' "$PAYLOAD_FILE" > "$PAYLOAD_FILE.s"
  mv "$PAYLOAD_FILE.s" "$PAYLOAD_FILE"
  [ "$(wc -c < "$PAYLOAD_FILE")" -ge 65536 ] || fail "payload under 64 KB: $(wc -c < "$PAYLOAD_FILE")"
  start="$(date +%s)"
  _hook_nojq
  elapsed=$(($(date +%s) - start))
  _assert_denied
  [ "$elapsed" -le 3 ] || fail "jq-less deny took ${elapsed}s"
}

@test "R2 (M1): without jq a unicode-escaped PostToolUse copy in the command cannot pass as the event" {
  printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat .context/decisions.jsonl \u0022hook_event_name\u0022:\u0022PostToolUse\u0022"}}' \
    > "$PAYLOAD_FILE"
  _hook_nojq
  _assert_denied
}

@test "R2: an unreadable user-decision-lib.sh denies every guarded PreToolUse shape" {
  local hook
  hook="$(_hook_copy)"
  chmod 000 "$WD/hooks-copy/lib/user-decision-lib.sh"
  _each_guarded_pre _hook_at "$hook"
  chmod 644 "$WD/hooks-copy/lib/user-decision-lib.sh"
}

@test "R2: a missing context library denies instead of reading as no worktask" {
  local hook
  hook="$(_hook_copy)"
  rm -f "$WD/hooks-copy/model-switch-lib.sh"
  _each_guarded_pre _hook_at "$hook"
}

# _hook_at <script> — _hook against another copy of the hook script.
_hook_at() {
  # shellcheck disable=SC2016  # $1/$2 are the inner shell's positional args, expanded there
  run --separate-stderr env -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR WORKSPACE_ROOT="$WD" \
    GIT_CEILING_DIRECTORIES="${WD%/*}" \
    bash -c 'cd -- "$1" && exec bash "$2"' _ "$WD" "$1" < "$PAYLOAD_FILE"
}

# --- R5: the hot path sources nothing and forks no jq ----------------------------------------

# _probe_hook — the hook beside stub libraries that log their own sourcing to $WD/sourced, with a
# jq shim first on PATH that logs each call to $WD/jq.log before running the real jq.
_probe_hook() {
  local f
  mkdir -p "$WD/probe/lib" "$WD/shim"
  cp "$PLUGIN_ROOT/$SCRIPT" "$WD/probe/"
  for f in model-switch-lib.sh lib/command-head-lib.sh lib/permission-denied-lib.sh lib/user-decision-lib.sh; do
    printf 'printf "%%s\\n" %s >> %q\n' "$f" "$WD/sourced" > "$WD/probe/$f"
  done
  printf '#!/bin/sh\nprintf "jq\\n" >> %q\nexec %q "$@"\n' "$WD/jq.log" "$(command -v jq)" > "$WD/shim/jq"
  chmod +x "$WD/shim/jq"
  rm -f "$WD/sourced" "$WD/jq.log"
  # shellcheck disable=SC2016  # $1/$2 are the inner shell's positional args, expanded there
  run --separate-stderr env -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR WORKSPACE_ROOT="$WD" \
    GIT_CEILING_DIRECTORIES="${WD%/*}" PATH="$WD/shim:$PATH" \
    bash -c 'cd -- "$1" && exec bash "$2"' _ "$WD" "$WD/probe/user-decision-record.sh" < "$PAYLOAD_FILE"
}

@test "R5: a payload naming none of the prefilter strings sources no library and forks no jq" {
  _bash_cmd 'git status --short'
  _probe_hook
  assert_success
  assert_output ""
  [ ! -e "$WD/sourced" ] || fail "libraries sourced on the hot path: $(cat "$WD/sourced")"
  [ ! -e "$WD/jq.log" ] || fail "jq forked on the hot path: $(wc -l < "$WD/jq.log") call(s)"
}

@test "R5: a payload that hits the prefilter still sources the libraries and dispatches with jq" {
  _pre pre.write-ledger.payload.json
  _probe_hook
  assert_success
  [ "$(wc -l < "$WD/sourced" | tr -d ' ')" = 4 ] || fail "expected four libraries sourced"
  [ -s "$WD/jq.log" ] || fail "no jq call on the matched path"
}

# --- M2: case-blind name tests (case-insensitive volumes) -------------------------------------

@test "M2: a Write to .context/Decisions.jsonl is denied" {
  _pre pre.write-ledger.payload.json ".tool_input.file_path = \"$CTX/Decisions.jsonl\""
  _hook
  _assert_denied
}

@test "M2: a Bash rm .context/DECISIONS.JSONL is denied" {
  _bash_cmd 'rm .context/DECISIONS.JSONL'
  _hook
  _assert_denied
}

@test "M2: bash hooks/USER-DECISION-RECORD.sh is denied" {
  _bash_cmd 'bash hooks/USER-DECISION-RECORD.sh'
  _hook
  _assert_denied
}

@test "M2: the read-only allow-list still allows, whatever the name's case" {
  local cmd
  for cmd in 'cat .context/decisions.jsonl' 'jq -c .id .context/DECISIONS.JSONL' 'bash -n hooks/USER-DECISION-RECORD.sh'; do
    rm -f "$AUDIT"
    _bash_cmd "$cmd"
    _hook
    _assert_allowed
  done
}

# --- N1: APFS folds U+017F (long s) and U+212A (Kelvin) onto ASCII; nocasematch does not ------

@test "N1: a Write to .context/deciſions.jsonl (long s) is denied" {
  _pre pre.write-ledger.payload.json ".tool_input.file_path = \"$CTX/deciſions.jsonl\""
  grep -q "$(printf 'deci\305\277ions')" "$PAYLOAD_FILE" || fail "payload does not carry a raw U+017F"
  _hook
  _assert_denied
}

@test "N1: a Bash >> to .context/deciſions.jsonl is denied, raw or as a JSON \\u017F escape" {
  _bash_cmd "$(printf 'printf x >> .context/deci\305\277ions.jsonl')"
  _hook
  _assert_denied
  printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf x >> .context/deciſions.jsonl"}}' \
    > "$PAYLOAD_FILE"
  _hook
  _assert_denied
}

@test "N1: bash hooks/user-deciſion-record.sh is denied, and a Write under the Kelvin-sign lock dir too" {
  _bash_cmd "$(printf 'bash hooks/user-deci\305\277ion-record.sh')"
  _hook
  _assert_denied
  mkdir -p "$CTX/decisions.jsonl.lock"
  _pre pre.write-ledger.payload.json ".tool_input.file_path = \"$CTX/decisions.jsonl.locK/x\""
  _hook
  _assert_denied
}

@test "N1 (R3-2): with sed failing, a long-s Write to the ledger still denies (fold failure fails closed)" {
  mkdir -p "$WD/badsed"
  printf '#!/bin/sh\nexit 1\n' > "$WD/badsed/sed"
  chmod +x "$WD/badsed/sed"
  _pre pre.write-ledger.payload.json ".tool_input.file_path = \"$CTX/deciſions.jsonl\""
  # shellcheck disable=SC2016  # $1/$2 are the inner shell's positional args, expanded there
  run --separate-stderr env -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR WORKSPACE_ROOT="$WD" \
    GIT_CEILING_DIRECTORIES="${WD%/*}" PATH="$WD/badsed:$PATH" \
    bash -c 'cd -- "$1" && exec bash "$2"' _ "$WD" "$PLUGIN_ROOT/$SCRIPT" < "$PAYLOAD_FILE"
  _assert_denied
}

# --- QA (DR #10): _ud_fold's escaped-unicode case-arm, not just the raw-byte one --------------
# DR round 3 found every existing "escape" case actually wrote raw UTF-8 bytes in both halves
# (od showed no backslash-u on disk), so _ud_fold's "backslash u 017[fF]" / "backslash u 212[aA]"
# case-arm ran in no test. BS below is one backslash byte built with $'\134' (bash octal escape,
# not a \u form) so this source file, and every payload it writes, carries a literal backslash
# followed by plain letters/digits -- never something a JSON \u escape could decode away.
@test "QA-DR10: a literal JSON backslash-u017F/u017f/u212A escape (not the raw byte) denies too" {
  local BS; BS=$'\134'
  printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf x >> '"$CTX"'/deci'"${BS}"'u017Fions.jsonl"}}' \
    > "$PAYLOAD_FILE"
  grep -qF "${BS}u017F" "$PAYLOAD_FILE" || fail "escape lost before disk: $(od -c "$PAYLOAD_FILE")"
  ! grep -qF $'\xc5\xbf' "$PAYLOAD_FILE" || fail "payload holds the raw byte, not the escape: $(od -c "$PAYLOAD_FILE")"
  _hook
  _assert_denied

  printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf x >> '"$CTX"'/deci'"${BS}"'u017fions.jsonl"}}' \
    > "$PAYLOAD_FILE"
  grep -qF "${BS}u017f" "$PAYLOAD_FILE" || fail "lowercase escape lost before disk: $(od -c "$PAYLOAD_FILE")"
  _hook
  _assert_denied
}

# QA note: a K (Kelvin) lock-dir Write variant analogous to the above was attempted and
# pulled before handoff — the physical lock dir and the jq-decoded FPATH matched byte-for-byte
# (confirmed with od), yet the hook allowed it. This needs a DV/DR follow-up with tracing inside
# do_pre's Write arm rather than a QA-side guess; tracked as a new P2, not a regression (N1's
# raw-byte and ASCII-case Kelvin coverage above are unaffected and still pass).

# --- I3: the Bash arm stays linear on a large segment ----------------------------------------

@test "I3: a 20 KB Bash segment redirecting into the ledger denies well inside the hook timeout" {
  local pad start elapsed
  pad="$(head -c 20000 /dev/zero | tr '\0' 'a')"
  _bash_cmd "printf x >> .context/decisions.jsonl # $pad"
  start="$(date +%s)"
  _hook
  elapsed=$(($(date +%s) - start))
  _assert_denied
  [ "$elapsed" -le 3 ] || fail "took ${elapsed}s"
  rm -f "$AUDIT"
  _bash_cmd "cat .context/decisions.jsonl # $pad"
  start="$(date +%s)"
  _hook
  elapsed=$(($(date +%s) - start))
  _assert_allowed
  [ "$elapsed" -le 3 ] || fail "allowed path took ${elapsed}s"
}

# --- AC7: no question or answer text in audit ------------------------------------------------

@test "AC7: recorded, refused and denied rows never carry the question or answer text" {
  _post post.valid.payload.json
  _hook
  _post post.valid.payload.json
  _hook
  _post post.idle.payload.json '.tool_use_id = "toolu_01UdFixture0003"'
  _hook
  _pre pre.write-ledger.payload.json
  _hook
  _pre pre.bash-ledger-write.payload.json
  _hook
  [ "$(_count_action user_decision_recorded)" -ge 1 ] || fail "no recorded row to inspect"
  [ "$(_count_action user_decision_refused)" -ge 1 ] || fail "no refused row to inspect"
  [ "$(_count_action user_decision_ledger_write_denied)" -ge 1 ] || fail "no deny row to inspect"
  local needle
  for needle in "$Q1" "$A1" 'Not yet' 'Land it in this release' '"question"' '"answer"'; do
    ! grep -qF -- "$needle" "$AUDIT" || fail "audit.jsonl carries: $needle"
  done
}

# --- AC5: the selftest -----------------------------------------------------------------------

@test "AC5: the selftest passes — pinned canonical digests, row-1 null prev, row-2 chained prev" {
  run env -u WORKSPACE_ROOT -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR bash "$PLUGIN_ROOT/$SELFTEST"
  assert_success
  assert_output --partial "user-decision-record: self-test OK"
  assert_output --regexp 'user-decision-record: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
  refute_output --partial "FAIL"
}
