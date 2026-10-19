#!/usr/bin/env bats
# Tests for hooks/audit-subagent.sh (DV0c) — SubagentStop → audit.jsonl writer
# emitting a `subagent_stopped` row with dedupe_key "<session>:<agent>:stop".
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="hooks/audit-subagent.sh"
PAYLOAD="${FIXTURES}/hooks/audit-subagent.payload.json"

setup() {
  WD="$(mk_tmpworkdir)"
  # The root ladder answers only a context holding a ledger.
  mkdir -p "$WD/.context"
  printf '%s' '{"version":2,"tasks":{}}' > "$WD/.context/state.json"
}

@test "happy: writes subagent_stopped row with duration + dedupe keys" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < "$PAYLOAD"
  assert_success
  run jq -e '
    .action == "subagent_stopped"
    and .subject == "corpflow:developer"
    and .metadata.duration_ms == 12345
    and .metadata.parent_agent_id == "agt_parent"
    and (.metadata.dedupe_key == "sess_fix:agt_dv:stop")
  ' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "edge: non-numeric duration_ms coerces to 0; absent ids fall back" {
  # A first-seen key records whatever its fields say; the stage is supplied only
  # so the row also exercises the env half of the identity ladder.
  run env CLAUDE_PROJECT_DIR="$WD" CLAUDE_TASK_METADATA_STAGE=DV \
    bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"agent_type":"corpflow:y","duration_ms":"oops"}'
  assert_success
  run jq -e '
    .metadata.duration_ms == 0
    and (.metadata.dedupe_key == "nosession:noagent:stop")
    and .metadata.parent_agent_id == "none"
  ' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "effort: the payload tier is recorded" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < "$PAYLOAD"
  assert_success
  run jq -e '.metadata.effort == "high"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "effort: a payload without effort records unknown, never \$CLAUDE_EFFORT" {
  # A haiku subagent runs with no effort: its SubagentStop payload omits .effort while the
  # env var still holds the requested tier.
  run env CLAUDE_EFFORT=high CLAUDE_PROJECT_DIR="$WD" \
    bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"agent_type":"corpflow:technical-writer","agent_id":"a9","session_id":"s9"}'
  assert_success
  run jq -e '.metadata.effort == "unknown"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "happy: stage is stamped from CLAUDE_TASK_METADATA_STAGE" {
  run env CLAUDE_PROJECT_DIR="$WD" CLAUDE_TASK_METADATA_STAGE=DV \
    bash "$PLUGIN_ROOT/$SCRIPT" < "$PAYLOAD"
  assert_success
  run jq -e '.metadata.stage == "DV" and .metadata.agent_id == "agt_dv"' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "edge: empty agent_type falls back to CLAUDE_SUBAGENT_TYPE, qualifier intact" {
  # The runtime sends "" (not null) for plugin agents, so `// "unknown"` alone
  # left the row anonymous and the report could not name who ran.
  run env CLAUDE_PROJECT_DIR="$WD" CLAUDE_SUBAGENT_TYPE="apple-developer:ios-developer" \
    bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"agent_type":"","agent_id":"a1","session_id":"s1","duration_ms":7}'
  assert_success
  run jq -e '.subject == "apple-developer:ios-developer"' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "edge: empty agent_type with no env fallback yields unknown, not empty" {
  # BSD env stops option parsing at the first NAME=VALUE operand, so -u must precede
  # the assignment or it is taken as the command name (status 127 on macOS).
  run env -u CLAUDE_SUBAGENT_TYPE -u CLAUDE_TASK_METADATA_STAGE CLAUDE_PROJECT_DIR="$WD" \
    bash "$PLUGIN_ROOT/$SCRIPT" <<< '{"agent_type":"","agent_id":"a1","session_id":"s1","duration_ms":7}'
  assert_success
  run jq -e '.subject == "unknown" and .metadata.stage == "unknown"' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "failure: malformed JSON exits 0 and writes no row" {
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< '{broken'
  assert_success
  [ ! -s "$WD/.context/logs/audit.jsonl" ]
}

@test "contract: --self-test passes (counted summary)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "self-test OK"
  assert_output --regexp 'audit-subagent: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
}

