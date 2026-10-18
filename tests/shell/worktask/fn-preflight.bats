#!/usr/bin/env bats
# Contract tests for skills/worktask/scripts/fn-preflight.sh.
# Contracts (from header + agents/project-manager.md § FN Stage):
#   - attachments: both Conductor files present => exit 0; missing => exit 1
#   - resolve-issue: ranked first-match (state url > gh-issue.json > issue_number > branch)
#   - validate-pr: body carries Closes #<n> => pass; missing => BLOCKED exit 1;
#                  no issue resolvable => audit-defer row + exit 0
#   - continuity: ancestor => pass; diverged => diagnostic + audit row, exit 0 (non-blocking)
#   - unknown command/flag => exit 2
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"
bats_require_minimum_version 1.5.0

SCRIPT="skills/worktask/scripts/fn-preflight.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context/logs" "$WD/.context/attachments"
  cat > "$WD/.context/state.json" <<'EOF'
{"version":1,"worktask_id":"wt-demo","run_index":2,"platform":"all",
 "plan_file":".context/planning-2.md","tasks":{"FN0":{"status":"in_progress"}},
 "facts":{},"handoffs":{},"metadata":{"github_issue_url":"https://github.com/o/r/issues/221"}}
EOF
}

mk_attachments() {
  printf 'pr\n' > "$WD/.context/attachments/PR instructions.md"
  printf 'rr\n' > "$WD/.context/attachments/Review request.md"
}

# A well-formed composed body: mandated heading + closing keyword, no leaks.
mk_body() {
  cat > "$WD/body.md" <<'EOF'
Summary of the work.

## Test plan

- bats tests/shell/worktask/fn-preflight.bats

Closes #221
EOF
}

# The observed-defect shape: a working-folder path line and an absolute path line.
mk_leaky_body() {
  cat > "$WD/body.md" <<'EOF'
Summary of the work.

Plan lives at .context/planning-2.md for reference.
Logs written to /Users/korich/secret/run.log during the run.

## Test plan

- bats tests/shell/worktask/fn-preflight.bats

Closes #221
EOF
}

# A visual-evidence row in attach-visual-evidence.sh `emit_pr` shape.
# $1 = run_index the row belongs to, $2 = result (ok|skipped).
mk_ve_row() {
  jq -cn --arg dk "wt-demo:$1:visual_evidence:pr" --arg r "$2" --argjson ri "$1" \
    '{ts:"2026-01-01T00:00:00Z", actor:"orchestrator",
      action:"visual_evidence_pr_emitted", result:$r,
      metadata:{worktask_id:"wt-demo", run_index:$ri, captures:0,
                host_tier:"none", reason:"fixture", dedupe_key:$dk}}' \
    >> "$WD/.context/logs/audit.jsonl"
}

no_screenshots() {
  jq '.metadata.requires_screenshots = false' "$WD/.context/state.json" > "$WD/s" \
    && mv "$WD/s" "$WD/.context/state.json"
}

@test "attachments: both present => exit 0" {
  cd "$WD"
  mk_attachments
  run bash "$PLUGIN_ROOT/$SCRIPT" attachments
  assert_success
  assert_output --partial "both present"
}

@test "attachments: missing Review request => BLOCKED exit 1" {
  cd "$WD"
  printf 'pr\n' > "$WD/.context/attachments/PR instructions.md"
  run bash "$PLUGIN_ROOT/$SCRIPT" attachments
  assert_failure 1
  assert_output --partial "Review request.md"
}

@test "resolve-issue: state.json github_issue_url wins (rank 1)" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" resolve-issue
  assert_success
  assert_output "221"
}

@test "resolve-issue: gh-issue.json .number used when url absent (rank 2)" {
  cd "$WD"
  jq 'del(.metadata.github_issue_url)' .context/state.json > s && mv s .context/state.json
  printf '{"number":314}\n' > .context/gh-issue.json
  run bash "$PLUGIN_ROOT/$SCRIPT" resolve-issue
  assert_success
  assert_output "314"
}

@test "resolve-issue: metadata.github_issue_number used (rank 3, megatask)" {
  cd "$WD"
  jq 'del(.metadata.github_issue_url) | .metadata.github_issue_number=99' \
    .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" resolve-issue
  assert_success
  assert_output "99"
}

@test "validate-pr: body with Closes #221 passes" {
  cd "$WD"
  printf 'Some work.\n\nCloses #221\n' > body.md
  run bash "$PLUGIN_ROOT/$SCRIPT" validate-pr --body body.md
  assert_success
  assert_output --partial "closes #221"
}

@test "validate-pr: body missing the closing keyword => BLOCKED exit 1" {
  cd "$WD"
  printf 'Some work with no closing line.\n' > body.md
  run bash "$PLUGIN_ROOT/$SCRIPT" validate-pr --body body.md
  assert_failure 1
  assert_output --partial "missing"
}

@test "validate-pr: case-insensitive Fixes/Resolves accepted" {
  cd "$WD"
  printf 'x\n\nfixes #221\n' > body.md
  run bash "$PLUGIN_ROOT/$SCRIPT" validate-pr --body body.md
  assert_success
}

@test "validate-pr: no issue resolvable => audit-defer row + exit 0" {
  cd "$WD"
  # Strip every issue source; run outside a git repo dir so branch parse yields nothing.
  jq 'del(.metadata)' .context/state.json > s && mv s .context/state.json
  printf 'body without issue\n' > body.md
  run env GIT_CEILING_DIRECTORIES="$WD" bash "$PLUGIN_ROOT/$SCRIPT" validate-pr --body body.md
  assert_success
  assert_output --partial "audit-deferred"
  run grep -c '"reason":"no_issue_resolved"' .context/logs/audit.jsonl
  assert_output "1"
}

@test "validate-pr: missing --body => usage exit 2" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" validate-pr
  assert_failure 2
}

@test "continuity: ancestor HEAD passes (fast-forward safe)" {
  cd "$WD"
  git init -q .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "base"
  jq '.metadata.base_ref="'"$(git rev-parse --abbrev-ref HEAD)"'"' \
    .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" continuity
  assert_success
  assert_output --partial "fast-forward safe"
}

# The base holds a commit HEAD lacks and HEAD holds one the base lacks. Since continuity
# tests base-into-HEAD, this is the shape that diverges; HEAD merely ahead of its base is not.
mk_diverged_base() { # $1 = base branch name
  git init -q -b work .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "base"
  git checkout -q -b "$1"
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "base moved on"
  git checkout -q work
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "worktask work"
}

@test "continuity: HEAD ahead of its base is fast-forward safe, not diverged (REQ-5, AC-7)" {
  # A feature branch is ahead of its base by design; that alone is never `diverged`.
  cd "$WD"
  git init -q -b work .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "base"
  git branch -q integration
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "worktask work"
  jq '.metadata.base_ref="integration"' .context/state.json > s && mv s .context/state.json
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" continuity
  assert_success
  assert_line "continuity: integration is an ancestor of worktree HEAD (fast-forward safe)"
  [[ "$stderr" != *"diverged"* ]] || fail "false diverged: $stderr"
  # Through cat: grep -c prints nothing at all for an absent log, which is the usual case.
  run bash -c "cat '$WD/.context/logs/audit.jsonl' 2> /dev/null | grep -c diverged_cherry_pick || true"
  assert_output "0"
}

@test "continuity: a base holding commits HEAD lacks records the cherry-pick fallback and still exits 0 (AC-8)" {
  # Carried from DV2/DV3: only the ancestor arm was covered, so the branch that
  # actually changes FN0's merge strategy had no test at all. The base moved on after the
  # fork, so it is not an ancestor of HEAD.
  cd "$WD"
  mk_diverged_base integration
  jq '.metadata.base_ref="integration"' .context/state.json > s && mv s .context/state.json
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" continuity
  # Divergence is a documented fallback, not a hard block.
  assert_success
  [[ "$stderr" == *"worktree branch diverged — falling back to cherry-pick; verify commits are complete."* ]]
  # commit_count is the observable that proves the divergence was MEASURED rather
  # than merely detected — a row with the right verdict but a wrong/zero count
  # would mean the operator is told nothing about how much work is at risk.
  run jq -se 'map(select(.action=="branch_continuity"))[-1]
              | [.result, .metadata.integration_branch, .metadata.commit_count]' \
    .context/logs/audit.jsonl
  assert_output --partial '"diverged_cherry_pick"'
  assert_output --partial '"integration"'
  run jq -se 'map(select(.action=="branch_continuity"))[-1].metadata.commit_count
              | (type == "number") and (. == 1)' .context/logs/audit.jsonl
  assert_output "true"
}

@test "SR-M1: a double quote in the branch name still yields a parseable audit row" {
  # `git check-ref-format 'refs/heads/foo"bar'` accepts, so a refname reaches the row
  # with a JSON metacharacter in it. The old printf template emitted an unparseable
  # line, which stops EVERY later reader of audit.jsonl at the parse error — not just
  # this row. Mutation check: revert the emitter to printf and this arm fails.
  cd "$WD"
  local hostile='int"egration'
  mk_diverged_base "$hostile"
  jq --arg b "$hostile" '.metadata.base_ref=$b' .context/state.json > s && mv s .context/state.json
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" continuity
  assert_success
  [[ "$stderr" == *"cherry-pick"* ]]
  # Whole-file parse, not a per-row one: the failure mode is a corrupted log stream.
  run jq -se '.' .context/logs/audit.jsonl
  assert_success
  run jq -sr 'map(select(.action=="branch_continuity"))[-1]
              | .metadata.integration_branch' .context/logs/audit.jsonl
  assert_success
  assert_output "$hostile"
  # commit_count stays a JSON number: readers compare it numerically.
  run jq -sr 'map(select(.action=="branch_continuity"))[-1]
              | .metadata.commit_count | type' .context/logs/audit.jsonl
  assert_output "number"
}

# ---------------------------------------------------------------------------
# pr-body — body-composition gate (REQ-4/REQ-5/REQ-6)
# ---------------------------------------------------------------------------

@test "F1: pr-body strips working-folder path lines and snapshots the original" {
  cd "$WD"
  no_screenshots
  mk_leaky_body
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
  run cat body.md
  refute_output --partial ".context/planning-2.md"
  refute_output --partial "/Users/korich/secret"
  assert_output --partial "## Test plan"
  [ -f "$WD/.context/logs/pr-body-2.presanitise.md" ]
  run grep -c '"action":"pr_body_sanitised"' .context/logs/audit.jsonl
  assert_output "1"
}

@test "F2: pr-body blocks a body with no Test plan heading" {
  cd "$WD"
  no_screenshots
  printf 'Summary only.\n\nCloses #221\n' > body.md
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_failure 1
  assert_output --partial "Test plan"
  run jq -r 'select(.action=="pr_body_gate") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "missing_test_plan_heading"
}

@test "F3: pr-body blocks when requires_screenshots and no visual-evidence row" {
  cd "$WD"
  mk_body
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_failure 1
  assert_output --partial "visual_evidence_pr_emitted"
  run jq -r 'select(.action=="pr_body_gate") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "missing_visual_evidence_row"
}

