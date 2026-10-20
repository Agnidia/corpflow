#!/usr/bin/env bats
# Contract tests for skills/worktask/scripts/state-patch.sh (AC-4 priority).
# Contracts asserted (from the script header + body):
#   - atomic completion merge into .context/state.json (tasks.<ID>.status=completed)
#   - idempotent re-run leaves state.json byte-identical
#   - disk-guard hard-halt exits 2 below DISK_MIN_GB
#   - absent artifact / absent state.json => no-op exit 0
#   - --self-test => "ALL PASS" exit 0
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/worktask/scripts/state-patch.sh"

# Key gate: every non-PL/IR --task-create row needs the five dispatch-shape
# keys, so fixtures merge them in rather than restating them at every call site.
# "null" (not literal {}) as the bash default dodges a bash-3.2 brace-matching
# quirk where "${1:-{}}" leaks a stray "}" onto a non-empty $1.
_r9_meta() {
  jq -cn --argjson x "${1:-null}" \
    '{effort:"high",isolation:"worktree",base_ref:"origin/develop",requires_screenshots:false,workspace_path:"/tmp/wt"} + ($x // {})'
}

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context/logs"
  cp "$FIXTURES/worktask/state.sample.json" "$WD/.context/state.json"
  cp "$FIXTURES/worktask/development-0.sample.md" "$WD/.context/development-0.md"
  # BATS_TMPDIR is a plain scratch dir, not a git repo: without a declared root the
  # ladder's rank 5/6 both miss and every case silently no-ops.
  export WORKSPACE_ROOT="$WD"
}

# --- C3: a non-canonical artifact name is silently un-linted ----------------------------

@test "artifact: a non-canonical --artifact name warns and still ledgers (F-16)" {
  # hooks/anchor-preflight.sh gates its lint on the canonical name and fails OPEN on
  # anything else, so an artifact one character off canonical is written, ledgered,
  # harness-passed and never anchor-linted. That hid two missing required anchors in one
  # run. Failing open is right; failing open silently is the defect.
  cd "$WD"
  cp .context/development-0.md .context/dev-notes.md
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/dev-notes.md
  assert_success
  [[ "$output" == *"is not the canonical name for stage DV"* ]] || fail "$output"
  [[ "$output" == *"development-<N>.md"* ]] || fail "canonical form unnamed: $output"
  # A warning, never a refusal: the row still lands.
  run jq -r '.tasks.DV0.status' .context/state.json
  assert_output "completed"
}

@test "artifact: the canonical name is silent" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md
  assert_success
  [[ "$output" != *"is not the canonical name"* ]] || fail "false positive: $output"
}

@test "artifact: a DV per-stream name is canonical, a malformed slug still warns" {
  cd "$WD"
  cp .context/development-0.md .context/development-0-service.md
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0-service.md
  assert_success
  [[ "$output" != *"is not the canonical name"* ]] || fail "false positive on a stream name: $output"
  cp .context/development-0.md .context/development-0-Service.md
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0-Service.md
  [[ "$output" == *"is not the canonical name for stage DV"* ]] || fail "malformed slug not flagged: $output"
}

# --- B1/B2: the decisions ring's recovery path and its casualty reporting ---------------

_write_n_decisions() {  # <count> [id-prefix]
  local n="$1" pre="${2:-ar}" i
  for ((i = 1; i <= n; i++)); do
    bash "$PLUGIN_ROOT/$SCRIPT" --state .context/state.json \
      --facts "{\"decisions\":[{\"id\":\"${pre}${i}\",\"summary\":\"d${i}\",\"stage\":\"AR0\"}]}" \
      > /dev/null 2>&1 || true
  done
}

@test "decisions: 12 written for one task all resolve through --read-decisions (F-04)" {
  # The ring keeps 8 per task and spills the rest. Before --read-decisions the spill had no
  # reader, so this run lost four architecture decisions — three of them the cross-client
  # parity controls — with nothing anywhere reporting it.
  cd "$WD"
  _write_n_decisions 12

  run jq '.facts.decisions | length' .context/state.json
  assert_success
  [ "$output" = "8" ] || fail "expected the clamp to keep 8, got $output"

  run bash "$PLUGIN_ROOT/$SCRIPT" --state .context/state.json --read-decisions
  assert_success
  local n
  n="$(printf '%s' "$output" | jq 'length')"
  [ "$n" = "12" ] || fail "expected all 12 to resolve, got $n"
  printf '%s' "$output" | jq -e 'map(.id) | index("ar1") and index("ar12")' > /dev/null \
    || fail "the union lost an end of the range: $output"
}

@test "decisions: the ledger wins on conflict with a staler spill line" {
  cd "$WD"
  _write_n_decisions 9
  # ar1 is evicted by now; re-writing it restores it to the ledger with new text while the
  # spill still holds the old snapshot.
  bash "$PLUGIN_ROOT/$SCRIPT" --state .context/state.json \
    --facts '{"decisions":[{"id":"ar1","summary":"RESTORED","stage":"AR0"}]}' > /dev/null 2>&1

  run bash "$PLUGIN_ROOT/$SCRIPT" --state .context/state.json --read-decisions
  assert_success
  local got
  got="$(printf '%s' "$output" | jq -r 'map(select(.id == "ar1")) | .[0].summary')"
  [ "$got" = "RESTORED" ] || fail "spill won over the ledger: $got"
  local dupes
  dupes="$(printf '%s' "$output" | jq '[.[].id] | length - (unique | length)')"
  [ "$dupes" = "0" ] || fail "union produced duplicate ids"
}

@test "decisions: an unparseable spill is a failure, never an empty set" {
  cd "$WD"
  _write_n_decisions 9
  printf 'not json at all\n' > .context/decisions-0.jsonl
  run bash "$PLUGIN_ROOT/$SCRIPT" --state .context/state.json --read-decisions
  assert_failure
  [[ "$output" == *"not readable as JSON lines"* ]] || fail "$output"
}

@test "facts: a rejected item id reaches audit.jsonl, not only stderr (F-15)" {
  # stderr inside a subagent turn is not a durable channel, and the run that needed this
  # could not afterwards say which items it had rejected.
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --state .context/state.json \
    --facts '{"decisions":[{"id":"ok1","summary":"kept"}],"open_questions":[{"id":"BADID","class":"decision","ref":"a.md#x","blocks_next_stage":false}]}'
  [ "$status" -eq 2 ] || fail "expected exit 2 for a partial rejection, got $status"

  run jq -e 'select(.action == "facts_items_rejected")
             | .metadata.rejected[0].label == "BADID"' .context/logs/audit.jsonl
  assert_success

  # The valid remainder still persisted — the partial-success contract is unchanged.
  run jq -e '[.facts.decisions[].id] | index("ok1")' .context/state.json
  assert_success
}

@test "facts: eviction is reported as eviction, and only real loss as loss (F-04)" {
  # The message used to assert `(clamp eviction)` unconditionally. On the run that produced
  # this finding it named four ids a later write had restored, while four OTHER ids were the
  # ones actually gone — so the only durable clue pointed away from the casualties.
  cd "$WD"
  local payload
  payload="$(jq -cn '{decisions: [range(1;12) | {id: ("ar" + (. | tostring)), summary: "d", stage: "AR0"}]}')"
  run bash "$PLUGIN_ROOT/$SCRIPT" --state .context/state.json --facts "$payload"
  [[ "$output" == *"clamp evicted these ids"* ]] || fail "eviction not named as eviction: $output"
  [[ "$output" != *"NEITHER the ledger nor the spill"* ]] || fail "spilled ids reported as lost: $output"

  # And every id it called evicted is genuinely recoverable.
  run bash "$PLUGIN_ROOT/$SCRIPT" --state .context/state.json --read-decisions
  assert_success
  local n
  n="$(printf '%s' "$output" | jq 'length')"
  [ "$n" = "11" ] || fail "expected all 11 to resolve through the union, got $n"
}

@test "happy: merges completed DV verdict into tasks.DV0 (atomic)" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md
  assert_success
  run jq -r '.tasks.DV0.status' .context/state.json
  assert_output "completed"
  run jq -r '.tasks.DV0.verdict' .context/state.json
  assert_output "ok"
  run jq -r '.tasks.DV0.artifact' .context/state.json
  assert_output --partial "development-0.md"
}

@test "happy: --stage with no --artifact resolves via run_index=0 from state.json" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV
  assert_success
  run jq -r '.tasks.DV0.status' .context/state.json
  assert_output "completed"
  run jq -r '.tasks.DV0.artifact' .context/state.json
  assert_output --partial "development-0.md"
}

@test "edge: idempotent re-run leaves state.json byte-identical" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md
  cp .context/state.json snap
  bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md
  run diff -q .context/state.json snap
  assert_success
}

@test "edge: absent artifact for an un-run stage is a no-op (exit 0, state unchanged)" {
  cd "$WD"
  cp .context/state.json snap
  # No testing-*.md / QA artifact exists in the fixture workdir.
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage QA
  assert_success
  run diff -q .context/state.json snap
  assert_success
}

@test "edge: absent state.json is F1 fallback no-op (exit 0)" {
  cd "$WD"
  rm -f .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md
  assert_success
  [ ! -f .context/state.json ]
}

@test "failure: disk-guard hard-halt exits 2 below DISK_MIN_GB" {
  cd "$WD"
  # --disk-check accepts an OPTIONAL root value. A bare --disk-check (last arg, or
  # followed by another -flag) defaults root=".". The real disk-guard halt fires
  # when DISK_MIN_GB exceeds free space on that root.
  DISK_MIN_GB=99999999 run bash "$PLUGIN_ROOT/$SCRIPT" \
    --stage DV --artifact .context/development-0.md --disk-check
  assert_failure 2
  assert_output --partial "HALT"
}

@test "disk-check: explicit root value is consumed (documented contract)" {
  cd "$WD"
  # An unparseable root (df fails) degrades silently → guard returns 0, patch applies.
  run bash "$PLUGIN_ROOT/$SCRIPT" \
    --stage DV --artifact .context/development-0.md --disk-check /no_such_mount_xyz
  assert_success
  run jq -r '.tasks.DV0.status' .context/state.json
  assert_output "completed"
}

@test "failure: unknown argument exits 2 via usage" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --bogus-flag
  assert_failure 2
  assert_output --partial "unknown argument"
}

@test "contract: --self-test runs T1-T9 green and reaches ALL PASS (AC-5)" {
  # --disk-check now consumes its optional root value, so T6's unparseable-mount
  # path degrades gracefully instead of aborting. T8 (--prev) and T9 (bounds) are
  # the new self-tests. The suite must reach "ALL PASS" (exit 0).
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "T1: explicit artifact"
  assert_output --partial "T6: disk-guard degrade"
  assert_output --partial "T8: --prev writes handoffs"
  assert_output --partial "T9: facts.decisions clamped"
  assert_output --partial "T9: dispatched_agents clamped"
  assert_output --partial "T11: alias basename resolves"
  assert_output --partial "T12: unresolved self-patch exits 3"
  assert_output --partial "T13: --prev USER writes"
  assert_output --partial "T18: replay resets the target"
  assert_output --partial "T-ack:"
  assert_output --partial "ALL PASS"
  assert_output --regexp 'ALL PASS \([1-9][0-9]* passed, 0 failed\)'
}

# ---------------------------------------------------------------------------
# --prev writes the handoffs edge every stage agent would otherwise hand-roll;
# bounds are enforced at the atomic_apply write.
# ---------------------------------------------------------------------------

@test "prev: --prev writes handoffs[PREV→TASK_ID] from summary + artifact basename" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --prev TL --artifact .context/development-0.md
  assert_success
  run jq -r '.handoffs["TL→DV0"]' .context/state.json
  assert_output --partial "ref:development-0.md"
  # Stage patch still lands alongside the handoffs edge.
  run jq -r '.tasks.DV0.status' .context/state.json
  assert_output "completed"
}

@test "prev: absent --prev leaves handoffs untouched (byte-stable default)" {
  cd "$WD"
  cp .context/state.json snap
  bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md
  run jq -r '.handoffs | length' .context/state.json
  assert_output "0"
}

@test "prev: invalid --prev value exits 2 via usage" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md --prev ZZ
  assert_failure 2
  assert_output --partial "invalid --prev value"
}

# ---------------------------------------------------------------------------
# Fail-loud resolution: alias basenames (REQ-1), unresolved self-patch (REQ-2),
# and USER as a predecessor-only code (REQ-3).
# ---------------------------------------------------------------------------

@test "alias: a documented alias basename resolves when the canonical name is absent" {
  cd "$WD"
  sed 's/stage: DV/stage: QA/' .context/development-0.md > .context/qa-0.md
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage QA
  assert_success
  run jq -r '.tasks.QA0.artifact' .context/state.json
  assert_output --partial "qa-0.md"
}

@test "alias: the canonical basename still outranks an alias when both exist" {
  cd "$WD"
  sed 's/stage: DV/stage: QA/' .context/development-0.md > .context/qa-0.md
  sed 's/stage: DV/stage: QA/' .context/development-0.md > .context/testing-0.md
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage QA
  assert_success
  run jq -r '.tasks.QA0.artifact' .context/state.json
  assert_output --partial "testing-0.md"
}

@test "alias: a basename that is not canonical or aliased stays unresolved" {
  cd "$WD"
  # 'quality' is neither QA's canonical basename nor one of its aliases.
  sed 's/stage: DV/stage: QA/' .context/development-0.md > .context/quality-0.md
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage QA
  assert_success
  run diff -q .context/state.json snap
  assert_success
}

@test "fail-loud: self-patch with an unresolved artifact exits 3 naming stage and basenames" {
  cd "$WD"
  cp .context/state.json snap
  # ST has no artifact in the fixture workdir; --prev without --via is the self-patch signature.
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage ST --prev FN
  assert_failure 3
  assert_output --partial "ST"
  assert_output --partial "retrospective-N.md"
  run diff -q .context/state.json snap
  assert_success
}

@test "fail-loud: --via (hook / step6_5) keeps the unresolved no-op at exit 0" {
  cd "$WD"
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage ST --prev FN --via hook
  assert_success
  run diff -q .context/state.json snap
  assert_success
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage ST --prev FN --via step6_5
  assert_success
}

@test "fail-loud: --allow-missing-artifact restores the exit-0 no-op for the self-patch path" {
  cd "$WD"
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage ST --prev FN --allow-missing-artifact
  assert_success
  run diff -q .context/state.json snap
  assert_success
}

@test "user: --prev USER writes the USER→PL origin edge" {
  cd "$WD"
  sed 's/stage: DV/stage: PL/' .context/development-0.md > .context/planning-0.md
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage PL --prev USER --artifact .context/planning-0.md
  assert_success
  run jq -r '.handoffs["USER→PL0"]' .context/state.json
  assert_output --partial "ref:planning-0.md"
}

@test "user: --prev USER writes the USER→IR origin edge (emergency pipeline)" {
  cd "$WD"
  sed 's/stage: DV/stage: IR/' .context/development-0.md > .context/incident-0.md
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage IR --prev USER --artifact .context/incident-0.md
  assert_success
  run jq -r '.handoffs["USER→IR0"]' .context/state.json
  assert_output --partial "ref:incident-0.md"
}

@test "user: USER is predecessor-only — --stage USER resolves nothing and never patches" {
  cd "$WD"
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage USER
  assert_success
  run diff -q .context/state.json snap
  assert_success
  # A genuinely invalid predecessor is still a caller bug.
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md --prev NOPE
  assert_failure 2
  assert_output --partial "invalid --prev value"
}

@test "bounds: unstamped decisions share the reserved bucket, dispatched_agents clamp to 6" {
  cd "$WD"
  jq -n '
    {version:2, worktask_id:"b", plan_file:".context/planning-0.md", platform:"all",
     run_index:0, tasks:{PL0:{status:"completed", verdict:"ok"}},
     facts:{files_modified:[], tests_added:[], open_questions:[], verdicts:{PL:"ok"},
       decisions:[ range(0;11) | {id:("d"+(.|tostring)), summary:"s", ref:"x.md#y"} ],
       dispatched_agents:(
         [ range(0;6) | {stage:"DV", task_id:("t"+(.|tostring)), subagent_type:"a", status:"completed"} ]
         + [ range(6;9) | {stage:"DV", task_id:("t"+(.|tostring)), subagent_type:"a", status:"launched"} ])},
     handoffs:{}}' > .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md
  assert_success
  # No .stage on any of the 11, so all of them fall into the reserved "_" bucket and the
  # per-task clamp degrades to exactly the old global one — the pre-partition ledger arm.
  run jq -r '.facts.decisions | length' .context/state.json
  assert_output "8"
  run jq -r '.facts.decisions[-1].id' .context/state.json
  assert_output "d10"
  run jq -r '.facts.dispatched_agents | length' .context/state.json
  assert_output "6"
  run jq -r '[.facts.dispatched_agents[] | select(.status=="launched")] | length' .context/state.json
  assert_output "3"
}

# ---------------------------------------------------------------------------
# --facts union — the compressed-fact channel's write path.
# Asserts on CONTENT survival, not merely on the field existing: the bug these
# cover is stage B's patch silently replacing stage A's entries.
# ---------------------------------------------------------------------------

@test "facts: a decision recorded upstream survives a later stage's patch (content-asserted)" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"decisions":[{"id":"pl-1","summary":"union not replace","ref":"planning-0.md#stages"}]}'
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md --facts \
    '{"decisions":[{"id":"dv-1","summary":"tail append","ref":"development-0.md"}]}'
  assert_success
  run jq -r '[.facts.decisions[] | select(.id=="pl-1")] | .[0].summary' .context/state.json
  assert_output "union not replace"
  run jq -c '[.facts.decisions[] | select(.id=="pl-1" or .id=="dv-1") | .id]' .context/state.json
  assert_output '["pl-1","dv-1"]'
}

