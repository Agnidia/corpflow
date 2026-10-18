#!/usr/bin/env bats
# tests/shell/dv-screenshot/cli-fallback.bats
# Target: skills/dv-screenshot-capture/scripts/cli-fallback.sh
# Covers: argument errors → exit 1, floor → exit 2 (tool_missing) / exit 3 (render_failed),
#         the tool_missing manifest row, root resolution and the ledger guard.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="skills/dv-screenshot-capture/scripts/cli-fallback.sh"
VALIDATOR="skills/worktask/scripts/attach-visual-evidence.sh"

setup() {
  WD="$(mk_tmpworkdir)"
  mkdir -p "$WD/.context/logs"
  printf '%s' '{"version":2,"worktask_id":"wt-test","tasks":{"DV0":{"status":"in_progress"}}}' \
    > "$WD/.context/state.json"
  MF="$WD/.context/images/wt-test/screenshots-DV0.md"
}

# Image-tool cases run on the allowlist farm, never on /usr/bin:/bin: a distro
# ImageMagick installs /usr/bin/convert, which would turn "absent" into "present".
floor() { # [extra args] — no image tool on PATH, $WD is not a git repository
  run_script_env --cwd "$WD" --hide silicon --hide magick --hide convert \
    --env "WORKSPACE_ROOT=$WD" "$SCRIPT" \
    --worktask-id wt-test --task-id DV0 --slug my-feature --platform backend --run-index 0 "$@"
}

in_repo() { # makes $WD a git repository with one commit, so the render steps run
  git -C "$WD" init -q
  git -C "$WD" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
}

render() { # [extra args] — farm PATH plus whatever stub_cmd installed
  run_script_env --cwd "$WD" --hide silicon --hide magick --hide convert \
    --env "WORKSPACE_ROOT=$WD" "$SCRIPT" \
    --worktask-id wt-test --task-id DV0 --slug my-feature --run-index 0 --base-ref HEAD "$@"
}

# An ImageMagick built without fontconfig: `-list font` is empty and a font NAME
# fails to load, while a font FILE (or no -font at all) renders.
stub_magick_without_font_registry() {
  stub_cmd magick --body '
    if [ "$1" = -list ]; then exit 0; fi
    prev=""
    for a in "$@"; do
      if [ "$prev" = -font ] && [ ! -r "$a" ]; then echo "magick: unable to read font $a" >&2; exit 1; fi
      prev="$a"
    done
    printf "\211PNG\r\n\032\nx" > "${@: -1}"'
}

# ---------------------------------------------------------------------------

@test "arg error: missing --worktask-id exits 1" {
  run bash -c "cd '$WD' && bash '$PLUGIN_ROOT/$SCRIPT' --task-id DV0 --slug my-feature"
  [ "$status" -eq 1 ]
}

@test "arg error: missing or malformed --task-id exits 1" {
  run bash -c "cd '$WD' && bash '$PLUGIN_ROOT/$SCRIPT' --worktask-id wt-test --slug my-feature"
  [ "$status" -eq 1 ]
  run bash -c "cd '$WD' && bash '$PLUGIN_ROOT/$SCRIPT' --worktask-id wt-test --task-id DV-0 --slug my-feature"
  [ "$status" -eq 1 ]
}

@test "arg error: invalid slug (uppercase) exits 1" {
  run bash -c "cd '$WD' && bash '$PLUGIN_ROOT/$SCRIPT' --worktask-id wt-test --task-id DV0 --slug MyFeature"
  [ "$status" -eq 1 ]
}

@test "arg error: invalid slug (>40 chars) exits 1" {
  LONG_SLUG="a$(printf '%0.sa' {1..40})"  # 41 chars
  run bash -c "cd '$WD' && bash '$PLUGIN_ROOT/$SCRIPT' --worktask-id wt-test --task-id DV0 --slug '$LONG_SLUG'"
  [ "$status" -eq 1 ]
}

@test "arg error: a platform carrying a pipe would break the manifest row and exits 1" {
  run bash -c "cd '$WD' && WORKSPACE_ROOT='$WD' bash '$PLUGIN_ROOT/$SCRIPT' --worktask-id wt-test --task-id DV0 --slug my-feature --platform 'a|b'"
  [ "$status" -eq 1 ]
  [ ! -e "$WD/.context/images" ]
}

@test "floor: no image tool and no repo -> exit 2, error=tool_missing, no .txt written" {
  floor
  [ "$status" -eq 2 ]
  [[ "$output" == *"ok=false"* ]]
  [[ "$output" == *"error=tool_missing"* ]]
  [ ! -e "$WD/.context/images/wt-test/dv-DV0-01-my-feature.txt" ]
  [ ! -e "$WD/.context/images/wt-test/dv-DV0-01-my-feature.png" ]
}

