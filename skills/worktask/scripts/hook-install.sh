#!/usr/bin/env bash
# hook-install.sh — Idempotent installer for the state-merge.sh SubagentStop hook.
#
# Copies state-merge.sh from the plugin's hooks/ to the project's .claude/hooks/
# and verifies the plugin.json registration. Safe to re-run.
#
# An existing but non-executable destination is overwritten, so it is first saved to
# state-merge.sh.bak — a single slot rewritten on each overwrite, never accumulated.
#
# Every replace of an existing copy appends one `hook_refreshed` row to
# .context/logs/audit.jsonl, with `previous` naming the recovery source (the .bak path, or
# `git`). A fresh install, a no-op and --check write none, and a project without .context/
# gets no row rather than a new directory.
#
# Usage:
#   hook-install.sh                 # install hook
#   hook-install.sh --self-test     # run self-test in a scratch dir
#   hook-install.sh --check         # verify installation without modifying
#
# Env:
#   CLAUDE_PLUGIN_ROOT — plugin install directory (auto-discovered if unset)

set -euo pipefail

# ---------- Plugin root discovery ----------
# Located from $(dirname "$0") like every sibling resolution this script already does.
# `[ -r ]` first, not a bare `.`: sourcing a missing file with the `.` builtin is a
# special-builtin error that exits a `set -e` shell immediately, bypassing an
# `if ! . …; then` guard entirely.
_CORPFLOW_BASE="$(dirname "$0")/../../shared/lib/corpflow-base.sh"
if [[ -r "$_CORPFLOW_BASE" ]]; then
  # shellcheck source=skills/shared/lib/corpflow-base.sh
  . "$_CORPFLOW_BASE"
else
  printf >&2 'hook-install.sh: corpflow-base.sh unreachable at %s — plugin install broken\n' \
    "$_CORPFLOW_BASE"
  exit 3
fi

# The env rung stays at the call sites, deliberately unvalidated: an explicit override
# must win whether or not the tree it names carries the marker, and the allowlist that
# pins which files may read the variable can only see it here.
_plugin_root() {
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    echo "$CLAUDE_PLUGIN_ROOT"
    return 0
  fi
  corpflow_plugin_root
}

# ---------- Check mode ----------
check_installation() {
  local rc=0
  if [[ -x ".claude/hooks/state-merge.sh" ]]; then
    echo "check: .claude/hooks/state-merge.sh exists and is executable ✓"
  else
    echo "check: .claude/hooks/state-merge.sh MISSING or not executable" >&2
    rc=1
  fi

  local plugin_root
  if plugin_root=$(_plugin_root); then
    # Presence is not currency. The installed copy is a snapshot taken whenever the
    # installer last ran, so a security fix shipped into hooks/state-merge.sh keeps
    # running the old code with no signal anywhere until someone compares the bytes.
    if [[ -e ".claude/hooks/state-merge.sh" && -f "$plugin_root/hooks/state-merge.sh" ]]; then
      if cmp -s "$plugin_root/hooks/state-merge.sh" ".claude/hooks/state-merge.sh"; then
        echo "check: installed hook matches $plugin_root/hooks/state-merge.sh ✓"
      else
        echo "check: installed hook DIFFERS from $plugin_root/hooks/state-merge.sh — re-run hook-install.sh to refresh" >&2
        rc=1
      fi
    fi
    if grep -q 'state-merge\.sh' "$plugin_root/.claude-plugin/plugin.json" 2>/dev/null; then
      echo "check: plugin.json registers state-merge.sh SubagentStop hook ✓"
    else
      echo "check: plugin.json does NOT register state-merge.sh" >&2
      rc=1
    fi
  else
    echo "check: cannot locate plugin root (CLAUDE_PLUGIN_ROOT unset)" >&2
    rc=1
  fi
  return $rc
}

# True when git tracks <path> and it carries no local modification — i.e. the content about
# to be overwritten is already recoverable with `git checkout`, so no rescue copy is needed.
# Every arm is a refusal, never a failure: outside a repo, without git, or on an untracked
# path the answer is "not recoverable", which keeps the .bak.
_tracked_and_clean() { # <path>
  command -v git > /dev/null 2>&1 || return 1
  git rev-parse --is-inside-work-tree > /dev/null 2>&1 || return 1
  git ls-files --error-unmatch -- "$1" > /dev/null 2>&1 || return 1
  git diff --quiet -- "$1" > /dev/null 2>&1 || return 1
  return 0
}

