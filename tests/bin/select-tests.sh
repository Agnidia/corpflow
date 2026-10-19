#!/usr/bin/env bash
# select-tests.sh — argv, git and formatting for the change→test selection engine.
#
# All rule evaluation lives in tests/lib/select_lib.bash; this file adds the git
# changed-set, the >50% cap arithmetic and the record stream. The root is derived
# from BASH_SOURCE the way run-tests.sh derives it — plugin-root-refs.bats asserts
# by exact match which four .sh files may name the plugin-root variable, and this
# is not one of them.
#
# Exit: 0 a verdict was produced (including FULL and WIDE) · 1 usage · 2 crash
# (the runner falls back to the full suite) · 3 --self-test failed. The 64/65 band
# belongs to run-tests.sh alone.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"

# shellcheck source=../lib/select_lib.bash
. "$SELF_DIR/../lib/select_lib.bash"

MODE=""
BASE_REF=""
WIDE_PCT=50

usage() {
  cat >&2 <<'EOF'
usage: select-tests.sh --changed [--base <ref>] [--root <dir>]
       select-tests.sh --self-test
EOF
}

die_usage() { printf 'select-tests.sh: %s\n' "$1" >&2; usage; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --changed)   MODE=changed ;;
    --self-test) MODE=selftest ;;
    --base)      [ "$#" -ge 2 ] || die_usage "--base needs a value"; BASE_REF="$2"; shift ;;
    --root)      [ "$#" -ge 2 ] || die_usage "--root needs a value"; ROOT="$2"; shift ;;
    -h|--help)   usage; exit 1 ;;
    *)           die_usage "unknown arg '$1'" ;;
  esac
  shift
done
[ -n "$MODE" ] || die_usage "one of --changed or --self-test is required"

OUT_SELECT=""
OUT_CHANGED=""
OUT_NOTE=""
VERDICT=""
TRIGGER="-"
DETAIL="-"

note() { OUT_NOTE="${OUT_NOTE}NOTE	$1"$'\n'; }

emit_full() { VERDICT="FULL"; TRIGGER="$1"; DETAIL="$2"; }

# Resolve the diff base. A shallow clone or detached HEAD with no trustworthy base
# is F2, not a guess: guessing narrows the run silently.
resolve_base() {
  local ref
  if [ -n "$BASE_REF" ]; then
    git -C "$ROOT" rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null 2>&1 && { printf '%s' "$BASE_REF"; return 0; }
    return 1
  fi
  for ref in origin/master master HEAD~1; do
    git -C "$ROOT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 && { printf '%s' "$ref"; return 0; }
  done
  return 1
}

# Union of three sources, all --no-renames, emitted as `<status>\t<path>`.
# Each git call is redirected to a file and its status checked explicitly: under
# `while read < <(git …)` a failed git reads as "no changes", F6 never fires and
# the run silently narrows. Untracked files are the third source and are not
# optional — a brand-new hooks/foo.sh has no diff entry yet must still select the
# coverage gate that fires on it.
collect_changed() {
  local base="$1" tmp rc=0 st p
  tmp="$(mktemp "${TMPDIR:-/tmp}/selchg.XXXXXX")" || return 1

  git -C "$ROOT" diff -z --name-status --no-renames --diff-filter=ACMD "$base...HEAD" > "$tmp" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || { rm -f "$tmp"; return 1; }
  while IFS= read -r -d '' st && IFS= read -r -d '' p; do printf '%s\t%s\n' "$st" "$p"; done < "$tmp"

  git -C "$ROOT" diff -z --name-status --no-renames --diff-filter=ACMD HEAD > "$tmp" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || { rm -f "$tmp"; return 1; }
  while IFS= read -r -d '' st && IFS= read -r -d '' p; do printf '%s\t%s\n' "$st" "$p"; done < "$tmp"

  git -C "$ROOT" ls-files -z --others --exclude-standard > "$tmp" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || { rm -f "$tmp"; return 1; }
  while IFS= read -r -d '' p; do printf '?\t%s\n' "$p"; done < "$tmp"

  rm -f "$tmp"
  return 0
}

