#!/usr/bin/env bats
# Contract tests for skills/worktask/scripts/branch-name.sh — the PL-stage entry
# point. Migrated from fn-preflight.bats's F18-F21c (rewritten for the ticket-less
# target and the new --goal/--check/--print-types argument surface), plus new cases.
# Canonical grammar/vocabulary/guard-ladder/exit-code contract:
# skills/shared/git-conventions.md § Branch Naming.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"
bats_require_minimum_version 1.5.0

SCRIPT="skills/worktask/scripts/branch-name.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context/logs"
  cat > "$WD/.context/state.json" <<'EOF'
{"version":1,"worktask_id":"wt-demo","run_index":0,"platform":"systems",
 "plan_file":".context/planning-0.md","tasks":{},"facts":{},"handoffs":{},"metadata":{}}
EOF
}

mk_branch_repo() {
  local branch="${1:-wt-abc123}" goal="${2:-Fix PR composition and branch naming}"
  git init -q -b "$branch" "$WD"
  git -C "$WD" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "work"
  jq --arg g "$goal" '.facts.goal = $g' "$WD/.context/state.json" > "$WD/s" \
    && mv "$WD/s" "$WD/.context/state.json"
}

# ---------------------------------------------------------------------------
# Migrated (6)
# ---------------------------------------------------------------------------

@test "M1: renames an anonymous branch to <type>/<slug>, no ticket" {
  cd "$WD"
  mk_branch_repo
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "->"
  assert_line --index 1 "target_branch=bugfix/fix-pr-composition-and-branch-naming"
  # `branch=` stays the FINAL line — four docs and every consumer specify that parse.
  assert_line --index "$((${#lines[@]} - 1))" "branch=bugfix/fix-pr-composition-and-branch-naming"
  run git rev-parse --abbrev-ref HEAD
  assert_output "bugfix/fix-pr-composition-and-branch-naming"
  run jq -r 'select(.action=="branch_renamed") | .result' .context/logs/audit.jsonl
  assert_output "ok"
}

@test "M2: second run is a no-op (idempotency)" {
  cd "$WD"
  mk_branch_repo
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  local first
  first=$(git rev-parse --abbrev-ref HEAD)
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  # Since R6 the second run is refused by the LEDGER guard (already_named), which sits
  # above already_conventional — the no-op the case is about is unchanged, its reason is
  # now the stronger one that also holds after a third-party rename (AD-12).
  assert_line --index 0 --partial "already named this run"
  run git rev-parse --abbrev-ref HEAD
  assert_output "$first"
}

@test "M3: refuses to rename a branch with an upstream" {
  cd "$WD"
  mk_branch_repo
  git remote add origin https://example.invalid/r.git
  git update-ref refs/remotes/origin/wt-abc123 HEAD
  git branch --set-upstream-to=origin/wt-abc123 wt-abc123 > /dev/null
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "upstream already tracked"
  run git rev-parse --abbrev-ref HEAD
  assert_output "wt-abc123"
  run jq -r 'select(.action=="branch_renamed") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "upstream_tracked"
}

@test "M4: self-disables under batch (MILESTONE_MODE) routing" {
  cd "$WD"
  mk_branch_repo
  run env MILESTONE_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "skipped (milestone_mode_env)"
  run git rev-parse --abbrev-ref HEAD
  assert_output "wt-abc123"
}

@test "M5: refuses to rename the integration branch itself" {
  cd "$WD"
  git init -q -b master "$WD"
  git -C "$WD" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "work"
  jq '.facts.goal = "Fix things" | .metadata.base_ref = "master"' .context/state.json > s \
    && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "integration branch"
  run git rev-parse --abbrev-ref HEAD
  assert_output "master"
}

@test "M6: BRANCH_NAME_PRINT=1 prints the bare target and renames nothing" {
  cd "$WD"
  mk_branch_repo
  run env BRANCH_NAME_PRINT=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output "bugfix/fix-pr-composition-and-branch-naming"
  run git rev-parse --abbrev-ref HEAD
  assert_output "wt-abc123"
}

@test "detached HEAD prints branch= empty, never the literal token HEAD" {
  cd "$WD"
  mk_branch_repo
  git checkout -q --detach HEAD
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "detached HEAD"
  assert_line --index 1 "target_branch="
  assert_line --index 2 "branch="
}

# ---------------------------------------------------------------------------
# New (7)
# ---------------------------------------------------------------------------

@test "N1: fresh anonymous branch renames via an explicit --goal argument" {
  cd "$WD"
  git init -q -b anon-branch "$WD"
  git -C "$WD" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "work"
  run bash "$PLUGIN_ROOT/$SCRIPT" --goal "Add a new login flow"
  assert_success
  run git rev-parse --abbrev-ref HEAD
  assert_output "feature/add-a-new-login-flow"
}

@test "N2: target shape is feature/<slug> with no trailing -<digits> ticket segment" {
  cd "$WD"
  mk_branch_repo wt-xyz "Add a new login flow"
  run env BRANCH_NAME_PRINT=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  refute_output --regexp -- '-[0-9]+$'
  assert_output "feature/add-a-new-login-flow"
}

@test "N3: already-conventional long form (feature/) is a no-op" {
  cd "$WD"
  mk_branch_repo "feature/already-named-thing"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "already conventional"
  run git rev-parse --abbrev-ref HEAD
  assert_output "feature/already-named-thing"
}

@test "N4: already-conventional short form (feat/) is a no-op" {
  cd "$WD"
  mk_branch_repo "feat/221-already-named"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "already conventional"
  run git rev-parse --abbrev-ref HEAD
  assert_output "feat/221-already-named"
}

@test "N4b: an existing fix/<slug> branch is non-conventional and gets renamed to bugfix/" {
  cd "$WD"
  mk_branch_repo "fix/crash-on-startup" "Fix crash on startup"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "->"
  run git rev-parse --abbrev-ref HEAD
  assert_output "bugfix/fix-crash-on-startup"
}

@test "N4c: a goal containing hotfix yields hotfix/<slug>, not bugfix/<slug>" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "Ship a hotfix for the login crash"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run git rev-parse --abbrev-ref HEAD
  assert_output "hotfix/ship-a-hotfix-for-the-login-crash"
}

@test "N4d: a goal carrying an issue key yields <type>/<ticket>-<slug> (D2)" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "OV-164 Product images blink on catalog open"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run git rev-parse --abbrev-ref HEAD
  assert_output "bugfix/ov-164-product-images-blink-on-catalog-open"
}

