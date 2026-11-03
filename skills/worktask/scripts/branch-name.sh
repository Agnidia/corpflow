#!/usr/bin/env bash
# @description branch-name.sh — the PL-stage branch-naming entry point. Renames the
#   current branch onto `<type>/[<ticket>-]<slug>` (see git-conventions.md § Branch
#   Naming), once, at the very start of the planning stage, before any commit exists.
#
#   Sources branch-lib.sh from its own directory for the guard ladder, the type
#   vocabulary, goal resolution, and the audit/scope helpers. The ticket segment is
#   derived from the goal text only — no issue lookup — and this script never writes
#   state.json: it prints `target_branch=<name>` then `branch=<name>` and the
#   orchestrator stamps `facts.branch` through the normal state-patch path.
#
#   Two names, two decisions. `branch=` is the LOCAL branch as it stands after this
#   run (the final stdout line — every consumer parses that one). `target_branch=` is
#   the name the REMOTE branch should carry, derived on every arm that can derive one
#   even when the local rename did not happen: an upstream or an existing target blocks
#   the local rename without making the PR head any less wrong. The orchestrator stamps
#   `facts.branch` from `target_branch=` when `branch=` is empty or non-conventional
#   (`skills/worktask/references/workflow.md § Step 3c`).
#
#   Inside a linked worktree the naming step RENAMES the local branch, like any other
#   checkout, so `branch=` and `target_branch=` agree. The host's branch↔workspace mapping
#   is updated by that rename — deliberately: a host-assigned placeholder is not a name
#   worth preserving, and a host may rename the branch again mid-run without telling the
#   pipeline. Set `BRANCH_NAME_WORKTREE_RENAME=0` to restore the previous defer-to-host
#   behaviour, in which the local name is kept and only `target_branch=` is derived.
#
#   Every rename-mode outcome exits 0, including an unreachable library: a naming
#   problem must never stop a worktask from planning. `--check`/`--print-types`/
#   `--print-target` are query modes with no git mutation and no audit row.
#
# @arg --goal <text>      Explicit goal text (Q1). Ranked fallbacks:
#                          argument > state.json .facts.goal > .worktask_id.
# @arg --state <path>     state.json path (default: .context/state.json).
# @arg --context <dir>    .context dir (default: .context).
# @arg --check <name>     Query: is <name> conventional? No git, no state, no audit row.
# @arg --print-types      Query: the type vocabulary, one token per line.
# @arg --print-target     Query: the target derived from --goal, bare, on stdout. Composes
#                         with --goal. Runs NO git command, walks no guard ladder, writes
#                         no state and no audit row — unlike BRANCH_NAME_PRINT, which is
#                         evaluated after the ladder and so answers "what would the rename
#                         do", not "what does this text derive to".
# @arg -h | --help        Show this header.
#
# @env BRANCH_NAME_PRINT  1 => dry run: print the bare target, rename nothing, no
#                         audit row, no `branch=`/`target_branch=` lines. A truncated
#                         slug is reported on stderr only. Evaluated AFTER the guard
#                         ladder so a dry run can never bypass a guard.
# @env BRANCH_NAME_WORKTREE_RENAME
#                         Literal `0` => inside a linked worktree, keep the host's local
#                         name and derive `target_branch=` only (the pre-R6 behaviour).
#                         Unset or any other value => rename, like any other checkout.
#                         Subtractive only: it can turn a would-be rename into a no-op and
#                         can never authorize one a higher guard refused.
# @env MILESTONE_MODE     1 => batch routing; self-disables.
# @env INCIDENT_MODE      1 => incident routing; self-disables.
# @env WORKSPACE_ROOT     Read transitively by fn_batch_scope / resolve_base_ref.
# @env FN_BASE_REF        Highest-priority integration-branch override (unrenamed
#                         despite the prefix — see skills/worktask/references/contracts/ledger-root.md § metadata.base_ref).
#
# @exitcode 0   Every rename-mode outcome (ok, noop, failed, skipped, unreachable
#               library). `--print-target`: a conventional target was printed.
# @exitcode 1   `--check`: name is not conventional. `--print-target`: unresolvable
#               (empty goal, empty slug, or a non-conventional candidate) — no stdout.
# @exitcode 2   Usage error, `--check` on an internal regex fault, or a query mode
#               with branch-lib.sh unreachable.
#
# Minimum shell: bash 3.2+ (macOS default).

