#!/usr/bin/env bats
# Behavioural tests for skills/worktask/scripts/attachments-preseed.sh — the FN
# pre-gate Conductor-attachments writer.
#
# The script reads the two canonical template leaves at run time, so
# there is no copy left to drift. P12/P12b pin the refusal that replaces the old
# drift guard — a broken install must not emit a half-rendered attachment — and
# P12c pins the emission rule itself against a fixture document. The rest pin
# field resolution, the documented defaults, and the failure paths.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/worktask/scripts/attachments-preseed.sh"
PR_DOC="skills/worktask/assets/templates/attachments-pr-template.md"
RV_DOC="skills/worktask/assets/templates/attachments-review-template.md"

PR_FILE=".context/attachments/PR instructions.md"
RV_FILE=".context/attachments/Review request.md"

setup() {
  WD="$BATS_TEST_TMPDIR/wd"
  mkdir -p "$WD/.context"
}

# Renders with every volatile input pinned, so output is a pure function of the
# templates and the fixtures.
_render() {
  run_script "$SCRIPT" --workdir "$WD" --worktask-id wt-1 --branch feature/x \
    --base-branch main --run-index 0 --commit-type fix --uncommitted 7 \
    --no-upstream --ts 2026-01-01T00:00:00Z "$@"
}

_seed_dr() {
  cat > "$WD/.context/developer-review-0.md" <<'EOF'
# Developer Review

Approval Status: APPROVED — one non-blocking note.

## Issues Found

Unused import in foo.sh
Magic number at bar.sh:42

## Summary

Fine.
EOF
}

_seed_qa() {
  cat > "$WD/.context/testing-0.md" <<'EOF'
# QA

GO/NO-GO: GO — suite green.

## Results

Flaky timing test retried once
EOF
}

@test "P1: writes both attachments and prints both paths" {
  _render
  assert_success
  assert_output --partial "$WD/$PR_FILE"
  assert_output --partial "$WD/$RV_FILE"
  [ -s "$WD/$PR_FILE" ]
  [ -s "$WD/$RV_FILE" ]
}

@test "P2: every documented placeholder token is resolved, skeleton prose is not" {
  _seed_dr
  _seed_qa
  _render
  assert_success
  for f in "$WD/$PR_FILE" "$WD/$RV_FILE"; do
    run grep -cE '<(WORKTASK_ID|ISO_TS|BRANCH|BASE_BRANCH|UPSTREAM_LINE|DR_VERDICT|QA_VERDICT|DR_CONCERNS_BULLETS|QA_NOTES_BULLETS|ISSUE_LINE)>' "$f"
    assert_output "0"
  done
  # Falsification arm: the templates' own angle-bracket prose is NOT a
  # placeholder and must survive verbatim, so P2 cannot be satisfied by a
  # renderer that strips every `<...>` it sees.
  run grep -c '<Change 1, user-visible language>' "$WD/$PR_FILE"
  assert_output "1"
  run grep -c '(<severity>)' "$WD/$RV_FILE"
  assert_output "2"
}

@test "P3: DR and QA verdicts and bullets come from the run-index-suffixed artifacts" {
  _seed_dr
  _seed_qa
  _render
  assert_success
  run cat "$WD/$RV_FILE"
  assert_output --partial "- DR verdict: Approval Status: APPROVED — one non-blocking note."
  assert_output --partial "- QA verdict: GO/NO-GO: GO — suite green."
  assert_output --partial "- Unused import in foo.sh"
  assert_output --partial "- Magic number at bar.sh:42"
  assert_output --partial "- Flaky timing test retried once"
  # Section scoping: `## Summary` follows `## Issues Found`, and its body must
  # not leak into the bullets.
  refute_output --partial "- Fine."
}

@test "P4: run-index selects the artifact — a -1 run does not read the -0 files" {
  _seed_dr
  _seed_qa
  run_script "$SCRIPT" --workdir "$WD" --worktask-id wt-1 --branch feature/x \
    --base-branch main --run-index 1 --commit-type fix --uncommitted 0 \
    --no-upstream --ts 2026-01-01T00:00:00Z
  assert_success
  run cat "$WD/$RV_FILE"
  assert_output --partial "- DR verdict: unknown"
  assert_output --partial "- QA verdict: unknown"
  refute_output --partial "APPROVED"
}