@test "N4e: a long ticketed goal never lands on a mid-word slug (D3)" {
  cd "$WD"
  mk_branch_repo "wt-abc123" \
    "OV-164 Product list images are blinking before rendering on the catalog screen"
  # --separate-stderr: this goal truncates, and the dry run reports that on stderr. The
  # assertion here is about the STDOUT contract (bare target, directly substitutable).
  run --separate-stderr env BRANCH_NAME_PRINT=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output "bugfix/ov-164-product-list-images-are-blinking-before"
}

@test "N4f: a goal ending in the word fix is a bugfix, not a feature (D4)" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "Images blink on catalog open, investigate and fix"
  run env BRANCH_NAME_PRINT=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output "bugfix/images-blink-on-catalog-open-investigate-and-fix"
}

@test "N4g: the shipped fix/catalog-image-blinking branch is renamed, not accepted (D1)" {
  cd "$WD"
  mk_branch_repo "fix/catalog-image-blinking" "Catalog images blink before rendering"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "->"
  run git rev-parse --abbrev-ref HEAD
  assert_output "bugfix/catalog-images-blink-before-rendering"
}

@test "N4h: an existing ticketed branch is conventional and never churned (D2)" {
  cd "$WD"
  mk_branch_repo "bugfix/ov-156-reconstruction-scan-flow" "OV-156 reconstruction scan flow"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "already conventional"
  run git rev-parse --abbrev-ref HEAD
  assert_output "bugfix/ov-156-reconstruction-scan-flow"
}

@test "N5: upstream present is a no-op (exit 0)" {
  cd "$WD"
  mk_branch_repo
  git remote add origin https://example.invalid/r.git
  git update-ref refs/remotes/origin/wt-abc123 HEAD
  git branch --set-upstream-to=origin/wt-abc123 wt-abc123 > /dev/null
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
}

@test "N6: on the integration branch is a no-op (exit 0)" {
  cd "$WD"
  git init -q -b master "$WD"
  git -C "$WD" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "work"
  jq '.metadata.base_ref = "master"' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
}

# Guard ladder, unchanged by the ticket/slug/type work — every arm still a no-op or a
# refusal, never a failure. Arms: already conventional (N3/N4/N4h), upstream tracked
# (M3/N5), integration branch (M5/N6), target exists (below + SR-1), detached HEAD /
# not a repo (the detached-HEAD case above).
@test "N6b: target exists is still a no-op when the target carries a ticket segment" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "OV-156 reconstruction scan flow"
  git branch feature/ov-156-reconstruction-scan-flow
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "already exists"
  run git rev-parse --abbrev-ref HEAD
  assert_output "wt-abc123"
  run jq -r 'select(.action=="branch_renamed") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "target_exists"
}

@test "N7: self-disables under incident (INCIDENT_MODE) routing" {
  cd "$WD"
  mk_branch_repo
  run env INCIDENT_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "skipped (incident_mode_env)"
  run git rev-parse --abbrev-ref HEAD
  assert_output "wt-abc123"
}

# ---------------------------------------------------------------------------
# already_conventional audit row (sign-off 3 / AC-9)
# ---------------------------------------------------------------------------

@test "already_conventional emits a noop audit row, not just a stdout partial" {
  cd "$WD"
  mk_branch_repo "feature/already-named-thing"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output --partial "no-op"
  run jq -r 'select(.action=="branch_renamed") | .result' .context/logs/audit.jsonl
  assert_output "noop"
  run jq -r 'select(.action=="branch_renamed") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "already_conventional"
}

@test "audit row records origin_stage PL, and actor orchestrator when no stage runs the rename" {
  cd "$WD"
  mk_branch_repo
  run env -u CLAUDE_TASK_METADATA_STAGE -u CORPFLOW_AUDIT_ACTOR bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run jq -r 'select(.action=="branch_renamed") | .actor' .context/logs/audit.jsonl
  assert_output "orchestrator"
  run jq -r 'select(.action=="branch_renamed") | .metadata.origin_stage' .context/logs/audit.jsonl
  assert_output "PL"
  run jq -r 'select(.action=="branch_renamed") | .subject' .context/logs/audit.jsonl
  assert_output "PL0"
}

# ---------------------------------------------------------------------------
# Batch-created shape recognised + the binding feature/lyon assertion (AC-4/AC-5)
# ---------------------------------------------------------------------------

@test "a batch-created feature/42-<slug> branch is recognised as conventional" {
  b=$(bash "$PLUGIN_ROOT/skills/shared/milestone-helpers/scripts/milestone-helpers.sh" \
    branch-name 42 "Add login flow")
  run bash "$PLUGIN_ROOT/$SCRIPT" --check "$b"
  assert_success
}

@test "AC-5 (binding): feature/lyon is recognised as conventional via --check only" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --check "feature/lyon"
  assert_success
}

@test "--check: a non-conventional name returns exit 1, silent" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --check "wt-abc123"
  assert_failure 1
  assert_output ""
}

@test "--print-types: emits the 13-token vocabulary, one per line, no fix" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --print-types
  assert_success
  assert_equal "${#lines[@]}" 13
  assert_line "feature"
  assert_line "feat"
  assert_line "bugfix"
  assert_line "hotfix"
  refute_line "fix"
}

@test "actor: a stage running the rename is named by the agent that owns it" {
  cd "$WD"
  mk_branch_repo
  run env -u CORPFLOW_AUDIT_ACTOR CLAUDE_TASK_METADATA_STAGE=FN bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run jq -r 'select(.action=="branch_renamed") | .actor' .context/logs/audit.jsonl
  assert_output "project-manager"
}

@test "actor: with no stage running, an exact in-set override is honoured" {
  cd "$WD"
  mk_branch_repo
  run env -u CLAUDE_TASK_METADATA_STAGE CORPFLOW_AUDIT_ACTOR=developer bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run jq -r 'select(.action=="branch_renamed") | .actor' .context/logs/audit.jsonl
  assert_output "developer"
}

@test "actor: while a stage runs, an override naming another stage's agent is refused" {
  cd "$WD"
  mk_branch_repo
  run env CORPFLOW_AUDIT_ACTOR=technical-lead CLAUDE_TASK_METADATA_STAGE=DV bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run jq -r 'select(.action=="branch_renamed") | .actor' .context/logs/audit.jsonl
  assert_output "developer"
}

@test "actor: an override carrying two actor names is refused, not matched as a substring" {
  cd "$WD"
  mk_branch_repo
  run env -u CLAUDE_TASK_METADATA_STAGE CORPFLOW_AUDIT_ACTOR='developer technical-lead' bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run jq -r 'select(.action=="branch_renamed") | .actor' .context/logs/audit.jsonl
  assert_output "orchestrator"
}

@test "actor: an invalid CORPFLOW_AUDIT_ACTOR is never written; the ladder answers" {
  cd "$WD"
  mk_branch_repo
  run env -u CLAUDE_TASK_METADATA_STAGE CORPFLOW_AUDIT_ACTOR='corpflow:developer' bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run jq -r 'select(.action=="branch_renamed") | .actor' .context/logs/audit.jsonl
  assert_output "orchestrator"
}

