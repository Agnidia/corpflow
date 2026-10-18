#!/usr/bin/env bash
# @description fn-preflight-cmds.sh — sourceable library holding every fn-preflight.sh
#   subcommand body and the four helpers they share. fn-preflight.sh keeps only the
#   documentation header (which `usage()` reads back out of its own `$0`), the sibling
#   resolution, argument parsing and dispatch.
#
#   Sourced by exactly one caller. The split is a size split, not a reuse seam: the
#   contract, the exit codes and the prose that documents them all live in
#   fn-preflight.sh, and every behaviour here is specified there.
#
#   Reads these globals from the caller, none of which it defines: STATE_PATH,
#   CONTEXT_DIR, BODY_FILE, SCRIPT_DIR, LIB_PATH, UD_PRINT. Also calls branch-lib.sh's
#   audit_fn, meta_json, fn_batch_scope, resolve_base_ref and resolve_git_ref, so the caller must
#   source that library FIRST — fn-preflight.sh's exit-3 guard is what enforces it.
#
#   Symbols: resolve_issue, sanitise_stream, VE_ACTION, ve_row_result,
#   cmd_attachments, cmd_staging, cmd_pr_body, cmd_validate_pr, cmd_continuity,
#   _continuity_stream_mode, _continuity_streams,
#   cmd_branch_divergence, cmd_issue_close_required, _bs_override_on,
#   _bs_fork_candidate, _bs_own_branch, _bs_local_fork_candidate, _bs_fork_evidence,
#   cmd_base_sanity, UD_HEADING, UD_LEAD, UD_ACTION, UD_SEP, _ud_rows,
#   _ud_question, _ud_render, _ud_scrub, _ud_splice, cmd_unresolved_decisions.
#
# Minimum shell: bash 3.2+ (macOS default).

# Anti-execution guard — MUST be the first statement. Fires only when this file is
# run directly ($0 == BASH_SOURCE[0]); a sourcing caller always has a different $0.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  printf >&2 'fn-preflight-cmds.sh: this is a library — source it, do not execute it directly\n'
  exit 2
fi

# ---------- Issue resolver (ranked, first-match-wins) ----------
# 1. state.json .metadata.github_issue_url  — trailing integer of /issues/<N>.
# 2. .context/gh-issue.json .url (trailing int) or .number — follow-up-run anchor.
# 3. state.json .metadata.github_issue_number — megatask per-issue mode.
# 4. branch parse: leading <type>/<NNN>-<slug> shape (externally-named-branch
#    fallback — the shape both branch generators actually produce), else first
#    #NNN in the last 5 commits. NOT a trailing integer: a ticket-less
#    `feature/<slug-ending-in-digit>` branch must not resolve a bogus issue number.
resolve_issue() {
  local n=""
  if command -v jq > /dev/null 2>&1; then
    n=$(jq -r '.metadata.github_issue_url // empty' "$STATE_PATH" 2> /dev/null \
      | grep -oE '[0-9]+$' || true)
    [[ -z "$n" ]] && n=$(jq -r 'if .url then .url elif .number then (.number|tostring) else empty end' \
      "${CONTEXT_DIR}/gh-issue.json" 2> /dev/null | grep -oE '[0-9]+$' || true)
    [[ -z "$n" ]] && n=$(jq -r '.metadata.github_issue_number // empty' "$STATE_PATH" 2> /dev/null || true)
  fi
  [[ -z "$n" ]] && n=$(git rev-parse --abbrev-ref HEAD 2> /dev/null \
    | sed -nE 's#^[a-zA-Z]+/([0-9]+)-.*#\1#p' || true)
  [[ -z "$n" ]] && n=$(git log --oneline -n 5 2> /dev/null | grep -oE '#[0-9]+' | head -1 | tr -d '#' || true)
  printf '%s' "$n"
}

# Parity with fn_batch_scope's shared signals is pinned by fn-preflight.bats "F14"
# and branch-lib.bats.

# ---------- sanitiser bridge ------------------------------------------------
# Reads a body on stdin, writes the sanitised body to stdout.
# The rule set is publish-pl-issue.sh's `sanitise_body`, reused verbatim — issue
# bodies and PR bodies must strip identically, and the fixture suite proves only
# that one implementation. Never reimplement or extend it here.
#
# The source happens in a subshell for three reasons: this script runs
# `set -euo pipefail` while the library is written for bare `set -u` (any non-zero
# status in its ~1600-line prologue would abort us); the library's globals stay out
# of our namespace; and its `exit`-capable `fatal`/`defer` cannot terminate the
# preflight. The dummy positional is required — the library iterates `"$@"`, which
# is an unbound-variable error on bash 3.2 when empty under `set -u`.
#
# path-scrub.sh is sourced by name so the PR path does not depend on the library's
# own sibling lookup; the second scrub pass is idempotent.
#
# Exit 97 = library unreachable or refused to source; 98 = sanitise_body or
# corpflow_path_scrub missing; other non-zero = the library stopped itself. All are
# blocking: a fail-open degrade would make a leaked path "usually" impossible.
# Batch and incident runs do reach here, but treat every status as non-blocking,
# so a broken plugin cache still cannot wedge /megatask.
sanitise_stream() {
  (
    set +e +o pipefail
    # shellcheck disable=SC1090
    PUBLISH_LIB_ONLY=1 . "$LIB_PATH" --fn-preflight > /dev/null 2>&1 || exit 97
    command -v sanitise_body > /dev/null 2>&1 || exit 98
    scrub="${SCRIPT_DIR}/../../shared/scripts/path-scrub.sh"
    [ -r "$scrub" ] || exit 98
    # shellcheck disable=SC1090
    . "$scrub" > /dev/null 2>&1
    command -v corpflow_path_scrub > /dev/null 2>&1 || exit 98
    # Set after the library prologue so an awk failure in sanitise_body fails the stream.
    set -o pipefail
    sanitise_body | corpflow_path_scrub
  )
}

# ---------- visual-evidence audit-row reader --------------------------------
VE_ACTION="visual_evidence_pr_emitted"
# $1 = worktask_id, $2 = run_index. Echoes ok|skipped, or empty when no row.
# Matching on the run's dedupe key (not the action alone) is what stops a row from
# an earlier run index satisfying the gate.
# The key grammar is emitted by attach-visual-evidence.sh `emit_pr` — keep in sync.
ve_row_result() {
  local dk="$1:$2:visual_evidence:pr" audit="${CONTEXT_DIR}/logs/audit.jsonl" r=""
  [[ -f "$audit" ]] || {
    printf ''
    return 0
  }
  if command -v jq > /dev/null 2>&1; then
    r=$(jq -r --arg a "$VE_ACTION" --arg dk "$dk" \
      'select(.action == $a) | select(.metadata.dedupe_key == $dk) | .result' \
      "$audit" 2> /dev/null | tail -1 || true)
  fi
  if [[ -z "$r" ]]; then
    # jq-less / malformed-line fallback: substring match on the same two fields.
    r=$(grep -F "\"$VE_ACTION\"" "$audit" 2> /dev/null |
      grep -F "\"dedupe_key\":\"$dk\"" |
      tail -1 | grep -oE '"result":"[a-z_]+"' | cut -d'"' -f4 || true)
  fi
  printf '%s' "$r"
}

