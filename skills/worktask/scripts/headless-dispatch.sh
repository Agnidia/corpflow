#!/usr/bin/env bash
# @description headless-dispatch.sh — validates a route-headless decision, builds the `claude`
#   argv array, and spawns it. The one place a ledger-sourced value becomes argv, so every
#   value is checked against a closed allowlist before the spawn line runs; a value that fails
#   any check aborts with nothing spawned (fail closed).
#
#   Surface: `claude -p --agent <id> --model <alias> --effort <tier> --permission-mode <mode>
#   --permission-prompts none --output-format stream-json --verbose`, run with the stream
#   worktree as cwd because there is no top-level `--cwd` (headless-dispatch.md § Dispatch
#   surface drift) — but the child's own `WORKSPACE_ROOT` env still names the orchestrator's
#   root, not that worktree, because that is where `.context/state.json` and the hooks that
#   read it live. The prompt is piped on stdin, never interpolated into argv.
#
#   `effort`/`permission-mode`/`workspace`/`artifact` are read straight off the ledger row
#   (`--ledger-root`'s state.json, keyed by `--task`) whenever the caller omits the matching
#   flag — the caller (the orchestrator's Step 6) therefore never has to carry a ledger value
#   through its own shell-string dispatch line: only `--task`/`--ledger-root` plus values it
#   owns outright (agent id, model alias, prompt file, session id) need to cross that
#   boundary. An explicit flag always wins over the self-read.
#
#   `--print-argv` is the dry mode whose tests exercise full validation, then the argv printed
#   NUL-delimited, no spawn. It shares every refusal path with the real dispatch — the two must
#   never diverge, or a passing dry-run would certify an argv the real path still rejects. Dry
#   mode never self-reads the ledger (there may be none), so it takes every value on the CLI.
#
#   The child's permission mode is never wider than the orchestrator's own session mode
#   (`--parent-mode`, defaulting to `manual` when the caller cannot report one): the two are
#   compared on a fixed privilege order and the narrower wins, before the PL/SR/FN/RE stages
#   apply their own `manual`-or-narrower ceiling on top.
#
#   Fallback: a `claude` binary missing/below floor, an auth failure, an unresolved `--agent`,
#   or a pre-artifact exit degrade to an in-process run that carries the same tier on the
#   Agent tool's `effort` — but ONLY when the pre/post side-effect snapshots match. A side effect
#   already landed means the run goes to the error chain instead (`side_effects_present`);
#   silently retrying in-process over real work would double it.
#
#   Symbols: none exported — this file is a CLI.
#
# @exitcode 2  usage error or a refused value (nothing spawned)
# @exitcode 3  side_effects_present: the child left work behind and cannot fall back
#
# Minimum shell: bash 3.2+ (macOS default) — no associative arrays, no `local -n`.

set -uo pipefail

_HD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HD_PLUGIN_ROOT="$(cd "${_HD_DIR}/../../.." && pwd)"
# shellcheck source=effort-ladder.sh
. "${_HD_DIR}/effort-ladder.sh"

MIN_CC_VERSION="2.1.303"
. "${_HD_DIR}/dispatch-controls.sh"

usage() {
  cat >&2 << 'EOF2'
usage:
  headless-dispatch.sh --task <ID> --agent <plugin:agent> --model <alias>
                        --ledger-root <path> --prompt <file>
                        --out <logfile>
                        [--effort <tier>] [--permission-mode <mode>] [--workspace <path>]
                        [--artifact <path>] [--parent-mode <mode>] [--session-id <uuid>]
                        [--resume <uuid>] [--state <path>]
                        [--auto-compact-window <tokens>] [--retry-watchdog <true|false>]
                        [--retry-watchdog-max-wait-ms <ms>]
                        [--retry-watchdog-max-usage-limit-wait-ms <ms>]
                        [--overloaded-retry-max-delay-ms <ms>]
  headless-dispatch.sh --task <ID> --agent <plugin:agent> --model <alias> --effort <tier>
                        --permission-mode <mode> --workspace <path> --print-argv

--effort/--permission-mode/--workspace/--artifact are read from the ledger row at
--ledger-root/.context/state.json (keyed by --task) whenever omitted — the live-dispatch
caller need not carry those ledger values itself. --print-argv has no ledger to read from,
so it always takes --effort/--permission-mode/--workspace explicitly.

--out is required outside --print-argv: the transcript must land under
<ledger-root>/.context/logs/ — never an arbitrary path, never a fallback temp file this script
forgets to clean up. The workspace's own membership check (r4-3 below) is the only workspace
gate now — there is no separate --expected-workspace flag to compare it against, because that
flag only ever repeated the same self-read ledger value the membership check already uses,
comparing it with itself.

A workspace must be --ledger-root itself, or a path `git worktree list` names for that repo.
When --ledger-root is ITSELF a linked worktree (shared with sibling sessions on the same repo),
that is narrowed further: the workspace must ALSO be one of this ledger's own DV rows'
metadata.workspace_path (r4-3) — git-owned membership alone would accept a sibling session's
tree too, and a bare DV-pin check alone would let a tampered row pin itself. Without jq to read
that pin set, a linked root refuses rather than silently widening to the repo-wide list.

--parent-mode is the orchestrator's own session mode; the child never runs wider than it
(narrower of the two, fixed order plan<dontAsk<manual<acceptEdits<auto<bypassPermissions).
Omitted, it defaults to manual — the conservative side. Unrecognized, it is refused (exit 2,
nothing spawned) — the same fail-closed rule every other enum flag gets, never a silent
default.

Prints one JSON result line (the route audit row shape) and exits 0 on success or a clean
fallback. Exits 2 before any spawn on a refused value. Exits 3 when the child left side
effects and cannot fall back.
EOF2
  exit 2
}