@test "actor: an override outside the closed actor set is refused" {
  cd "$WD"
  mk_branch_repo
  run env -u CLAUDE_TASK_METADATA_STAGE CORPFLOW_AUDIT_ACTOR=not-a-stage-agent bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run jq -r 'select(.action=="branch_renamed") | .actor' .context/logs/audit.jsonl
  assert_output "orchestrator"
}

@test "actor: the library-unreachable row follows the same ladder as branch-lib" {
  cd "$WD"
  mk_branch_repo
  mkdir -p lonely
  cp "$PLUGIN_ROOT/$SCRIPT" lonely/branch-name.sh
  local code want got
  for code in PL AR TL DV DR SR QA DC RE FN ST IR XX ""; do
    want=$(env -u CORPFLOW_AUDIT_ACTOR CLAUDE_TASK_METADATA_STAGE="$code" \
      bash -c ". '$PLUGIN_ROOT/skills/worktask/scripts/branch-lib.sh'; branch_audit_actor")
    env -u CORPFLOW_AUDIT_ACTOR CLAUDE_TASK_METADATA_STAGE="$code" bash lonely/branch-name.sh > /dev/null 2>&1
    got=$(jq -rs 'map(select(.action=="branch_renamed")) | last | .actor' .context/logs/audit.jsonl)
    [ "$got" = "$want" ] || fail "stage '$code': fallback wrote '$got', library answers '$want'"
  done
  local pair ov
  for pair in "technical-lead|DV" "orchestrator|DV" "developer|" "developer technical-lead|" \
    "not-a-stage-agent|QA" "Bad Actor!|QA"; do
    ov="${pair%%|*}"
    code="${pair#*|}"
    want=$(env CORPFLOW_AUDIT_ACTOR="$ov" CLAUDE_TASK_METADATA_STAGE="$code" \
      bash -c ". '$PLUGIN_ROOT/skills/worktask/scripts/branch-lib.sh'; branch_audit_actor")
    env CORPFLOW_AUDIT_ACTOR="$ov" CLAUDE_TASK_METADATA_STAGE="$code" bash lonely/branch-name.sh > /dev/null 2>&1
    got=$(jq -rs 'map(select(.action=="branch_renamed")) | last | .actor' .context/logs/audit.jsonl)
    [ "$got" = "$want" ] || fail "override '$ov' at stage '$code': fallback wrote '$got', library answers '$want'"
  done
}

# ---------------------------------------------------------------------------
# T4 (branch-name.sh half) — branch-lib.sh unreachable.
# ---------------------------------------------------------------------------

@test "T4: unreachable branch-lib.sh — rename mode exits 0 with a warning and a noop row" {
  cd "$WD"
  mk_branch_repo
  # Safe pattern (never mv the tracked library — an interrupt would leave the
  # plugin broken): copy branch-name.sh alone into a sibling-free temp dir.
  mkdir -p lonely
  cp "$PLUGIN_ROOT/$SCRIPT" lonely/branch-name.sh
  run --separate-stderr bash lonely/branch-name.sh
  assert_success
  # DR-3: the warning is on stderr specifically, not merely "present somewhere"
  # in the merged stream that --separate-stderr would otherwise hide.
  assert [ -n "$stderr" ]
  [[ "$stderr" == *"branch-lib.sh"* ]]
  assert_output --partial "library unreachable — skipped"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "branch=wt-abc123"
  run git rev-parse --abbrev-ref HEAD
  assert_output "wt-abc123"
  run jq -r 'select(.action=="branch_renamed") | .result' .context/logs/audit.jsonl
  assert_output "noop"
  run jq -r 'select(.action=="branch_renamed") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "branch_lib_unreachable"
  run jq -r 'select(.action=="branch_renamed") | .metadata.origin_stage' .context/logs/audit.jsonl
  assert_output "PL"
}

@test "T4: unreachable branch-lib.sh — --check exits 2 with a diagnostic" {
  cd "$WD"
  mkdir -p lonely
  cp "$PLUGIN_ROOT/$SCRIPT" lonely/branch-name.sh
  run --separate-stderr bash lonely/branch-name.sh --check "feature/lyon"
  assert_failure 2
  [[ "$stderr" == *"branch-lib.sh"* ]]
}

# ---------------------------------------------------------------------------
# Usage / argument surface
# ---------------------------------------------------------------------------

@test "--goal without a value is a usage error (exit 2)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --goal
  assert_failure 2
}

@test "--state without a value is a usage error (exit 2)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --state
  assert_failure 2
}

@test "--context without a value is a usage error (exit 2)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --context
  assert_failure 2
}

@test "--check without a value is a usage error (exit 2)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --check
  assert_failure 2
}

@test "unknown argument is a usage error (exit 2)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --bogus
  assert_failure 2
}

@test "-h/--help exits 2 and prints the header" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --help
  assert_failure 2
  assert_output --partial "branch-name.sh"
}

# ---------------------------------------------------------------------------
# SR0 rework — SR-1 (HIGH, CWE-78/88), SR-4 (MEDIUM, CWE-427), SR-3
# (MEDIUM, CWE-778), SR-5 (LOW).
# ---------------------------------------------------------------------------

# git-legal, shell-hostile: `;`, `|`, `&`, backtick and `$(` are all permitted
# in a ref name by `git check-ref-format --branch`, but not by bash. No space
# (git rejects a space in a ref name outright) — mirrors security-review-0.md's
# executed PoC shape exactly (`fix/a$(id>/tmp/...)`).
HOSTILE_BRANCH='fix/a$(id>/tmp/branch-name-sr1-marker)'

mk_hostile_repo() {
  local marker="$1"
  rm -f "$marker"
  git init -q -b main "$WD"
  git -C "$WD" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m work
  git -C "$WD" branch -m "$HOSTILE_BRANCH"
}

@test "SR-1 (HIGH, PoC): upstream_tracked arm never emits the raw hostile branch" {
  cd "$WD"
  local marker="/tmp/branch-name-sr1-marker-a"
  mk_hostile_repo "$marker"
  git remote add origin https://example.invalid/r.git
  git update-ref "refs/remotes/origin/${HOSTILE_BRANCH}" HEAD
  git branch --set-upstream-to="origin/${HOSTILE_BRANCH}" "$HOSTILE_BRANCH" > /dev/null
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "upstream already tracked"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "branch="
  refute_output --partial 'fix/a$('
  [ ! -e "$marker" ]
}

