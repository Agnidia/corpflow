#!/usr/bin/env bash
# @description effort-ladder.sh — the effort tier ladder and the resolver's tier/model clamp,
#   shared verbatim by everything that computes a bumped effort: the orchestrator's Step C.0a
#   resolver dispatch, state-patch.sh (the `metadata.effort` enum gate) and their bats suites.
#
#   One definition, several consumers, for the same reason as sweep-stub-lib.sh: a tier that
#   one caller accepts and another rejects is the class of disagreement this file exists to
#   make impossible. The ladder itself is canonical in
#   `skills/shared/model-selection.md § Effort Levels`; this file is its executable copy and
#   the bats suite asserts the two agree.
#
#   Sources nothing, sets no options, does no work at load.
#
#   Symbols: EFFORT_ENUM, EFFORT_CAPPED_CEILING, EFFORT_FULL_LADDER_RE,
#            effort_rank, effort_plus_one, effort_for_resolver.
#
# Minimum shell: bash 3.2+ (macOS default) — no associative arrays, no `local -n`.

# Constants are read by the sourcing consumers, never inside this file.
# shellcheck disable=SC2034

# Anti-execution guard — MUST be the first statement.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  printf >&2 'effort-ladder.sh: this is a library — source it, do not execute it directly; for a CLI run effort-ladder-cli.sh\n'
  exit 2
fi

# Include guard: a double source is a no-op rather than a re-assignment.
[ -n "${_CORPFLOW_EFFORT_LADDER:-}" ] && return 0
_CORPFLOW_EFFORT_LADDER=1

# Not `readonly`: the bats suites source this file more than once per process, and a second
# readonly assignment is rc 1, which kills a `set -e` caller.

# The whole tier vocabulary, in ascending order. Space-delimited so a `case`, a jq --argjson
# and the rank walk below all derive from one string.
EFFORT_ENUM='low medium high xhigh max'

# A model Claude Code does not list for `xhigh` runs it at the highest level it supports at or
# below, with no error (`model-selection.md § xhigh routing`). A resolver that asked for a tier
# the model cannot carry would run one or two rungs below what the audit row claims, so the bump
# stops here on those models. Ceiling, not a rejection: the resolver still runs.
EFFORT_CAPPED_CEILING='high'

# Alias-level test, matching what `metadata.model` actually carries. `model-selection.md
# § Prefer the alias over a pinned id` makes the alias the only value the pipeline writes, so
# matching ids here would encode a form no stage emits. These three aliases resolve to models
# that carry every rung (Opus 5.5, Sonnet 5.5, Fable 5.x); `haiku` is not on Claude Code's effort
# list. A full id that slipped through is capped — the safe direction, since the clamp only
# ever lowers.
EFFORT_FULL_LADDER_RE='^(opus|sonnet|fable)$'

# Splits EFFORT_ENUM into _el_arr under a KNOWN IFS. Every consumer sets its own IFS —
# state-patch.sh runs under `IFS=$'\n\t'` — and a bare `for t in $EFFORT_ENUM` there yields
# the whole enum as ONE word, so every lookup fails and every effort reads as off-ladder.
# `IFS=' ' read` scopes the override to the builtin instead of mutating the caller's shell.
_effort_split() {
  IFS=' ' read -r -a _el_arr <<< "$EFFORT_ENUM"
}

# 0-based position in EFFORT_ENUM; rc 2 and no output for anything not on the ladder.
# Callers use this to compare a requested tier against a resolved one.
effort_rank() { # <effort>
  _effort_split
  _el_i=0
  while [ "$_el_i" -lt "${#_el_arr[@]}" ]; do
    if [ "${_el_arr[$_el_i]}" = "${1:-}" ]; then
      printf '%s' "$_el_i"
      return 0
    fi
    _el_i=$((_el_i + 1))
  done
  return 2
}

# One rung up the ladder, saturating at the top. `max` in yields `max` out — a saturating
# bump, never an error, because a stage already at the ceiling still gets a resolver.
# rc 2 and no output for an effort not on the ladder: an unknown tier must not silently
# become `low`.
effort_plus_one() { # <effort>
  _el_r=$(effort_rank "${1:-}") || return 2
  _effort_split
  _el_n=$((_el_r + 1))
  if [ "$_el_n" -ge "${#_el_arr[@]}" ]; then
    _el_n=$((${#_el_arr[@]} - 1))
  fi
  printf '%s' "${_el_arr[$_el_n]}"
}

# The tier a Step C.0a resolver actually dispatches at: one rung above the emitting stage,
# then clamped to what the stage's own model can carry. Model is unchanged by design — only
# effort moves — so the clamp is the only place the model is consulted.
#
# Compare the result against `effort_plus_one` to detect a clamp; the caller audits
# `effort_clamped` when they differ.
effort_for_resolver() { # <stage effort> <stage model alias>
  _el_bumped=$(effort_plus_one "${1:-}") || return 2
  # These models carry every rung, so there is nothing to clamp.
  if [[ "${2:-}" =~ $EFFORT_FULL_LADDER_RE ]]; then
    printf '%s' "$_el_bumped"
    return 0
  fi
  _el_want=$(effort_rank "$_el_bumped") || return 2
  _el_cap=$(effort_rank "$EFFORT_CAPPED_CEILING") || return 2
  if [ "$_el_want" -gt "$_el_cap" ]; then
    printf '%s' "$EFFORT_CAPPED_CEILING"
  else
    printf '%s' "$_el_bumped"
  fi
}
