#!/usr/bin/env bash
# state-merge.sh — SubagentStop hook (OPTIONAL belt-and-suspenders for
# the handoff protocol). Reads the artifact's `handoff:` frontmatter and
# atomic-merges it into .context/state.json.
#
# Contract:
#   - Exits 0 ALWAYS — must never block a stage transition. Failures log to
#     .context/logs/state-merge.log and stderr.
#   - Idempotent: a ledger already reflecting this frontmatter is left alone.
#   - Absent state.json: exit 0 before any mkdir, log or write.
#   - Corrupt state.json: the original is copied aside and verified before any
#     write; an unverifiable backup aborts the repair and leaves the file as
#     found. The original is never destroyed.
#   - Absent frontmatter: derive a minimal handoff from CLAUDE_AGENT_NAME and
#     CLAUDE_ARTIFACT_PATH.
#   - YAML: prefer yq, else an inline awk subset (we own the schema).
#
# Env from Claude Code: CLAUDE_TASK_ID, CLAUDE_AGENT_NAME,
# CLAUDE_ARTIFACT_PATH, CLAUDE_WORKTASK_ID, CLAUDE_DURATION_MS,
# CLAUDE_TASK_METADATA_STAGE.
#
# All merge logic lives in skills/worktask/scripts/state-patch.sh; this is a
# delegating wrapper. That script is resolved from $CLAUDE_PLUGIN_ROOT first (a
# project-local copy has no skills/ tree beside it), else one level up.
#
# Usage (manual self-test):
#   state-merge.sh --self-test
#
# Usage (manual invocation):
#   CLAUDE_ARTIFACT_PATH=.context/development.md \
#   CLAUDE_TASK_METADATA_STAGE=DV \
#   .claude/hooks/state-merge.sh

set -euo pipefail

# ---------- Self-test / help ----------
# Dispatched BEFORE workspace resolution: neither depends on a resolved root
# (self-test delegates straight to state-patch.sh --self-test; help just prints
# this header), so gating them behind the ladder would fail a self-test run
# in exactly the unresolved-root environment a CI sandbox is likely to be.
#
# Re-run all original hook self-test cases by delegating to state-patch.sh --self-test.
# The cases cover: explicit artifact, idempotency, numbered artifact resolution (exact
# run_index + highest-N), and absent-artifact no-op.
if [[ "${1:-}" == "--self-test" ]]; then
  HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
  # hooks/ sits one level below the plugin root.
  PATCH_SCRIPT="${CLAUDE_PLUGIN_ROOT:-${HOOK_DIR}/..}/skills/worktask/scripts/state-patch.sh"
  if [[ ! -f "$PATCH_SCRIPT" ]]; then
    PATCH_SCRIPT="${HOOK_DIR}/../skills/worktask/scripts/state-patch.sh"
  fi
  if [[ ! -f "$PATCH_SCRIPT" ]]; then
    printf 'self-test: state-patch.sh not found at %s\n' "$PATCH_SCRIPT" >&2
    exit 1
  fi

  # Run the canonical self-test from state-patch.sh (covers all paths this hook uses).
  # Captured, not streamed: the wrapper line must repeat the delegate's executed-case count,
  # so a digitless line here cannot hide that the cases ran in another process.
  if st_out=$(bash "$PATCH_SCRIPT" --self-test); then
    printf '%s\n' "$st_out"
    st_n=$(printf '%s\n' "$st_out" | sed -n 's/^self-test: ALL PASS (\([0-9][0-9]*\) passed, 0 failed)$/\1/p' | tail -n 1)
    if [[ -z "$st_n" ]]; then
      printf 'self-test: state-patch.sh --self-test passed without a case count\n' >&2
      exit 1
    fi
    printf 'self-test (via state-patch.sh): ALL PASS (%s passed, 0 failed)\n' "$st_n"
    exit 0
  else
    printf '%s\n' "$st_out"
    printf 'self-test: state-patch.sh --self-test FAILED\n' >&2
    exit 1
  fi
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n 's/^# \{0,1\}//p' "$0" | sed -n '1,/^$/p'
  exit 0
fi