@test "facts: union survives where jq object-merge (. * \$patch) would replace" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"decisions":[{"id":"a","summary":"A","ref":"r"}]}'
  bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"decisions":[{"id":"b","summary":"B","ref":"r"}]}'
  # `. * $patch` semantics for the same two writes: the second array wins outright.
  run jq -n --argjson p '{"facts":{"decisions":[{"id":"b"}]}}' \
    '({"facts":{"decisions":[{"id":"a"}]}} * $p) | .facts.decisions | length'
  assert_output "1"
  run jq -r '.facts.decisions | length' .context/state.json
  assert_output "2"
}

@test "facts: all four fields union, keyed by .id and by string" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --facts '{
    "decisions":[{"id":"d1","summary":"s","ref":"r"}],
    "open_questions":[{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}],
    "files_modified":["a.sh"], "tests_added":["a.bats"]}'
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{
    "decisions":[{"id":"d2","summary":"s","ref":"r"}],
    "open_questions":[{"id":"sw-AR0-1","class":"escalate","ref":"architecture-0.md#elicitation-sweep","blocks_next_stage":false}],
    "files_modified":["b.sh"], "tests_added":["b.bats"]}'
  assert_success
  run jq -c '[(.facts.decisions|map(.id)), (.facts.open_questions|map(.id)),
              .facts.files_modified, .facts.tests_added]' .context/state.json
  assert_output '[["d1","d2"],["sw-PL0-1","sw-AR0-1"],["a.sh","b.sh"],["a.bats","b.bats"]]'
}

@test "facts: an open_questions item lacking class/ref is rejected, ledger byte-unchanged" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"open_questions":[{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}]}'
  cp .context/state.json .context/state.json.snap
  # The union REPLACES the incumbent object for that id, so a partial item would silently
  # drop the anchor the FN render resolves its options[] through.
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"open_questions":[{"id":"sw-PL0-1"}]}'
  assert_failure 2
  run diff -q .context/state.json .context/state.json.snap
  assert_success
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"open_questions":[{"id":"sw-PL0-2","class":"decision"}]}'
  assert_failure 2
  # blocks_next_stage is required too. Absent and explicit `false` are different claims —
  # absent used to let a re-emit inherit an incumbent `true` — so the field is stated by the
  # author, never inferred from its own omission.
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"open_questions":[{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep"}]}'
  assert_failure 2
  assert_output --partial "boolean .blocks_next_stage"
  run diff -q .context/state.json .context/state.json.snap
  assert_success
}

@test "facts: an explicit blocks_next_stage false clears an incumbent true" {
  cd "$WD"
  # The OV-183 defect: the union ORed the flag, so `true` was unclearable — even by the
  # author's own artifact value — and the ledger permanently outvoted the stub it came from.
  bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":true}]}'
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false}]}'
  assert_success
  run jq -r '.facts.open_questions[-1].blocks_next_stage' .context/state.json
  assert_output "false"
}

@test "facts: raising blocks_next_stage to true is still honoured" {
  cd "$WD"
  # Anti-vacuity for the case above: clearing must not have been bought by breaking the raise.
  bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"open_questions":[{"id":"sw-DV0-2","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false}]}'
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"open_questions":[{"id":"sw-DV0-2","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":true}]}'
  assert_success
  run jq -r '.facts.open_questions[-1].blocks_next_stage' .context/state.json
  assert_output "true"
}

@test "facts: a stub failing the shared predicate exits 2, naming the field, ledger unchanged" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"open_questions":[{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}]}'
  cp .context/state.json .context/state.json.snap
  # Each defect names itself AND the item it came from: per-item rejection reports
  # "<key> <id>: <reason>", so a mixed payload says which stub was refused.
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"open_questions":[{"id":"sw-P0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}]}'
  assert_failure 2
  assert_output --partial "sw-P0-1: id is not sw-<TASK_ID>-<n>"
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"open_questions":[{"id":"sw-PL0-1","class":"question","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}]}'
  assert_failure 2
  assert_output --partial "sw-PL0-1: class is not decision|escalate"
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"open_questions":[{"id":"sw-PL0-1","class":"decision","ref":"","blocks_next_stage":false}]}'
  assert_failure 2
  assert_output --partial "sw-PL0-1: ref is not an optional <artifact>.md path plus one non-empty #anchor"
  run diff -q .context/state.json .context/state.json.snap
  assert_success
}

@test "facts: an anchor-only ref is accepted (the tightening is not blanket)" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"open_questions":[{"id":"sw-PL0-9","class":"escalate","ref":"#elicitation-sweep","blocks_next_stage":false}]}'
  assert_success
  run jq -r '.facts.open_questions[-1].ref' .context/state.json
  assert_output "#elicitation-sweep"
}

@test "facts: decisions stay id-only — the stub tightening is scoped to open_questions" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"decisions":[{"id":"d1"}]}'
  assert_success
  run jq -r '.facts.decisions[0].id' .context/state.json
  assert_output "d1"
}

@test "facts: same .id from a later stage supersedes and moves to the tail" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"decisions":[{"id":"x","summary":"old","ref":"r"},{"id":"y","summary":"y","ref":"r"}]}'
  bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"decisions":[{"id":"x","summary":"new","ref":"r"}]}'
  run jq -c '[.facts.decisions[] | select(.id=="x" or .id=="y") | .id]' .context/state.json
  assert_output '["y","x"]'
  run jq -r '[.facts.decisions[] | select(.id=="x")] | length' .context/state.json
  assert_output "1"
  run jq -r '[.facts.decisions[] | select(.id=="x")] | .[0].summary' .context/state.json
  assert_output "new"
}

@test "facts: re-merging an already-merged payload is byte-identical" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"decisions":[{"id":"d1","summary":"s","ref":"r"}],"files_modified":["a.sh","b.sh"]}'
  cp .context/state.json snap
  bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    '{"decisions":[{"id":"d1","summary":"s","ref":"r"}],"files_modified":["a.sh","b.sh"]}'
  run diff -q .context/state.json snap
  assert_success
}

@test "bounds: clamp after union keeps the NEWEST 8 decisions, not an arbitrary 8" {
  cd "$WD"
  jq '.facts.decisions = [range(0;6) | {id:("d"+(.|tostring)), summary:"s", ref:"x.md#y"}]' \
    .context/state.json > s2 && mv s2 .context/state.json
  # 6 existing + 5 unioned = 11; the clamp must evict d0..d2, never the fresh tail.
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts \
    "$(jq -cn '{decisions:[range(6;11)|{id:("d"+(.|tostring)),summary:"s",ref:"x.md#y"}]}')"
  assert_success
  run jq -c '.facts.decisions | map(.id)' .context/state.json
  assert_output '["d3","d4","d5","d6","d7","d8","d9","d10"]'
}

@test "bounds: a superseded old decision re-enters at the tail and survives the clamp" {
  cd "$WD"
  jq '.facts.decisions = [range(0;8) | {id:("d"+(.|tostring)), summary:"s", ref:"x.md#y"}]' \
    .context/state.json > s2 && mv s2 .context/state.json
  bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"decisions":[{"id":"d0","summary":"revised","ref":"x"}]}'
  run jq -c '.facts.decisions | map(.id)' .context/state.json
  assert_output '["d1","d2","d3","d4","d5","d6","d7","d0"]'
  run jq -r '.facts.decisions[-1].summary' .context/state.json
  assert_output "revised"
}

@test "facts: unknown key is rejected and state.json is left unchanged" {
  cd "$WD"
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"verdicts":{"PL":"ok"}}'
  assert_failure
  assert_output --partial "unknown key(s): verdicts"
  run diff -q .context/state.json snap
  assert_success
}

@test "facts: wrong array shape is rejected before the merge lock" {
  cd "$WD"
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"decisions":[42]}'
  assert_failure
  assert_output --partial 'decisions 42: expected {id, summary, ref}'
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"files_modified":[7]}'
  assert_failure
  assert_output --partial "files_modified 7: not a string"
  # A value that is not an array at all stays a whole-payload refusal: nothing in it is
  # item-shaped enough to salvage.
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"decisions":{"id":"d1"}}'
  assert_failure
  assert_output --partial "bad shape for decisions (expected an array)"
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts 'not json'
  assert_failure
  assert_output --partial "not valid JSON"
  run diff -q .context/state.json snap
  assert_success
}

@test "facts: ledger channel is untouched by a standalone --facts call" {
  cd "$WD"
  before_tasks="$(jq -c '.tasks' .context/state.json)"
  before_handoffs="$(jq -c '.handoffs' .context/state.json)"
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"files_modified":["a.sh"]}'
  assert_success
  run jq -c '.tasks' .context/state.json
  assert_output "$before_tasks"
  run jq -c '.handoffs' .context/state.json
  assert_output "$before_handoffs"
}

@test "facts: lands even when the completion merge short-circuits as idempotent" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md --facts \
    '{"decisions":[{"id":"late","summary":"after idempotent stop","ref":"r"}]}'
  assert_success
  run jq -r '[.facts.decisions[] | select(.id=="late")] | .[0].summary' .context/state.json
  assert_output "after idempotent stop"
}

@test "bounds: small arrays are untouched (no clamp, byte-stable)" {
  cd "$WD"
  # The fixture state has short decisions/dispatched_agents; a patch must not perturb them.
  before_dec="$(jq -c '.facts.decisions // []' .context/state.json)"
  bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md
  run jq -c '.facts.decisions // []' .context/state.json
  assert_output "$before_dec"
}

# ---------------------------------------------------------------------------
# v1 additive upgrade — mkdir-spinlock + --via + worktree mapping (issue #199).
# All lock tests are deterministic via STATE_LOCK_TIMEOUT_S / STATE_LOCK_STALE_S
# env knobs — NO sleep-races.
# ---------------------------------------------------------------------------

@test "lock: held-but-fresh lock defers then times out → proceeds UNLOCKED + WARN, patch applied" {
  cd "$WD"
  # Pre-create the lock dir and keep it FRESH (STALE huge) so the stale-break path
  # does NOT fire — this exercises the pure timeout→unlocked-proceed branch.
  mkdir .context/state.json.lock.d
  STATE_LOCK_TIMEOUT_S=1 STATE_LOCK_STALE_S=99999 \
    run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md \
    --log .context/logs/lock.log
  assert_success
  run jq -r '.tasks.DV0.status' .context/state.json
  assert_output "completed"
  run grep -c 'proceeding UNLOCKED' .context/logs/lock.log
  assert_output "1"
}

@test "lock: stale lock (older than STATE_LOCK_STALE_S) is broken via mtime, patch applied, lock released" {
  cd "$WD"
  mkdir .context/state.json.lock.d
  # STALE=0 → any existing lock is immediately stale and broken.
  STATE_LOCK_TIMEOUT_S=3 STATE_LOCK_STALE_S=0 \
    run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md \
    --log .context/logs/lock.log
  assert_success
  run jq -r '.tasks.DV0.status' .context/state.json
  assert_output "completed"
  run grep -c 'lock stale' .context/logs/lock.log
  assert_output "1"
  # Lock released after a successful merge.
  [ ! -d .context/state.json.lock.d ]
}

@test "lock: the mtime probe keeps its format attached to the flag (GNU stdout-pollution guard)" {
  # Separated (`stat -f %m`), GNU reads -f as --file-system, which takes no
  # argument: the path becomes an operand, stat prints a filesystem block to
  # stdout and exits non-zero, and `||` — testing status only — appends the
  # fallback to that block. $mtime becomes junk, not empty. Attached is safe
  # because GNU getopt rejects `-f%m` before anything reaches stdout. This
  # asserts the source form, because the failure is unreachable on BSD/macOS.
  run grep -nE 'stat -[fc] +%' "$PLUGIN_ROOT/$SCRIPT"
  assert_failure
  run grep -c 'stat -f%m .* || stat -c%Y ' "$PLUGIN_ROOT/$SCRIPT"
  assert_output "1"
}

@test "lock: a non-numeric mtime probe is treated as un-ageable, not as age 0" {
  cd "$WD"
  # A junk probe must not reach the arithmetic. Shadow `stat` with the exact
  # GNU-separated failure shape: multi-line stdout plus non-zero status.
  mkdir -p "$WD/binshim" .context/state.json.lock.d
  cat > "$WD/binshim/stat" <<'SHIM'
#!/usr/bin/env bash
printf '  File: "/x"\n    ID: 0 Namelen: 255\n'
exit 1
SHIM
  chmod +x "$WD/binshim/stat"
  # The discriminator is the arithmetic, not the log: without the numeric guard
  # the junk reaches `age=$((now - mtime))`, whose first word is unset under
  # `set -u`, and the run dies with "File: unbound variable". Asserting only
  # "no 'lock stale' line" would pass either way — the aborted run prints no
  # such line either. Verified by mutation: reverting the guard to the old
  # emptiness test reproduces the unbound-variable abort.
  PATH="$WD/binshim:$PATH" STATE_LOCK_TIMEOUT_S=1 STATE_LOCK_STALE_S=0 \
    run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md \
    --log .context/logs/lock.log
  refute_output --partial "unbound variable"
  refute_output --partial "lock stale"
}

@test "lock: EXIT-trap releases the lock even when the jq merge fails (release-on-fail)" {
  cd "$WD"
  # Corrupt state.json so the jq merge inside atomic_apply() fails (rc=1), then
  # assert the lock the run acquired is still released by _lock_release / EXIT trap.
  printf 'NOT JSON {{{' > .context/state.json
  STATE_LOCK_TIMEOUT_S=2 STATE_LOCK_STALE_S=60 \
    run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md \
    --log .context/logs/lock.log
  # jq merge failure → state-patch exits 1 (script contract), but the lock dir it
  # created must NOT be leaked.
  assert_failure 1
  [ ! -d .context/state.json.lock.d ]
}

@test "via: --via hook stamps tasks.DV0.completed_via=hook (additive, version unchanged)" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md --via hook
  assert_success
  run jq -r '.tasks.DV0.completed_via' .context/state.json
  assert_output "hook"
  run jq -r '.version' .context/state.json
  assert_output "2"
}

@test "via: --via step6_5 stamps completed_via=step6_5; invalid --via value exits 2" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md --via step6_5
  assert_success
  run jq -r '.tasks.DV0.completed_via' .context/state.json
  assert_output "step6_5"
  # Invalid enum value is a caller bug → exit 2 via usage.
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md --via bogus
  assert_failure 2
  assert_output --partial "invalid --via value"
}

@test "worktree: worktree_path/worktree_branch frontmatter maps to tasks.DV0.worktree" {
  cd "$WD"
  cat > .context/development-0.md <<'EOART'
---
handoff:
  stage: DV
  verdict: ok
  summary: "worktree mapping fixture"
  worktree: true
  worktree_path: /tmp/wt/agent-abc
  worktree_branch: feature/xyz
---

# Development
EOART
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md
  assert_success
  run jq -r '.tasks.DV0.worktree.path' .context/state.json
  assert_output "/tmp/wt/agent-abc"
  run jq -r '.tasks.DV0.worktree.branch' .context/state.json
  assert_output "feature/xyz"
  # Additive: absent worktree frontmatter must NOT synthesize the key.
  run jq -e '.tasks.PL0 | has("worktree")' .context/state.json
  assert_output "false"
}

@test "parallel: concurrent DV+QA patches both land (no last-rename-wins drop)" {
  cd "$WD"
  # Two backgrounded state-patch invocations against the SAME state.json, one per
  # stage KEY (legal sibling overlap). The lock serializes read-merge-rename so
  # BOTH stages must read 'completed' — deterministic via a short stale window.
  cat > .context/testing-0.md <<'EOART'
---
handoff:
  stage: QA
  verdict: go
  summary: "parallel QA patch"
---
EOART
  STATE_LOCK_TIMEOUT_S=10 STATE_LOCK_STALE_S=30 \
    bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md \
    --log .context/logs/p.log &
  local dv_pid=$!
  STATE_LOCK_TIMEOUT_S=10 STATE_LOCK_STALE_S=30 \
    bash "$PLUGIN_ROOT/$SCRIPT" --stage QA --artifact .context/testing-0.md \
    --log .context/logs/p.log &
  local qa_pid=$!
  wait "$dv_pid"
  wait "$qa_pid"
  run jq -r '.tasks.DV0.status' .context/state.json
  assert_output "completed"
  run jq -r '.tasks.QA0.status' .context/state.json
  assert_output "completed"
}

# ---------------------------------------------------------------------------
# Conditional handoff edges for the optional AR/TL stages (3.42.0). PL0 sizes
# the stage set, so DV's predecessor is TL, AR or PL and TL's is AR or PL.
# ---------------------------------------------------------------------------

@test "prev: --stage DV --prev AR records the AR→DV edge (TL excluded)" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --prev AR --artifact .context/development-0.md
  assert_success
  run jq -r '.handoffs["AR→DV0"]' .context/state.json
  assert_output --partial "ref:development-0.md"
  run jq -r '.handoffs | has("TL→DV0")' .context/state.json
  assert_output "false"
}

@test "prev: --stage DV --prev PL records the PL→DV edge (AR and TL excluded)" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --prev PL --artifact .context/development-0.md
  assert_success
  run jq -r '.handoffs["PL→DV0"]' .context/state.json
  assert_output --partial "ref:development-0.md"
  run jq -r '.handoffs | keys | length' .context/state.json
  assert_output "1"
}