@test "SR-1: on_integration_branch arm never emits the hostile branch in the branch= line" {
  cd "$WD"
  local marker="/tmp/branch-name-sr1-marker-b"
  mk_hostile_repo "$marker"
  jq --arg b "$HOSTILE_BRANCH" '.metadata.base_ref = $b' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "integration branch"
  # The human-readable diagnostic MAY echo the raw name (operator-facing log
  # text, never re-interpolated) — only the `branch=` line is the contract
  # surface FN consumes, and that line specifically must never carry it.
  assert_line --index "$(( ${#lines[@]} - 1 ))" "branch="
  [ ! -e "$marker" ]
}

@test "SR-1: jq_unavailable arm never emits the raw hostile branch" {
  cd "$WD"
  local marker="/tmp/branch-name-sr1-marker-c"
  mk_hostile_repo "$marker"
  local nobin
  nobin="$WD/nobin"
  mkdir -p "$nobin"
  local tool
  for tool in git grep sed tr cut date mkdir bash sh env printf true false cat awk readlink dirname; do
    local p
    p=$(command -v "$tool" 2> /dev/null) || continue
    ln -sf "$p" "$nobin/$tool"
  done
  run env PATH="$nobin" bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index "$(( ${#lines[@]} - 1 ))" "branch="
  refute_output --partial 'fix/a$('
  [ ! -e "$marker" ]
}

@test "SR-1: fn_batch_scope (MILESTONE_MODE) arm never emits the raw hostile branch" {
  cd "$WD"
  local marker="/tmp/branch-name-sr1-marker-d"
  mk_hostile_repo "$marker"
  run env MILESTONE_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index "$(( ${#lines[@]} - 1 ))" "branch="
  refute_output --partial 'fix/a$('
  [ ! -e "$marker" ]
}

@test "SR-1: target_exists arm never emits the raw hostile branch" {
  cd "$WD"
  local marker="/tmp/branch-name-sr1-marker-e"
  mk_hostile_repo "$marker"
  jq '.facts.goal = "Add login flow"' .context/state.json > s && mv s .context/state.json
  git branch feature/add-login-flow
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "already exists"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "branch="
  refute_output --partial 'fix/a$('
  [ ! -e "$marker" ]
}

@test "SR-5: no arm emits the literal token HEAD — detached + batch/incident + library-unreachable" {
  cd "$WD"
  mk_branch_repo
  git checkout -q --detach HEAD
  run env MILESTONE_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  refute_line "branch=HEAD"
  assert_line --index "$(( ${#lines[@]} - 1 ))" "branch="

  run env INCIDENT_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  refute_line "branch=HEAD"

  mkdir -p lonely
  cp "$PLUGIN_ROOT/$SCRIPT" lonely/branch-name.sh
  run bash lonely/branch-name.sh
  assert_success
  refute_line "branch=HEAD"
}

@test "SR-3: a completed rename never exits 0 silently when the audit sink is unwritable" {
  cd "$WD"
  mk_branch_repo
  mkdir -p ro/logs
  chmod 500 ro/logs
  run bash "$PLUGIN_ROOT/$SCRIPT" --context ro
  chmod 700 ro/logs
  assert_success
  assert_output --partial "->"
  assert_output --partial "audit row NOT recorded"
  run git rev-parse --abbrev-ref HEAD
  assert_output "bugfix/fix-pr-composition-and-branch-naming"
}

@test "SR-4: CDPATH=. does not corrupt LIB_PATH or skip the guard ladder" {
  cd "$WD"
  mk_branch_repo
  run env CDPATH=. bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  refute_output --partial "unreachable"
  run git rev-parse --abbrev-ref HEAD
  assert_output "bugfix/fix-pr-composition-and-branch-naming"
}

# ---------------------------------------------------------------------------
# target_branch= — the derived remote name survives every no-op arm (Defect A),
# and the host-workspace arm (Defect C). The failure this closes: a run whose
# local rename was blocked stamped an empty/non-conventional `facts.branch`, so
# FN pushed the host-assigned name as the PR head.
# ---------------------------------------------------------------------------

# A linked worktree — the shape every worktree-based host provisions, and the only
# signal a host workspace reliably leaves (no workspace.json in $PWD).
mk_worktree_repo() {
  local branch="${1:-moab-v1}" goal="${2:-OV-166 Show all layers instead of zero at full score}"
  mkdir -p "$WD/main"
  git init -q -b master "$WD/main"
  git -C "$WD/main" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m work
  git -C "$WD/main" worktree add -b "$branch" "$WD/wt" > /dev/null 2>&1
  mkdir -p "$WD/wt/.context/logs"
  jq --arg g "$goal" '.facts.goal = $g' "$WD/.context/state.json" > "$WD/wt/.context/state.json"
}

# The documented Step 3c stamping rule, executed rather than paraphrased
# (skills/worktask/references/workflow.md § Step 3c — validate before stamping).
stamp_from_output() {
  local out="$1" local_branch target stamp
  local_branch=$(printf '%s\n' "$out" | sed -n 's/^branch=//p' | tail -n 1)
  target=$(printf '%s\n' "$out" | sed -n 's/^target_branch=//p' | tail -n 1)
  stamp="$local_branch"
  if [ -z "$stamp" ] || ! bash "$PLUGIN_ROOT/$SCRIPT" --check "$stamp"; then
    [ -n "$target" ] && stamp="$target"
  fi
  printf '%s' "$stamp"
}

# R6 INVERTED these two. They previously asserted the defer behaviour; the local name is
# now renamed by default and the deferring assertions moved to the opt-out (AC-10/2).
@test "TB-1: host workspace — renamed by default, both names agree" {
  mk_worktree_repo
  cd "$WD/wt"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "renamed inside a linked worktree"
  assert_line "target_branch=feature/ov-166-show-all-layers-instead-of-zero-at-full"
  run git rev-parse --abbrev-ref HEAD
  assert_output "feature/ov-166-show-all-layers-instead-of-zero-at-full"
  run jq -r 'select(.action=="branch_renamed") | .result' .context/logs/audit.jsonl
  assert_output "ok"
  run jq -r 'select(.action=="branch_renamed") | .metadata.in_worktree' .context/logs/audit.jsonl
  assert_output "true"
}

@test "TB-1b: host workspace — the opt-out still keeps the local name and skips" {
  mk_worktree_repo
  cd "$WD/wt"
  run env BRANCH_NAME_WORKTREE_RENAME=0 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "host workspace"
  assert_line "target_branch=feature/ov-166-show-all-layers-instead-of-zero-at-full"
  run git rev-parse --abbrev-ref HEAD
  assert_output "moab-v1"
  run jq -r 'select(.action=="branch_renamed") | .result' .context/logs/audit.jsonl
  assert_output "skipped"
  run jq -r 'select(.action=="branch_renamed") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "host_workspace_worktree"
}

