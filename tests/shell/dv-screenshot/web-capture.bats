#!/usr/bin/env bats
# Behavioural tests for skills/dv-screenshot-capture/scripts/web-capture.sh.
#
# Offline by construction: every Playwright entry point is a recording stub, so
# the network-fetch guard is proven by what the stub was NEVER asked to do
# rather than by an absence of evidence.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SUT="skills/dv-screenshot-capture/scripts/web-capture.sh"
WT="wt-web"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context"
  printf '%s' '{"version":2,"worktask_id":"wt-web","tasks":{"DV0":{"status":"in_progress"},"DV1":{"status":"in_progress"}}}' \
    > "$WD/.context/state.json"
  export WORKSPACE_ROOT="$WD"
  IMAGES="$WD/.context/images/$WT"
  AUDIT_LOG="$WD/.context/logs/audit.jsonl"
}

teardown() {
  _test_helper_cleanup
}

capture() {  # capture [extra args...] — always with the required flags
  run_script_env --cwd "$WD" --stub-path --separate-stderr "$SUT" \
    --worktask-id "$WT" --task-id DV0 --slug hero-shot --url https://example.com/app "$@"
}

# The npx rung is reached only when no `playwright` resolves first, and --stub-path
# keeps the host PATH: a host Playwright would take the capture and fetch the URL.
capture_npx_only() {  # capture_npx_only [extra args...]
  run_script_env --cwd "$WD" --hide playwright --separate-stderr "$SUT" \
    --worktask-id "$WT" --task-id DV0 --slug hero-shot --url https://example.com/app "$@"
}

# A stub that behaves like a working Playwright CLI: the last argv slot is the
# output path, and a real capture is a non-empty PNG on disk.
stub_playwright_writing_png() {
  stub_cmd "$1" --body 'out="${@: -1}"; printf "\211PNG\r\n\032\nfixture" > "$out"; exit 0'
}

# ---------------------------------------------------------------------------
# T1 — argument contract.
# ---------------------------------------------------------------------------
@test "T1: a missing required flag prints usage and exits 1" {
  run_script_env --cwd "$WD" --separate-stderr "$SUT" --task-id DV0 --slug s --url https://example.com
  assert_failure 1
  assert_output ''
  [[ "$stderr" == *'--worktask-id required'* ]]
  [[ "$stderr" == *'usage: web-capture.sh'* ]]
}

@test "T1b: --task-id is required and must match the task-id grammar" {
  run_script_env --cwd "$WD" --separate-stderr "$SUT" --worktask-id "$WT" --slug s --url https://example.com
  assert_failure 1
  [[ "$stderr" == *'--task-id required'* ]]
  run_script_env --cwd "$WD" --separate-stderr "$SUT" --worktask-id "$WT" --task-id dv0 --slug s --url https://example.com
  assert_failure 1
  [[ "$stderr" == *'--task-id must match'* ]]
  [ ! -d "$WD/.context/images" ]
}

@test "T2: a javascript: URL is rejected before any tool is reached" {
  stub_playwright_writing_png playwright
  run_script_env --cwd "$WD" --stub-path --separate-stderr "$SUT" \
    --worktask-id "$WT" --task-id DV0 --slug hero-shot --url 'javascript:alert(1)'
  assert_failure 1
  [[ "$stderr" == *'--url must be an http/https/file URL'* ]]
  # The allow-list must short-circuit ahead of dispatch, not after it.
  assert_equal "$(stub_log --count playwright)" '0'
  [ ! -d "$WD/.context/images" ]
}

# ---------------------------------------------------------------------------
# T3 — the offline guard. The probe `npx --no-install playwright --version` is
# itself offline, so the invariant is that `npx --yes` never runs without the flag.
# ---------------------------------------------------------------------------
@test "T3: without --allow-npx-install npx is never invoked with --yes" {
  # A local package that is not installed: the --no-install probe fails.
  stub_cmd npx --exit 1

  capture_npx_only
  assert_failure 2
  assert_output "path=$IMAGES/dv-DV0-01-hero-shot.png bytes=0 ok=false error=tool_missing"

  # The probe ran (offline, --no-install) …
  assert_equal "$(stub_log --count npx)" '1'
  assert_equal "$(stub_log --argv npx --call 1)" '--no-install
playwright
--version'
  # … and the network-fetching form never did.
  refute_line --partial '--yes'
  [[ "$(stub_log npx)" != *'--yes'* ]]
}