@test "F4: pr-body passes with an ok row and a Visual evidence section" {
  cd "$WD"
  mk_ve_row 2 ok
  cat > body.md <<'EOF'
Summary.

## Visual evidence

![shot](https://example.invalid/a.png)

## Test plan

- bats

Closes #221
EOF
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
}

@test "F5: pr-body blocks when the ok row's section was dropped from the body" {
  cd "$WD"
  mk_ve_row 2 ok
  mk_body
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_failure 1
  run jq -r 'select(.action=="pr_body_gate") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "missing_visual_evidence_section"
}

@test "F6: pr-body passes on a skipped row with no section (nothing was captured)" {
  cd "$WD"
  mk_ve_row 2 skipped
  mk_body
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
}

@test "F7: pr-body ignores a row from an earlier run index" {
  cd "$WD"
  mk_ve_row 1 ok
  mk_body
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_failure 1
  run jq -r 'select(.action=="pr_body_gate") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "missing_visual_evidence_row"
}

@test "F8: MILESTONE_MODE=1 drops the composition gate but still sanitises" {
  cd "$WD"
  printf 'Leak at /Users/korich/secret/run.log and no headings.\n' > body.md
  run env MILESTONE_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
  assert_output --partial "composition gate skipped (milestone_mode_env)"
  run jq -r 'select(.action=="pr_body_gate") | .result' .context/logs/audit.jsonl
  assert_output "skipped"
  # The exemption covers this command's BLOCKING checks only — a working-folder
  # path must not reach a published body on the batch route either.
  run cat body.md
  refute_output --partial "/Users/korich/secret/run.log"
}

@test "F8b: a /Volumes checkout path is stripped on the batch route too" {
  cd "$WD"
  printf 'Plan at /Volumes/internal/Projects/corpflow/.ctx/plan.md and no headings.\n' > body.md
  run env MILESTONE_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
  run cat body.md
  refute_output --partial "/Volumes/internal/Projects"
}

@test "F8c: batch routing degrades an unreachable sanitiser to a warning" {
  cd "$WD"
  mkdir -p "$WD/lonely"
  cp "$PLUGIN_ROOT/$SCRIPT" "$WD/lonely/fn-preflight.sh"
  cp "$PLUGIN_ROOT/skills/worktask/scripts/branch-lib.sh" "$WD/lonely/branch-lib.sh"
  cp "$PLUGIN_ROOT/skills/worktask/scripts/fn-preflight-cmds.sh" "$WD/lonely/fn-preflight-cmds.sh"
  printf 'Leak at /Users/korich/secret/run.log and no headings.\n' > body.md
  # The whole point of the batch exemption: a broken plugin cache cannot wedge
  # /megatask, so this reports and passes where F12 blocks.
  run env MILESTONE_MODE=1 bash "$WD/lonely/fn-preflight.sh" pr-body --body body.md
  assert_success
  assert_output --partial "sanitiser unavailable"
  run jq -r 'select(.action=="pr_body_gate") | .result' .context/logs/audit.jsonl
  assert_output "skipped"
}

@test "F9: metadata.milestone skips the gate" {
  cd "$WD"
  jq '.metadata.milestone = "v3.37"' .context/state.json > s && mv s .context/state.json
  printf 'Leak at /Users/korich/secret/run.log and no headings.\n' > body.md
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
  assert_output --partial "milestone_metadata"
}

@test "F10: workspace.json at \$PWD skips the gate" {
  cd "$WD"
  printf '{"git":{"base_branch":"master"}}\n' > workspace.json
  printf 'Leak at /Users/korich/secret/run.log and no headings.\n' > body.md
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
  assert_output --partial "workspace_record"
}

@test "F11: an IR stage (incident pipeline) skips the gate" {
  cd "$WD"
  jq '.tasks.IR0 = {"status":"completed"}' .context/state.json > s && mv s .context/state.json
  printf 'Leak at /Users/korich/secret/run.log and no headings.\n' > body.md
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
  assert_output --partial "incident_pipeline"
}

@test "F12: an unreachable sanitiser library blocks and names the path" {
  cd "$WD"
  mkdir -p "$WD/lonely"
  cp "$PLUGIN_ROOT/$SCRIPT" "$WD/lonely/fn-preflight.sh"
  # branch-lib.sh and fn-preflight-cmds.sh must ship alongside fn-preflight.sh — this
  # test isolates the sanitiser sibling (publish-pl-issue.sh), not either of those.
  cp "$PLUGIN_ROOT/skills/worktask/scripts/branch-lib.sh" "$WD/lonely/branch-lib.sh"
  cp "$PLUGIN_ROOT/skills/worktask/scripts/fn-preflight-cmds.sh" "$WD/lonely/fn-preflight-cmds.sh"
  no_screenshots
  mk_body
  run bash "$WD/lonely/fn-preflight.sh" pr-body --body body.md
  assert_failure 1
  assert_output --partial "sanitiser unavailable"
  assert_output --partial "$WD/lonely/publish-pl-issue.sh"
  run jq -r 'select(.action=="pr_body_gate") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "sanitiser_unavailable"
}

@test "F13: all sanitises before validate-pr sees the body" {
  cd "$WD"
  mk_attachments
  no_screenshots
  mk_leaky_body
  run bash "$PLUGIN_ROOT/$SCRIPT" all --body body.md
  assert_success
  assert_output --partial "closes #221"
  run cat body.md
  refute_output --partial "/Users/korich/secret"
  assert_output --partial "Closes #221"
}

@test "F14: scope parity — each shared is_milestone_mode signal disables the gate" {
  cd "$WD"
  printf 'Leak at /Users/korich/secret/run.log and no headings.\n' > body.md
  # 1. MILESTONE_MODE env override
  run env MILESTONE_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
  # 2. state.json .metadata.milestone
  jq '.metadata.milestone = "v3.37"' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
  jq 'del(.metadata.milestone)' .context/state.json > s && mv s .context/state.json
  # 3. workspace.json under WORKSPACE_ROOT
  mkdir -p "$WD/ws"
  printf '{}\n' > "$WD/ws/workspace.json"
  run env WORKSPACE_ROOT="$WD/ws" bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
  assert_output --partial "workspace_record"
}

@test "F23: batch scope answers before the unreachable-library check ever runs" {
  cd "$WD"
  mkdir -p "$WD/lonely"
  cp "$PLUGIN_ROOT/$SCRIPT" "$WD/lonely/fn-preflight.sh"
  cp "$PLUGIN_ROOT/skills/worktask/scripts/branch-lib.sh" "$WD/lonely/branch-lib.sh"
  cp "$PLUGIN_ROOT/skills/worktask/scripts/fn-preflight-cmds.sh" "$WD/lonely/fn-preflight-cmds.sh"
  printf 'Leak at /Users/korich/secret/run.log and no headings.\n' > body.md
  cp body.md body.orig.md
  run env MILESTONE_MODE=1 bash "$WD/lonely/fn-preflight.sh" pr-body --body body.md
  assert_success
  # fe795df moved the batch exemption ahead of the sanitiser, so an unreachable
  # library now returns from the warn branch and never reaches the composition
  # gate's "skipped (...)" line. What F23 guards is that batch scope is decided
  # first and does not block — the scope reason must be named either way.
  assert_output --partial "milestone_mode_env"
  refute_output --partial "BLOCKED"
  run diff body.md body.orig.md
  assert_success
}

@test "F22: the emitted dedupe key is the key the gate matches on (REQ-9)" {
  cd "$WD"
  no_screenshots
  # Producer: the real helper writes its own row for this run.
  run env WORKSPACE_ROOT="$WD" bash \
    "$PLUGIN_ROOT/skills/worktask/scripts/attach-visual-evidence.sh" --emit pr
  assert_success
  run jq -r 'select(.action=="visual_evidence_pr_emitted") | .metadata.dedupe_key' \
    .context/logs/audit.jsonl
  assert_output "wt-demo:2:visual_evidence:pr"
  # Consumer: the same row now has to satisfy a screenshot-requiring run.
  jq '.metadata.requires_screenshots = true' .context/state.json > s && mv s .context/state.json
  mk_body
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
}

# ---------------------------------------------------------------------------
# continuity — integration-branch resolution (REQ-11)
# ---------------------------------------------------------------------------

@test "F15: metadata.base_ref wins over the removed 'main' literal" {
  cd "$WD"
  git init -q -b master .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "base"
  jq '.metadata.base_ref = "master" | del(.git)' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" continuity
  assert_success
  assert_output --partial "master is an ancestor of worktree HEAD"
  refute_output --partial "main"
}

@test "F16: origin/HEAD is used when neither state field is set" {
  cd "$WD"
  git init -q -b trunk .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "base"
  # Fabricate the remote default-branch pointer without a network remote.
  git update-ref refs/remotes/origin/trunk HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  jq 'del(.git) | del(.metadata.base_ref)' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" continuity
  assert_success
  assert_output --partial "trunk"
}

@test "F17: nothing resolvable => base_ref_unresolved audit row, exit 0" {
  cd "$WD"
  git init -q -b master .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "base"
  jq 'del(.git) | del(.metadata.base_ref)' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" continuity
  assert_success
  assert_output --partial "unresolvable"
  run jq -r 'select(.action=="branch_continuity") | .result' .context/logs/audit.jsonl
  assert_output "base_ref_unresolved"
}

@test "F17b: FN_BASE_REF outranks every state field" {
  cd "$WD"
  git init -q -b master .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "base"
  jq '.metadata.base_ref = "never-used"' \
    .context/state.json > s && mv s .context/state.json
  printf '{"git":{"base_branch":"also-not"}}\n' > workspace.json
  run env FN_BASE_REF=master bash "$PLUGIN_ROOT/$SCRIPT" continuity
  assert_success
  assert_output --partial "master is an ancestor of worktree HEAD"
}

# ---------------------------------------------------------------------------
# branch-name removed from this validator (moved to the PL stage,
# skills/worktask/scripts/branch-name.sh) — the removed argument must be
# rejected, not silently accepted.
# ---------------------------------------------------------------------------

@test "the removed branch-name argument is rejected with a usage exit" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" branch-name
  assert_failure 2
  assert_output --partial "unknown argument"
}

@test "--help never mentions the removed branch-name command" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" --help
  assert_failure 2
  run bash -c "bash '$PLUGIN_ROOT/$SCRIPT' --help 2>&1 | grep -c 'branch-name'"
  assert_output "0"
}

# ---------------------------------------------------------------------------
# resolve-issue rank 4 — tightened to the leading <type>/<NNN>-<slug> shape
# ---------------------------------------------------------------------------

@test "resolve-issue: rank 4 resolves the leading <type>/<NNN>-<slug> branch shape" {
  cd "$WD"
  jq 'del(.metadata.github_issue_url)' .context/state.json > s && mv s .context/state.json
  rm -f .context/gh-issue.json
  git init -q -b "feature/42-add-login-flow" .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "work"
  run bash "$PLUGIN_ROOT/$SCRIPT" resolve-issue
  assert_success
  assert_output "42"
}

