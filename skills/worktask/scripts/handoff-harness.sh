#!/usr/bin/env bash
# handoff-harness.sh — token-count + schema-validation harness for the
# handoff protocol (state.json + frontmatter + atomic write).
#
# Usage:
#   handoff-harness.sh [--out DIR]
#       Generates a synthetic state.json and 3 synthetic stage artifacts
#       (PL, AR, DV) under DIR (default: a tempdir). Constructs a "baseline"
#       prompt (full-file inlining) and a "new" prompt (state.json + anchors
#       only) for stages DV, DR, QA, DC, FN. Computes token counts using a
#       wc-words proxy (words × 1.33 ≈ cl100k_base tokens), prints a
#       per-stage diff table, and asserts ≥30% reduction on each. Exits 1
#       if any stage fails the threshold (AC-12).
#
#   handoff-harness.sh --self-test
#       Runs the above against built-in fixtures, then validates frontmatter
#       and state.json schemas using yq + jq. Exits 0 on pass.
#
#   handoff-harness.sh --validate-frontmatter <artifact.md> [--state <state.json>] [--strict]
#                      [--legacy-tests-executed]
#       Validates the artifact's `handoff:` frontmatter against the per-stage
#       required-field matrix. Exits 0 on pass, 1 on fail.
#
#       DV and QA carry tests_executed as a list, one entry per runner
#       invocation: [{runner, count, summary_line}]. A scalar fails.
#       --legacy-tests-executed (or CORPFLOW_LEGACY_TESTS_EXECUTED=1) validates
#       a legacy scalar count with its top-level test_summary_line under the
#       integer rules instead, printing one deprecation warn. The opt-in is
#       deprecated but still accepted. A map never validates.
#
#       --state adds the AR->DV architecture-reference gate: when the artifact
#       is a DV handoff and the state ledger has a tasks.AR<N> entry, the
#       architecture reference (refs.decisions, then architecture.ref -- the
#       same precedence stage-contracts.md#tpl-dv and the DR rule declare)
#       must match ^architecture-[0-9]+\.md(#[a-z-]+)?$ and
#       resolve to a file beside the artifact. Without --state the check does
#       not run at all and behaviour is unchanged.
#
#       --strict turns gate violations from `warn:` + exit 0 into `fail:` +
#       exit 1. Equivalent env opt-in: CORPFLOW_AR_REF_STRICT=1, which the
#       orchestrator honours when deciding whether to pass --strict. The gate
#       is warn-only by default and blocks only under --strict, so treat
#       warnings as work to do now.
#
#       The inverse guard (an architecture reference with no tasks.AR<N> entry)
#       always warns and never fails, in either mode.
#
#       On an AR artifact, a consult line (an `## <Platform> App Architecture` section or a
#       sibling *-architecture.md) that cites a key_decisions id and contradicts it prints one
#       `warn: consult ...` line. It never changes the exit status, --strict included.
#
#       The artifact's H2 set is checked for every stage against cache-lint.sh
#       --anchor-diff (missing required or unexpected H2 = one `fail:` line each), in both
#       modes and with or without yq; an unreachable lint fails the gate.
#
#       The three closing-sweep checks (stub shape, ref anchor, ledger parity)
#       ride on the same invocation for EVERY stage and hard-fail in both modes.
#       Ledger parity needs --state; when --state is unreadable and the artifact
#       carries a sweep stub it fails rather than skips.
#
#       Exception: an unreadable --state (file missing, jq unavailable, or
#       invalid JSON) is itself a gate violation, not a silent skip -- it
#       warns by default and fails under --strict (exit 1), like the gate's
#       other violations. A state file we cannot read is not evidence AR didn't run.
#
#       A handoff.blocked_on fails the same way with or without yq: an unknown kind, an
#       unknown resume_with, or a missing or empty detail each print one `fail:` line and
#       exit 1. The enums are blocked-on-lib.sh's.
#
#   handoff-harness.sh --read-blocked-on <artifact.md>
#       Prints the artifact's need normalized through blocked-on-lib.sh as one compact JSON
#       line, then `source: blocked_on`.
#       Exits 1 when the artifact carries none, or its frontmatter cannot be read; 2 without
#       jq. Without yq every scalar is read as a string.
#
#   handoff-harness.sh --validate-state <state.json>
#       Validates the ledger against the schema (required keys, ≤500 token
#       proxy, atomic-write idempotency check by re-merging the same patch).
#       Exits 0 on pass, 1 on fail.
#
# Tokenizer proxy: wc-words × 1.33 — enough, because the ≥30% gate is a RELATIVE reduction.

set -euo pipefail

OUT_DIR=""
MODE="run"
ARG=""
STATE_ARG=""
# Env opt-in is read here so the gate is strict even when an older orchestrator
# forgets the --strict flag; --strict alone can only turn it on.
STRICT=0
if [[ "${CORPFLOW_AR_REF_STRICT:-0}" == "1" ]]; then STRICT=1; fi
# Same posture for the legacy scalar read: the env can only turn it on, so an
# orchestrator that drops the flag cannot silently re-enable a scalar count.
LEGACY_TE=0
if [[ "${CORPFLOW_LEGACY_TESTS_EXECUTED:-0}" == "1" ]]; then LEGACY_TE=1; fi

usage() {
  sed -n 's/^# \{0,1\}//p' "$0" | sed -n '1,/^$/p'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --out) shift; OUT_DIR="${1:-}"; shift ;;
    --self-test) MODE="self-test"; shift ;;
    --validate-frontmatter) MODE="validate-fm"; shift; ARG="${1:-}"; shift ;;
    --validate-state) MODE="validate-state"; shift; ARG="${1:-}"; shift ;;
    --read-blocked-on) MODE="read-bo"; shift; ARG="${1:-}"; shift ;;
    --state) shift; STATE_ARG="${1:-}"; shift ;;
    --strict) STRICT=1; shift ;;
    --legacy-tests-executed) LEGACY_TE=1; shift ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

# ---------- Token counter (wc-words × 1.33 proxy) ----------
toks() {
  local f="$1"
  local words
  words=$(wc -w < "$f" | tr -d ' ')
  awk -v w="$words" 'BEGIN { printf "%d", w * 1.33 }'
}

# Tokens spent on one handoff key's block alone, for the AD-2 discretionary budget.
# Measured over the SAME source text `toks` counts — the frontmatter as written, not a
# re-emitted copy — so the subtraction is exact rather than an estimate of a re-render.
# The block runs from the `<key>:` line to the next line indented no deeper, which is how
# YAML already delimits it; a file without the key yields 0.
toks_key_block() {  # <file> <key>
  local f="$1" key="$2" words
  words=$(awk -v key="$key" '
    !inblock && $0 ~ ("^[[:space:]]*" key ":") {
      match($0, /^[[:space:]]*/); indent = RLENGTH; inblock = 1; print; next
    }
    inblock {
      if ($0 ~ /^[[:space:]]*$/) { print; next }
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= indent) { inblock = 0; next }
      print
    }' "$f" | wc -w | tr -d ' ')
  awk -v w="$words" 'BEGIN { printf "%d", w * 1.33 }'
}

toks_str() {
  local s="$1"
  local words
  words=$(printf '%s' "$s" | wc -w | tr -d ' ')
  awk -v w="$words" 'BEGIN { printf "%d", w * 1.33 }'
}

# ---------- Frontmatter validation ----------
PL_REQ="stage verdict summary refs key_decisions next_stage_focus open_questions"
AR_REQ="stage verdict summary refs key_decisions next_stage_focus open_questions"
TL_REQ="stage verdict summary refs next_stage_focus open_questions"
# R-2.1 — the changed-file list is capped structurally, not excluded from the budget: the
# observed failure was not stages running out of budget, it was each stage inventing its own
# truncation. One shape everywhere: the first FILES_TOUCHED_MAX repo-relative paths plus a
# single `+ <count> more` marker. Ten paths plus the marker measure 33 proxy tokens of the
# 200-token discretionary budget. Defined once here and in stage-contracts.md; the budget
# checker gains no second extractor and no second cap constant.
FILES_TOUCHED_MAX=10

DV_REQ="stage verdict summary refs files_touched next_stage_focus tests_executed open_questions"
DR_REQ="stage verdict summary refs key_decisions open_questions"
SR_REQ="stage verdict summary refs key_decisions open_questions"
QA_REQ="stage verdict summary refs files_touched key_decisions tests_executed open_questions"
DC_REQ="stage verdict summary refs files_touched open_questions"
RE_REQ="stage verdict summary refs files_touched key_decisions open_questions"
FN_REQ="stage verdict summary refs next_stage_focus files_touched open_questions"
ST_REQ="stage verdict summary refs key_decisions open_questions"
IR_REQ="stage verdict summary refs key_decisions next_stage_focus open_questions"
ET_REQ="stage verdict summary refs key_decisions open_questions"

required_for() {
  case "$1" in
    PL) echo "$PL_REQ" ;; AR) echo "$AR_REQ" ;; TL) echo "$TL_REQ" ;;
    DV) echo "$DV_REQ" ;; DR) echo "$DR_REQ" ;; SR) echo "$SR_REQ" ;;
    QA) echo "$QA_REQ" ;; DC) echo "$DC_REQ" ;; RE) echo "$RE_REQ" ;;
    FN) echo "$FN_REQ" ;; ST) echo "$ST_REQ" ;; IR) echo "$IR_REQ" ;;
    ET) echo "$ET_REQ" ;;
    *) echo "" ;;
  esac
}

