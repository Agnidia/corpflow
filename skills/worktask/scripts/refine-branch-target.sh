#!/usr/bin/env bash
# @description refine-branch-target.sh — re-derive the PLANNED remote branch name from
#   the approved plan's own `title:`, at most once per run, after planning completes and
#   before the plan is published (`skills/worktask/references/workflow.md § Step A.4b`).
#
#   Ledger-only: it writes `facts.branch` and NOTHING else. It performs no git mutation,
#   never runs branch-name.sh in rename mode, and leaves the local branch byte-identical.
#   The once-only RENAME rule is untouched — see `skills/shared/git-conventions.md
#   § Once-only rule`.
#
#   Non-blocking by contract, like every other helper the orchestrator invokes with a
#   trailing `; true`: every runtime outcome exits 0 and is recorded as a
#   `branch_target_refined` audit row, `ok` or `noop` with a reason from the closed set.
#
#   Exactly one audit row per invocation **whenever `jq` is available**. `jq` is what
#   serialises the row, so the `jq_unavailable` arm — and only that arm — writes none,
#   announcing itself on stdout instead. This matches `branch-lib.sh audit_fn`, which
#   no-ops without `jq` for every caller.
#
#   The once-guard is a scan of audit.jsonl for a prior `ok` row at this run index rather
#   than an in-memory flag, so an interrupted-and-resumed orchestrator cannot spend the
#   window twice. `noop` rows never consume it.
#
# @arg --plan <path>      Plan file (default: state.json `.plan_file`). Both documented
#                         shapes are accepted — value as given, then its basename against
#                         the directory holding state.json (`skills/worktask/references/
#                         skills/worktask/references/contracts/ledger-root.md § plan_file shape boundary`).
# @arg --state <path>     state.json path (default: .context/state.json).
# @arg --context <dir>    .context dir (default: .context).
# @arg -h | --help        Show this header.
#
# @env WORKSPACE_ROOT     Read transitively by fn_batch_scope / resolve_base_ref.
# @env FN_BASE_REF        Highest-priority integration-branch override.
# @env MILESTONE_MODE     1 => batch routing; self-disables (batch owns naming).
# @env INCIDENT_MODE      1 => incident routing; self-disables.
#
# @exitcode 0   Every runtime outcome, refined or not.
# @exitcode 2   Usage error or -h.
#
# Minimum shell: bash 3.2+ (macOS default).

set -euo pipefail
IFS=$'\n\t'

STATE_PATH=".context/state.json"
CONTEXT_DIR=".context"
PLAN_ARG=""

usage() {
  awk 'NR>1{ if (!/^#/) exit; sub(/^# ?/,""); print }' "$0"
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --plan)
      shift
      [ $# -gt 0 ] || {
        printf >&2 'refine-branch-target: --plan requires a value\n'
        exit 2
      }
      PLAN_ARG="$1"
      shift
      ;;
    --state)
      shift
      [ $# -gt 0 ] || {
        printf >&2 'refine-branch-target: --state requires a value\n'
        exit 2
      }
      STATE_PATH="$1"
      shift
      ;;
    --context)
      shift
      [ $# -gt 0 ] || {
        printf >&2 'refine-branch-target: --context requires a value\n'
        exit 2
      }
      CONTEXT_DIR="$1"
      shift
      ;;
    -h | --help) usage ;;
    *)
      printf >&2 'refine-branch-target: unknown argument: %s\n' "$1"
      usage
      ;;
  esac
done

# Physical directory of this script — same resolution as branch-name.sh, and for the
# same reason: a symlinked entry point must not let sibling-library resolution be
# redirected onto an attacker-planted file next to the symlink.
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
LIB_PATH="${SCRIPT_DIR}/branch-lib.sh"

CURRENT=""
PLAN_FILE=""

# `[ -r ]` first, not a bare `.`: sourcing a missing file with the `.` builtin exits a
# `set -e` shell immediately, bypassing an `if ! . …` guard entirely.
if [ -r "$LIB_PATH" ]; then
  # shellcheck disable=SC1090
  . "$LIB_PATH"
