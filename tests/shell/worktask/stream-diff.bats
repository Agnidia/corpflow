#!/usr/bin/env bats
# Contract tests for skills/worktask/scripts/stream-diff.sh.
#   - source ladder per row: committed > staged > worktree > empty
#   - base only from resolve_base_ref; unresolved base is reported, never guessed
#   - rows sharing one physical tree print one body, later rows carry shared_with
#   - read-only: index, refs and worktree bytes unchanged
#   - exit 2 usage / 3 unresolved input, stdout empty on both
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"
bats_require_minimum_version 1.5.0

SCRIPT="skills/worktask/scripts/stream-diff.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  WD="$(cd "$WD" && pwd -P)"
  export HOME="$WD" GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  unset FN_BASE_REF
  git init -q -b develop "$WD/repo"
  printf 'base\n' > "$WD/repo/a.txt"
  printf 'base\n' > "$WD/repo/b.txt"
  git -C "$WD/repo" add -A
  git -C "$WD/repo" commit -qm base
  git init -q --bare "$WD/origin.git"
  git -C "$WD/repo" remote add origin "$WD/origin.git"
  git -C "$WD/repo" push -q origin develop
  git -C "$WD/repo" fetch -q origin
  git -C "$WD/repo" worktree add -q -b feature/s-service "$WD/wt-service" develop
  git -C "$WD/repo" worktree add -q -b feature/s-web "$WD/wt-web" develop
  mkdir -p "$WD/ledger/.context/logs"
  L="$WD/ledger/.context/state.json"
  jq --arg s "$WD/wt-service" --arg w "$WD/wt-web" \
    '.tasks.DV0.metadata.workspace_path = $s | .tasks.DV1.metadata.workspace_path = $w
     | .metadata = {base_ref: "develop"}' \
    "$FIXTURES/worktask/dv-fanout/state.two-stream.json" > "$L"
}

header_of() { # $1=task
  printf '%s\n' "$output" | grep "^stream-diff task=$1 "
}

@test "committed: a non-empty <ref>...HEAD range wins and carries its body" {
  printf 'svc\n' >> "$WD/wt-service/a.txt"
  git -C "$WD/wt-service" commit -qam "feat: service"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L"
  assert_success
  [[ "$(header_of DV0)" == *"source=committed"* ]]
  # assert_line, not a bare [[ ]]: bash 3.2 does not fail a test on a non-final [[ ]].
  assert_line --regexp '^stream-diff task=DV0 .* base=origin/develop base_source=task files=1 '
  [[ "$output" == *"+svc"* ]]
}

@test "task row: the row's base_ref outranks a wrong ledger mirror (AC-1)" {
  # origin/master stays one commit behind develop, so a master base would also count
  # develop's d.txt: files=1 proves the diff ran against the row's base.
  git -C "$WD/repo" push -q origin develop:master
  printf 'dev\n' > "$WD/repo/d.txt"
  git -C "$WD/repo" add d.txt
  git -C "$WD/repo" commit -qm "dev history"
  git -C "$WD/repo" push -q origin develop
  git -C "$WD/repo" fetch -q origin
  git -C "$WD/wt-service" merge -q --ff-only origin/develop
  printf 'svc\n' >> "$WD/wt-service/a.txt"
  git -C "$WD/wt-service" commit -qam "feat: service"
  jq '.metadata.base_ref = "master" | .tasks.DV0.metadata.base_ref = "develop"' "$L" > "$L.tmp" && mv "$L.tmp" "$L"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L" --task DV0 --caller DR0
  assert_success
  assert_line --regexp '^stream-diff task=DV0 .* source=committed base=develop base_source=task files=1 '
}

@test "staged: an empty range falls back to the index and is non-empty (AC2)" {
  printf 'web\n' >> "$WD/wt-web/b.txt"
  git -C "$WD/wt-web" add b.txt
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L"
  assert_success
  [[ "$(header_of DV1)" == *"source=staged"* ]]
  [[ "$(header_of DV1)" == *"files=1"* ]]
  [[ "$output" == *"+web"* ]]
}