@test "prev: --stage TL --prev PL records the PL→TL edge (AR excluded)" {
  cd "$WD"
  cat > .context/coordination-0.md <<'EOF'
---
handoff:
  stage: TL
  verdict: ok
  summary: "Single workstream, no fan-out"
  next_stage_focus: "DV implements in one batch"
  refs: { plan: planning-0.md#requirements }
---

# Coordination

## fan-out

Single stream.
EOF
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage TL --prev PL --artifact .context/coordination-0.md
  assert_success
  run jq -r '.handoffs["PL→TL0"]' .context/state.json
  assert_output --partial "ref:coordination-0.md"
  run jq -r '.tasks.TL0.status' .context/state.json
  assert_output "completed"
}

@test "prev: --stage DV --prev IR records the IR→DV edge (emergency pipeline, no PL)" {
  cd "$WD"
  # The emergency pipeline is IR→DV→DR→QA→RE→FN — there is no PL/AR/TL stage at all,
  # so PL→DV here would be exactly the phantom edge R8 exists to eliminate.
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --prev IR --artifact .context/development-0.md
  assert_success
  run jq -r '.handoffs["IR→DV0"]' .context/state.json
  assert_output --partial "ref:development-0.md"
  run jq -r '.handoffs | has("PL→DV0")' .context/state.json
  assert_output "false"
}

@test "remediation: same verdict with a new summary refreshes the handoffs edge" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --prev AR --artifact .context/development-0.md
  run jq -r '.handoffs["AR→DV0"]' .context/state.json
  assert_output --partial "DV0a fixture development artifact"

  # A DV→DR→DV loop re-completes DV at the same verdict; the edge must follow the new summary.
  sed -i.bak 's/DV0a fixture development artifact/remediated after DR round 1/' \
    .context/development-0.md
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --prev AR --artifact .context/development-0.md
  assert_success
  run jq -r '.handoffs["AR→DV0"]' .context/state.json
  assert_output --partial "remediated after DR round 1"
  refute_output --partial "DV0a fixture development artifact"
}

@test "remediation: an unchanged re-run is still byte-identical (idempotence preserved)" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --prev AR --artifact .context/development-0.md
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --prev AR --artifact .context/development-0.md
  assert_success
  run diff -q .context/state.json snap
  assert_success
}

# ---------------------------------------------------------------------------
# --task-replay. The load-bearing assertions are the refusals: a
# replay that resets a stage whose agent is still alive puts two writers in one
# tree, so every guard test asserts the ledger is BYTE-identical afterwards
# (checksum, not a field check) — a partially-applied reset would pass a field
# check on the field it never reached.
# ---------------------------------------------------------------------------

# mk_replay_wd [fixture-basename] — workdir on the multi-stage chain
# PL0→DV1→DR0→QA0→FN0→ST0, plus the three liveness fixtures every guard needs.
mk_replay_wd() {
  local w; w="$(mk_tmpworkdir)"
  mkdir -p "$w/.context/logs"
  cp "$FIXTURES/worktask/${1:-state.multistage.json}" "$w/.context/state.json"
  cp "$w/.context/state.json" "$w/before.json"
  printf '%s\n' '[]' > "$w/gone.json"
  printf '%s\n' '[{"id":"sess-dv1","sessionId":"sess-dv1deadbeef","name":"dv","state":"active"}]' \
    > "$w/busy.json"
  printf '%s\n' '[{"id":"sess-dv1","sessionId":"sess-dv1deadbeef","name":"dv","state":"blocked"}]' \
    > "$w/parked.json"
  printf '%s\n' 'not json' > "$w/garbage.json"
  printf '%s\n' "$w"
}

assert_ledger_unchanged() {
  cmp -s "$1/.context/state.json" "$1/before.json" \
    || fail "guard mutated state.json; it must be byte-identical
$(diff "$1/before.json" "$1/.context/state.json" || true)"
}

@test "replay guard: unknown task id refuses with exit 1, ledger byte-unchanged" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV7 --agents-json "$w/gone.json"
  assert_failure 1
  assert_output --partial "unknown task id"
  assert_ledger_unchanged "$w"
}

@test "replay guard: malformed task id stays exit 2 via usage, ledger byte-unchanged" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  # Exit 2 collides with DISK_HALT. That is pre-existing behaviour shared by all
  # task ops; this test pins it so a future change is a deliberate one.
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay ZZ0 --agents-json "$w/gone.json"
  assert_failure 2
  assert_output --partial "invalid task id"
  assert_ledger_unchanged "$w"
}

@test "replay guard: live agent refuses target-live (exit 4), ledger byte-unchanged" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/busy.json"
  assert_failure 4
  assert_output --partial "replay refused: target-live"
  assert_ledger_unchanged "$w"
}

@test "replay guard: parked agent refuses target-parked (exit 4), ledger byte-unchanged" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/parked.json"
  assert_failure 4
  assert_output --partial "replay refused: target-parked"
  assert_ledger_unchanged "$w"
}

@test "replay guard: unreadable agents payload refuses liveness-indeterminate (fail-closed)" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/nope.json"
  assert_failure 4
  assert_output --partial "replay refused: liveness-indeterminate"
  assert_ledger_unchanged "$w"
}

@test "replay guard: unparseable agents payload refuses liveness-indeterminate" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/garbage.json"
  assert_failure 4
  assert_output --partial "replay refused: liveness-indeterminate"
  assert_ledger_unchanged "$w"
}

@test "replay guard: incomplete planning refuses plan-incomplete, ledger byte-unchanged" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  jq '.tasks.PL0.status = "in_progress"' .context/state.json > t && mv t .context/state.json
  cp .context/state.json before.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/gone.json"
  assert_failure 4
  assert_output --partial "replay refused: plan-incomplete"
  assert_ledger_unchanged "$w"
}

@test "replay guard: no audit row is written on any refusal" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/busy.json" || true
  bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV7 --agents-json "$w/gone.json" || true
  # A refusal row would carry result:"error", which stale-check.sh reads as a real
  # stage failure and uses to rule OUT a budget halt — poisoning later diagnosis.
  [ ! -s .context/logs/audit.jsonl ] || fail "refusal appended: $(cat .context/logs/audit.jsonl)"
}

@test "replay: an escalated stage (retry_count 3 + escalation marker) is replayable" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run jq -r '[.tasks.DV1.metadata.retry_count, .tasks.DV1.metadata.error_escalated_to] | @csv' \
    .context/state.json
  assert_output '3,"AR"'

  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/gone.json"
  assert_success
  run jq -r '.tasks.DV1.status' .context/state.json
  assert_output "pending"
  run jq -r '[.tasks.DV1.metadata | has("retry_count"), has("error_escalated_to")] | @csv' \
    .context/state.json
  assert_output "false,false"
  run jq -r '.tasks.DV1 | has("completed_via")' .context/state.json
  assert_output "false"
  # The override is recorded where it is still knowable — at write time.
  assert_audit_row stage_replay --file "$w/.context/logs/audit.jsonl" \
    --subject DV1 --result ok --count 1 --meta escalation_cap_override=true --meta prior_retry_count=3 \
    --meta prior_escalated_to=AR --meta prior_status=in_progress
}

@test "replay: artifact, verdict and worktree survive the reset" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/gone.json"
  run jq -r '[.tasks.DV1.artifact, .tasks.DV1.verdict, .tasks.DV1.worktree.branch] | @csv' \
    .context/state.json
  assert_output '".context/development-1.md","ok","feature/replay"'
}

@test "replay blast radius: replaying DV1 changes DV1's fields and nothing else" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/gone.json"
  # Every task except DV1 must be byte-identical, PL0 included.
  run jq -S --slurpfile a before.json '.tasks | with_entries(select(.key != "DV1"))
        == ($a[0].tasks | with_entries(select(.key != "DV1")))' .context/state.json
  assert_output "true"
  run jq -S --slurpfile a before.json 'del(.tasks) == ($a[0] | del(.tasks))' .context/state.json
  assert_output "true"
  # …and within DV1 only the four documented paths moved.
  run jq -Sr --slurpfile a before.json '[
        (.tasks.DV1 | keys_unsorted) - ($a[0].tasks.DV1 | keys_unsorted),
        ($a[0].tasks.DV1 | keys_unsorted) - (.tasks.DV1 | keys_unsorted),
        ($a[0].tasks.DV1.metadata | keys) - (.tasks.DV1.metadata | keys)] | flatten | sort
      | join(",")' .context/state.json
  assert_output "completed_via,error_escalated_to,retry_count"
  # …and at value level: DV1 after == DV1 before minus exactly those three keys, with
  # status flipped. A silent rewrite of e.g. .artifact passes the key-set check above.
  run jq -Sr --slurpfile a before.json '.tasks.DV1 ==
        ($a[0].tasks.DV1
         | del(.completed_via) | .metadata |= (del(.retry_count) | del(.error_escalated_to))
         | .status = "pending")' .context/state.json
  assert_output "true"
}

@test "replay audit: the row is not matchable as an ordinary retry" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/gone.json"
  assert_audit_row stage_replay --file "$w/.context/logs/audit.jsonl" --count 1
  assert_audit_row retry_attempt --file "$w/.context/logs/audit.jsonl" --absent
  # A reader filtering ordinary retries keys on .metadata.retry; the replay row
  # deliberately names its counter prior_retry_count so that filter cannot match.
  run jq -r '[.[] | select(.metadata.retry)] | length' <(jq -s . .context/logs/audit.jsonl)
  assert_output "0"
  run jq -r '.metadata.via' .context/logs/audit.jsonl
  assert_output "state-patch --task-replay"
}

@test "replay P1: completed dependents are named as possibly stale, never reset" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/gone.json"
  assert_success
  assert_output --partial "replay warning: stale-dependents"
  assert_output --partial "DR0"
  run jq -r '.tasks.DR0.status' .context/state.json
  assert_output "completed"
}

@test "replay cascade: resets the transitive closure, skipping FN with a warning" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --cascade --agents-json "$w/gone.json"
  assert_success
  assert_output --partial "replay warning: side-effect-skipped"
  assert_output --partial "FN0"
  run jq -r '[.tasks | to_entries[] | select(.value.status == "pending") | .key] | sort | join(",")' \
    .context/state.json
  assert_output "DR0,DV1,QA0,ST0"
  # FN0 is traversed THROUGH (ST0 downstream of it is reset) but never reset itself.
  run jq -r '.tasks.FN0.status' .context/state.json
  assert_output "completed"
}

@test "replay cascade: one audit row per member, root first then BFS order" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --cascade --agents-json "$w/gone.json"
  run jq -rs 'map(.subject) | join(",")' .context/logs/audit.jsonl
  assert_output "DV1,DR0,QA0,ST0"
  run jq -rs '[.[] | .metadata.cascade_id] | unique | length' .context/logs/audit.jsonl
  assert_output "1"
  run jq -rs 'map(select(.subject == "DV1"))[0]
        | [(.metadata.cascade_members | join("+")), (.metadata.cascade_skipped | join("+"))]
        | join(" / ")' .context/logs/audit.jsonl
  assert_output "DV1+DR0+QA0+ST0 / FN0+RE0"
}

@test "replay cascade: the stale-dependent warning never names a task the same write resets" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  # Non-cascade, DR0 is a completed dependent that is NOT reset ⇒ genuinely stale.
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/gone.json"
  assert_output --partial "replay warning: stale-dependents"
  assert_output --partial "DR0"

  # Under --cascade the same DR0 IS reset by this write, so calling it stale would assert the
  # opposite of what the command does — and would write that claim into the durable audit row.
  local v; v="$(mk_replay_wd)"; cd "$v"; export WORKSPACE_ROOT="$v"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --cascade --agents-json "$v/gone.json"
  assert_success
  refute_output --partial "stale-dependents"
  run jq -rs 'map(select(.subject == "DV1"))[0] | .metadata.stale_dependents | length' \
    .context/logs/audit.jsonl
  assert_output "0"
}

@test "replay cascade: an FN root is reset, while a dependent RE is skipped and named stale" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  # The named target is always reset, cascade or not; only DEPENDENT side-effect stages are
  # skipped. RE0 is skipped, stays completed, and is therefore genuinely stale — which is the
  # discriminator between "in the graph" and "in the reset set".
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay FN0 --cascade --agents-json "$w/gone.json"
  assert_success
  assert_output --partial "replay warning: side-effect-target"
  assert_output --partial "replay warning: side-effect-skipped"
  run jq -r '[.tasks | to_entries[] | select(.value.status == "pending") | .key] | sort | join(",")' \
    .context/state.json
  assert_output "FN0,ST0"
  run jq -r '.tasks.RE0.status' .context/state.json
  assert_output "completed"
  run jq -rs 'map(select(.subject == "FN0"))[0]
        | [(.metadata.cascade_skipped | join("+")), (.metadata.stale_dependents | join("+"))]
        | join(" / ")' .context/logs/audit.jsonl
  assert_output "RE0 / RE0"
}

# The DR→DV loop-back as Step 7 performs it: a replay that clears retry_count, then a
# --task-meta re-stamp of prior + 1. A fix round is the same run, so run_index must not move.
@test "loop-back: replay then the retry re-stamp keeps run_index and counts the retry" {
  local w; w="$(mk_tmpworkdir)"; mkdir -p "$w/.context/logs"; cd "$w"; export WORKSPACE_ROOT="$w"
  printf '%s\n' '[]' > "$w/gone.json"
  jq -n '{version: 2, worktask_id: "wt-loop", run_index: 1, plan_file: ".context/planning-1.md",
          platform: "all",
          tasks: {PL0: {status: "completed", blocked_by: null, metadata: {stage: "PL"}},
                  DV0: {status: "completed", blocked_by: ["PL0"],
                        metadata: {stage: "DV", agent: "corpflow:developer", retry_count: 1}},
                  DR0: {status: "pending", blocked_by: ["DV0"],
                        metadata: {stage: "DR", agent: "corpflow:technical-lead", gate_from_stage: "DR"}}},
          facts: {}, handoffs: {}}' > .context/state.json
  local prior
  prior="$(jq -r '.tasks.DV0.metadata.retry_count' .context/state.json)"

  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV0 --cascade --agents-json "$w/gone.json"
  assert_success
  run jq -r '.tasks.DV0.metadata | has("retry_count")' .context/state.json
  assert_output "false"

  run bash "$PLUGIN_ROOT/$SCRIPT" --task-meta DV0 --set "{\"retry_count\":$((prior + 1))}"
  assert_success
  run jq -r '[.run_index, .tasks.DV0.metadata.retry_count, .tasks.DV0.status] | map(tostring) | join(" ")' \
    .context/state.json
  assert_output "1 2 pending"
}

@test "replay: --cascade and --agents-json are rejected on the other ledger ops" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-status DV1 pending --cascade
  assert_failure 2
  assert_output --partial "apply to --task-replay only"
  assert_ledger_unchanged "$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-meta DV1 --set '{}' --agents-json "$w/gone.json"
  assert_failure 2
  assert_ledger_unchanged "$w"
}

@test "replay cascade: a blocked member refuses the WHOLE cascade before any write" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  # Park QA0 (a mid-cascade member) rather than the root.
  jq '.tasks.QA0.status = "in_progress"
      | .facts.dispatched_agents += [{"stage":"QA","task_id":"QA0",
          "subagent_type":"corpflow:qa-engineer","agent_id":"sess-qa0","status":"launched"}]' \
    .context/state.json > t && mv t .context/state.json
  cp .context/state.json before.json
  printf '%s\n' '[{"id":"sess-qa0","sessionId":"sess-qa0deadbeef","name":"qa","state":"active"}]' \
    > mixed.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --cascade --agents-json mixed.json
  assert_failure 4
  assert_output --partial "replay refused: cascade-member-blocked — QA0: target-live"
  assert_ledger_unchanged "$w"
}

@test "replay cascade: a blocked_by cycle terminates and still resets the closure" {
  local w; w="$(mk_replay_wd state.cycle.json)"; cd "$w"; export WORKSPACE_ROOT="$w"
  # DR0 ↔ QA0 point at each other; blocked_by has no acyclicity enforcement, so the
  # walk must terminate on the visited set + task-count bound, not on graph shape.
  # No timeout(1) on macOS: termination is the assertion, so a hang fails the suite
  # by wall clock rather than by a wrapper this host may not have.
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --cascade --agents-json "$w/gone.json"
  assert_success
  run jq -r '[.tasks | to_entries[] | select(.value.status == "pending") | .key] | sort | join(",")' \
    .context/state.json
  assert_output "DR0,DV1,QA0,ST0"
}

@test "replay: a directly named FN target is allowed but warns about the side effect" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay FN0 --agents-json "$w/gone.json"
  assert_success
  assert_output --partial "replay warning: side-effect-target"
  run jq -r '.tasks.FN0.status' .context/state.json
  assert_output "pending"
}

@test "replay: replaying an already-clean task is idempotent" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/gone.json"
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/gone.json"
  assert_success
  run diff -q .context/state.json snap
  assert_success
}

@test "replay parity: the script's side-effect list matches stage-codes.md" {
  # bash cannot read the canonical markdown table, so the constant mirrors it; this
  # assertion is what keeps the mirror honest.
  local doc script_list
  doc="$(awk -F'|' '
    /^### Side-effect-bearing stages/ { f = 1; next }
    f && /^#/ { exit }
    f && NF > 2 { c = $2; gsub(/[[:space:]]/, "", c);
                  if (c ~ /^[A-Z][A-Z]$/) print c }' \
    "$PLUGIN_ROOT/skills/shared/stage-codes.md" | sort | paste -sd, -)"
  script_list="$(grep -E '^REPLAY_SIDE_EFFECT_STAGES=' "$PLUGIN_ROOT/$SCRIPT" \
    | cut -d'"' -f2 | tr ',' '\n' | sort | paste -sd, -)"
  [ -n "$doc" ] || fail "stage-codes.md § Side-effect-bearing stages parsed empty"
  [ "$doc" = "$script_list" ] \
    || fail "side-effect list drift: stage-codes.md=[$doc] state-patch.sh=[$script_list]"
}

# ---------------------------------------------------------------------------
# Split-stage slot resolution: --artifact disambiguates, ambiguity fails closed.
# The pre-existing coverage only ever had ONE open instance, which is the shape
# under which the mis-slotting defect is invisible.
# ---------------------------------------------------------------------------

