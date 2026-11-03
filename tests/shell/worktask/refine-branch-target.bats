#!/usr/bin/env bats
# Contract tests for skills/worktask/scripts/refine-branch-target.sh — the one-shot
# refinement of the PLANNED branch target from the approved plan's own `title:`
# (skills/worktask/references/workflow.md § Step A.4b). Ledger-only: no git mutation, ever.
# Canonical gate order, closed reason set and row schema: .context/architecture-0.md
# § schemas / skills/shared/git-conventions.md § Once-only rule.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"
bats_require_minimum_version 1.5.0

SCRIPT="skills/worktask/scripts/refine-branch-target.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context/logs"
}

mk_state() {
  local branch="$1" base="${2:-master}"
  cat > "$WD/.context/state.json" <<EOF
{"version":1,"worktask_id":"wt-demo","run_index":0,"platform":"systems",
 "plan_file":".context/planning-0.md","tasks":{},
 "facts":{"branch":"$branch","goal":"seed"},"handoffs":{},
 "metadata":{"base_ref":"$base"}}
EOF
}

# A repo whose branch is conventional, has no upstream and no commit beyond the base —
# the shape Step A.4b actually runs in (planning done, nothing implemented yet).
#
# `refs/remotes/origin/master` is synthesised at the branch point because that is the ref
# gate 3 is required to consult; a fixture with only a local base would let a gate that
# resolves the WRONG ref still pass every case here. `update-ref` alone configures no
# upstream, so gate 2 is unaffected.
mk_clean_repo() {
  local branch="${1:-feature/stamped-at-step-3c}"
  git init -q -b master "$WD"
  git -C "$WD" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m base
  git -C "$WD" update-ref refs/remotes/origin/master HEAD
  git -C "$WD" checkout -q -b "$branch"
  mk_state "$branch"
}

# The topology AD-7 exists for, and the one `mk_clean_repo` cannot express: the published
# base is at the branch point, the LOCAL base ref is behind it, and the branch has zero
# commits of its own. A gate that resolves `master` sees 1 commit; the truth is 0.
mk_stale_local_base_repo() {
  local branch="${1:-feature/stamped-at-step-3c}"
  git init -q -b master "$WD"
  git -C "$WD" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m base-old
  git -C "$WD" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m base-published
  git -C "$WD" update-ref refs/remotes/origin/master HEAD
  git -C "$WD" checkout -q -b "$branch"
  git -C "$WD" branch -f master HEAD~1
  mk_state "$branch"
}

# No remote at all — the local-only / fresh-clone arm of AD-7's ref-absence table.
mk_local_only_repo() {
  local branch="${1:-feature/stamped-at-step-3c}"
  git init -q -b master "$WD"
  git -C "$WD" -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m base
  git -C "$WD" checkout -q -b "$branch"
  mk_state "$branch"
}

mk_plan() {
  local title="${1:-Add a new login flow}"
  cat > "$WD/.context/planning-0.md" <<EOF
---
title: "$title"
handoff:
  stage: PL
  verdict: ok
---

# Planning
EOF
}

# The one place the helper is invoked, so every case runs it identically.
run_helper() {
  run bash "$PLUGIN_ROOT/$SCRIPT" --state .context/state.json --context .context "$@"
}

ledger_branch() { jq -r '.facts.branch // ""' "$WD/.context/state.json"; }

# Reads with the same tolerance the code under test has: a malformed or non-object line in
# a fixture must not break the assertion helper and mask the real result.
rows() {
  jq -rs -R "[ split(\"\n\")[] | fromjson? | objects
    | select(.action==\"branch_target_refined\") | .$1 ] | .[]" \
    "$WD/.context/logs/audit.jsonl"
}

@test "AC-7/1: applies — ledger becomes the refined target, one ok row naming both values" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  run_helper
  assert_success
  assert_line --index "$((${#lines[@]} - 1))" "ledger_branch=feature/add-a-new-login-flow"
  run ledger_branch
  assert_output "feature/add-a-new-login-flow"
  run rows result
  assert_output "ok"
  run rows metadata.from
  assert_output "feature/stamped-at-step-3c"
  run rows metadata.to
  assert_output "feature/add-a-new-login-flow"
  run rows metadata.source
  assert_output "plan_title"
  run rows subject
  assert_output "PL0"
}

