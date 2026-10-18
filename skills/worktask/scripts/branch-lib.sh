#!/usr/bin/env bash
# @description branch-lib.sh — sourceable library shared by branch-name.sh (PL-stage
#   rename entry point), fn-preflight.sh (surviving FN validator commands),
#   stream-diff.sh and fn-stream-merge.sh.
#
#   Dependency-free by construction: sources nothing, sets no shell options, does no
#   jq/git probing at load time, and has no side effects at load beyond idempotent
#   variable init. Its only failure mode is absence, which callers detect and report
#   loudly — see each caller's own guard.
#
#   Symbols: BRANCH_TYPES, branch_type_regex, branch_is_conventional, resolve_goal,
#   derive_type, derive_ticket, slug_body, slug_budget, slug_is_truncated, derive_slug,
#   target_branch_name, meta_json, audit_fn, fn_batch_scope, fork_base, _fork_base_uncached,
#   _base_ref_ranked, resolve_base_ref, base_ref_source, resolve_git_ref, BRANCH_AUDIT_ACTORS,
#   branch_audit_actor.
#
# @env BASE_REF_TASK_ID  Ledger task id whose row the ladder reads at rank 2a (e.g. DV1).
#                        Scope it to one call (`BASE_REF_TASK_ID=DV1 resolve_base_ref`): an
#                        exported value steers every later resolver call in that shell.
#
# Minimum shell: bash 3.2+ (macOS default).

# Anti-execution guard — MUST be the first statement. Fires only when this file is
# run directly ($0 == BASH_SOURCE[0]); a sourcing caller always has a different $0.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  printf >&2 'branch-lib.sh: this is a library — source it, do not execute it directly\n'
  exit 2
fi

# Idempotent carve-out: a `set -u` caller reading this before fn_batch_scope runs
# must not explode on an unset variable.
: "${SCOPE_REASON:=}"

# ---------- Branch type vocabulary — the only regex site in the repo ----------
# Newline-delimited, NOT an array and NOT `readonly`: a second `readonly` assignment
# is rc 1 and kills a `set -e` caller (this file's own bats source it twice), and a
# space-delimited list yields one token under a caller's `IFS=$'\n\t'`. Accept list
# (13) is deliberately wider than what derive_type ever emits (12): `style` is
# accepted but never generated; `feat` is emitted only for a leading "build" verb
# and otherwise accepted so an existing short-form branch is never churned.
# `fix` is intentionally absent — removed cleanly, not kept as a
# compatibility token — so a pre-existing `fix/<slug>` branch reads as non-conventional
# and gets renamed onto the derived `bugfix/`/`hotfix/` target. Canonical prose:
# skills/shared/git-conventions.md § Branch Naming.
BRANCH_TYPES='feat
feature
bugfix
hotfix
refactor
perf
docs
chore
test
ci
build
style
revert'

# Builds the `type1|type2|...` alternation from BRANCH_TYPES, skipping any blank
# entry (a blank entry would produce `^(feat||fix)/…`, which BSD grep rejects with
# rc 2 — indistinguishable from "no match" inside a bare `if grep -Eq`).
branch_type_regex() {
  local line first=1 regex=""
  local IFS=$'\n'
  for line in $BRANCH_TYPES; do
    [ -n "$line" ] || continue
    if [ "$first" -eq 1 ]; then
      regex="$line"
      first=0
    else
      regex="$regex|$line"
    fi
  done
  printf '%s' "$regex"
}

