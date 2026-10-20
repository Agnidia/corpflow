#!/usr/bin/env bats
# Tests for hooks/anchor-preflight.sh — the PreToolUse Edit H2 deny and the PostToolUse
# lint, H2 and frontmatter feedback for canonical .context/<stage>-N.md artifacts.
load "${BATS_TEST_DIRNAME}/../../lib/test_helper.bash"

SCRIPT="hooks/anchor-preflight.sh"

setup() {
  WD="$(mk_tmpworkdir)"
}

@test "happy: non-artifact write path is a no-op (exit 0, no lint invoked)" {
  # SKILL.md is not a worktask artifact -> the gating regex misses -> exit 0.
  run bash "$PLUGIN_ROOT/$SCRIPT" \
    < "${FIXTURES}/hooks/anchor-preflight-nonartifact.payload.json"
  assert_success
  [ -z "$output" ]
}

@test "edge: artifact-shaped path that does not exist on disk is a no-op" {
  # file_path matches the regex but the file is absent -> exit 0 (no lint).
  run bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< '{"tool_input":{"file_path":".context/development-99.md"}}'
  assert_success
}

@test "edge: empty stdin and no env path -> no-op exit 0" {
  run bash "$PLUGIN_ROOT/$SCRIPT" < /dev/null
  assert_success
}

@test "failure: a real artifact missing its H2 anchor surfaces a non-zero lint" {
  # Build a .context/<stage>-N.md artifact with NO H2 anchor; the gate must
  # delegate to cache-lint --anchor-lint, which fails for the missing anchor.
  mkdir -p "$WD/.context"
  cat > "$WD/.context/development-0.md" <<'EOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "no anchor present"
---

# Development

Body without the required `## DV Handoff` H2 anchor.
EOF
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "{\"tool_input\":{\"file_path\":\"$WD/.context/development-0.md\"}}"
  assert_failure
}

@test "failure: env unset -> self-located plugin root still lints (missing anchor)" {
  # Provider-agnostic fallback: with CLAUDE_PLUGIN_ROOT unset the hook derives
  # the plugin root from its own path and must still surface the lint failure
  # (pre-fix behavior was a silent exit 0).
  mkdir -p "$WD/.context"
  cat > "$WD/.context/development-0.md" <<'EOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "no anchor present"
---

# Development

Body without the required `## DV Handoff` H2 anchors.
EOF
  run env -u CLAUDE_PLUGIN_ROOT bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "{\"tool_input\":{\"file_path\":\"$WD/.context/development-0.md\"}}"
  assert_failure
}

@test "happy: env unset -> compliant artifact passes via self-located root" {
  # The self-location block must not trip `set -eu`, and a DV artifact carrying
  # the full anchor allow-list lints clean.
  mkdir -p "$WD/.context"
  cat > "$WD/.context/development-1.md" <<'EOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "all anchors present"
---

# Development

## files-changed

table

## tests-added

list

## deviations

none

## follow-ups

none

## elicitation-sweep

nothing to elicit
EOF
  run env -u CLAUDE_PLUGIN_ROOT bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "{\"tool_input\":{\"file_path\":\"$WD/.context/development-1.md\"}}"
  assert_success
}

@test "contract: explicit env override wins -> bogus root degrades to no-op exit 0" {
  # Strict env-first semantics: a set-but-bogus CLAUDE_PLUGIN_ROOT is honored
  # (never second-guessed by self-location), so the lint script is not found
  # and the hook no-ops. Same override contract apple-canvas.bats relies on.
  mkdir -p "$WD/.context"
  cat > "$WD/.context/development-2.md" <<'EOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "no anchor present"
---

# Development

Missing anchors, but lint is unreachable via the bogus override.
EOF
  run env CLAUDE_PLUGIN_ROOT="/nonexistent_plugin_root_$$" \
    bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "{\"tool_input\":{\"file_path\":\"$WD/.context/development-2.md\"}}"
  assert_success
}