@test "AC-11: rank 4 does NOT resolve a bogus issue from a digit-terminated ticket-less slug" {
  cd "$WD"
  jq 'del(.metadata.github_issue_url)' .context/state.json > s && mv s .context/state.json
  rm -f .context/gh-issue.json
  git init -q -b "feature/migrate-to-swift-6" .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "work"
  run bash "$PLUGIN_ROOT/$SCRIPT" resolve-issue
  assert_success
  assert_output ""
}

# ---------------------------------------------------------------------------
# T4 — branch-lib.sh moved aside: fn-preflight.sh exits 3, no dispatch runs.
# ---------------------------------------------------------------------------

@test "T4: fn-preflight.sh exits 3 with the path on stderr when branch-lib.sh is unreachable" {
  cd "$WD"
  # Safe pattern (never mv the tracked file — an interrupt would leave the
  # plugin broken): copy fn-preflight.sh alone into a sibling-free temp dir,
  # deliberately without branch-lib.sh alongside it.
  mkdir -p "$WD/lonely"
  cp "$PLUGIN_ROOT/$SCRIPT" "$WD/lonely/fn-preflight.sh"
  run --separate-stderr bash "$WD/lonely/fn-preflight.sh" attachments
  assert_failure 3
  # DR-3: prove the path lands on stderr, not merely somewhere in the merged
  # stream — this test's own name claims "with the path on stderr".
  [[ "$stderr" == *"branch-lib.sh"* ]]
  assert_output ""
  run bash "$WD/lonely/fn-preflight.sh" resolve-issue
  assert_failure 3
}

@test "T4b: fn-preflight.sh exits 3 naming fn-preflight-cmds.sh when only that sibling is missing" {
  cd "$WD"
  # branch-lib.sh present, cmds library absent: proves the second guard is reached
  # and reports its own path rather than being masked by the first one.
  mkdir -p "$WD/halflonely"
  cp "$PLUGIN_ROOT/$SCRIPT" "$WD/halflonely/fn-preflight.sh"
  cp "$PLUGIN_ROOT/skills/worktask/scripts/branch-lib.sh" "$WD/halflonely/branch-lib.sh"
  run --separate-stderr bash "$WD/halflonely/fn-preflight.sh" attachments
  assert_failure 3
  [[ "$stderr" == *"fn-preflight-cmds.sh"* ]]
  assert_output ""
}

@test "T4c: fn-preflight-cmds.sh refuses direct execution" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/skills/worktask/scripts/fn-preflight-cmds.sh"
  assert_failure 2
  assert_output --partial "source it, do not execute it directly"
}

@test "pr-body: missing --body => usage exit 2" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body
  assert_failure 2
}

@test "unknown command => exit 2 via usage" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" bogus-cmd
  assert_failure 2
  assert_output --partial "unknown argument"
}

# ---------------------------------------------------------------------------
# SR0 rework — SR-4 (MEDIUM, CWE-427): CDPATH=. must not corrupt LIB_PATH
# resolution or spuriously trip the exit-3 unreachable-library guard.
# ---------------------------------------------------------------------------

@test "SR-4: CDPATH=. does not corrupt library resolution (attachments still dispatches)" {
  cd "$WD"
  mk_attachments
  run env CDPATH=. bash "$PLUGIN_ROOT/$SCRIPT" attachments
  assert_success
  refute_output --partial "unreachable"
}

@test "SR-2/SR-4: a symlinked fn-preflight.sh still resolves its real sibling branch-lib.sh" {
  cd "$WD"
  mk_attachments
  mkdir -p linked
  ln -s "$PLUGIN_ROOT/$SCRIPT" linked/fn-preflight.sh
  run bash linked/fn-preflight.sh attachments
  assert_success
  refute_output --partial "unreachable"
}

# ---------------------------------------------------------------------------
# AC-10 case 8 (R6) — branch-divergence: has anything outside the pipeline
# renamed the local branch since the naming step?
#
# The comparison base is the `to` of the last `branch_renamed / ok` row, NOT
# facts.branch. That choice is what makes the check useful AND what makes R4
# structurally unable to trip it — both are asserted below, because the
# orthogonality is a design claim, not an accident.
# ---------------------------------------------------------------------------

mk_div_repo() {
  local branch="${1:-feature/add-a-new-login-flow}"
  git init -q -b "$branch" "$WD"
  git -C "$WD" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m work
}

# The row branch-name.sh writes on a successful rename.
mk_renamed_ok_row() {
  jq -cn --arg to "$1" \
    '{ts:"2026-01-01T00:00:00Z", actor:"product-manager", action:"branch_renamed",
      subject:"PL2", result:"ok", task_id:"PL0",
      metadata:{from:"moab-v1", to:$to, origin_stage:"PL",
                dedupe_key:"wt-demo:2:branch_renamed"}}' \
    >> "$WD/.context/logs/audit.jsonl"
}

# Reads with the same AD-9-tolerant idiom the script uses: one corrupt line in the fixture
# must not break the assertion helper either.
div_row() {
  jq -rs -R "[ split(\"\n\")[] | fromjson? | objects
    | select(.action==\"branch_divergence_detected\") | .$1 ] | (last // \"\")" \
    "$WD/.context/logs/audit.jsonl"
}

@test "branch-divergence: a third-party rename is detected and classed third_party" {
  cd "$WD"
  mk_div_repo "which-stages-ran-tests"
  mk_renamed_ok_row "feature/add-a-new-login-flow"
  run bash "$PLUGIN_ROOT/$SCRIPT" branch-divergence
  assert_success
  assert_output --partial "renamed by something outside the pipeline"
  run div_row 'metadata.class'
  assert_output "third_party"
  run div_row 'result'
  assert_output "warn"
  run div_row 'metadata.local'
  assert_output "which-stages-ran-tests"
  run div_row 'metadata.renamed_to'
  assert_output "feature/add-a-new-login-flow"
  run div_row 'metadata.source'
  assert_output "fn_preflight"
}

@test "branch-divergence: local matching the ok row is expected, not third_party" {
  cd "$WD"
  mk_div_repo "feature/add-a-new-login-flow"
  mk_renamed_ok_row "feature/add-a-new-login-flow"
  run bash "$PLUGIN_ROOT/$SCRIPT" branch-divergence
  assert_success
  assert_output --partial "class=expected"
  run div_row 'metadata.class'
  assert_output "expected"
}

# The deferred / no-op arms never renamed anything, so there is no ok row and nothing
# can be classed third_party — divergence there is designed, not external.
@test "branch-divergence: no branch_renamed ok row means expected, never third_party" {
  cd "$WD"
  mk_div_repo "moab-v1"
  jq -cn '{ts:"2026-01-01T00:00:00Z", actor:"product-manager", action:"branch_renamed",
           subject:"PL2", result:"skipped", task_id:"PL0",
           metadata:{reason:"host_workspace_worktree", branch:"moab-v1",
                     target:"feature/add-a-new-login-flow", origin_stage:"PL",
                     dedupe_key:"wt-demo:2:branch_renamed"}}' \
    >> .context/logs/audit.jsonl
  jq '.facts.branch = "feature/add-a-new-login-flow"' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" branch-divergence
  assert_success
  run div_row 'metadata.class'
  assert_output "expected"
  run div_row 'metadata.renamed_to'
  assert_output ""
}

# R4 rewrites facts.branch and never touches git. Because the base is the ok row's `to`
# and not facts.branch, a refinement cannot look like an external rename.
@test "branch-divergence: an R4 refinement cannot trip the check (orthogonality)" {
  cd "$WD"
  mk_div_repo "feature/add-a-new-login-flow"
  mk_renamed_ok_row "feature/add-a-new-login-flow"
  # Exactly what refine-branch-target.sh does: the LEDGER moves, git does not.
  jq '.facts.branch = "feature/derive-branch-names-from-a-title"' .context/state.json > s \
    && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" branch-divergence
  assert_success
  run div_row 'metadata.class'
  assert_output "expected"
  # The row still records the disagreement it saw — it just does not call it third_party.
  run div_row 'metadata.ledger'
  assert_output "feature/derive-branch-names-from-a-title"
  run div_row 'metadata.local'
  assert_output "feature/add-a-new-login-flow"
  # Had the check compared against facts.branch, this would have been third_party.
  refute_output "feature/derive-branch-names-from-a-title"
}

@test "branch-divergence: non-blocking — exit 0 on every arm, including detection" {
  cd "$WD"
  mk_div_repo "which-stages-ran-tests"
  mk_renamed_ok_row "feature/add-a-new-login-flow"
  run bash "$PLUGIN_ROOT/$SCRIPT" branch-divergence
  assert_success
  # no repo at all
  rm -rf .git
  run bash "$PLUGIN_ROOT/$SCRIPT" branch-divergence
  assert_success
  # no audit log at all
  rm -f .context/logs/audit.jsonl
  run bash "$PLUGIN_ROOT/$SCRIPT" branch-divergence
  assert_success
}

@test "branch-divergence: jq unavailable — skipped, exit 0, no row" {
  cd "$WD"
  mk_div_repo "which-stages-ran-tests"
  mk_renamed_ok_row "feature/add-a-new-login-flow"
  local nobin tool p
  nobin="$WD/nobin"
  mkdir -p "$nobin"
  for tool in git grep sed tr cut date mkdir bash sh env printf true false cat awk readlink dirname basename; do
    p=$(command -v "$tool" 2> /dev/null) || continue
    ln -sf "$p" "$nobin/$tool"
  done
  run env PATH="$nobin" bash "$PLUGIN_ROOT/$SCRIPT" branch-divergence
  assert_success
  assert_output --partial "jq unavailable"
  run bash -c "grep -c branch_divergence_detected .context/logs/audit.jsonl || true"
  assert_output "0"
}

# AD-9 idiom: one unparsable line must not blind the scan.
@test "branch-divergence: a corrupt audit line does not blind the scan" {
  cd "$WD"
  mk_div_repo "which-stages-ran-tests"
  printf 'not json at all\n' >> .context/logs/audit.jsonl
  mk_renamed_ok_row "feature/add-a-new-login-flow"
  run bash "$PLUGIN_ROOT/$SCRIPT" branch-divergence
  assert_success
  run div_row 'metadata.class'
  assert_output "third_party"
}

@test "branch-divergence: the most recent ok row wins" {
  cd "$WD"
  mk_div_repo "feature/second-name"
  mk_renamed_ok_row "feature/first-name"
  mk_renamed_ok_row "feature/second-name"
  run bash "$PLUGIN_ROOT/$SCRIPT" branch-divergence
  assert_success
  run div_row 'metadata.class'
  assert_output "expected"
  run div_row 'metadata.renamed_to'
  assert_output "feature/second-name"
}

@test "branch-divergence: detached HEAD is expected, never third_party" {
  cd "$WD"
  mk_div_repo "feature/add-a-new-login-flow"
  mk_renamed_ok_row "feature/add-a-new-login-flow"
  git checkout -q --detach HEAD
  run bash "$PLUGIN_ROOT/$SCRIPT" branch-divergence
  assert_success
  run div_row 'metadata.class'
  assert_output "expected"
  run div_row 'metadata.local'
  assert_output ""
}

