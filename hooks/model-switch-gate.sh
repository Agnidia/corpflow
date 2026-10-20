#!/usr/bin/env bash
# model-switch-gate — PreModelSwitch gate refusing a mid-worktask re-tier away from
# the model a stage was dispatched with. No matcher in plugin.json; self-filters.
#
# DOCUMENTED: to_model, from_model, and source (command/picker/sdk) in the hooks reference.
# LIVE-UNCONFIRMED: no installed-build payload was observed; alternate spellings remain defensive.
# ASSUMED: agent_id may be present; the ledger supplies the acting stage when it is absent.
# Output uses systemMessage for notices and permissionDecisionReason for ask/deny.
#
# The PIN is not assumed: it comes from this plugin's own
# .facts.dispatched_agents[].model_requested.
#
# Behavior:
#   - Exits 0 ALWAYS. A block travels in the stdout JSON, never in the exit code —
#     hook-monitoring.md § PreToolUse decisions records that an exit-2 block holds
#     even when its JSON fails schema validation, so a wrong field guess paired with
#     a non-zero exit would wedge every session that switches models.
#   - Fails OPEN structurally, not by discipline: BLOCK is reachable only once the
#     destination coalesce matches a real field. If every guess is wrong the
#     destination is empty and the ladder can only reach silent-pass or annotate.
#   - The two axes fail open differently. The DESTINATION axis enforces once it
#     matches a real field. The TRIGGER axis only enforces once a trigger field is
#     observed: absent means no evidence (row 6a, annotate), present-but-unknown
#     means the field name is confirmed and only its vocabulary is not (row 6b,
#     the one reachable deny).
#   - Silent for any session with no worktask ledger, no single in_progress stage,
#     or no unambiguous pin — zero side effects, no directory creation.
#   - CORPFLOW_MODEL_SWITCH_GATE=off disables rows 4-6. Process env only; an agent
#     cannot self-serve it from a command string.
#   - jq absent -> exit 0.
set -eu

SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

# Guarded source (AD-2). A TRUNCATED library is worse than an absent one: a
# syntax error in a sourced file is fatal under `set -e` and `||` does NOT rescue
# it, so `[ -f ]` alone would let a half-written library turn this fail-open gate
# into an exit-2 hard block on every model switch in every session. Capture `$-`,
# drop `-e` across the source, restore it only if it was set. The `command -v`
# probe converts the likelier failure — library present, symbol renamed — from a
# silent no-op into a detected state. It names the LAST symbol the library
# defines, so a mid-file truncation is caught as well as a rename.
#
# Position is load-bearing: after the option and --self-test parse, BEFORE stdin
# is read. A hook that drains stdin and then aborts has consumed the payload
# without emitting a decision.
_LIB="$(dirname "$0")/model-switch-lib.sh"
_cf_opts=$-
set +e
# shellcheck source=hooks/model-switch-lib.sh
[ -f "$_LIB" ] && . "$_LIB"
case "$_cf_opts" in *e*) set -e ;; esac

# Degraded signalling must be library-free — the audit appender is IN the library.
# Gated on an existing ledger so a degraded hook in an unrelated session cannot
# materialize .context/logs/ in every directory it fires from.
if ! command -v corpflow_hook_audit_row > /dev/null 2>&1; then
  echo "model-switch-gate: shared library unusable at $_LIB — switch passed through unchecked" >&2
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

# Classifies the trigger string into fallback | user | unknown.
classify_trigger() {
  _ct_raw=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  [ -n "$_ct_raw" ] || { printf 'unknown'; return; }
  case "$_ct_raw" in
    *fallback* | *404* | *not_found* | *notfound* | *unavailable* | *degrade* | *overload* | *error* | *retry*)
      printf 'fallback' ;;
    *user* | *manual* | *explicit* | *interactive* | *command* | *slash* | picker | sdk)
      printf 'user' ;;
    *) printf 'unknown' ;;
  esac
}