# ---------- Commands ----------
# A file staged by an earlier stage and then edited again by a later one ships the STAGED
# bytes while every report describes the worktree: QA and DC routinely edit files FN already
# has in the index, and two of two observed runs hit it.
#
# The predicate is a set INTERSECTION of two name lists — index-vs-HEAD and worktree-vs-index
# — i.e. porcelain `XY` with X in [MARC] and Y in [MD]. A bare ` M` (unstaged only) is the
# NORMAL state of every run before FN's own `git add` and must never fire; matching it would
# block every finalization. Name lists also sidestep porcelain's rename and quoting grammar.
#
# Scoped to the cwd repository. Enumerating `git worktree list` would reach the sibling
# worktrees of a Conductor multi-workspace checkout and block this run on another worktask's
# dirt; that enumeration is a follow-up, not this check.
cmd_staging() {
  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    printf 'staging: not a git repository — nothing to check\n'
    return 0
  fi
  local staged unstaged both
  staged=$(git diff --cached --name-only 2> /dev/null || printf '')
  unstaged=$(git diff --name-only 2> /dev/null || printf '')
  if [[ -n "$staged" && -n "$unstaged" ]]; then
    both=$(printf '%s\n' "$staged" | grep -Fxf <(printf '%s\n' "$unstaged") 2> /dev/null || true)
    if [[ -n "$both" ]]; then
      printf >&2 'BLOCKED: staged then modified again — the PR would ship the staged bytes, not these:\n'
      printf >&2 '  %s\n' $both
      audit_fn staging blocked "$(meta_json files "$(printf '%s' "$both" | tr '\n' ' ')")"
      return 1
    fi
  fi

  # The index bytes are what the PR ships, so the lint reads staged blobs, not the worktree.
  local lint="${SCRIPT_DIR}/control-byte-lint.sh" out lrc=0 first
  if [[ ! -r "$lint" ]]; then
    printf >&2 'BLOCKED: control-byte-lint.sh unreachable at %s — plugin install broken\n' "$lint"
    audit_fn staging blocked "$(meta_json reason control_byte_lint_unavailable lib "$lint")"
    return 3
  fi
  out=$(bash "$lint" --staged 2>&1) || lrc=$?
  case "$lrc" in
    0) ;;
    1)
      printf >&2 'BLOCKED: control bytes in staged files — the PR would ship them:\n'
      printf '%s\n' "$out" | grep -v '^control-byte-lint: ' | sed 's/^/  /' >&2
      audit_fn staging blocked "$(meta_json files "$(printf '%s\n' "$out" | grep -v '^control-byte-lint: ' \
        | sed 's/:[0-9]*:0x[0-9A-F][0-9A-F]$//' | LC_ALL=C sort -u | tr '\n' ' ')")"
      return 1
      ;;
    *)
      first=$(printf '%s\n' "$out" | grep -m1 '^control-byte-lint: ' || printf '%s' "${out%%$'\n'*}")
      printf >&2 'BLOCKED: staged control-byte check could not run: %s\n' "$first"
      audit_fn staging blocked "$(meta_json reason control_byte_check_failed detail "$first")"
      return 1
      ;;
  esac
  printf 'staging: no file is both staged and modified again\n'
  return 0
}

cmd_attachments() {
  local pr="${CONTEXT_DIR}/attachments/PR instructions.md"
  local rr="${CONTEXT_DIR}/attachments/Review request.md"
  if [[ -f "$pr" && -f "$rr" ]]; then
    printf 'attachments: both present\n'
    return 0
  fi
  printf >&2 'BLOCKED: missing Conductor attachment(s):%s%s\n' \
    "$([[ -f "$pr" ]] || printf ' "PR instructions.md"')" \
    "$([[ -f "$rr" ]] || printf ' "Review request.md"')"
  return 1
}

cmd_pr_body() {
  [[ -n "$BODY_FILE" && -f "$BODY_FILE" ]] || {
    printf >&2 'pr-body requires --body <path> to an existing file\n'
    exit 2
  }
  # Batch (/megatask) and incident (--emergency) routing is exempt from this
  # command's BLOCKING checks, never from sanitisation — a working-folder path
  # must not reach a published body on any route. The exemption exists so an
  # unreachable sanitiser library cannot wedge those pipelines, so for them the
  # strip below degrades to a warning rather than returning 1.
  local batch=0
  if fn_batch_scope; then batch=1; fi

  local ri before after tmp rc=0
  ri=$(jq -r '.run_index // 0' "$STATE_PATH" 2> /dev/null || printf '0')
  before=$(wc -l < "$BODY_FILE" | tr -d ' ')
  tmp="${BODY_FILE}.sanitised.$$"
  sanitise_stream < "$BODY_FILE" > "$tmp" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmp"
    if [[ "$batch" == 1 ]]; then
      printf >&2 'warn: PR-body sanitiser unavailable (rc=%s), not blocking under %s: %s\n' \
        "$rc" "$SCOPE_REASON" "$LIB_PATH"
      audit_fn pr_body_gate skipped \
        "$(meta_json reason sanitiser_unavailable scope "$SCOPE_REASON" lib "$LIB_PATH")"
      return 0
    fi
    printf >&2 'BLOCKED: PR-body sanitiser unavailable (rc=%s): %s\n' "$rc" "$LIB_PATH"
    audit_fn pr_body_gate blocked "$(meta_json reason sanitiser_unavailable lib "$LIB_PATH")"
    return 1
  fi
  if cmp -s "$tmp" "$BODY_FILE"; then
    rm -f "$tmp"
    audit_fn pr_body_sanitised unchanged "$(meta_json lines "$before")"
  else
    # Snapshot before overwriting: the strip rules are deliberately blunt, and a
    # reviewer needs the pre-sanitise text to judge an over-strip. Mirrors the
    # issue-body-<n>.aborted.tmp precedent in publish-pl-issue.sh.
    mkdir -p "${CONTEXT_DIR}/logs" 2> /dev/null || true
    cp "$BODY_FILE" "${CONTEXT_DIR}/logs/pr-body-${ri}.presanitise.md" 2> /dev/null || true
    mv -f "$tmp" "$BODY_FILE"
    after=$(wc -l < "$BODY_FILE" | tr -d ' ')
    printf 'pr-body: sanitised (%s -> %s lines)\n' "$before" "$after"
    audit_fn pr_body_sanitised ok "$(meta_json lines_before "$before" lines_after "$after" \
      snapshot "${CONTEXT_DIR}/logs/pr-body-${ri}.presanitise.md")"
  fi

  # Read back what the sanitiser actually produced. Sanitising without inspecting
  # the result is how a body that lost every image and kept a dead local path was
  # audited "ok". Runs here, after the rewrite, so it lints the byte-identical
  # body that reaches `gh pr create`. Warn-only by default. Under strict, a lint that
  # fails, errors or cannot run blocks, so a missing checker cannot pass the gate.
  # Batch and incident routes never block.
  local lint_rc=0 lint_reason=""
  if [ -x "${SCRIPT_DIR}/pr-body-lint.sh" ]; then
    bash "${SCRIPT_DIR}/pr-body-lint.sh" --body "$BODY_FILE" --state "$STATE_PATH" \
      --context "$CONTEXT_DIR" || lint_rc=$?
    case "$lint_rc" in
      0) ;;
      1) lint_reason="pr_body_lint_findings" ;;
      *) lint_reason="pr_body_lint_error" ;;
    esac
  else
    lint_reason="pr_body_lint_unavailable"
  fi
  if [[ "${CORPFLOW_PR_BODY_STRICT:-0}" == "1" && "$batch" != 1 && -n "$lint_reason" ]]; then
    printf >&2 'BLOCKED: pr-body-lint did not pass under --strict (%s, rc=%s): %s\n' \
      "$lint_reason" "$lint_rc" "${SCRIPT_DIR}/pr-body-lint.sh"
    audit_fn pr_body_gate blocked "$(meta_json reason "$lint_reason" lint_rc "$lint_rc")"
    return 1
  fi

  # Composition requirements below are worktask-FN contracts; batch and incident
  # runs compose their bodies elsewhere and only needed the strip above.
  if [[ "$batch" == 1 ]]; then
    printf 'pr-body: sanitised; composition gate skipped (%s)\n' "$SCOPE_REASON"
    audit_fn pr_body_gate skipped "$(meta_json reason "$SCOPE_REASON")"
    return 0
  fi

  # Checked AFTER sanitising, so a heading the sanitiser removed reports as missing
  # — one diagnostic instead of two rules disagreeing about the same body.
  if ! grep -E -i -q '^#{1,6}[[:space:]]+Test plan[[:space:]]*$' "$BODY_FILE"; then
    printf >&2 'BLOCKED: PR body has no "## Test plan" heading (hand-authored body?)\n'
    audit_fn pr_body_gate blocked "$(meta_json reason missing_test_plan_heading)"
    return 1
  fi

  # Visual evidence, keyed on the audit row first: only the row proves the helper
  # ran THIS run, and only the heading proves its stdout reached the body. A row
  # reporting `skipped` legitimately produced nothing, so no heading is required.
  # Default mirrors attach-visual-evidence.sh state_requires_screenshots: absent
  # metadata means true.
  local req wid vres
  req=$(jq -r 'if (.metadata|type=="object") and (.metadata|has("requires_screenshots"))
               then (.metadata.requires_screenshots|tostring) else "true" end' \
    "$STATE_PATH" 2> /dev/null || printf 'true')
  if [[ "$req" != "false" ]]; then
    wid=$(jq -r '.worktask_id // "unknown"' "$STATE_PATH" 2> /dev/null || printf 'unknown')
    vres=$(ve_row_result "$wid" "$ri")
    if [[ -z "$vres" ]]; then
      printf >&2 'BLOCKED: no %s audit row for %s:%s — run attach-visual-evidence.sh --emit pr\n' \
        "$VE_ACTION" "$wid" "$ri"
      audit_fn pr_body_gate blocked "$(meta_json reason missing_visual_evidence_row)"
      return 1
    fi
    # "reused" is an idempotent replay of an earlier "ok" — same block on stdout, so
    # it carries the same obligation. ve_row_result returns the LAST row, so omitting
    # it would let a second --emit run silently retire the heading requirement.
    if [[ "$vres" == "ok" || "$vres" == "reused" ]] &&
      ! grep -E -i -q '^#{1,6}[[:space:]]+Visual evidence[[:space:]]*$' "$BODY_FILE"; then
      printf >&2 'BLOCKED: %s reported result=ok but the body has no "## Visual evidence" section\n' \
        "$VE_ACTION"
      audit_fn pr_body_gate blocked "$(meta_json reason missing_visual_evidence_section)"
      return 1
    fi
  fi

  printf 'pr-body: composition gate passed\n'
  audit_fn pr_body_gate ok "$(meta_json requires_screenshots "$req")"
  return 0
}

