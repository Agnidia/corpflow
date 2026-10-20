#!/usr/bin/env bash
# @description stream-diff.sh — the review diff for every DV row, resolved per tree.
#
#   Ledger mode walks the DV rows in ascending task-id order (status "skipped" dropped)
#   and prints one labelled block per row. Tree mode does the same for one tree with no
#   ledger rows. Read-only on git: never writes the index, the worktree or a ref.
#
#   Base per row: branch-lib.sh resolve_base_ref evaluated at the row's tree with that
#   row's own task id as BASE_REF_TASK_ID, so the row's metadata.base_ref (rank 2a,
#   base_source=task) outranks the ledger mirror; mapped by resolve_git_ref. Tree mode
#   names no task. There is no literal fallback; an unresolved base is reported.
#
#   Source ladder per row, first match wins:
#     committed  <ref>...HEAD is non-empty                        body: git diff <ref>...HEAD
#     staged     index differs from HEAD, no unstaged tracked edit body: git diff --cached
#     worktree   any unstaged tracked edit                         body: git diff HEAD
#     empty      none of the above
#   Without a resolvable base the committed rung is skipped and the reason says why.
#
#   Header, one per row, space-free values, "-" when none:
#     stream-diff task=<ID|-> stream=<s|-> source=<committed|staged|worktree|empty>
#       base=<name|-> base_source=<env|task|state|workspace|origin_head|unresolved> files=<n>
#       untracked=<n> staged_also=<n> shared_with=<ID|-> reason=<token>
#   (one line). files = paths in the body; untracked = untracked, non-ignored paths;
#   staged_also = uncommitted tracked paths the body omits (non-zero only for committed).
#   reason: - | no_changes | base_unresolved | base_unresolvable | tree_unresolved |
#   tree_missing | not_a_work_tree.
#
#   Formats:
#     patch  header + diff body
#     stat   header + diff --stat
#     names  header + "<X>\t<path>" per body path (no renames) + "?\t<path>" per untracked
#     tsv    no bodies; line 1 is the column names
#            task stream source base base_source files untracked staged_also shared_with
#            reason tree
#            then one TAB-separated row per block
#   A row whose tree has the same physical path as a lower row prints no body and carries
#   shared_with=<lower ID>.
#
#   Audit: one row per run, action stream_diff_resolved, result ok|degraded (degraded when
#   any row's reason is neither "-" nor no_changes), actor stream-diff, task_id from
#   --caller else "unknown", meta blocks=<ID:source,...>. Ledger mode writes next to the
#   ledger; tree mode only when <tree>/.context already exists.
#
# @arg --state <path>   Ledger (default .context/state.json). Ledger mode only.
# @arg --task <DVk>     Narrow to this row; repeatable. Ledger mode only.
# @arg --tree <abs>     Tree mode: one absolute tree, no ledger rows.
# @arg --format <f>     patch (default) | stat | names | tsv.
# @arg --caller <ID>    Task id recorded on the audit row.
# @arg -- <pathspec>... Limits every diff and the untracked listing.
# @arg -h | --help      Print this header on stdout and exit 0.
#
# @env FN_BASE_REF      Highest-priority base override (resolve_base_ref rank 1).
# @env BASE_REF_TASK_ID Ignored: ledger mode sets it per row, tree mode clears it.
#
# @exitcode 0  Printed (degraded rows included).
# @exitcode 2  Usage: unknown flag or format, bad or unknown --task, --tree with --task or
#              --state, relative --tree, missing flag value. Nothing on stdout.
# @exitcode 3  Unresolved input: jq missing, ledger unreadable, zero DV rows, branch-lib.sh
#              unreachable. Nothing on stdout.
#
# Minimum shell: bash 3.2+ (macOS default).

set -euo pipefail
IFS=$'\n\t'

# Stops git from taking optional locks and opportunistically rewriting the index
# during `git diff`, which would make a review a write.
export GIT_OPTIONAL_LOCKS=0

usage() {
  awk 'NR>1{ if (!/^#/) exit; sub(/^# ?/,""); print }' "$0"
  exit 0
}

die_usage() {
  printf >&2 'stream-diff: %s\n' "$1"
  exit 2
}

die_input() {
  printf >&2 'stream-diff: %s\n' "$1"
  exit 3
}

_resolve_script_dir() {
  local src="${BASH_SOURCE[0]:-$0}" dir
  while [ -h "$src" ]; do
    dir=$(CDPATH='' cd -- "$(dirname -- "$src")" && pwd -P)
    src=$(readlink "$src")
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  CDPATH='' cd -- "$(dirname -- "$src")" && pwd -P
}
SCRIPT_DIR="$(_resolve_script_dir 2> /dev/null)" || SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]:-$0}")"

