#!/usr/bin/env bash
# Stage-completion audit row for the PL/FN/ST worktask-boundary agents.
# Registered in plugin.json under SubagentStop, one matcher group per agent
# (`^corpflow:<agent>$`) passing that agent's `--stage`. Claude Code ignores
# `hooks:` in plugin agent frontmatter, so the anchored matcher is what scopes
# this hook to those three agents.
#
# Writes one canonical `stage_completion_hook` row to
# .context/logs/audit.jsonl.
set -eu

STAGE="unknown"
SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) shift; STAGE="${1:-unknown}" ;;
    --self-test) SELF_TEST=1 ;;
  esac
  shift
done

read_stdin() {
  if [ "$SELF_TEST" -eq 1 ]; then
    printf '%s' '{"agent_type":"corpflow:product-manager","agent_id":"agt_pl","session_id":"sess_test","parent_agent_id":"agt_parent","background_tasks":[{"id":"bg1"},{"id":"bg2"}],"session_crons":[{"id":"cr1"}]}'
  else
    cat
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "agent-stop: jq not found, skipping" >&2
  exit 0
fi

PAYLOAD=$(read_stdin)

ROW=$(printf '%s' "$PAYLOAD" | jq -c \
  --arg ts "$(date -u +%FT%TZ)" \
  --arg stage "$STAGE" '
  {
    ts: $ts,
    actor: "hook:agent-stop",
    action: "stage_completion_hook",
    subject: (.agent_type // "unknown"),
    result: "ok",
    metadata: {
      stage: $stage,
      # Payload only: $CLAUDE_EFFORT keeps the requested tier even on haiku, which runs none.
      effort: (.effort.level // "unknown"),
      parent_agent_id: (.parent_agent_id // "none"),
      background_tasks_count: ((.background_tasks // []) | length),
      background_task_ids: ((.background_tasks // []) | map(.id // .task_id // "unknown")),
      session_crons_count: ((.session_crons // []) | length),
      session_cron_ids: ((.session_crons // []) | map(.id // .cron_id // "unknown")),
      dedupe_key: ((.session_id // "nosession") + ":" + (.agent_id // "noagent") + ":stage:" + $stage)
    }
  }') || {
    echo "agent-stop: jq parse failed" >&2
    exit 0
  }

if [ "$SELF_TEST" -eq 1 ]; then
  printf '%s\n' "$ROW" | jq -e '
    .action == "stage_completion_hook"
    and (.metadata.stage | type) == "string"
    and (.metadata.dedupe_key | startswith("sess_test:agt_pl:stage:"))
    and .metadata.parent_agent_id == "agt_parent"
    and .metadata.background_tasks_count == 2
    and .metadata.background_task_ids == ["bg1","bg2"]
    and .metadata.session_crons_count == 1
    and .metadata.session_cron_ids == ["cr1"]
  ' >/dev/null \
    || { echo "agent-stop: self-test FAIL (0 passed, 1 failed)"; exit 1; }
  echo "agent-stop: self-test OK (1 passed, 0 failed)"
  exit 0
fi

# Guarded source of the shared root ladder: a truncated library is a
# syntax error, fatal under `set -eu`, so `-e` is dropped across the source and
# restored rather than trusting `||` to rescue it.
_LIB="$(dirname "$0")/model-switch-lib.sh"
_CF_OPTS=$-
set +e
# shellcheck source=hooks/model-switch-lib.sh
[ -f "$_LIB" ] && . "$_LIB"
case "$_CF_OPTS" in *e*) set -e ;; esac

# Bind to the payload's /megatask issue before resolving: the inherited
# CLAUDE_PROJECT_DIR names the batch, not the issue this agent worked.
if command -v corpflow_bind_payload > /dev/null 2>&1; then
  corpflow_bind_payload "$PAYLOAD"
fi
if command -v corpflow_context_root > /dev/null 2>&1; then
  CTX=$(corpflow_context_root)
else
  # Degraded: declared roots only, requiring an existing ledger — never cwd.
  CTX=""
  if [ -n "${WORKSPACE_ROOT:-}" ] && [ -f "${WORKSPACE_ROOT}/.context/state.json" ]; then
    CTX="${WORKSPACE_ROOT}/.context"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "${CLAUDE_PROJECT_DIR}/.context/state.json" ]; then
    CTX="${CLAUDE_PROJECT_DIR}/.context"
  fi
fi
[ -n "$CTX" ] || exit 0

LOG_DIR="$CTX/logs"
mkdir -p "$LOG_DIR"

# Refuse a symlinked audit.jsonl: following it makes this append a write primitive
# against an arbitrary target. A lost row never blocks the caller.
[ ! -L "$LOG_DIR/audit.jsonl" ] || exit 0
printf '%s\n' "$ROW" >> "$LOG_DIR/audit.jsonl"
exit 0
