#!/usr/bin/env bats
# Tests for hooks/precompact-checkpoint.sh (DV0c) — PreCompact hook that copies
# state.json to a timestamped checkpoint and logs a precompact_checkpoint row.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="hooks/precompact-checkpoint.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context"
}

@test "happy: copies state.json to a checkpoint and logs result=ok" {
  printf '%s' '{"run_index":0,"tasks":{}}' > "$WD/.context/state.json"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  # A timestamped checkpoint file must now exist alongside state.json.
  run bash -c "ls $WD/.context/state.checkpoint-*.json"
  assert_success
  run jq -e '.action == "precompact_checkpoint" and .result == "ok" and .metadata.run_index == "0"' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "edge: absent state.json is a silent no-op — no logs dir, no row, no checkpoint" {
  # Pinned outside any git repo: with no ledger declared, the git ranks would
  # otherwise answer whatever checkout the suite happens to run from.
  run_script_env --cwd "$WD" --unset WORKSPACE_ROOT --env "CLAUDE_PROJECT_DIR=$WD" \
    --env "GIT_CEILING_DIRECTORIES=$WD" "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ ! -e "$WD/.context/logs" ]
  run bash -c "ls $WD/.context/state.checkpoint-*.json 2>/dev/null"
  assert_failure
}

@test "edge: checkpoint records pointers to planning/development artifacts" {
  printf '%s' '{"run_index":2,"tasks":{}}' > "$WD/.context/state.json"
  printf '# plan\n' > "$WD/.context/planning-2.md"
  printf '# dev\n' > "$WD/.context/development-2.md"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run jq -e '(.metadata.artifacts | length) == 2 and .metadata.run_index == "2"' \
    "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "contract: --self-test passes (counted summary)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "self-test OK"
  assert_output --regexp 'precompact-checkpoint: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
}

# --- checkpoint fidelity ------------------------------------------------------
# `ls state.checkpoint-*.json` only proved a file appeared. A hook that wrote an
# empty file, a truncated copy, or the wrong ledger satisfied it — which is the
# one failure mode that matters, since the checkpoint exists to be restored from.

@test "fidelity: the checkpoint is byte-for-byte the ledger it snapshotted" {
  local state="$WD/.context/state.json"
  # A non-trivial ledger: nested stages, arrays, unicode and a float.
  cat > "$state" <<'JSON'
{"version":1,"worktask_id":"wt-fidelity","run_index":3,"platform":"systems",
 "tasks":{"PL0":{"status":"complete","verdict":"ok"},
           "DV0":{"status":"in_progress","progress":{"completed_batches":["B1","B2"],"ratio":0.75}}},
 "facts":{"files_modified":["a.md","b/c.md"],"note":"ünïcode — em dash"},
 "handoffs":{"PL→DV":{"summary":"go"}}}
JSON
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success

  local ckpt
  ckpt="$(ls "$WD/.context/"state.checkpoint-*.json)"
  [ -n "$ckpt" ]
  [ -s "$ckpt" ]
  # Semantic equality, key order independent.
  run bash -c 'diff <(jq -S . "$1") <(jq -S . "$2")' _ "$state" "$ckpt"
  assert_success
  assert_output ""
  # And the nested content really survived, not just a valid-JSON stub.
  run jq -r '.tasks.DV0.progress.completed_batches | join(",")' "$ckpt"
  assert_output "B1,B2"
  run jq -r '.facts.note' "$ckpt"
  assert_output "ünïcode — em dash"
}

@test "fidelity: the original ledger is left untouched by the checkpoint" {
  local state="$WD/.context/state.json"
  printf '%s' '{"run_index":0,"tasks":{"DV0":{"status":"in_progress"}}}' > "$state"
  local before
  before="$(cat "$state")"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  run cat "$state"
  assert_output "$before"
}

@test "fidelity: a second checkpoint does not clobber the first" {
  local state="$WD/.context/state.json"
  printf '%s' '{"run_index":0,"tasks":{},"facts":{"seq":1}}' > "$state"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  # Timestamped names are second-resolution; make the second one distinct.
  sleep 1
  printf '%s' '{"run_index":0,"tasks":{},"facts":{"seq":2}}' > "$state"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success

  run bash -c 'ls "$1"/.context/state.checkpoint-*.json | wc -l | tr -d " "' _ "$WD"
  assert_output "2"
  # Each snapshot kept its own generation of the ledger.
  run bash -c 'for f in "$1"/.context/state.checkpoint-*.json; do jq -r ".facts.seq" "$f"; done | sort | tr "\n" ","' _ "$WD"
  assert_output "1,2,"
}

@test "SR: a symlinked audit.jsonl is refused, never written through" {
  printf '%s' '{"run_index":0,"tasks":{}}' > "$WD/.context/state.json"
  mkdir -p "$WD/.context/logs" "$WD/target-dir"
  ln -s "$WD/target-dir/escaped.txt" "$WD/.context/logs/audit.jsonl"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  # The checkpoint copy — the hook's actual job — must still have landed.
  run bash -c "ls $WD/.context/state.checkpoint-*.json"
  assert_success
  [ ! -e "$WD/target-dir/escaped.txt" ]
}

@test "SR: the no-state skip row is refused through a symlink too" {
  mkdir -p "$WD/.context/logs" "$WD/target-dir"
  ln -s "$WD/target-dir/escaped.txt" "$WD/.context/logs/audit.jsonl"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ ! -e "$WD/target-dir/escaped.txt" ]
}