@test "TB-2: host workspace — the acceptance trio (local name, facts.branch, PR head)" {
  mk_worktree_repo
  cd "$WD/wt"
  local out
  out=$(bash "$PLUGIN_ROOT/$SCRIPT")
  # 1. the local branch now carries the conventional name itself
  run git rev-parse --abbrev-ref HEAD
  assert_output "feature/ov-166-show-all-layers-instead-of-zero-at-full"
  # 2. + 3. what the orchestrator stamps, and therefore what FN pushes as the head — the
  # same string, which is the point of R6: no divergence left to reconcile.
  run stamp_from_output "$out"
  assert_output "feature/ov-166-show-all-layers-instead-of-zero-at-full"
}

@test "TB-3: batch routing still wins over the host-workspace arm" {
  mk_worktree_repo
  cd "$WD/wt"
  run env MILESTONE_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "skipped (milestone_mode_env)"
  # /megatask names its own branches — a target here would invite a stamp it never planned.
  assert_line "target_branch="
  run git rev-parse --abbrev-ref HEAD
  assert_output "moab-v1"
}

@test "TB-3b: a subdirectory of a PLAIN repo is not a host workspace (rename still happens)" {
  cd "$WD"
  mk_branch_repo
  mkdir -p src/deep
  cd src/deep
  # git answers --git-dir absolutely and --git-common-dir relatively from here; a raw
  # string compare would read every nested cwd as a linked worktree.
  run bash "$PLUGIN_ROOT/$SCRIPT" --state "$WD/.context/state.json" --context "$WD/.context"
  assert_success
  assert_line --index 0 --partial "->"
  run git rev-parse --abbrev-ref HEAD
  assert_output "bugfix/fix-pr-composition-and-branch-naming"
}

# INVERTED by R6. The detector is unchanged — only what it gates. Asserted through the
# OPT-OUT arm, because that is the arm whose output still proves detection distinctly: on
# the default arm a subdirectory of a plain repo would also rename, so a rename alone would
# no longer distinguish "detected" from "not detected" (see TB-3b for the plain-repo half).
@test "TB-3c: a subdirectory INSIDE a host workspace is still detected" {
  mk_worktree_repo
  mkdir -p "$WD/wt/src/deep"
  cd "$WD/wt/src/deep"
  run env BRANCH_NAME_WORKTREE_RENAME=0 bash "$PLUGIN_ROOT/$SCRIPT" \
    --state "$WD/wt/.context/state.json" --context "$WD/wt/.context"
  assert_success
  assert_line --index 0 --partial "host workspace"
  assert_line "target_branch=feature/ov-166-show-all-layers-instead-of-zero-at-full"
  run git rev-parse --abbrev-ref HEAD
  assert_output "moab-v1"
}

# The default-arm half of the same detection claim: from a subdirectory the worktree is
# still detected, so the disclosure fires and the rename happens.
@test "TB-3d: a subdirectory INSIDE a host workspace renames and discloses by default" {
  mk_worktree_repo
  mkdir -p "$WD/wt/src/deep"
  cd "$WD/wt/src/deep"
  run bash "$PLUGIN_ROOT/$SCRIPT" \
    --state "$WD/wt/.context/state.json" --context "$WD/wt/.context"
  assert_success
  assert_line --index 0 --partial "renamed inside a linked worktree"
  run git rev-parse --abbrev-ref HEAD
  assert_output "feature/ov-166-show-all-layers-instead-of-zero-at-full"
}

@test "TB-4: upstream_tracked keeps the branch AND emits the derived target" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "OV-166 Show all layers instead of zero at full score"
  git remote add origin https://example.invalid/r.git
  git update-ref refs/remotes/origin/wt-abc123 HEAD
  git branch --set-upstream-to=origin/wt-abc123 wt-abc123 > /dev/null
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "upstream already tracked"
  assert_line "target_branch=feature/ov-166-show-all-layers-instead-of-zero-at-full"
  # branch= unchanged from before this feature: the non-conventional local name is gated out.
  assert_line --index "$((${#lines[@]} - 1))" "branch="
  run git rev-parse --abbrev-ref HEAD
  assert_output "wt-abc123"
}

@test "TB-5: target_exists keeps the branch AND emits the derived target" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "OV-156 reconstruction scan flow"
  git branch feature/ov-156-reconstruction-scan-flow
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "already exists"
  assert_line "target_branch=feature/ov-156-reconstruction-scan-flow"
  run git rev-parse --abbrev-ref HEAD
  assert_output "wt-abc123"
}

@test "TB-6: jq_unavailable emits the target derived from an explicit --goal" {
  cd "$WD"
  mk_branch_repo
  local nobin tool p
  nobin="$WD/nobin"
  mkdir -p "$nobin"
  for tool in git grep sed tr cut date mkdir bash sh env printf true false cat awk readlink dirname; do
    p=$(command -v "$tool" 2> /dev/null) || continue
    ln -sf "$p" "$nobin/$tool"
  done
  run env PATH="$nobin" bash "$PLUGIN_ROOT/$SCRIPT" --goal "Add a new login flow"
  assert_success
  assert_line --index 0 --partial "target unresolvable"
  # The arm refuses the RENAME (batch scope is unknowable without jq); naming the PR
  # head needs no ledger read when the goal came in on argv.
  assert_line "target_branch=feature/add-a-new-login-flow"
}

@test "TB-7: no target on the arms that must not propose one" {
  cd "$WD"
  # already conventional — branch= is already the answer
  mk_branch_repo "feature/already-named-thing"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line "target_branch="
  assert_line --index "$((${#lines[@]} - 1))" "branch=feature/already-named-thing"

  # integration branch — never a PR head under any name.
  # The audit log is reset with the repo: the first half already wrote a branch_renamed
  # row, and since R6 that row is what already_named keys on, so leaving it would have the
  # once-guard answer this half instead of the arm under test.
  rm -rf "$WD/.git"
  : > .context/logs/audit.jsonl
  git init -q -b master "$WD"
  git -C "$WD" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m work
  jq '.facts.goal = "Add a new login flow" | .metadata.base_ref = "master"' \
    .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "integration branch"
  assert_line "target_branch="
}

@test "TB-8: library unreachable emits both lines, target empty (nothing can derive it)" {
  cd "$WD"
  mk_branch_repo
  mkdir -p lonely
  cp "$PLUGIN_ROOT/$SCRIPT" lonely/branch-name.sh
  run bash lonely/branch-name.sh
  assert_success
  assert_line "target_branch="
  assert_line --index "$((${#lines[@]} - 1))" "branch=wt-abc123"
}