cmd_validate_pr() {
  [[ -n "$BODY_FILE" && -f "$BODY_FILE" ]] || {
    printf >&2 'validate-pr requires --body <path> to an existing file\n'
    exit 2
  }
  local issue_n
  issue_n=$(resolve_issue)

  if [[ -n "$issue_n" ]]; then
    if grep -E -i -q "^(Closes|Fixes|Resolves)[[:space:]]+#${issue_n}[[:space:]]*$" "$BODY_FILE"; then
      printf 'validate-pr: body closes #%s\n' "$issue_n"
      return 0
    fi
    printf >&2 'BLOCKED: PR body missing "Closes #%s" (resolved issue)\n' "$issue_n"
    return 1
  fi

  # No issue resolvable → audit-defer row, proceed WITHOUT a closing line.
  audit_fn pr_issue_link deferred "$(meta_json reason no_issue_resolved)"
  printf 'validate-pr: no issue resolved — audit-deferred, proceeding without closing line\n'
  return 0
}

# Multi-stream finalization records >=2 stream branches; a single-stream ledger never
# does, so the legacy path below stays byte-for-byte what it was for every other run.
_continuity_stream_mode() {
  command -v jq > /dev/null 2>&1 || return 1
  jq -e '(.facts.stream_branches | type) == "object"
         and (.facts.stream_branches | length) >= 2' "$STATE_PATH" > /dev/null 2>&1
}

# Every stream branch must be an ancestor of HEAD (the combined branch). A missing stream
# is silent loss in the PR, so any unmerged stream exits 1 — after all are checked, so one
# run names every gap.
_continuity_streams() {
  local head rows s b unmerged=0
  head=$(git rev-parse --verify --quiet HEAD 2> /dev/null || printf '')
  rows=$(jq -r '.facts.stream_branches | to_entries[] | [.key, (.value | tostring)] | @tsv' \
    "$STATE_PATH" 2> /dev/null || printf '')
  while IFS=$'\t' read -r s b; do
    [[ -n "$s" ]] || continue
    if [[ -n "$head" && -n "$b" ]] &&
       git rev-parse --verify --quiet "refs/heads/${b}^{commit}" > /dev/null 2>&1 &&
       git merge-base --is-ancestor "refs/heads/${b}" "$head" 2> /dev/null; then
      printf 'continuity: stream %s branch %s is merged into HEAD\n' "$s" "$b"
      audit_fn branch_continuity stream_merged "$(meta_json stream "$s" branch "$b" head "$head")"
    else
      printf >&2 'BLOCKED: stream %s branch %s is not an ancestor of HEAD — its work would be missing from the PR\n' \
        "$s" "$b"
      audit_fn branch_continuity stream_unmerged "$(meta_json stream "$s" branch "$b" head "$head")"
      unmerged=1
    fi
  done <<< "$rows"
  [[ "$unmerged" -eq 0 ]] || return 1
  printf 'continuity: every stream branch is merged into HEAD\n'
  return 0
}

cmd_continuity() {
  local wt_head int_branch ref
  if _continuity_stream_mode; then
    _continuity_streams || return $?
    return 0
  fi
  wt_head=$(git rev-parse HEAD 2> /dev/null || printf '')
  int_branch=$(resolve_base_ref)
  if [[ -z "$int_branch" ]]; then
    printf >&2 'continuity: integration branch unresolvable (no metadata.base_ref, no workspace.json .git.base_branch, no origin/HEAD) — ancestor check skipped\n'
    audit_fn branch_continuity base_ref_unresolved "$(meta_json worktree_head "$wt_head")"
    return 0
  fi
  ref=$(resolve_git_ref "$int_branch" || printf '')
  if [[ -z "$ref" ]]; then
    printf >&2 'continuity: integration branch %s not present locally — ancestor check skipped\n' "$int_branch"
    audit_fn branch_continuity base_ref_unresolvable "$(meta_json integration_branch "$int_branch")"
    return 0
  fi

  # The printed name stays the resolved NAME, not the git ref it mapped to: that is
  # what an operator recognises, and what the existing contract test asserts.
  # Base-into-HEAD: a feature branch is ahead of its base by design, and only commits the
  # base holds that HEAD lacks make the merge more than a fast-forward (`diverged`).
  if [[ -n "$wt_head" ]] && git merge-base --is-ancestor "$ref" "$wt_head" 2> /dev/null; then
    printf 'continuity: %s is an ancestor of worktree HEAD (fast-forward safe)\n' "$int_branch"
    return 0
  fi

  printf >&2 'worktree branch diverged — falling back to cherry-pick; verify commits are complete.\n'
  local ts n
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  n=$(git rev-list --count "${ref}..${wt_head}" 2> /dev/null || printf '0')
  # --argjson below refuses anything that is not a JSON literal, and losing the whole
  # row to an unexpected count would be worse than reporting an honest zero.
  case "$n" in '' | *[!0-9]*) n=0 ;; esac
  mkdir -p "${CONTEXT_DIR}/logs" 2> /dev/null || true
  # Refuse a symlinked audit.jsonl: following it makes this append a write primitive
  # against an arbitrary target. A lost row never blocks the caller.
  if [ ! -L "${CONTEXT_DIR}/logs/audit.jsonl" ]; then
    # Built with jq, not printf: `git check-ref-format` accepts a double quote in a
    # refname, so a printf template interpolating $int_branch emits a line that no
    # later reader of audit.jsonl can parse. The row shape stays hand-written rather
    # than routed through audit_fn/meta_json because this row's contract is a bare
    # key set (no task_id/origin_stage/dedupe_key) and a NUMERIC commit_count.
    if command -v jq > /dev/null 2>&1; then
      if ! jq -cn --arg ts "$ts" --arg head "$wt_head" --arg branch "$int_branch" \
        --argjson n "$n" \
        '{ts: $ts, actor: "project-manager", action: "branch_continuity",
          subject: "FN0", result: "diverged_cherry_pick",
          metadata: {worktree_head: $head, integration_branch: $branch, commit_count: $n}}' \
        >> "${CONTEXT_DIR}/logs/audit.jsonl" 2> /dev/null; then
        printf >&2 'continuity: audit row NOT recorded (sink unwritable) — divergence still reported above\n'
      fi
    else
      printf >&2 'continuity: jq unavailable — divergence audit row skipped (diagnostic above stands)\n'
    fi
  fi
  return 0 # diverged is a documented fallback, not a hard block
}