set -euo pipefail
IFS=$'\n\t'

STATE_PATH=".context/state.json"
CONTEXT_DIR=".context"
GOAL_ARG=""
MODE="rename"
CHECK_NAME=""
# Top level, not inside cmd_rename: arms that return before derivation still reach
# emit_names, which reads it under `set -u`.
SLUG_TRUNCATED=0
IN_WORKTREE=0

usage() {
  awk 'NR>1{ if (!/^#/) exit; sub(/^# ?/,""); print }' "$0"
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --goal)
      shift
      [ $# -gt 0 ] || {
        printf >&2 'branch-name: --goal requires a value\n'
        exit 2
      }
      GOAL_ARG="$1"
      shift
      ;;
    --state)
      shift
      [ $# -gt 0 ] || {
        printf >&2 'branch-name: --state requires a value\n'
        exit 2
      }
      STATE_PATH="$1"
      shift
      ;;
    --context)
      shift
      [ $# -gt 0 ] || {
        printf >&2 'branch-name: --context requires a value\n'
        exit 2
      }
      CONTEXT_DIR="$1"
      shift
      ;;
    --check)
      shift
      [ $# -gt 0 ] || {
        printf >&2 'branch-name: --check requires a value\n'
        exit 2
      }
      MODE="check"
      CHECK_NAME="$1"
      shift
      ;;
    --print-types)
      MODE="print-types"
      shift
      ;;
    --print-target)
      MODE="print-target"
      shift
      ;;
    -h | --help) usage ;;
    *)
      printf >&2 'branch-name: unknown argument: %s\n' "$1"
      usage
      ;;
  esac
done

