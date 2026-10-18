#!/usr/bin/env bats
# Contract tests for skills/worktask/scripts/adhoc-visual-evidence.sh.
# Contracts (from header):
#   - --emit pr prints a "## Visual evidence" block, or NOTHING; exit 0 always
#   - skip-by-default: no path-class hit / no git / no base ref => empty stdout
#   - a .context/state.json carrying a worktask_id is refused (FN owns attachment)
#   - failure is never blocking: no operational path exits non-zero
#   - the manifest it writes satisfies attach-visual-evidence.sh --validate-manifest
#   - --detect emits {"visual_surface":bool,"files":N,"reason":"..."}
#   - the path-class vocabulary has ONE owner: detect-ui-change.sh --path-classes
#   - --self-test => "fail=0", exit 0
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/worktask/scripts/adhoc-visual-evidence.sh"
DETECTOR="skills/worktask/scripts/detect-ui-change.sh"
ATTACHER="skills/worktask/scripts/attach-visual-evidence.sh"

# A repo shaped like a real PR: base commit on master, work on a feature branch.
mk_pr_repo() { # $1=path-to-add
  local d; d="$(mk_tmpworkdir)"
  git -C "$d" init -q -b master
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  printf 'a\n' > "$d/README.md"
  git -C "$d" add -A && git -C "$d" commit -qm base
  git -C "$d" checkout -q -b feature
  mkdir -p "$d/$(dirname "$1")"
  printf 'x\n' > "$d/$1"
  git -C "$d" add -A && git -C "$d" commit -qm work
  printf '%s' "$d"
}

# cli-fallback's floor no longer writes a .txt placeholder, so a host with no image tool
# produces NO capture at all. Seeding the capture on disk (the script's existing-capture
# path, the same idiom its own t7 uses) keeps these arms deterministic without making
# silicon/ImageMagick a suite prerequisite.
seed_capture() { # $1=repo dir
  mkdir -p "$1/.context/images/adhoc-feature"
  printf '\x89PNG\r\n\x1a\n' > "$1/.context/images/adhoc-feature/dv-AD0-01-pr-diff.png"
}

@test "happy: a UI-touching diff emits a Visual evidence block" {
  local d; d="$(mk_pr_repo Views/app.css)"
  seed_capture "$d"
  run env WORKSPACE_ROOT="$d" BASE_REF=master ADHOC_ID=adhoc-feature \
    ASSET_HOST_MODE=none DRY_RUN=1 bash "$PLUGIN_ROOT/$SCRIPT" --emit pr
  assert_success
  assert_line --index 0 "## Visual evidence"
}

@test "floor: no image tool means no capture and no manifest row naming a missing file" {
  # The un-migrated consumer read cli-fallback's exit 2 as a successful capture, so the
  # manifest named a .png the new floor never wrote. Nothing may claim a file that is absent.
  local d; d="$(mk_pr_repo Views/app.css)"
  # Allowlist farm, not /usr/bin:/bin, where a distro ImageMagick installs convert.
  run_script_env --hide silicon --hide magick --hide convert \
    --env "WORKSPACE_ROOT=$d" --env BASE_REF=master --env ASSET_HOST_MODE=none --env DRY_RUN=1 \
    "$SCRIPT" --emit pr
  assert_success
  local mf; mf="$(find "$d/.context/images" -name screenshots-AD0.md 2>/dev/null | head -1)"
  if [ -n "$mf" ]; then
    local row
    while IFS='|' read -r _ _ _ row _; do
      row="$(printf '%s' "$row" | tr -d ' ')"
      case "$row" in
        dv-*) [ -e "$(dirname "$mf")/$row" ] || fail "manifest names a missing file: $row" ;;
      esac
    done < "$mf"
  fi
  refute_output --partial ".txt"
}

@test "happy: a docs-only diff emits nothing and audits no_ui_surface" {
  local d; d="$(mk_pr_repo docs/guide.md)"
  run env WORKSPACE_ROOT="$d" BASE_REF=master bash "$PLUGIN_ROOT/$SCRIPT" --emit pr
  assert_success
  assert_output ""
  run jq -e 'select(.action=="adhoc_visual_evidence") | .metadata.reason' \
    "$d/.context/logs/audit.jsonl"
  assert_output '"no_ui_surface"'
}

@test "edge: a worktask tree is refused so FN stays the only attacher" {
  local d; d="$(mk_pr_repo Views/app.css)"
  mkdir -p "$d/.context"
  printf '{"version":1,"worktask_id":"wid-real","run_index":0}' > "$d/.context/state.json"
  run env WORKSPACE_ROOT="$d" BASE_REF=master bash "$PLUGIN_ROOT/$SCRIPT" --emit pr
  assert_success
  assert_output ""
  run jq -e 'select(.action=="adhoc_visual_evidence") | .metadata.reason' \
    "$d/.context/logs/audit.jsonl"
  assert_output '"worktask_path"'
}