@test "floor: every tool absent writes one validator-legal tool_missing row, upserted by slug" {
  floor
  [ "$status" -eq 2 ]
  [ -f "$MF" ]
  run grep -c '^| 01 | my-feature | — | 0 | backend | cli_fallback | tool_missing: silicon(absent), magick(absent), convert(absent) |' "$MF"
  assert_output "1"
  run bash "$PLUGIN_ROOT/$VALIDATOR" --validate-manifest "$MF" --task-id DV0
  assert_failure 4
  assert_output 'tool_missing_only tools=silicon,magick,convert'

  floor
  [ "$status" -eq 2 ]
  run grep -c 'tool_missing:' "$MF"
  assert_output "1"
  run find "$WD/.context/images/wt-test" -name '.screenshots-*'
  assert_output ''
}

@test "floor: a present tool that fails to render -> exit 3, render_failed, no row" {
  stub_cmd silicon --exit 1
  in_repo
  render
  [ "$status" -eq 3 ]
  [[ "$output" == *"error=render_failed"* ]]
  [ ! -e "$WD/.context/images/wt-test/dv-DV0-01-my-feature.txt" ]
  [ ! -e "$MF" ]
}

@test "floor: a present tool outside a git repository exits 2 but records no tool_missing row" {
  stub_cmd silicon --exit 0
  run_script_env --cwd "$WD" --hide magick --hide convert \
    --env "WORKSPACE_ROOT=$WD" --env "GIT_CEILING_DIRECTORIES=$WD" "$SCRIPT" \
    --worktask-id wt-test --task-id DV0 --slug my-feature
  [ "$status" -eq 2 ]
  [[ "$output" == *"error=tool_missing"* ]]
  [ ! -e "$MF" ]
}

@test "magick: no font file and an empty registry -> no -font at all, render still succeeds" {
  stub_magick_without_font_registry
  in_repo
  export CLI_FALLBACK_FONT_FILES="$WD/absent.ttf"
  render
  assert_success
  [[ "$output" == *"ok=true error=null"* ]]
  [ -s "$WD/.context/images/wt-test/dv-DV0-01-my-feature.png" ]
  [[ "$(stub_log magick)" != *'-font '* ]]
}

# A registry hit does not prove the glyph file is installed (IM6 lists Courier
# without gsfonts), so a readable font file outranks the registry name.
@test "magick: a readable font file is preferred over a registry that lists Courier" {
  stub_cmd magick --body '
    if [ "$1" = -list ]; then printf "  Font: Courier\n    family: Courier\n"; exit 0; fi
    printf "\211PNG\r\n\032\nx" > "${@: -1}"'
  printf 'font' > "$WD/mono.ttf"
  in_repo
  export CLI_FALLBACK_FONT_FILES="$WD/absent.ttf:$WD/mono.ttf"
  render
  assert_success
  [[ "$(stub_log magick)" == *"-font $WD/mono.ttf "* ]]
  [[ "$(stub_log magick)" != *'-font Courier '* ]]
}

@test "magick: with no readable font file, a registry that lists Courier is asked for Courier" {
  stub_cmd magick --body '
    if [ "$1" = -list ]; then printf "  Font: Courier\n    family: Courier\n"; exit 0; fi
    printf "\211PNG\r\n\032\nx" > "${@: -1}"'
  in_repo
  export CLI_FALLBACK_FONT_FILES="$WD/absent.ttf"
  render
  assert_success
  [[ "$(stub_log magick)" == *'-font Courier '* ]]
}

@test "root: no declared root exits 1 and creates no .context under cwd" {
  local cwd
  cwd="$(mk_tmpworkdir)"
  run_script_env --cwd "$cwd" --unset WORKSPACE_ROOT --unset CLAUDE_PROJECT_DIR --unset CONTEXT_DIR \
    --env "GIT_CEILING_DIRECTORIES=$cwd" "$SCRIPT" --worktask-id wt-test --task-id DV0 --slug my-feature
  assert_failure 1
  [ ! -e "$cwd/.context" ]
}

@test "root: a ledger for another worktask exits 1 without writing" {
  run bash -c "cd '$WD' && PATH='/usr/bin:/bin' WORKSPACE_ROOT='$WD' bash '$PLUGIN_ROOT/$SCRIPT' \
    --worktask-id other --task-id DV0 --slug my-feature"
  [ "$status" -eq 1 ]
  [ ! -e "$WD/.context/images" ]
}

@test "audit row construction is guarded: a jq failure never aborts the capture" {
  # The two screenshot_captured rows tail their jq with a fallback and their audit
  # call with `|| true`, matching the sibling capture adapters.
  run grep -c "2> /dev/null || printf '{}'" "$PLUGIN_ROOT/$SCRIPT"
  [ "$output" -ge 2 ]
  run grep -c ')" 2> /dev/null || true' "$PLUGIN_ROOT/$SCRIPT"
  [ "$output" -ge 2 ]
}

@test "self-test smoke: --self-test exits 0 with pass count (NON-counting)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "0 failed"
}
