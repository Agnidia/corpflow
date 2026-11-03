#!/usr/bin/env bash
# @description ledger-digest.sh — the one executable copy of preamble section [3]:
#   a ledger pointer plus a readiness digest, never the ledger JSON
#   (skills/worktask/references/contracts/prompt-layout.md#cache-prefix § Section [3] — ledger pointer and readiness
#   digest). Prints exactly the grammar body (marker excluded) to stdout, one
#   `key: value` line per key, this order, no JSON, no timestamps:
#     ledger: .context/state.json
#     run_index: <integer>
#     ready: <task ids, comma-separated, ascending key order | none>
#     in_progress: <ids | none>
#     blocked: <ids | none>
#     open_blocking_questions: <integer>
#
#   The first line is the literal `ledger: .context/state.json` — the pointer
#   every stage agent resolves from its OWN workspace, not the path this script
#   happened to read from. `--state` only tells this script where to read; it
#   never changes what gets printed on that line.
#
#   `ready` is `status == "pending"` with every `blocked_by` id `completed`, the
#   same idiom `skills/worktask/references/orchestration.md § Readiness is mechanical, not a
#   judgement call` runs between stages. `in_progress` is `status ==
#   "in_progress"`. `blocked` is `status == "blocked"`. All three lists are the
#   matching task ids sorted ascending (jq `sort`, lexicographic), joined by a
#   comma, or the literal `none` when empty. `open_blocking_questions` counts
#   `facts.open_questions[]` entries with `blocks_next_stage == true` and a
#   `status` other than `resolved` — a missing `status` counts as open.
#
#   Read-only: writes nothing, takes no lock, touches no audit log.
#
# @arg --state <path>   Ledger to read (default .context/state.json).
# @arg -h | --help      Print this header on stdout and exit 0.
# @arg --self-test       Builds temp ledgers under mktemp -d and asserts ready/
#                        in_progress/blocked, `none` rendering, open_blocking_questions
#                        counting, and exit 3 on a missing or unparseable ledger.
#
# @exitcode 0  Digest printed.
# @exitcode 2  Usage: unknown flag, --state with no value.
# @exitcode 3  Ledger missing, unreadable, not a parseable JSON object, or jq not found.
#
# Minimum shell: bash 3.2+ (macOS default) — no associative arrays, no `local -n`.

set -euo pipefail
IFS=$'\n\t'

usage() {
  awk 'NR>1{ if (!/^#/) exit; sub(/^# ?/,""); print }' "$0"
  exit 0
}

die_usage() {
  printf >&2 'ledger-digest: %s\n' "$1"
  exit 2
}

die_input() {
  printf >&2 'ledger-digest: %s\n' "$1"
  exit 3
}

STATE_ARG=""
SELFTEST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state)
      [[ $# -ge 2 && -n "$2" ]] || die_usage "--state needs a path"
      STATE_ARG="$2"
      shift 2
      ;;
    --self-test | --selftest)
      SELFTEST=1
      shift
      ;;
    -h | --help) usage ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

command -v jq > /dev/null 2>&1 || die_input "jq not found"