# Has anything outside this pipeline renamed the local branch since the naming step?
#
# The comparison base is the `to` of the most recent `branch_renamed / ok` row, NOT
# `facts.branch`. That distinction is what makes the check useful: `facts.branch` is the
# PLANNED REMOTE name and is legitimately different from the local name on several arms, so
# comparing against it fires on every worktree run and gets ignored. It also makes R4
# structurally unable to trip this — R4 rewrites `facts.branch` and never touches git, so a
# refinement cannot look like an external rename.
#
# Read-only, exit 0 always, at most one row, never blocks: divergence is a legitimate
# designed state on the opt-out, upstream_tracked, target_exists and jq_unavailable arms.
cmd_branch_divergence() {
  local log="${CONTEXT_DIR}/logs/audit.jsonl" local_name ledger renamed_to class
  local_name=$(git rev-parse --abbrev-ref HEAD 2> /dev/null || printf '')
  if [[ "$local_name" == "HEAD" ]]; then local_name=""; fi

  if ! command -v jq > /dev/null 2>&1; then
    printf 'branch-divergence: jq unavailable — check skipped\n'
    return 0
  fi
  ledger=$(jq -r '.facts.branch // ""' "$STATE_PATH" 2> /dev/null || printf '')
  [[ "$ledger" == "null" ]] && ledger=""

  renamed_to=""
  if [[ -f "$log" ]]; then
    # `fromjson? | objects` — the first survives an unparsable line, the second a
    # well-formed NON-object one (`123`, `[1,2]`), which would otherwise abort the scan on
    # `.action` and silently suppress detection of a real third-party rename.
    # `last` takes the most recent ok row, so a re-run's row wins over an earlier one.
    renamed_to=$(jq -rs -R \
      '[ split("\n")[] | fromjson? | objects
         | select(.action == "branch_renamed" and .result == "ok") | .metadata.to ]
       | (last // "")' "$log" 2> /dev/null) || renamed_to=""
  fi

  # third_party requires an ok row to compare against; everything else is a designed
  # divergence (or none at all) and stays an audit row only.
  if [[ -n "$renamed_to" ]] && [[ -n "$local_name" ]] && [[ "$local_name" != "$renamed_to" ]]; then
    class="third_party"
  else
    class="expected"
  fi

  audit_fn branch_divergence_detected warn \
    "$(meta_json class "$class" ledger "$ledger" local "$local_name" \
      renamed_to "$renamed_to" source fn_preflight)"

  if [[ "$class" == "third_party" ]]; then
    printf 'branch-divergence: local branch is %s but this run renamed it to %s — renamed by something outside the pipeline\n' \
      "$local_name" "$renamed_to"
  else
    printf 'branch-divergence: no external rename detected (class=expected)\n'
  fi
  return 0
}

# ---------- issue-close-required ----------
# GitHub only honours a `Closes #N` trailer when the PR merges into the DEFAULT branch.
# Merging into any other integration branch leaves the issue open with no signal at all,
# so the issue has to be closed explicitly. Read-only: it prints the command, never runs
# it. FN opens the PR without merging it, so FN records the close and whoever merges runs
# this again post-merge (skills/megatask/SKILL.md § Post-merge settle).
#
# Unresolved base_ref or issue ⇒ report and return 0. A finalization gate that blocks on
# its own inability to introspect is worse than the open issue it is guarding against.
cmd_issue_close_required() {
  local base default_branch issue

  if ! command -v jq > /dev/null 2>&1; then
    printf 'issue-close-required: jq unavailable — check skipped\n'
    return 0
  fi

  base=$(resolve_base_ref)
  base="${base#origin/}"
  if [[ -z "$base" ]]; then
    audit_fn issue_close_required base_ref_unresolved "$(meta_json reason unresolved)"
    printf 'issue-close-required: integration branch unresolved — reporting, not guessing; verify the issue manually\n'
    return 0
  fi

  default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2> /dev/null || printf '')
  default_branch="${default_branch#origin/}"
  if [[ -z "$default_branch" ]]; then
    audit_fn issue_close_required default_branch_unresolved "$(meta_json base "$base")"
    printf 'issue-close-required: repository default branch unresolved — reporting, not guessing; verify the issue manually\n'
    return 0
  fi

  if [[ "$base" == "$default_branch" ]]; then
    audit_fn issue_close_required not_required \
      "$(meta_json base "$base" default_branch "$default_branch")"
    printf 'issue-close-required: no (integration branch %s IS the repository default — the merge trailer fires)\n' "$base"
    return 0
  fi

  issue=$(resolve_issue)
  if [[ -z "$issue" ]]; then
    audit_fn issue_close_required issue_unresolved \
      "$(meta_json base "$base" default_branch "$default_branch")"
    printf 'issue-close-required: yes, but no issue number resolved (integration branch %s is not the default %s).\nNo command can be printed — find the issue and close it manually.\n' \
      "$base" "$default_branch"
    return 0
  fi

  audit_fn issue_close_required required \
    "$(meta_json base "$base" default_branch "$default_branch" issue "$issue")"
  printf 'issue-close-required: yes — %s is not the repository default (%s), so the merge trailer will NOT fire.\nRun after the merge:\n  gh issue close %s --comment "Merged into %s."\n' \
    "$base" "$default_branch" "$issue" "$base"
  return 0
}

# ---------- base-sanity ----------
# The magnitude question no other check asks: does the diff a PR against the
# resolved base would carry resemble what this run says it changed? A branch
# stacked on another feature branch, opened against the shared integration
# branch, silently carries the whole intervening branch — 1008 files where the
# run itself recorded 27. Ancestry (`continuity`) cannot see that: a stacked branch
# still contains its base, so the ancestor test passes. Magnitude can.
#
# The thresholds are WRONG-BASE heuristics, not diff-quality rules. The
# multiplier alone would trip a 3-file run that legitimately touched 9; the
# 20-file floor alone would trip any large-but-correct run. Only the conjunction
# describes the shape of a wrong base, which is why neither half may be tuned or
# relaxed on its own.

# Forgiving on purpose: an escape hatch that silently fails to engage on
# `=true` is a worse footgun than a loose parse. bash 3.2 has no ${v,,}.
_bs_override_on() {
  case "${FN_BASE_SANITY_OVERRIDE:-}" in
    '' | 0 | [Ff][Aa][Ll][Ss][Ee] | [Nn][Oo]) return 1 ;;
    *) return 0 ;;
  esac
}

# Fork-point evidence is optional here BY DESIGN: base-sanity blocks correctly
# without it, so an install lacking the Change-B helper degrades the candidate
# line to `unavailable` rather than losing the block.
_bs_fork_candidate() {
  local configured="$1" f=""
  command -v fork_base > /dev/null 2>&1 || {
    printf 'unavailable'
    return 0
  }
  f=$(fork_base "$configured" 2> /dev/null || printf '')
  [ -n "$f" ] || f="unavailable"
  printf '%s' "$f"
}

# Does $1 name HEAD's own branch (its short name, or its upstream without the remote)?
# A stale `origin/<own-branch>` from an earlier push has the smallest ahead-count of all,
# so on a fix-in-PR re-run it would become the fork candidate and cap the ledger falsely.
# An upstream that is the branch's own start point is the parent, not a push of this
# branch: a worktree created from `origin/<parent>` tracks it, and discarding it would
# lose the one piece of evidence that names the real parent.
_bs_own_branch() {
  local c="$1" head up start
  head=$(git rev-parse --abbrev-ref HEAD 2> /dev/null || printf '')
  if [[ -n "$head" && "$head" != "HEAD" && "$c" == "$head" ]]; then return 0; fi
  up=$(git rev-parse --verify --quiet --abbrev-ref '@{upstream}' 2> /dev/null || printf '')
  if [[ -z "$up" || "$c" != "${up#*/}" ]]; then return 1; fi
  # The oldest reflog entry of the branch records its start point. No reflog keeps the
  # upstream treated as own: a lost parent only removes the cap, a false parent adds a block.
  start=$(git reflog show --format=%gs "refs/heads/${head}" 2> /dev/null | tail -n 1 || printf '')
  start="${start#branch: Created from }"
  start="${start#refs/remotes/}"
  if [[ -n "$start" && "$start" == "$up" ]]; then return 1; fi
  return 0
}