@test "branch-divergence: is not part of the all pipeline" {
  cd "$WD"
  mk_div_repo "which-stages-ran-tests"
  mk_renamed_ok_row "feature/add-a-new-login-flow"
  mk_attachments
  mk_body
  run bash "$PLUGIN_ROOT/$SCRIPT" all --body "$WD/body.md"
  run bash -c "grep -c branch_divergence_detected .context/logs/audit.jsonl || true"
  assert_output "0"
}

# Companion to AC-10/3d: `fromjson?` alone survives an unparsable line but NOT a
# well-formed non-object one, which parses and then dies on `.action` — silently
# suppressing detection of a real third-party rename.
@test "branch-divergence: a well-formed non-object audit line does not suppress detection" {
  cd "$WD"
  mk_div_repo "which-stages-ran-tests"
  printf '123\n[1,2]\n"a bare string"\n' >> .context/logs/audit.jsonl
  mk_renamed_ok_row "feature/add-a-new-login-flow"
  run bash "$PLUGIN_ROOT/$SCRIPT" branch-divergence
  assert_success
  run div_row 'metadata.class'
  assert_output "third_party"
  run div_row 'metadata.renamed_to'
  assert_output "feature/add-a-new-login-flow"
}

# ---------------------------------------------------------------------------
# issue-close-required (REQ-9). GitHub honours a `Closes #N` trailer only on a
# merge into the DEFAULT branch, so any other integration branch silently leaves
# the issue open. Standalone, read-only, exit 0 always.
# ---------------------------------------------------------------------------

# A repo whose origin/HEAD points at <default>, with an issue-bearing state.json.
_mk_repo_with_default() {
  local default="$1"
  cd "$WD"
  git init -q -b "$default" .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m base
  git update-ref "refs/remotes/origin/$default" HEAD
  git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$default"
}

@test "issue-close-required: a non-default integration branch requires an explicit close" {
  _mk_repo_with_default main
  jq '.metadata.base_ref="develop"' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" issue-close-required
  assert_success
  assert_output --partial "issue-close-required: yes"
  assert_output --partial "gh issue close 221"
  run jq -se 'map(select(.action=="issue_close_required"))[-1] | [.result, .metadata.base]' \
    .context/logs/audit.jsonl
  assert_output --partial '"required"'
  assert_output --partial '"develop"'
}

@test "issue-close-required: the repository default branch is a silent no-op" {
  _mk_repo_with_default main
  jq '.metadata.base_ref="main"' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" issue-close-required
  assert_success
  assert_output --partial "issue-close-required: no"
  refute_output --partial "gh issue close"
  run jq -se 'map(select(.action=="issue_close_required"))[-1] | .result' \
    .context/logs/audit.jsonl
  assert_output --partial '"not_required"'
}

@test "issue-close-required: an origin/ prefix on either side is not a false positive" {
  _mk_repo_with_default main
  jq '.metadata.base_ref="origin/main"' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" issue-close-required
  assert_success
  assert_output --partial "issue-close-required: no"
}

@test "issue-close-required: an unresolved integration branch degrades non-blocking" {
  cd "$WD"
  git init -q .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m base
  # No base_ref in state.json and no origin/HEAD to fall back on.
  jq 'del(.metadata.base_ref)' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" issue-close-required
  assert_success
  assert_output --partial "unresolved"
  refute_output --partial "gh issue close"
}

@test "issue-close-required: a required close with no resolvable issue says so and still exits 0" {
  _mk_repo_with_default main
  jq '.metadata.base_ref="develop" | del(.metadata.github_issue_url)' \
    .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" issue-close-required
  assert_success
  assert_output --partial "close it manually"
  run jq -se 'map(select(.action=="issue_close_required"))[-1] | .result' \
    .context/logs/audit.jsonl
  assert_output --partial '"issue_unresolved"'
}

@test "issue-close-required: it is NOT part of 'all' (cannot perturb the pre-PR battery)" {
  _mk_repo_with_default main
  jq '.metadata.base_ref="develop"' .context/state.json > s && mv s .context/state.json
  mk_attachments
  mk_body
  run bash "$PLUGIN_ROOT/$SCRIPT" --body "$WD/body.md" all
  refute_output --partial "issue-close-required"
}

@test "issue-close-required: the FN row's base_ref develop with origin/HEAD master prints the close (REQ-7, AC-12)" {
  # A merge into a non-default base never fires the Closes trailer. The FN row carries the
  # base; the mirror does not.
  _mk_repo_with_default master
  jq '.run_index = 0 | .tasks.FN0.metadata.base_ref = "develop" | del(.metadata.base_ref)
      | .metadata.github_issue_url = "https://github.com/o/r/issues/497"' \
    .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" issue-close-required
  assert_success
  assert_output --partial "gh issue close 497"
}

# Two candidate bases that both resolve: the FN row names one, the ledger mirror the other.
_fn_row_repo() {
  cd "$WD"
  git init -q -b integration .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m base
  git branch -q other
  git update-ref refs/remotes/origin/main HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git checkout -q -b feature/work
  printf 'x\n' > run1.txt
  git add run1.txt
  git -c user.email=a@b.c -c user.name=t commit -q -m run
  jq '.run_index = 0 | .tasks.FN0.metadata.base_ref = "integration" | .metadata.base_ref = "other"
      | .tasks.DV0 = {status: "completed", metadata: {base_ref: "other"}}
      | .facts.files_modified = ["run1.txt"]' \
    .context/state.json > s && mv s .context/state.json
}

@test "REQ-6: continuity, base-sanity and issue-close-required read the FN<run_index> row (AC-10)" {
  _fn_row_repo
  # An inherited DV-scoped value must not steer FN onto another row's base.
  run env BASE_REF_TASK_ID=DV0 bash "$PLUGIN_ROOT/$SCRIPT" continuity
  assert_success
  assert_output --partial "continuity: integration is an ancestor of worktree HEAD"
  run env BASE_REF_TASK_ID=DV0 bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  run jq -sr 'map(select(.action=="base_sanity"))[-1].metadata.base' .context/logs/audit.jsonl
  assert_output "integration"
  run env BASE_REF_TASK_ID=DV0 bash "$PLUGIN_ROOT/$SCRIPT" issue-close-required
  assert_success
  assert_output --partial 'Merged into integration.'
}

@test "REQ-6: with no FN<run_index> row each check falls through to the ledger mirror (AC-10)" {
  _fn_row_repo
  jq 'del(.tasks.FN0)' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" continuity
  assert_success
  assert_output --partial "continuity: other is an ancestor of worktree HEAD"
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  run jq -sr 'map(select(.action=="base_sanity"))[-1].metadata.base' .context/logs/audit.jsonl
  assert_output "other"
  run bash "$PLUGIN_ROOT/$SCRIPT" issue-close-required
  assert_success
  assert_output --partial 'Merged into other.'
  # A row without base_ref falls through the same way.
  jq '.tasks.FN0 = {status: "in_progress"}' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" issue-close-required
  assert_output --partial 'Merged into other.'
}

# ---------------------------------------------------------------------------
# base-sanity (REQ-T1 / AC-A1..A7). The magnitude comparison: does the diff a PR
# against the resolved base would carry resemble what this run recorded changing?
# Fixtures are local-only on purpose — the check resolves through resolve_git_ref,
# never a literal `origin/$base`, so no remote is needed.
# ---------------------------------------------------------------------------

_bs_commit() {
  git -c user.email=a@b.c -c user.name=t commit -q "$@"
}

# n files in one commit, named <prefix>N.txt.
_bs_files() {
  local prefix="$1" n="$2" i
  for i in $(seq 1 "$n"); do printf 'x\n' > "${prefix}${i}.txt"; done
  git add -A
  _bs_commit -m "$prefix"
}

# A flat repo: `master` holds the pre-run history, HEAD adds this run's files.
_bs_flat_repo() {
  cd "$WD"
  git init -q -b master .
  _bs_commit --allow-empty -m base
  git checkout -q -b feature/work
  _bs_files run "$1"
}

# The incident's shape: HEAD stacks on `parent`, which itself stacks on
# `grandparent`. A PR opened against the grandparent carries the whole
# intervening branch, not just this run's own commit.
_bs_stacked_repo() {
  cd "$WD"
  git init -q -b grandparent .
  _bs_commit --allow-empty -m base
  git checkout -q -b parent
  _bs_files other 25
  git checkout -q -b feature/work
  _bs_files run 2
  jq '.metadata.base_ref="grandparent" | .facts.files_modified=["run1.txt","run2.txt"]' \
    .context/state.json > s && mv s .context/state.json
}

# The candidate branch exists ONLY under refs/remotes/origin/ — a remote-only
# stacked parent, which is the incident's own topology and what fork_base
# enumerates. A bare name does not resolve under git's disambiguation ladder.
_bs_remote_only_parent_repo() {
  cd "$WD"
  git init -q -b grandparent .
  _bs_commit --allow-empty -m base
  git checkout -q -b parent
  _bs_files other 25
  git update-ref refs/remotes/origin/parent HEAD
  git checkout -q -b feature/work
  _bs_files run 2
  git branch -q -D parent
  jq '.metadata.base_ref="grandparent" | .facts.files_modified=["run1.txt","run2.txt"]' \
    .context/state.json > s && mv s .context/state.json
}

_bs_ledger() {
  jq --argjson f "$1" '.facts.files_modified=$f' .context/state.json > s \
    && mv s .context/state.json
}

_bs_row() {
  jq -sce 'map(select(.action=="base_sanity"))[-1] | [.result, .metadata]' \
    .context/logs/audit.jsonl
}

# A fan-out payload: four streams staged independently, merged into the integration branch.
# `facts.files_modified` records what ONE stream knew; no stage records the assembly.
_bs_fanout_repo() {
  cd "$WD"
  git init -q -b master .
  _bs_commit --allow-empty -m base
  git checkout -q -b feature/work
  _bs_files run 2
  local stream
  for stream in a b c; do
    git checkout -q -b "stream/$stream" master
    _bs_files "$stream" 12
    git checkout -q feature/work
    git merge -q --no-ff -m "merge stream/$stream" "stream/$stream"
  done
  jq '.metadata.base_ref="master" | .facts.files_modified=["run1.txt","run2.txt"]' \
    .context/state.json > s && mv s .context/state.json
}

@test "base-sanity: a multi-parent payload degrades instead of blocking (F-10)" {
  # The denominator is incomplete BY CONSTRUCTION under fan-out — each stream records what
  # it knew, none records the assembly — so the rule blocked on every fan-out and was
  # cleared only with the sanctioned override, which is a gate teaching its own operators
  # to bypass it. Observed at 140 PR files against 19 ledger files.
  _bs_fanout_repo
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  assert_output --partial "merge commit(s)"
  assert_output --partial "skipped"
  run _bs_row
  assert_output --partial "multi_parent_payload"
}

@test "base-sanity: a single-stream payload still blocks on a wrong base" {
  # The rung must not swallow the topology it exists to catch: no merge parents, no degrade.
  _bs_stacked_repo
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_failure 1
  assert_output --partial "BLOCKED: base-sanity"
  run _bs_row
  assert_output --partial '"blocked"'
}