@test "P5: documented defaults when DR and QA artifacts are absent" {
  _render
  assert_success
  run cat "$WD/$RV_FILE"
  assert_output --partial "- DR verdict: unknown"
  assert_output --partial "- QA verdict: unknown"
  assert_output --partial "(none flagged)"
  assert_output --partial "(none)"
  # Both files are still written — a missing optional input must not skip a Write.
  [ -s "$WD/$PR_FILE" ]
}

@test "P6: <ISSUE_LINE> — the whole line is omitted when absent, emitted when present" {
  _render
  assert_success
  # Absent: the line vanishes; the bullet before it and the comment after it stay
  # adjacent, so a renderer that left a blank line behind also fails here.
  run grep -A1 -F -e '- Worktask summary:' "$WD/$PR_FILE"
  assert_output --partial '<!-- If issue ref present:'
  # The template's own authoring comment quotes the bullet, so the refutation
  # has to be anchored: no LINE may start with the emitted bullet.
  refute_line --regexp '^- Issue: #'

  rm -rf "$WD/.context/attachments"
  _render --issue-ref 266
  assert_success
  run cat "$WD/$PR_FILE"
  assert_output --partial '- Issue: #266 — include `Closes #266` in the PR body to auto-close on merge.'
  assert_output --partial "Closes #266"
}

@test "P7: the <N> token is overloaded in the template and only the count sites resolve" {
  _render
  assert_success
  run grep -c -- '- Uncommitted changes: 7' "$WD/$PR_FILE"
  assert_output "1"
  run grep -c 'The worktask reports `7` uncommitted changes' "$WD/$PR_FILE"
  assert_output "1"
  # The PR-body checklist's `Closes #<N>` means the ISSUE number, not the
  # uncommitted count. A global <N> substitution would have written `Closes #7`.
  run grep -c 'Closes #<N>' "$WD/$PR_FILE"
  assert_output "1"
  run grep -c 'Closes #7' "$WD/$PR_FILE"
  assert_failure
}

@test "P8: upstream line has both arms" {
  _render
  assert_success
  run cat "$WD/$PR_FILE"
  assert_output --partial '- Upstream: No upstream branch yet — use `git push -u origin feature/x`.'

  rm -rf "$WD/.context/attachments"
  run_script "$SCRIPT" --workdir "$WD" --worktask-id wt-1 --branch feature/x \
    --base-branch main --run-index 0 --commit-type fix --uncommitted 7 \
    --upstream origin/feature/x --ts 2026-01-01T00:00:00Z
  assert_success
  run cat "$WD/$PR_FILE"
  assert_output --partial "- Upstream: Upstream tracking: origin/feature/x."
}

@test "P9: base branch is unresolvable => exit 3, audit row, and NO attachments written" {
  run_script_env --cwd "$WD" --unset FN_BASE_REF --separate-stderr \
    "$SCRIPT" --workdir "$WD" --worktask-id wt-1 --branch feature/x --run-index 0
  assert_failure 3
  [ -z "$output" ]
  [[ "$stderr" == *"base branch unresolved"* ]]
  # No half-written attachment may survive the refusal.
  [ ! -e "$WD/$PR_FILE" ]
  [ ! -e "$WD/$RV_FILE" ]
  assert_audit_row fn_attachments_preseed_failed --file "$WD/.context/logs/audit.jsonl" \
    --actor orchestrator --subject FN0 --result error \
    --jq '.metadata.reason == "base_branch_unresolved" and (.ts | length) > 0'
}