# ---------- Workspace resolution ----------
# Never resolve `.context/` from cwd: this fires on SubagentStop, often for a DV
# stream, whose cwd is a linked worktree where `.context/` does not exist (it is
# gitignored and never carried into a worktree checkout). A cwd-relative merge
# lands in a throwaway ledger, silently. No ledger means nothing to merge into,
# so an unseeded checkout gets no `.context/logs/` either.
#
# Guarded source (AD-2): a truncated library is a syntax error, fatal under this
# script's `set -e` and unrescuable by `||`, which would break a hook whose whole
# contract is "exit 0 ALWAYS". Capture `$-`, drop `-e` across the source, restore.
_LIB="$(dirname "$0")/model-switch-lib.sh"
_CF_OPTS=$-
set +e
# shellcheck source=hooks/model-switch-lib.sh
[ -f "$_LIB" ] && . "$_LIB"
case "$_CF_OPTS" in *e*) set -e ;; esac

LIB_DEGRADED=0
if command -v corpflow_hook_audit_row > /dev/null 2>&1; then
  # The payload is read only to bind a /megatask issue: the inherited
  # CLAUDE_PROJECT_DIR names the batch, not the issue this agent worked. Bounded
  # so a manual run on an open terminal or idle pipe never hangs the hook.
  PAYLOAD=""
  if [ ! -t 0 ]; then
    IFS= read -r -d '' -t 1 PAYLOAD || true
  fi
  if command -v corpflow_bind_payload > /dev/null 2>&1; then
    corpflow_bind_payload "$PAYLOAD"
  fi
  WORKSPACE_DIR=$(corpflow_workspace_root)
else
  # Library-free last resort: declared roots holding a ledger, never cwd.
  WORKSPACE_DIR=""
  if [ -n "${WORKSPACE_ROOT:-}" ] && [ -f "${WORKSPACE_ROOT}/.context/state.json" ]; then
    WORKSPACE_DIR="${WORKSPACE_ROOT}"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "${CLAUDE_PROJECT_DIR}/.context/state.json" ]; then
    WORKSPACE_DIR="${CLAUDE_PROJECT_DIR}"
  fi
  LIB_DEGRADED=1
fi

# Unresolved: there is nowhere safe to merge into or log to, so stop before the
# first mkdir rather than materialize .context/ under a guessed directory.
[ -n "$WORKSPACE_DIR" ] || exit 0

LOG_DIR="$WORKSPACE_DIR/.context/logs"
mkdir -p "$LOG_DIR" 2> /dev/null || true
LOG="$LOG_DIR/state-merge.log"

# Degraded signalling is library-free by necessity — stderr plus a zero-byte
# sentinel, never an audit row, because the appender is IN the library.
if [ "$LIB_DEGRADED" -eq 1 ]; then
  echo "state-merge: shared library unusable at $_LIB — workspace root resolved by fallback" >&2
  : > "$LOG_DIR/.corpflow-lib-missing" 2> /dev/null || true
fi

log() {
  printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${1:-INFO}" "${2:-}" >> "$LOG" 2> /dev/null || true
}

# Never invoked: state-merge delegates every resolution to state-patch.sh. It survives as
# source 3 of the seven-way map that artifact-map-parity.bats guards, which exists because
# that map has already drifted once and stranded a basename for 34 releases.
# shellcheck disable=SC2329 # parity fixture; deleting it deletes a drift guard
_basename_for_stage() {
  case "$1" in
    PL) printf 'planning' ;;
    AR) printf 'architecture' ;;
    TL) printf 'coordination' ;;
    DV) printf 'development' ;;
    DR) printf 'developer-review' ;;
    SR) printf 'security-review' ;;
    QA) printf 'testing' ;;
    DC) printf 'documentation' ;;
    RE) printf 'release' ;;
    FN) printf 'complete-summary' ;;
    ST) printf 'retrospective' ;;
    IR) printf 'incident' ;;
    ET) printf 'ethics-review' ;;
    *) printf '' ;;
  esac
}

# ---------- Locate state-patch.sh ----------
HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
# Plugin root first: worktask.md Step 3b copies this hook into <project>/.claude/hooks/,
# where the relative arm resolves to a skills/ tree that does not exist. state-patch.sh is
# the only merge implementation, so failing to find it silently disables the Layer-2 net.
# The relative arm serves the shipped copy, one level below the plugin root at hooks/.
PATCH_SCRIPT="${CLAUDE_PLUGIN_ROOT:-${HOOK_DIR}/..}/skills/worktask/scripts/state-patch.sh"
if [[ ! -f "$PATCH_SCRIPT" ]]; then
  PATCH_SCRIPT="${HOOK_DIR}/../skills/worktask/scripts/state-patch.sh"
fi

if [[ ! -f "$PATCH_SCRIPT" ]]; then
  # Exit 0, never non-zero: a SubagentStop hook must not block the stage transition.
  log WARN "state-patch.sh not found at $PATCH_SCRIPT — skipping state merge"
  exit 0