@test "T4: --allow-npx-install is the only thing that unlocks the fetching form" {
  stub_cmd npx --body '
    case "$1" in
      --no-install) exit 1 ;;                 # package genuinely absent
      --yes) exit 0 ;;                        # fetch path — records but produces nothing
    esac'

  capture_npx_only --allow-npx-install
  # No PNG was produced by the stub, so the adapter reports capture_failed (3),
  # not tool_missing (2) — the entry point WAS resolved.
  assert_failure 3
  assert_output "path=$IMAGES/dv-DV0-01-hero-shot.png bytes=0 ok=false error=capture_failed"
  [[ "$(stub_log npx)" == *'--yes playwright screenshot'* ]]
}

@test "T5: no npx and no playwright binary exits 2 tool_missing" {
  run_script_env --cwd "$WD" --hide npx --hide playwright --separate-stderr "$SUT" \
    --worktask-id "$WT" --task-id DV0 --slug hero-shot --url https://example.com/app
  assert_failure 2
  assert_output "path=$IMAGES/dv-DV0-01-hero-shot.png bytes=0 ok=false error=tool_missing"
  [[ "$stderr" == *'Playwright not available'* ]]
  assert_audit_row screenshot_platform_fallback --file "$AUDIT_LOG" \
    --actor web-capture-adapter --result ok \
    --jq '.metadata.reason == "playwright_unavailable" and .metadata.used_adapter == "cli_fallback" and .task_id == "DV0"'
}

# ---------------------------------------------------------------------------
# T6 — dv-<TASK_ID>-NN naming, and that NN never resets.
# ---------------------------------------------------------------------------
@test "T6: a successful capture lands at <ctx>/images/<id>/dv-<TASK_ID>-NN-<slug>.png" {
  stub_playwright_writing_png playwright

  capture
  assert_success
  assert_output "path=$IMAGES/dv-DV0-01-hero-shot.png bytes=15 ok=true error=null"
  [ -s "$IMAGES/dv-DV0-01-hero-shot.png" ]

  assert_audit_row screenshot_captured --file "$AUDIT_LOG" --result ok \
    --jq '.metadata.slug == "hero-shot" and .metadata.bytes == 15
          and .metadata.adapter == "web/playwright"'
}

@test "T7: NN is monotonic across reruns and does not reset" {
  mkdir -p "$IMAGES"
  printf 'x' > "$IMAGES/dv-DV0-01-earlier.png"
  printf 'x' > "$IMAGES/dv-DV0-02-earlier.png"
  stub_playwright_writing_png playwright

  capture
  assert_success
  assert_output --partial "dv-DV0-03-hero-shot.png"

  capture --slug second-shot
  assert_success
  assert_output --partial "dv-DV0-04-second-shot.png"
}

@test "T7b: parallel streams number independently — DV0 and DV1 both start at 01" {
  stub_playwright_writing_png playwright
  capture
  assert_success
  assert_output --partial "dv-DV0-01-hero-shot.png"
  capture --task-id DV1
  assert_success
  assert_output --partial "dv-DV1-01-hero-shot.png"
}

# ---------------------------------------------------------------------------
# T8 — a zero-byte PNG is a failed capture, never a pass.
# ---------------------------------------------------------------------------
@test "T8: an empty output file is classified capture_failed and removed" {
  stub_cmd playwright --body 'out="${@: -1}"; : > "$out"; exit 0'

  capture
  assert_failure 3
  assert_output "path=$IMAGES/dv-DV0-01-hero-shot.png bytes=0 ok=false error=capture_failed"
  [ ! -e "$IMAGES/dv-DV0-01-hero-shot.png" ]
  assert_audit_row screenshot_captured --file "$AUDIT_LOG" --absent
}

@test "T9: a Playwright timeout log is classified playwright_timeout" {
  stub_cmd playwright --body 'printf "page.goto: Timeout 30000ms exceeded.\n" >&2; exit 1'

  capture
  assert_failure 3
  assert_audit_row screenshot_platform_fallback --file "$AUDIT_LOG" \
    --jq '.metadata.reason == "playwright_timeout"'
}

