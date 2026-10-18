#!/usr/bin/env bash
# portability-lint.sh — flags BSD/GNU shell divergences (rules P001-P009) so a new one
# cannot land the way the 32 mktemp -t sites did.
#
# Usage:
#   portability-lint.sh                 # repo subject: git ls-files '*.sh' '*.bats' 'Makefile'
#   portability-lint.sh [--] <path>...  # explicit paths
#   portability-lint.sh --self-test     # built-in fixtures, one positive + one negative per rule
#   portability-lint.sh -h | --help
#
# Rules (IDs are interface — they appear in output and in disable directives):
#   P001  mktemp with -t in any option position (BSD "-t" means prefix, not GNU's template)
#   P002  mktemp template whose XXXXXX run is not the final characters (BSD substitutes
#         only a trailing run; a suffix after it comes back literal)
#   P003  sed -i with no suffix argument (BSD requires one, even if empty)
#   P004  single-path stat/date/hash with no sibling form in the same file
#   P005  bash 4+ syntax against the repository's bash 3.2 floor
#   P006  unguarded platform-only (Apple) binary at command position
#   P007  direct `uname` call outside host-os-lib.sh
#   P008  GNU-only flags (grep -P, find -printf, sort -V, readlink -f, GNU long options);
#         `git grep -P` is exempt (git ships its own PCRE2 matcher on every host)
#   P009  `\b` in a git grep pattern without -P (BSD regex has no `\b`, so the match is
#         silently empty on macOS)
#
# Suppression, in precedence order:
#   1. A line whose first non-blank character is `#` is never scanned.
#   2. Inline: `# portability-lint disable=P001 — <reason>`, same line or the line above.
#      The reason is mandatory; a reasonless directive is itself reported as P000.
#   3. File-level: `# portability-lint disable-file=P004,P008 — <reason>` in the first 20 lines.
#   4. Hard path exclusions: tests/vendor/ and this lint's own fixture directory.
#
# A hit prints `<path>:<line>:<RULE-ID>: <message>` on stdout; error lines start
# `portability-lint: ` on stderr, with one count line at the end.
#
# Exit: 0 clean, 1 at least one violation, 2 usage error / unreadable path / not a git
# repository / self-test harness unreachable. 2 wins over 1 — a partial scan is no verdict.
#
# Minimum shell: bash 3.2+ (macOS default).

set -euo pipefail

usage() {
  if [ "${1:-2}" -eq 0 ]; then
    sed -n '2,/^$/s/^# \{0,1\}//p' "$0"
  else
    sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2
  fi
  exit "${1:-2}"
}

err() {
  printf >&2 'portability-lint: %s\n' "$*"
}

HIT_COUNT=0
SCAN_ERR=0

# All rule IDs, space-delimited — the closed vocabulary a disable directive may name.
RULE_IDS="P001 P002 P003 P004 P005 P006 P007 P008 P009"

is_known_rule() {
  case " $RULE_IDS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# unknown_rule_ids <comma-list> -> prints the tokens in <comma-list> that are not in
# RULE_IDS, one per line. A directive naming only unknown IDs suppresses nothing, so
# scan_directive_reasonless() below also flags it — a typo'd rule ID must be visible,
# never a silent successful suppression.
unknown_rule_ids() {
  local ids="$1" id
  local IFS=','
  for id in $ids; do
    is_known_rule "$id" || printf '%s\n' "$id"
  done
}

# is_comment_line <line> -> rc 0 when the first non-blank character is `#`.
# NOT `[[:space:]]*'#'*` (a single-char bracket expression followed by two unanchored
# globs, matching "one space then # anywhere") — this strips exactly the leading
# whitespace run via a bash 3.2 parameter expansion, no extglob needed.
is_comment_line() {
  local l="$1" lead
  lead="${l%%[![:space:]]*}"
  case "${l#"$lead"}" in
    '#'*) return 0 ;;
  esac
  return 1
}

