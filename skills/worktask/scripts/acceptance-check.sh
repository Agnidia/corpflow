#!/usr/bin/env bash
# @description acceptance-check.sh — the acceptance-command gate, for DV and for QA.
#   DV lists, under its acceptance-commands anchor, one command per exact-output rule of the task
#   (CLI contract, output format, byte-level example). Each command must have run with exit 0
#   before the stage hands off: DV records its own run as `- exit=<n> <command>` rows next to the
#   fence and checks them with `--dv` alone, and QA replays every line and records the same rows
#   under its own anchor, checked with `--qa`. A green unit suite does not stand in for it: an
#   exact-output contract is what a paraphrase between agents loses.
#
# Usage: acceptance-check.sh --dv <development-N.md> [--dv <path>]...
#            DV self-check: the rows come from the DV artifacts themselves.
#        acceptance-check.sh --qa <testing-N.md> --dv <development-N.md> [--dv <path>]...
#            QA replay: the rows come from the QA artifact only.
#        acceptance-check.sh -h | --help
#
# @arg --dv <path>  A DV artifact, repeatable (one per DV ledger row).
# @arg --qa <path>  The QA artifact being written. Without it the script runs the DV self-check.
#
# Commands are read from the fenced block(s) under each `## acceptance-commands` heading of
# the DV artifacts: one command per non-blank line, `#` comment lines skipped. Rows are the
# `- exit=<n> <command>` list items under the same heading of the QA artifact (QA replay) or of
# the DV artifacts, outside the fence (DV self-check). Text is compared after trimming
# surrounding whitespace, never executed — this script only reads.
#
# Every command must also fail closed. A command whose top-level tail is `|| true`, `|| :`,
# `|| echo …` or `|| printf …` exits 0 whatever it found, so a green row proves nothing; it is
# reported as `fail-open:` in both modes. `|| exit 1` and `|| false` are not reported, nor is a
# `||` inside quotes, `$( )`, `( )` or `{ }`.
#
# stdout: `acceptance: <executed>/<required> executed, <failed> failed` then, per offending
#   command, one `missing: <command>` or `failed: <command>` line and one `fail-open: <command>`
#   line where they apply.
#
# @exitcode 0  Pass: every required command was executed with exit 0 and none fails open
#              (or none are required).
# @exitcode 1  No-go: a required command was not executed, exited non-zero, or fails open.
# @exitcode 2  Usage error (no --dv), or an artifact could not be read.
#
# Minimum shell: bash 3.2+ (macOS default). Requires awk.

set -euo pipefail
IFS=$'\n\t'
export LC_ALL=C

usage_error() {
  printf >&2 'acceptance-check: %s\n' "$1"
  printf >&2 'usage: acceptance-check.sh --dv <development-N.md> [--dv <path>]...                       (DV self-check)\n'
  printf >&2 '       acceptance-check.sh --qa <testing-N.md> --dv <development-N.md> [--dv <path>]...   (QA replay)\n'
  exit 2
}

QA=""
DV_LIST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --qa) [ $# -ge 2 ] || usage_error "--qa needs a path"; QA="$2"; shift 2 ;;
    --dv) [ $# -ge 2 ] || usage_error "--dv needs a path"; DV_LIST="${DV_LIST}${2}"$'\n'; shift 2 ;;
    -h | --help) awk '/^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done
[ -n "$DV_LIST" ] || usage_error "at least one --dv is required"