# fork_base enumerates refs/remotes/origin only, so an unpushed parent is invisible to it.
# A local branch counts when HEAD descends from it more closely than from the base
# (0 < ahead < $2); lowest ahead wins, then byte order. Prints "<ahead> <name>" or nothing.
_bs_local_fork_candidate() {
  local base_bare="$1" limit="$2" head name n rows="" sorted
  head=$(git rev-parse --abbrev-ref HEAD 2> /dev/null || printf '')
  while IFS= read -r name; do
    name="${name#refs/heads/}"
    [[ -n "$name" ]] || continue
    if [[ "$name" == "$head" || "$name" == "$base_bare" ]]; then continue; fi
    n=$(git rev-list --count "refs/heads/${name}..HEAD" 2> /dev/null) || continue
    case "$n" in '' | *[!0-9]*) continue ;; esac
    if [[ "$n" -gt 0 && "$n" -lt "$limit" ]]; then rows="${rows}${n} ${name}"$'\n'; fi
  done <<< "$(git for-each-ref --format='%(refname)' refs/heads 2> /dev/null || printf '')"
  [[ -n "$rows" ]] || return 0
  # Captured, not piped into `head -1`: an early-exit consumer can SIGPIPE sort under pipefail.
  sorted=$(printf '%s' "$rows" | LC_ALL=C sort -k1,1n -k2,2)
  printf '%s' "${sorted%%$'\n'*}"
}

# Fork evidence for base $1 with HEAD $2 commits ahead of it. Sets BS_FORK_NAME,
# BS_FORK_REF, BS_FORK_SOURCE (remote|local|none), BS_FORK_REL (same|distinct|none),
# BS_FORK_AHEAD and BS_OWN_BRANCH. Always returns 0: it is called bare under errexit, and
# globals because a `$(…)` capture would discard them.
# `distinct` = HEAD forked from something other than the base, so the files committed since
# that candidate are an independent measure of this run's footprint. A local candidate is
# tried before declaring `same`: otherwise a remote base that matches would pass a branch
# stacked on an unpushed parent.
_bs_fork_evidence() {
  local base_bare="${1#origin/}" limit="$2" f fref="" hit=""
  BS_FORK_NAME="unavailable" BS_FORK_REF="" BS_FORK_SOURCE="none" BS_FORK_REL="none"
  BS_FORK_AHEAD="" BS_OWN_BRANCH=""
  f=$(_bs_fork_candidate "$1")
  if [[ "$f" != "unavailable" && "${f#origin/}" != "$base_bare" ]] && _bs_own_branch "${f#origin/}"; then
    BS_OWN_BRANCH="$f"
    f="unavailable"
  fi
  if [[ "$f" != "unavailable" && "${f#origin/}" != "$base_bare" ]]; then
    fref=$(resolve_git_ref "$f" || printf '')
    if [[ -n "$fref" ]]; then
      BS_FORK_NAME="$f" BS_FORK_REF="$fref" BS_FORK_SOURCE="remote" BS_FORK_REL="distinct"
      BS_FORK_AHEAD=$(git rev-list --count "${fref}..HEAD" 2> /dev/null || printf '')
      return 0
    fi
  fi
  hit=$(_bs_local_fork_candidate "$base_bare" "$limit")
  if [[ -n "$hit" ]]; then
    BS_FORK_AHEAD="${hit%% *}" BS_FORK_NAME="${hit#* }"
    BS_FORK_REF="refs/heads/${BS_FORK_NAME}" BS_FORK_SOURCE="local" BS_FORK_REL="distinct"
    return 0
  fi
  if [[ "$f" != "unavailable" ]]; then
    BS_FORK_NAME="$f" BS_FORK_SOURCE="remote"
    if [[ "${f#origin/}" == "$base_bare" ]]; then BS_FORK_REL="same"; fi
  fi
  return 0
}

cmd_base_sanity() {
  local base ref src ahead pr_files ledger_files meta diff_out

  # Degrade ladder, evaluated BEFORE the rule and ordered most-fundamental first.
  # Each rung warns and exits 0: a blocking gate that fires on its own inability
  # to introspect is worse than the wrong base it guards against, and every rung
  # carries its own result token so a wrong-rung regression stays visible.
  if ! command -v jq > /dev/null 2>&1; then
    printf 'base-sanity: jq unavailable — check skipped\n'
    audit_fn base_sanity jq_unavailable "$(meta_json reason jq_unavailable)"
    return 0
  fi

  if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    printf 'base-sanity: not inside a git work tree — check skipped\n'
    audit_fn base_sanity no_git "$(meta_json reason no_git)"
    return 0
  fi

  # --with-fork-point: this is the one caller that can tell an inferred base from a
  # configured one (rung 5 below), so it is the one caller that may accept one.
  base=$(resolve_base_ref --with-fork-point)
  if [[ -z "$base" ]]; then
    printf 'base-sanity: integration branch unresolved — reporting, not guessing; verify the PR base manually\n'
    audit_fn base_sanity base_ref_unresolved "$(meta_json reason unresolved)"
    return 0
  fi

  # Via resolve_git_ref, never a literal `origin/$base`: the stored value may
  # already be remote-qualified, and a local-only clone has no remote at all.
  ref=$(resolve_git_ref "$base" || printf '')
  if [[ -z "$ref" ]]; then
    printf 'base-sanity: integration branch %s not present locally — magnitude comparison skipped\n' "$base"
    audit_fn base_sanity base_ref_unresolvable "$(meta_json base "$base")"
    return 0
  fi

  src=""
  if command -v base_ref_source > /dev/null 2>&1; then
    src=$(base_ref_source --with-fork-point 2> /dev/null || printf '')
  fi
  if [[ "$src" == "fork_point" ]]; then
    printf 'base-sanity: base %s is itself fork-point evidence rather than a configured target — blocking on a guess would be a false block; skipped\n' "$base"
    audit_fn base_sanity base_guessed "$(meta_json base "$base" base_source "$src")"
    return 0
  fi

  ledger_files=$(jq -r 'if (.facts.files_modified | type) == "array"
                        then (.facts.files_modified | length) else 0 end' \
    "$STATE_PATH" 2> /dev/null || printf '0')
  case "$ledger_files" in '' | *[!0-9]*) ledger_files=0 ;; esac
  # Cannot be folded into the rule: at ledger_files == 0 the multiplier clause is
  # satisfied by any non-empty diff, so the rule would degenerate to "every PR
  # touching 21+ files fails".
  if [[ "$ledger_files" -eq 0 ]]; then
    printf 'base-sanity: this run records no modified files — nothing to compare the PR diff against; skipped\n'
    audit_fn base_sanity ledger_unavailable "$(meta_json base "$base")"
    return 0
  fi

  ahead=$(git rev-list --count "${ref}..HEAD" 2> /dev/null || printf '0')
  case "$ahead" in '' | *[!0-9]*) ahead=0 ;; esac

  # Ninth degrade rung, evaluated before the eighth: a merge payload makes every
  # denominator unreliable, and its local stream branches would otherwise be taken as
  # fork evidence below. Under fan-out the payload is a MERGE of independently-staged
  # streams, and `facts.files_modified` is never their union: each stream records what it
  # knows, none records the assembly. So the denominator is incomplete BY CONSTRUCTION, not
  # by under-recording, and the rule blocks on every fan-out — observed at 140 PR files
  # against 19 ledger files, cleared only with the sanctioned override, which is a gate
  # teaching its own operators to bypass it.
  #
  # A merge parent is the mechanical signal: a single-stream payload has none. Same
  # direction as every rung above — an input the rule cannot trust degrades to a warn, and
  # a wrong base still shows up in `continuity`, which does not depend on this denominator.
  local merge_parents=0
  merge_parents=$(git rev-list --merges --count "${ref}..HEAD" 2> /dev/null || printf '0')
  case "$merge_parents" in '' | *[!0-9]*) merge_parents=0 ;; esac
  if [[ "$merge_parents" -gt 0 ]]; then
    printf 'base-sanity: this payload has %s merge commit(s) — facts.files_modified cannot be the union of independently-staged streams, so the magnitude comparison is unreliable; skipped