# --- failed copy ---------------------------------------------------------------
# The copy was bare under `set -eu` and the success row was written after it, so
# the one state a resume must not miss — "the checkpoint you are looking for was
# never written" — aborted the hook before anything recorded it.

@test "guard: an unwritable context dir records result=error and still exits 0" {
  printf '%s' '{"run_index":0,"tasks":{}}' > "$WD/.context/state.json"
  mkdir -p "$WD/.context/logs"
  # logs/ stays writable, so the audit row can still land while the copy cannot.
  chmod a-w "$WD/.context"
  run env CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT"
  local status_seen="$status"
  chmod u+w "$WD/.context"
  [ "$status_seen" -eq 0 ] || fail "hook exited $status_seen; the contract is always 0"

  run jq -e '.action == "precompact_checkpoint" and .result == "error"
             and (.metadata.error | length) > 0' "$WD/.context/logs/audit.jsonl"
  assert_success
  run bash -c "ls $WD/.context/state.checkpoint-*.json 2>/dev/null"
  assert_failure
}

# --- SR P3-3: the checkpoint destination ---------------------------------------
# cp -p follows a destination symlink, so the one unguarded path in a file whose two
# audit appends are both symlink-guarded was the copy itself. The name is a
# 1-second-granularity timestamp, so the destination is predictable enough to pre-place.

@test "SR: a symlinked checkpoint destination is refused and recorded, never written through" {
  printf '%s' '{"run_index":0,"tasks":{}}' > "$WD/.context/state.json"
  mkdir -p "$WD/.context/logs" "$WD/target-dir" "$WD/binshim"
  # Pin only the checkpoint timestamp so the destination is knowable; every other
  # `date` call passes through.
  cat > "$WD/binshim/date" <<'SHIM'
#!/usr/bin/env bash
[ "${2:-}" = "+%Y%m%d-%H%M%S" ] && { printf '19700101-000000\n'; exit 0; }
exec /bin/date "$@"
SHIM
  chmod +x "$WD/binshim/date"
  ln -s "$WD/target-dir/escaped.json" "$WD/.context/state.checkpoint-19700101-000000.json"

  run env PATH="$WD/binshim:$PATH" CLAUDE_PROJECT_DIR="$WD" bash "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ ! -e "$WD/target-dir/escaped.json" ] || fail "the copy was written through the symlink"
  # Refused, not silently skipped: a resume must never have to infer a missing checkpoint.
  run jq -e '.action == "precompact_checkpoint" and .result == "error"
             and (.metadata.error | test("symlink"))' "$WD/.context/logs/audit.jsonl"
  assert_success
}

@test "unresolved root exits 0 and creates no .context under cwd" {
  local cwd
  cwd="$(mk_tmpworkdir)"
  run_script_env --cwd "$cwd" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR --unset CONTEXT_DIR \
    --env "GIT_CEILING_DIRECTORIES=$cwd" "$PLUGIN_ROOT/$SCRIPT"
  assert_success
  [ ! -e "$cwd/.context" ]
}