# Physical directory of this script. CDPATH= disables a benign-but-common
# CDPATH setting that otherwise makes `cd` echo an extra line into this very
# capture, corrupting the path silently; `pwd -P` plus the readlink loop follow
# a symlinked script to its real directory so sibling-library resolution cannot
# be redirected onto an attacker-planted file next to the symlink.
_resolve_script_dir() {
  local src="${BASH_SOURCE[0]:-$0}" dir
  # Note: while loop has no iteration cap, but is unreachable in practice.
  # Bash cannot open a cyclic symlink to execute or source a script
  # ('Too many levels of symbolic links'), so BASH_SOURCE[0] can never be
  # cyclic at the moment this function runs. Only a TOCTOU race by someone
  # with write access to the script directory (who has easier options).
  while [ -h "$src" ]; do
    dir=$(CDPATH= cd -- "$(dirname -- "$src")" && pwd -P)
    src=$(readlink "$src")
    case "$src" in
      /*) ;;
      *) src="$dir/$src" ;;
    esac
  done
  CDPATH= cd -- "$(dirname -- "$src")" && pwd -P
}
SCRIPT_DIR="$(_resolve_script_dir 2> /dev/null)" || SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]:-$0}")"
LIB_PATH="${SCRIPT_DIR}/branch-lib.sh"

# `[ -r ]` first, not a bare `.`: sourcing a missing file with the `.` builtin is a
# special-builtin error that exits a `set -e` shell immediately, bypassing an
# `if ! . …; then` guard entirely (verified on bash 3.2 and 5.x).
if [ -r "$LIB_PATH" ]; then
  # shellcheck disable=SC1090
  . "$LIB_PATH"
else
  # The library's only failure mode is absence: a same-directory, same-commit
  # sibling missing means the plugin install itself is broken. A query mode has
  # nothing to answer without the predicate/list it needs; rename mode degrades
  # loud-but-non-blocking, matching the "never blocks" contract.
  if [ "$MODE" != "rename" ]; then
    printf >&2 'branch-name: branch-lib.sh unreachable at %s — cannot answer\n' "$LIB_PATH"
    exit 2
  fi
  printf >&2 'branch-name: branch-lib.sh unreachable at %s — skipping rename\n' "$LIB_PATH"
  cur=$(git rev-parse --abbrev-ref HEAD 2> /dev/null || printf '')
  # branch_is_conventional is unavailable here (that is the library that failed
  # to source) — fall back to a minimal safe-charset check so an untrusted
  # current branch name is never passed through to a later shell-interpolation
  # site. Never the literal "HEAD" (detached) either.
  if [ "$cur" = "HEAD" ] || ! printf '%s' "$cur" | grep -Eq '^[A-Za-z0-9._/-]+$'; then
    cur=""
  fi
  mkdir -p "${CONTEXT_DIR}/logs" 2> /dev/null || true
  # Refuse a symlinked audit.jsonl: following it makes this append a write primitive
  # against an arbitrary target. A lost row never blocks the caller.
  if command -v jq > /dev/null 2>&1 \
    && [ ! -L "${CONTEXT_DIR}/logs/audit.jsonl" ]; then
    # Self-contained audit row: the library that would supply audit_fn is exactly
    # what is missing, so this one path cannot delegate to it.
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    wid=$(jq -r '.worktask_id // "unknown"' "$STATE_PATH" 2> /dev/null || printf 'unknown')
    ri=$(jq -r '.run_index // 0' "$STATE_PATH" 2> /dev/null || printf '0')
    # The branch-lib.sh branch_audit_actor ladder, which this path cannot source.
    owner=""
    case "${CLAUDE_TASK_METADATA_STAGE:-}" in
      PL) owner=product-manager ;;
      AR) owner=software-architector ;;
      TL) owner=team-lead ;;
      DV) owner=developer ;;
      DR) owner=technical-lead ;;
      SR) owner=security-reviewer ;;
      QA) owner=qa-engineer ;;
      DC) owner=technical-writer ;;
      RE) owner=release-engineer ;;
      FN) owner=project-manager ;;
      ST) owner=stakeholder ;;
      IR) owner=incident-responder ;;
    esac
    actor="${CORPFLOW_AUDIT_ACTOR:-}"
    actor_set=" orchestrator product-manager software-architector team-lead developer"
    actor_set="$actor_set technical-lead security-reviewer qa-engineer technical-writer"
    actor_set="$actor_set release-engineer project-manager stakeholder incident-responder "
    case "$actor" in '' | *[[:space:]]*) actor="" ;; esac
    case "$actor_set" in *" $actor "*) : ;; *) actor="" ;; esac
    if [ -n "$actor" ] && [ -n "$owner" ] && [ "$actor" != "$owner" ] \
      && [ "$actor" != "orchestrator" ]; then
      actor=""
    fi
    [ -n "$actor" ] || actor="${owner:-orchestrator}"
    jq -cn --arg ts "$ts" --arg wid "$wid" --arg ri "$ri" --arg actor "$actor" \
      '{ts:$ts, actor:$actor, action:"branch_renamed", subject:("PL" + $ri),
        result:"noop", task_id:"PL0",
        metadata:{reason:"branch_lib_unreachable", origin_stage:"PL",
                  dedupe_key:($wid + ":" + $ri + ":branch_renamed")}}' \
      >> "${CONTEXT_DIR}/logs/audit.jsonl" 2> /dev/null || true
  fi
  printf 'branch-name: library unreachable — skipped\n'
  # No `target_branch` either: deriving one needs derive_type/derive_slug/
  # target_branch_name, which live in the library that just failed to source.
  printf 'target_branch=%s\n' ""
  printf 'branch=%s\n' "$cur"
  exit 0
fi

cmd_check() {
  branch_is_conventional "$CHECK_NAME"
  exit $?
}

cmd_print_types() {
  local line
  local IFS=$'\n'
  for line in $BRANCH_TYPES; do
    [ -n "$line" ] && printf '%s\n' "$line"
  done
  exit 0
}

# Derivation only — the answer to "what does this text derive to", which the guard
# ladder cannot give: on a checkout whose branch is already conventional the ladder
# returns on the no-op arm and prints no target at all.
cmd_print_target() {
  local goal ticket target
  goal=$(resolve_goal "$GOAL_ARG")
  ticket=$(derive_ticket "$goal")
  target=$(derive_target)
  if [ -z "$target" ] || ! branch_is_conventional "$target"; then
    exit 1
  fi
  if slug_is_truncated "$goal" "$ticket"; then
    printf >&2 'branch-name: slug_truncated=1\n'
  fi
  printf '%s\n' "$target"
  exit 0
}

# Emits `branch=<name>` only when <name> passes branch_is_conventional; any
# other value (including the current, un-derived branch name on a no-op arm)
# prints `branch=` empty instead. This is the fix for the git-legal-but-shell-
# hostile branch name reaching FN's `git push -u origin HEAD:refs/heads/<name>`
# command text (e.g. `fix/a$(id>/tmp/x)`) — git accepts characters bash does
# not, and no downstream consumer re-validates before interpolating. `target`
# (the rename-success arm) is conventional by construction and always passes;
# `cur` (every no-op/failure arm) is untrusted external input and often will not.
emit_branch() {
  local name="${1:-}"
  if [ -n "$name" ] && branch_is_conventional "$name"; then
    printf 'branch=%s\n' "$name"
  else
    printf 'branch=%s\n' ""
  fi
}

# Emits `target_branch=<name>` — the name the REMOTE branch should carry — through
# the same conventionality gate as emit_branch, for the same reason: both lines end
# up as shell command text in FN's push refspec, and a derived-but-unvalidated value
# would reopen exactly the hole emit_branch exists to close.
#
# Emitted BEFORE `branch=` on every rename-mode arm, never after: `branch=<name>` is
# specified as the script's FINAL stdout line in four places (skills/worktask/references/workflow.md
# § Step 3c, skills/worktask/references/orchestration.md, handoff-protocol.md, skills/worktask/references/pl0-procedure.md)
# and consumers tail for it. A new line appended at the end would silently retarget
# every one of those parses.
emit_target() {
  local name="${1:-}"
  if [ -n "$name" ] && branch_is_conventional "$name"; then
    printf 'target_branch=%s\n' "$name"
  else
    printf 'target_branch=%s\n' ""
  fi
}

# The pair, in contract order. Empty `$1` is the honest value for an arm that has no
# remote target to propose (self-disabled routing, no repo, integration branch) — as
# distinct from an arm that has one but could not apply it locally.
#
# `slug_truncated=1` precedes the pair, conditionally: appending it after `branch=` would
# break the FINAL-line contract, and placing it between the pair would break their
# adjacency. Conditional emission leaves `target_branch=` at stdout index 1 for every
# non-truncating goal, which existing consumers and assertions rely on.
# The signal is gated on the SAME condition as emit_target, not merely on a non-empty
# argument: a name that fails the predicate prints `target_branch=` empty, and a truncation
# notice above an empty target would describe a name the caller never receives.
emit_names() {
  if [ "${SLUG_TRUNCATED:-0}" = "1" ] && [ -n "${1:-}" ] && branch_is_conventional "${1:-}"; then
    printf 'slug_truncated=1\n'
  fi
  emit_target "${1:-}"
  emit_branch "${2:-}"
}

# Derives `<type>/[<ticket>-]<slug>` from the goal. Pure: no git, no state write, and
# no dependence on whether a rename is possible — which is the point. Split out of the
# rename path so every no-op arm below can still report the name the remote should
# carry. Empty output = unresolvable (no goal text, or a goal that yields no slug).
derive_target() {
  local goal type ticket slug
  goal=$(resolve_goal "$GOAL_ARG")
  type=$(derive_type "$goal")
  ticket=$(derive_ticket "$goal")
  slug=$(derive_slug "$goal" "$ticket")
  # A goal that is nothing but its issue key leaves no slug body. The key is then the
  # only name available, so it becomes the slug — not a ticket segment with nothing
  # after it, and not the target_unresolvable no-op.
  if [ -z "$slug" ] && [ -n "$ticket" ]; then
    slug="$ticket"
    ticket=""
  fi
  target_branch_name "$type" "$slug" "$ticket" 2> /dev/null || printf ''
}

# True inside a linked git worktree — the shape every worktree-based host (Conductor,
# /megatask, a hand-run `git worktree add`) provisions. A linked worktree's `--git-dir`
# points at `<common>/worktrees/<name>` while `--git-common-dir` is the shared
# `<common>`; in a plain checkout the two are identical. Nothing else in the ladder can
# see this: a host leaves no `workspace.json` in `$PWD`, so fn_batch_scope's six
# signals all miss it.
#
# A detector only. What it gates is the DISCLOSURE and the opt-out, not whether the rename
# happens: inside a linked worktree the branch is renamed like any other checkout, so
# `branch=` and `target_branch=` agree. The host's mapping is updated by that rename,
# deliberately — a host-assigned placeholder is not a name worth preserving, and a host may
# rename the branch again mid-run without telling the pipeline.
# A git too old for `--git-common-dir` yields empty and reads as "not a worktree" —
# the pre-existing rename behaviour, never a false positive.
#
# Both values are resolved to physical paths before comparing, and that is load-bearing
# rather than defensive: run from a SUBDIRECTORY of a plain repo, git answers `--git-dir`
# absolutely (`/repo/.git`) and `--git-common-dir` relatively (`../../.git`) — a raw
# string compare calls every nested cwd a worktree and silently stops renaming anywhere
# but the repo root.
is_host_workspace() {
  local d c
  d=$(git rev-parse --git-dir 2> /dev/null) || return 1
  c=$(git rev-parse --git-common-dir 2> /dev/null) || return 1
  [ -n "$d" ] && [ -n "$c" ] || return 1
  d=$(CDPATH= cd -- "$d" 2> /dev/null && pwd -P) || return 1
  c=$(CDPATH= cd -- "$c" 2> /dev/null && pwd -P) || return 1
  [ "$d" != "$c" ]
}

# The once-only guard, keyed on the LEDGER rather than on the current branch name. A
# name-based check ("is `cur` already conventional?") is only valid while nothing else
# renames the branch — and a host demonstrably does, mid-run, without notice. After such a
# rename the branch reads non-conventional again and a name-based check would authorize a
# SECOND rename, which the once-only rule forbids. Any `branch_renamed` row means the one
# rename-mode run already happened, whatever its outcome; a bumped run_index keys a
# different row and so still gets its own naming decision.
#
# Without jq the scan cannot run and this returns false — safe rather than a hole, because
# the jq_unavailable arm below refuses to mutate anyway.
# Set together with FIRST_RUN_TS by already_named. The recorded target is what the FIRST
# run decided the remote should carry; re-emitting it is the difference between "we already
# named this" and handing the caller two empty carriers, which reads as "no name was ever
# derived" and leaves the PR head wrong.
FIRST_RUN_TS=""
FIRST_RUN_TARGET=""
already_named() {
  local log="${CONTEXT_DIR}/logs/audit.jsonl" wid ri
  command -v jq > /dev/null 2>&1 || return 1
  [ -f "$log" ] || return 1
  wid=$(jq -r '.worktask_id // "unknown"' "$STATE_PATH" 2> /dev/null || printf 'unknown')
  ri=$(jq -r '.run_index // 0' "$STATE_PATH" 2> /dev/null || printf '0')
  # `fromjson?` alone only survives an UNPARSABLE line. A well-formed non-object line
  # (`123`, `[1,2]`) parses fine and then dies on `.metadata` — "Cannot index number with
  # string" — aborting the scan, which for a once-only guard means failing OPEN and
  # authorizing a second rename. `objects` discards those before any indexing.
  # Slurping avoids a `head -n1` that would SIGPIPE jq under the caller's pipefail.
  FIRST_RUN_TS=$(jq -rs -R --arg dk "${wid}:${ri}:branch_renamed" \
    '[ split("\n")[] | fromjson? | objects
       | select(.metadata.dedupe_key == $dk) | .ts ] | (.[0] // "")' \
    "$log" 2> /dev/null) || FIRST_RUN_TS=""
  # `to` before `target`: a row that actually renamed records the achieved name, which
  # outranks a no-op arm's proposal. Scanned across ALL matching rows rather than the
  # first, because the first row may be a `skipped` arm that carries neither key.
  FIRST_RUN_TARGET=$(jq -rs -R --arg dk "${wid}:${ri}:branch_renamed" \
    '[ split("\n")[] | fromjson? | objects
       | select(.metadata.dedupe_key == $dk)
       | (.metadata.to // .metadata.target // "") | select(. != "") ] | (.[0] // "")' \
    "$log" 2> /dev/null) || FIRST_RUN_TARGET=""
  [ -n "$FIRST_RUN_TS" ]
}

# Guard ladder — first hit wins, and every arm exits 0. This step is a courtesy
# rename, never a gate: no naming problem is worth failing a planning stage over.
cmd_rename() {
  local apply=1
  [ "${BRANCH_NAME_PRINT:-0}" = "1" ] && apply=0
  # Set once, from `apply`, so every arm below inherits the suppression — the header has
  # documented "no audit row" for BRANCH_NAME_PRINT since this flag existed, while the
  # ladder audited unconditionally. audit_fn holds the guard; this is the only site that
  # decides a run is a preview.
  # shellcheck disable=SC2034  # read by branch-lib.sh audit_fn through dynamic scope
  AUDIT_DRY_RUN=$((1 - apply))

  # Identity for audit_fn's call-time read — this is the PL-stage row, distinct
  # from the FN-stage defaults audit_fn falls back to when unset.
  # shellcheck disable=SC2034  # the three below are read by branch-lib.sh audit_fn
  AUDIT_ACTOR=$(branch_audit_actor)
  local ri
  ri=$(jq -r '.run_index // 0' "$STATE_PATH" 2> /dev/null || printf '0')
  # shellcheck disable=SC2034
  AUDIT_SUBJECT="PL${ri}"
  # shellcheck disable=SC2034
  AUDIT_STAGE="PL"

  # No target on this arm: batch/incident routing owns branch naming end to end, and
  # a target here would invite the orchestrator to stamp a name the batch never planned.
  if fn_batch_scope; then
    printf 'branch-name: skipped (%s)\n' "$SCOPE_REASON"
    audit_fn branch_renamed skipped "$(meta_json reason "$SCOPE_REASON")"
    emit_names "" "$(git rev-parse --abbrev-ref HEAD 2> /dev/null || printf '')"
    return 0
  fi

  git rev-parse --git-dir > /dev/null 2>&1 || {
    printf 'branch-name: not a git repo — skipped\n'
    printf 'target_branch=%s\n' ""
    printf 'branch=%s\n' ""
    return 0
  }

  local cur
  cur=$(git rev-parse --abbrev-ref HEAD 2> /dev/null || printf '')
  if [ -z "$cur" ] || [ "$cur" = "HEAD" ]; then
    # Never stamp the literal token "HEAD" as a branch name — FN interpolates
    # this value into a `refs/heads/<name>` push refspec, and "HEAD" is not a
    # branch. Empty is the honest, always-safe value for "no branch to name".
    printf 'branch-name: detached HEAD — skipped\n'
    printf 'target_branch=%s\n' ""
    printf 'branch=%s\n' ""
    return 0
  fi

  # ONCE-ONLY, and it must sit above already_conventional: after a third-party rename the
  # branch is non-conventional again, so that arm no longer fires and would let a second
  # rename through. No target — the naming decision is already on the ledger, and proposing
  # a freshly derived one here would invite a re-stamp of facts.branch from a name derived
  # at the wrong time. `branch`+`first_run_ts` together make a third-party rename legible in
  # the log at the moment a second run is refused.
  if already_named; then
    printf 'branch-name: already named this run (%s) — no-op\n' "$cur"
    audit_fn branch_renamed noop \
      "$(meta_json reason already_named branch "$cur" \
        first_run_ts "$FIRST_RUN_TS" target "$FIRST_RUN_TARGET")"
    # The RECORDED target, never a freshly derived one: re-deriving here would re-stamp
    # facts.branch from a name computed at the wrong time, which is exactly what this arm
    # exists to prevent. Empty when the first run recorded none — honest, and no worse
    # than the two empty carriers this arm used to emit unconditionally.
    emit_names "$FIRST_RUN_TARGET" "$cur"
    return 0
  fi

  # A conventional name is a deliberate name — never churn one. A CHURN guard, not the
  # once-only guard (that is already_named, above): this arm answers "is this name
  # deliberate?", which is a different question from "have we already renamed?".
  # No target: `branch=` already carries a conventional name, and proposing a second
  # one would hand the PR a head that disagrees with the branch it was planned on.
  if branch_is_conventional "$cur"; then
    printf 'branch-name: already conventional (%s) — no-op\n' "$cur"
    audit_fn branch_renamed noop "$(meta_json reason already_conventional branch "$cur")"
    emit_names "" "$cur"
    return 0
  fi

  # Derived HERE, above the no-op arms rather than below them: from this point down
  # `cur` is known non-conventional, so every remaining arm has a wrong PR head to fix
  # whether or not it can rename anything locally. Deriving inside the rename arm alone
  # is what let the upstream_tracked / target_exists / jq_unavailable arms compute the
  # right answer and drop it.
  local target
  target=$(derive_target)

  # Set in THIS shell, never inside derive_target — that runs in a command substitution
  # and its assignments die with the subshell. Dynamic scope carries it to emit_names.
  local goal_text ticket_text
  goal_text=$(resolve_goal "$GOAL_ARG")
  ticket_text=$(derive_ticket "$goal_text")
  if slug_is_truncated "$goal_text" "$ticket_text"; then
    SLUG_TRUNCATED=1
  fi

  # Renaming a branch that already has an upstream orphans the remote ref.
  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' > /dev/null 2>&1; then
    printf 'branch-name: upstream already tracked — no-op\n'
    audit_fn branch_renamed noop "$(meta_json reason upstream_tracked branch "$cur" target "$target")"
    emit_names "$target" "$cur"
    return 0
  fi

  local base
  base=$(resolve_base_ref)
  if [ -n "$base" ] && [ "$cur" = "${base#origin/}" ]; then
    # No target: the integration branch must never become a PR head under any name.
    printf 'branch-name: on the integration branch (%s) — refusing to rename\n' "$cur"
    audit_fn branch_renamed noop "$(meta_json reason on_integration_branch branch "$cur")"
    emit_names "" "$cur"
    return 0
  fi

  # Without jq, fn_batch_scope cannot see the ledger/workspace batch signals, so
  # scope is unknowable and renaming would be unsafe — refuse rather than guess.
  # `target` may still be non-empty (an explicit --goal needs no jq): naming the PR
  # head is not the mutation this arm refuses to make.
  if ! command -v jq > /dev/null 2>&1; then
    printf 'branch-name: target unresolvable — no-op\n'
    audit_fn branch_renamed noop "$(meta_json reason jq_unavailable)"
    emit_names "$target" "$cur"
    return 0
  fi

  if [ -z "$target" ]; then
    printf 'branch-name: target unresolvable — no-op\n'
    audit_fn branch_renamed noop "$(meta_json reason target_unresolvable)"
    emit_names "" "$cur"
    return 0
  fi

  # No `cur == target` arm here: `target` is conventional by construction
  # (type ∈ BRANCH_TYPES, slug matches the same charset the predicate accepts),
  # so equality would imply `cur` was already conventional — already handled
  # above. Keeping a dead arm invites a reason (`already_target`) no path emits.

  if [ "$apply" -eq 0 ]; then
    # stdout stays the bare target — the dry run's whole contract is that it is
    # directly substitutable — so the signal goes to stderr.
    if [ "$SLUG_TRUNCATED" = "1" ]; then
      printf >&2 'branch-name: slug_truncated=1\n'
    fi
    printf '%s\n' "$target"
    return 0
  fi

  # Linked worktree: rename like any other checkout, and fall through to the SAME
  # target_exists → `git branch -m` tail. The fall-through passes through target_exists by
  # design — a linked worktree shares `refs/heads` with the main checkout, so a collision
  # here is MORE likely than in a plain checkout, not less.
  #
  # BRANCH_NAME_WORKTREE_RENAME is subtractive only: literal `0` turns a would-be rename
  # into the previous defer-to-host no-op, and can never authorize one a higher guard
  # already refused.
  if is_host_workspace; then
    if [ "${BRANCH_NAME_WORKTREE_RENAME:-1}" = "0" ]; then
      printf 'branch-name: host workspace (linked worktree) — keeping %s, targeting %s\n' "$cur" "$target"
      audit_fn branch_renamed skipped \
        "$(meta_json reason host_workspace_worktree branch "$cur" target "$target")"
      emit_names "$target" "$cur"
      return 0
    fi
    IN_WORKTREE=1
  fi

  if git show-ref --verify --quiet "refs/heads/$target"; then
    printf 'branch-name: %s already exists — no-op\n' "$target"
    audit_fn branch_renamed noop "$(meta_json reason target_exists target "$target")"
    emit_names "$target" "$cur"
    return 0
  fi

  if git branch -m "$target" 2> /dev/null; then
    # BINDING (AD-14): inside a worktree the success line names the re-sync consequence and
    # the opt-out, at the moment the rename happens rather than after it is discovered.
    if [ "$IN_WORKTREE" = "1" ]; then
      printf 'branch-name: renamed inside a linked worktree (%s -> %s) — your host'"'"'s workspace↔branch mapping may need to re-sync; set BRANCH_NAME_WORKTREE_RENAME=0 to keep the host'"'"'s name\n' \
        "$cur" "$target"
      audit_fn branch_renamed ok "$(meta_json from "$cur" to "$target" in_worktree true)"
    else
      printf 'branch-name: %s -> %s\n' "$cur" "$target"
      audit_fn branch_renamed ok "$(meta_json from "$cur" to "$target")"
    fi
    emit_names "$target" "$target"
  else
    printf >&2 'branch-name: rename failed (%s -> %s) — continuing\n' "$cur" "$target"
    audit_fn branch_renamed failed "$(meta_json from "$cur" to "$target")"
    emit_names "$target" "$cur"
  fi
  return 0
}

case "$MODE" in
  check) cmd_check ;;
  print-types) cmd_print_types ;;
  print-target) cmd_print_target ;;
  rename) cmd_rename ;;
esac