TASK=""
AGENT=""
MODEL=""
EFFORT=""
MODE=""
PARENT_MODE=""
WORKSPACE=""
LEDGER_ROOT=""
PROMPT=""
SESSION_ID=""
RESUME_ID=""
ARTIFACT=""
STATE_PATH=""
OUT_LOG=""
PRINT_ARGV=0
CONTROL_ARGS=()
CONTROLS='{}'
HAS_CONTROLS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) TASK="${2:-}"; shift 2 ;;
    --agent) AGENT="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --effort) EFFORT="${2:-}"; shift 2 ;;
    --permission-mode) MODE="${2:-}"; shift 2 ;;
    --parent-mode) PARENT_MODE="${2:-}"; shift 2 ;;
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --ledger-root) LEDGER_ROOT="${2:-}"; shift 2 ;;
    --prompt) PROMPT="${2:-}"; shift 2 ;;
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --resume) RESUME_ID="${2:-}"; shift 2 ;;
    --artifact) ARTIFACT="${2:-}"; shift 2 ;;
    --state) STATE_PATH="${2:-}"; shift 2 ;;
    --out) OUT_LOG="${2:-}"; shift 2 ;;
    --auto-compact-window | --retry-watchdog | --retry-watchdog-max-wait-ms | --retry-watchdog-max-usage-limit-wait-ms | --overloaded-retry-max-delay-ms)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      CONTROL_ARGS+=("${1#--}" "$2"); shift 2 ;;
    --print-argv) PRINT_ARGV=1; shift ;;
    -h | --help) usage ;;
    *)
      printf >&2 'headless-dispatch.sh: unknown argument: %s\n' "$1"
      usage
      ;;
  esac
done

refuse() {
  printf >&2 'headless-dispatch.sh: refused: %s\n' "$1"
  exit 2
}

[ -n "$TASK" ] && [ -n "$AGENT" ] && [ -n "$MODEL" ] || usage
if [ "$PRINT_ARGV" -eq 1 ]; then
  # Dry mode has no ledger to self-read from — every value has to arrive on the CLI.
  [ -n "$EFFORT" ] && [ -n "$MODE" ] && [ -n "$WORKSPACE" ] || usage
else
  [ -n "$PROMPT" ] && [ -n "$LEDGER_ROOT" ] && [ -n "$OUT_LOG" ] || usage
fi

# --- parent-mode normalization, moved ahead of the ledger self-read below: a row with no
# permission_mode of its own (the common shape — PL0 stamps it only on SR/FN under
# --secure/--full, state-ledger.md:212) inherits this ALREADY-capped value instead of being
# refused outright (b10). ---
if [ -n "$PARENT_MODE" ]; then
  [ "$PARENT_MODE" = "default" ] && PARENT_MODE="manual"
  [[ "$PARENT_MODE" =~ ^(acceptEdits|auto|bypassPermissions|manual|dontAsk|plan)$ ]] \
    || refuse "parent-mode: $PARENT_MODE"
else
  # An orchestrator that cannot report its own mode gets the conservative default (sw-SR0-1's
  # recommended answer) — never treated as "no cap", which would let any wider request through.
  PARENT_MODE="manual"
fi

