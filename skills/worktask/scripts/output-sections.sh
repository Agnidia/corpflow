#!/usr/bin/env bash
# @description output-sections.sh — renders each stage's artifact H2 set from the anchor
#   allow-list into generator-owned regions, so no agent brief or protocol table restates
#   the list by hand.
#
#   Regions are the bytes between two whole-line markers, one pair per key per file:
#     <!-- output-sections:begin <key> -->
#     <!-- output-sections:end <key> -->
#   Keys: `stage=<CODE>` at the end of agents/<agent>.md; `table=required-pl-dr`,
#   `table=required-sr-et` and `table=optional` in handoff-protocol.md.
#
# @arg --print [--stage <CODE>]  Rendered regions, markers included, on stdout.
# @arg --write                   Rewrite every drifted region. An agent with no region gets
#                                one appended; the protocol never gets an insert.
# @arg --check                   Exit 1 naming every drifted, missing, duplicated or
#                                unbalanced region.
# @arg --self-test               Built-in fixtures in a tempdir.
# @arg --root <repo>             Tree holding agents/ and the protocol (default: this
#                                plugin). The allow-list is always this script's sibling.
#
# @exitcode 0  Ok.
# @exitcode 1  Drift or a missing, duplicated or unbalanced region (`<file>: <key>: <defect>`).
# @exitcode 2  Usage error, or cache-lint.sh --allow-list cannot run.
#
# Minimum shell: bash 3.2+ (macOS default).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_LINT="$SCRIPT_DIR/cache-lint.sh"
PROTOCOL_REL="skills/worktask/references/contracts/artifact-anchors.md"
PROTOCOL_KEYS="table=required-pl-dr table=required-sr-et table=optional"

usage() {
  sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2
  exit 2
}

# The allow-list TSV, fetched once per run into $ALLOW.
load_allow_list() {
  ALLOW="$WORK/allow.tsv"
  if ! bash "$CACHE_LINT" --allow-list > "$ALLOW" 2> "$WORK/allow.err" || [ ! -s "$ALLOW" ]; then
    printf >&2 'output-sections: cache-lint.sh --allow-list cannot run: %s\n' \
      "$(head -1 "$WORK/allow.err" 2> /dev/null)"
    exit 2
  fi
}

# Shared by both renderers. DV is the one stage with a second on-disk name: each DV ledger task
# writes development-<N>-<stream>.md, so naming only development-N.md would send a stream run's
# reader to a file it never wrote (skills/worktask/references/contracts/artifact-map.md § DV fan-out — ledger tasks).
# shellcheck disable=SC2016  # awk source, not a shell expansion
AWK_ARTIFACT_NAME='function artifact_name(b) { return (b == "development") ? b "-<N>[-<stream>].md" : b "-N.md" }'

stages() {
  awk -F'\t' '$1 != "*" && !seen[$1]++ { print $1 }' "$ALLOW"
}

agent_file_for() {
  awk -F'\t' -v s="$1" '$1 == s { print $2; exit }' "$ALLOW"
}

render_stage() {
  awk -F'\t' -v s="$1" "$AWK_ARTIFACT_NAME"'
    function add(list, h) { return list (list == "" ? "" : ", ") "`## " h "`" }
    $1 == s {
      base = $3
      if ($4 == "required" || $4 == "universal") req = add(req, $5)
      else if ($4 == "optional") opt = add(opt, $5)
    }
    $1 == "*" { any = add(any, $5) }
    END {
      if (base == "") exit 3
      print "### Artifact anchors"
      print ""
      printf "`%s` carries only these H2 headings; nest every other heading as H3. ", artifact_name(base)
      printf "Generated from `cache-lint.sh` by `output-sections.sh --write` — never edit by hand. "
      printf "An Edit adding another H2 is denied; a Write lands and Post feedback asks for an Edit fix, never a re-Write. "
      printf "The stage gate (`handoff-harness.sh --validate-frontmatter`) fails a missing or unexpected H2, "
      print "`handoff:` over 200 discretionary tokens, or a non-`escalate` sweep stub lacking 2-4 `options[]`."
      print ""
      print "- Required: " req
      if (opt != "") print "- Optional for " s ": " opt
      if (any != "") print "- Optional in any stage: " any
    }' "$ALLOW"
}

