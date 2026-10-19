#!/usr/bin/env bash
# PreCompact → state checkpoint (corpflow worktask plugin).
# Copies .context/state.json to .context/state.checkpoint-<ts>.json before
# auto-compaction so long worktask runs survive context summarization.
# Pairs with the existing PostCompact recovery prose in
# skills/context-compression/SKILL.md.
#
# Exit code is always 0 — never blocks compaction. Optional opt-in flag
# --block-on-active-handoff reserved for future use.
set -eu

SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

if [ "$SELF_TEST" -eq 1 ]; then
  TMP=$(mktemp -d)
  echo '{"run_index":0,"tasks":{}}' > "$TMP/state.json"
  cp "$TMP/state.json" "$TMP/state.checkpoint-test.json"
  [ -f "$TMP/state.checkpoint-test.json" ] || { echo "precompact-checkpoint: self-test FAIL (0 passed, 1 failed)"; exit 1; }
  rm -rf "$TMP"
  echo "precompact-checkpoint: self-test OK (1 passed, 0 failed)"
  exit 0
fi

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

PROJECT_DIR="${CONTEXT_DIR%/.context}"
LOG_DIR="$CONTEXT_DIR/logs"
STATE_FILE="$CONTEXT_DIR/state.json"

mkdir -p "$LOG_DIR"

TS=$(date -u +%Y%m%d-%H%M%S)
CHECKPOINT="$CONTEXT_DIR/state.checkpoint-$TS.json"

if [ ! -f "$STATE_FILE" ]; then
  # No active worktask state — nothing to checkpoint, but record the event.
  # Refuse a symlinked audit.jsonl: following it makes this append a write primitive
  # against an arbitrary target. A lost row never blocks the caller.
  if command -v jq >/dev/null 2>&1 && [ ! -L "$LOG_DIR/audit.jsonl" ]; then
    jq -cn --arg ts "$(date -u +%FT%TZ)" '{
      ts: $ts,
      actor: "hook:precompact",
      action: "precompact_checkpoint",
      result: "skipped",
      metadata: { reason: "no state.json" }
    }' >> "$LOG_DIR/audit.jsonl" || true
  fi
  exit 0
fi

# Guarded, not bare: under `set -eu` a failed copy would abort the script before
# the audit row below, so the one outcome a resume must not miss — "the
# checkpoint you are about to look for does not exist" — was the only outcome
# that left no trace anywhere. Failure is recorded and still exits 0.
CHECKPOINT_RESULT="ok"
CHECKPOINT_ERROR=""
if [ -L "$CHECKPOINT" ]; then
  # Same refusal the two audit appends make, for the same reason: cp -p follows a
  # destination symlink, which turns the checkpoint into a write primitive against an
  # arbitrary target. The name is a 1-second-granularity timestamp and fully predictable,
  # so pre-placement is awkward rather than impossible. Recorded rather than silently
  # skipped — a resume must never have to infer a missing checkpoint.
  CHECKPOINT_RESULT="error"
  CHECKPOINT_ERROR="checkpoint destination is a symlink; refused"
elif ! CHECKPOINT_ERROR=$(cp -p "$STATE_FILE" "$CHECKPOINT" 2>&1); then
  CHECKPOINT_RESULT="error"
  # A partial copy is worse than none: it would restore as a truncated ledger.
  rm -f "$CHECKPOINT" 2> /dev/null || true
fi

# Capture pointers to current planning/coordination/development artifacts.
ARTIFACTS=$(find "$CONTEXT_DIR" -maxdepth 1 -type f \( \
  -name 'planning-*.md' -o -name 'coordination-*.md' -o -name 'development-*.md' \
\) 2>/dev/null | sort | jq -R . | jq -s . || echo '[]')

RUN_INDEX="unknown"
if command -v jq >/dev/null 2>&1; then
  RUN_INDEX=$(jq -r '.run_index // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
fi

# Refuse a symlinked audit.jsonl: following it makes this append a write primitive
# against an arbitrary target. A lost row never blocks the caller.
if command -v jq >/dev/null 2>&1 && [ ! -L "$LOG_DIR/audit.jsonl" ]; then
  jq -cn \
    --arg ts "$(date -u +%FT%TZ)" \
    --arg state_file "${CHECKPOINT#$PROJECT_DIR/}" \
    --arg run_index "$RUN_INDEX" \
    --arg result "$CHECKPOINT_RESULT" \
    --arg error "$CHECKPOINT_ERROR" \
    --argjson artifacts "$ARTIFACTS" '{
      ts: $ts,
      actor: "hook:precompact",
      action: "precompact_checkpoint",
      result: $result,
      metadata: ({
        state_file: $state_file,
        run_index: $run_index,
        artifacts: $artifacts
      } + (if $result == "ok" then {} else { error: $error } end))
    }' >> "$LOG_DIR/audit.jsonl" || true
fi

exit 0