@test "worktree: an unstaged tracked edit is labelled worktree, not empty" {
  printf 'wip\n' >> "$WD/wt-web/b.txt"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L" --task DV1
  assert_success
  [[ "$(header_of DV1)" == *"source=worktree"* ]]
  [[ "$output" == *"+wip"* ]]
  run grep -c '^stream-diff ' <<< "$output"
  assert_output "1"
}

@test "empty: a clean tree is labelled empty with reason no_changes" {
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L"
  assert_success
  [[ "$(header_of DV0)" == *"source=empty"*"reason=no_changes"* ]]
  [[ "$(header_of DV1)" == *"source=empty"*"reason=no_changes"* ]]
}

@test "committed: staged_also counts uncommitted paths the body omits" {
  printf 'svc\n' >> "$WD/wt-service/a.txt"
  git -C "$WD/wt-service" commit -qam "feat: service"
  printf 'more\n' >> "$WD/wt-service/b.txt"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L" --task DV0
  assert_success
  [[ "$(header_of DV0)" == *"source=committed"*"staged_also=1"* ]]
}

@test "unresolved base: reported as base_unresolved, never a literal branch" {
  jq '.metadata = {} | del(.tasks[].metadata.base_ref)' "$L" > "$L.tmp" && mv "$L.tmp" "$L"
  printf 'web\n' >> "$WD/wt-web/b.txt"
  git -C "$WD/wt-web" commit -qam "feat: web"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L" --task DV1
  assert_success
  [[ "$(header_of DV1)" == *"base=- base_source=unresolved"*"reason=base_unresolved"* ]]
  [[ "$output" != *"master"* ]]
}

@test "read-only: index, refs and worktree bytes are unchanged by a run" {
  printf 'web\n' >> "$WD/wt-web/b.txt"
  git -C "$WD/wt-web" add b.txt
  printf 'wip\n' >> "$WD/wt-service/a.txt"
  local idx_web idx_svc refs bytes
  idx_web=$(git -C "$WD/wt-web" ls-files -s | shasum)
  idx_svc=$(git -C "$WD/wt-service" ls-files -s | shasum)
  refs=$(git -C "$WD/repo" for-each-ref | shasum)
  bytes=$(cat "$WD/wt-web/b.txt" "$WD/wt-service/a.txt" | shasum)
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L"
  assert_success
  [ "$(git -C "$WD/wt-web" ls-files -s | shasum)" = "$idx_web" ]
  [ "$(git -C "$WD/wt-service" ls-files -s | shasum)" = "$idx_svc" ]
  [ "$(git -C "$WD/repo" for-each-ref | shasum)" = "$refs" ]
  [ "$(cat "$WD/wt-web/b.txt" "$WD/wt-service/a.txt" | shasum)" = "$bytes" ]
}

@test "shared tree: the later row prints no body and names the lower row" {
  jq --arg s "$WD/wt-service" '.tasks.DV1.metadata.workspace_path = $s' "$L" > "$L.tmp" && mv "$L.tmp" "$L"
  printf 'svc\n' >> "$WD/wt-service/a.txt"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L"
  assert_success
  [[ "$(header_of DV0)" == *"shared_with=-"* ]]
  [[ "$(header_of DV1)" == *"shared_with=DV0"* ]]
  run grep -c '^+svc' <<< "$output"
  assert_output "1"
}

@test "skipped rows are dropped; rows print in ascending task-id order" {
  jq '.tasks.DV10 = .tasks.DV1 | .tasks.DV10.metadata.stream = "late"' "$L" > "$L.tmp" && mv "$L.tmp" "$L"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L" --format tsv
  assert_success
  run awk -F'\t' 'NR > 1 { print $1 }' <<< "$output"
  assert_output "$(printf 'DV0\nDV1\nDV10')"
  jq '.tasks.DV1.status = "skipped"' "$L" > "$L.tmp" && mv "$L.tmp" "$L"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L" --format tsv
  run awk -F'\t' 'NR > 1 { print $1 }' <<< "$output"
  assert_output "$(printf 'DV0\nDV10')"
}

@test "tsv: line 1 is the column names and no body is printed" {
  printf 'svc\n' >> "$WD/wt-service/a.txt"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L" --format tsv
  assert_success
  assert_line --index 0 "$(printf 'task\tstream\tsource\tbase\tbase_source\tfiles\tuntracked\tstaged_also\tshared_with\treason\ttree')"
  [[ "$output" != *"+svc"* ]]
}