@test "AC-7/2: once — a second run is a no-op, no second ok row" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  run_helper
  assert_success
  run_helper
  assert_success
  run ledger_branch
  assert_output "feature/add-a-new-login-flow"
  run bash -c "jq -r 'select(.action==\"branch_target_refined\" and .result==\"ok\")' \
    .context/logs/audit.jsonl | jq -s 'length'"
  assert_output "1"
  run bash -c "jq -r 'select(.action==\"branch_target_refined\") | .metadata.reason' \
    .context/logs/audit.jsonl | grep -c already_refined"
  assert_output "1"
}

# Asserted against the REMOTE-TRACKING ref (mk_clean_repo synthesises it at the branch
# point): the genuine commit guard must survive AD-7's ref-selection rewrite.
@test "AC-7/3: commit guard — a commit on the branch blocks the refinement" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m "work"
  # The commit is real relative to the published base, not an artefact of a stale local ref.
  run git rev-list --count refs/remotes/origin/master..HEAD
  assert_output "1"
  run_helper
  assert_success
  run ledger_branch
  assert_output "feature/stamped-at-step-3c"
  run rows result
  assert_output "noop"
  run rows metadata.reason
  assert_output "commit_exists"
}

# AD-7. The bug this pins: feeding resolve_base_ref's raw output to rev-list asks "is my
# local base behind?" instead of "have I committed?", so R4 no-ops on every real run.
@test "AC-7/18: a stale local base does not trip the commit guard" {
  cd "$WD"
  mk_stale_local_base_repo
  mk_plan "Add a new login flow"
  # The two refs disagree — the whole point of the fixture.
  run git rev-list --count master..HEAD
  assert_output "1"
  run git rev-list --count refs/remotes/origin/master..HEAD
  assert_output "0"
  run_helper
  assert_success
  # Gate 3 passes and evaluation continues past it.
  run rows metadata.reason
  refute_output "commit_exists"
  run rows result
  assert_output "ok"
  run ledger_branch
  assert_output "feature/add-a-new-login-flow"
}

@test "AC-7/19: no remote-tracking ref — gate 3 falls back to refs/heads/<base>" {
  cd "$WD"
  mk_local_only_repo
  mk_plan "Add a new login flow"
  run git rev-parse --verify --quiet refs/remotes/origin/master
  assert_failure
  run_helper
  assert_success
  run rows result
  assert_output "ok"
  run ledger_branch
  assert_output "feature/add-a-new-login-flow"
  # A silent fallback: no separate reason token was introduced for it.
  run bash -c "grep -c 'local_base' .context/logs/audit.jsonl || true"
  assert_output "0"
}

@test "AC-7/19b: the fallback still catches a real commit" {
  cd "$WD"
  mk_local_only_repo
  mk_plan "Add a new login flow"
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m work
  run_helper
  assert_success
  run rows metadata.reason
  assert_output "commit_exists"
  run ledger_branch
  assert_output "feature/stamped-at-step-3c"
}

@test "AC-7/20: neither base ref resolves — noop / base_unresolved, exit 0" {
  cd "$WD"
  mk_local_only_repo
  mk_plan "Add a new login flow"
  jq '.metadata.base_ref = "no-such-base"' .context/state.json > s && mv s .context/state.json
  run_helper
  assert_success
  run rows metadata.reason
  assert_output "base_unresolved"
  run ledger_branch
  assert_output "feature/stamped-at-step-3c"
}

@test "AC-7/20b: an unborn HEAD declines rather than guessing" {
  cd "$WD"
  git init -q -b master "$WD"
  git -C "$WD" update-ref refs/remotes/origin/master "$(git -C "$WD" hash-object -t tree /dev/null)" 2> /dev/null || true
  mk_state "feature/stamped-at-step-3c"
  mk_plan "Add a new login flow"
  run_helper
  assert_success
  run rows metadata.reason
  assert_output "base_unresolved"
}

@test "AC-7/4: upstream guard — a configured upstream blocks the refinement" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  git remote add origin https://example.invalid/r.git
  git update-ref refs/remotes/origin/feature/stamped-at-step-3c HEAD
  git branch --set-upstream-to=origin/feature/stamped-at-step-3c > /dev/null
  run_helper
  assert_success
  run ledger_branch
  assert_output "feature/stamped-at-step-3c"
  run rows metadata.reason
  assert_output "upstream_exists"
}