@test "failure: a per-stream DV write is linted like development-N.md (missing anchor)" {
  mkdir -p "$WD/.context"
  printf -- '---\nhandoff:\n  stage: DV\n  verdict: ok\n  summary: "no anchor"\n---\n\n# Development\n' \
    > "$WD/.context/development-0-service.md"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "{\"tool_input\":{\"file_path\":\"$WD/.context/development-0-service.md\"}}"
  assert_failure 2
}

@test "happy: an over-long stream slug is not an artifact name (no-op)" {
  mkdir -p "$WD/.context"
  long="$WD/.context/development-0-a2345678901234567890123456789012345678901.md"
  printf -- '---\nhandoff:\n  stage: DV\n---\n' > "$long"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "{\"tool_input\":{\"file_path\":\"$long\"}}"
  assert_success
}

@test "contract: --self-test asserts the gating regex (counted summary)" {
  run bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_success
  assert_output --partial "self-test OK"
  assert_output --regexp 'anchor-preflight: self-test OK \([0-9]+ passed, [0-9]+ failed\)$'
}

# --- control-byte lint (bytes are printf-generated) ---------------------------

# mk_compliant_dv <path> — a DV artifact carrying the full anchor allow-list.
mk_compliant_dv() {
  printf -- '---\nhandoff:\n  stage: DV\n  verdict: ok\n  summary: "all anchors"\n---\n\n# Development\n' > "$1"
  printf '\n## %s\n\nbody\n' files-changed tests-added deviations follow-ups elicitation-sweep >> "$1"
}

payload() {
  printf '{"tool_input":{"file_path":"%s"}}' "$1"
}

@test "control bytes: a NUL in a compliant artifact exits non-zero naming path and offset" {
  mkdir -p "$WD/.context"
  : > "$WD/.context/state.json"
  mk_compliant_dv "$WD/.context/development-3.md"
  local off
  off=$(wc -c < "$WD/.context/development-3.md" | tr -d ' ')
  printf '\000\n' >> "$WD/.context/development-3.md"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "$(payload "$WD/.context/development-3.md")"
  assert_failure 2
  assert_output --partial "control bytes in $WD/.context/development-3.md"
  assert_output --partial "$WD/.context/development-3.md:$off:0x00"
}

@test "control bytes: a NUL in a non-artifact text file under a ledger .context/ exits non-zero" {
  mkdir -p "$WD/.context"
  : > "$WD/.context/state.json"
  printf 'spellings `\\0` raw \000\n' > "$WD/.context/notes.md"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(payload "$WD/.context/notes.md")"
  assert_failure 2
  assert_output --partial "$WD/.context/notes.md:19:0x00"
}

@test "control bytes: R5 — outside any ledger .context/ nothing is scanned" {
  mkdir -p "$WD/src" "$WD/bare/.context"
  printf 'page\fbreak\n' > "$WD/src/gen.py"
  run --separate-stderr env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(payload "$WD/src/gen.py")"
  assert_success
  [ -z "$stderr" ] || fail "stderr: $stderr"
  # A .context/ with no state.json is not a ledger either.
  printf 'raw \000\n' > "$WD/bare/.context/notes.md"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(payload "$WD/bare/.context/notes.md")"
  assert_success
  assert_output ""
}

@test "control bytes: a clean non-artifact write is a no-op" {
  printf 'clean\ttext\r\n' > "$WD/notes.md"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(payload "$WD/notes.md")"
  assert_success
  assert_output ""
}

@test "control bytes: a non-text extension is not linted" {
  printf 'png\000data' > "$WD/logo.png"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$(payload "$WD/logo.png")"
  assert_success
}

@test "control bytes: an artifact with a NUL and a missing anchor shows both diagnostics" {
  mkdir -p "$WD/.context"
  : > "$WD/.context/state.json"
  printf -- '---\nhandoff:\n  stage: DV\n  verdict: ok\n  summary: "no anchor"\n---\n\n# Development\n\nraw \001 byte\n' \
    > "$WD/.context/development-4.md"
  local anchor_line
  anchor_line="$(bash "$PLUGIN_ROOT/skills/worktask/scripts/cache-lint.sh" --anchor-lint "$WD/.context/development-4.md" 2>&1 | head -1 || true)"
  [ -n "$anchor_line" ] || fail "anchor lint printed nothing for a missing-anchor artifact"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "$(payload "$WD/.context/development-4.md")"
  assert_failure 2
  assert_output --partial "control bytes in $WD/.context/development-4.md"
  assert_output --partial "$anchor_line"
}

