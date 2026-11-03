#!/usr/bin/env bats
# Contract tests for skills/worktask/scripts/land-artifacts.sh.
#
# Contracts covered:
#   - happy path: a boundary pass lands a staged producer artifact into a
#     cross-tree consumer; one ok contract_landed row; landed_paths recorded;
#     consumer status untouched.
#   - sha256_mismatch: a PATH `git` shim (tests/fixtures/worktask/land-artifacts/bin/git)
#     corrupts a keyed `cat-file` read; the run fails closed, blocks the consumer, and
#     the SKILL.md readiness filter stops listing it.
#   - a mid-run write failure rolls back every path this run created (not only the
#     failing one), and a failed git blob read surfaces as git_error, never a raw
#     git exit code; a failed ledger read while collecting declarations exits 2
#     with nothing dispatched.
#   - a consumes path holding an embedded newline or comma is refused as
#     bad_declaration without touching any other ledger row.
#   - preconditions: not_staged, staged_then_modified, not_produced,
#     producer_not_completed, not_blocked_on_producer, self_consume, bad_declaration;
#     a non-pending, non-blocked consumer is skipped with a warn row at the boundary
#     but still refused at the dispatch gate (consumer_already_dispatched).
#   - path-safety ladder: one case per refusal reason reachable from a real tree,
#     including the reserved-destination segments (.claude/, a case-folded .github/).
#   - same_tree: physically-equal roots copy nothing, ok row mode same_tree.
#   - row cardinality: idempotent re-run, gate no-op after boundary, gate into a
#     freshly re-pinned tree (landed_roots unioned, not replaced), boundary skip
#     of a blocked consumer.
#   - --list-landed scoped by --tree: union across rows sharing a tree, tree A
#     never sees tree B's landing, a malformed entry is dropped, a missing --tree
#     exits 2.
#   - --dry-run writes nothing; malformed/unknown ids and no selector exit 2.
#   - parity: the exclusion expression is byte-identical across every transport.
#   - readers: fn-preflight-cmds.sh base-sanity drops an untracked landed file from
#     its working-tree count and does not abort when a landed path has no untracked
#     match; the comment-density hook does not flag an untracked landed file; DR, FN
#     and SKILL.md name the exclusion.
#   - --self-test reaches ALL PASS (dv-tree-preflight.sh convention).
#
# Reader paths named literally for L1 selection reachability:
#   skills/worktask/scripts/land-artifacts.sh
#   skills/worktask/scripts/land-artifacts-selftest.sh
#   skills/worktask/scripts/fn-preflight-cmds.sh
#   hooks/dv-comment-density-gate.sh
#   agents/technical-lead.md
#   agents/project-manager.md
#   skills/worktask/references/orchestration.md
#   skills/worktask/references/state-ledger.md
#   skills/worktask/references/handoff-protocol.md
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"
bats_require_minimum_version 1.5.0

SCRIPT="skills/worktask/scripts/land-artifacts.sh"
FN_SCRIPT="skills/worktask/scripts/fn-preflight.sh"
FIXDIR="${FIXTURES}/worktask/land-artifacts"

# The one exclusion expression, mirrored here only for the parity assertions
# below — never sourced, so a drift in any transport is a diff, not a silent pass.
D8_JQ='[(.tasks // {})[] | .metadata | select(any(.landed_roots // [] | arrays | .[]; . == $root)) | .landed_paths // [] | arrays | .[] | strings | select(test("\\A[A-Za-z0-9._@+/-]+\\z"))] | unique | .[]'

phys() { (cd -P "$1" 2>/dev/null && pwd -P); }

setup() {
  WD="$(mk_tmpworkdir)"
  BASE="$WD/base"
  mkdir -p "$BASE"
  git -C "$BASE" init -q
  git -C "$BASE" config user.email t@t.t
  git -C "$BASE" config user.name t
  printf 'seed\n' > "$BASE/seed.txt"
  git -C "$BASE" add seed.txt
  git -C "$BASE" commit -q -m seed

  git -C "$BASE" worktree add -q -b p-branch "$WD/P" > /dev/null
  git -C "$BASE" worktree add -q -b c-branch "$WD/C" > /dev/null
  P_REAL="$(phys "$WD/P")"
  C_REAL="$(phys "$WD/C")"
  git -C "$P_REAL" config user.email t@t.t
  git -C "$P_REAL" config user.name t
  git -C "$C_REAL" config user.email t@t.t
  git -C "$C_REAL" config user.name t

  printf 'k: v\n' > "$P_REAL/contract.yaml"
  git -C "$P_REAL" add contract.yaml

  CTX="$WD/.context"
  mkdir -p "$CTX/logs"
  STATE="$CTX/state.json"
  jq --arg p "$P_REAL" --arg c "$C_REAL" \
    '(.tasks.DV0.metadata.workspace_path) = $p
     | (.tasks.DV1.metadata.workspace_path) = $c
     | (.tasks.DV2.metadata.workspace_path) = $p' \
    "$FIXDIR/state.land.json" > "$STATE"
  AUDIT="$CTX/logs/audit.jsonl"
}

teardown() {
  _test_helper_cleanup
}

run_land() {
  run bash "$PLUGIN_ROOT/$SCRIPT" --state "$STATE" "$@"
}

