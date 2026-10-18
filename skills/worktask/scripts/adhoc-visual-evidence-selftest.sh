#!/usr/bin/env bash
# adhoc-visual-evidence-selftest.sh — the `--self-test` harness for adhoc-visual-evidence.sh.
#
# SOURCED, never executed: adhoc-visual-evidence.sh loads this file only on the `--self-test`
# path, so the production path never pays for it. Sourcing leaves the caller's
# `$0` and every function it has already defined in scope — this file reads the
# caller's helpers and is not standalone.
#
# Contract: defines `run_self_tests`, returning 0 when every case passes.

# ---------- self-test -------------------------------------------------------
run_self_tests() {
  local pass=0 fail=0 self="$0"
  _ok()   { echo "adhoc-visual-evidence: $1 PASS"; pass=$((pass+1)); }
  _fail() { echo "adhoc-visual-evidence: $1 FAIL${2:+ — $2}"; fail=$((fail+1)); }

  # A repo with one commit on master and a checked-out feature branch, so
  # `master...HEAD` is a real PR-shaped diff rather than an empty one.
  _mk_repo() {
    local td; td=$(mktemp -d)
    git -C "$td" init -q -b master >/dev/null 2>&1
    git -C "$td" config user.email t@t; git -C "$td" config user.name t
    mkdir -p "$td/Views"
    printf 'a\n' > "$td/README.md"
    git -C "$td" add -A >/dev/null 2>&1
    git -C "$td" commit -qm base >/dev/null 2>&1
    git -C "$td" checkout -q -b feature >/dev/null 2>&1
    printf '%s' "$td"
  }

  # ---- t1: a docs-only diff emits nothing (the false-positive gate)
  local d1; d1=$(_mk_repo)
  printf 'b\n' >> "$d1/README.md"
  git -C "$d1" commit -qam docs >/dev/null 2>&1
  local o1; o1=$(WORKSPACE_ROOT="$d1" BASE_REF="master" bash "$self" --emit pr 2>/dev/null)
  if [ -z "$o1" ] && grep -q '"reason":"no_ui_surface"' "$d1/.context/logs/audit.jsonl" 2>/dev/null; then
    _ok "t1-docs-only-silent"
  else
    _fail "t1-docs-only-silent" "out='${o1:0:60}'"
  fi
  rm -rf "$d1"

  # ---- t2/t3/t4 and t2b own their PATH, so every host runs both arms: the host's
  # silicon/magick/convert are filtered out (a broken host tool must not pick or fail
  # an arm), and a PNG-writing silicon stub stands in for a working tool.
  # `read -a` splits without glob expansion. An empty entry is dropped: it means "cwd",
  # which shifts with every cd the child makes. A relative entry is pinned to its
  # physical absolute path, so the farm's symlinks cannot dangle.
  _toolless_path() { # $1=scratch dir; prints $PATH minus every silicon/magick/convert
    local root="$1" out='' dir n=0 farm entries=()
    IFS=: read -r -a entries <<< "$PATH"
    for dir in ${entries[@]+"${entries[@]}"}; do
      [ -n "$dir" ] && [ -d "$dir" ] || continue
      case "$dir" in
        /*) ;;
        *) dir=$(cd -- "$dir" 2>/dev/null && pwd -P) || continue ;;
      esac
      if [ -e "$dir/silicon" ] || [ -e "$dir/magick" ] || [ -e "$dir/convert" ]; then
        n=$((n+1)); farm="$root/farm$n"; mkdir -p "$farm"
        ln -s "$dir"/* "$farm"/ 2>/dev/null
        rm -f "$farm/silicon" "$farm/magick" "$farm/convert"
        dir="$farm"
      fi
      out="${out:+$out:}$dir"
    done
    printf '%s' "$out"
  }
  local st_tmp tl_path st_saved_traps st_caller_exit='' st_exit_cmd
  st_tmp=$(mktemp -d)
  # Captured before overriding so the caller's own handlers come back afterwards;
  # `$(trap -p ...)` reports the parent shell's traps, Bash 3.2 included.
  st_saved_traps=$(trap -p EXIT INT TERM)
  # trap -p prints `trap -- '<cmd>' EXIT` with <cmd> shell-quoted as one word, so the
  # third word is the caller's EXIT command verbatim.
  # shellcheck disable=SC2329  # invoked through the eval below
  _st_take_exit_cmd() { st_caller_exit="${3:-}"; }
  eval "_st_take_exit_cmd $(trap -p EXIT)"
  # The path is baked in with %q: the trap may fire after this function's locals unwind.
  # The caller's EXIT command is chained after the cleanup, so an exit inside this window
  # still runs it. `(exit N) && :` hands it the real $? without tripping a caller's set -e:
  # a failure that is not the last command of an && list does not trigger errexit. `|| :`
  # keeps a failed removal from ending the trap under set -e before the chained command.
  st_exit_cmd="_st_rc=\$?; rm -rf -- $(printf '%q' "$st_tmp") || :"
  [ -n "$st_caller_exit" ] \
    && st_exit_cmd="$st_exit_cmd; (exit \"\$_st_rc\") && :"$'\n'"$st_caller_exit"
  # INT/TERM route through exit so the EXIT trap does the one cleanup.
  # shellcheck disable=SC2064  # expand now, deliberately
  trap "$st_exit_cmd" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  tl_path=$(_toolless_path "$st_tmp")
  mkdir -p "$st_tmp/png-tool"
  # Drains stdin: cli-fallback pipes the diff in under pipefail.
  # shellcheck disable=SC2016  # the stub body expands when the stub runs, not here
  printf '%s\n' '#!/bin/sh' 'cat > /dev/null; out=""' \
    'while [ "$#" -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done' \
    '[ -n "$out" ] && printf "\211PNG\r\n\032\nselftest" > "$out"' > "$st_tmp/png-tool/silicon"
  chmod +x "$st_tmp/png-tool/silicon"

  local d2; d2=$(_mk_repo)
  printf 'body { color: red }\n' > "$d2/Views/app.css"
  git -C "$d2" add -A >/dev/null 2>&1; git -C "$d2" commit -qm ui >/dev/null 2>&1
  local o2
  o2=$(PATH="$st_tmp/png-tool:$tl_path" WORKSPACE_ROOT="$d2" BASE_REF="master" \
       ASSET_HOST_MODE=none DRY_RUN=1 bash "$self" --emit pr 2>/dev/null)

  {
    if printf '%s' "$o2" | grep -q '^## Visual evidence' \
       && ! printf '%s' "$o2" | grep -qE '\]\(\)|\]\(\.context/'; then
      _ok "t2-ui-emits-block"
    else
      _fail "t2-ui-emits-block" "$(printf '%s' "$o2" | head -6 | tr '\n' '~')"
    fi

    # ---- t3: rerun replays the cache instead of stacking a second capture
    local o3 caps
    o3=$(PATH="$st_tmp/png-tool:$tl_path" WORKSPACE_ROOT="$d2" BASE_REF="master" \
         ASSET_HOST_MODE=none DRY_RUN=1 bash "$self" --emit pr 2>/dev/null)
    caps=$(find "$d2/.context/images" -type f -name 'dv-*' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$o3" = "$o2" ] && [ "$caps" = "1" ]; then
      _ok "t3-idempotent"
    else
      _fail "t3-idempotent" "caps=$caps same=$([ "$o3" = "$o2" ] && echo y || echo n)"
    fi

    # ---- t4: manifest satisfies the attacher's own schema check
    local mf; mf=$(find "$d2/.context/images" -name screenshots-AD0.md 2>/dev/null | head -1)
    if bash "$ATTACHER" --validate-manifest "$mf" --task-id AD0 >/dev/null 2>&1; then
      _ok "t4-manifest-schema"
    else
      _fail "t4-manifest-schema" "$(bash "$ATTACHER" --validate-manifest "$mf" 2>&1 | head -2 | tr '\n' '~')"
    fi
  }
  rm -rf "$d2"

  # ---- t2b: no image tool → no capture is CLAIMED: exit 2 must never read as success,
  # and no manifest row may name a .png that does not exist.
  d2=$(_mk_repo)
  printf 'body { color: red }\n' > "$d2/Views/app.css"
  git -C "$d2" add -A >/dev/null 2>&1; git -C "$d2" commit -qm ui >/dev/null 2>&1
  o2=$(PATH="$tl_path" WORKSPACE_ROOT="$d2" BASE_REF="master" ASSET_HOST_MODE=none DRY_RUN=1 \
       bash "$self" --emit pr 2>/dev/null)
  {
    local ghost=0 mf2 mfdir
    mf2=$(find "$d2/.context/images" -name screenshots-AD0.md 2>/dev/null | head -1)
    if [ -n "$mf2" ]; then
      mfdir=$(dirname "$mf2")
      while IFS='|' read -r _ _ _ pth _; do
        pth=$(printf '%s' "$pth" | tr -d ' ')
        case "$pth" in
          dv-*) [ -e "$mfdir/$pth" ] || ghost=1 ;;
        esac
      done < "$mf2"
    fi
    if [ "$ghost" -eq 0 ] && [ -z "$o2" ]; then
      _ok "t2b-no-tool-manifests-no-ghost-row"
    else
      _fail "t2b-no-tool-manifests-no-ghost-row" "ghost=$ghost out='$(printf '%s' "$o2" | head -3 | tr '\n' '~')'"
    fi
  }
  rm -rf "$d2" "$st_tmp"
  # Reset first: a signal the caller left at default prints nothing in trap -p.
  trap - EXIT INT TERM
  eval "$st_saved_traps"

  # ---- t5: a worktask tree is refused, leaving FN's attachment the only one
  local d5; d5=$(_mk_repo)
  printf 'x\n' > "$d5/Views/app.css"
  git -C "$d5" add -A >/dev/null 2>&1; git -C "$d5" commit -qm ui >/dev/null 2>&1
  mkdir -p "$d5/.context"
  printf '{"version":1,"worktask_id":"wid-real","run_index":0}' > "$d5/.context/state.json"
  local o5; o5=$(WORKSPACE_ROOT="$d5" BASE_REF="master" bash "$self" --emit pr 2>/dev/null)
  if [ -z "$o5" ] && grep -q '"reason":"worktask_path"' "$d5/.context/logs/audit.jsonl" 2>/dev/null; then
    _ok "t5-worktask-refused"
  else
    _fail "t5-worktask-refused" "out='${o5:0:60}'"
  fi
  rm -rf "$d5"

  # ---- t7: a PNG capture renders as a hosted embed, not a bullet. Seeded on
  # disk because neither silicon nor ImageMagick is a suite prerequisite.
  local d7; d7=$(_mk_repo)
  printf 'x\n' > "$d7/Views/app.css"
  git -C "$d7" add -A >/dev/null 2>&1; git -C "$d7" commit -qm ui >/dev/null 2>&1
  mkdir -p "$d7/.context/images/adhoc-feature"
  printf 'x' > "$d7/.context/images/adhoc-feature/dv-AD0-01-pr-diff.png"
  local o7
  o7=$(WORKSPACE_ROOT="$d7" BASE_REF="master" ADHOC_ID=adhoc-feature \
       ASSET_HOST_MODE=raw ASSET_OWNER_REPO=o/r ASSET_REF=main DRY_RUN=1 \
       bash "$self" --emit pr 2>/dev/null)
  if printf '%s' "$o7" | grep -q '^!\[dv-01 ad-hoc PR diff.*\](https://raw\.githubusercontent\.com/'; then
    _ok "t7-png-embeds"
  else
    _fail "t7-png-embeds" "$(printf '%s' "$o7" | head -6 | tr '\n' '~')"
  fi
  rm -rf "$d7"

  # ---- t6: outside a git repo, --emit is silent and --detect says so
  local d6; d6=$(mktemp -d)
  local o6 j6
  o6=$(WORKSPACE_ROOT="$d6" bash "$self" --emit pr 2>/dev/null)
  j6=$(WORKSPACE_ROOT="$d6" bash "$self" --detect 2>/dev/null)
  if [ -z "$o6" ] && printf '%s' "$j6" | grep -q '"visual_surface":false'; then
    _ok "t6-no-git-silent"
  else
    _fail "t6-no-git-silent" "out='${o6:0:40}' json='$j6'"
  fi
  rm -rf "$d6"

  echo "adhoc-visual-evidence: self-test summary — pass=$pass fail=$fail"
  [ "$fail" -eq 0 ]
}