# --- ledger self-read: effort/permission-mode/workspace/artifact, only when the caller left
# the flag empty and only outside --print-argv. This is the ONLY place those four ledger
# fields are read; the caller's own dispatch line never has to carry them as shell content. ---
if [ "$PRINT_ARGV" -ne 1 ]; then
  _HD_STATE_PATH="${STATE_PATH:-${LEDGER_ROOT}/.context/state.json}"
  # No `refuse` (exit) inside this function: it runs inside a `$(...)` command substitution,
  # where `exit` only ends the subshell, never the script — a silent-empty result here is
  # caught, and reported, by the combined check below instead. --artifact stays genuinely
  # optional either way (it was optional before this self-read existed too), so an unreadable
  # state or missing jq must not turn an --artifact-less call fatal on its account alone.
  _hd_ledger_read() { # <jq filter on .tasks[$t]...>
    command -v jq > /dev/null 2>&1 && [ -r "$_HD_STATE_PATH" ] || return 0
    jq -r --arg t "$TASK" "$1" "$_HD_STATE_PATH" 2> /dev/null
  }
  [ -n "$EFFORT" ] || EFFORT="$(_hd_ledger_read '.tasks[$t].metadata.effort // ""')"
  [ -n "$MODE" ] || MODE="$(_hd_ledger_read '.tasks[$t].metadata.permission_mode // ""')"
  # permission_mode is optional on the row itself: a null/absent value inherits PARENT_MODE
  # (b10) rather than joining the required-field refusal below — only effort and workspace
  # stay mandatory.
  [ -n "$MODE" ] || MODE="$PARENT_MODE"
  [ -n "$WORKSPACE" ] || WORKSPACE="$(_hd_ledger_read '.tasks[$t].metadata.workspace_path // ""')"
  [ -n "$ARTIFACT" ] || ARTIFACT="$(_hd_ledger_read '.tasks[$t].metadata.artifact // ""')"
  STATE_PATH="${STATE_PATH:-$_HD_STATE_PATH}"
  [ -n "$EFFORT" ] && [ -n "$WORKSPACE" ] \
    || refuse "ledger row $TASK is missing effort/workspace_path (state unreadable, jq absent, or the row lacks the field)"
fi

# --- validation: every value is checked against a closed allowlist before argv is built -----
[[ "$TASK" =~ ^[A-Z]{2}[0-9]+$ ]] || refuse "task id: $TASK"
[[ "$AGENT" =~ ^[a-z0-9-]+:[a-z0-9-]+$ ]] || refuse "agent id: $AGENT"
_HD_BARE="${AGENT##*:}"
_HD_PREFIX="${AGENT%%:*}"
_HD_PLUGIN_NAME="$(command -v jq > /dev/null 2>&1 \
  && jq -r '.name // "corpflow"' "${_HD_PLUGIN_ROOT}/.claude-plugin/plugin.json" 2> /dev/null)"
_HD_PLUGIN_NAME="${_HD_PLUGIN_NAME:-corpflow}"
if [ "$_HD_PREFIX" = "$_HD_PLUGIN_NAME" ]; then
  [ -f "${_HD_PLUGIN_ROOT}/agents/${_HD_BARE}.md" ] || refuse "agent not registered: $AGENT"
else
  # A non-matching prefix is a platform-plugin agent: it has no file under this plugin's
  # agents/ to check. It still has to be a REGISTERED target, though — routing-matrix.md
  # is the registry (ad6 Validation), so an unregistered foreign id is refused exactly like an
  # unregistered corpflow one, never a free pass. Anchored to table ROWS (a line starting with
  # `|`), not any backtick-quoted mention anywhere in the file (prose, a "never use" note).
  _HD_ROUTING_MATRIX="${_HD_PLUGIN_ROOT}/skills/shared/routing-matrix.md"
  _HD_REGISTERED=1
  if [ ! -r "$_HD_ROUTING_MATRIX" ] || ! grep -qE "^\|.*\`${AGENT}\`" "$_HD_ROUTING_MATRIX"; then
    _HD_REGISTERED=0
  fi
  [ "$_HD_REGISTERED" -eq 1 ] || refuse "agent not registered: $AGENT"
fi
[[ "$MODEL" =~ ^(opus|sonnet|haiku|fable)$ ]] || refuse "model: $MODEL"
effort_rank "$EFFORT" > /dev/null 2>&1 || refuse "effort: $EFFORT"

# Plugin `default` has no CLI counterpart (headless-dispatch.md § Translation table —
# permission, workspace & MCP); map it to the CLI's allowlist-only mode before the enum check
# runs, rather than special-casing "default" inside the enum itself.
[ "$MODE" = "default" ] && MODE="manual"
[[ "$MODE" =~ ^(acceptEdits|auto|bypassPermissions|manual|dontAsk|plan)$ ]] \
  || refuse "permission-mode: $MODE"