@test "names: body paths as <X><TAB><path>, untracked as ?<TAB><path>" {
  printf 'svc\n' >> "$WD/wt-service/a.txt"
  printf 'new\n' > "$WD/wt-service/c.txt"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L" --task DV0 --format names
  assert_success
  assert_line "$(printf 'M\ta.txt')"
  assert_line "$(printf '?\tc.txt')"
  [[ "$(header_of DV0)" == *"untracked=1"* ]]
}

@test "tree mode: one block for an absolute tree with no ledger rows" {
  printf 'web\n' >> "$WD/wt-web/b.txt"
  git -C "$WD/wt-web" add b.txt
  run --separate-stderr env FN_BASE_REF=develop bash "$PLUGIN_ROOT/$SCRIPT" --tree "$WD/wt-web"
  assert_success
  [[ "$output" == "stream-diff task=- stream=- source=staged base=develop base_source=env"* ]]
}

@test "tree mode: an inherited BASE_REF_TASK_ID is cleared, so no task row answers" {
  mkdir -p "$WD/wt-web/.context"
  printf '{"tasks":{"DV0":{"metadata":{"base_ref":"master"}}},"metadata":{"base_ref":"develop"}}\n' \
    > "$WD/wt-web/.context/state.json"
  run --separate-stderr env BASE_REF_TASK_ID=DV0 bash "$PLUGIN_ROOT/$SCRIPT" --tree "$WD/wt-web"
  assert_success
  assert_line --regexp '^stream-diff task=- .* base=develop base_source=state '
}

@test "missing tree: tree_missing degrades the row, the run still exits 0" {
  jq '.tasks.DV1.metadata.workspace_path = "/nonexistent-398/web"' "$L" > "$L.tmp" && mv "$L.tmp" "$L"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L"
  assert_success
  [[ "$(header_of DV1)" == *"source=empty"*"reason=tree_missing"* ]]
  run jq -r 'select(.action == "stream_diff_resolved") | .result' "$WD/ledger/.context/logs/audit.jsonl"
  assert_output "degraded"
}

@test "audit: one stream_diff_resolved row carrying the caller and every block" {
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L" --caller DR0
  assert_success
  run jq -r 'select(.action == "stream_diff_resolved") | [.result, .subject, .task_id, .actor, .metadata.blocks] | @tsv' \
    "$WD/ledger/.context/logs/audit.jsonl"
  assert_output "$(printf 'ok\tDR0\tDR0\tstream-diff\tDV0:empty,DV1:empty')"
}

@test "audit: without --caller the row still lands, keyed unknown on both subject and task_id" {
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L"
  assert_success
  run jq -r 'select(.action == "stream_diff_resolved") | [.subject, .task_id] | @tsv' \
    "$WD/ledger/.context/logs/audit.jsonl"
  assert_output "$(printf 'unknown\tunknown')"
}

@test "usage errors exit 2 with empty stdout" {
  local args
  for args in "--format xml" "--task DR0" "--task DV7" "--tree relative/path" "--bogus"; do
    # shellcheck disable=SC2086
    run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L" $args
    assert_failure 2
    assert_output ""
  done
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --tree "$WD/wt-web" --task DV0
  assert_failure 2
  assert_output ""
}

@test "help: --help prints the header on stdout and exits 0" {
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --help
  assert_success
  assert_output --partial "Source ladder"
}

@test "unresolved input exits 3 with empty stdout: unreadable ledger, zero DV rows" {
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$WD/none.json"
  assert_failure 3
  assert_output ""
  jq '.tasks = {}' "$L" > "$L.tmp" && mv "$L.tmp" "$L"
  run --separate-stderr bash "$PLUGIN_ROOT/$SCRIPT" --state "$L"
  assert_failure 3
  assert_output ""
}

@test "the script names no index-, ref- or worktree-writing git verb" {
  run bash -c "grep -vE '^[[:space:]]*#' '$PLUGIN_ROOT/$SCRIPT' \
    | grep -nE '\\b(git|g) (-c [^ ]+ )*(add|stash|reset|checkout|switch|commit|merge|update-ref|restore)\\b'"
  assert_failure
}