run_changed() {
  local base base_sha changed sel rec tag rest total selected pct

  command -v git >/dev/null 2>&1 || { emit_full F1 "git not available"; return 0; }
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || { emit_full F1 "not a git repository"; return 0; }

  base="$(resolve_base)" || { emit_full F2 "no resolvable base (tried origin/master, master, HEAD~1)"; return 0; }
  base_sha="$(git -C "$ROOT" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null)"

  changed="$(collect_changed "$base")" || { emit_full F2 "git could not compute a changed set against $base"; return 0; }
  changed="$(printf '%s' "$changed" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u)"
  [ -n "$changed" ] || { emit_full F6 "computed changed set is empty"; return 0; }

  OUT_CHANGED="$(printf '%s\n' "$changed" | sed 's/^/CHANGED	/')"$'\n'

  sel_context_init "$ROOT" || { printf 'select-tests.sh: cannot initialise context at %s\n' "$ROOT" >&2; exit 2; }

  sel=""
  while IFS=$'\t' read -r tag rest; do
    [ -n "$rest" ] || continue
    sel="${sel}$(sel_select_for_path "$rest" "$tag")"$'\n'
  done <<< "$changed"

  # The ALWAYS floor is added once per run, not per path: sel_select_for_path is
  # deliberately L3-free so M10 can assert a deleted row deselects its target
  # without ALWAYS noise. Folding it in here — before the FULL scan and the
  # provenance fold — is what makes the floor reach a SELECT record at all.
  sel="${sel}$(sel_always_set)"$'\n'

  while IFS= read -r rec; do
    case "$rec" in
      "FULL	"*)
        rest="${rec#FULL	}"
        emit_full "${rest%%	*}" "${rest#*	}"
        return 0
        ;;
    esac
  done <<< "$sel"

  # Provenance is comma-joined per file so M7 can falsify L1 degrading to
  # convention-only: the absence of L1:PATHREF on a multi-consumer script IS the bug.
  OUT_SELECT="$(printf '%s\n' "$sel" | awk -F'\t' '
    $1 == "BATS" && $2 != "" { key[$2]; prov[$2] = prov[$2] $3 ":" $4 "\n" }
    END {
      for (f in key) {
        n = split(prov[f], a, "\n"); delete seen; s = ""
        for (i = 1; i <= n; i++) if (a[i] != "" && !(a[i] in seen)) { seen[a[i]]; s = s (s == "" ? "" : ",") a[i] }
        print "SELECT\t" f "\t" s
      }
    }' | LC_ALL=C sort)"$'\n'

  total="$(sel_all_bats | grep -c . || true)"; total="${total:-0}"
  selected="$(printf '%s' "$OUT_SELECT" | grep -c '^SELECT	' || true)"; selected="${selected:-0}"

  VERDICT="SCOPED"
  if [ "$total" -gt 0 ]; then
    pct=$(( selected * 100 / total ))
    if [ "$pct" -gt "$WIDE_PCT" ]; then
      VERDICT="WIDE"; TRIGGER="CAP"
      DETAIL="selection is $selected/$total files (${pct}%), over the ${WIDE_PCT}% cap"
    fi
  fi

  OUT_NOTE="${OUT_NOTE}COUNT	$selected	$total"$'\n'
  OUT_NOTE="${OUT_NOTE}PHASE	bats	run	scoped"$'\n'
  OUT_NOTE="${OUT_NOTE}PHASE	swift	run	out of scope for selection"$'\n'
  OUT_NOTE="${OUT_NOTE}PHASE	python-skills	run	out of scope for selection"$'\n'
  OUT_NOTE="${OUT_NOTE}PHASE	python-harness	run	out of scope for selection"$'\n'
  OUT_BASE="BASE	$base	${base_sha:--}"
  return 0
}