# The last three direct audit.jsonl writers in the hook tree carried no symlink
# refusal; the appender in model-switch-lib.sh has always had one.
@test "SR: a symlinked audit.jsonl is refused, never written through" {
  mkdir -p "$WD/.context/logs" "$WD/target-dir"
  ln -s "$WD/target-dir/escaped.txt" "$WD/.context/logs/audit.jsonl"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" < "$PAYLOAD"
  assert_success
  [ ! -e "$WD/target-dir/escaped.txt" ]
}

# --- phantom-row suppression, and the count that keeps it honest -------------
# The runtime fires SubagentStop on a ~31s cadence for the whole life of a
# dispatch: one real agent produced 21 rows. Every row the runtime delivers,
# phantom or terminal, carries no stage and duration 0 — so the discriminator is
# a REPEATED dedupe_key, and a first-seen key always records whatever its fields
# say. Suppressing repeats is only safe if the suppression itself is recorded,
# because a predicate one shade too broad would hide real events undetectably.

stop() {
  # stop <json payload> — one SubagentStop firing with no identity in the
  # environment, so the stage ladder resolves to its terminal fallback.
  run env -u CLAUDE_SUBAGENT_TYPE -u CLAUDE_TASK_METADATA_STAGE \
    CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$1"
}

# ghost <session> <n> — n phantom firings of one agent whose first stop has
# already been recorded: every one is a repeat of a key the trail holds.
ghost() {
  local i
  for i in $(seq 1 "$2"); do
    stop "$(jq -cn --arg s "$1" '{agent_id:"ghost", session_id:$s, duration_ms:0}')"
    assert_success
  done
}

rows_of() { jq -r --arg a "$1" 'select(.action == $a) | .action' "$WD/.context/logs/audit.jsonl" 2>/dev/null | wc -l | tr -d ' '; }

@test "AC-3a: a repeated dedupe_key writes no second subagent_stopped row" {
  stop '{"agent_id":"ghost","session_id":"s1","duration_ms":0}'
  assert_success
  stop '{"agent_id":"ghost","session_id":"s1","duration_ms":0}'
  assert_success
  [ "$(rows_of subagent_stopped)" = "1" ]
}