@test "control bytes: an empty plugin root never sources skills/ from the cwd" {
  mkdir -p "$WD/hookcopy" "$WD/skills/worktask/scripts"
  cp "$PLUGIN_ROOT/$SCRIPT" "$WD/hookcopy/anchor-preflight.sh"
  printf 'cb_is_lintable() { return 0; }\ncb_scan_file() { echo PLANTED; return 1; }\n' \
    > "$WD/skills/worktask/scripts/control-byte-lib.sh"
  printf 'x\000\n' > "$WD/notes.md"
  cd "$WD"
  run env -u CLAUDE_PLUGIN_ROOT bash "$WD/hookcopy/anchor-preflight.sh" <<< "$(payload "$WD/notes.md")"
  assert_success
  refute_output --partial "PLANTED"
}

@test "control bytes: --self-test fails when the library is unreachable" {
  run env CLAUDE_PLUGIN_ROOT="/nonexistent_plugin_root_$$" bash "$PLUGIN_ROOT/$SCRIPT" --self-test
  assert_failure
  assert_output --partial "control-byte-lib.sh unreachable"
}

# --- PreToolUse deny arm ------------------------------------------------------
# A JSON deny on stdout with exit 0 blocks the write; empty stdout with exit 0 allows it.
# Only an Edit is ever denied; a Write lands and the Post arm reports its findings.

# pre_payload <tool> <file_path> <content-or-new_string> [old_string]
pre_payload() {
  if [ "$1" = Write ]; then
    jq -cn --arg p "$2" --arg c "$3" '{hook_event_name:"PreToolUse", tool_name:"Write", tool_input:{file_path:$p, content:$c}}'
  else
    jq -cn --arg p "$2" --arg n "$3" --arg o "${4:-}" '{hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:$p, new_string:$n, old_string:$o}}'
  fi
}

with_ledger() { mkdir -p "$WD/.context"; : > "$WD/.context/state.json"; }

run_pre() { run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" <<< "$1"; }

run_post() {  # <tool> <file_path> [new_string] -> Post run with a hook payload
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" --event post \
    <<< "$(jq -cn --arg t "$1" --arg p "$2" --arg n "${3:-}" '{hook_event_name:"PostToolUse", tool_name:$t,
      tool_input:(if $t == "Edit" then {file_path:$p, new_string:$n, old_string:"x"} else {file_path:$p} end)}')"
}

@test "pre: a Write adding an off-list H2 is allowed; Post exits 2 naming it and the Edit fix" {
  with_ledger
  local body=$'## files-changed\n\n## Approach\n'
  run_pre "$(pre_payload Write "$WD/.context/development-0.md" "$body")"
  assert_success
  assert_output ""
  printf -- '---\nhandoff:\n  stage: DV\n---\n\n%s' "$body" > "$WD/.context/development-0.md"
  run_post Write "$WD/.context/development-0.md"
  assert_failure 2
  assert_output --partial "development-0.md (stage=DV) has H2 outside the allow-list: ## Approach."
  assert_output --partial "fix it with an Edit, do not re-Write the file."
}

@test "pre: an Edit adding an H2 outside the DV allow-list is denied, naming it and the allowed set" {
  with_ledger
  run_pre "$(pre_payload Edit "$WD/.context/development-0.md" $'## Approach\n' 'old body')"
  assert_success
  local decision reason
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$output")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")"
  [ "$decision" = deny ] || fail "not denied: $output"
  [[ "$reason" == *"development-0.md (stage=DV) adds H2 outside the allow-list: ## Approach."* ]]
  [[ "$reason" == *"Allowed: ## files-changed, ## tests-added"* ]]
  [[ "$reason" == *"optional: ## verification-command, ## acceptance-commands, ## decisions"* ]]
}

