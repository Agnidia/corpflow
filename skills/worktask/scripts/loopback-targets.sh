#!/usr/bin/env bash
# @description loopback-targets.sh — selects the DV rows a gate loop-back replays.
#   A wrong narrow leaves a defect unreplayed; a wrong widen only costs re-runs. So the set
#   narrows to ONE stream only when the text the gate already wrote proves it.
#
#   Narrow rule: every entry of the gate artifact's `blockers[]` (DR/ST) or
#   `blocking_defects[]` (QA) names the same single candidate stream. An entry names stream S
#   when a whole token of its text is S's artifact basename (as a path tail), or a repo-relative
#   path equal to, or under a directory entry of, S's handoff `files_modified[]` (or
#   `files_touched[]`). Entries naming no stream or 2+ streams are unattributable.
#   Attribution is per entry: an entry that names exactly one stream narrows even if it also cites a path no stream lists.
#
#   Full set (every DV row in the closure) is the fallback for: no blockers, any unattributable
#   entry, 2+ distinct streams, a missing or unreadable gate artifact or stream artifact.
#   Candidates are only DV rows inside the gate's closure, so a basename naming a row outside
#   it cannot attribute.
#
# @arg --state <path>   ledger path (required)
# @arg --gate <ID>      gate task id, e.g. QA0 (required)
# @arg -h | --help      show this header
#
# @stdout  DV row ids to replay, one per line, ascending numeric order; nothing on exit != 0.
# @stderr  one line: loopback-targets: scope=<narrow|full> reason=<token>
# @exitcode 0  a set was printed
# @exitcode 2  usage error
# @exitcode 3  unresolved input: ledger unreadable, unknown gate id, or no DV row in the closure
#
# Minimum shell: bash 3.2+ (macOS default).

set -euo pipefail
IFS=$'\n\t'

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=frontmatter-lib.sh disable=SC1091
. "$_here/frontmatter-lib.sh"

die_usage() { printf >&2 'loopback-targets: %s\n' "$1"; exit 2; }
die_input() { printf >&2 'loopback-targets: %s\n' "$1"; exit 3; }

state="" gate=""
while [ $# -gt 0 ]; do
  case "$1" in
    --state) [ $# -ge 2 ] || die_usage "--state needs a value"; state="$2"; shift 2 ;;
    --gate) [ $# -ge 2 ] || die_usage "--gate needs a value"; gate="$2"; shift 2 ;;
    -h | --help) sed -n '2,/^# Minimum shell/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
[ -n "$state" ] && [ -n "$gate" ] || die_usage "--state and --gate are required"
command -v jq > /dev/null 2>&1 || die_input "jq not found"
jq -e '.tasks | type == "object"' "$state" > /dev/null 2>&1 \
  || die_input "ledger unreadable: $state"
jq -e --arg g "$gate" '.tasks[$g] != null' "$state" > /dev/null 2>&1 \
  || die_input "unknown gate id: $gate"

