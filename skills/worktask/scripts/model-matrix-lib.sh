#!/usr/bin/env bash
# @description model-matrix-lib.sh — the one extractor for the Agent Model Matrix table
#   in stage-codes.md, the fail-open reader for a project's `CORPFLOW.md § Models` override,
#   and the ranked resolver both feed. state-patch.sh and effort-ladder.bats source this file;
#   model-matrix.sh wraps it for callers that cannot source bash. A fourth parser anywhere is
#   a review reject.
#
#   Hardening, each mapped to an observed misfire:
#     1. Section-anchored, not row-shaped: scope opens on the literal `## Agent Model Matrix`
#        heading line and closes at the next `^#` line of ANY level — a note paragraph inside
#        the section must not end capture, the next heading always must.
#     2. Header assertion: the exact `| Agent | Model | Effort |` header is required inside
#        scope; a row with other than three cells is a hard error, never a silent skip.
#     3. Cell validation, hard-fail: agent matches `^[a-z][a-z0-9-]*$` AND `agents/<agent>.md`
#        exists; model is opus/sonnet/haiku; effort is a rung effort-ladder.sh knows. This,
#        not the floor below, is what stops a literal like `opus` being read as an agent name
#        — the row fails on "no agents/opus.md", not on a name-shape heuristic.
#     4. Non-vacuity floor: zero rows or a duplicate agent hard-fails; callers assert the row
#        set is a bijection with `agents/*.md` themselves (stronger than a hard-coded count).
#
#   `model_override_rows` reads a CORPFLOW.md `## Models` section the same way, fail-open row
#   by row: a malformed cell or an unknown agent name is never fatal — the caller decides what
#   to audit. `corpflow_md_locate` picks WHICH CORPFLOW.md carries a heading: the project-root
#   file when it has that heading, else the user-scope one under
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}. `model_resolve` composes both into the three READ
#   ranks (state.models -> CORPFLOW.md -> built-in matrix); ranks 4-5 (the stamped task, an
#   explicit dispatch flag) are not read ranks and live in the caller.
#
#   Symbols: MODEL_ENUM, model_matrix_rows, model_override_rows, model_resolve,
#   corpflow_md_user_path, corpflow_md_locate, corpflow_md_source.
#
# @exitcode 2 executed rather than sourced
# @exitcode 3 model_matrix_rows: extraction failure (bad heading/header/row, zero rows, dup)
#
# Minimum shell: bash 3.2+ (macOS default) — no associative arrays, no `local -n`.

# Anti-execution guard — MUST be the first statement.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  printf >&2 'model-matrix-lib.sh: this is a library — source it, do not execute it directly\n'
  exit 2
fi

# Include guard: a double source is a no-op rather than a re-assignment.
[ -n "${_CORPFLOW_MODEL_MATRIX_LIB:-}" ] && return 0
_CORPFLOW_MODEL_MATRIX_LIB=1

# Alias-level vocabulary — matches what metadata.model actually carries
# (model-selection.md § Prefer the alias over a pinned id). Not `readonly`: bats suites
# source this file more than once per process.
MODEL_ENUM='opus sonnet haiku'

# effort_rank comes from effort-ladder.sh, never re-typed here (hardening rule 3 above). Sourced
# defensively: a caller that already has it loaded pays nothing extra (include-guarded).
_MML_EFFORT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/effort-ladder.sh"
if [ -z "${EFFORT_ENUM:-}" ] && [ -r "$_MML_EFFORT_LIB" ]; then
  # shellcheck source=effort-ladder.sh
  . "$_MML_EFFORT_LIB"
fi

# Plugin root is three levels up from skills/worktask/scripts/. Computed once at source
# time; every default below hangs off it so a caller that sources this from anywhere still
# resolves the live doc and the live agents/ tree.
_MML_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
_MML_DEFAULT_DOC="${_MML_PLUGIN_ROOT}/skills/worktask/references/stage-codes.md"
_MML_DEFAULT_AGENTS_DIR="${_MML_PLUGIN_ROOT}/agents"