@test "TB-9 (SR-1): a shell-hostile current branch reaches neither emitted line" {
  cd "$WD"
  local marker="/tmp/branch-name-sr1-marker-f"
  mk_hostile_repo "$marker"
  jq '.facts.goal = "Add login flow"' .context/state.json > s && mv s .context/state.json
  git branch feature/add-login-flow
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  # target_branch= carries the DERIVED name — conventional by construction, so the
  # hostile current name cannot ride along on either contract line.
  assert_line "target_branch=feature/add-login-flow"
  assert_line --index "$((${#lines[@]} - 1))" "branch="
  refute_output --partial 'fix/a$('
  [ ! -e "$marker" ]
}

@test "TB-10: BRANCH_NAME_PRINT dry run still prints the bare target, no key=value lines" {
  cd "$WD"
  mk_branch_repo
  run env BRANCH_NAME_PRINT=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output "bugfix/fix-pr-composition-and-branch-naming"
  refute_output --partial "target_branch="
}

# ---------------------------------------------------------------------------
# slug_truncated= and --print-target (AC-5, 7 assertions + query-mode coverage).
# ---------------------------------------------------------------------------

# 71-char kebab body against a 48-char budget.
TRUNCATING_GOAL="Product list images are blinking before rendering on the catalog screen"

@test "AC-5/1: rename mode with a truncating goal emits exactly one slug_truncated=1 line" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "$TRUNCATING_GOAL"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 1 "slug_truncated=1"
  assert_equal "$(printf '%s\n' "${lines[@]}" | grep -c '^slug_truncated=1$')" 1
}

@test "AC-5/2: rename mode with a non-truncating goal emits no slug_truncated line" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "Add a new login flow"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  refute_output --partial "slug_truncated"
  # The pre-existing index-1 contract for a non-truncating goal is what the conditional
  # emission exists to preserve.
  assert_line --index 1 "target_branch=feature/add-a-new-login-flow"
}

@test "AC-5/3: branch= is the final stdout line on every guard-ladder arm" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "$TRUNCATING_GOAL"
  # rename ok (truncating)
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index "$((${#lines[@]} - 1))" --partial "branch=bugfix/"
  # already conventional
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index "$((${#lines[@]} - 1))" --partial "branch=bugfix/"
  # batch routing
  run env MILESTONE_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index "$((${#lines[@]} - 1))" --partial "branch="
}

@test "AC-5/4: target_branch= is emitted immediately before branch= when truncating" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "$TRUNCATING_GOAL"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  local last=$((${#lines[@]} - 1))
  assert_line --index "$last" --partial "branch=bugfix/"
  assert_line --index "$((last - 1))" --partial "target_branch=bugfix/"
  assert_line --index "$((last - 2))" "slug_truncated=1"
}

@test "AC-5/5: dry run puts the bare target on stdout and the signal on stderr only" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "$TRUNCATING_GOAL"
  run --separate-stderr env BRANCH_NAME_PRINT=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output "bugfix/product-list-images-are-blinking-before"
  refute_output --partial "="
  [[ "$stderr" == *"slug_truncated=1"* ]]
}

@test "AC-5/6: dry run writes no audit row even when the goal truncates" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "$TRUNCATING_GOAL"
  run env BRANCH_NAME_PRINT=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ ! -s .context/logs/audit.jsonl ]
  run git rev-parse --abbrev-ref HEAD
  assert_output "wt-abc123"
}

@test "AC-5/7: exit code is 0 on every rename-mode arm, truncating or not" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "$TRUNCATING_GOAL"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run env MILESTONE_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run env INCIDENT_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  git checkout -q --detach HEAD
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
}

@test "PT-1: --print-target prints the bare target for the given goal, exit 0" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --print-target --goal "Add a new login flow"
  assert_success
  assert_output "feature/add-a-new-login-flow"
}

# The reason the dry run cannot serve: BRANCH_NAME_PRINT is evaluated AFTER the guard
# ladder, so on an already-conventional branch it returns on the no-op arm and prints
# no target at all. The query mode must still answer.
@test "PT-2: --print-target answers where the dry run short-circuits" {
  cd "$WD"
  mk_branch_repo "feature/already-named-thing" "Add a new login flow"
  run env BRANCH_NAME_PRINT=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  refute_output --partial "feature/add-a-new-login-flow"
  run bash "$PLUGIN_ROOT/$SCRIPT" --print-target --goal "Add a new login flow"
  assert_success
  assert_output "feature/add-a-new-login-flow"
}

@test "PT-3: --print-target runs no git command, needs no repo, and writes nothing" {
  cd "$WD"
  mkdir -p nogit/.context/logs
  cd nogit
  local nobin tool p
  nobin="$WD/nogitbin"
  mkdir -p "$nobin"
  for tool in grep sed tr cut date mkdir bash sh env printf true false cat awk readlink dirname jq; do
    p=$(command -v "$tool" 2> /dev/null) || continue
    ln -sf "$p" "$nobin/$tool"
  done
  # No `git` on PATH at all: any git invocation would fail loudly rather than silently.
  run env PATH="$nobin" bash "$PLUGIN_ROOT/$SCRIPT" --print-target --goal "Add a new login flow" \
    --context .context --state .context/state.json
  assert_success
  assert_output "feature/add-a-new-login-flow"
  [ ! -e .context/logs/audit.jsonl ]
}

@test "PT-4: --print-target emits the truncation signal on stderr, target on stdout" {
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --print-target --goal "$TRUNCATING_GOAL"
  assert_success
  assert_output "bugfix/product-list-images-are-blinking-before"
  [[ "$stderr" == *"slug_truncated=1"* ]]
}

@test "PT-5: --print-target is silent and exits 1 when the goal resolves to nothing" {
  cd "$WD"
  mkdir -p empty/.context
  cd empty
  printf '{"version":1,"worktask_id":"","run_index":0,"facts":{}}\n' > .context/state.json
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --print-target --goal "" \
    --state .context/state.json --context .context
  assert_failure 1
  assert_output ""
}

@test "PT-6: --print-target composes with --goal in either argument order" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --goal "Add a new login flow" --print-target
  assert_success
  assert_output "feature/add-a-new-login-flow"
}

@test "PT-7: --print-target with branch-lib.sh unreachable exits 2" {
  cd "$WD"
  mkdir -p lonely
  cp "$PLUGIN_ROOT/$SCRIPT" lonely/branch-name.sh
  run --separate-stderr bash lonely/branch-name.sh --print-target --goal "Add a new login flow"
  assert_failure 2
  [[ "$stderr" == *"branch-lib.sh"* ]]
}

# ---------------------------------------------------------------------------
# AC-10 (R6) — the linked-worktree arm renames, with an opt-out.
#
# FIXTURE RULE (AD-7 applied to R6): the worktree fixture MUST start on a NON-conventional
# branch and MUST assert the real `git` branch name. A conventional starting branch makes
# the renaming and deferring arms coincidentally agree — both no-op — and proves nothing.
# Cases 1 and 2 are the SAME fixture differing only in the env var.
# ---------------------------------------------------------------------------