# ---------------------------------------------------------------------------
# T10 — jq absent: the audit row degrades to the hand-built form. Without jq the
# ledger cannot be checked, so this runs ledger-free under an explicit CONTEXT_DIR.
# ---------------------------------------------------------------------------
@test "T10: jq absent falls back to minimal audit JSON without failing the capture" {
  local free="$WD/free/.context"
  mkdir -p "$free"
  stub_playwright_writing_png playwright
  run_script_env --cwd "$WD" --hide jq --unset WORKSPACE_ROOT --env "CONTEXT_DIR=$free" --separate-stderr "$SUT" \
    --worktask-id "$WT" --task-id DV0 --slug hero-shot --url https://example.com/app

  assert_success
  assert_output "path=$free/images/$WT/dv-DV0-01-hero-shot.png bytes=15 ok=true error=null"

  # The fallback branch emits a valid row with no metadata object at all.
  assert_audit_row screenshot_captured --file "$free/logs/audit.jsonl" \
    --actor web-capture-adapter --result ok \
    --jq 'has("metadata") | not'
}

@test "T11: --self-test passes without a browser, a network or a repo" {
  run_script_env --cwd "$WD" --hide npx --hide playwright "$SUT" --self-test
  assert_success
  assert_output --partial 'self-test: 7 passed, 0 failed'
}

# ---------------------------------------------------------------------------
# T12 — root resolution: the ladder, the ledger guard, never cwd.
# ---------------------------------------------------------------------------
@test "T12: no declared root and no ledger exits 1 and creates nothing under cwd" {
  local cwd
  cwd="$(mk_tmpworkdir)"
  stub_playwright_writing_png playwright
  run_script_env --cwd "$cwd" --stub-path --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR \
    --unset CONTEXT_DIR --env "GIT_CEILING_DIRECTORIES=$cwd" --separate-stderr "$SUT" \
    --worktask-id "$WT" --task-id DV0 --slug hero-shot --url https://example.com/app
  assert_failure 1
  [[ "$stderr" == *'no .context resolved'* ]]
  [ ! -e "$cwd/.context" ]
  assert_equal "$(stub_log --count playwright)" '0'
}

@test "T13: a ledger for another worktask, or a task it does not hold, exits 1" {
  stub_playwright_writing_png playwright
  run_script_env --cwd "$WD" --stub-path --separate-stderr "$SUT" \
    --worktask-id other-wt --task-id DV0 --slug hero-shot --url https://example.com/app
  assert_failure 1
  [[ "$stderr" == *'does not match'* ]]
  capture --task-id DV7
  assert_failure 1
  [[ "$stderr" == *'task DV7 is not in'* ]]
  [ ! -d "$WD/.context/images" ]
}

@test "T14: one unattended web stream from an unrelated cwd, stdin closed, then the live gate passes" {
  local proj="$WD/proj" cwd="$WD/elsewhere" png row
  mkdir -p "$proj/.context" "$cwd"
  jq -n '{version: 2, worktask_id: "wt-v2", platform: "web", metadata: {requires_screenshots: true},
          tasks: {DV0: {status: "in_progress", metadata: {stage: "DV", agent: "system-developer:bash-developer", platform: "web"}}},
          facts: {dispatched_agents: []}}' > "$proj/.context/state.json"
  stub_playwright_writing_png playwright

  run bash -c 'cd "$1" && shift && exec "$@" <&-' _ "$cwd" \
    env PATH="$STUB_PATH" WORKSPACE_ROOT="$proj" GIT_CEILING_DIRECTORIES="$WD" \
    bash "$PLUGIN_ROOT/$SUT" --worktask-id wt-v2 --task-id DV0 --slug home --url https://example.com/
  assert_success
  png="$proj/.context/images/wt-v2/dv-DV0-01-home.png"
  assert_output "path=$png bytes=15 ok=true error=null"
  [ ! -e "$cwd/.context" ]

  row="| 01 | home | ${png##*/} | 15 | web | web/playwright | home page | 2026-01-01T00:00:00Z | — |"
  printf '# Screenshots — wt-v2 / DV0\n\n| # | Slug | Path | Bytes | Platform | Adapter | Caption | Captured | Design Ref |\n|---|------|------|-------|----------|---------|---------|----------|------------|\n%s\n' \
    "$row" > "$proj/.context/images/wt-v2/screenshots-DV0.md"

  run bash "$PLUGIN_ROOT/hooks/dv-screenshot-gate.sh" --check DV0 --state "$proj/.context/state.json"
  assert_success
  assert_output --partial 'class=captured'

  run_script_env --cwd "$cwd" --env "WORKSPACE_ROOT=$proj" \
    --stdin-string '{"agent_type":"system-developer:bash-developer","agent_id":"agt_web","session_id":"s"}' \
    hooks/dv-screenshot-gate.sh
  assert_success
  assert_output ''
  assert_audit_row screenshot_gate_pass --file "$proj/.context/logs/audit.jsonl" \
    --meta task_id=DV0 --meta class=captured
}