# Two DV instances, both in_progress, with the planned artifact names PL0 seeds.
two_open_dv() {
  jq '.tasks = {"DV0": {"status":"in_progress","metadata":{"artifact":".context/development-0-gate.md"}},
                "DV1": {"status":"in_progress","metadata":{"artifact":".context/development-0-ledger.md"}}}' \
    "$WD/.context/state.json" > "$WD/.context/s.tmp" && mv "$WD/.context/s.tmp" "$WD/.context/state.json"
}

@test "slot: --artifact picks the matching instance out of two in_progress DVs" {
  cd "$WD"
  two_open_dv
  run bash "$PLUGIN_ROOT/$SCRIPT" --resolve-task-id DV --artifact .context/development-0-ledger.md
  assert_success
  assert_output "DV1"
}

@test "slot: an absolute --artifact resolves like the stored relative path" {
  cd "$WD"
  two_open_dv
  run bash "$PLUGIN_ROOT/$SCRIPT" --resolve-task-id DV --artifact "$WD/.context/development-0-ledger.md"
  assert_success
  assert_output "DV1"
}

@test "slot: a RECORDED artifact outranks another instance's stale planned one" {
  # PL0 seeds metadata.artifact from the plan, and a split stage routinely writes a
  # different file than the plan guessed. Reading metadata first would slot the patch
  # by the plan's guess — the same mis-slot, reintroduced through the fix.
  cd "$WD"
  two_open_dv
  jq '.tasks.DV0.artifact = ".context/development-1.md"
      | .tasks.DV1.metadata.artifact = ".context/development-1.md"' \
    .context/state.json > .context/s.tmp && mv .context/s.tmp .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --resolve-task-id DV --artifact .context/development-1.md
  assert_success
  assert_output "DV0"
}

@test "slot: two open instances with no discriminator refuse, naming both, before any write" {
  cd "$WD"
  two_open_dv
  local before
  before="$(shasum .context/state.json | cut -d' ' -f1)"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md --via step6_5
  assert_failure 4
  assert_output --partial "DV0,DV1"
  [ "$(shasum .context/state.json | cut -d' ' -f1)" = "$before" ] \
    || fail "a refused resolution must leave state.json byte-identical"
}

@test "slot: one open instance with a bare --stage is unchanged (agent-stop.sh path)" {
  cd "$WD"
  jq '.tasks = {"DV0": {"status":"in_progress"}, "DV1": {"status":"pending"}}' \
    .context/state.json > .context/s.tmp && mv .context/s.tmp .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --resolve-task-id DV
  assert_success
  assert_output "DV0"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --via step6_5
  assert_success
  run jq -r '.tasks.DV0.status + "/" + .tasks.DV1.status' .context/state.json
  assert_output "completed/pending"
}

# ---------------------------------------------------------------------------
# facts.verdicts mirror and sweep-stub defaults.
# ---------------------------------------------------------------------------

@test "verdicts: a completion mirrors the stage verdict into facts.verdicts[TASK_ID] and the derived facts.verdicts[CODE]" {
  # The schema has carried facts.verdicts since v2 with no writer at all, so every
  # consumer reading it saw an empty object no matter how many stages completed.
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md
  assert_success
  run jq -r '.facts.verdicts.DV0 + "/" + .facts.verdicts.DV' .context/state.json
  assert_output "ok/ok"
}

@test "verdict refused: every caller shape refuses before any write, artifact has handoff: with no verdict" {
  cd "$WD"
  cat > .context/no-verdict.md <<'EOART'
---
handoff:
  stage: DV
  summary: "no verdict fixture"
---

# Development
EOART
  local before; before="$(shasum .context/state.json)"
  # Every shape below must hit the SAME refusal: the verdict guard fires ahead of --via, --prev,
  # --allow-missing-artifact and --facts, none of which govern a found-but-invalid artifact.
  local shapes=(
    ""
    "--prev PL"
    "--via hook"
    "--via step6_5"
    "--allow-missing-artifact"
    '--facts {"files_modified":["x"]}'
  )
  local shape extra
  for shape in "${shapes[@]}"; do
    extra=()
    [[ -n "$shape" ]] && read -ra extra <<< "$shape"
    run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --task-id DV0 --artifact .context/no-verdict.md "${extra[@]}"
    assert_failure 3
    assert_output --partial "verdict refused"
    local after; after="$(shasum .context/state.json)"
    [ "$before" = "$after" ] || fail "state.json changed for shape [$shape]: $(diff <(printf '%s' "$before") <(printf '%s' "$after"))"
  done
}

@test "verdict refused: artifact with no frontmatter block at all still refuses under --stage" {
  cd "$WD"
  printf '# Development\n\nNo frontmatter block in this artifact.\n' > .context/plain.md
  local before; before="$(shasum .context/state.json)"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/plain.md
  assert_failure 3
  assert_output --partial "verdict refused"
  local after; after="$(shasum .context/state.json)"
  [ "$before" = "$after" ]
}

@test "verdict refused: an unknown verdict string is refused the same as a missing one" {
  cd "$WD"
  cat > .context/bad-verdict.md <<'EOART'
---
handoff:
  stage: DV
  verdict: conditional
  summary: "unknown verdict fixture"
---

# Development
EOART
  local before; before="$(shasum .context/state.json)"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/bad-verdict.md
  assert_failure 3
  assert_output --partial "verdict refused"
  local after; after="$(shasum .context/state.json)"
  [ "$before" = "$after" ]
}

@test "verdicts: DR0 stays off SKILL.md's readiness query while DV0 is blocked, escalated or failed" {
  # Extracted rather than duplicated by hand: a hand-copied query drifts from the doc and
  # stops testing what an agent actually runs. Anti-vacuity: fail loud if extraction breaks.
  local query
  query="$(awk '
      /^#### Readiness is mechanical/ { found = 1 }
      found && /^> ```bash/ { infence = 1; next }
      infence && /^> ```$/ { exit }
      infence { sub(/^> ?/, ""); print }
    ' "$PLUGIN_ROOT/skills/worktask/SKILL.md")"
  [ -n "$query" ] || fail "readiness query extraction from SKILL.md#Readiness-is-mechanical came back empty"

  local w; w="$(mk_tmpworkdir)"
  mkdir -p "$w/.context/logs"
  cd "$w"
  export WORKSPACE_ROOT="$w"

  local verdict
  for verdict in blocked escalate fail; do
    jq -n '{version:2, worktask_id:"readiness-fixture", plan_file:".context/planning-0.md",
        platform:"all", run_index:0,
        tasks:{DV0:{status:"pending"}, DR0:{status:"pending", blocked_by:["DV0"]}},
        facts:{files_modified:[],tests_added:[],decisions:[],open_questions:[],verdicts:{}},
        handoffs:{}}' > .context/state.json
    cat > .context/development-0.md <<EOART
---
handoff:
  stage: DV
  verdict: ${verdict}
  summary: "readiness fixture"
---

# Development
EOART
    run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --task-id DV0 --artifact .context/development-0.md
    run bash -c "$query"
    refute_output --partial "DR0"
  done

  # Control: a passing verdict clears the block and DR0 becomes ready.
  jq -n '{version:2, worktask_id:"readiness-fixture", plan_file:".context/planning-0.md",
      platform:"all", run_index:0,
      tasks:{DV0:{status:"pending"}, DR0:{status:"pending", blocked_by:["DV0"]}},
      facts:{files_modified:[],tests_added:[],decisions:[],open_questions:[],verdicts:{}},
      handoffs:{}}' > .context/state.json
  cat > .context/development-0.md <<'EOART'
---
handoff:
  stage: DV
  verdict: pass
  summary: "readiness fixture control"
---

# Development
EOART
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --task-id DV0 --artifact .context/development-0.md
  assert_success
  run bash -c "$query"
  assert_output --partial "DR0"
}

@test "root ladder: with no declared root and no git repo, \$PWD/.context is the last rank" {
  # Reverses the old "cwd is never a fallback" contract on purpose: the ladder ends at
  # $PWD/.context so a first write in a non-git workdir lands where the caller is, rather
  # than being dropped or retargeted at another checkout's ledger. The plugin-root refusal
  # (state-patch-context-root.bats) is what stops that rank from writing into the wrong tree.
  local tmp; tmp="$(mk_tmpworkdir)"
  mkdir -p "$tmp/.context/logs"
  cp "$FIXTURES/worktask/state.sample.json" "$tmp/.context/state.json"
  cd "$tmp"

  run env -u WORKSPACE_ROOT -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR \
    GIT_CEILING_DIRECTORIES="$(dirname "$tmp")" \
    bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"files_modified":["x"]}'
  assert_success
  run jq -e '.facts.files_modified | index("x")' .context/state.json
  assert_success

  local before; before="$(shasum .context/state.json)"
  run env -u WORKSPACE_ROOT -u CLAUDE_PROJECT_DIR -u CONTEXT_DIR \
    GIT_CEILING_DIRECTORIES="$(dirname "$tmp")" \
    bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --task-id DV0
  # No artifact on disk: the stage patch either no-ops (0) or, on the documented
  # self-patch signature, refuses loudly (3); either way the ledger is untouched.
  [[ "$status" -eq 0 || "$status" -eq 3 ]] || fail "unexpected status $status: $output"
  [ "$before" = "$(shasum .context/state.json)" ]
}

@test "sweep: a stub is stored with stage and status filled, never null" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-id DV0 --facts \
    '{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false}]}'
  assert_success
  run jq -r '.facts.open_questions[-1] | .stage + "/" + .status' .context/state.json
  assert_output "DV/open"
}

@test "sweep: an incumbent carrying nulls is backfilled on the next write" {
  cd "$WD"
  jq '.facts.open_questions = [{"id":"sw-PL0-1","class":"decision",
       "ref":"planning-0.md#elicitation-sweep","stage":null,"status":null}]' \
    .context/state.json > .context/s.tmp && mv .context/s.tmp .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-id DV0 --facts \
    '{"open_questions":[{"id":"sw-DV0-1","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false}]}'
  assert_success
  run jq -r '.facts.open_questions[0] | .stage + "/" + .status' .context/state.json
  assert_output "PL/open"
}

# --- per-item --facts rejection (R-2.3) --------------------------------------

@test "facts: a mixed payload persists its valid items and rejects only the bad ones" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{
      "decisions":[{"id":"d-good","summary":"kept"},{"summary":"no id"}],
      "open_questions":[
        {"id":"sw-DV0-1","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false},
        {"id":"sw-DV0-2","class":"risk","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false}]}'
  # Non-zero, because every existing caller branches on exit status to see a rejection.
  assert_failure 2
  assert_output --partial "2 item(s) rejected, the rest still persist"
  assert_output --partial "sw-DV0-2: class is not decision|escalate"
  run jq -r '[.facts.decisions[].id] | join(",")' .context/state.json
  assert_output --partial "d-good"
  run jq -r '[.facts.open_questions[].id] | join(",")' .context/state.json
  assert_output --partial "sw-DV0-1"
  refute_output --partial "sw-DV0-2"
}

@test "facts: a payload whose every item is invalid leaves the ledger byte-unchanged" {
  cd "$WD"
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"open_questions":[{"id":"sw-DV0-1"}]}'
  assert_failure 2
  assert_output --partial "no valid items in the payload"
  run diff -q .context/state.json snap
  assert_success
}

@test "facts: a rejection prints its diagnostic instead of the usage block" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"open_questions":[{"id":"sw-DV0-1"}]}'
  assert_failure 2
  # The reproduction this fixes: ~100 lines of help scrolled the real message away.
  [ "${#lines[@]}" -le 6 ]
  refute_output --partial "@arg"
}

@test "facts: a write with no ledger fails loudly rather than exiting 0 in silence" {
  cd "$WD"
  rm -f .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"decisions":[{"id":"d-1"}]}'
  assert_failure
  assert_output --partial "landed nothing"
}

@test "facts: the no-ledger log line says the same thing as the stderr line" {
  # The two were written by hand and had drifted: stderr said "no ledger at",
  # the log said "state.json absent at". Anyone grepping the log for the text
  # the caller saw found nothing.
  cd "$WD"
  rm -f .context/state.json
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"decisions":[{"id":"d-1"}]}'
  assert_failure
  [[ "$stderr" == *"no ledger at"* ]] || fail "unexpected stderr: $stderr"
  run grep -c "no ledger at .*--facts landed nothing" .context/logs/state-merge.log
  assert_output "1"
}

# --- metadata.description cap (R-4.4) ----------------------------------------

@test "task description: over-long values are truncated, never rejected, on create and meta" {
  cd "$WD"
  local long; long="$(printf 'x%.0s' $(seq 1 400))"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-create ET0 \
    --metadata "$(_r9_meta "$(jq -nc --arg d "$long" '{stage:"ET",agent:"corpflow:ethics-reviewer",description:$d}')")"
  assert_success
  run jq -r '.tasks.ET0.metadata.description | length' .context/state.json
  assert_output "240"
  run jq -r '.tasks.ET0.metadata.agent' .context/state.json
  assert_output "corpflow:ethics-reviewer"

  run bash "$PLUGIN_ROOT/$SCRIPT" --task-meta ET0 \
    --set "$(jq -nc --arg d "$long" '{description:$d}')"
  assert_success
  run jq -r '.tasks.ET0.metadata.description | endswith("…")' .context/state.json
  assert_output "true"
}

@test "task description: a value inside the cap is stored byte-for-byte" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-create ET1 \
    --metadata "$(_r9_meta '{"stage":"ET","description":"short and unchanged"}')"
  assert_success
  run jq -r '.tasks.ET1.metadata.description' .context/state.json
  assert_output "short and unchanged"
}

@test "facts: a partial rejection beside --stage survives the idempotent no-op exit" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md > /dev/null
  # Second completion is the idempotent path — the one every rework round takes.
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md \
    --facts '{"decisions":[{"id":"d-ok"},{"summary":"no id"}]}'
  assert_failure 2
  run jq -r '[.facts.decisions[].id] | index("d-ok") != null' .context/state.json
  assert_output "true"
}

# --- Ledger-op positive paths -------------------------------------------------
# Direct coverage for --task-create/--task-block/--task-unblock/--task-status.
# Until this block existed the only guard was the script's own inline self-test,
# so a regression here could only be caught by the instrument it would break.

@test "ledger ops: create seeds pending, block unions edges, status transitions" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DV0 --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer"}')"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DV1 --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer"}')"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DR0 --metadata "$(_r9_meta '{"stage":"DR","agent":"corpflow:technical-lead"}')"
  # Twice on purpose: blocked_by is a union, so the repeat must not duplicate DV0.
  bash "$PLUGIN_ROOT/$SCRIPT" --task-block DR0 --on DV0,DV1
  bash "$PLUGIN_ROOT/$SCRIPT" --task-block DR0 --on DV0
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-status DV0 in_progress
  assert_success
  run jq -c '[.tasks.DR0.blocked_by, .tasks.DV0.status, .tasks.DV1.status]' .context/state.json
  assert_output '[["DV0","DV1"],"in_progress","pending"]'
}

@test "ledger ops: a duplicate --task-create is a no-op that never clobbers metadata" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DV0 --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer"}')"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-create DV0 --metadata "$(_r9_meta '{"clobbered":true}')"
  assert_success
  run jq -c '[.tasks.DV0.metadata.agent, (.tasks.DV0.metadata | has("clobbered"))]' .context/state.json
  assert_output '["corpflow:developer",false]'
}

@test "task-create: a bare non-PL/IR --task-create is refused for missing metadata keys" {
  cd "$WD"
  local before
  before="$(shasum .context/state.json | cut -d' ' -f1)"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-create DV0
  assert_failure 2
  assert_output --partial "metadata missing required key(s): effort,isolation,base_ref,requires_screenshots,workspace_path"
  [ "$(shasum .context/state.json | cut -d' ' -f1)" = "$before" ] \
    || fail "a refused --task-create must leave state.json byte-identical"
}

@test "task-create: bare PL0/IR0 --task-create is exempt and defaults to an empty object" {
  cd "$WD"
  jq -n '{version:2, worktask_id:"fresh", plan_file:".context/planning-0.md",
      platform:"all", run_index:0, tasks:{},
      facts:{files_modified:[],tests_added:[],decisions:[],open_questions:[],verdicts:{}},
      handoffs:{}}' > .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-create PL0
  assert_success
  run jq -c '[.tasks.PL0.status, .tasks.PL0.metadata]' .context/state.json
  assert_output '["pending",{}]'
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-create IR0
  assert_success
  run jq -c '[.tasks.IR0.status, .tasks.IR0.metadata]' .context/state.json
  assert_output '["pending",{}]'
}

@test "task-create: a DV0 row missing only base_ref is refused, naming just that key" {
  cd "$WD"
  local before
  before="$(shasum .context/state.json | cut -d' ' -f1)"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-create DV0 \
    --metadata '{"effort":"high","isolation":"worktree","requires_screenshots":false,"workspace_path":"/tmp/wt"}'
  assert_failure 2
  assert_output --partial "metadata missing required key(s): base_ref"
  [[ "$output" != *"base_ref,"* ]] || fail "named more than base_ref: $output"
  [ "$(shasum .context/state.json | cut -d' ' -f1)" = "$before" ] \
    || fail "a refused --task-create must leave state.json byte-identical"
}

@test "task-create: requires_screenshots:false counts as present, workspace_path:\"\" counts as missing" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-create DV0 \
    --metadata "$(_r9_meta '{"workspace_path":""}')"
  assert_failure 2
  assert_output --partial "metadata missing required key(s): workspace_path"
  [[ "$output" != *"requires_screenshots"* ]] || fail "requires_screenshots:false must count as present: $output"
}

@test "ledger ops: --task-unblock subtracts exactly the named edge" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DV0 --metadata "$(_r9_meta '{"stage":"DV"}')"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DV1 --metadata "$(_r9_meta '{"stage":"DV"}')"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DR0 --metadata "$(_r9_meta '{"stage":"DR"}')"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-block DR0 --on DV0,DV1
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-unblock DR0 --off DV1
  assert_success
  run jq -c '.tasks.DR0.blocked_by' .context/state.json
  assert_output '["DV0"]'
}

