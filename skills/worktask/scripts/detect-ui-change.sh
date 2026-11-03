#!/usr/bin/env bash
# detect-ui-change.sh — deterministic UI-change detection for PL0.
#
# PL (product-manager) runs this against the draft plan as ADVISORY input: the
# planning model decides `metadata.requires_screenshots` (plan frontmatter +
# DV/QA task metadata + state.json) and may overrule the verdict in either
# direction, subject to the S1 floor. The flag drives dv-screenshot-capture and
# its completion gate.
# See skills/worktask/references/planning-tests.md § Required Metadata: Test Selection Gate.
#
# Usage:
#   detect-ui-change.sh <plan-file> [--platform <p>]
#   detect-ui-change.sh --path-classes
#   detect-ui-change.sh --ui-platforms
#   detect-ui-change.sh --self-test
#
# --path-classes prints the S4 UI path-class regex and exits 0, so a caller that
# classifies a git diff instead of a plan reads the vocabulary from its one owner
# rather than keeping a second copy free to drift. --ui-platforms does the same
# for the platforms S4 admits (apple|web|android).
#
# Output (stdout, single JSON line):
#   {"requires_screenshots": <bool>, "signals": ["S1",...], "rationale": "<one line>"}
#
# Contract:
#   - Exit 0 ALWAYS on the detection path. Any parse/IO error → emit
#     {"requires_screenshots": true, ..., "rationale": "...fail_safe_default"} and
#     still exit 0. The safe failure direction is toward capture (false positives
#     are cheap; a missed UI capture re-opens the original bug).
#   - ANY signal true ⇒ requires_screenshots: true (OR over S1..S4).
#
# Signals:
#   S1  plan frontmatter `ui_visual_check: true` (invariant: ui_visual_check ⇒ true)
#   S2  .context/designs/ contains figma-registry.md OR any *.png
#   S3  plan ## scope / ## requirements match the UI keyword set (word-boundary, -i)
#   S4  platform ∈ {apple,web,android} AND scope names UI path classes
#
# Advisory; the planner decides. The detector never downgrades on its own; S1 is
# the planner's hard floor, and an S2 hit with a `false` verdict needs a written
# reason in the plan.

set -u

PLATFORM=""
PLAN_FILE=""
# .context root for the S2 designs probe. Defaults beside the plan file's repo;
# overridable for self-tests via DESIGNS_DIR.
DESIGNS_DIR="${DESIGNS_DIR:-.context/designs}"

# UI keyword set (S3) — word-boundary, case-insensitive. Framework terms only:
# generic words fire on nearly every plan's prose. Bare `Compose` is omitted
# (matches "docker compose"); `Composable` and `Jetpack` cover Android Compose.
UI_KEYWORDS='SwiftUI|UIKit|AppKit|storyboard|xib|CSS|Composable|Jetpack|RecyclerView|ViewBinding|drawable'
# UI path classes (S4). Android resource dirs and the lowercase `ui/` package
# convention are listed explicitly — the match is case-sensitive, so `UI/` alone
# never matched an Android tree.
UI_PATH_CLASSES='Views/|Screens/|UI/|Components/|\.storyboard|\.xib|\.tsx|\.jsx|\.vue|\.svelte|\.css|\.scss|\.html|res/layout|res/drawable|res/values|res/menu|/ui/'
# Platforms S4 admits; also read by the DV escalation helper (one owner).
UI_PLATFORMS='apple|web|android'

emit() {
  # $1=bool ("true"/"false"), $2=signals-json-array, $3=rationale
  if command -v jq >/dev/null 2>&1; then
    jq -cn --argjson req "$1" --argjson sig "$2" --arg r "$3" \
      '{requires_screenshots:$req, signals:$sig, rationale:$r}'
  else
    # jq-absent floor: hand-rolled JSON (rationale never contains a quote here).
    printf '{"requires_screenshots":%s,"signals":%s,"rationale":"%s"}\n' "$1" "$2" "$3"
  fi
}

fail_safe() {
  # $1=rationale-suffix. Emit true + fail_safe_default, exit 0.
  emit true '["fail_safe"]' "UI-change detection error: $1; defaulting to true (fail_safe_default)"
  exit 0
}