@test "base-sanity: a flat repo whose ledger matches the diff passes, naming both counts" {
  _bs_flat_repo 4
  jq '.metadata.base_ref="master"' .context/state.json > s && mv s .context/state.json
  _bs_ledger '["run1.txt","run2.txt","run3.txt","run4.txt"]'
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  assert_output --partial "base-sanity: pass"
  assert_output --partial "would carry 4 files"
  assert_output --partial "ledger records 4"
  run _bs_row
  assert_output --partial '"ok"'
}

@test "base-sanity: a grandparent base fails, naming both counts, and aborts 'all'" {
  _bs_stacked_repo
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_failure 1
  assert_output --partial "BLOCKED: base-sanity"
  assert_output --partial "would carry 27 files"
  assert_output --partial "ledger records 2"
  assert_output --partial "Closest fork-point candidate"
  # The thresholds must stay readable as wrong-base heuristics, or a later
  # maintainer tunes them into a diff-quality gate.
  assert_output --partial "WRONG-BASE heuristics"
  run _bs_row
  assert_output --partial '"blocked"'
  assert_output --partial '"pr_files":"27"'
  assert_output --partial '"ledger_files":"2"'

  # AC-A6: it is a step of the composite battery, and its failure aborts it.
  mk_attachments
  no_screenshots
  mk_body
  run bash "$PLUGIN_ROOT/$SCRIPT" all --body "$WD/body.md"
  assert_failure 1
  assert_output --partial "BLOCKED: base-sanity"
}

@test "base-sanity: a demonstrably under-recording ledger warns instead of blocking" {
  # The blocking topology, but with a working tree that proves the denominator is
  # incomplete: 2 recorded against 25 dirty. A wrong base does not dirty the tree, so the
  # gap can only mean the ledger under-recorded — and a block computed from it would be
  # false. CHANGELOG 4.0.29 records this happening at 18 recorded against 33 dirty.
  _bs_stacked_repo
  local i
  for i in $(seq 1 25); do printf 'x\n' > "dirty$i.txt"; done
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  assert_output --partial "the denominator is incomplete"
  refute_output --partial "BLOCKED"
  run _bs_row
  assert_output --partial '"ledger_under_recording"'
}

@test "base-sanity: a clean tree still blocks the wrong-base topology" {
  # Non-vacuity twin for the rung above: the new skip must not disarm the check.
  _bs_stacked_repo
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_failure 1
  assert_output --partial "BLOCKED: base-sanity"
}

@test "base-sanity: a small run legitimately touching more files than recorded still passes" {
  # 10 files against a 3-file ledger trips the multiplier (10 > 9); the 20-file
  # floor is the half that stops it. This case is why the rule is a conjunction.
  _bs_flat_repo 10
  jq '.metadata.base_ref="master"' .context/state.json > s && mv s .context/state.json
  _bs_ledger '["run1.txt","run2.txt","run3.txt"]'
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  assert_output --partial "base-sanity: pass"
  refute_output --partial "BLOCKED"
}

@test "base-sanity: an empty or absent ledger record warns instead of false-blocking" {
  _bs_stacked_repo
  _bs_ledger '[]'
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  assert_output --partial "records no modified files"
  run _bs_row
  assert_output --partial '"ledger_unavailable"'

  # Same verdict when the key is absent entirely — with ledger_files == 0 the
  # rule would degenerate to "any PR touching 21+ files fails".
  jq 'del(.facts.files_modified)' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  assert_output --partial "records no modified files"
}

@test "base-sanity: an unresolvable base warns, records a row, and exits 0" {
  _bs_stacked_repo
  run env FN_BASE_REF=does/not/exist bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  assert_output --partial "not present locally"
  run _bs_row
  assert_output --partial '"base_ref_unresolvable"'
  assert_output --partial '"does/not/exist"'
}

@test "base-sanity: FN_BASE_SANITY_OVERRIDE downgrades the fail arm and is audited" {
  _bs_stacked_repo
  run env FN_BASE_SANITY_OVERRIDE=true bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  assert_output --partial "WARNING: base-sanity"
  assert_output --partial "would carry 27 files"
  assert_output --partial "ledger records 2"
  refute_output --partial "BLOCKED"
  run _bs_row
  assert_output --partial '"override"'
  assert_output --partial '"override":"true"'

  # Unset, AC-A2 holds unchanged: the override is the only path that moves the
  # verdict, and it moves only the fail arm.
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_failure 1
  run env FN_BASE_SANITY_OVERRIDE=0 bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_failure 1
}

@test "base-sanity: a remote-only fork candidate is still named with its ahead-count" {
  _bs_remote_only_parent_repo
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_failure 1
  assert_output --partial "Closest fork-point candidate by commits-ahead: parent (1 ahead) vs grandparent (2 ahead)."
  refute_output --partial "unavailable"
}

# --- git fork evidence (REQ-2, REQ-3, REQ-4) ----------------------------------

# HEAD forked from `develop`, which is both the configured base and, on origin, the fork
# candidate. $1 = files this run committed.
_bs_same_base_repo() {
  cd "$WD"
  git init -q -b develop .
  _bs_commit --allow-empty -m base
  git update-ref refs/remotes/origin/develop HEAD
  git checkout -q -b feature/work
  _bs_files run "$1"
  jq '.metadata.base_ref="develop" | .facts.files_modified=["run1.txt","run2.txt"]' \
    .context/state.json > s && mv s .context/state.json
}

@test "base-sanity: a fork candidate equal to the base warns fork_confirms_base instead of blocking (REQ-3, AC-4)" {
  # When HEAD forked from the base itself the gap can only be an incomplete ledger.
  _bs_same_base_repo 27
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  refute_output --partial "BLOCKED"
  assert_output --partial "IS the base"
  run jq -sr 'map(select(.action=="base_sanity"))[-1] | .result, .metadata.fork_relation' \
    .context/logs/audit.jsonl
  assert_output "$(printf 'fork_confirms_base\nsame')"
}

@test "base-sanity: committed files since a distinct fork candidate count as under-recording evidence (REQ-2, AC-5)" {
  # A clean tree, so the dirty-only rung saw nothing and the 2-file ledger blocked.
  cd "$WD"
  git init -q -b grandparent .
  _bs_commit --allow-empty -m base
  git checkout -q -b parent
  _bs_files other 25
  git update-ref refs/remotes/origin/parent HEAD
  git checkout -q -b feature/work
  _bs_files run 26
  git branch -q -D parent
  jq '.metadata.base_ref="grandparent" | .facts.files_modified=["run1.txt","run2.txt"]' \
    .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  refute_output --partial "BLOCKED"
  assert_output --partial "the denominator is incomplete"
  run jq -sr 'map(select(.action=="base_sanity"))[-1]
              | .result, .metadata.committed_files, .metadata.fork_source' .context/logs/audit.jsonl
  assert_output "$(printf 'ledger_under_recording\n26\nremote')"
}

@test "base-sanity: a ledger filled against the wrong base still blocks when origin names the parent (REQ-4, AC-6)" {
  # After the DV fill the ledger equals the PR file count against the base it was filled
  # from. A rule reading only the ledger would pass; the fork evidence caps it at 2.
  _bs_remote_only_parent_repo
  local f=() i
  for i in $(seq 1 25); do f+=("other$i.txt"); done
  _bs_ledger "$(printf '%s\n' run1.txt run2.txt "${f[@]}" | jq -R . | jq -sc .)"
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_failure 1
  assert_output --partial "BLOCKED: base-sanity"
  assert_output --partial "ledger records 27"
  assert_output --partial "Git evidence from fork candidate parent: 2 committed + 0 dirty files; the ledger is capped at 2."
  run jq -sr 'map(select(.action=="base_sanity"))[-1] | .result, .metadata.denominator' \
    .context/logs/audit.jsonl
  assert_output "$(printf 'blocked\n2')"
}

@test "base-sanity: a remote base match does not hide an unpushed local parent" {
  # Guard twin for AC-4: `same` is declared only after the local probe finds nothing.
  cd "$WD"
  git init -q -b grandparent .
  _bs_commit --allow-empty -m base
  git update-ref refs/remotes/origin/grandparent HEAD
  git checkout -q -b parent
  _bs_files other 25
  git checkout -q -b feature/work
  _bs_files run 2
  jq '.metadata.base_ref="grandparent" | .facts.files_modified=["run1.txt","run2.txt"]' \
    .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_failure 1
  assert_output --partial "BLOCKED: base-sanity"
  assert_output --partial "parent (1 ahead, local branch) vs grandparent (2 ahead)."
  run jq -sr 'map(select(.action=="base_sanity"))[-1] | .metadata.fork_source' .context/logs/audit.jsonl
  assert_output "local"
}

@test "base-sanity: a stale origin/<own-branch> is never fork evidence" {
  # Guard twin for AC-6: on a fix-in-PR re-run the branch's own earlier push has the
  # smallest ahead-count, and taking it as the parent would cap a full ledger at 2.
  _bs_same_base_repo 25
  git update-ref refs/remotes/origin/feature/work HEAD
  _bs_files late 2
  local f=() i
  for i in $(seq 1 25); do f+=("run$i.txt"); done
  _bs_ledger "$(printf '%s\n' "${f[@]}" late1.txt late2.txt | jq -R . | jq -sc .)"
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  assert_output --partial "base-sanity: pass"
  run jq -sr 'map(select(.action=="base_sanity"))[-1]
              | .metadata.fork_relation, .metadata.own_branch_candidate' .context/logs/audit.jsonl
  assert_output "$(printf 'none\nfeature/work')"
}

@test "base-sanity: a fan-out with a dirty tree is still multi_parent_payload" {
  # Guard twin for the rung reorder: the merge rung now runs before the under-recording
  # rung, so local stream branches never reach the fork probe.
  _bs_fanout_repo
  local i
  for i in $(seq 1 25); do printf 'x\n' > "dirty$i.txt"; done
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  run _bs_row
  assert_output --partial "multi_parent_payload"
}

@test "base-sanity: an upstream that is the branch's start point stays fork evidence" {
  # A worktree created from origin/<parent> tracks it. Treating that upstream as the
  # branch's own push would discard the only evidence naming the real parent, and the
  # filled ledger would then pass the wrong base.
  cd "$WD"
  git init -q -b grandparent .
  git config remote.origin.url /dev/null
  git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  _bs_commit --allow-empty -m base
  git checkout -q -b parent
  _bs_files other 25
  git update-ref refs/remotes/origin/parent HEAD
  git checkout -q grandparent
  git branch -q -D parent
  git checkout -q --track -b feature/work origin/parent
  _bs_files run 2
  [ "$(git rev-parse --abbrev-ref '@{upstream}')" = "origin/parent" ]
  local f=() i
  for i in $(seq 1 25); do f+=("other$i.txt"); done
  jq '.metadata.base_ref="grandparent"' .context/state.json > s && mv s .context/state.json
  _bs_ledger "$(printf '%s\n' run1.txt run2.txt "${f[@]}" | jq -R . | jq -sc .)"
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_failure 1
  assert_output --partial "BLOCKED: base-sanity"
  run jq -sr 'map(select(.action=="base_sanity"))[-1] | .metadata.fork_source, .metadata.own_branch_candidate' \
    .context/logs/audit.jsonl
  assert_output "$(printf 'remote\n')"
}