# Fixed privilege order, low to high. The in-process rule (SKILL.md § Step 5e) is "never
# widen the inherited mode"; a headless child gets the identical guarantee here by taking the
# narrower of its requested mode and the orchestrator's own session mode.
_hd_mode_rank() { # <mode> -> 0..5
  case "$1" in
    plan) printf '0' ;;
    dontAsk) printf '1' ;;
    manual) printf '2' ;;
    acceptEdits) printf '3' ;;
    auto) printf '4' ;;
    bypassPermissions) printf '5' ;;
    *) return 2 ;;
  esac
}

# PARENT_MODE was already normalized/validated above, ahead of the ledger self-read.
_HD_MODE_RANK="$(_hd_mode_rank "$MODE")" || refuse "permission-mode: $MODE"
_HD_PARENT_RANK="$(_hd_mode_rank "$PARENT_MODE")" || refuse "parent-mode: $PARENT_MODE"
if [ "$_HD_MODE_RANK" -gt "$_HD_PARENT_RANK" ]; then
  MODE="$PARENT_MODE"
fi

# PL/SR/FN/RE additionally never exceed manual, regardless of what the parent-mode cap above
# already allowed — these are the stages the operator always keeps ask-gated, in-process or
# headless alike.
case "$TASK" in
  PL* | SR* | FN* | RE*)
    _HD_CAP_RANK="$(_hd_mode_rank manual)"
    [ "$(_hd_mode_rank "$MODE")" -le "$_HD_CAP_RANK" ] || MODE="manual"
    ;;
esac

WORKSPACE_REAL="$(cd "$WORKSPACE" 2> /dev/null && pwd -P)" || refuse "workspace path: $WORKSPACE"

# The orchestrator's own root, exported to the child as WORKSPACE_ROOT (never the stream
# worktree above): state-merge.sh and the other SubagentStop hooks resolve .context/ from
# that env var, not from cwd, and the worktree has no .context/state.json of its own.
if [ -n "$LEDGER_ROOT" ]; then
  LEDGER_ROOT_REAL="$(cd "$LEDGER_ROOT" 2> /dev/null && pwd -P)" \
    || refuse "ledger-root path: $LEDGER_ROOT"
fi

[ "$(git -C "$WORKSPACE_REAL" rev-parse --is-inside-work-tree 2> /dev/null)" = "true" ] \
  || refuse "workspace is not a git worktree: $WORKSPACE_REAL"

# Outside --print-argv, "is some git worktree" is not enough (a tampered workspace_path could
# point anywhere on disk) — it has to be a worktree THIS ledger's repo actually owns: the
# ledger root itself, or a path `git worktree list` names for that repo. When the ledger root
# is ITSELF a linked worktree (this session's own tree, shared with sibling sessions on the
# same repo), "any worktree `git worktree list` names" is too wide — it would accept a sibling
# session's workspace too, and a bare DV-pin check is not enough on its own either: a tampered
# row's own workspace_path is trivially "in the pin set" it names, so it would approve itself
# (r4-3). Require BOTH for a linked root: git-owned membership AND presence in this ledger's
# own DV-pin set. Without jq to read that pin set, refuse rather than falling back to the
# repo-wide list, which would silently re-widen exactly the case this narrowing exists to close.
if [ "$PRINT_ARGV" -ne 1 ]; then
  _HD_WT_OK=0
  [ "$WORKSPACE_REAL" = "$LEDGER_ROOT_REAL" ] && _HD_WT_OK=1
  _HD_LEDGER_IS_LINKED_WT=0
  if [ "$(git -C "$LEDGER_ROOT_REAL" rev-parse --git-dir 2> /dev/null)" \
       != "$(git -C "$LEDGER_ROOT_REAL" rev-parse --git-common-dir 2> /dev/null)" ]; then
    _HD_LEDGER_IS_LINKED_WT=1
  fi
  _hd_wt_git_owned() { # -> exit 0/1: WORKSPACE_REAL is a path `git worktree list` names
    local _hd_ok=0 _hd_wt_line _hd_wt_real
    while IFS= read -r _hd_wt_line; do
      case "$_hd_wt_line" in
        worktree\ *)
          _hd_wt_real="$(cd "${_hd_wt_line#worktree }" 2> /dev/null && pwd -P)"
          [ -n "$_hd_wt_real" ] && [ "$_hd_wt_real" = "$WORKSPACE_REAL" ] && _hd_ok=1
          ;;
      esac
    done <<< "$(git -C "$LEDGER_ROOT_REAL" worktree list --porcelain 2> /dev/null)"
    return "$((1 - _hd_ok))"
  }
  if [ "$_HD_WT_OK" -eq 0 ] && [ "$_HD_LEDGER_IS_LINKED_WT" -eq 1 ]; then
    command -v jq > /dev/null 2>&1 && [ -f "$_HD_STATE_PATH" ] \
      || refuse "linked ledger root requires jq and a readable state.json to verify the DV-pin set (ledger-root $LEDGER_ROOT_REAL)"
    _HD_DV_PINNED=0
    while IFS= read -r _hd_dv_ws; do
      [ -n "$_hd_dv_ws" ] || continue
      _hd_dv_real="$(cd "$_hd_dv_ws" 2> /dev/null && pwd -P)"
      [ -n "$_hd_dv_real" ] && [ "$_hd_dv_real" = "$WORKSPACE_REAL" ] && _HD_DV_PINNED=1
    done <<< "$(jq -r \
      '.tasks | to_entries[] | select(.key | test("^DV")) | .value.metadata.workspace_path // ""' \
      "$_HD_STATE_PATH" 2> /dev/null)"
    if [ "$_HD_DV_PINNED" -eq 1 ] && _hd_wt_git_owned; then
      _HD_WT_OK=1
    fi
  elif [ "$_HD_WT_OK" -eq 0 ] && _hd_wt_git_owned; then
    _HD_WT_OK=1
  fi
  [ "$_HD_WT_OK" -eq 1 ] \
    || refuse "workspace $WORKSPACE_REAL is not a worktree this ledger pins (ledger-root $LEDGER_ROOT_REAL)"