@test "ledger ops: --task-unblock of an edge that was never set is a no-op success" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DV0 --metadata "$(_r9_meta '{"stage":"DV"}')"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DR0 --metadata "$(_r9_meta '{"stage":"DR"}')"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-block DR0 --on DV0
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-unblock DR0 --off ST0
  assert_success
  run jq -c '.tasks.DR0.blocked_by' .context/state.json
  assert_output '["DV0"]'
}

@test "ledger ops: a malformed task id is refused before any write" {
  cd "$WD"
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-status ZZ0 pending
  assert_failure
  run diff -q .context/state.json snap
  assert_success
}

@test "ledger ops: status/block/unblock/meta on an unknown id hit the existence guard" {
  # Only --task-create may introduce a key. Every other op must refuse rather than
  # autovivify a ghost through its .tasks[\$id] assignment. The stderr match pins WHICH
  # guard fired — a bare non-zero exit would also be satisfied by a parse error.
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DV0 --metadata "$(_r9_meta '{"stage":"DV"}')"
  cp .context/state.json snap
  local op
  for op in "--task-status FN0 pending" "--task-block FN0 --on DV0" \
            "--task-unblock FN0 --off DV0" "--task-meta FN0 --set {}"; do
    # shellcheck disable=SC2086
    run bash "$PLUGIN_ROOT/$SCRIPT" $op
    assert_failure
    assert_output --partial "unknown task id"
    run diff -q .context/state.json snap
    assert_success
  done
}

# --- Ledger version guard -----------------------------------------------------

@test "version guard: an unsupported ledger version halts the ledger-op path before any write" {
  cd "$WD"
  jq '.version = 1' .context/state.json > v1.json && mv v1.json .context/state.json
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-status PL0 in_progress
  assert_failure
  run diff -q .context/state.json snap
  assert_success
}

@test "version guard: an unsupported ledger version halts the --stage path before any write" {
  cd "$WD"
  jq '.version = 1' .context/state.json > v1.json && mv v1.json .context/state.json
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md --via hook
  assert_failure
  run diff -q .context/state.json snap
  assert_success
}

# --- Hook audit row -----------------------------------------------------------

@test "audit: --via hook appends exactly one stage_transition row for the patched task" {
  cd "$WD"
  rm -f .context/logs/audit.jsonl
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md --via hook
  assert_success
  assert_audit_row stage_transition --actor "hook:state-merge" --count 1 \
    --jq '.task_id == "DV0" and .metadata.via == "hook"'
}

@test "audit: --via step6_5 appends no row (the orchestrator scrape owns that record)" {
  cd "$WD"
  rm -f .context/logs/audit.jsonl
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md --via step6_5
  assert_success
  [ ! -s .context/logs/audit.jsonl ]
}

# --- eviction spill (both rings) ----------------------------------------------
# _spill_evicted_items is the heaviest function on the --facts hot path and had no
# coverage outside the script's own self-test. run_index 3 puts the spill files at
# fixed, non-zero names so a stray run-0 file cannot satisfy these assertions.
# The questions bound is 4 PER TASK, so every seed below is one task's bucket.

# seed_questions <total> <resolved-prefix-count>
seed_questions() {
  jq -n --argjson n "$1" --argjson res "$2" '
    { version: 2, worktask_id: "spill-fixture", plan_file: ".context/planning-0.md",
      platform: "all", run_index: 3,
      tasks: { DV1: { status: "in_progress" } },
      facts: { open_questions:
        [ range(1; $n + 1) as $i
          | { id: ("sw-PL0-" + ($i | tostring)), class: "decision",
              ref: "planning-0.md#elicitation-sweep", stage: "PL",
              status: (if $i <= $res then "resolved" else "open" end) }
          + (if $i <= $res then { resolution: "answered" } else {} end) ] },
      handoffs: {} }' > .context/state.json
  rm -f .context/open-questions-3.jsonl
}

add_question() {
  bash "$PLUGIN_ROOT/$SCRIPT" --task-id DV1 --facts \
    "{\"open_questions\":[{\"id\":\"$1\",\"class\":\"decision\",\"ref\":\"development-1.md#elicitation-sweep\",\"blocks_next_stage\":false}]}"
}

@test "spill: an earlier escalate snapshot prevents a class downgrade" {
  cd "$WD"
  seed_questions 0 0
  printf '%s\n' \
    '{"id":"sw-DR0-1","class":"escalate","ref":"developer-review-0.md#elicitation-sweep"}' \
    '{"id":"sw-DR0-1","class":"decision","ref":"developer-review-0.md#elicitation-sweep"}' \
    > .context/open-questions-3.jsonl
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-id DV1 --facts \
    '{"open_questions":[{"id":"sw-DR0-1","class":"decision","ref":"development-1.md#elicitation-sweep","blocks_next_stage":false}]}'
  assert_failure 2
  assert_output --partial 'class downgrade escalate -> decision refused'
  run jq -r '[.facts.open_questions[] | select(.id == "sw-DR0-1")][0].class' .context/state.json
  assert_output escalate
}

@test "spill: class raises across a spill incumbent" {
  cd "$WD"
  seed_questions 0 0
  printf '%s\n' '{"id":"sw-DR0-2","class":"decision","ref":"developer-review-0.md#elicitation-sweep"}' \
    > .context/open-questions-3.jsonl
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-id DV1 --facts \
    '{"open_questions":[{"id":"sw-DR0-2","class":"escalate","ref":"development-1.md#elicitation-sweep","blocks_next_stage":false}]}'
  assert_success
  refute_output --partial 'class downgrade'
  run jq -r '[.facts.open_questions[] | select(.id == "sw-DR0-2")][0].class' .context/state.json
  assert_output escalate
}

@test "spill: a malformed spill refuses the facts write" {
  cd "$WD"
  seed_questions 0 0
  printf 'broken json\n' > .context/open-questions-3.jsonl
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-id DV1 --facts \
    '{"open_questions":[{"id":"sw-DR0-1","class":"decision","ref":"development-1.md#elicitation-sweep","blocks_next_stage":false}]}'
  assert_failure
  assert_output --partial 'sweep spill unreadable or malformed'
  run cmp .context/state.json snap
  assert_success
}

@test "spill: an array inside the bound writes no spill file" {
  cd "$WD"
  seed_questions 3 0
  run add_question sw-DV1-1
  assert_success
  [ ! -e .context/open-questions-3.jsonl ]
}

@test "spill: an unresolved eviction spills the full stub and leaves ledger order intact" {
  cd "$WD"
  seed_questions 5 0
  run add_question sw-DV1-1
  assert_success
  run jq -r '.id' .context/open-questions-3.jsonl
  assert_output "sw-PL0-1"
  run grep -c '^' .context/open-questions-3.jsonl
  assert_output "1"
  run jq -e '.spilled_at and .spilled_from_stage and .class and .ref and .stage and .status' \
    .context/open-questions-3.jsonl
  assert_success
  run jq -c '.facts.open_questions | map(.id)' .context/state.json
  assert_output '["sw-PL0-2","sw-PL0-3","sw-PL0-4","sw-PL0-5","sw-DV1-1"]'
}

@test "spill: a RESOLVED eviction spills too, flagged was_resolved, answer intact" {
  # Spilling only unresolved items inverted the incentive: answering a question was
  # what made it vanish without a trace.
  cd "$WD"
  seed_questions 5 2
  run add_question sw-DV1-1
  assert_success
  run jq -c '[.id, .was_resolved, .resolution]' .context/open-questions-3.jsonl
  assert_output '["sw-PL0-1",true,"answered"]'
}

@test "spill: the trigger is bound-free — a union that evicts nothing writes no line" {
  # It once fired only on a post-clamp length of exactly the bound, so the spill died
  # silently the moment the bound moved — as it has now moved twice.
  cd "$WD"
  seed_questions 4 0
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-id DV1 --facts \
    '{"open_questions":[{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}]}'
  assert_success
  [ ! -e .context/open-questions-3.jsonl ]
  run jq -r '.facts.open_questions | length' .context/state.json
  assert_output "4"
}

@test "spill: an append that FAILS warns on stderr and claims no success" {
  # Root can write through mode 0444, which would make the unwritable-path recipe assert
  # nothing; skip rather than pass vacuously.
  [ "$(id -u)" -ne 0 ] || skip "runs as root: a 0444 spill path stays writable"
  cd "$WD"
  seed_questions 5 0
  : > .context/open-questions-3.jsonl
  chmod 0444 .context/open-questions-3.jsonl
  : > .context/spill.log
  run_script_env --cwd "$WD" --separate-stderr "$SCRIPT" \
    --log .context/spill.log --task-id DV1 --facts \
    '{"open_questions":[{"id":"sw-DV1-1","class":"decision","ref":"development-1.md#elicitation-sweep","blocks_next_stage":false}]}'
  chmod 0644 .context/open-questions-3.jsonl
  assert_success
  [ ! -s .context/open-questions-3.jsonl ]
  # Captured to a file first: `run` clobbers $stderr, and a bare [[ ]] mid-body is not
  # an assertion in bats — only the body's LAST status decides the verdict.
  printf '%s' "$stderr" > stderr.cap
  run grep -F 'spill append to ' stderr.cap
  assert_success
  run grep -F 'evicted item(s) unrecorded' stderr.cap
  assert_success
  # The merge itself is unaffected, and the log must not claim a spill that never landed.
  run jq -e '(.facts.open_questions | map(.id) | index("sw-DV1-1")) != null' .context/state.json
  assert_success
  run grep -q 'spill append failed for' .context/spill.log
  assert_success
  run grep -q 'spilled 1 evicted' .context/spill.log
  assert_failure
}

# --- post-write clamp-eviction detector ---------------------------------------

@test "clamp detector: an id evicted by the clamp on its own write is named on stderr" {
  # facts.decisions[] clamps to the newest 8 of the writer's own bucket, and its spill has
  # no reader, so an id can land and be evicted by the same write. The post-write assertion
  # is what makes that visible at the call site.
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --facts "$(jq -nc '{decisions: [range(1;9) | {id: ("old-" + (.|tostring))}]}')"
  run_script_env --cwd "$WD" --separate-stderr "$SCRIPT" \
    --facts "$(jq -nc '{decisions: [range(1;10) | {id: ("new-" + (.|tostring))}]}')"
  printf '%s' "$stderr" > stderr.cap
  # Named as an EVICTION, which is a recoverable state, and not as loss: these ids are in
  # the spill and `--read-decisions` still resolves them. Asserting the distinction here is
  # the point — the message used to claim eviction for both cases.
  run grep -F 'clamp evicted these ids' stderr.cap
  assert_success
  run grep -F 'new-1' stderr.cap
  assert_success
  run grep -F 'NEITHER the ledger nor the spill' stderr.cap
  assert_failure
}

# --- parse_frontmatter: both branches ------------------------------------------
# The yq branch was unexercised anywhere: every CI host lacks yq and takes the awk
# fallback, so the two parsers could disagree indefinitely without a red test.

@test "frontmatter: the yq branch is taken when yq is on PATH and its answers land" {
  cd "$WD"
  stub_cmd yq --body '
expr="${2:-}"
case "$expr" in
  *".handoff.stage"*)           printf "DV\n" ;;
  *".handoff.verdict"*)         printf "ok\n" ;;
  *".handoff.summary"*)         printf "summary parsed by the yq branch\n" ;;
  *".handoff.worktree_path"*)   printf "null\n" ;;
  *".handoff.worktree_branch"*) printf "null\n" ;;
  *".handoff"*)                 printf "stage: DV\n" ;;
esac
exit 0'
  run_script_env --cwd "$WD" --stub-path "$SCRIPT" \
    --stage DV --prev PL --artifact .context/development-0.md
  assert_success
  [ "$(stub_log --count yq)" -gt 0 ]
  run jq -r '.handoffs["PL→DV0"]' .context/state.json
  assert_output --partial "summary parsed by the yq branch"
  # `null` from yq must not reach the ledger as a worktree record.
  run jq -r '.tasks.DV0 | has("worktree")' .context/state.json
  assert_output "false"
}

@test "frontmatter: the awk fallback parses the same artifact when yq is absent" {
  cd "$WD"
  run_script_env --cwd "$WD" --hide yq "$SCRIPT" \
    --stage DV --prev PL --artifact .context/development-0.md
  assert_success
  run jq -r '.handoffs["PL→DV0"]' .context/state.json
  assert_output --partial "DV0a fixture development artifact"
}

@test "frontmatter: the yq and awk branches agree on the same artifact" {
  # The parity that matters: two parsers, one contract. Uses the REAL yq, so it pins
  # agreement rather than agreement-with-a-stub.
  command -v yq > /dev/null 2>&1 || skip "yq not installed"
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --prev PL --artifact .context/development-0.md
  # tests_executed is excluded: the mirror is yq-only by design, and a host without yq
  # leaves it untouched rather than reading the list as gone.
  jq -c '[(.tasks.DV0 | del(.tests_executed)), .handoffs]' .context/state.json > with-yq.json
  cp "$FIXTURES/worktask/state.sample.json" .context/state.json
  run_script_env --cwd "$WD" --hide yq "$SCRIPT" \
    --stage DV --prev PL --artifact .context/development-0.md
  assert_success
  jq -c '[(.tasks.DV0 | del(.tests_executed)), .handoffs]' .context/state.json > without-yq.json
  run diff -u with-yq.json without-yq.json
  assert_success
}

# --state with no directory component. `${state%/*}` is a no-op on a bare filename,
# so atomic_apply derived "<file>/.state.json….tmp" — ENOTDIR — and every ledger op
# failed leaving the file untouched. The mirrored derivation in the spill path always
# carried the guard, which is why the two disagreed. Regression for that split.
@test "regression: a --state with no directory component still writes (atomic_apply)" {
  cd "$WD/.context"
  run bash "$PLUGIN_ROOT/$SCRIPT" --state state.json --task-create ET0 --metadata "$(_r9_meta '{"agent":"x"}')"
  assert_success
  refute_output --partial "Not a directory"
  run jq -r '.tasks.ET0.status' state.json
  assert_output "pending"
}

@test "regression: bare and ./-prefixed --state produce the same ledger" {
  cd "$WD/.context"
  cp state.json bare.json
  cp state.json dotted.json
  bash "$PLUGIN_ROOT/$SCRIPT" --state bare.json     --task-create ET0 --metadata "$(_r9_meta '{"agent":"x"}')"
  bash "$PLUGIN_ROOT/$SCRIPT" --state ./dotted.json --task-create ET0 --metadata "$(_r9_meta '{"agent":"x"}')"
  run diff <(jq -S . bare.json) <(jq -S . dotted.json)
  assert_success
}

# ---------------------------------------------------------------------------
# --ledger-meta — the top-level metadata writer. Before it existed the only way
# to set .metadata.base_ref was to hand-edit state.json around the single writer,
# and an unresolved base_ref falls through to origin/HEAD — the wrong-base PR the
# base-sanity check exists to catch.
# ---------------------------------------------------------------------------
@test "ledger meta: --set merges into top-level metadata without dropping siblings" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --ledger-meta --set '{"milestone":"7"}'
  assert_success
  run bash "$PLUGIN_ROOT/$SCRIPT" --ledger-meta --set '{"base_ref":"refs/heads/parent"}'
  assert_success
  run jq -r '.metadata.milestone + "|" + .metadata.base_ref' .context/state.json
  assert_output "7|refs/heads/parent"
}

@test "ledger meta: resolve_base_ref reads what --ledger-meta wrote" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --ledger-meta --set '{"base_ref":"develop"}'
  assert_success
  run bash -c ". '$PLUGIN_ROOT/skills/worktask/scripts/branch-lib.sh'; \
    STATE_PATH=.context/state.json resolve_base_ref"
  assert_success
  assert_output --partial "develop"
}

@test "ledger meta: a non-object --set is refused and state.json is byte-identical" {
  cd "$WD"
  local before; before="$(md5 -q .context/state.json 2>/dev/null || md5sum .context/state.json)"
  run bash "$PLUGIN_ROOT/$SCRIPT" --ledger-meta --set '"develop"'
  assert_failure 1
  assert_output --partial "must be a JSON object"
  local after; after="$(md5 -q .context/state.json 2>/dev/null || md5sum .context/state.json)"
  [ "$before" = "$after" ]
}

@test "ledger meta: --set is required" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --ledger-meta
  assert_failure 2
  assert_output --partial "requires --set"
}

@test "ledger meta: combining it with a task op is refused, not silently half-applied" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --ledger-meta --set '{"a":"1"}' --task-status DV0 completed
  assert_failure 2
  assert_output --partial "separate writes"
  run jq -r '.metadata.a // "absent"' .context/state.json
  assert_output "absent"
}

@test "ledger meta: no ledger at --state writes nothing and says so" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --state .context/absent.json --ledger-meta --set '{"a":"1"}'
  assert_failure 1
  assert_output --partial "existing ledger only"
  [ ! -e .context/absent.json ]
}

# --- Symlink refusal on the two direct audit appends ---------------------------
#
# state-patch.sh writes audit.jsonl directly at two sites — the --via hook
# stage_transition row and replay_audit's stage_replay row — rather than through
# audit-lib.sh. Both must refuse a symlinked log, and neither refusal may undo
# the ledger write it accompanies: the row is best-effort, the patch is not.

@test "SR: --via hook refuses a symlinked audit.jsonl and still patches the ledger" {
  cd "$WD"
  rm -f .context/logs/audit.jsonl
  mkdir -p target-dir .context/logs
  ln -s "$WD/target-dir/escaped.txt" .context/logs/audit.jsonl
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md --via hook
  assert_success
  [ ! -e "$WD/target-dir/escaped.txt" ]
  run jq -r '.tasks.DV0.completed_via' .context/state.json
  assert_output "hook"
}