# has_directive_marker <line> -> rc 0 when <line> carries a real suppression-comment
# marker for this lint — either the whole line is a comment (is_comment_line), or the
# marker is a trailing comment preceded by whitespace. A bare substring search for the
# directive keyword pair is not enough: this file's own case-pattern source lines quote
# that exact text as glob literals, and a naive search self-matches them. Requiring the
# `#` to be a real comment opener — line-start (after whitespace) or whitespace-preceded —
# excludes a quoted string with no comment marker of its own, since nothing in this file
# has a bare space immediately before the `#` inside those quotes.
has_directive_marker() {
  local line="$1"
  if is_comment_line "$line"; then
    case "$line" in
      *'portability-lint disable'*) return 0 ;;
    esac
    return 1
  fi
  case "$line" in
    *[[:space:]]'#'*'portability-lint disable'*) return 0 ;;
  esac
  return 1
}

# file_level_disabled <file> <rule> -> rc 0 when a disable-file directive in the first
# 20 lines names <rule> and carries a reason.
file_level_disabled() {
  local f="$1" rule="$2" line ids reason=""
  local n=0
  while IFS= read -r line && [ "$n" -lt 20 ]; do
    n=$((n + 1))
    has_directive_marker "$line" || continue
    case "$line" in
      *'disable-file='*)
        ids="${line#*disable-file=}"
        ids="${ids%% *}"
        ids="${ids%%$'\t'*}"
        reason="${line#*—}"
        case " ${ids//,/ } " in
          *" $rule "*)
            [ -n "${reason# }" ] && [ "$reason" != "$line" ] && return 0
            ;;
        esac
        ;;
    esac
  done < "$f"
  return 1
}

# line_has_directive <line> <rule> -> rc 0 when the line carries an inline disable
# directive naming <rule>; prints P000 to stderr-tracked global when the reason is missing.
_directive_ids_and_reason() {
  local line="$1" ids reason
  has_directive_marker "$line" || return 1
  case "$line" in
    *'disable-file='*) return 1 ;;
    *'disable='*)
      ids="${line#*disable=}"
      ids="${ids%% *}"
      ids="${ids%%$'\t'*}"
      reason="${line#*—}"
      [ "$reason" = "$line" ] && reason=""
      printf '%s\n%s\n' "$ids" "$reason"
      return 0
      ;;
  esac
  return 1
}

# scan_directive_reasonless <file> — reports P000 for any disable directive (inline or
# file-level) in <file> that carries no reason text after the em dash, OR whose ID list
# is entirely unknown rule IDs (a typo'd ID suppresses nothing, so it must not read as a
# working suppression either — is_known_rule() is what makes that check real).
scan_directive_reasonless() {
  local f="$1" lineno=0 line ids reason unk
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    has_directive_marker "$line" || continue
    case "$line" in
      *'disable='* | *'disable-file='*)
        ids="${line#*disable}"
        ids="${ids#*=}"
        ids="${ids%% *}"
        ids="${ids%%$'\t'*}"
        case "$line" in
          *'—'*) reason="${line#*—}" ;;
          *) reason="" ;;
        esac
        if [ -z "${reason# }" ]; then
          printf '%s:%d:P000: disable directive with no reason (%s)\n' "$f" "$lineno" "$ids"
          HIT_COUNT=$((HIT_COUNT + 1))
        fi
        unk=$(unknown_rule_ids "$ids" | tr '\n' ',')
        unk="${unk%,}"
        if [ -n "$unk" ]; then
          printf '%s:%d:P000: disable directive names unknown rule id(s) (%s)\n' "$f" "$lineno" "$unk"
          HIT_COUNT=$((HIT_COUNT + 1))
        fi
        ;;
    esac
  done < "$f"
}

# suppressed <file> <lineno> <rule> <prevline_directive_hit> -> rc 0 when this hit is
# suppressed by tier 2 (same/previous line) or tier 3 (file-level).
suppressed_inline() {
  local this_line="$1" prev_line="$2" rule="$3" out ids reason candidate
  for candidate in "$this_line" "$prev_line"; do
    [ -n "$candidate" ] || continue
    if out=$(_directive_ids_and_reason "$candidate"); then
      ids=$(printf '%s' "$out" | sed -n '1p')
      reason=$(printf '%s' "$out" | sed -n '2p')
      case " ${ids//,/ } " in
        *" $rule "*)
          [ -n "${reason# }" ] && return 0
          ;;
      esac
    fi
  done
  return 1
}

