#!/usr/bin/env bats
# Contract for REQ-7: GitHub honours `Closes #N` only on a merge into the default branch,
# so an issue PR merged into another base needs an explicit close. FN opens the PR and never
# merges it, so FN records the close and the megatask merger runs it post-merge.
#
# Each helper takes the file as an argument, so the can-actually-fail twins re-run it against
# a planted copy of the pre-fix wording.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

MEGA="skills/megatask/SKILL.md"
PM="agents/project-manager.md"

# The body of the section whose heading line is exactly $2, up to the next heading of the
# same or a higher level.
_section() {
  awk -v h="$2" '
    $0 == h { on = 1; lvl = index(h, " ") - 1; next }
    on && /^#+ / { if (index($0, " ") - 1 <= lvl) exit }
    on { print }' "$1"
}

# 0 when the megatask post-merge settle step runs the check against the archived ledger
# (the issue worktree is removed at PR-created, before any merge) and runs the printed close.
_mega_has_settle() {
  local s
  s="$(_section "$1" '#### Post-merge settle')"
  [[ "$s" == *"fn-preflight.sh"* ]] &&
    [[ "$s" == *'--state "$A/state.json" --context "$A" issue-close-required'* ]] &&
    [[ "$s" == *"gh issue close"* ]] &&
    [[ "$s" != *"before the worktree is cleaned up"* ]] &&
    _mega_fallback_survives "$s"
}

# 0 when the no-archive fallback builds the close from the batch ledger, never from a file
# inside the archived .context/ that is missing in exactly that case.
_mega_fallback_survives() {
  [[ "$1" == *"orchestrator.json .base_branch"* ]] &&
    [[ "$1" == *'gh issue close <N> --repo'* ]] &&
    [[ "$1" != *"complete-summary-N.md"* ]]
}

# 0 when § Final FN steps tells FN itself to run the close.
_pm_fn_runs_close() {
  _section "$1" '#### Final FN steps' | grep -E -q 'run the `gh issue close'
}

@test "megatask SKILL.md: the post-merge settle step names issue-close-required and gh issue close" {
  _mega_has_settle "$PLUGIN_ROOT/$MEGA"
}

@test "project-manager.md: Final FN steps records the close and never runs it" {
  run _pm_fn_runs_close "$PLUGIN_ROOT/$PM"
  assert_failure
  run _section "$PLUGIN_ROOT/$PM" '#### Final FN steps'
  assert_output --partial "fn-preflight.sh issue-close-required"
  assert_output --partial "does not merge it"
}

@test "no awaiting_merge status was added to the monitor or the megatask skill" {
  run grep -rn 'awaiting_merge' "$PLUGIN_ROOT/hooks" "$PLUGIN_ROOT/skills/megatask"
  assert_failure 1
}

@test "twin: the pre-fix wording fails both helpers" {
  local wd
  wd="$(mk_tmpworkdir)"
  printf '%s\n' '### Starting and completing an issue' '' \
    '**Completing**: per-issue FN pushes the branch, opens a PR with `Closes #{issue}`.' \
    '#### Post-merge settle' 'Run fn-preflight.sh issue-close-required.' \
    '## Per-Track Task IDs' 'gh issue close <N>' \
    > "$wd/mega.md"
  run _mega_has_settle "$wd/mega.md"
  assert_failure
  printf '%s\n' '#### Final FN steps' '' \
    '- Post-merge run `fn-preflight.sh issue-close-required`; on `yes` run the `gh issue close <N>` it printed.' \
    > "$wd/pm.md"
  run _pm_fn_runs_close "$wd/pm.md"
  assert_success
  run _mega_fallback_survives 'No archived ledger: run the gh issue close FN recorded under complete-summary-N.md ### Issue.'
  assert_failure
}