@test "SR: --task-replay refuses a symlinked audit.jsonl and still applies the reset" {
  local w; w="$(mk_replay_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  mkdir -p "$w/target-dir"
  ln -s "$w/target-dir/escaped.txt" "$w/.context/logs/audit.jsonl"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV1 --agents-json "$w/gone.json"
  assert_success
  [ ! -e "$w/target-dir/escaped.txt" ]
  run jq -r '.tasks.DV1.status' "$w/.context/state.json"
  assert_output "pending"
}

# --- metadata.effort enum gate -----------------------------------------------
#
# metadata.effort became a mandatory ledger field when the Step C.0a resolver started
# reading it (commands/worktask.md § Step C.0a). It is validated at the write because an
# off-ladder value is otherwise invisible until a resolver dispatch fails a stage later.
# The enum lives in effort-ladder.sh; this suite asserts the gate, not a second copy of it.

@test "task-create accepts every tier on the ladder" {
  cd "$WD"
  . "$PLUGIN_ROOT/skills/worktask/scripts/effort-ladder.sh"
  i=0
  for tier in $EFFORT_ENUM; do
    run bash "$PLUGIN_ROOT/$SCRIPT" --task-create "QA$i" \
      --metadata "$(_r9_meta "$(jq -cn --arg t "$tier" '{stage:"QA",model:"sonnet",effort:$t}')")"
    assert_success
    run jq -r ".tasks.QA$i.metadata.effort" .context/state.json
    assert_output "$tier"
    i=$((i + 1))
  done
}

@test "task-create refuses an effort that is not on the ladder" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-create AR9 \
    --metadata "$(_r9_meta '{"stage":"AR","model":"opus","effort":"ultra"}')"
  assert_failure 2
  assert_output --partial "invalid effort: ultra"
  # The refusal must leave nothing behind, or a retry hits the idempotent-create short-circuit.
  run jq -r '.tasks | has("AR9")' .context/state.json
  assert_output "false"
}

@test "task-meta refuses an off-ladder effort and leaves the row untouched" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DR9 \
    --metadata "$(_r9_meta '{"stage":"DR","model":"opus","effort":"high"}')"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-meta DR9 --set '{"effort":"turbo"}'
  assert_failure 2
  assert_output --partial "invalid effort: turbo"
  run jq -r '.tasks.DR9.metadata.effort' .context/state.json
  assert_output "high"
}

@test "task-meta refuses a null or false effort rather than reading it as absent" {
  # `.effort // empty` treated both as a missing key, which let a required field be erased.
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DR8 \
    --metadata "$(_r9_meta '{"stage":"DR","model":"opus","effort":"high"}')"
  for bad in null false; do
    run bash "$PLUGIN_ROOT/$SCRIPT" --task-meta DR8 --set "{\"effort\":$bad}"
    assert_failure 2
    assert_output --partial "invalid effort: $bad"
  done
  run jq -r '.tasks.DR8.metadata.effort' .context/state.json
  assert_output "high"
}

@test "a metadata write without an effort key is unaffected by the gate" {
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create SR9 --metadata "$(_r9_meta '{"stage":"SR","model":"opus"}')"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-meta SR9 --set '{"model":"sonnet"}'
  assert_success
  run jq -r '.tasks.SR9.metadata.model' .context/state.json
  assert_output "sonnet"
}

@test "the effort gate does not fire on the non-metadata task ops" {
  # --task-status/--task-block parse --set globally; the gate must not reach them.
  cd "$WD"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DC9 \
    --metadata "$(_r9_meta '{"stage":"DC","model":"haiku","effort":"low"}')"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-status DC9 completed
  assert_success
  run jq -r '.tasks.DC9.status' .context/state.json
  assert_output "completed"
}

@test "the resolver's own bump of a stamped effort is a value the gate accepts" {
  # Closes the loop: whatever effort_for_resolver returns must survive being written back.
  cd "$WD"
  . "$PLUGIN_ROOT/skills/worktask/scripts/effort-ladder.sh"
  bumped=$(effort_for_resolver high opus)
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-create DV9 \
    --metadata "$(_r9_meta "$(jq -cn --arg e "$bumped" '{stage:"DV",model:"opus",effort:$e}')")"
  assert_success
  run jq -r '.tasks.DV9.metadata.effort' .context/state.json
  assert_output "xhigh"
}

# ---------------------------------------------------------------------------
# Per-task clamp partitioning, the decision spill, and the task-keyed edge.
# The defect: one prolific task evicted every other task's items from a global
# ring, and a fan-out collapsed to one last-writer-wins handoff entry.
# ---------------------------------------------------------------------------

@test "bounds: four tasks' questions survive each other — newest 4 per task, not 4 in total" {
  cd "$WD"
  mk_multitask_ledger .context/state.json --run-index 0 \
    --task PL0:6:0 --task AR0:5:0 --task TL0:4:0 --task DV1:7:0 > /dev/null
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-id DV1 --facts \
    '{"open_questions":[{"id":"sw-DV1-8","class":"decision","ref":"development-1.md#elicitation-sweep","blocks_next_stage":false}]}'
  assert_success
  # Every task keeps its own newest four, in the array's original order; the writing task's
  # eight-item bucket does not touch anyone else's.
  run jq -c '[.facts.open_questions[].id]' .context/state.json
  assert_output '["sw-PL0-3","sw-PL0-4","sw-PL0-5","sw-PL0-6","sw-AR0-2","sw-AR0-3","sw-AR0-4","sw-AR0-5","sw-TL0-1","sw-TL0-2","sw-TL0-3","sw-TL0-4","sw-DV1-5","sw-DV1-6","sw-DV1-7","sw-DV1-8"]'
}

@test "bounds: resolved-evicted-first is per bucket — one task's answers cannot shield another's" {
  cd "$WD"
  # PL0 holds four resolved and one open; DV1 holds five open. Under a GLOBAL resolved-first
  # pass PL0's answered items would be evicted to make room for DV1's, coupling the two.
  mk_multitask_ledger .context/state.json --run-index 0 \
    --task PL0:5:0:4 --task DV1:5:0 > /dev/null
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-id DV1 --facts \
    '{"open_questions":[{"id":"sw-DV1-6","class":"decision","ref":"development-1.md#elicitation-sweep","blocks_next_stage":false}]}'
  assert_success
  # PL0 keeps its one open item plus its newest three answers; DV1 keeps its newest four open.
  run jq -c '[.facts.open_questions[] | select(.id | startswith("sw-PL0")) | [.id, .status]]' \
    .context/state.json
  assert_output '[["sw-PL0-2","resolved"],["sw-PL0-3","resolved"],["sw-PL0-4","resolved"],["sw-PL0-5","open"]]'
  run jq -c '[.facts.open_questions[] | select(.id | startswith("sw-DV1")) | .id]' .context/state.json
  assert_output '["sw-DV1-3","sw-DV1-4","sw-DV1-5","sw-DV1-6"]'
}

@test "bounds: four tasks' decisions survive each other — newest 8 per task" {
  cd "$WD"
  mk_multitask_ledger .context/state.json --run-index 0 \
    --task PL0:0:9 --task AR0:0:10 --task DV0:0:8 --task DV1:0:3 > /dev/null
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-id DV1 --facts \
    '{"decisions":[{"id":"dv1-4","summary":"newest","ref":"development-1.md#approach"}]}'
  assert_success
  run jq -c '[.facts.decisions[].stage] | group_by(.) | map({(.[0]): length}) | add' \
    .context/state.json
  assert_output '{"AR0":8,"DV0":8,"DV1":4,"PL0":8}'
  # The writer stamps its own task id on the incoming item and on nothing else.
  run jq -r '[.facts.decisions[] | select(.id == "dv1-4") | .stage] | .[0]' .context/state.json
  assert_output "DV1"
  run jq -r '[.facts.decisions[] | select(.id == "pl0-1")] | length' .context/state.json
  assert_output "0"
  run jq -r '[.facts.decisions[] | select(.id == "pl0-2")] | length' .context/state.json
  assert_output "1"
}

@test "bounds: the stamp defaults only the INCOMING array — incumbents keep their author" {
  cd "$WD"
  # Defaulting the union instead would re-attribute PL0's decisions to whoever writes next.
  mk_multitask_ledger .context/state.json --run-index 0 --task PL0:0:2 > /dev/null
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-id AR0 --facts \
    '{"decisions":[{"id":"ar0-1","summary":"arch","ref":"architecture-0.md#decisions"}]}'
  assert_success
  run jq -c '[.facts.decisions[] | [.id, .stage]]' .context/state.json
  assert_output '[["pl0-1","PL0"],["pl0-2","PL0"],["ar0-1","AR0"]]'
}

@test "spill: a decision the clamp evicts is written to decisions-<n>.jsonl" {
  cd "$WD"
  mk_multitask_ledger .context/state.json --run-index 3 --task DV1:0:8 > /dev/null
  rm -f .context/decisions-3.jsonl
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-id DV1 --facts \
    '{"decisions":[{"id":"dv1-9","summary":"newest","ref":"development-1.md#approach"}]}'
  assert_success
  run jq -r '.id' .context/decisions-3.jsonl
  assert_output "dv1-1"
  # was_resolved is sweep-only: a decision carries no resolution status to flag.
  run jq -e '.spilled_at and .spilled_from_stage and ((has("was_resolved")) | not)' \
    .context/decisions-3.jsonl
  assert_success
  # The questions ring is untouched by the decisions spill.
  [ ! -e .context/open-questions-3.jsonl ]
}

@test "sweep warning: an artifact id the ledger does not hold is named at THIS write" {
  cd "$WD"
  cat > .context/development-0.md << 'ARTEOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "artifact declares a sweep id the ledger never received"
  open_questions:
    - { id: sw-DV0-9, class: decision, ref: "development-0.md#elicitation-sweep", blocks_next_stage: false }
  refs: { dev: development.md#files-changed }
---
ARTEOF
  run_script_env --cwd "$WD" --separate-stderr "$SCRIPT" \
    --stage DV --prev TL --artifact .context/development-0.md
  # A warning never moves the exit code: every `set -e` caller depends on that.
  assert_success
  printf '%s' "$stderr" > stderr.cap
  run grep -F 'sw-DV0-9' stderr.cap
  assert_success
  run grep -F 'the ledger does not hold' stderr.cap
  assert_success
  run jq -r '.tasks.DV0.status' .context/state.json
  assert_output "completed"
}

@test "sweep warning: the same call carrying --facts for that id must NOT warn" {
  cd "$WD"
  # The check runs AFTER the merge against the WRITTEN state; comparing before the write
  # would false-warn on every correct combined invocation.
  cat > .context/development-0.md << 'ARTEOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "artifact and ledger agree inside one call"
  open_questions:
    - { id: sw-DV0-9, class: decision, ref: "development-0.md#elicitation-sweep", blocks_next_stage: false }
  refs: { dev: development.md#files-changed }
---
ARTEOF
  run_script_env --cwd "$WD" --separate-stderr "$SCRIPT" \
    --stage DV --prev TL --artifact .context/development-0.md --facts \
    '{"open_questions":[{"id":"sw-DV0-9","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false}]}'
  assert_success
  printf '%s' "$stderr" > stderr.cap
  run grep -F 'the ledger does not hold' stderr.cap
  assert_failure
}

@test "sweep warning: an id the clamp evicted to the spill is recorded, not lost — no warning" {
  cd "$WD"
  # The record is ledger ∪ spill, the same union check_sweep_ledger and the FN gate read.
  cat > .context/development-0.md << 'ARTEOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "artifact declares an id that lives only in the eviction spill"
  open_questions:
    - { id: sw-DV0-9, class: decision, ref: "development-0.md#elicitation-sweep", blocks_next_stage: false }
  refs: { dev: development.md#files-changed }
---
ARTEOF
  printf '%s\n' '{"id":"sw-DV0-9","class":"decision","ref":"development-0.md#elicitation-sweep","blocks_next_stage":false,"spilled_at":"2026-09-08T00:00:00Z","spilled_from_stage":"DV"}' \
    > .context/open-questions-0.jsonl
  run_script_env --cwd "$WD" --separate-stderr "$SCRIPT" \
    --stage DV --prev TL --artifact .context/development-0.md
  assert_success
  printf '%s' "$stderr" > stderr.cap
  run grep -F 'the ledger does not hold' stderr.cap
  assert_failure
}

@test "facts: a rejection is named on stdout as well as stderr, remainder still persists" {
  cd "$WD"
  # An agent branching on the exit code alone, or whose harness swallows stderr, used to ship
  # a stage one sweep item short and discover it a boundary later.
  run_script_env --cwd "$WD" --separate-stderr "$SCRIPT" --facts \
    '{"open_questions":[{"id":"sw-PL0-1","class":"decision","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false},{"id":"sw-PL0-2","class":"risk","ref":"planning-0.md#elicitation-sweep","blocks_next_stage":false}]}'
  [ "$status" -eq 2 ]
  printf '%s' "$output" > stdout.cap
  printf '%s' "$stderr" > stderr.cap
  run grep -F 'sw-PL0-2' stdout.cap
  assert_success
  run grep -F 'sw-PL0-2' stderr.cap
  assert_success
  # One message per stream — not doubled in a caller that merges them.
  run grep -c 'item(s) rejected' stdout.cap
  assert_output "1"
  run jq -c '[.facts.open_questions[].id]' .context/state.json
  assert_output '["sw-PL0-1"]'
}

@test "prev: a four-way DV split writes four distinct edges, none overwriting another" {
  cd "$WD"
  jq '.tasks = {PL0:{status:"completed",verdict:"ok"}, TL0:{status:"completed",verdict:"ok"},
                DV0:{status:"in_progress"}, DV1:{status:"in_progress"},
                DV2:{status:"in_progress"}, DV3:{status:"in_progress"}}' \
    .context/state.json > s.tmp && mv s.tmp .context/state.json
  for i in 0 1 2 3; do
    cat > ".context/development-$i.md" << ARTEOF
---
handoff:
  stage: DV
  verdict: ok
  summary: "stream $i landed"
  refs: { dev: development.md#files-changed }
---
ARTEOF
    run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --task-id "DV$i" --prev TL \
      --artifact ".context/development-$i.md"
    assert_success
  done
  run jq -c '.handoffs | keys' .context/state.json
  assert_output '["TL→DV0","TL→DV1","TL→DV2","TL→DV3"]'
  run jq -r '.handoffs["TL→DV2"]' .context/state.json
  assert_output --partial "stream 2 landed"
  run jq -r '.handoffs["TL→DV0"]' .context/state.json
  assert_output --partial "stream 0 landed"
}

@test "prev: a re-run of one split instance stays idempotent under the task-keyed edge" {
  cd "$WD"
  jq '.tasks = {TL0:{status:"completed",verdict:"ok"}, DV1:{status:"in_progress"}}' \
    .context/state.json > s.tmp && mv s.tmp .context/state.json
  bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --task-id DV1 --prev TL \
    --artifact .context/development-0.md
  cp .context/state.json snap
  bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --task-id DV1 --prev TL \
    --artifact .context/development-0.md
  run diff -q .context/state.json snap
  assert_success
}

# ---------------------------------------------------------------------------
# R4a/R4b — the lock owner token and its two audit rows. Extends the five lock
# tests above; same env-knob determinism, no sleep-races.
#
# The observation point is a `sync` shim: atomic_apply calls sync INSIDE the
# lock, just before the rename and the release, which is the only window where
# the lock dir of a SUCCESSFUL run is observable from outside the process.
# ---------------------------------------------------------------------------

_mk_sync_shim() { # <shim-body>
  mkdir -p "$WD/binshim"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$1"
    printf 'exit 0\n'
  } > "$WD/binshim/sync"
  chmod +x "$WD/binshim/sync"
}

@test "lock: the claim writes a pid:nonce:epoch owner token and removes it on a clean release" {
  cd "$WD"
  _mk_sync_shim 'cp .context/state.json.lock.d/owner owner.seen 2>/dev/null || true'
  PATH="$WD/binshim:$PATH" run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV \
    --artifact .context/development-0.md
  assert_success
  [ -f owner.seen ] || fail "no owner token was written inside the lock window"
  run cat owner.seen
  [[ "$output" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || fail "token shape: $output"
  mv owner.seen owner.first
  # PID is reusable; the nonce is what makes two claims distinguishable, so a second
  # claim — here a --facts write, which cannot be short-circuited as idempotent —
  # must not produce the same token.
  PATH="$WD/binshim:$PATH" run bash "$PLUGIN_ROOT/$SCRIPT" --state .context/state.json \
    --facts '{"decisions":[{"id":"lk1","summary":"second claim","stage":"AR0"}]}'
  assert_success
  [ -f owner.seen ] || fail "the second claim wrote no token"
  run diff -q owner.first owner.seen
  assert_failure
  [ ! -d .context/state.json.lock.d ] || fail "clean release leaked the lock dir"
}

@test "lock: a successor's token is NOT removed by this writer's release (AC-G4)" {
  cd "$WD"
  # The defect sequence without a second process: a stale-break handing the lock to
  # writer B is, from A's side, exactly B's token replacing A's inside A's window.
  _mk_sync_shim 'printf "%s\n" "999999:deadbeef:1" > .context/state.json.lock.d/owner'
  PATH="$WD/binshim:$PATH" run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV \
    --artifact .context/development-0.md --log .context/logs/lock.log
  # The patch itself succeeded; refusing the removal must not invert that verdict.
  assert_success
  run jq -r '.tasks.DV0.status' .context/state.json
  assert_output "completed"
  [ -d .context/state.json.lock.d ] || fail "the successor's lock was removed"
  run cat .context/state.json.lock.d/owner
  assert_output "999999:deadbeef:1"
  run grep -c 'lock owner mismatch on release' .context/logs/lock.log
  assert_output "1"
  run jq -r 'select(.action=="lock_release_foreign") | [.result, .metadata.found] | @tsv' \
    .context/logs/audit.jsonl
  assert_output "$(printf 'degraded\t999999:deadbeef:1')"
}

@test "lock: an owner token that vanished mid-window is a mismatch, not a licence to remove" {
  cd "$WD"
  _mk_sync_shim 'rm -f .context/state.json.lock.d/owner'
  PATH="$WD/binshim:$PATH" run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV \
    --artifact .context/development-0.md --log .context/logs/lock.log
  assert_success
  [ -d .context/state.json.lock.d ] || fail "an ownerless lock dir was removed anyway"
  run jq -r 'select(.action=="lock_release_foreign") | .metadata.found' .context/logs/audit.jsonl
  assert_output "none"
}

@test "lock: the timeout's unlocked write emits a state_write_unlocked audit row (R4b)" {
  cd "$WD"
  mkdir .context/state.json.lock.d
  STATE_LOCK_TIMEOUT_S=1 STATE_LOCK_STALE_S=99999 \
    run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md \
    --log .context/logs/lock.log
  assert_success
  run grep -c 'proceeding UNLOCKED' .context/logs/lock.log
  assert_output "1"
  [ -f .context/logs/audit.jsonl ] || fail "the unlocked write left no audit row"
  run jq -r 'select(.action=="state_write_unlocked")
             | [.result, .metadata.reason, .metadata.waited_s] | @tsv' \
    .context/logs/audit.jsonl
  assert_output "$(printf 'degraded\ttimeout\t1')"
}

@test "lock: the acquire result is consumed, never discarded (R4b source guard)" {
  # The one-line defect: `|| true` made an unserialized write indistinguishable from
  # a clean one. A re-introduction is a source-level regression with no runtime shape
  # of its own, so it is pinned here rather than behaviourally.
  run grep -c '_lock_acquire "$state" || true' "$PLUGIN_ROOT/$SCRIPT"
  assert_failure
  run grep -c 'if ! _lock_acquire "$state"; then' "$PLUGIN_ROOT/$SCRIPT"
  assert_output "1"
}

# --- SR P3-1/P3-2: the claim's write-failure handback -----------------------------------
#
# The handback ran `rm -rf` with no ownership test, so a stale-break landing inside the
# window had this process delete a successor's LIVE lock. The shim plants the successor's
# token and makes it unwritable, which is the failed-write case from this process's side.

_mk_mkdir_shim() { # <post-mkdir-body>
  mkdir -p "$WD/binshim"
  {
    printf '#!/usr/bin/env bash\n'
    printf '/bin/mkdir "$@" || exit $?\n'
    printf 'for a in "$@"; do case "$a" in *.lock.d)\n'
    printf '%s\n' "$1"
    printf ';; esac; done\nexit 0\n'
  } > "$WD/binshim/mkdir"
  chmod +x "$WD/binshim/mkdir"
}

@test "lock: a failed owner write does NOT remove a lock this process cannot claim (P3-1)" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores the mode bits this shim relies on"
  cd "$WD"
  _mk_mkdir_shim 'printf "999999:deadbeef:1\n" > "$a/owner"; chmod 444 "$a/owner"'
  PATH="$WD/binshim:$PATH" STATE_LOCK_TIMEOUT_S=1 STATE_LOCK_STALE_S=99999 \
    run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md \
    --log .context/logs/lock.log
  # The patch still lands — unlocked, warned about, never silently dropped.
  assert_success
  run jq -r '.tasks.DV0.status' .context/state.json
  assert_output "completed"
  [ -d .context/state.json.lock.d ] || fail "the foreign lock dir was removed by the handback"
  run cat .context/state.json.lock.d/owner
  assert_output "999999:deadbeef:1"
}

@test "lock: a failed owner write hands the directory back, never wedges it (P3-1)" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores the mode bits this shim relies on"
  cd "$WD"
  # One-shot: the first claim finds an unwritable EMPTY owner — the disk-full shape, where
  # the file was created and the content never landed. rmdir alone refuses a non-empty
  # directory, so this process would wedge behind its own dead lock for a full stale cycle.
  _mk_mkdir_shim "[ -e '$WD/.planted' ] || { : > \"\$a/owner\"; chmod 444 \"\$a/owner\"; : > '$WD/.planted'; }"
  PATH="$WD/binshim:$PATH" STATE_LOCK_TIMEOUT_S=2 STATE_LOCK_STALE_S=99999 \
    run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --artifact .context/development-0.md \
    --log .context/logs/lock.log
  assert_success
  run jq -r '.tasks.DV0.status' .context/state.json
  assert_output "completed"
  # The retry claimed the lock for real, so the write was serialized, not degraded.
  run grep -c 'proceeding UNLOCKED' .context/logs/lock.log
  assert_failure
  [ ! -d .context/state.json.lock.d ] || fail "the handback leaked a lock dir nobody owns"
  run grep -c 'lock owner token unwritable' .context/logs/lock.log
  assert_output "1"
}

@test "lock: an oversized owner is bounded before it reaches the audit row (P3-2)" {
  cd "$WD"
  # An unbounded value inflates one row past the size at which the unlocked >> to
  # audit.jsonl is still atomic — the only condition under which the evidence log
  # this worktask protects can interleave.
  _mk_sync_shim 'head -c 5000 < /dev/zero | tr "\0" "A" > .context/state.json.lock.d/owner'
  PATH="$WD/binshim:$PATH" run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV \
    --artifact .context/development-0.md --log .context/logs/lock.log
  assert_success
  run jq -r 'select(.action=="lock_release_foreign") | .metadata.found | length' \
    .context/logs/audit.jsonl
  assert_output "256"
  [ -d .context/state.json.lock.d ] || fail "the foreign lock was removed"
}

# --- facts.stream_branches: object keyed by stream, union by key ---------------------------

@test "facts: stream_branches unions by stream key and leaves facts.branch byte-equal" {
  cd "$WD"
  jq '.facts.branch = "feature/398-combined"' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"stream_branches":{"service":"feature/s-service"}}'
  assert_success
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"stream_branches":{"web":"feature/s-web"}}'
  assert_success
  run jq -c '.facts.stream_branches' .context/state.json
  assert_output '{"service":"feature/s-service","web":"feature/s-web"}'
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"stream_branches":{"web":"feature/s-web-2"}}'
  assert_success
  run jq -c '.facts.stream_branches' .context/state.json
  assert_output '{"service":"feature/s-service","web":"feature/s-web-2"}'
  run jq -r '.facts.branch' .context/state.json
  assert_output "feature/398-combined"
}