# report <file> <lineno> <rule> <message> <curline> <prevline> — the single hit-emission
# path; applies tiers 2 and 3, then either prints or silently swallows the (suppressed)
# hit. <curline> is the already-read line from scan_file's loop — never re-read via a
# `sed` fork, which scan_file's caller already paid the cost of reading once.
report() {
  local f="$1" lineno="$2" rule="$3" msg="$4" curline="$5" prevline="$6"
  # Tier 1: comment-only lines are never scanned/reported at the call site.
  is_comment_line "$curline" && return 0
  suppressed_inline "$curline" "$prevline" "$rule" && return 0
  file_level_disabled "$f" "$rule" && return 0
  printf '%s:%d:%s: %s\n' "$f" "$lineno" "$rule" "$msg"
  HIT_COUNT=$((HIT_COUNT + 1))
}

# A git-grep head: `git` as a word, any global options (`-C <dir>`, `-c k=v`, `--no-pager`),
# then the `grep` subcommand. Kept in a variable because bash 3.2 and 4+ disagree on a
# quoted regex written inline in `[[ =~ ]]`.
GIT_GREP_HEAD='(^|[^A-Za-z0-9_./-])git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--[A-Za-z][A-Za-z-]*(=[^[:space:]]*)?))*[[:space:]]+grep([[:space:]]|$)'
GIT_GREP_PERL='(^|[[:space:]])(-[A-Za-z]*P[A-Za-z]*|--perl-regexp)([[:space:]=]|$)'

# cmd_segment <text> — sets SEGMENT to <text> up to the first `|`, `;` or `&&` outside
# quotes and SEGMENT_REST to what follows, so a -P on the next command of a pipeline is
# never credited to this one. Globals, not stdout: a `$(...)` per git grep line would
# fork on the lint's hot path.
cmd_segment() {
  local s="$1" i=0 c q="" n=${#1}
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"
    if [ "$c" = "\\" ] && [ "$q" != "'" ]; then
      i=$((i + 2))
      continue
    fi
    if [ -n "$q" ]; then
      [ "$c" = "$q" ] && q=""
    else
      case "$c" in
        "'" | '"') q="$c" ;;
        '|' | ';') break ;;
        '&') [ "${s:i:2}" = '&&' ] && break ;;
      esac
    fi
    i=$((i + 1))
  done
  SEGMENT="${s:0:i}"
  SEGMENT_REST="${s:i}"
}

# p009_scan <file> <lineno> <line> <prev> — at most one P009 per line, over every git
# grep command the line holds.
p009_scan() {
  local f="$1" lineno="$2" rest="$3" prev="$4"
  while [[ "$rest" =~ $GIT_GREP_HEAD ]]; do
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    cmd_segment "$rest"
    rest="$SEGMENT_REST"
    case "$SEGMENT" in
      *'\b'*)
        if [[ ! "$SEGMENT" =~ $GIT_GREP_PERL ]]; then
          report "$f" "$lineno" P009 "\\b in a git grep pattern without -P matches nothing on BSD regex — use git grep -P, or git grep -w for a whole word" "$3" "$prev"
          return 0
        fi
        ;;
    esac
  done
}