# Overrides DV0.produces and DV1.consumes to a single path, replacing the default.
set_pair_path() {
  local p="$1"
  jq --arg p "$p" \
    '(.tasks.DV0.metadata.produces) = [$p]
     | (.tasks.DV1.metadata.consumes) = [{"from": "DV0", "paths": [$p]}]' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

patch_state() {
  jq "$1" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

reason_of() { jq -r '.tasks.DV1.metadata.landing_error.reason' "$STATE"; }

# One case per refusal reachable purely from the ledger (no P/C filesystem
# fixture needed): the lexical check runs before any git/filesystem touch.
assert_refused() {
  local reason="$1" path="$2"
  run_land --producer DV0
  assert_equal "$status" 1
  assert_equal "$(reason_of)" "$reason"
  # dest_tracked/dest_exists seed a real conflicting file at $path on purpose;
  # "nothing landed" there means it survives untouched, not that it's absent.
  if [ "$#" -ge 3 ]; then
    assert_equal "$(cat "$C_REAL/$path")" "$3"
  else
    [ ! -e "$C_REAL/$path" ]
  fi
  assert_audit_row contract_landed --file "$AUDIT" --subject DV1 --result fail \
    --meta reason="$reason" --count 1
}

# ---------------------------------------------------------------------------
# happy path / corrupted read
# ---------------------------------------------------------------------------

@test "contract: happy path lands the producer artifact into the consumer tree" {
  run_land --producer DV0
  assert_equal "$status" 0
  [ -f "$C_REAL/contract.yaml" ]

  local oid dest_sha src_sha
  oid=$(git -C "$P_REAL" ls-files -s -- contract.yaml | awk '{print $2}')
  src_sha=$(git -C "$P_REAL" cat-file blob "$oid" | shasum -a 256 | awk '{print $1}')
  dest_sha=$(shasum -a 256 < "$C_REAL/contract.yaml" | awk '{print $1}')
  assert_equal "$dest_sha" "$src_sha"

  assert_audit_row contract_landed --file "$AUDIT" --subject DV1 --result ok --count 1
  assert_equal "$(jq -r '.tasks.DV1.metadata.landed_paths | index("contract.yaml") != null' "$STATE")" 'true'
  assert_equal "$(jq -r '.tasks.DV1.status' "$STATE")" 'pending'
}

@test "contract: a corrupted cat-file read fails closed with sha256_mismatch" {
  LAND_REAL_GIT="$(command -v git)"
  export LAND_REAL_GIT
  local old_path="$PATH"
  PATH="$FIXDIR/bin:$PATH"
  run_land --producer DV0
  PATH="$old_path"

  assert_equal "$status" 1
  [ ! -e "$C_REAL/contract.yaml" ]
  assert_equal "$(jq -r '.tasks.DV1.metadata.landed_paths // [] | length' "$STATE")" 0
  assert_equal "$(jq -r '.tasks.DV1.status' "$STATE")" 'blocked'
  assert_equal "$(reason_of)" 'sha256_mismatch'
  assert_audit_row contract_landed --file "$AUDIT" --subject DV1 --result fail \
    --meta reason=sha256_mismatch --count 1

  # The SKILL.md readiness filter (canonical jq, § Readiness is mechanical)
  # must no longer offer a `blocked` DV1.
  run jq -r '.tasks as $t | $t | to_entries[]
    | select(.value.status == "pending")
    | select([(.value.blocked_by // [])[] | $t[.].status] | all(. == "completed"))
    | .key' "$STATE"
  refute_line 'DV1'
}

@test "contract: a mid-run write failure rolls back every path this run created" {
  mkdir -p "$P_REAL/new/dir"
  printf 'a\n' > "$P_REAL/new/dir/a.yaml"
  printf 'k: v\n' > "$P_REAL/z.yaml"
  git -C "$P_REAL" add new/dir/a.yaml z.yaml

  patch_state '(.tasks.DV0.metadata.produces) = ["new/dir/a.yaml", "z.yaml"]
    | (.tasks.DV1.metadata.consumes) = [{"from": "DV0", "paths": ["new/dir/a.yaml", "z.yaml"]}]'

  # Both paths pass preflight (they are validly staged); jq `unique` sorts the
  # declared paths ('n' < 'z'), so new/dir/a.yaml writes first and z.yaml's
  # keyed blob read is corrupted second — the exact shape a subshell-scoped
  # rollback ledger cannot see past.
  local oid
  oid=$(git -C "$P_REAL" ls-files -s -- z.yaml | awk '{print $2}')

  LAND_REAL_GIT="$(command -v git)"
  export LAND_REAL_GIT
  export LAND_SHIM_CORRUPT_OID="$oid"
  local old_path="$PATH"
  PATH="$FIXDIR/bin:$PATH"
  run_land --producer DV0
  PATH="$old_path"
  unset LAND_SHIM_CORRUPT_OID

  assert_equal "$status" 1
  [ ! -e "$C_REAL/new" ]
  [ ! -e "$C_REAL/new/dir/a.yaml" ]
  [ ! -e "$C_REAL/z.yaml" ]
  assert_equal "$(jq -r '.tasks.DV1.status' "$STATE")" 'blocked'
  assert_equal "$(jq -r '.tasks.DV1.metadata.landed_paths // [] | length' "$STATE")" 0
  assert_audit_row contract_landed --file "$AUDIT" --subject DV1 --result fail --count 1
}

@test "contract: a TERM signal mid-landing rolls back the already-written path, status 2" {
  mkdir -p "$P_REAL/new/dir"
  printf 'a\n' > "$P_REAL/new/dir/a.yaml"
  printf 'k: v\n' > "$P_REAL/z.yaml"
  git -C "$P_REAL" add new/dir/a.yaml z.yaml

  patch_state '(.tasks.DV0.metadata.produces) = ["new/dir/a.yaml", "z.yaml"]
    | (.tasks.DV1.metadata.consumes) = [{"from": "DV0", "paths": ["new/dir/a.yaml", "z.yaml"]}]'

  # new/dir/a.yaml (n < z) writes first and durably; z.yaml's keyed blob read
  # is where the shim delivers the signal, mid-run, to the script itself.
  local oid
  oid=$(git -C "$P_REAL" ls-files -s -- z.yaml | awk '{print $2}')

  LAND_REAL_GIT="$(command -v git)"
  export LAND_REAL_GIT
  export LAND_SHIM_TERM_OID="$oid"
  # Neutralises the git shim's default (unset CORRUPT_OID => corrupt every
  # cat-file read): new/dir/a.yaml's own read must stream through genuine so
  # it is durably written before z.yaml's keyed read delivers the signal.
  export LAND_SHIM_CORRUPT_OID="0000000000000000000000000000000000000000"
  local old_path="$PATH"
  PATH="$FIXDIR/bin:$PATH"
  run_land --producer DV0
  PATH="$old_path"
  unset LAND_SHIM_TERM_OID LAND_SHIM_CORRUPT_OID

  assert_equal "$status" 2
  [ ! -e "$C_REAL/new" ]
  [ ! -e "$C_REAL/new/dir/a.yaml" ]
  [ ! -e "$C_REAL/z.yaml" ]
  assert_equal "$(jq -r '.tasks.DV1.status' "$STATE")" 'pending'
  assert_equal "$(jq -r '.tasks.DV1.metadata.landed_paths // [] | length' "$STATE")" 0
  run jq -r 'select(.action == "contract_landed" and .result == "ok") | .subject' "$AUDIT"
  refute_line 'DV1'
}

@test "contract: a guarded chmod failure blocks the consumer with git_error, nothing landed" {
  # Only the chmod shim's dir: git stays real, so the blob reads and the oid
  # check pass and the failure is the chmod step alone.
  local old_path="$PATH"
  PATH="$FIXDIR/bin-chmod:$PATH"
  run_land --producer DV0
  PATH="$old_path"

  assert_equal "$status" 1
  [ ! -e "$C_REAL/contract.yaml" ]
  assert_equal "$(jq -r '.tasks.DV1.status' "$STATE")" 'blocked'
  assert_equal "$(reason_of)" 'git_error'
  assert_equal "$(jq -r '.tasks.DV1.metadata.landed_paths // [] | length' "$STATE")" 0
}

@test "contract: a failed git blob read surfaces as git_error, not a raw git exit code" {
  local oid
  oid=$(git -C "$P_REAL" ls-files -s -- contract.yaml | awk '{print $2}')

  LAND_REAL_GIT="$(command -v git)"
  export LAND_REAL_GIT
  export LAND_SHIM_FAIL_OID="$oid"
  local old_path="$PATH"
  PATH="$FIXDIR/bin:$PATH"
  run_land --producer DV0
  PATH="$old_path"
  unset LAND_SHIM_FAIL_OID

  assert_equal "$status" 1
  [ ! -e "$C_REAL/contract.yaml" ]
  assert_equal "$(jq -r '.tasks.DV1.status' "$STATE")" 'blocked'
  assert_equal "$(reason_of)" 'git_error'
  assert_audit_row contract_landed --file "$AUDIT" --subject DV1 --result fail \
    --meta reason=git_error --count 1
}

@test "contract: a failed ledger read while collecting declarations exits 2, nothing dispatched" {
  LAND_REAL_JQ="$(command -v jq)"
  export LAND_REAL_JQ
  local old_path="$PATH"
  PATH="$FIXDIR/bin-jq:$PATH"
  run_land --producer DV0
  PATH="$old_path"

  assert_equal "$status" 2
  [ ! -e "$C_REAL/contract.yaml" ]
  assert_equal "$(jq -r '.tasks.DV1.status' "$STATE")" 'pending'
  assert_equal "$(jq -r '.tasks.DV1.metadata.landed_paths // [] | length' "$STATE")" 0
  run jq -r 'select(.action == "contract_landed") | .subject' "$AUDIT"
  refute_line 'DV1'
}

@test "contract: a consumes path holding an embedded newline is refused as bad_declaration" {
  patch_state '(.tasks.DV1.metadata.consumes) = [{"from": "DV0", "paths": ["a\nb.yaml"]}]'
  local before
  before=$(jq -S '.tasks | del(.DV1)' "$STATE")

  run_land --producer DV0
  assert_equal "$status" 1
  assert_equal "$(reason_of)" 'bad_declaration'
  [ ! -e "$C_REAL/a" ]

  local after
  after=$(jq -S '.tasks | del(.DV1)' "$STATE")
  assert_equal "$after" "$before"
  assert_audit_row contract_landed --file "$AUDIT" --subject DV1 --result fail \
    --meta reason=bad_declaration --count 1
}

@test "contract: a consumes path holding a comma is refused as bad_declaration" {
  patch_state '(.tasks.DV1.metadata.consumes) = [{"from": "DV0", "paths": ["a,b.yaml"]}]'
  local before
  before=$(jq -S '.tasks | del(.DV1)' "$STATE")

  run_land --producer DV0
  assert_equal "$status" 1
  assert_equal "$(reason_of)" 'bad_declaration'

  local after
  after=$(jq -S '.tasks | del(.DV1)' "$STATE")
  assert_equal "$after" "$before"
  assert_audit_row contract_landed --file "$AUDIT" --subject DV1 --result fail \
    --meta reason=bad_declaration --count 1
}

# ---------------------------------------------------------------------------
# path-safety ladder — lexical (no filesystem needed)
# ---------------------------------------------------------------------------

@test "contract: absolute_path is refused" {
  set_pair_path "/etc/passwd"
  assert_refused absolute_path "/etc/passwd"
}

@test "contract: dotdot is refused" {
  set_pair_path "a/../b.yaml"
  assert_refused dotdot "a/../b.yaml"
}

@test "contract: reserved_segment is refused (.GIT case-fold variant)" {
  set_pair_path ".GIT/x"
  assert_refused reserved_segment ".GIT/x"
}

@test "contract: reserved_destination is refused for a landing under .claude/" {
  set_pair_path ".claude/settings.json"
  assert_refused reserved_destination ".claude/settings.json"
}

@test "contract: reserved_destination is refused for a case-folded .github/ segment" {
  set_pair_path ".GitHub/workflows/x.yml"
  assert_refused reserved_destination ".GitHub/workflows/x.yml"
}

@test "contract: control_char is refused" {
  local p
  p=$'bad\x01name.yaml'
  set_pair_path "$p"
  assert_refused control_char "$p"
}

@test "contract: leading_dash is refused" {
  set_pair_path "-bad.yaml"
  assert_refused leading_dash "-bad.yaml"
}

@test "contract: unsafe_char is refused" {
  set_pair_path "bad name.yaml"
  assert_refused unsafe_char "bad name.yaml"
}

# ---------------------------------------------------------------------------
# path-safety ladder — needs a real tree
# ---------------------------------------------------------------------------

@test "contract: symlink_source is refused for a staged symlink (mode 120000)" {
  ln -s /nonexistent "$P_REAL/linkfile.yaml"
  git -C "$P_REAL" add linkfile.yaml
  set_pair_path "linkfile.yaml"
  assert_refused symlink_source "linkfile.yaml"
}

@test "contract: symlink_source is refused via a symlinked intermediate dir in P" {
  mkdir -p "$WD/real_target"
  printf 'inner\n' > "$WD/real_target/inner.txt"
  ln -s "$WD/real_target" "$P_REAL/sdir"
  # `git add` itself refuses to traverse a symlinked dir ("beyond a symbolic
  # link") on every git version, so the index entry is staged directly —
  # this fixture exercises the product's own on-disk symlink check, not git's.
  local oid
  oid=$(git -C "$P_REAL" hash-object -w "$WD/real_target/inner.txt")
  git -C "$P_REAL" update-index --add --cacheinfo "100644,${oid},sdir/inner.txt"
  set_pair_path "sdir/inner.txt"
  assert_refused symlink_source "sdir/inner.txt"
}

@test "contract: symlink_segment is refused for a symlinked dir in C" {
  mkdir -p "$P_REAL/seg"
  printf 'inner\n' > "$P_REAL/seg/inner.yaml"
  git -C "$P_REAL" add seg/inner.yaml
  ln -s "$WD" "$C_REAL/seg"
  set_pair_path "seg/inner.yaml"
  assert_refused symlink_segment "seg/inner.yaml"
}

@test "contract: symlink_dest is refused when the destination is already a symlink" {
  ln -s /nonexistent "$C_REAL/contract.yaml"
  assert_refused symlink_dest "contract.yaml"
}

@test "contract: a dest_escape vector actually classifies as symlink_segment (ladder order)" {
  # A parent segment symlinked outside C's root is caught by dest_walk's per-segment
  # -L check BEFORE the phys_parent/dest_escape comparison is ever reached, so this
  # vector's observed reason is symlink_segment, not dest_escape — pinned here rather
  # than asserted as unreachable so a ladder reorder shows up as a test failure.
  mkdir -p "$P_REAL/outside"
  printf 'inner\n' > "$P_REAL/outside/thing.yaml"
  git -C "$P_REAL" add outside/thing.yaml
  ln -s "$WD" "$C_REAL/outside"
  set_pair_path "outside/thing.yaml"
  assert_refused symlink_segment "outside/thing.yaml"
}

@test "contract: dest_tracked is refused when C already tracks different content" {
  printf 'different\n' > "$C_REAL/contract.yaml"
  git -C "$C_REAL" add contract.yaml
  git -C "$C_REAL" commit -q -m seed-tracked
  assert_refused dest_tracked "contract.yaml" "different"
}

@test "contract: dest_exists is refused for an untracked file with different content" {
  printf 'different\n' > "$C_REAL/contract.yaml"
  assert_refused dest_exists "contract.yaml" "different"
}

@test "contract: not_dir is refused when a parent segment is a regular file" {
  mkdir -p "$P_REAL/blocker"
  printf 'inner\n' > "$P_REAL/blocker/contract2.yaml"
  git -C "$P_REAL" add blocker/contract2.yaml
  printf 'i am a file\n' > "$C_REAL/blocker"
  set_pair_path "blocker/contract2.yaml"
  assert_refused not_dir "blocker/contract2.yaml"
}

@test "contract: gitlink (mode 160000) is refused" {
  local head_sha
  head_sha=$(git -C "$P_REAL" rev-parse HEAD)
  git -C "$P_REAL" update-index --add --cacheinfo "160000,${head_sha},sub.git"
  set_pair_path "sub.git"
  assert_refused gitlink "sub.git"
}

@test "contract: filtered_path is refused for a filter=lfs attribute" {
  printf 'lfs.bin filter=lfs\n' > "$P_REAL/.gitattributes"
  git -C "$P_REAL" add .gitattributes
  git -C "$P_REAL" commit -q -m attrs
  printf 'binary-ish\n' > "$P_REAL/lfs.bin"
  git -C "$P_REAL" add lfs.bin
  set_pair_path "lfs.bin"
  assert_refused filtered_path "lfs.bin"
}

# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------

@test "contract: not_staged is refused when the path was never git add'ed" {
  set_pair_path "never-staged.yaml"
  assert_refused not_staged "never-staged.yaml"
}

@test "contract: staged_then_modified is refused for a post-stage edit" {
  printf 'a\n' > "$P_REAL/mod.yaml"
  git -C "$P_REAL" add mod.yaml
  printf 'b\n' > "$P_REAL/mod.yaml"
  set_pair_path "mod.yaml"
  assert_refused staged_then_modified "mod.yaml"
}

@test "contract: not_produced is refused when the path is absent from producer.produces" {
  patch_state '(.tasks.DV1.metadata.consumes) = [{"from": "DV0", "paths": ["other.yaml"]}]'
  assert_refused not_produced "other.yaml"
}

@test "contract: a boundary pass skips a non-pending, non-blocked consumer with a warn row" {
  # A producer rework must not flip an already-completed
  # consumer to blocked. The gate stays the sole authority over dispatch.
  patch_state '(.tasks.DV1.status) = "completed"'
  run_land --producer DV0
  assert_equal "$status" 0
  [ ! -e "$C_REAL/contract.yaml" ]
  assert_equal "$(jq -r '.tasks.DV1.status' "$STATE")" 'completed'
  assert_equal "$(jq -r '.tasks.DV1.metadata.landed_paths // [] | length' "$STATE")" 0
  assert_audit_row contract_landed --file "$AUDIT" --subject DV1 --result warn \
    --meta reason=consumer_not_pending --meta status=completed --count 1
}

@test "contract: the dispatch gate still refuses a consumer that is already dispatched" {
  patch_state '(.tasks.DV1.status) = "in_progress"'
  run bash "$PLUGIN_ROOT/$SCRIPT" --state "$STATE" --consumer DV1
  assert_equal "$status" 1
  assert_equal "$(reason_of)" 'consumer_already_dispatched'
}

@test "contract: producer_not_completed is refused when P has not completed" {
  patch_state '(.tasks.DV0.status) = "pending"'
  assert_refused producer_not_completed "contract.yaml"
}

@test "contract: not_blocked_on_producer is refused when C.blocked_by omits P" {
  patch_state '(.tasks.DV1.blocked_by) = []'
  assert_refused not_blocked_on_producer "contract.yaml"
}

@test "contract: self_consume is refused when a row consumes from itself" {
  patch_state '(.tasks.DV1.metadata.consumes) = [{"from": "DV1", "paths": ["contract.yaml"]}]
    | (.tasks.DV1.blocked_by) = ["DV1"]'
  run_land --consumer DV1
  assert_equal "$status" 1
  assert_equal "$(reason_of)" 'self_consume'
}

@test "contract: bad_declaration is refused for a malformed consumes shape" {
  patch_state '(.tasks.DV1.metadata.consumes) = [{"from": "DV0"}]'
  run_land --producer DV0
  assert_equal "$status" 1
  assert_equal "$(reason_of)" 'bad_declaration'
  assert_audit_row contract_landed --file "$AUDIT" --subject DV1 --result fail \
    --meta reason=bad_declaration --count 1
}

@test "contract: bad_declaration is refused for a from id holding a trailing newline" {
  # The newline lives in the jq literal: "$(printf 'DV0\n')" would strip it.
  # The gate, not the boundary: a boundary pass for DV0 skips a row whose raw
  # `from` never equals "DV0".
  patch_state '(.tasks.DV1.metadata.consumes) = [{"from": "DV0\n", "paths": ["contract.yaml"]}]'
  run_land --consumer DV1
  assert_equal "$status" 1
  assert_equal "$(reason_of)" 'bad_declaration'
  [ ! -e "$C_REAL/contract.yaml" ]
  assert_audit_row contract_landed --file "$AUDIT" --subject DV1 --result fail \
    --meta reason=bad_declaration --count 1
}

@test "contract: bad_declaration is refused for an empty-string path" {
  patch_state '(.tasks.DV1.metadata.consumes) = [{"from": "DV0", "paths": [""]}]'
  run_land --producer DV0
  assert_equal "$status" 1
  assert_equal "$(reason_of)" 'bad_declaration'
  assert_audit_row contract_landed --file "$AUDIT" --subject DV1 --result fail \
    --meta reason=bad_declaration --count 1
}

# ---------------------------------------------------------------------------
# same-tree landing and row cardinality
# ---------------------------------------------------------------------------

@test "contract: same_tree writes an ok row and records no landed_paths" {
  run_land --producer DV0
  assert_equal "$status" 0
  assert_audit_row contract_landed --file "$AUDIT" --subject DV2 --result ok \
    --meta mode=same_tree --count 1
  assert_equal "$(jq -r '.tasks.DV2.metadata.landed_paths // [] | length' "$STATE")" 0
}

@test "contract: idempotent boundary re-run does not duplicate landed_paths" {
  run_land --producer DV0
  assert_equal "$status" 0
  run_land --producer DV0
  assert_equal "$status" 0
  local n
  n=$(jq -r '[.tasks.DV1.metadata.landed_paths[] | select(. == "contract.yaml")] | length' "$STATE")
  assert_equal "$n" 1
}

@test "contract: commit_landed drops a stored entry holding an embedded newline instead of laundering it" {
  jq --arg stray "$(printf 'ok.md\nevil')" \
    '(.tasks.DV1.metadata.landed_paths) = [$stray]' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  run_land --producer DV0
  assert_equal "$status" 0
  run jq -c '.tasks.DV1.metadata.landed_paths' "$STATE"
  assert_output '["contract.yaml"]'
}

@test "contract: the dispatch gate after a boundary pass is a no-op (no new row)" {
  run_land --producer DV0
  assert_equal "$status" 0
  local before
  before=$(wc -l < "$AUDIT" | tr -d ' ')
  run_land --consumer DV1
  assert_equal "$status" 0
  local after
  after=$(wc -l < "$AUDIT" | tr -d ' ')
  assert_equal "$after" "$before"
}

@test "contract: the dispatch gate into a freshly re-pinned tree adds one copied row and unions landed_roots" {
  run_land --producer DV0
  assert_equal "$status" 0

  git -C "$BASE" worktree add -q -b c2-branch "$WD/C2" > /dev/null
  local C2_REAL
  C2_REAL="$(phys "$WD/C2")"
  git -C "$C2_REAL" config user.email t@t.t
  git -C "$C2_REAL" config user.name t
  jq --arg c2 "$C2_REAL" '.tasks.DV1.metadata.workspace_path = $c2' "$STATE" > "$STATE.tmp" \
    && mv "$STATE.tmp" "$STATE"

  # The boundary pass above already wrote its own DV1/copied row; clear it so
  # the count below reflects only what this dispatch-gate call adds.
  : > "$AUDIT"
  run_land --consumer DV1
  assert_equal "$status" 0
  [ -f "$C2_REAL/contract.yaml" ]
  assert_audit_row contract_landed --file "$AUDIT" --subject DV1 --result ok \
    --meta mode=copied --count 1

  # landed_roots must gain C2's root without losing C's — a union, not a
  # replacement, or the boundary copy left behind in the old tree would stop
  # being excluded there.
  local roots
  roots=$(jq -r '.tasks.DV1.metadata.landed_roots[]' "$STATE")
  printf '%s\n' "$roots" | grep -qxF -- "$C_REAL"
  printf '%s\n' "$roots" | grep -qxF -- "$C2_REAL"
}

@test "contract: a boundary pass skips a blocked consumer, keeping its landing_error" {
  patch_state '(.tasks.DV1.status) = "blocked"
    | (.tasks.DV1.metadata.landing_error) = {"reason": "sha256_mismatch", "path": "contract.yaml", "producer": "DV0"}'
  run_land --producer DV0
  assert_equal "$status" 0
  assert_equal "$(reason_of)" 'sha256_mismatch'
  assert_audit_row contract_landed --file "$AUDIT" --subject DV1 --absent
}

# ---------------------------------------------------------------------------
# --list-landed, scoped by --tree / --dry-run / usage
# ---------------------------------------------------------------------------

@test "contract: --list-landed prints the sorted unique union across rows sharing a tree" {
  jq --arg c "$C_REAL" \
    '(.tasks.DV1.metadata.landed_paths) = ["b.yaml", "a.yaml"]
     | (.tasks.DV1.metadata.landed_roots) = [$c]
     | (.tasks.DV2.metadata.landed_paths) = ["a.yaml", "c.yaml"]
     | (.tasks.DV2.metadata.landed_roots) = [$c]' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  run bash "$PLUGIN_ROOT/$SCRIPT" --list-landed --tree "$C_REAL" --state "$STATE"
  assert_equal "$status" 0
  assert_equal "$output" "$(printf 'a.yaml\nb.yaml\nc.yaml')"
}

@test "contract: --list-landed on an empty ledger prints nothing and exits 0" {
  local empty="$WD/empty-state.json"
  printf '{"tasks":{}}' > "$empty"
  run bash "$PLUGIN_ROOT/$SCRIPT" --list-landed --tree "$WD" --state "$empty"
  assert_equal "$status" 0
  assert_equal "$output" ""
}

@test "contract: --list-landed without --tree exits 2" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --list-landed --state "$STATE"
  assert_equal "$status" 2
}

@test "contract: --list-landed never lists a path landed in a different tree" {
  jq --arg c "$C_REAL" \
    '(.tasks.DV1.metadata.landed_paths) = ["only-in-c.yaml"]
     | (.tasks.DV1.metadata.landed_roots) = [$c]' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  run bash "$PLUGIN_ROOT/$SCRIPT" --list-landed --tree "$P_REAL" --state "$STATE"
  assert_equal "$status" 0
  assert_equal "$output" ""
}

@test "contract: --list-landed drops an entry containing a space or a newline" {
  jq --arg c "$C_REAL" --arg nl "$(printf 'a\nb.yaml')" \
    '(.tasks.DV1.metadata.landed_paths) = ["good.yaml", "bad name.yaml", $nl]
     | (.tasks.DV1.metadata.landed_roots) = [$c]' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  run bash "$PLUGIN_ROOT/$SCRIPT" --list-landed --tree "$C_REAL" --state "$STATE"
  assert_equal "$status" 0
  assert_equal "$output" "good.yaml"
}

@test "contract: a non-strict --list-landed --tree read drops an entry with a trailing newline" {
  # Oniguruma's $ matches just before a FINAL trailing newline, not only at the
  # true end of string — a plain ^...$ anchor lets "foo.md\n" through; \A..\z
  # does not.
  jq --arg c "$C_REAL" \
    '(.tasks.DV1.metadata.landed_paths) = ["good.yaml", "foo.md\n"]
     | (.tasks.DV1.metadata.landed_roots) = [$c]' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  run bash "$PLUGIN_ROOT/$SCRIPT" --list-landed --tree "$C_REAL" --state "$STATE"
  assert_equal "$status" 0
  assert_equal "$output" "good.yaml"
}

# ---------------------------------------------------------------------------
# --check-path: sole mode, no ledger read and no git call
# ---------------------------------------------------------------------------

@test "contract: --check-path accepts a safe relative path, silent, exit 0" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --check-path "docs/api.md"
  assert_equal "$status" 0
  assert_equal "$output" ""
}

@test "contract: --check-path refuses a parent-traversal segment" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --check-path "../x"
  assert_equal "$status" 1
  assert_equal "$output" "reason=dotdot"
}

@test "contract: --check-path refuses an absolute path" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --check-path "/abs"
  assert_equal "$status" 1
  assert_equal "$output" "reason=absolute_path"
}

@test "contract: --check-path refuses a reserved destination segment" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --check-path ".git/config"
  assert_equal "$status" 1
  assert_equal "$output" "reason=reserved_segment"
}

