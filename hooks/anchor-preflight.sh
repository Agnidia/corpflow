#!/usr/bin/env bash
# anchor-preflight — PreToolUse and PostToolUse (Write|Edit) hook, one script for both events.
#
# Usage: anchor-preflight.sh [--event pre|post] | --self-test
#
# The manifest names the event in argv (`--event pre` on the PreToolUse registration) because
# stdin cannot be trusted to say it: without jq the payload is unreadable, and a Pre call that
# fell through to the Post checks would exit 2 on the not-yet-written file's old contents and
# block the write. With no --event the payload's hook_event_name decides, then Post.
#
# PreToolUse: denies only an Edit to a canonical .context/<stage>-N.md artifact (DV also its
# development-N-<stream>.md) whose new_string adds an H2 outside that stage's allow-list
# (cache-lint.sh --anchor-diff), minus the H2s old_string already carries. Re-issuing an Edit
# is cheap. A whole-file Write (every Codex patch maps to one) is never denied: a deny there
# forces a full re-emit of the artifact, while every defect it could carry is fixable by a
# small Edit. Its findings come back from the Post arm instead. A missing required H2 never
# denies: artifacts are built in steps. Fails open (allows) without jq, without a state.json
# beside the artifact, or without a plugin root.
#
# PostToolUse: a write under a .context/ that holds a state.json, whose extension is on the
# control-byte-lib text allowlist, is scanned for raw C0 control bytes (a form feed in a project's
# own source is not the plugin's business). A path matching the canonical .context/<stage>-N.md
# regex also runs cache-lint.sh --anchor-lint; under a ledger .context/ it adds one line per H2
# outside the allow-list, and handoff-harness.sh --validate-frontmatter on a same-basename temp copy of the file on disk for
# three classes only: frontmatter over the token budget, a digitless test summary_line, a sweep
# stub whose item has under 2 options. The frontmatter check runs for a Write, a Codex patch, an
# unreadable payload, and an Edit whose new_string is empty or lands in the frontmatter block or
# the ## elicitation-sweep section; a body-only Edit cannot change those classes. It fails open
# without yq or the harness.
#
# Moving these findings from a Pre deny to Post feedback loosens a write-time control on purpose:
# the stage-boundary harness (Step B.1) still fails closed, so nothing invalid crosses a stage.
#
# Plugin root is env-first ($CLAUDE_PLUGIN_ROOT), else self-located from $0. An empty root
# skips both lints. --self-test asserts the gating regex, the control-byte scan, the Pre Edit
# deny, the Pre Write allow, the Post frontmatter finding and the no-jq `--event pre` exit.
set -eu

SELF_TEST=0
EVENT=""
case "${1:-}" in
  --self-test) SELF_TEST=1 ;;
  --event)
    EVENT="${2:-}"
    # An unknown event is a manifest typo; a blocking hook fails open on it rather than guess.
    case "$EVENT" in pre | post) ;; *) exit 0 ;; esac
    ;;
esac

# Canonical artifact basenames (mirrors handoff-protocol.md#stage-artifact-map).
#
# DV also matches the per-stream development-N-<stream>.md: under handoff-protocol.md
# § DV fan-out — ledger tasks each stream file IS its row's DV handoff, read directly by
# DR/QA through refs.dev, so it carries the same anchor contract as development-N.md.
# The stream arm is the S1 slug grammar; its 40-char cap cannot be said in one ERE, so
# STREAM_TOO_LONG_RE subtracts over-long slugs. Other stages have no stream suffix.
ARTIFACT_RE='\.context/((planning|architecture|coordination|development|developer-review|security-review|testing|documentation|release|complete-summary|retrospective|incident|ethics-review)-[0-9]+|development-[0-9]+-[a-z0-9]+(-[a-z0-9]+)*)\.md$'
STREAM_TOO_LONG_RE='\.context/development-[0-9]+-[a-z0-9-]{41,}\.md$'

# is_artifact <path> — true when <path> is a lintable stage artifact name.
is_artifact() {
  printf '%s' "$1" | grep -qE "$ARTIFACT_RE" || return 1
  ! printf '%s' "$1" | grep -qE "$STREAM_TOO_LONG_RE"
}

