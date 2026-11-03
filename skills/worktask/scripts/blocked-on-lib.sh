#!/usr/bin/env bash
# @description blocked-on-lib.sh — the one definition of the typed `handoff.blocked_on` return:
#   both enums in registry order, the per-kind arm table, the normalize step and the two
#   validators. Sourced by handoff-harness.sh (boundary gate) and
#   blocked-on-dispatch.sh (router); two spellings of an enum are how the gate would admit a need
#   the router then refuses.
#
#   Change protocol: a new kind, detail key or resume_with value changes this file, the table in
#   skills/worktask/references/contracts/blocked-needs.md § Schema — blocked_on, the seven arms at a glance, and the
#   megatask Shared Seams registry entry together. Landing an arm flips its `landed` field here
#   and its row in SKILL.md § Step 6.5a3 in the same PR.
#
#   Symbols: BLOCKED_ON_KINDS, BLOCKED_ON_RESUME_WITH, blocked_on_arm, blocked_on_table_json,
#   blocked_on_normalize, blocked_on_validate, blocked_on_validate_arm.
#
# @exitcode 2 executed rather than sourced
#
# Minimum shell: bash 3.2+. Sets no shell options. Every function needs jq except blocked_on_arm.

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  printf >&2 'blocked-on-lib.sh: this is a library — source it, do not execute it directly\n'
  exit 2
fi
[ -n "${_BLOCKED_ON_LIB:-}" ] && return 0
_BLOCKED_ON_LIB=1

# Not readonly: consumer suites source this file more than once per process, and a second
# readonly assignment returns 1 under a `set -e` caller.
BLOCKED_ON_KINDS="user_decision user_action permission peer_session artifact correction host_environment"
BLOCKED_ON_RESUME_WITH="decision_ref artifact_path reply_ref"

# kind|required|optional|resume_with|legs|closing_leg|owner_issue|landed — rows in registry order.
# Every arm reads `yes` as of #404. The column stays: it is what the router's fallback and the
# batch renderer key on to name an owner issue, and the next kind added lands unlanded first.
_BLOCKED_ON_TABLE='user_decision|question,options|recommended,item|decision_ref|asked,answered,resumed|resumed|395|yes
user_action|request,command|verify|decision_ref|requested,verified|verified|394|yes
permission|tool,command,classifier_reason,allow_rule||decision_ref|denied,granted,resumed|resumed|393|yes
peer_session|to,question|deadline|reply_ref|sent,delivered,answered,relayed,expired|relayed|405|yes
artifact|producer_task,path||artifact_path|landed|landed|399|yes
correction|target_task,finding,evidence_ref,severity||artifact_path|opened,closed|closed|404|yes
host_environment|check,observed||decision_ref|probed|probed|390|yes'

# A value echoed into a fail: line is stage-written text: tojson escapes every control
# character, so the line stays one line, and the bound keeps a hostile value from flooding it.
# shellcheck disable=SC2016  # jq program text: its $names are jq variables, not shell ones
_BLOCKED_ON_JQ_SHOW='def bo_show: tojson | if length > 80 then .[0:79] + "…" else . end;'

# blocked_on_arm <kind> — prints `required|optional|resume_with|legs|closing_leg|owner_issue|landed`
# for the kind, comma-separated within a field; exit 1 on an unknown kind.
blocked_on_arm() {
  local _bo_line
  [ -n "${1:-}" ] || return 1
  while IFS= read -r _bo_line; do
    if [ "${_bo_line%%|*}" = "$1" ]; then
      printf '%s\n' "${_bo_line#*|}"
      return 0
    fi
  done <<< "$_BLOCKED_ON_TABLE"
  return 1
}

# blocked_on_table_json — the arm table as one object keyed by kind, for jq consumers:
# {required[], optional[], resume_with, legs[], closing_leg, owner_issue (number), landed (bool)}.
blocked_on_table_json() {
  command -v jq > /dev/null 2>&1 || return 1
  jq -cn --arg t "$_BLOCKED_ON_TABLE" '
    def csv: if . == "" then [] else split(",") end;
    [$t | split("\n")[] | select(length > 0) | split("|")
     | {key: .[0],
        value: {required: (.[1] | csv), optional: (.[2] | csv), resume_with: .[3],
                legs: (.[4] | csv), closing_leg: .[5], owner_issue: (.[6] | tonumber),
                landed: (.[7] == "yes")}}]
    | from_entries'
}