@test "AC-3a: a FIRST-seen key with no stage and zero duration still records" {
  # The shape every real terminal stop arrives in. A predicate on those two
  # fields would suppress every genuine stop of every agent and empty the trail.
  stop '{"agent_type":"Explore","agent_id":"a1","session_id":"s1","duration_ms":0}'
  assert_success
  stop '{"agent_type":"corpflow:qa-engineer","agent_id":"a2","session_id":"s1","duration_ms":0}'
  assert_success
  [ "$(rows_of subagent_stopped)" = "2" ]
  [ "$(rows_of subagent_stops_suppressed)" = "0" ]
  run jq -se 'map(.metadata.stage == "unknown" and .metadata.duration_ms == 0) | all' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "AC-3a: the same agent_id in ANOTHER session is a different key and records" {
  stop '{"agent_id":"a1","session_id":"sA","duration_ms":0}'
  stop '{"agent_id":"a1","session_id":"sB","duration_ms":0}'
  assert_success
  [ "$(rows_of subagent_stopped)" = "2" ]
}

@test "AC-3a: the match is on the encoded key fragment, not a substring of another key" {
  # `s1:a1:stop` must not be read as already-seen because `xs1:a1:stop` is.
  stop '{"agent_id":"a1","session_id":"xs1","duration_ms":0}'
  stop '{"agent_id":"a1","session_id":"s1","duration_ms":0}'
  assert_success
  [ "$(rows_of subagent_stopped)" = "2" ]
}

@test "AC-3b: n suppressions then a flush emit exactly one summary row counting n" {
  # n is deliberately greater than one: a test asserting only that the row exists,
  # or using n of one, cannot tell a working counter from a broken one — which is
  # the failure mode this whole option was chosen to prevent.
  stop '{"agent_id":"ghost","session_id":"s1","duration_ms":0}'
  assert_success
  ghost s1 5
  [ "$(rows_of subagent_stopped)" = "1" ]
  [ "$(rows_of subagent_stops_suppressed)" = "0" ]

  # A first-seen stop for the same session is the flush trigger.
  stop '{"agent_id":"real","session_id":"s1","duration_ms":1200}'
  assert_success
  [ "$(rows_of subagent_stops_suppressed)" = "1" ]
  run jq -se 'map(select(.action == "subagent_stops_suppressed")) | last
    | .metadata.suppressed_count == 5
      and .subject == "s1"
      and .result == "ok"
      and (.metadata.window_start | length) > 0
      and (.metadata.window_end | length) > 0' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "AC-3b: ZERO suppressions emit no summary row" {
  # An informational row reporting nothing is noise in the trail it exists to
  # keep honest.
  stop '{"agent_id":"real","session_id":"s1","duration_ms":1200}'
  assert_success
  [ "$(rows_of subagent_stopped)" = "1" ]
  [ "$(rows_of subagent_stops_suppressed)" = "0" ]
}

@test "AC-3b: the flush resets the window — a second flush does not re-report it" {
  stop '{"agent_id":"ghost","session_id":"s1","duration_ms":0}'
  ghost s1 2
  stop '{"agent_id":"real","session_id":"s1","duration_ms":1200}'
  stop '{"agent_id":"real2","session_id":"s1","duration_ms":1200}'
  assert_success
  [ "$(rows_of subagent_stops_suppressed)" = "1" ]
  run jq -se 'map(select(.action == "subagent_stops_suppressed"))
    | last | .metadata.suppressed_count == 2' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "AC-3c: concurrent hooks racing on one session's window lose no suppression" {
  # Two hooks fire on the same SubagentStop and parallel worktask streams run
  # concurrently. A read-increment-write on a shared counter under-counts here,
  # silently — reproducing this finding's own defect class inside its fix. One
  # token appended per suppression cannot.
  stop '{"agent_id":"ghost","session_id":"s1","duration_ms":0}'
  assert_success
  local i pids=()
  for i in $(seq 1 20); do
    env -u CLAUDE_SUBAGENT_TYPE -u CLAUDE_TASK_METADATA_STAGE CLAUDE_PROJECT_DIR="$WD" \
      bash "$PLUGIN_ROOT/$SCRIPT" \
      <<< '{"agent_id":"ghost","session_id":"s1","duration_ms":0}' &
    pids+=($!)
  done
  for i in "${pids[@]}"; do wait "$i"; done

  stop '{"agent_id":"real","session_id":"s1","duration_ms":1200}'
  assert_success
  run jq -se 'map(select(.action == "subagent_stops_suppressed"))
    | last | .metadata.suppressed_count == 20' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "AC-3b: windows are per session — one session's flush leaves another's pending" {
  stop '{"agent_id":"ghost","session_id":"sA","duration_ms":0}'
  ghost sA 2
  stop '{"agent_id":"ghost","session_id":"sB","duration_ms":0}'
  ghost sB 1
  stop '{"agent_id":"real","session_id":"sA","duration_ms":1200}'
  assert_success
  run jq -se 'map(select(.action == "subagent_stops_suppressed"))
    | length == 1 and (last | .subject == "sA" and .metadata.suppressed_count == 2)' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
  [ -f "$WD/.context/logs/.subagent-suppressed.sB" ]
}

@test "REQ-4c: the summary row goes through the SHARED appender, not a third append site" {
  # A hand-rolled third append site is what the requirement refuses: the appender
  # holds the closed actor/result sets and the symlink refusal, and a duplicate
  # would drift from both. The hook's own `>> audit.jsonl` for subagent_stopped
  # is the only remaining direct write in the file.
  grep -q 'corpflow_hook_audit_row' "$PLUGIN_ROOT/$SCRIPT"
  [ "$(grep -c '>> "\$LOG_DIR/audit.jsonl"' "$PLUGIN_ROOT/$SCRIPT")" = "1" ]

  stop '{"agent_id":"ghost","session_id":"s1","duration_ms":0}'
  ghost s1 1
  stop '{"agent_id":"real","session_id":"s1","duration_ms":1200}'
  run jq -se 'map(select(.action == "subagent_stops_suppressed")) | last
    | .actor == "hook:audit-subagent" and (has("subject"))
      and (.metadata | has("suppressed_count"))' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "REQ-22: a missing library degrades the summary, never the hook's exit code" {
  # The guarded-source idiom exists for exactly this: the hook runs under set -eu,
  # where a truncated library is fatal and `||` cannot rescue it. Suppression must
  # still suppress; only the summary is deferred.
  local fake="$WD/hooks"
  mkdir -p "$fake"
  cp "$PLUGIN_ROOT/$SCRIPT" "$fake/"
  local i
  for i in 1 2; do
    run env -u CLAUDE_SUBAGENT_TYPE -u CLAUDE_TASK_METADATA_STAGE CLAUDE_PROJECT_DIR="$WD" \
      bash "$fake/audit-subagent.sh" <<< '{"agent_id":"ghost","session_id":"s1","duration_ms":0}'
    assert_success
  done
  run env -u CLAUDE_SUBAGENT_TYPE -u CLAUDE_TASK_METADATA_STAGE CLAUDE_PROJECT_DIR="$WD" \
    bash "$fake/audit-subagent.sh" <<< '{"agent_id":"real","session_id":"s1","duration_ms":1200}'
  assert_success
  [ "$(rows_of subagent_stopped)" = "2" ]
  [ "$(rows_of subagent_stops_suppressed)" = "0" ]
  [ "$(wc -l < "$WD/.context/logs/.subagent-suppressed.s1" | tr -d ' ')" = "1" ]
}

# --- SR-1 / SR-2: the window file is store-shaped, so it is guarded like one ---

@test "SR-1: a symlinked window file is refused on APPEND, never followed" {
  # The same reasoning as the audit.jsonl guard twenty lines away: following the
  # link turns the append into a write primitive against an arbitrary target.
  mkdir -p "$WD/.context/logs" "$WD/target-dir"
  printf 'untouched\n' > "$WD/target-dir/victim.txt"
  ln -s "$WD/target-dir/victim.txt" "$WD/.context/logs/.subagent-suppressed.s1"

  stop '{"agent_id":"ghost","session_id":"s1","duration_ms":0}'
  ghost s1 1
  [ "$(cat "$WD/target-dir/victim.txt")" = "untouched" ]
}

@test "SR-1: a symlinked window file is refused on FLUSH — no target content reaches the trail" {
  # The flush is the second leg and the larger one: mv moves the LINK, then wc,
  # head and tail all follow it, and field two of the target's first and last
  # lines would be written into audit.jsonl as the window bounds. That is an
  # arbitrary-file read exfiltrated into the audit trail.
  mkdir -p "$WD/.context/logs" "$WD/target-dir"
  printf '1 SECRET-FIRST\n2 SECRET-LAST\n' > "$WD/target-dir/secret.txt"
  ln -s "$WD/target-dir/secret.txt" "$WD/.context/logs/.subagent-suppressed.s1"

  stop '{"agent_id":"real","session_id":"s1","duration_ms":1200}'
  assert_success
  [ "$(rows_of subagent_stops_suppressed)" = "0" ]
  run grep -c 'SECRET' "$WD/.context/logs/audit.jsonl"
  assert_failure
  # The link and its target both survive: refusing is not deleting.
  [ -L "$WD/.context/logs/.subagent-suppressed.s1" ]
  [ -s "$WD/target-dir/secret.txt" ]
}

@test "SR-2: a window that cannot be reported is NOT claimed — the count survives to the next flush" {
  # The inversion SR found: the flush claimed and destroyed the records, and only
  # then discovered it could not write the row. Suppression runs at full strength
  # on that path, so the trail was narrowed with no trace of the narrowing — the
  # one property this hook's header promises to preserve.
  local fake="$WD/hooks"
  mkdir -p "$fake"
  cp "$PLUGIN_ROOT/$SCRIPT" "$fake/"
  local i
  # The first firing records; the four that follow are repeats of its key.
  for i in 0 1 2 3 4; do
    run env -u CLAUDE_SUBAGENT_TYPE -u CLAUDE_TASK_METADATA_STAGE CLAUDE_PROJECT_DIR="$WD" \
      bash "$fake/audit-subagent.sh" <<< '{"agent_id":"ghost","session_id":"s1","duration_ms":0}'
    assert_success
  done
  # A genuine stop under the degraded library: the row it cannot write is not a
  # reason to delete the four records it holds.
  run env -u CLAUDE_SUBAGENT_TYPE -u CLAUDE_TASK_METADATA_STAGE CLAUDE_PROJECT_DIR="$WD" \
    bash "$fake/audit-subagent.sh" <<< '{"agent_id":"real","session_id":"s1","duration_ms":1200}'
  assert_success
  [ "$(rows_of subagent_stops_suppressed)" = "0" ]
  [ "$(wc -l < "$WD/.context/logs/.subagent-suppressed.s1" | tr -d ' ')" = "4" ]

  # The library is present again on the next invocation, and the whole window
  # reports: deferred, not lost.
  stop '{"agent_id":"real2","session_id":"s1","duration_ms":1200}'
  assert_success
  run jq -se 'map(select(.action == "subagent_stops_suppressed")) | last
    | .metadata.suppressed_count == 4 and .metadata.truncated == false' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "SR-2: a symlinked audit.jsonl also defers the window instead of destroying it" {
  # The appender returns 0 on every refusal and cannot report a dropped row, so
  # its reachable refusals are anticipated before the claim rather than detected
  # after it. This is the second of the two, and the one no library probe sees.
  mkdir -p "$WD/.context/logs" "$WD/target-dir"
  stop '{"agent_id":"ghost","session_id":"s1","duration_ms":0}'
  ghost s1 2
  # The swap happens after the seen-set was consulted; the trail is now a link.
  mv "$WD/.context/logs/audit.jsonl" "$WD/.context/logs/audit.real"
  ln -s "$WD/target-dir/escaped.txt" "$WD/.context/logs/audit.jsonl"

  stop '{"agent_id":"real","session_id":"s1","duration_ms":1200}'
  assert_success
  [ ! -e "$WD/target-dir/escaped.txt" ]
  [ "$(wc -l < "$WD/.context/logs/.subagent-suppressed.s1" | tr -d ' ')" = "2" ]
}

@test "SR-2: the window is capped, and a capped summary reports a floor and says so" {
  # sw-SR0-3 option A's cost: a window that cannot be reported now survives, so it
  # needs a bound. Past the cap the append is skipped and the summary marks
  # itself truncated — bounded growth that describes itself, rather than a count
  # invented from a second counter this design refuses to keep.
  mkdir -p "$WD/.context/logs"
  local pending="$WD/.context/logs/.subagent-suppressed.s1" i now
  # A CURRENT epoch, or the window expires on the first suppression and flushes
  # before the cap is ever exercised.
  now="$(date -u +%s)"
  # Seeded AFTER the key's first stop, or that stop would flush the window itself.
  stop '{"agent_id":"over","session_id":"s1","duration_ms":0}'
  assert_success
  for i in $(seq 1 1000); do printf '%s 2026-09-08T00:00:00Z\n' "$now"; done > "$pending"

  stop '{"agent_id":"over","session_id":"s1","duration_ms":0}'
  assert_success
  [ "$(wc -l < "$pending" | tr -d ' ')" = "1000" ]

  stop '{"agent_id":"real","session_id":"s1","duration_ms":1200}'
  assert_success
  run jq -se 'map(select(.action == "subagent_stops_suppressed")) | last
    | .metadata.suppressed_count == 1000 and .metadata.truncated == true' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "AC-2: a stray bare .context in a clean checkout is not a ledger — no logs, no row" {
  local repo
  repo="$(mk_git_fixture --file 'a.txt:hi' --commit 'init')"
  mkdir -p "$repo/.context"
  run_script_env --cwd "$repo" --env "WORKSPACE_ROOT=$repo" --env "CLAUDE_PROJECT_DIR=$repo" \
    --unset CONTEXT_DIR --stdin-file "$PAYLOAD" "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ -z "$(ls -A "$repo/.context")" ] || fail "the hook wrote into a bare context: $(ls -A "$repo/.context")"
}

@test "unresolved root exits 0 and creates no .context under cwd" {
  local cwd
  cwd="$(mk_tmpworkdir)"
  run_script_env --cwd "$cwd" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR --unset CONTEXT_DIR \
    --env "GIT_CEILING_DIRECTORIES=$cwd" --stdin-file "$PAYLOAD" "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ ! -e "$cwd/.context" ]
}

# --- stage ladder: payload, env, ledger dispatch row by agent_id, brief stage line ---

# _stage_ledger <rows-json> — a ledger whose facts.dispatched_agents holds <rows-json>.
_stage_ledger() {
  jq -cn --argjson rows "$1" '{version:2, tasks:{}, facts:{dispatched_agents:$rows}}' \
    > "$WD/.context/state.json"
}

# _stage_transcript <path> <stage-line> — a transcript whose first user record is a composed
# brief. A decoy `stage:` line before the task block proves the read is scoped to that block.
_stage_transcript() {
  local brief
  brief=$(printf '%s\n' '<<<contract-reminder>>>' 'stage: DR' '<<<task-description>>>' \
    'task_id: QA0' "$2" 'agent: corpflow:qa-engineer' '<<<retry-hints>>>' 'stage: FN')
  jq -cn '{type:"system",content:"init"}' > "$1"
  jq -cn --arg c "$brief" '{type:"user",message:{content:$c}}' >> "$1"
}

# _stage_run <payload-json> [env NAME=VALUE...] — runs the hook, echoes metadata.stage.
_stage_run() {
  local p="$1"
  shift
  rm -f "$WD/.context/logs/audit.jsonl"
  env -u CLAUDE_TASK_METADATA_STAGE CLAUDE_PROJECT_DIR="$WD" "$@" \
    bash "$PLUGIN_ROOT/$SCRIPT" <<< "$p" || return 1
  jq -r 'select(.action == "subagent_stopped") | .metadata.stage' "$WD/.context/logs/audit.jsonl"
}

@test "stage: the ledger dispatch row whose agent_id matches the payload names the stage, in any status" {
  local st
  for st in launched completed; do
    _stage_ledger "[{\"stage\":\"DV\",\"agent_id\":\"a_other\",\"status\":\"launched\"},
      {\"stage\":\"QA\",\"task_id\":\"QA0\",\"agent_id\":\"a_qa\",\"status\":\"$st\"}]"
    run _stage_run '{"agent_type":"","agent_id":"a_qa","session_id":"s1"}'
    assert_success
    assert_output "QA"
  done
}

@test "stage: with no matching row, the task-description stage line of the agent's brief names the stage" {
  _stage_ledger '[{"stage":"DV","agent_id":"a_other","status":"launched"}]'
  _stage_transcript "$WD/agent.jsonl" 'stage: QA'
  run _stage_run "$(jq -cn --arg t "$WD/agent.jsonl" '{agent_id:"a_qa",session_id:"s1",agent_transcript_path:$t}')"
  assert_success
  assert_output "QA"
  # transcript_path is the PARENT's transcript on SubagentStop, so it is never read.
  run _stage_run "$(jq -cn --arg t "$WD/agent.jsonl" '{agent_id:"a_qa",session_id:"s2",transcript_path:$t}')"
  assert_success
  assert_output "unknown"
  # A stage line that is not a stage code is no answer.
  _stage_transcript "$WD/bad.jsonl" 'stage: QA0'
  run _stage_run "$(jq -cn --arg t "$WD/bad.jsonl" '{agent_id:"a_qa",session_id:"s3",agent_transcript_path:$t}')"
  assert_success
  assert_output "unknown"
}

@test "stage: payload .stage and the env outrank both new rungs; nothing resolving gives unknown" {
  _stage_ledger '[{"stage":"QA","agent_id":"a_qa","status":"launched"}]'
  _stage_transcript "$WD/agent.jsonl" 'stage: AR'
  run _stage_run "$(jq -cn --arg t "$WD/agent.jsonl" '{stage:"DR",agent_id:"a_qa",session_id:"s1",agent_transcript_path:$t}')"
  assert_output "DR"
  run _stage_run "$(jq -cn --arg t "$WD/agent.jsonl" '{agent_id:"a_qa",session_id:"s2",agent_transcript_path:$t}')" \
    CLAUDE_TASK_METADATA_STAGE=DV
  assert_output "DV"
  run _stage_run '{"agent_id":"a_none","session_id":"s3"}'
  assert_success
  assert_output "unknown"
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "audit-subagent: self-test OK"
  assert_output --regexp 'audit-subagent: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
}

@test "stage: an agent_id on rows of two stages is ambiguous and falls to the brief, then to unknown" {
  _stage_ledger '[{"stage":"QA","agent_id":"a_x","status":"completed"},
    {"stage":"DR","agent_id":"a_x","status":"launched"}]'
  _stage_transcript "$WD/agent.jsonl" 'stage: AR'
  run _stage_run "$(jq -cn --arg t "$WD/agent.jsonl" '{agent_id:"a_x",session_id:"s1",agent_transcript_path:$t}')"
  assert_output "AR"
  run _stage_run '{"agent_id":"a_x","session_id":"s2"}'
  assert_output "unknown"
}
