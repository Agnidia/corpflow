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
# Phantom rows: the runtime fires this event on a ~31s cadence for the whole life
# of a dispatch, so one real agent produced 21 rows. Those are suppressed (see
# SUPPRESS below) and COUNTED, because a suppression that leaves no trace narrows
# the audit trail invisibly, which is the failure class this hook exists to
# record rather than create.
#
# The discriminator is a repeated dedupe_key, never the row's fields: every stop
# the runtime delivers, phantom or terminal, arrives with no stage and duration 0,
# so those fields cannot tell them apart. A phantom is a key the trail already
# holds — the duplicate the dedupe_key is declared for.
set -eu

# The shared appender, sourced under the guarded idiom. `[ -f ]` alone does not
# cover a TRUNCATED library: a syntax error in a sourced file is fatal under
# `set -e` and `||` cannot rescue it, which would turn a hook whose contract is
# "exit 0 always" into a hard failure. Capture `$-`, drop `-e` across the source,
# restore, then probe for the symbol — the library is `readonly -f` and refuses
# redefinition, so the probe is the only honest test that it loaded.
_LIB="$(dirname "$0")/model-switch-lib.sh"
_CF_OPTS=$-
set +e
# shellcheck source=hooks/model-switch-lib.sh
[ -f "$_LIB" ] && . "$_LIB"
case "$_CF_OPTS" in *e*) set -e ;; esac
LIB_DEGRADED=0
command -v corpflow_hook_audit_row > /dev/null 2>&1 || LIB_DEGRADED=1

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

# A pending window older than this flushes on the next invocation that reads it,
# so a dispatch that is still running reports its suppressions instead of holding
# them until it ends. Five minutes is ten cadence ticks: long enough that the
# common case reports one summary per dispatch rather than a stream of them,
# short enough that a stale file cannot accumulate for the life of a session.
SUPPRESS_WINDOW_S=300

# Bound on the retained tokens of one window. Reached only when a window cannot
# be reported for a long time — the degraded session sw-SR0-3 option A opens by
# refusing to claim what it cannot report. Beyond the cap the append is skipped
# and the eventual summary marks itself truncated, so the growth is bounded and
# says so. A thousand tokens is ~8h at the observed cadence: no honest dispatch
# reaches it, and a session that does has a bigger problem than its line count.
SUPPRESS_PENDING_MAX=1000

# One token appended per suppression, never a read-increment-write on a counter.
# Two hooks fire on the same SubagentStop and parallel worktask streams run
# concurrently, so read-modify-write races and silently under-counts — which
# would reproduce this finding's own defect class inside its fix. An O_APPEND
# write below PIPE_BUF is atomic on every platform this runs on, so concurrent
# appends interleave without loss. The file is named by SESSION ONLY so a second
# concurrent hook appends to the same file rather than racing to create its own.
pending_file() {
  printf '%s/.subagent-suppressed.%s' "$LOG_DIR" \
    "$(printf '%s' "${1:-nosession}" | LC_ALL=C tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
}

# flush_reportable -> 0 when a summary row can actually reach audit.jsonl.
#
# Checked BEFORE the claim, never after: the flush destroys the only record that
# suppression happened, so claiming a window it cannot report would delete the
# trace of a narrowing — the exact failure this hook exists to record rather than
# create. The appender returns 0 on every refusal by design and cannot report a
# dropped row, so its refusals have to be anticipated here instead of detected
# afterwards. Two are reachable from the flush: a degraded library and a
# symlinked audit.jsonl. The other two the appender guards are not — an absent
# `jq` exits this hook long before any suppression is recorded, and a failed
# `mkdir` of the log directory aborts it under `set -e`.
#
# Named residual: a write that fails INSIDE the appender still loses the window,
# and no caller can see it. Closing that needs the appender to report success,
# which pulls a second owner's file into scope (sw-SR0-3 option C).
flush_reportable() {
  [ "$LIB_DEGRADED" -eq 0 ] || return 1
  [ ! -L "$LOG_DIR/audit.jsonl" ] || return 1
  return 0
}