@test "edge: ADHOC_SKIP=1 suppresses a run the heuristic gets wrong" {
  local d; d="$(mk_pr_repo Views/app.css)"
  run env WORKSPACE_ROOT="$d" BASE_REF=master ADHOC_SKIP=1 \
    bash "$PLUGIN_ROOT/$SCRIPT" --emit pr
  assert_success
  assert_output ""
}

@test "edge: the emitted manifest satisfies the attacher's own schema check" {
  local d; d="$(mk_pr_repo Views/app.css)"
  seed_capture "$d"
  run env WORKSPACE_ROOT="$d" BASE_REF=master ADHOC_ID=adhoc-feature \
    ASSET_HOST_MODE=none DRY_RUN=1 bash "$PLUGIN_ROOT/$SCRIPT" --emit pr
  assert_success
  local mf; mf="$(find "$d/.context/images" -name screenshots-AD0.md | head -1)"
  [ -n "$mf" ]
  run bash "$PLUGIN_ROOT/$ATTACHER" --validate-manifest "$mf"
  assert_success
  run bash "$PLUGIN_ROOT/$ATTACHER" --validate-manifest "$mf" --task-id AD0
  assert_success
}

@test "edge: the ad-hoc stream is AD0 — per-task manifest and dv-AD0-NN capture name" {
  local d; d="$(mk_pr_repo Views/app.css)"
  seed_capture "$d"
  run env WORKSPACE_ROOT="$d" BASE_REF=master ADHOC_ID=adhoc-feature \
    ASSET_HOST_MODE=none DRY_RUN=1 bash "$PLUGIN_ROOT/$SCRIPT" --emit pr
  assert_success
  [ -f "$d/.context/images/adhoc-feature/screenshots-AD0.md" ]
  [ ! -e "$d/.context/images/adhoc-feature/screenshots.md" ]
  run grep -c '^| 01 | pr-diff | dv-AD0-01-pr-diff.png |' "$d/.context/images/adhoc-feature/screenshots-AD0.md"
  assert_output "1"
}

@test "edge: rerunning replays the first emission instead of stacking captures" {
  local d; d="$(mk_pr_repo Views/app.css)"
  seed_capture "$d"
  run env WORKSPACE_ROOT="$d" BASE_REF=master ADHOC_ID=adhoc-feature \
    ASSET_HOST_MODE=none DRY_RUN=1 bash "$PLUGIN_ROOT/$SCRIPT" --emit pr
  assert_success
  local first="$output"
  run env WORKSPACE_ROOT="$d" BASE_REF=master ADHOC_ID=adhoc-feature \
    ASSET_HOST_MODE=none DRY_RUN=1 bash "$PLUGIN_ROOT/$SCRIPT" --emit pr
  assert_success
  assert_output "$first"
  run bash -c "find '$d/.context/images' -type f -name 'dv-*' | wc -l | tr -d ' '"
  assert_output "1"
}

@test "failure: outside a git repo --emit is silent and still exits 0" {
  local d; d="$(mk_tmpworkdir)"
  run env WORKSPACE_ROOT="$d" bash "$PLUGIN_ROOT/$SCRIPT" --emit pr
  assert_success
  assert_output ""
}

@test "failure: an unresolvable base ref never blocks the PR" {
  local d; d="$(mk_pr_repo Views/app.css)"
  git -C "$d" branch -D master >/dev/null 2>&1 || true
  run env WORKSPACE_ROOT="$d" BASE_REF=no-such-ref bash "$PLUGIN_ROOT/$SCRIPT" --emit pr
  assert_success
  assert_output ""
}

@test "happy: --detect reports the visual surface as JSON" {
  local d; d="$(mk_pr_repo Views/app.css)"
  run env WORKSPACE_ROOT="$d" BASE_REF=master bash "$PLUGIN_ROOT/$SCRIPT" --detect
  assert_success
  local json="$output"
  run jq -r '.visual_surface' <<<"$json"
  assert_output "true"
  run jq -r '.files' <<<"$json"
  assert_output "1"
}

@test "edge: the path-class vocabulary is read from detect-ui-change, not copied" {
  run bash "$PLUGIN_ROOT/$DETECTOR" --path-classes
  assert_success
  refute_output ""
  # A literal second copy of the regex in the ad-hoc script would let the two
  # detectors disagree about what counts as UI.
  run grep -cF "$output" "$PLUGIN_ROOT/$SCRIPT"
  assert_output "0"
}

@test "failure: a bad mode is a caller error (exit 1), not a silent skip" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --emit issue
  assert_failure
}

@test "self-test: built-in fixtures pass" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "fail=0"
  assert_line "adhoc-visual-evidence: t2-ui-emits-block PASS"
  assert_line "adhoc-visual-evidence: t2b-no-tool-manifests-no-ghost-row PASS"
}

@test "self-test: failing host image tools on PATH do not decide or fail an arm" {
  local d; d="$(mk_tmpworkdir)"
  local t
  for t in silicon magick convert; do
    printf '#!/bin/sh\nexit 1\n' > "$d/$t"; chmod +x "$d/$t"
  done
  run env PATH="$d:$PATH" bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "fail=0"
}

