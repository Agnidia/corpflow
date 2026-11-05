#!/usr/bin/env bash
# dv-comment-density-gate — SubagentStop gate blocking a code-writing agent when
# a changed source file is more comment than skills/code-comment-standard allows.
# No matcher in plugin.json; the hook self-filters.
#
# The agent filter matches any writer (*developer*, *code-fixer*,
# *test-generator*) rather than one exact id, since a worktree waiver can
# dispatch a platform agent directly. Silent for reviewers, so a reviewer is
# never blocked for the writer's bloat.
#
# Behavior:
#   - No-op (exit 0) for non-writers, or when no source file changed.
#   - Density is the comment share of a file's ADDED lines (whole body for a new
#     file), so an agent is never blocked for inheriting existing bloat. Files
#     under MIN_ADDED_LINES are skipped — bulk-authored files are the target.
#   - Two signals, either one blocks: the ESSAY share (comment lines sitting in
#     runs longer than the per-declaration budget) over CORPFLOW_COMMENT_DENSITY_MAX
#     (default 40), or the aggregate share over the looser ..._HARD ceiling.
#     A block carries remediation in additionalContext plus a
#     comment_density_block row. Under -> pass, warning in the row past
#     ..._WARN (default 30) without blocking.
#   - jq or git absent -> exit 0, like the sibling gates.
#   - Exit is ALWAYS 0; a block travels in the decision JSON, never the code.
#   - --self-test: bloated fixture blocks, lean fixture passes.
set -eu

# Measured against a real offending branch: added-line density ran 26-67% per
# file, and 40 catches every genuine offender while clearing the two files whose
# documentation was proportionate. That ceiling scores the ESSAY share, not the
# aggregate: a 20-case enum with one budget-compliant /// per one-line case is
# structurally ~1:1 and measured 48% aggregate, so the aggregate alone cannot
# separate an essay from a long list of compliant one-liners.
DENSITY_MAX="${CORPFLOW_COMMENT_DENSITY_MAX:-40}"
# Secondary ceiling on the aggregate, so budget-shaped prose repeated all the
# way down still blocks. Derived from DENSITY_MAX so one knob moves both.
DENSITY_HARD="${CORPFLOW_COMMENT_DENSITY_HARD:-$((DENSITY_MAX + 20))}"
# A run longer than the standard's 1-3-line doc budget is an essay, whatever it
# documents (skills/shared/code-documentation.md § Length budget).
BLOCK_MAX="${CORPFLOW_COMMENT_BLOCK_MAX:-3}"
DENSITY_WARN="${CORPFLOW_COMMENT_DENSITY_WARN:-30}"
MIN_ADDED_LINES="${CORPFLOW_COMMENT_DENSITY_MIN_LINES:-40}"

SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

read_stdin() {
  if [ "$SELF_TEST" -eq 1 ]; then
    printf '%s' '{"agent_type":"apple-developer:ios-developer","agent_id":"agt_test","session_id":"sess_test"}'
  else
    cat
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "dv-comment-density-gate: jq not found, skipping" >&2
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "dv-comment-density-gate: git not found, skipping" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# comment_style_for <path>: the comment syntax family of a file, by extension.
#
# A single C-family regex scored every `#`-commented language at 0% comments, so
# a wholly-commented .py sailed through the gate it was supposed to trip. The
# style must track the extension, not the majority language in the repo.
# ---------------------------------------------------------------------------
comment_style_for() {
  case "${1##*.}" in
    py | sh | bash) printf 'hash' ;;
    *) printf 'cfamily' ;;
  esac
}

# ---------------------------------------------------------------------------
# rename_source_of <root> <file>: the pre-move path when <file> is a rename
# destination, else nothing. Feeding both paths to `git diff` is the only way to
# make rename detection fire under a pathspec.
#
# Emits nothing for a path containing whitespace — the caller word-splits this,
# and a wrong pathspec would silently measure the file as wholly new.
# ---------------------------------------------------------------------------
rename_source_of() {
  _rs_root="$1"
  _rs_file="$2"
  git -C "$_rs_root" diff HEAD -M --name-status --diff-filter=R 2>/dev/null |
    awk -F'\t' -v dest="$_rs_file" '
      $3 == dest && $2 !~ /[ \t]/ { print $2; exit }
    '
}