fi

# The artifact is ledger-root-relative (metadata.artifact is always ".context/…"), never
# worktree-relative, and never allowed to walk out of the ledger root.
if [ -n "$ARTIFACT" ]; then
  case "$ARTIFACT" in
    *..*) refuse "artifact path must not contain ..: $ARTIFACT" ;;
  esac
fi

if [ -n "$SESSION_ID" ]; then
  [[ "$SESSION_ID" =~ ^[A-Za-z0-9-]+$ ]] || refuse "session id: $SESSION_ID"
fi
if [ -n "$RESUME_ID" ]; then
  [[ "$RESUME_ID" =~ ^[A-Za-z0-9-]+$ ]] || refuse "resume id: $RESUME_ID"
fi

# --out is confined to <ledger-root>/.context/logs/ (never an arbitrary path, never a
# planted symlink) and is mandatory outside --print-argv — there is no mktemp fallback to
# forget to clean up.
if [ "$PRINT_ARGV" -ne 1 ]; then
  case "$OUT_LOG" in
    *..*) refuse "out log path must not contain ..: $OUT_LOG" ;;
  esac
  [ ! -L "$OUT_LOG" ] || refuse "out log path is a symlink: $OUT_LOG"
  _HD_OUT_DIR_REAL="$(cd "$(dirname "$OUT_LOG")" 2> /dev/null && pwd -P)" \
    || refuse "out log directory does not exist: $(dirname "$OUT_LOG")"
  [ "$_HD_OUT_DIR_REAL" = "${LEDGER_ROOT_REAL}/.context/logs" ] \
    || refuse "out log must be under ledger-root/.context/logs: $OUT_LOG"
fi

if [ "$PRINT_ARGV" -ne 1 ] && [ -f "$STATE_PATH" ]; then
  CONTROLS=$(jq -ce --arg t "$TASK" '.tasks[$t].metadata | with_entries(select(.key ==
    ("auto_compact_window", "retry_watchdog", "retry_watchdog_max_wait_ms",
     "retry_watchdog_max_usage_limit_wait_ms", "overloaded_retry_max_delay_ms")))' "$STATE_PATH") \
    || refuse "unreadable dispatch controls"
fi
while [ "${#CONTROL_ARGS[@]}" -gt 0 ]; do
  _control_key="${CONTROL_ARGS[0]//-/_}"
  _control_value="${CONTROL_ARGS[1]}"
  case "$_control_value" in true | false) ;; *)
    [[ "$_control_value" =~ ^[1-9][0-9]*$ ]] || refuse "invalid dispatch control" ;;
  esac
  CONTROLS=$(printf '%s' "$CONTROLS" | jq -ce --arg k "$_control_key" --argjson v "$_control_value" '. + {($k):$v}') \
    || refuse "invalid dispatch control"
  CONTROL_ARGS=("${CONTROL_ARGS[@]:2}")