@test "contract: --check-path refuses a leading-dash segment" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --check-path "-x"
  assert_equal "$status" 1
  assert_equal "$output" "reason=leading_dash"
}

@test "contract: --check-path refuses an embedded space" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --check-path "a b"
  assert_equal "$status" 1
  assert_equal "$output" "reason=unsafe_char"
}

@test "contract: --check-path with no value exits 2" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --check-path
  assert_equal "$status" 2
}

@test "contract: --check-path combined with --list-landed exits 2" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --check-path a --list-landed --tree "$WD"
  assert_equal "$status" 2
}

# ---------------------------------------------------------------------------
# --list-landed --strict
# ---------------------------------------------------------------------------

@test "contract: --list-landed --strict prints the same lines as non-strict for a clean set" {
  jq --arg c "$C_REAL" \
    '(.tasks.DV1.metadata.landed_paths) = ["b.yaml", "a.yaml"]
     | (.tasks.DV1.metadata.landed_roots) = [$c]' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  run bash "$PLUGIN_ROOT/$SCRIPT" --list-landed --tree "$C_REAL" --strict --state "$STATE"
  assert_equal "$status" 0
  assert_equal "$output" "$(printf 'a.yaml\nb.yaml')"
}

@test "contract: --list-landed --strict refuses a dotdot entry scoped to the tree, empty stdout" {
  jq --arg c "$C_REAL" \
    '(.tasks.DV1.metadata.landed_paths) = ["../x"]
     | (.tasks.DV1.metadata.landed_roots) = [$c]' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --list-landed --tree "$C_REAL" --strict --state "$STATE"
  assert_equal "$status" 1
  assert_equal "$output" ""
  [ -n "$stderr" ]
}

