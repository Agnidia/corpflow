#!/usr/bin/env bash
# @description workspace-root-banner.sh — the WORKSPACE_ROOT line injected into a stage
#   prompt, resolved per ledger task (skills/worktask/references/contracts/artifact-map.md § DV fan-out — ledger tasks).
#
#   A stream row's tree is tasks.<ID>.metadata.workspace_path, never the run-level
#   metadata: the row is authoritative and the orchestrator root is only the fallback.
#
#   Resolution: tasks.<ID>.metadata.workspace_path when it is a non-empty string, else
#   --orch-root, else `git rev-parse --show-toplevel`, else the physical cwd. Absent, null
#   and "" count as unset; any other JSON type is a ledger defect and exits 2.
#
# @arg --task <ID>         Ledger task id (e.g. DV1). Required.
# @arg --state <path>      state.json path (default: resolved via corpflow_context_dir(),
#                          never the invoking cwd).
# @arg --orch-root <path>  Orchestrator root used when the row has no workspace_path.
# @arg --self-test         Run the built-in self-test and exit.
# @arg -h | --help         Show this header.
#
# @stdout WORKSPACE_ROOT=<path>
# @exitcode 0  Printed.
# @exitcode 2  Usage error, malformed task id, unreadable ledger, unknown task id, a
#              workspace_path that is not a single-line absolute path or not a string,
#              or jq missing.
#              Never a silent fallback: a wrong banner puts the stage in another tree.
#
# Minimum shell: bash 3.2+ (macOS default).

set -euo pipefail
IFS=$'\n\t'

# Stderr, not stdout: callers capture stdout as the banner line itself.
usage() {
  sed -n '2,25s/^# \{0,1\}//p' "$0" >&2
  exit 2
}

die() {
  printf >&2 'workspace-root-banner: %s\n' "$1"
  exit 2
}

# Two uppercase stage letters and a run-scoped index, the only ids the ledger mints.
# [[ =~ ]] anchors the whole value; grep would match per line and pass $'DV1\nx'.
valid_task_id() {
  [[ "$1" =~ ^[A-Z]{2}[0-9]+$ ]]
}

orch_root_default() {
  git rev-parse --show-toplevel 2> /dev/null || pwd -P
}

resolve_state() {
  local lib ctx rc=0
  lib="$(dirname "${BASH_SOURCE[0]}")/../../shared/lib/state-read-lib.sh"
  [[ -r "$lib" ]] || die "state-read-lib.sh unreachable at $lib — plugin install broken"
  # shellcheck source=../../shared/lib/state-read-lib.sh
  # shellcheck disable=SC1090
  . "$lib" || die "failed to source $lib"
  ctx=$(corpflow_context_dir) || rc=$?
  [[ "$rc" -eq 0 && -n "$ctx" ]] || die "no .context/state.json resolved; pass --state"
  printf '%s/state.json' "$ctx"
}