done
CONTROL_ENV=("CORPFLOW_HEADLESS_CHILD=$TASK")
dispatch_controls_validate "$CONTROLS" || refuse "invalid dispatch controls"
if dispatch_controls_present "$CONTROLS"; then HAS_CONTROLS=1; fi
if [ "$HAS_CONTROLS" -eq 1 ]; then
  for _control_pair in \
    'retry_watchdog:CLAUDE_CODE_RETRY_WATCHDOG' \
    'retry_watchdog_max_wait_ms:CLAUDE_CODE_RETRY_WATCHDOG_MAX_WAIT_MS' \
    'retry_watchdog_max_usage_limit_wait_ms:CLAUDE_CODE_RETRY_WATCHDOG_MAX_USAGE_LIMIT_WAIT_MS' \
    'overloaded_retry_max_delay_ms:CLAUDE_CODE_OVERLOADED_RETRY_MAX_DELAY_MS'; do
    _control_key="${_control_pair%%:*}"
    _control_name="${_control_pair#*:}"
    if printf '%s' "$CONTROLS" | jq -e --arg k "$_control_key" 'has($k)' >/dev/null; then
      _control_value=$(printf '%s' "$CONTROLS" | jq -r --arg k "$_control_key" '.[$k]')
      case "$_control_value" in true) _control_value=1 ;; false) _control_value=0 ;; esac
      CONTROL_ENV+=("$_control_name=$_control_value")
    fi
  done
fi

# --- argv (array, never a shell string) ------------------------------------------------------
ARGV=(-p --agent "$AGENT" --model "$MODEL" --effort "$EFFORT" \
  --permission-mode "$MODE" --permission-prompts none \
  --output-format stream-json --verbose)
_compact_window=""
if [ "$HAS_CONTROLS" -eq 1 ]; then
  _compact_window=$(printf '%s' "$CONTROLS" | jq -r '.auto_compact_window // empty')
fi
if [ -n "$_compact_window" ]; then
  ARGV+=(--autocompact "$_compact_window")
  CONTROL_ENV+=("CLAUDE_CODE_AUTO_COMPACT_WINDOW=$_compact_window")
fi
# --session-id and --resume are mutually exclusive on the CLI surface unless --fork-session is
# also passed, and this is a true resume of the SAME child, never a fork — so a resume call
# carries --resume alone; --session-id only reaches argv when there is no resume in play.
# SESSION_ID itself still stays set on a resume call (the caller passes the child's own uuid):
# it is the internal key emit_result reports and the audit-lookup prefix below matches on, not
# only a CLI flag.
if [ -n "$RESUME_ID" ]; then
  # The resume round-trip after a hook block: same argv, same env, just --resume added and the
  # block reason + additionalContext arriving on stdin instead of the original brief.
  ARGV+=(--resume "$RESUME_ID")
else
  [ -z "$SESSION_ID" ] || ARGV+=(--session-id "$SESSION_ID")
fi
# --bg, --dangerously-skip-permissions and --allow-dangerously-skip-permissions are never
# appended here — there is no branch above that can add them, by construction.

if [ "$PRINT_ARGV" -eq 1 ]; then
  printf '%s\0' "${ARGV[@]}"
  exit 0
fi

# --- pre-spawn fallback checks (no side effects possible yet) --------------------------------
FALLBACK_REASON=""
if ! command -v claude > /dev/null 2>&1; then
  FALLBACK_REASON="cli_missing"
else
  CC_VERSION="$(claude --version 2> /dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -z "$CC_VERSION" ] || ! printf '%s\n%s\n' "$MIN_CC_VERSION" "$CC_VERSION" \
    | sort -t. -k1,1n -k2,2n -k3,3n | head -1 | grep -qx "$MIN_CC_VERSION"; then
    FALLBACK_REASON="cli_below_floor"
  fi
fi

# "null" and "" become a bare JSON null; every other value is already allowlist-checked.
_hd_str_or_null() {
  if [ -z "$1" ] || [ "$1" = "null" ]; then printf 'null'; else printf '"%s"' "$1"; fi
}

emit_result() {
  # $1 result (ok|warn|error) $2 effort_transport $3 effort_resolved ("null" -> JSON null)
  # $4 fallback_reason (or "") $5 duration_ms (or null) $6 usage json (or null)
  # $7 total_cost_usd (or null) $8 effort_resolved_reason (or "")
  if command -v jq > /dev/null 2>&1; then
    jq -cn --arg task "$TASK" --arg agent "$AGENT" --arg session "$SESSION_ID" \
      --arg result "$1" --arg transport "$2" --arg resolved "$3" --arg reason "$4" \
      --argjson duration "${5:-null}" --argjson usage "${6:-null}" --argjson cost "${7:-null}" \
      --arg resolved_reason "${8:-}" \
      '{task:$task, agent:$agent, session_id:$session, result:$result,
        effort_transport:$transport,
        effort_resolved:(if $resolved == "null" then null else $resolved end),
        effort_resolved_reason:(if $resolved_reason == "" then null else $resolved_reason end),
        fallback_reason:(if $reason == "" then null else $reason end),
        duration_ms:$duration, usage:$usage, total_cost_usd:$cost}'
  else
    printf '{"task":"%s","agent":"%s","result":"%s","effort_transport":"%s","effort_resolved":%s,"effort_resolved_reason":%s,"fallback_reason":%s}\n' \
      "$TASK" "$AGENT" "$1" "$2" "$(_hd_str_or_null "$3")" "$(_hd_str_or_null "${8:-}")" \
      "$(_hd_str_or_null "$4")"
  fi
}