# Predicate: is <name> a conventional `<type>/[<ticket>-]<slug>` branch? The sole
# matching site — nobody else greps this pattern, and no caller may judge
# conventionality by eye. The tail is charset-only on purpose: it accepts the
# ticketed and ticket-less shapes with one pattern, so adding the optional ticket
# segment cannot retroactively make an existing branch non-conventional and churn it.
# 0 = yes, 1 = no (documented exemption: a predicate that cannot say "no" is
# useless), 2 = internal regex fault (empty vocabulary).
branch_is_conventional() {
  local name="${1:-}" regex rc=0
  regex=$(branch_type_regex)
  if [ -z "$regex" ]; then
    printf >&2 'branch-lib: empty type vocabulary — cannot evaluate\n'
    return 2
  fi
  printf '%s' "$name" | grep -Eq "^(${regex})/[a-z0-9._-]+\$" && rc=0 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# ---------- Goal resolution ----------
# Ranked, first-non-empty-wins: explicit argument, then the ledger goal, then the
# worktask id. Shell `-z` semantics deliberately rank PAST an empty string (unlike
# jq's `//`, which treats "" as truthy and stops there) — the ranked fallbacks are
# the point of this function, not a corner case to special-case away.
resolve_goal() {
  local g="${1:-}"
  if [ -z "$g" ] && command -v jq > /dev/null 2>&1; then
    g=$(jq -r '.facts.goal // ""' "${STATE_PATH:-.context/state.json}" 2> /dev/null || printf '')
    [ "$g" = "null" ] && g=""
  fi
  if [ -z "$g" ] && command -v jq > /dev/null 2>&1; then
    g=$(jq -r '.worktask_id // ""' "${STATE_PATH:-.context/state.json}" 2> /dev/null || printf '')
    [ "$g" = "null" ] && g=""
  fi
  printf '%s' "$g"
}

# ---------- Pure derivation (no state, no git) ----------
# Conventional-commit type from a free-text goal. Unmatched goals fall back to
# `feature` — the long form is the canonical generated default. A title whose
# first word is "build" emits the short form `feat` instead.
derive_type() {
  local g t="feature"
  g=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$g" in
    *revert*) t="revert" ;;
    # hotfix MUST be checked before the general bugfix arm: "hotfix" itself
    # contains "fix" and would otherwise be swallowed by the fix-word arm.
    *hotfix*) t="hotfix" ;;
    # `fix` is matched as a WORD across its four positions (whole string, leading,
    # trailing, interior). The old `*"fix "*` required a trailing space, so a goal
    # ending "…and fix" or "…and fix." fell through to `feature`; a bare `*fix*`
    # would instead swallow prefix/suffix/fixture. The defect vocabulary that
    # follows catches bug reports whose text never contains "fix" at all.
    fix | fix[!a-z]* | *[!a-z]fix | *[!a-z]fix[!a-z]* | \
      *bug* | *defect* | *crash* | *blink* | *flicker* | *glitch* | *broken* | \
      *regression* | *incorrect* | *wrong* | *fails* | *failing*) t="bugfix" ;;
    *refactor*) t="refactor" ;;
    *perf* | *optimi*) t="perf" ;;
    *docs* | *document*) t="docs" ;;
    *test* | *coverage*) t="test" ;;
    *ci\ * | *pipeline*) t="ci" ;;
    # Leading verb "build" names new work; "build" anywhere else (build-time,
    # build:, builds, rebuild) still names the build system, below.
    build | build[[:space:]]*) t="feat" ;;
    *build* | *packaging*) t="build" ;;
    *chore* | *bump* | *dependency*) t="chore" ;;
    *) t="feature" ;;
  esac
  printf '%s' "$t"
}

# Issue key from a free-text goal — the first `\b[A-Z]{2,}-\d+\b` token, lowercased;
# empty when the goal carries none, which leaves the ticket-less shape unchanged.
# The all-caps match is what keeps it from firing on an already-kebabbed word pair.
# `head -n1` is deliberately avoided: it would SIGPIPE grep, and under the caller's
# `pipefail` that rc would discard a match this function had already found.
derive_ticket() {
  local k
  k=$(printf '%s' "${1:-}" | tr '\n' ' ' | grep -Eo '\b[A-Z]{2,}-[0-9]+\b') || k=""
  k=${k%%$'\n'*}
  printf '%s' "$k" | tr '[:upper:]' '[:lower:]'
}

