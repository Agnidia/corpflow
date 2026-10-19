#!/usr/bin/env bash
# PostModelSwitch → audit.jsonl writer (corpflow worktask plugin).
# Appends one model_switched row recording what the session actually moved to,
# so a stage's cost can be attributed to the model that ran rather than the one
# metadata.model requested.
#
# Payload field names are UNCONFIRMED — see hooks/model-switch-gate.sh for the
# CONFIRMED/ASSUMED split this shares.
#
# Unlike audit-tooluse.sh this is gated on an existing ledger: PostModelSwitch
# fires in every session, and an incidental /model switch in an ordinary chat must
# not materialize .context/logs/ in an unrelated directory.
#
# Self-test: pass --self-test.
set -eu

SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

# Guarded source (AD-2): a truncated library is a syntax error, fatal under
# `set -e` and unrescuable by `||`, which `[ -f ]` alone does not cover. The
# `command -v` probe then catches the likelier failure, a renamed symbol; it names
# the LAST symbol the library defines, so a mid-file truncation is caught too.
# Degraded signalling is library-free — the audit appender is IN the library.
_LIB="$(dirname "$0")/model-switch-lib.sh"
_cf_opts=$-
set +e
# shellcheck source=hooks/model-switch-lib.sh
[ -f "$_LIB" ] && . "$_LIB"
case "$_cf_opts" in *e*) set -e ;; esac

if ! command -v corpflow_hook_audit_row > /dev/null 2>&1; then
  echo "model-switch-audit: shared library unusable at $_LIB — switch not recorded" >&2
  # The full ladder lives in the library this branch cannot trust, so the
  # sentinel is only ever planted under an explicitly DECLARED root, never one
  # this hook would have to go looking for itself.
  _cf_ctx=""
  if [ -n "${WORKSPACE_ROOT:-}" ] && [ -f "${WORKSPACE_ROOT}/.context/state.json" ]; then
    _cf_ctx="${WORKSPACE_ROOT}/.context"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "${CLAUDE_PROJECT_DIR}/.context/state.json" ]; then
    _cf_ctx="${CLAUDE_PROJECT_DIR}/.context"
  fi
  if [ -n "$_cf_ctx" ] && [ -f "$_cf_ctx/state.json" ]; then
    { mkdir -p "$_cf_ctx/logs" && : > "$_cf_ctx/logs/.corpflow-lib-missing"; } 2> /dev/null || :
  fi
  exit 0
fi

read_stdin() {
  if [ "$SELF_TEST" -eq 1 ]; then
    printf '%s' '{"session_id":"sess_test","agent_id":"agt_test","from_model":"opus","to_model":"sonnet"}'
  else
    cat
  fi
}

if ! command -v jq > /dev/null 2>&1; then
  echo "model-switch-audit: jq not found, skipping" >&2
  exit 0
fi