@test "contract: --list-landed --strict refuses an entry holding an embedded newline" {
  jq --arg c "$C_REAL" --arg nl "$(printf 'a\nb')" \
    '(.tasks.DV1.metadata.landed_paths) = [$nl]
     | (.tasks.DV1.metadata.landed_roots) = [$c]' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --list-landed --tree "$C_REAL" --strict --state "$STATE"
  assert_equal "$status" 1
  assert_equal "$output" ""
}

@test "contract: --list-landed --strict refuses a non-string landed_paths entry" {
  jq --arg c "$C_REAL" \
    '(.tasks.DV1.metadata.landed_paths) = [1]
     | (.tasks.DV1.metadata.landed_roots) = [$c]' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --list-landed --tree "$C_REAL" --strict --state "$STATE"
  assert_equal "$status" 1
  assert_equal "$output" ""
}

@test "contract: --list-landed --strict ignores an unsafe entry scoped to a different tree" {
  jq --arg p "$P_REAL" --arg c "$C_REAL" \
    '(.tasks.DV0.metadata.landed_paths) = ["../x"]
     | (.tasks.DV0.metadata.landed_roots) = [$p]
     | (.tasks.DV1.metadata.landed_paths) = ["ok.yaml"]
     | (.tasks.DV1.metadata.landed_roots) = [$c]' \
    "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  run bash "$PLUGIN_ROOT/$SCRIPT" --list-landed --tree "$C_REAL" --strict --state "$STATE"
  assert_equal "$status" 0
  assert_equal "$output" "ok.yaml"
}