# The required tables split after DR so each stays under the section-lint cap.
render_table() {
  awk -F'\t' -v key="$1" "$AWK_ARTIFACT_NAME"'
    $1 == "*" { next }
    !seen[$1]++ { order[++n] = $1; if (split_at == 0 && $1 == "DR") split_at = n }
    $4 == "required" { req[$1] = req[$1] (req[$1] == "" ? "" : ", ") "`## " $5 "`"; base[$1] = $3 }
    $4 == "optional" { opt[$1] = opt[$1] (opt[$1] == "" ? "" : ", ") "`## " $5 "`" }
    END {
      if (key == "table=optional") {
        print "| Stage | Optional H2 anchors |"
        print "|-------|---------------------|"
        for (i = 1; i <= n; i++) if (opt[order[i]] != "") printf "| %s | %s |\n", order[i], opt[order[i]]
        exit
      }
      print "| Stage | Artifact | Mandatory H2 anchors |"
      print "|-------|----------|-----------------------|"
      lo = (key == "table=required-pl-dr") ? 1 : split_at + 1
      hi = (key == "table=required-pl-dr") ? split_at : n
      for (i = lo; i <= hi; i++) printf "| %s | %s | %s |\n", order[i], artifact_name(base[order[i]]), req[order[i]]
    }' "$ALLOW"
}

render_key() {
  case "$1" in
    stage=*) render_stage "${1#stage=}" ;;
    table=*) render_table "$1" ;;
  esac
}

# region_state <file> <key> — prints ok|missing|duplicate|unbalanced.
region_state() {
  awk -v b="<!-- output-sections:begin $2 -->" -v e="<!-- output-sections:end $2 -->" '
    $0 == b { nb++; if (open) bad = 1; open = 1 }
    $0 == e { ne++; if (!open) bad = 1; open = 0 }
    END {
      if (nb == 0 && ne == 0) print "missing"
      else if (nb > 1 || ne > 1) print "duplicate"
      else if (bad || open || nb != ne) print "unbalanced"
      else print "ok"
    }' "$1"
}

region_body() {
  awk -v b="<!-- output-sections:begin $2 -->" -v e="<!-- output-sections:end $2 -->" '
    $0 == e { inr = 0 }
    inr { print }
    $0 == b { inr = 1 }' "$1"
}

# Temp copy with the target's mode, then rename, so a reader never sees a half-written brief.
replace_region() {
  local f="$1" key="$2" body="$3" tmp
  tmp="$(mktemp "$(dirname "$f")/.output-sections.XXXXXX")" || return 1
  if cp -p "$f" "$tmp" \
    && awk -v b="<!-- output-sections:begin $key -->" -v e="<!-- output-sections:end $key -->" -v bf="$body" '
      $0 == e { while ((getline l < bf) > 0) print l; close(bf); inr = 0 }
      !inr { print }
      $0 == b { inr = 1 }' "$f" > "$tmp" \
    && mv -f "$tmp" "$f"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

append_region() {
  local f="$1" key="$2" body="$3" tmp
  tmp="$(mktemp "$(dirname "$f")/.output-sections.XXXXXX")" || return 1
  if cp -p "$f" "$tmp" \
    && {
      cat "$f"
      [ -z "$(tail -c 1 "$f")" ] || printf '\n'
      printf '\n<!-- output-sections:begin %s -->\n' "$key"
      cat "$body"
      printf '<!-- output-sections:end %s -->\n' "$key"
    } > "$tmp" \
    && mv -f "$tmp" "$f"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# sync_one <mode> <file> <key> <appendable 0|1> — rc 1 on a reported defect.
sync_one() {
  local mode="$1" f="$2" key="$3" appendable="$4" rel state body
  rel="${f#"$ROOT"/}"
  if [ ! -f "$f" ]; then
    printf '%s: %s: file not found\n' "$rel" "$key" >&2
    return 1
  fi
  body="$WORK/body"
  render_key "$key" > "$body" || { printf '%s: %s: render failed\n' "$rel" "$key" >&2; return 1; }
  state="$(region_state "$f" "$key")"
  case "$state" in
    duplicate | unbalanced)
      printf '%s: %s: %s marker pair\n' "$rel" "$key" "$state" >&2
      return 1
      ;;
    missing)
      if [ "$mode" = write ] && [ "$appendable" = 1 ]; then
        append_region "$f" "$key" "$body" || { printf '%s: %s: write failed\n' "$rel" "$key" >&2; return 1; }
        printf 'output-sections: appended %s to %s\n' "$key" "$rel"
        return 0
      fi
      printf '%s: %s: missing region\n' "$rel" "$key" >&2
      return 1
      ;;
  esac
  region_body "$f" "$key" > "$WORK/current"
  cmp -s "$WORK/current" "$body" && return 0
  if [ "$mode" = write ]; then
    replace_region "$f" "$key" "$body" || { printf '%s: %s: write failed\n' "$rel" "$key" >&2; return 1; }
    printf 'output-sections: rewrote %s in %s\n' "$key" "$rel"
    return 0
  fi
  printf '%s: %s: drift (run output-sections.sh --write)\n' "$rel" "$key" >&2
  return 1
}

