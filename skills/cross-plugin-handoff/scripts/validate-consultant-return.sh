#!/usr/bin/env bash
# @description Validates a sibling consultant's findings return against consultant-return.v1
#              and prints the normalized object. Input is one JSON object, or markdown whose
#              LAST closed ```json fence holds it. Parsed by jq only; no input value reaches
#              a command line. Requires bash >= 3.2 and jq >= 1.6.
# @arg --file <path>   Read the return from a file.
# @arg -               Read the return from stdin.
# @arg --self-test     Run the bundled checks; prints "self-test OK".
# @arg -h | --help     Print usage on stdout.
# @stdout Exit 0 only: one line of compact JSON, keys schema_version, verdict, severity_counts, findings.
#         severity_counts carries info, after low, only when the input carries it.
# @stderr "warn: <code>: <detail>" lines (exit 0), one "reject: <code>: <detail>" (exit 1),
#         or one "error: <code>: <detail>" (exit 2).
# @exitcode 0  Valid. Warnings, in order: version_absent, needs_changes_normalized, count_mismatch.
# @exitcode 1  Rejected; first failing check wins: version_mismatch, missing_severity_counts,
#              invalid_severity_counts, missing_findings, invalid_finding, invalid_verdict.
# @exitcode 2  Error: usage, unreadable, missing_dependency, no_json, unparseable.
set -Eeuo pipefail
shopt -s inherit_errexit 2> /dev/null || true
IFS=$'\n\t'
# Returns carry unpublished findings; the staged copy must not be world-readable.
umask 077

readonly SCHEMA_ID="consultant-return.v1"
WORK_DIR=""