STATE_ARG=""
TREE_ARG=""
FORMAT="patch"
CALLER=""
TASKS=()
PATHSPEC=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state)
      [[ $# -ge 2 && -n "$2" ]] || die_usage "--state needs a path"
      STATE_ARG="$2"
      shift 2
      ;;
    --task)
      [[ $# -ge 2 ]] || die_usage "--task needs a task id"
      [[ "$2" =~ ^DV[0-9]+$ ]] || die_usage "bad --task: $2 (expected DV<k>)"
      TASKS+=("$2")
      shift 2
      ;;
    --tree)
      [[ $# -ge 2 && -n "$2" ]] || die_usage "--tree needs an absolute path"
      TREE_ARG="$2"
      shift 2
      ;;
    --format)
      [[ $# -ge 2 ]] || die_usage "--format needs a value"
      case "$2" in
        patch | stat | names | tsv) FORMAT="$2" ;;
        *) die_usage "unknown --format: $2" ;;
      esac
      shift 2
      ;;
    --caller)
      [[ $# -ge 2 ]] || die_usage "--caller needs a task id"
      [[ "$2" =~ ^[A-Z]{2}[0-9]+$ ]] || die_usage "bad --caller: $2"
      CALLER="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    --)
      shift
      PATHSPEC=("$@")
      break
      ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

if [[ -n "$TREE_ARG" ]]; then
  [[ "${#TASKS[@]}" -eq 0 ]] || die_usage "--tree and --task are exclusive"
  [[ -z "$STATE_ARG" ]] || die_usage "--tree and --state are exclusive"
  [[ "$TREE_ARG" == /* ]] || die_usage "--tree must be absolute: $TREE_ARG"
fi

command -v jq > /dev/null 2>&1 || die_input "jq not found"

BRANCH_LIB_PATH="${SCRIPT_DIR}/branch-lib.sh"
if [ -r "$BRANCH_LIB_PATH" ]; then
  # shellcheck source=branch-lib.sh
  . "$BRANCH_LIB_PATH"
else
  die_input "branch-lib.sh unreachable at ${BRANCH_LIB_PATH} — plugin install broken"
fi

realpath_of() {
  [[ -n "${1:-}" ]] || return 1
  (CDPATH='' cd -- "$1" 2> /dev/null && pwd -P) || return 1
}

count_lines() {
  if [[ -z "$1" ]]; then
    printf '0'
  else
    printf '%s\n' "$1" | awk 'END { print NR }'
  fi
}

# Space- and TAB-free so the header stays one token per key.
token() {
  local v="${1:-}"
  v="${v//[[:space:]]/_}"
  printf '%s' "${v:--}"
}

# Tree-local git with fsmonitor off. .gitattributes clean filters (e.g. git-lfs) still run
# when a diff reads the worktree; filters are out of scope for the read-only guarantee.
g() {
  git -c core.fsmonitor=false -c core.quotepath=true "$@"
}

LEDGER=""
ROWS=""
if [[ -z "$TREE_ARG" ]]; then
  LEDGER="${STATE_ARG:-.context/state.json}"
  [[ -r "$LEDGER" ]] || die_input "ledger unreadable: $LEDGER"
  jq -e 'type == "object"' "$LEDGER" > /dev/null 2>&1 || die_input "ledger unreadable: $LEDGER"
  LEDGER="$(realpath_of "$(dirname -- "$LEDGER")")/$(basename -- "$LEDGER")"
  ROWS=$(jq -r '.tasks // {} | to_entries
    | map(select(.value.metadata.stage == "DV" and (.key | test("^DV[0-9]+$"))))
    | sort_by(.key | ltrimstr("DV") | tonumber)
    | map(select((.value.status // "") != "skipped"))
    | .[] | [.key, .value.metadata.stream, .value.metadata.workspace_path, .value.status]
    | map(if (type == "string") and (. != "") then . else "-" end) | @tsv' "$LEDGER" 2> /dev/null) \
    || die_input "ledger unreadable: $LEDGER"
  [[ -n "$ROWS" ]] || die_input "zero DV rows in $LEDGER"
  if [[ "${#TASKS[@]}" -gt 0 ]]; then
    for t in "${TASKS[@]}"; do
      printf '%s\n' "$ROWS" | awk -F'\t' -v t="$t" '$1 == t { found = 1 } END { exit !found }' \
        || die_usage "unknown --task: $t"
    done
  fi
else
  ROWS=$(printf -- '-\t-\t%s\t-' "$TREE_ARG")
fi

row_selected() {
  local t
  [[ "${#TASKS[@]}" -gt 0 ]] || return 0
  for t in "${TASKS[@]}"; do
    [[ "$t" == "$1" ]] && return 0
  done
  return 1
}

# Prints "source base base_source ref files untracked staged_also reason", TAB-separated,
# for the tree in $1, resolving the base for task $2 ("-" in tree mode). Runs in a
# subshell so the cd and the ledger env stay local.
probe_tree() (
  local tree="$1" task="${2:--}" bsrc base ref="" reason="-" source="empty"
  local committed="" staged="" unstaged="" untracked="" uncommitted="" headish files=0 also=0
  CDPATH='' cd -- "$tree" 2> /dev/null || {
    printf 'empty\t-\tunresolved\t-\t0\t0\t0\ttree_missing\n'
    exit 0
  }
  if [[ "$(git rev-parse --is-inside-work-tree 2> /dev/null || printf false)" != "true" ]]; then
    printf 'empty\t-\tunresolved\t-\t0\t0\t0\tnot_a_work_tree\n'
    exit 0
  fi
  export WORKSPACE_ROOT="$tree"
  [[ -z "$LEDGER" ]] || export STATE_PATH="$LEDGER"
  # The row's own id, never --caller: a reviewer's row is not the stream under review.
  # Cleared otherwise so an inherited value cannot point tree mode at some ledger row.
  if [[ -n "$LEDGER" && "$task" != "-" ]]; then
    export BASE_REF_TASK_ID="$task"
  else
    unset BASE_REF_TASK_ID
  fi
  base=$(resolve_base_ref)
  bsrc=$(base_ref_source)
  if [[ -z "$base" ]]; then
    reason="base_unresolved"
  else
    ref=$(resolve_git_ref "$base" || printf '')
    [[ -n "$ref" ]] || reason="base_unresolvable"
  fi

  # An unborn HEAD diffs against the empty tree rather than failing.
  headish=$(g rev-parse --verify --quiet 'HEAD^{commit}' 2> /dev/null || printf '')
  [[ -n "$headish" ]] || headish=$(g hash-object -t tree /dev/null 2> /dev/null || printf '')

  if [[ -n "$ref" ]] && g rev-parse --verify --quiet 'HEAD^{commit}' > /dev/null 2>&1; then
    committed=$(g diff --no-ext-diff --no-textconv --no-color --name-only --no-renames \
      "${ref}...HEAD" -- ${PATHSPEC[@]+"${PATHSPEC[@]}"} 2> /dev/null || printf '')
  fi
  staged=$(g diff --no-ext-diff --no-textconv --no-color --cached --name-only --no-renames \
    -- ${PATHSPEC[@]+"${PATHSPEC[@]}"} 2> /dev/null || printf '')
  unstaged=$(g diff --no-ext-diff --no-textconv --no-color --name-only --no-renames \
    -- ${PATHSPEC[@]+"${PATHSPEC[@]}"} 2> /dev/null || printf '')
  untracked=$(g ls-files --others --exclude-standard -- ${PATHSPEC[@]+"${PATHSPEC[@]}"} 2> /dev/null || printf '')

  if [[ -n "$committed" ]]; then
    source="committed"
    files=$(count_lines "$committed")
    uncommitted=$(g diff --no-ext-diff --no-textconv --no-color --name-only --no-renames \
      HEAD -- ${PATHSPEC[@]+"${PATHSPEC[@]}"} 2> /dev/null || printf '')
    also=$(count_lines "$uncommitted")
  elif [[ -n "$staged" && -z "$unstaged" ]]; then
    source="staged"
    files=$(count_lines "$staged")
  elif [[ -n "$unstaged" ]]; then
    source="worktree"
    uncommitted=$(g diff --no-ext-diff --no-textconv --no-color --name-only --no-renames \
      "$headish" -- ${PATHSPEC[@]+"${PATHSPEC[@]}"} 2> /dev/null || printf '')
    files=$(count_lines "$uncommitted")
  fi
  [[ "$source" != "empty" || "$reason" != "-" ]] || reason="no_changes"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$source" "$(token "$base")" "${bsrc:-unresolved}" \
    "${ref:--}" "$files" "$(count_lines "$untracked")" "$also" "$reason"
)

print_body() (
  local tree="$1" source="$2" ref="$3" headish
  CDPATH='' cd -- "$tree" 2> /dev/null || exit 0
  local opts=(--no-ext-diff --no-textconv --no-color)
  case "$FORMAT" in
    stat) opts+=(--stat) ;;
    names) opts+=(--name-status --no-renames) ;;
  esac
  case "$source" in
    committed) g diff "${opts[@]}" "${ref}...HEAD" -- ${PATHSPEC[@]+"${PATHSPEC[@]}"} ;;
    worktree)
      headish=$(g rev-parse --verify --quiet 'HEAD^{commit}' 2> /dev/null || printf '')
      [[ -n "$headish" ]] || headish=$(g hash-object -t tree /dev/null 2> /dev/null || printf '')
      g diff "${opts[@]}" "$headish" -- ${PATHSPEC[@]+"${PATHSPEC[@]}"}
      ;;
    staged) g diff "${opts[@]}" --cached -- ${PATHSPEC[@]+"${PATHSPEC[@]}"} ;;
  esac
  if [[ "$FORMAT" == "names" ]]; then
    g ls-files --others --exclude-standard -- ${PATHSPEC[@]+"${PATHSPEC[@]}"} \
      | awk '{ print "?\t" $0 }'
  fi
)

BLOCKS=""
DEGRADED=0
SEEN=""
if [[ "$FORMAT" == "tsv" ]]; then
  printf 'task\tstream\tsource\tbase\tbase_source\tfiles\tuntracked\tstaged_also\tshared_with\treason\ttree\n'
fi

# Every field is non-empty ("-" for none): TAB is IFS whitespace, so read collapses an
# empty field and shifts the rest left.
while IFS=$'\t' read -r id stream tree _status; do
  [[ -n "$id" ]] || continue
  if [[ "$id" != "-" ]]; then row_selected "$id" || continue; fi
  shared="-"
  real=""
  if [[ "$tree" != /* ]]; then
    probe=$(printf 'empty\t-\tunresolved\t-\t0\t0\t0\ttree_unresolved')
  elif real=$(realpath_of "$tree"); then
    shared=$(printf '%s\n' "$SEEN" | awk -F'\t' -v r="$real" '$1 == r { print $2; exit }')
    if [[ -z "$shared" ]]; then
      shared="-"
      SEEN="$SEEN"$'\n'"$real"$'\t'"$id"
    fi
    probe=$(probe_tree "$real" "$id") || probe=""
    [[ -n "$probe" ]] || probe=$(printf 'empty\t-\tunresolved\t-\t0\t0\t0\tnot_a_work_tree')
  else
    real=""
    probe=$(printf 'empty\t-\tunresolved\t-\t0\t0\t0\ttree_missing')
  fi
  IFS=$'\t' read -r source base bsrc ref files untracked also reason <<< "$probe"
  case "$reason" in
    - | no_changes) ;;
    *) DEGRADED=1 ;;
  esac
  BLOCKS="${BLOCKS:+$BLOCKS,}${id}:${source}"
  if [[ "$FORMAT" == "tsv" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(token "$stream")" "$source" \
      "$base" "$bsrc" "$files" "$untracked" "$also" "$shared" "$reason" "$(token "$tree")"
    continue
  fi
  printf 'stream-diff task=%s stream=%s source=%s base=%s base_source=%s files=%s untracked=%s staged_also=%s shared_with=%s reason=%s\n' \
    "$id" "$(token "$stream")" "$source" "$base" "$bsrc" "$files" "$untracked" "$also" "$shared" "$reason"
  [[ "$shared" == "-" && -n "$real" ]] || continue
  if [[ "$source" != "empty" ]] || [[ "$FORMAT" == "names" && "$untracked" != "0" ]]; then
    print_body "$real" "$source" "$ref" || true
  fi
done <<< "$ROWS"

AUDIT_FILE=""
if [[ -n "$LEDGER" ]]; then
  AUDIT_FILE="$(dirname -- "$LEDGER")/logs/audit.jsonl"
elif [[ -d "${TREE_ARG%/}/.context" ]]; then
  AUDIT_FILE="${TREE_ARG%/}/.context/logs/audit.jsonl"
fi
AUDIT_LIB="${SCRIPT_DIR}/../../shared/lib/audit-lib.sh"
if [[ -n "$AUDIT_FILE" && -r "$AUDIT_LIB" ]]; then
  # shellcheck source=../../shared/lib/audit-lib.sh
  . "$AUDIT_LIB"
  result="ok"
  [[ "$DEGRADED" -eq 0 ]] || result="degraded"
  corpflow_audit_row --file "$AUDIT_FILE" --actor stream-diff --action stream_diff_resolved \
    --result "$result" --subject "${CALLER:-unknown}" --task-id "${CALLER:-unknown}" --meta-kv "blocks=${BLOCKS}"
fi
exit 0
