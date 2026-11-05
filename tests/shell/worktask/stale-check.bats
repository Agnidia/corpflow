#!/usr/bin/env bats
# stale-check.sh — read-only staleness detection over a worktask ledger.
#
# The load-bearing assertions are the negative ones: a healthy long-running stage
# and every liveness ambiguity must NOT read "stale". A false stale verdict invites
# an operator to kill live work, which is strictly worse than missing a wedged one.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/worktask/scripts/stale-check.sh"

# mk_ledger <dir> [extra jq filters...] — v2 ledger with tasks{} + dispatched_agents[].
mk_ledger() {
  local dir="$1"; shift
  mkdir -p "$dir/.context/logs"
  printf '%s\n' '{"version":2,"worktask_id":"wt-stale","plan_file":".context/planning-0.md","platform":"all","run_index":0,"tasks":{},"facts":{"decisions":[],"open_questions":[],"dispatched_agents":[],"handoffs":{}},"handoffs":{},"metadata":{}}' \
    > "$dir/.context/state.json"
  local f tmp="$dir/.context/state.json.tmp"
  for f in "$@"; do
    jq "$f" "$dir/.context/state.json" > "$tmp" || fail "mk_ledger: jq filter failed: $f"
    mv -f "$tmp" "$dir/.context/state.json"
  done
}

# in_progress <ID> <STAGE> — jq filter seeding one in_progress task.
in_progress() {
  printf '.tasks["%s"] = {"status":"in_progress","metadata":{"stage":"%s","agent":"corpflow:developer"}}' "$1" "$2"
}

# dispatch <ID> <STAGE> <AGENT_ID> [STATUS] — jq filter appending a dispatch row.
dispatch() {
  printf '.facts.dispatched_agents += [{"stage":"%s","task_id":"%s","subagent_type":"corpflow:developer","agent_id":"%s","status":"%s"}]' \
    "$2" "$1" "$3" "${4:-launched}"
}

agents_file() {
  local out="$1"; shift
  printf '%s\n' "$1" > "$out"
  printf '%s\n' "$out"
}

# --- the four resume.md live-agent classifications ---------------------------

@test "alive-busy: a live mid-work agent is never reported stale (exit 0)" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  agents_file "$w/agents.json" '[{"id":"sess-dv0","kind":"background","state":"active"}]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_success
  assert_output --partial "[alive-busy]"
  assert_output --partial "Agent busy. Leave it; poll/await. Do not double-dispatch or nudge"
  assert_output --partial "verdict: clear"
  refute_output --partial "gone"
}

@test "alive-parked: waitingFor=approval maps to the SendMessage reattach verdict" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress QA0 QA)" "$(dispatch QA0 QA sess-qa0)"
  agents_file "$w/agents.json" '[{"id":"sess-qa0","state":"active","waitingFor":"approval"}]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 1
  assert_output --partial "[alive-parked]"
  assert_output --partial "SendMessage reattach with awaited answer"
  assert_output --partial "never auto-answer or re-dispatch"
  refute_output --partial "Re-delegate from the first incomplete stage"
}

@test "alive-parked: a 'Needs input' status is operator-owned, not stale" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  agents_file "$w/agents.json" '[{"id":"sess-dv0","kind":"interactive","status":"Needs input"}]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 1
  assert_output --partial "[alive-parked]"
}

@test "hook-config-broken: a hook schema error is operator-owned, not a SendMessage nudge" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  agents_file "$w/agents.json" \
    '[{"id":"sess-dv0","state":"blocked","hookError":"PreToolUse hook returned invalid JSON"}]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 1
  assert_output --partial "[hook-config-broken]"
  assert_output --partial "fix the hook"
  # The remedy must NOT be the ordinary parked one: a nudge is rejected again.
  refute_output --partial "[alive-parked]"
}

@test "reattach-undeliverable: a refused send outranks the parked verdict" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  agents_file "$w/agents.json" '[{"id":"sess-dv0","state":"blocked"}]'
  printf '%s\n' \
    '{"actor":"orchestrator","action":"reattach_send_result","subject":"DV0","task_id":"DV0","result":"blocked","metadata":{"reason":"refused"}}' \
    > "$w/.context/logs/audit.jsonl"

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 1
  assert_output --partial "[reattach-undeliverable]"
  assert_output --partial "still parked, not nudged"
}