# Uncapped kebab body, no leading/trailing '-'. `tr '\n' ' '` runs before the collapse:
# a multi-line goal would otherwise survive as embedded newlines through `sed`/`cut`'s
# line-oriented view and yield a two-line slug, which fails `git branch -m` outright.
# $2 is the optional ticket, stripped from the body or the key appears twice in one name.
slug_body() {
  local ticket="${2:-}" body
  body=$(printf '%s' "${1:-}" |
    tr '\n' ' ' |
    tr '[:upper:]' '[:lower:]' |
    sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//')

  if [ -n "$ticket" ]; then
    # Sentinel-wrapped so one pattern covers every position, and looped because a
    # replacement consumes its own trailing separator — a single global pass leaves
    # the second key of an adjacent "OV-1 OV-1" pair behind. Each pass strictly
    # shortens `body`, so the loop terminates. Glob-safe: derive_ticket emits only
    # [a-z0-9-] (rules/security.md — no dynamic program construction).
    body="-${body}-"
    while [ "$body" != "${body//-${ticket}-/-}" ]; do
      body="${body//-${ticket}-/-}"
    done
    body="${body#-}"
    body="${body%-}"
  fi
  printf '%s' "$body"
}

# Effective slug budget: the ticket segment and its separator are spent inside the
# same 48 characters. Floored at 1 so a pathologically long key cannot ask for a
# zero-length slug, which target_branch_name would refuse outright.
slug_budget() {
  local ticket="${1:-}" budget=48
  if [ -n "$ticket" ]; then
    budget=$((budget - ${#ticket} - 1))
    [ "$budget" -ge 1 ] || budget=1
  fi
  printf '%s' "$budget"
}

# Exit code only (0 = the budget dropped content), argv identical to derive_slug.
# A predicate rather than a flag set inside derive_slug: callers obtain the slug
# through command substitution, so any variable assigned there dies with the subshell.
# `slug_body` never emits a trailing '-', so an over-budget body always loses at
# least one real character on every branch of derive_slug's tail.
slug_is_truncated() {
  local body budget
  body=$(slug_body "${1:-}" "${2:-}")
  budget=$(slug_budget "${2:-}")
  [ "${#body}" -gt "$budget" ]
}

# Budget-capped kebab slug. Truncation drops the trailing PARTIAL segment rather than
# cutting mid-word. One whole word always survives, even one longer than the budget: an
# empty slug makes target_branch_name refuse, which is worse than a long name.
derive_slug() {
  local ticket="${2:-}" body budget keep next
  body=$(slug_body "${1:-}" "$ticket")
  budget=$(slug_budget "$ticket")

  if [ "${#body}" -le "$budget" ]; then
    printf '%s' "$body" | sed -e 's/-*$//'
    return 0
  fi

  # A cut landing exactly on a separator already ends on a whole word; stripping back
  # unconditionally would throw away a word that fit.
  next=$(printf '%s' "$body" | cut -c$((budget + 1))-$((budget + 1)))
  keep=$(printf '%s' "$body" | cut -c1-"$budget")
  if [ "$next" != "-" ]; then
    if [ "${keep%-*}" = "$keep" ]; then
      keep=${body%%-*}
    else
      keep=${keep%-*}
    fi
  fi
  printf '%s' "$keep" | sed -e 's/-*$//'
}

# `<type>/[<ticket>-]<slug>` — the ticket segment is emitted only when $3 is non-empty
# (`git-conventions.md § Branch Naming`). Returns 1 (no output) when the slug is empty —
# callers treat that as a no-op.
target_branch_name() {
  local t="${1:-}" s="${2:-}" k="${3:-}"
  [ -n "$s" ] || return 1
  if [ -n "$k" ]; then
    printf '%s/%s-%s' "$t" "$k" "$s"
  else
    printf '%s/%s' "$t" "$s"
  fi
}

# ---------- Audit helpers ----------
# meta_json k v k v … -> compact JSON object. Values are always strings. The
# <2-argument guard is not cosmetic: bash 3.2 errors on an empty array expansion
# under `set -u`, so the array must never reach jq empty.
meta_json() {
  command -v jq > /dev/null 2>&1 || {
    printf '{}'
    return 0
  }
  if [ $# -lt 2 ]; then
    printf '{}'
    return 0
  fi
  local args=() prog="{}" i=1
  while [ $# -gt 1 ]; do
    args+=(--arg "k$i" "$1" --arg "v$i" "$2")
    prog="$prog + {(\$k$i): \$v$i}"
    shift 2
    i=$((i + 1))
  done
  jq -cn "${args[@]}" "$prog"
}

# branch_audit_actor -> the actor a branch audit row names: CORPFLOW_AUDIT_ACTOR when it is
# exactly one name from BRANCH_AUDIT_ACTORS and, while a stage runs, that stage's own agent or
# orchestrator; else the agent owning CLAUDE_TASK_METADATA_STAGE (stage-codes.md § Primary
# Stages); else orchestrator, which runs the rename when no stage does. branch-name.sh keeps a
# copy for the one path that cannot source this file.
BRANCH_AUDIT_ACTORS="orchestrator product-manager software-architector team-lead developer
technical-lead security-reviewer qa-engineer technical-writer release-engineer project-manager
stakeholder incident-responder"

branch_audit_actor() {
  local o="${CORPFLOW_AUDIT_ACTOR:-}" owner=""
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
  # One exact word from a closed set: the row is the committed record of who acted. While a
  # stage runs, an override may name only that stage's own agent or the orchestrator, so a
  # stage cannot attribute its rename to an agent that did not act.
  case "$o" in '' | *[[:space:]]*) o="" ;; esac
  if [ -n "$o" ]; then
    case " ${BRANCH_AUDIT_ACTORS//$'\n'/ } " in
      *" $o "*)
        if [ -z "$owner" ] || [ "$o" = "$owner" ] || [ "$o" = "orchestrator" ]; then
          printf '%s' "$o"
          return 0
        fi
        ;;
    esac
  fi
  printf '%s' "${owner:-orchestrator}"
}

# One audit row per outcome. Identity is read from the environment AT CALL TIME
# rather than set through a setter: an order-dependent global would silently write
# the wrong actor on a missed call, and a jq path built from a variable is dynamic
# program construction (rules/security.md). Defaults reproduce the FN-stage rows
# byte-for-byte; branch-name.sh overrides all three knobs for its PL-stage rows.
# Never fails the caller: an audit row is evidence, not a gate.
#
# AUDIT_DRY_RUN=1 suppresses the row entirely. The guard lives HERE, not at the call
# sites, because branch-name.sh's ladder has nine arms and each one audits: a per-arm
# check is nine chances to forget, and the arm that forgets writes a real
# `branch_renamed` row for a run that renamed nothing — which then trips the once-per-run
# already_named guard and spends the naming window on a preview.
audit_fn() {
  local action="$1" result="$2" meta="${3:-}"
  [ "${AUDIT_DRY_RUN:-0}" = "1" ] && return 0
  local subj="${AUDIT_SUBJECT:-FN0}"
  local stage="${AUDIT_STAGE:-FN}"
  case "$stage" in
    [A-Z][A-Z]) ;;
    *) stage="FN" ;;
  esac
  local actor="${AUDIT_ACTOR:-}"
  if [ -z "$actor" ]; then
    if [ "$stage" = "FN" ]; then actor="project-manager"; else actor=$(branch_audit_actor); fi
  fi
  [ -n "$meta" ] || meta='{}'
  local ts wid ri tid dk
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  wid=$(jq -r '.worktask_id // "unknown"' "${STATE_PATH:-.context/state.json}" 2> /dev/null || printf 'unknown')
  ri=$(jq -r '.run_index // 0' "${STATE_PATH:-.context/state.json}" 2> /dev/null || printf '0')
  # Ledger keys are numbered. state-patch.sh owns the resolution ladder, so ask it rather
  # than keeping a second copy that can drift from the writer's idea of the current
  # instance. The local jq is the fallback for a truncated install: an audit row is
  # evidence, never a gate, so an unreachable sibling must not cost us the row.
  tid=$(STATE_PATH="${STATE_PATH:-.context/state.json}" \
    bash "$(dirname "${BASH_SOURCE[0]}")/state-patch.sh" \
    --state "${STATE_PATH:-.context/state.json}" --resolve-task-id "$stage" 2> /dev/null) \
    || tid=""
  [ -n "$tid" ] || tid=$(jq -r --arg s "$stage" '
    [ (.tasks // {}) | keys[] | select(test("^" + $s + "[0-9]+$")) ]
    | sort_by(ltrimstr($s) | tonumber) | last // ($s + "0")' \
    "${STATE_PATH:-.context/state.json}" 2> /dev/null || printf '%s0' "$stage")
  dk="$wid:$ri:$action"
  mkdir -p "${CONTEXT_DIR:-.context}/logs" 2> /dev/null || true
  # A symlinked audit.jsonl turns the append below into a write primitive against an
  # arbitrary target. Refuse rather than follow — the guard skills/shared/lib/audit-lib.sh
  # and hooks/model-switch-lib.sh both carry. Spelled inline here, and only here, because
  # this file's header contract is that it sources nothing: the batch-scope guard below
  # depends on absence being its only failure mode, which a source block would break.
  [ ! -L "${CONTEXT_DIR:-.context}/logs/audit.jsonl" ] || return 0
  # `2>/dev/null` on the pipeline above only silences jq's own stderr; the
  # `>>` append is the CALLING SHELL's redirection and its failure (e.g. an
  # unwritable log dir) is invisible to that guard. Capture it explicitly so a
  # rename that mutates git state never completes with silent, un-audited
  # evidence loss (a security-relevant action leaving no trace). Our own warning
  # line names the action/result only; the shell's own error line preceding it
  # will leak the sink path and absolute library path (operator's terminal only).
  if command -v jq > /dev/null 2>&1; then
    if ! jq -cn --arg ts "$ts" --arg a "$action" --arg subj "$subj" --arg r "$result" \
      --arg t "$tid" --arg dk "$dk" --arg actor "$actor" --arg origin "$stage" --argjson m "$meta" \
      '{ts:$ts, actor:$actor, action:$a, subject:$subj, result:$r, task_id:$t,
        metadata:($m + {origin_stage:$origin, dedupe_key:$dk})}' \
      >> "${CONTEXT_DIR:-.context}/logs/audit.jsonl" 2> /dev/null; then
      printf >&2 'branch-lib: audit row NOT recorded (sink unwritable) — action=%s result=%s\n' \
        "$action" "$result"
    fi
  fi
  return 0
}

# ---------- batch / incident scope guard ------------------------------------
# Re-derived, not mirrored: this file's only failure mode is absence (no jq probe,
# no fallible prologue at load time), so the "unreachable library cannot fail the
# guard that exempts batch runs" property holds without a partial local copy.
# Signals (any hit => self-disable):
#   1. MILESTONE_MODE=1        env override (tests, /megatask)
#   2. INCIDENT_MODE=1         env override (tests, incident runners)
#   3. state.json .metadata.milestone non-empty
#   4. state.json .tasks.PL0.metadata.megatask_group or .milestone non-empty — /megatask's
#      per-issue stamp, which holds after the stamp even when the env is lost
#   5. state.json .tasks.IR0 present — the emergency pipeline's marker stage
#   6. workspace.json present at $WORKSPACE_ROOT or $PWD
fn_batch_scope() {
  if [ "${MILESTONE_MODE:-0}" = "1" ]; then
    SCOPE_REASON="milestone_mode_env"
    return 0
  fi
  if [ "${INCIDENT_MODE:-0}" = "1" ]; then
    SCOPE_REASON="incident_mode_env"
    return 0
  fi
  if command -v jq > /dev/null 2>&1 && [ -f "${STATE_PATH:-.context/state.json}" ]; then
    local m
    m=$(jq -r '.metadata.milestone // ""' "${STATE_PATH:-.context/state.json}" 2> /dev/null || printf '')
    if [ -n "$m" ] && [ "$m" != "null" ]; then
      SCOPE_REASON="milestone_metadata"
      return 0
    fi
    m=$(jq -r '.tasks.PL0.metadata // {} | .megatask_group // .milestone // ""' \
      "${STATE_PATH:-.context/state.json}" 2> /dev/null || printf '')
    if [ -n "$m" ] && [ "$m" != "null" ]; then
      SCOPE_REASON="megatask_stamp"
      return 0
    fi
    if jq -e '[(.tasks // {}) | keys[] | select(test("^IR[0-9]+$"))] | length > 0' \
      "${STATE_PATH:-.context/state.json}" > /dev/null 2>&1; then
      SCOPE_REASON="incident_pipeline"
      return 0
    fi
  fi
  if [ -n "${WORKSPACE_ROOT:-}" ] && [ -f "${WORKSPACE_ROOT}/workspace.json" ]; then
    SCOPE_REASON="workspace_record"
    return 0
  fi
  if [ -f "${PWD}/workspace.json" ]; then
    SCOPE_REASON="workspace_record"
    return 0
  fi
  return 1
}

# ---------- integration-branch resolution -----------------------------------
# Single source of truth for "what is the integration branch", ranked:
#   0. fork_base()                           EVIDENCE — OPT-IN (--with-fork-point);
#                                            supplies a value only when 1-4 are all
#                                            empty and the caller asked; see below
#   1. $FN_BASE_REF                          explicit operator/test override
#   2a. state.json tasks.<ID>.metadata.base_ref
#                                            the row $BASE_REF_TASK_ID names; skipped
#                                            when the caller names no task
#   2b. state.json .metadata.base_ref        stamped by PL0, mirrors task metadata.
#                                            This rank is where a host-declared
#                                            target branch enters the order — it is
#                                            that value's provenance, not a probe
#   3. workspace.json .git.base_branch       /megatask per-issue record
#   4. git symbolic-ref refs/remotes/origin/HEAD
#   -  unresolved                            reported, never guessed
# There is deliberately NO hardcoded literal. Callers degrade non-blocking.
#
# Rank 0 reconciles, it never overrides: when the fork point disagrees with the
# value a lower rank supplied, the disagreement is surfaced by the caller (PL0's
# sweep item, base-sanity's candidate line) and stdout is unchanged. An overriding
# rank 0 would defeat base-sanity, which compares the diff against the base the PR
# will actually target — the resolver would hand it the right base and every
# wrong-base PR would pass.
#
# It is opt-in for the same reason it never overrides. Every other consumer reads an
# EMPTY return as "decline, do not guess" and gates on it (refine-branch-target's
# base_unresolved no-op, branch-name, continuity, issue-close-required). Filling that
# empty with an inferred branch would make those gates act on a guess — the failure
# base-sanity spends a whole degrade rung (base_guessed) avoiding. Only a caller that
# can tell an inferred base from a configured one passes --with-fork-point.

# Fork-point evidence: the remote branch HEAD most closely descends from, by
# smallest ahead-count. $1 (optional) is the configured base, used for tie-break
# level 2 only; passing it as an argument is what keeps rank 0 from recursing back
# through resolve_base_ref. Always exits 0 — this library is sourced into
# `set -euo pipefail` scripts where a non-zero `v=$(fork_base)` kills the caller.
#
# Memoised per process and per argument. base-sanity reaches the ladder three times in one
# run — resolve_base_ref, base_ref_source, then the fork candidate — and each evaluation
# costs 2 x `git rev-list --count` per remote branch, so a 400-branch remote paid ~2400
# rev-lists on the blocking FN path. Refs cannot move mid-run, so the later calls reuse the
# first. The cache is process-local: a new shell, and every bats case is one, recomputes.
fork_base() {
  if [ "${_FORK_BASE_KEY-$'\x01unset'}" = "${1:-}" ]; then
    printf '%s' "${_FORK_BASE_VAL:-}"
    return 0
  fi
  _FORK_BASE_VAL="$(_fork_base_uncached "${1:-}")"
  _FORK_BASE_KEY="${1:-}"
  printf '%s' "$_FORK_BASE_VAL"
}

_fork_base_uncached() {
  local configured="${1:-}" default="" rows="" sorted="" first=""
  local refname symref otype name ahead behind t2 t3
  if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    printf ''
    return 0
  fi
  configured="${configured#origin/}"
  default=$(git symbolic-ref --short refs/remotes/origin/HEAD 2> /dev/null || printf '')
  default="${default#origin/}"

  # Full refnames with %(symref), never %(refname:short): under short formatting
  # refs/remotes/origin/HEAD prints as the bare string `origin`, which a `/HEAD$`
  # filter misses and which no `origin/<name>` ref resolves. Dropping every
  # non-empty symref excludes any symbolic pointer, however it is spelled. The `|`
  # delimiter is required because an empty symref field collapses under IFS
  # whitespace splitting and shifts objecttype into its place.
  rows=$(git for-each-ref --format='%(refname)|%(symref)|%(objecttype)' \
    refs/remotes/origin 2> /dev/null || printf '')
  [ -n "$rows" ] || {
    printf ''
    return 0
  }

  # Tie-break, first discriminator wins: ahead-count, then the configured base,
  # then the repository default branch, then behind-count, then byte order.
  # The last level is determinism only and carries no meaning.
  rows=$(printf '%s\n' "$rows" | while IFS='|' read -r refname symref otype; do
    [ -n "$refname" ] || continue
    [ -z "$symref" ] || continue
    [ "$otype" = "commit" ] || continue
    name="${refname#refs/remotes/origin/}"
    # A candidate whose probe fails is dropped from the ranking, never ranked at a
    # sentinel: a failed probe must not be able to become the answer.
    ahead=$(git rev-list --count "$refname..HEAD" 2> /dev/null) || continue
    # Leading `(` on the pattern: bash 3.2 misparses an unparenthesised case
    # pattern inside a command substitution ("syntax error near `;;'").
    case "$ahead" in ('' | *[!0-9]*) continue ;; esac
    behind=$(git rev-list --count "HEAD..$refname" 2> /dev/null) || continue
    case "$behind" in ('' | *[!0-9]*) continue ;; esac
    # ahead=0 means the ref contains HEAD: HEAD's own pushed branch, a copy of it, or a
    # descendant. None is what HEAD forked from, and ranking is ahead-ascending, so left in
    # they always outrank the real parent — the fork-point diagnostic then names the branch
    # under test. Exception: a ref sitting exactly on HEAD that is also the configured base
    # or the repo default, because a run whose HEAD equals its integration branch did fork
    # from there.
    if [ "$ahead" -eq 0 ]; then
      [ "$behind" -eq 0 ] || continue
      if [ "$name" != "$configured" ] && [ "$name" != "$default" ]; then continue; fi
    fi
    t2=1
    if [ -n "$configured" ] && [ "$name" = "$configured" ]; then t2=0; fi
    t3=1
    if [ -n "$default" ] && [ "$name" = "$default" ]; then t3=0; fi
    printf '%s %s %s %s %s\n' "$ahead" "$t2" "$t3" "$behind" "$name"
  done)
  [ -n "$rows" ] || {
    printf ''
    return 0
  }

  # Captured, not piped into `head -1`: an early-exit pipe consumer can SIGPIPE
  # sort and trip a caller's pipefail.
  sorted=$(printf '%s\n' "$rows" | LC_ALL=C sort -k1,1n -k2,2n -k3,3n -k4,4n -k5,5)
  first="${sorted%%$'\n'*}"
  [ -n "$first" ] || {
    printf ''
    return 0
  }
  # Refnames cannot contain spaces, so the last field is the whole branch name
  # even for `feature/x` shapes.
  printf '%s' "${first##* }"
}

# THE ladder — written once so the value and its provenance can never disagree.
# Prints "<source> <value>" on one line; the two public wrappers take one field
# each. A global would not do: `v=$(resolve_base_ref)` runs in a subshell that
# discards anything the function assigns.
_base_ref_ranked() {
  local v src with_fork=0
  if [ "${1:-}" = "--with-fork-point" ]; then with_fork=1; fi
  v="${FN_BASE_REF:-}"
  src="env"
  [ "$v" = "null" ] && v=""
  if [ -z "$v" ] && command -v jq > /dev/null 2>&1; then
    # Rank 2a outranks the ledger mirror because the mirror is a copy: when it is
    # written wrong, every row under it inherits the wrong base, while the row's
    # own stamp is the value the run was dispatched with. The id is caller input,
    # so it reaches jq only as a bound variable; an unknown or hostile id is a
    # missing key and falls through to rank 2b. `strings` drops a non-string value
    # the same way instead of printing JSON as a branch name.
    if [ -n "${BASE_REF_TASK_ID:-}" ]; then
      v=$(jq -r --arg id "${BASE_REF_TASK_ID}" '.tasks[$id].metadata.base_ref // empty | strings' \
        "${STATE_PATH:-.context/state.json}" 2> /dev/null || printf '')
      [ "$v" = "null" ] && v=""
      if [ -n "$v" ]; then src="task"; fi
    fi
    if [ -z "$v" ]; then
      v=$(jq -r '.metadata.base_ref // empty' "${STATE_PATH:-.context/state.json}" 2> /dev/null || printf '')
      [ "$v" = "null" ] && v=""
      if [ -n "$v" ]; then src="state"; fi
    fi
    if [ -z "$v" ]; then
      local ws="${WORKSPACE_ROOT:-$PWD}/workspace.json"
      if [ -f "$ws" ]; then
        v=$(jq -r '.git.base_branch // empty' "$ws" 2> /dev/null || printf '')
        [ "$v" = "null" ] && v=""
        [ -n "$v" ] && src="workspace"
      fi
    fi
  fi
  if [ -z "$v" ]; then
    v=$(git symbolic-ref --short refs/remotes/origin/HEAD 2> /dev/null || printf '')
    [ "$v" = "null" ] && v=""
    [ -n "$v" ] && src="origin_head"
  fi
  # Rank 0, evaluated last on purpose: it fills only the gap that used to end in
  # `unresolved`, and only for a caller that opted in. Calling fork_base ahead of
  # ranks 1-4 would also cost one rev-list per remote branch on the preflight hot
  # path.
  if [ -z "$v" ] && [ "$with_fork" = "1" ]; then
    v=$(fork_base 2> /dev/null || printf '')
    [ -n "$v" ] && src="fork_point"
  fi
  [ -n "$v" ] || src="unresolved"
  printf '%s %s' "$src" "$v"
}

# Pass --with-fork-point to enable rank 0. Without it the return is byte-identical
# to the pre-rank-0 resolver, including the empty return that callers gate on.
resolve_base_ref() {
  local r
  r=$(_base_ref_ranked "${1:-}")
  printf '%s' "${r#* }"
}

# Which rank answered: env | task | state | workspace | origin_head | fork_point |
# unresolved. `task` is rank 2a, the row BASE_REF_TASK_ID names; `state` is the
# ledger mirror at rank 2b. `fork_point` tells a caller the base is inferred evidence rather
# than a configured target — base-sanity degrades rather than blocking on it.
base_ref_source() {
  local r
  r=$(_base_ref_ranked "${1:-}")
  printf '%s' "${r%% *}"
}

# A base ref may be stored bare (`master`) or remote-qualified (`origin/release/v2`
# — the form workspace-modes.md documents). Map either onto something git resolves,
# which is what lets both stored shapes work without normalising the stored value.
#
# The REMOTE-TRACKING ref is preferred over a same-named local branch. Trying the bare
# name first resolved a stale local copy whenever one existed, and a stale base makes
# the diff measured against it wrong in the blocking direction: base-sanity reported a
# 70-file diff against a ledger claiming 18 and refused a finalization that was in fact
# correct, while the only escape it signposts is the override that would also mask a
# REAL wrong-base finding. Third patch to this resolution logic, so reordering alone
# was rejected: it trades one silent wrong answer for another. Divergence is announced
# on stderr with both names and both ahead-counts, and callers must not swallow it.
resolve_git_ref() {
  local name="$1" bare="${1#origin/}" c remote="" local_ref="" counts behind ahead upstream

  # The branch's own configured upstream is tried first, because `origin` is not always the
  # canonical remote. In a fork workflow — origin = fork, upstream = canonical — hardcoding
  # origin/ picks the stale fork ref, and base-sanity then measures the diff against it and
  # blocks a correctly-based PR. Falls through to origin/ when no upstream is set, so the
  # single-remote case resolves exactly as before.
  # Short branch name, not refs/heads/: `@{upstream}` rejects a full refname outright
  # ("fatal: no such branch"), which silently yielded no upstream and fell through to origin/.
  upstream=$(git rev-parse --verify --quiet --abbrev-ref "${bare}@{upstream}" 2> /dev/null || printf '')
  for c in ${upstream:+"$upstream"} "origin/$bare" "refs/remotes/origin/$bare"; do
    if git rev-parse --verify --quiet "$c" > /dev/null 2>&1; then remote="$c"; break; fi
  done
  git rev-parse --verify --quiet "refs/heads/$bare" > /dev/null 2>&1 && local_ref="refs/heads/$bare"

  if [[ -n "$remote" ]]; then
    if [[ -n "$local_ref" ]] &&
       [[ "$(git rev-parse "$remote" 2> /dev/null)" != "$(git rev-parse "$local_ref" 2> /dev/null)" ]]; then
      # --left-right --count on a symmetric range: left = remote-only, right = local-only.
      counts=$(git rev-list --left-right --count "${remote}...${local_ref}" 2> /dev/null || printf '')
      behind=${counts%%[!0-9]*}; ahead=${counts##*[!0-9-]}
      printf >&2 'WARNING: base ref %s is ambiguous — %s and %s have diverged.\n' \
        "$name" "$remote" "$local_ref"
      printf >&2 '  %s is ahead by %s commit(s); %s is ahead by %s commit(s).\n' \
        "$remote" "${behind:-?}" "$local_ref" "${ahead:-?}"
      printf >&2 '  Resolving to %s. Pass FN_BASE_REF=%s to force the local branch.\n' \
        "$remote" "$local_ref"
    fi
    printf '%s' "$remote"
    return 0
  fi

  # No remote-tracking ref: fall back exactly as before, so a purely local base,
  # a tag or a raw revision still resolves.
  for c in "$name" "$local_ref"; do
    [[ -n "$c" ]] || continue
    if git rev-parse --verify --quiet "$c" > /dev/null 2>&1; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}