if [ "$SELF_TEST" -eq 1 ]; then
  ok=0
  for p in \
    ".context/development-0.md" \
    ".context/development-0-swift-app.md" \
    ".context/development-2-backend.md" \
    ".context/development-0-a234567890123456789012345678901234567890.md" \
    ".context/developer-review-12.md" \
    "/abs/path/.context/planning-3.md"; do
    is_artifact "$p" || { echo "anchor-preflight: self-test FAIL (should match: $p) ($ok passed, 1 failed)"; exit 1; }
    ok=$((ok + 1))
  done
  for p in \
    "skills/worktask/SKILL.md" \
    ".context/state.json" \
    ".context/development.md" \
    ".context/development-0-.md" \
    ".context/development-0-Stream.md" \
    ".context/development-0--web.md" \
    ".context/development-0-web-.md" \
    ".context/development-N-web.md" \
    ".context/development-0-a2345678901234567890123456789012345678901.md" \
    ".context/planning-0-stream.md" \
    ".context/developer-review-0-web.md" \
    ".context/worktask-comms.md"; do
    is_artifact "$p" && { echo "anchor-preflight: self-test FAIL (should NOT match: $p) ($ok passed, 1 failed)"; exit 1; }
    ok=$((ok + 1))
  done

  # An unreachable library is a FAIL here, never a vacuous OK: the hook itself fails open.
  _ST_LIB="${CLAUDE_PLUGIN_ROOT:-$(dirname -- "$0")/..}/skills/worktask/scripts/control-byte-lib.sh"
  if [ ! -r "$_ST_LIB" ]; then
    echo "anchor-preflight: self-test FAIL (control-byte-lib.sh unreachable at $_ST_LIB) ($ok passed, 1 failed)"
    exit 1
  fi
  # shellcheck source=skills/worktask/scripts/control-byte-lib.sh
  . "$_ST_LIB"
  _st_td=$(mktemp -d "${TMPDIR:-/tmp}/anchor-preflight-selftest.XXXXXX")
  # shellcheck disable=SC2064  # the path is fixed at set time on purpose
  trap "rm -rf '$_st_td'" EXIT
  # shellcheck disable=SC2016  # the backticks are fixture text, not a command substitution
  printf 'escape spellings `\\0` then a raw \000 byte\n' > "$_st_td/nul.md"
  printf 'tab\tcr\r\nliteral \\0 \\x00 ^@\n' > "$_st_td/clean.md"
  _st_rc=0
  _st_out=$(cb_scan_file "$_st_td/nul.md" nul.md) || _st_rc=$?
  [ "$_st_rc" -eq 1 ] && [ "$_st_out" = "nul.md:33:0x00" ] \
    || { echo "anchor-preflight: self-test FAIL (NUL not flagged: rc=$_st_rc out=$_st_out) ($ok passed, 1 failed)"; exit 1; }
  ok=$((ok + 1))
  _st_rc=0
  cb_scan_file "$_st_td/clean.md" clean.md > /dev/null || _st_rc=$?
  [ "$_st_rc" -eq 0 ] || { echo "anchor-preflight: self-test FAIL (clean file flagged: rc=$_st_rc) ($ok passed, 1 failed)"; exit 1; }
  ok=$((ok + 1))

  if command -v jq > /dev/null 2>&1; then
    mkdir -p "$_st_td/.context"
    : > "$_st_td/.context/state.json"
    _st_root="${CLAUDE_PLUGIN_ROOT:-$(dirname -- "$0")/..}"
    _st_pre() {  # <tool> <file_path> -> the hook's stdout for a PreToolUse write adding `## Approach`
      jq -cn --arg t "$1" --arg p "$2" '{hook_event_name: "PreToolUse", tool_name: $t,
        tool_input: (if $t == "Write" then {file_path: $p, content: "## files-changed\n## Approach\n"}
          else {file_path: $p, new_string: "## Approach\n", old_string: ""} end)}' \
        | CLAUDE_PLUGIN_ROOT="$_st_root" bash "$0"
    }
    _st_out=$(_st_pre Edit "$_st_td/.context/development-0.md") || _st_out=""
    case "$_st_out" in
      *'"permissionDecision":"deny"'*'## Approach'*) ;;
      *) echo "anchor-preflight: self-test FAIL (bad H2 in an artifact Edit not denied: $_st_out) ($ok passed, 1 failed)"; exit 1 ;;
    esac
    ok=$((ok + 1))
    _st_out=$(_st_pre Write "$_st_td/.context/development-0.md") || _st_out="rc!=0"
    [ -z "$_st_out" ] || { echo "anchor-preflight: self-test FAIL (artifact Write denied: $_st_out) ($ok passed, 1 failed)"; exit 1; }
    ok=$((ok + 1))
    if command -v yq > /dev/null 2>&1; then
      printf -- '---\nhandoff:\n  stage: QA\n  verdict: go\n  summary: "s"\n  tests_executed:\n    - { runner: bats, count: 3, summary_line: "ALL PASS" }\n  files_touched: []\n  key_decisions: []\n  open_questions: []\n  refs:\n    results: testing-0.md#results\n---\n\n## results\n' \
        > "$_st_td/.context/testing-0.md"
      _st_rc=0
      _st_out=$(jq -cn --arg p "$_st_td/.context/testing-0.md" '{hook_event_name: "PostToolUse", tool_name: "Write",
        tool_input: {file_path: $p}}' \
        | CLAUDE_PLUGIN_ROOT="$_st_root" bash "$0" --event post 2>&1 > /dev/null) || _st_rc=$?
      case "$_st_rc:$_st_out" in
        2:*'carries no digit'*'do not re-Write the file'*) ;;
        *) echo "anchor-preflight: self-test FAIL (digitless summary_line not reported at Post: rc=$_st_rc $_st_out) ($ok passed, 1 failed)"; exit 1 ;;
      esac
      ok=$((ok + 1))
      rm -f "$_st_td/.context/testing-0.md"
    fi
    _st_out=$(_st_pre Edit "$_st_td/notes-0.md") || _st_out="rc!=0"
    [ -z "$_st_out" ] || { echo "anchor-preflight: self-test FAIL (non-artifact write denied: $_st_out) ($ok passed, 1 failed)"; exit 1; }
    ok=$((ok + 1))
  else
    echo "anchor-preflight: self-test SKIP pre-write deny and post frontmatter arms (jq unavailable; both fail open)"
  fi

  # The farm carries the control-byte scan's tools but no jq, so the NUL file would exit 2 if
  # --event pre ever reached the Post path. The same run without --event proves the fixture bites.
  mkdir -p "$_st_td/bin"
  for _st_tool in awk grep od tr; do
    _st_src=$(command -v "$_st_tool" 2> /dev/null) || continue
    case "$_st_src" in /*) ln -s "$_st_src" "$_st_td/bin/$_st_tool" ;; esac
  done
  _st_nojq() {  # [--event pre] -> the hook's exit status with jq hidden
    _st_rc=0
    env PATH="$_st_td/bin" CLAUDE_TOOL_INPUT_FILE_PATH="$_st_file" \
      CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname -- "$0")/..}" \
      "$BASH" "$0" "$@" < /dev/null > /dev/null 2>&1 || _st_rc=$?
  }
  # The Post scan covers only a ledger's .context/, so the biting fixture lives in one.
  mkdir -p "$_st_td/.context"
  : > "$_st_td/.context/state.json"
  cp "$_st_td/nul.md" "$_st_td/.context/nul.md"
  _st_file="$_st_td/.context/nul.md"
  _st_nojq
  [ "$_st_rc" -eq 2 ] || { echo "anchor-preflight: self-test FAIL (no-jq Post fixture exited $_st_rc, want 2) ($ok passed, 1 failed)"; exit 1; }
  ok=$((ok + 1))
  _st_file="$_st_td/nul.md"
  _st_nojq
  [ "$_st_rc" -eq 0 ] || { echo "anchor-preflight: self-test FAIL (NUL outside any .context/ exited $_st_rc, want 0) ($ok passed, 1 failed)"; exit 1; }
  ok=$((ok + 1))
  _st_file="$_st_td/.context/nul.md"
  _st_nojq --event pre
  [ "$_st_rc" -eq 0 ] || { echo "anchor-preflight: self-test FAIL (no-jq --event pre exited $_st_rc) ($ok passed, 1 failed)"; exit 1; }
  ok=$((ok + 1))

  echo "anchor-preflight: self-test OK ($ok passed, 0 failed)"
  exit 0
fi

# An explicitly set env var always wins; otherwise derive the root from the shared
# resolver, which validates the .claude-plugin/plugin.json marker.
resolve_plugin_root() {
  PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
  [ -z "$PLUGIN_ROOT" ] || return 0
  # A TRUNCATED library is worse than an absent one: a syntax error in a sourced file is
  # fatal under `set -e` and `||` does not rescue it. Drop -e across the source and probe
  # for the symbol afterwards, so an unusable library degrades this preflight to a no-op
  # instead of turning it into a hard block on every artifact write.
  _LIB="$(dirname -- "$0")/lib/corpflow-base.sh"
  _cf_opts=$-
  set +e
  # shellcheck source=hooks/lib/corpflow-base.sh
  [ -f "$_LIB" ] && . "$_LIB"
  case "$_cf_opts" in *e*) set -e ;; esac
  if command -v corpflow_plugin_root > /dev/null 2>&1; then
    PLUGIN_ROOT="$(corpflow_plugin_root)" || PLUGIN_ROOT=""
  fi
  return 0
}

# The deny reason names the stage's whole allowed set, because an agent outside corpflow
# writing a canonical artifact name sees the contract nowhere else.
allowed_set() {
  bash "$1" --allow-list 2> /dev/null | awk -F'\t' -v b="$2" '
    function add(l, h) { return l (l == "" ? "" : ", ") "## " h }
    $3 == b && ($4 == "required" || $4 == "universal") { req = add(req, $5); st = $1 }
    $3 == b && $4 == "optional" { opt = add(opt, $5) }
    $1 == "*" { any = add(any, $5) }
    END {
      if (st == "") exit 1
      printf "%s\n%s%s%s", st, req, (opt == "" ? "" : "; optional: " opt), (any == "" ? "" : "; any stage: " any)
    }'
}

_nl='
'

# unexpected_h2s <anchor-diff rows> -> "## A, ## B" for the `unexpected` rows.
unexpected_h2s() {
  printf '%s\n' "$1" | awk -F'\t' '$1 == "unexpected" { printf "%s## %s", (n++ ? ", " : ""), $2 }'
}

# canonical_base <basename> — strip the run index and any DV stream suffix: the allow-list keys
# rows by canonical basename.
canonical_base() {
  printf '%s' "${1%.md}" | sed -E 's/-[0-9]+(-[a-z0-9-]+)?$//'
}

pre_tool_use_arm() {
  FILE_PATH=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // empty' 2> /dev/null) || return 0
  [ -n "$FILE_PATH" ] || return 0
  is_artifact "$FILE_PATH" || return 0
  # The ledger beside the artifact, not a resolved root: a megatask worktree's .context is
  # not the main checkout's.
  [ -f "$(dirname -- "$FILE_PATH")/state.json" ] || return 0
  resolve_plugin_root
  [ -n "$PLUGIN_ROOT" ] || return 0
  _lint="$PLUGIN_ROOT/skills/worktask/scripts/cache-lint.sh"
  [ -r "$_lint" ] || return 0

  # A Write never reaches the deny below; see the header for why.
  [ "$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.content | type' 2> /dev/null)" != string ] || return 0

  # Model-authored text reaches the lint only as file contents, never as argv.
  _pre_td=$(mktemp -d "${TMPDIR:-/tmp}/anchor-preflight.XXXXXX") || return 0
  # shellcheck disable=SC2064  # the path is fixed at set time on purpose
  trap "rm -rf '$_pre_td'" EXIT
  printf '%s' "$PAYLOAD" | jq -r '.tool_input.new_string // ""' > "$_pre_td/new" 2> /dev/null || return 0
  printf '%s' "$PAYLOAD" | jq -r '.tool_input.old_string // ""' > "$_pre_td/old" 2> /dev/null || return 0

  _rc=0
  _rows=$(bash "$_lint" --anchor-diff --for-path "$FILE_PATH" --baseline "$_pre_td/old" "$_pre_td/new" 2> /dev/null) || _rc=$?
  _bad=""
  [ "$_rc" -ne 1 ] || _bad=$(unexpected_h2s "$_rows")
  [ -n "$_bad" ] || return 0
  _base="${FILE_PATH##*/}"
  _set=$(allowed_set "$_lint" "$(canonical_base "$_base")") || return 0
  _reason="anchor-preflight: $_base (stage=${_set%%"$_nl"*}) adds H2 outside the allow-list: $_bad. Allowed: ${_set#*"$_nl"}. Nest other headings as H3."
  _doc=$(jq -cn --arg reason "$_reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' \
    2> /dev/null) || return 0
  printf '%s\n' "$_doc"
  return 0
}