# ---------------------------------------------------------------------------
# The scoring pass, shared by both arms via `mode`. Emits "<aggregate%> <lines>
# <essay%>": the essay share counts only comment lines inside a run longer than
# `budget`, which is what separates an essay from one compliant /// per
# declaration.
#
# A blank line, a code line, and (in diff mode) any non-added line all end a
# run: a doc block is contiguous, and hunks are not adjacent in the file.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016 # awk program text; $0/$1 are awk's, not the shell's
DENSITY_AWK='
  BEGIN { pat = (style == "hash") ? "^#" : "^(//|/\\*|\\*/|\\*)" }
  function flush() { if (run > budget) { essay += run } ; run = 0 }
  function feed(line) {
    sub(/^[ \t]+/, "", line)
    if (line == "") { flush(); return }
    total++
    if (line ~ pat) { comment++; run++; return }
    flush()
  }
  mode == "diff" && /^\+\+\+/ { flush(); next }
  mode == "diff" { if ($0 ~ /^\+/) { feed(substr($0, 2)) } else { flush() } ; next }
  { feed($0) }
  END {
    flush()
    if (total > 0) {
      printf "%d %d %d", (comment * 100) / total, total, (essay * 100) / total
    }
  }
'

# ---------------------------------------------------------------------------
# added_density_of <root> <file>: "<aggregate%> <added-lines> <essay%>", or
# nothing when the file has no countable body. Line-based on purpose — it must
# agree with the ratio a human gets from grep, not with a language parser.
#
# Python docstrings are NOT counted: the diff arm sees only added lines, so one
# unpaired `"""` would score every later line as comment. Undercounting is the
# safe direction. The leading license block is skipped so boilerplate nobody
# wrote cannot push a short file over the ceiling.
# ---------------------------------------------------------------------------
added_density_of() {
  _root="$1"
  _file="$2"
  _style=$(comment_style_for "$_file")
  # Added lines only — the agent owns what it wrote, not what it inherited.
  # Whole-file density would block an agent for touching one of the many
  # pre-existing files already over the ceiling (measured: 85 of 341 in a real
  # repo, p90 = 50%), which punishes the wrong person and trains people to
  # avoid touching bloated files.
  #
  # An untracked file has no diff, so its whole body is "added" — correct: a
  # new file is entirely the author's.
  #
  # A moved file needs BOTH of its paths in the pathspec. -M alone does not
  # help here: a pathspec naming only the destination filters the deletion side
  # out before rename detection runs, so the move still reads as a whole-file
  # addition and the file's inherited comments all count as newly written — a
  # pure `git mv` of a comment-dense file could breach the ceiling on its own.
  _pair=$(rename_source_of "$_root" "$_file")
  if git -C "$_root" ls-files --error-unmatch "$_file" >/dev/null 2>&1; then
    # shellcheck disable=SC2086 # $_pair is a git-emitted path, deliberately split
    git -C "$_root" diff HEAD -M -- $_pair "$_file" 2>/dev/null |
      awk -v style="$_style" -v budget="$BLOCK_MAX" -v mode=diff "$DENSITY_AWK"
  else
    awk -v style="$_style" -v budget="$BLOCK_MAX" -v mode=file "$DENSITY_AWK" \
      "$_root/$_file" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# run_gate: core logic, parameterized over the .context/ root + repo + payload.
# Echoes the block decision on stdout when blocking; appends one audit row.
# Returns 0 always.
# ---------------------------------------------------------------------------
run_gate() {
  _payload="$1"
  _ctx="$2"
  _repo="$3"

  _agent=$(printf '%s' "$_payload" | jq -r '.agent_type // "unknown"' 2>/dev/null || echo unknown)
  case "$_agent" in
    *developer* | *code-fixer* | *test-generator*) ;;
    *) return 0 ;;
  esac

  _root=$(git -C "$_repo" rev-parse --show-toplevel 2>/dev/null) || return 0

  # Changed + untracked source files, NUL-safe against paths with spaces.
  _tracked=$(git -C "$_root" diff --name-only --diff-filter=ACMR -M HEAD 2>/dev/null || true)
  _untracked=$(git -C "$_root" ls-files --others --exclude-standard 2>/dev/null || true)

  # A landed file is the producer's to ship — the consumer never authored it, so
  # it cannot count as this agent's comment bloat. Subtracted from the untracked
  # half only; a staged/tracked path stays visible regardless. Scoped to this
  # tree by its physical root (skills/worktask/references/ledger-streams.md § The landed set) so a
  # same-named untracked file in a different tree is never hidden here. A
  # missing state file, an unresolvable root or a jq failure leaves nothing
  # subtracted.
  if [ -n "$_untracked" ]; then
    _phys_root=$(CDPATH="" cd -P -- "$_root" 2>/dev/null && pwd -P) || _phys_root=""
    _landed=""
    if [ -n "$_phys_root" ]; then
      _landed=$(jq -r --arg root "$_phys_root" \
        '[(.tasks // {})[] | .metadata | select(any(.landed_roots // [] | arrays | .[]; . == $root)) | .landed_paths // [] | arrays | .[] | strings | select(test("\\A[A-Za-z0-9._@+/-]+\\z"))] | unique | .[]' \
        "$_ctx/state.json" 2>/dev/null || true)
    fi
    if [ -n "$_landed" ]; then
      _untracked=$(printf '%s\n' "$_untracked" | grep -F -x -v -f <(printf '%s\n' "$_landed") || true)
    fi
  fi

  _files=$(
    {
      printf '%s\n' "$_tracked"
      printf '%s\n' "$_untracked"
    } | sort -u
  )
  [ -n "$_files" ] || return 0

  _offenders=""
  _worst=0
  _worst_essay=0
  _checked=0
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    # Vendored trees are exempt: on a dependency refresh the added lines ARE the
    # third-party code, so added-line scoping stops shielding the writer from
    # bloat it cannot slim.
    case "$_f" in
      vendor/* | */vendor/* | */node_modules/* | */Pods/* | */third_party/*) continue ;;
    esac
    case "${_f##*.}" in
      swift | h | m | mm | c | cc | cpp | ts | tsx | js | jsx | py | kt | java | go | rs | sh | bash) ;;
      *) continue ;;
    esac
    [ -f "$_root/$_f" ] || continue
    _m=$(added_density_of "$_root" "$_f")
    [ -n "$_m" ] || continue
    _d=${_m%% *}
    _rest=${_m#* }
    _added=${_rest%% *}
    _e=${_rest##* }
    # Small edits are not the failure mode; bulk-authored files are. Below the
    # floor a two-line doc on a three-line fix would read as 66% and block.
    [ "$_added" -ge "$MIN_ADDED_LINES" ] || continue
    _checked=$((_checked + 1))
    [ "$_d" -gt "$_worst" ] && _worst="$_d"
    [ "$_e" -gt "$_worst_essay" ] && _worst_essay="$_e"
    if [ "$_e" -gt "$DENSITY_MAX" ] || [ "$_d" -gt "$DENSITY_HARD" ]; then
      _offenders="${_offenders}${_offenders:+, }${_f} (${_d}% of ${_added} added, ${_e}% in comment blocks over ${BLOCK_MAX} lines)"
    fi
  done <<EOF
$_files
EOF

  [ "$_checked" -gt 0 ] || return 0

  _log_dir="$_ctx/logs"
  mkdir -p "$_log_dir" 2>/dev/null || true
  _ts=$(date -u +%FT%TZ)

  if [ -z "$_offenders" ]; then
    _res="ok"
    # Warn on either signal, so a file drifting toward the secondary ceiling is
    # visible before it blocks.
    if [ "$_worst_essay" -gt "$DENSITY_WARN" ] || [ "$_worst" -gt "$((DENSITY_HARD - 10))" ]; then
      _res="warn"
    fi
    # Refuse a symlinked audit.jsonl: following it makes this append a write primitive
    # against an arbitrary target. A lost row never blocks the caller.
    if [ ! -L "$_log_dir/audit.jsonl" ]; then
      jq -cn --arg ts "$_ts" --arg agent "$_agent" --arg res "$_res" \
        --argjson worst "$_worst" --argjson essay "$_worst_essay" \
        --argjson checked "$_checked" --argjson max "$DENSITY_MAX" \
        --argjson hard "$DENSITY_HARD" --argjson block "$BLOCK_MAX" '
        {ts: $ts, actor: "hook:dv-comment-density-gate", action: "comment_density_pass",
         subject: $agent, result: $res,
         metadata: {worst_pct: $worst, worst_essay_pct: $essay, files_checked: $checked,
                    threshold: $max, hard_threshold: $hard, block_max: $block}}' \
        >>"$_log_dir/audit.jsonl" 2>/dev/null || true
    fi
    return 0
  fi

  _remedy="Comment-density gate: these changed files are over-documented — ${_offenders}. A file trips this when more than ${DENSITY_MAX}% of its added lines sit in comment blocks longer than ${BLOCK_MAX} lines, or when its added lines are over ${DENSITY_HARD}% comment overall. One compliant one-line /// per declaration is fine and does not trip it; multi-line essays and budget-shaped prose repeated down the whole file do. The corpflow standard (skill: corpflow:code-comment-standard) requires comment-to-code density well below 1:1; a file that is ~half prose is over-documented. Remove: multi-paragraph /// essays, defect/ticket history, before/after narration, AC-/REQ- IDs and issue tags as provenance, caller enumeration, QA runbooks and tuning instructions, prose restating the signature, and any justification written to answer a review finding. Keep: a one-line /// summary where the name is not self-evident, ONE terse WHY per non-obvious literal, and one-line invariants that prevent a regression. Rationale, threshold derivations and deviation justifications belong in .context/development-N.md and the PR — not in source. Re-run and return once every changed file is under the ceiling."

  # Refuse a symlinked audit.jsonl: following it makes this append a write primitive
  # against an arbitrary target. A lost row never blocks the caller.
  if [ ! -L "$_log_dir/audit.jsonl" ]; then
    jq -cn --arg ts "$_ts" --arg agent "$_agent" --arg off "$_offenders" \
      --argjson worst "$_worst" --argjson essay "$_worst_essay" \
      --argjson checked "$_checked" --argjson max "$DENSITY_MAX" \
      --argjson hard "$DENSITY_HARD" --argjson block "$BLOCK_MAX" '
      {ts: $ts, actor: "hook:dv-comment-density-gate", action: "comment_density_block",
       subject: $agent, result: "blocked",
       metadata: {worst_pct: $worst, worst_essay_pct: $essay, files_checked: $checked,
                  threshold: $max, hard_threshold: $hard, block_max: $block, offenders: $off}}' \
      >>"$_log_dir/audit.jsonl" 2>/dev/null || true
  fi

  jq -n --arg reason "$_remedy" '
    {decision: "block", reason: $reason,
     hookSpecificOutput: {hookEventName: "SubagentStop", additionalContext: $reason}}'
  return 0
}

# Body lives in lib/ — test code, sourced only here and never on the dispatch
# path below. This arm fails CLOSED: a self-test that cannot find its cases must
# report a failure, never "OK".
if [ "$SELF_TEST" -eq 1 ]; then
  _selftest_body="$(dirname "$0")/lib/dv-comment-density-gate-selftest.sh"
  if [ ! -f "$_selftest_body" ]; then
    echo "dv-comment-density-gate: self-test body missing at $_selftest_body" >&2
    exit 1
  fi
  . "$_selftest_body"
fi

PAYLOAD=$(read_stdin)

# Guarded source of the shared root ladder.
_LIB="$(dirname "$0")/model-switch-lib.sh"
_CF_OPTS=$-
set +e
# shellcheck source=hooks/model-switch-lib.sh
[ -f "$_LIB" ] && . "$_LIB"
case "$_CF_OPTS" in *e*) set -e ;; esac

REPO="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$REPO" ]; then
  REPO=$(git rev-parse --show-toplevel 2>/dev/null) || REPO=""
fi
[ -n "$REPO" ] || exit 0

# Bind to the payload's /megatask issue before resolving: the inherited
# CLAUDE_PROJECT_DIR names the batch, not the issue this agent worked.
if command -v corpflow_bind_payload > /dev/null 2>&1; then
  corpflow_bind_payload "$PAYLOAD"
fi
if command -v corpflow_context_root >/dev/null 2>&1; then
  CTX=$(corpflow_context_root)
else
  # Degraded: declared roots only, requiring an existing ledger — never cwd.
  CTX=""
  if [ -n "${WORKSPACE_ROOT:-}" ] && [ -f "${WORKSPACE_ROOT}/.context/state.json" ]; then
    CTX="${WORKSPACE_ROOT}/.context"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "${CLAUDE_PROJECT_DIR}/.context/state.json" ]; then
    CTX="${CLAUDE_PROJECT_DIR}/.context"
  fi
fi
[ -n "$CTX" ] || exit 0
# A bound issue's diff lives in its own worktree, not the batch checkout.
if [ -n "${_CORPFLOW_ISSUE_ROOT:-}" ]; then
  REPO="$_CORPFLOW_ISSUE_ROOT"
fi

run_gate "$PAYLOAD" "$CTX" "$REPO"
exit 0