@test "contract: --strict without --list-landed exits 2" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --strict --state "$STATE"
  assert_equal "$status" 2
}

@test "contract: --dry-run writes nothing to disk, the ledger or the audit log" {
  local before_sum after_sum
  before_sum=$(shasum -a 256 < "$STATE")
  run_land --producer DV0 --dry-run
  assert_equal "$status" 0
  [ ! -e "$C_REAL/contract.yaml" ]
  after_sum=$(shasum -a 256 < "$STATE")
  assert_equal "$after_sum" "$before_sum"
  [ ! -s "$AUDIT" ]
}

@test "contract: no selector at all exits 2" {
  run_land
  assert_equal "$status" 2
}

@test "contract: a malformed task id exits 2" {
  run_land --consumer DVx
  assert_equal "$status" 2
}

@test "contract: an unknown task id exits 2" {
  run_land --consumer DV9
  assert_equal "$status" 2
}

# ---------------------------------------------------------------------------
# --self-test
# ---------------------------------------------------------------------------

@test "contract: --self-test reaches ALL PASS" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_equal "$status" 0
  assert_output --partial "ALL PASS"
  assert_output --regexp 'ALL PASS \([1-9][0-9]* passed, 0 failed\)'
}

# ---------------------------------------------------------------------------
# parity — the exclusion expression is byte-identical at every transport
# ---------------------------------------------------------------------------