@test "base-sanity: a fork candidate holding all of HEAD's committed work never caps the ledger" {
  # Zero committed files since the candidate say nothing about HEAD's footprint; capping
  # at the dirty count alone would block on whatever happens to be uncommitted.
  _bs_remote_only_parent_repo
  git reset -q --hard HEAD~1
  _bs_commit --allow-empty -m "no files of its own"
  printf 'x\n' > dirty1.txt
  printf 'x\n' > dirty2.txt
  local f=() i
  for i in $(seq 1 25); do f+=("other$i.txt"); done
  _bs_ledger "$(printf '%s\n' "${f[@]}" | jq -R . | jq -sc .)"
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  refute_output --partial "BLOCKED"
  run jq -sr 'map(select(.action=="base_sanity"))[-1]
              | .metadata.fork_relation, .metadata.committed_files, .metadata.denominator' \
    .context/logs/audit.jsonl
  assert_output "$(printf 'distinct\n0\n25')"
}

@test "issue-close-required: runs from another checkout against an archived ledger" {
  # The megatask merger runs it after the issue worktree and its .context/ are gone.
  _mk_repo_with_default master
  local arch
  arch="$(mk_tmpworkdir)"
  mkdir -p "$arch/logs"
  jq '.run_index = 0 | .tasks.FN0.metadata.base_ref = "develop" | del(.metadata.base_ref)
      | .metadata.github_issue_url = "https://github.com/o/r/issues/497"' \
    .context/state.json > "$arch/state.json"
  rm -rf .context
  run bash "$PLUGIN_ROOT/$SCRIPT" --state "$arch/state.json" --context "$arch" issue-close-required
  assert_success
  assert_output --partial 'gh issue close 497 --comment "Merged into develop."'
  run jq -sr 'map(select(.action=="issue_close_required"))[-1].result' "$arch/logs/audit.jsonl"
  assert_output "required"
}

# --- QA additions: the five degrade rungs no REQ-T1 fixture reached -----------
# AR0 gave every rung its own result token so a wrong-rung regression is visible
# rather than masked by a generic warn. That only holds if each token is pinned,
# so each case below asserts the token, not just the exit status.

_bs_no_jq_path() {
  local dir="$WD/nobin" tool p
  mkdir -p "$dir"
  for tool in git grep sed tr cut date mkdir bash sh env printf true false cat wc awk seq \
    readlink realpath dirname basename pwd rm mv ln; do
    p=$(command -v "$tool" 2> /dev/null) || continue
    ln -sf "$p" "$dir/$tool"
  done
  printf '%s' "$dir"
}

@test "base-sanity rung 1: jq unavailable skips the check as jq_unavailable" {
  _bs_flat_repo 4
  jq '.metadata.base_ref="master"' .context/state.json > s && mv s .context/state.json
  _bs_ledger '["run1.txt"]'
  local nobin
  nobin=$(_bs_no_jq_path)
  run env PATH="$nobin" bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  assert_output --partial "jq unavailable"
  # No audit row is asserted, and that is the finding rather than an oversight:
  # audit_fn reads worktask_id and run_index through jq, so in the one condition
  # this rung fires it cannot write its own token. stdout and exit 0 are the whole
  # observable contract here; see testing-0.md#rung-1-token.
  assert [ ! -e "$WD/.context/logs/audit.jsonl" ]
}

@test "base-sanity rung 2: outside a git work tree the result is no_git" {
  cd "$WD"
  # Deliberately no `git init`: $WD is a temp dir outside any repository.
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  assert_output --partial "not inside a git work tree"
  run _bs_row
  assert_output --partial '"no_git"'
}

@test "base-sanity rung 3: every rank empty reports, never guesses (base_ref_unresolved)" {
  _bs_flat_repo 4
  # No configured base at any rank and no refs/remotes/origin/* for rank 0 to
  # enumerate, so even the opt-in fork point cannot fill it.
  jq 'del(.metadata.base_ref)' .context/state.json > s && mv s .context/state.json
  _bs_ledger '["run1.txt"]'
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  assert_output --partial "reporting, not guessing"
  run _bs_row
  assert_output --partial '"base_ref_unresolved"'
}

@test "base-sanity rung 5: an inferred base is never blocked on (base_guessed)" {
  cd "$WD"
  git init -q -b feature/work .
  _bs_commit --allow-empty -m base
  git update-ref refs/remotes/origin/parent HEAD
  _bs_files run 25
  # Ranks 1-4 empty with one remote branch: rank 0 answers, so the base is
  # fork-point evidence rather than a configured target. The 25-file diff would
  # trip the rule outright — the point is that rung 5 returns before it can.
  jq 'del(.metadata.base_ref)' .context/state.json > s && mv s .context/state.json
  _bs_ledger '["run1.txt"]'
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  refute_output --partial "BLOCKED"
  assert_output --partial "fork-point evidence"
  run _bs_row
  assert_output --partial '"base_guessed"'
  assert_output --partial '"base_source":"fork_point"'
}

# An orphan base shares no merge base with HEAD, so `git diff base...HEAD` exits 128.
# The count must come from git's own status: piping it through `wc -l` yields `0` and
# reads as a legitimately empty diff, which is a false pass on the exact topology this
# check exists to catch.
@test "base-sanity rung 7: a base with no merge base is diff_unreadable, not a 0-file pass" {
  cd "$WD"
  git init -q -b master .
  _bs_commit --allow-empty -m base
  git checkout -q --orphan unrelated
  _bs_commit --allow-empty -m unrelated
  git checkout -q master
  git checkout -q -b feature/work
  _bs_files run 2
  jq '.metadata.base_ref="unrelated"' .context/state.json > s && mv s .context/state.json
  _bs_ledger '["run1.txt","run2.txt"]'
  run bash "$PLUGIN_ROOT/$SCRIPT" base-sanity
  assert_success
  assert_output --partial "is unreadable"
  refute_output --partial "base-sanity: pass"
  run _bs_row
  assert_output --partial '"diff_unreadable"'
}

# --- staging (R-3.2) ---------------------------------------------------------

# seed_repo — a repo with one committed file, ready to dirty.
seed_repo() {
  git init -q .
  printf 'a\n' > a.txt
  printf 'x\n' > b.txt
  git add a.txt b.txt
  git -c user.email=a@b.c -c user.name=t commit -q -m base
}

@test "staging: a clean worktree passes" {
  cd "$WD"
  seed_repo
  run bash "$PLUGIN_ROOT/$SCRIPT" staging
  assert_success
  assert_output --partial "no file is both staged and modified again"
}

@test "staging: a merely unstaged modification passes — it is the normal pre-git-add state" {
  cd "$WD"
  seed_repo
  printf 'edit\n' >> b.txt
  run bash "$PLUGIN_ROOT/$SCRIPT" staging
  assert_success
}

@test "staging: a file staged and then edited again blocks and names the file" {
  cd "$WD"
  seed_repo
  printf 'edit\n' >> b.txt
  git add b.txt
  printf 'again\n' >> b.txt
  run bash "$PLUGIN_ROOT/$SCRIPT" staging
  assert_failure 1
  assert_output --partial "b.txt"
  refute_output --partial "a.txt"
}

@test "staging: the composite command fails on the same condition" {
  cd "$WD"
  seed_repo
  mk_attachments
  mk_body
  printf 'edit\n' >> b.txt
  git add b.txt
  printf 'again\n' >> b.txt
  run bash "$PLUGIN_ROOT/$SCRIPT" all --body "$WD/body.md"
  assert_failure
  assert_output --partial "staged then modified again"
}

@test "staging: a staged control byte blocks, naming the file and offset" {
  cd "$WD"
  seed_repo
  printf 'a\033b\n' > c.txt
  git add c.txt
  run bash "$PLUGIN_ROOT/$SCRIPT" staging
  assert_failure 1
  assert_output --partial "control bytes in staged files"
  assert_output --partial "c.txt:1:0x1B"
}

@test "staging: a clean staged file keeps the existing line" {
  cd "$WD"
  seed_repo
  printf 'clean\n' > c.txt
  git add c.txt
  run bash "$PLUGIN_ROOT/$SCRIPT" staging
  assert_success
  assert_output "staging: no file is both staged and modified again"
}

@test "staging: an empty index reports no control-byte hit and writes no blocked row" {
  cd "$WD"
  seed_repo
  run bash "$PLUGIN_ROOT/$SCRIPT" staging
  assert_success
  assert_output "staging: no file is both staged and modified again"
  refute_output --partial "control bytes"
  [ ! -s .context/logs/audit.jsonl ] || ! grep -q '"action":"staging"' .context/logs/audit.jsonl
}

@test "staging: a control-byte check that cannot run blocks and writes an audit row" {
  cd "$WD"
  seed_repo
  printf 'clean\n' > c.txt
  git add c.txt
  local sha
  sha="$(git rev-parse :c.txt)"
  rm -f ".git/objects/${sha:0:2}/${sha:2}"
  run bash "$PLUGIN_ROOT/$SCRIPT" staging
  assert_failure 1
  assert_output --partial "staged control-byte check could not run"
  run jq -r 'select(.action=="staging") | .result + " " + .metadata.reason' .context/logs/audit.jsonl
  assert_output "blocked control_byte_check_failed"
}

@test "staging: the composite command fails on a staged NUL" {
  cd "$WD"
  seed_repo
  mk_attachments
  mk_body
  printf 'x\000\n' > c.txt
  git add c.txt
  run bash "$PLUGIN_ROOT/$SCRIPT" all --body "$WD/body.md"
  assert_failure
  assert_output --partial "control bytes in staged files"
}

# ---------------------------------------------------------------------------
# resolve_git_ref divergence (AC-4a). The resolver used to try the bare name
# first, so a base branch name resolved to a STALE LOCAL branch whenever one
# existed — and a stale base makes base-sanity's diff wrong in the blocking
# direction. Unlike the arms above these fixtures need a real remote, because
# the whole defect is local-vs-remote-tracking preference.
# ---------------------------------------------------------------------------

# A repo whose local master and origin/master have genuinely diverged:
# remote ahead by $1, local ahead by $2.
_rgr_diverged_repo() { # $1=remote-ahead $2=local-ahead
  local d i; d="$(mk_tmpworkdir)"
  git -C "$d" init -q -b master
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'a\n' > "$d/f"; git -C "$d" add -A; git -C "$d" commit -qm base
  git -C "$d" init -q --bare "$d/remote.git"
  git -C "$d" remote add origin "$d/remote.git"
  git -C "$d" push -q origin master
  git -C "$d" checkout -q -b tmp
  # C-style, not `seq 1 $n`: BSD seq counts DOWN when the limit is below the start,
  # so `seq 1 0` yields "1 0" here and silently made the zero-ahead fixture diverge.
  for ((i = 0; i < $1; i++)); do printf 'r%s\n' "$i" >> "$d/f"; git -C "$d" commit -qam "r$i"; done
  git -C "$d" push -q origin tmp:master
  git -C "$d" checkout -q master
  for ((i = 0; i < $2; i++)); do printf 'l%s\n' "$i" >> "$d/f"; git -C "$d" commit -qam "l$i"; done
  git -C "$d" fetch -q origin
  printf '%s' "$d"
}