@test "pre: a conforming Write, and one missing required H2s, are both allowed" {
  with_ledger
  run_pre "$(pre_payload Write "$WD/.context/development-0.md" $'## files-changed\n\n## verification-command\n')"
  assert_success
  assert_output ""
}

@test "pre: the same bad content to a non-artifact path is allowed" {
  with_ledger
  run_pre "$(pre_payload Edit "$WD/.context/notes.md" $'## Approach\n')"
  assert_success
  assert_output ""
  run_pre "$(pre_payload Edit "$WD/docs/development-0.md" $'## Approach\n')"
  assert_success
  assert_output ""
}

@test "pre: no state.json beside the artifact means no deny" {
  mkdir -p "$WD/.context"
  run_pre "$(pre_payload Edit "$WD/.context/development-0.md" $'## Approach\n')"
  assert_success
  assert_output ""
}

@test "pre: a per-stream development file is a DV handoff and gets the DV allow-list" {
  with_ledger
  run_pre "$(pre_payload Edit "$WD/.context/development-0-backend.md" $'## files-changed\n\n## commits\n')"
  assert_success
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$output")" = deny ] || fail "not denied: $output"
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"development-0-backend.md (stage=DV) adds H2 outside the allow-list: ## commits."* ]]
  run_pre "$(pre_payload Edit "$WD/.context/development-0-backend.md" $'## files-changed\n\n## verification-command\n')"
  assert_success
  assert_output ""
}

@test "pre: an Edit whose new_string adds a bad H2 is denied; keeping an existing one is not" {
  with_ledger
  run_pre "$(pre_payload Edit "$WD/.context/testing-2.md" $'## Notes\nbody' 'old body')"
  assert_success
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$output")" = deny ]
  [[ "$output" == *"(stage=QA)"* ]]
  run_pre "$(pre_payload Edit "$WD/.context/testing-2.md" $'## Notes\nnew body' $'## Notes\nold body')"
  assert_success
  assert_output ""
}

@test "pre: a stage's title-case optional is allowed there and denied in another stage" {
  with_ledger
  run_pre "$(pre_payload Edit "$WD/.context/testing-0.md" $'## Visual Evidence\n')"
  assert_output ""
  run_pre "$(pre_payload Edit "$WD/.context/developer-review-0.md" $'## Visual Evidence\n')"
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$output")" = deny ]
}

@test "pre: an unreachable plugin root fails open" {
  with_ledger
  run env CLAUDE_PLUGIN_ROOT="/nonexistent_plugin_root_$$" bash "$PLUGIN_ROOT/$SCRIPT" \
    <<< "$(pre_payload Edit "$WD/.context/development-0.md" $'## Approach\n')"
  assert_success
  assert_output ""
}

@test "pre: the Pre arm never runs the PostToolUse control-byte scan or lint" {
  with_ledger
  printf 'x\000\n' > "$WD/.context/development-0.md"
  run_pre "$(pre_payload Write "$WD/.context/development-0.md" $'## files-changed\n')"
  assert_success
  assert_output ""
}

@test "manifest: anchor-preflight is registered under PreToolUse Write|Edit and PostToolUse" {
  run jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | test("anchor-preflight"))) | .matcher' \
    "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  assert_success
  assert_output "Write|Edit"
  run jq -r '.hooks.PostToolUse[] | select(any(.hooks[]; .command | test("anchor-preflight"))) | .matcher' \
    "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  assert_output "Write|Edit"
}