# scan_line_rules <file> <lineno> <line> <prevline> <p004_stat_exon> <p004_date_exon>
#   <p004_hash_exon> <p006_exonerated>
scan_line_rules() {
  local f="$1" lineno="$2" line="$3" prev="$4"
  local p004_stat_exon="$5" p004_date_exon="$6" p004_hash_exon="$7" p006_exon="$8"

  # `[[ =~ ]]` throughout, deliberately, never a piped `grep`: this scans every line of
  # the repository's ~52,800-line shell surface, and a forked grep per line per rule
  # turned that into a multi-minute run. The bash builtin costs no subprocess.
  case "$line" in
    *mktemp*)
      if [[ "$line" =~ mktemp(\ +-[a-zA-Z]+)*\ +-[a-zA-Z]*t($|[^a-zA-Z]) ]]; then
        # portability-lint disable=P001 — message text below names "mktemp -t" in prose, not a real call
        report "$f" "$lineno" P001 "mktemp -t is a BSD prefix flag, not a GNU template (AD-3 shape: mktemp [-d] \"\${TMPDIR:-/tmp}/<prefix>.XXXXXX\")" \
          "$line" "$prev"
      fi
      # The trailing-char class excludes X: ERE backtracking would otherwise shrink the
      # X{6,} match by one and count that leftover X as "the character after the run".
      if [[ "$line" =~ mktemp.*X{6,}[A-WYZa-z0-9._-] ]]; then
        report "$f" "$lineno" P002 "mktemp template's XXXXXX run must be the final characters — BSD substitutes only a trailing run" "$line" "$prev"
      fi
      ;;
  esac

  if [[ "$line" =~ sed\ +-i($|[^.\'\"a-zA-Z]) ]]; then
    if [[ ! "$line" =~ sed\ +-i(\.[A-Za-z0-9_-]+|\ +\'\'|\ +\"\") ]]; then
      report "$f" "$lineno" P003 "sed -i needs a suffix argument on BSD, even an empty one (sed -i '' or sed -i.bak)" "$line" "$prev"
    fi
  fi

  if [ "$p004_stat_exon" != 1 ] && [[ "$line" =~ (^|[^A-Za-z0-9_])stat\ +-[cf]($|[^A-Za-z0-9_]) ]]; then
    report "$f" "$lineno" P004 "single-path stat form — pair with the sibling -c/-f form in the same file, or disable with a reason" "$line" "$prev"
  fi
  if [ "$p004_date_exon" != 1 ] && [[ "$line" =~ (^|[^A-Za-z0-9_])date\ +-[drv]($|[^A-Za-z0-9_]) ]]; then
    report "$f" "$lineno" P004 "single-path date form — pair with the sibling -d/-r/-v form in the same file, or disable with a reason" "$line" "$prev"
  fi
  # `shasum` is not flagged here: it is a Perl-shipped tool present on both BSD/macOS
  # and Linux, not a GNU-vs-BSD divergent form like md5sum/sha256sum (GNU-only; BSD/macOS
  # has `md5` and `shasum -a` instead). Flagging it would make every already-portable
  # shasum-only call site read as a violation, which is exactly the false-positive class
  # rule_file_exonerated's hash branch below exists to not need a directive for.
  if [ "$p004_hash_exon" != 1 ] && [[ "$line" =~ (^|[^A-Za-z0-9_])(md5sum|sha256sum)($|[^A-Za-z0-9_]) ]]; then
    report "$f" "$lineno" P004 "GNU-only hash tool with no BSD/macOS equivalent in this file — pair with shasum, or disable with a reason" "$line" "$prev"
  fi

  # portability-lint disable=P005 — this pattern's own source names mapfile/readarray; not bash4+ usage
  if [[ "$line" =~ (declare\ +-A|local\ +-A|(^|[^A-Za-z0-9_])(mapfile|readarray)($|[^A-Za-z0-9_])|[$][{][A-Za-z_][A-Za-z0-9_]*(\^\^|,,)[}]|\&\>\>|(^|\ )\|\&(\ |$)) ]]; then
    report "$f" "$lineno" P005 "bash 4+ syntax against the repository's bash 3.2 floor" "$line" "$prev"
  fi

  if [ "$p006_exon" != 1 ] \
    && [[ "$line" =~ (^|[\;\&\|\(]|\&\&|\|\|)\ *(pbcopy|pbpaste|sips|osascript|plutil|sw_vers|xcrun|caffeinate|afplay)\  ]]; then
    report "$f" "$lineno" P006 "unguarded Apple-only binary at command position — guard with command -v first" "$line" "$prev"
  fi

  case "$f" in
    */host-os-lib.sh | host-os-lib.sh) : ;;
    *portability-lint.sh)
      : # portability-lint disable=P007 — this file's own pattern and message text name uname; not a real call
      ;;
    *)
      if [[ "$line" =~ (^|[^A-Za-z0-9_])uname($|[^A-Za-z0-9_]) ]]; then
        report "$f" "$lineno" P007 "direct uname call — branch on host_os() from host-os-lib.sh instead" "$line" "$prev"
      fi
      ;;
  esac

  # P009 and P008's grep -P branch key on the same git-grep head. P008 tests a copy with
  # each head swapped for a token that does not end in `grep`, so `git grep -P` passes
  # while a bare `grep -P` later in the same pipeline still fires.
  local p008_line="$line" before
  case "$line" in
    *git*grep*)
      case "$f" in
        *portability-lint.sh) : ;; # own regex and message text hold both tokens
        *) p009_scan "$f" "$lineno" "$line" "$prev" ;;
      esac
      while [[ "$p008_line" =~ $GIT_GREP_HEAD ]]; do
        before="$p008_line"
        p008_line="${p008_line/"${BASH_REMATCH[0]}"/ _gg_ }"
        [ "$p008_line" != "$before" ] || break
      done
      ;;
  esac

  if [[ "$p008_line" =~ grep\ +(-[A-Za-z]*)?-P($|[^A-Za-z]) ]] \
    || [[ "$line" =~ find\ .*-printf($|[^A-Za-z]) ]] \
    || [[ "$line" =~ sort\ +(-[A-Za-z]*)?-V($|[^A-Za-z]) ]] \
    || [[ "$line" =~ readlink\ +(-[A-Za-z]*)?-f($|[^A-Za-z]) ]]; then
    report "$f" "$lineno" P008 "GNU-only flag — no portable BSD equivalent in this form" "$line" "$prev"
  fi
}

# rule_file_exonerated <file> <rule> [<family>] -> rc 0 when P004/P006's coarse,
# file-scoped exoneration applies: for P004, the SIBLING form of the same tool family is
# also present in the file (both a GNU and a BSD form — evidence of an existing dual-path
# dispatch, not just any two unrelated tools), or a matching command -v guard; for P006, a
# matching command -v guard. Deliberately coarse — a line-oriented
# bash lint cannot do reliable scope analysis — but coarse is not the same as inert: a
# single-family check (was: "file has || AND any of stat/date/hash", which the hit line
# itself always satisfies, making every P004 candidate self-exonerate) must require the
# OTHER form of the SAME family, per <family>.
rule_file_exonerated() {
  local f="$1" rule="$2" family="${3:-}"
  case "$rule" in
    P004)
      case "$family" in
        stat)
          grep -qE '\bstat[[:space:]]+-c\b' "$f" 2> /dev/null && grep -qE '\bstat[[:space:]]+-f\b' "$f" 2> /dev/null && return 0
          grep -qE 'command[[:space:]]+-v[[:space:]]+stat\b' "$f" 2> /dev/null && return 0
          ;;
        date)
          grep -qE '\bdate[[:space:]]+-d\b' "$f" 2> /dev/null && grep -qE '\bdate[[:space:]]+-[rv]\b' "$f" 2> /dev/null && return 0
          grep -qE 'command[[:space:]]+-v[[:space:]]+date\b' "$f" 2> /dev/null && return 0
          ;;
        hash)
          # `shasum` itself is the portable escape hatch (Perl-shipped, present on both
          # BSD/macOS and Linux — this repo's suite is already green on Linux CI calling
          # it), so its presence anywhere in the file exonerates a bare md5sum/sha256sum
          # the same way a real sibling form would.
          grep -qE '\bshasum\b' "$f" 2> /dev/null && return 0
          grep -qE '\bmd5sum\b' "$f" 2> /dev/null && grep -qE '\bsha256sum\b' "$f" 2> /dev/null && return 0
          grep -qE 'command[[:space:]]+-v[[:space:]]+(md5sum|shasum|sha256sum)\b' "$f" 2> /dev/null && return 0
          ;;
      esac
      ;;
    P006)
      grep -qE 'command[[:space:]]+-v[[:space:]]+(pbcopy|pbpaste|sips|osascript|plutil|sw_vers|xcrun|caffeinate|afplay)' "$f" 2> /dev/null && return 0
      ;;
  esac
  return 1
}