# shellcheck disable=SC2329 # invoked by the EXIT trap, which shellcheck does not trace
cleanup() {
  if [ -n "$WORK_DIR" ]; then rm -rf -- "$WORK_DIR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# An unforeseen fault is the caller's environment, not the consultant's return, so it
# takes a code consumers fix locally instead of one that re-dispatches the consultant.
trap 'printf >&2 "error: unreadable: internal failure at line %s\n" "$LINENO"; exit 2' ERR

# Consumers quote a detail verbatim, so it must stay on one line.
one_line() {
  local s
  s="$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177')"
  printf '%s' "${s:0:80}"
}

fail_error() {
  printf >&2 'error: %s: %s\n' "$1" "$2"
  exit 2
}

usage() {
  printf '%s\n' \
    'Usage: validate-consultant-return.sh --file <path>' \
    '       validate-consultant-return.sh -' \
    '       validate-consultant-return.sh --self-test' \
    '       validate-consultant-return.sh -h | --help' \
    '' \
    'Validates a consultant-return.v1 findings return: a JSON object, or markdown whose' \
    'last closed ```json fence holds it. Exit 0 prints the normalized object on stdout;' \
    'exit 1 prints one "reject: <code>: <detail>" line; exit 2 prints one' \
    '"error: <code>: <detail>" line. Warnings go to stderr as "warn: <code>: <detail>".'
}

# Constant program: input reaches jq as data on stdin, never as program text.
# Output lines are "reject|warn<TAB>code<TAB>detail" or "out<TAB>-<TAB>json"; details are
# already single-line, so the TAB split in the caller is unambiguous.
# shellcheck disable=SC2016 # $i, $p, $k, $ks are jq variables and must reach jq unexpanded
readonly JQ_VALIDATE='
def sevs: ["critical", "high", "medium", "low"];
# info is optional, so a four-key return keeps byte-identical output and warning text.
def levels: sevs + ["info"];
def clean: explode | map(select((. >= 32 and . < 127) or . > 159)) | implode | .[0:80];
def shown: tojson | clean;
def is_count: type == "number" and . >= 0 and . == floor;
def finding_reject($i):
  "findings[\($i)]" as $p
  | if type != "object" then "\($p): not an object (\(type))"
    elif (has("id") | not) then "\($p).id: absent"
    elif (.id | type) != "string" or .id == "" then "\($p).id: \(.id | shown)"
    elif (has("severity") | not) then "\($p).severity: absent"
    elif ([levels[] == .severity] | any | not) then "\($p).severity: \(.severity | shown)"
    elif (has("summary") | not) then "\($p).summary: absent"
    elif (.summary | type) != "string" or .summary == "" then "\($p).summary: \(.summary | shown)"
    elif has("location") and (.location | type) != "string" then "\($p).location: \(.location | shown)"
    else empty end;
def rejects:
  (if has("schema_version") and .schema_version != "consultant-return.v1"
     then ["version_mismatch", "schema_version: \(.schema_version | shown)"] else empty end),
  (if (has("severity_counts") | not)
     then ["missing_severity_counts", "severity_counts: absent"] else empty end),
  (.severity_counts
   | if type != "object" then ["invalid_severity_counts", "severity_counts: not an object (\(type))"]
     elif ((keys - ["info"]) != (sevs | sort)) then ["invalid_severity_counts", "severity_counts: keys \(keys | shown)"]
     else ((sevs[], (if has("info") then "info" else empty end)) as $k | select(.[$k] | is_count | not)
           | ["invalid_severity_counts", "severity_counts.\($k): \(.[$k] | shown)"])
     end),
  (if (has("findings") | not) then ["missing_findings", "findings: absent"]
   elif (.findings | type) != "array" then ["missing_findings", "findings: not an array (\(.findings | type))"]
   else empty end),
  (if (.findings | type) == "array"
     then .findings | range(0; length) as $i | .[$i] | finding_reject($i) | ["invalid_finding", .]
     else empty end),
  (if (has("verdict") | not) then ["invalid_verdict", "verdict: absent"]
   elif (.verdict | . == "pass" or . == "fail" or . == "needs_changes") | not
     then ["invalid_verdict", "verdict: \(.verdict | shown)"]
   else empty end);
# floor + 0 prints 1.0 and -0 as 0 on every jq version, which keeps output idempotent.
# An absent info count reads as 0, so info findings under a four-key count still mismatch.
def counts($ks): . as $c | [$ks[] as $k | ($c[$k] // 0) | floor + 0];
def tally($ks): . as $f | [$ks[] as $k | [$f[] | select(.severity == $k)] | length];
def pairs($ks): . as $l | [range(0; $ks | length) as $j | "\($ks[$j])=\($l[$j])"] | join(" ");
(first(rejects) // null) as $r
| if $r != null then "reject\t\($r[0])\t\($r[1])"
  else
    (if (has("schema_version") | not)
       then "warn\tversion_absent\tschema_version absent; stamped consultant-return.v1" else empty end),
    (if .verdict == "needs_changes"
       then "warn\tneeds_changes_normalized\tverdict needs_changes normalized to fail" else empty end),
    ((if (.severity_counts | has("info")) or ([.findings[].severity == "info"] | any)
        then levels else sevs end) as $ks
     | (.severity_counts | counts($ks)) as $c | (.findings | tally($ks)) as $t
     | if $c != $t
         then "warn\tcount_mismatch\tseverity_counts \($c | pairs($ks)) but findings tally \($t | pairs($ks))"
         else empty end),
    ("out\t-\t" + ({
        schema_version: "consultant-return.v1",
        verdict: (if .verdict == "needs_changes" then "fail" else .verdict end),
        severity_counts: ((.severity_counts | counts(levels)) as $c
          | {critical: $c[0], high: $c[1], medium: $c[2], low: $c[3]}
          + (if .severity_counts | has("info") then {info: $c[4]} else {} end)),
        findings: [.findings[] | {id, severity, summary}
          + (if has("location") then {location} else {} end)]
      } | tojson))
  end
'

# --- arguments ---------------------------------------------------------------
MODE=""
FILE_PATH=""
[ "$#" -gt 0 ] || fail_error usage "no arguments; see --help"
case "$1" in
  --file)
    [ "$#" -eq 2 ] || fail_error usage "--file takes exactly one <path>"
    MODE="file"
    FILE_PATH="$2"
    ;;
  -)
    [ "$#" -eq 1 ] || fail_error usage "- takes no further arguments"
    MODE="stdin"
    ;;
  --self-test)
    [ "$#" -eq 1 ] || fail_error usage "--self-test takes no further arguments"
    MODE="self_test"
    ;;
  -h | --help)
    [ "$#" -eq 1 ] || fail_error usage "$1 takes no further arguments"
    usage
    exit 0
    ;;
  *) fail_error usage "unknown argument: $(one_line "$1")" ;;
