#!/usr/bin/env bash
# PostToolUse → audit.jsonl writer (corpflow worktask plugin).
# Reads CC hook stdin JSON (tool_name, tool_input, tool_use_id, duration_ms,
# effort.level, session_id) and appends one canonical row to
# .context/logs/audit.jsonl with actor "hook:audit-tooluse".
#
# Dedupe rule: paired with optional agent-emitted rows via
# metadata.dedupe_key = "<session_id>:<tool_use_id>". Readers prefer the
# hook row when both exist (see skills/agent-coordination/SKILL.md).
#
# Every row carries top-level subject and task_id: the --task-status id the command
# names, else the one in-progress ledger key, else "none" or "unknown".
#
# Self-test: pass --self-test to run a Write and a secret-carrying state-patch fixture
# through the row builder and assert schema and non-disclosure.
set -eu

SELF_TEST=0
KIND="tool"
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) SELF_TEST=1 ;;
    --kind) shift; KIND="${1:-tool}" ;;
  esac
  shift
done

ST_WRITE='{"tool_name":"Write","tool_use_id":"toolu_test","duration_ms":42,"session_id":"sess_test","effort":{"level":"medium"}}'
ST_CANARY="zqSELFTESTzq9d41"

if ! command -v jq >/dev/null 2>&1; then
  echo "audit-tooluse: jq not found, skipping" >&2
  exit 0
fi

if [ "$SELF_TEST" -eq 1 ]; then
  PAYLOAD="$ST_WRITE"
else
  PAYLOAD=$(cat)
fi

# The matcher covers all of Bash so stage transitions (state-patch.sh) are seen; every
# other Bash call is ordinary work and must not reach the audit log. Filtering here
# rather than in the matcher is what keeps the trail signal-only.
printf '%s' "$PAYLOAD" | jq -e '.tool_name != "Bash" or ((.tool_input.command // "") | test("state-patch\\.sh"))' \
  >/dev/null 2>&1 || exit 0

# Guarded sources, deliberately AFTER the filter above: resolving the root forks
# git/resolve-root.sh, and the redaction library loads the path scrub, neither of
# which an ordinary Bash call this hook discards should pay for.
_LIB="$(dirname "$0")/model-switch-lib.sh"
_CMDHEAD_LIB="${_LIB%/model-switch-lib.sh}/lib/command-head-lib.sh"
unset _CORPFLOW_CMDHEAD_LIB
_CF_OPTS=$-
set +e
# shellcheck source=hooks/model-switch-lib.sh
[ -f "$_LIB" ] && . "$_LIB"
# shellcheck source=hooks/lib/command-head-lib.sh
[ -f "$_CMDHEAD_LIB" ] && . "$_CMDHEAD_LIB"
case "$_CF_OPTS" in *e*) set -e ;; esac

# Bind to the payload's /megatask issue before resolving: the inherited
# CLAUDE_PROJECT_DIR names the batch, not the issue this agent worked.
if command -v corpflow_bind_payload > /dev/null 2>&1; then
  corpflow_bind_payload "$PAYLOAD"
fi
if command -v corpflow_context_root >/dev/null 2>&1; then
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
LOG_DIR="$CTX/logs"