fi

# ---------- Corrupt-ledger repair ----------
# One corrupt write would otherwise swallow every later stage: state-patch.sh
# leaves a ledger it cannot parse alone. Rebuilds the SKELETON ONLY and re-enters
# the delegation, which still owns the field merge.
#
# Invariant: the original is copied aside and verified byte-equal BEFORE any
# write, and an unverifiable backup aborts the repair — a corrupt ledger is
# recoverable, a destroyed one is not.
STATE_FILE="$WORKSPACE_DIR/.context/state.json"

# First unused name in the base, base-1, base-2 … series.
# `-L` as well as `-e`: `-e` is false for a DANGLING symlink, so a pre-planted broken
# link would read as a free name, `cp` would follow it to the link's target, and the
# `cmp -s` guard would dereference the same link and pass — a silent write-through.
_repair_backup_path() {
  local candidate="$1" i=1
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    candidate="$1-$i"
    i=$((i + 1))
  done
  printf '%s' "$candidate"
}

# Scrape a JSON string field out of bytes that no longer parse. Best-effort by
# construction: empty output means "no salvage", not "field absent".
_salvage_field() {
  local out
  if out=$(sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2> /dev/null); then
    printf '%s' "${out%%$'\n'*}"
  fi
}

# ALWAYS returns 0. Every non-repair path returns silently and leaves the corrupt file
# untouched, which is the pre-existing behaviour this must stay byte-identical to; only
# a repair that starts and then fails is worth a log line.
_repair_corrupt_state() {
  local art="${CLAUDE_ARTIFACT_PATH:-}" fm backup backup_rel tmp wt_id platform row n=0 suffix

  [[ -n "$art" && -f "$art" ]] || return 0
  fm=$(sed -n '1,40p' "$art" 2> /dev/null) || return 0
  # Subset check only — enough to know a rebuild is warranted. state-patch.sh below is
  # the authoritative parser.
  [[ $fm == *handoff:* ]] || return 0
  [[ $fm =~ [[:space:]]stage:[[:space:]]*[A-Za-z] ]] || return 0

  # run_index from the artifact's -N.md suffix: the same source state-patch.sh resolves
  # artifacts by, so the rebuilt skeleton cannot be labelled for a different run.
  suffix="${art##*-}"
  suffix="${suffix%.md}"
  if [[ $suffix =~ ^[0-9]+$ ]]; then n="$suffix"; fi

  backup=$(_repair_backup_path "$STATE_FILE.corrupt.$(date -u +%Y%m%dT%H%M%SZ)")
  if ! cp "$STATE_FILE" "$backup" 2> /dev/null || ! cmp -s "$STATE_FILE" "$backup"; then
    log WARN "corrupt state.json: backup to $backup failed or unverifiable — repair aborted, file untouched"
    if [[ -e "$backup" ]] && ! rm -f "$backup" 2> /dev/null; then
      log WARN "corrupt state.json: partial backup left at $backup"
    fi
    return 0
  fi

  wt_id=$(_salvage_field "$STATE_FILE" worktask_id)
  [[ -n "$wt_id" ]] || wt_id="${CLAUDE_WORKTASK_ID:-unknown}"
  platform=$(_salvage_field "$STATE_FILE" platform)
  [[ -n "$platform" ]] || platform="all"

  # Same directory as the target so the rename is atomic — derived from
  # STATE_FILE rather than re-spelled relative to cwd, so the two cannot drift
  # onto different filesystems (a cross-device rename is not atomic).
  tmp="$(dirname "$STATE_FILE")/.state.json.repair.$$.tmp"
  if ! jq -cn --arg id "$wt_id" --arg plat "$platform" --argjson n "$n" '
      { version: 2, worktask_id: $id,
        plan_file: (".context/planning-" + ($n | tostring) + ".md"),
        platform: $plat, run_index: $n,
        tasks: {}, facts: {}, handoffs: {}, metadata: {} }' > "$tmp" 2> /dev/null; then
    log WARN "corrupt state.json: skeleton write failed — file untouched (backup at $backup)"
    if [[ -e "$tmp" ]] && ! rm -f "$tmp" 2> /dev/null; then
      log WARN "corrupt state.json: stale temp left at $tmp"
    fi
    return 0
  fi
  if ! mv -f "$tmp" "$STATE_FILE"; then
    log WARN "corrupt state.json: rename failed — file untouched (backup at $backup)"
    return 0
  fi

  # Audit rows carry workspace-relative paths (handoff-protocol.md #f4 names the backup
  # `.context/state.json.corrupt.<iso-ts>`, and `artifact` below is relative), so the trail
  # stays portable across the worktree the hook happened to fire in.
  backup_rel="${backup#"$WORKSPACE_DIR"/}"

  if row=$(jq -cn --arg ts "$(date -u +%FT%TZ)" --arg id "$wt_id" --arg backup "$backup_rel" \
    --argjson n "$n" --arg stage "${CLAUDE_TASK_METADATA_STAGE:-}" --arg art "$art" '
      { ts: $ts, actor: "hook:state-merge", action: "state_repair", subject: $id,
        result: "repaired",
        metadata: { reason: "corrupt_state_json", backup: $backup, run_index: $n,
                    stage: $stage, artifact: $art } }' 2> /dev/null); then
    # A symlinked audit.jsonl turns this append into a write primitive against an
    # arbitrary target. Refuse rather than follow — the same guard the hook appender in
    # model-switch-lib.sh carries. A lost row never blocks a repair that already landed.
    if [ ! -L "$LOG_DIR/audit.jsonl" ]; then
      printf '%s\n' "$row" >> "$LOG_DIR/audit.jsonl"
    fi
  fi
  log INFO "corrupt state.json rebuilt from $art (backup=$backup run_index=$n) — delegating merge"
  return 0
}

# Idempotent by construction: after a repair the ledger parses, so a re-run does not
# re-enter this block — no second backup, no second audit row.
if [[ -f "$STATE_FILE" ]] && command -v jq > /dev/null 2>&1 \
  && ! jq -e . "$STATE_FILE" > /dev/null 2>&1; then
  _repair_corrupt_state
fi

# ---------- Delegate to state-patch.sh ----------
# Build CLI args from the SubagentStop env vars.  state-patch.sh is the single
# implementation; the hook just translates env → argv and enforces exit 0.
PATCH_ARGS=()
[[ -n "${CLAUDE_TASK_METADATA_STAGE:-}" ]] && PATCH_ARGS+=(--stage "$CLAUDE_TASK_METADATA_STAGE")
[[ -n "${CLAUDE_ARTIFACT_PATH:-}" ]] && PATCH_ARGS+=(--artifact "$CLAUDE_ARTIFACT_PATH")
# The stage code alone cannot name a split stage's instance, so forward the runtime's task
# id when it supplies one; the shape guard keeps a malformed value from becoming a new key.
[[ "${CLAUDE_TASK_ID:-}" =~ ^[A-Z]{2}[0-9]+$ ]] && PATCH_ARGS+=(--task-id "$CLAUDE_TASK_ID")
PATCH_ARGS+=(--log "$LOG")
# completed_via provenance: this delegating hook is enforcement Layer 2 ("hook").
# The orchestrator's synchronous Step-6.5 path overrides via STATE_MERGE_VIA=step6_5
# so the two layers are distinguishable in state.json. (Additive; absence = Layer 1.)
PATCH_ARGS+=(--via "${STATE_MERGE_VIA:-hook}")
# Pass the resolved root down explicitly rather than let state-patch.sh re-derive
# it from cwd: this hook already paid for rank 5's git probe (WORKSPACE_DIR
# above), and a second, independent resolution from a different cwd could answer
# differently. CONTEXT_DIR is exported too, for state-patch.sh's own rank 2.
PATCH_ARGS+=(--state "$STATE_FILE")
export CONTEXT_DIR="$WORKSPACE_DIR/.context"

# A SubagentStop with neither a stage nor an artifact is a non-stage subagent
# (reviewer, explorer, ...). There is nothing to patch, and delegating only made
# state-patch.sh append a WARN per stop to a log nobody reads. Leave no trace:
# a row or sentinel here would just move the same noise into audit.jsonl.
if [ -z "${CLAUDE_TASK_METADATA_STAGE:-}" ] && [ -z "${CLAUDE_ARTIFACT_PATH:-}" ]; then
  exit 0
fi

bash "$PATCH_SCRIPT" "${PATCH_ARGS[@]}" 2>> "$LOG" || {
  rc=$?
  log ERROR "state-patch.sh exited non-zero (rc=$rc stage=${CLAUDE_TASK_METADATA_STAGE:-} art=${CLAUDE_ARTIFACT_PATH:-}); continuing"
}

# Always exit 0 — MUST NOT block stage transition.
exit 0