# run_audit <payload> <ctx> -> appends one row, or nothing. Returns 0 always.
run_audit() {
  _payload="$1"
  _ctx="$2"

  [ -f "$_ctx/state.json" ] || return 0

  # One jq over the payload, one over the ledger. An empty payload read means
  # unparseable JSON — nothing to attribute, so no row.
  _fields=$(corpflow_switch_fields "$_payload")
  [ -n "$_fields" ] || return 0
  # Split by parameter expansion, not a tab-delimited `read`: TAB is IFS
  # *whitespace*, so read collapses a run of tabs into ONE delimiter and an empty
  # middle field then silently shifts every later field. @tsv escapes any tab
  # inside a value, so the three separators here are unambiguous.
  _rest="$_fields"
  _agent_id="${_rest%%$'\t'*}"; _rest="${_rest#*$'\t'}"
  _dest="${_rest%%$'\t'*}"; _rest="${_rest#*$'\t'}"
  _origin="${_rest%%$'\t'*}"
  _trigger_unused="${_rest#*$'\t'}"

  _pin_row=$(corpflow_stage_and_pin "$_ctx" "$_agent_id")
  _stage=""
  _pin=""
  _task_id=""
  if [ -n "$_pin_row" ]; then
    _rest="$_pin_row"
    _stage="${_rest%%$'\t'*}"; _rest="${_rest#*$'\t'}"
    _pin="${_rest%%$'\t'*}"
    _task_id="${_rest#*$'\t'}"
  fi

  # Same-family rule as the gate's row 3: an alias and a resolved id are one tier.
  # Only when either side is unrecognized does the raw spelling decide.
  _pin_family=$(corpflow_model_family "$_pin")
  _dest_family=$(corpflow_model_family "$_dest")
  _off_tier=false
  if [ -n "$_pin" ] && [ -n "$_dest" ]; then
    if [ -n "$_pin_family" ] && [ -n "$_dest_family" ]; then
      [ "$_pin_family" = "$_dest_family" ] || _off_tier=true
    else
      [ "$_pin" = "$_dest" ] || _off_tier=true
    fi
  fi

  # The appender never parses a payload, so dedupe_key is composed here. That
  # split is what lets one shared writer serve three differing row shapes.
  #
  # The row's own ts must equal the appender's, so it is computed once here and
  # passed through; deriving it twice would key the dedupe on a timestamp the row
  # does not carry.
  _ts=$(date -u +%FT%TZ 2> /dev/null) || _ts="unknown"
  _meta=$(printf '%s' "$_payload" | jq -c \
    --arg ts "$_ts" --arg stage "$_stage" --arg task "$_task_id" \
    --arg pin "$_pin" --arg dest "$_dest" --arg origin "$_origin" \
    --argjson off_tier "$_off_tier" '
    {
      stage: $stage,
      task_id: $task,
      pinned: $pin,
      origin: $origin,
      resolved: $dest,
      off_tier: $off_tier,
      # ts is part of the key on purpose: audit-dedup collapses rows per key, and a
      # session that switches twice (fallback, then back) must keep both rows.
      dedupe_key: ((.session_id // "nosession") + ":" + (.agent_id // "noagent")
                   + ":model-switch:" + $ts + ":" + $dest)
    }') || { echo "model-switch-audit: jq parse failed" >&2; return 0; }

  _subject="$_task_id"
  [ -n "$_subject" ] || _subject="$_stage"
  [ -n "$_subject" ] || _subject="unknown"

  _tid="$_task_id"
  [ -n "$_tid" ] || _tid=$(corpflow_audit_task_id "$_ctx")

  corpflow_hook_audit_row --ctx "$_ctx" --actor hook:model-switch-audit \
    --action "model_switched" --result ok --subject "$_subject" --task-id "$_tid" \
    --meta "$_meta"
}

if [ "$SELF_TEST" -eq 1 ]; then
  _tmp=$(mktemp -d)
  trap 'rm -rf "$_tmp"' EXIT
  _fail=0
  _st_cases=0

  _sctx="$_tmp/ok/.context"
  mkdir -p "$_sctx"
  # subagent_type is schema-required but never read here: these hooks key on the
  # stage's pin, not on which agent holds it. Kept agent-agnostic so the fixture
  # does not imply an agent dependency the code does not have.
  printf '%s' '{"version":1,"worktask_id":"wid-ms","tasks":{"DV0":{"status":"in_progress"}},"facts":{"dispatched_agents":[{"stage":"DV","task_id":"DV0","subagent_type":"stage-agent","agent_id":"agt_test","model_requested":"opus","status":"launched"}]}}' > "$_sctx/state.json"
  run_audit "$(read_stdin)" "$_sctx"
  _st_cases=$((_st_cases + 1))
  tail -n 1 "$_sctx/logs/audit.jsonl" | jq -e '
    .action == "model_switched" and .metadata.task_id == "DV0"
    and .metadata.pinned == "opus" and .metadata.resolved == "sonnet"
    and .metadata.off_tier == true
  ' > /dev/null 2>&1 || { echo "model-switch-audit: self-test FAIL (row)"; _fail=$((_fail + 1)); }

  _nctx="$_tmp/none/.context"
  mkdir -p "$_nctx"
  run_audit '{"session_id":"s","to_model":"sonnet"}' "$_nctx"
  _st_cases=$((_st_cases + 1))
  [ ! -d "$_nctx/logs" ] || { echo "model-switch-audit: self-test FAIL (no-ledger wrote logs)"; _fail=$((_fail + 1)); }

  [ "$_fail" -eq 0 ] || { echo "model-switch-audit: self-test FAIL ($((_st_cases - _fail)) passed, $_fail failed)"; exit 1; }
  echo "model-switch-audit: self-test OK ($_st_cases passed, 0 failed)"
  exit 0
fi

PAYLOAD=$(read_stdin)
CTX=$(corpflow_context_root)
run_audit "$PAYLOAD" "$CTX"
exit 0