@test "contract: the exclusion expression is byte-identical in every transport" {
  local f
  for f in skills/worktask/scripts/land-artifacts.sh hooks/dv-comment-density-gate.sh \
           agents/technical-lead.md agents/project-manager.md skills/worktask/references/state-ledger.md; do
    run grep -cF -- "$D8_JQ" "$(contract_source "$PLUGIN_ROOT/$f")"
    assert_success
    [ "$output" -ge 1 ]
  done
}

# ---------------------------------------------------------------------------
# reader exclusion — every transport drops an untracked landed path from its
# own count/scan, scoped to the tree that received the landing
# ---------------------------------------------------------------------------

@test "contract: fn-preflight-cmds.sh and the selftest harness name the landed-set transport" {
  grep -qE -- '--list-landed|landed_paths' \
    "$PLUGIN_ROOT/skills/worktask/scripts/fn-preflight-cmds.sh"
  [ -e "$PLUGIN_ROOT/skills/worktask/scripts/land-artifacts-selftest.sh" ]
}

@test "contract: fn-stream-merge.sh and blocked-on-dispatch.sh name the strict per-tree landed transport" {
  local f
  for f in skills/worktask/scripts/fn-stream-merge.sh skills/worktask/scripts/blocked-on-dispatch.sh; do
    grep -q -- '--list-landed' "$(contract_source "$PLUGIN_ROOT/$f")"
    grep -q -- '--strict' "$(contract_source "$PLUGIN_ROOT/$f")"
  done
  run grep -F -- '.metadata.landed_paths // [] | .[] | strings]' \
    "$PLUGIN_ROOT/skills/worktask/scripts/fn-stream-merge.sh"
  assert_failure
  run grep -F -- '.landed_roots' \
    "$PLUGIN_ROOT/skills/worktask/scripts/fn-stream-merge.sh"
  assert_failure
}

