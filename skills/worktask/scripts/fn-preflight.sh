#!/usr/bin/env bash
# @description fn-preflight.sh — the FN-stage pre-`gh pr create` validator battery,
#   extracted from agents/project-manager.md so the agent body carries a pointer call
#   instead of ~40 lines of inline jq/git one-liners (Phase-4 Worktask-Integration diet).
#
#   Checks, each also runnable standalone:
#     attachments    both Conductor attachment files exist (gate trip-wire mirror).
#     staging        no payload file is BOTH staged and modified again in the worktree;
#                    such a file ships its staged bytes while every report describes the
#                    worktree. Names the offending files. A merely-unstaged file is the
#                    normal pre-`git add` state and never fires. Then runs
#                    control-byte-lint.sh --staged: a raw C0 control byte in the index
#                    bytes of a staged text file blocks, naming the path and byte offset.
#     resolve-issue  print the issue number from ranked sources (first-match-wins).
#     validate-pr    the composed PR body carries `Closes #<n>` for the resolved issue,
#                    OR (no issue resolvable) append an audit-defer row and pass.
#     pr-body        the composed body was produced by the mandated pipeline, not
#                    hand-authored: sanitises it in place with publish-pl-issue.sh's
#                    own `sanitise_body`, then requires a `Test plan` heading and,
#                    on a screenshot-requiring run, the visual-evidence helper's
#                    audit row for THIS run index. Then runs pr-body-lint.sh over
#                    the sanitised body: warn-only by default; under --strict a lint
#                    that finds, errors or cannot run blocks with a `pr_body_gate`
#                    `blocked` row (reason pr_body_lint_findings | pr_body_lint_error |
#                    pr_body_lint_unavailable).
#     continuity     the integration branch is an ancestor of the worktree HEAD
#                    (`git merge-base --is-ancestor <base> HEAD`), so merging HEAD into it
#                    is a fast-forward; else log a diverged→cherry-pick diagnostic + audit
#                    row (never blocks). Diverged means the base holds commits HEAD lacks.
#                    It does NOT discriminate a wrong base: a branch stacked on another
#                    feature branch still contains its base and passes the same way.
#                    `base-sanity` is the check that discriminates a wrong base, and it blocks.
#                    Per-stream mode, entered only when facts.stream_branches holds >=2
#                    keys: every stream branch must be an ancestor of HEAD (one
#                    `branch_continuity` row each, `stream_merged` | `stream_unmerged`);
#                    any unmerged stream exits 1 after all are checked. The legacy
#                    ancestor check and its `diverged_cherry_pick` row never run there.
#     branch-divergence
#                    has anything outside the pipeline renamed the local branch since the
#                    naming step? Compares the local name against the `to` of the last
#                    `branch_renamed / ok` row — NOT against facts.branch, which is the
#                    planned REMOTE name and legitimately differs on several arms. Classes
#                    the result `third_party` or `expected`; only `third_party` is surfaced
#                    at the FN gate. Read-only, exit 0 always, never blocks.
#     issue-close-required
#                    is the integration branch something other than the repository
#                    default? If so the `Closes #N` merge trailer will never fire, so
#                    print the explicit `gh issue close` command to run post-merge. FN
#                    records it; whoever merges the PR runs it after the merge.
#                    Read-only, exit 0 always; unresolved inputs report, never guess.
#     base-sanity    does the diff a PR against the resolved base would carry resemble
#                    what this run recorded changing? Fails when the PR file count is
#                    over 3x the ledger's AND over 20 files larger — the signature of a
#                    base this work never forked from. Warns when HEAD is >25 commits
#                    ahead. Every unresolvable input degrades to a warning + exit 0.
#                    Git evidence caps the ledger: when HEAD's fork candidate (the remote
#                    `fork_base`, else the closest local branch) is not the base, the
#                    count compared is min(ledger, files committed since that candidate +
#                    dirty files), and the under-recording rung counts both. When the
#                    remote fork candidate IS the base, a firing rule warns
#                    (`fork_confirms_base`) and exits 0.
#     unresolved-decisions
#                    list the escalation-class questions this run shipped without a decision
#                    (its `sweep_escalation_unprompted` audit rows, one per metadata.id) in a
#                    `## Unresolved decisions` block at byte 0 of the body, replacing a block
#                    already there, so a re-run is byte-identical. The question text is the
#                    item's `summary` under its ref anchor, else the id alone. The block is
#                    passed through path-scrub.sh; if that file, its function or either ERE is
#                    missing, or the scrub fails, nothing is published: exit 1 and the body is
#                    byte-identical, on every route. Zero rows leaves the body untouched, exits
#                    0 and never sources the scrub, so a run with nothing to list cannot wedge.
#                    `--print` writes the same scrubbed block to stdout instead of the body;
#                    it is the one source for the final user message. One audit row,
#                    `unresolved_decisions_emitted`, carries `count`.
#     all            unresolved-decisions → attachments → staging → pr-body → validate-pr →
#                    continuity → base-sanity.
#
#   `branch-divergence` and `issue-close-required` are deliberately NOT in `all`: each is a
#   separate subcommand so it is independently testable and cannot perturb `continuity`'s
#   existing rows. `issue-close-required` additionally runs POST-merge, not pre-`pr create`.
#
#   `base-sanity` runs LAST in `all`: the `&&` chain aborts at the first failure, and
#   `continuity`'s non-blocking `diverged` row is directly useful when diagnosing a
#   base-sanity block. Blocking earlier would suppress that evidence.
#
#   `unresolved-decisions` runs FIRST in `all`: `pr-body` sanitises and lints the body it is
#   handed, so the block must already be in it for the published bytes to be the checked bytes.
#
#   `pr-body` runs BEFORE `validate-pr` because it rewrites the body in place: the
#   body whose `Closes #<n>` line is validated must be the byte-identical body that
#   reaches `gh pr create`.
#
#   Under batch (`/megatask`) and incident (`--emergency`) routing, `pr-body` still
#   sanitises — a working-folder path must not reach a published body on any route —
#   but drops its blocking checks: the composition requirements are skipped and an
#   unreachable sanitiser library degrades to a warning instead of exit 1. See
#   `fn_batch_scope` (branch-lib.sh) for the six signals.
#
#   Branch naming moved to the start of the planning stage (see
#   `skills/shared/git-conventions.md § Branch Naming`). This validator never
#   renames anything.
#
#   Behavior is byte-for-byte the logic documented in
#   agents/project-manager.md § FN Stage; this script is the single implementation the
#   agent and its tests share.  Zero network: no `gh`, no `git push`, no fetch.
#
# @arg --state <path>     state.json path (default: .context/state.json).
# @arg --context <dir>    .context dir (default: .context).
# @arg --body <path>      Composed PR body file (required by validate-pr / pr-body / all, and by
#                         unresolved-decisions unless --print).
# @arg --print            unresolved-decisions only: write the block to stdout, leave the body.
# @arg --strict           Export CORPFLOW_PR_BODY_STRICT=1: a pr-body-lint.sh failure blocks
#                         `pr-body` (and so `all`) outside batch and incident routing.
# @arg -h | --help        Show this header.
#
# @env CORPFLOW_PR_BODY_STRICT
#                         1 => same as --strict; also read by pr-body-lint.sh itself.
# @env FN_BASE_REF        Highest-priority integration-branch override (see resolve_base_ref).
# @env BASE_REF_TASK_ID   Ignored: every base resolution reads the ledger row FN<run_index>
#                         (rank 2a), then the ledger mirror. An inherited value is cleared.
# @env FN_BASE_SANITY_OVERRIDE
#                         The one sanctioned downgrade: any value other than unset/empty/
#                         `0`/`false`/`no` turns `base-sanity`'s hard fail into a warning and
#                         writes a `base_sanity` / `override` audit row naming both counts.
#                         Affects the fail arm only; there is no second bypass path.
# @env MILESTONE_MODE     1 => batch routing; `pr-body` sanitises but stops blocking.
# @env INCIDENT_MODE      1 => incident routing; same non-blocking mode.
#
# @exitcode 0   Check passed (or a non-blocking degrade: no issue resolvable / diverged /
#               scope-disabled).
# @exitcode 1   Blocking failure (missing attachment; a file both staged and re-modified;
#               a raw control byte in a staged text file, or a staged control-byte check
#               that could not run; body missing the closing keyword;
#               `pr-body`: missing `Test plan` heading, missing or contradicted
#               visual-evidence evidence, an unreachable sanitiser library, or under
#               --strict a pr-body-lint.sh that found, errored or could not run;
#               `base-sanity`: the PR diff dwarfs this run's own record of it;
#               `continuity` per-stream mode: a stream branch not merged into HEAD;
#               `unresolved-decisions`: rows to list but the path scrub is unavailable or
#               failed, or the audit log holds rows that cannot be read).
# @exitcode 2   Usage error (unknown command/flag; `pr-body`/`validate-pr` without --body;
#               `unresolved-decisions` without --body or --print; --print with any
#               other command).
# @exitcode 3   branch-lib.sh unreachable — no dispatch runs; or `staging` cannot read
#               control-byte-lint.sh (plugin install broken).
#
# Minimum shell: bash 3.2+ (macOS default). Mirrors state-patch.sh conventions.