if [ -n "$FALLBACK_REASON" ]; then
  [ "$HAS_CONTROLS" -eq 0 ] || refuse "dispatch controls require headless execution: $FALLBACK_REASON"
  # Nothing has run yet on this path, so there is no side effect to check. The in-process
  # fallback carries the tier on `effort`; only its hook rows can report what ran.
  emit_result "warn" "agent-param" "null" "$FALLBACK_REASON" null null null "inproc_fallback"
  exit 0
fi

# A missing shasum must fail closed: without it, both the before- and after-spawn hashes
# would be the same empty string, and a real side effect would silently read as "no change" —
# the exact silent-pass this whole snapshot exists to prevent.
command -v shasum > /dev/null 2>&1 \
  || refuse "shasum is required for the side-effect snapshot and was not found on PATH"

# --- side-effect snapshot: HEAD, a content hash of tracked+untracked changes (not porcelain
# status — that only sees FILE NAMES, and stream worktrees are routinely already dirty), a
# content hash of the artifact under the LEDGER ROOT (never the worktree — metadata.artifact is
# ledger-relative; a hash rather than a mere existence check, because the artifact already
# exists on every rework round, so a failed child that only edited it in place would otherwise
# read as "no change" — R2), and the ledger row's status+handoff sha, all taken before spawn --
_hd_snapshot() {
  local head diff_hash untracked_hash artifact_hash row_status row_sha
  head="$(git -C "$WORKSPACE_REAL" rev-parse HEAD 2> /dev/null || printf 'none')"
  diff_hash="$(git -C "$WORKSPACE_REAL" diff HEAD --binary -- . ':(exclude).context/logs/' \
    2> /dev/null | shasum 2> /dev/null | awk '{print $1}')"
  # `git -C` only changes directory for git itself: the `xargs shasum` stage still runs in
  # THIS process's cwd, so every path `ls-files` reports (relative to the worktree) would
  # 404 there and hash nothing at all, hiding every untracked-file side effect. The inner
  # subshell cd's to the worktree before shasum ever sees a path.
  untracked_hash="$(git -C "$WORKSPACE_REAL" ls-files -o --exclude-standard -z \
    -- . ':(exclude).context/logs/' 2> /dev/null \
    | (cd "$WORKSPACE_REAL" && xargs -0 shasum -a 256 2> /dev/null) \
    | shasum 2> /dev/null | awk '{print $1}')"
  artifact_hash="absent"
  if [ -n "$ARTIFACT" ] && [ -f "${LEDGER_ROOT_REAL}/${ARTIFACT}" ]; then
    artifact_hash="$(shasum -a 256 "${LEDGER_ROOT_REAL}/${ARTIFACT}" 2> /dev/null | awk '{print $1}')"
  fi
  row_status=""
  row_sha=""
  if [ -n "$STATE_PATH" ] && [ -f "$STATE_PATH" ] && command -v jq > /dev/null 2>&1; then
    row_status="$(jq -r --arg t "$TASK" '.tasks[$t].status // ""' "$STATE_PATH" 2> /dev/null)"
    row_sha="$(jq -r --arg t "$TASK" \
      '(.tasks[$t].handoff // "") | tostring' "$STATE_PATH" 2> /dev/null)"
  fi
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' \
    "$head" "$diff_hash" "$untracked_hash" "$artifact_hash" "$row_status" "$row_sha"
}

SNAPSHOT_BEFORE="$(_hd_snapshot)"

LOG_FILE="$OUT_LOG"
EXIT_CODE=0
# cd into the stream worktree in a subshell before the spawn — the child's own cwd, not the
# orchestrator's — while WORKSPACE_ROOT still names the ledger root so the child's hooks
# resolve .context/state.json there rather than in the (ledger-less) worktree.
( cd "$WORKSPACE_REAL" \
  && exec env WORKSPACE_ROOT="$LEDGER_ROOT_REAL" \
       "${CONTROL_ENV[@]}" claude "${ARGV[@]}" ) < "$PROMPT" > "$LOG_FILE" 2>&1 \
  || EXIT_CODE=$?