@test "contract: fn-preflight base-sanity drops an untracked landed file from its working-tree count" {
  local rwd
  rwd="$(mk_tmpworkdir)"
  mkdir -p "$rwd/.context/logs"
  (
    cd "$rwd"
    git init -q -b master .
    git -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m base
    git checkout -q -b feature/work
  )
  local i
  for i in $(seq 1 22); do printf 'x\n' > "$rwd/junk$i.txt"; done
  printf 'k: v\n' > "$rwd/landed.yaml"

  local root
  root="$(phys "$(git -C "$rwd" rev-parse --show-toplevel)")"
  jq -n --arg r "$root" \
    '{version: 2,
      tasks: {DV0: {status: "completed",
                    metadata: {landed_paths: ["landed.yaml"], landed_roots: [$r]}}},
      facts: {files_modified: ["seed.txt"]},
      metadata: {base_ref: "master"}}' \
    > "$rwd/.context/state.json"

  cd "$rwd"
  run bash "$PLUGIN_ROOT/$FN_SCRIPT" base-sanity
  assert_equal "$status" 0

  local tree_files
  tree_files=$(jq -rs 'map(select(.action == "base_sanity"))[-1].metadata.tree_files' \
    "$rwd/.context/logs/audit.jsonl")
  # 22 plain untracked files plus the landed one: without the tree-scoped
  # subtraction this would read 23. Reading 22 proves the landed file never
  # entered the denominator, not merely that it failed to trip a rung.
  assert_equal "$tree_files" "22"
}

