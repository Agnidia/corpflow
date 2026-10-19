#!/usr/bin/env bash
# @description model-switch-lib.sh — sourceable library shared by four hooks:
#   model-switch-gate.sh (PreModelSwitch decision), model-switch-audit.sh
#   (PostModelSwitch observer), test-execution-gate.sh (PreToolUse test-authority
#   gate) and state-merge.sh (SubagentStop ledger merge).
#
#   Dependency-free by construction: sources nothing, sets no shell options, probes
#   nothing at load time, no side effects at load. That keeps the shared point of
#   failure a LEAF — there is no load-order graph across consumers to get wrong.
#   Adding a `source` here is a design change, not a refactor.
#
#   Every symbol returns 0 on every path; failure is the empty string on stdout.
#   A non-zero return would abort a `set -e` consumer from inside a library whose
#   whole purpose is to keep those consumers fail-open.
#
#   Symbols: corpflow_workspace_root, corpflow_context_root, corpflow_active_stage,
#   corpflow_resolve_pin, corpflow_stage_and_pin, corpflow_model_family,
#   corpflow_switch_dest, corpflow_switch_origin, corpflow_switch_fields,
#   corpflow_audit_task_id, corpflow_hook_audit_row, corpflow_bind_payload,
#   corpflow_first_user_text.
#
# Minimum shell: bash 3.2+ (macOS default). Correct under the union of its
# consumers' option sets, `set -euf -o pipefail`, while setting none of them.

# Anti-execution guard — MUST be the first statement.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  printf >&2 'model-switch-lib.sh: this is a library — source it, do not execute it directly\n'
  exit 2
fi

# Include guard — MUST be the second statement. `readonly -f` below makes a second
# source a fatal redefinition attempt rather than a no-op, so four consumers that
# may transitively source each other need this to be idempotent.
[ -n "${_CORPFLOW_HOOK_LIB:-}" ] && return 0
_CORPFLOW_HOOK_LIB=1

# _cf_rank6_owns <main-checkout> <git-toplevel> — rc 0 when the session is
# the main checkout (physical CLAUDE_PROJECT_DIR equals it) or the toplevel is a
# stage worktree the main ledger registered as some task's metadata.workspace_path.
# Both sides are compared physically; a missing jq or unreadable ledger is rc 1,
# which callers read as "no worktask here".
_cf_rank6_owns() {
  local _o_main="${1:-}" _o_top="${2:-}" _o_pd _o_wp _o_wpp
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    _o_pd="$(CDPATH='' cd -- "$CLAUDE_PROJECT_DIR" 2> /dev/null && pwd -P)"
    [ -n "$_o_pd" ] && [ "$_o_pd" = "$_o_main" ] && return 0
  fi
  [ -n "$_o_top" ] || return 1
  _o_top="$(CDPATH='' cd -- "$_o_top" 2> /dev/null && pwd -P)"
  [ -n "$_o_top" ] || return 1
  command -v jq > /dev/null 2>&1 || return 1
  while IFS= read -r _o_wp; do
    [ -n "$_o_wp" ] || continue
    _o_wpp="$(CDPATH='' cd -- "$_o_wp" 2> /dev/null && pwd -P)"
    [ -n "$_o_wpp" ] && [ "$_o_wpp" = "$_o_top" ] && return 0
  done <<< "$(jq -r '(.tasks // {}) | to_entries[]
      | (.value.metadata.workspace_path? // empty) | select(type == "string")' \
    "$_o_main/.context/state.json" 2> /dev/null)"
  return 1
}

# Cleared at load so an inherited environment value can never act as a global
# override: only corpflow_bind_payload, inside this hook process, may set it.
_CORPFLOW_ISSUE_ROOT=""