# Lines of the fenced blocks under `## acceptance-commands`, up to the next H2.
dv_commands() {
  awk '
    /^## / { on = ($0 ~ /^## acceptance-commands[[:space:]]*$/); fence = 0; next }
    !on { next }
    /^```/ { fence = !fence; next }
    fence {
      line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line != "" && line !~ /^#/) print line
    }' "$1"
}

# `<exit>\t<command>` for each `- exit=<n> <command>` row under the heading. skipfence=1 is the
# DV self-check: there the fence holds the commands, so a row-shaped line inside it is a command
# and not evidence. QA mode leaves fences alone, as it always has.
exit_rows() {  # <artifact> <skipfence 0|1>
  awk -v skipfence="$2" '
    /^## / { on = ($0 ~ /^## acceptance-commands[[:space:]]*$/); fence = 0; next }
    !on { next }
    skipfence && /^```/ { fence = !fence; next }
    fence { next }
    /^[[:space:]]*[-*][[:space:]]+exit=[0-9]+[[:space:]]/ {
      line = $0; sub(/^[[:space:]]*[-*][[:space:]]+exit=/, "", line)
      code = line; sub(/[[:space:]].*$/, "", code)
      sub(/^[0-9]+[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      gsub(/^`|`$/, "", line)
      print code "\t" line
    }' "$1"
}

# Prints the command when its last top-level list operator is `||` and the word after it is
# true, :, echo or printf. "Top-level" is what decides the exit status: quotes, `$( )`, `( )`
# and `{ }` are skipped, a pipeline after the `||` binds tighter so its last stage decides, and
# an unquoted `#` word ends the line. The `&` and `|` of a redirect (`>&2`, `2>&1`, `<&0`, `&>`,
# `>|`) are not list operators; counting them would hide `|| echo x >&2`, the commonest form. `[[ … || … ]]` is not tracked; its right operand is never
# one of the four words in practice.
fail_open() {  # <command>
  printf '%s\n' "$1" | awk '
    {
      s = $0; n = length(s); q = ""; depth = 0; last = ""; tail = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "\x27") { if (c == "\x27") q = ""; continue }
        if (c == "\\") { i++; continue }
        if (q == "\"") { if (c == "\"") q = ""; continue }
        if (c == "\x27" || c == "\"") { q = c; continue }
        if (c == "(" || c == "{") { depth++; continue }
        if ((c == ")" || c == "}") && depth > 0) { depth--; continue }
        if (depth > 0) continue
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:]]/)) { n = i - 1; break }
        p = (i > 1) ? substr(s, i - 1, 1) : ""
        if (c == "&" && (p == ">" || p == "<" || substr(s, i + 1, 1) == ">")) continue
        if (c == "|" && p == ">") continue
        two = substr(s, i, 2)
        if (two == "||" || two == "&&") { last = two; tail = i + 2; i++; continue }
        if (c == ";" || c == "|" || c == "&") { last = c; tail = i + 1 }
      }
      if (last != "||") exit
      rest = substr(s, tail, n - tail + 1)
      sub(/^[[:space:]]+/, "", rest)
      word = rest; sub(/[[:space:]].*$/, "", word)
      if (word == "true" || word == ":" || word == "echo" || word == "printf") print s
    }'
}

[ -z "$QA" ] || [ -r "$QA" ] || usage_error "cannot read QA artifact: $QA"
REQUIRED=""
ROWS=""
while IFS= read -r dv; do
  [ -n "$dv" ] || continue
  [ -r "$dv" ] || usage_error "cannot read DV artifact: $dv"
  REQUIRED="${REQUIRED}$(dv_commands "$dv")"$'\n'
  [ -n "$QA" ] || ROWS="${ROWS}$(exit_rows "$dv" 1)"$'\n'
done <<< "$DV_LIST"
[ -z "$QA" ] || ROWS="$(exit_rows "$QA" 0)"

required=0 executed=0 failed=0 open=0 report=""
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  required=$((required + 1))
  code=""
  while IFS=$'\t' read -r c row; do
    [ "$row" = "$cmd" ] && { code="$c"; break; }
  done <<< "$ROWS"
  if [ -z "$code" ]; then
    report="${report}missing: ${cmd}"$'\n'
  else
    executed=$((executed + 1))
    if [ "$code" != "0" ]; then
      failed=$((failed + 1))
      report="${report}failed: ${cmd}"$'\n'
    fi
  fi
  if [ -n "$(fail_open "$cmd")" ]; then
    open=$((open + 1))
    report="${report}fail-open: ${cmd}"$'\n'
  fi
done <<< "$(printf '%s' "$REQUIRED" | awk '!seen[$0]++')"

printf 'acceptance: %d/%d executed, %d failed\n' "$executed" "$required" "$failed"
printf '%s' "$report"
[ "$executed" -eq "$required" ] && [ "$failed" -eq 0 ] && [ "$open" -eq 0 ]