@test "manifest: each registration names its event in argv" {
  run jq -r '[.hooks.PreToolUse[].hooks[], .hooks.PostToolUse[].hooks[]]
    | map(select(.command | test("anchor-preflight")) | (.args // []) | join(" ")) | join(",")' \
    "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  assert_success
  assert_output "--event pre,--event post"
}

# The Pre call fires before the write, so a Post lint of the on-disk file must never gate it.
@test "event: no jq + a legacy file-path env var + --event pre exits 0; without --event it exits 2" {
  with_ledger
  printf 'no anchors\n' > "$WD/.context/development-0.md"
  run_script_env --hide jq --env "CLAUDE_PLUGIN_ROOT=$PLUGIN_ROOT" \
    --env "CLAUDE_TOOL_INPUT_FILE_PATH=$WD/.context/development-0.md" -- "$SCRIPT" --event pre
  assert_success
  assert_output ""
  run_script_env --hide jq --env "CLAUDE_PLUGIN_ROOT=$PLUGIN_ROOT" \
    --env "CLAUDE_TOOL_INPUT_FILE_PATH=$WD/.context/development-0.md" -- "$SCRIPT"
  assert_failure 2
}

@test "event: --event post lints a PreToolUse-shaped payload as Post; an unknown event fails open" {
  mkdir -p "$WD/.context"
  printf 'no anchors\n' > "$WD/.context/development-0.md"
  local payload
  payload="$(jq -cn --arg p "$WD/.context/development-0.md" '{hook_event_name:"PreToolUse", tool_input:{file_path:$p}}')"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" --event post <<< "$payload"
  assert_failure 2
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" --event bogus <<< "$payload"
  assert_success
  assert_output ""
}

# RK-A1: an Edit is judged on new_string alone, so a heading the file keeps inside a fence
# still reads as an H2 and is denied; the reason carries the H3 workaround.
@test "pre: an Edit fragment that lands inside a fence in the file is still denied" {
  with_ledger
  printf '## files-changed\n\n```md\nold\n```\n' > "$WD/.context/development-0.md"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$PLUGIN_ROOT/$SCRIPT" --event pre \
    <<< "$(pre_payload Edit "$WD/.context/development-0.md" $'## Example\nold' 'old')"
  assert_success
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$output")" = deny ] || fail "not denied: $output"
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"## Example."*"Nest other headings as H3." ]]
}

# --- PostToolUse frontmatter arm ----------------------------------------------
# The three harness rejections an Edit can fix: the Write lands, Post reports, the boundary gates.

# qa_artifact <summary_line> <summary text> <sweep item body> — carries every required QA H2,
# so only the frontmatter classes can fail Post.
qa_artifact() {
  printf -- '---\nhandoff:\n  stage: QA\n  verdict: go\n  summary: "%s"\n' "$2"
  printf '  tests_executed:\n    - { runner: bats, count: 3, summary_line: "%s" }\n' "$1"
  printf '  files_touched: []\n  key_decisions: []\n  open_questions:\n'
  printf '    - { id: sw-QA0-1, class: decision, ref: "testing-0.md#elicitation-sweep", blocks_next_stage: false }\n'
  printf '  refs:\n    results: testing-0.md#results\n---\n\n## results\n\nok 3 of 3 at run 1.\n\n'
  printf '## coverage\n\nn/a\n\n## regressions\n\nnone\n\n## verdict\n\ngo\n\n## elicitation-sweep\n\n%s\n' "$3"
}

GOOD_SWEEP=$'sw-QA0-1: Ship now?\n- label: Yes\n- label: No'

fm_reported() {  # <content> -> Pre allows the Write; Post exits 2; prints the Post stderr
  with_ledger
  run_pre "$(pre_payload Write "$WD/.context/testing-0.md" "$1")"
  assert_success
  assert_output ""
  printf '%s\n' "$1" > "$WD/.context/testing-0.md"
  run_post Write "$WD/.context/testing-0.md"
  assert_failure 2
  assert_output --partial "fix it with a small Edit, do not re-Write the file."
  printf '%s\n' "$output"
}

@test "post frontmatter: a digitless test summary_line is allowed at Pre and reported at Post" {
  command -v yq > /dev/null || skip "yq unavailable: the arm fails open"
  out="$(fm_reported "$(qa_artifact 'ALL PASS' 'three suites green' "$GOOD_SWEEP")")"
  [[ "$out" == *"anchor-preflight: testing-0.md: fail: "*"summary_line carries no digit"* ]]
}

@test "post frontmatter: an over-budget frontmatter is reported with Edit guidance" {
  command -v yq > /dev/null || skip "yq unavailable: the arm fails open"
  local long
  long="$(printf 'word%s ' $(seq 1 200))"
  out="$(fm_reported "$(qa_artifact '1..3' "$long" "$GOOD_SWEEP")")"
  [[ "$out" == *"discretionary tokens > 200 budget"* ]]
  [[ "$out" == *"Edit"*"do not re-Write"* ]]
}