is_excluded_path() {
  case "$1" in
    tests/vendor/* | */tests/vendor/*) return 0 ;;
    */portability-lint-fixtures/* | portability-lint-fixtures/*) return 0 ;;
    # Fixture-GENERATING files, not a fixtures/ directory by name but the same class
    # AD-2 already exempts: every rule string these embed is test DATA (fixture content
    # a contract-test file feeds to a lint subprocess, or a shadow function a contract
    # test defines to fake a platform command), not code this file executes — a
    # line-oriented scan cannot tell "quoted fixture literal" / "test double" from "real
    # call" apart, so self-scanning them would only ever measure fixture coverage, never
    # a real portability defect.
    #
    # Three literal names, not yet a predicate: this is the third file needing the
    # exemption for the same structural reason (host-os-lib.bats joins portability-lint's
    # own two, after its `uname()`-shadowing fixtures self-hit P007 once tracked — B1's
    # exact shape recurring). A predicate broad enough to also catch a fourth case
    # without being named here would have to key on "is a *.bats testing something this
    # lint's rule set inherently quotes" — genuinely hard to state without either missing
    # a real one (a rule-relevant substring appearing incidentally, not structurally) or
    # over-matching and blinding the lint to a real violation inside an unrelated test
    # file. Three explicit, individually-justified names is the safer shape until a
    # fourth recurrence gives an actual predicate to generalise from, rather than a
    # guessed one now.
    */portability-lint-selftest.sh | portability-lint-selftest.sh) return 0 ;;
    */tests/shell/worktask/portability-lint.bats | tests/shell/worktask/portability-lint.bats) return 0 ;;
    */tests/shell/worktask/host-os-lib.bats | tests/shell/worktask/host-os-lib.bats) return 0 ;;
  esac
  return 1
}