# Sourcing the library directly: resolve_git_ref is a pure function of the cwd
# repository, and every subcommand that reaches it needs a full FN fixture around it.
_rgr() { # $1=repo $2=name
  bash -c "sed -n '/^resolve_git_ref() {/,/^}/p' '$PLUGIN_ROOT/skills/worktask/scripts/branch-lib.sh' > '$1/rgr.sh'
           cd '$1' && . ./rgr.sh && resolve_git_ref '$2'"
}

@test "AC-4a: a diverged base resolves to the remote-tracking ref, not the stale local" {
  local d; d="$(_rgr_diverged_repo 2 1)"
  run --separate-stderr _rgr "$d" master
  assert_success
  assert_output "origin/master"
}

@test "AC-4a: divergence is reported with both names and both ahead-counts" {
  local d; d="$(_rgr_diverged_repo 2 1)"
  run --separate-stderr _rgr "$d" master
  assert_success
  [[ "$stderr" == *"origin/master"* ]] || { echo "no remote name: $stderr"; return 1; }
  [[ "$stderr" == *"refs/heads/master"* ]] || { echo "no local name: $stderr"; return 1; }
  [[ "$stderr" == *"ahead by 2 commit(s)"* ]] || { echo "no remote count: $stderr"; return 1; }
  [[ "$stderr" == *"ahead by 1 commit(s)"* ]] || { echo "no local count: $stderr"; return 1; }
}

@test "AC-4a: an in-sync base resolves without a divergence warning" {
  local d; d="$(_rgr_diverged_repo 0 0)"
  run --separate-stderr _rgr "$d" master
  assert_success
  assert_output "origin/master"
  # Not "stderr is empty" — git chatter is not this function's contract; the
  # contract is that an in-sync pair raises no ambiguity.
  [[ "$stderr" != *"diverged"* ]] || { echo "unexpected warning: $stderr"; return 1; }
}

# The fork topology: origin is the contributor's fork and goes stale, upstream is
# canonical and moves on, and local master tracks upstream. Preferring origin/ here
# measures the diff against the stale fork ref and blocks a correctly-based PR.
_rgr_fork_repo() {
  local d; d="$(mk_tmpworkdir)"
  git -C "$d" init -q -b master
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'a\n' > "$d/f"; git -C "$d" add -A; git -C "$d" commit -qm base
  git -C "$d" init -q --bare "$d/fork.git"
  git -C "$d" init -q --bare "$d/canonical.git"
  git -C "$d" remote add origin "$d/fork.git"
  git -C "$d" remote add upstream "$d/canonical.git"
  git -C "$d" push -q origin master
  git -C "$d" push -q upstream master
  # Canonical advances; the fork stays where it was.
  git -C "$d" checkout -q -b tmp
  printf 'u\n' >> "$d/f"; git -C "$d" commit -qam upstream-work
  git -C "$d" push -q upstream tmp:master
  git -C "$d" checkout -q master
  git -C "$d" fetch -q --all
  git -C "$d" branch --set-upstream-to=upstream/master master > /dev/null 2>&1
  printf '%s' "$d"
}

@test "AC-4a: a base tracking a non-origin remote resolves through its upstream" {
  local d; d="$(_rgr_fork_repo)"
  run --separate-stderr _rgr "$d" master
  assert_success
  assert_output "upstream/master"
  refute_output "origin/master"
}

@test "AC-4a: a purely local base with no remote-tracking ref still resolves" {
  local d; d="$(mk_tmpworkdir)"
  git -C "$d" init -q -b master
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'a\n' > "$d/f"; git -C "$d" add -A; git -C "$d" commit -qm base
  git -C "$d" checkout -q -b local-only
  run _rgr "$d" local-only
  assert_success
  assert_output "local-only"
}

@test "AC-4a: an origin-qualified stored value still resolves to the remote ref" {
  local d; d="$(_rgr_diverged_repo 1 1)"
  run --separate-stderr _rgr "$d" origin/master
  assert_success
  assert_output "origin/master"
}

@test "SR: the diverged continuity row refuses a symlinked audit.jsonl" {
  cd "$WD"
  mk_diverged_base integration
  jq '.metadata.base_ref="integration"' .context/state.json > s && mv s .context/state.json
  mkdir -p target-dir .context/logs
  ln -s "$WD/target-dir/escaped.txt" .context/logs/audit.jsonl
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" continuity
  # The fallback itself must still be announced: refusing the row never changes
  # the merge strategy FN0 is told to use.
  assert_success
  [[ "$stderr" == *"cherry-pick"* ]]
  [ ! -e "$WD/target-dir/escaped.txt" ]
}

# ---------- strict PR-body lint gate ----------
# Under strict, the lint's verdict is the gate's verdict; with strict off the lint
# stays advisory and every row matches the pre-strict gate.

# A body complete in every structural rule whose only lint finding is P1: a checkout
# outside the mount list survives every line rule and rebases to `.context/` in the
# final scrub, which the lint then reads back.
mk_p1_body() {
  cat > "$WD/body.md" <<'EOF'
## Motivation

Why.

## Changes

- Scratch notes live at /nonexistent-cf/wt/.context/notes.txt now.

## Test plan

- bats tests/shell/worktask/fn-preflight.bats

Closes #221
EOF
}

# Copies the scripts tree so a test can remove or replace one sibling.
mk_tree() {
  mkdir -p "$WD/tree/skills/worktask"
  cp -R "$PLUGIN_ROOT/skills/worktask/scripts" "$WD/tree/skills/worktask/scripts"
  cp -R "$PLUGIN_ROOT/skills/shared" "$WD/tree/skills/shared"
}

gate_rows() {
  jq -r 'select(.action | test("^pr_body")) | "\(.action):\(.result)"' .context/logs/audit.jsonl
}

@test "F-strict-1: CORPFLOW_PR_BODY_STRICT=1 blocks a P1 finding with a pr_body_lint_findings row" {
  cd "$WD"
  no_screenshots
  mk_p1_body
  run env WORKSPACE_ROOT=/nonexistent-cf/wt CORPFLOW_PR_BODY_STRICT=1 \
    bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_failure 1
  assert_output --partial "BLOCKED: pr-body-lint did not pass under --strict"
  run grep -F '.context/notes.txt' body.md
  assert_success
  run jq -r 'select(.action=="pr_body_gate") | "\(.result):\(.metadata.reason)"' .context/logs/audit.jsonl
  assert_output "blocked:pr_body_lint_findings"
}

@test "F-strict-1b: --strict is equivalent to the environment variable" {
  cd "$WD"
  no_screenshots
  mk_p1_body
  run env WORKSPACE_ROOT=/nonexistent-cf/wt bash "$PLUGIN_ROOT/$SCRIPT" --strict pr-body --body body.md
  assert_failure 1
  run jq -r 'select(.action=="pr_body_gate") | "\(.result):\(.metadata.reason)"' .context/logs/audit.jsonl
  assert_output "blocked:pr_body_lint_findings"
}

@test "F-strict-1c: --strict aborts all before validate-pr" {
  cd "$WD"
  mk_attachments
  no_screenshots
  mk_p1_body
  run env WORKSPACE_ROOT=/nonexistent-cf/wt bash "$PLUGIN_ROOT/$SCRIPT" --strict all --body body.md
  assert_failure 1
  refute_output --partial "closes #221"
}

@test "F-strict-2: strict off, a lint finding stays advisory and the rows are unchanged" {
  cd "$WD"
  no_screenshots
  mk_body
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
  assert_output --partial "composition gate passed"
  run gate_rows
  assert_output "$(printf 'pr_body_sanitised:unchanged\npr_body_lint:warned\npr_body_gate:ok')"
}

@test "F-strict-3: MILESTONE_MODE=1 with strict on never blocks" {
  cd "$WD"
  mk_p1_body
  run env MILESTONE_MODE=1 WORKSPACE_ROOT=/nonexistent-cf/wt CORPFLOW_PR_BODY_STRICT=1 \
    bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
  run jq -r 'select(.action=="pr_body_gate") | .result' .context/logs/audit.jsonl
  assert_output "skipped"
}

@test "F-strict-4: a punctuation-glued host path is scrubbed from the final body" {
  cd "$WD"
  no_screenshots
  cat > body.md <<'EOF'
Logs (/Users/korich/secret/run.log) kept.

## Test plan

- bats tests/shell/worktask/fn-preflight.bats

Closes #221
EOF
  run bash "$PLUGIN_ROOT/$SCRIPT" pr-body --body body.md
  assert_success
  run cat body.md
  assert_output --partial "Logs ([local-path]) kept."
  refute_output --partial "/Users/"
}

@test "F-strict-5: strict blocks a lint that errors or cannot run" {
  cd "$WD"
  no_screenshots
  mk_body
  mk_tree
  local lint="$WD/tree/skills/worktask/scripts/pr-body-lint.sh"
  printf '#!/usr/bin/env bash\nexit 2\n' > "$lint"
  chmod +x "$lint"
  run env CORPFLOW_PR_BODY_STRICT=1 bash "$WD/tree/skills/worktask/scripts/fn-preflight.sh" pr-body --body body.md
  assert_failure 1
  run jq -r 'select(.action=="pr_body_gate") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "pr_body_lint_error"

  rm -f .context/logs/audit.jsonl
  chmod -x "$lint"
  run env CORPFLOW_PR_BODY_STRICT=1 bash "$WD/tree/skills/worktask/scripts/fn-preflight.sh" pr-body --body body.md
  assert_failure 1
  run jq -r 'select(.action=="pr_body_gate") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "pr_body_lint_unavailable"
}

@test "F12b: a missing path-scrub.sh blocks the PR path as an unavailable sanitiser" {
  cd "$WD"
  no_screenshots
  mk_body
  mk_tree
  rm -f "$WD/tree/skills/shared/scripts/path-scrub.sh"
  run bash "$WD/tree/skills/worktask/scripts/fn-preflight.sh" pr-body --body body.md
  assert_failure 1
  assert_output --partial "sanitiser unavailable"
  run jq -r 'select(.action=="pr_body_gate") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "sanitiser_unavailable"
}

# ---------- unresolved-decisions ----------
# One escalate item shipped unprompted under a bypassed FN gate. The row is logged twice so
# the dedupe is exercised, and the question names a host path so the scrub is.
mk_ud_fixture() {
  jq '.tasks.PL0 = {status:"completed", metadata:{fn_gate:"bypass"}}' "$WD/.context/state.json" > "$WD/s" \
    && mv "$WD/s" "$WD/.context/state.json"
  local i
  for i in 1 2; do
    ud_row sw-SR0-1 security-review-0.md#elicitation-sweep '{}'
  done
  cat > "$WD/.context/security-review-0.md" <<'EOF'
# Security review

## elicitation-sweep

- id: sw-SR0-1
  class: escalate
  summary: "Ship with the debug token written to /Users/korich/secret/token.json?"
EOF
}