@test "reattach-undeliverable: a later successful send clears the override" {
  # ANTI-VACUITY: without last-wins semantics every stage that ever had a failed
  # send would stay flagged forever, and the class would be noise.
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  agents_file "$w/agents.json" '[{"id":"sess-dv0","state":"blocked"}]'
  {
    printf '%s\n' '{"action":"reattach_send_result","task_id":"DV0","result":"blocked"}'
    printf '%s\n' '{"action":"reattach_send_result","task_id":"DV0","result":"ok"}'
  } > "$w/.context/logs/audit.jsonl"

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 1
  assert_output --partial "[alive-parked]"
  refute_output --partial "[reattach-undeliverable]"
}

@test "reattach-undeliverable: a settled dispatch keeps its reconcile remedy" {
  # The override applies only where a nudge is the remedy. A dispatch record that is
  # already terminal never sends again, so a stale failed row must not hide
  # dispatch-settled behind delivery advice that can no longer apply.
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0 completed)"
  agents_file "$w/agents.json" '[{"id":"sess-dv0","state":"blocked"}]'
  printf '%s\n' '{"action":"reattach_send_result","task_id":"DV0","result":"blocked"}' \
    > "$w/.context/logs/audit.jsonl"

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 1
  assert_output --partial "[dispatch-settled]"
  refute_output --partial "[reattach-undeliverable]"
}

@test "gone: an absent agent_id yields re-delegate (single stage stays 'gone')" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  agents_file "$w/agents.json" '[{"id":"sess-other","state":"active"}]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 1
  assert_output --partial "[gone]"
  assert_output --partial "Re-delegate from the first incomplete stage"
}

@test "gone: state=done counts as absent even though the row is listed" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  agents_file "$w/agents.json" '[{"id":"sess-dv0","state":"done"}]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 1
  assert_output --partial "[gone]"
}

@test "budget-halt: several agents gone at once with no failure row, retry_count preserved" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(in_progress QA0 QA)" \
    "$(dispatch DV0 DV sess-dv0)" "$(dispatch QA0 QA sess-qa0)"
  agents_file "$w/agents.json" '[]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 1
  assert_output --partial "[budget-halt]"
  assert_output --partial "do NOT increment metadata.retry_count"
  refute_output --partial "[gone]"
}

@test "budget-halt: an audit failure row keeps the simultaneous loss classified 'gone'" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(in_progress QA0 QA)" \
    "$(dispatch DV0 DV sess-dv0)" "$(dispatch QA0 QA sess-qa0)"
  agents_file "$w/agents.json" '[]'
  printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","actor":"orchestrator","action":"subagent_stopped","subject":"DV0","result":"error"}' \
    > "$w/.context/logs/audit.jsonl"

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 1
  assert_output --partial "[gone]"
  refute_output --partial "[budget-halt]"
}

# --- liveness degradation: never "stale" -------------------------------------

@test "liveness-unknown: the claude CLI missing from PATH degrades, never accuses" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"

  run_script_env --cwd "$w" --hide claude "$SCRIPT"
  assert_failure 3
  assert_output --partial "[liveness-unknown]"
  assert_output --partial "NOT a staleness verdict"
  refute_output --partial "[gone]"
}

@test "liveness-unknown: a non-zero CLI exit degrades" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  stub_cmd claude --exit 1 --stderr 'boom'

  run_script_env --cwd "$w" --stub-path "$SCRIPT"
  assert_failure 3
  assert_output --partial "[liveness-unknown]"
}

@test "liveness-unknown: unparseable CLI output degrades" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  stub_cmd claude --stdout 'not json at all'

  run_script_env --cwd "$w" --stub-path "$SCRIPT"
  assert_failure 3
  assert_output --partial "[liveness-unknown]"
}

@test "liveness-unknown: rows with no recognised liveness field are an unknown shape" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  agents_file "$w/agents.json" '[{"id":"sess-dv0","phase":"whatever"}]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json" --json
  assert_failure 3
  run jq -r '.liveness' <<< "$output"
  assert_output "unrecognized-shape"
}