@test "facts: a bad stream_branches key or value exits 2 with the ledger byte-unchanged" {
  cd "$WD"
  cp .context/state.json snap
  local payload
  for payload in '{"stream_branches":{"web":"bad branch"}}' \
                 '{"stream_branches":{"Web":"feature/x"}}' \
                 '{"stream_branches":{"web":7}}' \
                 '{"stream_branches":["feature/x"]}' \
                 '{"files_modified":["a.sh"],"stream_branches":{"web":"-x y"}}'; do
    run bash "$PLUGIN_ROOT/$SCRIPT" --facts "$payload"
    assert_failure 2
    assert_output --partial "invalid stream_branches"
    run cmp -s .context/state.json snap
    assert_success
  done
}

@test "facts: an empty stream_branches object is a no-op" {
  cd "$WD"
  cp .context/state.json snap
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"stream_branches":{}}'
  assert_success
  run cmp -s .context/state.json snap
  assert_success
}

# ---------------------------------------------------------------------------
# tests_executed mirror and rework_runs. The row mirrors the current artifact's list; a
# --task-replay marks a row holding evidence, and the next completion merge files the
# prior list as a new round before overwriting the mirror. Needs the real yq: the list is
# read only on the yq branch.
# ---------------------------------------------------------------------------

# _te_round <count> — the DV0 artifact for one round, one bats entry.
_te_round() {
  printf -- '---\nhandoff:\n  stage: DV\n  verdict: ok\n  summary: "round with %s"\n  tests_executed:\n    - { runner: bats, count: %s, summary_line: "1..%s" }\n  test_suite_compiles: true\n---\n\n1..%s\n' \
    "$1" "$1" "$1" "$1" > .context/development-0.md
}

# _te_seed — a DV0 row the replay guard accepts, with no agent alive.
_te_seed() {
  printf '%s\n' '[]' > gone.json
  bash "$PLUGIN_ROOT/$SCRIPT" --task-create DV0 \
    --metadata "$(_r9_meta '{"stage":"DV","agent":"corpflow:developer"}')" > /dev/null
}

_te_merge() {
  bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --task-id DV0 --artifact .context/development-0.md
}

@test "tests_executed: the completion merge mirrors the artifact list onto the task row" {
  command -v yq > /dev/null 2>&1 || skip "yq not installed"
  cd "$WD"
  _te_seed
  _te_round 12
  run _te_merge
  assert_success
  run jq -c '.tasks.DV0.tests_executed' .context/state.json
  assert_output '[{"runner":"bats","count":12,"summary_line":"1..12"}]'
  run jq -r '.tasks.DV0 | [has("rework_runs"), has("rework_pending")] | @csv' .context/state.json
  assert_output "false,false"
}

@test "tests_executed: a replay marks only a row that holds evidence" {
  command -v yq > /dev/null 2>&1 || skip "yq not installed"
  cd "$WD"
  _te_seed
  # A row without tests_executed resets exactly as it did before the marker existed.
  bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV0 --agents-json gone.json > /dev/null
  run jq -r '.tasks.DV0 | has("rework_pending")' .context/state.json
  assert_output "false"

  _te_round 12
  _te_merge > /dev/null
  bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV0 --agents-json gone.json > /dev/null
  run jq -r '.tasks.DV0.rework_pending' .context/state.json
  assert_output "true"
}

@test "rework_runs: round 2 files round 1, a re-merge is a no-op, round 3 keeps round 1 byte-identical" {
  command -v yq > /dev/null 2>&1 || skip "yq not installed"
  cd "$WD"
  local l1='[{"runner":"bats","count":12,"summary_line":"1..12"}]'
  local l2='[{"runner":"bats","count":14,"summary_line":"1..14"}]'
  local l3='[{"runner":"bats","count":16,"summary_line":"1..16"}]'
  _te_seed

  _te_round 12
  _te_merge > /dev/null
  bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV0 --agents-json gone.json > /dev/null
  _te_round 14
  run _te_merge
  assert_success
  run jq -c '.tasks.DV0.tests_executed' .context/state.json
  assert_output "$l2"
  run jq -c '.tasks.DV0.rework_runs' .context/state.json
  assert_output "[{\"round\":1,\"tests_executed\":$l1}]"
  run jq -r '.tasks.DV0 | has("rework_pending")' .context/state.json
  assert_output "false"

  # Idempotent: the same round-two artifact merged again finds no marker and appends nothing.
  cp .context/state.json snap-r2
  run _te_merge
  assert_success
  cmp -s .context/state.json snap-r2 || fail "re-merge mutated state.json
$(diff snap-r2 .context/state.json || true)"

  local round1_before
  round1_before="$(jq -c '.tasks.DV0.rework_runs[0]' .context/state.json)"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV0 --agents-json gone.json > /dev/null
  _te_round 16
  run _te_merge
  assert_success
  run jq -c '.tasks.DV0.rework_runs[0]' .context/state.json
  assert_output "$round1_before"
  run jq -c '.tasks.DV0.rework_runs' .context/state.json
  assert_output "[{\"round\":1,\"tests_executed\":$l1},{\"round\":2,\"tests_executed\":$l2}]"
  run jq -c '.tasks.DV0.tests_executed' .context/state.json
  assert_output "$l3"
}

@test "tests_executed: an artifact without a list drops the mirror; a replayed round is still filed" {
  command -v yq > /dev/null 2>&1 || skip "yq not installed"
  cd "$WD"
  _te_seed
  _te_round 12
  _te_merge > /dev/null
  bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV0 --agents-json gone.json > /dev/null
  printf -- '---\nhandoff:\n  stage: DV\n  verdict: ok\n  summary: "no list"\n---\n' \
    > .context/development-0.md
  run _te_merge
  assert_success
  run jq -c '.tasks.DV0 | [has("tests_executed"), has("rework_pending"), (.rework_runs | length)]' \
    .context/state.json
  assert_output '[false,false,1]'
}

# Both cases below keep artifact name, verdict and summary fixed, so the tests_executed
# comparison is the only field that can make the merge a non-no-op. gate_from_stage is empty
# on a completed row: a separator that collapses empty fields would hide the change.
_te_same_summary() {  # [count] — no count writes an artifact with no list
  if [[ -n "${1:-}" ]]; then
    printf -- '---\nhandoff:\n  stage: DV\n  verdict: ok\n  summary: "fixed summary"\n  tests_executed:\n    - { runner: bats, count: %s, summary_line: "1..%s" }\n  test_suite_compiles: true\n---\n\n1..%s\n' \
      "$1" "$1" "$1" > .context/development-0.md
  else
    printf -- '---\nhandoff:\n  stage: DV\n  verdict: ok\n  summary: "fixed summary"\n---\n' \
      > .context/development-0.md
  fi
}

@test "tests_executed: a changed list under the same artifact and verdict re-merges onto the row" {
  command -v yq > /dev/null 2>&1 || skip "yq not installed"
  cd "$WD"
  _te_seed
  _te_same_summary 12
  _te_merge > /dev/null
  run jq -r '.tasks.DV0 | [.status, .verdict, (.metadata.gate_from_stage // "")] | @csv' \
    .context/state.json
  assert_output '"completed","ok",""'

  _te_same_summary 14
  run _te_merge
  assert_success
  run jq -c '.tasks.DV0.tests_executed' .context/state.json
  assert_output '[{"runner":"bats","count":14,"summary_line":"1..14"}]'
  # No replay happened, so the corrected list replaces the mirror and files no round.
  run jq -r '.tasks.DV0 | [has("rework_runs"), has("rework_pending")] | @csv' .context/state.json
  assert_output "false,false"
}

@test "tests_executed: a row holding a list re-merged from an artifact with no list drops the mirror" {
  command -v yq > /dev/null 2>&1 || skip "yq not installed"
  cd "$WD"
  _te_seed
  _te_same_summary 12
  _te_merge > /dev/null
  run jq -r '.tasks.DV0 | has("tests_executed")' .context/state.json
  assert_output "true"

  _te_same_summary
  run _te_merge
  assert_success
  run jq -c '.tasks.DV0 | [has("tests_executed"), has("rework_runs"), .status, .verdict]' \
    .context/state.json
  assert_output '[false,false,"completed","ok"]'
}

@test "tests_executed: without yq the mirror and the rework marker are left untouched" {
  command -v yq > /dev/null 2>&1 || skip "yq not installed"
  cd "$WD"
  _te_seed
  _te_round 12
  _te_merge > /dev/null
  bash "$PLUGIN_ROOT/$SCRIPT" --task-replay DV0 --agents-json gone.json > /dev/null
  _te_round 14
  run_script_env --cwd "$WD" --hide yq "$SCRIPT" \
    --stage DV --task-id DV0 --artifact .context/development-0.md
  assert_success
  # An unreadable list is not an absent one: the round waits for a merge that can read it.
  run jq -c '.tasks.DV0 | [.tests_executed[0].count, .rework_pending, has("rework_runs")]' \
    .context/state.json
  assert_output '[12,true,false]'
}

# ---------------------------------------------------------------------------
# --task-reopen / --task-settle-stale — the correction ops.
# Mirrors the selftest's T-reopen-1/-2 and T-settle-1. As with --task-replay, the
# load-bearing half is the refusals: the op's idempotence IS its `completed`
# guard, so a retried correction that wrote anything before refusing would bump
# fix_round twice. Every guard case asserts a byte-identical ledger.
# ---------------------------------------------------------------------------

# mk_reopen_wd — the multistage chain PL0→DV0→DR0→QA0→FN0→RE0→ST0 plus a DC0
# source row, the target's artifact on disk (files_touched drives the settle
# change set) and a finding file. Prints the workdir.
mk_reopen_wd() {
  local w
  w="$(mk_tmpworkdir)"
  mkdir -p "$w/.context/logs"
  cp "$FIXTURES/worktask/state.multistage.json" "$w/.context/state.json"
  cat > "$w/.context/development-0.md" << 'EOART'
---
handoff:
  stage: DV
  verdict: ok
  summary: "target artifact"
  files_touched: [skills/worktask/scripts/a.sh, .context/development-0.md]
  next_stage_focus: "DR re-reviews"
  refs: { dev: development-0.md#files-changed }
---
EOART
  printf 'the --foo option does not exist in the tree\n' > "$w/finding.txt"
  WORKSPACE_ROOT="$w" bash "$PLUGIN_ROOT/$SCRIPT" --state "$w/.context/state.json" \
    --task-create DC0 --metadata "$(_r9_meta '{"stage":"DC","agent":"corpflow:technical-writer"}')" \
    > /dev/null
  WORKSPACE_ROOT="$w" bash "$PLUGIN_ROOT/$SCRIPT" --state "$w/.context/state.json" \
    --task-status DC0 completed > /dev/null
  cp "$w/.context/state.json" "$w/before.json"
  printf '%s\n' "$w"
}

@test "reopen guard: unknown target exits 1, malformed target exits 2, ledger byte-unchanged" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV7 --from DC0
  assert_failure 1
  assert_output --partial "unknown task id"
  assert_ledger_unchanged "$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen ZZ0 --from DC0
  assert_failure 2
  assert_output --partial "invalid task id"
  assert_ledger_unchanged "$w"
}

@test "reopen guard: a missing or malformed --from exits 2, ledger byte-unchanged" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0
  assert_failure 2
  assert_output --partial "requires --from"
  assert_ledger_unchanged "$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from nope
  assert_failure 2
  assert_output --partial "invalid --from id"
  assert_ledger_unchanged "$w"
}