R6_TARGET="feature/add-a-new-login-flow"

# `moab-v1` is non-conventional on purpose: it is the shape a host actually assigns.
mk_r6_worktree() {
  local branch="${1:-moab-v1}" goal="${2:-Add a new login flow}"
  mkdir -p "$WD/main"
  git init -q -b master "$WD/main"
  git -C "$WD/main" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m work
  git -C "$WD/main" worktree add -b "$branch" "$WD/wt" > /dev/null 2>&1
  mkdir -p "$WD/wt/.context/logs"
  jq --arg g "$goal" '.facts.goal = $g' "$WD/.context/state.json" > "$WD/wt/.context/state.json"
}

@test "AC-10/1: linked worktree, defaults — the local branch is renamed" {
  mk_r6_worktree
  cd "$WD/wt"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  # The real git state, not stdout alone.
  run git rev-parse --abbrev-ref HEAD
  assert_output "$R6_TARGET"
  run bash "$PLUGIN_ROOT/$SCRIPT" --check "$R6_TARGET"
  assert_success
}

@test "AC-10/1b: both names agree and branch= is final and non-empty" {
  mk_r6_worktree
  cd "$WD/wt"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index "$((${#lines[@]} - 1))" "branch=$R6_TARGET"
  assert_line "target_branch=$R6_TARGET"
  run jq -r 'select(.action=="branch_renamed") | .result' .context/logs/audit.jsonl
  assert_output "ok"
  run jq -r 'select(.action=="branch_renamed") | .metadata.in_worktree' .context/logs/audit.jsonl
  assert_output "true"
  run jq -r 'select(.action=="branch_renamed") | .metadata.from' .context/logs/audit.jsonl
  assert_output "moab-v1"
}

# Same fixture as AC-10/1, differing ONLY in the env var, so the delta is attributable.
@test "AC-10/2: BRANCH_NAME_WORKTREE_RENAME=0 preserves the defer behaviour verbatim" {
  mk_r6_worktree
  cd "$WD/wt"
  local before
  before=$(git rev-parse --abbrev-ref HEAD)
  run env BRANCH_NAME_WORKTREE_RENAME=0 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "host workspace"
  run git rev-parse --abbrev-ref HEAD
  assert_output "$before"
  assert_output "moab-v1"
  run jq -r 'select(.action=="branch_renamed") | .result' .context/logs/audit.jsonl
  assert_output "skipped"
  run jq -r 'select(.action=="branch_renamed") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "host_workspace_worktree"
}

@test "AC-10/2b: the opt-out arm emits target_branch= but an empty branch=" {
  mk_r6_worktree
  cd "$WD/wt"
  run env BRANCH_NAME_WORKTREE_RENAME=0 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line "target_branch=$R6_TARGET"
  assert_line --index "$((${#lines[@]} - 1))" "branch="
}

@test "AC-10/2c: only the literal 0 opts out" {
  mk_r6_worktree
  cd "$WD/wt"
  run env BRANCH_NAME_WORKTREE_RENAME=false bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run git rev-parse --abbrev-ref HEAD
  assert_output "$R6_TARGET"
}