@test "post frontmatter: an option-less sweep stub item is reported" {
  command -v yq > /dev/null || skip "yq unavailable: the arm fails open"
  out="$(fm_reported "$(qa_artifact '1..3' 'three suites green' 'sw-QA0-1: all fine, nothing to ask.')")"
  [[ "$out" == *"is a status note, not a question"* ]]
}

@test "post frontmatter: two findings give two lines" {
  command -v yq > /dev/null || skip "yq unavailable: the arm fails open"
  out="$(fm_reported "$(qa_artifact 'ALL PASS' 'three suites green' 'sw-QA0-1: all fine, nothing to ask.')")"
  [ "$(grep -c 'do not re-Write the file' <<< "$out")" -eq 2 ]
}

@test "post frontmatter: an Edit that fixes the frontmatter exits 0; the boundary still fails the unfixed file" {
  command -v yq > /dev/null || skip "yq unavailable: the arm fails open"
  with_ledger
  qa_artifact 'ALL PASS' 'three suites green' "$GOOD_SWEEP" > "$WD/.context/testing-0.md"
  run bash "$PLUGIN_ROOT/skills/worktask/scripts/handoff-harness.sh" --validate-frontmatter "$WD/.context/testing-0.md"
  assert_failure
  assert_output --partial "carries no digit"
  qa_artifact '1..3' 'three suites green' "$GOOD_SWEEP" > "$WD/.context/testing-0.md"
  run_post Edit "$WD/.context/testing-0.md" 'summary_line: "1..3" }'
  assert_success
}

@test "post frontmatter: a body-only Edit is not judged; an Edit in the frontmatter or sweep is" {
  command -v yq > /dev/null || skip "yq unavailable: the arm fails open"
  with_ledger
  qa_artifact 'ALL PASS' 'three suites green' "$GOOD_SWEEP" > "$WD/.context/testing-0.md"
  run_post Edit "$WD/.context/testing-0.md" 'ok 3 of 3 at run 1.'
  assert_success
  run_post Edit "$WD/.context/testing-0.md" 'summary: "three suites green"'
  assert_failure 2
  assert_output --partial "carries no digit"
  run_post Edit "$WD/.context/testing-0.md" '- label: Yes'
  assert_failure 2
  run_post Edit "$WD/.context/testing-0.md" ''
  assert_failure 2
}

@test "post frontmatter: no frontmatter or H2 feedback outside a ledger .context/" {
  command -v yq > /dev/null || skip "yq unavailable: the arm fails open"
  mkdir -p "$WD/.context"
  { qa_artifact 'ALL PASS' 'three suites green' "$GOOD_SWEEP"; printf '\n## Approach\n'; } > "$WD/.context/testing-0.md"
  run_post Write "$WD/.context/testing-0.md"
  refute_output --partial "do not re-Write the file"
  refute_output --partial "has H2 outside the allow-list"
}

@test "post frontmatter: an Edit starting in the sweep and running into a later H2 is judged" {
  command -v yq > /dev/null || skip "yq unavailable: the arm fails open"
  with_ledger
  { qa_artifact 'ALL PASS' 'three suites green' "$GOOD_SWEEP"; printf '\n## Visual Evidence\n\nshot\n'; } > "$WD/.context/testing-0.md"
  run_post Edit "$WD/.context/testing-0.md" $'- label: No\n\n## Visual Evidence\n\nshot'
  assert_failure 2
  assert_output --partial "carries no digit"
}

@test "post frontmatter: a compliant Write passes Post; Pre never judges an Edit on frontmatter" {
  with_ledger
  qa_artifact '1..3' 'three suites green' "$GOOD_SWEEP" > "$WD/.context/testing-0.md"
  run_post Write "$WD/.context/testing-0.md"
  assert_success
  run_pre "$(pre_payload Edit "$WD/.context/testing-0.md" '  summary_line: "ALL PASS"' '')"
  assert_success
  assert_output ""
}