@test "reopen guard: target is the source, or is not completed, refuses exit 4 byte-unchanged" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DV0
  assert_failure 4
  assert_output --partial "reopen refused: target-is-source"
  assert_ledger_unchanged "$w"
  # DV1 is in_progress and ST0 pending: neither ever produced an output to correct.
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV1 --from DC0
  assert_failure 4
  assert_output --partial "reopen refused: target-not-completed"
  assert_ledger_unchanged "$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC9
  assert_failure 1
  assert_output --partial "unknown task id"
  assert_ledger_unchanged "$w"
}

@test "reopen: target pending with fix_round 1 and gate_from_stage, artifact and verdict kept" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt
  assert_success
  run jq -c '.tasks.DV0 | [.status, .metadata.fix_round, .metadata.gate_from_stage,
                           .metadata.gate_blockers, .verdict, .artifact]' .context/state.json
  assert_output '["pending",1,"DC",["the --foo option does not exist in the tree"],"ok",".context/development-0.md"]'
}

@test "reopen: the finding arrives on stdin under --finding-file -" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash -c "printf 'stdin finding\n' | bash '$PLUGIN_ROOT/$SCRIPT' --task-reopen DV0 --from DC0 --finding-file -"
  assert_success
  run jq -r '.tasks.DV0.metadata.gate_blockers[0]' .context/state.json
  assert_output "stdin finding"
}

@test "reopen: the finding reaches neither the state-patch log nor an argv-shaped echo" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt
  assert_success
  # The durable record of a correction is the ledger field and the router's audit leg; the
  # merge log carries ids and counts only, so stage-written text cannot leak through it.
  run grep -c "the --foo option" .context/logs/state-merge.log
  assert_output "0"
  refute_output --partial "the --foo option"
}

@test "reopen: an oversized or control-byte finding exits 2, ledger byte-unchanged" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  head -c 2500 < /dev/zero | tr '\0' 'x' > big.txt
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file big.txt
  assert_failure 2
  assert_output --partial "2000-byte cap"
  assert_ledger_unchanged "$w"
  printf 'esc\033[2J here\n' > ctrl.txt
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file ctrl.txt
  assert_failure 2
  assert_output --partial "control byte"
  assert_ledger_unchanged "$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file absent.txt
  assert_failure 2
  assert_ledger_unchanged "$w"
}

@test "reopen: a re-routed correction is refused by the completed guard, fix_round stays 1" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt > /dev/null
  cp .context/state.json before.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt
  assert_failure 4
  assert_output --partial "reopen refused: target-not-completed"
  assert_ledger_unchanged "$w"
  run jq -r '.tasks.DV0.metadata.fix_round' .context/state.json
  assert_output "1"
}

@test "reopen: a second correction bumps fix_round to 2 and re-stamps the source stage" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt > /dev/null
  bash "$PLUGIN_ROOT/$SCRIPT" --task-status DV0 completed > /dev/null
  printf 'the fix regressed case 7\n' > finding2.txt
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from QA0 --finding-file finding2.txt
  assert_success
  run jq -c '.tasks.DV0.metadata | [.fix_round, .gate_from_stage, .gate_blockers[0]]' \
    .context/state.json
  assert_output '[2,"QA","the fix regressed case 7"]'
}

@test "reopen consumers: transitive and completed-only, minus the source and the FN/RE stages" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt
  assert_success
  # DR0 is direct, QA0 transitive through it. FN0 and RE0 are downstream and completed but
  # act outside the ledger; ST0 is downstream and never completed; DV1 is not downstream.
  run jq -r '[.tasks | to_entries[] | select(.value.status == "stale") | .key] | sort | join(",")' \
    .context/state.json
  assert_output "DR0,QA0"
  run jq -c '[.tasks.FN0.status, .tasks.RE0.status, .tasks.ST0.status, .tasks.DV1.status,
              .tasks.DC0.status]' .context/state.json
  assert_output '["completed","completed","pending","in_progress","completed"]'
}

@test "reopen consumers: the source is excluded even when it is downstream of the target" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from QA0 --finding-file finding.txt
  assert_success
  run jq -r '[.tasks | to_entries[] | select(.value.status == "stale") | .key] | sort | join(",")' \
    .context/state.json
  assert_output "DR0"
  run jq -r '.tasks.QA0.status' .context/state.json
  assert_output "completed"
}

@test "reopen consumers: a parked consumer keeps its verdict and artifact, and is never reset" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt
  assert_success
  run jq -c '.tasks.DR0 | [.status, .verdict, .artifact, has("rework_pending")]' .context/state.json
  assert_output '["stale","ok",".context/developer-review-0.md",false]'
}

@test "settle: a cited change returns the dependent to pending, an uncited one to completed" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-meta DR0 \
    --set '{"consumes":[{"from":"DV0","paths":["./skills/worktask/scripts/a.sh#files-changed"]}]}' > /dev/null
  bash "$PLUGIN_ROOT/$SCRIPT" --task-meta QA0 \
    --set '{"consumes":[{"from":"DV0","paths":["skills/worktask/scripts/b.sh:42"]}]}' > /dev/null
  bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt > /dev/null
  # No --changed: the change set comes from the target artifact's files_touched, and the
  # citations are normalised (a leading ./, a trailing #anchor, a trailing :N).
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-settle-stale DV0
  assert_success
  assert_output '{"settled":[{"task":"DR0","to":"pending","reason":"cited-file-changed"},{"task":"QA0","to":"completed","reason":"no-cited-file-changed"}]}'
  run jq -c '[.tasks.DR0.status, .tasks.QA0.status, .tasks.QA0.verdict]' .context/state.json
  assert_output '["pending","completed","go"]'
}

@test "settle: a .context/-only change set is known and lets every dependent stand" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-meta DR0 \
    --set '{"consumes":[{"from":"DV0","paths":["skills/worktask/scripts/a.sh"]}]}' > /dev/null
  bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt > /dev/null
  # The target rewrites its own artifact on every completion. Counting that would return
  # every dependent and defeat R5 — so the exclusion leaves a KNOWN, empty change set here,
  # not an unknown one, and the earlier result stands.
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-settle-stale DV0 --changed .context/development-0.md
  assert_success
  assert_output --partial '{"task":"DR0","to":"completed","reason":"no-cited-file-changed"}'
  run jq -r '.tasks.DR0.status' .context/state.json
  assert_output "completed"
}

@test "settle: an absent or empty change set fails safe to pending" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-meta DR0 \
    --set '{"consumes":[{"from":"DV0","paths":["skills/worktask/scripts/a.sh"]}]}' > /dev/null
  bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt > /dev/null
  rm -f .context/development-0.md
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-settle-stale DV0
  assert_success
  assert_output --partial '{"task":"DR0","to":"pending","reason":"change-set-unknown"}'
  run jq -r '.tasks.DR0.status' .context/state.json
  assert_output "pending"
}

@test "settle: a declared-but-empty files_touched is absent on both readers, never a known []" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-meta DR0 \
    --set '{"consumes":[{"from":"DV0","paths":["skills/worktask/scripts/a.sh"]}]}' > /dev/null
  bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt > /dev/null
  # yq reports this as a sequence; the awk fallback cannot tell it from a missing key. If the
  # two readers disagree, the fail-safe direction depends on whether the host has yq — the same
  # ledger and artifact would complete every dependent on one machine and re-verify them on
  # another. Both must read it as `absent`.
  cat > .context/development-0.md << 'EOART'
---
handoff:
  stage: DV
  verdict: ok
  summary: "target artifact with an empty files_touched"
  files_touched: []
  next_stage_focus: "DR re-reviews"
  refs: { dev: development-0.md#files-changed }
---
EOART
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-settle-stale DV0
  assert_success
  assert_output --partial '{"task":"DR0","to":"pending","reason":"change-set-unknown"}'
  refute_output --partial "no-cited-file-changed"
  run jq -r '.tasks.DR0.status' .context/state.json
  assert_output "pending"
}

@test "settle: a dependent citing nothing fails safe to pending, and an unparked ledger settles []" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt > /dev/null
  # Neither DR0 nor QA0 declares consumes[], and facts.files_read carries no row for either
  # stage: nothing could be checked, so both re-verify.
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-settle-stale DV0 --changed skills/worktask/scripts/a.sh
  assert_success
  assert_output '{"settled":[{"task":"DR0","to":"pending","reason":"cited-set-empty"},{"task":"QA0","to":"pending","reason":"cited-set-empty"}]}'
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-settle-stale DV0 --changed skills/worktask/scripts/a.sh
  assert_success
  assert_output '{"settled":[]}'
}

@test "settle: facts.files_read supplies the cited set when consumes[] is absent" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  bash "$PLUGIN_ROOT/$SCRIPT" --files-read DR0 ./skills/worktask/scripts/a.sh > /dev/null
  bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt > /dev/null
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-settle-stale DV0 --changed skills/worktask/scripts/a.sh
  assert_success
  assert_output --partial '{"task":"DR0","to":"pending","reason":"cited-file-changed"}'
}

@test "settle: empty citations compare the dependent's own files" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  jq '.tasks.QA0.artifact = ".context/qa-0.md"' .context/state.json > state.next
  mv state.next .context/state.json
  printf '%s\n' '---' 'handoff:' '  files_touched: [./skills/worktask/scripts/a.sh#section]' '---' > .context/qa-0.md
  bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt > /dev/null
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-settle-stale DV0 --changed skills/worktask/scripts/a.sh
  assert_success
  assert_output --partial '"task":"QA0","to":"pending","reason":"own-file-changed"'
}

@test "settle: disjoint own files retain the dependent result" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  jq '.tasks.QA0.artifact = ".context/qa-0.md"' .context/state.json > state.next
  mv state.next .context/state.json
  printf '%s\n' '---' 'handoff:' '  files_touched: [tests/b.bats]' '---' > .context/qa-0.md
  bash "$PLUGIN_ROOT/$SCRIPT" --task-reopen DV0 --from DC0 --finding-file finding.txt > /dev/null
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-settle-stale DV0 --changed skills/worktask/scripts/a.sh
  assert_success
  assert_output --partial '"task":"QA0","to":"completed","reason":"no-own-file-changed"'
}

@test "facts: string decisions dedupe and partial rejects name the object schema" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-id DV0 --facts '{"decisions":["chose the spill union"]}'
  assert_success
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-id DV0 --facts '{"decisions":["chose the spill union"]}'
  assert_success
  run jq -e '[.facts.decisions[] | select(.summary == "chose the spill union")]
    | length == 1 and .[0].stage == "DV0" and (.[0].id | type) == "string"' .context/state.json
  assert_success
  run bash "$PLUGIN_ROOT/$SCRIPT" --facts '{"decisions":[42,{"id":"d1","summary":"ok"}]}'
  assert_failure 2
  assert_output --partial '{id, summary, ref}'
  run jq -e '[.facts.decisions[] | select(.id == "d1")] | length == 1' .context/state.json
  assert_success
}

@test "facts: caller probe environment is ignored" {
  cd "$WD"
  run env ATOMIC_APPLY_PROBE='error("boom")' ATOMIC_APPLY_PROBE_OUT=junk \
    bash "$PLUGIN_ROOT/$SCRIPT" --task-meta PL0 --set '{"x":1}'
  assert_success
  refute_output --partial 'warn: atomic apply probe failed'
  run jq -e '.tasks.PL0.metadata.x == 1' .context/state.json
  assert_success
}

@test "prev: indexed task id writes the stage edge and invalid forms fail" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --prev AR0 --artifact .context/development-0.md
  assert_success
  run jq -e '.handoffs | has("AR→DV0")' .context/state.json
  assert_success
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --prev XX0 --artifact .context/development-0.md
  assert_failure 2
  assert_output --partial 'stage code'
  assert_output --partial 'task id'
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --prev USER0 --artifact .context/development-0.md
  assert_failure 2
  assert_output --partial 'invalid --prev value'
}

@test "correction modifiers: --from, --finding-file and --changed are refused on other ops" {
  local w; w="$(mk_reopen_wd)"; cd "$w"; export WORKSPACE_ROOT="$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-status DV0 pending --from DC0
  assert_failure 2
  assert_output --partial "--from / --finding-file apply to --task-reopen only"
  assert_ledger_unchanged "$w"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-status DV0 pending --changed a.sh
  assert_failure 2
  assert_output --partial "--changed applies to --task-settle-stale only"
  assert_ledger_unchanged "$w"
}

# --- REQ-1: a DV settle adds the branch diff to facts.files_modified ---------------------
# Base-sanity reads files_modified as its denominator, so an incomplete self-reported list
# blocks a correct base. Real git fixtures: the fill is a function of refs.

_fill_repo() {
  cd "$WD"
  git init -q -b develop .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m base
  git checkout -q -b feature/work
  printf 'x\n' > c1.sh
  printf 'x\n' > c2.sh
  printf 'x\n' > c3.sh
  git add c1.sh c2.sh c3.sh
  git -c user.email=a@b.c -c user.name=t commit -q -m work
}

_fill_row() { # $1 = DV0 metadata object
  jq --argjson m "$1" '.tasks.DV0 = {status: "in_progress", metadata: $m}' \
    .context/state.json > s && mv s .context/state.json
}

_fill_dv() { # $@ = extra args
  bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --task-id DV0 --artifact .context/development-0.md \
    --facts '{"files_modified":["a.sh"]}' "$@"
}

@test "files_modified: a DV settle adds the committed diff against the row base, each path once (REQ-1, AC-1)" {
  _fill_repo
  _fill_row '{"base_ref":"develop"}'
  run _fill_dv
  assert_success
  run jq -c '.facts.files_modified' .context/state.json
  assert_output '["a.sh","c1.sh","c2.sh","c3.sh"]'
  # A second settle that self-reports a git path adds no duplicate.
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage DV --task-id DV0 --artifact .context/development-0.md \
    --facts '{"files_modified":["c1.sh"]}'
  assert_success
  run jq -c '.facts.files_modified' .context/state.json
  assert_output '["a.sh","c1.sh","c2.sh","c3.sh"]'
}

@test "files_modified: an unresolvable base leaves the self-reported list and exit 0 (REQ-1, AC-2)" {
  _fill_repo
  # No row base_ref, no mirror, no workspace.json, no origin/HEAD.
  _fill_row '{}'
  run _fill_dv
  assert_success
  run jq -c '.facts.files_modified' .context/state.json
  assert_output '["a.sh"]'
}

@test "files_modified: a QA settle adds no git path (REQ-1, AC-3)" {
  _fill_repo
  _fill_row '{"base_ref":"develop"}'
  jq '.metadata = {base_ref: "develop"} | .tasks.QA0 = {status: "in_progress", metadata: {base_ref: "develop"}}' \
    .context/state.json > s && mv s .context/state.json
  printf -- '---\nhandoff:\n  stage: QA\n  verdict: go\n  summary: "fixture"\n---\n\n# Testing\n' \
    > .context/testing-0.md
  run bash "$PLUGIN_ROOT/$SCRIPT" --stage QA --task-id QA0 --artifact .context/testing-0.md \
    --facts '{"files_modified":["a.sh"]}'
  assert_success
  run jq -c '.facts.files_modified' .context/state.json
  assert_output '["a.sh"]'
}

@test "files_modified: an origin/HEAD-only base is a default, not a configured base, so nothing is added" {
  _fill_repo
  git update-ref refs/remotes/origin/develop develop
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  _fill_row '{}'
  run _fill_dv
  assert_success
  run jq -c '.facts.files_modified' .context/state.json
  assert_output '["a.sh"]'
}

@test "files_modified: a named workspace_path that is not a work tree adds nothing" {
  _fill_repo
  _fill_row "$(jq -cn --arg p "$WD/no-such-tree" '{base_ref: "develop", workspace_path: $p}')"
  run _fill_dv
  assert_success
  run jq -c '.facts.files_modified' .context/state.json
  assert_output '["a.sh"]'
}

@test "files_modified: a settle made from another cwd diffs the row's workspace_path" {
  _fill_repo
  _fill_row "$(jq -cn --arg p "$WD" '{base_ref: "develop", workspace_path: $p}')"
  local elsewhere
  elsewhere="$(mk_tmpworkdir)"
  cd "$elsewhere"
  run bash "$PLUGIN_ROOT/$SCRIPT" --state "$WD/.context/state.json" --stage DV --task-id DV0 \
    --artifact "$WD/.context/development-0.md" --facts '{"files_modified":["a.sh"]}'
  assert_success
  run jq -c '.facts.files_modified' "$WD/.context/state.json"
  assert_output '["a.sh","c1.sh","c2.sh","c3.sh"]'
}

@test "dispatch controls validate merged metadata and preserve the ledger on refusal" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-meta PL0 --set '{"retry_watchdog":true,"retry_watchdog_max_wait_ms":100}'
  assert_success
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-meta PL0 --set '{"retry_watchdog_max_wait_ms":200}'
  assert_success
  cp .context/state.json .context/before.json
  for patch in '{"retry_watchdog":false}' '{"auto_compact_window":"200000"}' '{"overloaded_retry_max_delay_ms":0}' '{"retry_watchdog":null}'; do
    run bash "$PLUGIN_ROOT/$SCRIPT" --task-meta PL0 --set "$patch"
    assert_failure 2
    cmp .context/state.json .context/before.json
  done
}

@test "batch task creation refuses every row when one dispatch control is invalid" {
  cd "$WD"
  cp .context/state.json .context/before.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-create PL8 --metadata '{"auto_compact_window":200000}' \
    --task-create PL9 --metadata '{"retry_watchdog_max_wait_ms":100}'
  assert_failure 2
  cmp .context/state.json .context/before.json
}

@test "unsetting watchdog alone refuses but removing its dependent limits succeeds" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-meta PL0 --set '{"retry_watchdog":true,"retry_watchdog_max_wait_ms":100}'
  assert_success
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-meta PL0 --unset retry_watchdog
  assert_failure 2
  run bash "$PLUGIN_ROOT/$SCRIPT" --task-meta PL0 --set '{"retry_watchdog":false}' --unset retry_watchdog_max_wait_ms
  assert_success
}