scan_file() {
  local f="$1"
  is_excluded_path "$f" && return 0
  [ -f "$f" ] && [ -r "$f" ] || {
    err "cannot read $f"
    SCAN_ERR=1
    return 0
  }

  scan_directive_reasonless "$f"

  local p004_stat_exon=0 p004_date_exon=0 p004_hash_exon=0 p006_exon=0
  rule_file_exonerated "$f" P004 stat && p004_stat_exon=1
  rule_file_exonerated "$f" P004 date && p004_date_exon=1
  rule_file_exonerated "$f" P004 hash && p004_hash_exon=1
  rule_file_exonerated "$f" P006 && p006_exon=1

  local lineno=0 line prev=""
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if is_comment_line "$line"; then
      prev="$line"
      continue
    fi
    scan_line_rules "$f" "$lineno" "$line" "$prev" \
      "$p004_stat_exon" "$p004_date_exon" "$p004_hash_exon" "$p006_exon"
    prev="$line"
  done < "$f"
}

lint_paths() {
  local p
  for p in "$@"; do
    scan_file "$p"
  done
  finish
}

finish() {
  if [ "$HIT_COUNT" -gt 0 ]; then
    err "$HIT_COUNT violation(s)"
  fi
  [ "$SCAN_ERR" -eq 0 ] || exit 2
  [ "$HIT_COUNT" -eq 0 ] || exit 1
  exit 0
}

# repo_subject_paths <fn> — NUL-delimited, so a fixture path with a space (the vendored
# bats-core tree ships one) is one argument to <fn>, never split into two.
repo_subject_paths() {
  local fn="$1" p
  while IFS= read -r -d '' p; do
    "$fn" "$p"
  done < <(git ls-files -z '*.sh' '*.bats' 'Makefile')
}

[ $# -gt 0 ] || {
  git rev-parse --git-dir > /dev/null 2>&1 || {
    err "not a git repository"
    exit 2
  }
  repo_subject_paths scan_file
  finish
}

case "${1:-}" in
  -h | --help) usage 0 ;;
  --self-test)
    [ $# -eq 1 ] || usage 2
    SELFTEST_LIB_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portability-lint-selftest.sh"
    if [ -r "$SELFTEST_LIB_PATH" ]; then
      # shellcheck source=portability-lint-selftest.sh
      # shellcheck disable=SC1090
      . "$SELFTEST_LIB_PATH"
    else
      err "self-test harness unreachable at $SELFTEST_LIB_PATH — plugin install broken"
      exit 2
    fi
    self_test
    ;;
  --)
    shift
    [ $# -gt 0 ] || usage 2
    lint_paths "$@"
    ;;
  -*)
    err "unknown option: $1"
    usage 2
    ;;
  *) lint_paths "$@" ;;
esac