# _mml_split_row <line> -> sets _mml_c1 _mml_c2 _mml_c3, returns 1 if not exactly 3 cells.
# Shared by model_matrix_rows and model_override_rows — one splitter, one trim rule.
_mml_split_row() {
  local line="$1" cells
  cells="${line#|}"
  cells="${cells%|}"
  local -a _mml_cells
  IFS='|' read -r -a _mml_cells <<< "$cells"
  [ "${#_mml_cells[@]}" -eq 3 ] || return 1
  _mml_c1="$(printf '%s' "${_mml_cells[0]}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/`//g')"
  _mml_c2="$(printf '%s' "${_mml_cells[1]}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/`//g')"
  _mml_c3="$(printf '%s' "${_mml_cells[2]}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/`//g')"
  return 0
}

# model_matrix_rows [doc] [agents_dir]
# Prints "agent<TAB>model<TAB>effort" per row under `## Agent Model Matrix`, in document
# order. [doc] defaults to skills/worktask/references/stage-codes.md; a fixture path is how R1-R3
# regression cases exercise the extractor without touching the live file.
model_matrix_rows() {
  local doc="${1:-$_MML_DEFAULT_DOC}"
  local agents_dir="${2:-$_MML_DEFAULT_AGENTS_DIR}"
  local heading='## Agent Model Matrix'
  local header='| Agent | Model | Effort |'

  if [ ! -r "$doc" ]; then
    printf >&2 'model_matrix_rows: cannot read %s\n' "$doc"
    return 3
  fi

  local in_scope=0 saw_header=0 saw_delim=0 nrows=0 line
  local -a seen_agents=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_scope" -eq 0 ]; then
      [ "$line" = "$heading" ] && in_scope=1
      continue
    fi
    case "$line" in
      '#'*)
        # Next heading of ANY level ends the section — rule 1.
        break
        ;;
    esac
    if [ "$saw_header" -eq 0 ]; then
      if [ "$line" = "$header" ]; then
        saw_header=1
        continue
      fi
      case "$line" in
        '|'*)
          # Only a line that looks like a table row must match the header exactly; prose
          # (the "single source of truth" lead-in) is skipped while scanning for it.
          printf >&2 'model_matrix_rows: expected header %s under %s, found: %s\n' \
            "$header" "$heading" "$line"
          return 3
          ;;
        *) continue ;;
      esac
    fi
    if [ "$saw_delim" -eq 0 ]; then
      case "$line" in
        '|'*'-'*)
          saw_delim=1
          continue
          ;;
      esac
    fi
    [ -z "$line" ] && continue
    case "$line" in
      '|'*'|'*) ;;
      *) continue ;; # a note paragraph inside the section — not a table row, rule 1
    esac

    if ! _mml_split_row "$line"; then
      printf >&2 'model_matrix_rows: malformed row (expected 3 cells): %s\n' "$line"
      return 3
    fi
    local agent="$_mml_c1" model="$_mml_c2" effort="$_mml_c3"

    case "$agent" in
      [a-z]*) ;;
      *)
        printf >&2 'model_matrix_rows: invalid agent name %s\n' "$agent"
        return 3
        ;;
    esac
    case "$agent" in
      *[!a-z0-9-]*)
        printf >&2 'model_matrix_rows: invalid agent name %s\n' "$agent"
        return 3
        ;;
    esac
    # The agents/<agent>.md existence check — not a name-shape heuristic — is what stops a
    # stray literal (a model name, an artifact filename) from being captured as an agent.
    if [ ! -f "${agents_dir}/${agent}.md" ]; then
      printf >&2 'model_matrix_rows: row names unknown agent %s (no %s/%s.md)\n' \
        "$agent" "$agents_dir" "$agent"
      return 3
    fi
    case " $MODEL_ENUM " in
      *" $model "*) ;;
      *)
        printf >&2 'model_matrix_rows: invalid model %s for agent %s\n' "$model" "$agent"
        return 3
        ;;
    esac
    if ! effort_rank "$effort" > /dev/null 2>&1; then
      printf >&2 'model_matrix_rows: invalid effort %s for agent %s\n' "$effort" "$agent"
      return 3
    fi
    local seen
    for seen in ${seen_agents[@]+"${seen_agents[@]}"}; do
      if [ "$seen" = "$agent" ]; then
        printf >&2 'model_matrix_rows: duplicate agent %s\n' "$agent"
        return 3
      fi
    done
    seen_agents[${#seen_agents[@]}]="$agent"
    printf '%s\t%s\t%s\n' "$agent" "$model" "$effort"
    nrows=$((nrows + 1))
  done < "$doc"

  if [ "$in_scope" -eq 0 ]; then
    printf >&2 'model_matrix_rows: heading "%s" not found in %s\n' "$heading" "$doc"
    return 3
  fi
  if [ "$nrows" -eq 0 ]; then
    printf >&2 'model_matrix_rows: zero rows under "%s"\n' "$heading"
    return 3
  fi
  return 0
}

# corpflow_md_user_path -> the user-scope CORPFLOW.md path, whether or not it exists.
# Same config-dir idiom as resolve-sibling-root.sh: CLAUDE_CONFIG_DIR, never also $HOME, when
# set — an isolated config must not read the operator's real file. rc 1 with neither set.
corpflow_md_user_path() {
  local config="${CLAUDE_CONFIG_DIR:-}"
  if [ -z "$config" ]; then
    [ -n "${HOME:-}" ] || return 1
    config="$HOME/.claude"
  fi
  printf '%s/CORPFLOW.md\n' "${config%/}"
}

# _cmd_canon_path <path> -> <path> with its directory resolved physically (`pwd -P`), so two
# spellings of one file (relative, trailing slash, symlinked dir) compare equal. Falls back
# to the input when the directory does not exist.
_cmd_canon_path() {
  local dir
  dir=$(cd "$(dirname -- "$1")" 2> /dev/null && pwd -P) || {
    printf '%s\n' "$1"
    return 0
  }
  printf '%s/%s\n' "${dir%/}" "$(basename -- "$1")"
}

# _cmd_owns_heading <file> <heading> -> rc 0 when <file> has <heading> as an exact line AND
# at least one non-blank line before the next `#` line. A heading left bare after its rows
# were deleted (the template's own "delete the rest") expresses no override, so it must not
# shadow the user-scope file; any content, garbled or not, still claims the heading.
_cmd_owns_heading() {
  [ -f "$1" ] || return 1
  awk -v h="$2" '
    !in_s { if ($0 == h) in_s = 1; next }
    /^#/ { in_s = 0; next }
    /[^[:space:]]/ { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$1" 2> /dev/null
}

# corpflow_md_locate <context_dir|project_root> <heading>
# Prints "<path><TAB><project|user>" for the CORPFLOW.md that owns <heading> (an exact line,
# e.g. `## Models`). Precedence is per heading: the project-root file wins whenever it carries
# the heading with any content under it — even when that section is garbled, so a broken
# project section is audited, never silently replaced by the user file. A bare heading with
# nothing under it does not count (_cmd_owns_heading). A project root that IS the config dir
# reports `user`, matching corpflow_md_source's label. A `.context` suffix is stripped; an
# empty first argument checks the user-scope file alone. rc 1 = neither file owns the heading.
corpflow_md_locate() {
  local root="${1:-}" heading="${2:-}" user=""
  [ -n "$heading" ] || return 1
  root="${root%/}"
  case "$root" in
    .context) root="." ;;
    */.context) root="${root%/.context}" ;;
  esac
  user=$(corpflow_md_user_path) || user=""
  if [ -n "$root" ] && _cmd_owns_heading "${root}/CORPFLOW.md" "$heading"; then
    if [ -n "$user" ] \
      && [ "$(_cmd_canon_path "${root}/CORPFLOW.md")" = "$(_cmd_canon_path "$user")" ]; then
      printf '%s\tuser\n' "${root}/CORPFLOW.md"
    else
      printf '%s\tproject\n' "${root}/CORPFLOW.md"
    fi
    return 0
  fi
  [ -n "$user" ] || return 1
  if _cmd_owns_heading "$user" "$heading"; then
    printf '%s\tuser\n' "$user"
    return 0
  fi
  return 1
}