else
  # audit_fn is in the library that just failed to source, so this one row is written
  # inline rather than delegated.
  mkdir -p "${CONTEXT_DIR}/logs" 2> /dev/null || true
  # Refuse a symlinked audit.jsonl: following it makes this append a write primitive
  # against an arbitrary target. A lost row never blocks the caller.
  if command -v jq > /dev/null 2>&1 \
    && [ ! -L "${CONTEXT_DIR}/logs/audit.jsonl" ]; then
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    wid=$(jq -r '.worktask_id // "unknown"' "$STATE_PATH" 2> /dev/null || printf 'unknown')
    ri=$(jq -r '.run_index // 0' "$STATE_PATH" 2> /dev/null || printf '0')
    CURRENT=$(jq -r '.facts.branch // ""' "$STATE_PATH" 2> /dev/null || printf '')
    jq -cn --arg ts "$ts" --arg wid "$wid" --arg ri "$ri" --arg cur "$CURRENT" \
      '{ts:$ts, actor:"orchestrator", action:"branch_target_refined", subject:("PL" + $ri),
        result:"noop", task_id:"PL0",
        metadata:{reason:"lib_unreachable", from:$cur, plan_file:"",
                  origin_stage:"PL", dedupe_key:($wid + ":" + $ri + ":branch_target_refined")}}' \
      >> "${CONTEXT_DIR}/logs/audit.jsonl" 2> /dev/null || true
  fi
  printf >&2 'refine-branch-target: branch-lib.sh unreachable at %s — no refinement\n' "$LIB_PATH"
  printf 'refine-branch-target: no-op (lib_unreachable)\n'
  printf 'ledger_branch=%s\n' "$CURRENT"
  exit 0
fi

# shellcheck disable=SC2034  # both read by branch-lib.sh audit_fn through dynamic scope
AUDIT_ACTOR="orchestrator"
# shellcheck disable=SC2034
AUDIT_STAGE="PL"
RUN_INDEX="0"
AUDIT_SUBJECT="PL0"

# Every blocked arm lands here: one row, the ledger untouched, the caller told what the
# planned name still is.
finish_noop() {
  local reason="$1"
  audit_fn branch_target_refined noop \
    "$(meta_json reason "$reason" from "$CURRENT" plan_file "$PLAN_FILE")"
  printf 'refine-branch-target: no-op (%s)\n' "$reason"
  printf 'ledger_branch=%s\n' "$CURRENT"
  exit 0
}

# Gate 0 — the preconditions that make any of the following knowable.
if ! command -v jq > /dev/null 2>&1; then
  printf 'refine-branch-target: no-op (jq_unavailable)\n'
  printf 'ledger_branch=%s\n' ""
  exit 0
fi

if [ ! -r "$STATE_PATH" ]; then
  finish_noop state_missing
fi

RUN_INDEX=$(jq -r '.run_index // 0' "$STATE_PATH" 2> /dev/null || printf '0')
AUDIT_SUBJECT="PL${RUN_INDEX}"
CURRENT=$(jq -r '.facts.branch // ""' "$STATE_PATH" 2> /dev/null || printf '')
[ "$CURRENT" = "null" ] && CURRENT=""

# Two-candidate resolution: the value as given, then its basename against the directory
# holding state.json.
resolve_plan_file() {
  local v="${1:-}" dir alt
  [ -n "$v" ] || return 0
  if [ -f "$v" ]; then
    printf '%s' "$v"
    return 0
  fi
  dir=$(dirname "$STATE_PATH")
  alt="${dir}/$(basename "$v")"
  if [ -f "$alt" ]; then
    printf '%s' "$alt"
    return 0
  fi
  printf '%s' "$v"
}

PLAN_RAW="$PLAN_ARG"
if [ -z "$PLAN_RAW" ]; then
  PLAN_RAW=$(jq -r '.plan_file // ""' "$STATE_PATH" 2> /dev/null || printf '')
  [ "$PLAN_RAW" = "null" ] && PLAN_RAW=""