# A caller that sources the harness the way adhoc-visual-evidence.sh does, with $0 set to
# the script so the self-test's own `bash "$self"` runs resolve. $2 is the caller's trap
# setup; it prints whether its traps survive run_self_tests unchanged.
mk_selftest_caller() { # $1=dir $2=caller trap setup (may be empty)
  cat > "$1/caller.sh" <<EOF
$2
ATTACHER="$PLUGIN_ROOT/$ATTACHER"
. "$PLUGIN_ROOT/skills/worktask/scripts/adhoc-visual-evidence-selftest.sh"
before=\$(trap -p EXIT INT TERM)
run_self_tests >/dev/null
after=\$(trap -p EXIT INT TERM)
[ "\$before" = "\$after" ] && echo "traps-restored" || echo "traps-changed<\$after>"
EOF
}

# The mkdir of the PNG stub dir runs inside the override window, so a TERM sent there
# exits the shell mid-test.
mk_midtest_killer() { # $1=dir
  mkdir -p "$1/bin"
  printf '%s\n' '#!/bin/sh' \
    'case "$*" in */png-tool) kill -TERM "$ST_KILL_PID" ;; esac' \
    'exec /bin/mkdir "$@"' > "$1/bin/mkdir"
  chmod +x "$1/bin/mkdir"
}

@test "self-test: a caller's EXIT and INT traps come back exactly" {
  local d; d="$(mk_tmpworkdir)"
  mk_selftest_caller "$d" "trap 'echo caller-exit' EXIT; trap 'echo caller-int' INT"
  run bash -c '. "$1"' "$PLUGIN_ROOT/$SCRIPT" "$d/caller.sh"
  assert_success
  assert_line "traps-restored"
  assert_line "caller-exit"
}

@test "self-test: a caller with no traps is left with none" {
  local d; d="$(mk_tmpworkdir)"
  mk_selftest_caller "$d" ""
  run bash -c '. "$1"; trap -p EXIT INT TERM' "$PLUGIN_ROOT/$SCRIPT" "$d/caller.sh"
  assert_success
  assert_output "traps-restored"
}

@test "self-test: an exit mid-test cleans up and still runs the caller's EXIT trap with the real status" {
  local d; d="$(mk_tmpworkdir)"
  mkdir -p "$d/tmp"; mk_midtest_killer "$d"
  mk_selftest_caller "$d" "set -e; trap 'echo \"caller-exit rc=\$?\"' EXIT"
  run env PATH="$d/bin:$PATH" TMPDIR="$d/tmp" bash -c 'ST_KILL_PID=$$; export ST_KILL_PID; . "$1"' \
    "$PLUGIN_ROOT/$SCRIPT" "$d/caller.sh"
  assert_equal "$status" 143
  assert_output "caller-exit rc=143"
  [ -z "$(find "$d/tmp" -name png-tool)" ]
}

@test "self-test: a failed scratch removal under set -e still runs the caller's EXIT trap" {
  local d; d="$(mk_tmpworkdir)"
  mkdir -p "$d/tmp"; mk_midtest_killer "$d"
  # Fails only on the self-test's scratch dir (the one holding png-tool); t1's repos and the
  # farm cleanup still remove normally, so set -e does not end the run before the kill.
  printf '%s\n' '#!/bin/sh' \
    'for a in "$@"; do [ -d "$a/png-tool" ] && exit 1; done' \
    'exec /bin/rm "$@"' > "$d/bin/rm"
  chmod +x "$d/bin/rm"
  mk_selftest_caller "$d" "set -e; trap 'echo \"caller-exit rc=\$?\"' EXIT"
  run env PATH="$d/bin:$PATH" TMPDIR="$d/tmp" bash -c 'ST_KILL_PID=$$; export ST_KILL_PID; . "$1"' \
    "$PLUGIN_ROOT/$SCRIPT" "$d/caller.sh"
  assert_equal "$status" 143
  assert_output "caller-exit rc=143"
}

@test "self-test: an exit mid-test with no caller trap still cleans up" {
  local d; d="$(mk_tmpworkdir)"
  mkdir -p "$d/tmp"; mk_midtest_killer "$d"
  mk_selftest_caller "$d" ""
  run env PATH="$d/bin:$PATH" TMPDIR="$d/tmp" bash -c 'ST_KILL_PID=$$; export ST_KILL_PID; . "$1"' \
    "$PLUGIN_ROOT/$SCRIPT" "$d/caller.sh"
  assert_equal "$status" 143
  assert_output ""
  [ -z "$(find "$d/tmp" -name png-tool)" ]
}

# Companion to the attach-visual-evidence arm of the same name: nothing pinned the
# symlink refusal for any worktask emitter, only for the hook-side one.
@test "SR: a symlinked audit.jsonl is refused, never written through" {
  local d; d="$(mk_tmpworkdir)"
  mkdir -p "$d/.context/logs" "$d/target-dir"
  ln -s "$d/target-dir/escaped.txt" "$d/.context/logs/audit.jsonl"
  run env WORKSPACE_ROOT="$d" ADHOC_SKIP=1 bash "$PLUGIN_ROOT/$SCRIPT" --emit pr
  assert_success
  [ ! -e "$d/target-dir/escaped.txt" ]
}