@test "P10: base-branch resolution order — FN_BASE_REF beats state.json metadata.base_ref" {
  cat > "$WD/.context/state.json" <<'EOF'
{"version":1,"worktask_id":"from-ledger","run_index":0,"metadata":{"base_ref":"develop"},"facts":{"goal":"fix a crash in the parser"}}
EOF
  run_script_env --cwd "$WD" --env FN_BASE_REF=release/9 \
    "$SCRIPT" --workdir "$WD" --branch feature/x --no-upstream --uncommitted 0 \
    --ts 2026-01-01T00:00:00Z
  assert_success
  run cat "$WD/$PR_FILE"
  assert_output --partial "Target: origin/release/9"
  refute_output --partial "origin/develop"
  # Same run proves two more ledger-sourced fields: worktask_id, and the commit
  # type derived from facts.goal via branch-lib (NOT from any plan file).
  assert_output --partial "worktask_id: from-ledger"
  assert_output --partial "- Suggested commit type: **bugfix**"
}

@test "P11: idempotent — a second run reproduces both files byte-for-byte" {
  _seed_dr
  _seed_qa
  _render
  cp "$WD/$PR_FILE" "$BATS_TEST_TMPDIR/pr1"
  cp "$WD/$RV_FILE" "$BATS_TEST_TMPDIR/rv1"
  _render
  assert_success
  run cmp "$BATS_TEST_TMPDIR/pr1" "$WD/$PR_FILE"
  assert_success
  run cmp "$BATS_TEST_TMPDIR/rv1" "$WD/$RV_FILE"
  assert_success
}

# Builds a minimal plugin fixture holding the script, the siblings it sources,
# and whatever template document $1 puts in place — nothing else. Prints the
# path of the script copy so the arm can invoke it out of tree.
_fixture_with_doc() {
  local doc_content="$1" fx="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$fx/skills/worktask/scripts" "$fx/skills/worktask/assets/templates" \
           "$fx/skills/shared/lib"
  cp "$PLUGIN_ROOT/$SCRIPT" "$fx/skills/worktask/scripts/"
  cp "$PLUGIN_ROOT/skills/worktask/scripts/branch-lib.sh" "$fx/skills/worktask/scripts/"
  cp "$PLUGIN_ROOT/skills/shared/lib/audit-lib.sh" "$fx/skills/shared/lib/"
  if [ "$doc_content" != "__omit__" ]; then
    printf '%s' "$doc_content" > "$fx/$PR_DOC"
    printf '%s' "$doc_content" > "$fx/$RV_DOC"
  fi
  printf '%s\n' "$fx/skills/worktask/scripts/attachments-preseed.sh"
}

# Replaces the former drift test: the templates are no longer copied into the
# script, so there is nothing left to drift. What has to hold instead is that a
# broken install refuses loudly rather than emitting a half-rendered attachment.
@test "P12: a missing template document is refused, and nothing is written" {
  local script
  script="$(_fixture_with_doc __omit__)"
  run bash "$script" --workdir "$WD" --worktask-id wt-1 --branch feature/x \
    --base-branch main --run-index 0 --no-upstream --uncommitted 0 \
    --ts 2026-01-01T00:00:00Z
  assert_failure 2
  assert_output --partial "plugin install broken"
  [ ! -e "$WD/$PR_FILE" ]
  [ ! -e "$WD/$RV_FILE" ]
  assert_audit_row fn_attachments_preseed_failed --file "$WD/.context/logs/audit.jsonl" \
    --actor orchestrator --result error \
    --jq '.metadata.reason == "template_unreadable"'
}

@test "P12b: a present-but-empty template section is refused the same way" {
  # The document exists and carries both headings, but one section has no
  # fenced body — the shape a bad merge or a truncated file produces. An empty
  # attachment is as useless to the FN agent as a missing one.
  local script doc
  doc='# Conductor Attachments

## Template — `PR instructions.md`

~~~markdown
Body.
~~~

## Template — `Review request.md`

Nothing fenced here.
'
  script="$(_fixture_with_doc "$doc")"
  run bash "$script" --workdir "$WD" --worktask-id wt-1 --branch feature/x \
    --base-branch main --run-index 0 --no-upstream --uncommitted 0 \
    --ts 2026-01-01T00:00:00Z
  assert_failure 2
  assert_output --partial "Review request.md"
  [ ! -e "$WD/$PR_FILE" ]
  [ ! -e "$WD/$RV_FILE" ]
}