# A silent replace leaves no trace of which hook code ran before, so a run that misbehaved
# under the old copy cannot be tied to it afterwards. Evidence only: a missing lib or an
# absent .context/ skips the row and never fails the install.
_audit_refresh() { # <previous>
  [[ -d .context ]] || return 0
  local lib
  lib="$(dirname "$0")/../../shared/lib/audit-lib.sh"
  [[ -r "$lib" ]] || return 0
  # shellcheck source=skills/shared/lib/audit-lib.sh disable=SC1091
  . "$lib"
  corpflow_audit_row --file .context/logs/audit.jsonl --actor hook-install \
    --action hook_refreshed --result ok --subject state-merge.sh --task-id none \
    --meta-kv "previous=$1"
}

# ---------- Install ----------
install_hook() {
  local plugin_root
  if ! plugin_root=$(_plugin_root); then
    echo "install: ERROR — cannot locate plugin root. Set CLAUDE_PLUGIN_ROOT." >&2
    return 1
  fi

  local src="$plugin_root/hooks/state-merge.sh"
  local dst=".claude/hooks/state-merge.sh"

  if [[ ! -f "$src" ]]; then
    echo "install: ERROR — source not found: $src" >&2
    return 1
  fi

  if [[ -x "$dst" ]] && cmp -s "$src" "$dst"; then
    echo "install: $dst already installed (idempotent — no-op)"
  elif [[ -x "$dst" ]]; then
    # Idempotence used to key on existence alone, which made re-running the installer
    # — the documented remedy for drift — a no-op precisely when it was needed.
    if _tracked_and_clean "$dst"; then
      # git already holds the copy being replaced, so a .bak would add nothing and would
      # add plenty: it lands untracked in the project tree, reaches the PR through FN's
      # `git add`, and trips DR's "no untracked files" re-entry rule. This is the common
      # case — the first worktask after a plugin upgrade.
      cp "$src" "$dst"
      chmod +x "$dst"
      echo "install: refreshed stale $dst (previous copy recoverable via git)"
      _audit_refresh git
    else
      cp "$dst" "$dst.bak"
      cp "$src" "$dst"
      chmod +x "$dst"
      echo "install: refreshed stale $dst (previous copy → $dst.bak)"
      _audit_refresh "$dst.bak"
    fi
  else
    mkdir -p .claude/hooks
    # A non-executable $dst is typically a hand-customized copy or a partial write; the
    # .bak (not .sh) suffix keeps the rescue out of the `.claude/hooks/*.sh` live-hook globs.
    local replaced=0
    if [[ -e "$dst" ]]; then
      cp "$dst" "$dst.bak"
      echo "install: backed up existing $dst → $dst.bak"
      replaced=1
    fi
    cp "$src" "$dst"
    chmod +x "$dst"
    echo "install: copied $src → $dst"
    [[ "$replaced" -eq 0 ]] || _audit_refresh "$dst.bak"
  fi

  if grep -q 'state-merge\.sh' "$plugin_root/.claude-plugin/plugin.json" 2>/dev/null; then
    echo "install: plugin.json hook registration verified ✓"
  else
    echo "install: WARNING — plugin.json does not register state-merge.sh. The hook will only work if invoked manually by the orchestrator (Step 6.5)." >&2
  fi
}

# ---------- main ----------
case "${1:-}" in
  --check)     check_installation ;;
  --self-test)
    # Sourced HERE, not at the top: the harness is test code the production path
    # never runs. `[ -r ]` first, not a bare `.`: sourcing a missing file with the
    # `.` builtin is a special-builtin error that exits the shell immediately,
    # bypassing an `if ! . …` guard entirely.
    SELFTEST_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/hook-install-selftest.sh"
    if [ -r "$SELFTEST_LIB_PATH" ]; then
      # shellcheck source=hook-install-selftest.sh
      # shellcheck disable=SC1090
      . "$SELFTEST_LIB_PATH"
    else
      printf >&2 'hook-install: self-test harness unreachable at %s — plugin install broken\n' \
        "$SELFTEST_LIB_PATH"
      exit 2
    fi
    self_test
    ;;
  -h|--help)
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '1,/^$/p'
    exit 0
    ;;
  *)           install_hook ;;
esac