# Resolve the written file path: prefer hook stdin JSON, fall back to env.
FILE_PATH=""
PAYLOAD=""
TOOL_NAME=""
if [ "$EVENT" = pre ] && ! command -v jq > /dev/null 2>&1; then
  exit 0
fi
if command -v jq >/dev/null 2>&1; then
  PAYLOAD=$(cat 2>/dev/null || true)
  if [ "$EVENT" = pre ]; then
    [ -z "$PAYLOAD" ] || pre_tool_use_arm
    exit 0
  fi
  if [ -n "$PAYLOAD" ]; then
    if [ -z "$EVENT" ] \
      && [ "$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2> /dev/null || true)" = "PreToolUse" ]; then
      pre_tool_use_arm
      exit 0
    fi
    FILE_PATH=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)
    TOOL_NAME=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null || true)
  fi
fi
[ -z "$FILE_PATH" ] && FILE_PATH="${CLAUDE_TOOL_INPUT_FILE_PATH:-}"
[ -n "$FILE_PATH" ] || exit 0

resolve_plugin_root
# Never fall back to `.`: an empty root would load skills/ out of the user's project (CWE-427).
[ -n "$PLUGIN_ROOT" ] || exit 0

# in_ledger_context <path> — rc 0 when the nearest ancestor directory named .context holds a
# state.json; rc 1 otherwise, including a path under no .context at all.
in_ledger_context() {
  local d="${1%/*}"
  [ "$d" != "$1" ] || return 1
  while [ -n "$d" ]; do
    case "$d" in
      */.context | .context)
        [ -f "$d/state.json" ]
        return
        ;;
    esac
    case "$d" in
      */*) d="${d%/*}" ;;
      *) return 1 ;;
    esac
  done
  return 1
}

cbrc=0
CB_LIB="$PLUGIN_ROOT/skills/worktask/scripts/control-byte-lib.sh"
if [ -f "$FILE_PATH" ] && [ -r "$CB_LIB" ] && in_ledger_context "$FILE_PATH"; then
  _cf_opts=$-
  set +e
  # shellcheck source=skills/worktask/scripts/control-byte-lib.sh
  . "$CB_LIB"
  case "$_cf_opts" in *e*) set -e ;; esac
  if command -v cb_scan_file > /dev/null 2>&1 && cb_is_lintable "$FILE_PATH"; then
    cbhits=$(cb_scan_file "$FILE_PATH" "$FILE_PATH") || cbrc=$?
    if [ "$cbrc" -eq 1 ]; then
      printf >&2 'anchor-preflight: control bytes in %s — a typed escape was decoded into a raw byte; rewrite each named byte\n' "$FILE_PATH"
      printf >&2 '%s\n' "$cbhits"
    else
      cbrc=0
    fi
  fi
fi

if ! is_artifact "$FILE_PATH" || [ ! -f "$FILE_PATH" ]; then
  [ "$cbrc" -eq 0 ] || exit 2
  exit 0
fi

# The Edit-fix feedback is the worktask contract, so it fires only beside a ledger, as the Pre
# deny does; --anchor-lint keeps its wider, pre-existing scope.
LEDGER=0
if in_ledger_context "$FILE_PATH"; then LEDGER=1; fi

arc=0
LINT="$PLUGIN_ROOT/skills/worktask/scripts/cache-lint.sh"
if [ -f "$LINT" ]; then
  bash "$LINT" --anchor-lint "$FILE_PATH" || arc=$?
fi
if [ -f "$LINT" ] && [ "$LEDGER" -eq 1 ]; then
  # --anchor-lint prints `unexpected: X`; the model-facing line names the H2 and the Edit fix.
  _rows=$(bash "$LINT" --anchor-diff --for-path "$FILE_PATH" "$FILE_PATH" 2> /dev/null) || true
  _bad=$(unexpected_h2s "$_rows")
  if [ -n "$_bad" ]; then
    _base="${FILE_PATH##*/}"
    if _set=$(allowed_set "$LINT" "$(canonical_base "$_base")"); then
      printf >&2 'anchor-preflight: %s (stage=%s) has H2 outside the allow-list: %s. Allowed: %s; fix it with an Edit, do not re-Write the file.\n' \
        "$_base" "${_set%%"$_nl"*}" "$_bad" "${_set#*"$_nl"}"
    fi
  fi