# print_digest <ledger-path> -> the digest body on stdout (marker excluded), or a
# non-zero return with nothing printed when the ledger is missing or unparseable.
print_digest() {
  local ledger="$1"
  [[ -r "$ledger" ]] || return 3
  jq -e 'type == "object"' "$ledger" > /dev/null 2>&1 || return 3

  local body
  body=$(jq -r '
    def sorted_join($ids):
      ($ids | sort) as $s | if ($s | length) == 0 then "none" else ($s | join(",")) end;

    (.tasks // {}) as $t
    | [ $t | to_entries[]
          | select(.value.status == "pending")
          | select([(.value.blocked_by // [])[] | $t[.].status] | all(. == "completed"))
          | .key
      ] as $ready
    | [ $t | to_entries[] | select(.value.status == "in_progress") | .key ] as $inprog
    | [ $t | to_entries[] | select(.value.status == "blocked") | .key ] as $blocked
    | ((.facts.open_questions // [])
        | map(select(.blocks_next_stage == true and ((.status // "") != "resolved")))
        | length) as $obq
    | (.run_index // 0) as $ri
    | "run_index: \($ri)",
      "ready: \(sorted_join($ready))",
      "in_progress: \(sorted_join($inprog))",
      "blocked: \(sorted_join($blocked))",
      "open_blocking_questions: \($obq)"
  ' "$ledger") || return 3

  printf 'ledger: .context/state.json\n%s\n' "$body"
}

# self_test — builds disposable ledgers under mktemp -d (trap cleanup) and
# re-invokes this script as "$0" against each, so the assertions exercise the
# real CLI (arg parsing, exit codes) rather than print_digest in isolation.
self_test() {
  _SELFTEST_PASSED=0
  local td
  td=$(mktemp -d "${TMPDIR:-/tmp}/ledger-digest-XXXXXX")
  # Expanded now on purpose: `td` is local and out of scope when the EXIT trap fires.
  # shellcheck disable=SC2064
  trap "rm -rf '$td'" EXIT

  # ---- ready / in_progress / blocked, the pending-with-completed-blockers
  # idiom, and an empty category rendering `none`.
  cat > "$td/ledger-mixed.json" <<'EOF'
{
  "run_index": 2,
  "tasks": {
    "PL0": { "status": "completed" },
    "DV0": { "status": "pending", "blocked_by": ["PL0"] },
    "DV1": { "status": "pending", "blocked_by": ["PL0", "DV0"] },
    "DR0": { "status": "in_progress" },
    "QA0": { "status": "blocked" }
  },
  "facts": { "open_questions": [] }
}
EOF
  local expected_mixed
  expected_mixed=$'ledger: .context/state.json\nrun_index: 2\nready: DV0\nin_progress: DR0\nblocked: QA0\nopen_blocking_questions: 0'
  local got_mixed
  got_mixed=$("$0" --state "$td/ledger-mixed.json") || {
    echo "self-test: mixed ledger digest: FAIL (nonzero exit)" >&2; exit 1
  }
  if [[ "$got_mixed" == "$expected_mixed" ]]; then
    echo "self-test: mixed ledger digest (ready/in_progress/blocked): ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: mixed ledger digest: FAIL" >&2
    echo "  expected: $expected_mixed" >&2
    echo "  got:      $got_mixed" >&2
    exit 1
  fi

  # ---- every category empty renders `none`, not a blank value.
  cat > "$td/ledger-empty.json" <<'EOF'
{
  "run_index": 0,
  "tasks": { "PL0": { "status": "completed" } },
  "facts": { "open_questions": [] }
}
EOF
  local expected_empty
  expected_empty=$'ledger: .context/state.json\nrun_index: 0\nready: none\nin_progress: none\nblocked: none\nopen_blocking_questions: 0'
  local got_empty
  got_empty=$("$0" --state "$td/ledger-empty.json") || {
    echo "self-test: empty-category ledger digest: FAIL (nonzero exit)" >&2; exit 1
  }
  if [[ "$got_empty" == "$expected_empty" ]]; then
    echo "self-test: empty-category 'none' rendering: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: empty-category 'none' rendering: FAIL" >&2
    echo "  expected: $expected_empty" >&2
    echo "  got:      $got_empty" >&2
    exit 1
  fi

  # ---- open_blocking_questions: blocks_next_stage==true and status not
  # "resolved" (a MISSING status counts as open); a resolved or non-blocking
  # entry is excluded either way.
  cat > "$td/ledger-obq.json" <<'EOF'
{
  "run_index": 1,
  "tasks": { "PL0": { "status": "completed" } },
  "facts": {
    "open_questions": [
      { "id": "sw-PL0-1", "blocks_next_stage": true, "status": "open" },
      { "id": "sw-PL0-2", "blocks_next_stage": true },
      { "id": "sw-PL0-3", "blocks_next_stage": true, "status": "resolved" },
      { "id": "sw-PL0-4", "blocks_next_stage": false, "status": "open" }
    ]
  }
}
EOF
  local got_obq
  got_obq=$("$0" --state "$td/ledger-obq.json") || {
    echo "self-test: open_blocking_questions count: FAIL (nonzero exit)" >&2; exit 1
  }
  if grep -qx 'open_blocking_questions: 2' <<< "$got_obq"; then
    echo "self-test: open_blocking_questions count (missing status counts as open): ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: open_blocking_questions count: FAIL (got: $got_obq)" >&2
    exit 1
  fi

  # ---- exit 3 on a missing ledger.
  local rc=0
  "$0" --state "$td/does-not-exist.json" > /dev/null 2>&1 || rc=$?
  if [[ $rc -eq 3 ]]; then
    echo "self-test: missing-ledger exit 3: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: missing-ledger exit 3: FAIL (rc=$rc)" >&2; exit 1
  fi

  # ---- exit 3 on an unparseable (invalid JSON) ledger.
  printf 'not json at all {' > "$td/ledger-bad.json"
  rc=0
  "$0" --state "$td/ledger-bad.json" > /dev/null 2>&1 || rc=$?
  if [[ $rc -eq 3 ]]; then
    echo "self-test: invalid-JSON exit 3: ok"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  else
    echo "self-test: invalid-JSON exit 3: FAIL (rc=$rc)" >&2; exit 1
  fi

  echo "self-test: ALL PASS ($_SELFTEST_PASSED passed, 0 failed)"
}

if [[ "$SELFTEST" -eq 1 ]]; then
  self_test
  exit $?
fi

LEDGER="${STATE_ARG:-.context/state.json}"
if ! print_digest "$LEDGER"; then
  die_input "ledger missing or unparseable: $LEDGER"
fi
exit 0