# corpflow_md_source <corpflow_md_path> -> `user-override` for the user-scope file (compared
# after _cmd_canon_path, so an explicit --corpflow spelling of it still counts), else
# `project-override` (any other explicit --corpflow path included). The ledger/audit label.
corpflow_md_source() {
  local user
  user=$(corpflow_md_user_path 2> /dev/null) || user=""
  if [ -n "$1" ] && [ -n "$user" ] \
    && [ "$(_cmd_canon_path "$1")" = "$(_cmd_canon_path "$user")" ]; then
    printf 'user-override\n'
  else
    printf 'project-override\n'
  fi
}

# model_override_rows <corpflow_md_path> [agents_dir]
# Reads a CORPFLOW.md `## Models` section (project-root or user-scope), fail-open per row
# — a bad cell or an unknown agent is reported, never fatal.
# Prints "agent<TAB>model<TAB>effort<TAB>status" per data row, status one of:
#   ok       — agent known, model/effort each valid or "-"/empty (inherits the matrix cell)
#   unknown  — agent not present under agents/<agent>.md
#   invalid  — agent known, but a non-empty model or effort cell is off-enum
# Return codes: 0 = scanned (rows may still be non-ok, that is the caller's to audit);
#   1 = no file, or file present but no `## Models` heading (all-default, not an error);
#   3 = heading present but the header never matched / zero rows parsed
#   (`model_override_unparsed` — the caller's audit action, not this function's).
model_override_rows() {
  local path="$1"
  local agents_dir="${2:-$_MML_DEFAULT_AGENTS_DIR}"
  [ -n "$path" ] && [ -f "$path" ] || return 1

  local heading='## Models'
  local header='| Agent | Model | Effort |'
  local in_scope=0 saw_header=0 saw_delim=0 nrows=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_scope" -eq 0 ]; then
      [ "$line" = "$heading" ] && in_scope=1
      continue
    fi
    case "$line" in '#'*) break ;; esac
    if [ "$saw_header" -eq 0 ]; then
      [ -z "$line" ] && continue
      if [ "$line" = "$header" ]; then
        saw_header=1
        continue
      fi
      # Prose (the "keep only the rows you override" note) precedes the table — keep
      # scanning for the header rather than failing on the first non-header line.
      continue
    fi
    if [ "$saw_delim" -eq 0 ]; then
      case "$line" in '|'*'-'*)
        saw_delim=1
        continue
        ;;
      esac
    fi
    [ -z "$line" ] && continue
    case "$line" in '|'*'|'*) ;; *) continue ;; esac

    _mml_split_row "$line" || continue # malformed row: skip it, fail-open
    local agent="$_mml_c1" model="$_mml_c2" effort="$_mml_c3"
    [ -n "$agent" ] || continue
    nrows=$((nrows + 1))

    # `read -r a b c d <<< "$tsv"` collapses ADJACENT tab delimiters — tab is IFS whitespace
    # even when IFS is set to tab alone — so a truly empty middle field merges with its
    # neighbour and every field after it shifts left. Every emitted cell is therefore
    # coerced to a non-empty placeholder; "-" already means "inherit" downstream.
    [ -n "$model" ] || model="-"
    [ -n "$effort" ] || effort="-"

    if [ ! -f "${agents_dir}/${agent}.md" ]; then
      printf '%s\t-\t-\tunknown\n' "$agent"
      continue
    fi
    local bad=0
    if [ -n "$model" ] && [ "$model" != "-" ]; then
      case " $MODEL_ENUM " in *" $model "*) ;; *) bad=1 ;; esac
    fi
    if [ "$bad" -eq 0 ] && [ -n "$effort" ] && [ "$effort" != "-" ]; then
      effort_rank "$effort" > /dev/null 2>&1 || bad=1
    fi
    if [ "$bad" -eq 1 ]; then
      printf '%s\t%s\t%s\tinvalid\n' "$agent" "$model" "$effort"
      continue
    fi
    printf '%s\t%s\t%s\tok\n' "$agent" "$model" "$effort"
  done < "$path"

  [ "$in_scope" -eq 1 ] || return 1
  [ "$nrows" -gt 0 ] || return 3
  return 0
}

