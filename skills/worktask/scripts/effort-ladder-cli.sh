#!/usr/bin/env bash
# @description effort-ladder-cli.sh — the executable entry point to effort-ladder.sh, so the
#   orchestrator can compute the Step C.0a resolver tier under an anchored allow-list grant.
#   A sourced library cannot be granted that way: `source …` is not a `bash <path> *` command.
#   Same split as branch-name.sh → branch-lib.sh: the library stays pure for state-patch.sh and
#   its other sourcing consumers, and this wrapper owns argv, exit codes and the newline.
#
# Usage:
#   effort-ladder-cli.sh for-resolver <effort> <model-alias>   tier a C.0a resolver runs at
#   effort-ladder-cli.sh plus-one <effort>                     one rung up, saturating at max
#   effort-ladder-cli.sh rank <effort>                         0-based position on the ladder
#   effort-ladder-cli.sh -h | --help
#
# Exit: 0 value printed with a trailing newline · 1 library unreachable · 2 usage error or an
#   off-ladder tier (stdout empty, one stderr line).
#
# Minimum shell: bash 3.2+ (macOS default).

set -uo pipefail

usage() {
  printf 'usage: effort-ladder-cli.sh {for-resolver <effort> <model> | plus-one <effort> | rank <effort>}\n'
}

_lib="$(dirname "${BASH_SOURCE[0]:-$0}")/effort-ladder.sh"
if [ ! -r "$_lib" ]; then
  printf >&2 'effort-ladder-cli.sh: library unreachable: %s\n' "$_lib"
  exit 1
fi
# shellcheck source=effort-ladder.sh
. "$_lib" || {
  printf >&2 'effort-ladder-cli.sh: library failed to load: %s\n' "$_lib"
  exit 1
}

# Every library function returns rc 2 with no output for an off-ladder tier. That rc is data
# here, not a crash, so the call is captured rather than run under `set -e`.
run_fn() { # <expected argc> <fn> [args...]
  _want=$1 _fn=$2
  shift 2
  if [ "$#" -ne "$_want" ]; then
    usage >&2
    exit 2
  fi
  _out=$("$_fn" "$@") || {
    printf >&2 'effort-ladder-cli.sh: not on the ladder (%s): %s\n' "$EFFORT_ENUM" "$*"
    exit 2
  }
  printf '%s\n' "$_out"
}

case "${1:-}" in
  for-resolver) shift; run_fn 2 effort_for_resolver "$@" ;;
  plus-one) shift; run_fn 1 effort_plus_one "$@" ;;
  rank) shift; run_fn 1 effort_rank "$@" ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