set -euo pipefail
IFS=$'\n\t'

STATE_PATH=".context/state.json"
CONTEXT_DIR=".context"
BODY_FILE=""
UD_PRINT=0

# Physical directory of this script. CDPATH= disables a benign-but-common
# CDPATH setting that otherwise makes `cd` echo an extra line into this very
# capture, corrupting the path silently; `pwd -P` plus the readlink loop follow
# a symlinked script to its real directory so sibling-library resolution cannot
# be redirected onto an attacker-planted file next to the symlink.
_resolve_script_dir() {
  local src="${BASH_SOURCE[0]:-$0}" dir
  while [ -h "$src" ]; do
    dir=$(CDPATH= cd -- "$(dirname -- "$src")" && pwd -P)
    src=$(readlink "$src")
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  CDPATH= cd -- "$(dirname -- "$src")" && pwd -P
}
SCRIPT_DIR="$(_resolve_script_dir 2> /dev/null)" || SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]:-$0}")"

# Sanitiser library, resolved from this script's own location (mirrors
# attach-visual-evidence.sh's _LIB).
# shellcheck disable=SC2034  # read by sanitise_stream in fn-preflight-cmds.sh
LIB_PATH="${SCRIPT_DIR}/publish-pl-issue.sh"

# Shared helpers (meta_json, audit_fn, fn_batch_scope, resolve_base_ref). This
# file's only failure mode is absence — a same-directory, same-commit sibling
# missing means the plugin install is broken, in which case this script is
# equally suspect. Loud and immediate: no dispatch runs on a broken install.
BRANCH_LIB_PATH="${SCRIPT_DIR}/branch-lib.sh"
# `[ -f ]` first, not a bare `.`: sourcing a missing file with the `.` builtin is a
# special-builtin error that exits a `set -e` shell immediately, bypassing an
# `if ! . …; then` guard entirely (verified on bash 3.2 and 5.x).
if [ -n "$BRANCH_LIB_PATH" ] && [ -r "$BRANCH_LIB_PATH" ]; then
  # shellcheck disable=SC1090
  . "$BRANCH_LIB_PATH"