@test "AC-7/5: no title — plan frontmatter without title: blocks the refinement" {
  cd "$WD"
  mk_clean_repo
  cat > .context/planning-0.md <<'EOF'
---
handoff:
  stage: PL
---

# Planning
EOF
  run_helper
  assert_success
  run ledger_branch
  assert_output "feature/stamped-at-step-3c"
  run rows metadata.reason
  assert_output "no_plan_title"
}

@test "AC-7/6: unconventional candidate — the stamped value survives intact" {
  cd "$WD"
  mk_clean_repo
  # Punctuation only: the kebab body is empty, so no target can be derived at all.
  mk_plan '!!! ??? ***'
  run_helper
  assert_success
  run ledger_branch
  assert_output "feature/stamped-at-step-3c"
  run rows result
  assert_output "noop"
  run rows metadata.reason
  assert_output "candidate_unusable"
}

@test "AC-7/7: no rename — the local branch name is byte-identical on every arm" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  local before
  before=$(git rev-parse --abbrev-ref HEAD)
  run_helper
  assert_success
  run git rev-parse --abbrev-ref HEAD
  assert_output "$before"
  # …and on a blocked arm too.
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m work
  run_helper
  assert_success
  run git rev-parse --abbrev-ref HEAD
  assert_output "$before"
}

@test "AC-7/8: no rename-mode run — the helper adds no branch_renamed row" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  run_helper
  assert_success
  run bash -c "grep -c branch_renamed .context/logs/audit.jsonl || true"
  assert_output "0"
}

@test "AC-7/9: exit 0 always — missing plan, missing state, no jq, not a git repo" {
  cd "$WD"
  # missing plan file
  mk_clean_repo
  run_helper
  assert_success
  run rows metadata.reason
  assert_output "plan_missing"

  # not a git repo
  rm -rf .git
  run_helper
  assert_success
  run bash -c "jq -r 'select(.action==\"branch_target_refined\") | .metadata.reason' \
    .context/logs/audit.jsonl | tail -n 1"
  assert_output "not_a_git_repo"

  # missing state file
  rm -f .context/state.json
  run_helper
  assert_success

  # jq absent
  mk_clean_repo
  mk_plan "Add a new login flow"
  local nobin tool p
  nobin="$WD/nobin"
  mkdir -p "$nobin"
  for tool in git grep sed tr cut date mkdir bash sh env printf true false cat awk readlink dirname basename sync mv rm; do
    p=$(command -v "$tool" 2> /dev/null) || continue
    ln -sf "$p" "$nobin/$tool"
  done
  run env PATH="$nobin" bash "$PLUGIN_ROOT/$SCRIPT" --state .context/state.json --context .context
  assert_success
  assert_output --partial "jq_unavailable"

  # unreachable library
  mkdir -p lonely
  cp "$PLUGIN_ROOT/$SCRIPT" lonely/refine-branch-target.sh
  run bash lonely/refine-branch-target.sh --state .context/state.json --context .context
  assert_success
  assert_output --partial "lib_unreachable"
}

@test "AC-7/10: ledger write is atomic — valid JSON, every pre-existing key preserved" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  jq '.metadata.milestone = null | .facts.goal = "seed" | .facts.decisions = ["keep me"]' \
    .context/state.json > s && mv s .context/state.json
  run_helper
  assert_success
  run jq -e . .context/state.json
  assert_success
  run jq -r '.worktask_id, .plan_file, .facts.goal, .facts.decisions[0], .metadata.base_ref' \
    .context/state.json
  assert_line --index 0 "wt-demo"
  assert_line --index 1 ".context/planning-0.md"
  assert_line --index 2 "seed"
  assert_line --index 3 "keep me"
  assert_line --index 4 "master"
  # No temp file left behind by the temp→fsync→rename.
  run bash -c "ls -A .context | grep -c 'tmp' || true"
  assert_output "0"
}

@test "AC-7/11: divergence from the local branch name is recorded explicitly" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  run_helper
  assert_success
  run rows metadata.local_branch
  assert_output "feature/stamped-at-step-3c"
  run rows metadata.diverges_from_local
  assert_output "true"
}