# run_gate <payload> <ctx> -> echoes decision JSON (block/confirm/annotate) or
# nothing. Returns 0 always.
run_gate() {
  _payload="$1"
  _ctx="$2"

  command -v jq > /dev/null 2>&1 || return 0

  # Hatch first — cheapest check, and a control switching off must not be silent.
  # Gated on state.json existing so a shell-profile-wide export cannot materialize
  # .context/logs/ in every unrelated directory.
  if [ "${CORPFLOW_MODEL_SWITCH_GATE:-}" = "off" ] && [ -f "$_ctx/state.json" ]; then
    _sentinel="$_ctx/logs/.model-switch-gate-off-noted"
    if [ ! -f "$_sentinel" ]; then
      # `|| :` — under set -e a failed touch here would be a non-zero hook exit.
      { mkdir -p "$_ctx/logs" && : > "$_sentinel"; } 2> /dev/null || :
      corpflow_hook_audit_row --ctx "$_ctx" --actor hook:model-switch-gate \
        --subject "CORPFLOW_MODEL_SWITCH_GATE" --action "model_switch_gate_disabled" \
        --task-id "$(corpflow_audit_task_id "$_ctx")" \
        --result ok --meta '{"vector":"CORPFLOW_MODEL_SWITCH_GATE"}'
    fi
    return 0
  fi

  # Every row below needs the same four payload fields and the same two ledger
  # answers, so each is read in ONE jq rather than one per field. An empty result
  # from the payload read is the unparseable case: not a switch this gate can
  # describe, so it earns silence rather than a row-2 annotation about a
  # destination that was never there.
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
  _trigger_raw="${_rest#*$'\t'}"

  # Row 1 — no worktask, no single acting stage, or no unambiguous pin.
  _pin_row=$(corpflow_stage_and_pin "$_ctx" "$_agent_id")
  [ -n "$_pin_row" ] || return 0
  _rest="$_pin_row"
  _stage="${_rest%%$'\t'*}"; _rest="${_rest#*$'\t'}"
  _pin="${_rest%%$'\t'*}"
  _task_id="${_rest#*$'\t'}"
  [ -n "$_stage" ] || return 0
  [ -n "$_pin" ] || return 0

  _pin_family=$(corpflow_model_family "$_pin")
  _dest_family=$(corpflow_model_family "$_dest")

  # Row 2 — destination unresolvable. Every wrong-guess path lands here, which is
  # what makes the fail-open property structural rather than conventional.
  if [ -z "$_dest_family" ]; then
    _ac="Stage $_stage (task $_task_id) is pinned to '$_pin', but this PreModelSwitch payload carried no field this gate recognizes as a destination model. Passing the switch through unblocked; verify dispatched_agents[].model_resolved before attributing this stage's cost."
    jq -cn --arg r "$_ac" '{
      systemMessage: $r
    }' 2> /dev/null || return 0
    corpflow_hook_audit_row --ctx "$_ctx" --actor hook:model-switch-gate \
      --subject "${_task_id:-unknown}" --task-id "${_task_id:-unknown}" --action "model_switch_annotated" --result ok \
      --meta "$(jq -cn --arg s "$_stage" --arg t "$_task_id" --arg p "$_pin" \
        '{stage:$s, task_id:$t, pinned:$p, kind:"destination_unresolved"}')"
    return 0
  fi

  # Row 3 — same family, different spelling. An alias and a resolved id are not a
  # re-tier.
  if [ "$_pin_family" = "$_dest_family" ]; then
    return 0
  fi

  _trigger=$(classify_trigger "$_trigger_raw")

  # Row 4 — error recovery. Blocking a fallback would strand the stage worse than
  # the re-tier does.
  if [ "$_trigger" = "fallback" ]; then
    _ac="Stage $_stage (task $_task_id) pinned '$_pin' but is falling back to '$_dest'. Allowed as error recovery. This stage did not run on the model it requested — re-check dispatched_agents[].model_resolved before attributing cost."
    jq -cn --arg r "$_ac" '{
      systemMessage: $r
    }' 2> /dev/null || return 0
    corpflow_hook_audit_row --ctx "$_ctx" --actor hook:model-switch-gate \
      --subject "${_task_id:-unknown}" --task-id "${_task_id:-unknown}" --action "model_switch_annotated" --result ok \
      --meta "$(jq -cn --arg s "$_stage" --arg t "$_task_id" --arg p "$_pin" \
        --arg d "$_dest" --arg o "$_origin" \
        '{stage:$s, task_id:$t, pinned:$p, requested:$d, origin:$o, kind:"fallback"}')"
    return 0
  fi

  # Row 5 — explicit human action. Confirm rather than refuse; the operator may
  # have a reason the ledger cannot see.
  if [ "$_trigger" = "user" ]; then
    _ac="Stage $_stage (task $_task_id) is pinned to '$_pin' via metadata.model. Switching to '$_dest' will run the rest of this stage off-tier. Confirm only if that is intended; otherwise cancel and re-dispatch the stage with an explicit metadata.model override."
    jq -cn --arg r "$_ac" '{
      hookSpecificOutput: {hookEventName: "PreModelSwitch", permissionDecision: "ask", permissionDecisionReason: $r}
    }' 2> /dev/null || return 0
    corpflow_hook_audit_row --ctx "$_ctx" --actor hook:model-switch-gate \
      --subject "${_task_id:-unknown}" --task-id "${_task_id:-unknown}" --action "model_switch_confirm_requested" --result ok \
      --meta "$(jq -cn --arg s "$_stage" --arg t "$_task_id" --arg p "$_pin" \
        --arg d "$_dest" --arg o "$_origin" \
        '{stage:$s, task_id:$t, pinned:$p, requested:$d, origin:$o, kind:"user"}')"
    return 0
  fi

  # Row 6a — no trigger field was observed at all. The trigger field names are
  # ASSUMED, so their absence is missing evidence, not an unrecognized override:
  # annotate rather than deny. This is the path every schema-drift scenario takes.
  if [ -z "$_trigger_raw" ]; then
    _ac="Stage $_stage (task $_task_id) is pinned to '$_pin'; this switch would move it to '$_dest'. This PreModelSwitch payload carried no field this gate recognizes as a switch trigger, so the switch is passing through unblocked. Verify dispatched_agents[].model_resolved before attributing this stage's cost."
    jq -cn --arg r "$_ac" '{
      systemMessage: $r
    }' 2> /dev/null || return 0
    corpflow_hook_audit_row --ctx "$_ctx" --actor hook:model-switch-gate \
      --subject "${_task_id:-unknown}" --task-id "${_task_id:-unknown}" --action "model_switch_annotated" --result ok \
      --meta "$(jq -cn --arg s "$_stage" --arg t "$_task_id" --arg p "$_pin" \
        --arg d "$_dest" --arg o "$_origin" \
        '{stage:$s, task_id:$t, pinned:$p, requested:$d, origin:$o, kind:"trigger_unobserved"}')"
    return 0
  fi

  # Row 6b — a trigger field IS present and classifies as neither fallback nor
  # user. Presence confirms the field name; only the vocabulary is unknown, and
  # that is evidence enough to deny. This is the gate's one reachable deny.
  _ac="Stage $_stage (task $_task_id) is pinned to '$_pin' via metadata.model; this switch would move it to '$_dest' with no recognized override trigger. To proceed: re-dispatch the stage with an explicit metadata.model override, or a human operator may restart with CORPFLOW_MODEL_SWITCH_GATE=off in the process environment — an agent cannot self-serve this."
  jq -cn --arg r "$_ac" '{
    hookSpecificOutput: {hookEventName: "PreModelSwitch", permissionDecision: "deny", permissionDecisionReason: $r}
  }' 2> /dev/null || return 0
  corpflow_hook_audit_row --ctx "$_ctx" --actor hook:model-switch-gate \
    --subject "${_task_id:-unknown}" --task-id "${_task_id:-unknown}" --action "model_switch_blocked" --result block \
    --meta "$(jq -cn --arg s "$_stage" --arg t "$_task_id" --arg p "$_pin" \
      --arg d "$_dest" --arg o "$_origin" --arg tr "$_trigger_raw" \
      '{stage:$s, task_id:$t, pinned:$p, requested:$d, origin:$o, trigger_raw:$tr, kind:"unrecognized_trigger"}')"
  return 0
}

# This arm fails CLOSED: a self-test that cannot find its cases reports failure,
# never "OK".
if [ "$SELF_TEST" -eq 1 ]; then
  _selftest_body="$(dirname "$0")/lib/model-switch-gate-selftest.sh"
  if [ ! -f "$_selftest_body" ]; then
    echo "model-switch-gate: self-test body missing at $_selftest_body" >&2
    exit 1
  fi
  . "$_selftest_body"
fi

PAYLOAD=$(cat)
CTX=$(corpflow_context_root)
run_gate "$PAYLOAD" "$CTX"
exit 0