@test "liveness-unknown: an unfamiliar state token on a matched row degrades" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  agents_file "$w/agents.json" '[{"id":"sess-dv0","state":"hibernating"}]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 3
  assert_output --partial "[liveness-unknown]"
}

# --- identity matching -------------------------------------------------------

@test "matching: an abbreviated id prefix still resolves to its live session" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" \
    "$(dispatch DV0 DV edb1778e-57aa-4b09-9ca7-c5364c45ded3)"
  agents_file "$w/agents.json" '[{"id":"edb1778e","sessionId":"edb1778e-57aa-4b09-9ca7-c5364c45ded3","state":"active"}]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_success
  assert_output --partial "[alive-busy]"
}

@test "matching: a named-spawn handle resolves when the ledger recorded no agent_id" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" \
    '.facts.dispatched_agents += [{"stage":"DV","task_id":"DV0","subagent_type":"corpflow:developer","name":"lane-42","status":"launched"}]'
  agents_file "$w/agents.json" '[{"id":"zzz","name":"lane-42","state":"active"}]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_success
  assert_output --partial "[alive-busy]"
}

@test "matching: a name two live rows share is ambiguous, never absent" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" \
    '.facts.dispatched_agents += [{"stage":"DV","task_id":"DV0","subagent_type":"corpflow:developer","name":"lane-42","status":"launched"}]'
  agents_file "$w/agents.json" '[{"id":"aaa","name":"lane-42","state":"active"},{"id":"bbb","name":"lane-42","state":"done"}]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 3
  assert_output --partial "[liveness-unknown]"
}

# --- ledger shapes -----------------------------------------------------------

@test "no ledger at all exits 0 with a clear message, not an error" {
  local w; w="$(mk_tmpworkdir)"
  run_script_env --cwd "$w" "$SCRIPT"
  assert_success
  assert_output --partial "no worktask in flight"
}

@test "a ledger with no in_progress stage is clear" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" '.tasks.PL0 = {"status":"completed","metadata":{"stage":"PL"}}'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json /dev/null
  assert_success
  assert_output --partial "no stage is in_progress"
}

@test "no-dispatch-record: in_progress with no dispatch row cites the stale-task row" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress PL0 PL)"
  agents_file "$w/agents.json" '[]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 1
  assert_output --partial "[no-dispatch-record]"
  assert_output --partial "Near-done & stale rows"
}

@test "dispatch-settled: a terminal dispatch row under an in_progress task is ledger drift" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0 completed)"
  agents_file "$w/agents.json" '[]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_failure 1
  assert_output --partial "[dispatch-settled]"
  assert_output --partial "Do not reattach"
}

@test "--state points the check at a ledger outside the cwd" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  agents_file "$w/agents.json" '[{"id":"sess-dv0","state":"active"}]'

  run_script_env "$SCRIPT" --state "$w/.context/state.json" --agents-json "$w/agents.json"
  assert_success
  assert_output --partial "[alive-busy]"
}

@test "a corrupt ledger is a usage error, not a staleness verdict" {
  local w; w="$(mk_tmpworkdir)"
  mkdir -p "$w/.context"
  printf '%s\n' '{not json' > "$w/.context/state.json"

  run_script_env --cwd "$w" "$SCRIPT" --agents-json /dev/null
  assert_failure 2
  refute_output --partial "gone"
}

@test "an unknown flag exits 2" {
  run_script_env "$SCRIPT" --nope
  assert_failure 2
}

@test "a value-taking flag with nothing after it is a usage error, not a finding" {
  # Exit 1 means "a stage needs a human decision"; a truncated command line must never
  # be reported in that vocabulary.
  local flag
  for flag in --state --context --agents-json; do
    run_script_env "$SCRIPT" "$flag"
    assert_failure 2
    assert_output --partial "$flag needs a value"
  done
}

@test "a value-taking flag followed by another flag is still a usage error" {
  run_script_env "$SCRIPT" --state --json
  assert_failure 2
  assert_output --partial "--state needs a value"
}