' \
      "$merge_parents"
    audit_fn base_sanity multi_parent_payload \
      "$(meta_json base "$base" ledger_files "$ledger_files" merge_parents "$merge_parents")"
    return 0
  fi

  # Eighth degrade rung. facts.files_modified is this rule's denominator and is known to
  # under-record — 18 recorded against 33 dirty in this release's own run. When the working
  # tree shows a gap of the same magnitude the rule itself treats as significant, the
  # denominator is demonstrably incomplete, and a block computed from it is a false block on a
  # correct base. Warn instead, like every other rung that cannot trust its inputs. A wrong
  # base does not dirty the working tree, so this cannot mask the topology being checked.
  local tree_files land_script land_out untracked_landed tree_top
  # Enumerated file-level, not the porcelain default's collapsed `?? dir/` — a
  # landed file can sit one level inside a new directory, and the collapsed
  # form would hide it from the subtraction below.
  tree_files=$(git status --porcelain --untracked-files=all 2> /dev/null | awk 'END{print NR + 0}')
  case "$tree_files" in '' | *[!0-9]*) tree_files=0 ;; esac
  # A landed file is the producer's to ship, not evidence the consumer
  # introduced drift, so it is dropped from the denominator — but only from
  # the untracked half; a staged landed path stays visible. A missing or
  # failing land-artifacts.sh, or an unresolvable toplevel, leaves the count
  # unchanged: the set is scoped to this tree, never the global union.
  land_script="${SCRIPT_DIR}/land-artifacts.sh"
  land_out=""
  tree_top=$(git rev-parse --show-toplevel 2> /dev/null || printf '')
  if [ -r "$land_script" ] && [ -n "$tree_top" ]; then
    land_out=$(bash "$land_script" --list-landed --tree "$tree_top" --state "$STATE_PATH" 2> /dev/null || printf '')
  fi
  if [[ -n "$land_out" ]]; then
    # grep -f exits 1 on no match; under errexit that would abort this whole
    # preflight run rather than degrade to "nothing subtracted".
    untracked_landed=$(git status --porcelain --untracked-files=all 2> /dev/null \
      | awk '/^\?\? /{print substr($0, 4)}' \
      | { grep -F -x -f <(printf '%s\n' "$land_out") || true; } \
      | awk 'END{print NR + 0}')
    case "$untracked_landed" in '' | *[!0-9]*) untracked_landed=0 ;; esac
    tree_files=$((tree_files - untracked_landed))
    [[ "$tree_files" -lt 0 ]] && tree_files=0
  fi

  # Committed files count only from a fork candidate that is NOT the base. Measured from
  # the base they would equal the PR diff, so the rung would fire on every wrong base.
  local committed_files="" fork_diff="" fork_diff_out evidence_files
  _bs_fork_evidence "$base" "$ahead"
  if [[ "$BS_FORK_REL" == "distinct" ]]; then
    # Captured, then counted, for the same reason as the PR diff below.
    if fork_diff_out=$(git diff --name-only "${BS_FORK_REF}...HEAD" 2> /dev/null); then
      committed_files=0
      if [[ -n "$fork_diff_out" ]]; then
        committed_files=$(printf '%s\n' "$fork_diff_out" | wc -l | tr -d ' ')
      fi
    else
      BS_FORK_REL="none"
      fork_diff="unreadable"
    fi
  fi
  evidence_files="$tree_files"
  if [[ "$BS_FORK_REL" == "distinct" ]]; then evidence_files=$((committed_files + tree_files)); fi

  if [[ "$evidence_files" -gt $((ledger_files * 3)) ]] && [[ $((evidence_files - ledger_files)) -gt 20 ]]; then
    if [[ "$BS_FORK_REL" == "distinct" ]]; then
      printf 'base-sanity: the ledger records %s modified files but git shows %s (%s committed since fork candidate %s, %s in the working tree) — the denominator is incomplete, so the magnitude comparison is unreliable; skipped\n' \
        "$ledger_files" "$evidence_files" "$committed_files" "$BS_FORK_NAME" "$tree_files"
    else
      printf 'base-sanity: the ledger records %s modified files but the working tree shows %s — the denominator is incomplete, so the magnitude comparison is unreliable; skipped\n' \
        "$ledger_files" "$tree_files"
    fi
    audit_fn base_sanity ledger_under_recording \
      "$(meta_json base "$base" ledger_files "$ledger_files" tree_files "$tree_files" \
        committed_files "$committed_files" fork_candidate "$BS_FORK_NAME" fork_source "$BS_FORK_SOURCE")"
    return 0
  fi

  # Captured, then counted — never `git diff | wc -l`: `wc` has already written `0`
  # by the time git fails, so the pipeline yields a plausible zero-file count and the
  # only trace of the failure is an exit status the pipeline then hides. A base sharing
  # no merge base with HEAD (git exit 128) is exactly that case, and it is the wrong-base
  # topology this check exists to catch.
  if ! diff_out=$(git diff --name-only "${ref}...HEAD" 2> /dev/null); then
    printf 'base-sanity: the diff against %s is unreadable — magnitude comparison skipped\n' "$base"
    audit_fn base_sanity diff_unreadable "$(meta_json base "$base" ledger_files "$ledger_files")"
    return 0
  fi
  # Guarded because an empty diff is one empty line to `wc`, not zero lines.
  pr_files=0
  if [[ -n "$diff_out" ]]; then
    pr_files=$(printf '%s\n' "$diff_out" | wc -l | tr -d ' ')
  fi

  # The ledger is capped by git evidence. Once DV fills files_modified from the branch
  # diff, the ledger is about the PR file count against the same base, so a rule reading
  # only the ledger could never fire on a wrong base again. Under `distinct`, the files
  # committed since the real parent are the independent count. No committed file is no cap:
  # a candidate that already holds all of HEAD's committed work says nothing about its
  # footprint, and the dirty count alone would then stand in for it.
  local denominator="$ledger_files" capped=0
  if [[ "$BS_FORK_REL" == "distinct" && "${committed_files:-0}" -gt 0 && "$evidence_files" -lt "$ledger_files" ]]; then
    denominator="$evidence_files"
    capped=1
  fi

  meta=$(meta_json base "$base" pr_files "$pr_files" ledger_files "$ledger_files" \
    ahead "$ahead" fork_candidate "$BS_FORK_NAME" base_source "${src:-unknown}" \
    fork_relation "$BS_FORK_REL" fork_source "$BS_FORK_SOURCE" committed_files "$committed_files" \
    tree_files "$tree_files" denominator "$denominator" own_branch_candidate "$BS_OWN_BRANCH" \
    fork_diff "$fork_diff")

  if [[ "$pr_files" -gt $((denominator * 3)) ]] && [[ $((pr_files - denominator)) -gt 20 ]]; then
    # HEAD forked from the base itself, so a gap this size is the ledger under-recording,
    # not the wrong-base topology the rule describes. Warned and audited, never blocked.
    if [[ "$BS_FORK_REL" == "same" ]]; then
      printf 'base-sanity: WARNING — a PR against %s would carry %s files; this run'"'"'s ledger records %s, but the fork candidate %s IS the base, so the gap is an incomplete ledger, not a wrong base; not blocking\n' \
        "$base" "$pr_files" "$ledger_files" "$BS_FORK_NAME"
      audit_fn base_sanity fork_confirms_base "$meta"
      return 0
    fi

    local candidate_line
    # The remote form is pinned byte-for-byte by the remote-only fixture.
    if [[ "$BS_FORK_SOURCE" == "local" && -n "$BS_FORK_AHEAD" ]]; then
      candidate_line=$(printf 'Closest fork-point candidate by commits-ahead: %s (%s ahead, local branch) vs %s (%s ahead).' \
        "$BS_FORK_NAME" "$BS_FORK_AHEAD" "$base" "$ahead")
    elif [[ "$BS_FORK_REL" == "distinct" && -n "$BS_FORK_AHEAD" ]]; then
      candidate_line=$(printf 'Closest fork-point candidate by commits-ahead: %s (%s ahead) vs %s (%s ahead).' \
        "$BS_FORK_NAME" "$BS_FORK_AHEAD" "$base" "$ahead")
    else
      candidate_line=$(printf 'Closest fork-point candidate by commits-ahead: unavailable vs %s (%s ahead).' \
        "$base" "$ahead")
    fi
    if [[ "$capped" -eq 1 ]]; then
      candidate_line="${candidate_line}"$'\n'"$(printf 'Git evidence from fork candidate %s: %s committed + %s dirty files; the ledger is capped at %s.' \
        "$BS_FORK_NAME" "$committed_files" "$tree_files" "$denominator")"
    fi

    if _bs_override_on; then
      printf >&2 'WARNING: base-sanity: a PR against %s would carry %s files; this run'"'"'s ledger records %s.\n%s\nDowngraded to a warning by FN_BASE_SANITY_OVERRIDE — the bypass is audited.\n' \
        "$base" "$pr_files" "$ledger_files" "$candidate_line"
      audit_fn base_sanity override \
        "$(meta_json base "$base" pr_files "$pr_files" ledger_files "$ledger_files" \
          ahead "$ahead" fork_candidate "$BS_FORK_NAME" base_source "${src:-unknown}" \
          fork_relation "$BS_FORK_REL" denominator "$denominator" \
          override "${FN_BASE_SANITY_OVERRIDE:-}")"
      return 0
    fi

    printf >&2 'BLOCKED: base-sanity: a PR against %s would carry %s files; this run'"'"'s ledger records %s.\nThat gap (over 3x and over 20 files) is the signature of a base branch this work never forked from.\n%s\nThese are WRONG-BASE heuristics, not diff-quality rules — do not tune them into a style gate.\nSet FN_BASE_SANITY_OVERRIDE=1 to downgrade this to a warning (audited).\n' \
      "$base" "$pr_files" "$ledger_files" "$candidate_line"
    audit_fn base_sanity blocked "$meta"
    return 1
  fi

  if [[ "$ahead" -gt 25 ]]; then
    printf 'base-sanity: WARNING — HEAD is %s commits ahead of %s (%s files vs %s recorded); unusual for one worktask, verify the base is right\n' \
      "$ahead" "$base" "$pr_files" "$ledger_files"
    audit_fn base_sanity warn_ahead "$meta"
    return 0
  fi

  printf 'base-sanity: pass — a PR against %s would carry %s files; this run'"'"'s ledger records %s\n' \
    "$base" "$pr_files" "$ledger_files"
  audit_fn base_sanity ok "$meta"
  return 0
}

