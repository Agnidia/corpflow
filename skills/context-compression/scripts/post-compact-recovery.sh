#!/usr/bin/env bash
# @description PostCompact recovery: parse the audit.jsonl tail, resolve the
#              in-progress stage and its error file, emit a compact JSON pointer
#              to .context/logs/post-compact-<ts>.json.
#
#              Detection is audit.jsonl-based (NOT mtime/ls ordering — those are
#              unreliable).  The selector does NOT filter on result: the most
#              recent non-advisory subagent_stopped entry is the interrupted
#              stage whatever its result, so recovery resumes from the last stage
#              that stopped rather than from the last one that stopped badly.
#              A stage can stop "ok" and still lose the turn that followed it.
#
# @arg --audit-file <path>  Override audit.jsonl path (default: $CLAUDE_PROJECT_DIR/.context/logs/audit.jsonl)
# @arg --out-dir <path>     Override output directory (default: $CLAUDE_PROJECT_DIR/.context/logs)
# @arg --tail-lines <N>     Lines of audit.jsonl to scan (default: 20)
# @arg --dry-run            Print JSON to stdout; do NOT write file
# @arg --self-test          Run fixture-based self-test and exit
# @exitcode 0  Recovery pointer written (or printed with --dry-run)
# @exitcode 1  Unexpected error
set -Eeuo pipefail
shopt -s inherit_errexit 2> /dev/null || true
IFS=$'\n\t'
trap 'printf >&2 "error: %s:%d: exit %d\n" "${BASH_SOURCE[0]}" "$LINENO" "$?"' ERR

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
# Rooted on the declared project dir, never on cwd: this runs as a PostCompact
# hook whose cwd may be a linked worktree or any subdirectory, and a cwd-relative
# default would read an empty audit trail and write the pointer where no resume
# will look for it. Explicit --audit-file / --out-dir still win.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
AUDIT_FILE="$PROJECT_DIR/.context/logs/audit.jsonl"
OUT_DIR="$PROJECT_DIR/.context/logs"
TAIL_LINES=20
DRY_RUN=0
SELF_TEST=0

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --audit-file)
      AUDIT_FILE="${2:?--audit-file requires a path}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:?--out-dir requires a path}"
      shift 2
      ;;
    --tail-lines)
      TAIL_LINES="${2:?--tail-lines requires an integer}"
      if [[ ! "$TAIL_LINES" =~ ^[0-9]+$ ]]; then
        printf >&2 'error: --tail-lines must be a positive integer, got: %s\n' "$TAIL_LINES"
        exit 1
      fi
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    -h | --help)
      cat >&2 << 'USAGE'
Usage: bash post-compact-recovery.sh [OPTIONS]

Options:
  --audit-file <path>   audit.jsonl location (default: $CLAUDE_PROJECT_DIR/.context/logs/audit.jsonl)
  --out-dir    <path>   output directory   (default: $CLAUDE_PROJECT_DIR/.context/logs)
  --tail-lines <N>      lines to scan      (default: 20)
  --dry-run             print JSON, do not write file
  --self-test           run fixture tests and exit
USAGE
      exit 0
      ;;
    *)
      printf >&2 'error: unknown argument: %s\n' "$1"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
if ! command -v jq > /dev/null 2>&1; then
  printf >&2 'error: jq is required but not found\n'
  exit 1
fi

# ---------------------------------------------------------------------------
# Core logic — operates on a caller-supplied audit file path
# ---------------------------------------------------------------------------