# --- the read-only contract --------------------------------------------------

@test "READ-ONLY: the ledger and .context/ are byte-identical after every arm" {
  local w before after
  w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(in_progress QA0 QA)" \
    "$(dispatch DV0 DV sess-dv0)" "$(dispatch QA0 QA sess-qa0)"
  printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","actor":"orchestrator","action":"resume","result":"ok"}' \
    > "$w/.context/logs/audit.jsonl"
  agents_file "$w/agents.json" '[{"id":"sess-dv0","state":"active"}]'

  before="$(find "$w/.context" -type f -exec shasum {} \; | sort)"

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json" --json
  run_script_env --cwd "$w" --hide claude "$SCRIPT"

  after="$(find "$w/.context" -type f -exec shasum {} \; | sort)"
  [ "$before" = "$after" ] || fail "stale-check mutated .context/:
$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)"
}

# --- taxonomy anchoring ------------------------------------------------------

@test "every verdict cites a resume.md section that actually exists" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  agents_file "$w/agents.json" '[]'

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json" --json
  assert_failure 1

  local sources src heading
  sources="$(jq -r '.findings[].source' <<< "$output" | sort -u)"
  [ -n "$sources" ]
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    heading="${src#* § }"
    grep -Fq "$heading" "$(contract_source "$PLUGIN_ROOT/skills/worktask/references/resume.md")" \
      || fail "cited section not found in resume.md: $heading"
  done <<< "$sources"
}

# The verdict strings name the recovery actions an operator should take, so they
# contain the same vocabulary a write would — "Reattach via SendMessage", "Re-delegate".
# Scanning for bare words therefore fails on the advice, not on a write. The guard
# matches invocation syntax instead. `SendMessage` is gone from the pattern entirely:
# it is an agent-side tool a bash/python script cannot call, so the word could only
# ever have matched prose.
@test "the script never writes: no execution, redirection, or write API in its body" {
  run grep -nE '(bash|sh|source|exec) +[^ ]*state-patch\.sh|(^|[;&|] *)gh +(pr|issue)|> *"?\$(STATE|OUT)|open\([^)]*["'"'"'][wa]|\.write_text|subprocess|os\.system' \
    "$PLUGIN_ROOT/$SCRIPT"
  assert_failure
}

@test "the write guard catches a real call, not just prose" {
  local probe="$BATS_TEST_TMPDIR/probe.sh"
  printf '%s\n' 'echo "Reattach via SendMessage with the awaited answer"' > "$probe"
  run grep -nE '(bash|sh|source|exec) +[^ ]*state-patch\.sh|(^|[;&|] *)gh +(pr|issue)|> *"?\$(STATE|OUT)|open\([^)]*["'"'"'][wa]|\.write_text|subprocess|os\.system' "$probe"
  assert_failure   # advice prose is not a write

  printf '%s\n' 'bash "$DIR/state-patch.sh" --set x=1' >> "$probe"
  run grep -nE '(bash|sh|source|exec) +[^ ]*state-patch\.sh|(^|[;&|] *)gh +(pr|issue)|> *"?\$(STATE|OUT)|open\([^)]*["'"'"'][wa]|\.write_text|subprocess|os\.system' "$probe"
  assert_success   # a real invocation still trips it
}

# --- tolerant audit read (R-1.1b) --------------------------------------------

@test "a malformed audit row is skipped, counted on stderr, and never blinds the scan" {
  local w; w="$(mk_tmpworkdir)"
  mk_ledger "$w" "$(in_progress DV0 DV)" "$(dispatch DV0 DV sess-dv0)"
  agents_file "$w/agents.json" '[{"id":"sess-dv0","kind":"background","state":"active"}]'
  {
    printf '{ not json at all\n'
    printf '{"ts":"2026-09-03T00:00:00Z","actor":"hook","action":"tool_invoked","result":"ok"}\n'
  } > "$w/.context/logs/audit.jsonl"

  run_script_env --cwd "$w" "$SCRIPT" --agents-json "$w/agents.json"
  assert_success
  assert_output --partial "1 unparseable audit row"
  assert_output --partial "[alive-busy]"
}
