#!/usr/bin/env bash
# PermissionDenied → one permission_denied audit row (corpflow worktask plugin).
#
# Observes only. Stdout stays empty, so no decision is returned and the denial stands; nothing
# here grants or persists a permission. Exit 0 on every operational path: a hook failure must
# never break the session it observes.
#
# Row: actor hook:permission-denied, subject <task id|unknown>, result block, metadata
# {tool, dedupe_key, command_head, truncated} from pd_audit_meta. The committed log never gets
# the command, classifier_reason, allow_rule or tool_input. The orchestrator fallback
# (skills/worktask/scripts/permission-park.sh) writes the same row when this event never fires;
# the shared key in hooks/lib/permission-denied-lib.sh keeps the count at one.
#
# Self-test: hooks/permission-denied.sh --self-test
set -u

SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1
_HOOK_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" 2> /dev/null && pwd -P)"

if [ "$SELF_TEST" -eq 1 ]; then
  command -v jq > /dev/null 2>&1 || { echo "permission-denied: self-test FAIL (jq missing)"; exit 1; }
  _st_tmp=$(mktemp -d) || exit 1
  trap 'rm -rf "$_st_tmp"' EXIT
  mkdir -p "$_st_tmp/.context"
  printf '%s' '{"run_index":0,"tasks":{"FN0":{"status":"in_progress"}}}' > "$_st_tmp/.context/state.json"
  _st_evt='{"hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{"command":"gh pr merge 1"},"reason":"Blocked by classifier"}'
  _st_out=""
  for _st_i in 1 2; do
    _st_out="$_st_out$(printf '%s' "$_st_evt" \
      | env -u WORKSPACE_ROOT -u CONTEXT_DIR CLAUDE_PROJECT_DIR="$_st_tmp" bash "$0" 2> /dev/null)"
  done
  _st_log="$_st_tmp/.context/logs/audit.jsonl"
  _st_rows=$(grep -c '"action":"permission_denied"' "$_st_log" 2> /dev/null || true)
  if [ -z "$_st_out" ] && [ "${_st_rows:-0}" = "1" ] \
    && ! grep -qF 'Blocked by classifier' "$_st_log" \
    && jq -e '.subject == "FN0" and .result == "block"
      and (.metadata | keys_unsorted) == ["tool", "dedupe_key", "command_head", "truncated"]
      and .metadata.command_head == "gh [redacted] [redacted] [redacted]" and .metadata.truncated == true' \
      "$_st_log" > /dev/null 2>&1; then
    echo "permission-denied: self-test OK (1 passed, 0 failed)"
    exit 0
  fi
  echo "permission-denied: self-test FAIL (rows=${_st_rows:-0}) (0 passed, 1 failed)"
  exit 1
fi

command -v jq > /dev/null 2>&1 || exit 0
PAYLOAD=""
[ -t 0 ] || PAYLOAD=$(cat 2> /dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // "PermissionDenied"' 2> /dev/null) || exit 0
[ "$EVENT" = "PermissionDenied" ] || exit 0

_LIB="$_HOOK_DIR/model-switch-lib.sh"
_PD_LIB_FILE="$_HOOK_DIR/lib/permission-denied-lib.sh"
_CF_OPTS=$-
set +e
# shellcheck source=hooks/model-switch-lib.sh
[ -f "$_LIB" ] && . "$_LIB"
# shellcheck source=hooks/lib/permission-denied-lib.sh
[ -f "$_PD_LIB_FILE" ] && . "$_PD_LIB_FILE"
case "$_CF_OPTS" in *e*) set -e ;; esac
command -v corpflow_hook_audit_row > /dev/null 2>&1 || exit 0
command -v pd_detail_from_event > /dev/null 2>&1 || exit 0

CTX=$(corpflow_context_root)
[ -n "$CTX" ] || exit 0

DETAIL=$(pd_detail_from_event "$PAYLOAD")
[ -n "$DETAIL" ] || exit 0
TOOL=$(printf '%s' "$DETAIL" | jq -r '.tool' 2> /dev/null) || exit 0
CMD=$(printf '%s' "$DETAIL" | jq -r '.command' 2> /dev/null) || exit 0
# The dedupe key is committed with the row, so a key hashed over the raw command would let a
# guessed secret be confirmed offline. A non-empty command that masks to nothing gets no row: the
# only key left to write would be over the unmasked text.
KCMD=$(pd_key_command "$CMD")
[ -n "$KCMD" ] || [ -z "$CMD" ] || exit 0
AGENT_ID=$(printf '%s' "$PAYLOAD" | jq -r '.agent_id // "" | tostring' 2> /dev/null) || AGENT_ID=""

# The payload names no task, so the subject is inferred: the launched dispatch for this agent,
# else the sole in_progress task. Anything ambiguous stays "unknown" rather than a guess.
TASK=$(jq -r --arg aid "$AGENT_ID" '
  (if (.facts.dispatched_agents | type) == "array" then .facts.dispatched_agents else [] end
   | map(select($aid != "" and .agent_id == $aid and .status == "launched"
       and ((.task_id // "") | length) > 0))) as $by
  | if ($by | length) == 1 then $by[0].task_id
    else ((.tasks // {}) | if type == "object"
            then [to_entries[] | select(.value.status == "in_progress") | .key] else [] end
          | if length == 1 then .[0] else "unknown" end)
    end' "$CTX/state.json" 2> /dev/null) || TASK="unknown"
case "$TASK" in
  PL[0-9]* | AR[0-9]* | TL[0-9]* | DV[0-9]* | DR[0-9]* | SR[0-9]* | QA[0-9]* | DC[0-9]* | RE[0-9]* | FN[0-9]* | ST[0-9]* | IR[0-9]* | ET[0-9]*) : ;;
  *) TASK="unknown" ;;
esac

AUDIT="$CTX/logs/audit.jsonl"
KEY=$(pd_dedupe_key "$TASK" "$TOOL" "$KCMD")
pd_audit_has_key "$AUDIT" "$KEY" && exit 0
if [ "$TASK" = "unknown" ]; then
  # An unnamed subject may be a denial the fallback already logged under its own task; rows
  # carry no command, so each ledger task's key is re-derived and looked up.
  _ids=()
  while IFS= read -r _id; do
    case "$_id" in
      PL[0-9]* | AR[0-9]* | TL[0-9]* | DV[0-9]* | DR[0-9]* | SR[0-9]* | QA[0-9]* | DC[0-9]* | RE[0-9]* | FN[0-9]* | ST[0-9]* | IR[0-9]* | ET[0-9]*)
        _ids[${#_ids[@]}]="$_id"
        ;;
    esac
  done <<< "$(jq -r '(.tasks // {}) | if type == "object" then keys[] else empty end' "$CTX/state.json" 2> /dev/null)"
  pd_audit_has_twin "$AUDIT" "$TOOL" "$KCMD" ${_ids[@]+"${_ids[@]}"} && exit 0
fi

META=$(pd_audit_meta "$TOOL" "$CMD" "$KEY")
[ -n "$META" ] || exit 0
corpflow_hook_audit_row --ctx "$CTX" --actor "hook:permission-denied" --action permission_denied \
  --result block --subject "$TASK" --task-id "$TASK" --meta "$META"
exit 0