# Extract the frontmatter `ui_visual_check` value (S1). Echoes true|false|"".
plan_ui_visual_check() {
  local plan="$1"
  awk '
    NR==1 && $0=="---" { fm=1; next }
    fm==1 && $0=="---" { exit }
    fm==1 && /^[[:space:]]*ui_visual_check[[:space:]]*:/ {
      v=$0; sub(/.*:[[:space:]]*/,"",v); sub(/[[:space:]]*#.*/,"",v); gsub(/[[:space:]"]+/,"",v)
      print tolower(v); exit
    }
  ' "$plan" 2>/dev/null
}

# Echo the body of ## scope and ## requirements sections (S3/S4 search corpus).
plan_ui_sections() {
  local plan="$1"
  awk '
    /^##[[:space:]]/ {
      h=tolower($0)
      inblk = (h ~ /^##[[:space:]]+(scope|requirements)([[:space:]]|$)/) ? 1 : 0
      next
    }
    inblk==1 { print }
  ' "$plan" 2>/dev/null
}

detect() {
  local plan="$1" platform="$2"
  [ -f "$plan" ] || fail_safe "plan file not readable: $plan"

  local signals=() req="false"

  # S1 — ui_visual_check: true (invariant).
  local uvc; uvc=$(plan_ui_visual_check "$plan")
  if [ "$uvc" = "true" ]; then
    signals+=("S1"); req="true"
  fi

  # S2 — design artifacts present.
  if [ -f "$DESIGNS_DIR/figma-registry.md" ] || \
     ls "$DESIGNS_DIR"/*.png >/dev/null 2>&1; then
    signals+=("S2"); req="true"
  fi

  local sections; sections=$(plan_ui_sections "$plan")

  # S3 — UI keyword match (word-boundary, case-insensitive) in scope/requirements.
  if printf '%s\n' "$sections" | grep -qiwE "$UI_KEYWORDS" 2>/dev/null; then
    signals+=("S3"); req="true"
  fi

  # S4 — platform ∈ {apple,web,android} AND scope names UI path classes.
  if printf '%s\n' "$platform" | grep -qxE "$UI_PLATFORMS" 2>/dev/null &&
     printf '%s\n' "$sections" | grep -qE "$UI_PATH_CLASSES" 2>/dev/null; then
    signals+=("S4"); req="true"
  fi

  # Build signals JSON array.
  local sig_json="[]"
  if [ "${#signals[@]}" -gt 0 ]; then
    if command -v jq >/dev/null 2>&1; then
      sig_json=$(printf '%s\n' "${signals[@]}" | jq -R . | jq -cs .)
    else
      local s out=""
      for s in "${signals[@]}"; do out="$out\"$s\","; done
      sig_json="[${out%,}]"
    fi
  fi

  local rationale
  if [ "$req" = "true" ]; then
    rationale="UI change detected (signals: ${signals[*]}); requires_screenshots=true"
  else
    rationale="No UI signal in plan scope/requirements (platform=$platform); requires_screenshots=false"
  fi
  emit "$req" "$sig_json" "$rationale"
}

# ---------- entrypoint ------------------------------------------------------
# Answered before the plan-file parser: readable in a tree with no plan.
if [ "${1:-}" = "--path-classes" ]; then
  printf '%s\n' "$UI_PATH_CLASSES"
  exit 0
fi

if [ "${1:-}" = "--ui-platforms" ]; then
  printf '%s\n' "$UI_PLATFORMS"
  exit 0
fi

if [ "${1:-}" = "--self-test" ]; then
  # Sourced HERE, not at the top: the harness is test code the production path
  # never runs. `[ -r ]` first, not a bare `.`: sourcing a missing file with the
  # `.` builtin is a special-builtin error that exits the shell immediately,
  # bypassing an `if ! . …` guard entirely.
  SELFTEST_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/detect-ui-change-selftest.sh"
  if [ -r "$SELFTEST_LIB_PATH" ]; then
    # shellcheck source=detect-ui-change-selftest.sh
    # shellcheck disable=SC1090
    . "$SELFTEST_LIB_PATH"
  else
    printf >&2 'detect-ui-change: self-test harness unreachable at %s — plugin install broken\n' \
      "$SELFTEST_LIB_PATH"
    exit 2
  fi
  run_self_tests || exit 2
  exit 0
fi

# Parse args: first non-flag = plan file; --platform <p>.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    --platform=*) PLATFORM="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) [ -z "$PLAN_FILE" ] && PLAN_FILE="$1"; shift ;;
  esac
done

[ -n "$PLAN_FILE" ] || fail_safe "no plan file argument"
detect "$PLAN_FILE" "$PLATFORM"
exit 0