# _cf_issue_root_of <path> — echoes the /megatask per-issue worktree
# <base>/.worktrees/<group>/<issue#> holding <path>, or nothing. <base> must be a
# declared root (WORKSPACE_ROOT or CLAUDE_PROJECT_DIR), so a payload can only
# narrow the session's own root, never point a hook at an arbitrary tree; the
# worktree must carry both workspace.json and its own ledger.
_cf_issue_root_of() {
  local _i_p _i_base _i_bp _i_rest _i_group _i_num _i_wt
  [ -n "${1:-}" ] || return 0
  _i_p="$(CDPATH='' cd -- "$1" 2> /dev/null && pwd -P)"
  [ -n "$_i_p" ] || return 0
  for _i_base in "${WORKSPACE_ROOT:-}" "${CLAUDE_PROJECT_DIR:-}"; do
    [ -n "$_i_base" ] || continue
    _i_bp="$(CDPATH='' cd -- "$_i_base" 2> /dev/null && pwd -P)"
    [ -n "$_i_bp" ] && [ -d "$_i_bp/.worktrees" ] || continue
    case "$_i_p/" in
      "$_i_bp/.worktrees/"*/*/*) ;;
      *) continue ;;
    esac
    _i_rest="${_i_p#"$_i_bp/.worktrees/"}/"
    _i_group="${_i_rest%%/*}"
    _i_rest="${_i_rest#*/}"
    _i_num="${_i_rest%%/*}"
    case "$_i_num" in '' | *[!0-9]*) continue ;; esac
    _i_wt="$_i_bp/.worktrees/$_i_group/$_i_num"
    if [ -f "$_i_wt/workspace.json" ] && [ -f "$_i_wt/.context/state.json" ]; then
      printf '%s' "$_i_wt"
      return 0
    fi
  done
  return 0
}

# corpflow_first_user_text <transcript_path> — echoes the text of the first user record
# within the first 40 lines of a JSONL transcript: the acting agent's dispatch prompt.
# Array content joins its text parts with newlines. Empty for a missing or unreadable
# file, no jq, or no user record. The single place that assumes the transcript schema, so
# the bind and the audit stage rung drift together if it changes.
corpflow_first_user_text() {
  local _u_tp="${1:-}"
  [ -n "$_u_tp" ] && [ -f "$_u_tp" ] && [ -r "$_u_tp" ] || return 0
  command -v jq > /dev/null 2>&1 || return 0
  head -n 40 "$_u_tp" 2> /dev/null | jq -rn '
      first(inputs | select(.type? == "user")) | .message.content
      | if type == "string" then . elif type == "array"
        then (map(select(.type? == "text") | .text | strings) | join("\n")) else empty end
    ' 2> /dev/null || :
  return 0
}