esac

if [ "$MODE" = "self_test" ]; then
  # Sourced only here so a production run never depends on test code. `[ -r ]` first:
  # a failed `.` is a special-builtin error that exits before any guard can run.
  SELFTEST_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/validate-consultant-return-selftest.sh"
  if [ -r "$SELFTEST_LIB_PATH" ]; then
    # shellcheck source=validate-consultant-return-selftest.sh
    # shellcheck disable=SC1090,SC1091 # resolved at run time beside this script
    . "$SELFTEST_LIB_PATH"
  else
    fail_error unreadable "self-test harness missing beside the validator"
  fi
  run_self_test
fi

command -v jq > /dev/null 2>&1 || fail_error missing_dependency "jq not found on PATH"

# --- stage the input ---------------------------------------------------------
WORK_DIR="$(mktemp -d 2> /dev/null || true)"
[ -n "$WORK_DIR" ] || fail_error unreadable "cannot create a temporary directory"
RAW="$WORK_DIR/raw"
if [ "$MODE" = "file" ]; then
  [ ! -d "$FILE_PATH" ] || fail_error unreadable "is a directory: $(one_line "$FILE_PATH")"
  # Grouped so the shell's own message for a failed `<` is silenced too; `<` rather
  # than an operand so a path named "-" is never read as stdin.
  { cat < "$FILE_PATH" > "$RAW"; } 2> /dev/null \
    || fail_error unreadable "cannot read: $(one_line "$FILE_PATH")"
else
  { cat > "$RAW"; } 2> /dev/null || fail_error unreadable "cannot read stdin"
fi

# --- extract one object ------------------------------------------------------
OBJ="$RAW"
if ! jq -e -s 'length == 1 and (.[0] | type) == "object"' < "$RAW" > /dev/null 2>&1; then
  FENCE="$WORK_DIR/fence"
  fence_rc=0
  # CRs are dropped so CRLF returns match; an unclosed fence never replaces the last closed one.
  awk '
    { sub(/\r$/, "") }
    !open && /^ ? ? ?```json *$/ { open = 1; buf = ""; next }
    open && /^ ? ? ?``` *$/ { open = 0; found = 1; last = buf; next }
    open { buf = buf $0 "\n" }
    END { if (!found) exit 3; printf "%s", last }
  ' "$RAW" > "$FENCE" || fence_rc=$?
  case "$fence_rc" in
    0) ;;
    3) fail_error no_json "no JSON object and no closed \`\`\`json fence" ;;
    *) fail_error unreadable "cannot scan input for a json fence" ;;
  esac
  # The fallback stays inside the substitution: set -E hands the ERR trap to subshells.
  shape="$(jq -r -s 'if length == 1 and (.[0] | type) == "object" then "object" else "other" end' \
    < "$FENCE" 2> /dev/null || printf 'invalid')"
  case "$shape" in
    object) ;;
    other) fail_error no_json "last \`\`\`json fence does not hold exactly one object" ;;
    *) fail_error unparseable "last \`\`\`json fence is not valid JSON" ;;
  esac
  OBJ="$FENCE"
fi

# --- validate and normalize --------------------------------------------------
RESULT="$WORK_DIR/result"
jq -r "$JQ_VALIDATE" < "$OBJ" > "$RESULT" 2> /dev/null \
  || fail_error unparseable "jq could not evaluate the object"

warnings=""
out_json=""
while IFS=$'\t' read -r kind code detail; do
  case "$kind" in
    reject)
      printf >&2 'reject: %s: %s\n' "$code" "$detail"
      exit 1
      ;;
    warn) warnings="${warnings}warn: ${code}: ${detail}"$'\n' ;;
    out) out_json="$detail" ;;
    *) ;;
  esac
done < "$RESULT"

[ -n "$out_json" ] || fail_error unparseable "jq produced no $SCHEMA_ID object"
printf >&2 '%s' "$warnings"
printf '%s\n' "$out_json"
exit 0