sync_all() {
  local mode="$1" rc=0 s key
  for s in $(stages); do
    sync_one "$mode" "$ROOT/agents/$(agent_file_for "$s").md" "stage=$s" 1 || rc=1
  done
  for key in $PROTOCOL_KEYS; do
    sync_one "$mode" "$ROOT/$PROTOCOL_REL" "$key" 0 || rc=1
  done
  [ "$rc" -eq 0 ] && [ "$mode" = check ] && printf 'output-sections: all regions match the allow-list\n'
  return "$rc"
}

print_regions() {
  local want="$1" s key
  for s in $(stages); do
    [ -z "$want" ] || [ "$want" = "$s" ] || continue
    printf '<!-- output-sections:begin stage=%s -->\n' "$s"
    render_stage "$s"
    printf '<!-- output-sections:end stage=%s -->\n' "$s"
  done
  [ -z "$want" ] || return 0
  for key in $PROTOCOL_KEYS; do
    printf '<!-- output-sections:begin %s -->\n' "$key"
    render_table "$key"
    printf '<!-- output-sections:end %s -->\n' "$key"
  done
}

self_test() {
  _SELFTEST_PASSED=0
  local td fx rc s
  td="$(mktemp -d "${TMPDIR:-/tmp}/output-sections-selftest.XXXXXX")"
  # shellcheck disable=SC2064  # the paths are fixed at set time on purpose
  trap "rm -rf '$td' '$WORK'" EXIT
  fx="$td/repo"
  mkdir -p "$fx/agents" "$fx/$(dirname "$PROTOCOL_REL")"
  awk -F'\t' '$1 != "*" && !seen[$2]++ { print $2 }' "$ALLOW" | while IFS= read -r agent; do
    printf '# %s\n\n## Handoff Protocol\n\nprose\n' "$agent" > "$fx/agents/$agent.md"
  done
  {
    printf '# Protocol\n'
    for s in $PROTOCOL_KEYS; do
      printf '\n<!-- output-sections:begin %s -->\n<!-- output-sections:end %s -->\n' "$s" "$s"
    done
  } > "$fx/$PROTOCOL_REL"

  _st() {  # <label> <want-rc> <args...>
    local label="$1" want="$2"
    shift 2
    rc=0
    bash "$0" --root "$fx" "$@" > "$td/out" 2>&1 || rc=$?
    [ "$rc" -eq "$want" ] || { printf 'self-test: %s: FAIL (rc=%s want=%s)\n' "$label" "$rc" "$want" >&2; cat "$td/out" >&2; exit 1; }
    printf 'self-test: %s: ok\n' "$label"
    _SELFTEST_PASSED=$((_SELFTEST_PASSED + 1))
  }

  _st "check fails on missing regions" 1 --check
  _st "write inserts every region" 0 --write
  _st "check passes after write" 0 --check
  cp "$fx/agents/developer.md" "$td/dev.before"
  _st "write is idempotent" 0 --write
  cmp -s "$td/dev.before" "$fx/agents/developer.md" \
    || { echo "self-test: idempotent write changed bytes: FAIL" >&2; exit 1; }
  # shellcheck disable=SC2016  # the backticks are fixture text, not a command substitution
  sed 's/^- Required: /- Required: `## planted`, /' "$fx/agents/developer.md" > "$td/x" && cat "$td/x" > "$fx/agents/developer.md"
  _st "hand edit is drift" 1 --check
  _st "write repairs drift" 0 --write
  printf '<!-- output-sections:begin stage=DV -->\n<!-- output-sections:end stage=DV -->\n' >> "$fx/agents/developer.md"
  _st "duplicate pair fails" 1 --check
  _st "write refuses a duplicate pair" 1 --write
  echo "self-test: ALL PASS ($_SELFTEST_PASSED passed, 0 failed)"
}

MODE=""
STAGE=""
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --print | --write | --check | --self-test) [ -z "$MODE" ] || usage; MODE="${1#--}"; shift ;;
    --stage) [ $# -ge 2 ] || usage; STAGE="$2"; shift 2 ;;
    --root) [ $# -ge 2 ] || usage; ROOT="$(cd "$2" 2> /dev/null && pwd)" || usage; shift 2 ;;
    -h | --help) usage ;;
    *) printf >&2 'output-sections: unknown argument: %s\n' "$1"; usage ;;
  esac
done
[ -n "$MODE" ] || usage
[ -z "$STAGE" ] || [ "$MODE" = print ] || usage

WORK="$(mktemp -d "${TMPDIR:-/tmp}/output-sections.XXXXXX")"
# shellcheck disable=SC2064  # the path is fixed at set time on purpose
trap "rm -rf '$WORK'" EXIT
load_allow_list

case "$MODE" in
  print)
    if [ -n "$STAGE" ] && ! stages | grep -qx -- "$STAGE"; then
      printf >&2 'output-sections: unknown stage: %s\n' "$STAGE"
      exit 2
    fi
    print_regions "$STAGE"
    ;;
  write | check) sync_all "$MODE" ;;
  self-test) self_test ;;
esac