# The SweepStub predicate is defined once, in sweep-stub-lib.sh, and enforced twice — here and
# in state-patch.sh --facts. A shape gate that cannot load its shape must not pass anything.
_SWEEP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sweep-stub-lib.sh"
if [ -r "$_SWEEP_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_SWEEP_LIB"
fi
if [ -z "${SWEEP_ID_RE:-}" ] || [ -z "${SWEEP_CLASS_ENUM:-}" ] || [ -z "${SWEEP_REF_RE:-}" ]; then
  echo "fail: sweep-stub-lib.sh unreachable at $_SWEEP_LIB — the sweep shape gate cannot run" >&2
  exit 1
fi

# One frontmatter reader across this tool and state-patch.sh. Fail closed for the same
# reason the sweep library does: a missing library under skills/ is a broken install.
# Sourced AFTER the sweep guard so a wholly broken install still reports the sweep library
# first, which is the message the cross-enforcer parity suite pins.
_FM_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/frontmatter-lib.sh"
if [ ! -r "$_FM_LIB" ]; then
  printf >&2 'fail: frontmatter-lib.sh unreachable at %s — the frontmatter reader cannot run\n' "$_FM_LIB"
  exit 1
fi
# shellcheck source=frontmatter-lib.sh
. "$_FM_LIB"

# Fail closed like the two libraries above: a gate that cannot scan for raw bytes must not
# hand yq an artifact it may silently truncate at a NUL.
_CB_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/control-byte-lib.sh"
if [ -r "$_CB_LIB" ]; then
  # shellcheck source=control-byte-lib.sh
  . "$_CB_LIB"
fi
if ! command -v cb_scan_file > /dev/null 2>&1; then
  printf >&2 'fail: control-byte-lib.sh unreachable at %s — the control-byte gate cannot run\n' "$_CB_LIB"
  exit 1
fi

# The blocked_on enums are the router's too; a gate reading its own copy would admit a need the
# router then refuses. Fail closed like the libraries above.
_BO_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/blocked-on-lib.sh"
if [ -r "$_BO_LIB" ]; then
  # shellcheck source=blocked-on-lib.sh
  . "$_BO_LIB"
fi
if ! command -v blocked_on_validate > /dev/null 2>&1; then
  printf >&2 'fail: blocked-on-lib.sh unreachable at %s — the blocked_on gate cannot run\n' "$_BO_LIB"
  exit 1
fi

# The no-yq reader of handoff.blocked_on: every CI host lacks yq, so this is the path the gate
# usually takes, and it must reach the same verdict as yq. It reads the YAML subset a stage
# writes — block mappings, flow mappings and sequences (JSON included), quoted and plain scalars,
# `|`/`>` block scalars — and prints {"blocked_on":<json|null>}. Exit 1 on a value it cannot
# parse, which the gate reports as a failure rather than reading as absent.
read -r -d '' _FM_BO_AWK << 'AWK' || true
function jstr(s,    i, c, o, n) {
  o = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") o = o "\\\\"
    else if (c == "\"") o = o "\\\""
    else if (c ~ /[[:cntrl:]]/) o = o " "
    else o = o c
  }
  return "\"" o "\""
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function scalar(s,    c, i, o, ch, nx) {
  s = trim(s); c = substr(s, 1, 1)
  if (c == "\"") {
    o = ""
    for (i = 2; i <= length(s); i++) {
      ch = substr(s, i, 1)
      if (ch == "\\") { nx = substr(s, i + 1, 1); o = o ((nx == "n") ? "\n" : ((nx == "t") ? "\t" : nx)); i++; continue }
      if (ch == "\"") break
      o = o ch
    }
    return jstr(o)
  }
  if (c == "'") {
    o = ""
    for (i = 2; i <= length(s); i++) {
      ch = substr(s, i, 1)
      if (ch == "'") { if (substr(s, i + 1, 1) == "'") { o = o "'"; i++; continue } break }
      o = o ch
    }
    return jstr(o)
  }
  sub(/[ \t]+#.*$/, "", s); s = trim(s)
  if (s == "" || s == "~" || s == "null" || s == "Null" || s == "NULL") return "null"
  return jstr(s)
}
function splitkey(line,    s, m, q) {
  s = line; sub(/^[ \t]+/, "", s)
  if (match(s, /^[A-Za-z0-9_.\/-]+:/)) {
    m = RLENGTH; KEY = substr(s, 1, m - 1)
  } else if (match(s, /^"[^"]*":/) || match(s, /^'[^']*':/)) {
    m = RLENGTH; KEY = substr(s, 2, m - 3)
  } else return 0
  # A key ends at a colon followed by a blank or the line end; `a:b` is a plain scalar.
  if (m < length(s) && substr(s, m + 1, 1) !~ /[ \t]/) return 0
  REST = trim(substr(s, m + 1))
  return 1
}
function fdepth(s,    i, c, d, qc) {
  d = 0; qc = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (qc != "") { if (c == "\\" && qc == "\"") { i++; continue } if (c == qc) qc = ""; continue }
    if (c == "\"" || c == "'") qc = c
    else if (c == "{" || c == "[") d++
    else if (c == "}" || c == "]") d--
  }
  return d
}
function fskip() { while (P <= length(S) && substr(S, P, 1) ~ /[ \t]/) P++ }
function fquoted(    qc, c, start) {
  qc = substr(S, P, 1); start = P; P++
  while (P <= length(S)) {
    c = substr(S, P, 1)
    if (qc == "\"" && c == "\\") { P += 2; continue }
    if (c == qc) { if (qc == "'" && substr(S, P + 1, 1) == "'") { P += 2; continue } P++; return substr(S, start, P - start) }
    P++
  }
  ERR = 1; return ""
}
function fkey(    c, start, t) {
  fskip(); c = substr(S, P, 1)
  if (c == "\"" || c == "'") { t = fquoted(); return substr(t, 2, length(t) - 2) }
  start = P
  while (P <= length(S) && substr(S, P, 1) != ":" && index(",{}[]", substr(S, P, 1)) == 0) P++
  return trim(substr(S, start, P - start))
}
function pflow(    c, out, first, key, v, start, cl) {
  fskip(); c = substr(S, P, 1)
  if (c == "{" || c == "[") {
    cl = (c == "{") ? "}" : "]"; P++; out = c; first = 1
    while (1) {
      fskip(); c = substr(S, P, 1)
      if (c == cl) { P++; return out cl }
      if (c == "") { ERR = 1; return "null" }
      if (cl == "}") {
        key = fkey(); if (ERR) return "null"
        fskip(); if (substr(S, P, 1) != ":") { ERR = 1; return "null" }
        P++; v = pflow(); if (ERR) return "null"
        out = out (first ? "" : ",") jstr(key) ":" v
      } else {
        v = pflow(); if (ERR) return "null"
        out = out (first ? "" : ",") v
      }
      first = 0
      fskip(); c = substr(S, P, 1)
      if (c == ",") { P++; continue }
      if (c == cl) { P++; return out cl }
      ERR = 1; return "null"
    }
  }
  if (c == "\"" || c == "'") { v = fquoted(); if (ERR) return "null"; return scalar(v) }
  start = P
  while (P <= length(S) && index(",}]", substr(S, P, 1)) == 0) P++
  return scalar(substr(S, start, P - start))
}
function isdash(s) { sub(/^[ \t]+/, "", s); return (s == "-" || s ~ /^-[ \t]/) }
# iskey: the value of a mapping key, which YAML lets open an indentless sequence at the key's own
# indent (`options:` then `- a`); a sequence item's empty value has no such form.
function inline_block(rest, k, ind, iskey,    c, j, o, first, fold, line, v) {
  if (rest == "" || rest ~ /^#/) return pblock(k + 1, ind, iskey)
  c = substr(rest, 1, 1)
  if (c == "{" || c == "[") {
    S = rest; j = k
    while (fdepth(S) > 0 && j < n) { j++; S = S " " T[j] }
    P = 1; v = pflow(); if (ERR) return "null"
    fskip(); if (P <= length(S) && substr(S, P, 1) != "#") { ERR = 1; return "null" }
    NX = j + 1; return v
  }
  if (rest ~ /^[|>][-+0-9]*[ \t]*(#.*)?$/) {
    fold = (c == ">"); o = ""; first = 1; j = k + 1
    while (j <= n && (T[j] ~ /^[ \t]*$/ || I[j] > ind)) {
      line = T[j]; sub(/^[ \t]+/, "", line)
      o = o (first ? "" : (fold ? " " : "\n")) line; first = 0; j++
    }
    NX = j; return jstr(o)
  }
  NX = k + 1
  return scalar(rest)
}
function pblock(start, pind, seqok,    j, ind, out, first, key, v, s, rest, col, pad, m) {
  j = start
  while (j <= n && B[j]) j++
  if (j > n || I[j] < pind || (I[j] == pind && !(seqok && isdash(T[j])))) { NX = j; return "null" }
  ind = I[j]; s = T[j]; sub(/^[ \t]+/, "", s)
  if (isdash(s)) {
    out = "["; first = 1
    while (j <= n) {
      if (B[j]) { j++; continue }
      s = T[j]; sub(/^[ \t]+/, "", s)
      if (I[j] != ind || !isdash(s)) break
      rest = substr(s, 2); match(rest, /^[ \t]*/); m = RLENGTH; rest = trim(rest)
      if (rest != "" && (isdash(rest) || splitkey(rest))) {
        # A `- key: v` or `- - v` item is a nested node whose indent is its content's column, so
        # the line is rewritten in place to that column and its continuation lines join it.
        col = ind + 1 + m; pad = ""
        while (length(pad) < col) pad = pad " "
        T[j] = pad rest; I[j] = col
        v = pblock(j, ind, 0)
      } else v = inline_block(rest, j, ind, 0)
      if (ERR) return "null"
      out = out (first ? "" : ",") v; first = 0; j = NX
    }
    NX = j; return out "]"
  }
  out = "{"; first = 1
  while (j <= n) {
    if (B[j]) { j++; continue }
    if (I[j] < ind) break
    if (I[j] > ind) { j++; continue }
    if (!splitkey(T[j])) { ERR = 1; return "null" }
    key = KEY; v = inline_block(REST, j, ind, 1); if (ERR) return "null"
    out = out (first ? "" : ",") jstr(key) ":" v; first = 0; j = NX
  }
  NX = j; return out "}"
}
{ sub(/\r$/, ""); n++; T[n] = $0; match($0, /^ */); I[n] = RLENGTH; B[n] = ($0 ~ /^[ \t]*(#.*)?$/) }
END {
  bo = "null"
  for (h = 1; h <= n; h++) if (T[h] ~ /^handoff:[ \t]*(#.*)?$/) break
  if (h <= n) {
    ci = -1
    for (k = h + 1; k <= n; k++) {
      if (B[k]) continue
      if (I[k] == 0) break
      if (ci < 0) ci = I[k]
      if (I[k] != ci || !splitkey(T[k])) continue
      if (KEY != "blocked_on") continue
      v = inline_block(REST, k, ci, 1)
      if (ERR) exit 1
      bo = v
      k = NX - 1
    }
  }
  printf "{\"blocked_on\":%s}\n", bo
}
AWK

# A yq failure inside a sweep check is a gate FAILURE, never a skip: the gate has no advisory
# tier, so a read that cannot be trusted must not yield a pass. First error line is surfaced.
_sweep_yq() {  # <expr> <fmfile>
  local out
  if ! out=$(yq eval "$1" "$2" 2>&1); then
    echo "fail: open_questions could not be read as sweep stubs — ${out%%$'\n'*}" >&2
    return 1
  fi
  printf '%s' "$out"
}

# ONE yq pass over the frontmatter, feeding all three sweep checks. This runs at every one
# of the thirteen stage boundaries, and the six separate `yq eval` processes it replaces
# each re-parsed the same file to answer one question about the same list.
#
# Still one select per defect, because yq v4 has no if/elif and a lumped rejection names no
# cause: the arms are concatenated into one array and splatted, each row tagged with the
# defect it evidences. The three predicates are SWEEP_ID_RE, SWEEP_CLASS_ENUM and
# SWEEP_REF_RE from sweep-stub-lib.sh — the same constants state-patch.sh --facts enforces,
# interpolated here and passed as jq arguments there, never re-stated in either place.
#
# The trailing STUB rows are the id/ref inventory the anchor and ledger-parity checks walk;
# they cover map items only, so those two never have to re-ask what shape an item was. FLAGS
# is a SECOND inventory rather than three more fields on STUB: check_sweep_ref_anchor splits a
# STUB row on its first space and takes the rest as the ref, so a widened row would silently
# hand it a ref with trailing junk.
_sweep_scan() {  # <fmfile> -> tagged rows on stdout
  local base='[.handoff.open_questions[]?] | to_entries | .[]'
  local classexpr="" cls
  for cls in $SWEEP_CLASS_ENUM; do
    classexpr="${classexpr:+$classexpr and }(.value.class // \"\") != \"$cls\""
  done
  # `tostring` on the id keeps a non-string id inside the bad-id arm rather than in yq's error path.
  local ismap='select(.value | type == "!!map")'
  _sweep_yq "(
      [\"TYPE \" + (.handoff.open_questions | type)]
    + [$base | select(.value | type != \"!!map\") | \"NONMAP \" + (.key | tostring)]
    + [$base | $ismap | select(((.value.id // \"\") | tostring) | test(\"$SWEEP_ID_RE\") | not) | \"BADID \" + (.key | tostring) + \" \" + ((.value.id // \"\") | tostring)]
    + [$base | $ismap | select($classexpr) | \"BADCLASS \" + (.key | tostring) + \" \" + ((.value.id // \"\") | tostring)]
    + [$base | $ismap | select(((.value.ref // \"\") | tostring) | test(\"$SWEEP_REF_RE\") | not) | \"NOREF \" + (.key | tostring) + \" \" + ((.value.id // \"\") | tostring)]
    + [$base | $ismap | select((.value.blocks_next_stage | tag) != \"!!bool\") | \"NOFLAG \" + (.key | tostring) + \" \" + ((.value.id // \"\") | tostring)]
    + [$base | $ismap | \"STUB \" + ((.value.id // \"\") | tostring) + \" \" + ((.value.ref // \"\") | tostring)]
    + [$base | $ismap | \"FLAGS \" + ((.value.id // \"\") | tostring) + \" \" + ((.value.class // \"\") | tostring) + \" \" + ((.value.blocks_next_stage // false) | tostring)]
  ) | .[]" "$1"
}

# Memoised per artifact: the three checks run back to back against one file, and a second
# scan would re-pay the parse this consolidation exists to remove.
_sweep_scan_for=""
_sweep_scan_out=""
_sweep_load() {  # <fmfile>
  [[ "$_sweep_scan_for" == "$1" ]] && return 0
  _sweep_scan_out=$(_sweep_scan "$1") || return 1
  _sweep_scan_for="$1"
  return 0
}

# Rows of one tag, with the tag stripped.
_sweep_rows() {  # <TAG>
  printf '%s' "$_sweep_scan_out" | sed -n "s/^$1 //p"
}

# THE shape gate for open_questions[]: the sweep stub is the only item shape the field
# accepts, so this runs first and the two checks below may assume every surviving item is a
# map carrying id/class/ref. A bare schema rejection names no cause, so each defect gets its
# own sentence. Offenders are addressed by index, the only identity a non-map item has.
check_sweep_stub_shape() {
  local fmfile="$1" rc=0 line
  local oqtype nonmap badid badclass noref noflag

  _sweep_load "$fmfile" || return 1

  # `[]?` in the scan silently yields nothing for a scalar, and the required-field loop only
  # asks for a non-empty value, so `open_questions: "none"` would otherwise pass every check.
  oqtype=$(_sweep_rows TYPE)
  case "$oqtype" in
    '!!seq' | '!!null') ;;
    *)
      echo "fail: open_questions is $oqtype, not a sequence — write open_questions: [] when there is nothing to elicit" >&2
      return 1 ;;
  esac

  nonmap=$(_sweep_rows NONMAP)
  badid=$(_sweep_rows BADID)
  badclass=$(_sweep_rows BADCLASS)
  noref=$(_sweep_rows NOREF)
  noflag=$(_sweep_rows NOFLAG)

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "fail: open_questions[$line] is not a sweep stub — every item is { id: sw-<TASK_ID>-<n>, class: decision|escalate, ref: \"<artifact>-N.md#elicitation-sweep\", blocks_next_stage: false }" >&2
    rc=1
  done <<< "$nonmap"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "fail: open_questions[${line%% *}] id \"${line#* }\" is not sw-<TASK_ID>-<n>" >&2
    rc=1
  done <<< "$badid"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "fail: sweep stub $(_sweep_label "$line") class is not $(printf '%s' "$SWEEP_CLASS_ENUM" | tr ' ' '|')" >&2
    rc=1
  done <<< "$badclass"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "fail: sweep stub $(_sweep_label "$line") carries no ref anchor — add ref: \"<artifact>-N.md#elicitation-sweep\" (an optional .md path plus one non-empty #anchor)" >&2
    rc=1
  done <<< "$noref"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "fail: sweep stub $(_sweep_label "$line") carries no blocks_next_stage — add blocks_next_stage: false (or true only if the next stage would build on a guess)" >&2
    rc=1
  done <<< "$noflag"
  return $rc
}

# "<index> <id>" -> the id when the item has one, else its positional address.
_sweep_label() {
  local id="${1#* }"
  [[ -n "$id" ]] && printf '%s' "$id" || printf 'open_questions[%s]' "${1%% *}"
}

# The stub's `ref` anchor is the SOLE transport of the options[] the FN gate renders —
# SweepStub carries none. A dangling anchor therefore has no failure arm anywhere in
# Step C: C.4 either skips the item or invents options, which is silent degradation of
# exactly the kind the ledger-parity check above exists to prevent. Verifying the FIELD
# exists is not enough; check_sweep_stub_shape's own error message hands the agent the
# literal to paste. An empty open_questions array walks nothing, so there is nothing to
# compare and the check is silent.
# An empty `open_questions: []` is a claim, not an absence: it says "I ran the sweep and had
# nothing to ask". Nothing distinguished that from a stage that never swept, which is the
# whole point of the rule — so the prose half is required exactly when the array half is
# empty, the mirror of the `ref` anchor already required when it is not.
#
# The heading alone is the check. Its CONTENT is the stage's explicit statement, and this
# gate does not read it: an anchor with an empty body is a stage that wrote the heading
# without thinking, which is a review problem rather than a mechanical one.
check_empty_sweep_prose() {
  local artifact="$1" fmfile="$2" oqtype rows

  oqtype=$(_sweep_rows TYPE)
  # Only a real sequence reaches this arm. A non-sequence is check_sweep_stub_shape's
  # failure and an ABSENT field is the required-field loop's, both already reported;
  # calling either one "empty" here would send the stage two failures for one slip.
  case "$oqtype" in
    '!!seq') ;;
    *) return 0 ;;
  esac
  rows=$(_sweep_rows STUB)
  [[ -z "$rows" ]] || return 0

  if ! grep -qE '^## +elicitation-sweep[[:space:]]*$' "$artifact"; then
    echo "fail: open_questions is empty but $(basename "$artifact") has no '## elicitation-sweep' heading — an empty array alone cannot tell 'swept, nothing to ask' from 'never swept'. Write the heading with the explicit statement (stage-contracts.md § Closing Elicitation Sweep)" >&2
    return 1
  fi
  return 0
}

check_sweep_ref_anchor() {
  local artifact="$1" fmfile="$2"
  local dir rows line id ref file anchor target
  dir=$(dirname "$artifact")
  _sweep_load "$fmfile" || return 1
  rows=$(_sweep_rows STUB)
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    id="${line%% *}"
    ref="${line#* }"
    [[ -n "$ref" && "$ref" != "$id" ]] || continue   # missing ref is check_sweep_stub_shape's failure
    anchor="${ref##*#}"
    file="${ref%%#*}"
    if [[ -z "$anchor" || "$anchor" == "$ref" ]]; then
      echo "fail: sweep stub $id ref \"$ref\" names no #anchor — it must point at the artifact heading carrying this item's options[]" >&2
      return 1
    fi
    target="$dir/$file"
    [[ -n "$file" ]] || target="$artifact"           # anchor-only ref resolves to this artifact
    # The per-stage templates spell the `refs:` rows `.context/<artifact>-N.md#…`, two lines
    # under a stub written `<artifact>-N.md#…`, so a ref that repeats the artifact's own
    # directory names the same file — not a nested one — and must not fail as missing.
    if [[ ! -f "$target" && "$file" == "$(basename "$dir")/"* ]]; then
      target="$dir/${file#*/}"
    fi
    if [[ ! -f "$target" ]]; then
      echo "fail: sweep stub $id ref \"$ref\" names a file that does not exist: $target" >&2
      return 1
    fi
    if ! grep -qE "^## +${anchor}[[:space:]]*\$" "$target"; then
      echo "fail: sweep stub $id ref \"$ref\" is dangling — $(basename "$target") has no '## $anchor' heading, so the FN gate has no options[] to render" >&2
      return 1
    fi
  done <<< "$rows"
  return 0
}

# A resolvable anchor proves only that the heading exists. What sits under it is what the
# FN gate renders, and a bare status note ("q", "done", "see below") renders as a prompt with
# nothing to pick, so the gate either skips the item or invents options. The item block must
# carry at least two options[] (`label:` entries). An escalate item is asked rather than chosen,
# so it may instead stand on an explicit question ending in `?`.
#
# The block runs from the first line in the anchor section naming the id to the next line
# that starts another item (a line opening on a different sw- id, optionally after `-`, `{`
# or `id:`), or the next `## ` heading. A mere mention such as "follow-up to sw-PL0-1" in a
# summary does not end the block. A missing file or heading is
# check_sweep_ref_anchor's failure and is skipped here so one slip yields one line. Unlike that
# check, every stub is reported: Step B.1 re-dispatches with the `fail:` lines verbatim, and a
# stage fixing one note at a time costs a round each.
check_sweep_item_body() {
  local artifact="$1" fmfile="$2"
  local dir rows flags line id ref file anchor target cls verdict where rc=0
  dir=$(dirname "$artifact")
  _sweep_load "$fmfile" || return 1
  rows=$(_sweep_rows STUB)
  flags=$(_sweep_rows FLAGS)
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    id="${line%% *}"
    ref="${line#* }"
    [[ -n "$ref" && "$ref" != "$id" ]] || continue
    anchor="${ref##*#}"
    file="${ref%%#*}"
    [[ -n "$anchor" && "$anchor" != "$ref" ]] || continue
    target="$dir/$file"
    [[ -n "$file" ]] || target="$artifact"
    if [[ ! -f "$target" && "$file" == "$(basename "$dir")/"* ]]; then
      target="$dir/${file#*/}"
    fi
    [[ -f "$target" ]] || continue
    cls=$(printf '%s\n' "$flags" | awk -v want="$id" '$1 == want { print $2; exit }')
    verdict=$(_sweep_item_verdict "$target" "$anchor" "$id" "$cls")
    where="'## $anchor' in $(basename "$target")"
    case "$verdict" in
      missing)
        echo "fail: sweep stub $id has no item under $where — write the full item there (summary, options[]) on lines that start by naming $id" >&2
        rc=1 ;;
      note)
        if [[ "$cls" == "escalate" ]]; then
          echo "fail: sweep stub $id is a status note, not a question — its item under $where has fewer than 2 options[] (label:) and no explicit question ending in '?'" >&2
        else
          echo "fail: sweep stub $id is a status note, not a question — its item under $where has fewer than 2 options[] (label:); only an escalate item may stand on a bare question" >&2
        fi
        rc=1 ;;
    esac
  done <<< "$rows"
  return $rc
}

# <file> <anchor> <id> <class> -> ok | note | missing | noanchor
# Values reach awk through ENVIRON, never `-v`: BSD awk rewrites backslash escapes in -v values.
# An id match must not run on into more digits, or sw-DV0-1 would claim sw-DV0-12's block.
_sweep_item_verdict() {
  _SIB_ANCHOR="$2" _SIB_ID="$3" _SIB_CLASS="$4" awk '
    function names_id(s,    i, nc) {
      while ((i = index(s, ID)) > 0) {
        nc = substr(s, i + length(ID), 1)
        if (nc !~ /[0-9]/) return 1
        s = substr(s, i + length(ID))
      }
      return 0
    }
    function starts_other(s,    t) {
      if (!match(s, /^[[:space:]]*(-[[:space:]]*)?([{][[:space:]]*)?(id:[[:space:]]*)?sw-[A-Z][A-Z][0-9]+-[0-9]+/)) return 0
      t = substr(s, RSTART, RLENGTH)
      sub(/.*sw-/, "sw-", t)
      return t != ID
    }
    BEGIN { ID = ENVIRON["_SIB_ID"]; ANCHOR = ENVIRON["_SIB_ANCHOR"]; CLS = ENVIRON["_SIB_CLASS"] }
    /^## / {
      insec = 0
      h = $0
      sub(/^## +/, "", h)
      sub(/[[:space:]]+$/, "", h)
      if (h == ANCHOR && !seen) { insec = 1; seen = 1 }
      next
    }
    !insec { next }
    inblk && starts_other($0) { inblk = 0 }
    !inblk && !found && names_id($0) { inblk = 1; found = 1 }
    inblk {
      s = $0
      labels += gsub(/(^|[^A-Za-z0-9_])label:/, "", s)
      if ($0 ~ /\?["\047]?[[:space:]]*$/ || $0 ~ /summary:[[:space:]]*"[^"]*\?"/ || $0 ~ /summary:[[:space:]]*\047[^\047]*\?\047/) q = 1
    }
    END {
      if (!seen) print "noanchor"
      else if (!found) print "missing"
      else if (labels >= 2) print "ok"
      else if (CLS == "escalate" && q) print "ok"
      else print "note"
    }
  ' "$1"
}

# state_unreadable_reason -> echoes why $STATE_ARG cannot be trusted, or nothing.
#
# Detection only. The two callers deliberately DISAGREE on the verdict — check_ar_ref
# downgrades to an advisory skip, check_sweep_ledger fails outright — so the verdict stays
# at the call site and only the three ways a ledger can be unusable are shared.
state_unreadable_reason() {
  if [[ ! -f "$STATE_ARG" ]]; then
    printf 'state file not found: %s' "$STATE_ARG"
  elif ! command -v jq > /dev/null 2>&1; then
    printf 'jq unavailable; cannot read %s' "$STATE_ARG"
  elif ! jq empty "$STATE_ARG" > /dev/null 2>&1; then
    printf 'state file is not valid JSON: %s' "$STATE_ARG"
  fi
}

# report_task_id_fallback <fmfile> <artifact> -> stderr note only; always returns 0.
#
# On a split stage an artifact without handoff.task_id leaves check_sweep_ledger to infer
# its task from stub prefixes, which cannot see a stub-less stream's items. That is worth
# saying, but it is not a sweep verdict: the sweep checks have no advisory tier, so the note
# lives here and the exit code stays whatever the checks decide.
report_task_id_fallback() {
  local fmfile="$1" artifact="${2:-}" stage_code stage_tasks
  [[ -r "$STATE_ARG" ]] || return 0
  [[ -z "$(corpflow_fm_field "$fmfile" task_id)" ]] || return 0
  stage_code=$(yq eval '.handoff.stage // ""' "$fmfile" 2> /dev/null || printf '')
  [[ -n "$stage_code" && "$stage_code" != "null" ]] || return 0
  stage_tasks=$(jq -r --arg st "$stage_code" \
      '(.tasks // {}) | keys[] | select(test("^" + $st + "[0-9]+$"))' \
    "$STATE_ARG" 2> /dev/null | grep -c . || true)
  if [[ "${stage_tasks:-0}" -ge 2 ]]; then
    echo "warn: $(basename "${artifact:-the artifact}") omits handoff.task_id while stage $stage_code has $stage_tasks tasks — parity falls back to stub prefixes" >&2
  fi
  return 0
}

# Sweep-stub ledger parity. The frontmatter stub and facts.open_questions[] are two
# transports with two writers and no derivation between them, so a stage that writes
# the stub but omits it from `state-patch.sh --facts` produces a schema-valid artifact
# whose sweep never reaches the FN gate. Fires only with --state, like check_ar_ref.
# No warn arm: the sweep obligation is strict (stage-contracts.md § Closing Elicitation
# Sweep), so a dropped item fails rather than whispers.
#
# An unreadable --state is a FAILURE here whenever there is a stub to compare, not a
# skip: check_ar_ref makes that case loud for DV only, and the other twelve stages
# would otherwise pass parity by never running it. An empty open_questions array leaves
# nothing to compare, so the check is silent.
check_sweep_ledger() {
  local fmfile="$1" artifact="${2:-}"
  local ids id missing unreadable divergent artname
  artname=$(basename "${artifact:-the artifact}")
  _sweep_load "$fmfile" || return 1
  ids=$(_sweep_rows STUB | sed 's/ .*//')

  # Reverse direction, scoped to THIS TASK. facts.open_questions[] accumulates across every
  # stage, and a split stage (DV0/DV1) shares one `.stage` slice, so the slice alone would
  # charge one stream with the other's stubs. The `sw-<TASK_ID>-` prefix is the task identity:
  # an artifact carrying stubs is charged only ids under its own prefixes; one with no stubs
  # is charged the stage slice only when tasks{} holds at most one task of that stage.
  #
  # Resolved items are excluded: a rework round re-emits only what is still open, so charging
  # it with an already-answered id fails the round, and Step B.1 reads that as missing_input
  # and burns a whole stage re-dispatch. A missing status reads as open, matching state-patch.sh.
  #
  # handoff.task_id, when set, IS the task identity and replaces the prefix inference: the
  # artifact is charged every open item of its own task whether or not it carries stubs. A
  # malformed id was already failed by validate_frontmatter, so it charges nothing here.
  local stage_code ledger_ids extra artifact_tasks stage_tasks task_id
  stage_code=$(yq eval '.handoff.stage // ""' "$fmfile" 2> /dev/null || printf '')
  task_id=$(corpflow_fm_field "$fmfile" task_id)
  ledger_ids=""
  if [[ -n "$stage_code" && "$stage_code" != "null" ]] && [[ -r "$STATE_ARG" ]] && [[ -n "$task_id" ]]; then
    if [[ "$task_id" =~ ^${stage_code}[0-9]+$ ]]; then
      # Only a readable `false` is a missing task; a ledger jq cannot parse is the unreadable
      # arm's to report, not a claim about tasks{}.
      local has_task
      has_task=$(jq -r --arg t "$task_id" '(.tasks // {}) | has($t)' "$STATE_ARG" 2> /dev/null || printf '')
      if [[ "$has_task" == "false" ]]; then
        echo "fail: handoff.task_id $task_id is not in tasks{}" >&2
        return 1
      fi
      # A sibling's valid id would charge that sibling's items and none of this stream's; a
      # stub under another prefix is the one trace of that mislabel the artifact itself holds.
      local foreign='' fid=''
      foreign=$(printf '%s\n' "$ids" | sed -n 's/^sw-\([A-Z][A-Z][0-9][0-9]*\)-[0-9][0-9]*$/& \1/p' \
        | awk -v t="$task_id" '$2 != t { print $1 }')
      if [[ -n "$foreign" ]]; then
        while IFS= read -r fid; do
          echo "fail: sweep stub $fid does not belong to handoff.task_id $task_id — stamp the task that asked it" >&2
        done <<< "$foreign"
        return 1
      fi
      ledger_ids=$(jq -r --arg st "$stage_code" --arg t "$task_id" '
          (.facts.open_questions? // [])
          | map(select((.stage // "") == $st and (.status // "open") != "resolved"))
          | .[].id // empty
          | select(startswith("sw-" + $t + "-"))' \
        "$STATE_ARG" 2> /dev/null || printf '')
    fi
  elif [[ -n "$stage_code" && "$stage_code" != "null" ]] && [[ -r "$STATE_ARG" ]]; then
    stage_tasks=$(jq -r --arg st "$stage_code" \
        '(.tasks // {}) | keys[] | select(test("^" + $st + "[0-9]+$"))' \
      "$STATE_ARG" 2> /dev/null | grep -c . || true)
    artifact_tasks=$(printf '%s\n' "$ids" \
      | sed -n 's/^sw-\([A-Z][A-Z][0-9][0-9]*\)-[0-9][0-9]*$/\1/p' | sort -u)
    if [[ -n "$artifact_tasks" ]]; then
      ledger_ids=$(jq -r --arg st "$stage_code" \
          --argjson tasks "$(printf '%s\n' "$artifact_tasks" | jq -R . | jq -sc .)" '
          (.facts.open_questions? // [])
          | map(select((.stage // "") == $st and (.status // "open") != "resolved"))
          | .[].id // empty
          | select(. as $i | $tasks | any(. as $t | $i | startswith("sw-" + $t + "-")))' \
        "$STATE_ARG" 2> /dev/null || printf '')
    else
      if [[ "${stage_tasks:-0}" -le 1 ]]; then
        ledger_ids=$(jq -r --arg st "$stage_code" '
            (.facts.open_questions? // [])
            | map(select((.stage // "") == $st and (.status // "open") != "resolved"))
            | .[].id // empty' \
          "$STATE_ARG" 2> /dev/null || printf '')
      fi
    fi
  fi

  # An empty artifact stub block used to be a silent pass — the one shape that hides a whole
  # stage's sweep. It is only a pass when the ledger holds nothing for this stage either.
  if [[ -z "$ids" ]] && [[ -z "$ledger_ids" ]]; then
    return 0
  fi

  if [[ -n "$ledger_ids" ]]; then
    extra=$(printf '%s\n' "$ledger_ids" | grep -vxF -f <(printf '%s\n' "$ids") 2> /dev/null || true)
    if [[ -n "$extra" ]]; then
      while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        echo "fail: sweep stub $id is in ledger, not in frontmatter — facts.open_questions[] carries it for stage $stage_code but $artname does not. Re-emit it in the artifact's open_questions[], or the two transports disagree about what this stage asked" >&2
      done <<< "$extra"
      return 1
    fi
  fi

  [[ -n "$ids" ]] || return 0

  unreadable=$(state_unreadable_reason)
  if [[ -n "$unreadable" ]]; then
    echo "fail: sweep ledger parity cannot be verified for $(echo "$ids" | tr '\n' ' ')— $unreadable" >&2
    return 1
  fi

  # One jq set difference, not one membership probe per id: the ledger is re-read and
  # re-parsed by every probe, and a sweep of any size pays that per item.
  #
  # 2>&1 into the same capture, like _sweep_yq: a ledger whose open_questions is a string
  # or a list of non-objects aborts jq mid-filter, and treating that exit as "nothing
  # missing" would pass the gate on exactly the shapes it exists to catch.
  # The ledger is not the whole record: the per-task question clamp spills unresolved evictions to
  # `open-questions-<run_index>.jsonl` (AD-4), and an item that legitimately reached the FN
  # gate through the spill must not read here as a dropped stub.  The path derives from the
  # ledger's own run_index — never guessed — and a MISSING spill contributes the empty set,
  # which is exactly today's behaviour for every run whose sweep never overflowed.
  local spill
  spill="$(dirname "$STATE_ARG")/open-questions-$(jq -r '.run_index // 0' "$STATE_ARG" 2> /dev/null || printf '0').jsonl"
  if [[ -e "$spill" ]] && ! jq -e -s 'type == "array"' "$spill" > /dev/null 2>&1; then
    # A spill that exists but cannot be parsed is a FAILURE, not an empty set: silently
    # treating a corrupt overflow file as "no items" restores the precise loss this check
    # exists to catch, and does it only in the runs that overflowed.
    echo "fail: sweep ledger parity cannot be verified for $(echo "$ids" | tr '\n' ' ')— spill file $spill is not readable as JSON lines" >&2
    return 1
  fi
  [[ -e "$spill" ]] || spill="/dev/null"

  if ! missing=$(printf '%s\n' "$ids" | jq -r -R -s --slurpfile st "$STATE_ARG" --rawfile sp "$spill" '
      ( ( ($st[0].facts.open_questions? // []) | map(.id) )
        + ( $sp | split("\n") | map(select(length > 0) | fromjson.id) ) ) as $have
      | split("\n") | map(select(length > 0 and . != "null"))
      | . - $have | .[]' 2>&1); then
    echo "fail: sweep ledger parity cannot be verified for $(echo "$ids" | tr '\n' ' ')— facts.open_questions in $STATE_ARG could not be read as an array of stubs: ${missing%%$'\n'*}" >&2
    return 1
  fi
  if [[ -n "$missing" ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      echo "fail: sweep stub $id is in the frontmatter but not in facts.open_questions[] — pass it in the state-patch.sh --facts payload, or the FN gate never sees it" >&2
    done <<< "$missing"
    return 1
  fi

  # Stub parity, not just id parity. The arm above catches an item that never reached the
  # ledger; this one catches an item that reached it carrying DIFFERENT values. Same two
  # transports, same absence of any derivation between them, and until this existed the only
  # cross-check was on id — so a stub saying `blocks_next_stage: false` beside a ledger entry
  # saying `true` validated clean, and the orchestrator read the ledger, joined raise-only and
  # held a boundary gate for an item its own author had marked non-blocking (OV-183).
  #
  # This is deliberately NOT a join: the two copies have ONE author, so a disagreement is a
  # defect and not a lattice (`skills/shared/stage-contracts.md § Self-labels raise, never
  # lower`). The harness refuses and names both values; reconciling is the agent's job, because
  # a harness that picked a winner would be guessing which copy the author meant.
  #
  # An absent flag normalises to `false` on BOTH sides, its documented default, so a legacy
  # ledger entry written before the field was required does not read as divergence.
  #
  # The LIVE ledger only — deliberately not the spill, which the id arm above does read. The
  # spill is an append-only record of what was evicted, never rewritten, so a re-emitted stub
  # legitimately disagrees with its own older eviction line; comparing against it would fail
  # rework rounds for doing exactly what the carry-forward contract asks. An item that exists
  # only in the spill has no live row to diverge from, so nothing is lost by skipping it.
  divergent=$(_sweep_rows FLAGS)
  [[ -n "$divergent" ]] || return 0
  # Every emitted field is non-empty — an absent ledger class prints as "(absent)" rather
  # than "" — because tab is IFS whitespace, so `read` would collapse an empty column and
  # silently shift every value after it into the wrong variable.
  if ! divergent=$(printf '%s\n' "$divergent" | jq -r -R -s --slurpfile st "$STATE_ARG" '
      def _norm: { class: (if (.class // "") == "" then "(absent)" else .class end),
                   flag: ((.blocks_next_stage // false) | tostring) };
      ( ( ($st[0].facts.open_questions? // []) | map({ key: .id, value: _norm }) )
        | from_entries ) as $have
      | split("\n") | map(select(length > 0))
      | map((. / " ") as $c | { id: $c[0], class: $c[1], flag: $c[2] })
      | map(select($have[.id] != null))
      | map(select(.class != $have[.id].class or .flag != $have[.id].flag))
      | .[] | [.id, .class, .flag, $have[.id].class, $have[.id].flag] | @tsv' 2>&1); then
    echo "fail: sweep stub parity cannot be verified for $(echo "$ids" | tr '\n' ' ')— facts.open_questions in $STATE_ARG could not be read as an array of stubs: ${divergent%%$'\n'*}" >&2
    return 1
  fi
  [[ -n "$divergent" ]] || return 0
  local fid fclass fflag lclass lflag
  while IFS=$'\t' read -r fid fclass fflag lclass lflag; do
    [[ -n "$fid" ]] || continue
    if [[ "$fflag" != "$lflag" ]]; then
      echo "fail: sweep stub $fid disagrees across transports — blocks_next_stage is $fflag in $artname but $lflag in facts.open_questions[]. Reconcile both to the intended value (the artifact is the author's copy); do not leave them divergent" >&2
    fi
    if [[ "$fclass" != "$lclass" ]]; then
      echo "fail: sweep stub $fid disagrees across transports — class is $fclass in $artname but $lclass in facts.open_questions[]. Reconcile both to the intended value (the artifact is the author's copy); do not leave them divergent" >&2
    fi
  done <<< "$divergent"
  return 1
}

# files_touched shape: at most FILES_TOUCHED_MAX paths, and any overflow declared by exactly
# one trailing `+ <count> more` marker. A list longer than the cap with no marker is the
# ad-hoc truncation this convention exists to replace — it reads as a complete set.
check_files_touched_cap() {  # <fmfile> <stage> <artname>
  local fmfile="$1" stage="$2" artname="$3"
  local entries markers paths last
  entries=$(yq eval '(.handoff.files_touched // []) | .[]' "$fmfile" 2> /dev/null || printf '')
  [[ -n "$entries" ]] || return 0
  markers=$(printf '%s\n' "$entries" | grep -cE '^\+ [0-9]+ more$' || true)
  paths=$(printf '%s\n' "$entries" | grep -vcE '^\+ [0-9]+ more$' || true)
  last=$(printf '%s\n' "$entries" | tail -1)

  if [[ "$markers" -gt 1 ]]; then
    echo "fail: stage=$stage files_touched carries ${markers} '+ <count> more' markers in $artname — emit exactly one, last" >&2
    return 1
  fi
  if [[ "$markers" -eq 1 ]] && ! printf '%s' "$last" | grep -qE '^\+ [0-9]+ more$'; then
    echo "fail: stage=$stage files_touched has a '+ <count> more' marker that is not the last entry in $artname" >&2
    return 1
  fi
  if [[ "$paths" -gt "$FILES_TOUCHED_MAX" ]]; then
    echo "fail: stage=$stage files_touched lists ${paths} paths > FILES_TOUCHED_MAX=${FILES_TOUCHED_MAX} in $artname — emit the first ${FILES_TOUCHED_MAX} plus one '+ <count> more' marker, and mark the body section carrying the full set authoritative in the same edit" >&2
    return 1
  fi
  return 0
}

# The decision comparator, shared by the body check (fail) and the consult check (warn) so the
# two cannot drift on what counts as a word. Run as
#   awk -v a=<statement> -v b=<statement> -v arms=<comma list> "$_DECISION_CMP_AWK"
# Exit 1 means the two conflict, with the reason on stdout; exit 0 means no enabled arm fired.
# Arms:
#   vocab     the two share no significant vocabulary at all;
#   digits    both quote numbers and no number is common (a restated bound or count);
#   polarity  one side holds `<prefix><stem>` and the other the bare stem (in+sensitive).
# Deliberately narrow. A frontmatter summary is a ≤160-char precis of a longer entry, so
# paraphrase is the NORM and an equality or high-overlap test would fail honest artifacts — a
# boundary-blocking false failure is worse than the divergence it would catch. Every arm
# reports a shape that means two different statements rather than two phrasings of one.
# Filenames are stripped BEFORE the split: `<stage>-<run_index>.md` would otherwise contribute
# its index as a bare digit, and the digits arm fires on an unmatched numeral. A digit counts
# only as a whole whitespace-delimited word — `newest-8` is a name, not a count. Residual: a
# bare `planning-0` carrying no extension survives the strip, and the whole-word rule covers it.
# POSIX awk only: BSD awk on macOS runs this, so no gensub, no \y, no arrays of arrays.
readonly _DECISION_CMP_AWK='
  function harvest(x, W, D,   i, n, w, m, t, tok) {
    x = tolower(x)
    gsub(/[a-z0-9_\/.-]+\.(md|yml|yaml|json|jsonl|sh|bats|txt|log)/, " ", x)
    m = split(x, t, /[ \t\n]+/)
    for (i = 1; i <= m; i++) {
      tok = t[i]
      sub(/^[^a-z0-9]+/, "", tok)
      sub(/[^a-z0-9]+$/, "", tok)
      if (tok ~ /^[0-9]+$/) D[tok] = 1
    }
    n = split(x, w, /[^a-z0-9]+/)
    for (i = 1; i <= n; i++) {
      if (w[i] == "") continue
      if (w[i] ~ /^[0-9]+$/) continue
      if (length(w[i]) >= 4) W[w[i]] = 1
    }
  }
  function on(arm) { return index("," arms ",", "," arm ",") > 0 }
  # An adverb and its adjective are one stem here: "sensitively" must meet "insensitive".
  function stems(W, S,   k, s) {
    for (k in W) {
      s = k
      if (length(s) >= 7 && substr(s, length(s) - 1) == "ly") s = substr(s, 1, length(s) - 2)
      S[s] = 1
    }
  }
  # A word w = p + r on side X conflicts when r stands bare on side Y, X never says r itself,
  # and Y never says w: then the two sides take opposite polarity on one stem. The r >= 5 floor
  # drops short accidental stems (in+put); a longer one (dis+patched) still needs "patched" bare
  # on the other side and "dispatched" absent from it. The warn names the pair, so a residual
  # false hit is cheap to dismiss.
  function polar(X, Y,   w, j, p, r) {
    for (w in X) {
      for (j = 1; j <= NP; j++) {
        p = PFX[j]
        if (substr(w, 1, length(p)) != p) continue
        r = substr(w, length(p) + 1)
        if (length(r) >= 5 && (r in Y) && !(r in X) && !(w in Y)) { HIT = r " vs " w; return 1 }
        break
      }
    }
    return 0
  }
  BEGIN {
    NP = split("non dis un in im ir il", PFX, " ")
    harvest(a, AW, AD); harvest(b, BW, BD)
    if (on("polarity")) {
      stems(AW, AS); stems(BW, BS)
      if (polar(AS, BS) || polar(BS, AS)) { print "polarity: " HIT; exit 1 }
    }
    if (on("vocab")) {
      for (k in AW) { ca++; if (k in BW) hit++ }
      for (k in BW) cb++
      if (ca > 0 && cb > 0 && hit == 0) { print "no shared vocabulary"; exit 1 }
    }
    if (on("digits")) {
      for (k in AD) { na++; if (k in BD) dhit++ }
      for (k in BD) nb++
      if (na > 0 && nb > 0 && dhit == 0) { print "numbers differ"; exit 1 }
    }
    exit 0
  }'

# key_decisions vs the body: the same id must not carry two different summaries. Until this
# existed the harness read the frontmatter slice alone, so a decision could be restated in the
# body with a different meaning and every downstream reader picked whichever copy it happened
# to open. Overlap-based, not equality: the frontmatter summary is a ≤160-char precis of a
# longer body entry, so a shared-vocabulary test is what distinguishes a precis from a
# contradiction. Silent when an id has no body entry — not every decision is restated.
check_decision_divergence() {  # <artifact> <fmfile> <stage>
  local artifact="$1" fmfile="$2" stage="$3"
  local rows body id fsum bsum artname
  artname=$(basename "$artifact")
  rows=$(yq eval '(.handoff.key_decisions // []) | .[] | ((.id // "") + "\t" + (.summary // ""))' \
    "$fmfile" 2> /dev/null || printf '')
  [[ -n "$rows" ]] || return 0
  body=$(mktemp "${TMPDIR:-/tmp}/handoff-body-XXXXXX")
  awk '/^---$/ { c++; next } c >= 2' "$artifact" > "$body"

  local failed=0
  while IFS=$'\t' read -r id fsum; do
    [[ -n "$id" && -n "$fsum" ]] || continue
    # Table row `| id | summary | ...`, bullet `- **id** — summary`, or bullet
    # `- **id — summary.**` (the form this repo's architecture artifacts use, against which
    # the check was inert); first hit wins. The third arm anchors its trim to the known id
    # rather than to a separator class, because leftmost-longest would eat an em-dash that
    # belongs to the summary.
    bsum=$(awk -v id="$id" '
      $0 ~ ("^[[:space:]]*\\|[[:space:]]*(\\*\\*)?" id "(\\*\\*)?[[:space:]]*\\|") {
        n = split($0, f, "|"); if (n >= 4) { print f[3]; exit }
      }
      $0 ~ ("^[[:space:]]*[-*][[:space:]]+\\*\\*" id "\\*\\*") {
        line = $0; sub(/^[^*]*\*\*[^*]*\*\*[[:space:]]*[-—:]*[[:space:]]*/, "", line)
        print line; exit
      }
      $0 ~ ("^[[:space:]]*[-*][[:space:]]+\\*\\*" id "[[:space:]]*[-—:]") {
        line = $0
        sub(/^[^*]*\*\*/, "", line)
        sub("^" id "[[:space:]]*[-—:]+[[:space:]]*", "", line)
        sub(/\*\*[[:space:]]*$/, "", line)
        print line; exit
      }' "$body")
    [[ -n "$bsum" ]] || continue
    if ! awk -v a="$fsum" -v b="$bsum" -v arms=vocab,digits "$_DECISION_CMP_AWK" > /dev/null; then
      echo "fail: decision $id disagrees across transports — frontmatter says \"${fsum}\" but the ${artname} body says \"${bsum}\". Reconcile both to one statement; a reader resolving the id must not get two answers" >&2
      failed=1
    fi
  done <<< "$rows"
  rm -f "$body"
  return "$failed"
}

# AR consult text vs key_decisions: a platform architect's line that cites a decision id must
# not say the opposite of that decision. AR merges the consult into its own artifact, so a
# contradiction there reaches DV as two answers for one id. Advisory by design: the line prints
# `warn:`, returns 0 on every path and ignores --strict, so it never changes the exit status
# (Step B.1 records it and carries it forward). Only a cited line is compared — without an id
# there is no decision to hold it to, and AR's own reconcile step covers the rest.
#
# Sources, by naming convention so no platform table is copied here: each
# `## <Platform> App Architecture` H2 section of the artifact, and every `*-architecture.md`
# beside it (its leading frontmatter skipped). The glob cannot match `architecture-N.md`.
# The vocab arm stays off: a cited line often extends a decision rather than restating it.
check_consult_divergence() {  # <artifact> <fmfile>
  local artifact="$1" fmfile="$2"
  local rows artname dir sf pairs
  local -a srcs
  artname=$(basename "$artifact")
  rows=$(yq eval '(.handoff.key_decisions // []) | .[] | ((.id // "") + "\t" + (.summary // ""))' \
    "$fmfile" 2> /dev/null || printf '')
  [[ -n "$rows" ]] || return 0
  dir=$(dirname "$artifact")
  srcs=("$artifact")
  for sf in "$dir"/*-architecture.md; do
    [[ -f "$sf" && "$sf" != "$artifact" ]] && srcs+=("$sf")
  done

  # One pass emits each (cited id, line) pair: id, summary, source, line number, the line with
  # that id removed (so the id never counts as a word), and the line as written. The id is
  # matched by index(), not a regex, so an id carrying a metacharacter stays literal.
  pairs=$(CONSULT_KEYS="$rows" awk -v art="$artifact" -v artname="$artname" '
    BEGIN {
      nk = split(ENVIRON["CONSULT_KEYS"], kl, "\n")
      for (i = 1; i <= nk; i++) {
        # An empty summary has nothing to compare, and its empty field would collapse under
        # the tab-split read below and shift every later field.
        t = index(kl[i], "\t"); if (t < 2 || t == length(kl[i])) continue
        n++; ID[n] = substr(kl[i], 1, t - 1); SUM[n] = substr(kl[i], t + 1)
      }
    }
    FNR == 1 { isart = (FILENAME == art); insec = 0; infm = 0
      m = split(FILENAME, p, "/"); base = p[m]
      if (!isart && $0 == "---") { infm = 1; next } }
    infm { if ($0 == "---") infm = 0; next }
    isart && /^## / {
      insec = ($0 ~ /^## .+ App Architecture[[:space:]]*$/)
      hdr = substr($0, 4); sub(/[[:space:]]+$/, "", hdr)
      next
    }
    isart && !insec { next }
    {
      line = $0; gsub(/\t/, " ", line)
      src = isart ? artname " § " hdr : base
      for (k = 1; k <= n; k++) {
        id = ID[k]; L = length(id); rest = line; out = ""; cited = 0
        # Whole-word boundary class [^A-Za-z0-9_-], so ad6 never matches inside ad60.
        while ((at = index(rest, id)) > 0) {
          before = (at == 1) ? (out == "" ? "" : substr(out, length(out))) : substr(rest, at - 1, 1)
          after = substr(rest, at + L, 1)
          if (before !~ /[A-Za-z0-9_-]/ && after !~ /[A-Za-z0-9_-]/) {
            cited = 1; out = out substr(rest, 1, at - 1) " "
          } else {
            out = out substr(rest, 1, at - 1 + L)
          }
          rest = substr(rest, at + L)
        }
        if (cited) printf "%s\t%s\t%s\t%d\t%s\t%s\n", id, SUM[k], src, FNR, out rest, line
      }
    }' "${srcs[@]}" 2> /dev/null || printf '')
  [[ -n "$pairs" ]] || return 0

  local id fsum src ln stripped orig reason
  while IFS=$'\t' read -r id fsum src ln stripped orig; do
    [[ -n "$id" && -n "$fsum" ]] || continue
    reason=$(awk -v a="$fsum" -v b="$stripped" -v arms=digits,polarity "$_DECISION_CMP_AWK") && continue
    [[ -n "$reason" ]] || continue
    echo "warn: consult ${src}:${ln} restates decision $id with different content (${reason}) — key_decisions says \"${fsum}\" but the consult says \"${orig:0:200}\". Reconcile it in ${artname} or raise an AR sweep item" >&2
  done <<< "$pairs"
  return 0
}

# ---------- tests_executed evidence (DV, QA) ----------
# One entry per runner invocation: {runner, count, summary_line}. A list, never a folded
# number: a stage running several runners had to squeeze them into one count, and every
# runner but one then had no checkable record.

# te_tag <fmfile> -> the yq tag of handoff.tests_executed; `!!null` when absent.
te_tag() {
  local t
  t=$(yq eval '.handoff.tests_executed | tag' "$1" 2> /dev/null) || t='!!null'
  printf '%s' "${t:-!!null}"
}

# te_rows <fmfile> -> one line per list entry, in order:
#   map entries:   !!map|<runner-tag>|<count-tag>|<summary_line-tag>|<count when !!int>
#   other entries: <entry-tag>
# Tags and integers only, so the line never carries free text that could hold the
# delimiter or a newline; runner and summary_line are read by index when needed.
# Two yq calls rather than one: a single expression with a `select` alternative drops
# non-map entries silently, and a dropped entry is a fault nobody would see.
te_rows() {
  local fm="$1" etag j=0
  local -a etags=() mrows=()
  while IFS= read -r etag; do
    [[ -n "$etag" ]] && etags+=("$etag")
  done < <(yq eval '.handoff.tests_executed[] | tag' "$fm" 2> /dev/null)
  while IFS= read -r etag; do
    [[ -n "$etag" ]] && mrows+=("$etag")
  done < <(yq eval '.handoff.tests_executed[] | select(tag == "!!map")
      | [(.runner | tag), (.count | tag), (.summary_line | tag),
         (.count | select(tag == "!!int") | to_string)] | join("|")' "$fm" 2> /dev/null)
  local i=0 n=${#etags[@]}
  while [[ "$i" -lt "$n" ]]; do
    if [[ "${etags[$i]}" == '!!map' ]]; then
      printf '!!map|%s\n' "${mrows[$j]:-}"
      j=$((j + 1))
    else
      printf '%s\n' "${etags[$i]}"
    fi
    i=$((i + 1))
  done
}

# A valid count is a YAML integer written as plain digits. The tag alone would admit
# `0x1F` and `+5`; the digits alone would admit the quoted "12" a JSON reader sees as text.
te_count_valid() {  # <count-tag> <count>
  [[ "$1" == '!!int' && "$2" =~ ^[0-9]+$ ]]
}

# rc 0 when the list reports nothing executed: empty, or every entry a map whose count is
# a valid 0. Any invalid entry answers "no", so a malformed entry is reported once, by
# check_summary_line, and not a second time as missing compile evidence.
te_list_reports_zero() {  # <fmfile>
  local row etag rtag ctag stag cval
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r etag rtag ctag stag cval <<< "$row"
    [[ "$etag" == '!!map' ]] || return 1
    te_count_valid "$ctag" "$cval" || return 1
    [[ $((10#$cval)) -eq 0 ]] || return 1
  done < <(te_rows "$1")
  return 0
}

# A DV stage reporting zero executed tests must say whether the suite COMPILES.
# Zero is a legal outcome; being unable to tell it from "never built" is not — that
# ambiguity let a platform reach a merge decision with no test ever run, while four
# stages escalated with remedies aimed at a control that was not the one refusing
# them. Compilation is answerable WITHOUT test-execution authority, which is why it
# is asked of the stage that was denied.
#
# Blocking, not warn-only: unlike the AR-ref arm this is not a rollout, and a
# missing value is exactly the state the check exists to refuse.
# Contract: stage-contracts.md#tpl-dv § Zero executed tests must say whether the
# suite compiles.
check_test_evidence() {
  local fmfile="$1" tag executed compiles missing_msg

  tag=$(te_tag "$fmfile")
  case "$tag" in
    '!!seq')
      te_list_reports_zero "$fmfile" || return 0
      missing_msg="fail: stage=DV reports no executed tests (an empty tests_executed list or every count 0) with no test_suite_compiles — add test_suite_compiles: true|false|unknown. It is checkable without test-execution authority, and it is what separates gate-blocked from never-built"
      ;;
    '!!null' | '!!map') return 0 ;;
    *)
      # A scalar outside the legacy opt-in is already refused by check_summary_line;
      # asking it for compile evidence too would send two failures for one slip.
      [[ "$LEGACY_TE" -eq 1 ]] || return 0
      executed=$(yq eval '.handoff.tests_executed' "$fmfile")
      case "$executed" in
        '' | *[!0-9]*) return 0 ;;
      esac
      [[ $((10#$executed)) -eq 0 ]] || return 0
      missing_msg="fail: stage=DV reports legacy tests_executed: 0 with no test_suite_compiles — add test_suite_compiles: true|false|unknown. It is checkable without test-execution authority, and it is what separates gate-blocked from never-built"
      ;;
  esac

  # NOT `// ""`: yq's alternative operator treats a literal `false` as falsy and
  # hands back the default, which would silently turn one of the three legal
  # answers into "absent" — the exact ambiguity this check exists to refuse.
  compiles=$(yq eval '.handoff.test_suite_compiles' "$fmfile")
  [[ "$compiles" == "null" ]] && compiles=""
  case "$compiles" in
    true | false | unknown) return 0 ;;
    "")
      echo "$missing_msg" >&2
      return 1 ;;
    *)
      echo "fail: stage=DV test_suite_compiles is \"$compiles\" — expected true, false or unknown" >&2
      return 1 ;;
  esac
}

# A non-zero execution count is checked against the words the runner used; otherwise
# `count: 4000` would validate clean for a stage that ran nothing.
#
# Two tiers, because "verbatim" is not mechanically decidable. Tier 1 asks only
# that the excerpt EXIST somewhere durable — the artifact body, or a .context/logs/
# capture the artifact names — which is platform-neutral and decidable. Tier 2, the
# count-token match, fails only for a strict runner (te_runner_strict), whose line always
# carries the count. For any other runner it warns: a free-form script or an Xcode
# formatter need not repeat the count, and a check that guesses wrong fails honest stages.
# The legacy scalar has no runner name, so it always warns.
#
# DV and QA only: they are the two stages holding test-execution authority, so no
# other stage can produce the line honestly.
# Contract: stage-contracts.md#tpl-dv § Verification Command carries the runner's
# verbatim summary line.
#
# Shape dispatcher. Absence is the required-field loop's business. A map is refused
# in every mode; a scalar passes only through the legacy opt-in.
check_summary_line() {  # <artifact> <fmfile> <stage>
  local artifact="$1" fmfile="$2" stage="$3" tag val

  tag=$(te_tag "$fmfile")
  case "$tag" in
    '!!null') return 0 ;;
    '!!seq')
      check_summary_line_list "$artifact" "$fmfile" "$stage" || return 1
      return 0 ;;
    '!!map')
      echo "fail: stage=$stage tests_executed is a map, not a list — record one entry per runner: tests_executed: [{runner, count, summary_line}]" >&2
      return 1 ;;
  esac

  val=$(yq eval '.handoff.tests_executed' "$fmfile")
  # An empty scalar is reported by the required-field loop already.
  [[ -n "$val" ]] || return 0
  if [[ "$LEGACY_TE" -eq 1 ]]; then
    check_summary_line_legacy "$artifact" "$fmfile" "$stage" || return 1
    return 0
  fi
  echo "fail: stage=$stage tests_executed is a scalar (\"$val\") — record one entry per runner: tests_executed: [{runner, count, summary_line}]; a legacy scalar validates only under --legacy-tests-executed" >&2
  return 1
}

# A strict runner has a line that always carries the executed count: its own tally, or for
# Gradle and JUnit the junit-tally.sh line. Every other runner keeps the warn: a bash-*
# script prints what its author chose, and xcodebuild prints one tally per framework and no
# total for a mixed XCTest + Swift Testing scheme. Matched lowercased; a trailing `*` is a
# prefix match, so gradlew and junit5 are strict too. Canonical list:
# skills/shared/testing-strategy.md § Strict-count runners. One or two names per pattern
# line, because tests/shell/skills/test-authority-matrix.bats refuses a line outside its
# allow-list that names three runners.
te_runner_strict() {  # <runner>
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    gradle* | junit*) return 0 ;;
    swift-testing) return 0 ;;
    vitest | jest) return 0 ;;
    pytest | bats) return 0 ;;
  esac
  return 1
}

# pytest prints a total only when every case passed; a failing run prints a list of
# outcome counts (`1 failed, 57 passed in 3.2s`). Its line still proves the count when the
# count lies in [base, base + errors], base = passed + failed + xpassed + xfailed: an error
# is either a case of its own (setup failed) or a second report on a case already counted
# (`1 passed, 1 error` when teardown fails). Skipped, deselected and warnings are not
# executed cases, so they never add. With no passed/failed/x* outcome at all (`3 errors`,
# a collection failure) the range is off: those errors may be no cases, so only a count
# the line carries as a token is proven. pytest only: the other strict runners print a total.
te_outcome_sum_matches() {  # <runner> <line> <count>
  local base errs n
  [[ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" == pytest ]] || return 1
  base=$(te_outcome_count "$2" 'passed|failed|xpassed|xfailed')
  errs=$(te_outcome_count "$2" 'errors?')
  n=$((10#$3))
  [[ "$base" -gt 0 && "$n" -ge "$base" && "$n" -le $((base + errs)) ]]
}

# A whole-number token is a digit run that is not part of a decimal (`0.1s`, `8.3.1`), so
# a stray decimal digit cannot stand in for a count. A TAP plan `1..N` is one token worth
# N: its lower bound 1 is not a count, and reading it as one would let `count: 1` pass
# every bats plan. Leftmost-longest matching takes the plan form before the bare digits.
te_count_is_token() {  # <line> <count>
  local tok n=$((10#$2))
  while IFS= read -r tok; do
    case "$tok" in
      *..*) tok=${tok#*..} ;;
      *.*) continue ;;
    esac
    [[ -n "$tok" && $((10#$tok)) -eq "$n" ]] && return 0
  done < <(printf '%s\n' "$1" | grep -oE '[0-9]+\.\.[0-9]+|[0-9]+(\.[0-9]+)*')
  return 1
}

te_outcome_count() {  # <line> <outcome-ere> — sum of "<N> <outcome>" tokens
  printf '%s\n' "$1" | grep -oE "(^|[^0-9.])[0-9]+ ($2)([^a-z]|\$)" \
    | awk 'match($0, /[0-9]+/) { s += substr($0, RSTART, RLENGTH) } END { print s + 0 }'
}

te_strict_fix() {  # <runner>
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    gradle* | junit*)
      echo "run skills/worktask/scripts/junit-tally.sh <results-dir>, capture its line to .context/logs/, name that capture, and quote the line as summary_line" ;;
    *)
      echo "quote the tally line the runner printed, the one that carries the count" ;;
  esac
}

# Every entry is checked and every fault gets its own line, so one run reports them all.
# Within an entry: a non-map stops that entry; runner and count are independent; the
# summary_line checks run only for a valid count > 0 and stop at the first fault, since
# each assumes the one before it held.
check_summary_line_list() {  # <artifact> <fmfile> <stage>
  local artifact="$1" fmfile="$2" stage="$3" rc=0 i=0
  local row etag rtag ctag stag cval runner count line xc_hint

  # fd 3, not stdin: the loop body runs yq and the audit appender, and neither may drain
  # the rows still to be read.
  while IFS= read -r row <&3; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r etag rtag ctag stag cval <<< "$row"
    if [[ "$etag" != '!!map' ]]; then
      echo "fail: stage=$stage tests_executed[$i] is not a map — each entry is {runner, count, summary_line}" >&2
      rc=1; i=$((i + 1)); continue
    fi

    # A collection has no one-line spelling to echo back; only scalars are quoted.
    runner=""
    case "$rtag" in
      '!!null' | '!!map' | '!!seq') ;;
      *) runner=$(yq eval ".handoff.tests_executed[$i].runner" "$fmfile") ;;
    esac
    if [[ "$rtag" != '!!str' || -z "${runner//[[:space:]]/}" ]]; then
      echo "fail: stage=$stage tests_executed[$i] has no runner — name the runner that produced this count as a non-empty string (bats, pytest, swift, …)" >&2
      rc=1
    fi

    if ! te_count_valid "$ctag" "$cval"; then
      count=""
      case "$ctag" in
        '!!int') count="$cval" ;;
        '!!null' | '!!map' | '!!seq') ;;
        *) count=$(yq eval ".handoff.tests_executed[$i].count" "$fmfile") ;;
      esac
      echo "fail: stage=$stage tests_executed[$i] runner=$runner count is \"$count\" — a count is a whole number and nothing else; a value carrying units, a range or a parenthetical skips the evidence contract below it" >&2
      rc=1; i=$((i + 1)); continue
    fi
    count="$cval"
    if [[ $((10#$count)) -eq 0 ]]; then
      i=$((i + 1)); continue
    fi

    # The tag, not the value: yq prints `null` for an absent key and for the string
    # "null" alike, and those are different mistakes.
    if [[ "$stag" == '!!null' ]]; then
      echo "fail: stage=$stage tests_executed[$i] runner=$runner reports count: $count with no summary_line — copy the runner's own summary line in verbatim; it is the only record downstream that a count was ever observed" >&2
      rc=1; i=$((i + 1)); continue
    fi
    line=$(yq eval ".handoff.tests_executed[$i].summary_line" "$fmfile")
    if [[ -z "${line//[[:space:]]/}" || "$line" != *[0-9]* ]]; then
      echo "fail: stage=$stage tests_executed[$i] runner=$runner summary_line carries no digit: \"$line\" — a runner's summary line reports numbers; a label is not evidence" >&2
      rc=1; i=$((i + 1)); continue
    fi
    if ! summary_line_corroborated "$artifact" "$line" "$count" "$runner"; then
      xc_hint=""
      te_runner_xcodebuild "$runner" \
        && xc_hint=" — for xcodebuild, or a named .context/logs/*.json xcresulttool summary whose totalTestCount is $count"
      echo "fail: stage=$stage tests_executed[$i] runner=$runner summary_line is uncorroborated: \"$line\" appears neither in $(basename "$artifact") nor in a .context/logs/ capture it names — an excerpt nobody can check is the unverifiable claim this arm refuses$xc_hint" >&2
      rc=1; i=$((i + 1)); continue
    fi
    if ! te_count_is_token "$line" "$count"; then
      if te_outcome_sum_matches "$runner" "$line" "$count"; then
        i=$((i + 1)); continue
      fi
      if te_runner_strict "$runner"; then
        echo "fail: stage=$stage tests_executed[$i] runner=$runner count: $count is not a whole-number token of summary_line \"$line\" — this runner has a line that prints the executed count, so a line without it does not prove the count; $(te_strict_fix "$runner")" >&2
        rc=1; i=$((i + 1)); continue
      fi
      echo "warn: stage=$stage tests_executed[$i] runner=$runner count: $count is not a whole-number token of summary_line \"$line\" — the excerpt is corroborated, the count is not; a bash-* script names a .context/logs/ capture whose result line carries the count" >&2
      summary_line_audit "$artifact" "$stage" "$count" "$line" "$runner"
    fi
    i=$((i + 1))
  done 3< <(te_rows "$fmfile")

  # Warn, not ignore silently: a stale top-level line left beside the list would read as
  # evidence to anyone skimming the frontmatter.
  if [[ "$(yq eval '.handoff.test_summary_line | tag' "$fmfile" 2> /dev/null)" != '!!null' ]]; then  # legacy key
    echo "warn: stage=$stage carries a legacy top-level test_summary_line next to a tests_executed list — it is ignored as evidence; move it into that runner's summary_line and delete the top-level key" >&2
  fi
  return "$rc"
}

# The legacy scalar shape under the opt-in: one count for the whole stage and one
# top-level summary line, checked with the integer rules the list replaced. Deprecated
# together with --legacy-tests-executed, which is still accepted.
check_summary_line_legacy() {  # <artifact> <fmfile> <stage>
  local artifact="$1" fmfile="$2" stage="$3" executed line

  echo "warn: stage=$stage tests_executed is a legacy scalar, validated under --legacy-tests-executed — deprecated; rewrite it as tests_executed: [{runner, count, summary_line}]" >&2

  executed=$(yq eval '.handoff.tests_executed' "$fmfile")
  case "$executed" in
    *[!0-9]*)
      echo "fail: stage=$stage legacy tests_executed is \"$executed\" — a count is a whole number and nothing else; a value carrying units, a range or a parenthetical skips the whole evidence contract below it" >&2
      return 1 ;;
  esac
  [[ $((10#$executed)) -gt 0 ]] || return 0

  # NOT `// ""`: the alternative operator cannot tell an absent field from an
  # empty one, and those two get different messages because they are different
  # mistakes — nothing written versus a placeholder left behind.
  line=$(yq eval '.handoff.test_summary_line' "$fmfile")  # legacy top-level key

  if [[ "$line" == "null" ]]; then
    echo "fail: stage=$stage reports legacy tests_executed: $executed with no test_summary_line — copy the runner's own summary line in verbatim; it is the only record downstream that a count was ever observed" >&2
    return 1
  fi
  if [[ -z "${line//[[:space:]]/}" || "$line" != *[0-9]* ]]; then
    echo "fail: stage=$stage legacy test_summary_line carries no digit: \"$line\" — a runner's summary line reports numbers; a label is not evidence" >&2
    return 1
  fi

  if ! summary_line_corroborated "$artifact" "$line"; then
    echo "fail: stage=$stage legacy test_summary_line is uncorroborated: \"$line\" appears neither in $(basename "$artifact") nor in a .context/logs/ capture it names — an excerpt nobody can check is the unverifiable claim this arm refuses" >&2
    return 1
  fi

  if ! printf '%s' "$line" | grep -qE "(^|[^0-9])${executed}([^0-9]|\$)"; then
    echo "warn: stage=$stage legacy tests_executed: $executed is not a whole-number token of test_summary_line \"$line\" — the excerpt is corroborated, the count is not" >&2
    summary_line_audit "$artifact" "$stage" "$executed" "$line"
  fi
  return 0
}

te_runner_xcodebuild() {  # <runner>
  [[ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" == xcodebuild* ]]
}

# named_log_captures <artifact> <body> -> each existing file that a .context/logs/ path in
# the body resolves to, glob included. Three resolutions, because an artifact names its
# capture from the repo root as often as from beside itself, and neither spelling is wrong.
named_log_captures() {
  local dir cand path f
  dir=$(cd "$(dirname "$1")" && pwd)
  while IFS= read -r cand; do
    [[ -n "$cand" ]] || continue
    for path in "$cand" "$dir/${cand#.context/}" "$dir/../$cand"; do
      for f in $path; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
      done
    done
  done < <(printf '%s\n' "$2" | grep -oE '[A-Za-z0-9._/*-]*logs/[A-Za-z0-9._/*-]+' | sort -u)
  return 0
}

# The excerpt must exist in something durable. Body first; then any .context/logs/
# path the body names — a scoped bats run is captured as `dv0-bats-*.log`, and a stage
# that names its capture that way has still put the line somewhere a reader can open.
#
# Third, for xcodebuild only: QA composes its line from `xcresulttool get test-results
# summary` JSON, which no runner prints, so the line cannot be found verbatim anywhere.
# A named *.json capture of that summary corroborates it when its total equals count and
# the line carries count as a token. The arm reads the file and never runs xcresulttool;
# a drifted JSON shape fails closed. The legacy scalar passes no count and gets no arm 3.
summary_line_corroborated() {  # <artifact> <line> [count] [runner]
  local artifact="$1" line="$2" count="${3-}" runner="${4-}" body f
  body=$(awk 'NR==1 && /^---[[:space:]]*$/ { fm=1; next }
              fm==1 && /^---[[:space:]]*$/ { fm=0; next }
              fm!=1' "$artifact")
  if printf '%s\n' "$body" | grep -Fq -- "$line"; then
    return 0
  fi
  while IFS= read -r f; do
    if grep -Fq -- "$line" "$f"; then
      return 0
    fi
  done < <(named_log_captures "$artifact" "$body")

  [[ -n "$count" ]] && te_runner_xcodebuild "$runner" || return 1
  te_count_is_token "$line" "$count" || return 1
  command -v jq > /dev/null 2>&1 || return 1
  while IFS= read -r f; do
    [[ "$f" == *.json ]] || continue
    if jq -e --argjson c "$((10#$count))" '
        if type == "object" then
          ([.totalTestCount, .passedTests, .failedTests] | all(type == "number"))
          and .totalTestCount == $c
        else false end' "$f" > /dev/null 2>&1; then
      return 0
    fi
  done < <(named_log_captures "$artifact" "$body")
  return 1
}

# Warn tier only. The row is evidence that the softer half of the contract fired,
# so a later reader can tell a formatter this arm cannot parse from a count nobody
# checked. It rides the shared appender rather than a second writer, and a missing
# library degrades to silence: an audit row is never a gate.
summary_line_audit() {  # <artifact> <stage> <executed> <line> [runner]
  local artifact="$1" stage="$2" executed="$3" line="$4" runner="${5-}" lib tid="$2"
  local -a runner_kv=()
  [[ $tid =~ ^[A-Z]{2}[0-9]+$ ]] || tid=unknown
  [[ -z "$runner" ]] || runner_kv=(--meta-kv "runner=$runner")
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../shared/lib/audit-lib.sh"
  [[ -r "$lib" ]] || return 0
  # shellcheck source=../../shared/lib/audit-lib.sh
  . "$lib" 2> /dev/null || return 0
  command -v corpflow_audit_row > /dev/null 2>&1 || return 0
  corpflow_audit_row --file "$(dirname "$artifact")/logs/audit.jsonl" \
    --actor "handoff-harness" --action "count_corroboration" --result "degraded" \
    --subject "$stage" --task-id "$tid" --meta-kv "tests_executed=$executed" \
    ${runner_kv[@]+"${runner_kv[@]}"} --meta-kv "summary_line=$line" || return 0
}

ARCH_REF_RE='^architecture-[0-9]+\.md(#[a-z-]+)?$'

# Warn-only by default so an advisory check can never break an unrelated run.
ar_ref_violation() {
  if [[ "$STRICT" -eq 1 ]]; then
    echo "fail: $1" >&2
    return 1
  fi
  echo "warn: $1" >&2
  return 0
}

# Runtime truth for "did AR run" is the tasks.AR<N> entry, never the presence of
# an architecture file — AR is optional and PL0 decides it per run.
check_ar_ref() {
  local artifact="$1" fmfile="$2"

  # A state file we cannot read is NOT evidence that AR did not run. Saying so
  # out loud keeps the two cases distinguishable under --strict, where a silent
  # skip would be a false negative on every jq-less host.
  local unreadable
  unreadable=$(state_unreadable_reason)

  if [[ -n "$unreadable" ]]; then
    ar_ref_violation "AR-ref check skipped — $unreadable" || return 1
    return 0
  fi

  local ar_present=0
  # Any AR instance counts: a split or renumbered AR lands as AR1/AR2, and the
  # gate asks "did AR run", not "did AR0 run".
  if jq -e '[(.tasks // {}) | keys[] | select(test("^AR[0-9]+$"))] | length > 0' "$STATE_ARG" >/dev/null 2>&1; then
    ar_present=1
  fi

  local ref
  ref=$(yq eval '.handoff.refs.decisions // .handoff.architecture.ref // ""' "$fmfile")
  [[ "$ref" == "null" ]] && ref=""

  if [[ "$ar_present" -eq 0 ]]; then
    if [[ -n "$ref" ]] && printf '%s' "$ref" | grep -qE '^architecture-'; then
      echo "warn: DV references $ref but state has no tasks.AR<N> entry" >&2
    fi
    return 0
  fi

  if [[ -z "$ref" ]]; then
    ar_ref_violation "AR completed but DV refs.decisions missing" || return 1
    return 0
  fi

  # Two different defects shared one message, so neither said what to do. A malformed shape
  # is not a dangling reference: the commonest form by far is a `.context/` prefix, which
  # every SIBLING ref in this block carries, so it is a reasonable thing to write and worth
  # naming outright rather than leaving to be inferred from a regex nobody is shown.
  if ! printf '%s' "$ref" | grep -qE "$ARCH_REF_RE"; then
    ar_ref_violation "DV architecture ref malformed: $ref (expected a bare 'architecture-<N>.md#<anchor>' relative to the artifact — no .context/ prefix, unlike the sibling refs in this block)" || return 1
    return 0
  fi

  local reffile
  reffile="${ref%%#*}"
  if [[ ! -f "$(dirname "$artifact")/$reffile" ]]; then
    ar_ref_violation "DV architecture ref dangling: $reffile names no file next to $(basename "$artifact")" || return 1
    return 0
  fi

  return 0
}

# check_anchors <artifact> <stage> — one `fail:` line per missing or unexpected H2. Fails
# closed: an unreachable lint is a gate failure, unlike the pre-write hook, which fails open.
check_anchors() {
  local f="$1" stage="$2" name rows drc=0 kind h
  name="$(basename "$f")"
  local lint
  lint="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cache-lint.sh"
  if [[ ! -r "$lint" ]]; then
    echo "fail: anchor gate cannot run on $name: cache-lint.sh unreachable at $lint" >&2
    return 1
  fi
  rows=$(bash "$lint" --anchor-diff --stage "$stage" "$f" 2>&1) || drc=$?
  [[ "$drc" -ne 0 ]] || return 0
  if [[ "$drc" -ne 1 ]]; then
    echo "fail: anchor gate cannot run on $name: ${rows%%$'\n'*}" >&2
    return 1
  fi
  while IFS=$'\t' read -r kind h; do
    case "$kind" in
      missing) echo "fail: anchor-lint stage=$stage missing required H2 '## $h' in $name" >&2 ;;
      unexpected) echo "fail: anchor-lint stage=$stage unexpected H2 '## $h' in $name — nest it as H3 (handoff-protocol.md#anchor-allow-list)" >&2 ;;
    esac
  done <<< "$rows"
  return 1
}

validate_frontmatter() {
  local f="$1"
  [[ -f "$f" ]] || { echo "frontmatter: file not found: $f" >&2; return 1; }

  # Raw bytes first: awk and yq must never see a NUL, which each may truncate at silently.
  local cbrc=0 cbhits cbline cbhex cboff
  cbhits=$(cb_scan_file "$f" "$f") || cbrc=$?
  if [[ "$cbrc" -eq 1 ]]; then
    while IFS= read -r cbline; do
      [[ -n "$cbline" ]] || continue
      cbhex="${cbline##*:}"
      cboff="${cbline%:*}"
      cboff="${cboff##*:}"
      echo "fail: control byte $cbhex at byte offset $cboff in $f — rewrite it as text" >&2
    done <<< "$cbhits"
    return 1
  elif [[ "$cbrc" -ne 0 ]]; then
    echo "fail: cannot scan $f for control bytes" >&2
    return 1
  fi

  # Extract just the frontmatter block (between first two ^---$ lines) to a tmp,
  # so yq can parse it as pure YAML (the rest of the markdown is not YAML).
  local fmfile
  fmfile=$(mktemp "${TMPDIR:-/tmp}/handoff-fm-XXXXXX")
  # One cleanup for fourteen exits. Every failure arm below used to carry its own
  # `rm -f`, so a new arm leaked the temp file unless its author noticed. RETURN
  # traps are not inherited by called functions without `set -T`, which this
  # script does not set, so the checks invoked below cannot fire it early.
  #
  # The path is baked in at trap-set time, exactly as validate_state's sibling
  # trap does it, because a RETURN trap stays installed after the function
  # returns and fires again when a sourced file completes — by which time the
  # local is gone and `"$fmfile"` would be an unbound-variable error under
  # `set -u`. Baked, that late firing is a no-op on an already-removed path.
  # shellcheck disable=SC2064  # expansion at set time is the point, see above
  trap "rm -f '$fmfile'" RETURN
  # One extractor, shared with state-patch.sh: the two used different awk programs, and an
  # artifact carrying a second `---` in its body was sliced differently by each.
  corpflow_fm_block "$f" > "$fmfile" 2> /dev/null || true
  if [[ ! -s "$fmfile" ]]; then
    echo "fail: missing frontmatter block in $f" >&2
    return 1
  fi

  # The shape gate, also shared. Checked before the yq branch below so the flat shape is
  # refused identically with or without yq on the host — it is the divergence that let an
  # artifact be unreadable here and still write a healthy ledger row.
  if ! corpflow_fm_has_handoff "$fmfile"; then
    echo "fail: no handoff: block" >&2
    return 1
  fi

  local bo_rc=0
  check_blocked_on "$fmfile" || bo_rc=1

  # Before the yq gate so H2 enforcement never depends on yq; an unknown or absent stage is
  # left to the stage checks below.
  local anchor_rc=0 fm_stage
  fm_stage=$(corpflow_fm_field "$fmfile" stage)
  if [[ -n "$fm_stage" && "$fm_stage" != "null" && -n "$(required_for "$fm_stage")" ]]; then
    check_anchors "$f" "$fm_stage" || anchor_rc=1
  fi
  local pre_rc=$((bo_rc | anchor_rc))

  command -v yq >/dev/null 2>&1 || {
    echo "frontmatter: yq required for full validation; running grep-only fallback" >&2
    head -1 "$f" | grep -q '^---$' || { echo "fail: missing leading ---" >&2; return 1; }
    return "$pre_rc"
  }

  local stage
  stage=$(yq eval '.handoff.stage // ""' "$fmfile")
  [[ -n "$stage" && "$stage" != "null" ]] || { echo "fail: no stage" >&2; return 1; }

  local req
  req=$(required_for "$stage")
  [[ -n "$req" ]] || { echo "fail: unknown stage $stage" >&2; return 1; }

  # Everything above is the fail-fast prologue: each of its checks makes every later check
  # meaningless, so running on would emit noise rather than information. Everything below
  # collects — an author handed one failure and then a second on the re-run pays a boundary
  # round per defect. Each check keeps its own message text and its own line: Step B.1
  # re-dispatches with the `fail:` line verbatim and the orchestrator greps for one naming a
  # sweep id, so aggregating them into a single line would break that reader.
  local rc="$pre_rc"

  local field
  for field in $req; do
    local val
    val=$(yq eval ".handoff.${field} // \"\"" "$fmfile")
    if [[ -z "$val" || "$val" == "null" ]]; then
      echo "fail: stage=$stage missing required field: $field" >&2
      rc=1
    fi
  done

  local task_id
  task_id=$(corpflow_fm_field "$fmfile" task_id)
  if [[ -n "$task_id" ]] && ! [[ "$task_id" =~ ^${stage}[0-9]+$ ]]; then
    echo "fail: handoff.task_id '$task_id' is not a task id of stage $stage" >&2
    rc=1
  fi

  if [[ "$stage" == "DV" && -n "$STATE_ARG" ]]; then
    check_ar_ref "$f" "$fmfile" || rc=1
  fi

  if [[ "$stage" == "DV" ]]; then
    check_test_evidence "$fmfile" || rc=1
  fi

  local te_arm_ok=0
  if [[ "$stage" == "DV" || "$stage" == "QA" ]]; then
    if check_summary_line "$f" "$fmfile" "$stage"; then te_arm_ok=1; else rc=1; fi
  fi

  check_files_touched_cap "$fmfile" "$stage" "$(basename "$f")" || rc=1
  check_decision_divergence "$f" "$fmfile" "$stage" || rc=1
  if [[ "$stage" == "AR" ]]; then check_consult_divergence "$f" "$fmfile" || true; fi
  local stub_shape_ok=1
  check_sweep_stub_shape "$fmfile" || { rc=1; stub_shape_ok=0; }
  check_sweep_ref_anchor "$f" "$fmfile" || rc=1
  check_sweep_item_body "$f" "$fmfile" || rc=1
  check_empty_sweep_prose "$f" "$fmfile" || rc=1
  if [[ -n "$STATE_ARG" ]]; then
    report_task_id_fallback "$fmfile" "$f"
    check_sweep_ledger "$fmfile" "$f" || rc=1
  fi

  # Token budget (AD-2). The budget constrains DISCRETIONARY prose — summary,
  # next_stage_focus, decision bodies — so the mandatory open_questions stubs and the
  # tests_executed evidence list are excluded from it: counting them made the check measure
  # the wrong thing and rewarded a stage for asking fewer questions, or for folding several
  # runners into one entry, since a verbatim summary line cannot be shortened.
  #
  #   discretionary = toks(frontmatter) - min( toks(stub block), 4 x 16 )
  #                                     - min( toks(tests_executed block), 4 x 24 )
  #   fail  when discretionary > 200
  #   warn  when total        > 360      # advisory; keeps the real absolute cost visible
  #
  # Each exclusion is capped (four stubs; four runner entries, a verbatim Xcode line being
  # about 19 tokens), so neither can be gamed by inflating strings or emitting extra items:
  # 360 is a deterministic ceiling. The cap is what makes an exclusion safe, not the order of
  # the shape checks.
  #
  # So an invalid tests_executed block is excluded at the same cap and the note says so:
  # its fault is reported once, by check_summary_line, and the check still runs, so a
  # broken block cannot hide an over-budget frontmatter. A broken stub block is counted
  # in full.
  local tcount stubtoks tetoks=0 discretionary budget_note="" te_shape
  tcount=$(toks "$fmfile")
  if [[ "$stub_shape_ok" -eq 1 ]]; then
    stubtoks=$(toks_key_block "$fmfile" open_questions)
    [[ "$stubtoks" -le 64 ]] || stubtoks=64
  else
    stubtoks=0
    budget_note="(stub-shape invalid: sweep stubs counted in full) "
  fi
  if [[ "$stage" == "DV" || "$stage" == "QA" ]]; then
    te_shape=$(te_tag "$fmfile")
    # A valid legacy scalar keeps no exclusion: it is a one-line, two-token key.
    if [[ ("$te_shape" == '!!seq' && "$te_arm_ok" -eq 1) \
      || ("$te_shape" != '!!null' && "$te_arm_ok" -eq 0) ]]; then
      tetoks=$(toks_key_block "$fmfile" tests_executed)
      [[ "$tetoks" -le 96 ]] || tetoks=96
      [[ "$te_arm_ok" -eq 1 ]] \
        || budget_note="${budget_note}(tests_executed invalid: excluded at the 96-token cap) "
    fi
  fi
  discretionary=$((tcount - stubtoks - tetoks))
  # The advisory line is emitted BEFORE the failure, not after: 360 is exactly 200 plus both
  # exclusion caps, so every artifact over the ceiling is already over the budget and a warn
  # placed after the `return 1` could never print. Ordering it first is what keeps the
  # absolute cost visible on the report that matters — the failing one.
  if [[ "$tcount" -gt 360 ]]; then
    echo "warn: stage=$stage frontmatter ${tcount} tokens > 360 absolute ceiling" >&2
  fi
  if [[ "$discretionary" -gt 200 ]]; then
    echo "fail: ${budget_note}stage=$stage frontmatter ${discretionary} discretionary tokens > 200 budget (${tcount} total - ${stubtoks} sweep-stub tokens - ${tetoks} tests_executed tokens excluded)" >&2
    rc=1
  fi

  [[ "$rc" -eq 0 ]] || return "$rc"
  echo "ok: $f stage=$stage tokens=$tcount"
}

# fm_blocked_on_raw <fmfile> — {"blocked_on":…} from the frontmatter block, null for an absent
# key; yq when present, the awk reader above otherwise. rc 1 when unreadable.
fm_blocked_on_raw() {
  local out
  if command -v yq > /dev/null 2>&1; then
    out=$(yq eval -o=json -I=0 '{"blocked_on": .handoff.blocked_on}' "$1" 2> /dev/null) || return 1
  else
    out=$(awk "$_FM_BO_AWK" "$1" 2> /dev/null) || return 1
  fi
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# check_blocked_on <fmfile> — the enum and detail gate on a typed need. Runs before the yq branch
# so a host without yq refuses the same artifacts; the per-kind keys stay the router's check.
check_blocked_on() {
  local raw norm
  # Most artifacts carry no need, and this runs at every stage boundary: no key, no process.
  grep -qE '^[[:space:]]+blocked_on:' "$1" 2> /dev/null || return 0
  if ! command -v jq > /dev/null 2>&1; then
    echo "fail: handoff.blocked_on present but jq is not installed to validate it" >&2
    return 1
  fi
  raw=$(fm_blocked_on_raw "$1") || { echo "fail: handoff.blocked_on could not be parsed" >&2; return 1; }
  norm=$(blocked_on_normalize "$raw") || return 0
  blocked_on_validate "$(printf '%s' "$norm" | jq -c '.blocked_on')"
}

# read_blocked_on <artifact> — the --read-blocked-on mode.
read_blocked_on() {
  local f="$1" fmfile raw norm
  [[ -f "$f" ]] || { echo "fail: file not found: $f" >&2; return 1; }
  command -v jq > /dev/null 2>&1 || { echo "fail: jq is required to read blocked_on" >&2; return 2; }
  # Same reason as validate_frontmatter: awk and yq must never see a raw NUL.
  if ! cb_scan_file "$f" "$f" > /dev/null 2>&1; then
    echo "fail: $f carries a control byte or cannot be scanned" >&2
    return 1
  fi
  fmfile=$(mktemp "${TMPDIR:-/tmp}/handoff-bo-XXXXXX")
  # shellcheck disable=SC2064  # bake the path in, as validate_frontmatter's trap does
  trap "rm -f '$fmfile'" RETURN
  corpflow_fm_block "$f" > "$fmfile" 2> /dev/null || true
  [[ -s "$fmfile" ]] || { echo "fail: missing frontmatter block in $f" >&2; return 1; }
  raw=$(fm_blocked_on_raw "$fmfile") || { echo "fail: handoff.blocked_on in $f could not be parsed" >&2; return 1; }
  norm=$(blocked_on_normalize "$raw") || { echo "fail: no blocked_on in $f" >&2; return 1; }
  printf '%s' "$norm" | jq -c '.blocked_on'
  printf 'source: %s\n' "$(printf '%s' "$norm" | jq -r '.source')"
}

# ---------- state.json validation ----------
validate_state() {
  local f="$1"
  [[ -f "$f" ]] || { echo "state: file not found: $f" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "state: jq required" >&2; return 1; }

  jq empty "$f" 2>/dev/null || { echo "fail: state.json invalid JSON" >&2; return 1; }
  local v
  v=$(jq -r '.version' "$f")
  [[ "$v" == "2" ]] || { echo "fail: version != 2 (got '$v')" >&2; return 1; }
  jq -e 'has("worktask_id") and has("plan_file") and has("platform") and has("tasks") and has("facts") and has("handoffs")' "$f" >/dev/null \
    || { echo "fail: missing required keys" >&2; return 1; }

  local tcount
  tcount=$(toks "$f")
  if [[ "$tcount" -gt 500 ]]; then
    echo "warn: state.json ${tcount} tokens > 500 budget" >&2
  fi

  # Atomic-write idempotency check: re-merging the same patch must be a no-op.
  local td
  td=$(mktemp -d "${TMPDIR:-/tmp}/handoff-state-XXXXXX")
  trap "rm -rf '$td'" RETURN
  cp "$f" "$td/orig.json"
  local patch='{"tasks":{"PL0":{"status":"completed"}}}'
  jq --argjson p "$patch" '. * $p' "$td/orig.json" > "$td/m1.json"
  jq --argjson p "$patch" '. * $p' "$td/m1.json" > "$td/m2.json"
  if ! diff -q "$td/m1.json" "$td/m2.json" >/dev/null; then
    echo "fail: idempotent merge produced different output" >&2
    return 1
  fi

  echo "ok: $f tokens=$tcount idempotent=yes"
}

# ---------- Synthetic fixtures + token-count run ----------
make_fixtures() {
  local d="$1"
  mkdir -p "$d/.context"

  cat > "$d/.context/state.json" <<'EOF'
{
  "version": 2,
  "worktask_id": "harness-demo",
  "plan_file": ".context/planning-0.md",
  "platform": "all",
  "tasks": {
    "PL0": {"status":"completed","verdict":"ok"},
    "AR0": {"status":"completed","verdict":"ok"},
    "TL0": {"status":"completed","verdict":"ok"}
  },
  "facts": {
    "files_modified": [],
    "tests_added": [],
    "decisions": [
      {"id":"pd1","summary":"9-stage worktask","ref":"planning-0.md#stages"},
      {"id":"ad1","summary":"Atomic write agent-primary + hook idempotent","ref":"architecture.md#decisions"}
    ],
    "open_questions": [],
    "verdicts": {"PL":"ok","AR":"ok","TL":"ok"}
  },
  "handoffs": {
    "PL→AR0": "9-stage, complexity 38. ref: planning-0.md#requirements",
    "AR→TL0": "Schemas designed, atomic write strategy. ref: architecture.md#decisions",
    "TL→DV0": "24-file fan-out, 8 batches. ref: coordination.md#fan-out"
  }
}
EOF

  cat > "$d/.context/planning-0.md" <<'EOF'
---
handoff:
  stage: PL
  verdict: ok
  summary: "Demo plan for harness."
  key_decisions:
    - { id: pd1, summary: "9-stage", anchor: "planning-0.md#stages" }
  next_stage_focus: "AR designs schema"
  open_questions: []
  refs: { plan: planning-0.md#requirements }
---

# Planning

## requirements

## elicitation-sweep

nothing to ask

EOF
  # Pad with synthetic body to make the baseline-mode reading expensive.
  for i in $(seq 1 200); do echo "- requirement line $i with extra context describing the work to be done in this synthetic plan" >> "$d/.context/planning-0.md"; done
  cat >> "$d/.context/planning-0.md" <<'EOF'

## acceptance-criteria

EOF
  for i in $(seq 1 60); do echo "- AC-$i criterion description with measurement details" >> "$d/.context/planning-0.md"; done
  cat >> "$d/.context/planning-0.md" <<'EOF'

## scope

In scope.

## out-of-scope

Out.

## risks

None.

## complexity

Score 38.

## stages

PL AR TL DV DR QA DC FN ST.

## summary

Demo plan.
EOF

  cat > "$d/.context/architecture.md" <<'EOF'
---
handoff:
  stage: AR
  verdict: ok
  summary: "Schemas designed."
  key_decisions:
    - { id: ad1, summary: "Atomic write", anchor: "architecture.md#decisions" }
  next_stage_focus: "TL fans out edits"
  open_questions:
    - { id: sw-AR0-1, class: decision, ref: "architecture.md#elicitation-sweep", blocks_next_stage: false }
  refs: { plan: planning-0.md#requirements }
---

# Architecture

## decisions

EOF
  for i in $(seq 1 200); do echo "- AD-$i decision body with justification, alternatives, and trade-offs spanning multiple lines" >> "$d/.context/architecture.md"; done
  cat >> "$d/.context/architecture.md" <<'EOF'

## trade-offs

Listed.

## patterns

Listed.

## integration-points

Listed.

## schemas

Listed.

## open-questions

q3, q4, q5, q6.

## risks

Listed.

## elicitation-sweep

- id: sw-AR0-1
  summary: "Which language do the hooks use?"
  options:
    - { label: "Bash", detail: "Matches every existing hook", recommended: true }
    - { label: "Python", detail: "Richer parsing, new runtime dependency" }
EOF

  cat > "$d/.context/development.md" <<'EOF'
---
handoff:
  stage: DV
  verdict: ok
  summary: "Implemented."
  tests_executed:
    - { runner: bats, count: 12, summary_line: "12 tests, 0 failures" }
  files_touched: [a.md, b.md]
  next_stage_focus: "DR reviews"
  open_questions: []
  refs: { dev: development.md#files-changed }
---

# Development

## files-changed

## verification-command

12 tests, 0 failures

## elicitation-sweep

nothing to ask

EOF
  for i in $(seq 1 100); do echo "- file-$i.md edit description" >> "$d/.context/development.md"; done
  cat >> "$d/.context/development.md" <<'EOF'

## tests-added

None.

## deviations

None.

## follow-ups

None.
EOF
}

run_token_count() {
  local d="${1:-$(mktemp -d "${TMPDIR:-/tmp}/handoff-demo-XXXXXX")}"
  make_fixtures "$d"

  echo "Fixtures created at: $d"
  echo
  printf '%-6s | %12s | %10s | %10s\n' "stage" "baseline_tok" "new_tok" "reduction"
  printf '%s\n' "------+--------------+------------+-----------"

  # New mode prompt: state.json blob + targeted anchor headers (frontmatter only).
  local state_tok
  state_tok=$(toks "$d/.context/state.json")

  # Per-stage simulated reading scope.
  # POSIX-compatible: case-statement lookup instead of associative arrays.
  baseline_files_for() {
    case "$1" in
      DV) echo ".context/planning-0.md .context/architecture.md" ;;
      DR) echo ".context/planning-0.md .context/architecture.md .context/development.md" ;;
      QA) echo ".context/planning-0.md .context/development.md" ;;
      DC) echo ".context/planning-0.md .context/development.md" ;;
      FN) echo ".context/planning-0.md .context/architecture.md .context/development.md" ;;
      *) echo "" ;;
    esac
  }
  new_files_for() {
    case "$1" in
      DV) echo ".context/planning-0.md" ;;
      DR|QA|DC|FN) echo ".context/development.md" ;;
      *) echo "" ;;
    esac
  }

  local rc=0 stage
  for stage in DV DR QA DC FN; do
    local baseline=0 new=$state_tok
    local rel
    for rel in $(baseline_files_for "$stage"); do
      baseline=$(( baseline + $(toks "$d/$rel") ))
    done
    # New mode: state.json + ONLY the frontmatter block of the most relevant artifact
    for rel in $(new_files_for "$stage"); do
      local fm
      fm=$(awk '/^---$/{c++; if (c==2) exit} c>=1' "$d/$rel")
      new=$(( new + $(toks_str "$fm") ))
    done
    local reduction
    reduction=$(awk -v l="$baseline" -v n="$new" 'BEGIN { if (l==0) print "0%"; else printf "%.0f%%", (l-n)*100.0/l }')
    printf '%-6s | %12d | %10d | %10s\n' "$stage" "$baseline" "$new" "$reduction"

    # Threshold: ≥30% reduction (AC-12).
    local pct
    pct=$(awk -v l="$baseline" -v n="$new" 'BEGIN { if (l==0) print 0; else printf "%.0f", (l-n)*100.0/l }')
    if [[ "$pct" -lt 30 ]]; then
      echo "FAIL: stage=$stage reduction $pct% < 30% threshold" >&2
      rc=1
    fi
  done

  echo
  if [[ $rc -eq 0 ]]; then
    echo "PASS: all stages ≥30% reduction (AC-12 met)"
  else
    echo "FAIL: one or more stages below 30% threshold"
  fi
  return $rc
}

# ---------- main ----------
case "$MODE" in
  run)              run_token_count "${OUT_DIR:-}" ;;
  self-test)
    # Sourced HERE, not at the top: the harness is test code the validate paths
    # never run. `[ -r ]` first, not a bare `.`: sourcing a missing file with the
    # `.` builtin is a special-builtin error that exits the shell immediately,
    # bypassing an `if ! . …` guard entirely.
    SELFTEST_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/handoff-harness-selftest.sh"
    if [ -r "$SELFTEST_LIB_PATH" ]; then
      # shellcheck source=handoff-harness-selftest.sh
      # shellcheck disable=SC1090
      . "$SELFTEST_LIB_PATH"
    else
      printf >&2 'handoff-harness: self-test harness unreachable at %s — plugin install broken\n' \
        "$SELFTEST_LIB_PATH"
      exit 2
    fi
    self_test
    ;;
  validate-fm)      [[ -n "$ARG" ]] || usage; validate_frontmatter "$ARG" ;;
  validate-state)   [[ -n "$ARG" ]] || usage; validate_state "$ARG" ;;
  read-bo)          [[ -n "$ARG" ]] || usage; read_blocked_on "$ARG" ;;
  *) usage ;;
esac