# ---------- unresolved-decisions ---------------------------------------------
UD_HEADING="## Unresolved decisions"
UD_LEAD="These escalation-class questions shipped without a decision in an unattended run."
UD_ACTION="sweep_escalation_unprompted"
# The unit separator, not a tab: `read` collapses runs of a whitespace IFS character, so an
# empty middle field would shift the ref into the stage slot.
UD_SEP=$'\037'

# The current run's rows, first occurrence per metadata.id, in log order: "id SEP stage SEP ref".
# A row carrying a run marker (metadata.run_index, or the `<worktask_id>:<run_index>:`
# dedupe_key prefix audit_fn stamps) must name this run. A row carrying none still counts:
# the orchestrator's row shape is only {id, stage, ref}, and dropping an unmarked row would
# hide exactly the item this block exists to show. Unparseable lines are skipped by fromjson?.
_ud_rows() {
  local audit="${CONTEXT_DIR}/logs/audit.jsonl" wid ri
  [[ -f "$audit" ]] || return 0
  wid=$(jq -r '.worktask_id // ""' "$STATE_PATH" 2> /dev/null) || wid=""
  ri=$(jq -r '.run_index // 0 | tostring' "$STATE_PATH" 2> /dev/null) || ri="0"
  jq -rR --arg wid "$wid" --arg ri "$ri" --arg act "$UD_ACTION" --arg sep "$UD_SEP" '
    fromjson? | select(type == "object" and .action == $act)
    | (.metadata // {}) as $m | select(($m | type) == "object")
    | select(($m.run_index // null) == null or ($m.run_index | tostring) == $ri)
    | (($m.dedupe_key // "") | tostring) as $dk
    | select(($dk | contains(":") | not) or ($dk | startswith($wid + ":" + $ri + ":")))
    | [($m.id // ""), ($m.stage // ""), ($m.ref // "")]
    | map(tostring | explode | map(if . < 32 then 32 else . end) | implode)
    | join($sep)
  ' "$audit" | awk -F "$UD_SEP" '!seen[$1]++'
}

# <ref> <id> -> the item's summary text, or nothing. Reads only a regular file under
# CONTEXT_DIR: the ref arrives through the audit log, so an absolute, `..` or symlinked
# target is refused rather than followed. The item block is found the way the handoff
# harness finds it: from the first line in the anchor section naming the id to the next
# line that starts another item (opens on a different sw- id) or the next `## ` heading.
# The cap counts characters, not bytes: a byte cap can split a UTF-8 sequence and
# publish an invalid byte. Continuation bytes (0x80-0xBF) ride with their lead byte.
_ud_question() {
  local ref="$1" id="$2" file anchor target
  anchor="${ref##*#}"
  file="${ref%%#*}"
  [[ -n "$file" && -n "$anchor" && "$anchor" != "$ref" ]] || return 0
  case "$file" in
    /* | *..*) return 0 ;;
  esac
  [[ "$file" =~ ^[A-Za-z0-9._/-]+$ ]] || return 0
  target="${CONTEXT_DIR}/${file}"
  [[ -f "$target" ]] || target="${CONTEXT_DIR}/${file#"$(basename "$CONTEXT_DIR")"/}"
  [[ -f "$target" && ! -L "$target" ]] || return 0
  _UD_ID="$id" _UD_ANCHOR="$anchor" awk '
    function names_id(s,    i, nc) {
      while ((i = index(s, ID)) > 0) {
        nc = substr(s, i + length(ID), 1)
        if (nc !~ /[0-9]/) return 1
        s = substr(s, i + length(ID))
      }
      return 0
    }
    function starts_other(s,    t) {
      if (!match(s, /^[[:space:]]*(-[[:space:]]*)?([{][[:space:]]*)?(id:[[:space:]]*)?sw-[A-Z][A-Z][0-9]+-[0-9]+/)) return 0
      t = substr(s, RSTART, RLENGTH)
      sub(/.*sw-/, "sw-", t)
      return t != ID
    }
    BEGIN { ID = ENVIRON["_UD_ID"]; ANCHOR = ENVIRON["_UD_ANCHOR"] }
    /^## / {
      if (insec) exit
      h = $0
      sub(/^## +/, "", h)
      sub(/[[:space:]]+$/, "", h)
      if (h == ANCHOR) insec = 1
      next
    }
    !insec { next }
    inblk && starts_other($0) { exit }
    !inblk && names_id($0) { inblk = 1 }
    inblk && match($0, /summary:[[:space:]]*/) {
      v = substr($0, RSTART + RLENGTH)
      c = substr(v, 1, 1)
      if (c == "\"" || c == "\047") {
        v = substr(v, 2)
        e = index(v, c)
        if (e) v = substr(v, 1, e - 1)
      } else {
        sub(/[[:space:]]*[,}][[:space:]]*$/, "", v)
        sub(/[[:space:]]+$/, "", v)
      }
      print v
      exit
    }
  ' "$target" 2> /dev/null | LC_ALL=C tr -d '\000-\037\177' | LC_ALL=C awk '
    {
      out = ""
      n = 0
      len = length($0)
      for (i = 1; i <= len; i++) {
        c = substr($0, i, 1)
        if (!(c >= "\200" && c < "\300") && ++n > 300) break
        out = out c
      }
      print out
      exit
    }
  '
}

# rows on stdin -> the unscrubbed block on stdout, and the rendered count on fd 3.
_ud_render() {
  local id ref task q n=0
  printf '%s\n\n%s\n\n' "$UD_HEADING" "$UD_LEAD"
  while IFS="$UD_SEP" read -r id _ ref; do
    # The id lands inside markdown emphasis in a published body, so only the sweep-id shape
    # is rendered; anything else could close the emphasis and inject markup.
    if [[ ! "$id" =~ ^sw-[A-Z][A-Z][0-9]+-[0-9]+$ ]]; then
      printf >&2 'warn: unresolved-decisions: skipped a %s row with a malformed id\n' "$UD_ACTION"
      continue
    fi
    task="${id#sw-}"
    task="${task%-*}"
    q=$(_ud_question "$ref" "$id")
    if [[ -n "$q" ]]; then
      printf -- '- **%s** (%s): %s\n' "$id" "$task" "$q"
    else
      printf -- '- **%s** (%s)\n' "$id" "$task"
    fi
    n=$((n + 1))
  done
  printf '%s' "$n" >&3
}

# <in> <out>. The shared seam's consumer contract: source only after `[ -r ]`, because `.` on
# a missing file exits a set -e shell before any guard runs; require the function and both
# EREs, because a partial load can scrub nothing and still exit 0; run under pipefail. Any miss
# is a non-zero exit and the caller publishes nothing. The subshell keeps the library's globals
# out of this script.
_ud_scrub() (
  set -o pipefail
  scrub="${SCRIPT_DIR}/../../shared/scripts/path-scrub.sh"
  [ -r "$scrub" ] || exit 97
  # shellcheck disable=SC1090
  . "$scrub" > /dev/null 2>&1 || exit 97
  command -v corpflow_path_scrub > /dev/null 2>&1 || exit 98
  [ -n "${CORPFLOW_HOST_PATH_ERE:-}" ] && [ -n "${CORPFLOW_DRIVE_PATH_ERE:-}" ] || exit 98
  corpflow_path_scrub < "$1" > "$2" || exit 99
  [ -s "$2" ] || exit 99
)

# <body> <block> <out>. Drops a leading block this command wrote (its heading on line 1, then
# only blank lines, the lead sentence and sw- bullets) and the blank lines after it, then
# writes block, one blank line, rest. Leading blanks are stripped on every run, not only when
# a block was present, which is what makes the second run byte-identical to the first.
_ud_splice() {
  local rest="$3.rest"
  _UD_H="$UD_HEADING" _UD_L="$UD_LEAD" awk '
    BEGIN { H = ENVIRON["_UD_H"]; L = ENVIRON["_UD_L"] }
    NR == 1 && $0 == H { inb = 1; next }
    inb && ($0 == "" || $0 == L || $0 ~ /^- \*\*sw-/) { next }
    { inb = 0 }
    !started && /^[[:space:]]*$/ { next }
    { started = 1; print }
  ' "$1" > "$rest" || return 1
  {
    cat "$2"
    if [[ -s "$rest" ]]; then
      printf '\n'
      cat "$rest"
    fi
  } > "$3" || return 1
  rm -f "$rest"
}

# <in> <out>. pr-body later passes the whole body through sanitise_stream, which drops any
# line naming a context path or a stage artifact, and path-scrub rewrites neither. Each
# bullet is therefore sanitised here, with the same function, so the item still ships: a
# line the sanitiser drops or mangles past its `- **<id>** (<TASK>)` prefix, or a sanitiser
# that fails, falls back to that prefix alone, which no strip rule matches. Running before
# the --print/--body split keeps the final message identical to the published block.
_ud_publishable() {
  local line prefix clean src
  local re='^- \*\*(sw-[A-Z][A-Z][0-9]+-[0-9]+)\*\* \(([A-Z][A-Z][0-9]+)\)'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re ]]; then
      prefix="- **${BASH_REMATCH[1]}** (${BASH_REMATCH[2]})"
      src=0
      clean=$(printf '%s\n' "$line" | sanitise_stream 2> /dev/null) || src=$?
      if [[ "$src" -eq 0 && "$clean" == "$prefix"* && "$clean" != *$'\n'* ]]; then
        line="$clean"
      else
        line="$prefix"
      fi
    fi
    printf '%s\n' "$line"
  done < "$1" > "$2"
}

cmd_unresolved_decisions() {
  local audit="${CONTEXT_DIR}/logs/audit.jsonl" rows count tmpd rc=0 mode=body
  [[ "$UD_PRINT" == 1 ]] && mode=print
  if [[ "$mode" == body && ( -z "$BODY_FILE" || ! -f "$BODY_FILE" ) ]]; then
    printf >&2 'unresolved-decisions requires --body <path> to an existing file, or --print\n'
    exit 2
  fi

  # A log naming the action that cannot be read is not a log with nothing to list.
  if ! command -v jq > /dev/null 2>&1 || ! rows=$(_ud_rows); then
    if grep -qF "\"$UD_ACTION\"" "$audit" 2> /dev/null; then
      printf >&2 'BLOCKED: unresolved-decisions: %s rows present but unreadable\n' "$UD_ACTION"
      audit_fn unresolved_decisions_emitted blocked "$(meta_json reason rows_unreadable)"
      return 1
    fi
    rows=""
  fi
  if [[ -z "$rows" ]]; then
    audit_fn unresolved_decisions_emitted none "$(meta_json count 0 mode "$mode")"
    return 0
  fi

  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fn-ud.XXXXXX") || {
    printf >&2 'BLOCKED: unresolved-decisions: no scratch directory\n'
    return 1
  }
  printf '%s\n' "$rows" | _ud_render > "$tmpd/block.raw" 3> "$tmpd/count" || rc=$?
  count=$(cat "$tmpd/count" 2> /dev/null) || count=""
  if [[ "$rc" -ne 0 || -z "$count" ]]; then
    rm -rf "$tmpd"
    printf >&2 'BLOCKED: unresolved-decisions: the block could not be rendered\n'
    audit_fn unresolved_decisions_emitted blocked "$(meta_json reason render_failed)"
    return 1
  fi
  if [[ "$count" == 0 ]]; then
    rm -rf "$tmpd"
    audit_fn unresolved_decisions_emitted none "$(meta_json count 0 mode "$mode")"
    return 0
  fi

  _ud_scrub "$tmpd/block.raw" "$tmpd/block.md" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    rm -rf "$tmpd"
    printf >&2 'BLOCKED: unresolved-decisions: path scrub unavailable or failed (rc=%s); nothing published\n' "$rc"
    audit_fn unresolved_decisions_emitted blocked \
      "$(meta_json reason scrub_unavailable scrub_rc "$rc" count "$count" mode "$mode")"
    return 1
  fi

  if ! _ud_publishable "$tmpd/block.md" "$tmpd/block.pub" || ! mv -f "$tmpd/block.pub" "$tmpd/block.md"; then
    rm -rf "$tmpd"
    printf >&2 'BLOCKED: unresolved-decisions: the block could not be rendered\n'
    audit_fn unresolved_decisions_emitted blocked "$(meta_json reason render_failed)"
    return 1
  fi

  if [[ "$mode" == print ]]; then
    cat "$tmpd/block.md"
    rm -rf "$tmpd"
    audit_fn unresolved_decisions_emitted ok "$(meta_json count "$count" mode print)"
    return 0
  fi

  # Written beside the body so the final mv is a same-filesystem rename.
  local out="${BODY_FILE}.unresolved.$$"
  if ! _ud_splice "$BODY_FILE" "$tmpd/block.md" "$out"; then
    rm -rf "$tmpd"
    rm -f "$out" "$out.rest"
    printf >&2 'BLOCKED: unresolved-decisions: the body could not be rewritten\n'
    audit_fn unresolved_decisions_emitted blocked "$(meta_json reason splice_failed count "$count")"
    return 1
  fi
  rm -rf "$tmpd"
  if cmp -s "$out" "$BODY_FILE"; then
    rm -f "$out"
  else
    mv -f "$out" "$BODY_FILE"
  fi
  printf 'unresolved-decisions: %s item(s) listed at the top of the PR body\n' "$count"
  audit_fn unresolved_decisions_emitted ok "$(meta_json count "$count" mode body)"
  return 0
}