SNAPSHOT_AFTER="$(_hd_snapshot)"
SIDE_EFFECTS=0
[ "$SNAPSHOT_BEFORE" = "$SNAPSHOT_AFTER" ] || SIDE_EFFECTS=1

# A non-zero exit with no auth-failure or agent-unresolved marker in the transcript reads as
# the plain "the child died before it did anything" case (exit_before_artifact).
if [ "$EXIT_CODE" -ne 0 ]; then
  if [ "$SIDE_EFFECTS" -eq 1 ]; then
    printf >&2 'headless-dispatch.sh: side effects present after a failed child; no fallback\n'
    # "requested, not applied" is reserved for the "none" transport (ADR-4) — a dead child
    # left work behind but never vouched for a tier, so this stays null/no_hook_rows like any
    # other unobserved dispatch-flag row, never that literal.
    emit_result "error" "dispatch-flag" "null" "side_effects_present" null null null \
      "no_hook_rows"
    exit 3
  fi
  REASON="exit_before_artifact"
  if grep -qiE 'auth(entication)? (failed|error)|not logged in' "$LOG_FILE" 2> /dev/null; then
    REASON="auth_failed"
  elif grep -qiE 'unknown agent|agent not found|no such agent' "$LOG_FILE" 2> /dev/null; then
    REASON="agent_unresolved"
  fi
  [ "$HAS_CONTROLS" -eq 0 ] || refuse "dispatch controls prevent in-process fallback: $REASON"
  emit_result "warn" "agent-param" "null" "$REASON" null null null "inproc_fallback"
  exit 0
fi

# --- success: pull duration/usage/cost from the stream-json `result` event -------------------
# effort_resolved is NEVER read from this event: the dispatch-flag transport's observed tier
# comes from the child's own audit-tooluse rows, written live by its PreToolUse/PostToolUse
# hooks into the ledger root's audit.jsonl (b2 makes that the same root this script itself
# reads) — never from the request, and never from the `result` event above, which only ever
# echoes back what was asked for.
RESULT_LINE="$(grep '"type":"result"' "$LOG_FILE" 2> /dev/null | tail -1)"
DURATION="null"
USAGE="null"
COST="null"
EFFORT_RESOLVED="null"
EFFORT_RESOLVED_REASON="no_hook_rows"
if [ -n "$RESULT_LINE" ] && command -v jq > /dev/null 2>&1; then
  DURATION="$(printf '%s' "$RESULT_LINE" | jq -c '.duration_ms // null' 2> /dev/null)"
  USAGE="$(printf '%s' "$RESULT_LINE" | jq -c '.usage // null' 2> /dev/null)"
  COST="$(printf '%s' "$RESULT_LINE" | jq -c '.total_cost_usd // null' 2> /dev/null)"
fi

# The row's own dedupe_key is "<session_id>:<tool_use_id>" (hooks/audit-tooluse.sh), never a
# bare session_id field, so the match is a prefix on that key — last matching row wins (the
# child's most recent observed tier), and an "unknown" effort (no hook payload carried one)
# never overwrites a real one. The observed value is re-validated against the tier enum: a
# malformed row the child itself appended (self-attested, per T5) must not flow downstream
# just because it parsed as a string.
_HD_AUDIT_LOG="${LEDGER_ROOT_REAL}/.context/logs/audit.jsonl"
if [ -n "$SESSION_ID" ] && [ -f "$_HD_AUDIT_LOG" ] && command -v jq > /dev/null 2>&1; then
  _HD_OBSERVED="$(jq -rs --arg pfx "${SESSION_ID}:" '
    map(select(.actor == "hook:audit-tooluse"
      and (.metadata.dedupe_key // "" | startswith($pfx))
      and (.metadata.effort // "unknown") != "unknown"))
    | last | .metadata.effort // ""' "$_HD_AUDIT_LOG" 2> /dev/null)"
  if [ -n "$_HD_OBSERVED" ] && [ "$_HD_OBSERVED" != "null" ] \
    && effort_rank "$_HD_OBSERVED" > /dev/null 2>&1; then
    EFFORT_RESOLVED="$_HD_OBSERVED"
    EFFORT_RESOLVED_REASON=""
  fi
fi

emit_result "ok" "dispatch-flag" "$EFFORT_RESOLVED" "" "$DURATION" "$USAGE" "$COST" \
  "$EFFORT_RESOLVED_REASON"
exit 0