fi

# frontmatter_edit_scope — rc 0 when the frontmatter classes need judging after this write.
# Only an Edit can be skipped, and only when its new_string provably sits in the body: in doubt
# (empty fragment, unreadable payload, a fragment spanning a region edge) it judges.
frontmatter_edit_scope() {
  [ "$TOOL_NAME" = Edit ] || return 0
  _new=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.new_string // ""' 2> /dev/null) || return 0
  [ -n "$_new" ] || return 0
  ! printf '%s\n' "$_new" | grep -qxE -- '---|## elicitation-sweep[[:space:]]*' || return 0
  _fm=$(awk 'NR == 1 && $0 != "---" { exit } { print } NR > 1 && $0 == "---" { exit }' "$FILE_PATH")
  case "$_fm" in *"$_new"*) return 0 ;; esac
  # Sweep to end of file: a fragment that starts in the sweep may run into a later H2.
  _sw=$(awk '/^## elicitation-sweep[[:space:]]*$/ { on = 1 } on' "$FILE_PATH")
  case "$_sw" in *"$_new"*) return 0 ;; esac
  return 1
}

# post_frontmatter_check — one stderr line per harness finding of the three Edit-fixable
# classes; rc 1 on any. The temp copy keeps the harness from consulting sibling files.
post_frontmatter_check() {
  head -n 1 "$FILE_PATH" | grep -q '^---$' || return 0
  command -v yq > /dev/null 2>&1 || return 0
  _hh="$PLUGIN_ROOT/skills/worktask/scripts/handoff-harness.sh"
  [ -r "$_hh" ] || return 0
  frontmatter_edit_scope || return 0
  _post_td=$(mktemp -d "${TMPDIR:-/tmp}/anchor-preflight.XXXXXX") || return 0
  # shellcheck disable=SC2064  # the path is fixed at set time on purpose
  trap "rm -rf '$_post_td'" EXIT
  _copy="$_post_td/${FILE_PATH##*/}"
  cp "$FILE_PATH" "$_copy" || return 0
  _fails=$(bash "$_hh" --validate-frontmatter "$_copy" 2>&1 > /dev/null \
    | grep -E '^fail: .*(discretionary tokens >|summary_line carries no digit|is a status note, not a question)') || return 0
  [ -n "$_fails" ] || return 0
  printf '%s\n' "$_fails" | while IFS= read -r _f; do
    printf >&2 'anchor-preflight: %s: %s; fix it with a small Edit, do not re-Write the file.\n' "${FILE_PATH##*/}" "$_f"
  done
  return 1
}

frc=0
[ "$LEDGER" -eq 0 ] || post_frontmatter_check || frc=$?
[ "$cbrc" -eq 0 ] && [ "$arc" -eq 0 ] && [ "$frc" -eq 0 ] || exit 2
exit 0