ud_row() {  # <id> <ref> <extra-metadata-json>
  jq -cn --arg id "$1" --arg ref "$2" --argjson x "$3" \
    '{ts:"2026-01-01T00:00:00Z", actor:"orchestrator", action:"sweep_escalation_unprompted",
      subject:"FN0", result:"recorded", metadata:({id:$id, stage:"SR", ref:$ref} + $x)}' \
    >> "$WD/.context/logs/audit.jsonl"
}

ud_expected() {
  printf '%s\n' '## Unresolved decisions' '' \
    'These escalation-class questions shipped without a decision in an unattended run.' '' \
    '- **sw-SR0-1** (SR0): Ship with the debug token written to [local-path]?'
}

ud_result() {
  jq -r 'select(.action=="unresolved_decisions_emitted")
         | "\(.result):\(if .result == "blocked" then .metadata.reason else .metadata.count end)"' \
    .context/logs/audit.jsonl
}

@test "UD1: unresolved-decisions writes the scrubbed block at byte 0 and lists the item once" {
  cd "$WD"
  mk_body
  mk_ud_fixture
  cp body.md orig.md
  run bash "$PLUGIN_ROOT/$SCRIPT" unresolved-decisions --body body.md
  assert_success
  run head -1 body.md
  assert_output "## Unresolved decisions"
  { ud_expected; printf '\n'; cat orig.md; } > want.md
  cmp -s body.md want.md || fail "body differs from block + original:
$(diff want.md body.md)"
  run grep -c 'Users/' body.md
  assert_output "0"
  run ud_result
  assert_output "ok:1"
}

@test "UD2: a second run over its own output is byte-identical" {
  cd "$WD"
  mk_body
  mk_ud_fixture
  bash "$PLUGIN_ROOT/$SCRIPT" unresolved-decisions --body body.md
  cp body.md once.md
  run bash "$PLUGIN_ROOT/$SCRIPT" unresolved-decisions --body body.md
  assert_success
  cmp -s body.md once.md || fail "second run changed the body:
$(diff once.md body.md)"
}

@test "UD3: --print emits the same scrubbed block and leaves the body alone" {
  cd "$WD"
  mk_body
  mk_ud_fixture
  cp body.md orig.md
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" unresolved-decisions --body body.md --print
  assert_success
  [ "$output" = "$(ud_expected)" ] || fail "print output: $output"
  cmp -s body.md orig.md || fail "--print modified the body"
  bash "$PLUGIN_ROOT/$SCRIPT" unresolved-decisions --body body.md
  [ "$(head -5 body.md)" = "$output" ] || fail "--print and --body rendered different blocks"
}

@test "UD4: rows marked for another run are not listed; unmarked rows are" {
  cd "$WD"
  mk_body
  mk_ud_fixture
  ud_row sw-SR0-8 security-review-0.md#elicitation-sweep '{"run_index":1}'
  ud_row sw-SR0-9 security-review-0.md#elicitation-sweep '{"dedupe_key":"wt-demo:1:sweep_escalation_unprompted"}'
  ud_row sw-QA0-2 '#elicitation-sweep' '{"dedupe_key":"wt-demo:2:sweep_escalation_unprompted"}'
  run bash "$PLUGIN_ROOT/$SCRIPT" unresolved-decisions --body body.md
  assert_success
  run cat body.md
  refute_output --partial "sw-SR0-8"
  refute_output --partial "sw-SR0-9"
  # An anchor-only ref names no file to read, so the bullet falls back to the id alone.
  assert_line "- **sw-QA0-2** (QA0)"
  run ud_result
  assert_output "ok:2"
}

@test "UD5: all runs unresolved-decisions before every other check" {
  cd "$WD"
  mk_attachments
  no_screenshots
  mk_body
  mk_ud_fixture
  run bash "$PLUGIN_ROOT/$SCRIPT" all --body body.md
  assert_success
  run head -1 body.md
  assert_output "## Unresolved decisions"
  run jq -rs 'map(.action) | map(select(. == "unresolved_decisions_emitted" or . == "pr_body_sanitised")) | join(",")' \
    .context/logs/audit.jsonl
  assert_output "unresolved_decisions_emitted,pr_body_sanitised"
}

@test "UD6: an unreadable path-scrub.sh publishes nothing: exit 1, body byte-identical" {
  cd "$WD"
  mk_body
  mk_ud_fixture
  mk_tree
  cp body.md orig.md
  rm -f "$WD/tree/skills/shared/scripts/path-scrub.sh"
  run bash "$WD/tree/skills/worktask/scripts/fn-preflight.sh" unresolved-decisions --body body.md
  assert_failure 1
  assert_output --partial "nothing published"
  cmp -s body.md orig.md || fail "body changed on a blocked run"
  run ud_result
  assert_output "blocked:scrub_unavailable"
}

@test "UD7: a scrub missing its function or an ERE, or exiting non-zero, publishes nothing on either route" {
  cd "$WD"
  mk_body
  mk_ud_fixture
  mk_tree
  cp body.md orig.md
  local lib="$WD/tree/skills/shared/scripts/path-scrub.sh" variant
  for variant in \
    'CORPFLOW_HOST_PATH_ERE=x; CORPFLOW_DRIVE_PATH_ERE=y' \
    'CORPFLOW_HOST_PATH_ERE=; CORPFLOW_DRIVE_PATH_ERE=y; corpflow_path_scrub() { cat; }' \
    'CORPFLOW_HOST_PATH_ERE=x; CORPFLOW_DRIVE_PATH_ERE=; corpflow_path_scrub() { cat; }' \
    'CORPFLOW_HOST_PATH_ERE=x; CORPFLOW_DRIVE_PATH_ERE=y; corpflow_path_scrub() { cat > /dev/null; return 1; }'; do
    printf '%s\n' "$variant" > "$lib"
    run bash "$WD/tree/skills/worktask/scripts/fn-preflight.sh" unresolved-decisions --body body.md
    [ "$status" -eq 1 ] || fail "--body exit $status for: $variant"
    cmp -s body.md orig.md || fail "body changed for: $variant"
    run --separate-stderr bash "$WD/tree/skills/worktask/scripts/fn-preflight.sh" unresolved-decisions --print
    [ "$status" -eq 1 ] || fail "--print exit $status for: $variant"
    [ -z "$output" ] || fail "--print published for: $variant: $output"
  done
}

@test "UD8: zero rows leave the body untouched, exit 0, and never source the scrub" {
  cd "$WD"
  mk_body
  mk_tree
  cp body.md orig.md
  # A scrub that would fail if sourced: the zero-row path must not reach it.
  rm -f "$WD/tree/skills/shared/scripts/path-scrub.sh"
  run bash "$WD/tree/skills/worktask/scripts/fn-preflight.sh" unresolved-decisions --body body.md
  assert_success
  cmp -s body.md orig.md || fail "zero-row run changed the body"
  run ud_result
  assert_output "none:0"
}

@test "UD9: unresolved-decisions without --body or --print is a usage error" {
  cd "$WD"
  run bash "$PLUGIN_ROOT/$SCRIPT" unresolved-decisions
  assert_failure 2
  assert_output --partial "requires --body"
}

@test "UD10: a question naming a context path or stage artifact survives pr-body as an id-only bullet" {
  cd "$WD"
  mk_attachments
  no_screenshots
  mk_body
  mk_ud_fixture
  # pr-body's sanitiser drops whole lines naming `.context/` or `<stage>-N.md`.
  cat > "$WD/.context/security-review-0.md" <<'EOF'
# Security review

## elicitation-sweep

- id: sw-SR0-1
  class: escalate
  summary: "Ship with the token logged in .context/logs/x.json, per security-review-0.md?"
EOF
  run bash "$PLUGIN_ROOT/$SCRIPT" all --body body.md
  assert_success
  run head -1 body.md
  assert_output "## Unresolved decisions"
  run grep -cFx -- '- **sw-SR0-1** (SR0)' body.md
  assert_output "1"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" unresolved-decisions --print
  assert_success
  [ "$output" = "$(head -5 body.md)" ] || fail "--print differs from the published block:
$output
---
$(head -5 body.md)"
}

@test "UD11: --print with any other command is a usage error and runs nothing" {
  cd "$WD"
  mk_attachments
  no_screenshots
  mk_body
  mk_ud_fixture
  cp body.md orig.md
  run bash "$PLUGIN_ROOT/$SCRIPT" all --body body.md --print
  assert_failure 2
  assert_output --partial "--print applies only to unresolved-decisions"
  cmp -s body.md orig.md || fail "a rejected --print still changed the body"
  run bash -c "grep -c unresolved_decisions_emitted .context/logs/audit.jsonl || true"
  assert_output "0"
}

@test "UD12: the question cap counts characters, so a multibyte character is never split" {
  cd "$WD"
  mk_body
  mk_ud_fixture
  local head299
  head299="$(printf 'a%.0s' $(seq 1 299))"
  printf '# Security review\n\n## elicitation-sweep\n\n- id: sw-SR0-1\n  class: escalate\n  summary: "%s\xe2\x80\x94bbb?"\n' \
    "$head299" > "$WD/.context/security-review-0.md"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" unresolved-decisions --print
  assert_success
  assert_line "- **sw-SR0-1** (SR0): ${head299}"$'\xe2\x80\x94'
}

# ---------------------------------------------------------------------------
# continuity per-stream mode: entered only with >=2 facts.stream_branches keys.
# Full merge fixtures live in fn-stream-merge.bats; these pin the mode switch.
# ---------------------------------------------------------------------------

@test "continuity: one stream_branches key keeps the legacy path and its diverged row" {
  cd "$WD"
  mk_diverged_base integration
  jq '.metadata.base_ref="integration" | .facts.stream_branches={"only":"integration"}' \
    .context/state.json > s && mv s .context/state.json
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" continuity
  assert_success
  run jq -r 'select(.action=="branch_continuity") | .result' .context/logs/audit.jsonl
  assert_output "diverged_cherry_pick"
}

@test "continuity: two merged stream branches pass with stream_merged rows only" {
  cd "$WD"
  git init -q -b main .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "base"
  git branch -q s-a
  git branch -q s-b
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "combined work"
  jq '.metadata.base_ref="main" | .facts.stream_branches={"a":"s-a","b":"s-b"}' \
    .context/state.json > s && mv s .context/state.json
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" continuity
  assert_success
  assert_output --partial "every stream branch is merged into HEAD"
  run jq -r 'select(.action=="branch_continuity") | .result' .context/logs/audit.jsonl
  assert_output "$(printf 'stream_merged\nstream_merged')"
}

@test "continuity: an unmerged or unknown stream branch blocks all, after checking every stream" {
  cd "$WD"
  git init -q -b main .
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "base"
  git checkout -q -b s-a
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "stream a only"
  git checkout -q main
  jq '.metadata.base_ref="main" | .facts.stream_branches={"a":"s-a","b":"no-such-branch"}' \
    .context/state.json > s && mv s .context/state.json
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" continuity
  assert_failure 1
  [[ "$stderr" == *"stream a branch s-a"* ]]
  [[ "$stderr" == *"stream b branch no-such-branch"* ]]
  run jq -r 'select(.action=="branch_continuity") | .result' .context/logs/audit.jsonl
  assert_output "$(printf 'stream_unmerged\nstream_unmerged')"
}