# AD-12: a name-based once-guard would authorize a SECOND rename here, because the
# third-party name is non-conventional again.
@test "AC-10/3: once-only survives a third-party rename between runs" {
  mk_r6_worktree
  cd "$WD/wt"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run git rev-parse --abbrev-ref HEAD
  assert_output "$R6_TARGET"

  # Simulate the host renaming the branch mid-run, as Conductor did live.
  git branch -m which-stages-ran-tests
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "already named this run"
  # Byte-identical to the third-party name: no second rename.
  run git rev-parse --abbrev-ref HEAD
  assert_output "which-stages-ran-tests"

  run bash -c "jq -rs -R '[split(\"\n\")[]|fromjson?
    |select(.action==\"branch_renamed\" and .result==\"ok\")]|length' .context/logs/audit.jsonl"
  assert_output "1"
  run bash -c "jq -rs -R '[split(\"\n\")[]|fromjson?
    |select(.action==\"branch_renamed\")]|last|.metadata.reason' .context/logs/audit.jsonl"
  assert_output "already_named"
  run bash -c "jq -rs -R '[split(\"\n\")[]|fromjson?
    |select(.metadata.reason==\"already_named\")]|last|.metadata.branch' .context/logs/audit.jsonl"
  assert_output "which-stages-ran-tests"
}

# A well-formed NON-object line parses cleanly through `fromjson?` and then dies on
# `.metadata` — aborting the scan, which for a once-only guard means failing OPEN.
# `objects` closes it. Same probe DR used against the R4 scans in the r1 cycle.
@test "AC-10/3d: a well-formed non-object audit line does not make already_named fail open" {
  mk_r6_worktree
  cd "$WD/wt"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run git rev-parse --abbrev-ref HEAD
  assert_output "$R6_TARGET"

  # Prepend a bare number and a JSON array AHEAD of the branch_renamed row.
  { printf '123\n[1,2]\n'; cat .context/logs/audit.jsonl; } > a \
    && mv a .context/logs/audit.jsonl
  git branch -m which-stages-ran-tests

  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "already named this run"
  # The guard held: no second rename.
  run git rev-parse --abbrev-ref HEAD
  assert_output "which-stages-ran-tests"
  run bash -c "jq -rs -R '[split(\"\n\")[]|fromjson?|objects
    |select(.action==\"branch_renamed\" and .result==\"ok\")]|length' .context/logs/audit.jsonl"
  assert_output "1"
}

@test "AC-10/3b: already_named outranks already_conventional and records first_run_ts" {
  mk_r6_worktree
  cd "$WD/wt"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  # Still conventional — so a run now must be refused by already_named, not by the churn guard.
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "already named this run"
  refute_output --partial "already conventional"
  run bash -c "jq -rs -R '[split(\"\n\")[]|fromjson?
    |select(.metadata.reason==\"already_named\")]|last|.metadata.first_run_ts' .context/logs/audit.jsonl"
  assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
}

@test "AC-10/3c: a bumped run_index gets its own naming decision" {
  mk_r6_worktree
  cd "$WD/wt"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  git branch -m host-renamed-again
  jq '.run_index = 1' .context/state.json > s && mv s .context/state.json
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  refute_output --partial "already named"
  run git rev-parse --abbrev-ref HEAD
  assert_output "$R6_TARGET"
}

# The R6-specific hazard: a linked worktree SHARES refs/heads with the main checkout, so a
# collision is more likely here than in a plain checkout — the fall-through must pass
# through the target_exists guard.
@test "AC-10/5: target_exists still precedes the rename inside a worktree" {
  mk_r6_worktree
  git -C "$WD/main" branch "$R6_TARGET"
  cd "$WD/wt"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "already exists"
  run git rev-parse --abbrev-ref HEAD
  assert_output "moab-v1"
  run jq -r 'select(.action=="branch_renamed") | .metadata.reason' .context/logs/audit.jsonl
  assert_output "target_exists"
  # The disclosure names a rename, so it must not appear on an arm that renamed nothing.
  refute_output --partial "renamed inside a linked worktree"
}

@test "AC-10/6: higher guards still win inside a worktree" {
  mk_r6_worktree
  cd "$WD/wt"
  git remote add origin https://example.invalid/r.git
  git update-ref refs/remotes/origin/moab-v1 HEAD
  git branch --set-upstream-to=origin/moab-v1 moab-v1 > /dev/null
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "upstream already tracked"
  run git rev-parse --abbrev-ref HEAD
  assert_output "moab-v1"
}

@test "AC-10/6b: batch and incident routing self-disable regardless of the opt-out" {
  mk_r6_worktree
  cd "$WD/wt"
  run env MILESTONE_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "skipped (milestone_mode_env)"
  run git rev-parse --abbrev-ref HEAD
  assert_output "moab-v1"

  run env INCIDENT_MODE=1 BRANCH_NAME_WORKTREE_RENAME=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "skipped (incident_mode_env)"
  run git rev-parse --abbrev-ref HEAD
  assert_output "moab-v1"
}

@test "AC-10/6c: BRANCH_NAME_PRINT is evaluated above the worktree arm — a dry run never mutates" {
  mk_r6_worktree
  cd "$WD/wt"
  run env BRANCH_NAME_PRINT=1 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output "$R6_TARGET"
  run git rev-parse --abbrev-ref HEAD
  assert_output "moab-v1"
  [ ! -s .context/logs/audit.jsonl ]
}

@test "AC-10/7: the disclosure line names the consequence and the opt-out (BINDING)" {
  mk_r6_worktree
  cd "$WD/wt"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 --partial "renamed inside a linked worktree"
  assert_line --index 0 --partial "re-sync"
  assert_line --index 0 --partial "BRANCH_NAME_WORKTREE_RENAME=0"
  assert_line --index 0 --partial "moab-v1"
  assert_line --index 0 --partial "$R6_TARGET"
}

@test "AC-10/7b: a plain checkout keeps its terse rename line, no disclosure" {
  cd "$WD"
  mk_branch_repo "wt-abc123" "Add a new login flow"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index 0 "branch-name: wt-abc123 -> $R6_TARGET"
  refute_output --partial "linked worktree"
  run jq -r 'select(.action=="branch_renamed") | .metadata.in_worktree // "absent"' .context/logs/audit.jsonl
  assert_output "absent"
}

@test "AC-10/4: branch= is final and non-empty on the worktree rename arm" {
  mk_r6_worktree
  cd "$WD/wt"
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index "$((${#lines[@]} - 1))" "branch=$R6_TARGET"
}

@test "AC-10/4b: branch= is final and empty on the opt-out arm" {
  mk_r6_worktree
  cd "$WD/wt"
  run env BRANCH_NAME_WORKTREE_RENAME=0 bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_line --index "$((${#lines[@]} - 1))" "branch="
}

@test "SR-2/SR-4: a symlinked script still resolves the real sibling branch-lib.sh" {
  cd "$WD"
  mk_branch_repo
  mkdir -p linked
  ln -s "$PLUGIN_ROOT/skills/worktask/scripts/branch-name.sh" linked/branch-name.sh
  run bash linked/branch-name.sh
  assert_success
  refute_output --partial "unreachable"
  run git rev-parse --abbrev-ref HEAD
  assert_output "bugfix/fix-pr-composition-and-branch-naming"
}

# ---------------------------------------------------------------------------
# R10/#9 — a preview must not spend the once-per-run naming window.
# The header has documented "no audit row" for BRANCH_NAME_PRINT since the flag
# existed; the ladder audited unconditionally, so any no-op arm firing during a
# preview wrote a real branch_renamed row that then tripped already_named.
# ---------------------------------------------------------------------------

@test "R10a: a preview whose arm fires writes NO audit row" {
  cd "$WD"
  mk_branch_repo
  # upstream_tracked is the arm observed doing this in production.
  UP="$(mktemp -d)/up.git"
  git init -q --bare "$UP"
  git -C "$WD" remote add origin "$UP"
  git -C "$WD" push -q -u origin HEAD
  BRANCH_NAME_PRINT=1 run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ ! -s "$WD/.context/logs/audit.jsonl" ]
}

@test "R10b: the naming window survives a preview" {
  cd "$WD"
  mk_branch_repo
  UP="$(mktemp -d)/up2.git"
  git init -q --bare "$UP"
  git -C "$WD" remote add origin "$UP"
  git -C "$WD" push -q -u origin HEAD
  BRANCH_NAME_PRINT=1 bash "$PLUGIN_ROOT/$SCRIPT" > /dev/null 2>&1 || true
  # The real run must reach its OWN arm, not already_named, and so must still
  # report the target the remote should carry.
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  refute_output --partial "already named this run"
  assert_output --partial "target_branch=bugfix/fix-pr-composition-and-branch-naming"
}

@test "R10c: a query mode still writes no audit row" {
  cd "$WD"
  mk_branch_repo
  run bash "$PLUGIN_ROOT/$SCRIPT" --print-target --goal "fix a thing"
  assert_success
  [ ! -s "$WD/.context/logs/audit.jsonl" ]
}

@test "R10d: already_named re-emits the target the FIRST run recorded" {
  cd "$WD"
  mk_branch_repo
  bash "$PLUGIN_ROOT/$SCRIPT" > /dev/null 2>&1
  # A host renames the branch back mid-run — the scenario already_named exists for.
  git -C "$WD" branch -m wt-abc123
  run bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  assert_output --partial "already named this run"
  assert_output --partial "target_branch=bugfix/fix-pr-composition-and-branch-naming"
}

@test "SR: the lib-unreachable audit row refuses a symlinked audit.jsonl" {
  cd "$WD"
  mk_branch_repo
  mkdir -p lonely target-dir
  cp "$PLUGIN_ROOT/$SCRIPT" lonely/branch-name.sh
  ln -s "$WD/target-dir/escaped.txt" .context/logs/audit.jsonl
  run bash lonely/branch-name.sh
  # The degrade contract still holds: exit 0 and the same stdout, row or no row.
  assert_success
  assert_output --partial "library unreachable — skipped"
  [ ! -e "$WD/target-dir/escaped.txt" ]
}