@test "AC-7/12: the refined value satisfies FN's ^[A-Za-z0-9._/-]+\$ re-validation" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  run_helper
  assert_success
  run bash -c "jq -r '.facts.branch' .context/state.json | grep -Eq '^[A-Za-z0-9._/-]+\$'"
  assert_success
  # FN reads the ledger, not the helper — so the identical check the PM agent documents
  # is the one exercised here.
  run bash "$PLUGIN_ROOT/skills/worktask/scripts/branch-name.sh" --check "$(ledger_branch)"
  assert_success
}

# AR gate 6 (AD-5). The refinement window exists to IMPROVE the planned name; spending it
# to replace a clean name with a mid-phrase fragment is a regression, and the fragment is
# exactly what the truncation signal was added to make visible.
@test "AC-7/13: candidate_not_better — a truncating candidate never displaces a clean name" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Product list images are blinking before rendering on the catalog screen"
  run_helper
  assert_success
  run ledger_branch
  assert_output "feature/stamped-at-step-3c"
  run rows result
  assert_output "noop"
  run rows metadata.reason
  assert_output "candidate_not_better"
}

@test "AC-7/13b: the same truncating candidate IS applied when the incumbent truncated" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Product list images are blinking before rendering on the catalog screen"
  # The R3.5 row from Step 3c is the incumbent-quality signal — R3's output is R4's input.
  jq -cn '{ts:"2026-01-01T00:00:00Z", actor:"orchestrator", action:"branch_slug_truncated",
           subject:"PL0", result:"warn", task_id:"PL0",
           metadata:{input_len:"249", slug:"stamped-at-step-3c"}}' \
    >> .context/logs/audit.jsonl
  run_helper
  assert_success
  run ledger_branch
  assert_output "bugfix/product-list-images-are-blinking-before"
  run rows result
  assert_output "ok"
}

@test "AC-7/14: candidate_unchanged — deriving the name already on the ledger is a no-op" {
  cd "$WD"
  mk_clean_repo "feature/add-a-new-login-flow"
  mk_plan "Add a new login flow"
  run_helper
  assert_success
  run ledger_branch
  assert_output "feature/add-a-new-login-flow"
  run rows metadata.reason
  assert_output "candidate_unchanged"
}

@test "AC-7/15: batch routing owns naming — MILESTONE_MODE self-disables the helper" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  run env MILESTONE_MODE=1 bash "$PLUGIN_ROOT/$SCRIPT" \
    --state .context/state.json --context .context
  assert_success
  run ledger_branch
  assert_output "feature/stamped-at-step-3c"
  run rows metadata.reason
  assert_output "batch_scope"
}

@test "AC-7/16: --plan accepts both documented plan_file shapes" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  # bare basename, resolved against the directory holding state.json
  run bash "$PLUGIN_ROOT/$SCRIPT" --state .context/state.json --context .context \
    --plan planning-0.md
  assert_success
  run ledger_branch
  assert_output "feature/add-a-new-login-flow"
}