# corpflow_bind_payload <hook-stdin-json> — binds THIS hook process to the
# /megatask per-issue worktree the payload belongs to, so corpflow_workspace_root
# answers the issue's ledger ahead of WORKSPACE_ROOT/CLAUDE_PROJECT_DIR, which a
# hook inherits from the batch session, not from the per-issue Bash prefix.
# Per-process by design: concurrent issues each get their own hook process, so no
# shared mutable state can cross-bind them. Candidates, first valid one wins: the
# `WORKSPACE_ROOT=` banner in the acting agent's own dispatch prompt (first user
# record of its transcript), a `WORKSPACE_ROOT=<path>` assignment in the payload's
# command (read as text, never expanded), the payload's cwd, this process's cwd.
# A subagent's cwd is the session's, so a session inside one issue's worktree
# must not outrank the issue the agent names; the agent writes its command but
# not its prompt, so the banner outranks the command. No match changes nothing.
corpflow_bind_payload() {
  local _b_payload="${1:-}" _b_fields _b_cwd="" _b_tp="" _b_cmd="" _b_cand="" _b_wt="" _b_re
  _CORPFLOW_ISSUE_ROOT=""
  # Cheap exit for every non-megatask session: no .worktrees under a declared
  # root means no candidate can validate, so skip the payload and transcript reads.
  if { [ -z "${WORKSPACE_ROOT:-}" ] || [ ! -d "${WORKSPACE_ROOT}/.worktrees" ]; } \
    && { [ -z "${CLAUDE_PROJECT_DIR:-}" ] || [ ! -d "${CLAUDE_PROJECT_DIR}/.worktrees" ]; }; then
    return 0
  fi
  if [ -n "$_b_payload" ] && command -v jq > /dev/null 2>&1; then
    # Only an assignment in a position bash honours matches, and a value holding
    # `$`, a backtick or a backslash never does. \x27 is a single quote.
    # shellcheck disable=SC2016 # a jq regex: `$` and backticks are pattern text, never expanded
    _b_re='(?:^|[\n;&|(])[ \t]*(?:export[ \t]+)?(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|\x27[^\x27]*\x27|[^ \t\n;&|"\x27]*)[ \t]+)*WORKSPACE_ROOT=(?:"(/[^"$`\\\n]*)"|\x27(/[^\x27\n]*)\x27|(/[^ \t\n;&|"\x27$`\\()<>]*))(?=[ \t\n;&|)]|$)'
    # A line break would shift the fields, so such a value is dropped. On
    # SubagentStop, transcript_path is the parent's; the agent's own is preferred.
    _b_fields=$(printf '%s' "$_b_payload" | jq -r --arg re "$_b_re" '
        def one: if type == "string" and ((contains("\n") or contains("\r")) | not) then . else "" end;
        ((.cwd // "") | one),
        (((.agent_transcript_path // .transcript_path) // "") | one),
        ((try ((.tool_input | objects | .command | strings)
                | [match($re).captures[] | .string | strings][0]) catch "") // "" | one)
      ' 2> /dev/null) || _b_fields=""
    {
      IFS= read -r _b_cwd || :
      IFS= read -r _b_tp || :
      IFS= read -r _b_cmd || :
    } <<< "$_b_fields"
  fi
  if [ -n "$_b_tp" ]; then
    _b_cand=$(corpflow_first_user_text "$_b_tp" \
      | sed -n 's/^WORKSPACE_ROOT=\(\/.*\)$/\1/p' | head -n 1) || _b_cand=""
    _b_wt=$(_cf_issue_root_of "$_b_cand")
  fi
  [ -n "$_b_wt" ] || _b_wt=$(_cf_issue_root_of "$_b_cmd")
  [ -n "$_b_wt" ] || _b_wt=$(_cf_issue_root_of "$_b_cwd")
  [ -n "$_b_wt" ] || _b_wt=$(_cf_issue_root_of "${PWD:-}")
  _CORPFLOW_ISSUE_ROOT="$_b_wt"
  return 0
}

# corpflow_workspace_root — echoes the absolute workspace root and also
# assigns it to _CORPFLOW_WS_ROOT, so a caller on a hot path can read the value
# without paying for a command substitution. Arguments are ignored.
# Always returns 0; an empty echo IS the unresolved answer, never a cwd guess.
# Resolves independently of cwd: a worktree checkout gitignores .context/, so
# these hooks cannot rely on finding it under cwd.
#
# Ranks 3-6 of the shared root-resolution ladder; ranks 1-2 are scripts-tree
# only (see skills/shared/lib/state-read-lib.sh). A per-issue worktree bound by
# corpflow_bind_payload answers ahead of rank 3. Every rank demands
# .context/state.json: a bare folder is what a stray mkdir leaves, and no hook
# may create the first .context/ — only the seed does. Ranks 5-6 also pass
# corpflow_inferred_ctx_ok (state-read-lib.sh): a cwd nested in the plugin checkout resolves empty.
corpflow_workspace_root() {
  local _cf_libdir _cf_resolver _cf_top _cf_root _cf_opts
  _CORPFLOW_WS_ROOT=""

  if [ -n "${_CORPFLOW_ISSUE_ROOT:-}" ] && [ -f "${_CORPFLOW_ISSUE_ROOT}/.context/state.json" ]; then
    _CORPFLOW_WS_ROOT="${_CORPFLOW_ISSUE_ROOT}"
    printf '%s' "$_CORPFLOW_WS_ROOT"; return 0
  fi

  if [ -n "${WORKSPACE_ROOT:-}" ] && [ -f "${WORKSPACE_ROOT}/.context/state.json" ]; then
    _CORPFLOW_WS_ROOT="${WORKSPACE_ROOT}"
    printf '%s' "$_CORPFLOW_WS_ROOT"; return 0
  fi

  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "${CLAUDE_PROJECT_DIR}/.context/state.json" ]; then
    _CORPFLOW_WS_ROOT="${CLAUDE_PROJECT_DIR}"
    printf '%s' "$_CORPFLOW_WS_ROOT"; return 0
  fi

  # Ranks 5-6 share one resolver lookup and are skipped together when it is not
  # a readable file: rank 6 cannot run without it, and running rank 5's git probe
  # alone on an install too broken to locate its own resolver would answer a
  # plain git question with a plugin-config-shaped confidence it has not earned.
  # Located from this file, not the plugin-root env var, so the resolver always
  # comes from the same plugin tree as the library that loaded it.
  _cf_resolver=""
  _cf_libdir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2> /dev/null && pwd -P)"
  if [ -n "$_cf_libdir" ] \
    && [ -r "$_cf_libdir/../skills/shared/scripts/resolve-root.sh" ]; then
    _cf_resolver="$_cf_libdir/../skills/shared/scripts/resolve-root.sh"
  fi

  if [ -n "$_cf_resolver" ]; then
    _cf_top=""
    _cf_top=$(git rev-parse --show-toplevel 2> /dev/null || true)
    # Ranks 5-6 are inferred from the cwd and need the reader guard. Sourced lazily and only
    # here: 15 hooks consume this lib and not all drop -e around it, so -e is dropped for the
    # source and restored. A guard that cannot load skips both ranks, like a missing resolver.
    if ! command -v corpflow_inferred_ctx_ok > /dev/null 2>&1 \
      && [ -r "$_cf_libdir/../skills/shared/lib/state-read-lib.sh" ]; then
      _cf_opts="$-"
      set +e
      # shellcheck source=../skills/shared/lib/state-read-lib.sh
      . "$_cf_libdir/../skills/shared/lib/state-read-lib.sh" 2> /dev/null
      case "$_cf_opts" in *e*) set -e ;; esac
    fi
    if ! command -v corpflow_inferred_ctx_ok > /dev/null 2>&1; then
      printf ''
      return 0
    fi
    if [ -n "$_cf_top" ] && [ -f "$_cf_top/.context/state.json" ]; then
      # A refusal ends the ladder: falling through to rank 6 would swap this tree's ledger
      # for the main checkout's.
      corpflow_inferred_ctx_ok "$_cf_top/.context" "$_cf_top" || { printf ''; return 0; }
      _CORPFLOW_WS_ROOT="$_cf_top"
      printf '%s' "$_CORPFLOW_WS_ROOT"; return 0
    fi

    _cf_root=""
    _cf_root=$(bash "$_cf_resolver" --root 2> /dev/null || true)
    # Rank 6 requires an existing ledger, not just a git root; --root doesn't
    # check this itself (existence-unchecked per its own docstring). It also
    # requires the main checkout's ledger to own THIS tree: any linked worktree
    # of the repo reaches the same main checkout, and borrowing its ledger from
    # an unrelated worktree turns that ledger's gates on work it never ran.
    if [ -n "$_cf_root" ] && [ -f "$_cf_root/.context/state.json" ] \
      && corpflow_inferred_ctx_ok "$_cf_root/.context" "$_cf_top" \
      && _cf_rank6_owns "$_cf_root" "$_cf_top"; then
      _CORPFLOW_WS_ROOT="$_cf_root"
      printf '%s' "$_CORPFLOW_WS_ROOT"; return 0
    fi
  fi

  printf ''
  return 0
}

# Echoes an absolute path to .context/, or the empty string when
# corpflow_workspace_root cannot resolve one — never `/.context` or `./.context`,
# which a caller's mkdir would otherwise plant under whatever cwd it happened to
# run from. Read view of the resolver above; called as a plain function, not
# through $( ), so the hot path pays no extra fork.
corpflow_context_root() {
  corpflow_workspace_root > /dev/null
  if [ -n "${_CORPFLOW_WS_ROOT:-}" ]; then
    printf '%s' "${_CORPFLOW_WS_ROOT}/.context"
  else
    printf ''
  fi
  return 0
}

# Echoes the single in_progress stage code, or empty.
#
# Every ambiguity resolves to empty, never a guess: no state.json, no jq, an
# unparseable file, zero or more than one distinct stage, or an unrecognized
# token. Empty means there is no reliable "who is acting" answer.
corpflow_active_stage() {
  local _ctx="${1:-}" _state _stages
  _state="$_ctx/state.json"
  [ -f "$_state" ] || { printf ''; return; }
  command -v jq > /dev/null 2>&1 || { printf ''; return; }

  # Ledger keys are numbered (DV0, DV1) but the pin is per stage CODE, so
  # parallel tracks of one stage collapse to a single unambiguous answer.
  _stages=$(jq -r '
    if (.tasks|type=="object") then
      (.tasks | to_entries | map(select(.value.status=="in_progress"))
        | map(.key | sub("[0-9]+$"; "")) | unique)
    else [] end
    | join(",")
  ' "$_state" 2> /dev/null) || { printf ''; return; }

  case "$_stages" in
    *,* | "") printf ''; return ;;
  esac

  case "$_stages" in
    PL | AR | TL | DV | DR | SR | QA | DC | RE | FN | ST | IR | ET) printf '%s' "$_stages" ;;
    *) printf '' ;;
  esac
}

# Echoes "<model_requested> <task_id>" for the pinned stage, or empty.
#
# Reads .facts.dispatched_agents[] (schema: handoff-protocol.md § facts —
# dispatched_agents). This is the gate's one non-guessed input, which is why the
# whole decision keys on it. Match order: exactly one launched row for the agent
# id, else exactly one launched row for the stage, else empty — ambiguous is
# unresolved, never a guess. A settled dispatch (completed, failed) is not a live
# pin on either arm. A row without model_requested carries no pin.
corpflow_resolve_pin() {
  local _ctx="${1:-}" _stage="${2:-}" _agent_id="${3:-}" _state _out
  _state="$_ctx/state.json"
  [ -f "$_state" ] || { printf ''; return; }
  [ -n "$_stage" ] || { printf ''; return; }
  command -v jq > /dev/null 2>&1 || { printf ''; return; }

  _out=$(jq -r --arg stage "$_stage" --arg aid "$_agent_id" '
    (if (.facts|type=="object") and (.facts.dispatched_agents|type=="array")
       then .facts.dispatched_agents else [] end) as $rows
    | ( if ($aid | length) > 0
          then ($rows | map(select(.agent_id == $aid and .status == "launched")))
          else [] end ) as $byid
    | ( if ($byid | length) == 1
          then $byid
          else ($rows | map(select(.stage == $stage and .status == "launched")))
        end ) as $cand
    | if ($cand | length) == 1
        and (($cand[0].model_requested // "") | length) > 0
        and (($cand[0].task_id // "") | length) > 0
      then "\($cand[0].model_requested) \($cand[0].task_id)"
      else "" end
  ' "$_state" 2> /dev/null) || { printf ''; return; }

  printf '%s' "$_out"
}

# Echoes opus|sonnet|haiku|fable, or empty.
#
# Normalizes an alias and a fully-resolved id onto one family so a difference in
# SPELLING is never read as a re-tier. Unrecognized yields empty, which callers
# read as "cannot compare" — not as "different".
corpflow_model_family() {
  local _raw _lower
  _raw="${1:-}"
  [ -n "$_raw" ] || { printf ''; return; }
  # tr, not ${x,,}: bash 3.2 has no case-conversion expansion.
  _lower=$(printf '%s' "$_raw" | tr '[:upper:]' '[:lower:]') || _lower=""
  case "$_lower" in
    *opus*) printf 'opus' ;;
    *sonnet*) printf 'sonnet' ;;
    *haiku*) printf 'haiku' ;;
    *fable*) printf 'fable' ;;
    *) printf '' ;;
  esac
}

# The three ASSUMED-field coalesces (see model-switch-gate.sh's CONFIRMED/ASSUMED
# split), each written exactly once. The per-field accessors and the combined
# reader below all interpolate these, so the gate's decision and the audit row can
# never disagree about what a payload said, and a schema-drift fix is one edit.
_CORPFLOW_JQ_DEST='.to_model // .toModel // .requested_model // .requestedModel // .new_model // .newModel // ""'
_CORPFLOW_JQ_ORIGIN='.from_model // .fromModel // .current_model // .currentModel // ""'
_CORPFLOW_JQ_TRIGGER='.reason // .trigger // .source // ""'

# corpflow_switch_dest <payload> — echoes the destination model, or empty.
# corpflow_switch_origin <payload> — echoes the origin model, or empty.
#
# The single-field view. Hooks on the hot path use corpflow_switch_fields instead;
# these stay as the named, unit-tested API for one field at a time.
corpflow_switch_dest() {
  local _cf_payload _cf_out
  _cf_payload="${1:-}"
  [ -n "$_cf_payload" ] || { printf ''; return 0; }
  command -v jq > /dev/null 2>&1 || { printf ''; return 0; }
  _cf_out=$(printf '%s' "$_cf_payload" | jq -r "$_CORPFLOW_JQ_DEST" 2> /dev/null) || _cf_out=""
  printf '%s' "$_cf_out"
  return 0
}

corpflow_switch_origin() {
  local _cf_payload _cf_out
  _cf_payload="${1:-}"
  [ -n "$_cf_payload" ] || { printf ''; return 0; }
  command -v jq > /dev/null 2>&1 || { printf ''; return 0; }
  _cf_out=$(printf '%s' "$_cf_payload" | jq -r "$_CORPFLOW_JQ_ORIGIN" 2> /dev/null) || _cf_out=""
  printf '%s' "$_cf_out"
  return 0
}

# corpflow_switch_fields <payload> — echoes one TAB-separated line,
# `agent_id \t destination \t origin \t trigger`, or the EMPTY STRING when the
# payload is not parseable JSON. That empty answer folds the callers' separate
# `jq -e .` validity probe into this one, so a decision costs one jq over the
# payload instead of five.
#
# @tsv, not string interpolation: these are untrusted payload values, and @tsv
# escapes an embedded tab or newline rather than letting it invent a field. A
# parseable payload with none of the assumed fields yields three empty fields,
# which is a different answer from unparseable and must stay distinguishable.
corpflow_switch_fields() {
  local _cf_payload _cf_out
  _cf_payload="${1:-}"
  [ -n "$_cf_payload" ] || { printf ''; return 0; }
  command -v jq > /dev/null 2>&1 || { printf ''; return 0; }
  _cf_out=$(printf '%s' "$_cf_payload" | jq -r "
    [ (.agent_id // \"\"), ($_CORPFLOW_JQ_DEST), ($_CORPFLOW_JQ_ORIGIN), ($_CORPFLOW_JQ_TRIGGER) ]
    | map(tostring) | @tsv" 2> /dev/null) || _cf_out=""
  printf '%s' "$_cf_out"
  return 0
}

# corpflow_stage_and_pin <ctx> <agent_id> — echoes one TAB-separated line,
# `stage \t model_requested \t task_id`, with empty fields for every ambiguity.
#
# The combined view of corpflow_active_stage and corpflow_resolve_pin: both read
# the same state.json for the same decision, and the pin lookup needs the stage,
# so asking twice pays two jq processes to re-parse one file. Semantics are those
# two functions' exactly — every ambiguity resolves to empty, never a guess — and
# the parity is what the lib suite asserts.
corpflow_stage_and_pin() {
  local _cf_ctx _cf_aid _cf_state _cf_out
  _cf_ctx="${1:-}"
  _cf_aid="${2:-}"
  _cf_state="$_cf_ctx/state.json"
  [ -f "$_cf_state" ] || { printf ''; return 0; }
  command -v jq > /dev/null 2>&1 || { printf ''; return 0; }
  _cf_out=$(jq -r --arg aid "$_cf_aid" '
    (if (.tasks|type=="object") then
       (.tasks | to_entries | map(select(.value.status=="in_progress"))
         | map(.key | sub("[0-9]+$"; "")) | unique)
     else [] end) as $codes
    | (if ($codes|length) == 1 then $codes[0] else "" end) as $one
    | (if ($one | test("^(PL|AR|TL|DV|DR|SR|QA|DC|RE|FN|ST|IR|ET)$")) then $one else "" end) as $stage
    | (if (.facts|type=="object") and (.facts.dispatched_agents|type=="array")
         then .facts.dispatched_agents else [] end) as $rows
    | (if ($aid | length) > 0
         then ($rows | map(select(.agent_id == $aid and .status == "launched")))
         else [] end) as $byid
    | (if ($byid | length) == 1
         then $byid
         else ($rows | map(select(.stage == $stage and .status == "launched")))
       end) as $cand
    | (if ($stage | length) > 0 and ($cand | length) == 1
          and ((($cand[0].model_requested // "") | length) > 0)
          and ((($cand[0].task_id // "") | length) > 0)
        then [($cand[0].model_requested), ($cand[0].task_id)]
        else ["", ""] end) as $pin
    | [$stage, $pin[0], $pin[1]] | @tsv
  ' "$_cf_state" 2> /dev/null) || _cf_out=""
  printf '%s' "$_cf_out"
  return 0
}

# corpflow_audit_task_id <ctx> — the task_id for a row whose caller holds no ledger key
# of its own: the one in_progress key; "none" with no ledger or nothing in progress;
# "unknown" when the ledger cannot say which. Never empty, unlike every other symbol
# here, because an empty task_id is exactly what the appender below refuses.
corpflow_audit_task_id() {
  local _cf_state="${1:-}/state.json" _cf_keys
  [ -f "$_cf_state" ] || { printf 'none'; return 0; }
  command -v jq > /dev/null 2>&1 || { printf 'unknown'; return 0; }
  _cf_keys=$(jq -r '
    if (.tasks|type=="object") then
      [.tasks | to_entries[] | select(.value.status=="in_progress") | .key
        | select(test("^[A-Z]{2}[0-9]+$"))] | join(",")
    else "" end
  ' "$_cf_state" 2> /dev/null) || { printf 'unknown'; return 0; }
  case "$_cf_keys" in
    "") printf 'none' ;;
    *,*) printf 'unknown' ;;
    *) printf '%s' "$_cf_keys" ;;
  esac
  return 0
}

# corpflow_hook_audit_row --ctx C --actor A --action ACT --result R --subject S --task-id T --meta JSON
#
# Named apart from the row appender in skills/shared/lib/audit-lib.sh on purpose: the two
# shared one name until 4.0.29. They take incompatible flags (--ctx here, a file path there)
# and skip unknown ones silently, so a consumer of both got last-loaded-wins, and a call
# carrying the other's flags wrote nothing and returned 0. `readonly -f` below turns the
# opposite load order into a hard redefinition error instead. Two names cannot collide; one
# name with two shapes is the silent-write class this release set out to remove.
#
# Appends one row to <ctx>/logs/audit.jsonl. Returns 0 always, including on every
# refusal — an audit failure must never become a hook's exit code.
#
# Flag-parsed rather than positional on purpose: two adjacent free-form strings
# (`action`, `result`) in a positional signature make a transposition produce a
# VALID ROW THAT LIES, which is the worst failure an audit log has. `result` and
# `actor` are held to closed sets for the same reason: a transposition then drops
# the row loudly instead of recording a plausible falsehood.
#
# `subject` and `task_id` are required and non-empty: a row no reader can attribute
# to a task is a gap that looks like a record. A call missing either writes nothing
# and names the key on one stderr line. `skipped` records a no-op that still happened.
#
# Malformed `--meta` degrades to {"_meta_invalid":true} rather than dropping the
# row: losing metadata beats losing a result:"block" row.
corpflow_hook_audit_row() {
  local _cf_ctx="" _cf_actor="" _cf_action="" _cf_result="" _cf_meta="" _cf_subject=""
  local _cf_task_id="" _cf_missing="" _cf_dir _cf_file _cf_ts _cf_row
  while [ "$#" -gt 0 ]; do
    case "${1:-}" in
      --ctx)     _cf_ctx="${2:-}" ;;
      --actor)   _cf_actor="${2:-}" ;;
      --action)  _cf_action="${2:-}" ;;
      --result)  _cf_result="${2:-}" ;;
      --meta)    _cf_meta="${2:-}" ;;
      --subject) _cf_subject="${2:-}" ;;
      --task-id) _cf_task_id="${2:-}" ;;
      *) shift; continue ;;
    esac
    # Never `shift 2` blind: a flag given with no value would shift past $# and
    # abort a `set -e` caller from inside the appender.
    if [ "$#" -gt 1 ]; then shift 2; else shift; fi
  done

  [ -n "$_cf_ctx" ] || return 0
  [ -n "$_cf_action" ] || return 0
  case "$_cf_actor" in hook:?*) : ;; *) return 0 ;; esac
  case "$_cf_result" in ok | block | degraded | skipped) : ;; *) return 0 ;; esac

  [ -n "$_cf_subject" ] || _cf_missing="subject"
  [ -n "$_cf_task_id" ] || _cf_missing="${_cf_missing:+$_cf_missing and }task_id"
  if [ -n "$_cf_missing" ]; then
    printf >&2 'corpflow_hook_audit_row: %s row not written, missing %s\n' \
      "${_cf_action//[^A-Za-z0-9_.:-]/_}" "$_cf_missing" || :
    return 0
  fi
  command -v jq > /dev/null 2>&1 || return 0

  [ -n "$_cf_meta" ] || _cf_meta="{}"
  printf '%s' "$_cf_meta" | jq -e . > /dev/null 2>&1 || _cf_meta='{"_meta_invalid":true}'

  _cf_dir="$_cf_ctx/logs"
  _cf_file="$_cf_dir/audit.jsonl"
  mkdir -p "$_cf_dir" 2> /dev/null || return 0
  # A symlinked audit.jsonl would turn this append into a write primitive against
  # an arbitrary target.
  [ ! -L "$_cf_file" ] || return 0
  _cf_ts=$(date -u +%FT%TZ 2> /dev/null) || _cf_ts="unknown"
  [ -n "$_cf_ts" ] || _cf_ts="unknown"

  # Key order is pinned by construction, not by jq's sort: assert with
  # keys_unsorted, never keys.
  _cf_row=$(jq -cn --arg ts "$_cf_ts" --arg actor "$_cf_actor" --arg action "$_cf_action" \
    --arg subject "$_cf_subject" --arg result "$_cf_result" --arg task_id "$_cf_task_id" \
    --argjson meta "$_cf_meta" '
    {ts: $ts, actor: $actor, action: $action, subject: $subject, result: $result,
     task_id: $task_id, metadata: $meta}
  ' 2> /dev/null) || return 0
  { printf '%s\n' "$_cf_row" >> "$_cf_file"; } 2> /dev/null || return 0
  return 0
}

# readonly -f makes self-test isolation un-violable rather than merely checkable:
# a body that tried to redefine a library symbol is refused, the original survives,
# and the refusal does not abort a `set -e` shell. Requires the include guard above.
readonly -f corpflow_workspace_root corpflow_context_root corpflow_active_stage \
  corpflow_resolve_pin corpflow_stage_and_pin corpflow_model_family \
  corpflow_switch_dest corpflow_switch_origin corpflow_switch_fields \
  corpflow_audit_task_id corpflow_hook_audit_row _cf_rank6_owns \
  _cf_issue_root_of corpflow_bind_payload corpflow_first_user_text