# model_resolve <agent> [state_path] [corpflow_md_path] [doc] [agents_dir]
# The three READ ranks: state.models[<agent>] (already-resolved ledger copy) -> the
# CORPFLOW.md `## Models` the caller located (corpflow_md_locate) -> the built-in matrix.
# Prints "model<TAB>effort<TAB>source" (source: state|project-override|user-override|matrix).
# Ranks 4 (the stamped task) and 5 (an explicit dispatch flag) are materialized output and
# caller precedence, respectively — never read here.
# @exitcode 2 unresolved: agent absent from state, override, and the built-in matrix alike
model_resolve() {
  local agent="$1"
  local state_path="${2:-}"
  local corpflow_path="${3:-}"
  local doc="${4:-$_MML_DEFAULT_DOC}"
  local agents_dir="${5:-$_MML_DEFAULT_AGENTS_DIR}"
  [ -n "$agent" ] || return 2
  # Normalize at the resolver boundary: metadata.agent is canonically "corpflow:<name>"
  # (pl0-procedure.md § Agent mapping), but every rank below keys on the bare basename.
  # A missing strip here is a silent-in-DV10's-case, loud-in-this-one failure mode —
  # fixing it at the one boundary every caller passes through means callers pass the
  # real prefixed string and get correct resolution, rather than each re-deriving the
  # strip (and risking skipping it) themselves.
  agent="${agent##*:}"

  if [ -n "$state_path" ] && [ -f "$state_path" ] && command -v jq > /dev/null 2>&1; then
    local srow
    srow=$(jq -r --arg a "$agent" \
      '(.models[$a] // empty) | select(.model and .effort) | [.model, .effort] | @tsv' \
      "$state_path" 2> /dev/null)
    if [ -n "$srow" ]; then
      printf '%s\tstate\n' "$srow"
      return 0
    fi
  fi

  local mrow mmodel meffort
  mrow=$(model_matrix_rows "$doc" "$agents_dir" 2> /dev/null \
    | awk -F'\t' -v a="$agent" '$1==a{print $2"\t"$3}')
  mmodel="${mrow%%$'\t'*}"
  meffort="${mrow##*$'\t'}"
  [ "$mrow" = "$mmodel" ] && meffort="" # no tab found: mrow was empty

  if [ -n "$corpflow_path" ] && [ -f "$corpflow_path" ]; then
    local orow ostatus omodel oeffort
    # First match wins: model_override_rows is fail-open and emits a duplicated agent twice,
    # and a two-line orow would garble the pair below (multi-line `cut` output). Filtered
    # without `exit` — an early awk exit SIGPIPEs the producer, which a `pipefail` caller
    # (model-matrix.sh) turns into a fatal 141. `|| true` for the same reason: rc 1/3 from a
    # heading-less or garbled section is a matrix fallback, not an errexit.
    orow=$(model_override_rows "$corpflow_path" "$agents_dir" 2> /dev/null \
      | awk -F'\t' -v a="$agent" '$1==a && !seen {print; seen=1}') || true
    if [ -n "$orow" ]; then
      ostatus="${orow##*$'\t'}"
      if [ "$ostatus" = "ok" ]; then
        omodel=$(printf '%s' "$orow" | cut -f2)
        oeffort=$(printf '%s' "$orow" | cut -f3)
        [ -n "$omodel" ] && [ "$omodel" != "-" ] || omodel="$mmodel"
        [ -n "$oeffort" ] && [ "$oeffort" != "-" ] || oeffort="$meffort"
        if [ -n "$omodel" ] && [ -n "$oeffort" ]; then
          printf '%s\t%s\t%s\n' "$omodel" "$oeffort" "$(corpflow_md_source "$corpflow_path")"
          return 0
        fi
      fi
    fi
  fi

  if [ -n "$mmodel" ] && [ -n "$meffort" ]; then
    printf '%s\t%s\tmatrix\n' "$mmodel" "$meffort"
    return 0
  fi
  return 2
}
