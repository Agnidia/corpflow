#!/usr/bin/env bash
# SubagentStop → audit.jsonl writer (corpflow worktask plugin).
# Replaces prose-instructed `subagent_stopped` row emission. Pairs with
# state-merge.sh; both fire on SubagentStop, both target .context/.
#
# Dedupe: metadata.dedupe_key = "<session_id>:<agent_id>:stop".
#
# The runtime sends `agent_type: ""` (not null) for plugin agents, so `//` alone
# leaves the row anonymous. Reader-keyed fields go through `first_nonempty`,
# which rejects "" as well as null.
#
# A repeated dedupe_key is a duplicate delivery and writes no second row. The
# key is the only discriminator: every stop arrives with no stage and duration 0.
set -eu

# The shared library, sourced under the guarded idiom. `[ -f ]` alone does not
# cover a TRUNCATED library: a syntax error in a sourced file is fatal under
# `set -e` and `||` cannot rescue it, which would turn a hook whose contract is
# "exit 0 always" into a hard failure. Capture `$-`, drop `-e` across the source,
# restore. Each use below probes for its symbol, because a partial load is silent.
_LIB="$(dirname "$0")/model-switch-lib.sh"
_CF_OPTS=$-
set +e
# shellcheck source=hooks/model-switch-lib.sh
[ -f "$_LIB" ] && . "$_LIB"
case "$_CF_OPTS" in *e*) set -e ;; esac

SELF_TEST=0
if [ "${1:-}" = "--self-test" ]; then
  SELF_TEST=1
  # Cleared in the parent shell, not in read_stdin's subshell: jq inherits from
  # here, so the identity/stage ladder must resolve to its terminal fallback.
  unset CLAUDE_SUBAGENT_TYPE CLAUDE_TASK_METADATA_STAGE || true
fi