else
  printf >&2 'fn-preflight.sh: branch-lib.sh unreachable at %s — plugin install broken\n' \
    "$BRANCH_LIB_PATH"
  exit 3
fi

# Every cmd_* body and the four helpers they share. Sourced AFTER branch-lib.sh
# because those bodies call its audit_fn/meta_json/fn_batch_scope/resolve_base_ref,
# and because T4 pins branch-lib.sh as the first sibling a broken install reports.
# Same absence-is-the-only-failure-mode contract, same exit 3.
CMDS_LIB_PATH="${SCRIPT_DIR}/fn-preflight-cmds.sh"
# `[ -f ]` first, not a bare `.`: sourcing a missing file with the `.` builtin is a
# special-builtin error that exits a `set -e` shell immediately, bypassing an
# `if ! . …; then` guard entirely (verified on bash 3.2 and 5.x).
if [ -n "$CMDS_LIB_PATH" ] && [ -r "$CMDS_LIB_PATH" ]; then
  # shellcheck disable=SC1090
  . "$CMDS_LIB_PATH"
else
  printf >&2 'fn-preflight.sh: fn-preflight-cmds.sh unreachable at %s — plugin install broken\n' \
    "$CMDS_LIB_PATH"
  exit 3
fi

usage() {
  awk 'NR>1{ if (!/^#/) exit; sub(/^# ?/,""); print }' "$0"
  exit 2
}