fi
PLAN_FILE=$(resolve_plan_file "$PLAN_RAW")

if fn_batch_scope; then
  finish_noop batch_scope
fi

if ! git rev-parse --git-dir > /dev/null 2>&1; then
  finish_noop not_a_git_repo
fi

# Gate 1 — the window is spent only by a successful refinement, so the guard survives
# resume without any additional state.
#
# `fromjson?` skips an UNPARSABLE line; `objects` additionally discards a well-formed
# NON-object one (`123`, `[1,2]`), which parses fine and then dies on `.action`.
#
# In this streaming form jq reports that error per-input and CONTINUES, so a bad line before
# the match still exits 0 — but one AFTER the match makes jq exit 5, the `&&` below reads
# that as "no prior row", and this guard fails OPEN, permitting a second refinement. Both
# tokens are load-bearing; the position of the bad line is what decides which one saves you.
if [ -f "${CONTEXT_DIR}/logs/audit.jsonl" ] \
  && jq -e -R --arg s "$AUDIT_SUBJECT" \
    'fromjson? | objects | select(.action == "branch_target_refined" and .result == "ok" and .subject == $s)' \
    "${CONTEXT_DIR}/logs/audit.jsonl" > /dev/null 2>&1; then
  finish_noop already_refined
fi

# Gate 2 — refining after a push would orphan the remote ref the upstream points at.
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' > /dev/null 2>&1; then
  finish_noop upstream_exists
fi

# Gate 3 — has this branch accumulated a commit of its own since it diverged from the
# integration base? A commit already carries the branch identity; renaming the plan under
# it would leave the two disagreeing.
#
# `resolve_base_ref` is shape-heterogeneous by design: three of its four sources yield a
# bare name (`master`), only the symbolic-ref fallback yields `origin/master`. A bare name
# resolves to the LOCAL `refs/heads/<base>`, which asks "is my local base behind?" — a
# different question, and one that answers yes on any long-lived clone or linked worktree
# with zero commits on the branch. Compare against the remote-tracking ref, which tracks
# the published tip the branch actually diverged from. `${base#origin/}` alone normalises
# a NAME; this gate needs a REV, so the name is normalised and then re-resolved.
BASE_REF=$(resolve_base_ref)
if [ -z "$BASE_REF" ]; then
  finish_noop base_unresolved
fi
BASE_NAME="${BASE_REF#origin/}"
BASE_REV=""
for _cand in "refs/remotes/origin/$BASE_NAME" "refs/heads/$BASE_NAME"; do
  if git rev-parse --verify --quiet "$_cand" > /dev/null 2>&1; then
    BASE_REV="$_cand" # remote-tracking wins; local is the silent no-remote fallback
    break
  fi
done
if [ -z "$BASE_REV" ]; then
  finish_noop base_unresolved
fi
# An unborn HEAD leaves the two refs incomparable, so the gate declines rather than guesses.
AHEAD=$(git rev-list --count "${BASE_REV}..HEAD" 2> /dev/null || printf '')
if [ -z "$AHEAD" ]; then
  finish_noop base_unresolved
fi
if [ "$AHEAD" != "0" ]; then
  finish_noop commit_exists
fi

# Gate 4 — the plan's own frontmatter `title:`, read without a yq dependency.
if [ -z "$PLAN_FILE" ] || [ ! -r "$PLAN_FILE" ]; then
  finish_noop plan_missing
fi

extract_title() {
  awk '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { next }
    $0 == "---" { exit }
    /^title:[[:space:]]*/ { sub(/^title:[[:space:]]*/, ""); print; exit }
  ' "$1"
}

