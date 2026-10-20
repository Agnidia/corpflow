#!/usr/bin/env bash
# megatask-monitor.sh — SubagentStop hook (corpflow worktask plugin).
#
# Drives the megatask completion loop. On every stop it reconciles each active
# group: a finished issue is marked completed/failed in orchestrator.json, its
# dependents are unblocked (a dependent whose blocked_by empties is promoted
# blocked → ready), its track is freed, and a megatask_progress row plus a
# terminal notification are emitted.
#
# A reconciliation SWEEP, not a per-agent signal: it never needs to know which
# agent stopped, which makes it idempotent and correct under retries. It scans
# .worktrees/*/orchestrator.json and reads each in-progress issue's
# workspace.json .execution.status.
#
# Completion contract, written by the per-issue worktask's FN/ST stage, or by its
# orchestrator when it parks or stops for the user (execution.reason says which):
#   .worktrees/<group>/<issue#>/workspace.json
#     .execution.status ∈ {"completed","failed"}  ("in_progress" otherwise)
#     .execution.pr      PR URL, optional
#
# Non-blocking contract:
#   - Exit 0 ALWAYS. Never blocks a stage/turn transition.
#   - Self-skips when no `.worktrees/*/orchestrator.json` exists, so plain
#     `/worktask` runs are untouched.
#   - Missing `jq` → log to stderr and exit 0.
#
# Self-test:  hooks/megatask-monitor.sh --self-test
set -eu

SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

ts() { date -u +%FT%TZ; }

# nullglob so an empty glob expands to nothing (not a literal) under bash & zsh.
shopt -s nullglob 2>/dev/null || setopt null_glob 2>/dev/null || true

if ! command -v jq >/dev/null 2>&1; then
  echo "megatask-monitor: jq not found, skipping" >&2
  exit 0
fi

# Atomic write: temp in the same dir + fsync + rename.
atomic_write() { # $1 = dest path, stdin = content
  _dest="$1"; _tmp="${_dest}.$$.${RANDOM:-0}.tmp"
  cat > "$_tmp" && { sync "$_tmp" 2>/dev/null || true; } && mv -f "$_tmp" "$_dest"
}