# The self-test payload carries the empty-string identity the runtime actually
# sends for plugin agents.
read_stdin() {
  if [ "$SELF_TEST" -eq 1 ]; then
    printf '%s' '{"agent_type":"","agent_id":"agt_test","session_id":"sess_test","duration_ms":12345,"parent_agent_id":"agt_parent","background_tasks":[{"id":"bg1"},{"id":"bg2"}],"session_crons":[{"id":"cr1"}]}'
  else
    cat
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "audit-subagent: jq not found, skipping" >&2
  exit 0
fi

PAYLOAD=$(read_stdin)

# Resolved before the row is built: the ledger stage rung below needs the context root.
# The self-test never binds, so both new rungs stay empty and its stage stays "unknown".
LEDGER_STAGE=""
BANNER_STAGE=""
if [ "$SELF_TEST" -eq 0 ]; then
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

  # The runtime delivers every stop with no stage, so the ledger and brief rungs supply it.
  # Each rung yields a validated stage code or "", and every ambiguity falls to the next
  # rung rather than to a guess. US (0x1f) separates the fields because read collapses
  # runs of a whitespace IFS, which would shift an empty one.
  P_FIELDS=$(printf '%s' "$PAYLOAD" | jq -r '[.stage, .agent_id, .agent_transcript_path]
    | map(if type == "string" then gsub("[\u001f\n]"; " ") else "" end) | join("\u001f")' \
    2> /dev/null) || P_FIELDS=""
  IFS=$'\037' read -r P_STAGE P_AGENT P_TRANSCRIPT <<< "$P_FIELDS" || true
  if [ -z "${P_STAGE:-}" ] && [ -z "${CLAUDE_TASK_METADATA_STAGE:-}" ]; then
    # Any status: state-merge.sh and state-patch.sh --dispatch may flip the row on this
    # same SubagentStop, and a row's stage never changes. Not corpflow_stage_and_pin:
    # that answers the single in_progress task's stage, not the matched row's.
    if [ -n "${P_AGENT:-}" ] && [ -f "$CTX/state.json" ]; then
      LEDGER_STAGE=$(jq -r --arg aid "$P_AGENT" '
        (if (.facts | type) == "object" and (.facts.dispatched_agents | type) == "array"
          then .facts.dispatched_agents else [] end)
        | [.[] | select(type == "object" and .agent_id == $aid) | .stage | strings
           | select(test("^(PL|AR|TL|DV|DR|SR|QA|DC|RE|FN|ST|IR|ET)$"))]
        | unique | if length == 1 then .[0] else "" end' "$CTX/state.json" 2> /dev/null) \
        || LEDGER_STAGE=""
    fi
    # agent_transcript_path only: on SubagentStop, transcript_path is the parent's. The
    # stage line read is the one brief-compose.sh writes in the task-description block;
    # a `stage:` line elsewhere in the brief is not this agent's.
    if [ -z "$LEDGER_STAGE" ] && [ -n "${P_TRANSCRIPT:-}" ] \
      && command -v corpflow_first_user_text > /dev/null 2>&1; then
      BANNER_STAGE=$(corpflow_first_user_text "$P_TRANSCRIPT" | awk '
        /^<<<task-description>>>$/ { inb = 1; next }
        inb && /^<<</ { exit }
        inb && /^stage: (PL|AR|TL|DV|DR|SR|QA|DC|RE|FN|ST|IR|ET)$/ { print substr($0, 8); exit }
      ' 2> /dev/null) || BANNER_STAGE=""
    fi
  fi
fi

ROW=$(printf '%s' "$PAYLOAD" | jq -c \
  --arg ts "$(date -u +%FT%TZ)" --arg ledger_stage "$LEDGER_STAGE" --arg banner_stage "$BANNER_STAGE" '
  def first_nonempty: map(select(type == "string" and . != "")) | first // "unknown";
  {
    ts: $ts,
    actor: "hook:audit-subagent",
    action: "subagent_stopped",
    subject: ([.agent_type, env.CLAUDE_SUBAGENT_TYPE] | first_nonempty),
    result: (.status // "ok"),
    metadata: {
      stage: ([.stage, env.CLAUDE_TASK_METADATA_STAGE, $ledger_stage, $banner_stage] | first_nonempty),
      agent_id: ([.agent_id] | first_nonempty),
      duration_ms: ((.duration_ms // 0) | tonumber? // 0),
      # Payload only: $CLAUDE_EFFORT keeps the requested tier even on haiku, which runs none.
      effort: (.effort.level // "unknown"),
      parent_agent_id: (.parent_agent_id // "none"),
      background_tasks_count: ((.background_tasks // []) | length),
      background_task_ids: ((.background_tasks // []) | map(.id // .task_id // "unknown")),
      session_crons_count: ((.session_crons // []) | length),
      session_cron_ids: ((.session_crons // []) | map(.id // .cron_id // "unknown")),
      dedupe_key: ((.session_id // "nosession") + ":" + (.agent_id // "noagent") + ":stop")
    }
  }') || {
    echo "audit-subagent: jq parse failed" >&2
    exit 0
  }

if [ "$SELF_TEST" -eq 1 ]; then
  printf '%s\n' "$ROW" | jq -e '
    .metadata.dedupe_key == "sess_test:agt_test:stop"
    and .subject == "unknown"
    and .metadata.stage == "unknown"
    and .metadata.agent_id == "agt_test"
    and .metadata.parent_agent_id == "agt_parent"
    and .metadata.background_tasks_count == 2
    and .metadata.background_task_ids == ["bg1","bg2"]
    and .metadata.session_crons_count == 1
    and .metadata.session_cron_ids == ["cr1"]
  ' >/dev/null \
    || { echo "audit-subagent: self-test FAIL (0 passed, 1 failed)"; exit 1; }
  echo "audit-subagent: self-test OK (1 passed, 0 failed)"
  exit 0
fi

# The trail itself is the seen-set, so there is no second store to race or drift.
# The fragment is JSON-encoded the way jq -c wrote it into the row, making the
# fixed-string match byte-exact; a symlinked trail reads as empty because the
# append below refuses it anyway.
DEDUPE_FRAG="\"dedupe_key\":$(printf '%s' "$ROW" | jq -r '.metadata.dedupe_key' | jq -R .)"
if [ -f "$LOG_DIR/audit.jsonl" ] && [ ! -L "$LOG_DIR/audit.jsonl" ] \
  && grep -qF -- "$DEDUPE_FRAG" "$LOG_DIR/audit.jsonl" 2> /dev/null; then
  exit 0
fi

# A symlinked audit.jsonl turns this append into a write primitive against an arbitrary
# target. Refuse rather than follow — the guard hooks/model-switch-lib.sh carries for the
# hook rows it writes, and tests/shell/hooks/test-execution-gate.bats pins.
[ ! -L "$LOG_DIR/audit.jsonl" ] || exit 0
printf '%s\n' "$ROW" >> "$LOG_DIR/audit.jsonl"
exit 0
