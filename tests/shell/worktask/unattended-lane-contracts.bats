#!/usr/bin/env bats
# Unattended megatask lanes (fn_gate bypass, decision_gate auto) — the seven #499 gap classes.
#
# Each gap was a missing or contradicting rule, so each test pins the rule's text in the file a
# stage agent actually reads, plus one ledger round-trip for the `metadata.ci` key. Patterns use
# grep -E without \b: BSD grep on macOS treats \b in -E as a literal, which makes a check vacuous.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

CONTRACTS="skills/shared/stage-contracts.md"
PM="agents/project-manager.md"
ST="agents/stakeholder.md"
DEV="agents/developer.md"
CMD="commands/worktask.md"
SKILL="skills/worktask/SKILL.md"
MEGA="skills/megatask/SKILL.md"
COORD="skills/agent-coordination/SKILL.md"
ACTIONS="skills/agent-coordination/references/audit-actions.md"
LEDGER_DOC="skills/shared/state-ledger.md"
HANDOFF="skills/worktask/references/handoff-protocol.md"

# section <file> <exact heading line> — the heading through the next heading of the same or a
# higher level, so a rule moved out of its section fails instead of matching elsewhere.
section() {
  awk -v h="$2" '
    $0 == h { on = 1; split(h, a, " "); lvl = length(a[1]); print; next }
    on && /^#+ / { split($0, b, " "); if (length(b[1]) <= lvl) exit }
    on { print }' "$PLUGIN_ROOT/$1"
}

# --- REQ-1: no question waits for a bypassed FN gate -------------------------

@test "REQ-1: the sweep matrix sends nothing to a bypassed FN gate" {
  run section "$CONTRACTS" "### Sweep obligation matrix"
  assert_success
  assert_output --partial 'Under `fn_gate: "bypass"` nothing is deferred to the FN gate'
  assert_output --partial "#### Under fn_gate: \"bypass\""
  assert_output --partial 'FN and ST emit
`open_questions: []`'
  assert_output --partial "(auto-recorded)"
}

@test "REQ-1: the FN facts example carries an empty open_questions list" {
  run grep -c -F '"open_questions": []}' "$PLUGIN_ROOT/$PM"
  assert_output "1"
  run grep -c -F 'sw-FN0-1' "$PLUGIN_ROOT/$PM"
  assert_output "0"
}

@test "REQ-1: FN and ST each state the bypass rule" {
  for f in "$PM" "$ST"; do
    run section "$f" '#### Under fn_gate: "bypass"'
    assert_output --partial 'open_questions: []'
    assert_output --partial 'stage-contracts.md § Under fn_gate: "bypass"'
  done
}

# --- REQ-2: ledger before relay ----------------------------------------------

@test "REQ-2: C.0a writes the ledger before any SendMessage relay" {
  run section "$CMD" "##### Step C.0a — record, then fall through"
  assert_success
  assert_output --partial 'Only after `state-patch.sh` exits 0 may `SendMessage` relay it'
  assert_output --partial "never relay"
  assert_output --partial "relay nothing (§ Error Handling)"
  # AC-2's Verify reads by line, so the write and the relay must share one.
  printf '%s\n' "$output" | grep -F 'state-patch.sh' | grep -q -F 'SendMessage' \
    || fail "no single line names both state-patch.sh and SendMessage"
  # The write must be named before the relay, not merely somewhere in the step.
  first=$(printf '%s\n' "$output" | grep -n -m1 -F 'state-patch.sh' | cut -d: -f1)
  relay=$(printf '%s\n' "$output" | grep -n -m1 -F 'SendMessage' | cut -d: -f1)
  [ -n "$first" ] && [ -n "$relay" ] && [ "$first" -le "$relay" ]
}

# --- REQ-3: the resolver tier through an allow-listed CLI --------------------

@test "REQ-3: the command grants the CLI, not the library, and step 1 runs it" {
  run grep -c -F 'scripts/effort-ladder-cli.sh *)' "$PLUGIN_ROOT/$CMD"
  assert_output "1"
  run grep -c -F 'scripts/effort-ladder.sh *)' "$PLUGIN_ROOT/$CMD"
  assert_output "0"
  run section "$CMD" "##### Step C.0a — the resolver dispatch"
  assert_output --partial 'effort-ladder-cli.sh for-resolver "<effort>" "<model>"'
  refute_output --partial "Source \`skills/worktask/scripts/effort-ladder.sh\`"
  # The clamp is step 1's for-resolver output against plus-one, not plus-one alone.
  assert_output --partial "\`effort_clamped\`: step 1's"
  assert_output --partial 'output differs from `plus-one "<effort>"`'
}

# --- REQ-4: no hand-back while a child runs ----------------------------------

@test "REQ-4: the hand-back guard defines the live check, verdicts and audit row" {
  run section "$SKILL" "### Hand-back guard"
  assert_success
  assert_output --partial "claude agents --json --all"
  assert_output --partial "ListAgents"
  assert_output --partial '"action":"handback_guard"'
  for r in clear deferred parked unverified; do
    assert_output --partial "\`$r\`"
  done
  assert_output --partial "**before** any wait"
}

@test "REQ-4: /megatask grants ListAgents, not Bash(claude:*), for the track hold" {
  run grep -m1 '^allowed-tools:' "commands/megatask.md"
  assert_success
  assert_output --partial "ListAgents"
  refute_output --partial "Bash(claude:"
}