@test "P12c: the rendered attachment is the document's template parts, verbatim" {
  # The runtime read has to reproduce the emission rule the document states for
  # itself — concatenate the fenced bodies in order, adding and dropping
  # nothing. A dropped blank line between two parts is invisible to a
  # line-membership check, so this compares the whole body.
  local script doc
  doc='# Fixture

## Template — `PR instructions.md`

~~~markdown
alpha <BRANCH>

~~~

#### Template part 2

~~~markdown
## beta

gamma
~~~

## Template — `Review request.md`

~~~markdown
delta
~~~
'
  script="$(_fixture_with_doc "$doc")"
  run bash "$script" --workdir "$WD" --worktask-id wt-1 --branch feature/x \
    --base-branch main --run-index 0 --no-upstream --uncommitted 0 \
    --ts 2026-01-01T00:00:00Z
  assert_success
  run cat "$WD/$PR_FILE"
  assert_output "alpha feature/x

## beta

gamma"
  run cat "$WD/$RV_FILE"
  assert_output "delta"
}

@test "P12d: a missing review leaf leaves both existing attachments unchanged" {
  local script fx="$BATS_TEST_TMPDIR/fx"
  script="$(_fixture_with_doc __omit__)"
  cp "$PLUGIN_ROOT/$PR_DOC" "$fx/$PR_DOC"
  mkdir -p "$WD/.context/attachments"
  printf 'existing PR\n' > "$WD/$PR_FILE"
  printf 'existing review\n' > "$WD/$RV_FILE"
  run bash "$script" --workdir "$WD" --worktask-id wt-1 --branch feature/x \
    --base-branch main --run-index 0 --no-upstream --uncommitted 0 \
    --ts 2026-01-01T00:00:00Z
  assert_failure 2
  assert_output --partial "attachments-review-template.md"
  [ "$(cat "$WD/$PR_FILE")" = 'existing PR' ]
  [ "$(cat "$WD/$RV_FILE")" = 'existing review' ]
}

@test "P13: --self-test passes and unknown args exit 2 with usage" {
  run_script "$SCRIPT" --self-test
  assert_success
  assert_output --partial "PASS:"

  run_script_env --separate-stderr "$SCRIPT" --bogus
  assert_failure 2
  [[ "$stderr" == *"unknown arg: --bogus"* ]]
  [[ "$stderr" == *"usage:"* ]]
}

# The emitter was the only one in the plugin building JSON with printf, so a quote
# in $reason emitted a line jq cannot parse — and one corrupt line stops every later
# reader of audit.jsonl. The reason is driven through the exit-3 path, which is the
# only caller, with a quoting-hostile --run-index standing in for a hostile reason.
@test "P-audit: the failure row is valid JSON even when its fields carry quotes" {
  run_script_env --cwd "$WD" --unset FN_BASE_REF --separate-stderr \
    "$SCRIPT" --workdir "$WD" --worktask-id wt-1 --branch feature/x \
    --run-index '0" ,"injected":"x'
  assert_failure 3
  run jq -e . "$WD/.context/logs/audit.jsonl"
  assert_success
  run jq -r '.injected // "absent"' "$WD/.context/logs/audit.jsonl"
  assert_output "absent"
}

# Companion to the attach-visual-evidence arm of the same name: nothing pinned the
# symlink refusal for any worktask emitter, only for the hook-side one.
@test "SR: a symlinked audit.jsonl is refused, never written through" {
  mkdir -p "$WD/.context/logs" "$WD/target-dir"
  ln -s "$WD/target-dir/escaped.txt" "$WD/.context/logs/audit.jsonl"
  run_script_env --cwd "$WD" --unset FN_BASE_REF --separate-stderr \
    "$SCRIPT" --workdir "$WD" --worktask-id wt-1 --branch feature/x --run-index 0
  assert_failure 3
  [ ! -e "$WD/target-dir/escaped.txt" ]
}