# Transitive blocked_by closure, DV rows only, ascending numeric.
dv_ids=$(jq -r --arg g "$gate" '
  def walk($seen; $stack):
    if ($stack | length) == 0 then $seen
    else ($stack[0]) as $id
      | if ($seen | index($id)) then walk($seen; $stack[1:])
        else walk($seen + [$id]; $stack[1:] + ((.tasks[$id].blocked_by // []) | map(select(type == "string")))) end
    end;
  walk([]; (.tasks[$g].blocked_by // []))
  | map(select(test("^DV[0-9]+$"))) | sort_by(.[2:] | tonumber) | .[]' "$state") || die_input "closure walk failed"
[ -n "$dv_ids" ] || die_input "no DV row in the closure of $gate"

emit() { # emit <scope> <reason> [ids...]
  local scope="$1" reason="$2"; shift 2
  printf >&2 'loopback-targets: scope=%s reason=%s\n' "$scope" "$reason"
  printf '%s\n' "$@"
  exit 0
}
# full <reason>: every closure row.
full() {
  local reason="$1" ids
  ids=$(printf '%s\n' "$dv_ids")
  printf >&2 'loopback-targets: scope=full reason=%s\n' "$reason"
  printf '%s\n' "$ids"
  exit 0
}

# One DV row: just the row, no attribution possible or needed.
if [ "$(printf '%s\n' "$dv_ids" | wc -l | tr -d ' ')" -eq 1 ]; then
  full single-dv-row
fi

root="$(cd "$(dirname "$state")/.." && pwd)"
resolve() { # resolve <artifact path from the ledger> -> readable file path or empty
  local p="$1"
  case "$p" in /*) [ -r "$p" ] && printf '%s' "$p"; return 0 ;; esac
  if [ -r "$root/$p" ]; then printf '%s' "$root/$p"
  elif [ -r "$(dirname "$state")/$(basename "$p")" ]; then printf '%s' "$(dirname "$state")/$(basename "$p")"
  fi
  return 0
}

# list_of <block-file> <key>... -> the first present list's items, one per line.
# Handles `key: [a, b]` flow lists and `- item` block lists. A block-list entry is every line
# from its dash to the next dash at the same indent, folded onto one line.
# Returns non-zero when the file or the parse fails, so callers widen instead of narrowing on a
# truncated list; an absent key is not a failure (empty output, exit 0).
list_of() {
  local f="$1"; shift
  local k
  [ -r "$f" ] || return 1
  for k in "$@"; do
    if grep -qE "^[[:space:]]*${k}:" "$f"; then
      awk -v key="$k" '
        function flush() { if (cur != "") print cur; cur = "" }
        !inl && match($0, "^[[:space:]]*" key ":") {
          match($0, "^[[:space:]]*"); kind = RLENGTH
          rest = $0; sub("^[[:space:]]*" key ":[[:space:]]*", "", rest)
          if (rest ~ /^\[/) {
            gsub(/^\[|\][[:space:]]*$/, "", rest)
            n = split(rest, a, ",")
            for (i = 1; i <= n; i++) { gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", a[i]); if (a[i] != "") print a[i] }
            exit
          }
          inl = 1; next
        }
        inl {
          if ($0 ~ /^[[:space:]]*$/) next
          match($0, /^[[:space:]]*/); ind = RLENGTH
          if (ind <= kind && $0 !~ /^[[:space:]]*-/) { flush(); exit }
          if (ind < kind) { flush(); exit }
          if ($0 ~ /^[[:space:]]*-[[:space:]]/ || $0 ~ /^[[:space:]]*-$/) {
            if (dash == "") dash = ind
            if (ind == dash) { flush(); cur = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", cur); next }
          }
          line = $0; sub(/^[[:space:]]+/, "", line); cur = cur " " line
        }
        END { flush() }' "$f" || return 1
      return 0
    fi
  done
  return 0
}

gate_art=$(jq -r --arg g "$gate" '.tasks[$g] | (.metadata.artifact // .artifact // "")' "$state") || full gate-artifact-unreadable
gate_file=""
[ -n "$gate_art" ] && gate_file=$(resolve "$gate_art")
[ -n "$gate_file" ] || full gate-artifact-missing

tmp=$(mktemp -d "${TMPDIR:-/tmp}/loopback-targets.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
corpflow_fm_block "$gate_file" > "$tmp/gate.fm" 2> /dev/null || full gate-frontmatter-unreadable
list_of "$tmp/gate.fm" blockers blocking_defects > "$tmp/blockers.txt" || full blockers-unreadable
[ -s "$tmp/blockers.txt" ] || full no-blockers

# Streams: {id, base, files[]} per candidate DV row.
: > "$tmp/streams.jsonl"
for id in $dv_ids; do
  art=$(jq -r --arg i "$id" '.tasks[$i] | (.metadata.artifact // .artifact // "")' "$state") || full stream-artifact-unreadable
  [ -n "$art" ] || full stream-artifact-missing
  base=$(basename "$art")
  f=$(resolve "$art")
  [ -n "$f" ] || full stream-artifact-missing
  corpflow_fm_block "$f" > "$tmp/dv.fm" 2> /dev/null || full stream-frontmatter-unreadable
  list_of "$tmp/dv.fm" files_modified files_touched > "$tmp/files.txt" || full stream-files-unreadable
  jq -cn --arg id "$id" --arg base "$base" --rawfile files "$tmp/files.txt" \
    '{id: $id, base: $base, files: ($files | split("\n") | map(select(. != "")))}' >> "$tmp/streams.jsonl" || full stream-json-failed
done

# Attribution in jq: whole-token matching, so `development-0-a.md` never matches inside
# `development-0-ab.md` and a path never matches a longer sibling filename.
result=$(jq -rn --rawfile b "$tmp/blockers.txt" --slurpfile s "$tmp/streams.jsonl" '
  def toks: [splits("[^A-Za-z0-9._/@+~-]+")] | map(sub("^\\./"; "") | sub("[.]+$"; "")) | map(select(. != ""));
  def under($t; $e): ($e | sub("^\\./"; "") | sub("/+$"; "")) as $d | ($d != "") and ($t == $d or ($t | startswith($d + "/")));
  ($b | split("\n") | map(select(. != ""))) as $entries
  | $s as $streams
  | [ $entries[] | toks as $t
      | [ $streams[] | . as $st
          | select( any($t[]; (. == $st.base) or endswith("/" + $st.base))
                    or any($t[]; . as $tk | any($st.files[]; under($tk; .))) )
          | .id ] ] as $named
  | if ($named | any(length != 1)) then "full unattributable-or-multi-stream"
    elif ($named | map(.[0]) | unique | length) == 1 then "narrow " + $named[0][0]
    else "full multiple-streams" end') || result="full attribution-failed"

case "$result" in
  "narrow "*) emit narrow single-stream "${result#narrow }" ;;
  "full "*) full "${result#full }" ;;
  *) full attribution-failed ;;
esac