# Rename-then-count, never truncate-then-count: a suppression landing between the
# read and the truncate would be lost, and losing the record is exactly what the
# counting exists to prevent. The rename is the claim — a second flusher racing
# here finds the file gone, its `mv` fails, and it emits nothing rather than
# double-reporting the same window.
flush_suppressed() {
  local _session="$1" _pending _claim _n _first _last _trunc=false
  _pending="$(pending_file "$_session")"
  [ -f "$_pending" ] || return 0
  # `mv` moves the symlink itself, but every read below FOLLOWS it: wc, head and
  # tail would report on the target and put two of its lines into audit.jsonl as
  # the window bounds. That makes the flush an arbitrary-file read on top of the
  # append the guard below refuses, so both legs are closed.
  [ ! -L "$_pending" ] || return 0
  flush_reportable || return 0
  _claim="$_pending.flushing.$$"
  mv -f "$_pending" "$_claim" 2> /dev/null || return 0
  _n=$(wc -l < "$_claim" 2> /dev/null | tr -d ' ') || _n=0
  _first=$(head -n 1 "$_claim" 2> /dev/null | cut -d' ' -f2) || _first=""
  _last=$(tail -n 1 "$_claim" 2> /dev/null | cut -d' ' -f2) || _last=""
  rm -f "$_claim" 2> /dev/null || true
  # Zero suppressions emit no summary row: an informational row reporting nothing
  # is noise in the trail it is meant to keep honest.
  [ "${_n:-0}" -gt 0 ] 2> /dev/null || return 0
  # A capped window reports a FLOOR, and says so. The exact number of events
  # dropped past the cap is not knowable without a second counter, and a second
  # counter is the read-increment-write race this design exists to avoid — so the
  # field is a flag rather than a count that would have to be invented.
  [ "$_n" -lt "$SUPPRESS_PENDING_MAX" ] || _trunc=true
  corpflow_hook_audit_row \
    --ctx "$CTX" \
    --actor "hook:audit-subagent" \
    --action "subagent_stops_suppressed" \
    --subject "$_session" \
    --task-id "$(corpflow_audit_task_id "$CTX")" \
    --result "ok" \
    --meta "$(jq -cn --argjson n "$_n" --argjson t "$_trunc" --arg from "$_first" --arg to "$_last" \
      '{suppressed_count: $n, truncated: $t, window_start: $from, window_end: $to}' \
      2> /dev/null || printf '{}')"
}

# The window is measured from the FIRST token, not from the file mtime: with
# suppressions still arriving every ~31s the mtime never ages, so an mtime-based
# window would never fire during the long dispatch it exists to serve.
window_expired() {
  local _first_epoch="$1" _now
  # A non-numeric first field means a corrupt or hand-edited window file; under
  # `set -u` feeding it to $(( )) would abort the hook, so decline instead.
  case "$_first_epoch" in '' | *[!0-9]*) return 1 ;; esac
  _now=$(date -u +%s 2> /dev/null) || return 1
  [ $((_now - _first_epoch)) -ge "$SUPPRESS_WINDOW_S" ]
}

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

SESSION=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "nosession"' 2> /dev/null) || SESSION="nosession"
[ -n "$SESSION" ] || SESSION="nosession"

# The trail itself is the seen-set, so there is no second store to race or drift.
# The fragment is JSON-encoded the way jq -c wrote it into the row, making the
# fixed-string match byte-exact; a symlinked trail reads as empty because the
# append below refuses it anyway.
#
# Residual: the surviving row is the FIRST firing, so its `ts` is the cadence
# tick after launch; the summary row's window_end marks a dispatch's last event.
SUPPRESS=0
DEDUPE_FRAG="\"dedupe_key\":$(printf '%s' "$ROW" | jq -r '.metadata.dedupe_key' | jq -R .)"
if [ -f "$LOG_DIR/audit.jsonl" ] && [ ! -L "$LOG_DIR/audit.jsonl" ] \
  && grep -qF -- "$DEDUPE_FRAG" "$LOG_DIR/audit.jsonl" 2> /dev/null; then
  SUPPRESS=1
fi

PENDING="$(pending_file "$SESSION")"

if [ "$SUPPRESS" -eq 1 ]; then
  # A symlinked window file turns this append into a write primitive against an
  # arbitrary target, the same reason audit.jsonl is refused below. Refuse rather
  # than follow: an unrecorded suppression is a bounded loss, an append into
  # someone else's file is not.
  [ ! -L "$PENDING" ] || exit 0
  FIRST_EPOCH=$(head -n 1 "$PENDING" 2> /dev/null | cut -d' ' -f1) || FIRST_EPOCH=""
  # `wc -l <` on an absent file is a SHELL redirect error that no `2>` on wc can
  # silence, so the first suppression of every window would print to stderr.
  PENDING_LINES=0
  [ ! -f "$PENDING" ] || PENDING_LINES=$(wc -l < "$PENDING" 2> /dev/null | tr -d ' ') || PENDING_LINES=0
  case "$PENDING_LINES" in '' | *[!0-9]*) PENDING_LINES=0 ;; esac
  if [ "$PENDING_LINES" -lt "$SUPPRESS_PENDING_MAX" ]; then
    # Epoch first, ISO second: the window arithmetic needs no portable date parser,
    # and the human-readable half still reaches the summary row's metadata.
    printf '%s %s\n' "$(date -u +%s)" "$(date -u +%FT%TZ)" >> "$PENDING" 2> /dev/null || true
  fi
  window_expired "$FIRST_EPOCH" && flush_suppressed "$SESSION"
  exit 0
fi

# A symlinked audit.jsonl turns this append into a write primitive against an arbitrary
# target. Refuse rather than follow — the guard hooks/model-switch-lib.sh carries for the
# hook rows it writes, and tests/shell/hooks/test-execution-gate.bats pins.
[ ! -L "$LOG_DIR/audit.jsonl" ] || exit 0
printf '%s\n' "$ROW" >> "$LOG_DIR/audit.jsonl"

# A genuine stop is the natural "something real happened" boundary, and the only
# trigger that can bound the window from inside a stateless hook: there is no
# end-of-dispatch event to hang it on.
#
# Documented residual: a session whose very last event is a suppression and which
# never runs another subagent leaves that final partial window unreported. Bounded
# and named, not silent.
flush_suppressed "$SESSION"
exit 0