# build_row <payload> -> ROW.
#
# CONTRACT: .tool_input carries file contents, diffs and full command lines, and
# audit.jsonl is committed. Only the --task-status id/status pair, a redacted
# command_head and scrubbed targets (hooks/lib/command-head-lib.sh) are derived from
# it, and only the command's first line and a Write/Edit file_path are read to get
# them; content, old_string and new_string never are. Guarded by audit-tooluse.bats.
build_row() {
  local fields tool input head="" targets="" trunc=0 redaction="" task="none"
  fields=$(printf '%s' "$1" | jq -r '
    ((.tool_name // "") | tostring | gsub("[\r\n]"; "")),
    (if .tool_name == "Bash" then (.tool_input.command // "")
     elif .tool_name == "Write" or .tool_name == "Edit" then (.tool_input.file_path // "")
     else "" end | tostring | split("\n") | .[0] // "")' 2>/dev/null) || return 1
  tool="${fields%%$'\n'*}"
  case "$fields" in *$'\n'*) input="${fields#*$'\n'}" ;; *) input="" ;; esac

  case "$tool" in
    Bash | Write | Edit)
      if ! command -v audit_targets >/dev/null 2>&1; then
        [ "$tool" != Bash ] || head="[redacted]"
        redaction="scrub_unavailable"
      elif [ "$tool" = Bash ]; then
        audit_command_head "$input" state-patch.sh >/dev/null
        head="$AUDIT_COMMAND_HEAD" targets="$AUDIT_TARGETS"
        trunc="$AUDIT_TARGETS_TRUNCATED" redaction="$AUDIT_REDACTION"
      else
        # A file_path outside the target grammar is dropped whole, never split into fragments.
        case "$input" in
          '' | *[!A-Za-z0-9._/~-]*) : ;;
          *)
            audit_targets "$input" >/dev/null
            targets="$AUDIT_TARGETS" trunc="$AUDIT_TARGETS_TRUNCATED" redaction="$AUDIT_REDACTION"
            ;;
        esac
      fi
      ;;
  esac

  if [ -n "$CTX" ] && command -v corpflow_audit_task_id >/dev/null 2>&1; then
    task=$(corpflow_audit_task_id "$CTX")
  fi

  ROW=$(printf '%s' "$1" | jq -c \
    --arg ts "$(date -u +%FT%TZ)" \
    --arg actor "hook:audit-tooluse" \
    --arg kind "$KIND" --arg task "$task" --arg head "$head" --arg targets "$targets" \
    --argjson trunc "$trunc" --arg redaction "$redaction" '
    # Collect into an array first: a bare capture(...)? yields ZERO outputs on no-match,
    # which would silently drop the whole row instead of just the two extra fields.
    # First line only, like every other derivation, and a closed status vocabulary so no
    # free text from the command can reach the row.
    ([((.tool_input.command // "") | tostring | split("\n") | .[0] // "")
      | capture("--task-status\\s+(?<id>[A-Z]{2}[0-9]+)\\s+(?<st>pending|in_progress|completed|blocked|skipped|failed|stale|done)([^A-Za-z0-9_]|$)")?] | first) as $patch
    | ((.tool_name // "") | tostring) as $t
    | (if $t == "" then "unknown" else $t end) as $tool
    | {
      ts: $ts,
      actor: $actor,
      action: "tool_invoked",
      subject: (if $tool == "Bash" then "state-patch" else $tool end),
      result: "ok",
      task_id: (if $patch then $patch.id else $task end),
      metadata: ({
        kind: $kind,
        duration_ms: ((.duration_ms // 0) | tonumber? // 0),
        # Payload only: $CLAUDE_EFFORT keeps the requested tier even on haiku, which runs none.
        effort: (.effort.level // "unknown"),
        dedupe_key: ((.session_id // "nosession") + ":" + (.tool_use_id // "notoolid"))
      }
      + (if $patch then {task_id: $patch.id, status: $patch.st} else {} end)
      + (if $tool == "Bash" then {command_head: $head} else {} end)
      + (if $tool == "Bash" or $tool == "Write" or $tool == "Edit"
           then {targets: ($targets | split("\n") | map(select(length > 0)))} else {} end)
      + (if $trunc == 1 then {targets_truncated: true} else {} end)
      + (if $redaction != "" then {redaction: $redaction} else {} end))
    }') || return 1
}

if [ "$SELF_TEST" -eq 1 ]; then
  _st_passed=0
  build_row "$ST_WRITE" || { echo "audit-tooluse: self-test FAIL (write row not built) ($_st_passed passed, 1 failed)"; exit 1; }
  printf '%s\n' "$ROW" | jq -e '.metadata.dedupe_key == "sess_test:toolu_test" and .metadata.duration_ms == 42
    and .metadata.effort == "medium" and .subject == "Write" and (.task_id | length > 0)' >/dev/null \
    || { echo "audit-tooluse: self-test FAIL ($_st_passed passed, 1 failed)"; exit 1; }
  _st_passed=$((_st_passed + 1))

  _root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
  _st_cmd="API_TOKEN=${ST_CANARY} bash ${_root}/skills/worktask/scripts/state-patch.sh --task-status DV1 done --note ghp_${ST_CANARY}"
  _st_bash=$(jq -cn --arg c "$_st_cmd" '{tool_name:"Bash", tool_input:{command:$c}, tool_use_id:"toolu_bash", session_id:"sess_test"}')
  WORKSPACE_ROOT="$_root" build_row "$_st_bash" \
    || { echo "audit-tooluse: self-test FAIL (bash row not built) ($_st_passed passed, 1 failed)"; exit 1; }
  # The host-path patterns are the ones path-scrub.sh exported when the row above loaded it;
  # restating them here would be a second definition. With the scrub loaded they must be
  # non-empty, so the host check can never pass vacuously.
  printf '%s\n' "$ROW" | jq -e --arg c "$ST_CANARY" \
    --arg host "${CORPFLOW_HOST_PATH_ERE:-}" --arg drive "${CORPFLOW_DRIVE_PATH_ERE:-}" '
    def hostless: (($host == "") or (test($host) | not)) and (($drive == "") or (test($drive) | not));
    (.metadata.command_head | type == "string" and length > 0 and length <= 120
      and (test("API_TOKEN=|ghp_|^/") | not) and hostless)
    and (.metadata.targets | length <= 5 and all(.[]; length <= 160 and (startswith("/") | not) and hostless))
    and .task_id == "DV1" and .subject == "state-patch"
    and (tostring | contains($c) | not)
    and ((.metadata.redaction // "") == "scrub_unavailable" or ($host != "" and $drive != ""))' >/dev/null \
    || { echo "audit-tooluse: self-test FAIL (bash row redaction) ($_st_passed passed, 1 failed)"; exit 1; }
  _st_passed=$((_st_passed + 1))
  echo "audit-tooluse: self-test OK ($_st_passed passed, 0 failed)"
  exit 0
fi

build_row "$PAYLOAD" || {
  echo "audit-tooluse: jq parse failed" >&2
  exit 0
}

[ -n "$CTX" ] || exit 0
# Only the write path creates the directory, so a filtered-out call leaves no trace.
mkdir -p "$LOG_DIR"
# A symlinked audit.jsonl turns this append into a write primitive against an arbitrary
# target. Refuse rather than follow — the guard hooks/model-switch-lib.sh carries for the
# hook rows it writes, and tests/shell/hooks/test-execution-gate.bats pins.
[ ! -L "$LOG_DIR/audit.jsonl" ] || exit 0
printf '%s\n' "$ROW" >> "$LOG_DIR/audit.jsonl"
exit 0