@test "contract: fn-preflight base-sanity does not abort when a landed path has no untracked match" {
  local rwd
  rwd="$(mk_tmpworkdir)"
  mkdir -p "$rwd/.context/logs"
  (
    cd "$rwd"
    git init -q -b master .
    git -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m base
    git checkout -q -b feature/work
  )
  # Real untracked files present, none of which match the declared landed
  # path — the exact shape that pipes an empty match into `grep -f`.
  printf 'x\n' > "$rwd/other1.txt"
  printf 'x\n' > "$rwd/other2.txt"

  local root
  root="$(phys "$(git -C "$rwd" rev-parse --show-toplevel)")"
  jq -n --arg r "$root" \
    '{version: 2,
      tasks: {DV0: {status: "completed",
                    metadata: {landed_paths: ["ghost.yaml"], landed_roots: [$r]}}},
      facts: {files_modified: ["seed.txt"]},
      metadata: {base_ref: "master"}}' \
    > "$rwd/.context/state.json"

  cd "$rwd"
  run bash "$PLUGIN_ROOT/$FN_SCRIPT" base-sanity
  assert_equal "$status" 0
  assert_output --partial "base-sanity: pass"
}

@test "contract: the canonical exclusion expression matches an untracked-landed-path on a fixture tree" {
  local repo
  repo="$(mk_git_fixture --branch main --file 'README.md:seed\n' --commit init)"
  printf 'k: v\n' > "$repo/contract.yaml"
  local root
  root="$(phys "$repo")"
  local ledger="$WD/reader-state.json"
  jq -n --arg p contract.yaml --arg r "$root" \
    '{tasks: {DV1: {status: "pending", metadata: {landed_paths: [$p], landed_roots: [$r]}}}}' \
    > "$ledger"

  local landed untracked
  landed=$(jq -r --arg root "$root" "$D8_JQ" "$ledger" | LC_ALL=C sort)
  untracked=$(git -C "$repo" status --porcelain --untracked-files=all \
    | awk '/^\?\? /{print substr($0,4)}' | LC_ALL=C sort)
  # Every untracked path in the fixture tree is accounted for by the landed set.
  local remainder
  remainder=$(comm -23 <(printf '%s\n' "$untracked") <(printf '%s\n' "$landed") | grep -v '^$' || true)
  assert_equal "$remainder" ""
}

@test "contract: the density hook does not flag an over-dense untracked landed file" {
  local repo
  repo="$(mk_git_fixture --branch main --file 'README.md:seed\n' --commit init)"
  mkdir -p "$repo/.context/logs"
  # Bloated content the hook would otherwise flag — except it is declared
  # landed for this tree.
  {
    printf '/// Essay line %s narrating history the standard bans.\n' 1 2 3 4 5 6 7 8 9 10
    printf '/// Contract prose %s restating the signature.\n' 1 2 3 4 5 6 7 8 9 10
    printf '/// Provenance %s.\n' 1 2 3 4 5 6 7 8 9 10
    echo 'struct Bloated {'
    printf '    let field%s: Int\n' 1 2 3 4 5 6 7 8
    echo '}'
  } > "$repo/Landed.swift"

  local root
  root="$(phys "$(git -C "$repo" rev-parse --show-toplevel)")"
  jq -n --arg r "$root" \
    '{version: 2,
      tasks: {DV0: {status: "completed",
                    metadata: {landed_paths: ["Landed.swift"], landed_roots: [$r]}}}}' \
    > "$repo/.context/state.json"

  run_script_env --env "CLAUDE_PROJECT_DIR=$repo" --cwd "$repo" \
    --stdin-string '{"agent_type":"corpflow:swift-developer","agent_id":"agt_t","session_id":"s"}' \
    "hooks/dv-comment-density-gate.sh"

  assert_success
  assert_output ''
  assert_audit_row comment_density_block --file "$repo/.context/logs/audit.jsonl" --absent
}

@test "contract: DR, FN and SKILL.md name the landed-set exclusion" {
  grep -qE -- "landed_paths|--list-landed" "$PLUGIN_ROOT/agents/technical-lead.md"
  grep -qE -- "landed_paths|--list-landed" "$PLUGIN_ROOT/agents/project-manager.md"
  grep -qE -- "landed_paths|--list-landed" "$(contract_source "$PLUGIN_ROOT/skills/worktask/references/orchestration.md")"
}

@test "contract: handoff-protocol.md documents the ledger-task fan-out land-artifacts.sh resolves through" {
  [ -e "$(contract_source "$PLUGIN_ROOT/skills/worktask/references/handoff-protocol.md")" ]
  grep -q "workspace_path" "$(contract_source "$PLUGIN_ROOT/skills/worktask/references/handoff-protocol.md")"
}