# blocked_on_normalize <handoff json> — prints {"blocked_on":{…},"source":"blocked_on"}. A non-null
# blocked_on passes through even when malformed, so a broken typed need is validated and refused
# downstream rather than read as absent. Exit 1 when it is absent: no other handoff key is a need.
blocked_on_normalize() {
  local _bo_out
  command -v jq > /dev/null 2>&1 || return 1
  _bo_out=$(printf '%s' "${1:-}" | jq -c '
    if type == "object" and .blocked_on != null then {blocked_on: .blocked_on, source: "blocked_on"}
    else empty end' 2> /dev/null) || _bo_out=""
  [ -n "$_bo_out" ] || return 1
  printf '%s\n' "$_bo_out"
}

# blocked_on_validate <blocked_on json> — kind and resume_with in their enums and detail a
# non-empty object; exit 1 with one `fail:` line on stderr naming the first violation. The
# harness stops here: pairing and per-kind keys are the router's (blocked_on_validate_arm).
blocked_on_validate() {
  local _bo_msg
  if ! command -v jq > /dev/null 2>&1; then
    printf >&2 'fail: blocked_on cannot be validated: jq is not installed\n'
    return 1
  fi
  # jq reads empty input as no values and exits 0, which would pass as valid.
  if [ -z "${1:-}" ]; then
    printf >&2 'fail: blocked_on is empty\n'
    return 1
  fi
  _bo_msg=$(printf '%s' "${1:-}" | jq -r --arg kinds "$BLOCKED_ON_KINDS" --arg rw "$BLOCKED_ON_RESUME_WITH" \
    "$_BLOCKED_ON_JQ_SHOW"'
    ($kinds | split(" ")) as $k | ($rw | split(" ")) as $r
    | if type != "object" then "blocked_on is not an object"
      elif (.kind as $x | any($k[]; . == $x)) | not then
        "blocked_on.kind \(.kind | bo_show) is not one of \($k | join("|"))"
      elif (.resume_with as $x | any($r[]; . == $x)) | not then
        "blocked_on.resume_with \(.resume_with | bo_show) is not one of \($r | join("|"))"
      elif (.detail | type) != "object" or (.detail | length) == 0 then
        "blocked_on.detail is missing or empty; kind \(.kind) needs a non-empty object"
      else empty end' 2> /dev/null) || _bo_msg="blocked_on is not valid JSON"
  [ -n "$_bo_msg" ] || return 0
  printf >&2 'fail: %s\n' "$_bo_msg"
  return 1
}

# A closed-shape check for the one kind whose detail reaches an AskUserQuestion prompt
# byte-verbatim (SR0 posture: unbounded text there is a second injection surface, not just a
# ledger row). Every other kind's detail is free-form and only the required-key check above
# bounds it.
# shellcheck disable=SC2016  # jq program text: its $names are jq variables, not shell ones
_BLOCKED_ON_JQ_UD='
def ud_shape:
  (.detail.question) as $q
  | (.detail.options // []) as $opts
  | (.detail.recommended) as $rec
  | (.detail.item) as $item
  | if ($q | type) != "string" or ($q | length) == 0 or ($q | length) > 512 then
      "blocked_on.detail.question for kind user_decision must be a 1-512 char string"
    # 0 is valid (a free-text-only decision, e.g. an expired peer_session fallback in
    # mailbox.sh, which has no discrete choices to offer). The built-in AskUserQuestion takes
    # 2-4 options per question and refuses fewer, so blocked-on-dispatch.sh `batch` renders the
    # empty case under a synthetic pair it never stores here, and the user answers through the
    # free-form choice that tool adds. The 4 cap below is this arm bounding its own detail.
    # Exactly 1 is refused as neither a real choice nor free-form.
    elif ($opts | type) != "array" or ($opts | length) == 1 or ($opts | length) > 4 then
      "blocked_on.detail.options for kind user_decision must be 0 or 2-4 options"
    elif (($opts | map(select((type != "string") or length == 0 or length > 200))) | length) > 0 then
      "blocked_on.detail.options for kind user_decision must each be a 1-200 char string"
    elif ($opts | unique | length) != ($opts | length) then
      "blocked_on.detail.options for kind user_decision must be unique"
    elif $rec != null and (($opts | index($rec)) == null) then
      "blocked_on.detail.recommended for kind user_decision must be one of options"
    elif $item != null and (($item | type) != "string" or ($item | test("^sw-[A-Z]{2}[0-9]+-[0-9]+$") | not)) then
      "blocked_on.detail.item for kind user_decision must match the sweep-id grammar"
    else empty end;
'

# blocked_on_validate_arm <blocked_on json> — blocked_on_validate, then every required key of the
# kind's arm present and non-null, then the kind's one resume_with, then user_decision's own
# closed shape. A null counts as missing: `"command": null` reaches the user prompt as nothing
# to run, which is not what "" declares.
blocked_on_validate_arm() {
  local _bo_msg _bo_table
  blocked_on_validate "${1:-}" || return 1
  _bo_table=$(blocked_on_table_json) || {
    printf >&2 'fail: blocked_on arm table unavailable\n'
    return 1
  }
  _bo_msg=$(printf '%s' "$1" | jq -r --argjson t "$_bo_table" \
    "$_BLOCKED_ON_JQ_SHOW$_BLOCKED_ON_JQ_UD"'
    $t[.kind] as $a
    | ([$a.required[] as $key | select(.detail[$key] == null) | $key] | .[0]) as $miss
    | if $miss != null then "blocked_on.detail for kind \(.kind) is missing required key: \($miss)"
      elif .resume_with != $a.resume_with then
        "blocked_on.resume_with for kind \(.kind) must be \($a.resume_with), not \(.resume_with | bo_show)"
      elif .kind == "user_decision" then ud_shape
      else empty end' 2> /dev/null) || _bo_msg="blocked_on arm check could not run"
  [ -n "$_bo_msg" ] || return 0
  printf >&2 'fail: %s\n' "$_bo_msg"
  return 1
}