# ---------- Argument parsing ----------
COMMAND=""
# shellcheck disable=SC2034  # STATE_PATH/CONTEXT_DIR/BODY_FILE/UD_PRINT are read by fn-preflight-cmds.sh
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state)
      shift
      STATE_PATH="${1:-}"
      shift
      ;;
    --context)
      shift
      CONTEXT_DIR="${1:-}"
      shift
      ;;
    --body)
      shift
      BODY_FILE="${1:-}"
      shift
      ;;
    --print)
      UD_PRINT=1
      shift
      ;;
    --strict)
      # Exported so the pr-body-lint.sh child process sees the same mode.
      export CORPFLOW_PR_BODY_STRICT=1
      shift
      ;;
    -h | --help) usage ;;
    attachments | staging | resolve-issue | validate-pr | pr-body | continuity | branch-divergence | issue-close-required | base-sanity | unresolved-decisions | all)
      COMMAND="$1"
      shift
      ;;
    *)
      printf >&2 'unknown argument: %s\n' "$1"
      usage
      ;;
  esac
done

[[ -n "$COMMAND" ]] || {
  printf >&2 'no command given\n'
  usage
}

# Every other command would ignore the flag and still run, so `all --print` would publish
# nothing at the top of the body while looking like a successful preflight.
if [[ "$UD_PRINT" == 1 && "$COMMAND" != unresolved-decisions ]]; then
  printf >&2 -- '--print applies only to unresolved-decisions\n'
  usage
fi

# Process-wide, not exported: every resolver call in every check reads this run's FN row
# first. A value inherited from a DV- or PL-scoped caller would point FN at another row's base.
unset BASE_REF_TASK_ID
if command -v jq > /dev/null 2>&1; then
  _fn_run_index=$(jq -r '.run_index | numbers | floor | tostring' "$STATE_PATH" 2> /dev/null || printf '')
  # shellcheck disable=SC2034  # read by _base_ref_ranked in branch-lib.sh
  case "$_fn_run_index" in
    '' | *[!0-9]*) ;;
    *) BASE_REF_TASK_ID="FN${_fn_run_index}" ;;
  esac
fi

case "$COMMAND" in
  attachments) cmd_attachments ;;
  staging) cmd_staging ;;
  resolve-issue) resolve_issue && printf '\n' ;;
  validate-pr) cmd_validate_pr ;;
  pr-body) cmd_pr_body ;;
  continuity) cmd_continuity ;;
  branch-divergence) cmd_branch_divergence ;;
  issue-close-required) cmd_issue_close_required ;;
  base-sanity) cmd_base_sanity ;;
  unresolved-decisions) cmd_unresolved_decisions ;;
  all)
    cmd_unresolved_decisions && cmd_attachments && cmd_staging && cmd_pr_body \
      && cmd_validate_pr && cmd_continuity && cmd_base_sanity
    ;;
esac