OUT_BASE=""

render() {
  printf 'VERDICT\t%s\t%s\t%s\n' "$VERDICT" "$TRIGGER" "$DETAIL"
  [ -n "$OUT_BASE" ] && printf '%s\n' "$OUT_BASE"
  [ -n "$OUT_CHANGED" ] && printf '%s' "$OUT_CHANGED"
  [ -n "$OUT_SELECT" ] && printf '%s' "$OUT_SELECT"
  [ -n "$OUT_NOTE" ] && printf '%s' "$OUT_NOTE"
  return 0
}

self_test() {
  local wd rc=0 out passed=0 failed=0
  wd="$(mktemp -d "${TMPDIR:-/tmp}/selst.XXXXXX")" || return 3
  mkdir -p "$wd/tests/shell/hooks" "$wd/tests/shell/meta" "$wd/tests/selection" "$wd/agents" "$wd/hooks"
  printf '@test "a" {\n :\n}\n' > "$wd/tests/shell/hooks/widget.bats"
  printf '@test "a" {\n :\n}\n' > "$wd/tests/shell/meta/other.bats"
  printf 'x\n' > "$wd/agents/designer.md"
  printf '#!/bin/bash\n' > "$wd/hooks/widget.sh"
  printf 'agents/*.md\thooks/widget\tR01\tself-test row with a sufficiently long rationale\n' \
    > "$wd/tests/selection/matrix.tsv"

  sel_context_init "$wd" || return 3

  out="$(sel_select_for_path "agents/designer.md" M)"
  case "$out" in *"tests/shell/hooks/widget.bats"*) passed=$((passed + 1)) ;; *) echo "self-test: L2 row did not select its target" >&2; failed=$((failed + 1)); rc=1 ;; esac

  out="$(sel_select_for_path "hooks/widget.sh" M)"
  case "$out" in *"L1	CONV"*) passed=$((passed + 1)) ;; *) echo "self-test: convention resolution failed" >&2; failed=$((failed + 1)); rc=1 ;; esac

  out="$(sel_select_for_path "docs/new.md" M)"
  case "$out" in "FULL	F3	"*) passed=$((passed + 1)) ;; *) echo "self-test: unmatched path did not fail closed to F3" >&2; failed=$((failed + 1)); rc=1 ;; esac

  out="$(sel_select_for_path "hooks/widget.sh" D)"
  case "$out" in "FULL	F4	"*) passed=$((passed + 1)) ;; *) echo "self-test: delete under a fail-closed root did not yield F4" >&2; failed=$((failed + 1)); rc=1 ;; esac

  out="$(sel_select_for_path "agents/designer.md" D)"
  case "$out" in "FULL	"*) echo "self-test: agent-doc delete wrongly widened to FULL" >&2; failed=$((failed + 1)); rc=1 ;; *) passed=$((passed + 1)) ;; esac

  out="$(sel_select_for_path "run-tests.sh" M)"
  case "$out" in "FULL	F5	"*) passed=$((passed + 1)) ;; *) echo "self-test: foundation path did not yield F5" >&2; failed=$((failed + 1)); rc=1 ;; esac

  printf 'a\tb\tR02\tfive field row with a long enough rationale\textra\n' >> "$wd/tests/selection/matrix.tsv"
  out="$(sel_matrix_rows)"
  case "$out" in *"FULL	F7	"*) passed=$((passed + 1)) ;; *) echo "self-test: a 5-field row was not rejected as F7" >&2; failed=$((failed + 1)); rc=1 ;; esac

  sel_context_free
  rm -rf "$wd"
  [ "$rc" -eq 0 ] || { echo "select-tests.sh: self-test FAIL ($passed passed, $failed failed)"; return 3; }
  echo "select-tests.sh: self-test OK ($passed passed, $failed failed)"
  return 0
}

case "$MODE" in
  selftest) self_test; exit $? ;;
  changed)  run_changed || exit 2; render; exit 0 ;;
esac