TITLE=$(extract_title "$PLAN_FILE" 2> /dev/null || printf '')
TITLE=$(printf '%s' "$TITLE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
case "$TITLE" in
  '"'*'"')
    TITLE=${TITLE#\"}
    TITLE=${TITLE%\"}
    ;;
  "'"*"'")
    TITLE=${TITLE#\'}
    TITLE=${TITLE%\'}
    ;;
esac
if [ -z "$TITLE" ]; then
  finish_noop no_plan_title
fi

# Gate 5 — the single derivation site. The query mode is used rather than the dry run
# because the dry run walks the guard ladder and returns nothing on a checkout whose
# branch is already conventional.
CANDIDATE=$(bash "${SCRIPT_DIR}/branch-name.sh" --print-target --goal "$TITLE" \
  --state "$STATE_PATH" --context "$CONTEXT_DIR" 2> /dev/null) || CANDIDATE=""
if [ -z "$CANDIDATE" ] || ! branch_is_conventional "$CANDIDATE"; then
  finish_noop candidate_unusable
fi
# The same charset FN re-validates against before building the push refspec.
if ! printf '%s' "$CANDIDATE" | grep -Eq '^[A-Za-z0-9._/-]+$'; then
  finish_noop candidate_unusable
fi
if [ "$CANDIDATE" = "$CURRENT" ]; then
  finish_noop candidate_unchanged
fi

# Gate 6 — the one window exists to IMPROVE the planned name. Spending it to replace a
# name with no recorded truncation by a mid-phrase fragment is a regression.
CAND_TRUNCATES=0
CAND_TICKET=$(derive_ticket "$TITLE")
if slug_is_truncated "$TITLE" "$CAND_TICKET"; then
  CAND_TRUNCATES=1
fi
# Same streaming-form hazard as the once-guard above, failing the other way: a missed scan
# reads the incumbent as not-truncated, so gate 6 refuses a refinement it should allow.
INCUMBENT_TRUNCATED=0
if [ -f "${CONTEXT_DIR}/logs/audit.jsonl" ] \
  && jq -e -R --arg s "$AUDIT_SUBJECT" \
    'fromjson? | objects | select(.action == "branch_slug_truncated" and .subject == $s)' \
    "${CONTEXT_DIR}/logs/audit.jsonl" > /dev/null 2>&1; then
  INCUMBENT_TRUNCATED=1
fi
if [ "$CAND_TRUNCATES" = "1" ] && [ "$INCUMBENT_TRUNCATED" = "0" ]; then
  finish_noop candidate_not_better
fi

# Ledger write — temp, fsync, rename. No spinlock: no stage has been dispatched at
# Step A.4b, so this window is single-writer by construction.
STATE_DIR=$(dirname "$STATE_PATH")
TMP_STATE="${STATE_DIR}/.state.json.$$.${RANDOM}.tmp"
WROTE=0
if jq --arg b "$CANDIDATE" '.facts.branch = $b' "$STATE_PATH" > "$TMP_STATE" 2> /dev/null \
  && jq -e . "$TMP_STATE" > /dev/null 2>&1; then
  sync "$TMP_STATE" 2> /dev/null || sync 2> /dev/null || true
  if mv -f "$TMP_STATE" "$STATE_PATH" 2> /dev/null; then
    WROTE=1
  fi
fi
if [ "$WROTE" -ne 1 ]; then
  rm -f "$TMP_STATE" 2> /dev/null || true
  finish_noop write_failed
fi

LOCAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2> /dev/null || printf '')
if [ "$LOCAL_BRANCH" = "HEAD" ]; then
  LOCAL_BRANCH=""
fi
DIVERGES=false
if [ "$CANDIDATE" != "$LOCAL_BRANCH" ]; then
  DIVERGES=true
fi

audit_fn branch_target_refined ok \
  "$(meta_json from "$CURRENT" to "$CANDIDATE" source plan_title plan_file "$PLAN_FILE" \
    local_branch "$LOCAL_BRANCH" diverges_from_local "$DIVERGES")"
printf 'refine-branch-target: %s -> %s (plan title)\n' "$CURRENT" "$CANDIDATE"
printf 'ledger_branch=%s\n' "$CANDIDATE"
exit 0