@test "REQ-4: an indeterminate live check is unverified, never clear" {
  run section "$SKILL" "#### Hand-back guard — verdicts"
  assert_output --partial "Nothing that is unclear maps to \`clear\`"
  row=$(printf '%s\n' "$output" | grep -F 'liveness is indeterminate')
  [[ "$row" == *'`unverified`'* ]] || fail "indeterminate row does not resolve to unverified: $row"
  [[ "$row" != *'`clear`'* ]] || fail "indeterminate row resolves to clear"
}

@test "REQ-4: every park kind names its resume.md arm, and a reattach re-runs the guard" {
  run section "$SKILL" "#### Hand-back guard — parked children"
  assert_output --partial "never hands back while a reattached child runs"
  for arm in "liveness branch — alive and responsive" "parked or gone" \
             "liveness branch — parked, awaiting input" "broken hook configuration"; do
    assert_output --partial "§ Live-agent rows — $arm"
    grep -q -F "### Live-agent rows — $arm" "$PLUGIN_ROOT/skills/worktask/references/resume.md" \
      || fail "resume.md has no arm named: $arm"
  done
  [ "$(printf '%s\n' "$output" | grep -c -F 'run the guard again')" -ge 3 ]
}

@test "REQ-4: every hand-back point cites the guard" {
  run section "$SKILL" "## Post-Worktask Self-Improvement"
  assert_output --partial "run § Hand-back guard before handing back"
  run section "$SKILL" "##### Step 4.9 — checkpoint and bypass paths"
  assert_output --partial "run § Hand-back guard (\`point: checkpoint\`)"
}

@test "REQ-4: handback_guard is a registered stage-loop action" {
  run section "$ACTIONS" "## Orchestrator — stage loop"
  assert_output --partial '`handback_guard`'
  assert_output --partial '`skills/megatask/SKILL.md` (track hold)'
}

@test "REQ-4: megatask holds a freed track while that issue's child is live" {
  run section "$MEGA" "### Starting and completing an issue"
  assert_output --partial "live child of that issue's worktask"
  assert_output --partial '`point: track_reassign`'
  run section "$MEGA" "#### Track hold before reassignment"
  row=$(printf '%s\n' "$output" | grep -F 'the check cannot run here')
  [[ "$row" == *'release it'* && "$row" == *'`unverified`'* ]] || fail "no unverified release arm: $row"
  assert_output --partial "best-effort"
  assert_output --partial "bounded by \`agent-coordination § Stall Timeout\`"
  run section "$MEGA" "### Monitoring Loop"
  assert_output --partial "assign freed,
   unheld tracks"
}

# --- REQ-5: metadata.ci ------------------------------------------------------

@test "REQ-5: the ci key has one home, a schema line and both readers" {
  run section "$LEDGER_DOC" "### CI field"
  assert_output --partial 'Only the literal `"disabled"` turns CI off'
  run grep -c -F 'ci: { type: string, enum: [enabled, disabled]' "$PLUGIN_ROOT/$HANDOFF"
  assert_output "1"
  run grep -c -F 'skipped when `metadata.ci` is `"disabled"`' "$PLUGIN_ROOT/$COORD"
  assert_output "1"
  run section "$PM" "##### CI wait"
  assert_output --partial "skip \`gh run watch\`"
  run grep -c -F 'only gap is a missing CI run is not PARTIAL' "$PLUGIN_ROOT/$ST"
  assert_output "1"
}

@test "REQ-5: --ledger-meta writes ci disabled and reverts it to enabled" {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context/logs"
  cp "$FIXTURES/worktask/state.sample.json" "$WD/.context/state.json"
  export WORKSPACE_ROOT="$WD"
  cd "$WD"
  run bash "$PLUGIN_ROOT/skills/worktask/scripts/state-patch.sh" --ledger-meta --set '{"ci":"disabled"}'
  assert_success
  run jq -r '.metadata.ci' .context/state.json
  assert_output "disabled"
  run bash "$PLUGIN_ROOT/skills/worktask/scripts/state-patch.sh" --ledger-meta --set '{"ci":"enabled"}'
  assert_success
  run jq -r '.metadata.ci' .context/state.json
  assert_output "enabled"
}

# --- REQ-6: portability banner -----------------------------------------------

@test "REQ-6: every brief gets a PORTABILITY line and no template cds into a bare variable" {
  run section "$SKILL" "##### Step 4.7 — portability banner"
  assert_output --partial "PORTABILITY: the shell can be zsh on macOS"
  run grep -rn -E 'cd \$[A-Za-z_{]' "$PLUGIN_ROOT/skills/worktask" "$PLUGIN_ROOT/$CMD"
  assert_failure 1
}

# --- REQ-7: chosen flattens are reported too ---------------------------------

@test "REQ-7: dispatch_flattened carries reason depth_cap or chosen, before the work" {
  run section "$COORD" "#### Depth-refusal self-report"
  assert_output --partial '| `metadata.reason` | `depth_cap`'
  assert_output --partial '`chosen` (the agent flattened by choice)'
  assert_output --partial '`null` under `chosen`'
  run section "$DEV" "### Flattened dispatch"
  assert_output --partial '`dispatch_flattened` audit row **before** the inline'
  assert_output --partial '`chosen` or `depth_cap`'
}
