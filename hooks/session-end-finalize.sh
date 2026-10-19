#!/usr/bin/env bash
# SessionEnd → ledger finalization record (corpflow worktask plugin).
# Appends one session_end_finalize row to .context/logs/audit.jsonl naming the
# tasks still in_progress when the session tore down. Background work killed by
# teardown otherwise ends with no completion record at all, so a resume cannot
# distinguish "still running" from "died with the session".
#
# Reports; it does NOT mutate task status. A teardown hook races the very writer
# it would have to take the ledger lock from, and a wrong terminal status is
# worse than an honest "unsettled at session end".
#
# Exit code is always 0 — a lost row must never delay teardown. The plugin.json
# entry's `timeout` bounds the run: without one, SessionEnd hooks get a 1.5 s
# budget that a slow ledger can outlast, losing the row.
set -eu

SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

if [ "$SELF_TEST" -eq 1 ]; then
  TMP=$(mktemp -d)
  mkdir -p "$TMP/.context"
  echo '{"run_index":0,"tasks":{"DV0":{"status":"in_progress"}}}' > "$TMP/.context/state.json"
  printf '%s' '{"hook_event_name":"SessionEnd","reason":"clear"}' \
    | env -u WORKSPACE_ROOT CLAUDE_PROJECT_DIR="$TMP" "$0" > /dev/null 2>&1
  if ! grep -q '"session_end_reason":"clear"' "$TMP/.context/logs/audit.jsonl" 2> /dev/null; then
    echo "session-end-finalize: self-test FAIL (0 passed, 1 failed)"
    rm -rf "$TMP"
    exit 1
  fi
  rm -rf "$TMP"
  echo "session-end-finalize: self-test OK (1 passed, 0 failed)"
  exit 0
fi

# The payload arrives on stdin like every other hook event; `reason` names the
# teardown cause (clear / logout / prompt_input_exit / other). Read only when
# something is attached, so a bare invocation cannot hang on a terminal — and
# below the self-test branch, whose own stdin is whatever harness invoked it.
PAYLOAD=""
[ -t 0 ] || PAYLOAD=$(cat 2> /dev/null || printf '')

# Guarded source of the shared root ladder: resolve BEFORE any
# mkdir, so an unresolved root leaves no `.context/` trace under whatever cwd
# this fired from.
_LIB="$(dirname "$0")/model-switch-lib.sh"
_CF_OPTS=$-
set +e
# shellcheck source=hooks/model-switch-lib.sh
[ -f "$_LIB" ] && . "$_LIB"
case "$_CF_OPTS" in *e*) set -e ;; esac

if command -v corpflow_context_root > /dev/null 2>&1; then
  CONTEXT_DIR=$(corpflow_context_root)
else
  # Degraded: declared roots only, requiring an existing ledger — never cwd.
  CONTEXT_DIR=""
  if [ -n "${WORKSPACE_ROOT:-}" ] && [ -f "${WORKSPACE_ROOT}/.context/state.json" ]; then
    CONTEXT_DIR="${WORKSPACE_ROOT}/.context"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "${CLAUDE_PROJECT_DIR}/.context/state.json" ]; then
    CONTEXT_DIR="${CLAUDE_PROJECT_DIR}/.context"
  fi
fi
[ -n "$CONTEXT_DIR" ] || exit 0

LOG_DIR="$CONTEXT_DIR/logs"
STATE_FILE="$CONTEXT_DIR/state.json"

mkdir -p "$LOG_DIR" 2> /dev/null || true

# Refuse a symlinked audit.jsonl: following it makes this append a write primitive
# against an arbitrary target. A lost row never blocks the caller.
command -v jq > /dev/null 2>&1 || exit 0
[ ! -L "$LOG_DIR/audit.jsonl" ] || exit 0

REASON=$(printf '%s' "$PAYLOAD" | jq -r '.reason // "unknown"' 2> /dev/null) || REASON="unknown"
[ -n "$REASON" ] || REASON="unknown"

if [ ! -f "$STATE_FILE" ]; then
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg reason "$REASON" '{
    ts: $ts,
    actor: "hook:session-end",
    action: "session_end_finalize",
    result: "skipped",
    metadata: { reason: "no state.json", session_end_reason: $reason }
  }' >> "$LOG_DIR/audit.jsonl" || true
  exit 0
fi

# Unsettled means in_progress only. `pending`/`blocked` never started, and the
# settled set is enumerated downstream — reading it here would re-encode an enum
# this hook has no reason to know.
SUMMARY=$(jq -c '{
  run_index: (.run_index // "unknown" | tostring),
  unsettled: [ (.tasks // {}) | to_entries[] | select(.value.status == "in_progress") | .key ],
  status_counts: ((.tasks // {}) | to_entries | map(.value.status // "unknown")
                  | group_by(.) | map({ key: .[0], value: length }) | from_entries)
}' "$STATE_FILE" 2> /dev/null) || SUMMARY=""
[ -n "$SUMMARY" ] || SUMMARY='{"run_index":"unknown","unsettled":[],"status_counts":{}}'

# A headless child's own in_progress row is real, ongoing stage work, not a session that
# died unnoticed — CORPFLOW_HEADLESS_CHILD (set by headless-dispatch.sh's spawn env) tags
# the row instead of leaving it read as an ordinary unsettled teardown.
HEADLESS_CHILD="${CORPFLOW_HEADLESS_CHILD:-}"

jq -cn \
  --arg ts "$(date -u +%FT%TZ)" \
  --arg reason "$REASON" \
  --arg headless_child "$HEADLESS_CHILD" \
  --argjson summary "$SUMMARY" '{
    ts: $ts,
    actor: "hook:session-end",
    action: "session_end_finalize",
    result: (if ($summary.unsettled | length) > 0 then "warn" else "ok" end),
    metadata: ($summary + { session_end_reason: $reason }
      + (if $headless_child == "" then {} else { headless_child: $headless_child } end))
  }' >> "$LOG_DIR/audit.jsonl" || true

exit 0
