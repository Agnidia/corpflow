#!/usr/bin/env bash
# @description sweep-stub-lib.sh — the SweepStub predicate, shared verbatim by the two
#   enforcers of `handoff.open_questions[]`: handoff-harness.sh (the frontmatter shape gate)
#   and state-patch.sh (the --facts ledger writer).
#
#   One definition, two enforcers: a stub that passes one and fails the other is the class of
#   disagreement this file exists to make impossible. Values are deduplicated here; the
#   semantics are pinned by the parity table in tests/shell/worktask/sweep-stub-lib.bats.
#
#   Sources nothing, sets no options, does no work at load. Consumers interpolate the
#   constants into a yq expression or pass them to jq as --arg/--argjson — never splice a
#   regex into a jq program body, which would make the program caller-controlled.
#
#   Symbols: SWEEP_ID_RE, SWEEP_CLASS_ENUM, SWEEP_REF_RE.
#
# Minimum shell: bash 3.2+ (macOS default).

# The constants are read by the sourcing enforcers, never inside this file.
# shellcheck disable=SC2034

# Anti-execution guard — MUST be the first statement.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  printf >&2 'sweep-stub-lib.sh: this is a library — source it, do not execute it directly\n'
  exit 2
fi

# Include guard: a double source is a no-op rather than a re-assignment.
[ -n "${_CORPFLOW_SWEEP_STUB_LIB:-}" ] && return 0
_CORPFLOW_SWEEP_STUB_LIB=1

# Not `readonly`: the two enforcers' bats suites source this file more than once per process,
# and a second readonly assignment is rc 1, which kills a `set -e` caller.

# `sw-<TASK_ID>-<n>` — task-scoped so the ledger's union on .id cannot collide across stages.
SWEEP_ID_RE='^sw-[A-Z]{2}[0-9]+-[0-9]+$'

# The whole class vocabulary. Space-delimited so a `case` and a jq --argjson both derive from it.
# Deliberately two values. A risk-shaped observation — one that records something without asking
# anything — is NOT a sweep item and gets no class here: it belongs in the artifact's `follow-ups`
# anchor (`skills/worktask/references/contracts/sweep-items.md § A risk-shaped observation is not a sweep item`).
SWEEP_CLASS_ENUM='decision escalate'

# An optional `.md` path, then exactly one `#`, then a non-empty lowercase-kebab anchor. The
# anchor is mandatory because it is the sole transport of the options[] the gate renders: an
# empty or anchor-less ref reaches the render with nothing to resolve.
SWEEP_REF_RE='^([A-Za-z0-9._/-]+\.md)?#[a-z0-9][a-z0-9-]*$'