# A source-level gate, not a spot check: running a handful of arms can only ever prove the
# tokens those arms emit. Every reason the script is CAPABLE of emitting is enumerated from
# the source and checked both ways against the closed set.
@test "AC-7/17: the reason vocabulary is exactly the closed 15-token set, both ways" {
  run bash -c "
    set -o pipefail
    S='$PLUGIN_ROOT/$SCRIPT'
    closed=\$(printf '%s\n' lib_unreachable jq_unavailable state_missing batch_scope \
      not_a_git_repo already_refined upstream_exists base_unresolved commit_exists \
      plan_missing no_plan_title candidate_unusable candidate_unchanged \
      candidate_not_better write_failed | sort)
    # Every token the source can emit: finish_noop call sites, the jq_unavailable stdout
    # arm, and the inline lib_unreachable row (written before the library is available).
    emitted=\$( { grep -Eo 'finish_noop [a-z_]+' \"\$S\" | awk '{print \$2}'
                  grep -Eo 'reason:\"[a-z_]+\"' \"\$S\" | sed -e 's/reason:\"//' -e 's/\"//'
                  grep -Eo 'no-op \(([a-z_]+)\)' \"\$S\" | sed -e 's/no-op (//' -e 's/)//'
                } | sort -u )
    [ -n \"\$emitted\" ] || { printf 'NO TOKENS EXTRACTED — the extraction itself broke\n'; exit 1; }
    extra=\$(comm -23 <(printf '%s\n' \"\$emitted\") <(printf '%s\n' \"\$closed\"))
    missing=\$(comm -13 <(printf '%s\n' \"\$emitted\") <(printf '%s\n' \"\$closed\"))
    [ -z \"\$extra\" ] || { printf 'OUT OF VOCABULARY: %s\n' \"\$extra\"; exit 1; }
    [ -z \"\$missing\" ] || { printf 'DECLARED BUT UNREACHABLE: %s\n' \"\$missing\"; exit 1; }
    exit 0
  "
  assert_success
}

# The runtime companion: whatever several live arms actually write must also be in the set.
@test "AC-7/17b: reasons emitted at runtime are all in the closed set" {
  cd "$WD"
  mk_clean_repo
  run_helper
  mk_plan "Add a new login flow"
  git -c user.email=a@b.c -c user.name=t commit -q --allow-empty -m work
  run_helper
  rm -rf .git
  run_helper
  run bash -c "
    jq -r 'select(.action==\"branch_target_refined\" and .result==\"noop\") | .metadata.reason' \
      .context/logs/audit.jsonl | sort -u | while read -r r; do
      case \"\$r\" in
        lib_unreachable|jq_unavailable|state_missing|batch_scope|not_a_git_repo|\
already_refined|upstream_exists|base_unresolved|commit_exists|plan_missing|\
no_plan_title|candidate_unusable|candidate_unchanged|candidate_not_better|write_failed) ;;
        *) printf 'OUT OF VOCABULARY: %s\n' \"\$r\"; exit 1 ;;
      esac
    done
  "
  assert_success
}

# A corrupt line before the ok row must not make the once-guard miss (AD-9): jq -e would
# abort at rc 5, the guard would read "never refined", and the window would be spent twice.
@test "AC-7/22: a corrupt audit line does not make the once-guard fail open" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  run_helper
  assert_success
  run rows result
  assert_output "ok"
  # Interleave garbage BEFORE the existing ok row, then re-run.
  printf 'not json at all\n' >> .context/logs/audit.jsonl
  { printf 'not json at all\n'; cat .context/logs/audit.jsonl; } > a && mv a .context/logs/audit.jsonl
  run_helper
  assert_success
  run bash -c "jq -R 'fromjson? | select(.action==\"branch_target_refined\" and .result==\"ok\")' \
    .context/logs/audit.jsonl | jq -s 'length'"
  assert_output "1"
  run bash -c "jq -R 'fromjson? | select(.metadata.reason==\"already_refined\")' \
    .context/logs/audit.jsonl | jq -s 'length'"
  assert_output "1"
}

@test "AC-7/21: stdout ends with ledger_branch= on every arm, and -h exits 2" {
  cd "$WD"
  mk_clean_repo
  run_helper
  assert_success
  assert_line --index "$((${#lines[@]} - 1))" --partial "ledger_branch="
  mk_plan "Add a new login flow"
  run_helper
  assert_success
  assert_line --index "$((${#lines[@]} - 1))" "ledger_branch=feature/add-a-new-login-flow"
  run bash "$PLUGIN_ROOT/$SCRIPT" --help
  assert_failure 2
  assert_output --partial "refine-branch-target.sh"
  run bash "$PLUGIN_ROOT/$SCRIPT" --bogus
  assert_failure 2
  run bash "$PLUGIN_ROOT/$SCRIPT" --plan
  assert_failure 2
}

# --- QA additions: the three arms no fixture reached ------------------------
# `mk_state` always stamps `base_ref`, so every case above enters gate 3 with a name in
# hand. These three enter it without one, or without a branch to compare.

@test "AC-7/23 (QA): an unresolvable base_ref — every source empty — is base_unresolved" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  # Empty the ledger source and leave no fallback: no workspace.json, no origin/HEAD.
  jq '.metadata.base_ref = ""' .context/state.json > s && mv s .context/state.json
  run git symbolic-ref --short refs/remotes/origin/HEAD
  assert_failure
  run_helper
  assert_success
  run rows metadata.reason
  assert_output "base_unresolved"
  run ledger_branch
  assert_output "feature/stamped-at-step-3c"
}

@test "AC-7/24 (QA): detached HEAD refines and records local_branch as empty, never HEAD" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  git checkout -q --detach HEAD
  run_helper
  assert_success
  run rows result
  assert_output "ok"
  # `git rev-parse --abbrev-ref HEAD` answers the literal token HEAD when detached; the
  # row must carry the absence, not that token, or a reader takes it for a branch name.
  run rows metadata.local_branch
  assert_output ""
  run rows metadata.diverges_from_local
  assert_output "true"
  run bash -c "git rev-parse --abbrev-ref HEAD"
  assert_output "HEAD"
}

@test "AC-7/25 (QA): FN_BASE_REF with a non-origin/ prefix resolves no ref today" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  # Pins today's behaviour: gate 3 strips `origin/` and nothing else, so `upstream/master`
  # is looked up verbatim under both candidate namespaces and matches neither. A future
  # general `<remote>/` strip changes this answer — that is the point of asserting it.
  FN_BASE_REF=upstream/master run_helper
  assert_success
  run rows metadata.reason
  assert_output "base_unresolved"
  run ledger_branch
  assert_output "feature/stamped-at-step-3c"
}

# AD-9's `fromjson?` survives an unparsable line; `objects` is what survives a well-formed
# NON-object one. For these STREAMING-form scans (`jq -e -R`, not slurped) the position
# matters: jq reports a per-input error and continues, so a non-object line BEFORE the match
# still exits 0 and the guard holds. A non-object line AFTER the match makes jq exit 5, the
# `&&` reads that as "no prior row", and the once-guard fails OPEN.
#
# The line is therefore appended, not prepended — a prepending version of this test passes
# identically with and without `objects` and proves nothing.
@test "AC-7/26: a non-object line after the ok row does not make the once-guard fail open" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  run_helper
  assert_success
  run rows result
  assert_output "ok"

  # A revised plan title, so the candidate now DIFFERS from the ledger value. Without it
  # gate 5 (candidate_unchanged) masks a missed once-guard and the test cannot see the bug.
  mk_plan "Ship the dark mode toggle"
  printf '123\n' >> .context/logs/audit.jsonl

  run_helper
  assert_success
  # Two rows exist by now (the ok row, then this one) — assert on the latest.
  run bash -c "jq -rs -R '[split(\"\n\")[]|fromjson?|objects
    |select(.action==\"branch_target_refined\")]|last|.metadata.reason' .context/logs/audit.jsonl"
  assert_output "already_refined"
  run ledger_branch
  assert_output "feature/add-a-new-login-flow"
  run bash -c "jq -rs -R '[split(\"\n\")[]|fromjson?|objects
    |select(.action==\"branch_target_refined\" and .result==\"ok\")]|length' .context/logs/audit.jsonl"
  assert_output "1"
}

# Same mechanism on the incumbent-truncation scan. This one fails CLOSED — a missed scan
# reads the incumbent as not-truncated, so gate 6 refuses a refinement it should allow —
# but it is still observable, so the case is discriminating rather than decorative.
@test "AC-7/27: a non-object line after the truncation row does not blind gate 6" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Product list images are blinking before rendering on the catalog screen"
  jq -cn '{ts:"2026-01-01T00:00:00Z", actor:"orchestrator", action:"branch_slug_truncated",
           subject:"PL0", result:"warn", task_id:"PL0",
           metadata:{input_len:"249", slug:"stamped-at-step-3c"}}' \
    >> .context/logs/audit.jsonl
  printf '123\n' >> .context/logs/audit.jsonl

  run_helper
  assert_success
  # The incumbent IS recorded as truncated, so gate 6 passes and the refinement applies.
  run rows result
  assert_output "ok"
  run ledger_branch
  assert_output "bugfix/product-list-images-are-blinking-before"
}

@test "SR: the lib-unreachable audit row refuses a symlinked audit.jsonl" {
  cd "$WD"
  mk_clean_repo
  mk_plan "Add a new login flow"
  mkdir -p lonely target-dir
  cp "$PLUGIN_ROOT/$SCRIPT" lonely/refine-branch-target.sh
  ln -s "$WD/target-dir/escaped.txt" .context/logs/audit.jsonl
  run bash lonely/refine-branch-target.sh --state .context/state.json --context .context
  assert_success
  assert_output --partial "lib_unreachable"
  [ ! -e "$WD/target-dir/escaped.txt" ]
}