# derive_recovery <audit_file> <tail_lines>
# Prints a compact JSON object (single line) with the recovery pointer fields.
derive_recovery() {
  local audit_file="$1"
  local tail_lines="$2"

  # Collect the tail without echoing file contents back to the model's context.
  # Non-advisory filter: advisory=true rows are duplicates emitted by secondary
  # hooks; only the primary (advisory absent / false) carries ground-truth data.
  local audit_tail unparseable tail_raw total_rows parsed_rows
  unparseable=0
  if [[ -s "$audit_file" ]]; then
    tail_raw=$(tail -n "$tail_lines" -- "$audit_file")
    # Tolerant per-line read. A slurped `jq -s` aborts the whole tail on the first
    # malformed line, and an aborted read is indistinguishable from "no rows
    # matched" — the exact silent failure this recovery path exists to survive.
    # `objects` guards a well-formed non-object line, which parses and then dies
    # on `.metadata`.
    audit_tail=$(printf '%s\n' "$tail_raw" | jq -ncR '
      [ inputs | select(length > 0) | fromjson? | objects
        | select(.metadata.advisory != true) ]
    ')
    total_rows=$(printf '%s\n' "$tail_raw" | grep -c '[^[:space:]]' || true)
    parsed_rows=$(printf '%s\n' "$tail_raw" | jq -ncR '[ inputs | select(length > 0) | fromjson? | objects ] | length')
    unparseable=$((total_rows - parsed_rows))
    [[ "$unparseable" -gt 0 ]] && printf >&2 'warn: %s: %d unparseable audit row(s) skipped in the last %s lines\n' \
      "$audit_file" "$unparseable" "$tail_lines"
  else
    audit_tail='[]'
  fi

  # Find the most recent non-advisory subagent_stopped entry.
  # This is the stage that was running when compaction occurred.
  local stopped_entry
  stopped_entry=$(printf '%s' "$audit_tail" | jq 'reverse | map(select(.action == "subagent_stopped")) | first // null')

  local task_id agent_subject agent_basename error_file stage_ts
  task_id='null'
  agent_subject='null'
  agent_basename='null'
  error_file='null'
  stage_ts='null'

  if [[ "$stopped_entry" != 'null' && -n "$stopped_entry" ]]; then
    # subject: "plugin:agent-name" or bare "agent-name"
    agent_subject=$(printf '%s' "$stopped_entry" | jq -r '.subject // "unknown"')
    stage_ts=$(printf '%s' "$stopped_entry" | jq -r '.ts // "unknown"')

    # Strip plugin prefix (everything up to and including the last ':')
    agent_basename="${agent_subject##*:}"

    # Error file path follows agent-coordination convention: basename.md
    error_file=".context/errors/${agent_basename}.md"

    # Task ID from background_task_ids[0] — the Task System handle
    task_id=$(printf '%s' "$stopped_entry" | jq -r '
      (.metadata.background_task_ids // []) | first // "unknown"
    ')
  fi

  jq -nc \
    --argjson audit_tail "$audit_tail" \
    --argjson unparseable "$unparseable" \
    --arg task_id "$task_id" \
    --arg agent "$agent_basename" \
    --arg error_file "$error_file" \
    --arg stage_ts "$stage_ts" \
    --arg contracts "skills/worktask/references/stage-contracts.md" \
    --arg resume_guide "skills/worktask/references/resume.md" \
    '{
      recovery: {
        detected_via: "audit.jsonl-tail",
        interrupted_stage: {
          agent:      $agent,
          task_id:    $task_id,
          stopped_at: $stage_ts,
          error_file: $error_file
        },
        audit_tail_count: ($audit_tail | length),
        unparseable_rows: $unparseable,
        stage_contracts_ref: $contracts,
        resume_guide_ref:   $resume_guide,
        instruction: "1) Read .context/state.json tasks{} to confirm task status. 2) Read error_file if present. 3) Follow resume_guide_ref — resume from first incomplete stage. Do NOT replay completed tasks."
      }
    }'
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
if [[ "$SELF_TEST" -eq 1 ]]; then
  TMP=$(mktemp -d)
  trap 'rm -rf -- "$TMP"' EXIT

  FIXTURE="$TMP/audit.jsonl"

  # Helper: write a non-advisory subagent_stopped line
  write_stop() {
    local subject="$1" task_id="$2" result="${3:-ok}"
    printf '{"ts":"2026-06-29T10:00:00Z","actor":"hook:audit-subagent","action":"subagent_stopped","subject":"%s","result":"%s","metadata":{"background_task_ids":["%s"],"effort":"high","parent_agent_id":"none","dedupe_key":"sess:agent:stop"}}\n' \
      "$subject" "$result" "$task_id"
  }

  # Helper: write an advisory duplicate (should be ignored)
  write_advisory_stop() {
    local subject="$1"
    printf '{"ts":"2026-06-29T10:00:00Z","actor":"apple-developer:hook:audit-subagent","action":"subagent_stopped","subject":"%s","result":"ok","metadata":{"advisory":true,"dedupe_key":"sess:agent:stop"}}\n' \
      "$subject"
  }

  # Helper: write a tool_invoked line (should not be picked as in-progress stage)
  write_tool() {
    printf '{"ts":"2026-06-29T10:00:01Z","actor":"hook:audit-tooluse","action":"tool_invoked","subject":"Edit","result":"ok","metadata":{"kind":"tool","dedupe_key":"sess:tool"}}\n'
  }

  echo "--- self-test 1: empty audit file ---"
  : > "$FIXTURE"
  OUT1=$(derive_recovery "$FIXTURE" 20)
  AGENT1=$(printf '%s' "$OUT1" | jq -r '.recovery.interrupted_stage.agent')
  [[ "$AGENT1" == "null" ]] || {
    printf 'FAIL: expected null agent, got %s\n' "$AGENT1"
    exit 1
  }
  printf 'PASS: empty file → null agent\n'

  echo "--- self-test 2: only tool_invoked entries ---"
  write_tool > "$FIXTURE"
  write_tool >> "$FIXTURE"
  OUT2=$(derive_recovery "$FIXTURE" 20)
  AGENT2=$(printf '%s' "$OUT2" | jq -r '.recovery.interrupted_stage.agent')
  [[ "$AGENT2" == "null" ]] || {
    printf 'FAIL: expected null agent, got %s\n' "$AGENT2"
    exit 1
  }
  printf 'PASS: no subagent_stopped → null agent\n'

  echo "--- self-test 3: single subagent_stopped with plugin prefix ---"
  write_stop "apple-developer:ios-developer" "task123" "error" > "$FIXTURE"
  OUT3=$(derive_recovery "$FIXTURE" 20)
  AGENT3=$(printf '%s' "$OUT3" | jq -r '.recovery.interrupted_stage.agent')
  TASK3=$(printf '%s' "$OUT3" | jq -r '.recovery.interrupted_stage.task_id')
  ERR3=$(printf '%s' "$OUT3" | jq -r '.recovery.interrupted_stage.error_file')
  [[ "$AGENT3" == "ios-developer" ]] || {
    printf 'FAIL: expected ios-developer, got %s\n' "$AGENT3"
    exit 1
  }
  [[ "$TASK3" == "task123" ]] || {
    printf 'FAIL: expected task123, got %s\n' "$TASK3"
    exit 1
  }
  [[ "$ERR3" == ".context/errors/ios-developer.md" ]] || {
    printf 'FAIL: wrong error file: %s\n' "$ERR3"
    exit 1
  }
  printf 'PASS: plugin-prefixed subject stripped correctly\n'

  echo "--- self-test 4: advisory entry ignored; canonical entry wins ---"
  {
    write_stop "corpflow:technical-lead" "taskABC" "ok"
    write_advisory_stop "corpflow:technical-lead"
  } > "$FIXTURE"
  OUT4=$(derive_recovery "$FIXTURE" 20)
  AGENT4=$(printf '%s' "$OUT4" | jq -r '.recovery.interrupted_stage.agent')
  TASK4=$(printf '%s' "$OUT4" | jq -r '.recovery.interrupted_stage.task_id')
  [[ "$AGENT4" == "technical-lead" ]] || {
    printf 'FAIL: expected technical-lead, got %s\n' "$AGENT4"
    exit 1
  }
  [[ "$TASK4" == "taskABC" ]] || {
    printf 'FAIL: expected taskABC, got %s\n' "$TASK4"
    exit 1
  }
  printf 'PASS: advisory duplicate ignored\n'

  echo "--- self-test 5: most recent subagent_stopped wins ---"
  {
    write_stop "corpflow:product-manager" "taskOLD" "ok"
    write_tool
    write_stop "system-developer:bash-developer" "taskNEW" "ok"
  } > "$FIXTURE"
  OUT5=$(derive_recovery "$FIXTURE" 20)
  AGENT5=$(printf '%s' "$OUT5" | jq -r '.recovery.interrupted_stage.agent')
  TASK5=$(printf '%s' "$OUT5" | jq -r '.recovery.interrupted_stage.task_id')
  [[ "$AGENT5" == "bash-developer" ]] || {
    printf 'FAIL: expected bash-developer, got %s\n' "$AGENT5"
    exit 1
  }
  [[ "$TASK5" == "taskNEW" ]] || {
    printf 'FAIL: expected taskNEW, got %s\n' "$TASK5"
    exit 1
  }
  printf 'PASS: most recent entry selected correctly\n'

  echo "--- self-test 6: audit_tail_count reflects non-advisory lines only ---"
  {
    write_stop "corpflow:developer" "taskX" "ok"
    write_advisory_stop "corpflow:developer"
    write_tool
  } > "$FIXTURE"
  OUT6=$(derive_recovery "$FIXTURE" 20)
  COUNT6=$(printf '%s' "$OUT6" | jq -r '.recovery.audit_tail_count')
  # 2 non-advisory lines (one subagent_stopped + one tool_invoked)
  [[ "$COUNT6" -eq 2 ]] || {
    printf 'FAIL: expected 2 non-advisory lines, got %s\n' "$COUNT6"
    exit 1
  }
  printf 'PASS: audit_tail_count excludes advisory duplicates\n'

  echo "--- self-test 7: a malformed row is skipped, counted, and does not blind the scan ---"
  {
    printf '{ this is not json\n'
    write_stop "corpflow:developer" "taskY" "error"
    printf '["well-formed but not an object"]\n'
    write_tool
  } > "$FIXTURE"
  OUT7=$(derive_recovery "$FIXTURE" 20 2> "$TMP/warn7.txt")
  AGENT7=$(printf '%s' "$OUT7" | jq -r '.recovery.interrupted_stage.agent')
  UNP7=$(printf '%s' "$OUT7" | jq -r '.recovery.unparseable_rows')
  COUNT7=$(printf '%s' "$OUT7" | jq -r '.recovery.audit_tail_count')
  [[ "$AGENT7" == "developer" ]] || {
    printf 'FAIL: malformed row blinded the scan; agent=%s\n' "$AGENT7"
    exit 1
  }
  [[ "$UNP7" -eq 2 ]] || {
    printf 'FAIL: expected 2 unparseable rows, got %s\n' "$UNP7"
    exit 1
  }
  [[ "$COUNT7" -eq 2 ]] || {
    printf 'FAIL: expected the 2 parseable rows to survive, got %s\n' "$COUNT7"
    exit 1
  }
  grep -q 'unparseable audit row' "$TMP/warn7.txt" || {
    printf 'FAIL: unparseable count was not surfaced on stderr\n'
    exit 1
  }
  printf 'PASS: malformed rows skipped, counted, and warned about\n'

  printf '\nAll self-tests passed.\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# Main path
# ---------------------------------------------------------------------------
RECOVERY_JSON=$(derive_recovery "$AUDIT_FILE" "$TAIL_LINES")

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s\n' "$RECOVERY_JSON"
  exit 0
fi

# The default output dir is a hook's write into the project: without a ledger there is
# no worktask to recover, and the mkdir below would plant a .context/ in a clean checkout.
if [[ "$OUT_DIR" == "$PROJECT_DIR/.context/logs" && ! -f "$PROJECT_DIR/.context/state.json" ]]; then
  exit 0
fi

mkdir -p -- "$OUT_DIR"
TS=$(date -u +%Y%m%d-%H%M%S)
OUT_FILE="${OUT_DIR}/post-compact-${TS}.json"
printf '%s\n' "$RECOVERY_JSON" > "$OUT_FILE"
printf 'PostCompact recovery written to %s\n' "$OUT_FILE" >&2