# Reconcile a single orchestrator.json. Echoes one progress line per newly
# settled issue. Returns 0 always.
reconcile_group() { # $1 = path to orchestrator.json
  orch="$1"; group_dir="$(dirname "$orch")"
  [ -f "$orch" ] || return 0
  jq -e . "$orch" >/dev/null 2>&1 || { echo "megatask-monitor: $orch unreadable" >&2; return 0; }

  # Collect (number,status) for in_progress issues whose workspace reports done.
  settled="" # space-separated  number:status[:pr]
  for num in $(jq -r '.issues[] | select(.status=="in_progress") | .number' "$orch" 2>/dev/null); do
    ws="$group_dir/$num/workspace.json"
    [ -f "$ws" ] || continue
    st=$(jq -r '.execution.status // "in_progress"' "$ws" 2>/dev/null || echo in_progress)
    case "$st" in
      completed|failed)
        pr=$(jq -r '.execution.pr // ""' "$ws" 2>/dev/null || echo "")
        settled="$settled $num:$st:$pr"
        ;;
    esac
  done
  [ -n "${settled# }" ] || return 0

  for entry in $settled; do
    num="${entry%%:*}"; rest="${entry#*:}"; status="${rest%%:*}"; pr="${rest#*:}"
    [ "$pr" = "$status" ] && pr=""   # no pr field present

    new=$(jq -c \
        --argjson c "$num" --arg st "$status" --arg pr "$pr" '
      # 1. settle the completed/failed issue + free its track
        .issues |= map(
          if .number == $c then
            .status = $st | .track = null
            | (if $pr != "" then .pr = $pr else . end)
          else . end )
      # 2. unblock dependents ONLY when the blocker completed (failed keeps them blocked)
      | (if $st == "completed" then
           .issues |= map(.blocked_by = ((.blocked_by // []) - [$c]))
           | .issues |= map(
               if .status == "blocked" and ((.blocked_by // []) | length) == 0
               then .status = "ready" else . end )
         else . end)
      # 3. free the track slot
      | .tracks |= with_entries(
          if .value.issue_number == $c
          then .value = { issue_number: null, status: "available" }
          else . end )
      # 4. recompute progress
      | .progress = {
          total:       (.issues | length),
          completed:   (.issues | map(select(.status=="completed")) | length),
          in_progress: (.issues | map(select(.status=="in_progress")) | length),
          ready:       (.issues | map(select(.status=="ready")) | length),
          blocked:     (.issues | map(select(.status=="blocked")) | length),
          failed:      (.issues | map(select(.status=="failed")) | length)
        }
      ' "$orch") || { echo "megatask-monitor: jq transform failed for #$num" >&2; continue; }

    printf '%s' "$new" | atomic_write "$orch"

    # Progress line: which dependents became ready as a result.
    ready_now=$(printf '%s' "$new" | jq -c '[.issues[] | select(.status=="ready") | .number]')
    remaining=$(printf '%s' "$new" | jq -r '.progress | (.total - .completed - .failed)')
    grp=$(printf '%s' "$new" | jq -r '.group // "unknown"')
    echo "$grp|$num|$status|$ready_now|$remaining"
  done
  return 0
}

run() { # $1 = root dir
  root="$1"
  log_dir="$root/.context/logs"
  any=0
  for orch in "$root"/.worktrees/*/orchestrator.json; do
    any=1
    while IFS='|' read -r grp num status ready_now remaining; do
      [ -n "$grp" ] || continue
      mkdir -p "$log_dir" 2>/dev/null || true
      # Refuse a symlinked audit.jsonl: following it makes this append a write primitive
      # against an arbitrary target. A lost row never blocks the caller.
      if [ ! -L "$log_dir/audit.jsonl" ]; then
        jq -cn --arg ts "$(ts)" --arg grp "$grp" --argjson num "$num" \
               --arg status "$status" --argjson ready "$ready_now" --argjson rem "$remaining" '
          { ts:$ts, actor:"hook:megatask-monitor", action:"megatask_progress",
            subject:("#"+($num|tostring)), result:$status,
            metadata:{ group:$grp, completed_issue:$num, newly_ready:$ready, remaining:$rem } }' \
          >> "$log_dir/audit.jsonl" 2>/dev/null || true
      fi
      # Terminal notification (safe additive stdout field on SubagentStop).
      [ "$SELF_TEST" -eq 0 ] && printf '{"hookSpecificOutput":{"terminalSequence":"\033]9;Megatask %s: #%s %s — %s left\007"}}\n' \
        "$grp" "$num" "$status" "$remaining" 2>/dev/null || true
    done <<EOF
$(reconcile_group "$orch")
EOF
  done
  [ "$any" -eq 1 ] || return 0   # self-skip: no megatask groups present
  return 0
}

# ---------------- Self-test ----------------
if [ "$SELF_TEST" -eq 1 ]; then
  td=$(mktemp -d "${TMPDIR:-/tmp}/megatask-monitor.XXXXXX"); trap 'rm -rf "$td"' EXIT
  mkdir -p "$td/.worktrees/milestone-9/41" "$td/.worktrees/milestone-9/42" "$td/.context/logs"
  cat > "$td/.worktrees/milestone-9/orchestrator.json" <<'EOF'
{ "version":"3.1","group":"milestone-9","milestone":{"number":9,"title":"T"},
  "configuration":{"parallel_tracks":2,"isolation":"worktree"},
  "topological_order":[41,42],
  "issues":[
    {"number":41,"priority":"P0","status":"in_progress","track":1,"level":0,"blocked_by":[],"blocks":[42]},
    {"number":42,"priority":"P1","status":"blocked","track":null,"level":1,"blocked_by":[41],"blocks":[]}],
  "tracks":{"1":{"issue_number":41},"2":{"issue_number":null,"status":"available"}},
  "progress":{"total":2,"completed":0,"in_progress":1,"ready":0,"blocked":1,"failed":0} }
EOF
  # Issue 41 reports completed via its workspace.json.
  cat > "$td/.worktrees/milestone-9/41/workspace.json" <<'EOF'
{ "version":"2.0","isolation":"worktree","execution":{"status":"completed","pr":"https://x/pull/1"} }
EOF
  cat > "$td/.worktrees/milestone-9/42/workspace.json" <<'EOF'
{ "version":"2.0","isolation":"worktree","execution":{"status":"in_progress"} }
EOF
  run "$td" >/dev/null
  out="$td/.worktrees/milestone-9/orchestrator.json"
  ok=$(jq -e '
       (.issues[] | select(.number==41) | .status=="completed" and .pr=="https://x/pull/1" and .track==null)
    and (.issues[] | select(.number==42) | .status=="ready" and (.blocked_by|length)==0)
    and (.tracks["1"].issue_number==null)
    and (.progress.completed==1 and .progress.ready==1 and .progress.blocked==0)
  ' "$out" >/dev/null && echo yes || echo no)
  if [ "$ok" = "yes" ] && grep -q megatask_progress "$td/.context/logs/audit.jsonl"; then
    echo "megatask-monitor: self-test OK (1 passed, 0 failed)"; exit 0
  fi
  echo "megatask-monitor: self-test FAIL (0 passed, 1 failed)"; jq . "$out" 2>/dev/null; exit 1
fi

# ---------------- Normal invocation ----------------
# Consume (ignore) stdin payload — reconciliation does not need the agent id.
cat >/dev/null 2>&1 || true
ROOT="${WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-.}}"
run "$ROOT"
exit 0