cmd_render() {
  local state="$1" task="$2" orch="$3" known kind path
  valid_task_id "$task" || die "malformed task id: $task (expected e.g. DV1)"
  command -v jq > /dev/null 2>&1 || die "jq is required"
  [[ -n "$state" ]] || state="$(resolve_state)"
  [[ -r "$state" ]] || die "ledger unreadable: $state"

  known=$(jq -r --arg id "$task" '.tasks[$id] != null' "$state" 2> /dev/null) \
    || die "ledger is not valid JSON: $state"
  [[ "$known" == "true" ]] || die "unknown task id: $task"

  # A number or object here is a malformed row, not an unset one; falling back would hide it.
  kind=$(jq -r --arg id "$task" '.tasks[$id].metadata.workspace_path | type' "$state")
  case "$kind" in
    null | string) ;;
    *) die "tasks.$task.metadata.workspace_path is a $kind, expected a string" ;;
  esac
  path=$(jq -r --arg id "$task" '.tasks[$id].metadata.workspace_path // empty' "$state")
  if [[ -n "$path" ]]; then
    case "$path" in
      /*) ;;
      *) die "tasks.$task.metadata.workspace_path is not absolute: $path" ;;
    esac
    [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] \
      || die "tasks.$task.metadata.workspace_path spans lines"
  else
    path="${orch:-$(orch_root_default)}"
  fi
  printf 'WORKSPACE_ROOT=%s\n' "$path"
}

cmd_self_test() {
  local self tmp out rc fail=0
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: $tmp is local and gone by EXIT time
  trap "rm -rf -- '$tmp'" EXIT
  cat > "$tmp/state.json" << 'EOF'
{"tasks":{"DV0":{"metadata":{"stage":"DV"}},"DV1":{"metadata":{"stage":"DV","workspace_path":"/x"}},
"DV2":{"metadata":{"stage":"DV","workspace_path":""}},"DV3":{"metadata":{"workspace_path":"rel/p"}},
"DV4":{"metadata":{"workspace_path":7}},"DV5":{"metadata":{"workspace_path":{"p":"/x"}}}}}
EOF
  check() { # <label> <expected-rc> <expected-stdout> -- args...
    local label="$1" want_rc="$2" want_out="$3"
    shift 4
    rc=0
    out=$(bash "$self" "$@" 2> /dev/null) || rc=$?
    if [[ "$rc" -eq "$want_rc" && "$out" == "$want_out" ]]; then
      printf 'ok: %s\n' "$label"
    else
      printf 'FAIL: %s (rc=%s out=%s)\n' "$label" "$rc" "$out" >&2
      fail=1
    fi
  }
  check "row path wins" 0 "WORKSPACE_ROOT=/x" -- --state "$tmp/state.json" --task DV1 --orch-root /o
  check "no row path -> orch root" 0 "WORKSPACE_ROOT=/o" -- --state "$tmp/state.json" --task DV0 --orch-root /o
  check "empty row path -> orch root" 0 "WORKSPACE_ROOT=/o" -- --state "$tmp/state.json" --task DV2 --orch-root /o
  check "unknown task id exits 2" 2 "" -- --state "$tmp/state.json" --task DV9 --orch-root /o
  check "malformed task id exits 2" 2 "" -- --state "$tmp/state.json" --task 'DV1;x' --orch-root /o
  check "relative row path exits 2" 2 "" -- --state "$tmp/state.json" --task DV3 --orch-root /o
  check "newline-bearing task id exits 2" 2 "" -- --state "$tmp/state.json" --task $'DV1\nx' --orch-root /o
  check "numeric row path exits 2" 2 "" -- --state "$tmp/state.json" --task DV4 --orch-root /o
  check "object row path exits 2" 2 "" -- --state "$tmp/state.json" --task DV5 --orch-root /o
  check "missing --task exits 2" 2 "" -- --state "$tmp/state.json"
  mkdir -p "$tmp/repo"
  (cd "$tmp/repo" && git init -q . 2> /dev/null) || true
  local repo_top
  repo_top="$(cd "$tmp/repo" && { git rev-parse --show-toplevel 2> /dev/null || pwd -P; })"
  out=$(cd "$tmp/repo" && bash "$self" --state "$tmp/state.json" --task DV0 2> /dev/null) || fail=1
  if [[ "$out" == "WORKSPACE_ROOT=$repo_top" ]]; then
    printf 'ok: no --orch-root -> git toplevel\n'
  else
    printf 'FAIL: no --orch-root -> git toplevel (out=%s want=%s)\n' "$out" "$repo_top" >&2
    fail=1
  fi
  [[ "$fail" -eq 0 ]] || exit 1
  printf 'workspace-root-banner: self-test OK\n'
}

main() {
  local cmd="render" task="" state="" orch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) [[ $# -ge 2 ]] || usage; task="$2"; shift 2 ;;
      --state) [[ $# -ge 2 ]] || usage; state="$2"; shift 2 ;;
      --orch-root) [[ $# -ge 2 ]] || usage; orch="$2"; shift 2 ;;
      --self-test) cmd="self-test"; shift ;;
      -h | --help) usage ;;
      *) printf >&2 'unknown argument: %s\n' "$1"; usage ;;
    esac
  done
  case "$cmd" in
    self-test) cmd_self_test ;;
    render)
      [[ -n "$task" ]] || usage
      cmd_render "$state" "$task" "$orch"
      ;;
  esac
}

main "$@"
